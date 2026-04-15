use anyhow::{anyhow, Result};
use std::path::PathBuf;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Default)]
pub struct Opts {
    pub level: i32,
    pub threads: u32,
    pub to: Option<PathBuf>,
    pub find: Option<String>,
    pub verbose: bool,
    pub summary: bool,
    pub force: bool,
    pub store: bool,
    pub nochecksum: bool,
    pub nosort: bool,
    pub dict: bool,
    pub nodict: bool,
    pub nolong: bool,
    pub nopreproc: bool,
    pub bcj: Option<String>,
    pub exec_ok: Option<String>,
    pub exec_error: Option<String>,
    pub exclude: Vec<String>,
    pub minsize: Option<u64>,
    pub maxsize: Option<u64>,
    pub filelist: Option<PathBuf>,
    pub datefrom: Option<i64>,
    pub dateto: Option<i64>,
    pub chunk_mib: Option<u64>,
    pub comment: Option<String>,
    pub hash: Option<String>,
    pub xattrs: bool,
    pub append: bool,
    pub delta: Option<u8>,
    pub route: bool,
    pub dedup: bool,
    pub noprogress: bool,
}

#[derive(Debug)]
pub enum Cmd {
    Add { archive: PathBuf, sources: Vec<PathBuf>, opts: Opts },
    Extract { archive: PathBuf, opts: Opts },
    List { archive: PathBuf, opts: Opts },
    Test { archive: PathBuf, opts: Opts },
    Compare { left: PathBuf, right: PathBuf, opts: Opts },
    Dedupe { root: PathBuf, opts: Opts },
    Verify { archive: PathBuf, source: PathBuf, opts: Opts },
    Help { topic: Option<String> },
    Banner,
}

pub fn parse(args: Vec<String>) -> Result<Cmd> {
    let mut args = args.into_iter();
    let _prog = args.next();
    let cmd = match args.next() {
        Some(c) => c,
        None => return Ok(Cmd::Banner),
    };

    if cmd == "h" || cmd == "help" || cmd == "-h" || cmd == "--help" {
        return Ok(Cmd::Help { topic: args.next() });
    }
    if cmd == "-v" || cmd == "--version" {
        println!("syc v{VERSION}");
        std::process::exit(0);
    }

    let rest: Vec<String> = args.collect();

    match cmd.as_str() {
        "a" | "add" => {
            let (positional, opts) = split_flags(&rest)?;
            if positional.is_empty() {
                return Err(anyhow!("a: needs <archive> [<source>...]"));
            }
            if positional.len() == 1 && opts.filelist.is_none() {
                return Err(anyhow!("a: needs at least one source or -filelist FILE"));
            }
            let archive = PathBuf::from(&positional[0]);
            let sources: Vec<PathBuf> = positional[1..].iter().map(PathBuf::from).collect();
            Ok(Cmd::Add { archive, sources, opts })
        }
        "x" | "extract" => {
            let (positional, opts) = split_flags(&rest)?;
            if positional.is_empty() {
                return Err(anyhow!("x: needs <archive>"));
            }
            Ok(Cmd::Extract {
                archive: PathBuf::from(&positional[0]),
                opts,
            })
        }
        "l" | "list" => {
            let (positional, opts) = split_flags(&rest)?;
            if positional.is_empty() {
                return Err(anyhow!("l: needs <archive>"));
            }
            Ok(Cmd::List {
                archive: PathBuf::from(&positional[0]),
                opts,
            })
        }
        "t" | "test" => {
            let (positional, opts) = split_flags(&rest)?;
            if positional.is_empty() {
                return Err(anyhow!("t: needs <archive>"));
            }
            Ok(Cmd::Test {
                archive: PathBuf::from(&positional[0]),
                opts,
            })
        }
        "v" | "verify" => {
            let (positional, opts) = split_flags(&rest)?;
            if positional.len() < 2 {
                return Err(anyhow!("v: needs <archive> <source_dir>"));
            }
            Ok(Cmd::Verify {
                archive: PathBuf::from(&positional[0]),
                source: PathBuf::from(&positional[1]),
                opts,
            })
        }
        "d" | "dedupe" => {
            let (positional, opts) = split_flags(&rest)?;
            if positional.is_empty() {
                return Err(anyhow!("d: needs <dir>"));
            }
            Ok(Cmd::Dedupe {
                root: PathBuf::from(&positional[0]),
                opts,
            })
        }
        "c" | "compare" => {
            let (positional, opts) = split_flags(&rest)?;
            if positional.len() < 2 {
                return Err(anyhow!("c: needs <dirA> <dirB>"));
            }
            Ok(Cmd::Compare {
                left: PathBuf::from(&positional[0]),
                right: PathBuf::from(&positional[1]),
                opts,
            })
        }
        other => Err(anyhow!("unknown command: {other}   (try `syc h`)")),
    }
}

