{ syccrypto — the primitives of syc's encryption (wiki: syc encryption):
  BLAKE2b and Argon2id (RFC 9106) for the password, XChaCha20-Poly1305
  (RFC 8439 + draft-irtf-cfrg-xchacha) for the data, the system's random
  numbers, and a constant-time comparison.

  Written from the RFCs; this Pascal is the reference. tests/syccrypto
  checks it against the RFCs' test vectors and, through
  tools/crypto_xcheck.py, against libsodium (PyNaCl), OpenSSL and
  Python's hashlib on random inputs. }
unit syccrypto;

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

uses
  {$ifdef windows}Windows,{$endif}
  {$ifdef unix}BaseUnix,{$endif}
  {$ifndef SYLZ_PUREPASCAL}sylz,{$endif}   { links sylzc.o }
  SysUtils;

type
  TKey32 = array[0..31] of Byte;
  TNonce24 = array[0..23] of Byte;
  TTag16 = array[0..15] of Byte;
  PNonce24 = ^TNonce24;
  PTag16 = ^TTag16;

{ BLAKE2b with an outLen of 1..64 bytes, unkeyed }
procedure Blake2b(outLen: Integer; p: PByte; n: SizeInt; dst: PByte);

{ Argon2id, version 1.3: tagLen bytes from the password, the salt, an
  optional secret and associated data, t passes over m KiB in p lanes.
  Raises EOutOfMemory when m KiB cannot be had. }
procedure Argon2id(pwd: PByte; pwdLen: SizeInt; salt: PByte; saltLen: SizeInt;
  secret: PByte; secretLen: SizeInt; ad: PByte; adLen: SizeInt;
  t, mKiB, p: UInt32; dst: PByte; tagLen: UInt32);

{ ChaCha20 (RFC 8439): data[0..n) xor the key stream from block counter,
  in place }
procedure ChaCha20Xor(const key: TKey32; const nonce12; counter: UInt32; data: PByte; n: SizeInt);
{ HChaCha20: a subkey from a key and 16 bytes of nonce }
procedure HChaCha20(const key: TKey32; const nonce16; out subkey: TKey32);
{ Poly1305 of msg with a one-time key }
procedure Poly1305(const key: TKey32; msg: PByte; n: SizeInt; out tag: TTag16);

{ XChaCha20-Poly1305: encrypts data[0..n) in place and gives its tag }
procedure XChaChaPolyEncrypt(const key: TKey32; const nonce: TNonce24; aad: PByte;
  aadLen: SizeInt; data: PByte; n: SizeInt; out tag: TTag16);
{ checks the tag, then decrypts in place; False (data untouched) when the
  tag does not match }
function XChaChaPolyDecrypt(const key: TKey32; const nonce: TNonce24; aad: PByte;
  aadLen: SizeInt; data: PByte; n: SizeInt; const tag: TTag16): Boolean;

{ n bytes from the system's cryptographic random source; raises when there
  is none }
procedure RandomBytes(p: PByte; n: SizeInt);
{ a = b over n bytes, in a time that does not depend on where they differ }
function SameBytes(a, b: PByte; n: SizeInt): Boolean;
{ overwrites n bytes with zeros (keys, passwords) in a way the compiler
  keeps }
procedure Wipe(p: Pointer; n: SizeInt);

var
  { the C paths of ChaCha20, Poly1305 and Argon2's block filling (when
    built in); False: the Pascal ones }
  CryptoUseC: Boolean = {$ifdef SYLZ_PUREPASCAL}False{$else}True{$endif};

implementation

{$ifndef SYLZ_PUREPASCAL}
procedure sylzc_chacha20_xor(key, nonce12: PByte; counter: UInt32; data: PByte; n: SizeInt);
  cdecl; external name 'sylzc_chacha20_xor';
procedure sylzc_poly1305_blocks(st: PUInt32; m: PByte; nblocks: SizeInt; hibit: UInt32);
  cdecl; external name 'sylzc_poly1305_blocks';
procedure sylzc_argon2_fill(prev, ref, next: Pointer; withXor: LongInt);
  cdecl; external name 'sylzc_argon2_fill';
{$endif}

{ ── BLAKE2b ──────────────────────────────────────────────────────────── }

const
  B2B_IV: array[0..7] of UInt64 = (
    UInt64($6A09E667F3BCC908), UInt64($BB67AE8584CAA73B),
    UInt64($3C6EF372FE94F82B), UInt64($A54FF53A5F1D36F1),
    UInt64($510E527FADE682D1), UInt64($9B05688C2B3E6C1F),
    UInt64($1F83D9ABFB41BD6B), UInt64($5BE0CD19137E2179));

  B2B_SIGMA: array[0..11, 0..15] of Byte = (
    ( 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15),
    (14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3),
    (11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4),
    ( 7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8),
    ( 9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13),
    ( 2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9),
    (12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11),
    (13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10),
    ( 6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5),
    (10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0),
    ( 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15),
    (14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3));

