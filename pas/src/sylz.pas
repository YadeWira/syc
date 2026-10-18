{ sylz — syc fast LZ codec.

  Format v1 (one block = one call; the caller stores the decoded size):

    block    := ctrlLen:u32le  control[ctrlLen]  literals[...]
    control  := sequence*
    sequence := token  offset:u16le  [litlen-ext]  [matchlen-ext]
    token    := bits 7..5  literal length 0..6, 7 = extended
                bits 4..0  match length - SYLZ_MINMATCH, 0..30; 31 = extended
    offset   := distance - 1, so distances run 1..65536
    ext      := bytes added to the field's maximum; 255 means "another
                byte follows"

  Literals live in their own stream, in order. Each sequence takes its
  literals from the front of that stream, then copies its match; whatever
  is left in the literal stream after the last sequence is the block's
  tail.

  Why two streams: the next token is always 3 bytes further on (plus the
  rare extension), whatever the literal length, so the decoder's loads for
  the next sequence don't wait on the current one. The 3/5 bit split fits
  the measured distributions (silesia.tar, see NOTES.md): 0..6 literals
  cover 93-94% of sequences, 4..34 match bytes 95-97%. }
unit sylz;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$inline on}
{$pointermath on}

interface

const
  SYLZ_MINMATCH = 4;
  SYLZ_MAXDIST  = 65536;
  SYLZ_MAXLEVEL = 12;

{ Worst-case compressed size of n input bytes. }
function SylzBound(n: SizeInt): SizeInt;

{ Compresses src[0..n) into dst (capacity cap, at least SylzBound(n)).
  level 1 = fast greedy, 2..SYLZ_MAXLEVEL = hash chains with lazy matching.
  Returns the compressed size, or -1 if cap is too small. }
function SylzCompress(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt;
  level: Integer): SizeInt;

{ Decompresses src[0..n) into exactly dstLen bytes at dst.
  Safe on corrupt input: never reads or writes out of bounds.
  Returns dstLen, or -1 on corrupt input. }
function SylzDecompress(src: PByte; n: SizeInt; dst: PByte; dstLen: SizeInt): SizeInt;

implementation

const
  HEADER_SIZE  = 4;
  LIT_FIELD    = 7;     { literal length field: 0..6 inline, 7 = extended }
  ML_FIELD     = 31;    { match length field: 0..30 inline, 31 = extended }
  SEARCH_TAIL  = 12;    { no match search within this many bytes of the end }
  FAST_HASHLOG = 14;
  SKIP_STRENGTH = 6;
  HC_HASHLOG   = 17;
  HC_MAXDIST   = 65535; { chain deltas are UInt16 }
  HC_CHAINSIZE = 1 shl 16;
  HC_CHAINMASK = HC_CHAINSIZE - 1;
  SCRATCH_SLACK = 16;   { literal scratch overshoot room for Copy16 }

function SylzBound(n: SizeInt): SizeInt;
begin
  Result := HEADER_SIZE + n + n div 255 + 16;
end;

function Read32(p: PByte): UInt32; inline;
begin
  Result := PUInt32(p)^;
end;

function Read64(p: PByte): UInt64; inline;
begin
  Result := PUInt64(p)^;
end;

procedure Copy8(d, s: PByte); inline;
begin
  PUInt64(d)^ := PUInt64(s)^;
end;

procedure Copy16(d, s: PByte); inline;
begin
  PUInt64(d)^ := PUInt64(s)^;
  PUInt64(d + 8)^ := PUInt64(s + 8)^;
end;

function Hash4(v: UInt32; hashLog: Integer): UInt32; inline;
begin
  { FPC widens UInt32*UInt32 to the native int on 64-bit targets: truncate
    before shifting or the high bits leak into the index }
  Result := UInt32(v * UInt32(2654435761)) shr (32 - hashLog);
end;

{ Hash of the 4 or 5 bytes at p for the fast level: 5 bytes on 64-bit
  targets (fewer false candidates), 4 where a 64-bit multiply is costly. }
