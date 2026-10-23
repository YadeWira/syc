{ sylzhuf — canonical Huffman coding of byte chunks, for sylz literals.

  A chunk is coded as

    chunk   := mode:u8  payload
    mode 0  := raw bytes (the chunk's length is known to the caller)
    mode 1  := lengths[128]  size1:u16le size2:u16le size3:u16le
               stream1 stream2 stream3 stream4

  lengths packs the code length of symbol 2k in the low nibble of byte k
  and of 2k+1 in the high nibble; 0 = the symbol does not occur, else
  1..HUF_MAXBITS. Mode 1 needs n >= HUF_MIN_SYMBOLS. Codes are canonical:
  shorter codes first, equal lengths by symbol. The chunk's n symbols are split into four runs of
  q = (n + 3) div 4 symbols (the last one shorter), each coded into its
  own stream, LSB first (a code's first bit is the lowest unused bit, as
  in deflate, so the decoder reads 8 bytes little-endian with no byte
  swap); stream 4 ends where its last code does. Four independent streams let the decoder
  interleave four dependency chains.

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
  HUF_HEADER    = 128 + 6;   { lengths + three stream sizes }
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

{ Decodes one chunk of exactly n bytes from src[0..srcLen) into dst.
  Returns the number of src bytes the chunk took, or -1 if it is
  corrupt. }
function HufDecodeChunk(src: PByte; srcLen: SizeInt; dst: PByte; n: SizeInt): SizeInt;

{ The code lengths (0 = absent, else 1..HUF_MAXBITS) HufEncodeChunk would
  give symbols with these frequencies. }
procedure HufLengths(freq: PUInt32; len: PByte);

var
  { x86-64: decode with the assembler bulk loop, and in it BMI2's shrx
    (set at startup from cpuid). Both can be cleared (tests, benchmarks);
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

{ LSB-first bit writer over a 64-bit accumulator. }
type
  TBitWriter = record
    p, pend: PByte;
    acc: UInt64;
    bits: Integer;     { bits held in acc, from bit 0 up }
    overflow: Boolean;
  end;

procedure BwInit(out w: TBitWriter; p, pend: PByte);
begin
  w.p := p;
  w.pend := pend;
  w.acc := 0;
  w.bits := 0;
  w.overflow := False;
end;

{ code is already bit-reversed (first bit lowest) }
procedure BwPut(var w: TBitWriter; code: UInt32; n: Integer); inline;
begin
  w.acc := w.acc or (UInt64(code) shl w.bits);
  Inc(w.bits, n);
  while w.bits >= 8 do
  begin
    if w.p >= w.pend then
    begin
      w.overflow := True;
      w.bits := 0;
      Exit;
    end;
    w.p^ := Byte(w.acc);
    Inc(w.p);
    w.acc := w.acc shr 8;
    Dec(w.bits, 8);
  end;
end;

procedure BwFlush(var w: TBitWriter);
begin
  if w.bits > 0 then
  begin
    if w.p >= w.pend then
      w.overflow := True
    else
    begin
      w.p^ := Byte(w.acc);
      Inc(w.p);
    end;
  end;
  w.bits := 0;
  w.acc := 0;
end;

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

function HufEncodeChunk(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt): SizeInt;
var
  freq: array[0..255] of UInt32;
  len: array[0..255] of Byte;
  code: array[0..255] of UInt32;
  i, s, q, a, b: SizeInt;
  bits: Int64;
  w: TBitWriter;
  p, start: PByte;
  size: SizeInt;
begin
  if cap < 1 + n then
    Exit(-1);
  if n >= HUF_MIN_SYMBOLS then
  begin
    for i := 0 to 255 do
      freq[i] := 0;
    for i := 0 to n - 1 do
      Inc(freq[src[i]]);
    BuildLengths(freq, len, HUF_MAXBITS);
    { a single symbol has no complete code: such a chunk stays raw }
    if CanonicalCodes(len, code) then
    begin
      for i := 0 to 255 do
        if len[i] > 0 then
          code[i] := ReverseBits(code[i], len[i]);
      bits := 0;
      for i := 0 to 255 do
        Inc(bits, Int64(freq[i]) * len[i]);
      { Huffman only when it saves HUF_MIN_GAIN_PCT of the chunk: on
        nearly random data it saves little and costs a table decode per
        byte (mixed corpus: 4% gives +12% decode speed for 0.1 point of
        ratio; 8% gives +25% for 0.5) }
      if HUF_HEADER + bits div 8 + 4 + n * HUF_MIN_GAIN_PCT div 100 < n then
      begin
        p := dst + 1;
        for i := 0 to 127 do
          p[i] := len[2 * i] or (len[2 * i + 1] shl 4);
        start := p + HUF_HEADER;
        q := (n + 3) div 4;
        BwInit(w, start, dst + cap);
        for s := 0 to 3 do
        begin
          a := s * q;
          b := a + q;
          if b > n then
            b := n;
          for i := a to b - 1 do
            BwPut(w, code[src[i]], len[src[i]]);
          BwFlush(w);
          size := w.p - start;
          if s < 3 then
          begin
            if size > $FFFF then
              w.overflow := True;
            p[128 + 2 * s] := Byte(size);
            p[129 + 2 * s] := Byte(size shr 8);
          end;
          start := w.p;
        end;
        if not w.overflow and (w.p - dst < 1 + n) then
        begin
          dst[0] := 1;
          Exit(w.p - dst);
        end;
      end;
    end;
  end;
  dst[0] := 0;
  if n > 0 then
    Move(src^, dst[1], n);
  Result := 1 + n;
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
  { table entry: symbol in bits 0..7, code length in bits 8..15 }
  THufTable = array[0..HUF_TABLESIZE - 1] of UInt16;

function BuildTable(lens: PByte; var t: THufTable): Boolean;
var
  len: array[0..255] of Byte;
  code: array[0..255] of UInt32;
  i, k, first, count: Integer;
begin
  for i := 0 to 127 do
  begin
    len[2 * i] := lens[i] and 15;
    len[2 * i + 1] := lens[i] shr 4;
  end;
  if not CanonicalCodes(len, code) then
    Exit(False);
  { LSB first: a code of length L occupies the low L bits of the index,
    reversed; every value of the bits above it maps to the same entry }
  for i := 0 to 255 do
    if len[i] > 0 then
    begin
      first := ReverseBits(code[i], len[i]);
      count := 1 shl (HUF_MAXBITS - len[i]);
      for k := 0 to count - 1 do
        t[first or (k shl len[i])] := UInt16(i or (len[i] shl 8));
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
    buf: array[0..3] of UInt64;   {   0: unused }
    cnt: array[0..3] of Int64;    {  32: in/out, bits taken past p }
    p: array[0..3] of PByte;      {  64: in/out }
    table: Pointer;               {  96: in }
    out0: PByte;                  { 104: in/out, stream 0's next output }
    q: Int64;                     { 112: in, symbols per stream (output stride) }
    outEnd: PByte;                { 120: in, last out0 a round may start at }
    plimit: PByte;                { 128: in, last p a refill may read 8 bytes at }
  end;
  PHufBulk = ^THufBulk;

{ The bulk loop of HufDecodeChunk: rounds of a reload and five symbols per
  stream, until out0 passes outEnd or a reload would read past plimit (a
  round stops before decoding anything, so the streams stay in step).
  Each stream keeps the eight bytes at p in a register and the bits taken
  from them in a count (at most 7 + 5 * 11 = 62): a symbol is a table
  lookup at buf >> count, and a reload moves p by whole bytes, so the
  buffer itself is never shifted. Registers: r8-r11 buffers, rbp/r13-r15
  counts, rdi table, rsi stream 0/1 output, r12 stream 2/3 output, rbx
  stride q; rax, rcx, rdx scratch. (rbp never addresses memory: FPC reads
  [rbp + n] as a frame access.) The read pointers and limits live on the
  stack: they are only touched at a reload, once per five symbols.
  HufBulkBmi2 shifts with shrx (one uop; written as bytes, FPC 3.2's
  assembler lacks BMI2), HufBulkX64 with shr cl, for CPUs before BMI2. }
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
  sub rsp, 56
  mov [rsp + 48], rax             { state }
  mov rdx, [rax + 64]
  mov [rsp + 0], rdx                  { p0..p3 at [rsp + 8k] }
  mov rdx, [rax + 72]
  mov [rsp + 8], rdx
  mov rdx, [rax + 80]
  mov [rsp + 16], rdx
  mov rdx, [rax + 88]
  mov [rsp + 24], rdx
  mov rdx, [rax + 120]
  mov [rsp + 32], rdx             { outEnd }
  mov rdx, [rax + 128]
  mov [rsp + 40], rdx             { plimit }
  mov rbp, [rax + 32]
  mov r13, [rax + 40]
  mov r14, [rax + 48]
  mov r15, [rax + 56]
  mov rdi, [rax + 96]
  mov rsi, [rax + 104]
  mov rbx, [rax + 112]
  lea r12, [rsi + rbx * 2]

@round:
  cmp rsi, [rsp + 32]
  ja @done
  { reload: p += consumed >> 3; consumed &= 7; buf = load64(p) }
  mov rax, rbp
  shr rax, 3
  add rax, [rsp + 0]
  cmp rax, [rsp + 40]
  ja @done
  mov [rsp + 0], rax
  and rbp, 7
  mov r8, [rax]
  mov rax, r13
  shr rax, 3
  add rax, [rsp + 8]
  cmp rax, [rsp + 40]
  ja @done
  mov [rsp + 8], rax
  and r13, 7
  mov r9, [rax]
  mov rax, r14
  shr rax, 3
  add rax, [rsp + 16]
  cmp rax, [rsp + 40]
  ja @done
  mov [rsp + 16], rax
  and r14, 7
  mov r10, [rax]
  mov rax, r15
  shr rax, 3
  add rax, [rsp + 24]
  cmp rax, [rsp + 40]
  ja @done
  mov [rsp + 24], rax
  and r15, 7
  mov r11, [rax]
  db $C4, $C2, $D3, $F7, $C0   { shrx rax, r8, rbp }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 0], al
  movzx ecx, ah
  add rbp, rcx
  db $C4, $C2, $93, $F7, $C1   { shrx rax, r9, r13 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 0], al
  movzx ecx, ah
  add r13, rcx
  db $C4, $C2, $8B, $F7, $C2   { shrx rax, r10, r14 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 0], al
  movzx ecx, ah
  add r14, rcx
  db $C4, $C2, $83, $F7, $C3   { shrx rax, r11, r15 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 0], al
  movzx ecx, ah
  add r15, rcx
  db $C4, $C2, $D3, $F7, $C0   { shrx rax, r8, rbp }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 1], al
  movzx ecx, ah
  add rbp, rcx
  db $C4, $C2, $93, $F7, $C1   { shrx rax, r9, r13 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 1], al
  movzx ecx, ah
  add r13, rcx
  db $C4, $C2, $8B, $F7, $C2   { shrx rax, r10, r14 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 1], al
  movzx ecx, ah
  add r14, rcx
  db $C4, $C2, $83, $F7, $C3   { shrx rax, r11, r15 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 1], al
  movzx ecx, ah
  add r15, rcx
  db $C4, $C2, $D3, $F7, $C0   { shrx rax, r8, rbp }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 2], al
  movzx ecx, ah
  add rbp, rcx
  db $C4, $C2, $93, $F7, $C1   { shrx rax, r9, r13 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 2], al
  movzx ecx, ah
  add r13, rcx
  db $C4, $C2, $8B, $F7, $C2   { shrx rax, r10, r14 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 2], al
  movzx ecx, ah
  add r14, rcx
  db $C4, $C2, $83, $F7, $C3   { shrx rax, r11, r15 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 2], al
  movzx ecx, ah
  add r15, rcx
  db $C4, $C2, $D3, $F7, $C0   { shrx rax, r8, rbp }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 3], al
  movzx ecx, ah
  add rbp, rcx
  db $C4, $C2, $93, $F7, $C1   { shrx rax, r9, r13 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 3], al
  movzx ecx, ah
  add r13, rcx
  db $C4, $C2, $8B, $F7, $C2   { shrx rax, r10, r14 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 3], al
  movzx ecx, ah
  add r14, rcx
  db $C4, $C2, $83, $F7, $C3   { shrx rax, r11, r15 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 3], al
  movzx ecx, ah
  add r15, rcx
  db $C4, $C2, $D3, $F7, $C0   { shrx rax, r8, rbp }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 4], al
  movzx ecx, ah
  add rbp, rcx
  db $C4, $C2, $93, $F7, $C1   { shrx rax, r9, r13 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 4], al
  movzx ecx, ah
  add r13, rcx
  db $C4, $C2, $8B, $F7, $C2   { shrx rax, r10, r14 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 4], al
  movzx ecx, ah
  add r14, rcx
  db $C4, $C2, $83, $F7, $C3   { shrx rax, r11, r15 }
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 4], al
  movzx ecx, ah
  add r15, rcx
  add rsi, 5
  add r12, 5
  jmp @round

