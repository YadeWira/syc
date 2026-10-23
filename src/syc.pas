{ syc — minimal command line, placeholder until the real CLI is designed.

  Compresses or decompresses one file with sylz. The container format below
  is provisional as well: it will change, and files written by this
  version are not expected to open with later ones.

    file   := "SYZ0" version:u8 level:u8 block*  end
              version 2 = sylz format v2 or v3 blocks (1: v2 only, also read)
    block  := rawLen:u32le packed:u32le crc32:u32le payload
              packed bit 31 set = payload stored raw, else a sylz block;
              the low 31 bits are the payload length
    end    := rawLen = 0 (4 zero bytes)

  crc32 is of the raw block, checked on decompression. }
program syc;

{$mode objfpc}{$H+}

uses
  {$ifdef windows}Windows,{$endif}
  SysUtils, Classes, Math, sylz;

const
  SYC_VERSION   = '0.2.12';
  MAGIC         = 'SYZ0';
  FORMAT_VER    = 2;   { 2: sylz v2 or v3 blocks; 1: v2 only (syc 0.2.2-0.2.4);
                         0 was sylz v1 (syc 0.2.0-0.2.1) }
  STORED_FLAG   = UInt32($80000000);
  PAYLOAD_MASK  = UInt32($7FFFFFFF);
  DEFAULT_BLOCK = 4 shl 20;
  MAX_BLOCK     = 512 shl 20;
  SUFFIX        = '.sylz';
  TMP_SUFFIX    = '.syc-partial';

var
  crcTable: array[0..255] of UInt32;

{ CRC-32 (IEEE, reflected, polynomial $EDB88320), as zlib's crc32. Here
  rather than FPC's crc unit, which the win64 RTL doesn't ship. }
procedure CrcInit;
var
  i, k: Integer;
  c: UInt32;
begin
  for i := 0 to 255 do
  begin
    c := i;
    for k := 1 to 8 do
      if c and 1 <> 0 then
        c := (c shr 1) xor $EDB88320
      else
        c := c shr 1;
    crcTable[i] := c;
  end;
end;

function crc32(crc: UInt32; p: PByte; n: SizeInt): UInt32;
var
  i: SizeInt;
begin
  crc := not crc;
  for i := 0 to n - 1 do
    crc := crcTable[(crc xor p[i]) and $FF] xor (crc shr 8);
  Result := not crc;
end;

procedure Usage;
begin
  WriteLn('syc ', SYC_VERSION, ' — sylz file compressor (minimal CLI, provisional format)');
  WriteLn;
  WriteLn('  syc c [-LEVEL] [-ec] [-b MIB] INPUT [OUTPUT]');
  WriteLn('                                           compress (default OUTPUT = INPUT', SUFFIX, ')');
  WriteLn('  syc d INPUT [OUTPUT]                     decompress (default OUTPUT = INPUT without ', SUFFIX, ')');
  WriteLn;
  WriteLn('  -LEVEL    0 (fastest) .. ', SYLZ_MAXLEVEL, ' (best ratio), default ', SYLZ_DEFLEVEL,
    ': 0-1 single hash, 2-3 two hashes, 4-8 hash chains, 9-10 optimal parsing');
  WriteLn('  -ec       extra compression: entropy-coded literals (sylz format v3,');
  WriteLn('            experimental), smaller, slower to decode; levels 0 .. ', SYLZ_EC_MAXLEVEL,
    ',');
  WriteLn('            level N parsing as -', SYLZ_EC_SHIFT, ' + N does');
  WriteLn('  -b MIB    block size in MiB, default ', DEFAULT_BLOCK shr 20);
end;

procedure Die(const msg: string);
begin
  WriteLn(StdErr, 'syc: ', msg);
  Halt(1);
end;

type
  { an error while compressing or decompressing: the main program deletes
    the partial output before reporting it }
  ESycError = class(Exception);

var
  tmpPath: string = '';   { the output being written, renamed when complete }
  report: string = '';    { printed once the output is in place }

procedure Fail(const msg: string);
begin
  raise ESycError.Create(msg);
end;

