{ sylzhuf — canonical Huffman coding of byte chunks, for sylz literals.

  A chunk is coded as

    chunk   := mode:u8  payload
    mode 0  := raw bytes (the chunk's length is known to the caller)
    mode 2  := lengths[128]  size1:u16le size2:u16le size3:u16le size4:u16le
               stream1 stream2 stream3 stream4
    mode 1  := lengths[128]  size1:u16le size2:u16le size3:u16le
               stream1 stream2 stream3 stream4   (written by syc 0.2.4 to
               0.2.13, still read; stream 4 ends where its last code does)

    mode 3  := lengths[128]  size1:u16le .. size8:u16le
               stream1 .. stream8   (format v5)

  Mode 2 gives every stream's size, so the next chunk's place is known
  without decoding this one (chunks can be decoded in parallel).

  lengths packs the code length of symbol 2k in the low nibble of byte k
  and of 2k+1 in the high nibble; 0 = the symbol does not occur, else
  1..HUF_MAXBITS. Modes 1 and 2 need n >= HUF_MIN_SYMBOLS. Codes are canonical:
  shorter codes first, equal lengths by symbol. The chunk's n symbols are split into four runs of
  q = (n + 3) div 4 symbols (the last one shorter), each coded into its
  own stream, LSB first (a code's first bit is the lowest unused bit, as
  in deflate, so the decoder reads 8 bytes little-endian with no byte
  swap). Four independent streams let the decoder interleave four
  dependency chains.

  Mode 3 (format v5's chunks, HufEncodeChunk8 / HufDecodeChunk8) has
  eight streams, and deals the symbols out to them in turn: symbol i is
  in stream i mod 8. Eight chains instead of four: a symbol's chain
  (table load, shift) is about 7 cycles, so four streams cannot go
  below 1.75 cycles a symbol; eight took 1.39 in a prototype against
  1.93 for four (silesia.tar's literals), and the v5 decoder 6-8% fewer
  cycles per byte (-ec 0 and 1). The symbols of a round of all eight streams go
  to consecutive bytes, so the decoder has a single output pointer.

  The decoder never reads or writes out of bounds, whatever the input:
  it rejects length sets that are not a complete prefix code, and checks
  every stream ends inside its bytes. }
unit sylzhuf;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$inline on}
{$pointermath on}

interface

const
  HUF_MAXBITS   = 11;
  HUF_TABLESIZE = 1 shl HUF_MAXBITS;
  HUF_HEADER    = 128 + 6;   { mode 1: lengths + three stream sizes }
  HUF_HEADER2   = 128 + 8;   { mode 2: lengths + four stream sizes }
  HUF_HEADER3   = 128 + 16;  { mode 3: lengths + eight stream sizes }
  HUF_MIN_GAIN_PCT = 4;
  { smallest chunk that may be Huffman-coded (mode 1); smaller ones are
    raw. The decoder rejects mode 1 below it: with fewer symbols the
    four-run split degenerates (n = 5: runs of 2, 2, 2 and -1). }
  HUF_MIN_SYMBOLS = 256;

{ Worst-case size of a coded chunk of n bytes (mode byte included). }
function HufBound(n: SizeInt): SizeInt;

{ Codes src[0..n) as one chunk into dst (cap bytes): Huffman if it is
  smaller, else raw. Returns the chunk size, or -1 if cap is too small.
  n <= 65536 * 4 keeps every stream under the u16 size limit. }
function HufEncodeChunk(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt): SizeInt;

{ HufEncodeChunk with eight interleaved streams: mode 3 (or raw). }
function HufEncodeChunk8(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt): SizeInt;

{ Decodes one chunk (modes 0, 1, 2) of exactly n bytes from
  src[0..srcLen) into dst. Returns the number of src bytes the chunk
  took, or -1 if it is corrupt. }
function HufDecodeChunk(src: PByte; srcLen: SizeInt; dst: PByte; n: SizeInt): SizeInt;

{ HufDecodeChunk for modes 0 and 3 (format v5's chunks). }
function HufDecodeChunk8(src: PByte; srcLen: SizeInt; dst: PByte; n: SizeInt): SizeInt;

{ The code lengths (0 = absent, else 1..HUF_MAXBITS) HufEncodeChunk would
  give symbols with these frequencies. }
procedure HufLengths(freq: PUInt32; len: PByte);

var
  { x86-64: decode with the assembler bulk loop, and in it BMI2's shrx
    and LZCNT (set at startup from cpuid). Both can be cleared (tests, benchmarks);
    unused on other targets. }
  HufUseAsm: Boolean = True;
  HufUseBmi2: Boolean = False;

implementation

{$if defined(CPUX86_64) and not defined(SYLZ_PUREPASCAL)}
{$define HUF_ASM_X64}
{$asmmode intel}
{$endif}

function HufBound(n: SizeInt): SizeInt;
begin
  Result := 1 + n;
end;

{ ── code lengths ───────────────────────────────────────────────────────── }

{ Huffman code lengths for freq[0..255], limited to maxBits. Symbols with
  freq 0 get length 0. Classic two-queue construction on the sorted
  frequencies, then the lengths over maxBits are clamped and the Kraft
  excess paid back by lengthening the least frequent short codes. }
procedure BuildLengths(const freq: array of UInt32; var len: array of Byte;
  maxBits: Integer);
var
  sym: array[0..255] of Integer;
  w: array[0..511] of UInt64;
  parent: array[0..511] of Integer;
  depth: array[0..511] of Integer;
  n, i, j, a, b, leaf, node, nodes: Integer;
  kraft, limit: Int64;
  t: Integer;
begin
  for i := 0 to 255 do
    len[i] := 0;
  n := 0;
  for i := 0 to 255 do
    if freq[i] > 0 then
    begin
      sym[n] := i;
      Inc(n);
    end;
  if n = 0 then
    Exit;
  if n = 1 then
  begin
    len[sym[0]] := 1;
    Exit;
  end;
  { sort the present symbols by frequency (insertion sort, n <= 256) }
  for i := 1 to n - 1 do
  begin
    t := sym[i];
    j := i - 1;
    while (j >= 0) and (freq[sym[j]] > freq[t]) do
    begin
      sym[j + 1] := sym[j];
      Dec(j);
    end;
    sym[j + 1] := t;
  end;
  { two queues: leaves 0..n-1 (sorted), internal nodes n..2n-2 in order }
  for i := 0 to n - 1 do
    w[i] := freq[sym[i]];
  leaf := 0;
  node := n;
  nodes := n;
  for i := 0 to n - 2 do
  begin
    { pick the two lightest of the two queue fronts }
    if (leaf < n) and ((node >= nodes) or (w[leaf] <= w[node])) then
    begin
      a := leaf;
      Inc(leaf);
    end
    else
    begin
      a := node;
      Inc(node);
    end;
    if (leaf < n) and ((node >= nodes) or (w[leaf] <= w[node])) then
    begin
      b := leaf;
      Inc(leaf);
    end
    else
    begin
      b := node;
      Inc(node);
    end;
    w[nodes] := w[a] + w[b];
    parent[a] := nodes;
    parent[b] := nodes;
    Inc(nodes);
  end;
  { depths, root = nodes - 1 }
  depth[nodes - 1] := 0;
  for i := nodes - 2 downto 0 do
    depth[i] := depth[parent[i]] + 1;
  for i := 0 to n - 1 do
    if depth[i] > maxBits then
      len[sym[i]] := maxBits
    else
      len[sym[i]] := depth[i];
  { pay back the Kraft excess of the clamp: lengthen short codes, least
    frequent first (sym is sorted ascending by frequency) }
  limit := Int64(1) shl maxBits;
  kraft := 0;
  for i := 0 to n - 1 do
    Inc(kraft, Int64(1) shl (maxBits - len[sym[i]]));
  while kraft > limit do
    for i := 0 to n - 1 do
      if len[sym[i]] < maxBits then
      begin
        Dec(kraft, Int64(1) shl (maxBits - len[sym[i]] - 1));
        Inc(len[sym[i]]);
        if kraft <= limit then
          Break;
      end;
  { and spend leftover slack shortening the most frequent codes }
  for i := n - 1 downto 0 do
    while (len[sym[i]] > 1) and (kraft + (Int64(1) shl (maxBits - len[sym[i]])) <= limit) do
    begin
      Inc(kraft, Int64(1) shl (maxBits - len[sym[i]]));
      Dec(len[sym[i]]);
    end;
end;

{ Canonical codes from lengths. Returns false unless the lengths form a
  complete prefix code over two symbols or more. }
function CanonicalCodes(const len: array of Byte; var code: array of UInt32): Boolean;
var
  count: array[0..HUF_MAXBITS] of Integer;
  next: array[0..HUF_MAXBITS + 1] of UInt32;
  i, b, used: Integer;
  kraft: Int64;
begin
  for b := 0 to HUF_MAXBITS do
    count[b] := 0;
  used := 0;
  kraft := 0;
  for i := 0 to 255 do
  begin
    if len[i] > HUF_MAXBITS then
      Exit(False);
    if len[i] > 0 then
    begin
      Inc(count[len[i]]);
      Inc(used);
      Inc(kraft, Int64(1) shl (HUF_MAXBITS - len[i]));
    end;
  end;
  { a complete prefix code over at least two symbols: then every table
    entry of the decoder gets filled }
  if (used < 2) or (kraft <> Int64(1) shl HUF_MAXBITS) then
    Exit(False);
  next[1] := 0;
  for b := 1 to HUF_MAXBITS do
    next[b + 1] := (next[b] + UInt32(count[b])) shl 1;
  for i := 0 to 255 do
    if len[i] > 0 then
    begin
      code[i] := next[len[i]];
      Inc(next[len[i]]);
    end;
  Result := True;
end;

{ ── encoder ────────────────────────────────────────────────────────────── }

function ReverseBits(v: UInt32; n: Integer): UInt32;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to n do
  begin
    Result := (Result shl 1) or (v and 1);
    v := v shr 1;
  end;
end;

const
  { symbols coded between two writes: 7 bits left over and these codes
    fit the 64-bit accumulator }
  ENC_GROUP = 5;
  ENC_SLACK = 8;   { a run's last write may go this far past its end }

{ The codes of n symbols at p, LSB first, the last byte padded with zero
  bits: src[0], src[step], src[2 * step] ...; tab[symbol] = its code
  (first bit lowest) shl 4 or its length. Returns where the run ends;
  writes up to ENC_SLACK - 1 bytes past it. (The accumulator is stored
  whole every ENC_GROUP symbols and the pointer moved by the whole bytes
  in it: one byte at a time, with a bounds check each, took 28 cycles a
  literal; this takes 3.) }
function EncodeRun(src: PByte; n, step: SizeInt; tab: PUInt32; p: PByte): PByte;
var
  acc: UInt64;
  bits: SizeUInt;
  e: UInt32;
  i: SizeInt;
begin
  acc := 0;
  bits := 0;
  i := 0;
  while i + ENC_GROUP <= n do
  begin
    e := tab[src^];
    acc := acc or (UInt64(e shr 4) shl bits);
    Inc(bits, e and 15);
    e := tab[src[step]];
    acc := acc or (UInt64(e shr 4) shl bits);
    Inc(bits, e and 15);
    e := tab[src[2 * step]];
    acc := acc or (UInt64(e shr 4) shl bits);
    Inc(bits, e and 15);
    e := tab[src[3 * step]];
    acc := acc or (UInt64(e shr 4) shl bits);
    Inc(bits, e and 15);
    e := tab[src[4 * step]];
    acc := acc or (UInt64(e shr 4) shl bits);
    Inc(bits, e and 15);
    PUInt64(p)^ := acc;
    Inc(p, bits shr 3);
    acc := acc shr (bits and 56);
    bits := bits and 7;
    Inc(src, ENC_GROUP * step);
    Inc(i, ENC_GROUP);
  end;
  { fewer than ENC_GROUP left: they fit too }
  while i < n do
  begin
    e := tab[src^];
    acc := acc or (UInt64(e shr 4) shl bits);
    Inc(bits, e and 15);
    Inc(src, step);
    Inc(i);
  end;
  PUInt64(p)^ := acc;
  Result := p + (bits + 7) shr 3;
end;

{ HufEncodeChunk (streams = 4: mode 2) and HufEncodeChunk8 (8: mode 3). }
function EncodeChunk(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt;
  streams: Integer): SizeInt;
var
  hist: array[0..3, 0..255] of UInt32;
  freq: array[0..255] of UInt32;
  len: array[0..255] of Byte;
  code: array[0..255] of UInt32;
  tab: array[0..255] of UInt32;
  i, s, q, a, b, header: SizeInt;
  bits: Int64;
  p, start, stop: PByte;
  size: SizeInt;
  fits: Boolean;
begin
  if cap < 1 + n then
    Exit(-1);
  if n >= HUF_MIN_SYMBOLS then
  begin
    { four histograms, added up: a byte that repeats does not wait for the
      store of its own count }
    FillChar(hist, SizeOf(hist), 0);
    i := 0;
    while i + 4 <= n do
    begin
      Inc(hist[0, src[i]]);
      Inc(hist[1, src[i + 1]]);
      Inc(hist[2, src[i + 2]]);
      Inc(hist[3, src[i + 3]]);
      Inc(i, 4);
    end;
    while i < n do
    begin
      Inc(hist[0, src[i]]);
      Inc(i);
    end;
    for i := 0 to 255 do
      freq[i] := hist[0, i] + hist[1, i] + hist[2, i] + hist[3, i];
    BuildLengths(freq, len, HUF_MAXBITS);
    if streams = 8 then
      header := HUF_HEADER3
    else
      header := HUF_HEADER2;
    { a single symbol has no complete code: such a chunk stays raw }
    if CanonicalCodes(len, code) then
    begin
      bits := 0;
      for i := 0 to 255 do
      begin
        tab[i] := 0;
        if len[i] > 0 then
          tab[i] := (ReverseBits(code[i], len[i]) shl 4) or len[i];
        Inc(bits, Int64(freq[i]) * len[i]);
      end;
      { Huffman only when it saves HUF_MIN_GAIN_PCT of the chunk: on
        nearly random data it saves little and costs a table decode per
        byte (mixed corpus: 4% gives +12% decode speed for 0.1 point of
        ratio; 8% gives +25% for 0.5). The streams take at most bits div
        8 + streams bytes, so they end inside the chunk's raw size, and
        EncodeRun's writes inside cap when that leaves ENC_SLACK. }
      if (header + bits div 8 + streams + n * HUF_MIN_GAIN_PCT div 100 < n)
         and (1 + header + bits div 8 + streams + ENC_SLACK <= cap) then
      begin
        p := dst + 1;
        for i := 0 to 127 do
          p[i] := len[2 * i] or (len[2 * i + 1] shl 4);
        start := p + header;
        q := (n + 3) div 4;
        fits := True;
        for s := 0 to streams - 1 do
        begin
          if streams = 8 then
            { symbols s, s + 8, s + 16 ... }
            stop := EncodeRun(src + s, (n - s + 7) div 8, 8, @tab[0], start)
          else
          begin
            { a run of q symbols }
            a := s * q;
            b := a + q;
            if b > n then
              b := n;
            stop := EncodeRun(src + a, b - a, 1, @tab[0], start);
          end;
          size := stop - start;
          if size > $FFFF then
            fits := False;   { the size field is 16 bits }
          p[128 + 2 * s] := Byte(size);
          p[129 + 2 * s] := Byte(size shr 8);
          start := stop;
        end;
        if fits and (start - dst < 1 + n) then
        begin
          if streams = 8 then
            dst[0] := 3
          else
            dst[0] := 2;
          Exit(start - dst);
        end;
      end;
    end;
  end;
  dst[0] := 0;
  if n > 0 then
    Move(src^, dst[1], n);
  Result := 1 + n;
end;

function HufEncodeChunk(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt): SizeInt;
begin
  Result := EncodeChunk(src, n, dst, cap, 4);
end;

function HufEncodeChunk8(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt): SizeInt;
begin
  Result := EncodeChunk(src, n, dst, cap, 8);
end;

procedure HufLengths(freq: PUInt32; len: PByte);
var
  f: array[0..255] of UInt32;
  l: array[0..255] of Byte;
  i: Integer;
begin
  for i := 0 to 255 do
    f[i] := freq[i];
  BuildLengths(f, l, HUF_MAXBITS);
  for i := 0 to 255 do
    len[i] := l[i];
end;

{ ── decoder ────────────────────────────────────────────────────────────── }

type
  { table entry: code length in bits 0..7, symbol in bits 8..15 (the
    assembler shifts by the entry itself: a shift count is taken mod 64) }
  THufTable = array[0..HUF_TABLESIZE - 1] of UInt16;

{ The decoding table of a chunk's packed code lengths. False unless they
  form a complete prefix code over two symbols or more (CanonicalCodes'
  conditions): then every entry gets filled.

  LSB first: a code of length L sits at its bits reversed, in the low L
  bits of the index, whatever the bits above. So the table for the codes
  of up to L bits is the first 2^L entries, and copying them after
  themselves makes the one for L + 1 bits, where a code of that length
  takes a single entry: eleven block copies and a store per symbol.
  (Writing each code's 2^(HUF_MAXBITS - L) entries at their stride, and
  reversing each code bit by bit, was 12% of the decoder's time, 22000
  cycles a chunk; this is 6000.) }
function BuildTable(lens: PByte; var t: THufTable): Boolean;
var
  len, order: array[0..255] of Byte;
  count, start: array[0..15] of Integer;
  i, l, k, size: Integer;
  r, m: UInt32;
  kraft: Int64;
begin
  Result := False;
  for l := 0 to 15 do
    count[l] := 0;
  for i := 0 to 127 do
  begin
    len[2 * i] := lens[i] and 15;
    len[2 * i + 1] := lens[i] shr 4;
    Inc(count[lens[i] and 15]);
    Inc(count[lens[i] shr 4]);
  end;
  kraft := 0;
  for l := 1 to HUF_MAXBITS do
    Inc(kraft, Int64(count[l]) shl (HUF_MAXBITS - l));
  for l := HUF_MAXBITS + 1 to 15 do
    if count[l] <> 0 then
      Exit;
  if (256 - count[0] < 2) or (kraft <> Int64(1) shl HUF_MAXBITS) then
    Exit;
  { the symbols in the order of their codes: by length, then by value }
  k := 0;
  for l := 1 to HUF_MAXBITS do
  begin
    start[l] := k;
    Inc(k, count[l]);
  end;
  for i := 0 to 255 do
    if len[i] <> 0 then
    begin
      order[start[len[i]]] := i;
      Inc(start[len[i]]);
    end;
  size := 1;
  r := 0;   { the next code, bits reversed; it reads the same at L + 1 bits }
  k := 0;
  for l := 1 to HUF_MAXBITS do
  begin
    Move(t[0], t[size], size * SizeOf(UInt16));
    size := size * 2;
    for i := 1 to count[l] do
    begin
      t[r] := UInt16(l or (order[k] shl 8));
      Inc(k);
      { one more, from the top bit down }
      m := size shr 1;
      while r and m <> 0 do
      begin
        r := r xor m;
        m := m shr 1;
      end;
      r := r or m;
    end;
  end;
  Result := True;
end;

type
  { One stream's reader, LSB first: buf holds count valid bits from bit 0
    up, p is the next byte not yet loaded. }
  THufReader = record
    buf: UInt64;
    count: SizeInt;
    p, start, pend: PByte;
  end;

procedure RdInit(out r: THufReader; p, pend: PByte);
begin
  r.buf := 0;
  r.count := 0;
  r.p := p;
  r.start := p;
  r.pend := pend;
end;

{ Exact refill near the end of the input: byte by byte, zero past pend. }
procedure RdRefillSafe(var r: THufReader); inline;
begin
  while r.count <= 56 do
  begin
    if r.p < r.pend then
      r.buf := r.buf or (UInt64(r.p^) shl r.count);
    Inc(r.p);
    Inc(r.count, 8);
  end;
end;

{ Bits this stream took, and whether that fits its bytes. }
function RdEndsInside(const r: THufReader): Boolean; inline;
begin
  Result := (r.p - r.start) * 8 - r.count <= (r.pend - r.start) * 8;
end;

{$ifdef HUF_ASM_X64}
type
  { In/out state of the assembler bulk decoder; fixed field order. }
  THufBulk = record
    buf: array[0..3] of UInt64;   {   0: in/out, the streams' bit buffers }
    cnt: array[0..3] of Int64;    {  32: in/out, valid bits in each }
    p: array[0..3] of PByte;      {  64: in/out, the next bytes to load }
    table: Pointer;               {  96: in }
    out0: PByte;                  { 104: in/out, stream 0's next output }
    q: Int64;                     { 112: in, symbols per stream (output stride) }
    outEnd: PByte;                { 120: in, out0 after the last round to run }
  end;
  PHufBulk = ^THufBulk;

{ The bulk loop of HufDecodeChunk: rounds of a refill and five symbols per
  stream, until out0 reaches outEnd (at least one round; the caller counts
  how many rounds the input allows: a refill reads 8 bytes at p and moves
  p by at most 7).

  A stream's state is its bit buffer and the count of valid bits in it. A
  symbol: the table entry at the buffer's low HUF_MAXBITS bits (length in
  the low byte, symbol in the high one), then the buffer shifted right by
  the length. So the chain from one symbol to the next is and, load,
  shift: 7 cycles, where keeping the buffer and shifting by a running
  count needed 9 (the length came through ah: 2 cycles) and a reload of
  the buffer through that count every five symbols. Measured 2.4 cycles
  a literal against 3.0 (four streams; the stores and the counts share
  the ports with the chains, so not the 1.9 the chain alone allows). The
  refill (Giesen's, branch-free) ors the 8 bytes at p above the valid
  bits and moves p by the whole bytes that fit: at least 56 bits are
  valid after it, enough for five codes of HUF_MAXBITS. The bits above
  the count are the stream's next ones, so oring them in again changes
  nothing.

  The count is kept in the low byte of its register: the whole entry is
  subtracted from it (the length never borrows from the byte above: a
  code is never longer than the bits left), and only that byte is read.

  Registers: r8-r11 the buffers, r12-r15 the counts, rdi the table, rsi
  stream 0's output, rbx the stride q and rdx 3q (the other streams'
  outputs are at rsi + q, 2q, 3q: no REX prefix, so the symbol can be
  stored from ah); rax, rcx, rbp scratch (rbp never addresses memory: FPC
  reads [rbp + n] as a frame access). The read pointers live on the
  stack: touched once per five symbols.
  HufBulkBmi2 shifts with shrx / shlx (one uop, any count register;
  written as bytes, FPC 3.2's assembler lacks BMI2), HufBulkX64 with
  shr / shl cl, for CPUs before BMI2. }
procedure HufBulkBmi2(st: PHufBulk); assembler; nostackframe;
asm
  push rbx
  push r12
  push rbp
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  sub rsp, 48
  mov [rsp + 40], rax             { state }
  mov rdx, [rax + 64]
  mov [rsp + 0], rdx              { p0..p3 at [rsp + 8k] }
  mov rdx, [rax + 72]
  mov [rsp + 8], rdx
  mov rdx, [rax + 80]
  mov [rsp + 16], rdx
  mov rdx, [rax + 88]
  mov [rsp + 24], rdx
  mov rdx, [rax + 120]
  mov [rsp + 32], rdx             { outEnd }
  mov r8, [rax + 0]
  mov r9, [rax + 8]
  mov r10, [rax + 16]
  mov r11, [rax + 24]
  mov r12, [rax + 32]
  mov r13, [rax + 40]
  mov r14, [rax + 48]
  mov r15, [rax + 56]
  mov rdi, [rax + 96]
  mov rsi, [rax + 104]
  mov rbx, [rax + 112]
  lea rdx, [rbx + rbx * 2]

@round:
  movzx ecx, r12b
  mov rax, [rsp + 0]
  db $C4, $E2, $F1, $F7, $28   { shlx rbp, [rax], rcx }
  or r8, rbp
  xor ecx, 63
  shr ecx, 3
  add rax, rcx
  mov [rsp + 0], rax
  or r12d, 56
  movzx ecx, r13b
  mov rax, [rsp + 8]
  db $C4, $E2, $F1, $F7, $28   { shlx rbp, [rax], rcx }
  or r9, rbp
  xor ecx, 63
  shr ecx, 3
  add rax, rcx
  mov [rsp + 8], rax
  or r13d, 56
  movzx ecx, r14b
  mov rax, [rsp + 16]
  db $C4, $E2, $F1, $F7, $28   { shlx rbp, [rax], rcx }
  or r10, rbp
  xor ecx, 63
  shr ecx, 3
  add rax, rcx
  mov [rsp + 16], rax
  or r14d, 56
  movzx ecx, r15b
  mov rax, [rsp + 24]
  db $C4, $E2, $F1, $F7, $28   { shlx rbp, [rax], rcx }
  or r11, rbp
  xor ecx, 63
  shr ecx, 3
  add rax, rcx
  mov [rsp + 24], rax
  or r15d, 56
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C0   { shrx r8, r8, rax }
  mov byte ptr [rsi + 0], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C9   { shrx r9, r9, rax }
  mov byte ptr [rsi + rbx + 0], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $D2   { shrx r10, r10, rax }
  mov byte ptr [rsi + rbx * 2 + 0], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $DB   { shrx r11, r11, rax }
  mov byte ptr [rsi + rdx + 0], ah
  sub r15d, eax
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C0   { shrx r8, r8, rax }
  mov byte ptr [rsi + 1], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C9   { shrx r9, r9, rax }
  mov byte ptr [rsi + rbx + 1], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $D2   { shrx r10, r10, rax }
  mov byte ptr [rsi + rbx * 2 + 1], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $DB   { shrx r11, r11, rax }
  mov byte ptr [rsi + rdx + 1], ah
  sub r15d, eax
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C0   { shrx r8, r8, rax }
  mov byte ptr [rsi + 2], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C9   { shrx r9, r9, rax }
  mov byte ptr [rsi + rbx + 2], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $D2   { shrx r10, r10, rax }
  mov byte ptr [rsi + rbx * 2 + 2], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $DB   { shrx r11, r11, rax }
  mov byte ptr [rsi + rdx + 2], ah
  sub r15d, eax
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C0   { shrx r8, r8, rax }
  mov byte ptr [rsi + 3], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C9   { shrx r9, r9, rax }
  mov byte ptr [rsi + rbx + 3], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $D2   { shrx r10, r10, rax }
  mov byte ptr [rsi + rbx * 2 + 3], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $DB   { shrx r11, r11, rax }
  mov byte ptr [rsi + rdx + 3], ah
  sub r15d, eax
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C0   { shrx r8, r8, rax }
  mov byte ptr [rsi + 4], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C9   { shrx r9, r9, rax }
  mov byte ptr [rsi + rbx + 4], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $D2   { shrx r10, r10, rax }
  mov byte ptr [rsi + rbx * 2 + 4], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $DB   { shrx r11, r11, rax }
  mov byte ptr [rsi + rdx + 4], ah
  sub r15d, eax
  add rsi, 5
  cmp rsi, [rsp + 32]
  jb @round

  mov rax, [rsp + 40]
  mov [rax + 0], r8
  mov [rax + 8], r9
  mov [rax + 16], r10
  mov [rax + 24], r11
  movzx ecx, r12b
  mov [rax + 32], rcx
  movzx ecx, r13b
  mov [rax + 40], rcx
  movzx ecx, r14b
  mov [rax + 48], rcx
  movzx ecx, r15b
  mov [rax + 56], rcx
  mov rdx, [rsp + 0]
  mov [rax + 64], rdx
  mov rdx, [rsp + 8]
  mov [rax + 72], rdx
  mov rdx, [rsp + 16]
  mov [rax + 80], rdx
  mov rdx, [rsp + 24]
  mov [rax + 88], rdx
  mov [rax + 104], rsi
  add rsp, 48
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop rbp
  pop r12
  pop rbx
end;

procedure HufBulkX64(st: PHufBulk); assembler; nostackframe;
asm
  push rbx
  push r12
  push rbp
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  sub rsp, 48
  mov [rsp + 40], rax             { state }
  mov rdx, [rax + 64]
  mov [rsp + 0], rdx              { p0..p3 at [rsp + 8k] }
  mov rdx, [rax + 72]
  mov [rsp + 8], rdx
  mov rdx, [rax + 80]
  mov [rsp + 16], rdx
  mov rdx, [rax + 88]
  mov [rsp + 24], rdx
  mov rdx, [rax + 120]
  mov [rsp + 32], rdx             { outEnd }
  mov r8, [rax + 0]
  mov r9, [rax + 8]
  mov r10, [rax + 16]
  mov r11, [rax + 24]
  mov r12, [rax + 32]
  mov r13, [rax + 40]
  mov r14, [rax + 48]
  mov r15, [rax + 56]
  mov rdi, [rax + 96]
  mov rsi, [rax + 104]
  mov rbx, [rax + 112]
  lea rdx, [rbx + rbx * 2]

@round:
  movzx ecx, r12b
  mov rax, [rsp + 0]
  mov rbp, [rax]
  shl rbp, cl
  or r8, rbp
  xor ecx, 63
  shr ecx, 3
  add rax, rcx
  mov [rsp + 0], rax
  or r12d, 56
  movzx ecx, r13b
  mov rax, [rsp + 8]
  mov rbp, [rax]
  shl rbp, cl
  or r9, rbp
  xor ecx, 63
  shr ecx, 3
  add rax, rcx
  mov [rsp + 8], rax
  or r13d, 56
  movzx ecx, r14b
  mov rax, [rsp + 16]
  mov rbp, [rax]
  shl rbp, cl
  or r10, rbp
  xor ecx, 63
  shr ecx, 3
  add rax, rcx
  mov [rsp + 16], rax
  or r14d, 56
  movzx ecx, r15b
  mov rax, [rsp + 24]
  mov rbp, [rax]
  shl rbp, cl
  or r11, rbp
  xor ecx, 63
  shr ecx, 3
  add rax, rcx
  mov [rsp + 24], rax
  or r15d, 56
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r8, cl
  mov byte ptr [rsi + 0], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r9, cl
  mov byte ptr [rsi + rbx + 0], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r10, cl
  mov byte ptr [rsi + rbx * 2 + 0], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r11, cl
  mov byte ptr [rsi + rdx + 0], ah
  sub r15d, eax
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r8, cl
  mov byte ptr [rsi + 1], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r9, cl
  mov byte ptr [rsi + rbx + 1], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r10, cl
  mov byte ptr [rsi + rbx * 2 + 1], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r11, cl
  mov byte ptr [rsi + rdx + 1], ah
  sub r15d, eax
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r8, cl
  mov byte ptr [rsi + 2], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r9, cl
  mov byte ptr [rsi + rbx + 2], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r10, cl
  mov byte ptr [rsi + rbx * 2 + 2], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r11, cl
  mov byte ptr [rsi + rdx + 2], ah
  sub r15d, eax
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r8, cl
  mov byte ptr [rsi + 3], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r9, cl
  mov byte ptr [rsi + rbx + 3], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r10, cl
  mov byte ptr [rsi + rbx * 2 + 3], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r11, cl
  mov byte ptr [rsi + rdx + 3], ah
  sub r15d, eax
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r8, cl
  mov byte ptr [rsi + 4], ah
  sub r12d, eax
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r9, cl
  mov byte ptr [rsi + rbx + 4], ah
  sub r13d, eax
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r10, cl
  mov byte ptr [rsi + rbx * 2 + 4], ah
  sub r14d, eax
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r11, cl
  mov byte ptr [rsi + rdx + 4], ah
  sub r15d, eax
  add rsi, 5
  cmp rsi, [rsp + 32]
  jb @round

  mov rax, [rsp + 40]
  mov [rax + 0], r8
  mov [rax + 8], r9
  mov [rax + 16], r10
  mov [rax + 24], r11
  movzx ecx, r12b
  mov [rax + 32], rcx
  movzx ecx, r13b
  mov [rax + 40], rcx
  movzx ecx, r14b
  mov [rax + 48], rcx
  movzx ecx, r15b
  mov [rax + 56], rcx
  mov rdx, [rsp + 0]
  mov [rax + 64], rdx
  mov rdx, [rsp + 8]
  mov [rax + 72], rdx
  mov rdx, [rsp + 16]
  mov [rax + 80], rdx
  mov rdx, [rsp + 24]
  mov [rax + 88], rdx
  mov [rax + 104], rsi
  add rsp, 48
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop rbp
  pop r12
  pop rbx
end;

type
  { In/out state of the mode 3 bulk decoder; fixed field order. }
  THufBulk8 = record
    pos: array[0..7] of UInt64;   {  0: in/out, each stream's next bit, as its address times 8 }
    table: Pointer;               { 64: in }
    out0: PByte;                  { 72: in/out, the next output byte }
    outEnd: PByte;                { 80: in, out0 after the last round to run }
  end;
  PHufBulk8 = ^THufBulk8;

{ The bulk loop of HufDecodeChunk8: rounds of five symbols from each of
  the eight streams (40 output bytes: symbol j of stream k at out0 + 8j +
  k), until out0 reaches outEnd (at least one round). A refill reads the
  8 bytes at the stream's byte; the caller counts the rounds the input
  allows (a round takes at most 55 bits of a stream).

  A stream's buffer is loaded at its bit position, shifted so that its
  next bit is bit 0, and bit 63 set: the code bits are below that mark,
  57 of them or more, enough for five codes of HUF_MAXBITS. A symbol:
  the table entry at the low HUF_MAXBITS bits (length in the low byte,
  symbol in the high one), the buffer shifted right by the length. The
  mark moves down with the bits taken, so at the refill its leading
  zeros are the bits the round took: no count to keep in a register.

  Registers: r8-r15 the buffers, rdi the table, rsi the output (no REX
  prefix: the symbol is stored from ah), rbp outEnd (never addresses
  memory: FPC reads [rbp + n] as a frame access), edx the symbols left
  in the round; rax, rcx scratch. The bit positions live on the stack.
  HufBulk8Bmi2 uses bzhi, shrx and lzcnt (written as bytes, FPC 3.2's
  assembler lacks them; HufUseBmi2 is only set with LZCNT too),
  HufBulk8X64 and, shr cl and bsr. }
procedure HufBulk8Bmi2(st: PHufBulk8); assembler; nostackframe;
asm
  push rbx
  push r12
  push rbp
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  sub rsp, 72
  mov [rsp + 64], rax             { state }
  mov rcx, [rax + 0]
  mov [rsp + 0], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r8, [rdx]
  db $C4, $42, $F3, $F7, $C0   { shrx r8, r8, rcx }
  bts r8, 63
  mov rcx, [rax + 8]
  mov [rsp + 8], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r9, [rdx]
  db $C4, $42, $F3, $F7, $C9   { shrx r9, r9, rcx }
  bts r9, 63
  mov rcx, [rax + 16]
  mov [rsp + 16], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r10, [rdx]
  db $C4, $42, $F3, $F7, $D2   { shrx r10, r10, rcx }
  bts r10, 63
  mov rcx, [rax + 24]
  mov [rsp + 24], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r11, [rdx]
  db $C4, $42, $F3, $F7, $DB   { shrx r11, r11, rcx }
  bts r11, 63
  mov rcx, [rax + 32]
  mov [rsp + 32], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r12, [rdx]
  db $C4, $42, $F3, $F7, $E4   { shrx r12, r12, rcx }
  bts r12, 63
  mov rcx, [rax + 40]
  mov [rsp + 40], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r13, [rdx]
  db $C4, $42, $F3, $F7, $ED   { shrx r13, r13, rcx }
  bts r13, 63
  mov rcx, [rax + 48]
  mov [rsp + 48], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r14, [rdx]
  db $C4, $42, $F3, $F7, $F6   { shrx r14, r14, rcx }
  bts r14, 63
  mov rcx, [rax + 56]
  mov [rsp + 56], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r15, [rdx]
  db $C4, $42, $F3, $F7, $FF   { shrx r15, r15, rcx }
  bts r15, 63
  mov rdi, [rax + 64]             { table }
  mov rsi, [rax + 72]             { out0 }
  mov rbp, [rax + 80]             { outEnd }
  mov ebx, HUF_MAXBITS
@round:
  mov edx, 5
@sym:
  db $C4, $C2, $60, $F5, $C0   { bzhi eax, r8d, ebx }
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C0   { shrx r8, r8, rax }
  mov byte ptr [rsi + 0], ah
  db $C4, $C2, $60, $F5, $C1   { bzhi eax, r9d, ebx }
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $C9   { shrx r9, r9, rax }
  mov byte ptr [rsi + 1], ah
  db $C4, $C2, $60, $F5, $C2   { bzhi eax, r10d, ebx }
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $D2   { shrx r10, r10, rax }
  mov byte ptr [rsi + 2], ah
  db $C4, $C2, $60, $F5, $C3   { bzhi eax, r11d, ebx }
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $DB   { shrx r11, r11, rax }
  mov byte ptr [rsi + 3], ah
  db $C4, $C2, $60, $F5, $C4   { bzhi eax, r12d, ebx }
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $E4   { shrx r12, r12, rax }
  mov byte ptr [rsi + 4], ah
  db $C4, $C2, $60, $F5, $C5   { bzhi eax, r13d, ebx }
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $ED   { shrx r13, r13, rax }
  mov byte ptr [rsi + 5], ah
  db $C4, $C2, $60, $F5, $C6   { bzhi eax, r14d, ebx }
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $F6   { shrx r14, r14, rax }
  mov byte ptr [rsi + 6], ah
  db $C4, $C2, $60, $F5, $C7   { bzhi eax, r15d, ebx }
  movzx eax, word ptr [rdi + rax * 2]
  db $C4, $42, $FB, $F7, $FF   { shrx r15, r15, rax }
  mov byte ptr [rsi + 7], ah
  add rsi, 8
  dec edx
  jnz @sym
  xor ecx, ecx
  db $F3, $49, $0F, $BD, $C8   { lzcnt rcx, r8 }
  add rcx, [rsp + 0]
  mov [rsp + 0], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r8, [rax]
  db $C4, $42, $F3, $F7, $C0   { shrx r8, r8, rcx }
  bts r8, 63
  xor ecx, ecx
  db $F3, $49, $0F, $BD, $C9   { lzcnt rcx, r9 }
  add rcx, [rsp + 8]
  mov [rsp + 8], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r9, [rax]
  db $C4, $42, $F3, $F7, $C9   { shrx r9, r9, rcx }
  bts r9, 63
  xor ecx, ecx
  db $F3, $49, $0F, $BD, $CA   { lzcnt rcx, r10 }
  add rcx, [rsp + 16]
  mov [rsp + 16], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r10, [rax]
  db $C4, $42, $F3, $F7, $D2   { shrx r10, r10, rcx }
  bts r10, 63
  xor ecx, ecx
  db $F3, $49, $0F, $BD, $CB   { lzcnt rcx, r11 }
  add rcx, [rsp + 24]
  mov [rsp + 24], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r11, [rax]
  db $C4, $42, $F3, $F7, $DB   { shrx r11, r11, rcx }
  bts r11, 63
  xor ecx, ecx
  db $F3, $49, $0F, $BD, $CC   { lzcnt rcx, r12 }
  add rcx, [rsp + 32]
  mov [rsp + 32], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r12, [rax]
  db $C4, $42, $F3, $F7, $E4   { shrx r12, r12, rcx }
  bts r12, 63
  xor ecx, ecx
  db $F3, $49, $0F, $BD, $CD   { lzcnt rcx, r13 }
  add rcx, [rsp + 40]
  mov [rsp + 40], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r13, [rax]
  db $C4, $42, $F3, $F7, $ED   { shrx r13, r13, rcx }
  bts r13, 63
  xor ecx, ecx
  db $F3, $49, $0F, $BD, $CE   { lzcnt rcx, r14 }
  add rcx, [rsp + 48]
  mov [rsp + 48], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r14, [rax]
  db $C4, $42, $F3, $F7, $F6   { shrx r14, r14, rcx }
  bts r14, 63
  xor ecx, ecx
  db $F3, $49, $0F, $BD, $CF   { lzcnt rcx, r15 }
  add rcx, [rsp + 56]
  mov [rsp + 56], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r15, [rax]
  db $C4, $42, $F3, $F7, $FF   { shrx r15, r15, rcx }
  bts r15, 63
  cmp rsi, rbp
  jb @round
  mov rax, [rsp + 64]
  mov [rax + 72], rsi
  mov rcx, [rsp + 0]
  mov [rax + 0], rcx
  mov rcx, [rsp + 8]
  mov [rax + 8], rcx
  mov rcx, [rsp + 16]
  mov [rax + 16], rcx
  mov rcx, [rsp + 24]
  mov [rax + 24], rcx
  mov rcx, [rsp + 32]
  mov [rax + 32], rcx
  mov rcx, [rsp + 40]
  mov [rax + 40], rcx
  mov rcx, [rsp + 48]
  mov [rax + 48], rcx
  mov rcx, [rsp + 56]
  mov [rax + 56], rcx
  add rsp, 72
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop rbp
  pop r12
  pop rbx
end;

procedure HufBulk8X64(st: PHufBulk8); assembler; nostackframe;
asm
  push rbx
  push r12
  push rbp
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  sub rsp, 72
  mov [rsp + 64], rax             { state }
  mov rcx, [rax + 0]
  mov [rsp + 0], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r8, [rdx]
  shr r8, cl
  bts r8, 63
  mov rcx, [rax + 8]
  mov [rsp + 8], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r9, [rdx]
  shr r9, cl
  bts r9, 63
  mov rcx, [rax + 16]
  mov [rsp + 16], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r10, [rdx]
  shr r10, cl
  bts r10, 63
  mov rcx, [rax + 24]
  mov [rsp + 24], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r11, [rdx]
  shr r11, cl
  bts r11, 63
  mov rcx, [rax + 32]
  mov [rsp + 32], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r12, [rdx]
  shr r12, cl
  bts r12, 63
  mov rcx, [rax + 40]
  mov [rsp + 40], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r13, [rdx]
  shr r13, cl
  bts r13, 63
  mov rcx, [rax + 48]
  mov [rsp + 48], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r14, [rdx]
  shr r14, cl
  bts r14, 63
  mov rcx, [rax + 56]
  mov [rsp + 56], rcx
  mov rdx, rcx
  shr rdx, 3
  and ecx, 7
  mov r15, [rdx]
  shr r15, cl
  bts r15, 63
  mov rdi, [rax + 64]             { table }
  mov rsi, [rax + 72]             { out0 }
  mov rbp, [rax + 80]             { outEnd }
@round:
  mov edx, 5
@sym:
  mov eax, r8d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r8, cl
  mov byte ptr [rsi + 0], ah
  mov eax, r9d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r9, cl
  mov byte ptr [rsi + 1], ah
  mov eax, r10d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r10, cl
  mov byte ptr [rsi + 2], ah
  mov eax, r11d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r11, cl
  mov byte ptr [rsi + 3], ah
  mov eax, r12d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r12, cl
  mov byte ptr [rsi + 4], ah
  mov eax, r13d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r13, cl
  mov byte ptr [rsi + 5], ah
  mov eax, r14d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r14, cl
  mov byte ptr [rsi + 6], ah
  mov eax, r15d
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov ecx, eax
  shr r15, cl
  mov byte ptr [rsi + 7], ah
  add rsi, 8
  dec edx
  jnz @sym
  bsr rcx, r8
  xor ecx, 63
  add rcx, [rsp + 0]
  mov [rsp + 0], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r8, [rax]
  shr r8, cl
  bts r8, 63
  bsr rcx, r9
  xor ecx, 63
  add rcx, [rsp + 8]
  mov [rsp + 8], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r9, [rax]
  shr r9, cl
  bts r9, 63
  bsr rcx, r10
  xor ecx, 63
  add rcx, [rsp + 16]
  mov [rsp + 16], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r10, [rax]
  shr r10, cl
  bts r10, 63
  bsr rcx, r11
  xor ecx, 63
  add rcx, [rsp + 24]
  mov [rsp + 24], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r11, [rax]
  shr r11, cl
  bts r11, 63
  bsr rcx, r12
  xor ecx, 63
  add rcx, [rsp + 32]
  mov [rsp + 32], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r12, [rax]
  shr r12, cl
  bts r12, 63
  bsr rcx, r13
  xor ecx, 63
  add rcx, [rsp + 40]
  mov [rsp + 40], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r13, [rax]
  shr r13, cl
  bts r13, 63
  bsr rcx, r14
  xor ecx, 63
  add rcx, [rsp + 48]
  mov [rsp + 48], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r14, [rax]
  shr r14, cl
  bts r14, 63
  bsr rcx, r15
  xor ecx, 63
  add rcx, [rsp + 56]
  mov [rsp + 56], rcx
  mov rax, rcx
  shr rax, 3
  and ecx, 7
  mov r15, [rax]
  shr r15, cl
  bts r15, 63
  cmp rsi, rbp
  jb @round
  mov rax, [rsp + 64]
  mov [rax + 72], rsi
  mov rcx, [rsp + 0]
  mov [rax + 0], rcx
  mov rcx, [rsp + 8]
  mov [rax + 8], rcx
  mov rcx, [rsp + 16]
  mov [rax + 16], rcx
  mov rcx, [rsp + 24]
  mov [rax + 24], rcx
  mov rcx, [rsp + 32]
  mov [rax + 32], rcx
  mov rcx, [rsp + 40]
  mov [rax + 40], rcx
  mov rcx, [rsp + 48]
  mov [rax + 48], rcx
  mov rcx, [rsp + 56]
  mov [rax + 56], rcx
  add rsp, 72
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop rbp
  pop r12
  pop rbx
end;

{ BMI2 (cpuid leaf 7, ebx bit 8) and LZCNT (leaf $80000001, ecx bit 5).
  HufBulk8Bmi2 needs both: without LZCNT its lzcnt runs as bsr, which
  gives 63 minus the bits a round took, so the bit positions would run
  past the rounds the caller allowed for. Every BMI2 CPU has LZCNT, but
  a virtual machine may report one without the other. }
function CpuHasBmi2: Boolean; assembler; nostackframe;
asm
  push rbx
  xor eax, eax
  cpuid
  cmp eax, 7
  jb @no
  mov eax, 7
  xor ecx, ecx
  cpuid
  bt ebx, 8
  jnc @no
  mov eax, $80000000
  cpuid
  cmp eax, $80000001
  jb @no
  mov eax, $80000001
  cpuid
  mov eax, ecx
  shr eax, 5
  and eax, 1
  pop rbx
  ret
@no:
  xor eax, eax
  pop rbx
end;
{$endif}

function HufDecodeChunk(src: PByte; srcLen: SizeInt; dst: PByte; n: SizeInt): SizeInt;
var
  t: THufTable;
  send: PByte;
  r: array[0..3] of THufReader;
  q, i, j, k, lastN, s1, s2, s3, s4, bulkEnd, used: SizeInt;
  chunkEnd: PByte;
  v: UInt16;
  d: array[0..3] of PByte;
  b0, b1, b2, b3: UInt64;
  c0, c1, c2, c3: SizeInt;
  p0, p1, p2, p3, plimit: PByte;
  d0, d1, d2, d3: PByte;
{$ifdef HUF_ASM_X64}
  bulk: THufBulk;
{$endif}
begin
  Result := -1;
  if srcLen < 1 then
    Exit;
  send := src + srcLen;
  if src[0] = 0 then
  begin
    if srcLen - 1 < n then
      Exit;
    Move(src[1], dst^, n);
    Exit(1 + n);
  end;
  if ((src[0] <> 1) and (src[0] <> 2)) or (n < HUF_MIN_SYMBOLS) then
    Exit;
  if (srcLen < 1 + HUF_HEADER) or ((src[0] = 2) and (srcLen < 1 + HUF_HEADER2)) then
    Exit;
  if not BuildTable(src + 1, t) then
    Exit;
  s1 := src[129] or (SizeInt(src[130]) shl 8);
  s2 := src[131] or (SizeInt(src[132]) shl 8);
  s3 := src[133] or (SizeInt(src[134]) shl 8);
  if src[0] = 2 then
  begin
    s4 := src[135] or (SizeInt(src[136]) shl 8);
    if 1 + HUF_HEADER2 + s1 + s2 + s3 + s4 > srcLen then
      Exit;
    p0 := src + 1 + HUF_HEADER2;
    chunkEnd := p0 + s1 + s2 + s3 + s4;
  end
  else
  begin
    if 1 + HUF_HEADER + s1 + s2 + s3 > srcLen then
      Exit;
    p0 := src + 1 + HUF_HEADER;
    chunkEnd := send;   { stream 4 ends where its last code does }
  end;
  RdInit(r[0], p0, p0 + s1);
  RdInit(r[1], p0 + s1, p0 + s1 + s2);
  RdInit(r[2], p0 + s1 + s2, p0 + s1 + s2 + s3);
  RdInit(r[3], p0 + s1 + s2 + s3, chunkEnd);
  q := (n + 3) div 4;
  lastN := n - 3 * q;   { >= 0 for n >= HUF_MIN_SYMBOLS }
  d0 := dst; d1 := dst + q; d2 := dst + 2 * q; d3 := dst + 3 * q;

  { bulk: rounds of symbols from all four streams, with branch-free refills
    reading eight bytes at p (valid while p + 8 <= send: the streams lie
    back to back, so reading past one's end lands in the next) }
  b0 := 0; b1 := 0; b2 := 0; b3 := 0;
  c0 := 0; c1 := 0; c2 := 0; c3 := 0;
  p0 := r[0].p; p1 := r[1].p; p2 := r[2].p; p3 := r[3].p;
  plimit := send - 8;
  i := 0;
  bulkEnd := lastN - 4;
{$ifdef HUF_ASM_X64}
  if (lastN >= 5) and HufUseAsm then
  begin
    FillChar(bulk, SizeOf(bulk), 0);
    bulk.p[0] := p0; bulk.p[1] := p1; bulk.p[2] := p2; bulk.p[3] := p3;
    bulk.table := @t[0];
    bulk.out0 := d0;
    bulk.q := q;
    { rounds of five symbols per stream, as many at a time as the input
      allows without a check: a round's refills read 8 bytes at each p
      and move it by at most 7 }
    j := lastN div 5;
    while j > 0 do
    begin
      used := j;
      for k := 0 to 3 do
        if bulk.p[k] > plimit then
          used := 0
        else if (plimit - bulk.p[k]) div 7 + 1 < used then
          used := (plimit - bulk.p[k]) div 7 + 1;
      if used = 0 then
        Break;
      bulk.outEnd := bulk.out0 + 5 * used;
      if HufUseBmi2 then
        HufBulkBmi2(@bulk)
      else
        HufBulkX64(@bulk);
      Dec(j, used);
    end;
    i := bulk.out0 - d0;
    { back to the exact readers; the bits past the count are the stream's
      next ones, which the exact refills will read again: cleared }
    for k := 0 to 3 do
    begin
      r[k].p := bulk.p[k];
      r[k].count := bulk.cnt[k];
      r[k].buf := bulk.buf[k] and ((UInt64(1) shl bulk.cnt[k]) - 1);
    end;
  end
  else
{$endif}
  begin
    while (i <= bulkEnd) and (p0 <= plimit) and (p1 <= plimit) and (p2 <= plimit) and (p3 <= plimit) do
    begin
      b0 := b0 or (PUInt64(p0)^ shl c0); Inc(p0, (63 - c0) shr 3); c0 := c0 or 56;
      b1 := b1 or (PUInt64(p1)^ shl c1); Inc(p1, (63 - c1) shr 3); c1 := c1 or 56;
      b2 := b2 or (PUInt64(p2)^ shl c2); Inc(p2, (63 - c2) shr 3); c2 := c2 or 56;
      b3 := b3 or (PUInt64(p3)^ shl c3); Inc(p3, (63 - c3) shr 3); c3 := c3 or 56;
      for k := 0 to 3 do
      begin
        v := t[b0 and (HUF_TABLESIZE - 1)]; d0[i + k] := Byte(v shr 8); b0 := b0 shr (v and 255); Dec(c0, v and 255);
        v := t[b1 and (HUF_TABLESIZE - 1)]; d1[i + k] := Byte(v shr 8); b1 := b1 shr (v and 255); Dec(c1, v and 255);
        v := t[b2 and (HUF_TABLESIZE - 1)]; d2[i + k] := Byte(v shr 8); b2 := b2 shr (v and 255); Dec(c2, v and 255);
        v := t[b3 and (HUF_TABLESIZE - 1)]; d3[i + k] := Byte(v shr 8); b3 := b3 shr (v and 255); Dec(c3, v and 255);
      end;
      Inc(i, 4);
    end;
    r[0].buf := b0; r[0].count := c0; r[0].p := p0;
    r[1].buf := b1; r[1].count := c1; r[1].p := p1;
    r[2].buf := b2; r[2].count := c2; r[2].p := p2;
    r[3].buf := b3; r[3].count := c3; r[3].p := p3;
    { the bulk refill loads 8 bytes but counts at most 63 - count bits of
      them, so the bits past count are not reliable: clear them before the
      exact tail refills }
    for k := 0 to 3 do
      if r[k].count < 64 then
        r[k].buf := r[k].buf and ((UInt64(1) shl r[k].count) - 1);
  end;
  d[0] := d0; d[1] := d1; d[2] := d2; d[3] := d3;

  { tail: one symbol at a time, exact refills }
  for k := 0 to 3 do
  begin
    if k < 3 then
      used := q
    else
      used := lastN;
    for j := i to used - 1 do
    begin
      RdRefillSafe(r[k]);
      v := t[r[k].buf and (HUF_TABLESIZE - 1)];
      d[k][j] := Byte(v shr 8);
      r[k].buf := r[k].buf shr (v and 255);
      Dec(r[k].count, v and 255);
    end;
    if not RdEndsInside(r[k]) then
      Exit;
  end;
  if src[0] = 2 then
    Result := chunkEnd - src
  else
    Result := r[3].p - src - r[3].count div 8;
end;

{ Mode 3's symbols first, first + 8 .. below n, from a stream at bit pos
  of src, one at a time; no byte read at or past srcLen. Returns the
  bit position after them. }
function DecodeTail8(src: PByte; srcLen: SizeInt; const t: THufTable;
  pos: SizeInt; dst: PByte; first, n: SizeInt): SizeInt;
var
  j, k: SizeInt;
  w, v: UInt32;
begin
  j := first;
  while j < n do
  begin
    { a code starts at bit pos and 7 + HUF_MAXBITS bits fit in 3 bytes }
    k := pos shr 3;
    w := 0;
    if k < srcLen then
      w := src[k];
    if k + 1 < srcLen then
      w := w or (UInt32(src[k + 1]) shl 8);
    if k + 2 < srcLen then
      w := w or (UInt32(src[k + 2]) shl 16);
    v := t[(w shr (pos and 7)) and (HUF_TABLESIZE - 1)];
    dst[j] := Byte(v shr 8);
    Inc(pos, v and 255);
    Inc(j, 8);
  end;
  Result := pos;
end;

function HufDecodeChunk8(src: PByte; srcLen: SizeInt; dst: PByte; n: SizeInt): SizeInt;
const
  ROUND_BITS = 5 * HUF_MAXBITS;   { the most a bulk round takes of a stream }
var
  t: THufTable;
  pos, lim: array[0..7] of SizeInt;   { the streams' bits, from src }
  k, j, total, rounds, used, c: SizeInt;
  b: UInt64;
  v: UInt32;
  o: PByte;
{$ifdef HUF_ASM_X64}
  bulk: THufBulk8;
{$endif}
begin
  Result := -1;
  if srcLen < 1 then
    Exit;
  if src[0] = 0 then
  begin
    if srcLen - 1 < n then
      Exit;
    Move(src[1], dst^, n);
    Exit(1 + n);
  end;
  if (src[0] <> 3) or (n < HUF_MIN_SYMBOLS) or (srcLen < 1 + HUF_HEADER3) then
    Exit;
  if not BuildTable(src + 1, t) then
    Exit;
  total := 1 + HUF_HEADER3;
  for k := 0 to 7 do
  begin
    pos[k] := total * 8;
    Inc(total, src[129 + 2 * k] or (SizeInt(src[130 + 2 * k]) shl 8));
    lim[k] := total * 8;
  end;
  if total > srcLen then
    Exit;
  { nothing past the chunk's 8 bytes of slack is read: the bit
    positions stay small (32-bit targets) }
  if srcLen > total + 8 then
    srcLen := total + 8;
  { bulk: rounds of five symbols from each stream, while every stream
    has five left (stream 7 has the fewest, n div 8) and its refills read
    inside src[0 .. srcLen): reading past a stream's end into the next
    one only matters to codes that end past it, which the end check
    below rejects }
  rounds := n div 8 div 5;
  o := dst;
{$ifdef HUF_ASM_X64}
  if HufUseAsm then
  begin
    for k := 0 to 7 do
      bulk.pos[k] := UInt64(SizeUInt(src)) * 8 + UInt64(pos[k]);
    bulk.table := @t[0];
    bulk.out0 := dst;
    while rounds > 0 do
    begin
      { refills at the start and after each round, each round at most
        ROUND_BITS further: the last 8-byte read must end by srcLen }
      used := rounds;
      for k := 0 to 7 do
      begin
        c := ((srcLen - 8) * 8 - pos[k]) div ROUND_BITS;
        if c < used then
          used := c;
      end;
      if used <= 0 then
        Break;
      bulk.outEnd := bulk.out0 + 40 * used;
      if HufUseBmi2 then
        HufBulk8Bmi2(@bulk)
      else
        HufBulk8X64(@bulk);
      for k := 0 to 7 do
        pos[k] := SizeInt(bulk.pos[k] - UInt64(SizeUInt(src)) * 8);
      Dec(rounds, used);
    end;
    o := bulk.out0;
  end
  else
{$endif}
  while rounds > 0 do
  begin
    for k := 0 to 7 do
      if pos[k] shr 3 + 8 > srcLen then
        rounds := 0;
    if rounds = 0 then
      Break;
    for k := 0 to 7 do
    begin
      b := PUInt64(src + pos[k] shr 3)^ shr (pos[k] and 7);
      c := 0;
      for j := 0 to 4 do
      begin
        v := t[b and (HUF_TABLESIZE - 1)];
        o[8 * j + k] := Byte(v shr 8);
        b := b shr (v and 255);
        Inc(c, v and 255);
      end;
      Inc(pos[k], c);
    end;
    Inc(o, 40);
    Dec(rounds);
  end;
  { the rest one at a time; each stream must end inside its bytes }
  for k := 0 to 7 do
    if DecodeTail8(src, srcLen, t, pos[k], dst, o - dst + k, n) > lim[k] then
      Exit;
  Result := total;
end;

{$ifdef HUF_ASM_X64}
initialization
  HufUseBmi2 := CpuHasBmi2;
{$endif}
end.
