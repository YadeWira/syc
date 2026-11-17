# syc

A streaming archiver and compressor with its own LZ codecs, written from
scratch in Free Pascal, with C and assembler for the hottest loops. Tuned
for modest hardware.

| Component | Status |
|---|---|
| CI | [![CI][ciBadge]][ciLink] |
| Latest release | [![Release][relBadge]][relLink] |

[ciBadge]: https://github.com/YadeWira/syc/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/syc/actions/workflows/ci.yml
[relBadge]: https://img.shields.io/github/v/release/YadeWira/syc?include_prereleases "Latest release"
[relLink]: https://github.com/YadeWira/syc/releases

| OS | Architectures | State |
|---|---|---|
| Linux | x86-64, arm64, x86 (32-bit) | CI and release binaries |
| Windows | x86-64, x86 (32-bit) | CI and release binaries; also tested on Windows 10 |
| macOS | arm64 (Apple Silicon) | CI and release binaries |

CI builds and tests every platform above and checks they all compress to
the same bytes, also with the Pascal-only build (`-dSYLZ_PUREPASCAL`).

**Status: v1.0.0.** Through 1.x the commands, their options, the exit
status, what scripts read from `syc l` and every file format stay as they
are ([Usage: what stays the same](https://github.com/YadeWira/syc/wiki/Usage#what-stays-the-same-for-scripts)).
syc v0.1.x was a Rust archiver; its sources are archived in
[`legacy/rust/`](legacy/rust/). v0.2 restarted the project in Free Pascal.

**Compatibility:** every later syc reads what an earlier one wrote, back
to 0.2.2; a frozen format never changes; `syc a` appends in the archive's
own format, and no format stops being read within 1.x. CI reads files
written by the released binaries of 0.2.2 to 0.9.0 (`tests/compat/`) on
every platform. The whole promise:
[Versioning and releases](https://github.com/YadeWira/syc/wiki/Versioning-and-releases#compatibility).

## Goals

"Modest hardware" is taken literally:

- bounded memory, small match-finder tables, reusable contexts: a stream
  takes about 15 MiB to compress and 10 MiB to decompress at any level, an
  archive with one thread 70–85 MiB to write and 25–30 MiB to extract
  (each thread adds about two blocks; numbers per level, 64- and 32-bit,
  in the wiki's [Memory and speed](https://github.com/YadeWira/syc/wiki/Memory-and-speed));
- good on 1–4 cores rather than needing 16;
- no AVX2 requirement: x86-64 baseline (SSE2) is enough;
- 32-bit targets supported (the Pascal code paths run anywhere FPC does);
  on 32-bit x86 the decoder picks its SSE2 version at run time (cpuid)
  where the CPU has SSE2, its i686 one elsewhere.

Languages: Free Pascal first; C and x86-64 assembler only where Free
Pascal's code falls short, each next to a Pascal version that stays the
reference (the tests check they give the same bytes). C never becomes
the main language.

## sylz

**syc writes sylz format v4 by default since v0.9.0, and v5 with `-ec`**
(below: [Formats v4 and v5](#formats-v4-and-v5-frozen-at-v080)); `-F 2`
writes the older formats v2 and v3, larger and slower but readable by
every syc since 0.2.14. The design below starts with v2 and v3, which v4
and v5 build on; the speed tables are v4 and v5.

The first codec: a fast LZ with separate control and literal streams, so
the decoder finds the next sequence at a fixed distance whatever the
literal length, and a token table derived from measured parses, so that
few sequences need a length extension (a branch the CPU can't predict).
Format v3 (`-F 2 -ec`; extra compression) adds Huffman-coded literals, in 64 KiB
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

silesia.tar, in memory, one block, one core (Xeon E5-2697A v4, 2.6 GHz,
Broadwell, 2016; pinned with `taskset`), 2026-11-17: sylz in its default
format v4 (`syc b`), the others in lzbench 2.4.1 (gcc 14.2), both best of
several runs. misa77's decoder is its unsafe one (UB on invalid input; its
safe one decodes `-1` at 3910 MB/s here); sylz's always checks its input.
On a newer CPU misa77 does better than here (its README: 5348 MB/s at
`-1` on a 14th-generation Core).

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4 1.10.0 | 511 MB/s | 3122 MB/s | 47.59% |
| misa77 0.7.0 --1 | 256 MB/s | 3801 MB/s | 46.74% |
| zxc 0.15.0 -3 | 148 MB/s | 3464 MB/s | 46.65% |
| **sylz -0** | **587 MB/s** | **4642 MB/s** | 44.67% |
| misa77 0.7.0 -0 | 157 MB/s | 3734 MB/s | 44.60% |
| zxc 0.15.0 -4 | 111 MB/s | 3427 MB/s | 43.43% |
| **sylz -1** (default) | **525 MB/s** | **4476 MB/s** | 42.82% |
| misa77 0.7.0 -1 | 46.7 MB/s | 3996 MB/s | 42.64% |
| lz4hc 1.10.0 -2 | 222 MB/s | 2874 MB/s | 42.05% |
| zxc 0.15.0 -5 | 68.7 MB/s | 3382 MB/s | 40.83% |
| lizard 2.1 -12 | 109 MB/s | 2631 MB/s | 40.68% |
| misa77 0.7.0 -2 | 37.7 MB/s | 3807 MB/s | 40.33% |
| **sylz -2** | **286 MB/s** | **3842 MB/s** | **39.39%** |
| **sylz -3** | 223 MB/s | 3948 MB/s | 38.59% |
| misa77 0.7.0 -3 | 10.4 MB/s | 3691 MB/s | 37.76% |
| lz4hc 1.10.0 -4 | 62.1 MB/s | 2685 MB/s | 37.65% |
| **sylz -4** | **99.0 MB/s** | **4010 MB/s** | **37.48%** |
| lz4hc 1.10.0 -6 | 39.7 MB/s | 2857 MB/s | 36.98% |
| lz4hc 1.10.0 -9 | 28.5 MB/s | 3053 MB/s | 36.75% |
| **sylz -5** | 70.2 MB/s | 3898 MB/s | 36.58% |
| lizard 2.1 -19 | 3.67 MB/s | 2809 MB/s | 36.52% |
| lz4hc 1.10.0 -12 | 9.40 MB/s | 3209 MB/s | 36.45% |
| zxc 0.15.0 -6 | 8.49 MB/s | 2780 MB/s | 36.28% |
| **sylz -6** | 52.6 MB/s | 3979 MB/s | 36.00% |
| **sylz -7** | 40.6 MB/s | 3951 MB/s | 35.65% |
| **sylz -8** | 25.6 MB/s | 3925 MB/s | 35.35% |
| **sylz -9** | 8.2 MB/s | 4228 MB/s | 34.92% |
| **sylz -10** | 7.3 MB/s | **4322 MB/s** | **34.91%** |
| zstd 1.5.7 -1 | 315 MB/s | 1028 MB/s | 34.53% |

With `-ec` (format v5: Huffman-coded literals; `-ec -0` .. `-8` parse as
`-2` .. `-10` do, `-ec -9` / `-10` price each literal by its code), same
session:

| codec | compress | decompress | ratio |
|---|---|---|---|
| **sylz -ec -0** | 252 MB/s | 2908 MB/s | 37.22% |
| **sylz -ec -1** | 195 MB/s | 2939 MB/s | 36.52% |
| **sylz -ec -2** | 92.9 MB/s | 2986 MB/s | 35.37% |
| **sylz -ec -3** | 69.5 MB/s | 3048 MB/s | 34.55% |
| zstd 1.5.7 -1 | 315 MB/s | 1028 MB/s | 34.53% |
| **sylz -ec -4** | 52.4 MB/s | 3099 MB/s | 34.00% |
| **sylz -ec -5** | 40.9 MB/s | 3103 MB/s | 33.68% |
| **sylz -ec -6** | 26.2 MB/s | 3149 MB/s | 33.39% |
| zxc 0.15.0 -7 | 6.13 MB/s | 1895 MB/s | 33.09% |
| **sylz -ec -7** | 8.4 MB/s | 3439 MB/s | 32.78% |
| **sylz -ec -8** | 7.5 MB/s | 3410 MB/s | 32.78% |
| zstd 1.5.7 -2 | 224 MB/s | 784 MB/s | 32.70% |
| **sylz -ec -9** | 5.8 MB/s | 3356 MB/s | 32.36% |
| **sylz -ec -10** | 5.1 MB/s | 3344 MB/s | 32.36% |
| misa77 0.7.0 -4 | 1.75 MB/s | 1502 MB/s | 32.34% |
| zstd 1.5.7 -3 | 158 MB/s | 676 MB/s | 31.20% |

On very redundant data -10 searches deeper than -9 and pays for it: zpaq-std's mixed sample 17.73% (-9) -> 17.59% (-10).

32-bit Windows and arm64 have no assembler: there the C paths run.
Windows 7 32-bit (a VM, mozilla, format v2, v0.2.11): compress -1 282 MB/s, -4 66.6 MB/s,
-8 18.6 MB/s, decode 1640-2370 MB/s; the Pascal paths made 177, 39.8 and
11.1 MB/s, decode 850-1150 MB/s.
[Benchmarks](https://github.com/YadeWira/syc/wiki/Benchmarks#32-bit-windows-v0211).


### Formats v4 and v5 (frozen at v0.8.0)

syc writes format v4 by default since v0.9.0, and v5 with `-ec`
(`--format 4` / `-F 4` asks for it explicitly; `-F 2` for v2 and v3).
**Frozen at v0.8.0** (the layout of 0.7.0, which they read; 0.6.0's
earlier layout is not read): from now on they never change. syc 0.7.0
and later read them; for readers older than that, write with `-F 2`.
What is new in them:

- three streams instead of two: one-byte tokens, offsets, literals;
- a match can take the previous match's offset again for no offset bytes
  (in structured data a fifth to a half of the matches do);
- what has no code of its own is written as two or three plain tokens
  instead of an escape, which the decoder takes without a branch;
- the token table starts as a built-in one in each block, and each chunk
  of tokens can replace entries of it (3 bytes each) with the pairs it
  uses most; a small block pays no more header than v2's;
- v5's Huffman chunks have eight interleaved streams.

On GitHub's own machines (silesia.tar, the formats interleaved level by
level, best of 3 rounds, 2026-11-14; `bench` workflow), how much faster
the new format is than the old one, in MB/s, over levels 0-10:

| machine | v4 vs v2, compress | v4 vs v2, decompress | v5 vs v3, compress | v5 vs v3, decompress |
|---|---|---|---|---|
| Linux x86-64 | +3% to +20% | +9% to +34% | +3% to +56% | +15% to +21% |
| Windows x86-64 | +3% to +13% | +3% to +19% | +3% to +52% | +12% to +15% |
| Linux arm64 | +3% to +11% | +20% to +31% | +3% to +51% | +23% to +32% |
| macOS arm64 | +2% to +20% | +17% to +39% | +4% to +59% | +22% to +38% |

(macOS: the average of two runs; its single runs move by ±5%, so one or
two levels per run, different each time, came out a few percent either
way.) In both formats every level is also 1.0-1.9 points smaller.

In cycles on one machine, the same levels as v2 and v3 (v5 at v3's `-ec` levels), one block of
each corpus, one core (CPU 17 of the Xeon E5-2697A v4, shared machine),
user-space cycles per input byte from `perf stat` (the difference
between 3 and 1 compressions, 2 and 1 at levels 7-10; 11 and 1 decodes;
the least of 2 interleaved rounds, 1 at levels 9-10), 2026-11-13:
**fewer cycles is faster**; on this CPU (2.6 GHz) MB/s is about 2600
divided by the cycles per byte (6.37 cycles/byte: ~410 MB/s; 0.768:
~3390 MB/s). Cycles, not seconds, because the machine is shared: its
MB/s move by ±10% with the load, its cycle counts hardly.

**silesia.tar, v4 against v2**

| level | ratio v2 | ratio v4 | compress v2, cycles/byte | compress v4, cycles/byte | change | decompress v2, cycles/byte | decompress v4, cycles/byte | change |
|---|---|---|---|---|---|---|---|---|
| 0 | 46.51% | **44.67%** | 6.37 | 5.83 | -8.5% | 1.030 | 0.768 | -25.5% |
| 1 | 44.55% | **42.82%** | 6.86 | 6.29 | -8.4% | 1.036 | 0.776 | -25.1% |
| 2 | 40.89% | **39.39%** | 12.42 | 11.45 | -7.8% | 1.102 | 0.902 | -18.2% |
| 3 | 39.99% | **38.59%** | 16.81 | 15.56 | -7.4% | 1.095 | 0.920 | -15.9% |
| 4 | 38.80% | **37.48%** | 36.55 | 33.66 | -7.9% | 1.082 | 0.900 | -16.8% |
| 5 | 37.78% | **36.58%** | 50.03 | 46.87 | -6.3% | 1.064 | 0.856 | -19.5% |
| 6 | 37.13% | **36.00%** | 66.43 | 63.28 | -4.7% | 1.091 | 0.886 | -18.8% |
| 7 | 36.73% | **35.65%** | 89.23 | 78.88 | -11.6% | 1.047 | 0.853 | -18.6% |
| 8 | 36.38% | **35.35%** | 145.05 | 119.63 | -17.5% | 1.053 | 0.844 | -19.8% |
| 9 | 36.04% | **34.96%** | 414.18 | 386.78 | -6.6% | 0.991 | 0.798 | -19.5% |
| 10 | 36.03% | **34.94%** | 494.01 | 448.45 | -9.2% | 0.988 | 0.880 | -10.9% |

**silesia.tar, v5 against v3**

| level | ratio v3 | ratio v5 | compress v3, cycles/byte | compress v5, cycles/byte | change | decompress v3, cycles/byte | decompress v5, cycles/byte | change |
|---|---|---|---|---|---|---|---|---|
| 0 | 38.80% | **37.22%** | 13.13 | 12.30 | -6.4% | 1.455 | 1.162 | -20.1% |
| 1 | 37.99% | **36.52%** | 18.38 | 16.35 | -11.0% | 1.422 | 1.171 | -17.7% |
| 2 | 36.72% | **35.37%** | 37.15 | 35.23 | -5.2% | 1.420 | 1.123 | -21.0% |
| 3 | 35.79% | **34.55%** | 51.28 | 47.48 | -7.4% | 1.401 | 1.097 | -21.7% |
| 4 | 35.18% | **34.00%** | 67.31 | 63.75 | -5.3% | 1.426 | 1.092 | -23.4% |
| 5 | 34.80% | **33.68%** | 91.20 | 81.45 | -10.7% | 1.382 | 1.133 | -18.0% |
| 6 | 34.47% | **33.39%** | 129.43 | 123.44 | -4.6% | 1.371 | 1.075 | -21.6% |
| 7 | 33.99% | **32.82%** | 413.29 | 382.99 | -7.3% | 1.330 | 1.028 | -22.7% |
| 8 | 33.98% | **32.80%** | 487.81 | 450.29 | -7.7% | 1.310 | 1.037 | -20.9% |
| 9 | 33.61% | **32.40%** | 839.28 | 563.90 | -32.8% | 1.384 | 1.057 | -23.6% |
| 10 | 33.60% | **32.38%** | 987.67 | 629.47 | -36.3% | 1.468 | 1.064 | -27.6% |

**mixed.tar, v4 against v2**

| level | ratio v2 | ratio v4 | compress v2, cycles/byte | compress v4, cycles/byte | change | decompress v2, cycles/byte | decompress v4, cycles/byte | change |
|---|---|---|---|---|---|---|---|---|
| 0 | 66.31% | **64.83%** | 4.70 | 4.24 | -9.8% | 0.990 | 0.856 | -13.5% |
| 1 | 65.59% | **64.23%** | 5.00 | 4.55 | -9.0% | 0.965 | 0.838 | -13.1% |
| 2 | 63.29% | **62.01%** | 12.08 | 9.68 | -19.9% | 1.028 | 0.943 | -8.3% |
| 3 | 62.89% | **61.73%** | 15.87 | 13.77 | -13.2% | 1.042 | 0.961 | -7.8% |
| 4 | 61.55% | **60.49%** | 44.17 | 29.44 | -33.4% | 1.046 | 0.943 | -9.8% |
| 5 | 61.10% | **60.10%** | 65.14 | 40.95 | -37.1% | 1.026 | 0.934 | -8.9% |
| 6 | 60.83% | **59.87%** | 78.63 | 51.50 | -34.5% | 1.040 | 0.929 | -10.7% |
| 7 | 60.68% | **59.75%** | 98.12 | 59.95 | -38.9% | 1.012 | 0.919 | -9.2% |
| 8 | 60.55% | **59.64%** | 122.45 | 88.72 | -27.5% | 1.003 | 0.902 | -10.1% |
| 9 | 60.42% | **59.40%** | 267.21 | 246.36 | -7.8% | 0.972 | 0.926 | -4.8% |
| 10 | 60.39% | **59.37%** | 372.89 | 297.37 | -20.3% | 0.934 | 0.859 | -8.1% |

**mixed.tar, v5 against v3**

| level | ratio v3 | ratio v5 | compress v3, cycles/byte | compress v5, cycles/byte | change | decompress v3, cycles/byte | decompress v5, cycles/byte | change |
|---|---|---|---|---|---|---|---|---|
| 0 | 59.78% | **58.48%** | 14.26 | 13.25 | -7.1% | 1.932 | 1.506 | -22.1% |
| 1 | 59.46% | **58.27%** | 19.29 | 16.51 | -14.4% | 1.888 | 1.497 | -20.7% |
| 2 | 58.30% | **57.15%** | 48.67 | 32.05 | -34.1% | 1.881 | 1.474 | -21.6% |
| 3 | 57.86% | **56.82%** | 68.88 | 45.63 | -33.8% | 1.852 | 1.447 | -21.9% |
| 4 | 57.62% | **56.61%** | 83.62 | 56.64 | -32.3% | 1.850 | 1.459 | -21.1% |
| 5 | 57.48% | **56.48%** | 94.72 | 66.79 | -29.5% | 1.870 | 1.466 | -21.6% |
| 6 | 57.35% | **56.40%** | 132.13 | 94.03 | -28.8% | 1.871 | 1.457 | -22.1% |
| 7 | 57.19% | **56.16%** | 275.80 | 249.82 | -9.4% | 1.803 | 1.428 | -20.8% |
| 8 | 57.16% | **56.13%** | 372.58 | 301.26 | -19.1% | 1.958 | 1.431 | -26.9% |
| 9 | 56.94% | **55.87%** | 543.00 | 402.72 | -25.8% | 1.835 | 1.443 | -21.4% |
| 10 | 56.91% | **55.85%** | 754.98 | 467.59 | -38.1% | 1.823 | 1.404 | -23.0% |

So at every level, on both corpora: **smaller** (v4 1.0 to 1.8 points
under v2, v5 1.0 to 1.6 under v3, and smaller on every file of Silesia
at every level), **faster to compress** (v4 5-18% fewer cycles than v2
on silesia.tar, 8-39% on the mixed corpus; v5 5-36% and 7-38% fewer
than v3) and **faster to decompress** (v4 11-26% and 5-14%, v5 18-28%
and 21-27%). More:
[Benchmarks](https://github.com/YadeWira/syc/wiki/Benchmarks) and the
sylz format page.

Competitors measured with lzbench 2.4.1 (GCC 14.2, no `-march=native`) on
the same core. More, and how: [Benchmarks](https://github.com/YadeWira/syc/wiki/Benchmarks).
The format: [sylz format](https://github.com/YadeWira/syc/wiki/sylz-format).

## Build

Free Pascal 3.2.2 and a C compiler for the target (gcc; gcc -m32 for
Linux x86; clang on macOS; mingw-w64 for Windows; aarch64-linux-gnu-gcc
for arm64; `CC` overrides), which build.sh picks from the compiler's
target:

```sh
./build.sh                    # out/syc and out/sylzbench
./build.sh -Twin64            # Windows x86-64 (FPC's win64 units;
                              #   with FPC's Windows installer: -Px86_64 -Twin64)
./build.sh -dSYLZ_PUREPASCAL  # no assembler, no C: Pascal paths only
FPC=ppcross386 ./build.sh -Twin32                  # Windows 32-bit
FPC=ppcrossa64 ./build.sh -XPaarch64-linux-gnu-    # Linux arm64
scripts/fpc-i386.sh /opt/fpc-i386                  # Linux x86: a 32-bit FPC
FPC=/opt/fpc-i386/fpc ./build.sh                   #   (needs gcc-multilib)
```

On macOS (`brew install fpc`) `./build.sh` builds as on Linux.

Release binaries: Linux x86-64, arm64 and x86, Windows x86-64 and 32-bit,
macOS arm64. The macOS ones are not signed: after downloading, run
`xattr -d com.apple.quarantine syc` (or allow it in System Settings ›
Privacy & Security).
Setting up the cross compilers: [Building](https://github.com/YadeWira/syc/wiki/Building).

## Use

Every command and option: [Usage](https://github.com/YadeWira/syc/wiki/Usage) (and `syc h CMD`).
The archive (`.syc`, format 2; encrypted: 4) and stream (`.sylz`, version 4;
encrypted: 6) formats are frozen, and read by every 1.x: [syc archive format](https://github.com/YadeWira/syc/wiki/syc-archive-format),
[syc stream format](https://github.com/YadeWira/syc/wiki/syc-stream-format).

```sh
out/syc a backup.syc docs/ photos/   # a new archive: deduplicated, solid blocks
out/syc a backup.syc docs/ photos/   # again: a new version with what changed
out/syc l -l backup.syc              # list (filters: paths, directories, globs)
out/syc i backup.syc                 # versions, sizes, deduplication
out/syc t backup.syc                 # check everything, write nothing
out/syc x backup.syc -o restore/     # extract (-f replaces, --skip leaves existing files)
out/syc x -u 1 backup.syc -o old/    # as of version 1 (or a date: -u 2026-10-24)
out/syc l --all backup.syc docs/     # every version of each file
out/syc a -p secret.syc docs/        # encrypted (asks for the password; or --password-file)
out/syc k secret.syc                 # a new password, in place (no recompression)

out/syc c -1 file          # -> file.sylz   (-0 .. -10, -ec, -b MIB, -t N threads; format v4)
out/syc c -F 2 file        # in sylz format v2 (v3 with -ec): for syc before 0.7.0
out/syc d file.sylz        # -> file        (keeps the input; --rm deletes it)
out/syc t file.sylz        # check it, write nothing
tar c dir | out/syc c > dir.tar.sylz       # no FILE: stdin -> stdout
out/syc i file.sylz        # its format, level, blocks and sizes (-v: each block)
out/syc h a                # every option of a command
```

Each command also goes by its word (`syc add`, `extract`, `list`, `info`,
`compress`, `decompress`, `test`, `key`). On a terminal there is a progress
bar, results read `✓ backup.syc  version 2 · 3 files · 1 directory` (on one
that shows Unicode; elsewhere ASCII), names come out with control
characters escaped, and `l -l` and `i` round their sizes (`-v`: exact);
into a pipe or a file the output is plain, as scripts read it. An existing output is not overwritten
without `-f`. Exit status: 0 ok, 1 an input skipped, 2 usage, 3 corrupt
data, 4 I/O error.

For developing syc, and for reporting a problem with it:

```sh
out/syc b FILE             # benchmark: every level in memory (--levels 1,4,9; -ec; -F 2; --time S)
out/syc s                  # self-test: is this build right on this machine?
out/syc r                  # report: build, machine, self-test, for a bug report
out/syc c --stats file     # at the end: bytes, time, speed, threads, peak memory
out/syc t --debug file     # an error's kind and where it happened; each phase's time
out/syc c --paths pascal file   # the reference Pascal instead of assembler and C:
                                #   the same bytes, or a fast path has a bug
out/syc -V                 # the version, the commit, the compiler, the paths in use
out/sylzbench -l 1,9 FILE  # the benchmark as a program of its own, lzbench-style
```

`syc s` runs the codec at every level and format through every code path
built in, damaged blocks, the checksums, hashes and ciphers against their
known answers, and a stream and an archive through the commands, in
about ten seconds. `syc r` lists the `SYC_*` variables that are set by name only,
never their values. `--color auto|always|never` (and `NO_COLOR`) decides
the colours.

Each block carries a CRC32 of its data, checked on decompression.

## zpaq-std plugins

`plugin/` holds one plugin file for
[zpaq-std](https://github.com/YadeWira/zpaq-std) (plugin ABI 1) with two
codecs: `sylz` (`-ma:sylz`, format v2) and `sylzec` (`-ma:sylzec`, format
v3: `-ec`'s), levels 0..10, default 1. It exports `zpaqstd_codec_v1`
(sylz, what zpaq-std 1.7 and earlier load) and `zpaqstd_codecs_v1(i)`
(0 sylz, 1 sylzec, then NULL). Before v0.4.2 sylzec was a file of its own.

```sh
plugin/build.sh linux-x86_64          # out/plugin/linux-x86_64/sylz.so
plugin/build.sh win64                 # .../win64/sylz.dll
FPC=ppcross386 plugin/build.sh win32 -Fu<rtl>/units/i386-win32
FPC=ppcrossa64 plugin/build.sh linux-arm64 -Fu<rtl>/units/aarch64-linux \
  -Fl/usr/lib/gcc-cross/aarch64-linux-gnu/14 -Fl/usr/aarch64-linux-gnu/lib
```

`plugin/test_plugin.c` loads the plugin the way zpaq-std does (`--codec N`
picks a codec of the list) and checks the contract: exported entry, ABI fields, roundtrips at every level,
`compress` never past `cap` (also when `cap` is too small), corrupt and
truncated streams, 8 threads at once, and that loading the library leaves
the process's floating-point state (MXCSR, x87 control word) alone. It
passes on Linux x86-64 and arm64 (qemu-user), Windows 10 x64 and
Windows 7 (32-bit plugin).

`sylz` writes format v2 as frozen at tag v0.2.2, `sylzec` format v3 as
frozen at tag v0.2.14 (a v3 block, or plain v2 when that is smaller);
a later format would be a new codec name in zpaq-std. For decoders
written elsewhere (zpaq-std's ZPAQL ones): `tools/sylz_ref.py`, a
reference decoder in Python written from the format description, and
`tests/sylzvectors.pas`, which writes test vectors (released as
`sylz-vectors.zip`).

## Test

```sh
fpc -O3 -Fusrc -FUout/units -FEout tests/sylzfuzz.pas
out/sylzfuzz 3000 SAMPLE-FILES...
```

Roundtrips random, structured and real data at every level, decodes
corrupted and truncated blocks against guard-page buffers (any read or
write out of bounds faults), alternates the assembler and Pascal paths,
and checks the two compressors agree byte for byte. Unix only (uses
mmap). `tests/clitest.sh` checks the commands and switches above;
`.github/test.sh` runs every test the way CI does, `syc s` and `syc r`
included.

## Layout

```
src/           sylz codec (sylz.pas, and sylzc.c: its C part), its Huffman
               coder (sylzhuf.pas), the syc CLI (syc.pas; sycdev.pas: bench,
               self-test, report; sycui.pas: terminal, colours, times)
bench/         sylzbench, sylzstats (sequence histograms of a block), modest.sh
               (speed and peak memory of every level, threads, block size)
tests/         sylzfuzz, sylzedge, sylzvectors (test vectors for other decoders),
               arctest.sh and clitest.sh (the commands end to end)
tools/         sylz_ref.py: a reference decoder in Python
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