type
  TBlake2b = record
    h: array[0..7] of UInt64;
    t: UInt64;          { bytes so far (messages here are far below 2^64) }
    buf: array[0..127] of Byte;
    bufLen: Integer;
    outLen: Integer;
  end;

procedure B2bCompress(var s: TBlake2b; block: PByte; last: Boolean);
var
  m, v: array[0..15] of UInt64;
  i, r: Integer;

  procedure G(a, b, c, d: Integer; x, y: UInt64); inline;
  begin
    v[a] := v[a] + v[b] + x;  v[d] := RorQWord(v[d] xor v[a], 32);
    v[c] := v[c] + v[d];      v[b] := RorQWord(v[b] xor v[c], 24);
    v[a] := v[a] + v[b] + y;  v[d] := RorQWord(v[d] xor v[a], 16);
    v[c] := v[c] + v[d];      v[b] := RorQWord(v[b] xor v[c], 63);
  end;

begin
  for i := 0 to 15 do
    m[i] := LEtoN(PUInt64(block + 8 * i)^);
  for i := 0 to 7 do
  begin
    v[i] := s.h[i];
    v[i + 8] := B2B_IV[i];
  end;
  v[12] := v[12] xor s.t;     { the high half of the 128-bit counter stays 0 }
  if last then
    v[14] := not v[14];
  for r := 0 to 11 do
  begin
    G(0, 4,  8, 12, m[B2B_SIGMA[r, 0]],  m[B2B_SIGMA[r, 1]]);
    G(1, 5,  9, 13, m[B2B_SIGMA[r, 2]],  m[B2B_SIGMA[r, 3]]);
    G(2, 6, 10, 14, m[B2B_SIGMA[r, 4]],  m[B2B_SIGMA[r, 5]]);
    G(3, 7, 11, 15, m[B2B_SIGMA[r, 6]],  m[B2B_SIGMA[r, 7]]);
    G(0, 5, 10, 15, m[B2B_SIGMA[r, 8]],  m[B2B_SIGMA[r, 9]]);
    G(1, 6, 11, 12, m[B2B_SIGMA[r, 10]], m[B2B_SIGMA[r, 11]]);
    G(2, 7,  8, 13, m[B2B_SIGMA[r, 12]], m[B2B_SIGMA[r, 13]]);
    G(3, 4,  9, 14, m[B2B_SIGMA[r, 14]], m[B2B_SIGMA[r, 15]]);
  end;
  for i := 0 to 7 do
    s.h[i] := s.h[i] xor v[i] xor v[i + 8];
end;

procedure B2bInit(out s: TBlake2b; outLen: Integer);
begin
  s.h := B2B_IV;
  s.h[0] := s.h[0] xor $01010000 xor UInt64(outLen);
  s.t := 0;
  s.bufLen := 0;
  s.outLen := outLen;
end;

procedure B2bUpdate(var s: TBlake2b; p: PByte; n: SizeInt);
var
  take: SizeInt;
