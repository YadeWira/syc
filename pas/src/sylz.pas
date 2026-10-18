{ sylz — syc fast LZ codec.

  Format v0 (one block = one call; the caller stores the decoded size):

    sequence := token [litlen-ext] literals [offset16 [matchlen-ext]]
    token    := high nibble literal length (15 = extended),
                low nibble  match length - SYLZ_MINMATCH (15 = extended)
    ext      := bytes added to the nibble; 255 means "another byte follows"
    offset16 := little-endian distance back from the current output, 1..65535

  The last sequence carries literals only: the block ends right after them.
  The encoder keeps the last SYLZ_LASTLITERALS bytes as literals and starts no
  match within SYLZ_MFLIMIT bytes of the end, so the decoder's fast copies
  (which may write up to 15 bytes past a sequence) stay inside the block in
  the common case; near the end it falls back to exact copies.

  v0 is deliberately LZ4-shaped: it exists to measure how much Free Pascal's
  codegen costs against the C reference before the format gets its own ideas. }
unit sylz;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$inline on}
{$pointermath on}

interface

const
  SYLZ_MINMATCH     = 4;
  SYLZ_LASTLITERALS = 5;
  SYLZ_MFLIMIT      = 12;
  SYLZ_MAXDIST      = 65535;
  SYLZ_MAXLEVEL     = 12;

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
  FAST_HASHLOG = 16;
  HC_HASHLOG   = 17;
  HC_CHAINSIZE = 1 shl 16;   { power of two > SYLZ_MAXDIST }
  HC_CHAINMASK = HC_CHAINSIZE - 1;

function SylzBound(n: SizeInt): SizeInt;
begin
  Result := n + n div 255 + 16;
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

{ Writes one sequence. litLen literals start at lit; matchLen = 0 means the
  final, literals-only sequence. Returns false when dst would overflow. }
function EmitSequence(var op: PByte; oend: PByte; lit: PByte; litLen: SizeInt;
  offset, matchLen: SizeInt): Boolean; inline;
var
  token: PByte;
  l: SizeInt;
begin
  Result := False;
  { token + literal ext + literals + offset + match ext, worst case }
  if op + 1 + litLen div 255 + 1 + litLen + 2 + matchLen div 255 + 1 > oend then
    Exit;
  token := op;
  Inc(op);
  if litLen >= 15 then
  begin
    token^ := 15 shl 4;
    l := litLen - 15;
    while l >= 255 do
    begin
      op^ := 255;
      Inc(op);
      Dec(l, 255);
    end;
    op^ := Byte(l);
    Inc(op);
  end
  else
    token^ := Byte(litLen shl 4);
  Move(lit^, op^, litLen);
  Inc(op, litLen);
  if matchLen = 0 then
    Exit(True);
  op[0] := Byte(offset);
  op[1] := Byte(offset shr 8);
  Inc(op, 2);
  l := matchLen - SYLZ_MINMATCH;
  if l >= 15 then
  begin
    token^ := token^ or 15;
    Dec(l, 15);
    while l >= 255 do
    begin
      op^ := 255;
      Inc(op);
      Dec(l, 255);
    end;
    op^ := Byte(l);
    Inc(op);
  end
  else
    token^ := token^ or Byte(l);
  Result := True;
end;

{ ── level 1: greedy, single hash table ───────────────────────────────────── }

function CompressFast(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt): SizeInt;
var
  table: array of UInt32;
  ip, anchor, iend, mflimit, matchlimit, ref, op, oend: PByte;
  h: UInt32;
  len, step, misses: SizeInt;
begin
  op := dst;
  oend := dst + cap;
  anchor := src;
  iend := src + n;
  if n >= SYLZ_MFLIMIT + 1 then
  begin
    SetLength(table, 1 shl FAST_HASHLOG);   { zero-filled: position 0 }
    mflimit := iend - SYLZ_MFLIMIT;
    matchlimit := iend - SYLZ_LASTLITERALS;
    ip := src + 1;
    misses := 0;
    while ip < mflimit do
    begin
      h := Hash4(Read32(ip), FAST_HASHLOG);
      ref := src + table[h];
      table[h] := UInt32(ip - src);
      if (ip - ref <= SYLZ_MAXDIST) and (Read32(ref) = Read32(ip)) then
      begin
        while (ip > anchor) and (ref > src) and (ip[-1] = ref[-1]) do
        begin
          Dec(ip);
          Dec(ref);
        end;
        len := SYLZ_MINMATCH + CountMatch(ip + SYLZ_MINMATCH, ref + SYLZ_MINMATCH, matchlimit);
        if not EmitSequence(op, oend, anchor, ip - anchor, ip - ref, len) then
          Exit(-1);
        Inc(ip, len);
        anchor := ip;
        if ip < mflimit then
          table[Hash4(Read32(ip - 2), FAST_HASHLOG)] := UInt32(ip - 2 - src);
        misses := 0;
      end
      else
      begin
        { skip faster through incompressible stretches: the step grows with
          the number of failed probes, not the distance (that would be
          quadratic and skip whole files) }
        step := 1 + misses shr 6;
        Inc(misses);
        Inc(ip, step);
      end;
    end;
  end;
  if not EmitSequence(op, oend, anchor, iend - anchor, 0, 0) then
    Exit(-1);
  Result := op - dst;
