{ cryptotest — tests of src/syccrypto.pas: the RFCs' test vectors (in
  src/sycvectors.pas, which syc's self-test runs too), and
  random cases for tools/crypto_xcheck.py to recompute with libsodium
  (PyNaCl), OpenSSL and hashlib.

  Usage: cryptotest           the test vectors, speed
         cryptotest --dump N  N random cases per primitive, one a line:
                              KIND inputs... output, in hex }
program cryptotest;

{$mode objfpc}{$H+}

uses
  SysUtils, blake2s, syccrypto, sycvectors;

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
  CryptoVectors(@Check);
  Speed;
{$ifndef SYLZ_PUREPASCAL}
  CryptoUseC := True;
  WriteLn('-- C');
  CryptoVectors(@Check);
  Speed;
{$endif}
  if failures > 0 then
  begin
    WriteLn(failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('all ok');
end.
