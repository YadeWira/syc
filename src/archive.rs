use anyhow::{anyhow, Context, Result};
use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

pub const MAGIC: &[u8; 4] = b"SYC4";

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Zstd = 0,
    Lzma = 1,
    Ppmd = 2,
}

impl Backend {
    pub fn from_u8(v: u8) -> Result<Self> {
        Ok(match v {
            0 => Self::Zstd,
            1 => Self::Lzma,
            2 => Self::Ppmd,
            _ => return Err(anyhow!("unknown backend id: {v}")),
        })
    }
}

/// PPMd configuration embedded in the preamble when backend = Ppmd.
#[derive(Clone, Copy, Debug)]
pub struct PpmdParams {
    pub order: u8,
    pub mem_mb: u32,
}
pub const CHUNK: usize = 256 * 1024;
pub const IO_BUF: usize = 1024 * 1024;

/// Upper bound of raw sample bytes fed to `zstd::dict::from_samples`. Enough
/// variety to build a useful shared dictionary without blowing up RAM.
pub const DICT_SAMPLES_CAP: usize = 16 * 1024 * 1024;
/// Max bytes read per file when gathering samples.
pub const DICT_SAMPLE_PER_FILE: usize = 256 * 1024;
/// Target zstd dictionary size. 110 KiB is the zstd CLI default.
pub const DICT_TARGET: usize = 112_640;
/// Training is only attempted if we gather at least this many sample bytes.
pub const DICT_MIN_SAMPLES: usize = 1024 * 1024;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    File = 0,
    Dir = 1,
    Symlink = 2,
}

impl EntryKind {
    fn from_u8(v: u8) -> Result<Self> {
        Ok(match v {
            0 => Self::File,
            1 => Self::Dir,
            2 => Self::Symlink,
            _ => return Err(anyhow!("unknown entry kind: {v}")),
        })
    }
}

pub struct EntryHeader {
    pub kind: EntryKind,
    pub mode: u32,
    pub size: u64,
    pub path: String,
    pub link_target: String,
}

impl EntryHeader {
    pub fn write_to<W: Write>(&self, w: &mut W) -> Result<()> {
        w.write_u8(self.kind as u8)?;
        w.write_u32::<LittleEndian>(self.mode)?;
        w.write_u64::<LittleEndian>(self.size)?;
        let pb = self.path.as_bytes();
        w.write_u16::<LittleEndian>(pb.len() as u16)?;
        w.write_all(pb)?;
        let lb = self.link_target.as_bytes();
        w.write_u16::<LittleEndian>(lb.len() as u16)?;
        w.write_all(lb)?;
        Ok(())
    }

