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
literal length, and a token table derived from measured parses, so that
few sequences need a length extension (a branch the CPU can't predict).
`--fast=2`, `--fast=1`, `-1` and `-2` are greedy single-hash levels (the
hash table doubles at each step); `-3` to `-10` use hash chains with lazy
matching; `-11` and `-12` an optimal parser whose prices include decode
time, so it picks cheaper sequences: `-11` decodes fastest of all levels. The decoder is safe on corrupt input. Hot
loops have x86-64 assembler versions (Linux and Win64) next to the Pascal
ones, and the fuzzer checks that both compressors produce the same bytes.

silesia.tar, in memory, one block, one core (Xeon E5-2697A v4, 2.6 GHz),
all in one session:

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4 1.10.0 | 492 MB/s | 2979 MB/s | 47.59% |
| zxc 0.15.0 -3 | 159 MB/s | 3464 MB/s | 46.65% |
| misa77 0.6.0 --1 | 277 MB/s | 3979 MB/s | 46.74% |
| **sylz --fast=2** | **565 MB/s** | 3364 MB/s | 48.64% |
| **sylz --fast=1** | **508 MB/s** | **3433 MB/s** | **46.51%** |
| **sylz -1** | 432 MB/s | 3421 MB/s | 45.26% |
| **sylz -2** | 322 MB/s | 3245 MB/s | 44.20% |
| misa77 0.6.0 -0 | 171 MB/s | 3963 MB/s | 44.60% |
| zxc 0.15.0 -4 | 117 MB/s | 3421 MB/s | 43.43% |
| zxc 0.15.0 -5 | 69.8 MB/s | 3454 MB/s | 40.83% |
| sylz -3 | 73.7 MB/s | 3002 MB/s | 40.75% |
| zxc 0.15.0 -6 † | 9.42 MB/s | 2755 MB/s | 36.28% |
| **sylz -11** † | 5.79 MB/s | **3683 MB/s** | 36.37% |
| **sylz -12** † | 2.77 MB/s | 3351 MB/s | **36.12%** |

Competitors measured with lzbench 2.4.1 (GCC 14.2, no `-march=native`) on
the same core († in a later session, on another core). More, and how: [Benchmarks](https://github.com/YadeWira/syc/wiki/Benchmarks).
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
out/syc c -1 file          # -> file.sylz (-1 .. -12, --fast=1/2, -b MIB block size)
out/syc d file.sylz        # -> file
out/sylzbench -l 1,9 FILE  # in-memory benchmark, lzbench-style
```

Each block carries a CRC32 of its data, checked on decompression.

## zpaq-std plugin

`plugin/` holds sylz as a codec plugin for
[zpaq-std](https://github.com/YadeWira/zpaq-std) (`-ma:sylz`, plugin ABI 1:
one exported C function, `zpaqstd_codec_v1`):

```sh
plugin/build.sh linux-x86_64                                  # out/plugin/linux-x86_64/sylz.so
plugin/build.sh win64                                         # .../win64/sylz.dll
FPC=ppcross386 plugin/build.sh win32 -Fu<rtl>/units/i386-win32
FPC=ppcrossa64 plugin/build.sh linux-arm64 -Fu<rtl>/units/aarch64-linux \
  -Fl/usr/lib/gcc-cross/aarch64-linux-gnu/14 -Fl/usr/aarch64-linux-gnu/lib
```

`plugin/test_plugin.c` loads a plugin the way zpaq-std does and checks the
contract: exported entry, ABI fields, roundtrips at every level,
`compress` never past `cap` (also when `cap` is too small), corrupt and
truncated streams, 8 threads at once, and that loading the library leaves
the process's floating-point state (MXCSR, x87 control word) alone. It
passes on Linux x86-64 and arm64 (qemu-user), Windows 10 x64 and
Windows 7 (32-bit plugin).

The plugin writes sylz format v2 as frozen at tag v0.2.2; a later sylz
format would be a new codec name in zpaq-std.

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
plugin/        zpaq-std codec plugin and its test
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

MIT, see [LICENSE](LICENSE).

The legacy Rust v0.1.x was published as MIT OR Apache-2.0; its archive in
`legacy/rust/` also holds third-party code (packJPG, packPNG, ppmd-rust)
under those projects' own licenses.
