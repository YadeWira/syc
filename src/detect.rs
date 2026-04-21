use std::io::Read;
use std::path::Path;

#[derive(Debug, PartialEq, Eq)]
pub enum FileKind {
    Jpeg,
    Other,
}

/// Detect file type by reading the first 16 bytes (magic numbers).
/// Returns `Other` on any I/O error (no access, empty file, etc.).
pub fn detect(path: &Path) -> FileKind {
    let mut buf = [0u8; 16];
    let n = std::fs::File::open(path)
        .and_then(|mut f| f.read(&mut buf))
        .unwrap_or(0);

    if n >= 2 && buf[0] == 0xFF && buf[1] == 0xD8 {
        return FileKind::Jpeg;
    }

    FileKind::Other
}
