# syc in Free Pascal — development notes

Rewrite of syc in Free Pascal, keeping "tuned for modest hardware": bounded
memory, good on 1–4 cores, no AVX2 requirement (SSE2 baseline), 32-bit
targets supported. Algorithms first, written from scratch.

Competitors: misa77, lz5-ex, lizard (fast LZ); zstd, lz6 (LZ + entropy);
ultra-fast-lzma2 (high ratio).

## Layout

- `src/sylz.pas` — sylz codec; `src/syc.pas` — minimal CLI
- `bench/sylzbench.pas` — in-memory benchmark, lzbench-style output;
  `SYLZ_DUMP=prefix` writes each compressed block to `prefix.LEVEL`,
  `SYLZ_NOASM=1` uses the Pascal paths only
- `bench/sylzstats.pas` — literal/match/offset histograms of a block
- `tests/sylzfuzz.pas` — roundtrip + corrupt/truncated input, guard-page buffers
- `build.sh` — builds the CLI and the benchmark into `out/`
- `legacy/rust/` — syc v0.1.x (Rust), with its own NOTES.md

Test data lives outside the repo, in `/mnt/IA_LAB/agentes/syc/`
(`silesia/`, `silesia.tar`, and `lzbench/` built from source).

## sylz format v1

`ctrlLen:u32le, control[ctrlLen], literals[...]`. Control entries are a
token (3 bits literal length, 5 bits match length - 4; all-ones = extended)
and a 16-bit `distance - 1`, then 255-run extensions if any. Literals are a
separate stream; what is left after the last sequence is the block's tail.
Full description at the top of `src/sylz.pas`.

