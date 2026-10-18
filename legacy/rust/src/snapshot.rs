//! Best-effort filesystem snapshots for `-snapshot`.
//!
//! Before walking the source tree, try to take an atomic read-only snapshot so
//! files that change during the archive operation don't corrupt the stream.
//! Supported: btrfs (`btrfs subvolume snapshot -r`), zfs (`zfs snapshot`).
//! Everything else (ext4, xfs, tmpfs, LVM without DM integration, …) falls
//! back to the live tree with a warning.
//!
//! The returned `SnapshotGuard` owns cleanup (subvolume delete / snapshot
//! destroy) and runs it on drop. If snapshotting fails (no root, wrong FS,
//! src not at subvolume/dataset root, binaries missing), we log and continue
//! on the live tree — never a hard error, since `-snapshot` is best-effort.

use anyhow::Result;
use std::path::{Path, PathBuf};
use std::process::Command;

/// RAII guard for a filesystem snapshot. `effective_src` is the path to use
/// for archival — either the snapshot mount (success) or the original path
/// (fallback). Dropping the guard runs the cleanup (delete snapshot).
pub struct SnapshotGuard {
    pub effective_src: PathBuf,
    pub kind: &'static str,
    cleanup: Option<Box<dyn FnOnce() + Send>>,
}

impl Drop for SnapshotGuard {
    fn drop(&mut self) {
        if let Some(f) = self.cleanup.take() {
            f();
        }
    }
}

impl SnapshotGuard {
    fn passthrough(src: &Path) -> Self {
        Self { effective_src: src.to_path_buf(), kind: "none", cleanup: None }
    }
}

/// Try to snapshot `src`. Always returns a guard; check `kind` to see what
/// happened. Prints one info line to stderr describing the outcome.
pub fn take_snapshot(src: &Path) -> Result<SnapshotGuard> {
    let fs = detect_fs(src);
    match fs {
        Some("btrfs") => Ok(try_btrfs(src).unwrap_or_else(|e| {
            eprintln!("{}", crate::color::warn_line(&format!(
                "-snapshot: btrfs fallback ({e}); using live tree"
            )));
            SnapshotGuard::passthrough(src)
        })),
        Some("zfs") => Ok(try_zfs(src).unwrap_or_else(|e| {
            eprintln!("{}", crate::color::warn_line(&format!(
                "-snapshot: zfs fallback ({e}); using live tree"
            )));
            SnapshotGuard::passthrough(src)
        })),
        other => {
            eprintln!("{}", crate::color::warn_line(&format!(
                "-snapshot: filesystem {} not supported (need btrfs or zfs); using live tree",
                other.unwrap_or("unknown")
            )));
            Ok(SnapshotGuard::passthrough(src))
        }
    }
}

#[cfg(unix)]
fn detect_fs(p: &Path) -> Option<&'static str> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = CString::new(p.as_os_str().as_bytes()).ok()?;
    unsafe {
        let mut s: libc::statfs = std::mem::zeroed();
        if libc::statfs(c.as_ptr(), &mut s) != 0 {
            return None;
        }
        // Magic numbers from linux/magic.h. f_type is signed on some libc
        // variants, so mask to u32.
        let ty = s.f_type as u32 as u64;
        match ty {
            0x9123683E => Some("btrfs"),
            0x2FC12FC1 => Some("zfs"),
            0xEF53 => Some("ext4"),
            0x58465342 => Some("xfs"),
            0x01021994 => Some("tmpfs"),
            0x65735546 => Some("fuse"),
            _ => None,
        }
    }
}

#[cfg(not(unix))]
fn detect_fs(_p: &Path) -> Option<&'static str> {
    None
}

fn try_btrfs(src: &Path) -> Result<SnapshotGuard> {
    let abs = src.canonicalize()?;
    let parent = abs
        .parent()
        .ok_or_else(|| anyhow::anyhow!("no parent for {}", abs.display()))?;
    let tag = format!(
        ".syc-snap-{}-{}",
        std::process::id(),
        now_epoch_ns()
    );
    let snap = parent.join(&tag);
    let out = Command::new("btrfs")
        .args(["subvolume", "snapshot", "-r"])
        .arg(&abs)
        .arg(&snap)
        .output()
        .map_err(|e| anyhow::anyhow!("btrfs binary not available: {e}"))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(anyhow::anyhow!("btrfs snapshot failed: {}", stderr.trim()));
    }
    eprintln!("-snapshot: btrfs ro-snapshot at {}", snap.display());
    let snap_cleanup = snap.clone();
    Ok(SnapshotGuard {
        effective_src: snap,
        kind: "btrfs",
        cleanup: Some(Box::new(move || {
            let _ = Command::new("btrfs")
                .args(["subvolume", "delete"])
                .arg(&snap_cleanup)
                .output();
        })),
    })
}

fn try_zfs(src: &Path) -> Result<SnapshotGuard> {
    let abs = src.canonicalize()?;
    // Resolve the dataset containing `abs` via `df --output=source`.
    let out = Command::new("df")
        .arg("--output=source")
        .arg(&abs)
        .output()
        .map_err(|e| anyhow::anyhow!("df not available: {e}"))?;
    if !out.status.success() {
        return Err(anyhow::anyhow!("df failed"));
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let dataset = text
        .lines()
        .nth(1)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow::anyhow!("df output empty"))?
        .to_string();
    let tag = format!("syc-snap-{}-{}", std::process::id(), now_epoch_ns());
    let full = format!("{dataset}@{tag}");
    let st = Command::new("zfs")
        .arg("snapshot")
        .arg(&full)
        .output()
        .map_err(|e| anyhow::anyhow!("zfs binary not available: {e}"))?;
    if !st.status.success() {
        let stderr = String::from_utf8_lossy(&st.stderr);
        return Err(anyhow::anyhow!("zfs snapshot failed: {}", stderr.trim()));
    }
    // Resolve the dataset mountpoint to find the .zfs/snapshot path.
    let mp_out = Command::new("zfs")
        .args(["get", "-H", "-o", "value", "mountpoint"])
        .arg(&dataset)
        .output()?;
    let mountpoint = String::from_utf8_lossy(&mp_out.stdout).trim().to_string();
    // Compute rel path inside the dataset.
    let rel = abs.strip_prefix(&mountpoint).unwrap_or(Path::new(""));
    let snap_root = PathBuf::from(&mountpoint).join(".zfs/snapshot").join(&tag).join(rel);
    eprintln!("-snapshot: zfs snapshot {} at {}", full, snap_root.display());
    let full_cleanup = full.clone();
    Ok(SnapshotGuard {
        effective_src: snap_root,
        kind: "zfs",
        cleanup: Some(Box::new(move || {
            let _ = Command::new("zfs")
                .arg("destroy")
                .arg(&full_cleanup)
                .output();
        })),
    })
}

fn now_epoch_ns() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}
