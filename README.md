# syc

Streaming archiver + compressor in (almost) pure Rust, tuned for modest hardware.

Status: **alpha** — format may evolve before v1.

## Why

Most Rust archivers either wrap `tar` + a single compressor or re-implement zip.
`syc` treats the archive as a single solid compressed stream with optional
preprocessors, so one pass of zstd / LZMA / PPMd7 sees every file at once and
can share dictionary state across them. Decompression is a single streaming
read — no central directory, no seeks.

Benchmarks live in [`NOTES.md`](NOTES.md). Headline: decompression is **10–18×
faster than FreeArc/ARC** at equivalent ratio tiers; ratio ties or beats ARC up
to `-m4`, LZMA preset catches up around `-m5`.

## Install

Pre-built binaries on the [releases page](https://github.com/YadeWira/syc/releases).

Linux:

```sh
chmod +x syc-0.1.8-linux-x86_64
./syc-0.1.8-linux-x86_64 h
```

Windows: download `syc-0.1.8-windows-x86_64.exe`, run from `cmd` or
PowerShell.

Or build from source (stable Rust, edition 2021):

```sh
git clone https://github.com/YadeWira/syc
cd syc
cargo build --release
./target/release/syc h
```

## Quick start

```sh
# pack
syc a data.syc ./mydir -level 5

# list / test / extract
syc l data.syc
syc t data.syc
syc x data.syc -to ./restored
```

Levels run `0..=10`. Default is `5` (LZMA sweet-spot). Levels `0..=4` use zstd
(fast); `5..=10` use LZMA (best ratio).

## Features

**Backends**
- `zstd` (default, levels 0–4) with long-range matching
- `LZMA` (levels 5–10) via `xz2`
- `PPMd7` opt-in: `SYC_BACKEND=ppmd` (single-threaded — model is sequential)

**Threads**
- Auto: when `-threads` is omitted **and** input ≥ 256 MiB, syc picks
  `min(cores, 8)` and forwards to both zstd's MT path and the LZMA
  `MtStreamBuilder`. zstd MT costs ~0.1% ratio; LZMA MT splits at 3× dict
  per block (RAM cost: N × 128 MiB at default).
- Manual: `-threads N`. `-threads 1` forces single-threaded.

**Preprocessors** (applied between the archive body and the compressor)
- **REP / SREP** — long-repeat finder, auto-enabled for corpora > 1 GiB
- **BCJ** — x86/ARM/IA64/SPARC/PPC branch-code filter; auto-detects ELF/PE
  in the sample and applies x86 when the majority matches (`-bcj off` to skip,
  or pick explicitly)
- **Delta** — `-delta N` (stride 1, 2, or 4) for PCM / raster data
- **LZP** — `-lzp` context-hash predictor; pairs well with PPMd
- **FastCDC** — `-fastcdc` content-defined chunking for cross-file dedup at
  sub-file granularity

**Archive modes**
- `-append` — writes a new compressed frame to the end of an existing archive;
  existing bytes are never rewritten (antiransomware property). Multi-frame
  streams decode transparently.
- `-route` — partitions entries by extension: pre-compressed media
  (jpg/mp4/zip/pdf/apk/…) goes to a level-0 frame, the rest goes to the
  chosen level. Saves CPU on data that won't compress anyway.
- `-dedup` — xxh3_64 per file; duplicates become `HardLink` entries pointing
  at the canonical path. On extract, real hardlinks (copy fallback on
  cross-device). On 4 copies of `/usr/share/doc/python3.13`: 4× less
  compression work and ≈16% smaller archive.

**Per-file integrity**
- `-hash crc32 | xxh3 | blake3` (default `crc32`). `blake3` is cryptographic;
  `xxh3` is fastest; `crc32` is smallest. `-nochecksum` to skip.

**Metadata**
- Unix mode preserved, symlinks preserved, mtime restored on extract.
- Linux extended attributes with `-xattrs` (`user.*` / `system.*` /
  `security.*`).
- Archive-level `-comment TEXT`, shown by `syc l`.
- Optional `-snapshot` takes a btrfs / zfs read-only snapshot before walking
  the tree (silent fallback to the live tree on unsupported FS).

**Solid / dict**
- Solid sort groups files by `(kind, extension, parent dir, size, path)` so
  similar payloads stream adjacent to each other (better dictionary reuse).
- Optional zstd dictionary training (`-dict`) with size adaptive to the
  corpus (64 KiB → 256 KiB).

**Selectors and plumbing**
- `-exclude PATTERN` (repeatable), `-minsize N`, `-maxsize N`
- `-filelist FILE`, `-datefrom YYYY-MM-DD`, `-dateto YYYY-MM-DD`
- `-chunk SIZE` — split output into `archive.001`, `.002`, … Accepts size
  suffixes: `-chunk 100MB`, `-chunk 2GB`, `-chunk 1.5GiB`. KB/MB/GB are
  1024-base (matches zpaqfranz). `-minsize` / `-maxsize` accept the same
  suffixes.
- Pipe support: `-` as archive path reads from stdin / writes to stdout
- `-exec_ok CMD` / `-exec_error CMD` hooks

**UX (zpaqfranz-flavored)**
- Live progress bar (4 Hz, stderr, auto-off without a TTY): `pack 42% ETA
  00:01:13  720 MB of 1.75 GB  450 MB/s`. Disable with `-noprogress`. After
  100% it switches to `flushing...` while the encoder finalizes.
- Numbered red errors (`00042! …`) and yellow warnings (`00042: …`) with a
  count footer.
- Atomic write: pack streams to `<archive>.tmp` and renames on success.
  Cancelled runs leave the `.tmp` behind; the final name is never half-written.

## Commands

```
a   add        pack sources into archive
x   extract    unpack archive (streaming, no seek)
l   list       show entries
t   test       decompress & verify checksums (no extract)
v   verify     stream-compare archive against a live source dir
c   compare    diff two directories by content (size + crc32)
d   dedupe     report duplicates in a tree (read-only)
h   help       `syc h` for banner, `syc h <cmd>` for detail
```

## Status vs FreeArc / ARC.exe

On `/usr/share/doc/python3.13` (71 MiB, 1502 files):

| Tier   | syc ratio | ARC ratio | decomp speed vs ARC |
|--------|-----------|-----------|---------------------|
| low    | 0.214     | 0.228     | 9.7× faster         |
| mid    | 0.155     | 0.166     | 10.4× faster        |
| high   | 0.148     | 0.146     | 14.9× faster        |
| top    | 0.148     | 0.139     | 17.9× faster        |

`syc` wins ratio through `-m4`. ARC's top tier activates its `Dict + LZP +
PPMd` stack which `syc` does not yet port; closing that gap is tracked in
`NOTES.md`.

## Build targets

- Linux `x86_64-unknown-linux-gnu` (native)
- Windows `x86_64-pc-windows-gnu` via mingw-w64
  (`.cargo/config.toml` has the linker wired up; `cargo build --release
  --target x86_64-pc-windows-gnu` from a Linux host with `mingw-w64`
  installed)

## License

Dual MIT / Apache-2.0.
