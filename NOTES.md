# syc in Free Pascal — development notes

Rewrite of syc in Free Pascal, keeping "tuned for modest hardware": bounded
memory, good on 1–4 cores, no AVX2 requirement (SSE2 baseline), 32-bit
targets supported. Algorithms first, written from scratch.

Competitors: misa77, lz5-ex, lizard, zxc (fast LZ); zstd, lz6 (LZ +
entropy); ultra-fast-lzma2 (high ratio).

### zxc (added 2026-10-18)

github.com/hellobertrand/zxc, BSD-3-Clause, C. Write-once/read-many like
sylz. Two block formats: GHI for the fast levels, one packed 32-bit word
per sequence (8-bit literals, 8-bit match - 5, 16-bit offset) with
extensions only past 255, so almost no escape branch; GLO for the others,
four streams (literals, 4/4-bit tokens, offsets 8- or 16-bit per block,
prefix-varint extras). 32-byte copies, a 4x unrolled decoder, offset
checks dropped past the first 64 KiB. Levels 6-7: price-based optimal
parse and Huffman literals in a SIMD-decodable layout (PivCo).

silesia.tar, same core (lzbench 2.4.1, no -march=native), load ~5:

| codec | compress | decompress | ratio |
|---|---|---|---|
| zxc -1 | 522 MB/s | 3936 MB/s | 61.76 |
| zxc -2 | 364 MB/s | 3894 MB/s | 53.86 |
| zxc -3 | 160 MB/s | 3422 MB/s | 46.65 |
| zxc -4 | 117 MB/s | 3414 MB/s | 43.43 |
| zxc -5 | 71.3 MB/s | 3407 MB/s | 40.83 |
| zxc -6 | 9.42 MB/s | 2755 MB/s | 36.28 |
| zxc -7 | 6.30 MB/s | 1856 MB/s | 33.09 |
| lz4 (same run) | 515 MB/s | 3080 MB/s | 47.59 |
| sylz -1 (same load) | 383 MB/s | 3103 MB/s | 44.18 |
| sylz -2 | 73.4 MB/s | 2892 MB/s | 40.75 |
| sylz -9 | 21.2 MB/s | 3333 MB/s | 36.60 |

zxc leads around 40-46% (sylz -2 vs zxc -5: -18% decode at the same
ratio); sylz leads around 36% (sylz -9 vs zxc -6: +21% decode). sylz
compresses 3.3x faster than zxc -4 at a similar ratio. zxc -7's 33%
has no sylz counterpart.

## Layout

- `src/sylz.pas` — sylz codec; `src/syc.pas` — minimal CLI
- `bench/sylzbench.pas` — in-memory benchmark, lzbench-style output;
  `SYLZ_DUMP=prefix` writes each compressed block to `prefix.LEVEL`,
  `SYLZ_NOASM=1` uses the Pascal paths only
- `bench/sylzstats.pas` — literal/match/offset histograms of a block
- `bench/sylztable.pas` — derives SYLZ_TOKENS from sample blocks
- `tests/sylzfuzz.pas` — roundtrip + corrupt/truncated input, guard-page buffers
- `build.sh` — builds the CLI and the benchmark into `out/`
- `legacy/rust/` — syc v0.1.x (Rust), with its own NOTES.md

Test data lives outside the repo, in `/mnt/IA_LAB/agentes/syc/`
(`silesia/`, `silesia.tar`, `mixed/` + `mixed.tar` (the table's training
mix), and `lzbench/` built from source).

## sylz format v2

Same block layout as v1; the token becomes an index into SYLZ_TOKENS:
210 exact (literals, match) pairs, literals <= 15 and match <= 32, then
46 escapes (literals exact + match extended, literals extended + match
exact, both extended). Full description at the top of `src/sylz.pas`.

Why: perf showed 65% of the decoder's branch misses on the "field
extended" branches, and 15.5% of level-1 sequences on silesia.tar needed
an extension with the 3/5 split. A branch-free extension made things
worse (see the profile below), so the fix had to be fewer extensions.
`bench/sylzstats` showed the joint (literals, match) distribution is
concentrated: the top 210 pairs inside the fixed-copy region cover
87.9-91.8% of sequences against 79.0-87.7% for the 3/5 split, measured on
silesia.tar and on mixed.tar (141 MB: 60 random samples each of text,
document, executable, font, other, poly, image and audio from the shared
corpus, 20 KB-3 MB), levels 1 and 9, each input weighted equally
(`bench/sylztable`, which prints the table). Larger fixed-copy regions
(literals up to 31, match up to 64) stay within a point and need wider
copies, so 15/32 it is.