fn split_flags(args: &[String]) -> Result<(Vec<String>, Opts)> {
    let mut positional = Vec::new();
    let mut opts = Opts {
        level: 5,
        threads: 0,
        ..Default::default()
    };
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if a == "-" {
            positional.push(a.clone());
            i += 1;
            continue;
        }
        if let Some(flag) = a.strip_prefix('-') {
            match flag {
                "verbose" => opts.verbose = true,
                "summary" => opts.summary = true,
                "force" => opts.force = true,
                "store" => opts.store = true,
                "nochecksum" => opts.nochecksum = true,
                "nosort" => opts.nosort = true,
                "dict" => opts.dict = true,
                "nodict" => opts.nodict = true,
                "xattrs" => opts.xattrs = true,
                "append" => opts.append = true,
                "route" => opts.route = true,
                "dedup" => opts.dedup = true,
                "noprogress" | "noeta" => opts.noprogress = true,
                "nolong" => opts.nolong = true,
                "nopreproc" => opts.nopreproc = true,
                "level" | "m" => {
                    opts.level = arg_val(args, &mut i, flag)?.parse()?;
                }
                "threads" | "j" => {
                    opts.threads = arg_val(args, &mut i, flag)?.parse()?;
                }
                "to" => {
                    opts.to = Some(PathBuf::from(arg_val(args, &mut i, flag)?));
                }
                "find" => {
                    opts.find = Some(arg_val(args, &mut i, flag)?.to_string());
                }
                "bcj" => {
                    opts.bcj = Some(arg_val(args, &mut i, flag)?.to_string());
                }
                "exec_ok" => {
                    opts.exec_ok = Some(arg_val(args, &mut i, flag)?.to_string());
                }
                "exec_error" => {
                    opts.exec_error = Some(arg_val(args, &mut i, flag)?.to_string());
                }
                "exclude" => {
                    opts.exclude.push(arg_val(args, &mut i, flag)?.to_string());
                }
                "minsize" => {
                    opts.minsize = Some(arg_val(args, &mut i, flag)?.parse()?);
                }
                "maxsize" => {
                    opts.maxsize = Some(arg_val(args, &mut i, flag)?.parse()?);
                }
                "filelist" => {
                    opts.filelist = Some(PathBuf::from(arg_val(args, &mut i, flag)?));
                }
                "datefrom" => {
                    opts.datefrom = Some(parse_date_arg(arg_val(args, &mut i, flag)?)?);
                }
                "dateto" => {
                    opts.dateto = Some(parse_date_arg(arg_val(args, &mut i, flag)?)?);
                }
                "chunk" => {
                    opts.chunk_mib = Some(arg_val(args, &mut i, flag)?.parse()?);
                }
                "comment" => {
                    opts.comment = Some(arg_val(args, &mut i, flag)?.to_string());
                }
                "hash" => {
                    opts.hash = Some(arg_val(args, &mut i, flag)?.to_string());
                }
                "delta" => {
                    let v: u8 = arg_val(args, &mut i, flag)?.parse()?;
                    if !matches!(v, 1 | 2 | 4) {
                        return Err(anyhow!("-delta: stride must be 1, 2, or 4 (got {v})"));
                    }
                    opts.delta = Some(v);
                }
                _ => return Err(anyhow!("unknown flag: -{flag}")),
            }
        } else {
            positional.push(a.clone());
        }
        i += 1;
    }
    Ok((positional, opts))
}

