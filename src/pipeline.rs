//! Encoder pipeline for v0.1.20+ — explicit phase separation.
//!
//! ```text
//! Phase 1 — Scan        : stat() each file, classify by extension, build Plan
//! Phase 2 — Dedup       : (caller-driven) build dedup map before specific
//! Phase 3 — Specific    : (caller-driven) packJPG / packPNG per file
//! Phase 4 — General     : (caller-driven) LZMA / Zstd solid block
//! ```
//!
//! This module owns Phase 1 only. Phases 2-4 live in `main.rs::cmd_add` for
//! now; they read the [`Plan`] produced here to drive smart defaults.
//!
//! The Phase 1 cost is bounded: only `stat()` + extension lookup, no file
//! contents read. For a 100 k-file corpus this completes in well under a
//! second; the file-system metadata cost is the same `cmd_add` already pays
//! during its existing scan.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;

/// Coarse classification of a file by extension. Used to drive smart defaults
/// and report scan summary. The actual per-file decision in Phase 3 still
/// falls back to magic-byte detection (`detect::detect`) — extension is a
/// hint, not authoritative.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ExtKind {
    Jpeg,
    Png,
    /// Already-compressed media (mp4 / webm / zip / pdf / etc.) — passthrough
    /// candidates.
    Media,
    /// Anything else: text, source code, binaries, unknown formats.
    Other,
}

impl ExtKind {
    pub fn classify(rel: &std::path::Path) -> Self {
        let ext = rel
            .extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_ascii_lowercase());
        match ext.as_deref() {
            Some("jpg") | Some("jpeg") => Self::Jpeg,
            Some("png") | Some("apng") => Self::Png,
            // Media extensions copied from main.rs::is_media_ext to keep the
            // smart-default logic consistent with the existing -route gate.
            Some("mp4") | Some("m4a") | Some("m4v") | Some("mov") | Some("mkv")
            | Some("webm") | Some("avi") | Some("mp3") | Some("ogg") | Some("opus")
            | Some("flac") | Some("aac") | Some("wma") | Some("zip") | Some("7z")
            | Some("rar") | Some("gz") | Some("xz") | Some("bz2") | Some("lz4")
            | Some("zst") | Some("pdf") | Some("epub") | Some("djvu") => Self::Media,
            _ => Self::Other,
        }
    }
}

/// One row per scanned file. Mirrors the `(full, rel)` tuple cmd_add uses
/// today plus the cached metadata (size, kind) so Phase 3 doesn't `stat()`
/// again. Symlinks and directories are recorded but their `size` is 0 (we
/// don't follow links during scan).
#[derive(Clone, Debug)]
pub struct ScanEntry {
    pub full: PathBuf,
    pub rel: PathBuf,
    pub size: u64,
    pub kind: ExtKind,
    /// True for regular files; false for symlinks / dirs / unreadable.
    pub is_regular: bool,
}

/// Output of Phase 1. Drives smart defaults and is consumed by Phases 2-4.
/// Cheap to clone and pass around; per-file metadata is owned, not borrowed.
#[derive(Clone, Debug, Default)]
pub struct Plan {
    pub files: Vec<ScanEntry>,
    pub total_bytes: u64,
    /// Bytes per ExtKind. `total_bytes == sum(type_bytes.values())` for
    /// regular files; symlinks/dirs contribute zero.
    pub type_bytes: HashMap<ExtKind, u64>,
    /// Count per ExtKind (regular files only).
    pub type_count: HashMap<ExtKind, u64>,
    pub regular_count: u64,
    /// Median file size (regular files only). 0 if no regular files.
    pub p50_size: u64,
    /// 95th percentile file size. Used to detect "all files small" corpora.
    pub p95_size: u64,
}

impl Plan {
    /// Build the plan from the `(full, rel)` list `cmd_add` collects today.
    /// Equivalent in cost to the existing scan summary loop — we just bottle
    /// the result into a typed value instead of throwing it away.
    pub fn from_entries(entries: &[(PathBuf, PathBuf)]) -> Self {
        let mut files = Vec::with_capacity(entries.len());
        let mut type_bytes: HashMap<ExtKind, u64> = HashMap::new();
        let mut type_count: HashMap<ExtKind, u64> = HashMap::new();
        let mut total_bytes: u64 = 0;
        let mut regular_count: u64 = 0;
        let mut sizes: Vec<u64> = Vec::with_capacity(entries.len());

        for (full, rel) in entries {
            let kind = ExtKind::classify(rel);
            let (size, is_regular) = match std::fs::symlink_metadata(full) {
                Ok(m) => {
                    let reg = m.is_file();
                    (if reg { m.len() } else { 0 }, reg)
                }
                Err(_) => (0, false),
            };
            if is_regular {
                regular_count += 1;
                total_bytes = total_bytes.saturating_add(size);
                *type_bytes.entry(kind).or_insert(0) += size;
                *type_count.entry(kind).or_insert(0) += 1;
                sizes.push(size);
            }
            files.push(ScanEntry { full: full.clone(), rel: rel.clone(), size, kind, is_regular });
        }

        sizes.sort_unstable();
        let p50_size = pct(&sizes, 50);
        let p95_size = pct(&sizes, 95);

        Plan { files, total_bytes, type_bytes, type_count, regular_count, p50_size, p95_size }
    }

