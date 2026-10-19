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

- `src/sylz.pas` — sylz codec; `src/sylzhuf.pas` — its Huffman chunk
  coder (format v3); `src/syc.pas` — minimal CLI
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

## Bug review, 2026-10-19

A review of the changes since v0.2.4 (and a longer fuzz: 20000 cases with
32 files copied from the format-sample corpus, arm64 under qemu, and an
exhaustive edge test: sizes 0..300 x every level x v2/v3 x every output
capacity, 5.7 M cases, canaries past cap) found:

- **sylzhuf, since v0.2.4 (format v3 decoder): a one-byte heap write past
  the output.** A Huffman chunk declaring 5 symbols splits into runs of
  q = 2: 2, 2, 2 and -1, and stream 2 wrote dst[4..5], one past the end. The
  encoder only Huffman-codes chunks of >= 256 symbols, so only a crafted
  block reached it (litCount 5, or 65536k + 5). Fix: mode 1 needs
  n >= HUF_MIN_SYMBOLS (256); the fuzzer now also decodes single Huffman
  chunks with wrong declared sizes (it faults on the old code).
- **zpaq-std plugin: read format v3 too.** SylzDecompress reads v2 and v3,
  and the plugin passed blocks straight to it, so a crafted zpaq archive
  could reach the v3 decoder (and the bug above) through `-ma:sylz`.
  The plugin now refuses blocks with bit 31 set; the harness builds a
  valid v3 block and checks it is refused.
- **syc CLI: a failed decompression left a partial OUTPUT**, and had
  already truncated an existing file of that name. Now OUTPUT is written
  as OUTPUT.syc-partial and moved over OUTPUT in one step (rename on
  Unix, MoveFileEx with REPLACE_EXISTING on Windows) when complete;
  errors delete the partial file; OUTPUT = INPUT is refused.

The assembler compressors (levels 0-1 and 2-3) and the Huffman bulk loops
were checked against their Pascal versions branch by branch: no defect.

## Levels 2-3: two hash tables (2026-10-18)

The old level 2 (single hash, 2^16 entries) made 44.19% against level
1's 44.55%, at about the same speed; level 3 (hash chains, 2 attempts,
lazy) 40.75% at 70 MB/s, 7x slower. lz4hc -1/-2 ("LZ4MID": two hash
tables, greedy) made 42.05% at 211 MB/s, lizard -12 40.68% at 109.

Hash chains insert and search every position; perf put most of their
time on the head-table loads (two hot spots of 11% each, right after
them). Smaller tables, 16-bit heads, a 5-byte hash, a capped lazy step or
a single attempt moved them only to 60-77 MB/s (1 attempt: 41.37% at 77).

The two-table parser (Pascal; silesia.tar / mixed, one session):

| variant | silesia | compress | decompress | mixed | compress |
|---|---|---|---|---|---|
| greedy, no look at the next byte | 42.23% | 203 MB/s | 2990 MB/s | 64.02% | 191 MB/s |
| greedy + next byte's long candidate when len < 8 (**level 2**) | 40.89% | 187 MB/s | 3351 MB/s | 63.29% | 200 MB/s |
| greedy + that look for every len < 32 | 40.65% | 182 MB/s | 3121 MB/s | 63.19% | 200 MB/s |
| lazy, 2^15 tables | 40.29% | 167 MB/s | 3118 MB/s | 63.00% | 188 MB/s |
| lazy, 2^16 tables (**level 3**) | 39.99% | 139 MB/s | 3373 MB/s | 62.89% | 158 MB/s |
| old level 3 (hash chains) | 40.75% | 71 MB/s | 3027 MB/s | 62.60% | 53 MB/s |

x86-64 assembler (CompressMidX64, one routine for both levels, same
bytes as the Pascal; same session as lz4hc/lizard runs of the day):

