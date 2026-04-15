//! End-to-end roundtrip tests: archive then extract, verify contents match.
//! Exercises each backend (zstd, lzma, ppmd) and the REP/SREP preprocessors
//! via the actual CLI binary so format changes can't silently diverge.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn syc_bin() -> PathBuf {
    // cargo sets CARGO_BIN_EXE_<name> for binaries declared in the package.
    PathBuf::from(env!("CARGO_BIN_EXE_syc"))
}

fn tmp_root(tag: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    let pid = std::process::id();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    p.push(format!("syc-test-{tag}-{pid}-{nanos}"));
    let _ = fs::remove_dir_all(&p);
    fs::create_dir_all(&p).unwrap();
    p
}

fn write_file(path: &Path, bytes: &[u8]) {
    if let Some(p) = path.parent() {
        fs::create_dir_all(p).unwrap();
    }
    fs::write(path, bytes).unwrap();
}

fn make_fixture(root: &Path) {
    write_file(&root.join("hello.txt"), b"Hello, world!\n");
    // Several sizes to exercise chunking, plus repetitive content to exercise
    // the compressors.
    let filler: Vec<u8> = (0..2048).map(|i| (i % 251) as u8).collect();
    write_file(&root.join("nested/a.bin"), &filler);
    let repeated: Vec<u8> = b"abcdefgh".repeat(4096);
    write_file(&root.join("nested/deep/b.bin"), &repeated);
    // Empty file and a zero-filled one.
    write_file(&root.join("empty"), b"");
    write_file(&root.join("zeros.bin"), &vec![0u8; 65537]);
}

fn assert_same_tree(a: &Path, b: &Path) {
    let mut entries_a = Vec::new();
    let mut entries_b = Vec::new();
    walk(a, a, &mut entries_a);
    walk(b, b, &mut entries_b);
    entries_a.sort();
    entries_b.sort();
    assert_eq!(entries_a, entries_b, "directory listings differ");
    for (rel, kind, size) in &entries_a {
        if *kind == 'f' {
            let fa = fs::read(a.join(rel)).unwrap();
            let fb = fs::read(b.join(rel)).unwrap();
            assert_eq!(fa.len() as u64, *size);
            assert_eq!(fa, fb, "content mismatch for {}", rel.display());
        }
    }
}

fn walk(base: &Path, here: &Path, out: &mut Vec<(PathBuf, char, u64)>) {
    for entry in fs::read_dir(here).unwrap() {
        let entry = entry.unwrap();
        let p = entry.path();
        let rel = p.strip_prefix(base).unwrap().to_path_buf();
        let md = fs::symlink_metadata(&p).unwrap();
        if md.is_dir() {
            out.push((rel.clone(), 'd', 0));
            walk(base, &p, out);
        } else if md.file_type().is_symlink() {
            out.push((rel, 'l', 0));
        } else {
            out.push((rel, 'f', md.len()));
        }
    }
}

fn run_syc(args: &[&str], envs: &[(&str, &str)]) {
    let mut cmd = Command::new(syc_bin());
    cmd.args(args);
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let out = cmd.output().expect("spawn syc");
    assert!(
        out.status.success(),
        "syc {:?} failed: stderr={}",
        args,
        String::from_utf8_lossy(&out.stderr)
    );
}

