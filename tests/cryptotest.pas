{ cryptotest — tests of src/syccrypto.pas: the RFCs' test vectors, and
  random cases for tools/crypto_xcheck.py to recompute with libsodium
  (PyNaCl), OpenSSL and hashlib.

  Usage: cryptotest           the test vectors, speed
         cryptotest --dump N  N random cases per primitive, one a line:
                              KIND inputs... output, in hex }
program cryptotest;

{$mode objfpc}{$H+}

uses
  SysUtils, blake2s, syccrypto;

var
  failures: Integer = 0;
  seed: UInt32 = 77;

function Rnd: UInt32;
begin
  seed := seed xor (seed shl 13);
  seed := seed xor (seed shr 17);
  seed := seed xor (seed shl 5);
  Result := seed;
end;

function FromHex(const s: string): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Length(s) div 2);
  for i := 0 to High(Result) do
    Result[i] := StrToInt('$' + Copy(s, 2 * i + 1, 2));
end;

function ToHex(p: PByte; n: SizeInt): string;
var
  i: SizeInt;
begin
  Result := '';
  for i := 0 to n - 1 do
    Result := Result + LowerCase(IntToHex(p[i], 2));
end;

function HexOf(const b: TBytes): string;
begin
  if Length(b) = 0 then
    Result := '-'
  else
    Result := ToHex(@b[0], Length(b));
end;

function PtrOf(const b: TBytes): PByte;
begin
  if Length(b) = 0 then
    Result := nil
  else
    Result := @b[0];
end;

procedure Check(ok: Boolean; const what: string);
begin
  if ok then
    WriteLn('ok    ', what)
  else
  begin
    WriteLn('FAIL  ', what);
    Inc(failures);
  end;
end;

function RandomData(n: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, n);
  for i := 0 to n - 1 do
    Result[i] := Byte(Rnd);
end;

procedure Vectors;
const
  LADIES = '4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e';
var
  out: array[0..63] of Byte;
  key: TKey32;
  b, n12, aad: TBytes;
  sub: TKey32;
  nonce: TNonce24;
  tag: TTag16;
  i: Integer;
  pwd, salt, secret, ad: TBytes;
  abc: string;
