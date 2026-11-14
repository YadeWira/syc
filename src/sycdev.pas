{ sycdev — the commands about this build and this machine, for whoever
  develops syc or reports a problem with it:

    syc b   benchmark: files compressed and decompressed in memory
    syc s   self-test: the codec, the checksums and ciphers, a stream and
            an archive, through every code path built in
    syc r   report: the build, the machine and the self-test's result,
            to paste into a bug report }
unit sycdev;

{$mode objfpc}{$H+}

interface

uses
  syccli;

function RunBenchCommand(const opts: TOptions): Integer;
function RunSelfTestCommand(const opts: TOptions): Integer;
function RunReportCommand(const opts: TOptions): Integer;

implementation

uses
  {$ifdef windows}Windows,{$endif}
  {$ifdef unix}BaseUnix,{$endif}
  SysUtils, Classes, Math, sylz, sylzhuf, blake2s, syccdc, syccrypto, sycblocks, sycui,
  sycbuild, sycvectors, sycstream, sycarc;

const
  ISSUES_URL = 'https://github.com/YadeWira/syc/issues';

{ ── syc b ──────────────────────────────────────────────────────────────── }

function LoadFile(const path: string; out buf: TBytes): SizeInt;
var
  fs: TFileStream;
begin
  try
    fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  except
    on E: EFOpenError do
      Fail(EXIT_FATAL, path + ': cannot open');
  end;
  try
    if fs.Size > High(SizeInt) - 1 then
      Fail(EXIT_FATAL, path + ': too large to hold in memory');
    Result := fs.Size;
    SetLength(buf, Result + 1);   { +1 keeps @buf[0] valid for empty files }
    if Result > 0 then
      fs.ReadBuffer(buf[0], Result);
  finally
    fs.Free;
  end;
end;

function FormatName(flags: Integer): string;
begin
  Result := Format('sylz format v%d', [SylzFlagsFormat(flags)]);
  if flags and SYLZ_ENTROPY <> 0 then
    Result := Result + ' (-ec)';
end;

{ One file: every level, each block compressed and decompressed until
  the measurement has run for minNs, the best run kept. }
procedure BenchFile(const opts: TOptions; const path: string; const levels: array of Integer;
  minNs: UInt64);
var
  src, cbuf, dbuf: TBytes;
  csizes: array of SizeInt;
  n, blockSize, blocks, b, at, cat, got, csize: SizeInt;
  li, level: Integer;
  t0, t1, best, total: UInt64;
  ctx: TSylzCtx;
  dctx: TSylzDCtx;
  cSpeed, dSpeed: Double;
  line: string;
begin
  n := LoadFile(path, src);
  blockSize := SizeInt(opts.blockMiB) shl 20;
  if blockSize = 0 then
  begin
    if n > MAX_BLOCK then
      Fail(EXIT_USAGE, Format('%s: over %d MiB, more than one block holds (give -b MIB)',
        [path, MAX_BLOCK shr 20]));
    blockSize := Max(n, 1);
  end;
  blocks := (n + blockSize - 1) div blockSize;
  SetLength(csizes, blocks + 1);
  SetLength(cbuf, n + blocks * (SylzBound(blockSize) - blockSize) + 1);
  SetLength(dbuf, n + 1);

  line := Format('%s: %d bytes', [path, n]);
  if blocks > 1 then
    line := line + Format(' in %d blocks of %d MiB', [blocks, opts.blockMiB])
  else
    line := line + ', one block';
  WriteLn(Paint(1, stHead, line));
  if opts.verbosity <> vQuiet then
    WriteLn(Format('%s, paths: %s, at least %s per measurement, one thread',
      [FormatName(opts.flags), CodePathsInUse, HumanTime(minNs / 1e9)]));
  WriteLn(Paint(1, stHead, 'level    compressed    ratio      compress    decompress'));

  SylzCtxInit(ctx);
  SylzDCtxInit(dctx);
  try
    for li := 0 to High(levels) do
    begin
      level := levels[li];
      SetWhere(path, -1, -1);
      best := High(UInt64);
      total := 0;
      csize := 0;
      repeat
        at := 0;
        cat := 0;
        t0 := NowNs;
        for b := 0 to blocks - 1 do
        begin
          got := SylzCompressEx(ctx, @src[at], Min(blockSize, n - at), @cbuf[cat],
            Length(cbuf) - cat, level, opts.flags);
          if got < 0 then
            Fail(EXIT_FATAL, Format('%s: compression failed at level %d, block %d', [path, level, b]));
          csizes[b] := got;
          Inc(cat, got);
          Inc(at, blockSize);
        end;
        t1 := NowNs;
        csize := cat;
        best := Min(best, t1 - t0);
        Inc(total, t1 - t0);
      until total >= minNs;
      { an empty file: one empty block, as SylzCompressEx gives it }
      if blocks = 0 then
        csize := 0;
      cSpeed := n * 1000.0 / Max(best, 1);

      FillChar(dbuf[0], n, 0);
      best := High(UInt64);
      total := 0;
      repeat
        at := 0;
        cat := 0;
        t0 := NowNs;
        for b := 0 to blocks - 1 do
        begin
          got := Min(blockSize, n - at);
          if SylzDecompressCtx(dctx, @cbuf[cat], csizes[b], @dbuf[at], got) <> got then
            Fail(EXIT_FATAL, Format('%s: level %d, block %d does not decompress: a bug, please '
              + 'report it (syc report)', [path, level, b]));
          Inc(cat, csizes[b]);
          Inc(at, blockSize);
        end;
        t1 := NowNs;
        best := Min(best, t1 - t0);
        Inc(total, t1 - t0);
      until total >= minNs;
      if (n > 0) and (CompareByte(src[0], dbuf[0], n) <> 0) then
        Fail(EXIT_FATAL, Format('%s: level %d does not give the file back: a bug, please '
          + 'report it (syc report)', [path, level]));
      dSpeed := n * 1000.0 / Max(best, 1);

      WriteLn(Format('%5d  %12d  %6.2f%%  %7.1f MB/s  %7.1f MB/s',
        [level, csize, csize * 100.0 / Max(n, 1), cSpeed, dSpeed]));
    end;
  finally
    SylzCtxFree(ctx);
    SylzDCtxFree(dctx);
    ClearWhere;
  end;
