# syc in Free Pascal — notes

Rewrite of syc in Free Pascal, keeping "tuned for modest hardware": bounded
memory, good on 1–4 cores, no AVX2 requirement (SSE2 baseline), 32-bit
targets supported. Algorithms first, written from scratch.

Competitors: misa77, lz5-ex, lizard (fast LZ); zstd, lz6 (LZ + entropy);
ultra-fast-lzma2 (high ratio).

## Layout

- `src/sylz.pas` — fast LZ codec
- `bench/sylzbench.pas` — in-memory benchmark, lzbench-style output
- `bench/lz4xcheck.c` — decodes a sylz v0 stream with the reference LZ4 decoder
- `tests/sylzfuzz.pas` — roundtrip + corrupt/truncated input, guard-page buffers
- `build.sh` — builds the benchmark into `out/`

Test data lives outside the repo, in `/mnt/IA_LAB/agentes/syc/`
(`silesia/`, `silesia.tar`, and `lzbench/` built from source).

## sylz format v0

Deliberately LZ4-shaped, to measure Free Pascal's codegen against C before
the format gets ideas of its own. It is byte-compatible with the LZ4 block
format: `LZ4_decompress_safe` decodes sylz v0 streams (checked on
silesia.tar at levels 1 and 9).

## FPC codegen findings

- `UInt32 * UInt32` is evaluated in 64 bits on x86_64: truncate with
  `UInt32(...)` before shifting a multiplicative hash.
- The decoder's speed is decided by register allocation. FPC 3.2.2 has 14
  usable GPRs and, when they run out, spills the hottest variable (`ip`)
  first. -O4, -OoUSERBP and -OoREGVAR don't change it. What works:
  - no calls in the hot loop (a single `Move` forces every live value into
    the 5 callee-saved registers); the exact tail decoder is a separate
    function;
  - a small live set: no saved sequence start, copy loops count the length
    down instead of keeping an end pointer, one variable reused as scratch.
  Check with `fpc -O3 -al` and count `(%rsp)` references in the loop.

## Measurements

silesia.tar (211,957,760 bytes), one block, single thread pinned with
`taskset`, Xeon E5-2697A v4 (Broadwell, 2.6 GHz). Shared machine: expect a
few percent of noise.

2026-10-17, lzbench 2.4.1 (GCC 14.2):

| codec | compress | decompress | ratio |
|---|---|---|---|
| lz4 1.10.0 | 511 MB/s | 3223 MB/s | 47.59 |
| lz4hc -9 | 27.9 MB/s | 2977 MB/s | 36.75 |
| lz4hc -12 | 8.98 MB/s | 2889 MB/s | 36.45 |
| misa77 -1 | 48.7 MB/s | 3899 MB/s | 42.64 |
| misa77 -3 | 10.3 MB/s | 3517 MB/s | 37.76 |
| lizard -10 | 391 MB/s | 2679 MB/s | 48.78 |
| lizard -19 | 3.61 MB/s | 2720 MB/s | 36.52 |
| zstd -1 | 311 MB/s | 996 MB/s | 34.53 |
| **sylz -1** | 172 MB/s | 1663 MB/s | 45.52 |
| **sylz -9** | 21.3 MB/s | 2238 MB/s | 37.13 |
| **sylz -12** | 12.2 MB/s | ~2200 MB/s | 37.05 |

Same stream, two decoders (codegen only):

| stream | LZ4 C decoder | sylz Pascal decoder | Pascal / C |
|---|---|---|---|
| sylz -1 | 2322 MB/s | 1663 MB/s | 72 % |
| sylz -9 | 2937 MB/s | 2238 MB/s | 76 % |

Decoder history on sylz -9: 830 MB/s (first version, `ip`/`op` on the
stack) → 2031 (call-free fast loop) → 1385 (small-offset copy pushed `ip`
back to the stack) → 2095 (smaller live set).
