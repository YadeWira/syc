mod archive;
mod cli;
mod color;
mod delta;
mod detect;
mod dict_fa;
mod fastcdc;
mod lzp;
mod pipeline;
mod pjg;
mod ppg;
mod progress;
mod rep;
mod snapshot;
mod srep;

use anyhow::{anyhow, Context, Result};
use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use crate::archive::{
    collect_entries, gather_samples, pack_entry, read_preamble, solid_sort, train_dict,
    unpack_entry, write_preamble, Backend, EntryHeader, EntryKind, HashAlgo,
    PpmdParams, CHUNK,
    PREPROC_LZP, PREPROC_REP, PREPROC_SREP,
};
use ppmd_rust::{Ppmd7Decoder, Ppmd7Encoder};
use crate::cli::{Cmd, Opts};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    // Pre-scan before the parser runs so the banner honors -nocolor even on
    // parse errors. Both spellings match zpaqfranz (`-nocolor`) and a terse
    // alias (`-nc`).
    let cli_nocolor = args.iter().any(|a| a == "-nocolor" || a == "-nc");
    color::init(cli_nocolor);
    let cmd = match cli::parse(args) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{}", color::err_line(&format!("syc: {e}")));
            std::process::exit(2);
        }
    };
    let (archive_for_hook, exec_ok, exec_error) = match &cmd {
        Cmd::Add { archive, opts, .. }
        | Cmd::Extract { archive, opts }
        | Cmd::List { archive, opts }
        | Cmd::Test { archive, opts } => (
            Some(archive.clone()),
            opts.exec_ok.clone(),
            opts.exec_error.clone(),
        ),
        Cmd::Compare { left, opts, .. } => (
            Some(left.clone()),
            opts.exec_ok.clone(),
            opts.exec_error.clone(),
        ),
        Cmd::Dedupe { root, opts } => (
            Some(root.clone()),
            opts.exec_ok.clone(),
            opts.exec_error.clone(),
        ),
        Cmd::Verify { archive, opts, .. } => (
            Some(archive.clone()),
            opts.exec_ok.clone(),
            opts.exec_error.clone(),
        ),
        _ => (None, None, None),
    };
    // zpaqfranz prints its banner on every invocation, including real
    // commands. Skip for help / bare `syc` (they print help_main themselves).
    if !matches!(cmd, Cmd::Banner | Cmd::Help { .. }) {
        cli::banner();
    }
    let res = match cmd {
        Cmd::Banner => {
            cli::help_main();
            Ok(())
        }
        Cmd::Help { topic } => {
            cli::help(topic);
            Ok(())
        }
        Cmd::Add { archive, sources, opts } => cmd_add(archive, sources, opts),
        Cmd::Extract { archive, opts } => cmd_extract(archive, opts),
        Cmd::List { archive, opts } => cmd_list(archive, opts),
        Cmd::Test { archive, opts } => cmd_test(archive, opts),
        Cmd::Compare { left, right, opts } => cmd_compare(left, right, opts),
        Cmd::Dedupe { root, opts } => cmd_dedupe(root, opts),
        Cmd::Verify { archive, source, opts } => cmd_verify(archive, source, opts),
        Cmd::Scan { path, opts } => cmd_scan(path, opts),
    };
    let (status, hook) = match &res {
        Ok(()) => ("ok", exec_ok.as_deref()),
        Err(_) => ("error", exec_error.as_deref()),
    };
    if let Err(e) = &res {
        eprintln!("{}", color::err_line(&format!("syc: {e:#}")));
        let n = color::err_count();
        let w = color::warn_count();
        let warn_tail = if w > 0 {
            format!(", {} warning{}", w, if w == 1 { "" } else { "s" })
        } else {
            String::new()
        };
        eprintln!("{}", color::r(&format!("({} error{}{}, with errors)",
            n, if n == 1 { "" } else { "s" }, warn_tail)));
    } else {
        // Success path: still surface a one-liner if we emitted any warnings
        // so the user knows something non-fatal happened (e.g. snapshot
        // fallback, flag locked by preamble).
        let w = color::warn_count();
        if w > 0 {
            eprintln!("{}", color::y(&format!(
                "({} warning{})", w, if w == 1 { "" } else { "s" }
            )));
        }
    }
    if let (Some(cmd), Some(archive)) = (hook, archive_for_hook.as_ref()) {
        run_exec_hook(cmd, archive, status);
    }
    if res.is_err() {
        std::process::exit(1);
    }
}

/// European-style thousand separator (zpaqfranz convention). 131858 → "131.858".
fn eu_num(n: u64) -> String {
    let s = n.to_string();
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    for (i, &c) in b.iter().enumerate() {
        if i > 0 && (b.len() - i) % 3 == 0 {
            out.push('.');
        }
        out.push(c as char);
    }
    out
}

/// Compact IEC-style human unit, space between value and label: "128.77 KB".
/// Uses 1024-base like zpaqfranz despite the short "KB/MB" labels.
fn human_si(bytes: u64) -> String {
    const UNITS: &[&str] = &["B", "KB", "MB", "GB", "TB", "PB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    format!("{:.2} {}", v, UNITS[i])
}

fn hms(secs: u64) -> String {
    format!("{:02}:{:02}:{:02}", secs / 3600, (secs / 60) % 60, secs % 60)
}

/// Final one-line footer printed at the end of every command (zpaqfranz
/// convention): `0.020s (00:00:00,7.16MB) (all OK)`. The value after the
/// comma is average throughput.
fn end_footer(elapsed: std::time::Duration, processed_bytes: u64) {
    let secs = elapsed.as_secs_f64();
    let rate = if secs > 0.0 {
        (processed_bytes as f64 / secs) as u64
    } else {
        processed_bytes
    };
    let rate_s = human_si(rate).replace(' ', "");
    eprintln!(
        "{:.3}s ({},{}) {}",
        secs,
        hms(elapsed.as_secs()),
        rate_s,
        color::g("(all OK)"),
    );
}

/// Filter walked entries in-place per -exclude / -minsize / -maxsize /
/// -datefrom / -dateto. Exclude patterns match as case-sensitive substrings
/// against the relative path. Size and date filters only apply to regular
/// files — dirs and symlinks pass.
fn apply_selectors(all: &mut Vec<(PathBuf, PathBuf)>, opts: &Opts) {
    if opts.exclude.is_empty()
        && opts.minsize.is_none()
        && opts.maxsize.is_none()
        && opts.datefrom.is_none()
        && opts.dateto.is_none()
    {
        return;
    }
    let needs_meta = opts.minsize.is_some()
        || opts.maxsize.is_some()
        || opts.datefrom.is_some()
        || opts.dateto.is_some();
    all.retain(|(full, rel)| {
        let rel_s = rel.to_string_lossy();
        for pat in &opts.exclude {
            if rel_s.contains(pat.as_str()) {
                return false;
            }
        }
        if needs_meta {
            match std::fs::symlink_metadata(full) {
                Ok(m) if m.is_file() => {
                    let sz = m.len();
                    if let Some(mn) = opts.minsize { if sz < mn { return false; } }
                    if let Some(mx) = opts.maxsize { if sz > mx { return false; } }
                    if opts.datefrom.is_some() || opts.dateto.is_some() {
                        let mtime = m.modified()
                            .ok()
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| d.as_secs() as i64)
                            .unwrap_or(0);
                        if let Some(from) = opts.datefrom { if mtime < from { return false; } }
                        if let Some(to)   = opts.dateto   { if mtime > to   { return false; } }
                    }
                }
                _ => {}
            }
        }
        true
    });
}

/// Read additional source paths from a file (one per line, blank lines and
/// lines starting with '#' ignored).
fn load_filelist(path: &Path) -> Result<Vec<PathBuf>> {
    let s = std::fs::read_to_string(path)
        .with_context(|| format!("read filelist {}", path.display()))?;
    Ok(s.lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(PathBuf::from)
        .collect())
}

fn run_exec_hook(shell_cmd: &str, archive: &Path, status: &str) {
    let sh = std::process::Command::new("sh")
        .arg("-c")
        .arg(shell_cmd)
        .env("SYC_ARCHIVE", archive.as_os_str())
        .env("SYC_STATUS", status)
        .status();
    if let Err(e) = sh {
        eprintln!("{}", color::err_line(&format!("exec hook failed: {e}")));
    }
}

/// Walk a directory and fingerprint every regular file as (size, crc32).
/// Symlinks and dirs are indexed with size 0, crc32 0 — presence matters only.
fn index_dir(root: &Path) -> Result<std::collections::HashMap<PathBuf, (u64, u32)>> {
    use std::collections::HashMap;
    let root_abs = root.canonicalize().with_context(|| format!("canonicalize {}", root.display()))?;
    let mut map: HashMap<PathBuf, (u64, u32)> = HashMap::new();
    for entry in walkdir::WalkDir::new(&root_abs).follow_links(false) {
        let entry = entry?;
        let rel = match entry.path().strip_prefix(&root_abs) {
            Ok(p) => p.to_path_buf(),
            Err(_) => continue,
        };
        if rel.as_os_str().is_empty() {
            continue;
        }
        let meta = entry.path().symlink_metadata()?;
        if meta.is_file() {
            let mut h = crc32fast::Hasher::new();
            let mut f = BufReader::with_capacity(archive::IO_BUF, File::open(entry.path())?);
            let mut buf = [0u8; CHUNK];
            loop {
                let n = f.read(&mut buf)?;
                if n == 0 { break; }
                h.update(&buf[..n]);
            }
            map.insert(rel, (meta.len(), h.finalize()));
        } else {
            map.insert(rel, (0, 0));
        }
    }
    Ok(map)
}

fn cmd_compare(left: PathBuf, right: PathBuf, opts: Opts) -> Result<()> {
    let started = Instant::now();
    let a = index_dir(&left)?;
    let b = index_dir(&right)?;
    let mut only_a: Vec<&PathBuf> = Vec::new();
    let mut only_b: Vec<&PathBuf> = Vec::new();
    let mut differing: Vec<&PathBuf> = Vec::new();
    let mut same: u64 = 0;
    for (k, v) in &a {
        match b.get(k) {
            None => only_a.push(k),
            Some(v2) if v2 != v => differing.push(k),
            Some(_) => same += 1,
        }
    }
    for k in b.keys() {
        if !a.contains_key(k) {
            only_b.push(k);
        }
    }
    only_a.sort();
    only_b.sort();
    differing.sort();
    if opts.verbose {
        for p in &only_a     { println!("<  {}", p.display()); }
        for p in &only_b     { println!(">  {}", p.display()); }
        for p in &differing  { println!("!= {}", p.display()); }
    }
    let status = if only_a.is_empty() && only_b.is_empty() && differing.is_empty() {
        "match"
    } else {
        "diff"
    };
    eprintln!(
        "{}  only<A {}  only>B {}  differ {}  match {}  [{:.2}s]",
        status,
        only_a.len(),
        only_b.len(),
        differing.len(),
        same,
        started.elapsed().as_secs_f64()
    );
    if status == "diff" {
        std::process::exit(2);
    }
    Ok(())
}

/// Wraps any writer to tally bytes the encoder emitted.
/// Sits *above* BufWriter (between encoder and buffer) so the counter ticks
/// the moment the encoder produces output, not after BufWriter's 1 MiB
/// buffer flushes. Important for LZMA-MT: workers buffer internally and only
/// emit output blocks during `finish()`; counting at disk-level would show
/// 0 B for tens of seconds even though the compressor is alive. This is
/// closer to zpaqfranz's `g_scritti` in spirit (tracks compressor output),
/// just sitting one layer up the chain.
struct CountingWriter<W: Write> {
    inner: W,
    counter: Arc<AtomicU64>,
}

impl<W: Write> CountingWriter<W> {
    fn new(inner: W, counter: Arc<AtomicU64>) -> Self {
        Self { inner, counter }
    }
    fn into_inner(self) -> W {
        self.inner
    }
}

impl<W: Write> Write for CountingWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.counter.fetch_add(n as u64, Ordering::Relaxed);
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// Build the per-part path for -chunk output: base becomes base.001, .002, ...
fn part_path(base: &Path, n: u32) -> PathBuf {
    let mut s = base.as_os_str().to_owned();
    s.push(format!(".{:03}", n));
    PathBuf::from(s)
}

/// Rotating-file writer for -chunk. Emits base.001, .002, ... of `chunk_size`
/// bytes each. The compressed stream is just split byte-for-byte — concat the
/// parts back and you get the original archive.
struct ChunkedWriter {
    base: PathBuf,
    part: u32,
    current: File,
    written_in_part: u64,
    chunk_size: u64,
}

impl ChunkedWriter {
    fn new(base: PathBuf, chunk_size: u64) -> std::io::Result<Self> {
        let path = part_path(&base, 1);
        let current = File::create(&path)?;
        Ok(Self { base, part: 1, current, written_in_part: 0, chunk_size })
    }
    fn announce(&self, part: u32, size: u64) {
        // \r + 80-char-wide line nukes any leftover progress-bar pixels to the
        // right (zpaqfranz progress is ~70 chars). \n commits and the next
        // progress refresh resumes on a fresh line.
        let line = format!("wrote   {} ({})", part_path(&self.base, part).display(), human_si(size));
        eprintln!("\r{:<80}", line);
    }
    fn rotate(&mut self) -> std::io::Result<()> {
        self.current.flush()?;
        self.announce(self.part, self.written_in_part);
        self.part += 1;
        self.current = File::create(part_path(&self.base, self.part))?;
        self.written_in_part = 0;
        Ok(())
    }
}

impl Write for ChunkedWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        // zpaqfranz semantics: write the whole buffer, then rotate once we've
        // crossed the threshold. Parts end up slightly larger than chunk_size
        // (by up to one upstream write — typically tens of KiB) but each part
        // ends on a clean writer-boundary instead of mid-buffer.
        let n = self.current.write(buf)?;
        self.written_in_part += n as u64;
        if self.written_in_part > self.chunk_size {
            self.rotate()?;
        }
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> { self.current.flush() }
}