@done:
  mov rax, [rsp + 48]
  mov [rax + 32], rbp
  mov [rax + 40], r13
  mov [rax + 48], r14
  mov [rax + 56], r15
  mov rdx, [rsp + 0]
  mov [rax + 64], rdx
  mov rdx, [rsp + 8]
  mov [rax + 72], rdx
  mov rdx, [rsp + 16]
  mov [rax + 80], rdx
  mov rdx, [rsp + 24]
  mov [rax + 88], rdx
  mov [rax + 104], rsi
  add rsp, 56
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
  sub rsp, 56
  mov [rsp + 48], rax             { state }
  mov rdx, [rax + 64]
  mov [rsp + 0], rdx                  { p0..p3 at [rsp + 8k] }
  mov rdx, [rax + 72]
  mov [rsp + 8], rdx
  mov rdx, [rax + 80]
  mov [rsp + 16], rdx
  mov rdx, [rax + 88]
  mov [rsp + 24], rdx
  mov rdx, [rax + 120]
  mov [rsp + 32], rdx             { outEnd }
  mov rdx, [rax + 128]
  mov [rsp + 40], rdx             { plimit }
  mov rbp, [rax + 32]
  mov r13, [rax + 40]
  mov r14, [rax + 48]
  mov r15, [rax + 56]
  mov rdi, [rax + 96]
  mov rsi, [rax + 104]
  mov rbx, [rax + 112]
  lea r12, [rsi + rbx * 2]