function HashFast(p: PByte): UInt32; inline;
begin
{$ifdef CPU64}
  Result := UInt32((Read64(p) shl 24) * UInt64(889523592379) shr (64 - FAST_HASHLOG));
{$else}
  Result := Hash4(Read32(p), FAST_HASHLOG);
{$endif}
end;

{ Length of the common prefix of a and b, not reading at or past limit
  (limit applies to a; b is always behind a). }
function CountMatch(a, b, limit: PByte): SizeInt; inline;
var
  start: PByte;
  diff: UInt64;
begin
  start := a;
  while a + 8 <= limit do
  begin
    diff := Read64(a) xor Read64(b);
    if diff <> 0 then
    begin
      Result := (a - start) + SizeInt(BsfQWord(diff) shr 3);
      Exit;
    end;
    Inc(a, 8);
    Inc(b, 8);
  end;
  while (a < limit) and (a^ = b^) do
  begin
    Inc(a);
    Inc(b);
  end;
  Result := a - start;
end;

{ ── encoder output ───────────────────────────────────────────────────────── }

type
  { The control stream is written straight into dst (after the header);
    literals go to a scratch buffer and are appended when the block ends. }
  TEmit = record
    dst, ctrl, oend: PByte;
    lits, lit: PByte;
    srcEnd: PByte;    { end of the input: bounds the wide literal reads }
  end;

procedure EmitInit(out e: TEmit; dst: PByte; cap: SizeInt; scratch, srcEnd: PByte);
begin
  e.srcEnd := srcEnd;
  e.dst := dst;
  e.ctrl := dst + HEADER_SIZE;
  e.oend := dst + cap;
  e.lits := scratch;
  e.lit := scratch;
end;

procedure PutExt(var p: PByte; v: SizeInt); inline;
begin
  while v >= 255 do
  begin
    p^ := 255;
    Inc(p);
    Dec(v, 255);
  end;
  p^ := Byte(v);
  Inc(p);
end;

{ One sequence: litLen literals starting at lit, then a match. Returns false
  when the block would no longer fit in dst. }
{ Not inline on purpose: inlined, its locals and its Move call add to the
  compressor loop's register pressure, and that loop is the hotter one
  (measured: 273 -> 285 MB/s at level 1). }
function EmitSequence(var e: TEmit; lit: PByte; litLen, dist, matchLen: SizeInt): Boolean;
var
  l, m: SizeInt;
  p: PByte;
begin
  { control so far + this entry, worst case + all literals so far }
  if e.ctrl + 3 + litLen div 255 + 1 + matchLen div 255 + 1
     + (e.lit - e.lits) + litLen > e.oend then
    Exit(False);
  m := matchLen - SYLZ_MINMATCH;
  if litLen < LIT_FIELD then l := litLen else l := LIT_FIELD;
  if m >= ML_FIELD then
    e.ctrl[0] := Byte((l shl 5) or ML_FIELD)
  else
    e.ctrl[0] := Byte((l shl 5) or m);
  e.ctrl[1] := Byte(dist - 1);
  e.ctrl[2] := Byte((dist - 1) shr 8);
  p := e.ctrl + 3;
  if litLen >= LIT_FIELD then
    PutExt(p, litLen - LIT_FIELD);
  if m >= ML_FIELD then
    PutExt(p, m - ML_FIELD);
  e.ctrl := p;
  { the scratch buffer has SCRATCH_SLACK spare bytes }
  if (litLen <= 16) and (lit + 16 <= e.srcEnd) then
    Copy16(e.lit, lit)
  else
    Move(lit^, e.lit^, litLen);
  Inc(e.lit, litLen);
  Result := True;
end;

{ Appends the block's tail literals and the literal stream; returns the
  block size or -1. }
function EmitFinish(var e: TEmit; lit: PByte; litLen: SizeInt): SizeInt;
var
  ctrlLen, litTotal: SizeInt;