// Final partial part never crosses the threshold, so rotate() never announces
// it. Drop fires at end of the writer's scope (after pack_all + finish_writes
// have flushed the encoder), so written_in_part is the real on-disk size.
impl Drop for ChunkedWriter {
    fn drop(&mut self) {
        let _ = self.current.flush();
        if self.written_in_part > 0 {
            self.announce(self.part, self.written_in_part);
        }
    }
}

/// Reader that transparently concatenates base.001, .002, ... when the plain
/// base path doesn't exist.
struct ChunkedReader {
    base: PathBuf,
    part: u32,
    current: Option<BufReader<File>>,
}

impl ChunkedReader {
    fn open(base: PathBuf) -> Result<Self> {
        let path = part_path(&base, 1);
        let f = File::open(&path)
            .with_context(|| format!("open {}", path.display()))?;
        Ok(Self { base, part: 1, current: Some(BufReader::with_capacity(archive::IO_BUF, f)) })
    }
    fn advance(&mut self) -> std::io::Result<()> {
        self.part += 1;
        let path = part_path(&self.base, self.part);
        if path.exists() {
            self.current = Some(BufReader::with_capacity(archive::IO_BUF, File::open(path)?));
        } else {
            self.current = None;
        }
        Ok(())
    }
}

impl Read for ChunkedReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            match self.current.as_mut() {
                None => return Ok(0),
                Some(r) => {
                    let n = r.read(buf)?;
                    if n > 0 { return Ok(n); }
                    self.advance()?;
                }
            }
        }
    }
}

/// Open the archive path for writing. Path "-" means stdout. If chunk_bytes is
/// set, output is split into archive.001, .002, ... (stdout + chunk is an error).
///
/// For a regular single-file archive we write to `<archive>.tmp` and return
/// that path as the second tuple element — the caller renames it to the final
/// path once the stream has flushed cleanly. A cancelled/failed run therefore
/// leaves the partial `.tmp` behind instead of clobbering the final name.
fn open_output(archive: &Path, chunk_bytes: Option<u64>) -> Result<(Box<dyn Write>, Option<PathBuf>)> {
    if archive.as_os_str() == "-" {
        if chunk_bytes.is_some() {
            return Err(anyhow!("-chunk cannot be combined with stdout (`-`)"));
        }
        return Ok((Box::new(std::io::stdout().lock()), None));
    }
    if let Some(b) = chunk_bytes {
        let chunk_size = b.max(1);
        return Ok((Box::new(ChunkedWriter::new(archive.to_path_buf(), chunk_size)?), None));
    }
    let mut tmp = archive.as_os_str().to_os_string();
    tmp.push(".tmp");
    let tmp_path = PathBuf::from(tmp);
    let f = File::create(&tmp_path)
        .with_context(|| format!("create {}", tmp_path.display()))?;
    Ok((Box::new(f), Some(tmp_path)))
}

/// Open the archive path for reading. Path "-" means stdin. If the plain path
/// is missing but `archive.001` exists, concatenate the parts transparently.
fn open_input(archive: &Path) -> Result<Box<dyn Read>> {
    if archive.as_os_str() == "-" {
        return Ok(Box::new(std::io::stdin().lock()));
    }
    if archive.exists() {
        return Ok(Box::new(
            File::open(archive).with_context(|| format!("open {}", archive.display()))?,
        ));
    }
    let first = part_path(archive, 1);
    if first.exists() {
        return Ok(Box::new(ChunkedReader::open(archive.to_path_buf())?));
    }
    Err(anyhow!("archive not found: {} (nor {})", archive.display(), first.display()))
}

fn is_stream_path(archive: &Path) -> bool {
    archive.as_os_str() == "-"
}

fn cmd_verify(archive: PathBuf, source: PathBuf, opts: Opts) -> Result<()> {
    let started = Instant::now();
    let source_abs = source
        .canonicalize()
        .with_context(|| format!("canonicalize {}", source.display()))?;
    let (mut dec, hash_algo, comment, has_xattrs, version) = open_archive(&archive)?;
    if let Some(c) = comment.as_deref() {
        if !opts.summary { eprintln!("comment {}", c); }
    }
    let mut buf = vec![0u8; CHUNK];
    let mut live = vec![0u8; CHUNK];
    let mut checked: u64 = 0;
    let mut mismatches: u64 = 0;
    let mut total_bytes: u64 = 0;
    let mut reg = fastcdc::DecodeRegistry::new();
    while let Some(header) = EntryHeader::read_from(&mut dec, version)? {
        if has_xattrs { let _ = archive::read_xattrs_block(&mut dec)?; }
        if opts.verbose {
            eprintln!("? {}", header.path);
        }
        if header.kind.is_file_like() {
            let live_path = source_abs.join(&header.path);
            let mut live_f = match File::open(&live_path) {
                Ok(f) => Some(BufReader::with_capacity(archive::IO_BUF, f)),
                Err(_) => {
                    eprintln!("{}", color::err_line(&format!("miss {}", header.path)));
                    mismatches += 1;
                    None
                }
            };
            total_bytes += header.size;
            let mut this_mismatch = false;
            let body_outcome = archive::read_file_body(&mut dec, &header, &mut reg, hash_algo, &mut buf, |bytes| {
                if let Some(lf) = live_f.as_mut() {
                    if lf.read_exact(&mut live[..bytes.len()]).is_err()
                        || live[..bytes.len()] != *bytes
                    {
                        this_mismatch = true;
                        live_f = None;
                    }
                }
                Ok(())
            })?;
            if matches!(body_outcome, archive::BodyOutcome::HashMismatch) {
                eprintln!(
                    "{}",
                    color::err_line(&format!(
                        "corrupt archive body for {} ({} mismatch)",
                        header.path,
                        hash_algo.map(|a| a.name()).unwrap_or("hash"),
                    ))
                );
                this_mismatch = true;
            }
            if let Some(mut lf) = live_f {
                let mut tail = [0u8; 1];
                if lf.read(&mut tail)? > 0 {
                    this_mismatch = true;
                }
            }
            if this_mismatch {
                eprintln!("{}", color::err_line(&format!("diff {}", header.path)));
                mismatches += 1;
            }
            checked += 1;
        } else {
            // Presence-only check for non-file entries. HardLink has no
            // body in the archive; the live-side file should still exist
            // (dedup is an archive-internal optimization).
            let live_path = source_abs.join(&header.path);
            if !live_path.exists() && live_path.symlink_metadata().is_err() {
                eprintln!("{}", color::err_line(&format!("miss {}", header.path)));
                mismatches += 1;
            }
        }
    }
    let elapsed = started.elapsed();
    if mismatches == 0 {
        eprintln!(
            "verify OK  {} files, {:.2} MiB matched  [{:.2}s]",
            checked,
            total_bytes as f64 / (1024.0 * 1024.0),
            elapsed.as_secs_f64()
        );
        Ok(())
    } else {
        eprintln!(
            "verify FAIL  {} mismatches out of {} files  [{:.2}s]",
            mismatches, checked, elapsed.as_secs_f64()
        );
        std::process::exit(2);
    }
}

fn cmd_dedupe(root: PathBuf, opts: Opts) -> Result<()> {
    use std::collections::HashMap;
    let started = Instant::now();
    let root_abs = root.canonicalize().with_context(|| format!("canonicalize {}", root.display()))?;
    // First pass: group candidates by size (so we only hash collisions)
    let mut by_size: HashMap<u64, Vec<PathBuf>> = HashMap::new();
    for entry in walkdir::WalkDir::new(&root_abs).follow_links(false) {
        let entry = entry?;
        let meta = entry.path().symlink_metadata()?;
        if !meta.is_file() || meta.len() == 0 {
            continue;
        }
        by_size.entry(meta.len()).or_default().push(entry.path().to_path_buf());
    }
    // Second pass: hash each size-collision group
    let mut groups: HashMap<(u64, u32), Vec<PathBuf>> = HashMap::new();
    let mut total_files: u64 = 0;
    for (size, paths) in &by_size {
        total_files += paths.len() as u64;
        if paths.len() < 2 {
            continue;
        }
        for p in paths {
            let mut h = crc32fast::Hasher::new();
            let mut f = BufReader::with_capacity(archive::IO_BUF, File::open(p)?);
            let mut buf = [0u8; CHUNK];
            loop {
                let n = f.read(&mut buf)?;
                if n == 0 { break; }
                h.update(&buf[..n]);
            }
            groups.entry((*size, h.finalize())).or_default().push(p.clone());
        }
    }
    let mut dup_groups: u64 = 0;
    let mut dup_files: u64 = 0;
    let mut wasted: u64 = 0;
    let mut sorted_keys: Vec<_> = groups.iter().filter(|(_, v)| v.len() >= 2).collect();
    sorted_keys.sort_by(|a, b| b.0.0.cmp(&a.0.0));
    for ((size, _crc), paths) in sorted_keys {
        let mut paths = paths.clone();
        paths.sort();
        dup_groups += 1;
        dup_files += paths.len() as u64 - 1;
        wasted += size * (paths.len() as u64 - 1);
        if opts.verbose {
            println!("dup  size={}  n={}", size, paths.len());
            for (i, p) in paths.iter().enumerate() {
                let tag = if i == 0 { "keep" } else { "dupe" };
                println!("  {}  {}", tag, p.display());
            }
        }
    }
    eprintln!(
        "scanned {} files, {} dup-groups, {} redundant files, {:.2} MiB wasted  [{:.2}s]",
        total_files, dup_groups, dup_files,
        wasted as f64 / (1024.0 * 1024.0),
        started.elapsed().as_secs_f64()
    );
    Ok(())
}

/// `syc scan <DIR>` — walk a directory and print a per-extension breakdown of
/// file count + total bytes, plus the high-level type categories (png / jpeg /
/// media / other) that the encoder uses to pick smart defaults.
///
/// Read-only, no archive involvement. Useful for sizing up a corpus before
/// running `syc a` so you can predict the work split (e.g. how many PNGs go
/// through Phase 3, how much "other" hits Zstd / LZMA).
fn cmd_scan(path: PathBuf, opts: Opts) -> Result<()> {
    use std::collections::HashMap;
    let started = Instant::now();
    let root = path
        .canonicalize()
        .with_context(|| format!("scan: cannot resolve {}", path.display()))?;
    let meta = std::fs::symlink_metadata(&root)
        .with_context(|| format!("scan: stat {}", root.display()))?;
    if !meta.is_dir() {
        return Err(anyhow!("scan: {} is not a directory", root.display()));
    }

    // (count, bytes) per extension (lowercase). Files with no extension live
    // under the empty string key; we render them as `(no ext)` later.
    let mut per_ext: HashMap<String, (u64, u64)> = HashMap::new();
    let mut n_files: u64 = 0;
    let mut n_dirs: u64 = 0;
    let mut n_symlinks: u64 = 0;
    let mut n_unreadable: u64 = 0;
    let mut total_bytes: u64 = 0;

    // Per ExtKind categories — same buckets pipeline::ExtKind uses, so the
    // output mirrors what the encoder will see at scan time.
    let mut cat_count: HashMap<pipeline::ExtKind, u64> = HashMap::new();
    let mut cat_bytes: HashMap<pipeline::ExtKind, u64> = HashMap::new();

    for entry in walkdir::WalkDir::new(&root).follow_links(false) {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => {
                n_unreadable += 1;
                continue;
            }
        };
        let p = entry.path();
        let m = match p.symlink_metadata() {
            Ok(m) => m,
            Err(_) => {
                n_unreadable += 1;
                continue;
            }
        };
        if m.is_dir() {
            n_dirs += 1;
            continue;
        }
        if m.file_type().is_symlink() {
            n_symlinks += 1;
            continue;
        }
        if !m.is_file() {
            continue;
        }
        n_files += 1;
        let size = m.len();
        total_bytes = total_bytes.saturating_add(size);

        let ext = p
            .extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();
        let row = per_ext.entry(ext).or_insert((0, 0));
        row.0 += 1;
        row.1 = row.1.saturating_add(size);

        let kind = pipeline::ExtKind::classify(p);
        *cat_count.entry(kind).or_insert(0) += 1;
        *cat_bytes.entry(kind).or_insert(0) =
            cat_bytes.get(&kind).copied().unwrap_or(0).saturating_add(size);
    }

    let elapsed = started.elapsed();

    if opts.summary {
        println!(
            "{} files, {} dirs, {} ({})  in {:.2}s",
            eu_num(n_files),
            eu_num(n_dirs),
            eu_num(total_bytes),
            human_si(total_bytes),
            elapsed.as_secs_f64(),
        );
        return Ok(());
    }

    eprintln!();
    eprintln!("scan {}", root.display());
    eprintln!();
    eprintln!(
        "{} files, {} dirs, {} symlinks, {} ({})",
        eu_num(n_files),
        eu_num(n_dirs),
        eu_num(n_symlinks),
        eu_num(total_bytes),
        human_si(total_bytes),
    );
    if n_unreadable > 0 {
        eprintln!("{} unreadable entries skipped", eu_num(n_unreadable));
    }
    eprintln!();

    // Per-extension table, sorted by bytes descending.
    let mut rows: Vec<(String, u64, u64)> = per_ext
        .into_iter()
        .map(|(k, (c, b))| (k, c, b))
        .collect();
    rows.sort_by(|a, b| b.2.cmp(&a.2));

    let label_w = rows
        .iter()
        .map(|(k, _, _)| if k.is_empty() { "(no ext)".len() } else { k.len() })
        .max()
        .unwrap_or(8)
        .max(8);
    let count_w = rows
        .iter()
        .map(|(_, c, _)| eu_num(*c).len())
        .max()
        .unwrap_or(5)
        .max(5);

    eprintln!(
        "{:label_w$}  {:>count_w$}    {:>10}    {:>5}",
        "ext",
        "files",
        "size",
        "share",
        label_w = label_w,
        count_w = count_w,
    );
    eprintln!(
        "{:-<label_w$}  {:->count_w$}    {:->10}    {:->5}",
        "",
        "",
        "",
        "",
        label_w = label_w,
        count_w = count_w,
    );
    for (ext, count, bytes) in &rows {
        let label = if ext.is_empty() { "(no ext)".to_string() } else { ext.clone() };
        let share = if total_bytes == 0 {
            0.0
        } else {
            (*bytes as f64 / total_bytes as f64) * 100.0
        };
        eprintln!(
            "{:label_w$}  {:>count_w$}    {:>10}    {:>4.1}%",
            label,
            eu_num(*count),
            human_si(*bytes),
            share,
            label_w = label_w,
            count_w = count_w,
        );
    }

    eprintln!();
    eprintln!("category    files     size     share");
    eprintln!("--------  -------  -------    -----");
    for kind in [
        pipeline::ExtKind::Png,
        pipeline::ExtKind::Jpeg,
        pipeline::ExtKind::Media,
        pipeline::ExtKind::Other,
    ] {
        let count = cat_count.get(&kind).copied().unwrap_or(0);
        let bytes = cat_bytes.get(&kind).copied().unwrap_or(0);
        let share = if total_bytes == 0 {
            0.0
        } else {
            (bytes as f64 / total_bytes as f64) * 100.0
        };
        let label = match kind {
            pipeline::ExtKind::Png => "png",
            pipeline::ExtKind::Jpeg => "jpeg",
            pipeline::ExtKind::Media => "media",
            pipeline::ExtKind::Other => "other",
        };
        eprintln!(
            "{:<8}  {:>7}  {:>7}    {:>4.1}%",
            label,
            eu_num(count),
            human_si(bytes),
            share,
        );
    }

    eprintln!();
    end_footer(elapsed, total_bytes);
    Ok(())
}

