# syc

A streaming archiver and compressor with its own LZ codecs, written from
scratch in Free Pascal, with C and assembler for the hottest loops. Tuned
for modest hardware.

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
- 32-bit targets supported (the Pascal code paths run anywhere FPC does);
  the 32-bit x86 release binaries need SSE2 (Pentium 4 / Athlon 64 or
  later), used by the decoder.

Languages: Free Pascal first; C and x86-64 assembler only where Free
Pascal's code falls short, each next to a Pascal version that stays the
reference (the tests check they give the same bytes). C never becomes
the main language.

## sylz

The first codec: a fast LZ with separate control and literal streams, so
the decoder finds the next sequence at a fixed distance whatever the
literal length, and a token table derived from measured parses, so that
few sequences need a length extension (a branch the CPU can't predict).
Format v3 (`-ec`, extra compression, experimental) adds Huffman-coded literals, in 64 KiB
chunks with four interleaved streams; a v2 block is a valid v3 block.
Eleven levels, `-0` to `-10` (default `-1`): `-0` and `-1` are greedy
single-hash levels (`-1` with the bigger table); `-2` and `-3` use two
hash tables, keyed on 6 and 4 bytes (`-2` greedy, `-3` lazy); `-4` to
`-8` hash chains with lz4hc's parse (matches may start inside the
previous one and extend backwards); `-9` and `-10` an optimal parser over
a binary-tree match finder, whose prices include decode time, so it picks
cheaper sequences. The decoder is safe on corrupt input. Hot
loops have x86-64 assembler versions (Linux and Win64) next to the Pascal
ones, the optimal parser's DP a C one, and the fuzzer checks that every
path produces the same bytes.

silesia.tar, in memory, one block, one core (Xeon E5-2697A v4, 2.6 GHz),
everything in one session (2026-10-23; the machine was moderately busy,
load ~4, so speeds vary by ~10%). Fast and middle levels:

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4 1.10.0 | 507 MB/s | 3132 MB/s | 47.59% |
| misa77 0.6.0 --1 | 265 MB/s | 4069 MB/s | 46.74% |
| zxc 0.15.0 -3 | 155 MB/s | 3457 MB/s | 46.65% |
| **sylz -0** | 480 MB/s | 3070 MB/s | 46.51% |
| misa77 0.6.0 -0 | 166 MB/s | 3961 MB/s | 44.60% |
| **sylz -1** | **442 MB/s** | 3136 MB/s | 44.55% |
| zxc 0.15.0 -4 | 114 MB/s | 3442 MB/s | 43.43% |
| lz4hc 1.10.0 -2 | 224 MB/s | 2805 MB/s | 42.05% |
| **sylz -2** | **235 MB/s** | 2978 MB/s | **40.89%** |
| zxc 0.15.0 -5 | 68.8 MB/s | 3431 MB/s | 40.83% |
| lizard 2.1 -12 | 115 MB/s | 2791 MB/s | 40.68% |
| **sylz -3** | **187 MB/s** | 2958 MB/s | **39.99%** |
| **sylz -4** | **85.9 MB/s** | 2976 MB/s | 38.80% |
| lz4hc 1.10.0 -3 | 67.9 MB/s | 2823 MB/s | 38.38% |
| **sylz -5** | 61.9 MB/s | 3029 MB/s | 37.78% |
| misa77 0.6.0 -3 | 10.3 MB/s | 3874 MB/s | 37.76% |
| lz4hc 1.10.0 -4 | 57.6 MB/s | 2878 MB/s | 37.65% |
| **sylz -6** | 46.2 MB/s | 3061 MB/s | 37.13% |
| lz4hc 1.10.0 -6 | 42.4 MB/s | 3064 MB/s | 36.98% |