begin
  ctrlLen := e.ctrl - (e.dst + HEADER_SIZE);
  litTotal := (e.lit - e.lits) + litLen;
  if e.ctrl + litTotal > e.oend then
    Exit(-1);
  PUInt32(e.dst)^ := UInt32(ctrlLen);
  Move(e.lits^, e.ctrl^, e.lit - e.lits);
  Move(lit^, (e.ctrl + (e.lit - e.lits))^, litLen);
  Result := HEADER_SIZE + ctrlLen + litTotal;
end;

{ ── level 1: greedy, single hash table, accelerating skip ────────────────── }

{ The hot loops take raw, preallocated buffers and leave allocation to a
  wrapper: a try/finally or a managed local (dynamic array) gives a routine
  an exception frame built on fpc_setjmp, and with one the compressor loop
  kept nearly every local on the stack. }
function CompressFastCore(src: PByte; n: SizeInt; var e: TEmit; table: PUInt32): SizeInt;
{ (written without labels/goto: the goto version kept more of its locals
  on the stack, 127 vs 104 references, and ran at 226 vs 273 MB/s) }
var
  ip, anchor, iend, mflimit, ref, fwd: PByte;
  h, fwdH: UInt32;
  len, step, probes: SizeInt;
begin
  anchor := src;
  iend := src + n;
  ref := src;   { only read after a successful probe; silences a warning }
  if n >= SEARCH_TAIL + 1 then
  begin
    mflimit := iend - SEARCH_TAIL;
    ip := src + 1;
    fwdH := HashFast(ip);
    while True do
    begin
      { find a match; the probe step grows with the number of misses }
      fwd := ip;
      step := 1;
      probes := 1 shl SKIP_STRENGTH;
      repeat
        h := fwdH;
        ip := fwd;
        Inc(fwd, step);
        step := probes shr SKIP_STRENGTH;
        Inc(probes);
        if fwd > mflimit then
          Break;
        ref := src + table[h];
        fwdH := HashFast(fwd);
        table[h] := UInt32(ip - src);
      until (ip - ref <= SYLZ_MAXDIST) and (Read32(ref) = Read32(ip));
      if fwd > mflimit then
        Break;

      while (ip > anchor) and (ref > src) and (ip[-1] = ref[-1]) do
      begin
        Dec(ip);
        Dec(ref);
      end;

      { emit, then chain straight into a match at the next position: it
        needs no literals }
      repeat
        len := SYLZ_MINMATCH + CountMatch(ip + SYLZ_MINMATCH, ref + SYLZ_MINMATCH, iend);
        if not EmitSequence(e, anchor, ip - anchor, ip - ref, len) then
          Exit(-1);
        Inc(ip, len);
        anchor := ip;
        if ip > mflimit then
          Break;
        table[HashFast(ip - 2)] := UInt32(ip - 2 - src);
        h := HashFast(ip);
        ref := src + table[h];
        table[h] := UInt32(ip - src);
      until (ip - ref > SYLZ_MAXDIST) or (Read32(ref) <> Read32(ip));
      if ip > mflimit then
        Break;

      Inc(ip);
      fwdH := HashFast(ip);
    end;
  end;
  Result := EmitFinish(e, anchor, iend - anchor);
end;

function CompressFast(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt): SizeInt;
var
  e: TEmit;
  scratch: PByte;
  table: PUInt32;
begin
  scratch := GetMem(n + SCRATCH_SLACK);
  table := GetMem(SizeOf(UInt32) shl FAST_HASHLOG);
  try
    FillChar(table^, SizeOf(UInt32) shl FAST_HASHLOG, 0);   { position 0 }
    EmitInit(e, dst, cap, scratch, src + n);
    Result := CompressFastCore(src, n, e, table);
  finally
    FreeMem(table);
    FreeMem(scratch);
  end;
end;

{ ── levels 2+: hash chains, lazy matching ────────────────────────────────── }

type
  THcState = record
    src: PByte;
    head: PInt32;             { last position with this hash, -1 = none }
    chain: PUInt16;           { distance to the previous position with the same hash }
    nextToInsert: SizeInt;
    attempts: Integer;
  end;

procedure HcInsertUpTo(var s: THcState; pos: SizeInt); inline;
var
  i, prev, delta: SizeInt;
  h: UInt32;
