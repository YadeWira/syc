{ syc — minimal command line, placeholder until the real CLI is designed.

  Compresses or decompresses one file with sylz. The container format below
  is provisional as well: it will change, and files written by this
  version are not expected to open with later ones.

    file   := "SYZ0" version:u8 level:u8 block*  end
              version 3 = sylz format v2 or v3 blocks, v3 literal chunks
              with four stream sizes; 2: the same with three (syc
              0.2.5-0.2.13); 1: v2 only. All read.
    block  := rawLen:u32le packed:u32le crc32:u32le payload
              packed bit 31 set = payload stored raw, else a sylz block;
              the low 31 bits are the payload length
    end    := rawLen = 0 (4 zero bytes)

  crc32 is of the raw block, checked on decompression. }
program syc;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  {$ifdef windows}Windows,{$endif}
  SysUtils, Classes, Math, sylz;

const
  SYC_VERSION   = '0.2.14';
  MAGIC         = 'SYZ0';
  FORMAT_VER    = 3;   { 3: sylz v2 or v3 blocks, v3 chunks of mode 2 (syc
                         0.2.14-); 2: v3 chunks of mode 1 (syc 0.2.5-0.2.13);
                         1: v2 only (syc 0.2.2-); 0 was sylz v1 (syc
                         0.2.0-0.2.1) }
  STORED_FLAG   = UInt32($80000000);
  PAYLOAD_MASK  = UInt32($7FFFFFFF);
  DEFAULT_BLOCK = 4 shl 20;
  MAX_BLOCK     = 512 shl 20;
  SUFFIX        = '.sylz';
  TMP_SUFFIX    = '.syc-partial';
  MAX_THREADS   = 64;

var
  crcTable: array[0..7, 0..255] of UInt32;