| | v1 | v2 |
|---|---|---|
| silesia -1 ratio | 44.62% | 44.18% |
| silesia -9 ratio | 36.88% | 36.60% |
| mixed -1 ratio | 65.30% | 64.96% |
| mixed -9 ratio | 61.01% | 60.73% |
| silesia -1 decode | 3000 MB/s | 3150 MB/s |
| silesia -9 decode | 3209 MB/s | 3254 MB/s |
| mixed -1 decode | 3143 MB/s | 3411 MB/s |
| mixed -9 decode | 3196 MB/s | 3380 MB/s |

perf, per decode of silesia.tar -1: 256.7 M -> 238.5 M cycles, 599 M ->
504 M instructions, 3.28 M -> 2.49 M branch misses. At -9 cycles barely
move (236.9 -> 235.8 M): fewer misses, paid back by the table load.

The syc container's format version went to 1 with this change.

## sylz format v1 (superseded by v2)

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

2026-10-17 23:18, format v2, quieter machine (load ~1):

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4 1.10.0 | 544 MB/s | 3302 MB/s | 47.59 |
| misa77 --1 | 284 MB/s | 3995 MB/s | 46.74 |
| misa77 -0 | 171 MB/s | 3962 MB/s | 44.60 |
| misa77 -1 | 51.8 MB/s | 4118 MB/s | 42.64 |
| misa77 -3 | 11.3 MB/s | 3785 MB/s | 37.76 |
| lizard -10 | 436 MB/s | 2960 MB/s | 48.78 |
| zstd --fast=1 | 392 MB/s | 1402 MB/s | 41.01 |
| zstd -1 | 345 MB/s | 1146 MB/s | 34.53 |
| lz4hc -9 | 28.2 MB/s | 3230 MB/s | 36.75 |
| **sylz v2 -1** | 423 MB/s | 3178 MB/s | 44.18 |
| **sylz v2 -2** | 77.3 MB/s | 3069 MB/s | 40.75 |
| **sylz v2 -9** | 21.9 MB/s | 3229 MB/s | 36.60 |

### Decoder after format v2 (perf, 2026-10-18)

Method: per-decode counters as (40 iterations - 20 iterations) / 20, which
cancels file loading (a 0-iteration baseline varied by 20% with the page
cache).

silesia.tar -1, v0.2.2 decoder: 238 M cycles, 504 M instructions, 2.49 M
branch misses per decode. Branch misses by site (`branch-misses:pp`):
escape entry 52% (inherent to the format), offset < 16 14%, long-match
loop exit 11%, long-literal loop exit 9%, "match > 32" 8%.

- Counted path rewritten: its own 32-byte match copy without a length
  test (exact tokens have match <= 32), the stored distance - 1 kept with
  the -1 folded into the address displacement: 504 -> 453 M instructions,
  238 -> 236 M cycles.
- Escape path: 32 literal bytes and 64 match bytes copied
  unconditionally, loops only past them: 2.49 -> 2.32 M misses, 234 M
  cycles. Together +1-4% wall clock, same output.

Where the rest goes (`cycles:pp`): the match-source loads and their
stores. Per decode 2.77 M loads blocked by store forwarding (the match
source was written a few cycles earlier, by stores of another size or
alignment: offsets under ~64), 2.56 M L1 misses (nearly all L2 hits).

Encoder-side policies tried (format unchanged), silesia.tar:

| | size | decode cycles |
|---|---|---|
| -1 as is | 93.64 M | 232 M |
| -1, distance >= 32 | 98.23 M (+4.9%) | 220 M (-5%) |
| -1, distance >= 64 | 99.59 M (+6.3%) | 216 M (-7%) |
| -1, match >= 6 | 95.28 M (+1.8%) | 218 M (-7%), 19% fewer sequences |
| -1, match >= 6, distance >= 32 | 99.68 M (+6.4%) | 212 M (-9%) |
| -9 as is | 77.58 M | 224 M |
| -9, distance >= 64 | 78.47 M (+1.2%) | 212 M (-5%) |
| -9, match >= 6 | 83.40 M (+7.5%) | 217 M (-3.5%) |

Trade-offs, not wins; none made default. Each store-forwarding block
costs ~8 cycles (they overlap with other work), less than the ~15
assumed. A minimum distance is how misa77's format avoids them (its
distances start at hashtab_lag + 1). The only cheap one is match >= 6 at
level 1 (+1.8% size for -7% decode), a candidate for a decode-speed
level.

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