@round:
  cmp rsi, [rsp + 32]
  ja @done
  { reload: p += consumed >> 3; consumed &= 7; buf = load64(p) }
  mov rax, rbp
  shr rax, 3
  add rax, [rsp + 0]
  cmp rax, [rsp + 40]
  ja @done
  mov [rsp + 0], rax
  and rbp, 7
  mov r8, [rax]
  mov rax, r13
  shr rax, 3
  add rax, [rsp + 8]
  cmp rax, [rsp + 40]
  ja @done
  mov [rsp + 8], rax
  and r13, 7
  mov r9, [rax]
  mov rax, r14
  shr rax, 3
  add rax, [rsp + 16]
  cmp rax, [rsp + 40]
  ja @done
  mov [rsp + 16], rax
  and r14, 7
  mov r10, [rax]
  mov rax, r15
  shr rax, 3
  add rax, [rsp + 24]
  cmp rax, [rsp + 40]
  ja @done
  mov [rsp + 24], rax
  and r15, 7
  mov r11, [rax]
  mov rcx, rbp
  mov rax, r8
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 0], al
  movzx ecx, ah
  add rbp, rcx
  mov rcx, r13
  mov rax, r9
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 0], al
  movzx ecx, ah
  add r13, rcx
  mov rcx, r14
  mov rax, r10
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 0], al
  movzx ecx, ah
  add r14, rcx
  mov rcx, r15
  mov rax, r11
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 0], al
  movzx ecx, ah
  add r15, rcx
  mov rcx, rbp
  mov rax, r8
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 1], al
  movzx ecx, ah
  add rbp, rcx
  mov rcx, r13
  mov rax, r9
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 1], al
  movzx ecx, ah
  add r13, rcx
  mov rcx, r14
  mov rax, r10
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 1], al
  movzx ecx, ah
  add r14, rcx
  mov rcx, r15
  mov rax, r11
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 1], al
  movzx ecx, ah
  add r15, rcx
  mov rcx, rbp
  mov rax, r8
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 2], al
  movzx ecx, ah
  add rbp, rcx
  mov rcx, r13
  mov rax, r9
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 2], al
  movzx ecx, ah
  add r13, rcx
  mov rcx, r14
  mov rax, r10
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 2], al
  movzx ecx, ah
  add r14, rcx
  mov rcx, r15
  mov rax, r11
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 2], al
  movzx ecx, ah
  add r15, rcx
  mov rcx, rbp
  mov rax, r8
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 3], al
  movzx ecx, ah
  add rbp, rcx
  mov rcx, r13
  mov rax, r9
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 3], al
  movzx ecx, ah
  add r13, rcx
  mov rcx, r14
  mov rax, r10
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 3], al
  movzx ecx, ah
  add r14, rcx
  mov rcx, r15
  mov rax, r11
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 3], al
  movzx ecx, ah
  add r15, rcx
  mov rcx, rbp
  mov rax, r8
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + 4], al
  movzx ecx, ah
  add rbp, rcx
  mov rcx, r13
  mov rax, r9
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [rsi + rbx + 4], al
  movzx ecx, ah
  add r13, rcx
  mov rcx, r14
  mov rax, r10
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + 4], al
  movzx ecx, ah
  add r14, rcx
  mov rcx, r15
  mov rax, r11
  shr rax, cl
  and eax, HUF_TABLESIZE - 1
  movzx eax, word ptr [rdi + rax * 2]
  mov byte ptr [r12 + rbx + 4], al
  movzx ecx, ah
  add r15, rcx
  add rsi, 5
  add r12, 5
  jmp @round