| | silesia | compress | decompress | mixed | compress |
|---|---|---|---|---|---|
| sylz 1 | 44.55% | 473 MB/s | 3271 MB/s | 65.59% | 634 MB/s |
| **sylz 2** | 40.89% | **255 MB/s** | 3078 MB/s | 63.29% | 257 MB/s |
| **sylz 3** | 39.99% | **193 MB/s** | 3045 MB/s | 62.89% | 203 MB/s |
| sylz 4 (hash chains) | 39.35% | 63 MB/s | 3077 MB/s | 61.94% | 51 MB/s |
| lz4hc 1.10.0 -2 | 42.05% | 215 MB/s | 2833 MB/s | | |
| lizard 2.1 -12 | 40.68% | 109 MB/s | 2742 MB/s | | |

Pascal -> assembler: +35-45%. Level 2 at IPC 1.31 (memory bound: the
table loads and the candidate reads).

Found on the way (experiment harness, Int32 tables): 16-bit position
tables +35-40% compression speed, same output otherwise; 6-byte long hash
better than 8 (41.37 vs 41.69%); a 5-byte short hash decodes faster
(fewer short matches) but loses 0.4 points; inserting every position of
a match, or every 2nd-4th into the long table, cost 10-30% speed for
0.1-0.3 points; probe step shift 9 against 8, 10, 12: within noise.

## sylz format v3 (experimental, 2026-10-18)

v2 plus optionally Huffman-coded literals. Bit 31 of the block's first
u32 flags it (a v2 decoder rejects it as an impossible control length;
a v2 block is a valid v3 block). Literals go in chunks of 65536, each
raw or canonical Huffman (codes up to 11 bits, 128-byte nibble-packed
length table, four interleaved LSB-first streams), only when it saves at
least 4% of the chunk. Decoding is two-pass: chunks into a literal
buffer (kept in a TSylzDCtx), then the unchanged LZ decoder.

Why: order-0 entropy per 64 KiB chunk on silesia.tar promised literals
-13 to -21%, and -16% overall at level 12 with tokens and offsets too;
one histogram for the whole 212 MB promised only -4 to -9% (the tar mixes
data types). Measured Huffman sizes landed within 0.5% of the estimate.

Huffman decoder: per-symbol 8-byte big-endian loads with bounds checks
ran at 280-330 MB/s; FPC's SwapEndian is a call, so LSB-first streams
(no byte swap); branch-free refills (Giesen) in Pascal 380 MB/s, held
back by register pressure; x86-64 assembler with the bit buffers and
counts in registers and the read pointers on the stack: 800-830 MB/s
(~10 instructions per symbol). Reusing the literal buffer instead of a
GetMem per block: silesia -11 decode 1793 -> 2020 MB/s, mixed 1116 ->
1457.

Minimum gain per chunk: 0% / 4% / 8% gave mixed -11 decode 1035 / 1166 /
1297 MB/s at 57.26 / 57.37 / 57.80%; 4% kept.

Same session as zstd (load ~6):

| | silesia | decompress | mixed | decompress |
|---|---|---|---|---|
| zstd -1 | 34.53% | 1035 MB/s | 56.14% | 1080 MB/s |
| zstd -2 | 32.70% | 757 MB/s | 54.88% | 995 MB/s |
| zxc -7 | 33.09% | 1866 MB/s | 57.34% | 1725 MB/s |
| sylz -e -10 | 34.82% | 2062 MB/s | 57.60% | 1397 MB/s |
| sylz -e -11 | 34.29% | 2032 MB/s | 57.37% | 1441 MB/s |
| sylz -e -12 | 34.06% | 2080 MB/s | 57.26% | 1442 MB/s |

### Where v3's decode time goes (2026-10-18, v0.2.5 levels, CPU 20)

Decode only (sylzbench with SYLZ_LOAD), silesia.tar: v2 -10 3318 MB/s,
v3 -10 2446. The parse is the same (ctrl 42.3 MB, 34.3 M literals);
Huffman saves 12.7% of the literals, 2 points of ratio. perf on v3 -10:
LZ decoder 61% (as fast as in v2), Huffman bulk loop 25%, table builds
2%. The Huffman loop runs at IPC 2.35, 2.29 uops per cycle: **latency
bound**, not uop bound. Each stream's chain (shift, mask, table load,
length, add) is ~9-10 cycles per symbol; four streams give ~2.4 cycles
per literal, ~1.4-1.6 GB/s of literals here, about what huff0's
single-symbol decoder does on this generation.