fn cmd_add(archive: PathBuf, sources: Vec<PathBuf>, mut opts: Opts) -> Result<()> {
    let started = Instant::now();

    if !(0..=10).contains(&opts.level) {
        return Err(anyhow!("level must be 0..=10 (got {})", opts.level));
    }

    // Optional FS snapshot: take once per source directory, keep the guards
    // alive until this function returns so cleanup runs after archival.
    let mut _snap_guards: Vec<snapshot::SnapshotGuard> = Vec::new();
    let effective_sources: Vec<PathBuf> = if opts.snapshot {
        let mut v = Vec::with_capacity(sources.len());
        for src in &sources {
            let g = snapshot::take_snapshot(src)?;
            v.push(g.effective_src.clone());
            _snap_guards.push(g);
        }
        v
    } else {
        sources.clone()
    };

    // ─── v0.1.20 Phase 1: scan ─────────────────────────────────────────────
    // Collect + filter + sort + build Plan. No file contents read here, only
    // metadata (stat). Keep the scan time separate from pack time so the
    // user can see where wall-clock is being spent. The `Scanned N file/s`
    // line mirrors zpaqfranz's pre-pack summary; the Plan drives smart
    // defaults (auto -ppg) and is consumed by Phases 2-4 downstream.
    let scan_started = Instant::now();
    let mut all: Vec<(PathBuf, PathBuf)> = Vec::new();
    for src in &effective_sources {
        all.extend(collect_entries_or_single(src)?);
    }
    if let Some(fl) = opts.filelist.as_deref() {
        for src in load_filelist(fl)? {
            all.extend(collect_entries_or_single(&src)?);
        }
    }
    let before = all.len();
    apply_selectors(&mut all, &opts);
    let skipped = before - all.len();
    if skipped > 0 && !opts.summary {
        eprintln!("filter  {} entries skipped (exclude/minsize/maxsize)", skipped);
    }
    if !opts.nosort {
        solid_sort(&mut all);
    }
    // v0.1.20 Phase 1 — explicit Plan from the scan output. Replaces the
    // ad-hoc scan_bytes loop. Same I/O cost (one symlink_metadata per entry)
    // but preserves the result for smart defaults + later phases instead of
    // throwing it away.
    let plan = pipeline::Plan::from_entries(&all);
    if !opts.summary {
        eprintln!(
            "Scanned {} file/s  {}  {} ({}){}",
            eu_num(all.len() as u64),
            hms(scan_started.elapsed().as_secs()),
            eu_num(plan.total_bytes),
            human_si(plan.total_bytes),
            plan.summary_line(),
        );
    }

    // v0.1.20 Phase 1 smart default — auto-enable -ppg when PNG dominates the
    // corpus. Three flag states: -ppg explicit ON, -noppg explicit OFF, neither.
    // Only the third state lets the Plan decide. Threshold 50 % of total
    // bytes: matches the heuristic used by the existing -route auto-gate
    // (route auto-on when media >= 20 %; ppg auto-on when png >= 50 % is more
    // conservative because packPNG is slower than packJPG).
    // v0.1.21: format-specific compression is always-on by default for ALL
    // -m levels — pjg for JPEGs (already unconditional in the pack loop) and
    // ppg for PNGs. The previous 50 %-of-bytes threshold gated ppg too
    // conservatively (a 1.74 GB corpus with 32 % PNG ≈ 600 MB of un-packPNG'd
    // PNG never triggered). User opt-out via `-noppg`. Explicit `-ppg` is
    // now redundant but kept as a no-op for script compatibility.
    if !opts.noppg {
        opts.ppg = true;
    }

    if opts.append {
        return cmd_add_append(archive, all, opts, started);
    }

    let backend = pick_backend(opts.level, opts.store);

    // Partition up-front so dict samples, total_raw, preproc decisions, and
    // BCJ auto-detect all key off the compressible bucket only. Media files
    // don't belong in those stats anyway (they won't compress and their
    // headers are already compressed payloads).
    let (mut default_entries, mut media_entries): (Vec<(PathBuf, PathBuf)>, Vec<(PathBuf, PathBuf)>) =
        if opts.route {
            all.into_iter().partition(|(_, rel)| !is_media_ext(rel))
        } else {
            (all, Vec::new())
        };

    // Auto-gate: -route only pays off when media is a meaningful share of
    // bytes. On mixed source trees (lots of small PNGs/icons), splitting
    // adds frame overhead and drops solid-mode dedup context, measured
    // +1.2 % ratio with no CPU savings. Threshold 20 % of total bytes.
    const ROUTE_MIN_SHARE: f64 = 0.20;
    if opts.route {
        let sum_bytes = |v: &[(PathBuf, PathBuf)]| -> u64 {
            v.iter()
                .filter_map(|(full, _)| std::fs::symlink_metadata(full).ok())
                .filter(|m| m.is_file())
                .map(|m| m.len())
                .sum()
        };
        let default_b = sum_bytes(&default_entries);
        let media_b = sum_bytes(&media_entries);
        let total = default_b + media_b;
        let share = if total > 0 { media_b as f64 / total as f64 } else { 0.0 };
        if share < ROUTE_MIN_SHARE {
            if !opts.summary {
                eprintln!(
                    "route   auto-off: media is {:.1}% of bytes (<{:.0}% threshold)",
                    share * 100.0,
                    ROUTE_MIN_SHARE * 100.0
                );
            }
            default_entries.extend(media_entries.drain(..));
            opts.route = false;
        }
    }

    // ─── v0.1.20 Phase 2: dedup ────────────────────────────────────────────
    // Build dedup maps per-bucket so HardLink entries always point at a
    // canonical within the same frame (canonical must be extracted before any
    // of its references). Runs BEFORE Phase 3 — duplicate files don't trigger
    // redundant packJPG/packPNG calls; their entries become HardLinks in the
    // pack loop and the FFI cost is paid only for the canonical instance.
    let dedup_default = if opts.dedup {
        build_dedup_map(&default_entries)?
    } else {
        std::collections::HashMap::new()
    };
    let dedup_media = if opts.dedup && !media_entries.is_empty() {
        build_dedup_map(&media_entries)?
    } else {
        std::collections::HashMap::new()
    };
    if opts.dedup && !opts.summary {
        let n_default = dedup_default.len();
        let n_media = dedup_media.len();
        if n_default + n_media > 0 {
            eprintln!(
                "dedup   {} duplicates → hardlink entries ({} default, {} media)",
                n_default + n_media, n_default, n_media
            );
        } else {
            eprintln!("dedup   no duplicate contents found");
        }
    }

    let total_raw: u64 = default_entries
        .iter()
        .filter_map(|(full, _)| std::fs::symlink_metadata(full).ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum();

    // Auto-MT: when the user didn't pass -t, scale threads with the input.
    // Single-threaded zstd at L1 caps near 600 MB/s on a fast core; with
    // multithread() the encoder splits the stream into independent blocks and
    // runs them in parallel. LZMA's MT path has its own ratio-vs-cores gate
    // (build_lzma_stream), so it's safe to forward the same auto value.
    // Threshold at 256 MiB: smaller inputs barely benefit because spawn +
    // block setup eats the win, and ratio cost on tiny data shows up more.
    if opts.threads == 0 && total_raw >= 256 * 1024 * 1024 {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get() as u32)
            .unwrap_or(1);
        // v0.1.23: dropped the previous .min(8) cap. The cap was for Zstd MT
        // sub-linear scaling, but with Phase 3 (parallel pjg/ppg) introduced
        // in v0.1.20 the same opts.threads now governs per-file FFI workers
        // — and packJPG/packPNG calls scale linearly with cores. Capping at
        // 8 made syc roughly 2× slower than packPNG standalone on 16-HT
        // boxes. The backend's diminishing returns past 8 are still cheaper
        // than under-utilising Phase 3.
        opts.threads = cores.max(1);
        if !opts.summary && opts.threads > 1 {
            eprintln!("threads {} (auto: -t not set, input {})",
                opts.threads, human_si(total_raw));
        }
    }

    // Progress bar total: actual bytes pack_all will feed to the compressor,
    // so hardlink-dedup'd entries and media-bucket files are both included
    // but dedup skipped bytes are subtracted.
    let progress_total: u64 = packable_bytes(&default_entries, &dedup_default)
        + packable_bytes(&media_entries, &dedup_media);
    let progress_enabled = !opts.noprogress && progress::stderr_is_tty() && !opts.summary;
    let mut prog = progress::Progress::new("pack", progress_total, progress_enabled);

    // Dict is opt-in via `-dict` (we don't auto-enable). In solid mode the
    // zstd stream already sees all shared templates inline, so a precomputed
    // dict is redundant at best and net-negative at worst (measured: +5..10 %
    // output on /usr/include at L1 and L4, both slower). Keep the flag for
    // experimentation and for future non-solid modes. Size adapts to corpus:
    // a 110 KiB dict is dead weight on a 4 MiB archive.
    let want_dict = backend == Backend::Zstd && !opts.store && !opts.nodict && opts.dict;
    let dict: Vec<u8> = if want_dict {
        let samples = gather_samples(&default_entries)?;
        let target = archive::adaptive_dict_target(total_raw);
        let d = train_dict(&samples, target);
        if !d.is_empty() && !opts.summary {
            eprintln!("dict    {} KiB trained from {} samples (target {})",
                d.len() / 1024, samples.len(), target);
        }
        d
    } else {
        Vec::new()
    };

    let is_stream = is_stream_path(&archive);
    let is_chunked = opts.chunk_bytes.is_some() && !is_stream;
    if let (Some(b), false) = (opts.chunk_bytes, opts.summary) {
        if !is_stream {
            eprintln!("chunk   {}  (output split into {}.001, .002, ...)",
                human_si(b), archive.display());
        }
    }
    let (out, tmp_path) = open_output(&archive, opts.chunk_bytes)?;
    // When tmp_path is Some we're writing to `<archive>.tmp`; rename to the
    // final name only after the encoder chain and the optional route-frame
    // append have flushed. Route-append also targets tmp_path.
    let comp_counter = Arc::new(AtomicU64::new(0));
    prog.set_compressed_counter(Arc::clone(&comp_counter));
    let bw_inner = BufWriter::with_capacity(archive::IO_BUF, out);
    let mut bw = CountingWriter::new(bw_inner, Arc::clone(&comp_counter));
    // Pick preprocessor based on size:
    //   <128 MiB  → none (LZMA's 128 MiB dict already covers it)
    //   128 MiB..512 MiB → REP (catches shorter repeats too, hash still sparse)
    //   >512 MiB  → SREP (block-sampled, scales to multi-GB without saturating)
    // REP/SREP only pay off when long repeats live beyond LZMA's 128 MiB
    // dict. Measurements on test-files.tar subsets (2026-04-15):
    //   200 MiB — REP adds ~0.1% to ratio and 35% to time (net loss)
    //   2.3 GiB — SREP saves 0.5% (net win)
    // So default to no preproc unless the input is clearly beyond reach of
    // LZMA's dict.
    let preproc_eligible = matches!(backend, Backend::Lzma | Backend::Ppmd);
    let mut preproc: u8 = if opts.nopreproc || !preproc_eligible {
        0
    } else if total_raw > 1024 * 1024 * 1024 {
        PREPROC_SREP
    } else {
        0
    };
    // Per-file hash is default-on (crc32); -nochecksum disables it, -hash
    // picks xxh3/blake3 (or crc32 explicitly).
    let hash_algo: Option<HashAlgo> = if opts.nochecksum {
        None
    } else {
        Some(parse_hash_algo(opts.hash.as_deref())?)
    };
    if hash_algo.is_some() {
        preproc |= archive::FEATURE_CRC32;
        if !matches!(hash_algo, Some(HashAlgo::Crc32)) {
            preproc |= archive::FEATURE_HASH_ALGO;
        }
    }
    if opts.comment.is_some() {
        preproc |= archive::FEATURE_COMMENT;
    }
    if opts.xattrs {
        preproc |= archive::FEATURE_XATTRS;
    }
    if let Some(stride) = opts.delta {
        if backend == Backend::Ppmd {
            return Err(anyhow!("-delta is not supported with the PPMd backend"));
        }
        if preproc & (PREPROC_REP | PREPROC_SREP) != 0 {
            return Err(anyhow!(
                "-delta cannot combine with REP/SREP (pass -nopreproc or drop -delta)"
            ));
        }
        preproc |= archive::FEATURE_DELTA;
        if !opts.summary {
            eprintln!("delta   stride {}  (pre-filter before compressor)", stride);
        }
    }
    if opts.fastcdc {
        if opts.append {
            return Err(anyhow!(
                "-fastcdc not supported with -append (chunk registry is per-frame)"
            ));
        }
        if opts.delta.is_some() {
            return Err(anyhow!("-fastcdc not supported with -delta"));
        }
        if !opts.summary {
            eprintln!(
                "fastcdc min {} avg {} max {}  (content-defined chunk-level dedup)",
                fastcdc::MIN_SIZE, fastcdc::AVG_SIZE, fastcdc::MAX_SIZE
            );
        }
    }
    if opts.lzp {
        if !preproc_eligible {
            return Err(anyhow!("-lzp needs -m 5+ (LZMA) or SYC_BACKEND=ppmd"));
        }
        if preproc & (PREPROC_REP | PREPROC_SREP) != 0 {
            return Err(anyhow!(
                "-lzp cannot combine with REP/SREP (pass -nopreproc or drop -lzp)"
            ));
        }
        if opts.delta.is_some() {
            return Err(anyhow!("-lzp cannot combine with -delta"));
        }
        preproc |= PREPROC_LZP;
        if !opts.summary {
            eprintln!("lzp     ctx {}  min-match {}  (context-hash predictor)", lzp::CTX, lzp::MIN_MATCH);
        }
    }
    if opts.route {
        if matches!(backend, Backend::Ppmd) {
            return Err(anyhow!("-route not supported with PPMd backend"));
        }
        if preproc & (PREPROC_REP | PREPROC_SREP) != 0 {
            return Err(anyhow!("-route not compatible with REP/SREP preprocessor"));
        }
        if preproc & PREPROC_LZP != 0 {
            return Err(anyhow!("-route not compatible with -lzp"));
        }
        if opts.delta.is_some() {
            return Err(anyhow!("-route not compatible with -delta"));
        }
        if is_stream_path(&archive) {
            return Err(anyhow!("-route cannot be used with stdout (`-`)"));
        }
        if opts.chunk_bytes.is_some() {
            return Err(anyhow!("-route not compatible with -chunk"));
        }
    }
    let ppmd_params = if backend == Backend::Ppmd {
        Some(pick_ppmd_params(opts.level))
    } else {
        None
    };
    let scan_summary = plan.to_scan_summary();
    write_preamble(
        &mut bw, backend, preproc, &dict, ppmd_params,
        opts.comment.as_deref(), hash_algo, opts.delta, &scan_summary,
    )?;

    let mut total_bytes: u64 = 0;
    let mut n_entries: u64 = 0;
    let mut n_pjg: u64 = 0;
    let mut n_ppg: u64 = 0;

    match backend {
        Backend::Zstd => {
            let zlevel = if opts.store { 0 } else { map_zstd_level(opts.level) };
            let mut enc = if dict.is_empty() {
                zstd::stream::Encoder::new(bw, zlevel)?
            } else {
                zstd::stream::Encoder::with_dictionary(bw, zlevel, &dict)?
            };
            if opts.threads > 0 {
                let _ = enc.multithread(opts.threads);
            }
            let _ = enc.include_checksum(true);
            if !opts.nolong {
                let _ = enc.window_log(28);
                let _ = enc.long_distance_matching(true);
            }
            if opts.level >= 4 && !opts.store {
                use zstd::zstd_safe::CParameter;
                let _ = enc.set_parameter(CParameter::Strategy(zstd::zstd_safe::Strategy::ZSTD_btultra2));
                let _ = enc.set_parameter(CParameter::ChainLog(28));
                let _ = enc.set_parameter(CParameter::HashLog(27));
                let _ = enc.set_parameter(CParameter::SearchLog(10));
                let _ = enc.set_parameter(CParameter::TargetLength(999));
            }
            if let Some(stride) = opts.delta {
                let mut dw = delta::DeltaWriter::new(enc, stride);
                pack_all(&mut dw, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let enc = dw.finish()?;
                let counted = enc.finish()?;
                let bw_inner = counted.into_inner();
                let mut inner = bw_inner.into_inner().map_err(|e| anyhow!("flush: {e}"))?;
                inner.flush()?;
            } else {
                pack_all(&mut enc, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let counted = enc.finish()?;
                let bw_inner = counted.into_inner();
                let mut inner = bw_inner.into_inner().map_err(|e| anyhow!("flush: {e}"))?;
                inner.flush()?;
            }
        }
        Backend::Lzma => {
            // BCJ selection order: -bcj CLI flag → SYC_BCJ env → auto-detect.
            // Worth ~3–4% on x86 binary tarballs, neutral on text.
            let bcj = if let Some(s) = opts.bcj.as_deref() {
                parse_bcj(s.trim())
                    .ok_or_else(|| anyhow!("-bcj: unknown filter '{s}' (x86|arm|armt|ia64|sparc|ppc|off)"))?
            } else {
                match std::env::var("SYC_BCJ") {
                    Ok(v) => parse_bcj(v.trim())
                        .ok_or_else(|| anyhow!("SYC_BCJ: unknown filter '{v}' (x86|arm|armt|ia64|sparc|ppc|off)"))?,
                    Err(_) => auto_detect_bcj(&default_entries),
                }
            };
            if bcj != Bcj::None && !opts.summary {
                eprintln!("bcj     {:?}  (auto)", bcj);
            }
            let stream = build_lzma_stream(opts.level, opts.threads, total_raw, bcj)?;
            let enc = xz2::write::XzEncoder::new_stream(bw, stream);
            if let Some(stride) = opts.delta {
                let mut dw = delta::DeltaWriter::new(enc, stride);
                pack_all(&mut dw, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let enc = dw.finish()?;
                let mut inner = enc.finish()?;
                inner.flush()?;
            } else if preproc & PREPROC_SREP != 0 {
                let mut pp = srep::SrepWriter::new(enc);
                pack_all(&mut pp, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let enc = pp.finish()?;
                let mut inner = enc.finish()?;
                inner.flush()?;
            } else if preproc & PREPROC_REP != 0 {
                let mut rep = rep::RepWriter::new(enc);
                pack_all(&mut rep, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let enc = rep.finish()?;
                let mut inner = enc.finish()?;
                inner.flush()?;
            } else if preproc & PREPROC_LZP != 0 {
                let mut lz = lzp::LzpWriter::new(enc);
                pack_all(&mut lz, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let enc = lz.finish()?;
                let mut inner = enc.finish()?;
                inner.flush()?;
            } else {
                let mut enc = enc;
                pack_all(&mut enc, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let mut inner = enc.finish()?;
                inner.flush()?;
            }
        }
        Backend::Ppmd => {
            let p = ppmd_params.expect("ppmd params");
            let mem_bytes = (p.mem_mb as u32).saturating_mul(1024 * 1024);
            let enc = Ppmd7Encoder::new(bw, p.order as u32, mem_bytes)
                .map_err(|e| anyhow!("ppmd init: {e}"))?;
            if preproc & PREPROC_SREP != 0 {
                let mut pp = srep::SrepWriter::new(enc);
                pack_all(&mut pp, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let enc = pp.finish()?;
                let mut inner = enc.finish(true)?;
                inner.flush()?;
            } else if preproc & PREPROC_REP != 0 {
                let mut rep = rep::RepWriter::new(enc);
                pack_all(&mut rep, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let enc = rep.finish()?;
                let mut inner = enc.finish(true)?;
                inner.flush()?;
            } else if preproc & PREPROC_LZP != 0 {
                let mut lz = lzp::LzpWriter::new(enc);
                pack_all(&mut lz, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let enc = lz.finish()?;
                let mut inner = enc.finish(true)?;
                inner.flush()?;
            } else {
                let mut enc = enc;
                pack_all(&mut enc, &default_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_default,&mut prog)?;
                let mut inner = enc.finish(true)?;
                inner.flush()?;
            }
        }
    }

    // Second frame for the media bucket at level 0. Same backend + same dict
    // (if any), so the top-level decoder handles it as just another frame.
    // Wrapping checks already rejected ppmd, REP/SREP, delta, stdout, chunk.
    if opts.route && !media_entries.is_empty() {
        let route_target: &Path = tmp_path.as_deref().unwrap_or(&archive);
        let append_file = OpenOptions::new()
            .append(true)
            .open(route_target)
            .with_context(|| format!("open for route-append {}", route_target.display()))?;
        // Share the same counter so the second-frame bytes also feed the
        // progress projection. CountingWriter sits *above* BufWriter to count
        // encoder output as soon as it's produced (LZMA-MT batches output;
        // counting at disk-level would lag for many seconds).
        let bw2_inner = BufWriter::with_capacity(archive::IO_BUF, append_file);
        let bw2 = CountingWriter::new(bw2_inner, Arc::clone(&comp_counter));
        match backend {
            Backend::Zstd => {
                let mut enc = if dict.is_empty() {
                    zstd::stream::Encoder::new(bw2, 0)?
                } else {
                    zstd::stream::Encoder::with_dictionary(bw2, 0, &dict)?
                };
                if opts.threads > 0 {
                    let _ = enc.multithread(opts.threads);
                }
                let _ = enc.include_checksum(true);
                pack_all(&mut enc, &media_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_media,&mut prog)?;
                let counted2 = enc.finish()?;
                let bw2 = counted2.into_inner();
                let mut inner = bw2.into_inner().map_err(|e| anyhow!("flush: {e}"))?;
                inner.flush()?;
            }
            Backend::Lzma => {
                let stream = build_lzma_stream(0, opts.threads, 0, Bcj::None)?;
                let mut enc = xz2::write::XzEncoder::new_stream(bw2, stream);
                pack_all(&mut enc, &media_entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup_media,&mut prog)?;
                let mut inner = enc.finish()?;
                inner.flush()?;
            }
            Backend::Ppmd => unreachable!(),
        }
        if !opts.summary {
            eprintln!(
                "route   {} default + {} media (level-0 frame)",
                default_entries.len(),
                media_entries.len()
            );
        }
    }

    prog.finish();

    // Atomic commit: promote the .tmp file to its final name only now, after
    // every frame has flushed. On cancel/failure the .tmp stays so the user
    // can inspect or delete it; the final path is never half-written.
    if let Some(tp) = tmp_path.as_deref() {
        std::fs::rename(tp, &archive)
            .with_context(|| format!("rename {} -> {}", tp.display(), archive.display()))?;
    }

    let out_size = if is_stream {
        0
    } else if is_chunked {
        let mut total = 0u64;
        let mut n = 1u32;
        loop {
            let p = part_path(&archive, n);
            match std::fs::metadata(&p) {
                Ok(m) => { total += m.len(); n += 1; }
                Err(_) => break,
            }
        }
        total
    } else {
        std::fs::metadata(&archive)?.len()
    };
    let elapsed = started.elapsed();
    let ratio = if total_bytes > 0 {
        out_size as f64 / total_bytes as f64
    } else {
        0.0
    };
    let mbps = if elapsed.as_secs_f64() > 0.0 {
        (total_bytes as f64 / (1024.0 * 1024.0)) / elapsed.as_secs_f64()
    } else {
        0.0
    };
    let backend_name = match backend {
        Backend::Zstd => "zstd",
        Backend::Lzma => "lzma",
        Backend::Ppmd => "ppmd",
    };
    let n_files = n_entries;
    let n_dirs = default_entries.iter().chain(media_entries.iter())
        .filter(|(full, _)| std::fs::symlink_metadata(full).map(|m| m.is_dir()).unwrap_or(false))
        .count();
    if opts.summary {
        eprintln!(
            "{} entries {} -> {} (ratio {:.3}) {:.2}s {:.1} MB/s [{}]",
            n_entries,
            human_si(total_bytes),
            if is_stream { "stream".to_string() } else { human_si(out_size) },
            ratio,
            elapsed.as_secs_f64(),
            mbps,
            backend_name,
        );
    } else {
        let out_disp = if is_stream {
            "stream".to_string()
        } else {
            format!("{} ({})", eu_num(out_size), human_si(out_size))
        };
        let now = chrono_like_now();
        eprintln!(
            "Creating {} at offset 0 + 0",
            if is_stream { "<stdout>".to_string() } else { archive.display().to_string() }
        );
        eprintln!(
            "Add {}         {:>3}         {:>11} ({:>7}) {}T ({} dirs)",
            now,
            n_files,
            eu_num(total_bytes),
            human_si(total_bytes),
            opts.threads.max(1),
            n_dirs,
        );
        eprintln!("{} +added, 0 -removed.", n_files);
        eprintln!(
            "0 + ({} -> {} -> {}) = {}  @ {:.2} MB/s",
            eu_num(total_bytes),
            eu_num(total_bytes),
            eu_num(out_size),
            out_disp,
            mbps,
        );
        eprintln!("Files added +{}", n_files);
        // Tag the ratio green if it compressed well (<0.80), yellow if the
        // data resisted compression (>=0.95). Mirrors zpaqfranz's list color
        // signal for "this file didn't compress".
        let ratio_s = format!("{:.3}", ratio);
        let ratio_col = if ratio >= 0.95 {
            color::y(&ratio_s)
        } else if ratio < 0.80 {
            color::g(&ratio_s)
        } else {
            ratio_s
        };
        let pjg_tag = if n_pjg > 0 {
            format!("  pjg:{}", n_pjg)
        } else {
            String::new()
        };
        let ppg_tag = if n_ppg > 0 {
            format!("  ppg:{}", n_ppg)
        } else {
            String::new()
        };
        eprintln!(
            "syc-l{}  backend {}  threads {}  ratio {}{}{}",
            opts.level, backend_name, opts.threads, ratio_col, pjg_tag, ppg_tag,
        );
    }
    end_footer(elapsed, total_bytes);
    Ok(())
}

/// `YYYY-MM-DD HH:MM:SS` UTC from UNIX seconds. No deps; pre-1970 (negative)
/// values collapse to epoch since they never occur in practice on syc inputs.
fn fmt_mtime(unix_secs: i64) -> String {
    let t = if unix_secs < 0 { 0u64 } else { unix_secs as u64 };
    let days = t / 86400;
    let secs = t % 86400;
    let h = secs / 3600;
    let m = (secs / 60) % 60;
    let s = secs % 60;
    let (y, mo, d) = days_to_ymd(days);
    format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02}", y, mo, d, h, m, s)
}

fn chrono_like_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    fmt_mtime(t)
}

/// Gregorian conversion from days-since-1970 — enough for a cosmetic date
/// stamp, matches zpaqfranz's `Add YYYY-MM-DD HH:MM:SS` header column.
fn days_to_ymd(mut days: u64) -> (u64, u64, u64) {
    let mut y: u64 = 1970;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let ydays = if leap { 366 } else { 365 };
        if days < ydays { break; }
        days -= ydays;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let ml = [31, if leap {29} else {28}, 31,30,31,30,31,31,30,31,30,31];
    let mut m = 0;
    while m < 12 && days >= ml[m] { days -= ml[m]; m += 1; }
    (y, m as u64 + 1, days + 1)
}

/// Append a fresh compressed frame at the end of an existing archive.
///
/// The original preamble (and thus archive-level config: backend, dict, hash
/// algo, xattr bit, comment) is preserved byte-for-byte — antiransomware
/// guarantee. Per-level/-threads flags apply only to the NEW frame. Decoders
/// for zstd and xz handle multi-frame streams natively; we flipped the xz
/// decoder to `new_multi_decoder` so list/extract/test see every frame.
fn cmd_add_append(
    archive: PathBuf,
    entries: Vec<(PathBuf, PathBuf)>,
    mut opts: Opts,
    started: Instant,
) -> Result<()> {
    if is_stream_path(&archive) {
        return Err(anyhow!("-append cannot be used with stdout (`-`)"));
    }
    if opts.chunk_bytes.is_some() {
        return Err(anyhow!("-append is not compatible with -chunk"));
    }
    if !archive.exists() {
        return Err(anyhow!(
            "-append: archive does not exist: {} (omit -append to create a new one)",
            archive.display()
        ));
    }

    let rd = File::open(&archive)
        .with_context(|| format!("open {}", archive.display()))?;
    let size_before = rd.metadata()?.len();
    let mut br = BufReader::with_capacity(archive::IO_BUF, rd);
    let (_version, backend, preproc, dict, ppmd_params, existing_comment, hash_algo, delta_stride, _scan_summary) =
        read_preamble(&mut br)?;
    drop(br);

    if matches!(backend, Backend::Ppmd) {
        let _ = ppmd_params; // keep variable bound
        return Err(anyhow!(
            "-append: ppmd backend does not support multi-frame streams"
        ));
    }
    if preproc & (PREPROC_REP | PREPROC_SREP) != 0 {
        return Err(anyhow!(
            "-append: archive uses REP/SREP preprocessor; per-frame match \
             state would diverge. Repack without REP/SREP first."
        ));
    }
    if preproc & PREPROC_LZP != 0 {
        return Err(anyhow!(
            "-append: archive uses LZP preprocessor; per-frame predictor \
             state would diverge. Repack without -lzp first."
        ));
    }
    if delta_stride.is_some() {
        return Err(anyhow!(
            "-append: archive uses delta pre-filter; ring-buffer state would \
             diverge across frames. Repack without -delta first."
        ));
    }

    // Flags that are locked by the existing preamble win over anything passed
    // on the CLI. Warn so the user isn't surprised.
    let archive_xattrs = preproc & archive::FEATURE_XATTRS != 0;
    if opts.xattrs && !archive_xattrs {
        eprintln!("{}", color::warn_line("-xattrs ignored (archive was created without FEATURE_XATTRS)"));
    } else if !opts.xattrs && archive_xattrs && !opts.summary {
        eprintln!("{}", color::warn_line("archive has FEATURE_XATTRS, appended entries will include xattrs too"));
    }
    opts.xattrs = archive_xattrs;

    if opts.hash.is_some() && !opts.summary {
        eprintln!(
            "{}",
            color::warn_line(&format!(
                "-hash ignored (archive locks hash algo to {})",
                hash_algo.map(|h| h.name()).unwrap_or("none")
            ))
        );
    }
    if opts.comment.is_some() && !opts.summary {
        eprintln!("{}", color::warn_line("-comment ignored (archive preamble is preserved)"));
    }
    let _ = existing_comment;

    let file = OpenOptions::new()
        .append(true)
        .open(&archive)
        .with_context(|| format!("open for append {}", archive.display()))?;
    let comp_counter = Arc::new(AtomicU64::new(0));
    let bw_inner = BufWriter::with_capacity(archive::IO_BUF, file);
    let bw = CountingWriter::new(bw_inner, Arc::clone(&comp_counter));

    // Dedup applies within the appended frame only — we don't scan the existing
    // frame(s) so an appended file that matches an old one still gets re-packed.
    // That keeps -append non-destructive and stream-only.
    let dedup = if opts.dedup {
        build_dedup_map(&entries)?
    } else {
        std::collections::HashMap::new()
    };
    if opts.dedup && !opts.summary && !dedup.is_empty() {
        eprintln!("dedup   {} duplicates in appended batch", dedup.len());
    }

    let mut total_bytes: u64 = 0;
    let mut n_entries: u64 = 0;
    let mut n_pjg: u64 = 0;
    let mut n_ppg: u64 = 0;
    let progress_total = packable_bytes(&entries, &dedup);
    let progress_enabled = !opts.noprogress && progress::stderr_is_tty() && !opts.summary;
    let mut prog = progress::Progress::new("pack", progress_total, progress_enabled);
    prog.set_compressed_counter(Arc::clone(&comp_counter));

    match backend {
        Backend::Zstd => {
            let zlevel = if opts.store { 0 } else { map_zstd_level(opts.level) };
            let mut enc = if dict.is_empty() {
                zstd::stream::Encoder::new(bw, zlevel)?
            } else {
                zstd::stream::Encoder::with_dictionary(bw, zlevel, &dict)?
            };
            if opts.threads > 0 {
                let _ = enc.multithread(opts.threads);
            }
            let _ = enc.include_checksum(true);
            if !opts.nolong {
                let _ = enc.window_log(28);
                let _ = enc.long_distance_matching(true);
            }
            pack_all(&mut enc, &entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup,&mut prog)?;
            let counted = enc.finish()?;
            let bw = counted.into_inner();
            let mut inner = bw.into_inner().map_err(|e| anyhow!("flush: {e}"))?;
            inner.flush()?;
        }
        Backend::Lzma => {
            let bcj = if let Some(s) = opts.bcj.as_deref() {
                parse_bcj(s.trim())
                    .ok_or_else(|| anyhow!("-bcj: unknown filter '{s}'"))?
            } else {
                match std::env::var("SYC_BCJ") {
                    Ok(v) => parse_bcj(v.trim())
                        .ok_or_else(|| anyhow!("SYC_BCJ: unknown filter '{v}'"))?,
                    Err(_) => auto_detect_bcj(&entries),
                }
            };
            let stream = build_lzma_stream(opts.level, opts.threads, 0, bcj)?;
            let mut enc = xz2::write::XzEncoder::new_stream(bw, stream);
            pack_all(&mut enc, &entries, &opts, hash_algo, &mut total_bytes, &mut n_entries, &mut n_pjg, &mut n_ppg, &dedup,&mut prog)?;
            let mut inner = enc.finish()?;
            inner.flush()?;
        }
        Backend::Ppmd => unreachable!(),
    }
    prog.finish();

    let size_after = std::fs::metadata(&archive)?.len();
    let appended_bytes = size_after.saturating_sub(size_before);
    let elapsed = started.elapsed();
    let ratio = if total_bytes > 0 {
        appended_bytes as f64 / total_bytes as f64
    } else {
        0.0
    };
    let mbps = if elapsed.as_secs_f64() > 0.0 {
        (total_bytes as f64 / (1024.0 * 1024.0)) / elapsed.as_secs_f64()
    } else {
        0.0
    };
    if opts.summary {
        eprintln!(
            "append {} entries {:.2} MiB -> +{:.2} MiB (ratio {:.3}) {:.2}s {:.1} MiB/s",
            n_entries,
            total_bytes as f64 / (1024.0 * 1024.0),
            appended_bytes as f64 / (1024.0 * 1024.0),
            ratio,
            elapsed.as_secs_f64(),
            mbps
        );
    } else {
        eprintln!("appended {} entries", n_entries);
        eprintln!("in      {:.2} MiB", total_bytes as f64 / (1024.0 * 1024.0));
        eprintln!(
            "added   +{:.2} MiB   (total now {:.2} MiB)",
            appended_bytes as f64 / (1024.0 * 1024.0),
            size_after as f64 / (1024.0 * 1024.0)
        );
        eprintln!("time    {:.2} s    ({:.1} MiB/s)", elapsed.as_secs_f64(), mbps);
    }
    Ok(())
}

/// Which backend to use for a given syc level.
/// l0..l4 use zstd (fast decomp, enough ratio to beat ARC m1-m4).
/// l5..l10 default to LZMA (higher ratio).
/// Set `SYC_BACKEND=ppmd` to force PPMd7 (experimental, usually loses to
/// tuned LZMA until Dict/LZP preprocessors land — kept for future combo).
fn pick_backend(syc_level: i32, store: bool) -> Backend {
    if store || syc_level <= 4 {
        return Backend::Zstd;
    }
    match std::env::var("SYC_BACKEND").ok().as_deref() {
        Some("ppmd") => Backend::Ppmd,
        Some("zstd") => Backend::Zstd,
        _ => Backend::Lzma,
    }
}

/// PPMd7 params per syc level. Order drives ratio (higher = more context,
/// diminishing returns past ~8 for typical text). Memory caps the context
/// tree; FreeArc's `m9t` preset uses ~192 MiB at order 12.
fn pick_ppmd_params(syc_level: i32) -> PpmdParams {
    let (order, mem_mb) = match syc_level {
        7 => (8, 128),
        8 => (10, 192),
        9 => (12, 192),
        _ => (16, 256), // l10
    };
    let order = env_u32("SYC_PPMD_ORDER", order as u32).clamp(2, 16) as u8;
    let mem_mb = env_u32("SYC_PPMD_MEM_MB", mem_mb as u32).max(1);
    PpmdParams { order, mem_mb }
}

/// Map syc level (0..=4) to zstd level. Each tier must beat ARC mN on the
/// python3.13 docs benchmark. See NOTES.md.
fn map_zstd_level(syc_level: i32) -> i32 {
    // Benchmarked 2026-04-16 on 596 MB mixed binary (icons+fonts+doc tar):
    //   old m2=L15 → 33 s / 17.9 MB/s / ratio 0.236
    //   new m2=L9  → 10 s /  60 MB/s  / ratio 0.242   (~3.4× faster, ~2.5 % worse)
    //   old m3=L19 → 163 s / 3.6 MB/s / ratio 0.226
    //   new m3=L15 →  33 s / 18 MB/s  / ratio 0.236   (~5× faster, ~4.4 % worse;
    //                                                   matches old m2 ratio)
    // m1 and m4 are intentionally unchanged: m1 stays at L1 for raw speed, m4
    // stays at L19 + btultra2/ChainLog/HashLog/SearchLog overrides for users
    // who want every last bit. The speed tax on m4 is real but opt-in.
    match syc_level {
        0 => -5, // draft
        1 => 1,  // vs ARC m1 (0.228)  → 0.2142
        2 => 9,  // was L15; now middle tier w/ zstd sweet spot
        3 => 15, // was L19; now matches old m2 ratio at 5× speed
        4 => 19, // vs ARC m4 (0.162)  → 0.1507 (con ULTRA + overrides arriba)
        _ => 9,
    }
}

/// Build a custom LZMA2 stream tuned per-level. Base preset is 9|EXTREME,
/// then we override for text: lc=4, lp=0, pb=0, nice_len=273, dict grande.
const LZMA_PRESET_EXTREME: u32 = 1 << 31;

fn env_u32(name: &str, default: u32) -> u32 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// BCJ filter kind for the xz filter chain. `None` means no BCJ.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Bcj {
    None,
    X86,
    Arm,
    ArmThumb,
    Ia64,
    Sparc,
    PowerPc,
}

fn parse_hash_algo(s: Option<&str>) -> Result<HashAlgo> {
    match s.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        None | Some("") | Some("crc32") | Some("crc") => Ok(HashAlgo::Crc32),
        Some("xxh3") | Some("xxhash3") => Ok(HashAlgo::Xxh3),
        Some("blake3") | Some("b3") => Ok(HashAlgo::Blake3),
        Some(other) => Err(anyhow!("-hash: unknown algo '{other}' (crc32|xxh3|blake3)")),
    }
}

/// Extensions that are typically already-compressed payloads. When `-route`
/// is on, these land in a level-0 frame so we spend zero CPU trying to
/// re-compress (pointless — they stay ~1.0 ratio either way). Case-insensitive.
const ROUTE_STORE_EXTS: &[&str] = &[
    // Images
    "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif",
    // Audio (already lossy/compressed)
    "mp3", "aac", "m4a", "ogg", "opus", "flac",
    // Video
    "mp4", "mkv", "webm", "mov", "avi", "flv", "wmv", "m4v",
    // Archives
    "zip", "gz", "xz", "7z", "rar", "bz2", "zst", "lz4", "lzma",
    "tgz", "tbz2", "txz", "tzst",
    // Packages
    "deb", "rpm", "apk", "jar", "war", "ear", "crx", "whl", "egg",
    // Misc
    "pdf",
];

fn is_media_ext(rel: &Path) -> bool {
    rel.extension()
        .and_then(|e| e.to_str())
        .map(|e| ROUTE_STORE_EXTS.iter().any(|x| x.eq_ignore_ascii_case(e)))
        .unwrap_or(false)
}

fn parse_bcj(s: &str) -> Option<Bcj> {
    match s {
        "" | "off" | "none" | "0" => Some(Bcj::None),
        "x86" => Some(Bcj::X86),
        "arm" => Some(Bcj::Arm),
        "armt" | "arm_thumb" => Some(Bcj::ArmThumb),
        "ia64" => Some(Bcj::Ia64),
        "sparc" => Some(Bcj::Sparc),
        "powerpc" | "ppc" => Some(Bcj::PowerPc),
        _ => None,
    }
}

/// Auto-detect whether BCJ x86 is worthwhile. Samples up to 64 regular files
/// in the pack list, peeking the first 20 bytes. Counts x86/x86_64 ELF hits
/// (magic 7F 45 4C 46 + e_machine 0x3E or 0x03) and PE 'MZ' hits. Returns
/// `Bcj::X86` when ≥30 % of non-empty samples look like x86 executables.
fn auto_detect_bcj(all: &[(PathBuf, PathBuf)]) -> Bcj {
    let mut hits: u32 = 0;
    let mut samples: u32 = 0;
    let mut buf = [0u8; 20];
    for (full, _) in all.iter().take(64) {
        let meta = match std::fs::symlink_metadata(full) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !meta.is_file() || meta.len() < 20 {
            continue;
        }
        let mut f = match File::open(full) {
            Ok(f) => f,
            Err(_) => continue,
        };
        if f.read_exact(&mut buf).is_err() {
            continue;
        }
        samples += 1;
        // ELF magic then e_machine at offset 0x12 (little-endian u16)
        if &buf[0..4] == b"\x7FELF" {
            let em = u16::from_le_bytes([buf[0x12], buf[0x13]]);
            if em == 0x3E || em == 0x03 {
                hits += 1;
                continue;
            }
        }
        // PE / MS-DOS stub — fuzzy but most .exe/.dll start with MZ and are x86
        if buf[0] == b'M' && buf[1] == b'Z' {
            hits += 1;
        }
    }
    if samples >= 4 && hits * 10 >= samples * 3 {
        Bcj::X86
    } else {
        Bcj::None
    }
}

fn build_lzma_stream(syc_level: i32, threads: u32, total_raw: u64, bcj: Bcj) -> Result<xz2::stream::Stream> {
    use xz2::stream::{Check, Filters, LzmaOptions, MtStreamBuilder, Stream};
    let mut opts = LzmaOptions::new_preset(9 | LZMA_PRESET_EXTREME)?;
    // Text-tuned defaults; env vars let the sweep harness override.
    let lc = env_u32("SYC_LC", 4);
    let lp = env_u32("SYC_LP", 0);
    let pb = env_u32("SYC_PB", 0);
    let nice = env_u32("SYC_NICE", 273);
    opts.literal_context_bits(lc);
    opts.literal_position_bits(lp);
    opts.position_bits(pb);
    opts.nice_len(nice);
    let default_dict: u32 = match syc_level {
        5 | 6 => 64 * 1024 * 1024,
        _ => 128 * 1024 * 1024,
    };
    let dict = env_u32("SYC_DICT", default_dict);
    opts.dict_size(dict);
    let mut filters = Filters::new();
    // Optional BCJ pre-filter for executable data (transforms relative jumps →
    // absolute so LZMA sees repeating patterns). Decoder rediscovers the chain
    // from the xz block header, so no format change needed.
    match bcj {
        Bcj::None => {}
        Bcj::X86 => { filters.x86(); }
        Bcj::Arm => { filters.arm(); }
        Bcj::ArmThumb => { filters.arm_thumb(); }
        Bcj::Ia64 => { filters.ia64(); }
        Bcj::Sparc => { filters.sparc(); }
        Bcj::PowerPc => { filters.powerpc(); }
    }
    filters.lzma2(&opts);

    // Multithreaded: splits the stream into independent blocks — each block
    // restarts the LZMA state, so ratio is slightly worse but compression
    // scales near-linearly with cores. Only enable when the input is big
    // enough that at least a couple of blocks get parallelism AND splitting
    // won't tank the ratio (measured: python docs 71 MB → 4% ratio loss;
    // test-files.tar 200 MB subset → 0.1% loss, 2.3× faster).
    let block_bytes_default = (dict as u64).saturating_mul(3);
    let block_bytes = env_u32("SYC_LZMA_BLOCK_MIB", 0);
    let block_bytes = if block_bytes > 0 {
        (block_bytes as u64) * 1024 * 1024
    } else {
        block_bytes_default
    };
    // At least 2× block_bytes of input → worth splitting. Otherwise single
    // thread (preserves ratio, which is why we picked LZMA in the first place).
    let mt_eligible = threads > 1 && total_raw >= block_bytes.saturating_mul(2);
    if mt_eligible {
        MtStreamBuilder::new()
            .threads(threads)
            .block_size(block_bytes)
            .filters(filters)
            .check(Check::Crc64)
            .encoder()
            .map_err(|e| anyhow!("lzma mt init: {e:?}"))
    } else {
        Stream::new_stream_encoder(&filters, Check::Crc64).map_err(|e| anyhow!("lzma init: {e:?}"))
    }
}

/// Sum of bytes `pack_all` will actually stream through the compressor for
/// this bucket — regular files that aren't hardlink-dedup'd.
fn packable_bytes(
    all: &[(PathBuf, PathBuf)],
    dedup: &std::collections::HashMap<PathBuf, String>,
) -> u64 {
    all.iter()
        .filter(|(full, _)| !dedup.contains_key(full))
        .filter_map(|(full, _)| std::fs::symlink_metadata(full).ok())
        .filter(|m| m.is_file())
        .map(|m| m.len())
        .sum()
}

fn pack_all<W: Write>(
    enc: &mut W,
    all: &[(PathBuf, PathBuf)],
    opts: &Opts,
    hash_algo: Option<HashAlgo>,
    total_bytes: &mut u64,
    n_entries: &mut u64,
    n_pjg: &mut u64,
    n_ppg: &mut u64,
    dedup: &std::collections::HashMap<PathBuf, String>,
    progress: &mut progress::Progress,
) -> Result<()> {
    let mut buf = vec![0u8; CHUNK];
    let mut chunk_reg = if opts.fastcdc {
        Some(fastcdc::ChunkRegistry::new())
    } else {
        None
    };

    // ─── v0.1.20 Phase 3: specific compression (pjg / ppg) ─────────────────
    // v0.1.25: Phase 3 (parallel pjg/ppg pre-compress) and Phase 4 (sequential
    // pack-loop write through the LZMA/Zstd backend) now run CONCURRENTLY.
    // Workers stream their results into a bounded channel; the pack loop pulls
    // them on demand via `PrecompressStream::take_or_block`. This collapses the
    // two phases' wall-clocks into roughly max(Phase3, Phase4) instead of sum.
    let mut precomputed: std::collections::HashMap<usize, pipeline::Precompressed> =
        std::collections::HashMap::new();
    let mut pjg_idx_set: std::collections::HashSet<usize> =
        std::collections::HashSet::new();
    let mut precompress_stream: Option<pipeline::PrecompressStream> = None;
    if opts.threads > 1 {
        let mut jobs: Vec<pipeline::SpecificJob> = Vec::new();
        for (idx, (full, rel)) in all.iter().enumerate() {
            if dedup.contains_key(full) {
                continue;
            }
            let kind = match detect::detect(full) {
                detect::FileKind::Jpeg if !opts.nopjg => Some(pipeline::SpecificKind::Pjg),
                detect::FileKind::Png if opts.ppg => Some(pipeline::SpecificKind::Ppg),
                _ => None,
            };
            if let Some(k) = kind {
                if std::fs::symlink_metadata(full).map(|m| m.is_file()).unwrap_or(false) {
                    pjg_idx_set.insert(idx);
                    jobs.push(pipeline::SpecificJob {
                        idx,
                        full: full.clone(),
                        rel: rel.clone(),
                        kind: k,
                    });
                }
            }
        }
        if !jobs.is_empty() {
            let nw = pipeline::phase3_worker_count(opts.threads);
            if !opts.summary {
                eprintln!(
                    "phase3  pre-compress {} pjg/ppg job(s) on {} worker(s) (overlap with phase4)",
                    jobs.len(),
                    nw,
                );
            }
            precompress_stream =
                Some(pipeline::spawn_precompress_stream(jobs, nw, hash_algo));
        }
    }

    // ─── v0.1.20 Phase 4: write entries (general compression streams via enc) ──
    // The `enc` writer wraps the LZMA / Zstd / PPMd encoder. Each entry written
    // here flows through that backend as it goes — the entry-level loop is
    // sequential, but the backend may be MT-LZMA when -threads >= 2 and the
    // input is large enough (see build_lzma_stream).
    for (idx, (full, rel)) in all.iter().enumerate() {
        // v0.1.25: pull this entry's pjg/ppg cache from the streaming Phase 3
        // pool BEFORE the existing pack-loop branches run. take_or_block also
        // drains any already-arrived results (advancing progress for them) so
        // the bounded channel doesn't stall workers during slow non-pjg/ppg
        // inline writes.
        if let Some(s) = precompress_stream.as_mut() {
            if pjg_idx_set.contains(&idx) {
                if let Some(Ok(p)) = s.take_or_block(idx, progress) {
                    precomputed.insert(idx, p);
                }
                // Err result silently dropped → falls through to the JPG/PNG
                // fallback below, matching v0.1.20-v0.1.24 behaviour.
            }
        }
        if opts.verbose {
            eprintln!("+ {}", rel.display());
        }
        if let Some(canonical) = dedup.get(full) {
            let rel_str = rel.to_string_lossy().replace('\\', "/");
            let mtime = std::fs::symlink_metadata(full)
                .map(|m| archive::meta_mtime(&m))
                .unwrap_or(0);
            let header = EntryHeader {
                kind: EntryKind::HardLink,
                mode: entry_mode(full),
                size: 0,
                mtime,
                path: rel_str,
                link_target: canonical.clone(),
            };
            header.write_to(enc)?;
            if opts.xattrs {
                archive::write_xattrs_block(enc, full, false)?;
            }
        } else if let Some(p) = precomputed.remove(&idx) {
            // v0.1.20 Phase 3: cached pre-compress hit — write directly
            // without the FFI call (already done by the worker pool).
            let original_size = p.original_size;
            let kind_label = p.kind;
            write_specific_from_cache(p, enc, opts.xattrs, full,
                &mut |n| progress.advance(n))?;
            *total_bytes += original_size;
            match kind_label {
                pipeline::SpecificKind::Pjg => *n_pjg += 1,
                pipeline::SpecificKind::Ppg => *n_ppg += 1,
            }
        } else if !opts.nopjg && detect::detect(full) == detect::FileKind::Jpeg {
            if let Ok(meta) = std::fs::symlink_metadata(full) {
                if meta.is_file() {
                    match pack_entry_pjg(full, rel, enc, hash_algo, opts.xattrs,
                        &mut |n| progress.advance(n))
                    {
                        Ok(()) => { *n_pjg += 1; }
                        Err(_) => {
                            // Unsupported JPEG variant — fall back to plain File.
                            pack_entry(full, rel, enc, &mut buf, hash_algo, opts.xattrs,
                                &mut |n| progress.advance(n))?;
                        }
                    }
                    *total_bytes += meta.len();
                } else {
                    pack_entry(full, rel, enc, &mut buf, hash_algo, opts.xattrs,
                        &mut |n| progress.advance(n))?;
                }
            }
        } else if opts.ppg && detect::detect(full) == detect::FileKind::Png {
            if let Ok(meta) = std::fs::symlink_metadata(full) {
                if meta.is_file() {
                    match pack_entry_ppg(full, rel, enc, hash_algo, opts.xattrs,
                        &mut |n| progress.advance(n))
                    {
                        Ok(()) => { *n_ppg += 1; }
                        Err(_) => {
                            // Unsupported PNG variant — fall back to plain File.
                            pack_entry(full, rel, enc, &mut buf, hash_algo, opts.xattrs,
                                &mut |n| progress.advance(n))?;
                        }
                    }
                    *total_bytes += meta.len();
                } else {
                    pack_entry(full, rel, enc, &mut buf, hash_algo, opts.xattrs,
                        &mut |n| progress.advance(n))?;
                }
            }
        } else if let Some(reg) = chunk_reg.as_mut() {
            pack_entry_chunked(full, rel, enc, hash_algo, opts.xattrs, reg,
                &mut |n| progress.advance(n))?;
            if let Ok(meta) = std::fs::symlink_metadata(full) {
                if meta.is_file() {
                    *total_bytes += meta.len();
                }
            }
        } else {
            // Per-chunk progress: pack_entry calls back per write so a single
            // multi-GB file ticks the bar instead of jumping straight to
            // flushing... Total bytes counter still bumps once per file at
            // the end (independent of progress UI).
            pack_entry(full, rel, enc, &mut buf, hash_algo, opts.xattrs,
                &mut |n| progress.advance(n))?;
            if let Ok(meta) = std::fs::symlink_metadata(full) {
                if meta.is_file() {
                    *total_bytes += meta.len();
                }
            }
        }
        *n_entries += 1;
    }
    // v0.1.25: drain any straggler Phase 3 results and join workers. Under
    // normal flow the pack loop has already consumed every job's result via
    // take_or_block; this is the safety net for unusual paths.
    if let Some(s) = precompress_stream.take() {
        let _ = s.finish(progress);
    }
    // All entries streamed. The encoder's finish() step can still take a
    // while (LZMA MT in particular), so flip the bar to a "flushing..."
    // message before we hand control to enc.finish() back in cmd_add.
    progress.flushing();
    Ok(())
}

/// Pack one entry using FastCDC chunking. Regular (Dir/Symlink) entries fall
/// back to plain pack_entry; only File entries switch to ChunkedFile format.
fn pack_entry_chunked<W: Write>(
    full: &Path,
    rel: &Path,
    out: &mut W,
    hash_algo: Option<HashAlgo>,
    with_xattrs: bool,
    reg: &mut fastcdc::ChunkRegistry,
    on_bytes: &mut dyn FnMut(u64),
) -> Result<()> {
    let meta = std::fs::symlink_metadata(full)
        .with_context(|| format!("stat {}", full.display()))?;
    // Dirs/symlinks don't get chunked — their bodies are empty. Plain pack_entry
    // handles them; we only intercept regular files.
    if !meta.is_file() || meta.file_type().is_symlink() {
        let mut small_buf = vec![0u8; CHUNK];
        return pack_entry(full, rel, out, &mut small_buf, hash_algo, with_xattrs, on_bytes);
    }
    let size = meta.len();
    let rel_str = rel.to_string_lossy().replace('\\', "/");
    let mtime = archive::meta_mtime(&meta);
    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode()
    };
    #[cfg(not(unix))]
    let mode = 0o644u32;
    let header = EntryHeader {
        kind: EntryKind::ChunkedFile,
        mode,
        size,
        mtime,
        path: rel_str,
        link_target: String::new(),
    };
    header.write_to(out)?;
    if with_xattrs {
        archive::write_xattrs_block(out, full, false)?;
    }
    let f = File::open(full)
        .with_context(|| format!("open {}", full.display()))?;
    let r = BufReader::with_capacity(archive::IO_BUF, f);
    let mut hasher = hash_algo.map(archive::EntryHasher::new);
    let total = fastcdc::pack_chunked_body(r, out, reg, |bytes| {
        if let Some(h) = hasher.as_mut() { h.update(bytes); }
        on_bytes(bytes.len() as u64);
    })?;
    if total != size {
        return Err(anyhow!("fastcdc: file {} changed during pack ({} vs {})",
            full.display(), total, size));
    }
    if let (Some(h), Some(algo)) = (hasher, hash_algo) {
        let mut trailer = [0u8; 32];
        let tb = algo.trailer_bytes();
        h.finalize_into(&mut trailer[..tb]);
        out.write_all(&trailer[..tb])?;
    }
    Ok(())
}

/// Pack a JPEG as PJG (EntryKind::PjgFile). Body layout:
///   [pjg_size:u32LE][pjg_bytes]
/// `header.size` = original JPEG size; hash covers decoded JPEG bytes.
fn pack_entry_pjg<W: Write>(
    full: &Path,
    rel: &Path,
    out: &mut W,
    hash_algo: Option<archive::HashAlgo>,
    with_xattrs: bool,
    on_bytes: &mut dyn FnMut(u64),
) -> Result<()> {
    let meta = std::fs::symlink_metadata(full)
        .with_context(|| format!("stat {}", full.display()))?;
    let jpg_bytes = std::fs::read(full)
        .with_context(|| format!("read {}", full.display()))?;
    let pjg_bytes = pjg::jpg_to_pjg(&jpg_bytes)
        .map_err(|e| anyhow!("packJPG encode {}: {e}", full.display()))?;

    let rel_str = rel.to_string_lossy().replace('\\', "/");
    let mtime = archive::meta_mtime(&meta);
    #[cfg(unix)]
    let mode = { use std::os::unix::fs::PermissionsExt; meta.permissions().mode() };
    #[cfg(not(unix))]
    let mode = 0o644u32;

    let header = EntryHeader {
        kind: EntryKind::PjgFile,
        mode,
        size: jpg_bytes.len() as u64,
        mtime,
        path: rel_str,
        link_target: String::new(),
    };
    header.write_to(out)?;
    if with_xattrs { archive::write_xattrs_block(out, full, false)?; }

    out.write_u32::<LittleEndian>(pjg_bytes.len() as u32)?;
    out.write_all(&pjg_bytes)?;
    on_bytes(pjg_bytes.len() as u64);

    if let Some(algo) = hash_algo {
        let mut hasher = archive::EntryHasher::new(algo);
        hasher.update(&jpg_bytes);
        let tb = algo.trailer_bytes();
        let mut trailer = [0u8; 32];
        hasher.finalize_into(&mut trailer[..tb]);
        out.write_all(&trailer[..tb])?;
    }
    Ok(())
}

/// Pack a PNG/APNG as PPG (EntryKind::PpgFile). Body layout:
///   [ppg_size:u32LE][ppg_bytes]
/// `header.size` = original PNG size; hash covers decoded PNG bytes.
fn pack_entry_ppg<W: Write>(
    full: &Path,
    rel: &Path,
    out: &mut W,
    hash_algo: Option<archive::HashAlgo>,
    with_xattrs: bool,
    on_bytes: &mut dyn FnMut(u64),
) -> Result<()> {
    let meta = std::fs::symlink_metadata(full)
        .with_context(|| format!("stat {}", full.display()))?;
    let png_bytes = std::fs::read(full)
        .with_context(|| format!("read {}", full.display()))?;
    let ppg_bytes = ppg::png_to_ppg(&png_bytes)
        .map_err(|e| anyhow!("packPNG encode {}: {e}", full.display()))?;

    let rel_str = rel.to_string_lossy().replace('\\', "/");
    let mtime = archive::meta_mtime(&meta);
    #[cfg(unix)]
    let mode = { use std::os::unix::fs::PermissionsExt; meta.permissions().mode() };
    #[cfg(not(unix))]
    let mode = 0o644u32;

    let header = EntryHeader {
        kind: EntryKind::PpgFile,
        mode,
        size: png_bytes.len() as u64,
        mtime,
        path: rel_str,
        link_target: String::new(),
    };
    header.write_to(out)?;
    if with_xattrs { archive::write_xattrs_block(out, full, false)?; }

    out.write_u32::<LittleEndian>(ppg_bytes.len() as u32)?;
    out.write_all(&ppg_bytes)?;
    on_bytes(ppg_bytes.len() as u64);

    if let Some(algo) = hash_algo {
        let mut hasher = archive::EntryHasher::new(algo);
        hasher.update(&png_bytes);
        let tb = algo.trailer_bytes();
        let mut trailer = [0u8; 32];
        hasher.finalize_into(&mut trailer[..tb]);
        out.write_all(&trailer[..tb])?;
    }
    Ok(())
}

/// Write a pre-compressed pjg/ppg entry from the v0.1.20 Phase-3 cache.
/// Mirrors the I/O part of pack_entry_pjg / pack_entry_ppg but skips the
/// filesystem read and the FFI call (the worker pool already did both,
/// including the hash if requested).
fn write_specific_from_cache<W: Write>(
    p: pipeline::Precompressed,
    out: &mut W,
    with_xattrs: bool,
    full: &Path,
    on_bytes: &mut dyn FnMut(u64),
) -> Result<()> {
    let kind = match p.kind {
        pipeline::SpecificKind::Pjg => EntryKind::PjgFile,
        pipeline::SpecificKind::Ppg => EntryKind::PpgFile,
    };
    let rel_str = p.rel.to_string_lossy().replace('\\', "/");
    let header = EntryHeader {
        kind,
        mode: p.mode,
        size: p.original_size,
        mtime: p.mtime,
        path: rel_str,
        link_target: String::new(),
    };
    header.write_to(out)?;
    if with_xattrs {
        archive::write_xattrs_block(out, full, false)?;
    }
    out.write_u32::<LittleEndian>(p.body.len() as u32)?;
    out.write_all(&p.body)?;
    // v0.1.22: progress already advanced during Phase 3 (parallel_precompress
    // bumped by original_size when the worker completed). Don't double-count.
    let _ = on_bytes;
    if let Some(trailer) = &p.hash_trailer {
        out.write_all(trailer)?;
    }
    Ok(())
}

#[cfg(unix)]
fn entry_mode(full: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    std::fs::symlink_metadata(full)
        .map(|m| m.permissions().mode())
        .unwrap_or(0o644)
}

#[cfg(not(unix))]
fn entry_mode(_full: &Path) -> u32 { 0o644 }

/// Scan `entries` and build a map of duplicate-file full-path → canonical
/// archive-relative path (the first-seen copy). Only considers regular files
/// with size > 0. Hash: xxh3_64 over full content. Callers must have already
/// sorted entries — canonical is whichever file comes first in the iteration
/// order.
fn build_dedup_map(
    entries: &[(PathBuf, PathBuf)],
) -> Result<std::collections::HashMap<PathBuf, String>> {
    use std::collections::HashMap;
    use std::hash::Hasher;
    let mut seen: HashMap<(u64, u64), String> = HashMap::new();
    let mut targets: HashMap<PathBuf, String> = HashMap::new();
    let mut buf = vec![0u8; archive::CHUNK];
    for (full, rel) in entries {
        let meta = match std::fs::symlink_metadata(full) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !meta.is_file() || meta.len() == 0 {
            continue;
        }
        let size = meta.len();
        let f = match File::open(full) {
            Ok(f) => f,
            Err(_) => continue,
        };
        let mut r = BufReader::with_capacity(archive::IO_BUF, f);
        let mut h = twox_hash::XxHash3_64::new();
        loop {
            let n = match r.read(&mut buf) {
                Ok(n) => n,
                Err(_) => break,
            };
            if n == 0 { break; }
            h.write(&buf[..n]);
        }
        let key = (size, h.finish());
        let rel_str = rel.to_string_lossy().replace('\\', "/");
        match seen.get(&key) {
            Some(canonical) => {
                targets.insert(full.clone(), canonical.clone());
            }
            None => {
                seen.insert(key, rel_str);
            }
        }
    }
    Ok(targets)
}

fn collect_entries_or_single(src: &Path) -> Result<Vec<(PathBuf, PathBuf)>> {
    let meta = std::fs::symlink_metadata(src)
        .with_context(|| format!("stat {}", src.display()))?;
    if meta.is_dir() {
        collect_entries(src)
    } else {
        let rel = src
            .file_name()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("file"));
        Ok(vec![(src.to_path_buf(), rel)])
    }
}

fn open_archive(archive: &Path) -> Result<(Box<dyn Read>, Option<HashAlgo>, Option<String>, bool, archive::ArchiveVersion)> {
    let rd = open_input(archive)?;
    let mut br = BufReader::with_capacity(archive::IO_BUF, rd);
    let (version, backend, preproc, dict, ppmd, comment, hash_algo, delta_stride, _scan_summary) = read_preamble(&mut br)?;
    let has_xattrs = preproc & archive::FEATURE_XATTRS != 0;
    let raw: Box<dyn Read> = match backend {
        Backend::Zstd => {
            let mut d = if dict.is_empty() {
                zstd::stream::Decoder::with_buffer(br)?
            } else {
                zstd::stream::Decoder::with_dictionary(br, &dict)?
            };
            let _ = d.window_log_max(31);
            Box::new(d)
        }
        // `new_multi_decoder` transparently handles a sequence of concatenated
        // xz streams — which is what the `-append` command produces. It's a
        // strict superset of the single-stream decoder, so non-appended
        // archives decode identically.
        Backend::Lzma => Box::new(xz2::read::XzDecoder::new_multi_decoder(br)),
        Backend::Ppmd => {
            let p = ppmd.ok_or_else(|| anyhow!("ppmd backend missing params"))?;
            let mem_bytes = (p.mem_mb as u32).saturating_mul(1024 * 1024);
            let d = Ppmd7Decoder::new(br, p.order as u32, mem_bytes)
                .map_err(|e| anyhow!("ppmd init: {e}"))?;
            Box::new(d)
        }
    };
    // Both REP and SREP emit the same wire format, so RepReader handles both.
    // LZP uses its own (context-hash) wire format, handled by LzpReader.
    let pre_delta: Box<dyn Read> = if preproc & (PREPROC_REP | PREPROC_SREP) != 0 {
        Box::new(rep::RepReader::new(raw))
    } else if preproc & PREPROC_LZP != 0 {
        Box::new(lzp::LzpReader::new(raw))
    } else {
        raw
    };
    let dec: Box<dyn Read> = if let Some(stride) = delta_stride {
        Box::new(delta::DeltaReader::new(pre_delta, stride))
    } else {
        pre_delta
    };
    Ok((dec, hash_algo, comment, has_xattrs, version))
}

fn cmd_extract(archive: PathBuf, opts: Opts) -> Result<()> {
    let out = opts
        .to
        .clone()
        .ok_or_else(|| anyhow!("x: -to DIR is required"))?;
    let started = Instant::now();
    std::fs::create_dir_all(&out)?;
    let (mut dec, hash_algo, comment, has_xattrs, version) = open_archive(&archive)?;
    if let Some(c) = comment.as_deref() { if !opts.summary { eprintln!("comment {}", c); } }

    let mut buf = vec![0u8; CHUNK];
    let mut n_entries: u64 = 0;
    let mut total_bytes: u64 = 0;
    let progress_enabled = !opts.noprogress && progress::stderr_is_tty() && !opts.summary;
    let mut prog = progress::Progress::new("extract", 0, progress_enabled);
    let mut reg = fastcdc::DecodeRegistry::new();

    // v0.1.24: parallel pjg/ppg decompress + write. Main thread reads bodies
    // sequentially (LZMA stream is single-producer); workers do the expensive
    // FFI decode and disk write in parallel, scaling extract on PNG-heavy
    // corpora roughly with -threads N (matches Phase 3 on the encode side).
    let workers = pipeline::phase3_worker_count(opts.threads);
    let pool = pipeline::DecodePool::new(workers);
    let mut decode_errors: Vec<String> = Vec::new();

    while let Some(header) = EntryHeader::read_from(&mut dec, version)? {
        if header.kind.is_file_like() {
            total_bytes += header.size;
        }
        if opts.verbose {
            eprintln!("- {}", header.path);
        }
        match header.kind {
            EntryKind::PjgFile | EntryKind::PpgFile => {
                let xattrs = if has_xattrs {
                    Some(archive::read_xattrs_block(&mut dec)?)
                } else {
                    None
                };
                let body_size = dec.read_u32::<LittleEndian>()? as usize;
                let mut body = vec![0u8; body_size];
                dec.read_exact(&mut body)?;
                let hash_trailer = if let Some(algo) = hash_algo {
                    let tb = algo.trailer_bytes();
                    let mut t = vec![0u8; tb];
                    dec.read_exact(&mut t)?;
                    Some(t)
                } else {
                    None
                };
                let safe_rel = archive::sanitize_rel(&header.path)?;
                let full_path = out.join(safe_rel);
                let kind = match header.kind {
                    EntryKind::PjgFile => pipeline::SpecificKind::Pjg,
                    EntryKind::PpgFile => pipeline::SpecificKind::Ppg,
                    _ => unreachable!(),
                };
                let job = pipeline::DecodeJob {
                    full_path,
                    kind,
                    body,
                    hash_trailer,
                    hash_algo,
                    mtime: header.mtime,
                    mode: header.mode,
                    xattrs,
                    size: header.size,
                    rel_display: header.path.clone(),
                };
                if pool.dispatch(job).is_err() {
                    return Err(anyhow!("decode pool closed unexpectedly"));
                }
                while let Some(r) = pool.try_recv() {
                    match r.result {
                        Ok(()) => prog.advance(r.size),
                        Err(e) => decode_errors.push(e),
                    }
                }
            }
            _ => {
                unpack_entry(&mut dec, &out, &header, &mut buf, hash_algo, has_xattrs, &mut reg)?;
                if header.kind.is_file_like() {
                    prog.advance(header.size);
                }
            }
        }
        n_entries += 1;
    }

    let mut sink = [0u8; 1024];
    while dec.read(&mut sink)? > 0 {}

    for r in pool.finish() {
        match r.result {
            Ok(()) => prog.advance(r.size),
            Err(e) => decode_errors.push(e),
        }
    }
    prog.finish();

    if !decode_errors.is_empty() {
        for e in &decode_errors {
            eprintln!("{}", color::err_line(e));
        }
        return Err(anyhow!("{} decode error(s)", decode_errors.len()));
    }

    let elapsed = started.elapsed();
    if opts.summary {
        eprintln!(
            "{} entries {} in {:.2}s",
            n_entries,
            human_si(total_bytes),
            elapsed.as_secs_f64()
        );
    } else {
        eprintln!();
        eprintln!(
            "<<{}>>: extracted into {}",
            archive.display(),
            out.display(),
        );
        eprintln!(
            "{} files, {} ({})",
            n_entries,
            eu_num(total_bytes),
            human_si(total_bytes),
        );
    }
    end_footer(elapsed, total_bytes);
    Ok(())
}

fn cmd_list(archive: PathBuf, opts: Opts) -> Result<()> {
    let started = Instant::now();
    let arc_size = std::fs::metadata(&archive).map(|m| m.len()).unwrap_or(0);
    let (mut dec, hash_algo, comment, has_xattrs, version) = open_archive(&archive)?;

    let mut buf = vec![0u8; CHUNK];
    let needle = opts.find.as_deref().map(|s| s.to_lowercase());
    let mut n_entries: u64 = 0;
    let mut n_files: u64 = 0;
    let mut total_bytes: u64 = 0;
    // (kind, mtime, size, path, link_target)
    let mut rows: Vec<(EntryKind, i64, u64, String, String)> = Vec::new();
    let mut reg = fastcdc::DecodeRegistry::new();

    while let Some(header) = EntryHeader::read_from(&mut dec, version)? {
        if has_xattrs { let _ = archive::read_xattrs_block(&mut dec)?; }
        let show = match &needle {
            Some(t) => header.path.to_lowercase().contains(t),
            None => true,
        };
        if header.kind.is_file_like() {
            total_bytes += header.size;
            n_files += 1;
        }
        n_entries += 1;
        if show && !opts.summary {
            rows.push((header.kind, header.mtime, header.size, header.path.clone(), header.link_target.clone()));
        }
        if header.kind.is_file_like() {
            match archive::read_file_body(&mut dec, &header, &mut reg, hash_algo, &mut buf, |_| Ok(()))? {
                archive::BodyOutcome::Ok => {}
                archive::BodyOutcome::HashMismatch => {
                    return Err(anyhow!(
                        "{} mismatch on {}",
                        hash_algo.map(|a| a.name()).unwrap_or("hash"),
                        header.path
                    ));
                }
            }
        }
    }

    if opts.summary {
        eprintln!(
            "{} files, {} ({}) uncompressed, archive {} ({})",
            n_files,
            eu_num(total_bytes),
            human_si(total_bytes),
            eu_num(arc_size),
            human_si(arc_size),
        );
    } else {
        println!();
        println!("<<{}>>:", archive.display());
        if let Some(c) = comment.as_deref() { println!("comment: {}", c); }
        println!(
            "1 versions, {} files, {} bytes ({})",
            n_files,
            eu_num(total_bytes),
            human_si(total_bytes),
        );
        println!();
        // zpaqfranz-style layout: Date Time Size Ratio Name.
        // We don't store per-entry compressed bytes, so the Ratio column
        // carries a kind tag instead of a percentage: <dir>, <lnk>, <hln>,
        // <cdc> for chunked files, blank for plain files. This keeps the
        // column visually useful without inventing numbers.
        println!("Date       Time                  Size  Ratio  Name");
        println!("---------- --------  --------------  -----  ----");
        for (kind, mtime, size, path, link) in &rows {
            let date = if *mtime > 0 { fmt_mtime(*mtime) } else { "                   ".to_string() };
            let size_s = eu_num(*size);
            let (tag_raw, tag_col): (&str, String) = match kind {
                EntryKind::Dir => ("<dir>", color::c("<dir>")),
                EntryKind::Symlink => ("<lnk>", color::y("<lnk>")),
                EntryKind::HardLink => ("<hln>", color::y("<hln>")),
                EntryKind::ChunkedFile => ("<cdc>", color::g("<cdc>")),
                EntryKind::PjgFile => ("<pjg>", color::g("<pjg>")),
                EntryKind::PpgFile => ("<ppg>", color::g("<ppg>")),
                EntryKind::File => ("     ", "     ".to_string()),
            };
            // Track raw tag width (5 chars) but print colored version; column
            // alignment still looks right in a TTY because ANSI codes are
            // zero-width.
            let _ = tag_raw;
            if !link.is_empty() && matches!(kind, EntryKind::Symlink | EntryKind::HardLink) {
                println!("{}  {:>14}  {}  {} -> {}", date, size_s, tag_col, path, link);
            } else {
                println!("{}  {:>14}  {}  {}", date, size_s, tag_col, path);
            }
        }
        println!();
        let ratio = if total_bytes > 0 { arc_size as f64 / total_bytes as f64 } else { 0.0 };
        let ratio_s = format!("{:.3}", ratio);
        let ratio_col = if ratio >= 0.95 {
            color::y(&ratio_s)
        } else if ratio < 0.80 && ratio > 0.0 {
            color::g(&ratio_s)
        } else {
            ratio_s
        };
        println!(
            "              {} ({}) of {} ({}) in {} files shown",
            eu_num(total_bytes),
            human_si(total_bytes),
            eu_num(total_bytes),
            human_si(total_bytes),
            n_files,
        );
        println!(
            "               {} compressed  Ratio {} <<{}>>",
            eu_num(arc_size),
            ratio_col,
            archive.display(),
        );
        if let Some(algo) = hash_algo {
            println!("hash: {}", algo.name());
        }
    }
    let _ = n_entries;
    end_footer(started.elapsed(), arc_size);
    Ok(())
}

fn cmd_test(archive: PathBuf, opts: Opts) -> Result<()> {
    let started = Instant::now();
    let arc_size = std::fs::metadata(&archive).map(|m| m.len()).unwrap_or(0);
    let (mut dec, hash_algo, comment, has_xattrs, version) = open_archive(&archive)?;
    if !opts.summary {
        eprintln!();
        eprintln!("<<{}>>:", archive.display());
        if let Some(c) = comment.as_deref() { eprintln!("comment: {}", c); }
    }

    let mut buf = vec![0u8; CHUNK];
    let mut n_entries: u64 = 0;
    let mut total_bytes: u64 = 0;
    let mut hashes_verified: u64 = 0;
    let mut hashes_failed: u64 = 0;
    let mut failed_paths: Vec<String> = Vec::new();
    let mut stream_error: Option<String> = None;
    let progress_enabled = !opts.noprogress && progress::stderr_is_tty() && !opts.summary;
    let mut prog = progress::Progress::new("test", 0, progress_enabled);
    let mut reg = fastcdc::DecodeRegistry::new();
    // Inner loop wrapped so any Err (zstd frame checksum, truncated stream, …)
    // is captured instead of bubbling past the summary. Hash mismatches stay
    // tally-and-continue; stream-level errors mean we can't resync, so we
    // record them and break. Either way we still print the final verdict so a
    // nightly cron gets a useful line regardless of failure mode.
    loop {
        let header = match EntryHeader::read_from(&mut dec, version) {
            Ok(Some(h)) => h,
            Ok(None) => break,
            Err(e) => {
                stream_error = Some(format!("archive header read failed: {e:#}"));
                break;
            }
        };
        if has_xattrs {
            if let Err(e) = archive::read_xattrs_block(&mut dec) {
                stream_error = Some(format!("xattrs block on {}: {e:#}", header.path));
                break;
            }
        }
        if opts.verbose {
            eprintln!("? {}", header.path);
        }
        if header.kind.is_file_like() {
            total_bytes += header.size;
            prog.advance(header.size);
            let outcome = match archive::read_file_body(
                &mut dec, &header, &mut reg, hash_algo, &mut buf, |_| Ok(())
            ) {
                Ok(o) => o,
                Err(e) => {
                    stream_error = Some(format!(
                        "body read failed on {}: {e:#}", header.path
                    ));
                    break;
                }
            };
            match outcome {
                archive::BodyOutcome::Ok => {
                    if hash_algo.is_some() { hashes_verified += 1; }
                }
                archive::BodyOutcome::HashMismatch => {
                    hashes_failed += 1;
                    let algo = hash_algo.map(|a| a.name()).unwrap_or("hash");
                    let msg = format!("{} mismatch on {}", algo, header.path);
                    eprintln!("\r{}", color::err_line(&msg));
                    failed_paths.push(header.path.clone());
                }
            }
        }
        n_entries += 1;
    }
    prog.finish();
    // Don't echo stream_error here — it's what we return as Err at the end,
    // and main() already formats Errs through err_line, so logging both would
    // duplicate the 0xxxx! counter line.
    let elapsed = started.elapsed();
    let algo_name = hash_algo.map(|a| a.name()).unwrap_or("off");
    let verdict_ok = hashes_failed == 0 && stream_error.is_none();
    if opts.summary {
        if verdict_ok {
            eprintln!(
                "test OK  {} entries ({} {} verified) {} in {:.2}s",
                n_entries, hashes_verified, algo_name,
                human_si(total_bytes), elapsed.as_secs_f64(),
            );
        } else {
            eprintln!(
                "test FAIL  {} entries ({} {} verified, {} failed) {} in {:.2}s",
                n_entries, hashes_verified, algo_name, hashes_failed,
                human_si(total_bytes), elapsed.as_secs_f64(),
            );
        }
    } else {
        let n_files = n_entries; // approximate — non-file entries skipped hashing
        eprintln!(
            "{} versions, {} files, {} bytes ({})",
            1, n_files, eu_num(total_bytes), human_si(total_bytes),
        );
        eprintln!(
            "To be checked {} ({}) in {} files ({} threads)",
            eu_num(total_bytes), human_si(total_bytes), n_files, opts.threads.max(1),
        );
        let mbps = if elapsed.as_secs_f64() > 0.0 {
            (total_bytes as f64 / (1024.0 * 1024.0)) / elapsed.as_secs_f64()
        } else { 0.0 };
        eprintln!(
            "Total       {} speed {}.000/s ({:.2} MB/s)",
            eu_num(total_bytes), eu_num(total_bytes), mbps,
        );
        if verdict_ok {
            eprintln!(
                "VERDICT         : {}                   ({} stored vs decompressed)",
                color::g("OK"),
                algo_name,
            );
        } else {
            eprintln!(
                "VERDICT         : {}  ({} of {} files failed {} check)",
                color::r("FAIL"),
                hashes_failed, hashes_verified + hashes_failed, algo_name,
            );
            // Echo up to 20 failed paths so cron logs are useful without being
            // enormous. Past that just say "... and N more".
            let shown = failed_paths.len().min(20);
            for p in failed_paths.iter().take(shown) {
                eprintln!("  {} {}", color::r("FAIL"), p);
            }
            if failed_paths.len() > shown {
                eprintln!("  ... and {} more", failed_paths.len() - shown);
            }
        }
        let _ = arc_size;
    }
    end_footer(elapsed, total_bytes);
    if !verdict_ok {
        let detail = if let Some(msg) = stream_error {
            msg
        } else {
            format!("{} entries failed {} verification", hashes_failed, algo_name)
        };
        return Err(anyhow!(detail));
    }
    Ok(())
}