@done:
  mov rax, [rsp + 48]
  mov [rax + 32], rbp
  mov [rax + 40], r13
  mov [rax + 48], r14
  mov [rax + 56], r15
  mov rdx, [rsp + 0]
  mov [rax + 64], rdx
  mov rdx, [rsp + 8]
  mov [rax + 72], rdx
  mov rdx, [rsp + 16]
  mov [rax + 80], rdx
  mov rdx, [rsp + 24]
  mov [rax + 88], rdx
  mov [rax + 104], rsi
  add rsp, 56
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

{ BMI2 (cpuid leaf 7, ebx bit 8) }
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
  mov eax, ebx
  shr eax, 8
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
  q, i, j, k, lastN, s1, s2, s3, bulkEnd, used: SizeInt;
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
  if (src[0] <> 1) or (srcLen < 1 + HUF_HEADER) or (n < HUF_MIN_SYMBOLS) then
    Exit;
  if not BuildTable(src + 1, t) then
    Exit;
  s1 := src[129] or (SizeInt(src[130]) shl 8);
  s2 := src[131] or (SizeInt(src[132]) shl 8);
  s3 := src[133] or (SizeInt(src[134]) shl 8);
  if 1 + HUF_HEADER + s1 + s2 + s3 > srcLen then
    Exit;
  p0 := src + 1 + HUF_HEADER;
  RdInit(r[0], p0, p0 + s1);
  RdInit(r[1], p0 + s1, p0 + s1 + s2);
  RdInit(r[2], p0 + s1 + s2, p0 + s1 + s2 + s3);
  RdInit(r[3], p0 + s1 + s2 + s3, send);
  q := (n + 3) div 4;
  lastN := n - 3 * q;   { >= 0 for n >= HUF_MIN_SYMBOLS }
  d0 := dst; d1 := dst + q; d2 := dst + 2 * q; d3 := dst + 3 * q;

  { bulk: rounds of four symbols per stream, with branch-free refills
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
    bulk.outEnd := d0 + lastN - 5;
    bulk.plimit := plimit;
    if HufUseBmi2 then
      HufBulkBmi2(@bulk)
    else
      HufBulkX64(@bulk);
    i := bulk.out0 - d0;
    { back to the exact readers: whole bytes taken move p, the rest are
      dropped from a fresh buffer }
    for k := 0 to 3 do
    begin
      r[k].p := bulk.p[k] + bulk.cnt[k] shr 3;
      RdRefillSafe(r[k]);
      r[k].buf := r[k].buf shr (bulk.cnt[k] and 7);
      Dec(r[k].count, bulk.cnt[k] and 7);
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
        v := t[b0 and (HUF_TABLESIZE - 1)]; d0[i + k] := Byte(v); b0 := b0 shr (v shr 8); Dec(c0, v shr 8);
        v := t[b1 and (HUF_TABLESIZE - 1)]; d1[i + k] := Byte(v); b1 := b1 shr (v shr 8); Dec(c1, v shr 8);
        v := t[b2 and (HUF_TABLESIZE - 1)]; d2[i + k] := Byte(v); b2 := b2 shr (v shr 8); Dec(c2, v shr 8);
        v := t[b3 and (HUF_TABLESIZE - 1)]; d3[i + k] := Byte(v); b3 := b3 shr (v shr 8); Dec(c3, v shr 8);
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
      d[k][j] := Byte(v);
      r[k].buf := r[k].buf shr (v shr 8);
      Dec(r[k].count, v shr 8);
    end;
    if not RdEndsInside(r[k]) then
      Exit;
  end;
  Result := r[3].p - src - r[3].count div 8;
end;

{$ifdef HUF_ASM_X64}
initialization
  HufUseBmi2 := CpuHasBmi2;
{$endif}
end.
