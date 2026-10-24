{ sycdedup — tests of the archive's dedup pieces: BLAKE2s-256 (blake2s)
  and the fragment cutter (syccdc).

  Usage: sycdedup [FILE]          checks, statistics and speed (FILE: the
                                  data to cut; without it, generated)
         sycdedup --dump FILE     one line per fragment: offset length
                                  blake2s, for tools/syc_cdc_ref.py --check }
program sycdedup;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math, blake2s, syccdc;

var
  seed: UInt32 = 2026;
  failures: Integer = 0;

{ xorshift32: an LCG's low bits repeat every 2^k values, and data with a
  period of 64 KiB cuts into fragments of exactly 64 KiB }
function Rnd: UInt32;
begin
  seed := seed xor (seed shl 13);
  seed := seed xor (seed shr 17);
  seed := seed xor (seed shl 5);
  Result := seed;
end;

function Hex(const d: TBlake2sDigest): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(d) do
    Result := Result + LowerCase(IntToHex(d[i], 2));
end;

procedure Check(ok: Boolean; const what: string);
begin
  if not ok then
  begin
    WriteLn('FAIL: ', what);
    Inc(failures);
  end;
end;

function LoadFile(const path: string): TBytes;
begin
  with TFileStream.Create(path, fmOpenRead or fmShareDenyWrite) do
  try
    SetLength(Result, Size);
    if Size > 0 then
      ReadBuffer(Result[0], Size);
  finally
    Free;
  end;
end;

{ RFC 7693 appendix B and the empty message; then, for many lengths,
  the hash in pieces of random sizes against the hash in one call }
procedure TestBlake2s;
const
  ABC = 'abc';
var
  d, e: TBlake2sDigest;
  buf: TBytes;
  s: TBlake2s;
  n, at, take, i: SizeInt;
begin
  Blake2s256(@ABC[1], 3, d);
  Check(Hex(d) = '508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982', 'blake2s("abc")');
  Blake2s256(nil, 0, d);
  Check(Hex(d) = '69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9', 'blake2s("")');
  SetLength(buf, 5000);
  for i := 0 to High(buf) do
    buf[i] := Byte(Rnd);
  for n := 0 to Length(buf) do
  begin
    if (n > 300) and (n mod 61 <> 0) then
      Continue;
    Blake2s256(@buf[0], n, d);
    Blake2sInit(s);
    at := 0;
    while at < n do
    begin
      take := Rnd mod 150;
      if take > n - at then
        take := n - at;
      Blake2sUpdate(s, @buf[at], take);
      Inc(at, take);
    end;
    Blake2sFinal(s, e);
    Check(CompareByte(d, e, SizeOf(d)) = 0, Format('blake2s in pieces, length %d', [n]));
  end;
end;

type
  TFrag = record
    off, len: SizeInt;
    hash: TBlake2sDigest;
  end;
  TFrags = array of TFrag;

function Cut(const prm: TCdcParams; const data: TBytes): TFrags;
var
  at, len, k: SizeInt;
begin
  Result := nil;
  SetLength(Result, Length(data) div prm.minSize + 1);
  at := 0;
  k := 0;
  while at < Length(data) do
  begin
    len := CdcCut(prm, @data[at], Length(data) - at);
    Result[k].off := at;
    Result[k].len := len;
    Blake2s256(@data[at], len, Result[k].hash);
    Inc(k);
    Inc(at, len);
  end;
  SetLength(Result, k);
end;