Why: the next token is always 3 bytes on, whatever the literal length, so
the decoder's next loads don't wait on the current sequence (the idea
misa77's light format is built on). The bit split comes from measured
distributions on silesia.tar with the v0 parser: 0..6 literals cover
92.8-94.5% of sequences, matches of 4..34 bytes 94.9-97.3% (4..18, LZ4's
nibble, only 86.5-92.6%). Offsets under 16 are 1.6-2.3% of matches, so they
stay allowed behind a rarely taken branch. Repeat offsets are 2.6-4.6%:
with a fixed-size control entry they would save nothing, left for a later
format.

v0 (LZ4 block layout, kept in git history before 2026-10-17 22:00) was the
calibration step: `LZ4_decompress_safe` decoded its streams, and on them
the Pascal decoder ran at 72-76% of the C one.

## FPC codegen findings

All on FPC 3.2.2 x86_64, checked with `fpc -O3 -al` (count `(%rsp)`
references in the routine).

- `UInt32 * UInt32` is evaluated in 64 bits on x86_64: truncate with
  `UInt32(...)` before shifting a multiplicative hash.
- Register allocation decides the speed, and FPC gives a variable one
  location for the whole routine (no live-range splitting), so the
  routine's total variable count is what matters, inlined callees'
  locals included.
- A routine that makes any call keeps its variables only in the 5
  callee-saved registers (rbx, r12-r15). One `Move` in a hot loop is
  enough to push the rest to the stack.
- Passing a local by `var`, even to an `inline` function, pins it to the
  stack.
- Records larger than a register always live in memory. That is a tool:
  put values used only in comparisons (loop limits) in a record and the
  registers go to the pointers on the critical path.
- try/finally and managed locals (dynamic arrays) add an fpc_setjmp
  exception frame; the compressor loop kept nearly every local on the
  stack with one. Allocate in a wrapper, run the loop on raw pointers.
- The goto version of the fast compressor kept more locals on the stack
  (127 vs 104 references) and ran at 226 vs 273 MB/s.
- -O4, -OoUSERBP and -OoREGVAR made no difference to these loops.

## x86_64 assembler

`src/sylz.pas` has two assembler routines, used on x86_64 unless built
with `-dSYLZ_PUREPASCAL`; `SylzUseAsm := False` (or `SYLZ_NOASM=1` for the
bench) switches to the Pascal paths at run time.

- `DecodeFastX64`: the decoder's fast loop. Same results as the Pascal
  one; adds a counted mode: past the first 64 KiB of output no offset can
  be out of range, and k = min(ctrl room / 4, literal room / 8, output
  room / 64) common sequences fit the margins, so the loop only counts
  down k.
- `CompressFastX64`: level 1, same algorithm as `CompressFastCore` and the
  same output byte for byte. Used only when `cap >= SylzBound(n)`, which
  guarantees every sequence fits.

Both handle SysV (Linux) and Microsoft x64 (Win64: argument in rcx, rsi
and rdi callee-saved). Tested: the fuzzer alternates the paths and checks
the two compressors agree byte for byte; silesia.tar level 1 is identical
from both; Win64 build on the win10 VM roundtrips Silesia files with
both paths and gives the same sizes.

## Measurements

silesia.tar (211,957,760 bytes), one block, single thread pinned with
`taskset`, Xeon E5-2697A v4 (Broadwell, 2.6 GHz). Shared machine: runs
vary by up to ~10%.

2026-10-17 22:00, first levels, lzbench 2.4.1 (GCC 14.2):

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4 1.10.0 | 515 MB/s | 3105 MB/s | 47.59 |
| lz4 --fast -4 | 613 MB/s | 3169 MB/s | 51.45 |
| misa77 --1 | 260 MB/s | 3746 MB/s | 46.74 |
| misa77 -0 | 157 MB/s | 3907 MB/s | 44.60 |
| misa77 -1 | 50.4 MB/s | 4101 MB/s | 42.64 |
| lizard -10 | 433 MB/s | 2965 MB/s | 48.78 |
| zstd -1 | 345 MB/s | 1135 MB/s | 34.53 |
| zstd --fast=1 | 397 MB/s | 1405 MB/s | 41.01 |
| **sylz v1 -1** | 269 MB/s | 2347 MB/s | 44.69 |
| **sylz v1 -2** | 78 MB/s | 2257 MB/s | 41.05 |
| **sylz v1 -9** | 22.6 MB/s | 2493 MB/s | 36.88 |

2026-10-17 22:30, x86_64 assembler (same machine and core):

| codec | compress | decompress | ratio |
|---|---|---|---|
| **sylz -1, asm** | 402 MB/s | 2930 MB/s | 44.62 |
| sylz -1, Pascal | 262 MB/s | 2303 MB/s | 44.62 |
| **sylz -9, asm decoder** | 22.5 MB/s | 3150 MB/s | 36.88 |
| sylz -9, Pascal | 22.5 MB/s | 2456 MB/s | 36.88 |

Decoder asm steps: plain port +25% (2950 / 3100 MB/s at -1 / -9), counted
mode +2-3% more. At ~15 cycles per sequence for ~25 instructions, the
rest is stalls (memory, mispredicted extension and long-match branches);
`perf` is not available to tell which (perf_event_paranoid = 3).

### Decoder profile (perf, 2026-10-17 23:00)

`perf stat` on 20 decodes of silesia.tar minus a 0-iteration run (file
loading), asm decoder:

| | level 1 | level 9 |
|---|---|---|
| cycles per sequence | 17.4 | 16.0 |
| instructions per sequence | 40.8 | 39.0 |
| IPC | 2.34 | 2.44 |
| branch misses per sequence | 0.22 | 0.16 |
| L1 load misses per sequence | 0.57 | 0.73 |

Mispredictions at ~16 cycles each are about 20% of the time.
`perf record -e branch-misses:pp` (PEBS, exact branch) on level 1:

| branch | share of misses |
|---|---|
| literal field extended (`jae @ext` + its compare) | 49% |
| match field extended (`je @ext` + its compare) | 16% |
| long-literal copy loop exit | 12% |
| long-match copy loop exit | 9% |
| offset < 16 | 8% |
| match > 32 | 2% |

Tried and dropped:

- Branch-free one-byte extensions (cmov): 2400 vs 2930 MB/s. The next
  token's address then depends on this sequence's loaded bytes, a serial
  chain of loads; with the branch, the CPU predicts ctrl + 3 and runs
  ahead. The extension misses are a format problem, not a code one.
- Copying 48 match bytes unconditionally to drop the "match > 32" branch:
  4% more cycles, and that branch was only 2% of the misses.

Fast-level hash table size (sylz v1 -1): 2^12 entries 281 MB/s, 47.70%;
2^13 264 MB/s, 45.78%; 2^14 236 MB/s, 44.69% (chosen); 2^15 207 MB/s,
44.08%; 2^16 194 MB/s, 43.74%. With lz4's table size (2^12) the ratio
matches lz4's, at 55% of its compression speed: the gap is codegen.

Earlier, 2026-10-17 21:05 (v0):

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4hc -9 | 27.9 MB/s | 2977 MB/s | 36.75 |
| lz4hc -12 | 8.98 MB/s | 2889 MB/s | 36.45 |
| misa77 -3 | 10.3 MB/s | 3517 MB/s | 37.76 |
| lizard -19 | 3.61 MB/s | 2720 MB/s | 36.52 |
| sylz v0 -1 | 172 MB/s | 1663 MB/s | 45.52 |
| sylz v0 -9 | 21.3 MB/s | 2238 MB/s | 37.13 |

Decoder history on level 9: v0 830 MB/s (`ip`/`op` on the stack) → 2031
(call-free fast loop) → 2095 (smaller live set); v1 1834 (ll/ml passed by
var) → 2210 (extensions written inline) → 2458 (limits moved to a record).