Literals as a share of the output: 30% at -0, 27% at -1, 15-16% at -8 to
-10. At -1 Huffman saves 20% of them, at -10 13%.

Minimum gain per chunk (decode only, silesia / mixed):

| gain | -1 | decode | -8 | decode | mixed -1 | decode | mixed -8 | decode |
|---|---|---|---|---|---|---|---|---|
| 4% | 39.21% | 1686 | 34.82% | 2216 | 60.03% | 1264 | 57.60% | 1481 |
| 8% | 39.30% | 1749 | 35.01% | 2378 | 60.39% | 1414 | 58.07% | 1751 |
| 12% | 39.34% | 1765 | 35.25% | 2532 | 61.18% | 1585 | 58.73% | 1994 |
| 16% | 40.48% | 2055 | 35.46% | 2631 | 62.71% | 1917 | 59.62% | 2263 |
| 20% | 41.08% | 2205 | 35.74% | 2757 | 63.82% | 2148 | 60.01% | 2385 |
| 25% | 41.35% | 2263 | 35.83% | 2774 | 64.71% | 2349 | 60.52% | 2536 |
| v2 | 44.55% | 3295 | 36.60% | ~3300 | 65.59% | 3523 | 60.73% | 3416 |

No knee: decode speed and ratio trade almost linearly.

New bulk loop (kept): each stream keeps the 8 bytes at p in a register
and a count of the bits taken; a symbol is a lookup at buf >> count, a
reload moves p by count >> 3 bytes, five symbols per reload (7 + 5 * 11
= 62 bits). With BMI2's shrx (bytes in a `db`, FPC 3.2 lacks BMI2;
cpuid picks it at startup) +3-5% over the old loop; with shr cl the
same as the old one. Fewer uops, but the chain is unchanged, so little
gain. Eight streams would shorten the chain per literal but need 16
registers (8 buffers, 8 counts) or the buffers in memory; estimated at
best ~2.2 cycles per literal against 2.4.

Two symbols per lookup: the literals average ~7 bits (13% saved at
-10), so two rarely fit in an 11-bit index.

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

### Fast levels, 2026-10-18: 6-byte hash and a table-size ladder

Level 1 hashed 5 bytes into 2^14 entries. Sweep of hash width x table
size, silesia.tar (decode cycles per decode, perf, asm decoder):

| hash | table | compress | decode cycles | ratio | mixed ratio |
|---|---|---|---|---|---|
| 5 B | 2^13 | 481 MB/s | 232 M | 45.26% | 65.37% |
| 5 B | 2^14 (old -1) | 415 MB/s | 233 M | 44.18% | 64.96% |
| 5 B | 2^15 | 356 MB/s | 231 M | 43.55% | 64.71% |
| 6 B | 2^12 | 605 MB/s | 221 M | 48.64% | 66.96% |
| 6 B | 2^13 | 535 MB/s | 219 M | 46.51% | 66.31% |
| 6 B | 2^14 | 450 MB/s | 220 M | 45.26% | 65.86% |
| 6 B | 2^15 | 361 MB/s | 219 M | 44.57% | 65.60% |
| 6 B | 2^16 | 332 MB/s | 220 M | 44.20% | 65.45% |
| 7 B | 2^14 | 465 MB/s | 221 M | 47.24% | 67.27% |

A 6-byte hash decodes ~6% faster at every table size (fewer, longer
matches) and compresses faster; each doubling of the table costs ~15% of
compression speed for ~1 point of ratio. So the fast levels became a
ladder, all 6-byte hash: --fast=2 (level -2) 2^12, --fast=1 (-1) 2^13,
-1 2^14, -2 2^16; the chain levels moved up to -3..-12 (attempts
2..1024). --fast=1 beats lz4 on all three numbers in the same session
(508 vs 492 MB/s, 3433 vs 2979 MB/s, 46.51 vs 47.59%) and matches zxc -3
(3464 MB/s, 46.65%) at 3.2x its compression speed.

