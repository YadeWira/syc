{ sylzfuzz — roundtrip and corrupt-input tests for the sylz codec (Linux).

  Usage: sylzfuzz [ITERATIONS] [SAMPLE-FILE...]

  Every buffer handed to the decoder sits flush against a PROT_NONE guard
  page, so a read past the compressed input or a write past the output
  faults immediately instead of going unnoticed. Cases alternate between
  the assembler and the Pascal code paths (SylzUseAsm), and every
  compressed block is also produced by the other path and compared. }
program sylzfuzz;

{$mode objfpc}{$H+}

uses
  BaseUnix, SysUtils, Classes, sylz;

const
  PAGE = 4096;

type
  { n usable bytes ending exactly at a guard page }
  TGuarded = record
    base: Pointer;
    total: SizeUInt;
    p: PByte;
  end;

function GuardedAlloc(n: SizeInt): TGuarded;
var
  body: SizeUInt;
begin
  body := (SizeUInt(n) + PAGE - 1) div PAGE * PAGE;
  if body = 0 then
    body := PAGE;
  Result.total := body + PAGE;
  Result.base := fpmmap(nil, Result.total, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
  if Result.base = MAP_FAILED then
  begin
    WriteLn(StdErr, 'mmap failed');
    Halt(2);
  end;
  fpmprotect(PByte(Result.base) + body, PAGE, PROT_NONE);
  Result.p := PByte(Result.base) + body - SizeUInt(n);
end;

procedure GuardedFree(var g: TGuarded);
begin
  fpmunmap(g.base, g.total);
end;

var
  samples: array of TBytes;
  fctx: TSylzCtx;
  rng: UInt64 = UInt64($9E3779B97F4A7C15);
  roundtrips: Int64 = 0;
  corrupt: Int64 = 0;

function Rand: UInt32;
begin
  { xorshift64* }
  rng := rng xor (rng shr 12);
  rng := rng xor (rng shl 25);
  rng := rng xor (rng shr 27);
  Result := UInt32((rng * UInt64(2685821657736338717)) shr 32);
end;

function RandBelow(n: UInt32): UInt32;
begin
  if n = 0 then
    Exit(0);
  Result := Rand mod n;
end;

procedure LoadSample(const path: string);
var
  fs: TFileStream;
  i: Integer;
begin
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    i := Length(samples);
    SetLength(samples, i + 1);
    SetLength(samples[i], fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(samples[i][0], fs.Size);
  finally
    fs.Free;
  end;
end;

function Min(a, b: SizeInt): SizeInt; inline;
begin
  if a < b then Result := a else Result := b;
end;

{ Fills buf with one of several kinds of data. }
procedure MakeInput(buf: PByte; n: SizeInt);
var
  kind, i, period: SizeInt;
  s: TBytes;
  start: SizeInt = 0;
  alphabet: UInt32;
begin
  if Length(samples) > 0 then
    kind := RandBelow(6)
  else
    kind := RandBelow(5);
  case kind of
    0: { random }
      for i := 0 to n - 1 do
        buf[i] := Byte(Rand);
    1: { small alphabet: many short matches }
      begin
        alphabet := 2 + RandBelow(6);
        for i := 0 to n - 1 do
          buf[i] := Byte(RandBelow(alphabet));
      end;
    2: { periodic: overlapping matches at every small offset }
      begin
        period := 1 + RandBelow(20);
        for i := 0 to n - 1 do
          if i < period then
            buf[i] := Byte(Rand)
          else
            buf[i] := buf[i - period];
      end;
    3: { long runs }
      begin
        i := 0;
        while i < n do
        begin
          period := 1 + RandBelow(600);
          FillChar(buf[i], Min(period, n - i), Byte(Rand));
          Inc(i, period);
        end;
      end;
    4: { copies of earlier stretches with noise: long and far matches }
      for i := 0 to n - 1 do
        if (i > 64) and (RandBelow(100) < 97) then
          buf[i] := buf[i - 1 - SizeInt(RandBelow(Min(i - 1, 70000)))]
        else
          buf[i] := Byte(Rand);
  else { slice of a real file }
    s := samples[RandBelow(Length(samples))];
    if Length(s) = 0 then
      FillChar(buf^, n, 0)
    else
      for i := 0 to n - 1 do
      begin
        if i = 0 then
          start := RandBelow(Length(s));
        buf[i] := s[(start + i) mod Length(s)];
      end;
  end;
end;

procedure Fail(const what: string; n, level: SizeInt);
begin
  WriteLn(StdErr, 'FAIL: ', what, ' (n=', n, ' level=', level, ' seed state=', rng, ')');
  Halt(1);
end;

procedure OneCase;
var
  n, level, csize, r, i, flips, cut: SizeInt;
  input, comp, outp, bad, other: TGuarded;
  flags: Integer;
begin
  case RandBelow(4) of
    0: n := RandBelow(64);
    1: n := RandBelow(1024);
    2: n := RandBelow(70000);
  else
    n := RandBelow(400000);
  end;
  level := SYLZ_MINLEVEL + RandBelow(SYLZ_MAXLEVEL - SYLZ_MINLEVEL + 1);   { 0 = default }

  input := GuardedAlloc(n);
  MakeInput(input.p, n);
  comp := GuardedAlloc(SylzBound(n));
  if RandBelow(2) = 0 then
    flags := 0
  else
    flags := SYLZ_ENTROPY;
  csize := SylzCompressEx(fctx, input.p, n, comp.p, SylzBound(n), level, flags);
  if csize < 0 then
    Fail('compress returned -1 with a SylzBound buffer', n, level);

  { the assembler and Pascal compressors must agree byte for byte }
  other := GuardedAlloc(SylzBound(n));
  SylzUseAsm := not SylzUseAsm;
  r := SylzCompressEx(fctx, input.p, n, other.p, SylzBound(n), level, flags);
  SylzUseAsm := not SylzUseAsm;
  if (r <> csize) or (CompareByte(comp.p^, other.p^, csize) <> 0) then
    Fail('assembler and Pascal compressors disagree', n, level);
  GuardedFree(other);

  { decode from a buffer of exactly csize bytes, into exactly n bytes }
  bad := GuardedAlloc(csize);
  Move(comp.p^, bad.p^, csize);
  outp := GuardedAlloc(n);
  r := SylzDecompress(bad.p, csize, outp.p, n);
  if (r <> n) or ((n > 0) and (CompareByte(input.p^, outp.p^, n) <> 0)) then
    Fail('roundtrip mismatch', n, level);
  Inc(roundtrips);

  { corrupted copies: must return -1 or some length, never fault }
  for i := 1 to 4 do
  begin
    Move(comp.p^, bad.p^, csize);
    flips := 1 + RandBelow(4);
    while (flips > 0) and (csize > 0) do
    begin
      bad.p[RandBelow(csize)] := Byte(Rand);
      Dec(flips);
    end;
    SylzDecompress(bad.p, csize, outp.p, n);
    Inc(corrupt);
  end;
  GuardedFree(bad);

  { truncated input: must be rejected }
  if csize > 1 then
  begin
    cut := RandBelow(csize);
    bad := GuardedAlloc(cut);
    Move(comp.p^, bad.p^, cut);
    if SylzDecompress(bad.p, cut, outp.p, n) = n then
      Fail('truncated input accepted', n, level);
    GuardedFree(bad);
    Inc(corrupt);
  end;

  { output buffer one byte short: must be rejected }
  if n > 0 then
  begin
    GuardedFree(outp);
    outp := GuardedAlloc(n - 1);
    if SylzDecompress(comp.p, csize, outp.p, n - 1) <> -1 then
      Fail('short output buffer accepted', n, level);
    Inc(corrupt);
  end;

  GuardedFree(outp);
  GuardedFree(comp);
  GuardedFree(input);
end;

var
  iters, k: Int64;
  i: Integer;
  first: Integer;
begin
  iters := 2000;
  first := 1;
  if (ParamCount >= 1) and TryStrToInt64(ParamStr(1), iters) then
    first := 2;
  for i := first to ParamCount do
    LoadSample(ParamStr(i));
  SylzCtxInit(fctx);
  for k := 1 to iters do
  begin
    SylzUseAsm := Odd(k);   { alternate the assembler and Pascal decoders }
    OneCase;
  end;
  WriteLn('ok: ', roundtrips, ' roundtrips, ', corrupt, ' corrupt/truncated decodes');
end.