High ratios:

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4hc 1.10.0 -9 | 27.0 MB/s | 3050 MB/s | 36.75% |
| **sylz -7** | 35.7 MB/s | 3113 MB/s | 36.73% |
| lizard 2.1 -19 | 3.78 MB/s | 2879 MB/s | 36.52% |
| lz4hc 1.10.0 -12 | 9.39 MB/s | 3200 MB/s | 36.45% |
| **sylz -8** | 22.0 MB/s | 3135 MB/s | 36.38% |
| zxc 0.15.0 -6 | 9.31 MB/s | 2891 MB/s | 36.28% |
| **sylz -9** | 7.65 MB/s | **3449 MB/s** | **36.04%** |
| **sylz -10** | 6.45 MB/s | 3393 MB/s | **36.03%** |
| zstd 1.5.7 -1 | 350 MB/s | 1135 MB/s | 34.53% |
| **sylz -ec -8** (v3) | 21.6 MB/s | 2181 MB/s | 34.47% |
| **sylz -ec -9** (v3) | 7.44 MB/s | 2219 MB/s | 33.99% |
| **sylz -ec -10** (v3) | 6.37 MB/s | **2254 MB/s** | **33.98%** |
| zxc 0.15.0 -7 | 6.41 MB/s | 1978 MB/s | 33.09% |
| zstd 1.5.7 -2 | 238 MB/s | 814 MB/s | 32.70% |
| zstd 1.5.7 -3 | 153 MB/s | 678 MB/s | 31.20% |

On very redundant data -10 searches deeper than -9 and pays for it: zpaq-std's mixed sample 17.73% (-9) -> 17.59% (-10).

32-bit Windows and arm64 have no assembler: there the C paths run.
Windows 7 32-bit (a VM, mozilla): compress -1 282 MB/s, -4 66.6 MB/s,
-8 18.6 MB/s, decode 1640-2370 MB/s; the Pascal paths made 177, 39.8 and
11.1 MB/s, decode 850-1150 MB/s.
[Benchmarks](https://github.com/YadeWira/syc/wiki/Benchmarks#32-bit-windows-v0211).

`-ec` is format v3 (Huffman-coded literals, experimental): on silesia.tar
it beats zstd -1 on ratio at twice its decompression speed, but compresses
far slower; on mixed data zstd -1 is still smaller.

Competitors measured with lzbench 2.4.1 (GCC 14.2, no `-march=native`) on
the same core. More, and how: [Benchmarks](https://github.com/YadeWira/syc/wiki/Benchmarks).
The format: [sylz format](https://github.com/YadeWira/syc/wiki/sylz-format).

## Build

Free Pascal 3.2.2 and a C compiler for the target (gcc; mingw-w64 for
Windows; aarch64-linux-gnu-gcc for arm64; `CC` overrides), which
build.sh picks from the fpc options:

```sh
./build.sh                    # out/syc and out/sylzbench
./build.sh -Twin64            # Windows x86-64 (FPC's win64 units)
./build.sh -dSYLZ_PUREPASCAL  # no assembler, no C: Pascal paths only
FPC=ppcross386 ./build.sh -Twin32                  # Windows 32-bit
FPC=ppcrossa64 ./build.sh -XPaarch64-linux-gnu-    # Linux arm64
```

Release binaries: Linux x86-64 and arm64, Windows x86-64 and 32-bit.
Setting up the cross compilers: [Building](https://github.com/YadeWira/syc/wiki/Building).

## Use

The current command line is minimal and its file format provisional:
files it writes are not expected to open with later versions.

```sh
out/syc c -1 file          # -> file.sylz (-0 .. -10, -ec, -b MIB block size)
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
src/           sylz codec (sylz.pas, and sylzc.c: its C part), its Huffman
               coder (sylzhuf.pas), the syc CLI (syc.pas)
bench/         sylzbench, sylzstats (sequence histograms of a block)
tests/         sylzfuzz, sylzedge
plugin/        zpaq-std codec plugin and its test
build.sh       (and build-c.sh, which compiles the C part for the target)
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