/// Parse a date-ish argument. Accepts UNIX timestamp (all digits) or a simple
/// `YYYY-MM-DD` that's interpreted as UTC midnight. Uses Howard Hinnant's
/// civil-from-days algorithm to avoid a chrono dep.
fn parse_date_arg(s: &str) -> Result<i64> {
    let s = s.trim();
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()) {
        return Ok(s.parse()?);
    }
    let parts: Vec<&str> = s.split('-').collect();
    if parts.len() != 3 {
        return Err(anyhow!("bad date '{s}' (expected YYYY-MM-DD or UNIX seconds)"));
    }
    let y: i32 = parts[0].parse().map_err(|_| anyhow!("bad year in '{s}'"))?;
    let m: u32 = parts[1].parse().map_err(|_| anyhow!("bad month in '{s}'"))?;
    let d: u32 = parts[2].parse().map_err(|_| anyhow!("bad day in '{s}'"))?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return Err(anyhow!("bad date '{s}' (month/day out of range)"));
    }
    let yy = if m <= 2 { y - 1 } else { y };
    let era = if yy >= 0 { yy / 400 } else { (yy - 399) / 400 };
    let yoe = (yy - era * 400) as u32;
    let mm = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mm + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era as i64 * 146097 + doe as i64 - 719468;
    Ok(days * 86400)
}

fn arg_val<'a>(args: &'a [String], i: &mut usize, flag: &str) -> Result<&'a str> {
    *i += 1;
    args.get(*i)
        .map(|s| s.as_str())
        .ok_or_else(|| anyhow!("flag -{flag} needs a value"))
}