fn roundtrip_at_level(level: &str, envs: &[(&str, &str)], tag: &str) {
    let root = tmp_root(tag);
    let src = root.join("src");
    let archive = root.join("out.syc");
    let dst = root.join("dst");
    make_fixture(&src);

    run_syc(
        &[
            "a",
            archive.to_str().unwrap(),
            src.to_str().unwrap(),
            "-level",
            level,
            "-threads",
            "2",
        ],
        envs,
    );
    run_syc(
        &["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()],
        &[],
    );
    // Archive stores `src` as a directory; extraction writes it under dst.
    assert_same_tree(&src, &dst);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn roundtrip_zstd_l1() {
    roundtrip_at_level("1", &[], "zstd-l1");
}

#[test]
fn roundtrip_zstd_l4() {
    roundtrip_at_level("4", &[], "zstd-l4");
}

#[test]
fn roundtrip_lzma_l5() {
    roundtrip_at_level("5", &[], "lzma-l5");
}

#[test]
fn roundtrip_ppmd_l7() {
    roundtrip_at_level("7", &[("SYC_BACKEND", "ppmd")], "ppmd-l7");
}

fn roundtrip_lzp(level: &str, envs: &[(&str, &str)], tag: &str) {
    let root = tmp_root(tag);
    let src = root.join("src");
    let archive = root.join("out.syc");
    let dst = root.join("dst");
    make_fixture(&src);
    // Add a larger repeating payload so LZP has something long to match on.
    let long_rep: Vec<u8> =
        b"the quick brown fox jumps over the lazy dog 0123456789 "
            .repeat(4096);
    write_file(&src.join("nested/repeats.txt"), &long_rep);

    run_syc(
        &["a", archive.to_str().unwrap(), src.to_str().unwrap(),
          "-level", level, "-lzp"],
        envs,
    );
    run_syc(&["t", archive.to_str().unwrap()], &[]);
    run_syc(&["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()], &[]);
    assert_same_tree(&src, &dst);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn roundtrip_lzp_lzma() {
    roundtrip_lzp("6", &[], "lzp-lzma");
}

#[test]
fn roundtrip_lzp_ppmd() {
    roundtrip_lzp("7", &[("SYC_BACKEND", "ppmd")], "lzp-ppmd");
}

fn roundtrip_hash(algo: &str, tag: &str) {
    let root = tmp_root(tag);
    let src = root.join("src");
    let archive = root.join("out.syc");
    let dst = root.join("dst");
    make_fixture(&src);
    run_syc(
        &["a", archive.to_str().unwrap(), src.to_str().unwrap(),
          "-level", "1", "-hash", algo],
        &[],
    );
    run_syc(&["t", archive.to_str().unwrap()], &[]);
    run_syc(&["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()], &[]);
    assert_same_tree(&src, &dst);
    let _ = fs::remove_dir_all(&root);
}

#[cfg(target_os = "linux")]
#[test]
fn roundtrip_xattrs() {
    let root = tmp_root("xattrs");
    let src = root.join("src");
    let archive = root.join("out.syc");
    let dst = root.join("dst");
    make_fixture(&src);
    // Set a user.* xattr on one file. Skip the test (don't fail) if the
    // filesystem rejects it — some CI containers run on tmpfs without
    // xattr support.
    let attr_path = src.join("hello.txt");
    if xattr::set(&attr_path, "user.syc_test", b"roundtrip").is_err() {
        eprintln!("xattrs not supported on this fs; skipping");
        let _ = fs::remove_dir_all(&root);
        return;
    }
    run_syc(
        &["a", archive.to_str().unwrap(), src.to_str().unwrap(),
          "-level", "1", "-xattrs"],
        &[],
    );
    run_syc(&["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()], &[]);
    assert_same_tree(&src, &dst);
    let got = xattr::get(dst.join("hello.txt"), "user.syc_test")
        .expect("getxattr after extract")
        .expect("xattr missing after extract");
    assert_eq!(got, b"roundtrip");
    let _ = fs::remove_dir_all(&root);
}

fn roundtrip_append(level: &str, tag: &str) {
    let root = tmp_root(tag);
    let src1 = root.join("src1");
    let src2 = root.join("src2");
    let archive = root.join("out.syc");
    let dst = root.join("dst");

    // First batch.
    make_fixture(&src1);
    // Second batch — different content so we can verify both ended up in dst.
    write_file(&src2.join("appended/one.txt"), b"I was appended!\n");
    write_file(&src2.join("appended/two.bin"), &vec![7u8; 4096]);

    run_syc(
        &["a", archive.to_str().unwrap(), src1.to_str().unwrap(),
          "-level", level],
        &[],
    );
    let size_after_first = fs::metadata(&archive).unwrap().len();
    run_syc(
        &["a", archive.to_str().unwrap(), src2.to_str().unwrap(),
          "-append", "-level", level],
        &[],
    );
    let size_after_second = fs::metadata(&archive).unwrap().len();
    assert!(
        size_after_second > size_after_first,
        "append should grow the archive (before={size_after_first} after={size_after_second})"
    );

    // Extract and verify files from both frames landed in dst. collect_entries
    // stores paths relative to each source root, so both trees merge into dst.
    run_syc(&["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()], &[]);
    assert_eq!(fs::read(dst.join("hello.txt")).unwrap(), b"Hello, world!\n");
    assert_eq!(
        fs::read(dst.join("appended/one.txt")).unwrap(),
        b"I was appended!\n"
    );
    assert_eq!(fs::read(dst.join("appended/two.bin")).unwrap(), vec![7u8; 4096]);

    // List and test should also see entries from both frames.
    run_syc(&["t", archive.to_str().unwrap()], &[]);

    let _ = fs::remove_dir_all(&root);
}

fn roundtrip_delta(level: &str, stride: &str, tag: &str) {
    let root = tmp_root(tag);
    let src = root.join("src");
    let archive = root.join("out.syc");
    let dst = root.join("dst");
    // 16-bit LE PCM sawtooth — realistic delta-2 target. Delta should
    // reduce this to nearly-constant output, so LZMA crushes it.
    let mut pcm = Vec::with_capacity(16 * 1024);
    for i in 0..8192i32 {
        let v: i16 = ((i * 37) & 0x7FFF) as i16;
        pcm.extend_from_slice(&v.to_le_bytes());
    }
    write_file(&src.join("tone.raw"), &pcm);
    // Also a non-PCM file to verify the filter doesn't corrupt heterogeneous
    // data — only compression ratio suffers, correctness must hold.
    write_file(&src.join("readme.txt"), b"hello, delta\n");

    run_syc(
        &["a", archive.to_str().unwrap(), src.to_str().unwrap(),
          "-level", level, "-delta", stride],
        &[],
    );
    run_syc(&["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()], &[]);
    assert_same_tree(&src, &dst);
    // Also test/list should decode cleanly through the DeltaReader.
    run_syc(&["t", archive.to_str().unwrap()], &[]);
    let _ = fs::remove_dir_all(&root);
}

fn roundtrip_route(level: &str, tag: &str) {
    let root = tmp_root(tag);
    let src = root.join("src");
    let archive = root.join("out.syc");
    let dst = root.join("dst");

    // Compressible text
    write_file(&src.join("notes.txt"), &b"hello routing world!\n".repeat(200));
    // Fake "pre-compressed" files — extensions trigger the media bucket.
    write_file(&src.join("image.jpg"), &vec![0xABu8; 5000]);
    write_file(&src.join("sub/clip.mp4"), &vec![0xCDu8; 7000]);
    write_file(&src.join("sub/pack.zip"), &vec![0xEFu8; 3000]);

    run_syc(
        &["a", archive.to_str().unwrap(), src.to_str().unwrap(),
          "-level", level, "-route"],
        &[],
    );
    run_syc(&["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()], &[]);
    assert_same_tree(&src, &dst);
    // List must see all entries (both frames).
    let out = Command::new(syc_bin())
        .args(["l", archive.to_str().unwrap()])
        .output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("notes.txt"), "list missing default-bucket entry: {stdout}");
    assert!(stdout.contains("image.jpg"), "list missing media-bucket entry: {stdout}");
    assert!(stdout.contains("clip.mp4"), "list missing media-bucket entry: {stdout}");
    assert!(stdout.contains("pack.zip"), "list missing media-bucket entry: {stdout}");
    run_syc(&["t", archive.to_str().unwrap()], &[]);
    let _ = fs::remove_dir_all(&root);
}

fn roundtrip_dedup(level: &str, tag: &str) {
    let root = tmp_root(tag);
    let src = root.join("src");
    let archive_plain = root.join("plain.syc");
    let archive_dedup = root.join("dedup.syc");
    let dst = root.join("dst");

    // Three identical "large" blobs + one unique — dedup should collapse the
    // three to one body plus two HardLink entries.
    let big: Vec<u8> = (0..256 * 1024).map(|i| (i % 251) as u8).collect();
    write_file(&src.join("a/blob.bin"), &big);
    write_file(&src.join("b/blob.bin"), &big);
    write_file(&src.join("c/copy.bin"), &big);
    write_file(&src.join("unique.txt"), b"not a duplicate\n");
    // Also a zero-byte file pair — dedup skips size==0 (no gain).
    write_file(&src.join("empty1"), b"");
    write_file(&src.join("empty2"), b"");

    // Baseline: no dedup.
    run_syc(
        &["a", archive_plain.to_str().unwrap(), src.to_str().unwrap(),
          "-level", level],
        &[],
    );
    // With dedup.
    run_syc(
        &["a", archive_dedup.to_str().unwrap(), src.to_str().unwrap(),
          "-level", level, "-dedup"],
        &[],
    );

    let plain_size = fs::metadata(&archive_plain).unwrap().len();
    let dedup_size = fs::metadata(&archive_dedup).unwrap().len();
    assert!(
        dedup_size < plain_size,
        "dedup archive should be smaller (plain={plain_size} dedup={dedup_size})"
    );

    // Roundtrip: all original files reconstructed byte-exact.
    run_syc(
        &["x", archive_dedup.to_str().unwrap(), "-to", dst.to_str().unwrap()],
        &[],
    );
    assert_same_tree(&src, &dst);
    // test should also walk cleanly.
    run_syc(&["t", archive_dedup.to_str().unwrap()], &[]);
    // list must show all entries including the hardlink ones.
    let out = Command::new(syc_bin())
        .args(["l", archive_dedup.to_str().unwrap()])
        .output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("blob.bin"), "list missing blob: {stdout}");
    assert!(stdout.contains("unique.txt"), "list missing unique: {stdout}");
    // At least one entry line must have the hardlink flag column ("h  <path> -> <target>").
    assert!(
        stdout.lines().any(|l| {
            let t = l.trim_start();
            t.starts_with("h ") || l.contains(" h  ") || l.contains(" h\t") || l.contains(" -> ")
        }),
        "list has no hardlink entries: {stdout}"
    );

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn roundtrip_dedup_zstd() { roundtrip_dedup("1", "dedup-zstd"); }

#[test]
fn roundtrip_dedup_lzma() { roundtrip_dedup("5", "dedup-lzma"); }

fn roundtrip_fastcdc(level: &str, tag: &str) {
    let root = tmp_root(tag);
    let src = root.join("src");
    let archive_plain = root.join("plain.syc");
    let archive_cdc = root.join("cdc.syc");
    let dst = root.join("dst");

    // Build two files that share large overlapping regions at shifted offsets
    // so file-level dedup can't collapse them, but chunk-level CDC can.
    let mut base: Vec<u8> = Vec::with_capacity(512 * 1024);
    let mut x: u64 = 0xABCD_0123;
    for _ in 0..512 * 1024 {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        base.push((x >> 33) as u8);
    }
    let mut shifted: Vec<u8> = b"PREAMBLE-AAAAA".to_vec();
    shifted.extend_from_slice(&base);
    shifted.extend_from_slice(b"-TAIL-Z");
    let mut inserted: Vec<u8> = base[..256 * 1024].to_vec();
    inserted.extend_from_slice(b"INSERTED-MIDDLE-BLOCK-64-BYTES-PADDING-PADDING-");
    inserted.extend_from_slice(&base[256 * 1024..]);

    write_file(&src.join("a.bin"), &base);
    write_file(&src.join("b.bin"), &shifted);
    write_file(&src.join("c.bin"), &inserted);
    // plus a small unrelated file
    write_file(&src.join("note.txt"), b"fastcdc test\n");

    // Baseline: no fastcdc.
    run_syc(
        &["a", archive_plain.to_str().unwrap(), src.to_str().unwrap(),
          "-level", level],
        &[],
    );
    // With fastcdc.
    run_syc(
        &["a", archive_cdc.to_str().unwrap(), src.to_str().unwrap(),
          "-level", level, "-fastcdc"],
        &[],
    );

    let plain_size = fs::metadata(&archive_plain).unwrap().len();
    let cdc_size = fs::metadata(&archive_cdc).unwrap().len();
    // CDC only expected to strictly beat solid-mode compression at level 0
    // (store); at higher levels the zstd/lzma sliding window already catches
    // the cross-file overlap. Allow a small ceiling for metadata overhead.
    let ceiling = plain_size + plain_size / 20; // +5%
    assert!(
        cdc_size <= ceiling,
        "fastcdc archive overhead too high (plain={plain_size} cdc={cdc_size})"
    );

    run_syc(
        &["x", archive_cdc.to_str().unwrap(), "-to", dst.to_str().unwrap()],
        &[],
    );
    assert_same_tree(&src, &dst);
    run_syc(&["t", archive_cdc.to_str().unwrap()], &[]);

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn roundtrip_fastcdc_zstd() { roundtrip_fastcdc("1", "fastcdc-zstd"); }

#[test]
fn roundtrip_fastcdc_lzma() { roundtrip_fastcdc("5", "fastcdc-lzma"); }

#[test]
fn roundtrip_snapshot_fallback() {
    // -snapshot on a tmpfs/ext4 path must fall back cleanly to the live tree
    // (warn to stderr, but archive anyway). The test environment doesn't
    // have btrfs/zfs root, so we exercise the fallback path.
    let root = tmp_root("snapshot-fallback");
    let src = root.join("src");
    let archive = root.join("out.syc");
    let dst = root.join("dst");
    make_fixture(&src);
    run_syc(
        &["a", archive.to_str().unwrap(), src.to_str().unwrap(),
          "-level", "1", "-snapshot"],
        &[],
    );
    run_syc(&["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()], &[]);
    assert_same_tree(&src, &dst);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn roundtrip_route_zstd() { roundtrip_route("1", "route-zstd"); }

#[test]
fn roundtrip_route_lzma() { roundtrip_route("5", "route-lzma"); }

#[test]
fn roundtrip_delta_zstd_s2() { roundtrip_delta("1", "2", "delta-zstd-s2"); }

#[test]
fn roundtrip_delta_lzma_s2() { roundtrip_delta("5", "2", "delta-lzma-s2"); }

#[test]
fn roundtrip_delta_lzma_s4() { roundtrip_delta("5", "4", "delta-lzma-s4"); }

#[test]
fn roundtrip_append_zstd() { roundtrip_append("1", "append-zstd"); }

#[test]
fn roundtrip_append_lzma() { roundtrip_append("5", "append-lzma"); }

#[test]
fn roundtrip_hash_crc32() { roundtrip_hash("crc32", "hash-crc32"); }

#[test]
fn roundtrip_hash_xxh3() { roundtrip_hash("xxh3", "hash-xxh3"); }

#[test]
fn roundtrip_hash_blake3() { roundtrip_hash("blake3", "hash-blake3"); }

#[test]
fn roundtrip_lzma_bcj_x86() {
    // SYC_BCJ=x86 inserts a BCJ filter before LZMA2. xz stores the filter
    // chain in the block header, so the decoder rediscovers it without needing
    // the env var at extract time.
    roundtrip_at_level("5", &[("SYC_BCJ", "x86")], "lzma-bcj-x86");
}

#[test]
fn roundtrip_store() {
    let root = tmp_root("store");
    let src = root.join("src");
    let archive = root.join("out.syc");
    let dst = root.join("dst");
    make_fixture(&src);

    run_syc(
        &[
            "a",
            archive.to_str().unwrap(),
            src.to_str().unwrap(),
            "-store",
        ],
        &[],
    );
    run_syc(
        &["x", archive.to_str().unwrap(), "-to", dst.to_str().unwrap()],
        &[],
    );
    assert_same_tree(&src, &dst);
    let _ = fs::remove_dir_all(&root);
}