{ CRC-32 (IEEE, reflected, polynomial $EDB88320), as zlib's crc32. Here
  rather than FPC's crc unit, which the win64 RTL doesn't ship. Slicing by
  8: eight tables, eight bytes a step (one byte a step ran at a few
  hundred MB/s and held syc's fast levels back). }
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
    crcTable[0, i] := c;
  end;
  for i := 0 to 255 do
    for k := 1 to 7 do
      crcTable[k, i] := (crcTable[k - 1, i] shr 8) xor crcTable[0, crcTable[k - 1, i] and $FF];
end;

{$ifndef SYLZ_PUREPASCAL}
{ sylzc.o comes linked with the sylz unit }
function sylzc_crc32(crc: UInt32; p: PByte; n: SizeInt; tables: PUInt32): UInt32;
  cdecl; external name 'sylzc_crc32';
{$endif}

function crc32(crc: UInt32; p: PByte; n: SizeInt): UInt32;
var
  a, b: UInt32;
begin
{$ifndef SYLZ_PUREPASCAL}
  { the C version (sylzc.c), same results: FPC ran this loop at ~1.2 GB/s }
  Exit(sylzc_crc32(crc, p, n, @crcTable[0, 0]));
{$endif}
  crc := not crc;
  while n >= 8 do
  begin
    a := (p[0] or (UInt32(p[1]) shl 8) or (UInt32(p[2]) shl 16) or (UInt32(p[3]) shl 24)) xor crc;
    b := p[4] or (UInt32(p[5]) shl 8) or (UInt32(p[6]) shl 16) or (UInt32(p[7]) shl 24);
    crc := crcTable[7, a and $FF] xor crcTable[6, (a shr 8) and $FF]
       xor crcTable[5, (a shr 16) and $FF] xor crcTable[4, a shr 24]
       xor crcTable[3, b and $FF] xor crcTable[2, (b shr 8) and $FF]
       xor crcTable[1, (b shr 16) and $FF] xor crcTable[0, b shr 24];
    Inc(p, 8);
    Dec(n, 8);
  end;
  while n > 0 do
  begin
    crc := crcTable[0, (crc xor p^) and $FF] xor (crc shr 8);
    Inc(p);
    Dec(n);
  end;
  Result := not crc;
end;

procedure Usage;
begin
  WriteLn('syc ', SYC_VERSION, ' — sylz file compressor (minimal CLI, provisional format)');
  WriteLn;
  WriteLn('  syc c [-LEVEL] [-ec] [-b MIB] [-th N] INPUT [OUTPUT]');
  WriteLn('                                           compress (default OUTPUT = INPUT', SUFFIX, ')');
  WriteLn('  syc d [-th N] INPUT [OUTPUT]             decompress (default OUTPUT = INPUT without ', SUFFIX, ')');
  WriteLn;
  WriteLn('  -LEVEL    0 (fastest) .. ', SYLZ_MAXLEVEL, ' (best ratio), default ', SYLZ_DEFLEVEL,
    ': 0-1 single hash, 2-3 two hashes, 4-8 hash chains, 9-10 optimal parsing');
  WriteLn('  -ec       extra compression: entropy-coded literals (sylz format v3,');
  WriteLn('            experimental), smaller, slower to decode; levels 0 .. ', SYLZ_EC_MAXLEVEL,
    ':');
  WriteLn('            0-8 parse as -', SYLZ_EC_SHIFT, ' .. -', SYLZ_MAXLEVEL,
    ' do, 9-10 price literals by their Huffman codes');
  WriteLn('  -b MIB    block size in MiB, default ', DEFAULT_BLOCK shr 20);
  WriteLn('  -th N     threads, default 1: blocks are compressed and decompressed');
  WriteLn('            N at a time (the output is the same whatever N)');
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

{ ── blocks, compressed or decompressed N at a time ────────────────────── }

type
  { One block's work, done by a worker thread (or the main one with -th 1).
    Compress: raw[0..n) -> packed[0..c) and its crc. Decompress: payload
    (stored or a sylz block) -> raw[0..n), checked against sum. }
  TJob = class
    raw, payload: PByte;
    rawCap, payCap: SizeInt;
    n, c, payLen: SizeInt;
    stored: Boolean;
    sum, crc: UInt32;
    ok: Boolean;
    ctx: TSylzCtx;
    dctx: TSylzDCtx;
    constructor Create;
    destructor Destroy; override;
    procedure Reserve(rawSize, paySize: SizeInt);
    procedure DoCompress(level, flags: Integer);
    procedure DoDecompress;
  end;

  { A pipeline of 2N slots: slot k is worked on by thread k mod N, so each
    thread takes its two slots in turn, while the main thread reads the
    next blocks into free slots and writes finished ones in order. Workers
    never wait for a whole batch, so they stay busy: with batches, the
    decode threads worked in bursts of ~1 ms and their cores never left a
    low clock (1.6 GHz against 2.7, measured). With one thread no worker
    runs: the main thread does the jobs itself. }
  TPipeline = class;

  TWorker = class(TThread)
  public
    pipe: TPipeline;
    index: Integer;
    constructor Create(aPipe: TPipeline; aIndex: Integer);
    procedure Execute; override;
  end;

  TPipeline = class
    jobs: array of TJob;
    startEv, doneEv: array of PRTLEvent;
    busy: array of Boolean;            { started, not yet waited for }
    workers: array of TWorker;
    threads: Integer;
    decompressing: Boolean;
    level, flags: Integer;
    constructor Create(aThreads: Integer; aDecompressing: Boolean; aLevel, aFlags: Integer);
    destructor Destroy; override;
    function Slots: Integer;
    procedure Start(slot: Integer);    { slot's job is ready: work on it }
    procedure Finish(slot: Integer);   { wait until slot's job is done }
    procedure RunJob(job: TJob);
  end;


constructor TJob.Create;
begin
  inherited Create;
  SylzCtxInit(ctx);
  SylzDCtxInit(dctx);
end;

destructor TJob.Destroy;
begin
  SylzCtxFree(ctx);
  SylzDCtxFree(dctx);
  FreeMem(raw);
  FreeMem(payload);
  inherited Destroy;
end;

procedure TJob.Reserve(rawSize, paySize: SizeInt);
begin
  if rawSize > rawCap then
  begin
    FreeMem(raw);
    raw := GetMem(rawSize);
    rawCap := rawSize;
  end;
  if paySize > payCap then
  begin
    FreeMem(payload);
    payload := GetMem(paySize);
    payCap := paySize;
  end;
end;

procedure TJob.DoCompress(level, flags: Integer);
begin
  crc := crc32(0, raw, n);
  c := SylzCompressEx(ctx, raw, n, payload, payCap, level, flags);
  ok := c >= 0;
end;

procedure TJob.DoDecompress;
begin
  if stored then
    Move(payload^, raw^, n)
  else if SylzDecompressCtx(dctx, payload, payLen, raw, n) <> n then
  begin
    ok := False;
    Exit;
  end;
  ok := crc32(0, raw, n) = sum;
end;

constructor TWorker.Create(aPipe: TPipeline; aIndex: Integer);
begin
  pipe := aPipe;
  index := aIndex;
  inherited Create(False);
end;

procedure TWorker.Execute;
var
  slot: Integer;
begin
  slot := index;
  while True do
  begin
    RTLEventWaitFor(pipe.startEv[slot]);
    if pipe.jobs[slot].n < 0 then
      Break;   { no more blocks }
    pipe.RunJob(pipe.jobs[slot]);
    RTLEventSetEvent(pipe.doneEv[slot]);
    { this thread's other slot }
    slot := (slot + pipe.threads) mod pipe.Slots;
  end;
end;

constructor TPipeline.Create(aThreads: Integer; aDecompressing: Boolean; aLevel, aFlags: Integer);
var
  i: Integer;
begin
  inherited Create;
  threads := aThreads;
  decompressing := aDecompressing;
  level := aLevel;
  flags := aFlags;
  SetLength(jobs, Slots);
  SetLength(busy, Slots);
  SetLength(startEv, Slots);
  SetLength(doneEv, Slots);
  for i := 0 to Slots - 1 do
  begin
    jobs[i] := TJob.Create;
    startEv[i] := RTLEventCreate;
    doneEv[i] := RTLEventCreate;
  end;
  if threads > 1 then
  begin
    SetLength(workers, threads);
    for i := 0 to threads - 1 do
      workers[i] := TWorker.Create(Self, i);
  end;
end;

destructor TPipeline.Destroy;
var
  i, slot: Integer;
begin
  { let the jobs still running end (an error stops the main thread early),
    then each worker waits on one of its two slots: end both }
  for i := 0 to High(busy) do
    if busy[i] then
      Finish(i);
  for i := 0 to High(workers) do
    for slot in [i, i + threads] do
    begin
      jobs[slot].n := -1;
      RTLEventSetEvent(startEv[slot]);
    end;
  for i := 0 to High(workers) do
  begin
    workers[i].WaitFor;
    workers[i].Free;
  end;
  for i := 0 to Slots - 1 do
  begin
    jobs[i].Free;
    RTLEventDestroy(startEv[i]);
    RTLEventDestroy(doneEv[i]);
  end;
  inherited Destroy;
end;

function TPipeline.Slots: Integer;
begin
  if threads > 1 then
    Result := 2 * threads
  else
    Result := 1;
end;

procedure TPipeline.RunJob(job: TJob);
begin
  try
    if decompressing then
      job.DoDecompress
    else
      job.DoCompress(level, flags);
  except
    job.ok := False;   { out of memory }
  end;
end;

procedure TPipeline.Start(slot: Integer);
begin
  if threads > 1 then
  begin
    busy[slot] := True;
    RTLEventSetEvent(startEv[slot]);
  end
  else
    RunJob(jobs[slot]);
end;

procedure TPipeline.Finish(slot: Integer);
begin
  if busy[slot] then
  begin
    RTLEventWaitFor(doneEv[slot]);
    busy[slot] := False;
  end;
end;

procedure Compress(const inPath, outPath: string; level, blockSize, flags, threads: Integer);
var
  fin, fout: TFileStream;
  pipe: TPipeline;
  hdr: array[0..5] of Byte;
  total, written: Int64;
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
      Fail('internal error: compression failed');
    WriteU32(fout, UInt32(job.n));
    if job.c < job.n then
    begin
      WriteU32(fout, UInt32(job.c));
      WriteU32(fout, job.crc);
      fout.WriteBuffer(job.payload^, job.c);
    end
    else
    begin
      WriteU32(fout, UInt32(job.n) or STORED_FLAG);
      WriteU32(fout, job.crc);
      fout.WriteBuffer(job.raw^, job.n);
    end;
    Inc(total, job.n);
  end;

begin
  fin := TFileStream.Create(inPath, fmOpenRead or fmShareDenyWrite);
  fout := nil;
  pipe := TPipeline.Create(threads, False, level, flags);
  try
    for i := 0 to pipe.Slots - 1 do
      pipe.jobs[i].Reserve(blockSize, SylzBound(blockSize));
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
      if pipe.jobs[slot].n < blockSize then
        eof := True;
      if pipe.jobs[slot].n = 0 then
        Break;
      pipe.Start(slot);
      Inc(blocks);
    end;
    { the blocks still in flight }
    b := blocks - pipe.Slots;
    if b < 0 then
      b := 0;
    while b < blocks do
    begin
      WriteSlot(b mod pipe.Slots);
      Inc(b);
    end;
    WriteU32(fout, 0);
    written := fout.Size;
    report := Format('%s: %d -> %d bytes (%.2f%%)',
      [inPath, total, written, written * 100.0 / Max(total, 1)]);
  finally
    pipe.Free;
    fout.Free;
    fin.Free;
  end;
end;

procedure Decompress(const inPath, outPath: string; threads: Integer);
var
  fin, fout: TFileStream;
  pipe: TPipeline;
  job: TJob;
  rawLen, packedField, sum, payLen: UInt32;
  hdr: array[0..5] of Byte;
  total, at: Int64;
  blocks, b, slot: Int64;

  procedure WriteSlot(slot: Integer);
  var
    job: TJob;
  begin
    pipe.Finish(slot);
    job := pipe.jobs[slot];
    if not job.ok then
      Fail(Format('%s: corrupt data or checksum mismatch in the block at output offset %d',
        [inPath, total]));
    fout.WriteBuffer(job.raw^, job.n);
    Inc(total, job.n);
  end;

begin
  fin := TFileStream.Create(inPath, fmOpenRead or fmShareDenyWrite);
  fout := nil;
  pipe := TPipeline.Create(threads, True, 0, 0);
  try
    if (ReadFull(fin, @hdr[0], 6) <> 6) or (CompareByte(hdr[0], MAGIC[1], 4) <> 0) then
      Fail(inPath + ': not a syc file');
    if (hdr[4] < 1) or (hdr[4] > FORMAT_VER) then
      Fail(Format('%s: format version %d not supported by syc %s', [inPath, hdr[4], SYC_VERSION]));
    tmpPath := outPath + TMP_SUFFIX;
    fout := TFileStream.Create(tmpPath, fmCreate);
    total := 0;
    at := 0;
    blocks := 0;
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
        Fail(Format('%s: corrupt block header at output offset %d', [inPath, at]));
      slot := blocks mod pipe.Slots;
      if blocks >= pipe.Slots then
        WriteSlot(slot);
      job := pipe.jobs[slot];
      job.Reserve(rawLen, payLen);
      if ReadFull(fin, job.payload, payLen) <> SizeInt(payLen) then
        Fail(inPath + ': truncated');
      job.n := rawLen;
      job.payLen := payLen;
      job.stored := packedField and STORED_FLAG <> 0;
      job.sum := sum;
      Inc(at, rawLen);
      pipe.Start(slot);
      Inc(blocks);
    end;
    b := blocks - pipe.Slots;
    if b < 0 then
      b := 0;
    while b < blocks do
    begin
      WriteSlot(b mod pipe.Slots);
      Inc(b);
    end;
    report := Format('%s: %d bytes', [outPath, total]);
  finally
    pipe.Free;
    fout.Free;
    fin.Free;
  end;
end;

var
  cmd, inPath, outPath, arg: string;
  level, blockMiB, i, flags, threads: Integer;
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
  threads := 1;
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
    else if arg = '-th' then
    begin
      Inc(i);
      if (i > ParamCount) or not TryStrToInt(ParamStr(i), threads)
         or (threads < 1) or (threads > MAX_THREADS) then
        Die(Format('-th takes a number of threads, 1..%d', [MAX_THREADS]));
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
      Compress(inPath, outPath, level, blockMiB shl 20, flags, threads);
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
      Decompress(inPath, outPath, threads);
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
