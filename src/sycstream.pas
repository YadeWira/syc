{ sycstream — syc c / d / t: one file (or stdin) as a .sylz stream.

    stream := "SYZ0" 4 codec:u8 level:u8 block* end
              codec 1 = sylz (format v2 or v3 blocks), 2 = sylz (v4 or
              v5 blocks, frozen at syc 0.8.0); level is what the
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
  {$ifdef unix}BaseUnix,{$endif}
  SysUtils, Classes, Math, sylz, syccrypto, sycblocks, sycui, syccli, sycenc, sycarc;

{ runs syc c, d or t on every operand; returns the exit code }
function RunStreamCommand(const opts: TOptions): Integer;
{ path is a file that starts as a .sylz stream does }
function IsStreamFile(const path: string): Boolean;
{ syc i on a stream: its header and its blocks' sizes, read without
  decompressing (or a password); returns the exit code }
function StreamInfo(const opts: TOptions; const path: string): Integer;

implementation

const
  MAGIC        = 'SYZ0';
  FORMAT_VER   = 4;   { 4: a codec byte (syc 0.4.0-); 3: sylz v2 or v3
                        blocks, v3 chunks of mode 2 (syc 0.2.14-0.3.4); 2:
                        v3 chunks of mode 1 (syc 0.2.5-0.2.13); 1: v2 only
                        (syc 0.2.2-); 0 was sylz v1 (syc 0.2.0-0.2.1) }
  FORMAT_ENC1  = 5;   { 5: encrypted, syc 0.5.0-0.9.x (wiki: syc encryption) }
  FORMAT_ENC   = 6;   { 6: encrypted, a key record with its key check }
  CODEC_SYLZ   = 1;
  CODEC_SYLZ4  = 2;   { sylz blocks of formats v2 to v5 (syc 0.7.0-; 0.6.0 wrote an
                        earlier layout of v4/v5, which is not read) }
  STORED_FLAG  = UInt32($80000000);
  PAYLOAD_MASK = UInt32($7FFFFFFF);

type
  { seals (compressing) or opens (decompressing) the blocks of an
    encrypted stream (version 5 or 6), on each block's thread }
  TStreamSealer = class
    keys: TSycKeys;
    function Aad(job: TJob): TBytes;
    procedure SealJob(job: TJob);
    procedure OpenJob(job: TJob);
  end;

{ "SYZB", the block's position, rawLen, packed }
function TStreamSealer.Aad(job: TJob): TBytes;
var
  packedField: UInt32;
begin
  Result := nil;
  PutBytes(Result, 'SYZB');
  PutU64(Result, UInt64(job.tag));
  PutU32(Result, UInt32(job.n));
  packedField := UInt32(job.payLen);
  if job.stored then
    packedField := packedField or STORED_FLAG;
  PutU32(Result, packedField);
end;

{ after compressing: the payload (compressed, or the raw data when that
  is no smaller), sealed in place }
procedure TStreamSealer.SealJob(job: TJob);
begin
  job.stored := job.c >= job.n;
  if job.stored then
  begin
    Move(job.raw^, job.payload^, job.n);
    job.payLen := job.n;
  end
  else
    job.payLen := job.c;
  SealData(keys.aead, Aad(job), job.payload, job.payLen, @job.seal[0]);
end;

{ before decompressing: the payload checked and opened in place }
procedure TStreamSealer.OpenJob(job: TJob);
begin
  if not OpenData(keys.aead, Aad(job), job.payload, job.payLen, @job.seal[0]) then
  begin
    job.ok := False;
    job.failed := -1;   { the tag }
  end;
end;

{ the header's bytes, as the key record's AAD takes them }
{ The codec byte for what these flags write. }
function CodecOf(flags: Integer): Byte;
begin
  if flags and SYLZ_V4 <> 0 then
    Result := CODEC_SYLZ4
  else
    Result := CODEC_SYLZ;
end;

function StreamPrefix(version, codec, level: Byte): TBytes;
begin
  Result := nil;
  PutBytes(Result, MAGIC);
  SetLength(Result, 7);
  Result[4] := version;
  Result[5] := codec;
  Result[6] := level;
end;

{ Compresses fin to fout; returns the bytes read and written. With a
  password (-p...), stream version 5: encrypted. }
procedure Compress(fin, fout: TStream; const opts: TOptions; const name: string; prog: TProgress;
  out total, written: Int64);
var
  pipe: TPipeline;
  hdr, rec, pw, aad: TBytes;
  blockSize: SizeInt;
  blocks, b, slot: Int64;
  i: Integer;
  eof, enc: Boolean;
  sealer: TStreamSealer;
  seal: array[0..SEAL_SIZE - 1] of Byte;

  procedure WriteSlot(slot: Integer);
  var
    job: TJob;
  begin
    pipe.Finish(slot);
    job := pipe.jobs[slot];
    if not job.ok then
      Fail(EXIT_FATAL, 'out of memory');
    WriteU32(fout, UInt32(job.n));
    if enc then
    begin
      { rawLen, packed, crc32 = 0, nonce, the sealed payload, tag }
      if job.stored then
        WriteU32(fout, UInt32(job.payLen) or STORED_FLAG)
      else
        WriteU32(fout, UInt32(job.payLen));
      WriteU32(fout, 0);
      fout.WriteBuffer(job.seal[0], 24);
      fout.WriteBuffer(job.payload^, job.payLen);
      fout.WriteBuffer(job.seal[24], 16);
      Inc(written, 12 + SEAL_SIZE + job.payLen);
    end
    else if job.c < job.n then
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
  enc := EncryptionRequested(opts);
  blockSize := SizeInt(opts.blockMiB) shl 20;
  sealer := nil;
  pipe := TPipeline.Create(opts.threads, False, opts.level, opts.flags);
  try
    for i := 0 to pipe.Slots - 1 do
      pipe.jobs[i].Reserve(blockSize, SylzBound(blockSize));
    if enc then
    begin
      Phase('c: the key (Argon2id)');
      hdr := StreamPrefix(FORMAT_ENC, CodecOf(opts.flags), Byte(opts.level));
      pw := GetPassword(opts, True, name);
      sealer := TStreamSealer.Create;
      NewKeyRecord(hdr, pw, UInt32(opts.kdfMemMiB) * 1024, 0, sealer.keys, rec);
      Wipe(@pw[0], Length(pw));
      fout.WriteBuffer(hdr[0], Length(hdr));
      fout.WriteBuffer(rec[0], Length(rec));
      written := Length(hdr) + Length(rec);
      pipe.SetPre(nil, True);
      pipe.SetPost(@sealer.SealJob);
    end
    else
    begin
      hdr := StreamPrefix(FORMAT_VER, CodecOf(opts.flags), Byte(opts.level));
      fout.WriteBuffer(hdr[0], Length(hdr));
      written := Length(hdr);
    end;
    Phase('c: read, compress, write ' + name);
    total := 0;
    blocks := 0;
    eof := False;
    { block b goes to slot b mod Slots; before a slot takes a new block,
      its previous one (b - Slots) is written: blocks leave in order }
    while not eof do
    begin
      slot := blocks mod pipe.Slots;
      SetWhere(name, blocks, blocks * Int64(blockSize));
      if blocks >= pipe.Slots then
        WriteSlot(slot);
      pipe.jobs[slot].n := ReadFull(fin, pipe.jobs[slot].raw, blockSize);
      prog.Add(pipe.jobs[slot].n);
      if pipe.jobs[slot].n < blockSize then
        eof := True;
      if pipe.jobs[slot].n = 0 then
        Break;
      pipe.jobs[slot].tag := blocks;
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
    if enc then
    begin
      { the end, authenticated with the number of blocks }
      aad := nil;
      PutBytes(aad, 'SYZE');
      PutU64(aad, UInt64(blocks));
      SealData(sealer.keys.aead, aad, nil, 0, @seal[0]);
      fout.WriteBuffer(seal, SEAL_SIZE);
      Inc(written, SEAL_SIZE);
    end;
  finally
    pipe.Free;
    if sealer <> nil then
    begin
      WipeKeys(sealer.keys);
      sealer.Free;
    end;
  end;
end;

{ Decompresses fin to fout (nil: only checks it); returns the bytes
  written. name is fin's, for the messages. }
procedure Decompress(fin, fout: TStream; const opts: TOptions; const name: string; prog: TProgress;
  out total: Int64);
var
  pipe: TPipeline;
  job: TJob;
  rawLen, packedField, sum, payLen: UInt32;
  hdr: array[0..6] of Byte;
  prefix, rec, pw, aad: TBytes;
  seal: array[0..SEAL_SIZE - 1] of Byte;
  extra: Byte;
  at: Int64;
  blocks, b, slot: Int64;
  enc: Boolean;
  sealer: TStreamSealer;

  procedure WriteSlot(slot: Integer);
  var
    job: TJob;
  begin
    pipe.Finish(slot);
    job := pipe.jobs[slot];
    if not job.ok then
    begin
      if job.failed = -1 then
        Fail(EXIT_CORRUPT, Format('%s: the block at output offset %d does not authenticate '
          + '(changed, moved or from another stream)', [name, total]));
      if (hdr[4] >= 4) and (hdr[5] = CODEC_SYLZ4) then
        Fail(EXIT_CORRUPT, Format('%s: corrupt data or checksum mismatch in the block at output offset %d'
          + ' (or blocks of format v4/v5 written by syc 0.6.0, an earlier layout that'
          + ' later versions do not read)', [name, total]));
      Fail(EXIT_CORRUPT, Format('%s: corrupt data or checksum mismatch in the block at output offset %d',
        [name, total]));
    end;
    if fout <> nil then
      fout.WriteBuffer(job.raw^, job.n);
    Inc(total, job.n);
  end;

begin
  total := 0;
  if (ReadFull(fin, @hdr[0], 6) <> 6) or (CompareByte(hdr[0], MAGIC[1], 4) <> 0) then
    Fail(EXIT_CORRUPT, name + ': not a ' + STREAM_SUFFIX + ' stream');
  if (hdr[4] < 1) or (hdr[4] > FORMAT_ENC) then
    Fail(EXIT_CORRUPT, Format('%s: stream format version %d not supported by syc %s',
      [name, hdr[4], SYC_VERSION]));
  if (hdr[4] < FORMAT_ENC1) and EncryptionRequested(opts) then
    raise EInputUsage.Create(EXIT_USAGE, name + ': not encrypted, but a password was given');
  if (hdr[4] < FORMAT_ENC1) and PasswordInEnvironment then
    WriteLn(StdErr, WarnTag, name, ': not encrypted (SYC_PASSWORD was not used)');
  { version 4 and up: hdr[5] is the codec; the level byte follows }
  if hdr[4] >= 4 then
  begin
    if not (hdr[5] in [CODEC_SYLZ, CODEC_SYLZ4]) then
      Fail(EXIT_CORRUPT, Format('%s: codec %d not supported by syc %s', [name, hdr[5], SYC_VERSION]));
    if ReadFull(fin, @hdr[6], 1) <> 1 then
      Fail(EXIT_CORRUPT, name + ': truncated');
  end;
  enc := hdr[4] >= FORMAT_ENC1;
  sealer := nil;
  pipe := TPipeline.Create(opts.threads, True, 0, 0);
  try
    if enc then
    begin
      Phase('d: the key (Argon2id)');
      prefix := StreamPrefix(hdr[4], hdr[5], hdr[6]);
      if hdr[4] = FORMAT_ENC1 then
        SetLength(rec, KEYREC_SIZE_1)
      else
        SetLength(rec, KEYREC_SIZE);
      if ReadFull(fin, @rec[0], Length(rec)) <> Length(rec) then
        Fail(EXIT_CORRUPT, name + ': truncated');
      if (Length(rec) > 4) and (rec[4] <> 0) then
        Fail(EXIT_CORRUPT, name + ': damaged key record (flags)');
      pw := GetPassword(opts, False, name);
      sealer := TStreamSealer.Create;
      if not OpenKeyRecord(prefix, rec, pw, name, sealer.keys) then
        Fail(EXIT_CORRUPT, name + ': wrong password, or a damaged key record');
      Wipe(@pw[0], Length(pw));
      pipe.SetPre(@sealer.OpenJob, True);
    end;
    Phase('d: read, decompress ' + name);
    at := 0;
    blocks := 0;
    try
      while True do
      begin
        SetWhere(name, blocks, at);
        rawLen := ReadU32(fin);
        if rawLen = 0 then
          Break;
        packedField := ReadU32(fin);
        sum := ReadU32(fin);
        payLen := packedField and PAYLOAD_MASK;
        if (rawLen > MAX_BLOCK) or (payLen > MAX_BLOCK)
           or ((packedField and STORED_FLAG <> 0) and (payLen <> rawLen))
           or (enc and (sum <> 0)) then
          Fail(EXIT_CORRUPT, Format('%s: corrupt block header at output offset %d', [name, at]));
        slot := blocks mod pipe.Slots;
        if blocks >= pipe.Slots then
          WriteSlot(slot);
        job := pipe.jobs[slot];
        job.Reserve(rawLen, payLen);
        if enc and (ReadFull(fin, @job.seal[0], 24) <> 24) then
          Fail(EXIT_CORRUPT, name + ': truncated');
        if ReadFull(fin, job.payload, payLen) <> SizeInt(payLen) then
          Fail(EXIT_CORRUPT, name + ': truncated');
        if enc and (ReadFull(fin, @job.seal[24], 16) <> 16) then
          Fail(EXIT_CORRUPT, name + ': truncated');
        prog.Add(12 + payLen);
        job.n := rawLen;
        job.payLen := payLen;
        job.stored := packedField and STORED_FLAG <> 0;
        job.sum := sum;
        job.tag := blocks;
        Inc(at, rawLen);
        pipe.Start(slot);
        Inc(blocks);
      end;
      if enc then
      begin
        { the end: authenticated with the number of blocks, then nothing }
        if ReadFull(fin, @seal[0], SEAL_SIZE) <> SEAL_SIZE then
          Fail(EXIT_CORRUPT, name + ': truncated');
        aad := nil;
        PutBytes(aad, 'SYZE');
        PutU64(aad, UInt64(blocks));
        if not OpenData(sealer.keys.aead, aad, nil, 0, @seal[0]) then
          Fail(EXIT_CORRUPT, name + ': the end does not authenticate (cut, or blocks added)');
      end;
      { nothing follows the end (two streams joined with cat would
        otherwise decode as the first one alone) }
      if ReadFull(fin, @extra, 1) <> 0 then
        Fail(EXIT_CORRUPT, name + ': bytes after the end');
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
    if sealer <> nil then
    begin
      WipeKeys(sealer.keys);
      sealer.Free;
    end;
  end;
end;

{ --raw: the whole input (at most MAX_BLOCK bytes) as one bare sylz block,
  what SylzCompressEx returns (the zpaq-std plugins' compress()): no
  header, size or CRC. }
procedure CompressRaw(fin, fout: TStream; const opts: TOptions; const name: string;
  out total, written: Int64);
var
  src, dst: array of Byte;
  n, c: SizeInt;
  ctx: TSylzCtx;
begin
  { as big as the input, when its size is known (a pipe: grown as it
    comes, up to the limit) }
  if fin is TFileStream then
    n := Min(fin.Size, MAX_BLOCK) + 1
  else
    n := 1 shl 20;
  SetLength(src, n);
  n := ReadFull(fin, @src[0], Length(src));
  while (n = Length(src)) and (n <= MAX_BLOCK) do
  begin
    SetLength(src, Min(2 * Length(src), MAX_BLOCK + 1));
    Inc(n, ReadFull(fin, @src[n], Length(src) - n));
    if n < Length(src) then
      Break;
  end;
  if n > MAX_BLOCK then
    Fail(EXIT_USAGE, Format('%s: --raw takes at most %d MiB (one block)', [name, MAX_BLOCK shr 20]));
  SetLength(src, n + 1);
  SetLength(dst, SylzBound(n) + 1);
  SylzCtxInit(ctx);
  try
    c := SylzCompressEx(ctx, @src[0], n, @dst[0], Length(dst), opts.level, opts.flags);
  finally
    SylzCtxFree(ctx);
  end;
  if c < 0 then
    Fail(EXIT_FATAL, name + ': compression failed');
  fout.WriteBuffer(dst[0], c);
  total := n;
  written := c;
end;

{ --raw --size: one bare sylz block of size bytes decoded (fout nil: only
  checked) }
procedure DecompressRaw(fin, fout: TStream; const name: string; size: SizeInt; out total: Int64);
var
  src, dst: array of Byte;
  n: SizeInt;
begin
  { a block is at most SylzBound of what it decodes to }
  SetLength(src, SylzBound(size) + 2);
  n := ReadFull(fin, @src[0], Length(src));
  if n = Length(src) then
    Fail(EXIT_CORRUPT, Format('%s: longer than a block of %d bytes can be', [name, size]));
  SetLength(dst, size + 1);
  if SylzDecompress(@src[0], n, @dst[0], size) <> size then
    Fail(EXIT_CORRUPT, Format('%s: not a sylz block of %d bytes (corrupt, or another --size)',
      [name, size]));
  if fout <> nil then
    fout.WriteBuffer(dst[0], size);
  total := size;
end;

function EcNote(flags: Integer): string;
begin
  Result := Format(' (sylz format v%d)', [SylzFlagsFormat(flags)]);
  if flags and SYLZ_ENTROPY <> 0 then
    Result := ' -ec' + Result;
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
  arcPath, suffix: string;
  t0: UInt64;
  inSize: Int64;   { the input file's size; -1: stdin }
{$ifdef unix}
  st: Stat;
{$endif}
begin
  inSize := -1;
  Result := EXIT_OK;
  t0 := NowNs;
  written := 0;
  if opts.raw then
    suffix := RAW_SUFFIX
  else
    suffix := STREAM_SUFFIX;
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
        outPath := input + suffix
      else if SameText(ExtractFileExt(input), suffix) then
        outPath := ChangeFileExt(input, '')
      else
      begin
        WriteLn(StdErr, WarnTag, input, ': no ', suffix, ' suffix, skipped (give -o or -O)');
        Exit(EXIT_WARN);
      end;
      if not fromStdin and SameFileName(ExpandFileName(input), ExpandFileName(outPath)) then
        Fail(EXIT_USAGE, input + ': the output is the input');
      if DirectoryExists(outPath) then
      begin
        WriteLn(StdErr, WarnTag, outPath, ' is a directory, skipped');
        Exit(EXIT_WARN);
      end;
      if FileExists(outPath) and not opts.force then
      begin
        WriteLn(StdErr, WarnTag, outPath, ' exists, skipped (-f overwrites)');
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
            WriteLn(StdErr, WarnTag, input, ': cannot open, skipped');
            Exit(EXIT_WARN);
          end;
        end;
      if fin is TFileStream then
      begin
        inSize := fin.Size;
        prog := TProgress.Create(opts.progress, fin.Size);
      end
      else
        prog := TProgress.Create(opts.progress, 0);
      prog.title := ExtractFileName(inName);
      if toStdout then
        fout := StdStream(1)
      else if outPath <> '' then
      begin
        fout := CreateTemp(outPath, tmpPath);
      end;

      if opts.raw then
      begin
        if opts.cmd = 'c' then
          CompressRaw(fin, fout, opts, inName, total, written)
        else
          DecompressRaw(fin, fout, inName, opts.rawSize, total);
      end
      else if opts.cmd = 't' then
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
          Decompress(pre, nil, opts, inName, prog, total);
        finally
          pre.Free;
        end;
      end
      else if opts.cmd = 'c' then
        Compress(fin, fout, opts, inName, prog, total, written)
      else
        Decompress(fin, fout, opts, inName, prog, total);
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
{$ifdef unix}
      { the output gets the input's permissions, as gzip's and zstd's do
        (a private file stays private) }
      if not fromStdin and (fpStat(input, st) = 0) then
        fpChmod(tmpPath, st.st_mode and &7777);
{$endif}
      ForgetTemp(tmpPath);
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
        WriteLn(StdErr, WarnTag, input, ': cannot delete');
        Result := EXIT_WARN;
      end;

    ClearWhere;
    if opts.cmd = 'c' then
      StatAdd(total, written)
    else if inSize >= 0 then
      StatAdd(inSize, total)
    else
      StatAdd(0, total);
    if opts.verbosity <> vQuiet then
    begin
      case opts.cmd of
        'c': WriteLn(StdErr, Summary(2, mkOk, inName, [SizeChange(2, total, written),
               Elapsed(t0), SpeedSince(total, t0)]));
        'd': WriteLn(StdErr, Summary(2, mkOk, inName, [HumanSize(total), Elapsed(t0),
               SpeedSince(total, t0)]));
        't': WriteLn(StdErr, Summary(2, mkOk, inName, [Paint(2, stOk, 'ok'),
               HumanSize(total) + ' checked', Elapsed(t0), SpeedSince(total, t0)]));
      end;
      if (opts.cmd = 'c') and opts.raw then
        WriteLn(StdErr, Detail(2, [Format('one sylz block: decode with --raw --size %d', [total])]));
    end;
    if opts.verbosity = vVerbose then
    begin
      if (opts.cmd = 'c') and not opts.raw then
        WriteLn(StdErr, Detail(2, [Format('level %d%s', [opts.level, EcNote(opts.flags)]),
          Format('blocks of %d MiB', [opts.blockMiB]), Count(opts.threads, 'thread')]));
      if opts.cmd = 'c' then
        WriteLn(StdErr, Detail(2, [Format('%d bytes %s %d', [total, Arrow(2), written])]))
      else
        WriteLn(StdErr, Detail(2, [Format('%d bytes', [total])]));
    end;
  except
    { no partial output left behind; an existing output stays as it was }
    on E: Exception do
    begin
      if tmpPath <> '' then
      begin
        SysUtils.DeleteFile(tmpPath);
        ForgetTemp(tmpPath);
      end;
      if E is ESycError then
        raise;
      if E is EOutOfMemory then
        Fail(EXIT_FATAL, inName + ': out of memory');
      Fail(EXIT_FATAL, inName + ': ' + E.Message);
    end;
  end;
end;

{ ── syc i on a stream ──────────────────────────────────────────────────── }

function IsStreamFile(const path: string): Boolean;
var
  fs: TFileStream;
  m: array[0..3] of Byte;
begin
  Result := False;
  if (path = '-') or not FileExists(path) then
    Exit;
  try
    fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
    try
      Result := (ReadFull(fs, @m[0], 4) = 4) and (CompareByte(m[0], MAGIC[1], 4) = 0);
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

function StreamInfo(const opts: TOptions; const path: string): Integer;
var
  fs: TFileStream;
  hdr: array[0..6] of Byte;
  rec: array[0..KEYREC_SIZE - 1] of Byte;
  first: array[0..3] of Byte;
  rawLen, packedField, sum, payLen, gen, bestGen, memKiB: UInt32;
  blocks, nStored, raw, at, pos, extra: Int64;
  nFmt: array['2'..'5'] of Int64;   { blocks of each sylz format }
  c: Char;
  enc, pretty: Boolean;
  what, kind, codecWhat: string;
  i, recHead: Integer;

  procedure Need(p: Pointer; n: SizeInt);
  begin
    if ReadFull(fs, p, n) <> n then
      Fail(EXIT_CORRUPT, path + ': truncated');
  end;

  procedure Row(const name, value: string);
  begin
    WriteLn(Paint(1, stHead, Format('%-12s', [name])), value);
  end;

begin
  Result := EXIT_OK;
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    Need(@hdr[0], 6);
    if (hdr[4] < 1) or (hdr[4] > FORMAT_ENC) then
      Fail(EXIT_CORRUPT, Format('%s: stream format version %d not supported by syc %s',
        [path, hdr[4], SYC_VERSION]));
    { versions 1-3: "SYZ0", the version, the level; 4 and 5 have the codec
      between them }
    if hdr[4] >= 4 then
    begin
      if not (hdr[5] in [CODEC_SYLZ, CODEC_SYLZ4]) then
        Fail(EXIT_CORRUPT, Format('%s: codec %d not supported by syc %s', [path, hdr[5], SYC_VERSION]));
      Need(@hdr[6], 1);
    end
    else
      hdr[6] := hdr[5];
    enc := hdr[4] >= FORMAT_ENC1;
    extra := 0;
    codecWhat := 'codec sylz';
    if (hdr[4] >= 4) and (hdr[5] = CODEC_SYLZ4) then
      codecWhat := 'codec sylz (block formats v4 and v5)';
    if enc then
    begin
      { the key record: "SYCK", flags, then two slots; the one of the
        highest generation holds the current password's parameters }
      if hdr[4] = FORMAT_ENC1 then
        recHead := 8
      else
        recHead := 40;
      Need(@rec[0], recHead + 2 * SLOT_SIZE);
      bestGen := 0;
      memKiB := 0;
      for i := 0 to 1 do
      begin
        gen := LEtoN(PUInt32(@rec[recHead + i * SLOT_SIZE])^);
        if gen > bestGen then
        begin
          bestGen := gen;
          memKiB := LEtoN(PUInt32(@rec[recHead + i * SLOT_SIZE + 8])^);
        end;
      end;
      what := Format('encrypted (XChaCha20-Poly1305, key from Argon2id over %d MiB)',
        [memKiB shr 10]);
      extra := SEAL_SIZE;
    end
    else
      what := 'not encrypted';
    WriteLn(Paint(1, stHead, path), '  ', Joined(1, [STREAM_SUFFIX + ' stream',
      Format('format version %d', [hdr[4]]), codecWhat, Format('level %d', [hdr[6]]), what]));
    pretty := IsTerminal(1) and (opts.verbosity <> vVerbose);
    if opts.verbosity = vVerbose then
      WriteLn(Paint(1, stHead, '   block    at offset         raw      stored    ratio  kind'));

    blocks := 0;
    nStored := 0;
    for c := '2' to '5' do
      nFmt[c] := 0;
    raw := 0;
    while True do
    begin
      pos := fs.Position;
      SetWhere(path, blocks, pos);
      Need(@rawLen, 4);
      rawLen := LEtoN(rawLen);
      if rawLen = 0 then
        Break;
      Need(@packedField, 4);
      Need(@sum, 4);
      packedField := LEtoN(packedField);
      payLen := packedField and PAYLOAD_MASK;
      if (rawLen > MAX_BLOCK) or (payLen > MAX_BLOCK)
         or ((packedField and STORED_FLAG <> 0) and (payLen <> rawLen)) then
        Fail(EXIT_CORRUPT, Format('%s: corrupt block header at offset %d', [path, pos]));
      at := fs.Position;
      if at + extra + payLen > fs.Size then
        Fail(EXIT_CORRUPT, path + ': truncated');
      if packedField and STORED_FLAG <> 0 then
      begin
        kind := 'stored';
        Inc(nStored);
      end
      else if enc then
        kind := 'sylz'
      else
      begin
        { a sylz block says its format in its first u32 }
        kind := 'sylz v2';
        if payLen >= 4 then
        begin
          Need(@first[0], 4);
          kind := Format('sylz v%d', [SylzBlockFormat(@first[0], 4)]);
        end;
        Inc(nFmt[kind[Length(kind)]]);
      end;
      if opts.verbosity = vVerbose then
        WriteLn(Format('%8d %12d %11d %11d  %6.2f%%  %s',
          [blocks, pos, rawLen, payLen, payLen * 100.0 / rawLen, kind]));
      fs.Position := at + extra + payLen;
      Inc(raw, rawLen);
      Inc(blocks);
    end;
    ClearWhere;
    what := IntToStr(blocks);
    if enc then
      what := what + Format(' (%d stored; the others'' format shows once decrypted)', [nStored])
    else
    begin
      what := what + ' (';
      for c := '2' to '5' do
        if (nFmt[c] > 0) or ((c <= '3') and (nFmt['4'] + nFmt['5'] = 0)) then
          what := what + Format('%d sylz v%s, ', [nFmt[c], c]);
      what := what + Format('%d stored)', [nStored]);
    end;
    Row('blocks', what);
    if pretty then
    begin
      Row('raw size', Format('%s (%d bytes)', [HumanSize(raw), raw]));
      Row('stored size', Format('%s (%d bytes), %.2f%%', [HumanSize(fs.Size), fs.Size,
        fs.Size * 100.0 / Max(raw, 1)]));
    end
    else
    begin
      Row('raw size', Format('%d bytes', [raw]));
      Row('stored size', Format('%d bytes, %.2f%%', [fs.Size, fs.Size * 100.0 / Max(raw, 1)]));
    end;
    if opts.verbosity <> vQuiet then
      WriteLn(Paint(1, stDim, '(sizes as the headers give them; syc t checks the data)'));
  finally
    fs.Free;
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
        if (E.code = EXIT_USAGE) and not (E is EInputUsage) then
          raise;
        ShowError(E, E.code);
        r := E.code;
      end;
    end;
    Result := Max(Result, r);
  end;
end;

end.