end;

function RunBenchCommand(const opts: TOptions): Integer;
var
  levels: TIntArray;
  i: Integer;
begin
  levels := opts.benchLevels;
  if opts.levelSet then
  begin
    SetLength(levels, Length(levels) + 1);
    levels[High(levels)] := opts.level;
  end;
  if Length(levels) = 0 then
  begin
    SetLength(levels, SYLZ_MAXLEVEL - SYLZ_MINLEVEL + 1);
    for i := 0 to High(levels) do
      levels[i] := SYLZ_MINLEVEL + i;
  end;
  for i := 0 to High(opts.operands) do
  begin
    if i > 0 then
      WriteLn;
    BenchFile(opts, opts.operands[i], levels, UInt64(Round(opts.benchSeconds * 1e9)));
  end;
  Result := EXIT_OK;
end;

{ ── syc s ──────────────────────────────────────────────────────────────── }

var
  { the self-test's state: checks call a plain procedure (TCheckProc) }
  stPassed, stFailed: Integer;
  stVerbosity: TVerbosity;
  stSilent: Boolean;        { syc r: only the count }
  stPrefix: string;         { the code path of the checks running }
  stSeed: UInt32;

procedure Check(ok: Boolean; const what: string);
begin
  if ok then
    Inc(stPassed)
  else
    Inc(stFailed);
  if stSilent or (ok and (stVerbosity = vQuiet)) then
    Exit;
  if ok then
    WriteLn(Paint(1, stOk, 'ok     '), stPrefix, what)
  else
    WriteLn(Paint(1, stErr, 'FAILED '), stPrefix, what);
end;

{ a detail of a check, shown with -v only, counted either way }
procedure Detail(ok: Boolean; const what: string);
var
  keep: TVerbosity;
begin
  keep := stVerbosity;
  if (stVerbosity = vNormal) and ok then
    stVerbosity := vQuiet;
  Check(ok, what);
  stVerbosity := keep;
end;

function Rnd: UInt32;
begin
  stSeed := stSeed xor (stSeed shl 13);
  stSeed := stSeed xor (stSeed shr 17);
  stSeed := stSeed xor (stSeed shl 5);
  Result := stSeed;
end;

{ Generated inputs, the same on every machine. }
function MakeText(n: SizeInt): TBytes;
const
  WORDS: array[0..23] of string = ('the', 'archive', 'of', 'a', 'block', 'stream', 'and',
    'compressed', 'literal', 'match', 'offset', 'window', 'to', 'in', 'level', 'faster',
    'smaller', 'hardware', 'modest', 'tuned', 'for', 'is', 'version', 'fragment');
var
  at: SizeInt;
  w: string;
begin
  SetLength(Result, n + 1);
  at := 0;
  while at < n do
  begin
    { words by a skewed draw, now and then a number or a line end }
    case Rnd mod 16 of
      0: w := IntToStr(Rnd mod 100000);
      1: w := '.' + LineEnding;
    else
      w := WORDS[(Rnd mod 24) * (Rnd mod 24) div 24];
    end;
    w := w + ' ';
    Move(w[1], Result[at], Min(Length(w), n - at));
    Inc(at, Length(w));
  end;
  SetLength(Result, n + 1);
end;

function MakeBinary(n: SizeInt): TBytes;
var
  i: SizeInt;
  counter: UInt32;
begin
  { records of 16 bytes: a counter, a few fixed fields, some noise }
  SetLength(Result, n + 1);
  counter := 0;
  for i := 0 to n - 1 do
    case i and 15 of
      0: begin
           Inc(counter, 1 + Rnd mod 3);
           Result[i] := Byte(counter);
         end;
      1: Result[i] := Byte(counter shr 8);
      2, 3: Result[i] := 0;
      4: Result[i] := Byte(Rnd mod 5);
      5 .. 9: Result[i] := Byte(i shr 9);
      10: Result[i] := Byte(Rnd);
    else
      Result[i] := $FF;
    end;
end;

function MakeRuns(n: SizeInt): TBytes;
var
  at, len, k, period: SizeInt;
  v: Byte;
begin
  { runs of one byte and of short periods, some of them long }
  SetLength(Result, n + 1);
  at := 0;
  while at < n do
  begin
    len := 1 + Rnd mod 600;
    if Rnd mod 8 = 0 then
      len := len * 40;
    len := Min(len, n - at);
    period := 1 + Rnd mod 7;
    v := Byte(Rnd);
    for k := 0 to len - 1 do
      Result[at + k] := v + Byte(k mod period);
    Inc(at, len);
  end;
end;

function MakeRandom(n: SizeInt): TBytes;
var
  i: SizeInt;
begin
  SetLength(Result, n + 1);
  for i := 0 to n - 1 do
    Result[i] := Byte(Rnd shr 8);
end;

type
  TPathSet = record
    name: string;      { for SetCodePaths }
    bmi2: Boolean;     { HufUseBmi2 while it runs }
    shown: string;
  end;

  TPathSets = array of TPathSet;

{ The code paths this binary has, the default first. }
function CodecPaths: TPathSets;

  procedure Add(const name, shown: string; bmi2: Boolean);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].name := name;
    Result[High(Result)].shown := shown;
    Result[High(Result)].bmi2 := bmi2;
  end;