    /// Share of total bytes accounted for by a given ExtKind. Returns 0.0
    /// when total_bytes == 0.
    pub fn share(&self, kind: ExtKind) -> f64 {
        if self.total_bytes == 0 {
            return 0.0;
        }
        self.type_bytes.get(&kind).copied().unwrap_or(0) as f64 / self.total_bytes as f64
    }

    /// Format a one-line summary suitable for the `Scanned ...` line in
    /// `cmd_add`. Shows the dominant types only (>5 % of bytes) to keep the
    /// line readable. Format mimics the existing scan banner so users
    /// upgrading from 0.1.19 don't see a regression in clarity.
    pub fn summary_line(&self) -> String {
        let mut parts: Vec<(ExtKind, f64)> = [ExtKind::Png, ExtKind::Jpeg, ExtKind::Media, ExtKind::Other]
            .into_iter()
            .map(|k| (k, self.share(k)))
            .filter(|&(_, s)| s >= 0.05)
            .collect();
        parts.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let labels: Vec<String> = parts
            .into_iter()
            .map(|(k, s)| format!("{} {:.0}%", kind_label(k), s * 100.0))
            .collect();
        if labels.is_empty() {
            String::new()
        } else {
            format!(" / {}", labels.join(" "))
        }
    }
}

fn kind_label(k: ExtKind) -> &'static str {
    match k {
        ExtKind::Png => "png",
        ExtKind::Jpeg => "jpg",
        ExtKind::Media => "media",
        ExtKind::Other => "other",
    }
}