    pub fn read_from<R: Read>(r: &mut R) -> Result<Option<Self>> {
        let kind_byte = match r.read_u8() {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let kind = EntryKind::from_u8(kind_byte)?;
        let mode = r.read_u32::<LittleEndian>()?;
        let size = r.read_u64::<LittleEndian>()?;
        let plen = r.read_u16::<LittleEndian>()? as usize;
        let mut pbuf = vec![0u8; plen];
        r.read_exact(&mut pbuf)?;
        let path = String::from_utf8(pbuf).context("path not utf8")?;
        let llen = r.read_u16::<LittleEndian>()? as usize;
        let mut lbuf = vec![0u8; llen];
        r.read_exact(&mut lbuf)?;
        let link_target = String::from_utf8(lbuf).context("link not utf8")?;
        Ok(Some(Self { kind, mode, size, path, link_target }))
    }
}

/// Preprocessor flags (bitmask) applied between the archive body and the
/// compressor. Bit 0 = REP (byte-level, saturates past ~512 MiB).
/// Bit 1 = SREP (block-sampled, scales to multi-GB inputs). Both emit the
/// same wire format, so a single decoder (RepReader) handles either.
/// Bit 2 = FEATURE_CRC32 — each File entry is followed by u32 LE crc32 of
/// its raw contents. Lives in the same byte because old readers only mask
/// for REP|SREP, so a new archive appears "no preproc" to them — but the
/// trailing u32 per file then desyncs them. Forward-incompatible with
/// SYC4-era readers that pre-date this flag. Default ON since v0.2.
pub const PREPROC_REP: u8 = 0x01;
pub const PREPROC_SREP: u8 = 0x02;
pub const FEATURE_CRC32: u8 = 0x04;
/// Archive-level comment (UTF-8, up to 64 KiB) stored inline in the preamble
/// after the flags byte. Old readers will desync on dict_len like with CRC.
pub const FEATURE_COMMENT: u8 = 0x08;
/// Extended per-entry hash (non-crc32). When set alongside FEATURE_CRC32, a
/// u8 `hash_algo` sits right after the optional comment, and each File entry
/// is followed by a trailer whose size depends on the algo.
pub const FEATURE_HASH_ALGO: u8 = 0x10;
/// Preserve Linux extended attributes (user.*, system.*, security.*). When
/// set, every entry header is immediately followed by an xattr block:
///   u16 n_attrs, then n_attrs × (u16 name_len, name_bytes, u32 val_len, val_bytes).
/// Emitted before the file body (and before any hash trailer). On non-unix
/// platforms the encoder emits `n_attrs=0` so the format stays consistent.
pub const FEATURE_XATTRS: u8 = 0x20;
/// Delta pre-filter applied to the body stream between the archive and the
/// compressor (cheap win on PCM / rasters). When set, the preamble carries
/// an extra u8 `delta_stride` (1, 2, or 4) right before `dict_len`. Mutually
/// exclusive with REP/SREP and with the PPMd backend (enforced by cmd_add).
pub const FEATURE_DELTA: u8 = 0x40;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HashAlgo {
    Crc32 = 1,
    Xxh3 = 2,
    Blake3 = 3,
}

impl HashAlgo {
    pub fn from_u8(v: u8) -> Result<Self> {
        Ok(match v {
            1 => Self::Crc32,
            2 => Self::Xxh3,
            3 => Self::Blake3,
            _ => return Err(anyhow!("unknown hash algo id: {v}")),
        })
    }
    pub fn trailer_bytes(self) -> usize {
        match self {
            Self::Crc32 => 4,
            Self::Xxh3 => 8,
            Self::Blake3 => 32,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::Crc32 => "crc32",
            Self::Xxh3 => "xxh3",
            Self::Blake3 => "blake3",
        }
    }
}

pub enum EntryHasher {
    Crc32(crc32fast::Hasher),
    Xxh3(twox_hash::XxHash3_64),
    Blake3(Box<blake3::Hasher>),
}

impl EntryHasher {
    pub fn new(algo: HashAlgo) -> Self {
        match algo {
            HashAlgo::Crc32 => Self::Crc32(crc32fast::Hasher::new()),
            HashAlgo::Xxh3 => Self::Xxh3(twox_hash::XxHash3_64::new()),
            HashAlgo::Blake3 => Self::Blake3(Box::new(blake3::Hasher::new())),
        }
    }
    pub fn update(&mut self, data: &[u8]) {
        match self {
            Self::Crc32(h) => h.update(data),
            Self::Xxh3(h) => {
                use std::hash::Hasher;
                h.write(data);
            }
            Self::Blake3(h) => { h.update(data); }
        }
    }
    pub fn finalize_into(self, out: &mut [u8]) {
        use std::hash::Hasher;
        match self {
            Self::Crc32(h) => {
                let v = h.finalize().to_le_bytes();
                out[..4].copy_from_slice(&v);
            }
            Self::Xxh3(h) => {
                let v = h.finish().to_le_bytes();
                out[..8].copy_from_slice(&v);
            }
            Self::Blake3(h) => {
                let d = h.finalize();
                out[..32].copy_from_slice(d.as_bytes());
            }
        }
    }
}

/// File preamble (NOT compressed): magic + u8 backend + u8 preproc_flags +
/// u32 dict_len + dict bytes. Dict only meaningful for zstd. When backend
/// = Ppmd, a trailing (u8 order, u32 mem_mb) is appended after the dict.
pub fn write_preamble<W: Write>(
    w: &mut W,
    backend: Backend,
    preproc: u8,
    dict: &[u8],
    ppmd: Option<PpmdParams>,
    comment: Option<&str>,
    hash_algo: Option<HashAlgo>,
    delta_stride: Option<u8>,
) -> Result<()> {
    w.write_all(MAGIC)?;
    w.write_u8(backend as u8)?;
    let has_comment = preproc & FEATURE_COMMENT != 0 && comment.is_some();
    w.write_u8(preproc)?;
    if has_comment {
        let c = comment.unwrap().as_bytes();
        if c.len() > u16::MAX as usize {
            return Err(anyhow!("comment too long: {} bytes (max 65535)", c.len()));
        }
        w.write_u16::<LittleEndian>(c.len() as u16)?;
        w.write_all(c)?;
    }
    if preproc & FEATURE_HASH_ALGO != 0 {
        let algo = hash_algo.ok_or_else(|| anyhow!("FEATURE_HASH_ALGO set without algo"))?;
        w.write_u8(algo as u8)?;
    }
    if preproc & FEATURE_DELTA != 0 {
        let s = delta_stride.ok_or_else(|| anyhow!("FEATURE_DELTA set without stride"))?;
        w.write_u8(s)?;
    }
    w.write_u32::<LittleEndian>(dict.len() as u32)?;
    if !dict.is_empty() {
        w.write_all(dict)?;
    }
    if backend == Backend::Ppmd {
        let p = ppmd.ok_or_else(|| anyhow!("ppmd backend requires ppmd params"))?;
        w.write_u8(p.order)?;
        w.write_u32::<LittleEndian>(p.mem_mb)?;
    }
    Ok(())
}

pub fn read_preamble<R: Read>(
    r: &mut R,
) -> Result<(Backend, u8, Vec<u8>, Option<PpmdParams>, Option<String>, Option<HashAlgo>, Option<u8>)> {
    let mut buf = [0u8; 4];
    r.read_exact(&mut buf)?;
    if &buf != MAGIC {
        return Err(anyhow!(
            "bad magic: not a syc v4 archive (got {:?})",
            std::str::from_utf8(&buf).unwrap_or("?")
        ));
    }
    let backend = Backend::from_u8(r.read_u8()?)?;
    let preproc = r.read_u8()?;
    let comment = if preproc & FEATURE_COMMENT != 0 {
        let clen = r.read_u16::<LittleEndian>()? as usize;
        let mut cbuf = vec![0u8; clen];
        r.read_exact(&mut cbuf)?;
        Some(String::from_utf8(cbuf).context("comment not utf8")?)
    } else {
        None
    };
    let hash_algo = if preproc & FEATURE_HASH_ALGO != 0 {
        Some(HashAlgo::from_u8(r.read_u8()?)?)
    } else if preproc & FEATURE_CRC32 != 0 {
        Some(HashAlgo::Crc32)
    } else {
        None
    };
    let delta_stride = if preproc & FEATURE_DELTA != 0 {
        let s = r.read_u8()?;
        if !crate::delta::is_valid_stride(s) {
            return Err(anyhow!("invalid delta stride {s} (expected 1, 2, or 4)"));
        }
        Some(s)
    } else {
        None
    };
    let dict_len = r.read_u32::<LittleEndian>()? as usize;
    let mut dict = vec![0u8; dict_len];
    if dict_len > 0 {
        r.read_exact(&mut dict)?;
    }
    let ppmd = if backend == Backend::Ppmd {
        let order = r.read_u8()?;
        let mem_mb = r.read_u32::<LittleEndian>()?;
        Some(PpmdParams { order, mem_mb })
    } else {
        None
    };
    Ok((backend, preproc, dict, ppmd, comment, hash_algo, delta_stride))
}

/// Gather up to DICT_SAMPLES_CAP bytes of sample data from regular files in
/// `entries`. Each file contributes at most DICT_SAMPLE_PER_FILE bytes from
/// its head. Returns one Vec<u8> per sample (ownership simplifies the call to
/// zstd::dict::from_samples).
pub fn gather_samples(entries: &[(PathBuf, PathBuf)]) -> Result<Vec<Vec<u8>>> {
    let mut samples: Vec<Vec<u8>> = Vec::new();
    let mut total: usize = 0;
    for (full, _rel) in entries {
        if total >= DICT_SAMPLES_CAP {
            break;
        }
        let meta = match fs::symlink_metadata(full) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !meta.is_file() || meta.len() == 0 {
            continue;
        }
        let want = DICT_SAMPLE_PER_FILE.min((DICT_SAMPLES_CAP - total).max(1));
        let mut f = match File::open(full) {
            Ok(f) => f,
            Err(_) => continue,
        };
        let mut buf = vec![0u8; want];
        let mut read = 0;
        while read < want {
            match f.read(&mut buf[read..]) {
                Ok(0) => break,
                Ok(n) => read += n,
                Err(_) => break,
            }
        }
        if read == 0 {
            continue;
        }
        buf.truncate(read);
        total += read;
        samples.push(buf);
    }
    Ok(samples)
}

/// Train a zstd dictionary from samples. Returns empty Vec on any soft error
/// (too few samples, zstd refusal) — caller falls back to no-dict mode.
/// `target` is the desired dict size in bytes; see `adaptive_dict_target`.
pub fn train_dict(samples: &[Vec<u8>], target: usize) -> Vec<u8> {
    let total: usize = samples.iter().map(|s| s.len()).sum();
    if total < DICT_MIN_SAMPLES || samples.len() < 7 {
        return Vec::new();
    }
    match zstd::dict::from_samples(samples, target) {
        Ok(d) => d,
        Err(_) => Vec::new(),
    }
}

/// Pick a zstd dict size based on raw corpus size. Small corpora get a
/// compact dict (avoids wasting ratio on a dict that's itself a sizable
/// fraction of the payload); large corpora get more room for shared
/// vocabulary. Values chosen against `test-files.tar` subsets: smaller
/// dicts hurt >200 MiB corpora (−0.5 % ratio), larger dicts waste space
/// on <20 MiB ones.
pub fn adaptive_dict_target(total_raw: u64) -> usize {
    const MB: u64 = 1024 * 1024;
    match total_raw {
        0..=67_108_863 => 64 * 1024,        // <64 MiB → 64 KiB
        x if x < 512 * MB => DICT_TARGET,   // 64..512 MiB → 110 KiB (default)
        x if x < 2 * 1024 * MB => 192 * 1024, // 512 MiB..2 GiB → 192 KiB
        _ => 256 * 1024,                    // ≥2 GiB → 256 KiB
    }
}

pub fn collect_entries(root: &Path) -> Result<Vec<(PathBuf, PathBuf)>> {
    let mut out = Vec::new();
    let root_abs = fs::canonicalize(root)
        .with_context(|| format!("canonicalize {}", root.display()))?;
    for entry in walkdir::WalkDir::new(&root_abs).follow_links(false) {
        let entry = entry?;
        let full = entry.path().to_path_buf();
        let rel = full.strip_prefix(&root_abs)?.to_path_buf();
        if rel.as_os_str().is_empty() {
            continue;
        }
        out.push((full, rel));
    }
    Ok(out)
}

/// "Solid" ordering inspired by 7-zip/RAR: group similar files together so the
/// compressor can share dictionary state across them. Dirs go first (empty
/// bodies — cheap). Symlinks next. Files ordered by (extension, size, path)
/// so same-ext-same-size blobs sit next to each other in the stream.
/// `sort_by_cached_key` computes each key once; no O(N log N) stat calls.
pub fn solid_sort(entries: &mut Vec<(PathBuf, PathBuf)>) {
    entries.sort_by_cached_key(|(full, rel)| sort_key(full, rel));
}

#[derive(PartialEq, Eq, PartialOrd, Ord, Clone)]
enum KindRank {
    Dir = 0,
    Symlink = 1,
    File = 2,
}

fn sort_key(full: &Path, rel: &Path) -> (KindRank, String, String, u64, String) {
    let meta = fs::symlink_metadata(full).ok();
    let (kind, size) = match &meta {
        Some(m) if m.file_type().is_symlink() => (KindRank::Symlink, 0u64),
        Some(m) if m.is_dir() => (KindRank::Dir, 0u64),
        Some(m) => (KindRank::File, m.len()),
        None => (KindRank::File, 0u64),
    };
    let ext = rel
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    // Parent directory first: files that share a subtree (and therefore are
    // more likely to share templates/headers) end up adjacent in the stream.
    let parent = rel
        .parent()
        .map(|p| p.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let path = rel.to_string_lossy().to_lowercase();
    (kind, ext, parent, size, path)
}

pub fn pack_entry<W: Write>(
    full: &Path,
    rel: &Path,
    out: &mut W,
    buf: &mut [u8],
    hash_algo: Option<HashAlgo>,
    with_xattrs: bool,
) -> Result<()> {
    let meta = fs::symlink_metadata(full)
        .with_context(|| format!("stat {}", full.display()))?;
    let rel_str = rel.to_string_lossy().replace('\\', "/");

    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode()
    };
    #[cfg(not(unix))]
    let mode = 0o644u32;

    if meta.file_type().is_symlink() {
        let target = fs::read_link(full)?.to_string_lossy().into_owned();
        let header = EntryHeader {
            kind: EntryKind::Symlink,
            mode,
            size: 0,
            path: rel_str,
            link_target: target,
        };
        header.write_to(out)?;
        if with_xattrs { write_xattrs_block(out, full, true)?; }
    } else if meta.is_dir() {
        let header = EntryHeader {
            kind: EntryKind::Dir,
            mode,
            size: 0,
            path: rel_str,
            link_target: String::new(),
        };
        header.write_to(out)?;
        if with_xattrs { write_xattrs_block(out, full, false)?; }
    } else {
        let size = meta.len();
        let header = EntryHeader {
            kind: EntryKind::File,
            mode,
            size,
            path: rel_str,
            link_target: String::new(),
        };
        header.write_to(out)?;
        if with_xattrs { write_xattrs_block(out, full, false)?; }
        let f = File::open(full)
            .with_context(|| format!("open {}", full.display()))?;
        let mut r = BufReader::with_capacity(IO_BUF, f);
        let mut remaining = size;
        let mut hasher = hash_algo.map(EntryHasher::new);
        while remaining > 0 {
            let want = remaining.min(buf.len() as u64) as usize;
            let n = r.read(&mut buf[..want])?;
            if n == 0 {
                return Err(anyhow!("unexpected EOF reading {}", full.display()));
            }
            if let Some(h) = hasher.as_mut() { h.update(&buf[..n]); }
            out.write_all(&buf[..n])?;
            remaining -= n as u64;
        }
        if let (Some(h), Some(algo)) = (hasher, hash_algo) {
            let mut trailer = [0u8; 32];
            let tb = algo.trailer_bytes();
            h.finalize_into(&mut trailer[..tb]);
            out.write_all(&trailer[..tb])?;
        }
    }
    Ok(())
}

pub fn unpack_entry<R: Read>(
    r: &mut R,
    dest_root: &Path,
    header: &EntryHeader,
    buf: &mut [u8],
    hash_algo: Option<HashAlgo>,
    with_xattrs: bool,
) -> Result<()> {
    let safe_rel = sanitize_rel(&header.path)?;
    let full = dest_root.join(&safe_rel);

    // xattrs are emitted immediately after the header, before any body. Read
    // them into a buffer now so we can apply them once the dest path exists.
    let xattrs = if with_xattrs {
        Some(read_xattrs_block(r)?)
    } else {
        None
    };

    match header.kind {
        EntryKind::Dir => {
            fs::create_dir_all(&full)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(&full, fs::Permissions::from_mode(header.mode));
            }
            if let Some(attrs) = &xattrs { apply_xattrs(&full, attrs, false); }
        }
        EntryKind::Symlink => {
            if let Some(p) = full.parent() {
                fs::create_dir_all(p)?;
            }
            if full.exists() || full.symlink_metadata().is_ok() {
                let _ = fs::remove_file(&full);
            }
            #[cfg(unix)]
            std::os::unix::fs::symlink(&header.link_target, &full)?;
            #[cfg(not(unix))]
            return Err(anyhow!("symlinks not supported on this platform"));
            if let Some(attrs) = &xattrs { apply_xattrs(&full, attrs, true); }
        }
        EntryKind::File => {
            // Parent dirs should already exist (Dir entries come first in
            // solid-sorted streams). Only create on demand if missing.
            let f = match File::create(&full) {
                Ok(f) => f,
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    if let Some(p) = full.parent() {
                        fs::create_dir_all(p)?;
                    }
                    File::create(&full)
                        .with_context(|| format!("create {}", full.display()))?
                }
                Err(e) => return Err(e).with_context(|| format!("create {}", full.display())),
            };
            let mut w = BufWriter::with_capacity(IO_BUF, f);
            let mut remaining = header.size;
            let mut hasher = hash_algo.map(EntryHasher::new);
            while remaining > 0 {
                let want = remaining.min(buf.len() as u64) as usize;
                let n = r.read(&mut buf[..want])?;
                if n == 0 {
                    return Err(anyhow!("unexpected EOF in archive body"));
                }
                if let Some(h) = hasher.as_mut() { h.update(&buf[..n]); }
                w.write_all(&buf[..n])?;
                remaining -= n as u64;
            }
            w.flush()?;
            if let (Some(h), Some(algo)) = (hasher, hash_algo) {
                let tb = algo.trailer_bytes();
                let mut stored = [0u8; 32];
                r.read_exact(&mut stored[..tb])?;
                let mut computed = [0u8; 32];
                h.finalize_into(&mut computed[..tb]);
                if stored[..tb] != computed[..tb] {
                    return Err(anyhow!(
                        "{} mismatch on {}",
                        algo.name(), header.path
                    ));
                }
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(&full, fs::Permissions::from_mode(header.mode));
            }
            if let Some(attrs) = &xattrs { apply_xattrs(&full, attrs, false); }
        }
    }
    Ok(())
}

