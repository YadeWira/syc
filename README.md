# syc

A streaming archiver and compressor with its own LZ codecs, written from
scratch in Free Pascal. Tuned for modest hardware.

**Status: v0.2.x, pre-release.** Every release stays a pre-release until
v1.0.0, and the formats can change between versions. syc v0.1.x was a
Rust archiver; its sources are archived in [`legacy/rust/`](legacy/rust/). v0.2 restarts
the project in Free Pascal, algorithms first: the codec is under way, the
command line is a placeholder and will also be designed from scratch.

## Goals

"Modest hardware" is taken literally:

- bounded memory, small match-finder tables, reusable contexts;
- good on 1–4 cores rather than needing 16;
- no AVX2 requirement: x86-64 baseline (SSE2) is enough;
- 32-bit targets supported (the Pascal code paths run anywhere FPC does).

## sylz

The first codec: a fast LZ with separate control and literal streams, so
the decoder finds the next sequence at a fixed distance whatever the
literal length. Level 1 is a greedy single-hash parser, levels 2–12 use
hash chains with lazy matching. The decoder is safe on corrupt input. Hot
loops have x86-64 assembler versions (Linux and Win64) next to the Pascal
ones, and the fuzzer checks that both compressors produce the same bytes.

silesia.tar, in memory, one block, one core (Xeon E5-2697A v4, 2.6 GHz):

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4 1.10.0 | 515 MB/s | 3105 MB/s | 47.59% |
| misa77 0.6.0 -0 | 157 MB/s | 3907 MB/s | 44.60% |
| lizard 2.1 -10 | 433 MB/s | 2965 MB/s | 48.78% |
| zstd 1.5.7 --fast=1 | 397 MB/s | 1405 MB/s | 41.01% |
| **sylz -1** | **402 MB/s** | **2930 MB/s** | **44.62%** |
| **sylz -9** | 22.5 MB/s | 3150 MB/s | 36.88% |

Competitors measured with lzbench 2.4.1 (GCC 14.2) on the same core. How,
and more numbers: [Benchmarks](https://github.com/YadeWira/syc/wiki/Benchmarks).
The format: [sylz format](https://github.com/YadeWira/syc/wiki/sylz-format).

## Build

Free Pascal 3.2.2:

```sh
./build.sh                    # out/syc and out/sylzbench
./build.sh -Twin64            # Windows x86-64 (FPC's win64 units)
./build.sh -dSYLZ_PUREPASCAL  # no assembler, Pascal paths only
FPC=ppcross386 ./build.sh -Twin32                  # Windows 32-bit
FPC=ppcrossa64 ./build.sh -XPaarch64-linux-gnu-    # Linux arm64
```

Release binaries: Linux x86-64 and arm64, Windows x86-64 and 32-bit.
Setting up the cross compilers: [Building](https://github.com/YadeWira/syc/wiki/Building).

## Use

The current command line is minimal and its file format provisional:
files it writes are not expected to open with later versions.

```sh
out/syc c -1 file          # -> file.sylz (levels -1 .. -12, -b MIB block size)
out/syc d file.sylz        # -> file
out/sylzbench -l 1,9 FILE  # in-memory benchmark, lzbench-style
```

Each block carries a CRC32 of its data, checked on decompression.

## Test

```sh
fpc -O3 -Fusrc -FUout/units -FEout tests/sylzfuzz.pas
out/sylzfuzz 3000 SAMPLE-FILES...
```

Roundtrips random, structured and real data at every level, decodes
corrupted and truncated blocks against guard-page buffers (any read or
write out of bounds faults), alternates the assembler and Pascal paths,
and checks the two compressors agree byte for byte. Linux only (uses
mmap).

## Layout

```
src/           sylz codec (sylz.pas) and the syc CLI (syc.pas)
bench/         sylzbench, sylzstats (sequence histograms of a block)
tests/         sylzfuzz
build.sh
NOTES.md       development log: measurements, FPC codegen findings
legacy/rust/   syc v0.1.x, the Rust archiver: README, NOTES and its sources
               archived in syc-rust-v0.1.29.zip
```

## Documentation

The [wiki](https://github.com/YadeWira/syc/wiki): format, benchmarks,
building, Free Pascal codegen notes, versioning, and the legacy Rust
version.

## License

Dual MIT / Apache-2.0.
