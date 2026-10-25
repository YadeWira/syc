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
  coder (format v3)
- `src/syc.pas` — the CLI's entry; `src/syccli.pas` — options and help;
  `src/sycstream.pas` — `c`/`d`/`t` on `.sylz` streams;
  `src/sycblocks.pas` — CRC-32, errors/exit codes, the block pipeline
- `src/blake2s.pas`, `src/syccdc.pas` — the archive's fragment hash and
  cutter; `tests/sycdedup.pas` tests them, `tools/syc_cdc_ref.py` is the
  reference written from the wiki's spec
- `src/sycarc.pas` — the archiver (`a`, `x`, `l`, `i`, `t` on archives);
  `src/sycfmt.pas` — its format, the index encoded/decoded and checked;
  `src/sycfs.pas` — paths, directory listings, metadata, globs;
  `tests/arctest.sh` — the archiver end to end, with damage
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

## Encryption, stages 3-4: the password, encrypted streams (2026-10-24)

- `src/sycenc.pas`: the key record (made with a random data key wrapped
  by Argon2id's key; opened slot by slot, the structure checked before
  any Argon2id runs), the subkeys, SealData / OpenData, the password.
- Password, in order: -pPASSWORD / --password=, --password-file (first
  line), SYC_PASSWORD, the terminal without echo (/dev/tty with termios;
  CONIN$ with ReadConsoleW on Windows), twice when creating. Checked
  through a pseudo-terminal: no echo, the two entries compared, a
  password with spaces and "ñ" the same typed and inline.
- Streams version 5 (`c -p`): each block sealed on its thread after
  compression (TJob.post), opened before decompression on its thread
  (TJob.pre, new); no CRC-32 (TJob.noCrc); the end sealed with the number
  of blocks. Refused (exit 3): a wrong password, each of 60 random byte
  flips, a stream cut at a block boundary with the end record copied
  after it, two blocks swapped, a byte after the end. `--raw` with a
  password is a usage error.

## Encryption, stage 2: the primitives (2026-10-24)

Plan and format: wiki "syc encryption" (draft, approved by the user).
`src/syccrypto.pas` (Pascal reference): BLAKE2b, Argon2id v1.3,
ChaCha20, HChaCha20, Poly1305 (5 x 26-bit limbs), XChaCha20-Poly1305,
RandomBytes (getrandom / BCryptGenRandom), SameBytes (constant time),
Wipe; `src/blake2s.pas` gained the keyed mode (also in the C lanes: a
lane runs the padded key block first).

- Test vectors fetched from the RFCs' text (RFC 7693 A, RFC 8439 2.3.2,
  2.4.2, 2.5.2, 2.8.2, xchacha draft 2.2.1 and A.3.1, RFC 9106 5.3) and
  checked against hashlib, cryptography, PyNaCl and OpenSSL before use;
  tests/cryptotest passes all of them with the Pascal and the C paths,
  on the first try.
- tools/crypto_xcheck.py recomputes `cryptotest --dump N` (random
  inputs: BLAKE2b at every length, keyed BLAKE2s one at a time and in
  lanes, ChaCha20 at random counters, Poly1305, XChaCha20-Poly1305 both
  ways, Argon2id with p 1-4 through OpenSSL and p = 1 also through
  libsodium): no mismatch on x86-64, arm64 (qemu), win32 and win64
  (wine), C and Pascal paths.
- Speed (x86-64, CPU 20): XChaCha20-Poly1305 Pascal 84 MB/s, C 473 (four
  ChaCha20 blocks in vector lanes, Poly1305 with 64-bit products);
  Argon2id m=64 MiB t=3 Pascal 406 ms, C 204. win32 (wine): 148 MB/s and
  435 ms in C.

## One plugin file, two codecs (2026-10-24)