pub type XattrPair = (Vec<u8>, Vec<u8>);

/// Write xattrs block for `path`. `is_symlink=true` means use lgetxattr/etc
/// so the link itself (not its target) is queried. On non-unix and on any
/// soft error, emits an empty block (`n_attrs=0`) so the format stays stable.
#[cfg(unix)]
pub fn write_xattrs_block<W: Write>(w: &mut W, path: &Path, is_symlink: bool) -> Result<()> {
    let pairs = gather_xattrs(path, is_symlink).unwrap_or_default();
    w.write_u16::<LittleEndian>(pairs.len().min(u16::MAX as usize) as u16)?;
    for (name, val) in pairs.iter().take(u16::MAX as usize) {
        let nlen = name.len().min(u16::MAX as usize) as u16;
        w.write_u16::<LittleEndian>(nlen)?;
        w.write_all(&name[..nlen as usize])?;
        let vlen = val.len().min(u32::MAX as usize) as u32;
        w.write_u32::<LittleEndian>(vlen)?;
        w.write_all(&val[..vlen as usize])?;
    }
    Ok(())
}

#[cfg(not(unix))]
pub fn write_xattrs_block<W: Write>(w: &mut W, _path: &Path, _is_symlink: bool) -> Result<()> {
    w.write_u16::<LittleEndian>(0)?;
    Ok(())
}