{ the share of a's fragments (by bytes) found in b }
function Shared(const a, b: TFrags): Double;
var
  list: TStringList;
  i: Integer;
  same, total: Int64;
begin
  list := TStringList.Create;
  try
    list.Sorted := True;
    list.Duplicates := dupIgnore;
    for i := 0 to High(b) do
      list.Add(Hex(b[i].hash));
    same := 0;
    total := 0;
    for i := 0 to High(a) do
    begin
      Inc(total, a[i].len);
      if list.IndexOf(Hex(a[i].hash)) >= 0 then
        Inc(same, a[i].len);
    end;
  finally
    list.Free;
  end;
  if total = 0 then
    Exit(1);
  Result := same / total;
end;

procedure TestCdc(const data: TBytes);
var
  prm: TCdcParams;
  f, g: TFrags;
  edited: TBytes;
  i, mid, under: SizeInt;
  sum: Int64;
  t0, ms: QWord;
  d: TBlake2sDigest;
begin
  prm := CdcParams(CDC_MIN_LOG, CDC_AVG_LOG, CDC_MAX_LOG);
  f := Cut(prm, data);
  { every fragment within bounds; only the last one under the minimum }
  sum := 0;
  under := 0;
  for i := 0 to High(f) do
  begin
    Inc(sum, f[i].len);
    Check((f[i].len >= 1) and (f[i].len <= prm.maxSize), Format('fragment %d length %d', [i, f[i].len]));
    if f[i].len < prm.minSize then
      Inc(under);
    if (f[i].len < prm.minSize) and (i <> High(f)) then
      Check(False, Format('fragment %d under the minimum and not last', [i]));
  end;
  Check(sum = Length(data), 'the fragments cover the data');
  WriteLn(Format('cdc: %d bytes, %d fragments, mean %.1f KiB', [Length(data), Length(f),
    sum / Length(f) / 1024]));

  { insertions and a deletion near the start: almost every fragment after
    them is found again }
  if Length(data) > 4 * prm.maxSize then
  begin
    mid := Length(data) div 3;
    SetLength(edited, Length(data) + 100);
    Move(data[0], edited[0], mid);
    for i := 0 to 99 do
      edited[mid + i] := Byte(Rnd);
    Move(data[mid], edited[mid + 100], Length(data) - mid);
    g := Cut(prm, edited);
    WriteLn(Format('cdc: 100 bytes inserted at 1/3: %.2f%% of the data in fragments found again',
      [Shared(f, g) * 100]));
    Check(Shared(f, g) > 0.95, 'fragments found again after an insertion');
  end;

  { speed }
  t0 := GetTickCount64;
  for i := 1 to 3 do
    f := Cut(prm, data);
  ms := GetTickCount64 - t0;
  WriteLn(Format('cdc + blake2s: %.0f MB/s', [3.0 * Length(data) / 1e6 / Max(ms, 1) * 1000]));
  t0 := GetTickCount64;
  for i := 1 to 3 do
    Blake2s256(@data[0], Length(data), d);
  ms := GetTickCount64 - t0;
  WriteLn(Format('blake2s alone: %.0f MB/s', [3.0 * Length(data) / 1e6 / Max(ms, 1) * 1000]));
end;

procedure Dump(const data: TBytes);
var
  f: TFrags;
  i: Integer;
begin
  f := Cut(CdcParams(CDC_MIN_LOG, CDC_AVG_LOG, CDC_MAX_LOG), data);
  for i := 0 to High(f) do
    WriteLn(f[i].off, ' ', f[i].len, ' ', Hex(f[i].hash));
end;

var
  data: TBytes;
  i: SizeInt;
begin
  if (ParamCount = 2) and (ParamStr(1) = '--dump') then
  begin
    Dump(LoadFile(ParamStr(2)));
    Exit;
  end;
  if ParamCount >= 1 then
    data := LoadFile(ParamStr(1))
  else
  begin
    SetLength(data, 32 shl 20);
    for i := 0 to High(data) do
      data[i] := Byte(Rnd);
  end;
  { the Pascal block function, then the C one (when built in) }
  Blake2sUseC := False;
  TestBlake2s;
  WriteLn('blake2s, Pascal: checked');
{$ifndef SYLZ_PUREPASCAL}
  Blake2sUseC := True;
  TestBlake2s;
  WriteLn('blake2s, C: checked');
{$endif}
  TestCdc(data);
  if failures > 0 then
  begin
    WriteLn(failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('ok');
end.