begin
  { RFC 7693, appendix A }
  abc := 'abc';
  Blake2b(64, @abc[1], 3, @out[0]);
  Check(ToHex(@out[0], 64) = 'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
    'BLAKE2b-512("abc"), RFC 7693 A');

  for i := 0 to 31 do
    key[i] := i;
  { RFC 8439 2.3.2: the block function, as the key stream of block 1 }
  SetLength(b, 64);
  FillChar(b[0], 64, 0);
  n12 := FromHex('000000090000004a00000000');
  ChaCha20Xor(key, n12[0], 1, @b[0], 64);
  Check(HexOf(b) = '10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e',
    'ChaCha20 block, RFC 8439 2.3.2');
  { 2.4.2 }
  b := FromHex(LADIES);
  n12 := FromHex('000000000000004a00000000');
  ChaCha20Xor(key, n12[0], 1, @b[0], Length(b));
  Check(HexOf(b) = '6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d',
    'ChaCha20 encryption, RFC 8439 2.4.2');
  { 2.5.2 }
  b := FromHex('85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b');
  Move(b[0], sub, 32);
  abc := 'Cryptographic Forum Research Group';
  Poly1305(sub, @abc[1], Length(abc), tag);
  Check(ToHex(@tag[0], 16) = 'a8061dc1305136c6c22b8baf0c0127a9', 'Poly1305, RFC 8439 2.5.2');
  { draft-irtf-cfrg-xchacha 2.2.1 }
  b := FromHex('000000090000004a0000000031415927');
  HChaCha20(key, b[0], sub);
  Check(ToHex(@sub[0], 32) = '82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc',
    'HChaCha20, xchacha draft 2.2.1');
  { draft A.3.1 }
  b := FromHex('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
  Move(b[0], key, 32);
  b := FromHex('404142434445464748494a4b4c4d4e4f5051525354555657');
  Move(b[0], nonce, 24);
  aad := FromHex('50515253c0c1c2c3c4c5c6c7');
  b := FromHex(LADIES);
  XChaChaPolyEncrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag);
  Check((HexOf(b) = 'bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e')
    and (ToHex(@tag[0], 16) = 'c0875924c1c7987947deafd8780acf49'), 'XChaCha20-Poly1305, xchacha draft A.3.1');
  Check(XChaChaPolyDecrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag)
    and (HexOf(b) = LADIES), 'XChaCha20-Poly1305 decrypts it back');
  XChaChaPolyEncrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag);
  b[5] := b[5] xor 1;
  Check(not XChaChaPolyDecrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag),
    'XChaCha20-Poly1305 refuses a changed byte');
  b[5] := b[5] xor 1;
  aad[0] := aad[0] xor 1;
  Check(not XChaChaPolyDecrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag),
    'XChaCha20-Poly1305 refuses a changed AAD');
  { RFC 9106 5.3 }
  SetLength(pwd, 32);
  FillChar(pwd[0], 32, 1);
  SetLength(salt, 16);
  FillChar(salt[0], 16, 2);
  SetLength(secret, 8);
  FillChar(secret[0], 8, 3);
  SetLength(ad, 12);
  FillChar(ad[0], 12, 4);
  Argon2id(@pwd[0], 32, @salt[0], 16, @secret[0], 8, @ad[0], 12, 3, 32, 4, @out[0], 32);
  Check(ToHex(@out[0], 32) = '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
    'Argon2id, RFC 9106 5.3');
  { the system's random numbers: two draws differ, and are not all zero }
  SetLength(b, 64);
  SetLength(aad, 64);
  RandomBytes(@b[0], 64);
  RandomBytes(@aad[0], 64);
  FillChar(out, SizeOf(out), 0);
  Check((CompareByte(b[0], aad[0], 64) <> 0) and (CompareByte(b[0], out[0], 64) <> 0),
    'RandomBytes gives different, non-zero draws');
end;

procedure Speed;
var
  data: TBytes;
  key: TKey32;
  nonce: TNonce24;
  tag: TTag16;
  out: array[0..31] of Byte;
  t0, ms: QWord;
  pw: string;
begin
  SetLength(data, 64 shl 20);
  FillChar(key, SizeOf(key), 7);
  FillChar(nonce, SizeOf(nonce), 9);
  t0 := GetTickCount64;
  XChaChaPolyEncrypt(key, nonce, nil, 0, @data[0], Length(data), tag);
  ms := GetTickCount64 - t0;
  WriteLn(Format('XChaCha20-Poly1305: %.0f MB/s', [Length(data) / 1e6 / (ms + 1) * 1000]));
  pw := 'correct horse battery staple';
  t0 := GetTickCount64;
  Argon2id(@pw[1], Length(pw), @key[0], 16, nil, 0, nil, 0, 3, 65536, 1, @out[0], 32);
  ms := GetTickCount64 - t0;
  WriteLn(Format('Argon2id m=64 MiB t=3 p=1: %d ms', [ms]));
end;

{ random cases for tools/crypto_xcheck.py }
procedure Dump(count: Integer);
var
  k, outLen, n, p, t, m: Integer;
  msg, aad, outb: TBytes;
  key: TKey32;
  nonce: TNonce24;
  n12: TBytes;
  tag: TTag16;
  counter: UInt32;
  pwd, salt: TBytes;
  d1: TBlake2sDigest;
  many: array[0..6] of TBytes;
  mp: array[0..6] of PByte;
  ml: array[0..6] of SizeInt;
  md: array[0..6] of TBlake2sDigest;
  j: Integer;
begin
  for k := 1 to count do
  begin
    { BLAKE2b, every output length }
    outLen := 1 + Integer(Rnd mod 64);
    msg := RandomData(Rnd mod 600);
    SetLength(outb, outLen);
    Blake2b(outLen, PtrOf(msg), Length(msg), @outb[0]);
    WriteLn('blake2b ', outLen, ' ', HexOf(msg), ' ', HexOf(outb));
    { ChaCha20 at a counter }
    msg := RandomData(Rnd mod 400);
    outb := Copy(msg);
    Move(RandomData(32)[0], key, 32);
    n12 := RandomData(12);
    counter := Rnd mod 1000;
    ChaCha20Xor(key, n12[0], counter, PtrOf(outb), Length(outb));
    WriteLn('chacha20 ', ToHex(@key[0], 32), ' ', HexOf(n12), ' ', counter, ' ', HexOf(msg), ' ', HexOf(outb));
    { Poly1305 }
    msg := RandomData(Rnd mod 300);
    Move(RandomData(32)[0], key, 32);
    Poly1305(key, PtrOf(msg), Length(msg), tag);
    WriteLn('poly1305 ', ToHex(@key[0], 32), ' ', HexOf(msg), ' ', ToHex(@tag[0], 16));
    { XChaCha20-Poly1305 }
    msg := RandomData(Rnd mod 500);
    aad := RandomData(Rnd mod 40);
    outb := Copy(msg);
    Move(RandomData(32)[0], key, 32);
    Move(RandomData(24)[0], nonce, 24);
    XChaChaPolyEncrypt(key, nonce, PtrOf(aad), Length(aad), PtrOf(outb), Length(outb), tag);
    { the ciphertext, then the tag: one field (just the tag when empty) }
    WriteLn('xchacha ', ToHex(@key[0], 32), ' ', ToHex(@nonce[0], 24), ' ', HexOf(aad), ' ',
      HexOf(msg), ' ', ToHex(PtrOf(outb), Length(outb)), ToHex(@tag[0], 16));
    { BLAKE2s, keyed (the archive's fragment ids and subkeys): one at a
      time, and in lanes (several messages, some empty) }
    msg := RandomData(Rnd mod 300);
    aad := RandomData(1 + Integer(Rnd mod 32));   { the key }
    Blake2s256Key(@aad[0], Length(aad), PtrOf(msg), Length(msg), d1);
    WriteLn('blake2s ', HexOf(aad), ' ', HexOf(msg), ' ', ToHex(@d1[0], 32));
    for j := 0 to 6 do
    begin
      many[j] := RandomData(Rnd mod 3 * Integer(Rnd mod 150));
      mp[j] := PtrOf(many[j]);
      ml[j] := Length(many[j]);
    end;
    Blake2sManyKey(@aad[0], Length(aad), @mp[0], @ml[0], 7, @md[0]);
    for j := 0 to 6 do
      WriteLn('blake2s ', HexOf(aad), ' ', HexOf(many[j]), ' ', ToHex(@md[j][0], 32));
    { Argon2id: small memory, any lanes (OpenSSL), p = 1 also through libsodium }
    p := 1 + Integer(Rnd mod 4);
    t := 1 + Integer(Rnd mod 3);
    m := 8 * p + Integer(Rnd mod 64);
    pwd := RandomData(Rnd mod 40);
    salt := RandomData(16);
    outLen := 4 + Integer(Rnd mod 100);
    SetLength(outb, outLen);
    Argon2id(PtrOf(pwd), Length(pwd), @salt[0], 16, nil, 0, nil, 0, t, m, p, @outb[0], outLen);
    WriteLn('argon2id ', t, ' ', m, ' ', p, ' ', HexOf(pwd), ' ', HexOf(salt), ' ', HexOf(outb));
  end;
end;

begin
  if (ParamCount >= 2) and (ParamStr(1) = '--dump') then
  begin
    { --dump N [pascal]: the C paths unless told }
    CryptoUseC := ParamStr(3) <> 'pascal';
    Blake2sUseC := CryptoUseC;
    Dump(StrToInt(ParamStr(2)));
    Exit;
  end;
  { the Pascal paths, then the C ones (when built in) }
  CryptoUseC := False;
  WriteLn('-- Pascal');
  Vectors;
  Speed;
{$ifndef SYLZ_PUREPASCAL}
  CryptoUseC := True;
  WriteLn('-- C');
  Vectors;
  Speed;
{$endif}
  if failures > 0 then
  begin
    WriteLn(failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('all ok');
end.