{ Moves the complete output over OUTPUT in one step, replacing it: rename
  does on Unix; on Windows it fails when OUTPUT exists, MoveFileEx doesn't. }
function ReplaceFile(const src, dst: string): Boolean;
begin
{$ifdef windows}
  Result := MoveFileEx(PChar(src), PChar(dst), MOVEFILE_REPLACE_EXISTING);
{$else}
  Result := RenameFile(src, dst);
{$endif}
end;

procedure WriteU32(s: TStream; v: UInt32);
begin
  v := NtoLE(v);
  s.WriteBuffer(v, 4);
end;

function ReadU32(s: TStream): UInt32;
begin
  s.ReadBuffer(Result, 4);
  Result := LEtoN(Result);
end;

{ Reads up to n bytes; fewer only at the end of the stream. }
function ReadFull(s: TStream; p: PByte; n: SizeInt): SizeInt;
var
  got: SizeInt;
begin
  Result := 0;
  while Result < n do
  begin
    got := s.Read(p[Result], n - Result);
    if got <= 0 then
      Break;
    Inc(Result, got);
  end;
end;

procedure Compress(const inPath, outPath: string; level, blockSize, flags: Integer);
var
  fin, fout: TFileStream;
  raw, packed_: PByte;
  ctx: TSylzCtx;
  n, c: SizeInt;
  hdr: array[0..5] of Byte;
  total, written: Int64;
begin
  fin := TFileStream.Create(inPath, fmOpenRead or fmShareDenyWrite);
  fout := nil;
  raw := GetMem(blockSize);
  packed_ := GetMem(SylzBound(blockSize));
  SylzCtxInit(ctx);
  try
    tmpPath := outPath + TMP_SUFFIX;
    fout := TFileStream.Create(tmpPath, fmCreate);
    Move(MAGIC[1], hdr[0], 4);
    if flags and SYLZ_ENTROPY <> 0 then
      hdr[4] := FORMAT_VER
    else
      hdr[4] := 1;   { readable by syc 0.2.2-0.2.4 }
    hdr[5] := Byte(level);
    fout.WriteBuffer(hdr, 6);
    total := 0;
    repeat
      n := ReadFull(fin, raw, blockSize);
      if n = 0 then
        Break;
      c := SylzCompressEx(ctx, raw, n, packed_, SylzBound(blockSize), level, flags);
      if c < 0 then
        Fail('internal error: compression failed');
      WriteU32(fout, UInt32(n));
      if c < n then
      begin
        WriteU32(fout, UInt32(c));
        WriteU32(fout, crc32(0, raw, n));
        fout.WriteBuffer(packed_^, c);
      end
      else
      begin
        WriteU32(fout, UInt32(n) or STORED_FLAG);
        WriteU32(fout, crc32(0, raw, n));
        fout.WriteBuffer(raw^, n);
      end;
      Inc(total, n);
    until n < blockSize;
    WriteU32(fout, 0);
    written := fout.Size;
    report := Format('%s: %d -> %d bytes (%.2f%%)',
      [inPath, total, written, written * 100.0 / Max(total, 1)]);
  finally
    SylzCtxFree(ctx);
    FreeMem(packed_);
    FreeMem(raw);
    fout.Free;
    fin.Free;
  end;
end;

procedure Decompress(const inPath, outPath: string);
var
  fin, fout: TFileStream;
  raw, payload: PByte;
  rawCap, payCap: SizeInt;
  rawLen, packedField, sum, payLen: UInt32;
  hdr: array[0..5] of Byte;
  total: Int64;
begin
  fin := TFileStream.Create(inPath, fmOpenRead or fmShareDenyWrite);
  fout := nil;
  raw := nil;
  payload := nil;
  rawCap := 0;
  payCap := 0;
  try
    if (ReadFull(fin, @hdr[0], 6) <> 6) or (CompareByte(hdr[0], MAGIC[1], 4) <> 0) then
      Fail(inPath + ': not a syc file');
    if (hdr[4] < 1) or (hdr[4] > FORMAT_VER) then
      Fail(Format('%s: format version %d not supported by syc %s', [inPath, hdr[4], SYC_VERSION]));
    tmpPath := outPath + TMP_SUFFIX;
    fout := TFileStream.Create(tmpPath, fmCreate);
    total := 0;
    while True do
    begin
      rawLen := ReadU32(fin);
      if rawLen = 0 then
        Break;
      packedField := ReadU32(fin);
      sum := ReadU32(fin);
      payLen := packedField and PAYLOAD_MASK;
      if (rawLen > MAX_BLOCK) or (payLen > MAX_BLOCK) then
        Fail(Format('%s: corrupt block header at output offset %d', [inPath, total]));
      if SizeInt(rawLen) > rawCap then
      begin
        FreeMem(raw);
        rawCap := rawLen;
        raw := GetMem(rawCap);
      end;
      if packedField and STORED_FLAG <> 0 then
      begin
        if payLen <> rawLen then
          Fail(Format('%s: corrupt block header at output offset %d', [inPath, total]));
        if ReadFull(fin, raw, rawLen) <> SizeInt(rawLen) then
          Fail(inPath + ': truncated');
      end
      else
      begin
        if SizeInt(payLen) > payCap then
        begin
          FreeMem(payload);
          payCap := payLen;
          payload := GetMem(payCap);
        end;
        if ReadFull(fin, payload, payLen) <> SizeInt(payLen) then
          Fail(inPath + ': truncated');
        if SylzDecompress(payload, payLen, raw, rawLen) <> SizeInt(rawLen) then
          Fail(Format('%s: corrupt data in the block at output offset %d', [inPath, total]));
      end;
      if crc32(0, raw, rawLen) <> sum then
        Fail(Format('%s: checksum mismatch in the block at output offset %d', [inPath, total]));
      fout.WriteBuffer(raw^, rawLen);
      Inc(total, rawLen);
    end;
    report := Format('%s: %d bytes', [outPath, total]);
  finally
    FreeMem(payload);
    FreeMem(raw);
    fout.Free;
    fin.Free;
  end;
end;

var
  cmd, inPath, outPath, arg: string;
  level, blockMiB, i, flags: Integer;
begin
  CrcInit;
  if ParamCount < 1 then
  begin
    Usage;
    Halt(1);
  end;
  cmd := ParamStr(1);
  if (cmd = '-h') or (cmd = '--help') or (cmd = 'h') then
  begin
    Usage;
    Exit;
  end;
  if (cmd = '-V') or (cmd = '--version') then
  begin
    WriteLn('syc ', SYC_VERSION);
    Exit;
  end;

  if (cmd <> 'c') and (cmd <> 'd') then
    Die('unknown command ' + cmd + ' (syc -h for help)');

  level := SYLZ_DEFLEVEL;
  flags := 0;
  blockMiB := DEFAULT_BLOCK shr 20;
  inPath := '';
  outPath := '';
  i := 2;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if arg = '-ec' then
      flags := flags or SYLZ_ENTROPY
    else if arg = '-b' then
    begin
      Inc(i);
      if (i > ParamCount) or not TryStrToInt(ParamStr(i), blockMiB)
         or (blockMiB < 1) or (blockMiB > MAX_BLOCK shr 20) then
        Die(Format('-b takes a size in MiB, 1..%d', [MAX_BLOCK shr 20]));
    end
    else if (Length(arg) > 1) and (arg[1] = '-') then
    begin
      if not TryStrToInt(Copy(arg, 2, MaxInt), level) or (level < SYLZ_MINLEVEL) or (level > SYLZ_MAXLEVEL) then
        Die(Format('unknown option %s (levels are -%d..-%d)', [arg, SYLZ_MINLEVEL, SYLZ_MAXLEVEL]));
    end
    else if inPath = '' then
      inPath := arg
    else if outPath = '' then
      outPath := arg
    else
      Die('too many arguments');
    Inc(i);
  end;
  if inPath = '' then
    Die('missing INPUT (syc -h for help)');
  if (flags and SYLZ_ENTROPY <> 0) and (level > SYLZ_EC_MAXLEVEL) then
    Die(Format('with -ec the levels are -%d..-%d', [SYLZ_MINLEVEL, SYLZ_EC_MAXLEVEL]));

  try
    if cmd = 'c' then
    begin
      if outPath = '' then
        outPath := inPath + SUFFIX;
      if SameFileName(ExpandFileName(inPath), ExpandFileName(outPath)) then
        Die('OUTPUT is INPUT');
      Compress(inPath, outPath, level, blockMiB shl 20, flags);
    end
    else if cmd = 'd' then
    begin
      if outPath = '' then
      begin
        if not SameText(ExtractFileExt(inPath), SUFFIX) then
          Die('INPUT has no ' + SUFFIX + ' suffix: give OUTPUT explicitly');
        outPath := ChangeFileExt(inPath, '');
      end;
      if SameFileName(ExpandFileName(inPath), ExpandFileName(outPath)) then
        Die('OUTPUT is INPUT');
      Decompress(inPath, outPath);
    end;
    { complete: replace OUTPUT. If that fails, the complete output stays
      under its temporary name, and OUTPUT as it was. }
    if not ReplaceFile(tmpPath, outPath) then
    begin
      arg := tmpPath;
      tmpPath := '';
      Fail('cannot replace ' + outPath + '; the output is in ' + arg);
    end;
    tmpPath := '';
    WriteLn(report);
  except
    on E: Exception do
    begin
      { no partial output left behind; an existing OUTPUT stays as it was }
      if tmpPath <> '' then
        DeleteFile(tmpPath);
      Die(E.Message);
    end;
  end;
end.