pub fn banner() {
    println!(
        "\
syc v{VERSION} — streaming archiver + zstd compressor (pure-ish Rust)
Tuned for modest hardware  (C) 2026

Help     : syc h <command>    (single)   syc h h   (full)
Core     : a, x, l, t, v, c, d
Info     : h, v

  a   add        pack sources into archive
  x   extract    unpack archive (stream, no seek)
  l   list       show entries
  t   test       decompress & verify CRCs (no extract)
  v   verify     stream-compare archive against live source dir
  c   compare    diff two directories by content (size+crc32)
  d   dedupe     report duplicate files in a tree (size+crc32)
  h   help       this screen, or detail for a command
  v   version    print version

Switches : -m N (alias -level)  -threads N  -to DIR  -find TEXT
           -verbose  -summary  -force  -store  -nochecksum
           -nosort   -dict   -nolong   -nopreproc
           -bcj TYPE (x86|arm|armt|ia64|sparc|ppc|off)
           -exec_ok CMD   -exec_error CMD
           -exclude PATTERN (repeatable)  -minsize N  -maxsize N
           -filelist FILE  -datefrom YYYY-MM-DD  -dateto YYYY-MM-DD
           -chunk N_MiB  (split output into archive.001, .002, ...)
           -comment TEXT  (archive-level UTF-8 tag, shown by `l`)
           -hash ALGO    (crc32|xxh3|blake3, default crc32)
           -xattrs       preserve Linux extended attributes (user.*, etc.)
           -append       append a new compressed frame to an existing archive
                         (antiransomware: existing bytes are never rewritten)
           -delta N      delta pre-filter stride (1|2|4), for PCM / rasters
           -route        split pre-compressed media (jpg/mp4/zip/...) into
                         a level-0 frame, saves CPU without losing ratio
           -dedup        pack identical files once; duplicates become hardlink
                         entries (extracted as hardlinks, fall back to copy)
           -noprogress   suppress the progress bar (auto-off when stderr
                         isn't a TTY; alias: -noeta)
           -nodict       force dict training off (opposite of -dict)

Env      : SYC_BACKEND=ppmd   force PPMd7 (experimental, needs Dict/LZP)
           SYC_PPMD_ORDER=N   PPMd context order (2..16, default 8..16)
           SYC_PPMD_MEM_MB=N  PPMd context memory, MiB
           SYC_DICT=BYTES     LZMA dictionary size override
           SYC_LC/LP/PB/NICE  LZMA lc/lp/pb/nice_len overrides
           SYC_BCJ=x86|arm|armt|ia64|sparc|ppc  BCJ pre-filter (LZMA only)
",
        VERSION = VERSION
    );
}

pub fn help(topic: Option<String>) {
    match topic.as_deref() {
        None | Some("h") | Some("help") => {
            banner();
            println!(
"Examples:
  syc a data.syc ./mydir -m 9 -threads 4
  syc a data.syc file1 dir2 dir3 -summary
  syc x data.syc -to ./restored
  syc l data.syc -find '.md'
  syc t data.syc
  tar c dir | syc a - -m 3 > archive.syc
  cat archive.syc | syc x - -to restored
");
        }
        Some("a") | Some("add") => println!(
"CMD a               (add) pack sources into a .syc archive
                    Formato streaming SYC1: header + bytes por entrada.
                    Preserva modo Unix y symlinks. Sin índice final.
-m N / -level N     syc level 0..=10, default 5 (sweet spot)
                    0..4  = zstd (rápido, suficiente para ARC -m1..-m4)
                    5..10 = lzma (preset 9|EXTREME tuneado para texto)
-threads N          worker threads (0 = single, default 0)
-store              Store mode: no compression (level 0, pass-through)
-nopreproc          Desactiva REP/SREP (auto-enabled para datasets >128 MiB)
-bcj TYPE           BCJ pre-filter para LZMA (x86|arm|armt|ia64|sparc|ppc|off)
                    Auto: si >30% de los samples son ELF/PE x86 → x86
-nolong             Desactiva long-range matching en zstd
-dict               Entrena diccionario zstd (~110 KiB) desde samples
-nosort             Sin solid-sort (pack en orden de walkdir)
-nochecksum         Disable per-file hash (default ON since v0.2)
-hash ALGO          Per-file hash: crc32 (default, 4B) | xxh3 (8B) | blake3 (32B)
                    blake3 is cryptographic; xxh3 is fastest; crc32 is smallest.
-summary            One-line summary at end
-verbose            Print each entry packed
-append             Append a new compressed frame to an existing archive.
                    Inherits backend/dict/hash/xattrs from the original
                    preamble; existing bytes are never rewritten. Not
                    compatible with -chunk, stdout, ppmd backend, or
                    REP/SREP preprocessors.
"
        ),
        Some("x") | Some("extract") => println!(
"CMD x               Extract archive into a directory (streaming, no seek)
-to DIR             Destination dir (required, created if missing)
-force              Overwrite existing files
-summary            One-line summary at end
-verbose            Print each entry extracted
"
        ),
        Some("l") | Some("list") => println!(
"CMD l               List entries in the archive
-find TEXT          Filter paths containing TEXT (case-insensitive)
-summary            Show totals only
"
        ),
        Some("t") | Some("test") => println!(
"CMD t               Test archive: decompress & walk all entries (no write)
-verbose            Print every entry while testing
"
        ),
        Some("d") | Some("dedupe") => println!(
"CMD d               Report duplicate files in a directory tree
                    Groups files by (size, crc32). Prints each group with a
                    keeper (first) and the rest as duplicates. Read-only —
                    never deletes anything. Wasted bytes reported at end.
-verbose            List every duplicate pair
-summary            Totals only
"
        ),
        Some("v") | Some("verify") => println!(
"CMD v               Verify archive byte-for-byte against a live source dir
                    For each File entry, read the corresponding path under
                    <source_dir> and compare byte-by-byte with the archive
                    stream. Stops on first mismatch, exit 2 on any diff.
-verbose            Print each entry as it's verified
-summary            Totals only
"
        ),
        Some("c") | Some("compare") => println!(
"CMD c               Compare two directories by content
                    Walks both, indexes regular files as (size, crc32),
                    reports paths only in A, only in B, differing, matching.
-verbose            List every differing / unique path
-summary            One-line summary only
"
        ),
        Some(x) => println!("no help for '{x}'   (try `syc h`)"),
    }
}
