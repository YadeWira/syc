{ sycstream — syc c / d / t: one file (or stdin) as a .sylz stream.

    stream := "SYZ0" 4 codec:u8 level:u8 block* end
              codec 1 = sylz (format v2 or v3 blocks); level is what the
              writer used, for information. Versions 1-3 (syc 0.2.2-0.3.4)
              have no codec byte and are read too: 3 = v2 or v3 blocks, 2 =
              v3 literal chunks with three stream sizes, 1 = v2 only.
    block  := rawLen:u32le packed:u32le crc32:u32le payload
              packed bit 31 set = payload stored raw, else a sylz block;
              the low 31 bits are the payload length
    end    := rawLen = 0 (4 zero bytes)

  crc32 is of the raw block, checked on decompression. Frozen at syc
  0.4.0 (wiki: syc stream format). }
unit sycstream;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, sylz, sycblocks, syccli, sycarc;

{ runs syc c, d or t on every operand; returns the exit code }
function RunStreamCommand(const opts: TOptions): Integer;

implementation

const
  MAGIC        = 'SYZ0';
  FORMAT_VER   = 4;   { 4: a codec byte (syc 0.4.0-); 3: sylz v2 or v3
                        blocks, v3 chunks of mode 2 (syc 0.2.14-0.3.4); 2:
                        v3 chunks of mode 1 (syc 0.2.5-0.2.13); 1: v2 only
                        (syc 0.2.2-); 0 was sylz v1 (syc 0.2.0-0.2.1) }
  CODEC_SYLZ   = 1;
  STORED_FLAG  = UInt32($80000000);
  PAYLOAD_MASK = UInt32($7FFFFFFF);

{ Compresses fin to fout; returns the bytes read and written. }
procedure Compress(fin, fout: TStream; const opts: TOptions; prog: TProgress; out total, written: Int64);
var
  pipe: TPipeline;
  hdr: array[0..6] of Byte;
  blockSize: SizeInt;
  blocks, b, slot: Int64;
  i: Integer;
  eof: Boolean;

  procedure WriteSlot(slot: Integer);
  var
    job: TJob;
  begin
    pipe.Finish(slot);
    job := pipe.jobs[slot];
    if not job.ok then
      Fail(EXIT_FATAL, 'out of memory');
    WriteU32(fout, UInt32(job.n));
    if job.c < job.n then
    begin
      WriteU32(fout, UInt32(job.c));
      WriteU32(fout, job.crc);
      fout.WriteBuffer(job.payload^, job.c);
      Inc(written, 12 + job.c);
    end
    else
    begin
      WriteU32(fout, UInt32(job.n) or STORED_FLAG);
      WriteU32(fout, job.crc);
      fout.WriteBuffer(job.raw^, job.n);
      Inc(written, 12 + job.n);
    end;
    Inc(total, job.n);
  end;

begin
  blockSize := SizeInt(opts.blockMiB) shl 20;
  pipe := TPipeline.Create(opts.threads, False, opts.level, opts.flags);
  try
    for i := 0 to pipe.Slots - 1 do
      pipe.jobs[i].Reserve(blockSize, SylzBound(blockSize));
    Move(MAGIC[1], hdr[0], 4);
    hdr[4] := FORMAT_VER;
    hdr[5] := CODEC_SYLZ;
    hdr[6] := Byte(opts.level);
    fout.WriteBuffer(hdr, 7);
    total := 0;
    written := 7;
    blocks := 0;
    eof := False;
    { block b goes to slot b mod Slots; before a slot takes a new block,
      its previous one (b - Slots) is written: blocks leave in order }
    while not eof do
    begin
      slot := blocks mod pipe.Slots;
      if blocks >= pipe.Slots then
        WriteSlot(slot);
      pipe.jobs[slot].n := ReadFull(fin, pipe.jobs[slot].raw, blockSize);
      prog.Add(pipe.jobs[slot].n);
      if pipe.jobs[slot].n < blockSize then
        eof := True;
      if pipe.jobs[slot].n = 0 then
        Break;
      pipe.Start(slot);
      Inc(blocks);
    end;
    { the blocks still in flight }
    b := Max(blocks - pipe.Slots, 0);
    while b < blocks do
    begin
      WriteSlot(b mod pipe.Slots);
      Inc(b);
    end;
    WriteU32(fout, 0);
    Inc(written, 4);
  finally
    pipe.Free;
  end;
end;