The cost is on executables, full of 4-5 byte matches: ooffice at -1
went 67.82% -> 70.27% (-2 gives 68.57%). Silesia lost 1.08 points at
-1, the mixed corpus 0.90.

The table size is now a run-time parameter, so the assembler shifts by
cl reloaded from the stack at each hash (rcx is free at all five): 2-4%
slower compression than an immediate shift, within the noise.

Tried and dropped (2026-10-18): two candidates per fast-level hash entry
(newest + previous, keep the longer match). Pascal compressor, so speeds
are relative only; silesia.tar unless noted:

| | memory | compress | ratio | decode cycles |
|---|---|---|---|---|
| 1 way 2^13 | 32 KB | 294 MB/s | 46.51% | 224 M |
| 2 ways 2^12 | 32 KB | 238 MB/s | 45.87% | 218 M |
| 1 way 2^15 | 128 KB | 250 MB/s | 44.57% | 221 M |
| 2 ways 2^13 | 64 KB | 200 MB/s | 44.33% | 218 M |
| 1 way 2^16 | 256 KB | 222 MB/s | 44.20% | 221 M |
| 2 ways 2^14 | 128 KB | 174 MB/s | 43.57% | 219 M |
| ooffice, 1 way 2^15 | | 176 MB/s | 69.16% | |
| ooffice, 2 ways 2^13 | | 168 MB/s | 69.68% | |
| ooffice, 1 way 2^16 | | 147 MB/s | 68.54% | |
| ooffice, 2 ways 2^14 | | 130 MB/s | 68.41% | |

At equal compression speed a bigger single table wins on ratio,
executables included; two ways only win on memory and by 1-2% decode
cycles.

### Optimal parser, levels 11-12 (2026-10-18)

A forward dynamic program over windows of 4096 positions: one literal
and every match length of every candidate (each length priced with the
nearest candidate reaching it), prices in bytes plus decode penalties
(per sequence, per escape token, per offset < 16). Literal runs are
priced as they grow; charging the literal extension to the match that
ends a run made the first version never end one (x-ray at 100%).

silesia.tar, CPU 20 (socket 1), sizes and decode cycles per decode:

| | size | compress | decode cycles |
|---|---|---|---|
| lazy, 256 attempts (level 10) | 77.58 M | 18.3 MB/s | 217 M |
| lazy, 1024 attempts (old level 12) | 77.43 M | 13.8 MB/s | 218 M |
| optimal, 64, no penalties | 77.04 M | 5.4 MB/s | 215 M |
| optimal, 64, penalties 0.5/1/0.5 | 77.06 M | 5.7 MB/s | 210 M |
| optimal, 64, penalties 2/4/2 | 79.58 M | 5.8 MB/s | 202 M |
| optimal, 64, penalties 4/8/4 | 88.09 M | 5.7 MB/s | 175 M |
| optimal, 16, skip 16 | 79.26 M | 17.4 MB/s | 217 M |
| optimal, 64, skip 32 | 77.51 M | 8.4 MB/s | 208 M |
| optimal, 256, penalties 1/2/1 | 76.67 M | 2.8 MB/s | 217 M |

At equal compression speed lazy parsing with deep chains beats the
optimal parser with shallow ones, and skipping inside long matches costs
more ratio than it saves time, so the optimal parser only takes the top:
level 11 = 64 attempts, level 12 = 256, penalties 0.5/1/0.5, every match
length up to 36 (limiting it barely changed speed: the cost is per
position, not per length). The lazy levels moved to 3..10.

Full ladder, same session:

| level | silesia | compress | decompress | mixed | compress | decompress |
|---|---|---|---|---|---|---|
| 10 | 36.60% | 22.0 MB/s | 3349 MB/s | 60.73% | 26.9 MB/s | 3148 MB/s |
| 11 | 36.37% | 5.79 MB/s | **3683 MB/s** | 60.63% | 9.98 MB/s | **3398 MB/s** |
| 12 | 36.12% | 2.77 MB/s | 3351 MB/s | 60.49% | 5.22 MB/s | 3326 MB/s |