zpaq-std asked (for its 1.8.0) for sylz and sylzec in one file, like
pja.dll: `zpaqstd_codec_v1` returns sylz as before (zpaq-std 1.7 and
earlier load the file unchanged), `zpaqstd_codecs_v1(int i)` returns 0
sylz, 1 sylzec, then NULL. Names, library strings and bytes unchanged:
66 compressions (both codecs, 11 levels, 3 files) identical to v0.4.1's
two files. plugin/test_plugin.c gained `--codec N` (and checks that entry
0 is zpaqstd_codec_v1's and that the list ends). Under wine the x64
harness reports MXCSR's precision flag (0x20, a status bit) set by
loading, with v0.4.1's DLL too; on Windows 10 both DLLs pass.

## syc c / d / t --raw (2026-10-24)

One bare sylz block, what SylzCompressEx (the plugins' compress()) writes:
no header, size or CRC; input up to 512 MiB; `d`/`t` need `--size N`
(SylzDecompress decodes into exactly N bytes). The blocks are the same
bytes as the plugin vectors' (tests/sylzvectors) at all 11 levels, v2 and
v3, 10 cases each; tools/sylz_ref.py decodes them.

## Formats frozen: archive format 2, stream version 4 (2026-10-24)

- Before freezing, a codec byte: the archive's version head grows from 16
  to 20 bytes (codec:u8, 1 = sylz, and three reserved zero bytes), the
  stream's header from 6 to 7 (version 4, codec after it). Other codecs
  on the roadmap can then live in the same formats. Archive format 1 and
  stream versions 1-3 (syc 0.2.2-0.3.4) are still read; a format 1
  archive is appended to in format 1, so syc 0.3.4 keeps reading it.
  syc 0.3.4 refuses the new ones with "format 2 / version 4 not
  supported" instead of misreading them.
- The wiki pages say every range and check a reader needs (the header's
  fragment parameters, block and fragment sizes, path and target
  lengths, reference ranges, where blocks, index and commit must meet).
- `tools/syc_ref.py`: a reference reader in Python written from those
  pages (sylz blocks through tools/sylz_ref.py): lists, extracts, checks
  every CRC and fragment hash, finds the complete versions by structure
  first, as the page says.
- `tests/syc_vectors.py` writes test vectors with syc from trees it
  builds (mtimes, permissions, setuid, links, a dangling one, non-ASCII
  names, sizes around the limits, duplicates, four versions with a type
  change and a path coming back, -ec and stored blocks, several blocks, a
  tail after the last version, three damaged archives; six streams); the
  expected states come from the trees, not from syc. tests/arctest.sh
  writes them and checks them with the reference reader and `syc t`.

## Verifications left from the CLI stages (2026-10-24)

- **Owner, as root** (sudo, in a scratch directory): files, a directory
  and a symlink owned by other uids, a setuid file owned by root; `x` as
  root gives back every owner (the link's with lchown) and the setuid bit
  (chmod after chown); `--no-owner` as root leaves root; a user extracts
  them as their own, without an error.
- **Symlinks on Windows without the right** (Windows 10, developer mode
  off): run as a temporary standard user (medium integrity) through a
  scheduled task, its batch logon right granted with secedit and the
  original policy put back after; each link "cannot create the symlink",
  files and directories extracted, exit 1. (A process started with other
  credentials from the SSH session fails with 0xC0000142; the VM's own
  user has UAC off, so its tasks run elevated.) User, profile (after a
  restart), task and policy removed or restored.
- **Progress in a Windows console**: on by default there (stderr is a
  console), rewritten in place; seen in a screenshot of the VM (`vm shot`).
- `syc l -l` shows setuid, setgid and sticky as ls does (s/S, t/T).

## Archiver speed: a reader thread, BLAKE2s in four lanes (2026-10-24)

silesia (212 MB), level 1, CPUs 20-23, before -> after:

| | 1 thread | 2 | 4 |
|---|---|---|---|
| `a` | 1.63 -> 1.38 s | 1.16 -> 0.75 | 1.02 -> 0.70 |
| `t` | 0.81 -> 0.51 | | 0.31 -> 0.22 |
| `x` (tmpfs) | 0.90 -> 0.64 | | 0.46 -> 0.37 |

The archives are the same bytes as before.

- perf (`a -1 -t 4`, a copy built with -Xs-: Debian's fpc.cfg strips by
  default) showed the main thread at 38% of all samples, doing the
  cutting (13%), its share of the hashing, Move, the kernel's page
  clearing (a new 2 MB read buffer per file) and the reads.
- **Reader thread** (-t 2 and up): reads and cuts into three 8 MiB
  batches in turn while the main thread hashes (with the pool) and stores
  the one before. With -t 1 the same code runs in turn on one thread. One
  read buffer for every file.
- **Cutter in C**: 806 -> 1240 MB/s (the loop is the hash's dependency
  chain, a shift, an add and a load a byte). Same cuts as the Pascal one
  on all of silesia.tar (tests/sycdedup compares them at every cut).
- **BLAKE2s, four messages at a time** (sylzc_blake2s_many): lane k of
  each vector is a message of its own; a lane whose message ends takes
  the next one, the last one or two finish on the scalar code. GCC's
  vector extensions, so SSE2 on x86-64 and NEON on arm64 from one source.
  64 KiB messages: 372 -> 765 MB/s; the message loaded with vector loads
  and a 4x4 transpose 792. Compiled for SSSE3 (pshufb for the 8- and
  16-bit rotations) it was no faster. On 32-bit x86 the 16 state vectors
  do not fit its 8 registers: 196 MB/s against 310 one at a time (wine),
  so i386 hashes one at a time. `a` hashes groups of 8 fragments a task;
  `t`/`x` hash a block's fragments together on the thread that decoded it.
- What is left, by CPU share at -t 4: sylz level 1 itself (~30%),
  BLAKE2s, CRC-32 (8%), the cutter; and the kernel clearing the pages of
  the pipeline's 2N block buffers on first use.

## CLI stage 8: progress, help, Usage page (2026-10-24)

- TProgress (sycblocks): one line on stderr rewritten with CR at most 5
  times a second: percent, bytes, speed, time left (bytes and speed only
  when the total is unknown, as for stdin). On by default when stderr is
  a terminal and not -q; --progress / --no-progress. `a` counts the bytes
  read of the files to store, `x` the bytes written, `t` the bytes
  checked, `c` the bytes read, `d` the compressed bytes read.
- The help: one summary (syc h) and a page per command (syc h CMD);
  the wiki's Usage page has the rest.

## Archiver stage 7: symlinks on Windows (2026-10-24)

- Stored: a reparse point tagged as a symlink (its print name, read with
  FSCTL_GET_REPARSE_POINT; a relative target with "/" as on Unix), and
  whether it points to a directory (the directory attribute kept in its
  Windows attributes: Windows makes the two kinds differently).
  Junctions are skipped (not followed either); other reparse points
  (cloud placeholders, deduplicated files) are ordinary files and
  directories, for IsLink too.
- Made with CreateSymbolicLinkW, asking for an unprivileged link
  (developer mode, Windows 10 1703+) and without that flag where it is an
  invalid parameter; without the privilege it fails with a warning (exit
  1). A link from a Unix archive is a directory link if its target is a
  directory once everything else is extracted. Times are set on the link
  itself (FILE_FLAG_OPEN_REPARSE_POINT), attributes are not.
- Windows 10, x86-64 and 32-bit: file and directory symlinks stored and
  made again, Linux links (to a file, a directory, dangling) made on
  Windows and read through; the Windows archive's links made on Linux.
- With that the metadata of the plan is all there: times, Unix mode and
  owner (restored as root only), Windows
  attributes, symlinks, empty directories. Not stored: hard links (as
  separate files, deduplicated), extended attributes, ACLs, alternate
  streams, devices, sockets and FIFOs.

## Archiver stage 6: versions (2026-10-24)

- `syc a` on an existing archive appends a version with what changed
  since the last one: an entry whose metadata (type, size, mtime,
  attributes, owner, link target) matches is left out without reading
  the file; new fragments are deduplicated against every version (the
  table is filled from the indexes). Deletions: what was under one of the
  PATHs and is gone, unless excluded (-X), unreadable this time, or
  --no-delete. No change: no version written (exit 0).
- Like zpaq, a file changed without a new size or mtime is not seen.
- The append writes in place after the last good commit (cutting what an
  interrupted syc a left), flushes the data and index before the commit
  and the commit after it; a failure truncates back. tests/arctest.sh
  cuts the last version at 7 points (and a manual run at 27 more): `t`
  says 1, the next `a` cuts and appends, the archive checks clean.
- An archive cut down to its 8-byte header takes a first version.
- `l --all`: every entry of every version, by path then version.
- 338 MB tree (silesia + mixed), 4 threads: first `a` 2.69 s; again with
  nothing changed 0.02 s; one 51 MB file with a byte appended 0.39 s, 22.8
  kB written (the rest found in repeated fragments).
- Windows 10 (x86-64, 32-bit): versions, -u, deletions, the no-change run,
  the cut version recovered.

## Archiver stage 5: syc x (2026-10-24)

- **Order**: what happens to each entry (write, replace, skip) is decided
  first; then the blocks the written files need, in path order, are
  decoded ahead by the pipeline (each fragment's hash checked on the
  decoding thread) and the main thread writes. A block needed again later
  (dedup across files) is decoded again: memory stays at 2N blocks.
- **Safety**: stored paths have no `..` (checked when the index is read);
  no file is written through a symlink: a directory on the way that is a
  symlink skips the entry (exit 1), and the archive's own symlinks are
  made after every file. Files go to NAME.syc-partial and are renamed;
  a corrupt block stops with exit 3 and no partial file left.
- **Metadata**: Unix mode, mtime to the ns (libc utimensat, also on
  symlinks), owner when root (lchown); directories last, deepest first.
  Windows: times (directories too) and attributes (read-only, hidden,
  system, archive), the read-only one after the times. Symlinks are not
  made on Windows yet (warning, exit 1).
- Windows: ReplaceFile used MoveFileEx's ANSI version, so a Unicode name
  could not be renamed into place (in `x`, and in `c`/`d` too); now
  MoveFileExW.
- silesia (212 MB, tmpfs, CPUs 20-23): `x` 0.90 s with 1 thread, 0.46 s
  with 4; `d` of the tar's stream 0.35 / 0.31 s. The difference is the
  BLAKE2s check of every fragment, which `d` (CRC-32 only) does not do.
- tests/arctest.sh compares the extracted tree with the original
  (contents, types, permissions, mtime in ns, link targets) after `x`,
  `x -t 4` of an `-ec` archive, `x -` from stdin, and `x -f`; Windows 10
  checked by hand (x86-64 and 32-bit: contents, times, attributes,
  Unicode names, `-f` over read-only files).

## Archiver stage 4: syc a (one version), l, i, t (2026-10-24)

- **Reading** goes back from the last commit; an end that is not a commit
  falls back to a forward scan to the last whole version (warning, exit
  1). Every count in an index is bounded by the bytes left, a varint over
  the range is an error (a 2^63 count turned negative passed the first
  bound check), file sizes are checked against their fragments and the
  blocks must lead exactly to the index. tests/arctest.sh: 200 random
  byte flips all found by `t` (exit 3), `l`/`i` exit 0 or 3, 100
  truncations exit 3, junk after the commit exit 1.
- **stdin** (`l -`, `i -`, `t -`) goes through a temporary file: a
  forward pass cannot know where fragments are before the index.
- **Same archive whatever -t** (version time masked): fragments are hashed
  in parallel in 8 MiB batches, then deduplicated and packed in order.
- silesia (directory, 212 MB), CPUs 20-23: `a -1` 1.63 s with 1 thread,
  1.03 with 2, 0.97 with 4 (`c -1` on silesia.tar: 0.71 / 0.37); `t` 0.81
  / 0.43 / 0.31 s once each block's fragments are hashed by the thread that
  decoded it (0.73 with 4 threads when the main thread hashed). Size: the
  archive 94.55 MB against the tar's stream 94.50 MB at -1. What stays
  serial in `a`: reading and cutting (~0.25 s) and the batch's hashing
  wait; overlapping the next batch's cutting with this one's hashing, and
  SIMD BLAKE2s, are what is left.
- **Windows**: FPC 3.2's strings are in the ANSI code page, so a name
  like ñandú-日本.txt could not be opened. syc now sets the conversion,
  file-system and console code pages to UTF-8 and reads its command line
  with CommandLineToArgvW; checked on Windows 10 (x86-64 and 32-bit).
  Reparse points (symlinks, junctions) are skipped until stage 7.
- `sycblocks`: TJob.post (work done on the job's thread after its block,
  here the hash check) and TTaskPool (a parallel for).

## The archive's dedup pieces: BLAKE2s and the cutter (2026-10-24)

Format: wiki "syc archive format". Fragments cut by a gear hash, FastCDC
normalization (16 KiB / 64 KiB / 512 KiB), identity BLAKE2s-256.

- The cuts and hashes match `tools/syc_cdc_ref.py` (written from the
  spec, hashlib's blake2s) on empty, 1000 bytes, exactly the minimum,
  minimum + 1, 3 MB of zeros, x-ray, samba; x86_64, arm64 (qemu) and
  win32 (wine) dump the same fragments.
- silesia.tar: 2807 fragments, mean 73.7 KiB (normalization keeps it
  near the target; uniform random data 72.3). 100 bytes inserted at 1/3:
  99.97% of the bytes in fragments found again.
- First test data was an LCG's low byte, which repeats every 64 KiB: every
  fragment came out exactly 64 KiB and "100%" found again. The tests use
  xorshift32 now.
- Speed, silesia.tar, CPU 20: BLAKE2s in Pascal ~160 MB/s; in C with a
  loop over the sigma table 332; with the ten rounds unrolled (sigma's
  indices constant, so m stays in registers) 393. The cutter alone ~900
  MB/s; cutter + hash 279 MB/s. Hashing is the archiver's own cost per
  byte (level 1 compresses at ~450 MB/s): SIMD BLAKE2s (SSE2/SSSE3, 4
  lanes) or hashing on the worker threads are the next steps if `syc a`
  measures it as the bottleneck.

## Format v3 frozen, the sylzec plugin (2026-10-23)

Writing test vectors for zpaq-std showed v3 was hardly ever used on small
blocks: EncodeLiteralChunks got the v2 literal stream's size as its
limit and wanted room for each chunk's raw form inside it, so a block of
one chunk (under ~65536 literals) never became v3, and -ec -9/-10's
parse, priced for v3, was then emitted as v2 (worse than plain v2: dickens'
first 200 KB 92201 bytes against 88001). Now the chunks get the output's
room and v3 is kept when smaller: dickens 200 KB -ec 8 80862, -ec 10
78622 bytes; 2 MB slices and silesia.tar unchanged (their earlier chunks
left the room).

The sylzec plugin (plugin/sylzec_zpaqstd.pas; zs_codec.inc shared with
sylz's): name "sylzec", library "sylz format v3 (syc 0.2.14)", levels
0..10 (-ec's), default 1, decodes v2 and v3. tools/sylz_ref.py decodes
both formats from the wiki's description alone; it agrees with sylz on
all 220 vectors of tests/sylzvectors.pas (10 cases x 11 levels x 2
formats: empty, one byte, all equal, random, text, binary, multi-chunk
with a short last chunk, 11-bit codes, generated text, under 256
literals).

## Format v3: chunk mode 2 (2026-10-23)

A Huffman chunk's stream 4 ended where its last code did, so the next
chunk's place was only known after decoding this one: no decoding chunks
in parallel. Mode 2 stores all four stream sizes (+2 bytes per 64 KiB
chunk: +778 bytes on silesia.tar's 82 MB at -ec 0), and the chunk is
exactly its header plus them. Mode 1 is still read (v0.2.4-0.2.13
files); older decoders reject mode 2, and syc writes container version 3
for -ec files so v0.2.13 says "format version 3 not supported" instead
of "corrupt". The fuzzer also decodes each Huffman chunk converted back
to mode 1.

## syc -th: threads (2026-10-23)

`-th N` (now `-t N` / `--threads N`; default 1): blocks are compressed and decompressed N at a time;
the output is the same whatever N. A pipeline of 2N slots, slot k worked
on by thread k mod N, the main thread reading the next blocks into free
slots and writing finished ones in order.

First version: batches (read N blocks, run, write N). Decompression got
slower with threads (silesia.tar 0.43 s with 1, 0.71 s with 2): same
instructions and cycles, but 1.56 GHz against 2.75 (perf): each block
decodes in ~1.5 ms, so the workers ran in bursts and their cores never
left a low clock. The pipeline keeps them busy.

The CRC-32 ran byte by byte at a few hundred MB/s and was the CLI's real
limit: slicing by 8 (now in C, sylzc_crc32; FPC's slicing ran at ~1.2
GB/s, gcc's the same within noise here, the kernel's writes dominate
after it).

silesia.tar on CPUs 20-23, seconds (1 / 2 / 4 threads): compress level 1
0.68 / 0.46 / 0.39 (was 1.16 single-threaded with the old CRC), level 4
2.56 / 1.47 / 0.87, -ec -9 55.6 / - / 17.5; decompress 0.33 / 0.31 /
0.34 (was 0.79): bound by the main thread's writes (half the time in the
kernel) after the CRC fix.

## Format v3 levels (2026-10-23)

-ec levels 0..8 parse as v2's 2..10: v2's 0 and 1 leave 27-30% of the
output as literals, which Huffman-coded decode slower than level 2's
parse and compress worse (silesia.tar -ec on v2's 0 / 1 / 2: 40.11% 1655
MB/s, 39.21% 1795, 38.80% 2209).

-ec 9 and 10 are new: the optimal parser with each literal priced by its
Huffman code instead of a byte. A first parse (v2 prices) counts the
literals per 256 KiB region; their code lengths (as HufEncodeChunk would
build them; 8 bits where the chunk would stay raw) plus a 1-bit penalty
price the parse that is emitted. Prices are now in bits (OPT_SCALE 8;
v2 output unchanged, checked on every path). silesia.tar / mixed / zpaq-
std's sample, against -ec 8:

| | silesia | mixed | sample | compress (silesia) | decode only (silesia) |
|---|---|---|---|---|---|
| -ec 8 | 33.98% | 57.15% | 16.82% | 6.5 MB/s | 2311 MB/s |
| -ec 9 (level 9's tree) | 33.61% | 56.94% | 16.81% | 3.8 MB/s | 2196 MB/s |
| -ec 10 (level 10's tree) | 33.60% | 56.91% | 16.69% | 3.3 MB/s | 2204 MB/s |

Tried: no penalty 33.70% (and slower decode: more literals); 2 bits
33.71%, decode back at level 8's; 64 KiB regions 33.72%; a third parse
priced from the second's literals 33.58% (+50% time); accumulating both
parses' counts 33.70%. The 1-bit penalty helps the ratio too: the first
parse's lengths miss each chunk's table and the shift in statistics the
cheaper literals cause.

## C (2026-10-23)

New rule from the user: the project is Free Pascal, C and embedded
assembler, C never the main language; C goes where FPC's code falls
short. First use: the optimal parser's DP (sylzc_opt_dp in src/sylzc.c),
FPC's version spilled its many live values to the stack. The window now
runs in three passes (candidates from the tree; the DP over them, in C
or Pascal; the path), same output byte for byte on silesia, the mixed
corpus and zpaq-std's sample. The DP went from ~39% of level 9's cycles
to 25% (~1.6x), but the separate candidate pass costs ~5%: total cycles
-5% (level 9) and -3% (level 10). What is left is the tree (64%,
assembler, memory bound).

The decoder in C (sylzc_decode: DecodePas's fast loop and margins, and
DecodeSafe), the fast path where there is no assembler (32-bit Windows,
arm64). x86_64, silesia.tar decode, level 1 / 8 / 10: assembler 3372 /
3433 / 3693 MB/s, C 2900-3060 / 2770-2950 / 3020-3270, Pascal 2456 /
2419 / 2650. First C version 2852 / 2683 / 2857: the token table came as
a 7th argument, on the stack, read for every sequence, and the literal
limit spilled; limits computed once as integers (no pointer before a
buffer's start, undefined in C) and the table in a local fixed both.
Windows 7 32-bit (VM), decode, Pascal -> C: dickens level 1 501 -> 853
MB/s, level 10 794 -> 1338; mozilla level 1 925 -> 1507, level 10 1120 ->
1892 (+63-70%).

Levels 0-1's compressor in C (sylzc_compress_fast, with emit_sequence
for the next ones): CompressFastCore with positions as offsets (fwd can
run past the input; a pointer there is undefined in C). Same bytes as
the assembler and Pascal. x86_64, compress MB/s, silesia level 0 / 1:
assembler 486 / 452, C 420 / 403, Pascal 304 / 302; mixed: 688 / 648, 605
/ 564, 440 / 408.

Levels 2-3 (sylzc_compress_mid), the hash-chain search of 4-8
(sylzc_hc_search) and the binary tree of 9-10 (sylzc_bt_insert) in C:
same bytes as assembler and Pascal on silesia and zpaq-std's sample.
x86_64 compress MB/s (asm / C / Pascal), silesia: level 2 274 / 253 /
179, 3 204 / 184 / 141, 4 85 / 73 / 61, 6 48 / 44 / 37, 8 24 / 22 / 20, 9
8.2 / 6.5 / 6.0, 10 6.7 / 5.6 / 5.0.

Windows 7 32-bit (VM), mozilla, compress Pascal -> C: level 0 186 -> 258
MB/s, 1 171 -> 291, 2 147 -> 157, 3 107 -> 131, 4 43 -> 58, 6 26 -> 36, 8
11.0 -> 18.5, 9 5.9 -> 6.7; decode 830-1130 -> 1130-1680 MB/s. Same
output. Every level of 32-bit Windows and arm64 now runs C where x86_64
runs assembler.

32-bit x86 and SSE2 (Pentium 4 / Athlon 64 and later): -msse2 for all
of sylzc.c made decode +10-15% but compression ~10% slower at levels 3
and 8 (gcc moved the 64-bit compares of count_match into xmm registers).
SSE2 for the decoder only (__attribute__((target("sse2")))): Windows 7
32-bit, mozilla, decode 1383-1692 -> 1726-2107 MB/s (+22-27%),
compression unchanged.

x86_64, where the parse around the assembler searches stayed Pascal:
levels 4-8's lz4hc parse in C (sylzc_compress_hc), calling the chain
search through a pointer (HcSearchX64 follows the C calling convention,
SysV and Win64; sylzc_hc_search elsewhere); and levels 9-10's candidate
pass (sylzc_opt_cands, BtFindAll included) the same way over
BtInsertX64. Same bytes. Cycles, silesia.tar: level 4 -13% (1.15x), 6
-7%, 8 -5%, 9 -2.4%, 10 -1.4%.

zpaq-std asked for one 32-bit DLL that runs on any x86: the decoder is
now compiled twice in the same object (decode_core inlined into a
target("sse2") function and a plain one) and sylzc_decode picks one with
cpuid (leaf 1, edx bit 26; <cpuid.h> is header-only, fine freestanding)
on its first call. Windows 7 32-bit, mozilla decode, -DSYLZC_NO_SSE2
build vs the automatic one: 1302-1834 vs 1661-2299 MB/s (it picks SSE2
there). Same bytes.

Build: build-c.sh compiles sylzc.c with the target's compiler (gcc,
x86_64/i686-w64-mingw32-gcc, aarch64-linux-gnu-gcc; -fPIC with -Cg),
freestanding (no libc, no builtins, no loop-to-memset, no stack
protector, no unwind tables), into the object path fpc gets with -Fo;
sylz.pas links it with {$L sylzc.o}. On win32 FPC adds C's leading
underscore itself. -dSYLZ_PUREPASCAL builds without C.

## Levels 9-10: a binary-tree match finder (2026-10-23)

After v0.2.8, level 8 (lz4hc's parse, 64 attempts) made 36.38%, as much
as level 9 (optimal parser, 64 hash-chain attempts: 36.37%) at 4.6x its
speed. Sweeping the optimal parser (silesia.tar):

- penalties: none 36.36% (decode -4%), half-byte (as is) 36.37%, 1-byte
  36.43%, 2-byte 37.62%: they cost almost nothing up to 1 byte, then a lot;
- chain attempts: 256 36.12% at 2.2 MB/s, 1024 36.05% at 1.0 MB/s. The
  ratio was limited by the candidates, and a deeper chain is slow;
- perf: 73% of the time in the chain search (every position, 64 attempts).

A binary tree (LZMA's bt4 without its 2- and 3-byte hashes; positions in
a 64 KiB cyclic son array, roots per 4-byte hash; 768 KiB) finds nearly
every useful candidate at a fixed cost per position:

| finder | silesia | compress |
|---|---|---|
| chain, 64 attempts (old level 9) | 36.37% | 4.7 MB/s |
| chain, 1024 attempts | 36.05% | 1.0 MB/s |
| tree, depth 16 (**level 9**) | 36.17% | 5.4-5.7 MB/s |
| tree, depth 32 | 36.09% | 5.1 MB/s |
| tree, depth 128, matches to 1024, sufficient 512 (**level 10**) | 36.04% | 4.4-4.8 MB/s |
| tree, depth 512, to 2048, subLen 128, lighter penalties | 36.02% | 3.6 MB/s |

Mixed corpus: level 9 60.63 -> 60.61%, level 10 60.49 -> 60.41%; compress
7.3 -> 8.3 and 3.7 -> 5.7 MB/s; decode unchanged or slightly faster.
Speed barely follows the depth (16: 5.7, 8: 7.8 MB/s for 36.85%): the
tree insert (63%, Pascal) and the DP (33%) at every position dominate.
Skipping inside long matches (skipLen 32-64) cost 0.03-0.2 points for
little speed.

Then, same output (checked byte for byte on both corpora): the tree in
x86-64 assembler (BtInsertX64), the DP's prices as integers in quarter
bytes (the penalties are multiples of a quarter, so the sums are exact as
they were in Single; each window starts at cost 0 and literals are priced
by their step, so no overflow on 512 MiB blocks), and match prices from a
table per pending run (the inner loop was MatchCost with an ExactCode
lookup for each of up to 36 lengths per candidate). Cycles, silesia.tar
(compress + one decode): level 9 118.5 G -> 90.9 G (1.30x), level 10
146.5 G -> 106.7 G (1.37x). Integer prices alone: DP -4.5%.

zpaq-std's mixed sample (16 MB: binaries, a 2 MB run, random data, small
files; /mnt/IA_LAB/compartido/syc-n9-mezcla) showed v0.2.9's level 9
worse than v0.2.8's (18.56 vs 18.12%) and than level 8 (17.71%), and
slower. Two causes:

- the tree compares at most btMaxLen bytes (256 at level 9), so a long
  run came out as 256-byte matches, a sequence each. A match that reaches
  btMaxLen is now extended as far as the bytes go (CountMatch, outside
  the tree). That alone also helps silesia (level 9 36.17 -> 36.11%) and
  the mixed corpus (60.61 -> 60.52%);
- depth 16 is too shallow on very redundant data (many similar suffixes):
  the sample's 1.bin (text) and 20.bin. Depth (silesia / mixed / sample,
  silesia speed): 16 36.11/60.52/17.93% 7.5 MB/s; 32 36.04/60.42/17.73%
  7.4; 48 36.03/60.41/17.72% 7.1; 64 36.03/60.40/17.70% 6.9. Level 10 at
  depth 256: 36.03/60.39/17.59%, 5.9 MB/s.

Level 9 now uses depth 32, level 10 depth 256. Not the cause: the window
edges (32 KiB windows: same size), the penalties (none: -0.03%), the
`sufficient` cut (without it: +7%).

## Levels 4-8: lz4hc's parse (2026-10-22)

At the same attempts, lz4hc -3 (4 attempts) made 38.38% where sylz's
lazy level 4 (4 attempts) made 39.35%: the difference was the parse.
lz4hc's (LZ4HC_compress_hashChain) searches at the end of each match for
a "wider" one that may start inside it and extend backwards, and trims
overlapping matches so each pays for itself. Ported as is (silesia.tar,
Pascal, same attempts; the machine was loaded, speeds +-10%):

| attempts | lazy (old) | lz4hc's parse |
|---|---|---|
| 4 | 39.35% 61 MB/s | 37.74% 55 MB/s |
| 8 | 38.35% 53 | 37.11% 46 |
| 16 | 37.65% 45 | 36.72% 39 |
| 64 | 36.89% 31 | 36.38% 26 |
| 256 | 36.60% 21 | 36.28% 19 |

With 1, 2, 3 attempts: 40.14% at 66 MB/s, 38.69% at 60, 38.09% at 55.
Speed hardly follows the attempts below 8: inserting every position
dominates (perf: the head-table load in HcInsertUpTo the hottest
instruction). Heads now keep 16-bit positions (FastDist), 2^16 of them,
128 KiB instead of 512: same speed and ratio (the opt levels moved by a
few bytes), a quarter of the memory.

New ladder (attempts 2, 4, 8, 16, 64): silesia 38.80 / 37.78 / 37.13 /
36.73 / 36.38%, mixed 61.55 / 61.10 / 60.83 / 60.68 / 60.55%. Level 8
now matches level 9's ratio (36.37%, mixed 60.63%) at ~4x its speed;
level 9 keeps a ~9% faster decode.

x86-64 assembler (HcSearchX64): the insertion loop and the chain walk
with forward and backward extension, one routine for both searches of
the parse (a plain one at pos, lowLimit = pos, and the "wider" one); the
parse itself stays in Pascal (~12% of the time). Same bytes as the
Pascal. Cycles, silesia.tar (compress + one decode): level 4 12.8 G ->
9.6 G (1.33x), level 6 19.8 -> 16.6 G (1.18x), level 8 36.3 -> 31.2 G
(1.16x). What remains is memory latency: the hottest instructions wait on
the candidate's bytes and on its chain link. Loading the link first, so
the two loads overlap: no gain (+0.6 to +6% cycles), dropped.

tests/sylzedge.pas (the exhaustive size x level x format x capacity
test of the 2026-10-19 review) is now in the repository.

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