{ Decompresses fin to fout (nil: only checks it); returns the bytes
  written. name is fin's, for the messages. }
procedure Decompress(fin, fout: TStream; const name: string; threads: Integer; prog: TProgress;
  out total: Int64);
var
  pipe: TPipeline;
  job: TJob;
  rawLen, packedField, sum, payLen: UInt32;
  hdr: array[0..6] of Byte;
  at: Int64;
  blocks, b, slot: Int64;

  procedure WriteSlot(slot: Integer);
  var
    job: TJob;
  begin
    pipe.Finish(slot);
    job := pipe.jobs[slot];
    if not job.ok then
      Fail(EXIT_CORRUPT, Format('%s: corrupt data or checksum mismatch in the block at output offset %d',
        [name, total]));
    if fout <> nil then
      fout.WriteBuffer(job.raw^, job.n);
    Inc(total, job.n);
  end;

begin
  total := 0;
  if (ReadFull(fin, @hdr[0], 6) <> 6) or (CompareByte(hdr[0], MAGIC[1], 4) <> 0) then
    Fail(EXIT_CORRUPT, name + ': not a ' + STREAM_SUFFIX + ' stream');
  if (hdr[4] < 1) or (hdr[4] > FORMAT_VER) then
    Fail(EXIT_CORRUPT, Format('%s: stream format version %d not supported by syc %s',
      [name, hdr[4], SYC_VERSION]));
  { version 4: hdr[5] is the codec; the level byte follows }
  if hdr[4] >= 4 then
  begin
    if hdr[5] <> CODEC_SYLZ then
      Fail(EXIT_CORRUPT, Format('%s: codec %d not supported by syc %s', [name, hdr[5], SYC_VERSION]));
    if ReadFull(fin, @hdr[6], 1) <> 1 then
      Fail(EXIT_CORRUPT, name + ': truncated');
  end;
  pipe := TPipeline.Create(threads, True, 0, 0);
  try
    at := 0;
    blocks := 0;
    try
      while True do
      begin
        rawLen := ReadU32(fin);
        if rawLen = 0 then
          Break;
        packedField := ReadU32(fin);
        sum := ReadU32(fin);
        payLen := packedField and PAYLOAD_MASK;
        if (rawLen > MAX_BLOCK) or (payLen > MAX_BLOCK)
           or ((packedField and STORED_FLAG <> 0) and (payLen <> rawLen)) then
          Fail(EXIT_CORRUPT, Format('%s: corrupt block header at output offset %d', [name, at]));
        slot := blocks mod pipe.Slots;
        if blocks >= pipe.Slots then
          WriteSlot(slot);
        job := pipe.jobs[slot];
        job.Reserve(rawLen, payLen);
        if ReadFull(fin, job.payload, payLen) <> SizeInt(payLen) then
          Fail(EXIT_CORRUPT, name + ': truncated');
        prog.Add(12 + payLen);
        job.n := rawLen;
        job.payLen := payLen;
        job.stored := packedField and STORED_FLAG <> 0;
        job.sum := sum;
        Inc(at, rawLen);
        pipe.Start(slot);
        Inc(blocks);
      end;
    except
      on EReadError do
        Fail(EXIT_CORRUPT, name + ': truncated');
    end;
    b := Max(blocks - pipe.Slots, 0);
    while b < blocks do
    begin
      WriteSlot(b mod pipe.Slots);
      Inc(b);
    end;
  finally
    pipe.Free;
  end;
end;

{ One operand. Returns its exit code; a usage error is raised instead. }
function RunOne(const opts: TOptions; const input: string): Integer;
var
  fromStdin, toStdout: Boolean;
  inName, outPath, tmpPath, keep: string;
  fin, fout, pre: TStream;
  prog: TProgress;
  total, written: Int64;
  magic: array of Byte;
  got: SizeInt;
  arcPath: string;
begin
  Result := EXIT_OK;
  SetLength(magic, 4);
  fromStdin := (input = '') or (input = '-');
  if fromStdin then
    inName := '(stdin)'
  else
    inName := input;

  if fromStdin and IsTerminal(0) and not opts.force then
    Fail(EXIT_USAGE, 'no input: stdin is a terminal (give a FILE)');

  { where the output goes }
  outPath := '';
  toStdout := False;
  if opts.cmd <> 't' then
  begin
    toStdout := opts.toStdout or (fromStdin and (opts.outPath = ''));
    if not toStdout then
    begin
      if opts.outPath <> '' then
        outPath := opts.outPath
      else if opts.cmd = 'c' then
        outPath := input + STREAM_SUFFIX
      else if SameText(ExtractFileExt(input), STREAM_SUFFIX) then
        outPath := ChangeFileExt(input, '')
      else
      begin
        WriteLn(StdErr, 'syc: ', input, ': no ', STREAM_SUFFIX, ' suffix, skipped (give -o or -O)');
        Exit(EXIT_WARN);
      end;
      if not fromStdin and SameFileName(ExpandFileName(input), ExpandFileName(outPath)) then
        Fail(EXIT_USAGE, input + ': the output is the input');
      if FileExists(outPath) and not opts.force then
      begin
        WriteLn(StdErr, 'syc: ', outPath, ' exists, skipped (-f overwrites)');
        Exit(EXIT_WARN);
      end;
    end
    else if (opts.cmd = 'c') and IsTerminal(1) and not opts.force then
      Fail(EXIT_USAGE, 'compressed data not written to a terminal (-f forces it)');
  end;

  fin := nil;
  fout := nil;
  prog := nil;
  tmpPath := '';
  try
    try
      if fromStdin then
        fin := StdStream(0)
      else
        try
          fin := TFileStream.Create(input, fmOpenRead or fmShareDenyWrite);
        except
          on E: EFOpenError do
          begin
            WriteLn(StdErr, 'syc: ', input, ': cannot open, skipped');
            Exit(EXIT_WARN);
          end;
        end;
      if fin is TFileStream then
        prog := TProgress.Create(opts.progress, fin.Size)
      else
        prog := TProgress.Create(opts.progress, 0);
      if toStdout then
        fout := StdStream(1)
      else if outPath <> '' then
      begin
        tmpPath := outPath + TMP_SUFFIX;
        fout := TFileStream.Create(tmpPath, fmCreate);
      end;

      if opts.cmd = 't' then
      begin
        { an archive or a stream: by the first 4 bytes }
        got := ReadFull(fin, @magic[0], 4);
        if (got = 4) and (CompareByte(magic[0], 'SYCA', 4) = 0) then
        begin
          if fromStdin then
          begin
            tmpPath := SpoolToTemp(magic, fin);
            arcPath := tmpPath;
          end
          else
            arcPath := input;
          FreeAndNil(fin);
          try
            Result := TestArchive(opts, arcPath, inName);
          finally
            if fromStdin then
            begin
              SysUtils.DeleteFile(tmpPath);
              tmpPath := '';
            end;
          end;
          Exit;
        end;
        pre := TPrefixStream.Create(Copy(magic, 0, got), fin);
        try
          Decompress(pre, nil, inName, opts.threads, prog, total);
        finally
          pre.Free;
        end;
      end
      else if opts.cmd = 'c' then
        Compress(fin, fout, opts, prog, total, written)
      else
        Decompress(fin, fout, inName, opts.threads, prog, total);
    finally
      if prog <> nil then
        prog.Finish;
      FreeAndNil(prog);
      fout.Free;
      fin.Free;
    end;

    { complete: replace the output. If that fails, the complete output
      stays under its temporary name, and the output as it was. }
    if tmpPath <> '' then
    begin
      if not ReplaceFile(tmpPath, outPath) then
      begin
        keep := tmpPath;
        tmpPath := '';
        Fail(EXIT_FATAL, 'cannot replace ' + outPath + '; the output is in ' + keep);
      end;
      tmpPath := '';
    end;
    if opts.removeInput and not fromStdin and not toStdout and (opts.cmd <> 't') then
      if not SysUtils.DeleteFile(input) then
      begin
        WriteLn(StdErr, 'syc: ', input, ': cannot delete');
        Result := EXIT_WARN;
      end;

    if opts.verbosity <> vQuiet then
      case opts.cmd of
        'c': WriteLn(StdErr, Format('%s: %d -> %d bytes (%.2f%%)',
               [inName, total, written, written * 100.0 / Max(total, 1)]));
        'd': WriteLn(StdErr, Format('%s: %d bytes', [inName, total]));
        't': WriteLn(StdErr, Format('%s: ok, %d bytes', [inName, total]));
      end;
  except
    { no partial output left behind; an existing output stays as it was }
    on E: Exception do
    begin
      if tmpPath <> '' then
        SysUtils.DeleteFile(tmpPath);
      if E is ESycError then
        raise;
      if E is EOutOfMemory then
        Fail(EXIT_FATAL, inName + ': out of memory');
      Fail(EXIT_FATAL, inName + ': ' + E.Message);
    end;
  end;
end;

function RunStreamCommand(const opts: TOptions): Integer;
var
  inputs: array of string;
  i, r: Integer;
begin
  inputs := opts.operands;
  if Length(inputs) = 0 then
    inputs := ['-'];
  Result := EXIT_OK;
  for i := 0 to High(inputs) do
  begin
    try
      r := RunOne(opts, inputs[i]);
    except
      on E: ESycError do
      begin
        if E.code = EXIT_USAGE then
          raise;
        WriteLn(StdErr, 'syc: ', E.Message);
        r := E.code;
      end;
    end;
    Result := Max(Result, r);
  end;
end;

end.