Level 11 decodes fastest of all levels (the penalties pick cheaper
sequences). Against zxc -6 (36.28%, 2755 MB/s, 9.42 MB/s): level 11
decodes 34% faster at about its ratio, level 12 is smaller and 22%
faster; both compress slower.

### Fast levels 0-2, 2026-10-18: 16-bit hash tables

perf on the level-1 assembler compressor (silesia.tar): IPC 1.29, 28.7 M
branch misses (~26% of the time: "is the candidate a match" is
inherently unpredictable) and 108 M L1 misses: the 2^14-entry table of
u32 positions is 64 KiB, twice the L1. The window is 64 KiB, so a table
entry only needs the low 16 bits of a position: distance = (pos - entry)
mod 2^16, 0 meaning 65536; an entry older than 64 KiB was useless anyway
and now aliases to some position inside the window, which the 4-byte
check rejects. Half the memory, same or slightly better ratio. Pascal
and assembler still write the same bytes.

With cheaper tables the ladder moved up one step at levels 0 and 1
(2^12/2^14/2^16 -> 2^13/2^15/2^16): level 0's 2^13 table (16 KiB) still
fits in L1, and level 1's 2^15 trades 2.6% of speed for 0.7 points.
2^17 at level 2 cost 17% of speed for 0.18 points: no.

Same session, against the previous commit (assembler):

| | compress | ratio silesia | ratio mixed | decompress |
|---|---|---|---|---|
| 0 before | 572 MB/s | 48.64% | 66.96% | 3422 MB/s |
| 0 now | 539 MB/s | 46.51% | 66.31% | 3512 MB/s |
| 1 before | 426 MB/s | 45.26% | 65.86% | 3497 MB/s |
| 1 now | 503 MB/s | 44.55% | 65.59% | 3523 MB/s |
| 2 before | 320 MB/s | 44.20% | 65.45% | 3481 MB/s |
| 2 now | 479 MB/s | 44.19% | 65.45% | 3522 MB/s |

After the change, perf (cycles:pp) puts the level-1 compressor's time
in the 4-byte check of each candidate (random reads up to 64 KiB back,
often L2 hits: 8% + 6.6% of the samples), the table loads, and the match
length loop (~10%). A software prefetch of the next probe's candidate
(prefetcht0, output unchanged) made it 6-10% slower: the extra
instructions cost more than the latency they hide, which the out-of-order
core already overlaps.

The new fast parses need more escape tokens (silesia 14.9% at level 0,
12.6% at level 1; mixed 19.2% / 17.6%) than the token table was trained
on. A table retrained on them would cut that by 0.1-0.3 points, and a
larger fixed-copy region (literals <= 31, match <= 64) by at most 1.6:
those sequences have literal runs or matches long enough to need copy
loops whatever the table. Not worth a format change.

Register tweak in the fast compressor: mflimit compared from memory
(once per probe) frees r12 as scratch, so rcx keeps the hash shift for
the whole routine instead of a reload before each of the five hashes:
3% fewer instructions, cycles per silesia.tar compression -2.6% at level
0, -0.4% at 1, +0.3% at 2 (perf; wall clock is within noise). The rest
of the time is the inherently unpredictable "is the candidate a match"
branch (~16 M misses per compression) and the candidate loads.

Tried at the same time and dropped (Pascal compressor, relative): a
repeat-offset candidate when the hash misses (-0.1 to -0.3 points, -1
to -10% speed), inserting ip-1 or the start of long matches too (~0 /
up to -0.22 points at level 1 for -1 to -5%), a faster probe step
(skip 5: +3-9% speed in Pascal for +0.1-0.24 points, but no speed gain
at all in the assembler with 16-bit tables, where probing is no longer
the bottleneck).

Status (2026-10-18): levels 0 and 1 are closed. With the hash shift kept
in cl (-2.6% cycles at level 0) and the retrained token table measured
and dropped, what is left is the match branch and the candidate loads;
going further needs a different search design, not more tuning.

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