begin
  Result := nil;
{$if defined(SYLZ_PUREPASCAL)}
  Add('pascal', 'Pascal', False);
{$elseif defined(CPUX86_64)}
  Add('auto', 'assembler', HufUseBmi2);
  if HufUseBmi2 then
    Add('auto', 'assembler without BMI2', False);
  Add('c', 'C', False);
  Add('pascal', 'Pascal', False);
{$else}
  Add('auto', 'C', False);
  Add('pascal', 'Pascal', False);
{$endif}
end;

function CompressOne(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt; level, flags: Integer): SizeInt;
var
  ctx: TSylzCtx;
begin
  SylzCtxInit(ctx);
  try
    Result := SylzCompressEx(ctx, src, n, dst, cap, level, flags);
  finally
    SylzCtxFree(ctx);
  end;
end;

{ One input at every level of one format: each path compresses it to the
  same bytes, and each path decompresses them back. }
procedure CodecCase(const what: string; const data: TBytes; n: SizeInt; flags: Integer);
var
  paths: TPathSets;
  ref, cbuf, dbuf: TBytes;
  level, p, q: Integer;
  refSize, c: SizeInt;
  hadBmi2, ok, levelOk: Boolean;
  bad: string;
begin
  paths := CodecPaths;
  hadBmi2 := HufUseBmi2;
  SetLength(ref, SylzBound(n) + 1);
  SetLength(cbuf, SylzBound(n) + 1);
  SetLength(dbuf, n + 65);
  ok := True;
  bad := '';
  try
    for level := SYLZ_MINLEVEL to SYLZ_MAXLEVEL do
    begin
      levelOk := True;
      refSize := -1;
      for p := 0 to High(paths) do
      begin
        SetCodePaths(paths[p].name);
        HufUseBmi2 := paths[p].bmi2;
        try
          c := CompressOne(@data[0], n, @cbuf[0], Length(cbuf), level, flags);
        except
          c := -2;
        end;
        if p = 0 then
        begin
          refSize := c;
          if c > 0 then
            Move(cbuf[0], ref[0], c);
          if c < 0 then
            levelOk := False;
        end
        else if (c <> refSize) or ((c > 0) and (CompareByte(cbuf[0], ref[0], c) <> 0)) then
        begin
          levelOk := False;
          bad := bad + Format(' [level %d: %s writes other bytes than %s]',
            [level, paths[p].shown, paths[0].shown]);
        end;
      end;
      if refSize >= 0 then
        for q := 0 to High(paths) do
        begin
          SetCodePaths(paths[q].name);
          HufUseBmi2 := paths[q].bmi2;
          FillChar(dbuf[0], n + 64, $A5);
          if (SylzDecompress(@ref[0], refSize, @dbuf[0], n) <> n)
             or ((n > 0) and (CompareByte(dbuf[0], data[0], n) <> 0))
             or (dbuf[n] <> $A5) or (dbuf[n + 63] <> $A5) then
          begin
            levelOk := False;
            bad := bad + Format(' [level %d: %s does not decompress it]', [level, paths[q].shown]);
          end;
        end
      else
        bad := bad + Format(' [level %d: compression failed]', [level]);
      if not levelOk then
        ok := False;
      if stVerbosity = vVerbose then
        Detail(levelOk, Format('%s, level %d: %d -> %d bytes', [what, level, n, refSize]));
    end;
  finally
    HufUseBmi2 := hadBmi2;
  end;
  Check(ok, Format('%s, levels %d-%d: back to the same %d bytes, the same block from %d path(s)%s',
    [what, SYLZ_MINLEVEL, SYLZ_MAXLEVEL, n, Length(paths), bad]));
end;

{ Damaged blocks: cut short they are refused; with bits changed or made
  of noise they are refused or decode to something (the containers'
  checksums tell), never past the output. }
procedure DamageCase(const what: string; const data: TBytes; n: SizeInt; level, flags: Integer);
var
  paths: TPathSets;
  cbuf, work, dbuf: TBytes;
  c, cut, r, at: SizeInt;
  p, k: Integer;
  ok: Boolean;
  bad: string;