#[cfg(unix)]
fn gather_xattrs(path: &Path, is_symlink: bool) -> Result<Vec<XattrPair>> {
    use std::os::unix::ffi::OsStrExt;
    if is_symlink {
        return Ok(Vec::new());
    }
    let mut out: Vec<XattrPair> = Vec::new();
    let names = match xattr::list(path) {
        Ok(it) => it,
        Err(_) => return Ok(Vec::new()),
    };
    for name in names {
        let nb = name.as_bytes().to_vec();
        match xattr::get(path, &name) {
            Ok(Some(v)) => out.push((nb, v)),
            _ => continue,
        }
    }
    Ok(out)
}

pub fn read_xattrs_block<R: Read>(r: &mut R) -> Result<Vec<XattrPair>> {
    let n = r.read_u16::<LittleEndian>()? as usize;
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let nlen = r.read_u16::<LittleEndian>()? as usize;
        let mut name = vec![0u8; nlen];
        r.read_exact(&mut name)?;
        let vlen = r.read_u32::<LittleEndian>()? as usize;
        let mut val = vec![0u8; vlen];
        r.read_exact(&mut val)?;
        out.push((name, val));
    }
    Ok(out)
}

/// Apply xattrs to `path`. Best-effort: individual failures (e.g. permission
/// denied on `security.*` attrs) are silently skipped rather than aborting
/// the extract. Symlinks: currently no-op (see `gather_xattrs`).
#[cfg(unix)]
pub fn apply_xattrs(path: &Path, attrs: &[XattrPair], is_symlink: bool) {
    use std::os::unix::ffi::OsStrExt;
    if is_symlink {
        return;
    }
    for (name, val) in attrs {
        let name_str = std::ffi::OsStr::from_bytes(name);
        let _ = xattr::set(path, name_str, val);
    }
}

#[cfg(not(unix))]
pub fn apply_xattrs(_path: &Path, _attrs: &[XattrPair], _is_symlink: bool) {}

fn sanitize_rel(p: &str) -> Result<PathBuf> {
    let path = PathBuf::from(p);
    if path.is_absolute() {
        return Err(anyhow!("absolute path in archive: {p}"));
    }
    for comp in path.components() {
        use std::path::Component;
        match comp {
            Component::ParentDir => return Err(anyhow!("parent dir traversal in archive: {p}")),
            Component::Prefix(_) | Component::RootDir => {
                return Err(anyhow!("invalid path component in archive: {p}"))
            }
            _ => {}
        }
    }
    Ok(path)
}