end;

{ ── levels 2+: hash chains, lazy matching ────────────────────────────────── }

type
  THcState = record
    src: PByte;
    head: array of Int32;     { last position with this hash, -1 = none }
    chain: array of UInt16;   { distance to the previous position with the same hash }
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
    if (prev < 0) or (delta > SYLZ_MAXDIST) then
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
    while (tries > 0) and (pos - cand <= SYLZ_MAXDIST) do
    begin
      ref := s.src + cand;
      { check the byte that would extend the best match first: cheap reject }
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

function CompressHC(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt;
  level: Integer): SizeInt;
var
  s: THcState;
  op, oend, iend, mflimit, matchlimit: PByte;
  pos, anchor, len, dist, len2, dist2: SizeInt;
  i: Integer;
begin
  op := dst;
  oend := dst + cap;
  iend := src + n;
  anchor := 0;
  if n >= SYLZ_MFLIMIT + 1 then
  begin
    s.src := src;
    SetLength(s.head, 1 shl HC_HASHLOG);
    for i := 0 to High(s.head) do
      s.head[i] := -1;
    SetLength(s.chain, HC_CHAINSIZE);
    s.nextToInsert := 0;
    s.attempts := 1 shl (level - 1);
    mflimit := iend - SYLZ_MFLIMIT;
    matchlimit := iend - SYLZ_LASTLITERALS;
    pos := 0;
    while src + pos < mflimit do
    begin
      len := HcFindBest(s, pos, matchlimit, dist);
      if len = 0 then
      begin
        Inc(pos);
        Continue;
      end;
      { lazy: a longer match one byte later is worth a literal }
      while src + pos + 1 < mflimit do
      begin
        len2 := HcFindBest(s, pos + 1, matchlimit, dist2);
        if len2 <= len then
          Break;
        Inc(pos);
        len := len2;
        dist := dist2;
      end;
      if not EmitSequence(op, oend, src + anchor, pos - anchor, dist, len) then
        Exit(-1);
      Inc(pos, len);
      anchor := pos;
    end;
  end;
  if not EmitSequence(op, oend, src + anchor, n - anchor, 0, 0) then
    Exit(-1);
  Result := op - dst;
end;

function SylzCompress(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt;
  level: Integer): SizeInt;
begin
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