begin
  paths := CodecPaths;
  SetLength(cbuf, SylzBound(n) + 1);
  SetLength(dbuf, n + 65);
  c := CompressOne(@data[0], n, @cbuf[0], Length(cbuf), level, flags);
  ok := c > 0;
  bad := '';
  SetLength(work, c + 1);
  for p := 0 to High(paths) do
  begin
    if not ok then
      Break;
    SetCodePaths(paths[p].name);
    for k := 1 to 240 do
    begin
      Move(cbuf[0], work[0], c);
      FillChar(dbuf[0], n + 64, $A5);
      cut := c;
      if k <= 40 then
        { cut short: by one byte, then anywhere }
        if k = 1 then
          cut := c - 1
        else
          cut := Rnd mod c
      else if k <= 200 then
      begin
        at := Rnd mod c;
        work[at] := work[at] xor Byte(1 shl (Rnd mod 8));
      end
      else
        for r := 0 to c - 1 do
          work[r] := Byte(Rnd shr 8);
      r := SylzDecompress(@work[0], cut, @dbuf[0], n);
      if (dbuf[n] <> $A5) or (dbuf[n + 63] <> $A5) then
      begin
        ok := False;
        bad := Format(' [%s wrote past the output]', [paths[p].shown]);
      end
      else if (k <= 40) and (r <> -1) then
      begin
        ok := False;
        bad := Format(' [%s took a block cut to %d of %d bytes]', [paths[p].shown, cut, c]);
      end
      else if (r <> n) and (r <> -1) then
      begin
        ok := False;
        bad := Format(' [%s returned %d]', [paths[p].shown, r]);
      end;
    end;
  end;
  Check(ok, Format('%s: 240 damaged blocks per path refused or decoded within bounds%s', [what, bad]));
end;

{ the fast paths against the Pascal ones on the same inputs }
procedure PathAgreement(const data: TBytes; n: SizeInt);
{$ifndef SYLZ_PUREPASCAL}
var
  d1, d2: TBlake2sDigest;
  i, len, at, a, b: SizeInt;
  ok: Boolean;
  prm: TCdcParams;
  key: TKey32;
  nonce: TNonce24;
  t1, t2: TTag16;
  w1, w2: TBytes;
  msg: array[0..6] of PByte;
  lens: array[0..6] of SizeInt;
  many: array[0..6] of TBlake2sDigest;
