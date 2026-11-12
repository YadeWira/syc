{ sycvectors — the known answers syc's hashes, checksum and ciphers are
  checked against: the RFCs' test vectors. tests/cryptotest runs them on
  each code path, and so does syc's self-test (syc s). }
unit sycvectors;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, blake2s, syccrypto, sycblocks;

type
  { what a check found, and what it checked }
  TCheckProc = procedure(ok: Boolean; const what: string);

function FromHex(const s: string): TBytes;
function ToHex(p: PByte; n: SizeInt): string;
function HexOf(const b: TBytes): string;

{ BLAKE2b, ChaCha20, Poly1305, HChaCha20, XChaCha20-Poly1305, Argon2id and
  the system's random numbers, on the paths CryptoUseC selects }
procedure CryptoVectors(check: TCheckProc);
{ CRC-32 and BLAKE2s, on the paths CrcUseC and Blake2sUseC select }
procedure HashVectors(check: TCheckProc);

implementation

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

procedure CryptoVectors(check: TCheckProc);
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
  check(ToHex(@out[0], 64) = 'ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923',
    'BLAKE2b-512("abc"), RFC 7693 A');

  for i := 0 to 31 do
    key[i] := i;
  { RFC 8439 2.3.2: the block function, as the key stream of block 1 }
  SetLength(b, 64);
  FillChar(b[0], 64, 0);
  n12 := FromHex('000000090000004a00000000');
  ChaCha20Xor(key, n12[0], 1, @b[0], 64);
  check(HexOf(b) = '10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e',
    'ChaCha20 block, RFC 8439 2.3.2');
  { 2.4.2 }
  b := FromHex(LADIES);
  n12 := FromHex('000000000000004a00000000');
  ChaCha20Xor(key, n12[0], 1, @b[0], Length(b));
  check(HexOf(b) = '6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d',
    'ChaCha20 encryption, RFC 8439 2.4.2');
  { 2.5.2 }
  b := FromHex('85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b');
  Move(b[0], sub, 32);
  abc := 'Cryptographic Forum Research Group';
  Poly1305(sub, @abc[1], Length(abc), tag);
  check(ToHex(@tag[0], 16) = 'a8061dc1305136c6c22b8baf0c0127a9', 'Poly1305, RFC 8439 2.5.2');
  { draft-irtf-cfrg-xchacha 2.2.1 }
  b := FromHex('000000090000004a0000000031415927');
  HChaCha20(key, b[0], sub);
  check(ToHex(@sub[0], 32) = '82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc',
    'HChaCha20, xchacha draft 2.2.1');
  { draft A.3.1 }
  b := FromHex('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
  Move(b[0], key, 32);
  b := FromHex('404142434445464748494a4b4c4d4e4f5051525354555657');
  Move(b[0], nonce, 24);
  aad := FromHex('50515253c0c1c2c3c4c5c6c7');
  b := FromHex(LADIES);
  XChaChaPolyEncrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag);
  check((HexOf(b) = 'bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e')
    and (ToHex(@tag[0], 16) = 'c0875924c1c7987947deafd8780acf49'), 'XChaCha20-Poly1305, xchacha draft A.3.1');
  check(XChaChaPolyDecrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag)
    and (HexOf(b) = LADIES), 'XChaCha20-Poly1305 decrypts it back');
  XChaChaPolyEncrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag);
  b[5] := b[5] xor 1;
  check(not XChaChaPolyDecrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag),
    'XChaCha20-Poly1305 refuses a changed byte');
  b[5] := b[5] xor 1;
  aad[0] := aad[0] xor 1;
  check(not XChaChaPolyDecrypt(key, nonce, @aad[0], Length(aad), @b[0], Length(b), tag),
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
  check(ToHex(@out[0], 32) = '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659',
    'Argon2id, RFC 9106 5.3');
  { the system's random numbers: two draws differ, and are not all zero }
  SetLength(b, 64);
  SetLength(aad, 64);
  RandomBytes(@b[0], 64);
  RandomBytes(@aad[0], 64);
  FillChar(out, SizeOf(out), 0);
  check((CompareByte(b[0], aad[0], 64) <> 0) and (CompareByte(b[0], out[0], 64) <> 0),
    'RandomBytes gives different, non-zero draws');
end;

procedure HashVectors(check: TCheckProc);
const
  DIGITS: string = '123456789';
  ABC: string = 'abc';
var
  d: TBlake2sDigest;
  key: array[0..31] of Byte;
  i: Integer;
begin
  { the check value of CRC-32/ISO-HDLC, zlib's }
  check(crc32(0, @DIGITS[1], 9) = $CBF43926, 'CRC-32("123456789")');
  check(crc32(crc32(0, @DIGITS[1], 4), @DIGITS[5], 5) = $CBF43926, 'CRC-32 in two pieces');
  { RFC 7693, appendix B }
  Blake2s256(@ABC[1], 3, d);
  check(ToHex(@d[0], 32) = '508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982',
    'BLAKE2s-256("abc"), RFC 7693 B');
  Blake2s256(nil, 0, d);
  check(ToHex(@d[0], 32) = '69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9',
    'BLAKE2s-256("")');
  { the reference implementation's keyed vector for the empty message:
    key 00 01 .. 1f }
  for i := 0 to 31 do
    key[i] := i;
  Blake2s256Key(@key[0], 32, nil, 0, d);
  check(ToHex(@d[0], 32) = '48a8997da407876b3d79c0d92325ad3b89cbb754d86ab71aee047ad345fd2c49',
    'BLAKE2s-256 keyed, of ""');
end;

end.