begin
  i := s.nextToInsert;
  while i < pos do
  begin
    h := Hash4(Read32(s.src + i), HC_HASHLOG);
    prev := s.head[h];
    delta := i - prev;
    if (prev < 0) or (delta > HC_MAXDIST) then
      delta := 0;               { 0 terminates the chain }
    s.chain[i and HC_CHAINMASK] := UInt16(delta);
    s.head[h] := Int32(i);
    Inc(i);
  end;
  s.nextToInsert := pos;
end;

{ Longest match for position pos; returns its length (0 if < MINMATCH) and
  its distance in dist. }
function HcFindBest(var s: THcState; pos: SizeInt; matchlimit: PByte;
  out dist: SizeInt): SizeInt;
var
  ip, ref: PByte;
  cand, delta, len, best: SizeInt;
  tries: Integer;
  first: UInt32;
begin
  HcInsertUpTo(s, pos);
  ip := s.src + pos;
  first := Read32(ip);
  best := 0;
  dist := 0;
  cand := s.head[Hash4(first, HC_HASHLOG)];
  if (cand >= 0) and (cand < pos) then
  begin
    tries := s.attempts;
    { the head entry for pos itself is inserted only later, so cand < pos }
    while (tries > 0) and (pos - cand <= HC_MAXDIST) do
    begin
      ref := s.src + cand;
      { check the byte that would extend the best match first: cheap reject;
        ip + best < matchlimit here, see the Break below }
      if (ref[best] = ip[best]) and (Read32(ref) = first) then
      begin
        len := SYLZ_MINMATCH + CountMatch(ip + SYLZ_MINMATCH, ref + SYLZ_MINMATCH, matchlimit);
        if len > best then
        begin
          best := len;
          dist := pos - cand;
          if ip + len >= matchlimit then
            Break;
        end;
      end;
      Dec(tries);
      delta := s.chain[cand and HC_CHAINMASK];
      if delta = 0 then
        Break;
      Dec(cand, delta);
    end;
  end;
  if best < SYLZ_MINMATCH then
    best := 0;
  Result := best;
end;

function CompressHCCore(src: PByte; n: SizeInt; var e: TEmit; var s: THcState;
  level: Integer): SizeInt;
var
  iend, mflimit: PByte;
  pos, anchor, len, dist, len2, dist2: SizeInt;
begin
  iend := src + n;
  anchor := 0;
  if n >= SEARCH_TAIL + 1 then
  begin
    s.src := src;
    s.nextToInsert := 0;
    s.attempts := 1 shl (level - 1);
    mflimit := iend - SEARCH_TAIL;
    pos := 0;
    while src + pos < mflimit do
    begin
      len := HcFindBest(s, pos, iend, dist);
      if len = 0 then
      begin
        Inc(pos);
        Continue;
      end;
      { lazy: a longer match one byte later is worth a literal }
      while src + pos + 1 < mflimit do
      begin
        len2 := HcFindBest(s, pos + 1, iend, dist2);
        if len2 <= len then
          Break;
        Inc(pos);
        len := len2;
        dist := dist2;
      end;
      if not EmitSequence(e, src + anchor, pos - anchor, dist, len) then
        Exit(-1);
      Inc(pos, len);
      anchor := pos;
    end;
  end;
  Result := EmitFinish(e, src + anchor, n - anchor);
end;

function CompressHC(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt;
  level: Integer): SizeInt;
var
  e: TEmit;
  s: THcState;
  scratch: PByte;
  i: Integer;
begin
  scratch := GetMem(n + SCRATCH_SLACK);
  s.head := GetMem(SizeOf(Int32) shl HC_HASHLOG);
  s.chain := GetMem(SizeOf(UInt16) * HC_CHAINSIZE);
  try
    for i := 0 to (1 shl HC_HASHLOG) - 1 do
      s.head[i] := -1;
    EmitInit(e, dst, cap, scratch, src + n);
    Result := CompressHCCore(src, n, e, s, level);
  finally
    FreeMem(s.chain);
    FreeMem(s.head);
    FreeMem(scratch);
  end;
end;