begin
  ok := True;
  for i := 1 to 200 do
  begin
    len := Rnd mod 5000;
    at := Rnd mod (n - len);
    CrcUseC := True;
    a := crc32(0, @data[at], len);
    CrcUseC := False;
    ok := ok and (crc32(0, @data[at], len) = UInt32(a));
  end;
  Check(ok, 'CRC-32: C and Pascal agree on 200 inputs');

  ok := True;
  for i := 1 to 200 do
  begin
    len := Rnd mod 3000;
    at := Rnd mod (n - len);
    Blake2sUseC := True;
    Blake2s256(@data[at], len, d1);
    Blake2sUseC := False;
    Blake2s256(@data[at], len, d2);
    ok := ok and (CompareByte(d1, d2, SizeOf(d1)) = 0);
  end;
  { several messages at once (the archive's fragments), against one at a time }
  for i := 0 to 6 do
  begin
    lens[i] := Rnd mod 20000;
    msg[i] := @data[Rnd mod (n - lens[i])];
  end;
  Blake2sUseC := True;
  Blake2sMany(@msg[0], @lens[0], 7, @many[0]);
  Blake2sUseC := False;
  for i := 0 to 6 do
  begin
    Blake2s256(msg[i], lens[i], d2);
    ok := ok and (CompareByte(many[i], d2, SizeOf(d2)) = 0);
  end;
  Check(ok, 'BLAKE2s: C (one message, and several in lanes) and Pascal agree');

  { the fragment cutter over the whole input }
  ok := True;
  prm := CdcParams(10, 12, 14);
  at := 0;
  while at < n do
  begin
    CdcUseC := True;
    a := CdcCut(prm, @data[at], n - at);
    b := CdcCutPas(prm, @data[at], n - at);
    if (a <> b) or (a <= 0) then
    begin
      ok := False;
      Break;
    end;
    Inc(at, a);
  end;
  Check(ok, 'fragment cutter: C and Pascal cut at the same places');

  ok := True;
  FillChar(key, SizeOf(key), 7);
  FillChar(nonce, SizeOf(nonce), 9);
  for i := 1 to 40 do
  begin
    len := Rnd mod 9000;
    at := Rnd mod (n - len);
    w1 := Copy(data, at, len + 1);
    w2 := Copy(data, at, len + 1);
    CryptoUseC := True;
    XChaChaPolyEncrypt(key, nonce, @data[0], 13, @w1[0], len, t1);
    CryptoUseC := False;
    XChaChaPolyEncrypt(key, nonce, @data[0], 13, @w2[0], len, t2);
    ok := ok and (CompareByte(w1[0], w2[0], len + 1) = 0) and (CompareByte(t1, t2, SizeOf(t1)) = 0);
    { opened by the other path }
    CryptoUseC := True;
    ok := ok and XChaChaPolyDecrypt(key, nonce, @data[0], 13, @w2[0], len, t2)
      and ((len = 0) or (CompareByte(w2[0], data[at], len) = 0));
  end;
  Check(ok, 'XChaCha20-Poly1305: C and Pascal agree on 40 inputs');
end;
{$else}
begin
end;
{$endif}

{ ── a stream and an archive through the commands themselves ───────────── }

function SameFile(const path: string; const data: TBytes; n: SizeInt): Boolean;
var
  got: TBytes;
begin
  Result := False;
  if not FileExists(path) then
    Exit;
  try
    Result := (LoadFile(path, got) = n) and ((n = 0) or (CompareByte(got[0], data[0], n) = 0));
  except
    Result := False;
  end;
end;

procedure SaveFile(const path: string; const data: TBytes; n: SizeInt);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(path, fmCreate);
  try
    if n > 0 then
      fs.WriteBuffer(data[0], n);
  finally
    fs.Free;
  end;
end;

{ removes dir and everything in it (the self-test's own directory) }
procedure RemoveTree(const dir: string);
var
  sr: TSearchRec;
begin
  if FindFirst(dir + DirectorySeparator + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then
        Continue;
      if sr.Attr and faDirectory <> 0 then
        RemoveTree(dir + DirectorySeparator + sr.Name)
      else
        SysUtils.DeleteFile(dir + DirectorySeparator + sr.Name);
    until FindNext(sr) <> 0;
    SysUtils.FindClose(sr);
  end;
  RemoveDir(dir);
end;

function QuietOpts(cmd: Char; const operands: array of string): TOptions;
var
  i: Integer;
begin
  Result := Default(TOptions);
  Result.cmd := cmd;
  Result.level := SYLZ_DEFLEVEL;
  Result.flags := DEFAULT_FLAGS;
  Result.blockMiB := 1;
  Result.threads := 2;
  Result.verbosity := vQuiet;
  Result.rawSize := -1;
  Result.kdfMemMiB := 8;
  Result.force := True;
  SetLength(Result.operands, Length(operands));
  for i := 0 to High(operands) do
    Result.operands[i] := operands[i];
end;

{ runs a command of syc; its exit code, or -1 when it raised }
function RunQuiet(const o: TOptions): Integer;
var
  debug: Boolean;
begin
  { its errors are expected, and its phases are not the self-test's }
  ErrorsShown := False;
  debug := SycDebug;
  SycDebug := False;
  try
    try
      if o.cmd in ['a', 'x'] then
        Result := RunArchiveCommand(o)
      else
        Result := RunStreamCommand(o);
    except
      Result := -1;
    end;
  finally
    ErrorsShown := True;
    SycDebug := debug;
  end;
end;

procedure CommandsCase(const text, binary: TBytes; nText, nBinary: SizeInt);
var
  dir, sub, f1, f2, sylz, back, arc, outDir: string;
  o: TOptions;
  big: TBytes;
  nBig, k: SizeInt;
  pass, r: Integer;
  ok: Boolean;
  what, pw: string;
begin
  dir := IncludeTrailingPathDelimiter(GetTempDir(False))
    + Format('syc-selftest-%d-%d', [GetProcessID, Rnd mod 100000]);
  if not ForceDirectories(dir) then
  begin
    Check(False, 'a directory under ' + GetTempDir(False) + ' for the stream and archive checks');
    Exit;
  end;
  try
    { 2.5 MiB: three blocks of 1 MiB, on two threads }
    nBig := 0;
    SetLength(big, 5 shl 19 + nText + nBinary + 1);
    while nBig < 5 shl 19 do
    begin
      Move(text[0], big[nBig], nText);
      Inc(nBig, nText);
      Move(binary[0], big[nBig], nBinary);
      Inc(nBig, nBinary);
    end;
    f1 := dir + DirectorySeparator + 'data.bin';
    sylz := f1 + STREAM_SUFFIX;
    back := dir + DirectorySeparator + 'back.bin';
    SaveFile(f1, big, nBig);
    for pass := 0 to 1 do
    begin
      if pass = 0 then
      begin
        what := 'a stream';
        pw := '';
      end
      else
      begin
        what := 'an encrypted stream';
        pw := 'self-test';
      end;
      o := QuietOpts('c', [f1]);
      o.passwordInline := pw;
      if pass = 1 then
        o.flags := o.flags or SYLZ_ENTROPY;
      ok := RunQuiet(o) = EXIT_OK;
      o := QuietOpts('t', [sylz]);
      o.passwordInline := pw;
      ok := ok and (RunQuiet(o) = EXIT_OK);
      o := QuietOpts('d', [sylz]);
      o.passwordInline := pw;
      o.outPath := back;
      ok := ok and (RunQuiet(o) = EXIT_OK) and SameFile(back, big, nBig);
      Check(ok, Format('%s written, checked and read back (%d bytes, 3 blocks, 2 threads)',
        [what, nBig]));
      if pass = 1 then
      begin
        o := QuietOpts('t', [sylz]);
        o.passwordInline := 'another';
        r := RunQuiet(o);
        Check(r = EXIT_CORRUPT, 'the encrypted stream refuses another password');
      end;
      { one byte changed in the middle: refused }
      if LoadFile(sylz, big) > 1000 then
      begin
        k := LoadFile(sylz, big);
        big[k div 2] := big[k div 2] xor $10;
        SaveFile(sylz, big, k);
        o := QuietOpts('t', [sylz]);
        o.passwordInline := pw;
        r := RunQuiet(o);
        Check(r = EXIT_CORRUPT, what + ' with a changed byte is refused');
      end;
      nBig := LoadFile(f1, big);
    end;

    { an archive: two versions, the second with a changed file }
    sub := dir + DirectorySeparator + 'tree';
    ForceDirectories(sub + DirectorySeparator + 'inner');
    f2 := sub + DirectorySeparator + 'inner' + DirectorySeparator + 'binary.bin';
    SaveFile(sub + DirectorySeparator + 'text.txt', text, nText);
    SaveFile(f2, binary, nBinary);
    SaveFile(sub + DirectorySeparator + 'copy.txt', text, nText);
    SaveFile(sub + DirectorySeparator + 'empty', text, 0);
    for pass := 0 to 1 do
    begin
      if pass = 0 then
      begin
        what := 'an archive';
        pw := '';
      end
      else
      begin
        what := 'an encrypted archive';
        pw := 'self-test';
      end;
      arc := dir + DirectorySeparator + Format('test%d.syc', [pass]);
      outDir := dir + DirectorySeparator + Format('out%d', [pass]);
      SaveFile(f2, binary, nBinary);
      o := QuietOpts('a', [arc, 'tree']);
      o.cdDir := dir;
      o.blockMiB := 1;
      o.passwordInline := pw;
      ok := RunQuiet(o) = EXIT_OK;
      SaveFile(f2, binary, nBinary div 2);
      ok := ok and (RunQuiet(o) = EXIT_OK);
      o := QuietOpts('t', [arc]);
      o.passwordInline := pw;
      ok := ok and (RunQuiet(o) = EXIT_OK);
      o := QuietOpts('x', [arc]);
      o.outPath := outDir;
      o.passwordInline := pw;
      ok := ok and (RunQuiet(o) = EXIT_OK);
      outDir := outDir + DirectorySeparator + 'tree' + DirectorySeparator;
      ok := ok and SameFile(outDir + 'text.txt', text, nText)
        and SameFile(outDir + 'copy.txt', text, nText)
        and SameFile(outDir + 'empty', text, 0)
        and SameFile(outDir + 'inner' + DirectorySeparator + 'binary.bin', binary, nBinary div 2);
      { the first version }
      o.untilSpec := '1';
      o.outPath := dir + DirectorySeparator + Format('old%d', [pass]);
      ok := ok and (RunQuiet(o) = EXIT_OK)
        and SameFile(o.outPath + DirectorySeparator + 'tree' + DirectorySeparator + 'inner'
          + DirectorySeparator + 'binary.bin', binary, nBinary);
      Check(ok, what + ' of two versions written, checked and extracted (each version)');
    end;
  finally
    RemoveTree(dir);
  end;
end;

{ Runs every check; the code paths are left as they were. }
procedure SelfTest;
var
  text, binary, runs, noise, tiny: TBytes;
  keep: array[0..7] of Boolean;
  flags: Integer;
  p: Integer;
  paths: TPathSets;
  what: string;
begin
  keep[0] := SylzUseAsm;
  keep[1] := SylzPreferC;
  keep[2] := HufUseAsm;
  keep[3] := Blake2sUseC;
  keep[4] := CdcUseC;
  keep[5] := CryptoUseC;
  keep[6] := CrcUseC;
  keep[7] := HufPreferC;
  stPassed := 0;
  stFailed := 0;
  stPrefix := '';
  stSeed := 20261112;
  try
    text := MakeText(300000);
    binary := MakeBinary(160000);
    runs := MakeRuns(200000);
    noise := MakeRandom(70000);
    tiny := MakeText(13);
    for flags := 0 to 3 do   { SYLZ_ENTROPY, SYLZ_V4: formats 2 .. 5 }
    begin
      what := FormatName(flags);
      Phase('s: ' + what);
      CodecCase(what + ', text', text, 300000, flags);
      CodecCase(what + ', binary records', binary, 160000, flags);
      CodecCase(what + ', runs', runs, 200000, flags);
      CodecCase(what + ', noise', noise, 70000, flags);
      CodecCase(what + ', 13 bytes', tiny, 13, flags);
      CodecCase(what + ', one byte', tiny, 1, flags);
      CodecCase(what + ', nothing', tiny, 0, flags);
      DamageCase(what + ', text', text, 300000, 1, flags);
      DamageCase(what + ', binary records', binary, 160000, 6, flags);
    end;

    { the known answers, on each path }
    Phase('s: checksums, hashes, ciphers');
    paths := CodecPaths;
    for p := 0 to High(paths) do
    begin
      if (p > 0) and (paths[p].name = paths[p - 1].name) then
        Continue;
      if (paths[p].name = 'c') then
        Continue;   { hashes and ciphers have two paths: C and Pascal }
      SetCodePaths(paths[p].name);
      if paths[p].name = 'pascal' then
        stPrefix := 'Pascal: '
      else
        stPrefix := 'C: ';
      HashVectors(@Check);
      CryptoVectors(@Check);
    end;
    stPrefix := '';
    PathAgreement(text, 300000);

    SylzUseAsm := keep[0];
    SylzPreferC := keep[1];
    HufUseAsm := keep[2];
    Blake2sUseC := keep[3];
    CdcUseC := keep[4];
    CryptoUseC := keep[5];
    CrcUseC := keep[6];
    HufPreferC := keep[7];
    Phase('s: a stream and an archive');
    CommandsCase(text, binary, 300000, 160000);
  finally
    SylzUseAsm := keep[0];
    SylzPreferC := keep[1];
    HufUseAsm := keep[2];
    Blake2sUseC := keep[3];
    CdcUseC := keep[4];
    CryptoUseC := keep[5];
    CrcUseC := keep[6];
    HufPreferC := keep[7];
    stPrefix := '';
  end;
end;

function SelfTestSummary(startNs: UInt64): string;
begin
  if stFailed = 0 then
    Result := Format('ok: %d checks passed in %s', [stPassed, HumanTime((NowNs - startNs) / 1e9)])
  else
    Result := Format('FAILED: %d of %d checks failed', [stFailed, stPassed + stFailed]);
end;

function RunSelfTestCommand(const opts: TOptions): Integer;
var
  t0: UInt64;
begin
  stVerbosity := opts.verbosity;
  stSilent := False;
  t0 := NowNs;
  if opts.verbosity <> vQuiet then
    WriteLn(Paint(1, stHead, 'syc ' + SYC_VERSION + ' self-test'), ', paths built in: ', CodePathsBuilt);
  SelfTest;
  if stFailed = 0 then
  begin
    WriteLn(Paint(1, stOk, SelfTestSummary(t0)));
    Result := EXIT_OK;
  end
  else
  begin
    WriteLn(Paint(1, stErr, SelfTestSummary(t0)));
    WriteLn('Please report it: run "syc report" and open an issue at ', ISSUES_URL);
    Result := EXIT_FATAL;
  end;
end;

{ ── syc r ──────────────────────────────────────────────────────────────── }

{$ifdef darwin}
function sysctlbyname(name: PChar; oldp: Pointer; oldlenp: PSizeUInt; newp: Pointer;
  newlen: SizeUInt): LongInt; cdecl; external 'c' name 'sysctlbyname';
{$endif}

{$ifdef windows}
type
  TOsVersionInfoExW = record
    dwOSVersionInfoSize, dwMajorVersion, dwMinorVersion, dwBuildNumber, dwPlatformId: DWORD;
    szCSDVersion: array[0..127] of WideChar;
    wServicePackMajor, wServicePackMinor, wSuiteMask: Word;
    wProductType, wReserved: Byte;
  end;

  TMemoryStatusEx = record
    dwLength, dwMemoryLoad: DWORD;
    ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual,
      ullAvailVirtual, ullAvailExtendedVirtual: UInt64;
  end;

{ (GetVersionEx answers by the program's manifest; this one tells the truth) }
function RtlGetVersion(var info: TOsVersionInfoExW): LongInt; stdcall;
  external 'ntdll.dll' name 'RtlGetVersion';
function GlobalMemoryStatusEx(var status: TMemoryStatusEx): BOOL; stdcall;
  external 'kernel32.dll' name 'GlobalMemoryStatusEx';
{$endif}

{ the first line of a /proc file that starts with key, after its colon }
function ProcField(const path, key: string): string;
var
  f: TextFile;
  line: string;
begin
  Result := '';
  if not FileExists(path) then
    Exit;
  try
    AssignFile(f, path);
    Reset(f);
    try
      while not Eof(f) do
      begin
        ReadLn(f, line);
        if (Copy(line, 1, Length(key)) = key) and (Pos(':', line) > 0) then
        begin
          Result := Trim(Copy(line, Pos(':', line) + 1, MaxInt));
          Break;
        end;
      end;
    finally
      CloseFile(f);
    end;
  except
    Result := '';
  end;
end;

function SystemName: string;
{$ifdef windows}
var
  info: TOsVersionInfoExW;
begin
  FillChar(info, SizeOf(info), 0);
  info.dwOSVersionInfoSize := SizeOf(info);
  if RtlGetVersion(info) = 0 then
  begin
    Result := Format('Windows %d.%d build %d', [info.dwMajorVersion, info.dwMinorVersion,
      info.dwBuildNumber]);
    if info.wServicePackMajor > 0 then
      Result := Result + Format(' SP%d', [info.wServicePackMajor]);
  end
  else
    Result := 'Windows';
end;
{$else}
var
  u: UtsName;
begin
  if fpUname(u) = 0 then
    Result := Format('%s %s (%s)', [PChar(@u.sysname[0]), PChar(@u.release[0]), PChar(@u.machine[0])])
  else
    Result := 'unknown';
end;
{$endif}

function CpuName: string;
{$if defined(windows)}
var
  key: HKEY;
  buf: array[0..255] of WideChar;
  size, kind: DWORD;
begin
  Result := '';
  if RegOpenKeyExW(HKEY_LOCAL_MACHINE, 'HARDWARE\DESCRIPTION\System\CentralProcessor\0', 0,
    KEY_READ, key) = ERROR_SUCCESS then
  begin
    size := SizeOf(buf) - SizeOf(WideChar);
    FillChar(buf, SizeOf(buf), 0);
    if (RegQueryValueExW(key, 'ProcessorNameString', nil, @kind, @buf[0], @size) = ERROR_SUCCESS)
       and (kind = REG_SZ) then
      Result := Trim(UTF8Encode(UnicodeString(PWideChar(@buf[0]))));
    RegCloseKey(key);
  end;
end;
{$elseif defined(darwin)}
var
  buf: array[0..255] of Char;
  size: SizeUInt;
begin
  Result := '';
  size := SizeOf(buf) - 1;
  FillChar(buf, SizeOf(buf), 0);
  if sysctlbyname('machdep.cpu.brand_string', @buf[0], @size, nil, 0) = 0 then
    Result := Trim(PChar(@buf[0]));
end;
{$else}
begin
  Result := ProcField('/proc/cpuinfo', 'model name');
  if Result = '' then
    Result := ProcField('/proc/cpuinfo', 'Model');
  if Result = '' then
    Result := ProcField('/proc/cpuinfo', 'Hardware');
end;
{$endif}

{ the machine's memory in bytes; 0 when unknown }
function TotalMemory: Int64;
{$if defined(windows)}
var
  st: TMemoryStatusEx;
begin
  Result := 0;
  FillChar(st, SizeOf(st), 0);
  st.dwLength := SizeOf(st);
  if GlobalMemoryStatusEx(st) then
    Result := Int64(st.ullTotalPhys);
end;
{$elseif defined(darwin)}
var
  v: Int64;
  size: SizeUInt;
begin
  Result := 0;
  v := 0;
  size := SizeOf(v);
  if sysctlbyname('hw.memsize', @v, @size, nil, 0) = 0 then
    Result := v;
end;
{$else}
var
  s: string;
begin
  { "MemTotal:  263842216 kB" }
  s := ProcField('/proc/meminfo', 'MemTotal');
  if Pos(' ', s) > 0 then
    s := Copy(s, 1, Pos(' ', s) - 1);
  Result := StrToInt64Def(s, 0) * 1024;
end;
{$endif}

function YesNo(b: Boolean): string;
begin
  if b then
    Result := 'yes'
  else
    Result := 'no';
end;

{ the names (never the values: SYC_PASSWORD is one) of the variables that
  change what syc does }
function EnvNames: string;
var
  i, eq: Integer;
  s, name: string;
begin
  Result := '';
  for i := 1 to GetEnvironmentVariableCount do
  begin
    s := GetEnvironmentString(i);
    eq := Pos('=', s);
    if eq < 2 then
      Continue;
    name := Copy(s, 1, eq - 1);
    if (Copy(name, 1, 4) = 'SYC_') or (Copy(name, 1, 5) = 'SYLZ_') or (name = 'NO_COLOR') then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + name;
    end;
  end;
  if Result = '' then
    Result := 'none'
  else
    Result := Result + ' (set; values not shown)';
end;

function RunReportCommand(const opts: TOptions): Integer;
var
  t0: UInt64;
  cpu: string;
  mem: Int64;

  procedure Row(const what, value: string);
  begin
    WriteLn(Paint(1, stHead, Format('%-13s', [what])), value);
  end;

begin
  WriteLn(Paint(1, stHead, 'syc report'), ' (paste it whole into the issue: ', ISSUES_URL, ')');
  Row('version', 'syc ' + SYC_VERSION);
  Row('commit', Format('%s (%s)', [BUILD_COMMIT, BUILD_DATE]));
  Row('compiler', 'Free Pascal ' + BUILD_FPC);
  Row('target', BUILD_TARGET);
  Row('paths built', CodePathsBuilt);
  Row('paths in use', CodePathsInUse);
  Row('system', SystemName);
  cpu := CpuName;
  if cpu = '' then
    cpu := 'unknown';
  Row('cpu', Format('%s, %d thread(s)', [cpu, CpuCount]));
  mem := TotalMemory;
  if mem > 0 then
    Row('memory', Format('%.1f GiB', [mem / 1073741824]))
  else
    Row('memory', 'unknown');
  Row('terminal', Format('stdin %s, stdout %s, stderr %s; colours %s',
    [YesNo(IsTerminal(0)), YesNo(IsTerminal(1)), YesNo(IsTerminal(2)), YesNo(UseColor(1))]));
  Row('environment', EnvNames);
  { the self-test, only its result (syc s shows each check) }
  stVerbosity := vNormal;
  stSilent := opts.verbosity <> vVerbose;
  t0 := NowNs;
  SelfTest;
  stSilent := False;
  Row('self-test', SelfTestSummary(t0));
  if stFailed = 0 then
    Result := EXIT_OK
  else
  begin
    WriteLn('Run "syc s" for the checks that failed, and add its output.');
    Result := EXIT_FATAL;
  end;
end;

end.