begin
  while n > 0 do
  begin
    { a full buffer waits for more data: the last block is Final's }
    if s.bufLen = 128 then
    begin
      Inc(s.t, 128);
      B2bCompress(s, @s.buf[0], False);
      s.bufLen := 0;
    end;
    take := 128 - s.bufLen;
    if take > n then
      take := n;
    Move(p^, s.buf[s.bufLen], take);
    Inc(s.bufLen, take);
    Inc(p, take);
    Dec(n, take);
  end;
end;

procedure B2bFinal(var s: TBlake2b; dst: PByte);
var
  full: array[0..63] of Byte;
  i: Integer;
begin
  Inc(s.t, s.bufLen);
  FillChar(s.buf[s.bufLen], 128 - s.bufLen, 0);
  B2bCompress(s, @s.buf[0], True);
  for i := 0 to 7 do
    PUInt64(@full[8 * i])^ := NtoLE(s.h[i]);
  Move(full, dst^, s.outLen);
  Wipe(@s, SizeOf(s));
end;

procedure Blake2b(outLen: Integer; p: PByte; n: SizeInt; dst: PByte);
var
  s: TBlake2b;
begin
  B2bInit(s, outLen);
  B2bUpdate(s, p, n);
  B2bFinal(s, dst);
end;

{ ── Argon2id ─────────────────────────────────────────────────────────── }

const
  ARGON2_BLOCK = 1024;
  ARGON2_QWORDS = ARGON2_BLOCK div 8;
  ARGON2_VERSION = $13;
  ARGON2_ID = 2;
  ARGON2_SYNC_POINTS = 4;

type
  TArgonBlock = array[0..ARGON2_QWORDS - 1] of UInt64;
  PArgonBlock = ^TArgonBlock;

procedure PutU32(var s: TBlake2b; v: UInt32);
begin
  v := NtoLE(v);
  B2bUpdate(s, @v, 4);
end;

{ H' (RFC 9106, 3.3): outLen bytes from the input's BLAKE2b chain }
procedure HPrime(outLen: UInt32; p: PByte; n: SizeInt; dst: PByte);
var
  s: TBlake2b;
  v: array[0..63] of Byte;
  left: UInt32;
begin
  if outLen <= 64 then
  begin
    B2bInit(s, outLen);
    PutU32(s, outLen);
    B2bUpdate(s, p, n);
    B2bFinal(s, dst);
    Exit;
  end;
  B2bInit(s, 64);
  PutU32(s, outLen);
  B2bUpdate(s, p, n);
  B2bFinal(s, @v[0]);
  Move(v, dst^, 32);
  Inc(dst, 32);
  left := outLen - 32;
  while left > 64 do
  begin
    Blake2b(64, @v[0], 64, @v[0]);
    Move(v, dst^, 32);
    Inc(dst, 32);
    Dec(left, 32);
  end;
  Blake2b(left, @v[0], 64, dst);
  Wipe(@v, SizeOf(v));
end;

{ the permutation P's mixing: BLAKE2b's G with the multiplications }
procedure GB(var a, b, c, d: UInt64); inline;
begin
  a := a + b + 2 * UInt64(UInt32(a)) * UInt64(UInt32(b));
  d := RorQWord(d xor a, 32);
  c := c + d + 2 * UInt64(UInt32(c)) * UInt64(UInt32(d));
  b := RorQWord(b xor c, 24);
  a := a + b + 2 * UInt64(UInt32(a)) * UInt64(UInt32(b));
  d := RorQWord(d xor a, 16);
  c := c + d + 2 * UInt64(UInt32(c)) * UInt64(UInt32(d));
  b := RorQWord(b xor c, 63);
end;

procedure RoundP(var v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15: UInt64); inline;
begin
  GB(v0, v4, v8, v12);
  GB(v1, v5, v9, v13);
  GB(v2, v6, v10, v14);
  GB(v3, v7, v11, v15);
  GB(v0, v5, v10, v15);
  GB(v1, v6, v11, v12);
  GB(v2, v7, v8, v13);
  GB(v3, v4, v9, v14);
end;

{ next := G(prev, ref) (xor next when withXor: passes after the first) }
procedure FillBlock(prev, ref, next: PArgonBlock; withXor: Boolean);
var
  r, tmp: TArgonBlock;
  i: Integer;
begin
{$ifndef SYLZ_PUREPASCAL}
  if CryptoUseC then
  begin
    sylzc_argon2_fill(prev, ref, next, Ord(withXor));
    Exit;
  end;
{$endif}
  for i := 0 to ARGON2_QWORDS - 1 do
    r[i] := prev^[i] xor ref^[i];
  tmp := r;
  if withXor then
    for i := 0 to ARGON2_QWORDS - 1 do
      tmp[i] := tmp[i] xor next^[i];
  { rows: 8 groups of 16 consecutive words }
  for i := 0 to 7 do
    RoundP(r[16 * i], r[16 * i + 1], r[16 * i + 2], r[16 * i + 3],
      r[16 * i + 4], r[16 * i + 5], r[16 * i + 6], r[16 * i + 7],
      r[16 * i + 8], r[16 * i + 9], r[16 * i + 10], r[16 * i + 11],
      r[16 * i + 12], r[16 * i + 13], r[16 * i + 14], r[16 * i + 15]);
  { columns: pairs of words, one pair from each row }
  for i := 0 to 7 do
    RoundP(r[2 * i], r[2 * i + 1], r[2 * i + 16], r[2 * i + 17],
      r[2 * i + 32], r[2 * i + 33], r[2 * i + 48], r[2 * i + 49],
      r[2 * i + 64], r[2 * i + 65], r[2 * i + 80], r[2 * i + 81],
      r[2 * i + 96], r[2 * i + 97], r[2 * i + 112], r[2 * i + 113]);
  for i := 0 to ARGON2_QWORDS - 1 do
    next^[i] := tmp[i] xor r[i];
end;

procedure Argon2id(pwd: PByte; pwdLen: SizeInt; salt: PByte; saltLen: SizeInt;
  secret: PByte; secretLen: SizeInt; ad: PByte; adLen: SizeInt;
  t, mKiB, p: UInt32; dst: PByte; tagLen: UInt32);
var
  s: TBlake2b;
  h0: array[0..71] of Byte;   { H0, then two u32 for the first blocks }
  mem: array of TArgonBlock;
  blockBytes: array[0..ARGON2_BLOCK - 1] of Byte;
  mBlocks, q, segLen: UInt32;
  pass, slice, lane, idx: UInt32;
  i, j: Integer;
  zero, input, address: TArgonBlock;
  dataIndependent: Boolean;
  curr, prev, refLane, refIndex, startIdx: UInt32;
  pseudo, refArea, rel, startPos: UInt64;
  final: TArgonBlock;
begin
  { H0 }
  B2bInit(s, 64);
  PutU32(s, p);
  PutU32(s, tagLen);
  PutU32(s, mKiB);
  PutU32(s, t);
  PutU32(s, ARGON2_VERSION);
  PutU32(s, ARGON2_ID);
  PutU32(s, pwdLen);
  B2bUpdate(s, pwd, pwdLen);
  PutU32(s, saltLen);
  B2bUpdate(s, salt, saltLen);
  PutU32(s, secretLen);
  B2bUpdate(s, secret, secretLen);
  PutU32(s, adLen);
  B2bUpdate(s, ad, adLen);
  B2bFinal(s, @h0[0]);

  mBlocks := 4 * p * (mKiB div (4 * p));
  q := mBlocks div p;
  segLen := q div ARGON2_SYNC_POINTS;
  SetLength(mem, mBlocks);

  { the first two blocks of each lane }
  for lane := 0 to p - 1 do
    for i := 0 to 1 do
    begin
      PUInt32(@h0[64])^ := NtoLE(UInt32(i));
      PUInt32(@h0[68])^ := NtoLE(lane);
      HPrime(ARGON2_BLOCK, @h0[0], 72, @blockBytes[0]);
      for j := 0 to ARGON2_QWORDS - 1 do
        mem[lane * q + UInt32(i)][j] := LEtoN(PUInt64(@blockBytes[8 * j])^);
    end;

  FillChar(zero, SizeOf(zero), 0);
  FillChar(address, SizeOf(address), 0);
  for pass := 0 to t - 1 do
    for slice := 0 to ARGON2_SYNC_POINTS - 1 do
      for lane := 0 to p - 1 do
      begin
        dataIndependent := (pass = 0) and (slice < ARGON2_SYNC_POINTS div 2);
        FillChar(input, SizeOf(input), 0);
        if dataIndependent then
        begin
          input[0] := pass;
          input[1] := lane;
          input[2] := slice;
          input[3] := mBlocks;
          input[4] := t;
          input[5] := ARGON2_ID;
        end;
        startIdx := 0;
        if (pass = 0) and (slice = 0) then
        begin
          startIdx := 2;
          if dataIndependent then
          begin
            Inc(input[6]);
            FillBlock(@zero, @input, @address, False);
            FillBlock(@zero, @address, @address, False);
          end;
        end;
        for idx := startIdx to segLen - 1 do
        begin
          curr := lane * q + slice * segLen + idx;
          if curr mod q = 0 then
            prev := curr + q - 1
          else
            prev := curr - 1;
          if dataIndependent then
          begin
            if idx mod ARGON2_QWORDS = 0 then
            begin
              Inc(input[6]);
              FillBlock(@zero, @input, @address, False);
              FillBlock(@zero, @address, @address, False);
            end;
            pseudo := address[idx mod ARGON2_QWORDS];
          end
          else
            pseudo := mem[prev][0];
          { the reference block's lane and position }
          refLane := (pseudo shr 32) mod p;
          if (pass = 0) and (slice = 0) then
            refLane := lane;
          if pass = 0 then
          begin
            if slice = 0 then
              refArea := idx - 1
            else if refLane = lane then
              refArea := UInt64(slice) * segLen + idx - 1
            else if idx = 0 then
              refArea := UInt64(slice) * segLen - 1
            else
              refArea := UInt64(slice) * segLen;
          end
          else
          begin
            if refLane = lane then
              refArea := q - segLen + idx - 1
            else if idx = 0 then
              refArea := q - segLen - 1
            else
              refArea := q - segLen;
          end;
          rel := pseudo and $FFFFFFFF;
          rel := (rel * rel) shr 32;
          rel := refArea - 1 - ((refArea * rel) shr 32);
          if (pass = 0) or (slice = ARGON2_SYNC_POINTS - 1) then
            startPos := 0
          else
            startPos := UInt64(slice + 1) * segLen;
          refIndex := (startPos + rel) mod q;
          FillBlock(@mem[prev], @mem[refLane * q + refIndex], @mem[curr], pass > 0);
        end;
      end;

  { the last column, xored, then H' }
  final := mem[q - 1];
  for lane := 1 to p - 1 do
    for j := 0 to ARGON2_QWORDS - 1 do
      final[j] := final[j] xor mem[lane * q + q - 1][j];
  for j := 0 to ARGON2_QWORDS - 1 do
    PUInt64(@blockBytes[8 * j])^ := NtoLE(final[j]);
  HPrime(tagLen, @blockBytes[0], ARGON2_BLOCK, dst);
  Wipe(@blockBytes, SizeOf(blockBytes));
  Wipe(@final, SizeOf(final));
  Wipe(@h0, SizeOf(h0));
  if Length(mem) > 0 then
    Wipe(@mem[0], Length(mem) * SizeOf(TArgonBlock));
end;

{ ── ChaCha20, HChaCha20 ──────────────────────────────────────────────── }

type
  TChaState = array[0..15] of UInt32;

procedure QR(var a, b, c, d: UInt32); inline;
begin
  a := a + b; d := RolDWord(d xor a, 16);
  c := c + d; b := RolDWord(b xor c, 12);
  a := a + b; d := RolDWord(d xor a, 8);
  c := c + d; b := RolDWord(b xor c, 7);
end;

procedure ChaRounds(var x: TChaState);
var
  i: Integer;
begin
  for i := 1 to 10 do
  begin
    QR(x[0], x[4], x[8], x[12]);
    QR(x[1], x[5], x[9], x[13]);
    QR(x[2], x[6], x[10], x[14]);
    QR(x[3], x[7], x[11], x[15]);
    QR(x[0], x[5], x[10], x[15]);
    QR(x[1], x[6], x[11], x[12]);
    QR(x[2], x[7], x[8], x[13]);
    QR(x[3], x[4], x[9], x[14]);
  end;
end;

procedure ChaSetup(out st: TChaState; const key: TKey32; w12, w13, w14, w15: UInt32);
var
  i: Integer;
begin
  st[0] := $61707865;   { "expand 32-byte k" }
  st[1] := $3320646E;
  st[2] := $79622D32;
  st[3] := $6B206574;
  for i := 0 to 7 do
    st[4 + i] := LEtoN(PUInt32(@key[4 * i])^);
  st[12] := w12;
  st[13] := w13;
  st[14] := w14;
  st[15] := w15;
end;

procedure ChaCha20Xor(const key: TKey32; const nonce12; counter: UInt32; data: PByte; n: SizeInt);
var
  st, x: TChaState;
  ks: array[0..63] of Byte;
  i, take: Integer;
  nw: PUInt32;
begin
{$ifndef SYLZ_PUREPASCAL}
  if CryptoUseC then
  begin
    sylzc_chacha20_xor(@key[0], @nonce12, counter, data, n);
    Exit;
  end;
{$endif}
  nw := @nonce12;
  ChaSetup(st, key, counter, LEtoN(nw[0]), LEtoN(nw[1]), LEtoN(nw[2]));
  while n > 0 do
  begin
    x := st;
    ChaRounds(x);
    for i := 0 to 15 do
      PUInt32(@ks[4 * i])^ := NtoLE(x[i] + st[i]);
    take := 64;
    if take > n then
      take := n;
    for i := 0 to take - 1 do
      data[i] := data[i] xor ks[i];
    Inc(data, take);
    Dec(n, take);
    st[12] := st[12] + 1;
  end;
  Wipe(@ks, SizeOf(ks));
  Wipe(@st, SizeOf(st));
  Wipe(@x, SizeOf(x));
end;

procedure HChaCha20(const key: TKey32; const nonce16; out subkey: TKey32);
var
  x: TChaState;
  nw: PUInt32;
  i: Integer;
begin
  nw := @nonce16;
  ChaSetup(x, key, LEtoN(nw[0]), LEtoN(nw[1]), LEtoN(nw[2]), LEtoN(nw[3]));
  ChaRounds(x);
  for i := 0 to 3 do
  begin
    PUInt32(@subkey[4 * i])^ := NtoLE(x[i]);
    PUInt32(@subkey[16 + 4 * i])^ := NtoLE(x[12 + i]);
  end;
  Wipe(@x, SizeOf(x));
end;

{ ── Poly1305 (five 26-bit limbs, 64-bit products) ───────────────────── }

type
  TPoly = record
    r, h, pad: array[0..4] of UInt32;
    buf: array[0..15] of Byte;
    bufLen: Integer;
  end;

procedure PolyInit(out st: TPoly; const key: TKey32);
var
  t0, t1, t2, t3: UInt32;
begin
  t0 := LEtoN(PUInt32(@key[0])^);
  t1 := LEtoN(PUInt32(@key[4])^);
  t2 := LEtoN(PUInt32(@key[8])^);
  t3 := LEtoN(PUInt32(@key[12])^);
  { r clamped, in 26-bit limbs }
  st.r[0] := t0 and $3FFFFFF;
  st.r[1] := ((t0 shr 26) or (t1 shl 6)) and $3FFFF03;
  st.r[2] := ((t1 shr 20) or (t2 shl 12)) and $3FFC0FF;
  st.r[3] := ((t2 shr 14) or (t3 shl 18)) and $3F03FFF;
  st.r[4] := (t3 shr 8) and $00FFFFF;
  FillChar(st.h, SizeOf(st.h), 0);
  st.pad[0] := LEtoN(PUInt32(@key[16])^);
  st.pad[1] := LEtoN(PUInt32(@key[20])^);
  st.pad[2] := LEtoN(PUInt32(@key[24])^);
  st.pad[3] := LEtoN(PUInt32(@key[28])^);
  st.bufLen := 0;
end;

procedure PolyBlockPas(var st: TPoly; m: PByte; hibit: UInt32); forward;

{ h := (h + block + hibit) * r mod 2^130 - 5, for n whole blocks }
procedure PolyBlocks(var st: TPoly; m: PByte; n: SizeInt; hibit: UInt32);
begin
{$ifndef SYLZ_PUREPASCAL}
  { st.r, st.h: the C function's 10 words, in this order }
  if CryptoUseC then
  begin
    sylzc_poly1305_blocks(@st.r[0], m, n, hibit);
    Exit;
  end;
{$endif}
  while n > 0 do
  begin
    PolyBlockPas(st, m, hibit);
    Inc(m, 16);
    Dec(n);
  end;
end;

procedure PolyBlockPas(var st: TPoly; m: PByte; hibit: UInt32);
var
  r0, r1, r2, r3, r4, s1, s2, s3, s4: UInt64;
  h0, h1, h2, h3, h4: UInt64;
  d0, d1, d2, d3, d4: UInt64;
  t0, t1, t2, t3: UInt32;
  c: UInt64;
begin
  r0 := st.r[0]; r1 := st.r[1]; r2 := st.r[2]; r3 := st.r[3]; r4 := st.r[4];
  s1 := r1 * 5; s2 := r2 * 5; s3 := r3 * 5; s4 := r4 * 5;
  t0 := LEtoN(PUInt32(m)^);
  t1 := LEtoN(PUInt32(m + 4)^);
  t2 := LEtoN(PUInt32(m + 8)^);
  t3 := LEtoN(PUInt32(m + 12)^);
  h0 := st.h[0] + (t0 and $3FFFFFF);
  h1 := st.h[1] + (((t0 shr 26) or (t1 shl 6)) and $3FFFFFF);
  h2 := st.h[2] + (((t1 shr 20) or (t2 shl 12)) and $3FFFFFF);
  h3 := st.h[3] + (((t2 shr 14) or (t3 shl 18)) and $3FFFFFF);
  h4 := st.h[4] + ((t3 shr 8) or hibit);
  d0 := h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
  d1 := h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
  d2 := h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
  d3 := h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
  d4 := h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
  c := d0 shr 26; h0 := d0 and $3FFFFFF;
  d1 := d1 + c; c := d1 shr 26; h1 := d1 and $3FFFFFF;
  d2 := d2 + c; c := d2 shr 26; h2 := d2 and $3FFFFFF;
  d3 := d3 + c; c := d3 shr 26; h3 := d3 and $3FFFFFF;
  d4 := d4 + c; c := d4 shr 26; h4 := d4 and $3FFFFFF;
  h0 := h0 + c * 5; c := h0 shr 26; h0 := h0 and $3FFFFFF;
  h1 := h1 + c;
  st.h[0] := h0; st.h[1] := h1; st.h[2] := h2; st.h[3] := h3; st.h[4] := h4;
end;

procedure PolyUpdate(var st: TPoly; p: PByte; n: SizeInt);
var
  take: SizeInt;
begin
  if st.bufLen > 0 then
  begin
    take := 16 - st.bufLen;
    if take > n then
      take := n;
    Move(p^, st.buf[st.bufLen], take);
    Inc(st.bufLen, take);
    Inc(p, take);
    Dec(n, take);
    if st.bufLen < 16 then
      Exit;
    PolyBlocks(st, @st.buf[0], 1, 1 shl 24);
    st.bufLen := 0;
  end;
  if n >= 16 then
  begin
    PolyBlocks(st, p, n div 16, 1 shl 24);
    Inc(p, n and not SizeInt(15));
    n := n and 15;
  end;
  if n > 0 then
  begin
    Move(p^, st.buf[0], n);
    st.bufLen := n;
  end;
end;

procedure PolyFinish(var st: TPoly; out tag: TTag16);
var
  h0, h1, h2, h3, h4, c: UInt32;
  g0, g1, g2, g3, g4, mask: UInt32;
  f: UInt64;
begin
  if st.bufLen > 0 then
  begin
    { the last partial block: a 1 byte after it, no 2^128 bit }
    st.buf[st.bufLen] := 1;
    FillChar(st.buf[st.bufLen + 1], 15 - st.bufLen, 0);
    PolyBlocks(st, @st.buf[0], 1, 0);
  end;
  h0 := st.h[0]; h1 := st.h[1]; h2 := st.h[2]; h3 := st.h[3]; h4 := st.h[4];
  { full carry }
  c := h1 shr 26; h1 := h1 and $3FFFFFF;
  h2 := h2 + c; c := h2 shr 26; h2 := h2 and $3FFFFFF;
  h3 := h3 + c; c := h3 shr 26; h3 := h3 and $3FFFFFF;
  h4 := h4 + c; c := h4 shr 26; h4 := h4 and $3FFFFFF;
  h0 := h0 + c * 5; c := h0 shr 26; h0 := h0 and $3FFFFFF;
  h1 := h1 + c;
  { h - p, chosen without a branch }
  g0 := h0 + 5; c := g0 shr 26; g0 := g0 and $3FFFFFF;
  g1 := h1 + c; c := g1 shr 26; g1 := g1 and $3FFFFFF;
  g2 := h2 + c; c := g2 shr 26; g2 := g2 and $3FFFFFF;
  g3 := h3 + c; c := g3 shr 26; g3 := g3 and $3FFFFFF;
  g4 := h4 + c - (1 shl 26);
  mask := (g4 shr 31) - 1;   { all ones when h >= p }
  g0 := g0 and mask; g1 := g1 and mask; g2 := g2 and mask; g3 := g3 and mask; g4 := g4 and mask;
  mask := not mask;
  h0 := (h0 and mask) or g0;
  h1 := (h1 and mask) or g1;
  h2 := (h2 and mask) or g2;
  h3 := (h3 and mask) or g3;
  h4 := (h4 and mask) or g4;
  { to 4 x 32 bits, then + pad mod 2^128 }
  h0 := (h0 or (h1 shl 26));
  h1 := ((h1 shr 6) or (h2 shl 20));
  h2 := ((h2 shr 12) or (h3 shl 14));
  h3 := ((h3 shr 18) or (h4 shl 8));
  f := UInt64(h0) + st.pad[0]; h0 := UInt32(f);
  f := UInt64(h1) + st.pad[1] + (f shr 32); h1 := UInt32(f);
  f := UInt64(h2) + st.pad[2] + (f shr 32); h2 := UInt32(f);
  f := UInt64(h3) + st.pad[3] + (f shr 32); h3 := UInt32(f);
  PUInt32(@tag[0])^ := NtoLE(h0);
  PUInt32(@tag[4])^ := NtoLE(h1);
  PUInt32(@tag[8])^ := NtoLE(h2);
  PUInt32(@tag[12])^ := NtoLE(h3);
  Wipe(@st, SizeOf(st));
end;

procedure Poly1305(const key: TKey32; msg: PByte; n: SizeInt; out tag: TTag16);
var
  st: TPoly;
begin
  PolyInit(st, key);
  PolyUpdate(st, msg, n);
  PolyFinish(st, tag);
end;

{ ── XChaCha20-Poly1305 ───────────────────────────────────────────────── }

const
  ZERO16: array[0..15] of Byte = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

{ the subkey and 12-byte nonce of ChaCha20-Poly1305 for a 24-byte nonce }
procedure XSetup(const key: TKey32; const nonce: TNonce24; out sub: TKey32; out n12: array of Byte);
begin
  HChaCha20(key, nonce[0], sub);
  FillChar(n12[0], 4, 0);
  Move(nonce[16], n12[4], 8);
end;

procedure AeadTag(const sub: TKey32; const n12: array of Byte; aad: PByte; aadLen: SizeInt;
  ct: PByte; n: SizeInt; out tag: TTag16);
var
  polyKey: TKey32;
  st: TPoly;
  lens: array[0..1] of UInt64;
begin
  FillChar(polyKey, SizeOf(polyKey), 0);
  ChaCha20Xor(sub, n12[0], 0, @polyKey[0], 32);
  PolyInit(st, polyKey);
  PolyUpdate(st, aad, aadLen);
  PolyUpdate(st, @ZERO16[0], (16 - aadLen mod 16) mod 16);
  PolyUpdate(st, ct, n);
  PolyUpdate(st, @ZERO16[0], (16 - n mod 16) mod 16);
  lens[0] := NtoLE(UInt64(aadLen));
  lens[1] := NtoLE(UInt64(n));
  PolyUpdate(st, @lens[0], 16);
  PolyFinish(st, tag);
  Wipe(@polyKey, SizeOf(polyKey));
end;

procedure XChaChaPolyEncrypt(const key: TKey32; const nonce: TNonce24; aad: PByte;
  aadLen: SizeInt; data: PByte; n: SizeInt; out tag: TTag16);
var
  sub: TKey32;
  n12: array[0..11] of Byte;
begin
  XSetup(key, nonce, sub, n12);
  ChaCha20Xor(sub, n12[0], 1, data, n);
  AeadTag(sub, n12, aad, aadLen, data, n, tag);
  Wipe(@sub, SizeOf(sub));
end;

function XChaChaPolyDecrypt(const key: TKey32; const nonce: TNonce24; aad: PByte;
  aadLen: SizeInt; data: PByte; n: SizeInt; const tag: TTag16): Boolean;
var
  sub: TKey32;
  n12: array[0..11] of Byte;
  want: TTag16;
begin
  XSetup(key, nonce, sub, n12);
  AeadTag(sub, n12, aad, aadLen, data, n, want);
  Result := SameBytes(@want[0], @tag[0], 16);
  if Result then
    ChaCha20Xor(sub, n12[0], 1, data, n);
  Wipe(@sub, SizeOf(sub));
end;

{ ── randomness, comparison, wiping ───────────────────────────────────── }

{$ifdef darwin}
function getentropy(buf: Pointer; buflen: SizeUInt): LongInt;
  cdecl; external 'c' name 'getentropy';

procedure RandomBytes(p: PByte; n: SizeInt);
var
  k: SizeInt;
begin
  while n > 0 do
  begin
    k := n;
    if k > 256 then   { getentropy's limit per call }
      k := 256;
    if getentropy(p, k) <> 0 then
      raise Exception.Create('no random numbers from the system (getentropy)');
    Inc(p, k);
    Dec(n, k);
  end;
end;
{$else}{$ifdef unix}
function getrandom(buf: Pointer; buflen: SizeUInt; flags: LongWord): PtrInt;
  cdecl; external 'c' name 'getrandom';

procedure RandomBytes(p: PByte; n: SizeInt);
var
  got: PtrInt;
begin
  while n > 0 do
  begin
    got := getrandom(p, n, 0);
    if got <= 0 then
    begin
      if fpGetErrno = ESysEINTR then
        Continue;
      raise Exception.Create('no random numbers from the system (getrandom)');
    end;
    Inc(p, got);
    Dec(n, got);
  end;
end;
{$else}
function BCryptGenRandom(alg: Pointer; buf: PByte; len: ULONG; flags: ULONG): LONG;
  stdcall; external 'bcrypt.dll' name 'BCryptGenRandom';

const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2;

procedure RandomBytes(p: PByte; n: SizeInt);
var
  take: SizeInt;
begin
  while n > 0 do
  begin
    take := n;
    if take > $10000000 then
      take := $10000000;
    if BCryptGenRandom(nil, p, take, BCRYPT_USE_SYSTEM_PREFERRED_RNG) <> 0 then
      raise Exception.Create('no random numbers from the system (BCryptGenRandom)');
    Inc(p, take);
    Dec(n, take);
  end;
end;
{$endif}{$endif}

function SameBytes(a, b: PByte; n: SizeInt): Boolean;
var
  d: Byte;
  i: SizeInt;
begin
  d := 0;
  for i := 0 to n - 1 do
    d := d or (a[i] xor b[i]);
  Result := d = 0;
end;

procedure Wipe(p: Pointer; n: SizeInt);
begin
  { FillChar is a real call FPC does not drop, even on memory that is
    dead after it (a byte loop here took 0.3 s for Argon2's 64 MiB) }
  if n > 0 then
    FillChar(p^, n, 0);
  ReadWriteBarrier;
end;

end.
