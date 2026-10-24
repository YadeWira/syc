{ blake2s — BLAKE2s-256 (RFC 7693), unkeyed: the identity of the archive's
  fragments (see the wiki's syc archive format).

  The block function is C (sylzc_blake2s_blocks in src/sylzc.c, linked
  through the sylz unit) unless SYLZ_PUREPASCAL; the Pascal one below is
  the reference, and tests/sycdedup checks that both agree. Measured on
  silesia.tar (x86_64): Pascal ~160 MB/s, C (see NOTES.md). Blake2sMany
  hashes four messages at a time in vector lanes (C). }
unit blake2s;

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

{$ifndef SYLZ_PUREPASCAL}
uses
  sylz;   { links sylzc.o }
{$endif}

const
  BLAKE2S_OUTLEN = 32;

type
  TBlake2sDigest = array[0..BLAKE2S_OUTLEN - 1] of Byte;
  PBlake2sDigest = ^TBlake2sDigest;

  TBlake2s = record
    h: array[0..7] of UInt32;
    t: UInt64;                    { bytes compressed so far }
    buf: array[0..63] of Byte;
    bufLen: Integer;
  end;

procedure Blake2sInit(out s: TBlake2s);
procedure Blake2sUpdate(var s: TBlake2s; p: PByte; n: SizeInt);
procedure Blake2sFinal(var s: TBlake2s; out digest: TBlake2sDigest);
{ the hash of p[0..n) in one call }
procedure Blake2s256(p: PByte; n: SizeInt; out digest: TBlake2sDigest);
{ the hashes of count messages (msg[k], len[k]) into digests[k]: in C,
  four at a time in vector lanes; the same as Blake2s256 on each }
procedure Blake2sMany(msg: PPByte; len: PSizeInt; count: SizeInt; digests: PByte);

var
  { the C block function (when built in); False: the Pascal one }
  Blake2sUseC: Boolean = {$ifdef SYLZ_PUREPASCAL}False{$else}True{$endif};

implementation

{$ifndef SYLZ_PUREPASCAL}
procedure sylzc_blake2s_blocks(h: PUInt32; p: PByte; n: SizeInt; t: PUInt64; last: LongInt);
  cdecl; external name 'sylzc_blake2s_blocks';
procedure sylzc_blake2s_many(msg: PPByte; len: PSizeInt; count: SizeInt; digests: PByte);
  cdecl; external name 'sylzc_blake2s_many';
{$endif}

const
  IV: array[0..7] of UInt32 = (
    $6A09E667, $BB67AE85, $3C6EF372, $A54FF53A,
    $510E527F, $9B05688C, $1F83D9AB, $5BE0CD19);

  SIGMA: array[0..9, 0..15] of Byte = (
    ( 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15),
    (14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3),
    (11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4),
    ( 7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8),
    ( 9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13),
    ( 2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9),
    (12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11),
    (13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10),
    ( 6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5),
    (10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0));

{ one 64-byte block, s.t already counting it; last: the final one (the
  f0 flag) }
procedure Compress(var s: TBlake2s; block: PByte; last: Boolean);
var
  m: array[0..15] of UInt32;
  v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15: UInt32;
  r, i: Integer;
  sg: PByte;
begin
  for i := 0 to 15 do
    m[i] := LEtoN(PUInt32(block + 4 * i)^);
  v0 := s.h[0]; v1 := s.h[1]; v2 := s.h[2]; v3 := s.h[3];
  v4 := s.h[4]; v5 := s.h[5]; v6 := s.h[6]; v7 := s.h[7];
  v8 := IV[0]; v9 := IV[1]; v10 := IV[2]; v11 := IV[3];
  v12 := IV[4] xor UInt32(s.t);
  v13 := IV[5] xor UInt32(s.t shr 32);
  if last then
    v14 := not IV[6]
  else
    v14 := IV[6];
  v15 := IV[7];
  for r := 0 to 9 do
  begin
    sg := @SIGMA[r, 0];
    { columns }
    v0 := v0 + v4 + m[sg[0]];  v12 := RorDWord(v12 xor v0, 16);
    v8 := v8 + v12;            v4 := RorDWord(v4 xor v8, 12);
    v0 := v0 + v4 + m[sg[1]];  v12 := RorDWord(v12 xor v0, 8);
    v8 := v8 + v12;            v4 := RorDWord(v4 xor v8, 7);

    v1 := v1 + v5 + m[sg[2]];  v13 := RorDWord(v13 xor v1, 16);
    v9 := v9 + v13;            v5 := RorDWord(v5 xor v9, 12);
    v1 := v1 + v5 + m[sg[3]];  v13 := RorDWord(v13 xor v1, 8);
    v9 := v9 + v13;            v5 := RorDWord(v5 xor v9, 7);

    v2 := v2 + v6 + m[sg[4]];  v14 := RorDWord(v14 xor v2, 16);
    v10 := v10 + v14;          v6 := RorDWord(v6 xor v10, 12);
    v2 := v2 + v6 + m[sg[5]];  v14 := RorDWord(v14 xor v2, 8);
    v10 := v10 + v14;          v6 := RorDWord(v6 xor v10, 7);

    v3 := v3 + v7 + m[sg[6]];  v15 := RorDWord(v15 xor v3, 16);
    v11 := v11 + v15;          v7 := RorDWord(v7 xor v11, 12);
    v3 := v3 + v7 + m[sg[7]];  v15 := RorDWord(v15 xor v3, 8);
    v11 := v11 + v15;          v7 := RorDWord(v7 xor v11, 7);
    { diagonals }
    v0 := v0 + v5 + m[sg[8]];  v15 := RorDWord(v15 xor v0, 16);
    v10 := v10 + v15;          v5 := RorDWord(v5 xor v10, 12);
    v0 := v0 + v5 + m[sg[9]];  v15 := RorDWord(v15 xor v0, 8);
    v10 := v10 + v15;          v5 := RorDWord(v5 xor v10, 7);

    v1 := v1 + v6 + m[sg[10]]; v12 := RorDWord(v12 xor v1, 16);
    v11 := v11 + v12;          v6 := RorDWord(v6 xor v11, 12);
    v1 := v1 + v6 + m[sg[11]]; v12 := RorDWord(v12 xor v1, 8);
    v11 := v11 + v12;          v6 := RorDWord(v6 xor v11, 7);

    v2 := v2 + v7 + m[sg[12]]; v13 := RorDWord(v13 xor v2, 16);
    v8 := v8 + v13;            v7 := RorDWord(v7 xor v8, 12);
    v2 := v2 + v7 + m[sg[13]]; v13 := RorDWord(v13 xor v2, 8);
    v8 := v8 + v13;            v7 := RorDWord(v7 xor v8, 7);

    v3 := v3 + v4 + m[sg[14]]; v14 := RorDWord(v14 xor v3, 16);
    v9 := v9 + v14;            v4 := RorDWord(v4 xor v9, 12);
    v3 := v3 + v4 + m[sg[15]]; v14 := RorDWord(v14 xor v3, 8);
    v9 := v9 + v14;            v4 := RorDWord(v4 xor v9, 7);
  end;
  s.h[0] := s.h[0] xor v0 xor v8;
  s.h[1] := s.h[1] xor v1 xor v9;
  s.h[2] := s.h[2] xor v2 xor v10;
  s.h[3] := s.h[3] xor v3 xor v11;
  s.h[4] := s.h[4] xor v4 xor v12;
  s.h[5] := s.h[5] xor v5 xor v13;
  s.h[6] := s.h[6] xor v6 xor v14;
  s.h[7] := s.h[7] xor v7 xor v15;
end;

{ n blocks from p, the last one final when last }
procedure Blocks(var s: TBlake2s; p: PByte; n: SizeInt; last: Boolean);
begin
{$ifndef SYLZ_PUREPASCAL}
  if Blake2sUseC then
  begin
    sylzc_blake2s_blocks(@s.h[0], p, n, @s.t, Ord(last));
    Exit;
  end;
{$endif}
  while n > 0 do
  begin
    Inc(s.t, 64);
    Compress(s, p, last and (n = 1));
    Inc(p, 64);
    Dec(n);
  end;
end;

procedure Blake2sInit(out s: TBlake2s);
begin
  s.h := IV;
  { parameter block: digest length 32, no key, fanout 1, depth 1 }
  s.h[0] := s.h[0] xor $01010000 xor BLAKE2S_OUTLEN;
  s.t := 0;
  s.bufLen := 0;
end;

procedure Blake2sUpdate(var s: TBlake2s; p: PByte; n: SizeInt);
var
  take: SizeInt;
begin
  { the last block is compressed by Final (with the flag), so a full
    buffer waits until more data comes }
  if n <= 0 then
    Exit;
  if s.bufLen > 0 then
  begin
    take := 64 - s.bufLen;
    if take > n then
      take := n;
    Move(p^, s.buf[s.bufLen], take);
    Inc(s.bufLen, take);
    Inc(p, take);
    Dec(n, take);
    if n = 0 then
      Exit;
    Blocks(s, @s.buf[0], 1, False);
    s.bufLen := 0;
  end;
  if n > 64 then
  begin
    take := (n - 1) div 64;   { whole blocks, at least one byte left }
    Blocks(s, p, take, False);
    Inc(p, 64 * take);
    Dec(n, 64 * take);
  end;
  Move(p^, s.buf[0], n);
  s.bufLen := n;
end;

procedure Blake2sFinal(var s: TBlake2s; out digest: TBlake2sDigest);
var
  i: Integer;
begin
  { the final block counts only its bytes: Blocks adds 64 }
  s.t := s.t + UInt64(s.bufLen) - 64;
  FillChar(s.buf[s.bufLen], 64 - s.bufLen, 0);
  Blocks(s, @s.buf[0], 1, True);
  for i := 0 to 7 do
    PUInt32(@digest[4 * i])^ := NtoLE(s.h[i]);
end;

procedure Blake2s256(p: PByte; n: SizeInt; out digest: TBlake2sDigest);
var
  s: TBlake2s;
begin
  Blake2sInit(s);
  Blake2sUpdate(s, p, n);
  Blake2sFinal(s, digest);
end;

procedure Blake2sMany(msg: PPByte; len: PSizeInt; count: SizeInt; digests: PByte);
var
  k: SizeInt;
begin
{$ifndef SYLZ_PUREPASCAL}
  if Blake2sUseC then
  begin
    sylzc_blake2s_many(msg, len, count, digests);
    Exit;
  end;
{$endif}
  for k := 0 to count - 1 do
    Blake2s256(msg[k], len[k], PBlake2sDigest(digests + k * BLAKE2S_OUTLEN)^);
end;

end.
