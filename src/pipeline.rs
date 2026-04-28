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
