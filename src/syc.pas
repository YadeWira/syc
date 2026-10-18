{ syc — minimal command line, placeholder until the real CLI is designed.

  Compresses or decompresses one file with sylz. The container format below
  is provisional as well: it will change, and files written by this
  version are not expected to open with later ones.

    file   := "SYZ0" version:u8 level:u8 block*  end
    block  := rawLen:u32le packed:u32le crc32:u32le payload
              packed bit 31 set = payload stored raw, else a sylz block;
              the low 31 bits are the payload length
    end    := rawLen = 0 (4 zero bytes)

  crc32 is of the raw block, checked on decompression. }
program syc;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math, sylz;

const
  SYC_VERSION   = '0.2.0';
  MAGIC         = 'SYZ0';
  FORMAT_VER    = 0;
  STORED_FLAG   = UInt32($80000000);
  DEFAULT_BLOCK = 4 shl 20;
  MAX_BLOCK     = 512 shl 20;
  SUFFIX        = '.sylz';

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
  WriteLn('  syc c [-LEVEL] [-b MIB] INPUT [OUTPUT]   compress (default OUTPUT = INPUT', SUFFIX, ')');
  WriteLn('  syc d INPUT [OUTPUT]                     decompress (default OUTPUT = INPUT without ', SUFFIX, ')');
  WriteLn;
  WriteLn('  -LEVEL  1 (fast, default) .. ', SYLZ_MAXLEVEL, ' (best)');
  WriteLn('  -b MIB  block size in MiB, default ', DEFAULT_BLOCK shr 20);
end;

procedure Die(const msg: string);
begin
  WriteLn(StdErr, 'syc: ', msg);
  Halt(1);
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

procedure Compress(const inPath, outPath: string; level, blockSize: Integer);
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
    fout := TFileStream.Create(outPath, fmCreate);
    Move(MAGIC[1], hdr[0], 4);
    hdr[4] := FORMAT_VER;
    hdr[5] := Byte(level);
    fout.WriteBuffer(hdr, 6);
    total := 0;
    repeat
      n := ReadFull(fin, raw, blockSize);
      if n = 0 then
        Break;
      c := SylzCompressCtx(ctx, raw, n, packed_, SylzBound(blockSize), level);
      if c < 0 then
        Die('internal error: compression failed');
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
    WriteLn(Format('%s: %d -> %d bytes (%.2f%%)',
      [inPath, total, written, written * 100.0 / Max(total, 1)]));
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
      Die(inPath + ': not a syc file');
    if hdr[4] <> FORMAT_VER then
      Die(Format('%s: format version %d not supported by syc %s', [inPath, hdr[4], SYC_VERSION]));
    fout := TFileStream.Create(outPath, fmCreate);
    total := 0;
    while True do
    begin
      rawLen := ReadU32(fin);
      if rawLen = 0 then
        Break;
      packedField := ReadU32(fin);
      sum := ReadU32(fin);
      payLen := packedField and not STORED_FLAG;
      if (rawLen > MAX_BLOCK) or (payLen > MAX_BLOCK) then
        Die(inPath + ': corrupt block header');
      if SizeInt(rawLen) > rawCap then
      begin
        FreeMem(raw);
        rawCap := rawLen;
        raw := GetMem(rawCap);
      end;
      if packedField and STORED_FLAG <> 0 then
      begin
        if payLen <> rawLen then
          Die(inPath + ': corrupt block header');
        if ReadFull(fin, raw, rawLen) <> SizeInt(rawLen) then
          Die(inPath + ': truncated');
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
          Die(inPath + ': truncated');
        if SylzDecompress(payload, payLen, raw, rawLen) <> SizeInt(rawLen) then
          Die(Format('%s: corrupt data at offset %d', [inPath, total]));
      end;
      if crc32(0, raw, rawLen) <> sum then
        Die(Format('%s: checksum mismatch at offset %d', [inPath, total]));
      fout.WriteBuffer(raw^, rawLen);
      Inc(total, rawLen);
    end;
    WriteLn(Format('%s: %d bytes', [outPath, total]));
  finally
    FreeMem(payload);
    FreeMem(raw);
    fout.Free;
    fin.Free;
  end;
end;

var
  cmd, inPath, outPath, arg: string;
  level, blockMiB, i: Integer;
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

  level := 1;
  blockMiB := DEFAULT_BLOCK shr 20;
  inPath := '';
  outPath := '';
  i := 2;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if arg = '-b' then
    begin
      Inc(i);
      if (i > ParamCount) or not TryStrToInt(ParamStr(i), blockMiB)
         or (blockMiB < 1) or (blockMiB > MAX_BLOCK shr 20) then
        Die(Format('-b takes a size in MiB, 1..%d', [MAX_BLOCK shr 20]));
    end
    else if (Length(arg) > 1) and (arg[1] = '-') then
    begin
      if not TryStrToInt(Copy(arg, 2, MaxInt), level) or (level < 1) or (level > SYLZ_MAXLEVEL) then
        Die(Format('unknown option %s (levels are -1..-%d)', [arg, SYLZ_MAXLEVEL]));
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

  try
    if cmd = 'c' then
    begin
      if outPath = '' then
        outPath := inPath + SUFFIX;
      Compress(inPath, outPath, level, blockMiB shl 20);
    end
    else if cmd = 'd' then
    begin
      if outPath = '' then
      begin
        if not SameText(ExtractFileExt(inPath), SUFFIX) then
          Die('INPUT has no ' + SUFFIX + ' suffix: give OUTPUT explicitly');
        outPath := ChangeFileExt(inPath, '');
      end;
      Decompress(inPath, outPath);
    end
    else
      Die('unknown command ' + cmd + ' (syc -h for help)');
  except
    on E: EStreamError do
      Die(E.Message);
    on E: EInOutError do
      Die(E.Message);
  end;
end.