{ Exact, fully checked decoding from (ip, op) to the end of the block. Used
  for the block tail and for any sequence that doesn't fit the fast loop's
  margins. Kept out of line: its Move call would otherwise force the fast
  loop's variables out of registers. }
function DecodeSafe(ip, iend, op, oend, dst: PByte): SizeInt;
var
  m, cpyEnd: PByte;
  token: Byte;
  b: Byte;
  ll, ml, off: SizeInt;
begin
  Result := -1;
  while True do
  begin
    if ip >= iend then
      Exit;
    token := ip^;
    Inc(ip);

    { literals }
    ll := token shr 4;
    if ll = 15 then
      repeat
        if ip >= iend then
          Exit;
        b := ip^;
        Inc(ip);
        Inc(ll, b);
      until b <> 255;
    if (ll > iend - ip) or (ll > oend - op) then
      Exit;
    if (ll <= 16) and (iend - ip >= 16) and (oend - op >= 16) then
      Copy16(op, ip)
    else
      Move(ip^, op^, ll);
    Inc(op, ll);
    Inc(ip, ll);
    if ip = iend then
      Break;

    { match }
    if iend - ip < 2 then
      Exit;
    off := ip[0] or (SizeInt(ip[1]) shl 8);
    Inc(ip, 2);
    if (off = 0) or (off > op - dst) then
      Exit;
    ml := token and 15;
    if ml = 15 then
      repeat
        if ip >= iend then
          Exit;
        b := ip^;
        Inc(ip);
        Inc(ml, b);
      until b <> 255;
    Inc(ml, SYLZ_MINMATCH);
    if ml > oend - op then
      Exit;
    m := op - off;
    cpyEnd := op + ml;
    if (off >= 8) and (oend - cpyEnd >= 8) then
    begin
      { 8-byte steps may overshoot cpyEnd by up to 7 bytes: still in dst }
      repeat
        Copy8(op, m);
        Inc(op, 8);
        Inc(m, 8);
      until op >= cpyEnd;
      op := cpyEnd;
    end
    else
    begin
      while op < cpyEnd do
      begin
        op^ := m^;
        Inc(op);
        Inc(m);
      end;
    end;
  end;
  if op <> oend then
    Exit;
  Result := oend - dst;
end;

const
  { a sequence starts in the fast loop only with this much room left on
    both sides; every fast copy (literals, matches, their overshoot) then
    stays inside the buffers without a per-copy check }
  FAST_MARGIN = 32;
  { smallest multiple of off that is >= 8, for off in 1..7 }
  PERIOD_STRIDE: array[1..7] of Byte = (8, 8, 9, 8, 10, 12, 14);

{ The fast loop is register-starved under FPC (14 GPRs, and its allocator
  spills the hottest variable first), so it keeps the live set small: no
  saved sequence start, and `off` doubles as the scratch byte for length
  extensions while it holds no offset. }
function SylzDecompress(src: PByte; n: SizeInt; dst: PByte; dstLen: SizeInt): SizeInt;
var
  ip, iend, op, oend, m: PByte;
  token, off: SizeUInt;
  ll, ml: SizeInt;   { signed: the copy loops count them down past zero }
begin
  ip := src;
  iend := src + n;
  op := dst;
  oend := dst + dstLen;
  while (iend - ip >= FAST_MARGIN) and (oend - op >= FAST_MARGIN) do
  begin
    token := ip^;
    Inc(ip);

    { literals }
    ll := token shr 4;
    if ll <> 15 then
    begin
      Copy16(op, ip);
      Inc(op, ll);
      Inc(ip, ll);
    end
    else
    begin
      { read the extension through m so that giving up leaves ip, op at
        the token: nothing has been written yet }
      m := ip;
      repeat
        if m >= iend - FAST_MARGIN div 2 then
        begin
          ll := -1;   { extension runs into the margin }
          Break;
        end;
        off := m^;
        Inc(m);
        Inc(ll, off);
      until off <> 255;
      if (ll < 0) or (ll > iend - m - 16) or (ll > oend - op - FAST_MARGIN) then
      begin
        Dec(ip);      { back to the token: DecodeSafe redoes this sequence }
        Break;
      end;
      ip := m;
      { count down; the last step overshoots by -ll bytes, taken back after }
      repeat
        Copy16(op, ip);
        Inc(op, 16);
        Inc(ip, 16);
        Dec(ll, 16);
      until ll <= 0;
      Inc(op, ll);
      Inc(ip, ll);
    end;

    { match; at least 13 input bytes remain here }
    off := PUInt16(ip)^;
    Inc(ip, 2);
    if (off = 0) or (SizeInt(off) > op - dst) then
      Exit(-1);
    m := op - off;
    ml := token and 15;
    if ml = 15 then
      repeat
        if ip >= iend then
          Exit(-1);
        off := ip^;
        Inc(ip);
        Inc(ml, off);
      until off <> 255;
    Inc(ml, SYLZ_MINMATCH);
    if ml > oend - op - 16 then
    begin
      { only near the end of the output: exact copy, no overshoot }
      if ml > oend - op then
        Exit(-1);
      repeat
        op^ := m^;
        Inc(op);
        Inc(m);
        Dec(ml);
      until ml = 0;
      Continue;
    end;
    off := op - m;
    if off >= 16 then
      repeat
        Copy16(op, m);
        Inc(op, 16);
        Inc(m, 16);
        Dec(ml, 16);
      until ml <= 0
    else if off >= 8 then
      repeat
        Copy8(op, m);
        Inc(op, 8);
        Inc(m, 8);
        Dec(ml, 8);
      until ml <= 0
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
    end;
    Inc(op, ml);   { ml <= 0: undo the overshoot }
  end;
  Result := DecodeSafe(ip, iend, op, oend, dst);
end;

end.