fn pct(sorted: &[u64], p: u64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    // Nearest-rank percentile: ceil(p/100 * N) - 1 (0-indexed).
    let n = sorted.len() as u64;
    let idx = ((p * n + 99) / 100).saturating_sub(1) as usize;
    sorted[idx.min(sorted.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn classify_extensions() {
        assert_eq!(ExtKind::classify(Path::new("a.jpg")), ExtKind::Jpeg);
        assert_eq!(ExtKind::classify(Path::new("A.JPEG")), ExtKind::Jpeg);
        assert_eq!(ExtKind::classify(Path::new("p.png")), ExtKind::Png);
        assert_eq!(ExtKind::classify(Path::new("p.APNG")), ExtKind::Png);
        assert_eq!(ExtKind::classify(Path::new("v.mp4")), ExtKind::Media);
        assert_eq!(ExtKind::classify(Path::new("README.md")), ExtKind::Other);
        assert_eq!(ExtKind::classify(Path::new("noext")), ExtKind::Other);
    }

    #[test]
    fn percentile_basic() {
        assert_eq!(pct(&[], 50), 0);
        assert_eq!(pct(&[42], 50), 42);
        assert_eq!(pct(&[1, 2, 3, 4, 5], 50), 3);
        assert_eq!(pct(&[1, 2, 3, 4, 5], 95), 5);
    }
}

/* ─── Phase 3: parallel specific compression (-thN) ──────────────────────── */

/// Which specific compressor to invoke for a job.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpecificKind {
    Pjg,
    Ppg,
}

/// A single pjg/ppg pre-compress job. `idx` is the position in the original
/// entry list — used by the pack loop to write results in the same order the
/// input entries were collected (workers complete out of order).
pub struct SpecificJob {
    pub idx: usize,
    pub full: PathBuf,
    pub rel: PathBuf,
    pub kind: SpecificKind,
}

/// Result of a successful pre-compression. Holds everything the pack loop
/// needs to write the entry without a second filesystem read or FFI call.
/// `body` is the .pjg / .ppg payload; `hash_trailer` is the (already-computed)
/// content hash if the user passed `-hash`.
pub struct Precompressed {
    pub idx: usize,
    pub kind: SpecificKind,
    pub rel: PathBuf,
    pub original_size: u64,
    pub body: Vec<u8>,
    pub hash_trailer: Option<Vec<u8>>,
    pub mtime: i64,
    pub mode: u32,
}

/// Single-job pre-compress: read file, invoke FFI, hash if requested.
/// Pure CPU-bound (modulo the initial read) — safe to call from a worker
/// thread. Returns the original file's idx on both Ok and Err so the caller
/// can correlate failures back to the input list.
fn precompress_one(
    job: &SpecificJob,
    hash_algo: Option<crate::archive::HashAlgo>,
) -> (usize, Result<Precompressed, String>) {
    let result = (|| -> Result<Precompressed, String> {
        let meta = std::fs::symlink_metadata(&job.full)
            .map_err(|e| format!("stat {}: {e}", job.full.display()))?;
        let bytes = std::fs::read(&job.full)
            .map_err(|e| format!("read {}: {e}", job.full.display()))?;
        let body = match job.kind {
            SpecificKind::Pjg => crate::pjg::jpg_to_pjg(&bytes)
                .map_err(|e| format!("packJPG encode {}: {e}", job.full.display()))?,
            SpecificKind::Ppg => crate::ppg::png_to_ppg(&bytes)
                .map_err(|e| format!("packPNG encode {}: {e}", job.full.display()))?,
        };
        let mtime = crate::archive::meta_mtime(&meta);
        #[cfg(unix)]
        let mode = {
            use std::os::unix::fs::PermissionsExt;
            meta.permissions().mode()
        };
        #[cfg(not(unix))]
        let mode = 0o644u32;
        let hash_trailer = hash_algo.map(|algo| {
            let mut hasher = crate::archive::EntryHasher::new(algo);
            hasher.update(&bytes);
            let mut buf = vec![0u8; algo.trailer_bytes()];
            hasher.finalize_into(&mut buf);
            buf
        });
        Ok(Precompressed {
            idx: job.idx,
            kind: job.kind,
            rel: job.rel.clone(),
            original_size: bytes.len() as u64,
            body,
            hash_trailer,
            mtime,
            mode,
        })
    })();
    (job.idx, result)
}

/// Parallel pre-compress with a worker pool of `num_workers` threads.
///
/// Workers pop jobs off a shared `Mutex<Vec<SpecificJob>>` (work-stealing
/// queue, last-in-first-out — order doesn't matter because results are
/// reordered by `idx` on the receiver side). Returns `Vec<Result>` aligned
/// with the input job vector's positions.
///
/// Memory peak: sum of all `body` bytes for successfully compressed jobs,
/// held in the returned vector until the caller drains it. Currently a
/// full pre-pass — for huge corpora this could dominate RAM. A streaming
/// variant with a bounded result channel is a reasonable v0.1.21 follow-up.
pub fn parallel_precompress(
    jobs: Vec<SpecificJob>,
    num_workers: usize,
    hash_algo: Option<crate::archive::HashAlgo>,
) -> Vec<Result<Precompressed, String>> {
    let n = jobs.len();
    if n == 0 {
        return Vec::new();
    }
    let num_workers = num_workers.min(n).max(1);

    let queue: Arc<Mutex<Vec<SpecificJob>>> = Arc::new(Mutex::new(jobs));
    let (tx, rx) = std::sync::mpsc::channel::<(usize, Result<Precompressed, String>)>();

    let mut handles = Vec::with_capacity(num_workers);
    for _ in 0..num_workers {
        let q = Arc::clone(&queue);
        let tx = tx.clone();
        handles.push(thread::spawn(move || loop {
            let job = match q.lock().unwrap().pop() {
                Some(j) => j,
                None => break,
            };
            let res = precompress_one(&job, hash_algo);
            if tx.send(res).is_err() {
                break;
            }
        }));
    }
    drop(tx);

    let mut results: Vec<Option<Result<Precompressed, String>>> =
        (0..n).map(|_| None).collect();
    while let Ok((idx, r)) = rx.recv() {
        if idx < results.len() {
            results[idx] = Some(r);
        }
    }
    for h in handles {
        let _ = h.join();
    }

    results
        .into_iter()
        .map(|o| o.unwrap_or_else(|| Err("worker dropped result".to_string())))
        .collect()
}

/// Worker count cap for `parallel_precompress`. Mirrors packJPG's `-sfth`
/// fixed cap of 4: beyond this point per-file FFI parallelism hits diminishing
/// returns, and oversubscribing the CPU hurts the LZMA backend that runs
/// after Phase 3. Caller may pass a smaller value via `-thN`; this is the
/// upper bound only.
pub const PHASE3_MAX_WORKERS: usize = 8;

/// Resolve the effective worker count for Phase 3 from the user's `-thN`
/// flag, the hardware concurrency, and the per-task cap. Mirrors the
/// existing -sfth-style logic in packJPG / packPNG.
pub fn phase3_worker_count(opt_threads: u32) -> usize {
    let hw = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);
    let user = if opt_threads == 0 { hw } else { opt_threads as usize };
    user.min(hw).min(PHASE3_MAX_WORKERS).max(1)
}
