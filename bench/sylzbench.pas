{ sylzbench — in-memory benchmark for the sylz codec, lzbench-style.

  Usage: sylzbench [-l LEVELS] [-t SECONDS] [-ec] FILE...
    -l  comma-separated levels, default 1,2,4,6,9,12
    -t  minimum time per measurement, default 1.0
    -ec extra compression, format v3: entropy-coded literals (SYLZ_ENTROPY);
        levels 0..SYLZ_EC_MAXLEVEL, level N parsing as v2's N + 2

  Each file is one block. Speeds are the best of the repeated runs, in
  MB/s with MB = 10^6 bytes (as lzbench), measured on the input size.
  Compression reuses one TSylzCtx across runs, as a long-lived caller would.
  SYLZ_DUMP=PREFIX writes each compressed block to PREFIX.LEVEL;
  SYLZ_LOAD=PREFIX decodes those blocks instead of compressing (compress
  speed shows as 0); SYLZ_NOASM=1 uses the Pascal code paths only;
  SYLZ_NOBMI2=1 the Huffman decoder without BMI2; SYLZ_C=1 the C paths
  instead of the assembler ones where both exist. }
program sylzbench;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}Linux, UnixType,{$endif}
  {$ifdef windows}Windows,{$endif}
  SysUtils, Classes, Math, sylz, sylzhuf;

function NowNs: UInt64;
{$ifdef unix}
var
  ts: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @ts);
  Result := UInt64(ts.tv_sec) * 1000000000 + UInt64(ts.tv_nsec);
end;
{$endif}
{$ifdef windows}
var
  c, f: Int64;
begin
  QueryPerformanceCounter(c);
  QueryPerformanceFrequency(f);
  Result := UInt64(Round(c / f * 1e9));
end;
{$endif}

function LoadFile(const path: string; out buf: TBytes): SizeInt;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    Result := fs.Size;
    SetLength(buf, Result + 1);   { +1 keeps @buf[0] valid for empty files }
    if Result > 0 then
      fs.ReadBuffer(buf[0], Result);
  finally
    fs.Free;
  end;
end;

function Speed(bytes: SizeInt; ns: UInt64): Double;
begin
  if ns = 0 then
    ns := 1;
  Result := bytes * 1000.0 / ns;
end;

procedure BenchFile(const path: string; const levels: array of Integer;
  minNs: UInt64; flags: Integer);
var
  src, cbuf, dbuf: TBytes;
  n, csize, dsize: SizeInt;
  li, level: Integer;
  t0, t1, best, total: UInt64;
  ctx: TSylzCtx;
  dctx: TSylzDCtx;
begin
  SylzCtxInit(ctx);
  SylzDCtxInit(dctx);
  n := LoadFile(path, src);
  SetLength(cbuf, SylzBound(n) + 1);
  SetLength(dbuf, n + 1);
  for li := 0 to High(levels) do
  begin
    level := levels[li];

    best := High(UInt64);
    total := 0;
    if GetEnvironmentVariable('SYLZ_LOAD') <> '' then
    begin
      { decode only: the block SYLZ_DUMP wrote for this file and level }
      with TFileStream.Create(Format('%s.%d', [GetEnvironmentVariable('SYLZ_LOAD'), level]), fmOpenRead) do
      try
        csize := Size;
        if csize > Length(cbuf) then
          SetLength(cbuf, csize);
        ReadBuffer(cbuf[0], csize);
      finally
        Free;
      end;
      best := 0;
    end
    else
      repeat
        t0 := NowNs;
        csize := SylzCompressEx(ctx, @src[0], n, @cbuf[0], Length(cbuf), level, flags);
        t1 := NowNs;
        if t1 - t0 < best then
          best := t1 - t0;
        Inc(total, t1 - t0);
      until total >= minNs;
    if csize < 0 then
    begin
      WriteLn(StdErr, path, ': compression failed at level ', level);
      Halt(2);
    end;
    if GetEnvironmentVariable('SYLZ_DUMP') <> '' then
      with TFileStream.Create(Format('%s.%d', [GetEnvironmentVariable('SYLZ_DUMP'), level]), fmCreate) do
      try
        WriteBuffer(cbuf[0], csize);
      finally
        Free;
      end;
    Write(Format('sylz %-3d  %9.2f MB/s', [level, IfThen(best = 0, 0.0, Speed(n, best))]));

    FillChar(dbuf[0], n, 0);
    best := High(UInt64);
    total := 0;
    repeat
      t0 := NowNs;
      dsize := SylzDecompressCtx(dctx, @cbuf[0], csize, @dbuf[0], n);
      t1 := NowNs;
      if t1 - t0 < best then
        best := t1 - t0;
      Inc(total, t1 - t0);
    until total >= minNs;
    if (dsize <> n) or ((n > 0) and (CompareByte(src[0], dbuf[0], n) <> 0)) then
    begin
      WriteLn;
      WriteLn(StdErr, path, ': ROUNDTRIP MISMATCH at level ', level);
      Halt(3);
    end;
    WriteLn(Format('  %9.2f MB/s  %12d  %6.2f  %s',
      [Speed(n, best), csize, csize * 100.0 / Max(n, 1), ExtractFileName(path)]));
  end;
  SylzCtxFree(ctx);
  SylzDCtxFree(dctx);
end;

var
  levels: array of Integer;
  minTime: Double;
  i, argi: Integer;
  parts: TStringArray;
  flags: Integer;
begin
  flags := 0;
  levels := [1, 2, 4, 6, 9, 12];
  if GetEnvironmentVariable('SYLZ_C') <> '' then
    SylzPreferC := True;
  if GetEnvironmentVariable('SYLZ_NOBMI2') <> '' then
    HufUseBmi2 := False;
  if GetEnvironmentVariable('SYLZ_NOASM') <> '' then
    SylzUseAsm := False;

  minTime := 1.0;
  argi := 1;
  while (argi <= ParamCount) and (Copy(ParamStr(argi), 1, 1) = '-') do
  begin
    if (ParamStr(argi) = '-l') and (argi < ParamCount) then
    begin
      parts := ParamStr(argi + 1).Split([',']);
      SetLength(levels, Length(parts));
      for i := 0 to High(parts) do
        levels[i] := StrToInt(parts[i]);
      Inc(argi, 2);
    end
    else if ParamStr(argi) = '-ec' then
    begin
      flags := flags or SYLZ_ENTROPY;
      Inc(argi);
    end
    else if (ParamStr(argi) = '-t') and (argi < ParamCount) then
    begin
      minTime := StrToFloat(ParamStr(argi + 1));
      Inc(argi, 2);
    end
    else
    begin
      WriteLn(StdErr, 'unknown option ', ParamStr(argi));
      Halt(1);
    end;
  end;
  if argi > ParamCount then
  begin
    WriteLn(StdErr, 'usage: sylzbench [-l 1,2,4] [-t SECONDS] [-ec] FILE...');
    Halt(1);
  end;
  WriteLn('Compressor  Compress.      Decompress.     Compr. size   Ratio  Filename');
  for i := argi to ParamCount do
    BenchFile(ParamStr(i), levels, UInt64(Round(minTime * 1e9)), flags);
end.