function SylzCompress(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt;
  level: Integer): SizeInt;
begin
  if cap < HEADER_SIZE then
    Exit(-1);
  if level < 1 then
    level := 1;
  if level > SYLZ_MAXLEVEL then
    level := SYLZ_MAXLEVEL;
  if level = 1 then
    Result := CompressFast(src, n, dst, cap)
  else
    Result := CompressHC(src, n, dst, cap, level);
end;

{ ── decoder ──────────────────────────────────────────────────────────────── }

{ Reads a 255-run extension at p, not reading at or past pend. Returns
  false if it runs off the end. }
function GetExt(var p: PByte; pend: PByte; var v: SizeInt): Boolean; inline;
var
  b: SizeInt;
begin
  repeat
    if p >= pend then
      Exit(False);
    b := p^;
    Inc(p);
    Inc(v, b);
  until b <> 255;
  Result := True;
end;

{ Exact, fully checked decoding from the given stream positions to the end
  of the block. Handles the block tail and any sequence that doesn't fit
  the fast loop's margins. Kept out of line: its Move calls would force
  the fast loop's variables out of registers. }
function DecodeSafe(ctrl, cend, lit, lend, op, oend, dst: PByte): SizeInt;
var
  m: PByte;
  t: Byte;
  ll, ml, off: SizeInt;
begin
  Result := -1;
  while ctrl < cend do
  begin
    if cend - ctrl < 3 then
      Exit;
    t := ctrl[0];
    off := SizeInt(ctrl[1] or (UInt32(ctrl[2]) shl 8)) + 1;
    Inc(ctrl, 3);
    ll := t shr 5;
    ml := t and 31;
    if (ll = LIT_FIELD) and not GetExt(ctrl, cend, ll) then
      Exit;
    if (ml = ML_FIELD) and not GetExt(ctrl, cend, ml) then
      Exit;
    Inc(ml, SYLZ_MINMATCH);
    if (ll > lend - lit) or (ll > oend - op) then
      Exit;
    Move(lit^, op^, ll);
    Inc(op, ll);
    Inc(lit, ll);
    if (off > op - dst) or (ml > oend - op) then
      Exit;
    m := op - off;
    if off >= ml then
    begin
      Move(m^, op^, ml);
      Inc(op, ml);
    end
    else
      while ml > 0 do
      begin
        op^ := m^;
        Inc(op);
        Inc(m);
        Dec(ml);
      end;
  end;
  { the rest of the literal stream is the block's tail }
  if lend - lit <> oend - op then
    Exit;
  Move(lit^, op^, lend - lit);
  Result := oend - dst;
end;

const
  { A sequence starts in the fast loop only with this much room left. The
    common sequence (literal and match fields not extended) copies 8
    literal bytes and up to 48 match bytes unconditionally, so it never
    needs a bounds check; extended ones are checked one by one. }
  CTRL_MARGIN = 3;
  LIT_MARGIN  = 16;
  OUT_MARGIN  = 64;
  { smallest multiple of off that is >= 8, for off in 1..7 }
  PERIOD_STRIDE: array[1..7] of Byte = (8, 8, 9, 8, 10, 12, 14);

{ The fast loop is register-starved under FPC: 14 GPRs, and when they run
  out its allocator may spill exactly the pointer on the critical path.
  So the values used only in comparisons (the fast limits and dst) live in
  a record, which FPC never keeps in registers: a compare against an L1
  stack slot is cheap and off the dependency chain, and the registers go
  to ctrl, lit, op and the sequence fields. }
type
  TDecodeLimits = record
    cfast, lfast, ofast, dst: PByte;
  end;

function SylzDecompress(src: PByte; n: SizeInt; dst: PByte; dstLen: SizeInt): SizeInt;
var
  lim: TDecodeLimits;
  ctrl, lit, op, m: PByte;
  t, off: SizeUInt;
  ll, ml: SizeInt;   { signed: the copy loops count them down past zero }
begin
  if n < HEADER_SIZE then
    Exit(-1);
  ll := PUInt32(src)^;
  if ll > n - HEADER_SIZE then
    Exit(-1);
  ctrl := src + HEADER_SIZE;
  lit := ctrl + ll;
  lim.cfast := lit - CTRL_MARGIN;
  lim.lfast := src + n - LIT_MARGIN;
  lim.ofast := dst + dstLen - OUT_MARGIN;
  lim.dst := dst;
  op := dst;

  while (ctrl <= lim.cfast) and (lit <= lim.lfast) and (op <= lim.ofast) do
  begin
    t := ctrl[0];
    off := SizeUInt(PUInt16(ctrl + 1)^) + 1;
    Inc(ctrl, 3);

    if (t < LIT_FIELD shl 5) and ((t and 31) <> ML_FIELD) then
    begin
      { common case: both fields inline }
      ll := t shr 5;
      ml := (t and 31) + SYLZ_MINMATCH;
      Copy8(op, lit);
      Inc(op, ll);
      Inc(lit, ll);
    end
    else
    begin
      { extended field(s): read them through m so that giving up leaves
        everything at the token, nothing written yet }
      { (written out instead of calling GetExt: passing ll/ml/m by var,
        even to an inline function, would pin them to the stack) }
      ll := t shr 5;
      ml := t and 31;
      m := ctrl;
      if ll = LIT_FIELD then
        repeat
          if m >= lim.cfast + CTRL_MARGIN then
          begin
            ll := -1;
            Break;
          end;
          Inc(ll, m^);
          Inc(m);
        until m[-1] <> 255;
      if (ml = ML_FIELD) and (ll >= 0) then
        repeat
          if m >= lim.cfast + CTRL_MARGIN then
          begin
            ll := -1;
            Break;
          end;
          Inc(ml, m^);
          Inc(m);
        until m[-1] <> 255;
      Inc(ml, SYLZ_MINMATCH);
      if (ll < 0) or (ll > lim.lfast - lit) or (ll + ml > lim.ofast - op + 16) then
      begin
        Dec(ctrl, 3);   { DecodeSafe redoes this sequence exactly }
        Break;
      end;
      ctrl := m;
      { count down; the last step overshoots by -ll bytes, taken back after }
      repeat
        Copy16(op, lit);
        Inc(op, 16);
        Inc(lit, 16);
        Dec(ll, 16);
      until ll <= 0;
      Inc(op, ll);
      Inc(lit, ll);
    end;

    { match }
    if SizeInt(off) > op - lim.dst then
      Exit(-1);
    m := op - off;
    if off >= 16 then
    begin
      Copy16(op, m);
      Copy16(op + 16, m + 16);
      if ml > 32 then
      begin
        Inc(op, 32);
        Inc(m, 32);
        Dec(ml, 32);
        repeat
          Copy16(op, m);
          Inc(op, 16);
          Inc(m, 16);
          Dec(ml, 16);
        until ml <= 0;
      end;
      Inc(op, ml);   { ml <= 32: a single step; else ml <= 0, the overshoot }
    end
    else if off >= 8 then
    begin
      repeat
        Copy8(op, m);
        Inc(op, 8);
        Inc(m, 8);
        Dec(ml, 8);
      until ml <= 0;
      Inc(op, ml);
    end
    else
    begin
      { off < 8: the first 8 bytes byte by byte. They repeat with period
        off, so the rest can be copied from the nearest multiple of off
        that is >= 8, which allows 8-byte steps }
      op[0] := m[0]; op[1] := m[1]; op[2] := m[2]; op[3] := m[3];
      op[4] := m[4]; op[5] := m[5]; op[6] := m[6]; op[7] := m[7];
      Inc(op, 8);
      m := op - PERIOD_STRIDE[off];
      Dec(ml, 8);
      while ml > 0 do
      begin
        Copy8(op, m);
        Inc(op, 8);
        Inc(m, 8);
        Dec(ml, 8);
      end;
      Inc(op, ml);
    end;
  end;
  Result := DecodeSafe(ctrl, lim.cfast + CTRL_MARGIN, lit, lim.lfast + LIT_MARGIN,
    op, lim.ofast + OUT_MARGIN, dst);
end;

end.
