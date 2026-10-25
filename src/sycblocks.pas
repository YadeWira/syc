{ sycblocks — what syc's commands share: CRC-32, the errors and their exit
  codes, small stream helpers, and the pipeline that compresses or
  decompresses blocks N at a time. }
unit sycblocks;

{$mode objfpc}{$H+}

interface

uses
  {$ifdef windows}Windows,{$endif}
  {$ifdef unix}termio,{$endif}
  SysUtils, Classes, Math, sylz;

const
  MAX_BLOCK   = 512 shl 20;
  MAX_THREADS = 64;
  TMP_SUFFIX  = '.syc-partial';

  { exit codes }
  EXIT_OK      = 0;
  EXIT_WARN    = 1;   { finished, but some inputs were skipped or unreadable }
  EXIT_USAGE   = 2;
  EXIT_CORRUPT = 3;   { a checksum or the data's structure is wrong }
  EXIT_FATAL   = 4;   { I/O error, out of memory }

type
  { an error ending a command (or one input of it), with its exit code }
  ESycError = class(Exception)
    code: Integer;
    constructor Create(aCode: Integer; const msg: string);
  end;

procedure Fail(code: Integer; const msg: string);

function crc32(crc: UInt32; p: PByte; n: SizeInt): UInt32;

procedure WriteU32(s: TStream; v: UInt32);
function ReadU32(s: TStream): UInt32;
{ Reads up to n bytes; fewer only at the end of the stream. }
function ReadFull(s: TStream; p: PByte; n: SizeInt): SizeInt;
{ Moves src over dst in one step, replacing it. }
function ReplaceFile(const src, dst: string): Boolean;
{ handle 0, 1 or 2 is a terminal }
function IsTerminal(std: Integer): Boolean;
function StdStream(std: Integer): THandleStream;

type
  { reads prefix first, then inner (not owned): for an input whose first
    bytes were read to see what it is }
  TPrefixStream = class(TStream)
  private
    prefix: array of Byte;
    at: SizeInt;
    inner: TStream;
  public
    constructor Create(const aPrefix: array of Byte; aInner: TStream);
    function Read(var Buffer; Count: LongInt): LongInt; override;
  end;

  { One block's work, done by a worker thread (or the main one with one
    thread). Compress: raw[0..n) -> payload[0..c) and its crc. Decompress:
    payload (stored or a sylz block) -> raw[0..n), checked against sum. }
  TJob = class;
  { run by the job's thread after its block is done (and ok) }
  TJobPost = procedure(job: TJob) of object;

  TJob = class
    raw, payload: PByte;
    rawCap, payCap: SizeInt;
    n, c, payLen: SizeInt;
    stored: Boolean;
    sum, crc: UInt32;
    ok: Boolean;
    ctx: TSylzCtx;
    dctx: TSylzDCtx;
    post: TJobPost;
    pre: TJobPost;       { decompressing: run first (decryption); clears ok to stop }
    tag: Int64;          { the caller's: which block this is }
    failed: Int64;       { set by post: what it found wrong (0: nothing) }
    noCrc: Boolean;      { encrypted blocks: no CRC-32 (their tag checks them) }
    seal: array[0..39] of Byte;   { an encrypted block's nonce (24) and tag (16) }
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
    procedure SetPost(p: TJobPost);
    { pre hooks, and no CRC-32 (encrypted blocks) }
    procedure SetPre(p: TJobPost; aNoCrc: Boolean);
    procedure Start(slot: Integer);    { slot's job is ready: work on it }
    procedure Finish(slot: Integer);   { wait until slot's job is done }
    procedure RunJob(job: TJob);
  end;

  { A progress line on stderr, rewritten in place at most 5 times a second:
    percent (when the total is known), bytes, speed, time left. Nothing
    when disabled. }
  TProgress = class
    enabled: Boolean;
    total, done: Int64;
    started, lastShown: QWord;
    width: Integer;
    constructor Create(aEnabled: Boolean; aTotal: Int64);
    procedure Add(n: Int64);
    procedure Show;
    procedure Finish;   { clears the line }
  end;

  { Runs proc(0) .. proc(count - 1) on N threads (the calling one among
    them) and returns when all are done; the order is not defined. }
  TParallelProc = procedure(i: SizeInt) of object;

  TTaskPool = class;

  TPoolThread = class(TThread)
  public
    pool: TTaskPool;
    index: Integer;
    constructor Create(aPool: TTaskPool; aIndex: Integer);
    procedure Execute; override;
  end;

  TTaskPool = class
    threads: array of TPoolThread;
    startEv, doneEv: array of PRTLEvent;
    proc: TParallelProc;
    count: LongInt;
    next: LongInt;
    stopping, failed: Boolean;
    constructor Create(n: Integer);
    destructor Destroy; override;
    procedure Run(aCount: SizeInt; aProc: TParallelProc);
    procedure Work;
  end;

implementation

constructor ESycError.Create(aCode: Integer; const msg: string);
begin
  inherited Create(msg);
  code := aCode;
end;

procedure Fail(code: Integer; const msg: string);
begin
  raise ESycError.Create(code, msg);
end;

{ ── CRC-32 ─────────────────────────────────────────────────────────────── }

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


{ ── stream helpers ─────────────────────────────────────────────────────── }

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

{ rename does it on Unix; on Windows it fails when dst exists, MoveFileEx
  doesn't }
function ReplaceFile(const src, dst: string): Boolean;
begin
{$ifdef windows}
  Result := MoveFileExW(PWideChar(UnicodeString(src)), PWideChar(UnicodeString(dst)),
    MOVEFILE_REPLACE_EXISTING);
{$else}
  Result := RenameFile(src, dst);
{$endif}
end;

function StdHandle(std: Integer): THandle;
begin
  case std of
    0: Result := StdInputHandle;
    1: Result := StdOutputHandle;
  else
    Result := StdErrorHandle;
  end;
end;

function IsTerminal(std: Integer): Boolean;
begin
{$ifdef windows}
  Result := GetFileType(StdHandle(std)) = FILE_TYPE_CHAR;
{$else}
  Result := IsATTY(StdHandle(std)) = 1;
{$endif}
end;

function StdStream(std: Integer): THandleStream;
begin
  Result := THandleStream.Create(StdHandle(std));
end;

constructor TPrefixStream.Create(const aPrefix: array of Byte; aInner: TStream);
var
  i: Integer;
begin
  inherited Create;
  SetLength(prefix, Length(aPrefix));
  for i := 0 to High(aPrefix) do
    prefix[i] := aPrefix[i];
  inner := aInner;
end;

function TPrefixStream.Read(var Buffer; Count: LongInt): LongInt;
var
  n: LongInt;
begin
  n := 0;
  if at < Length(prefix) then
  begin
    n := Length(prefix) - at;
    if n > Count then
      n := Count;
    Move(prefix[at], Buffer, n);
    Inc(at, n);
    if n = Count then
      Exit(n);
  end;
  Result := n + inner.Read(PByte(@Buffer)[n], Count - n);
end;

{ ── the pipeline ───────────────────────────────────────────────────────── }

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
  if noCrc then
    crc := 0
  else
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
  ok := noCrc or (crc32(0, raw, n) = sum);
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
    job.failed := 0;
    if decompressing then
    begin
      job.ok := True;
      if Assigned(job.pre) then
        job.pre(job);
      if job.ok then
        job.DoDecompress;
    end
    else
      job.DoCompress(level, flags);
    if job.ok and Assigned(job.post) then
      job.post(job);
  except
    job.ok := False;   { out of memory }
  end;
end;

procedure TPipeline.SetPost(p: TJobPost);
var
  i: Integer;
begin
  for i := 0 to High(jobs) do
    jobs[i].post := p;
end;

procedure TPipeline.SetPre(p: TJobPost; aNoCrc: Boolean);
var
  i: Integer;
begin
  for i := 0 to High(jobs) do
  begin
    jobs[i].pre := p;
    jobs[i].noCrc := aNoCrc;
  end;
end;

{ ── progress ───────────────────────────────────────────────────────────── }

function Human(n: Double): string;
begin
  if n < 1e6 then
    Result := Format('%.0f kB', [n / 1e3])
  else if n < 1e9 then
    Result := Format('%.1f MB', [n / 1e6])
  else
    Result := Format('%.2f GB', [n / 1e9]);
end;

constructor TProgress.Create(aEnabled: Boolean; aTotal: Int64);
begin
  inherited Create;
  enabled := aEnabled;
  total := aTotal;
  started := GetTickCount64;
  lastShown := started;
end;

procedure TProgress.Add(n: Int64);
var
  now: QWord;
begin
  Inc(done, n);
  if not enabled then
    Exit;
  now := GetTickCount64;
  if now - lastShown >= 200 then
  begin
    lastShown := now;
    Show;
  end;
end;

procedure TProgress.Show;
var
  secs, speed, left: Double;
  line: string;
begin
  secs := (GetTickCount64 - started) / 1000;
  if secs <= 0 then
    secs := 0.001;
  speed := done / secs;
  if total > 0 then
  begin
    line := Format('%3d%%  %s / %s  %s/s', [Min(100, done * 100 div total), Human(done),
      Human(total), Human(speed)]);
    if (speed > 0) and (done < total) then
    begin
      left := (total - done) / speed;
      line := line + Format('  %d:%.2d left', [Trunc(left) div 60, Trunc(left) mod 60]);
    end;
  end
  else
    line := Format('%s  %s/s', [Human(done), Human(speed)]);
  if Length(line) < width then
    line := line + StringOfChar(' ', width - Length(line));
  width := Length(line);
  Write(StdErr, #13, line);
end;

procedure TProgress.Finish;
begin
  if enabled and (width > 0) then
  begin
    Write(StdErr, #13, StringOfChar(' ', width), #13);
    width := 0;
  end;
end;

{ ── the task pool ──────────────────────────────────────────────────────── }

constructor TPoolThread.Create(aPool: TTaskPool; aIndex: Integer);
begin
  pool := aPool;
  index := aIndex;
  inherited Create(False);
end;

procedure TPoolThread.Execute;
begin
  while True do
  begin
    RTLEventWaitFor(pool.startEv[index]);
    if pool.stopping then
      Break;
    try
      pool.Work;
    except
      pool.failed := True;
    end;
    RTLEventSetEvent(pool.doneEv[index]);
  end;
end;

constructor TTaskPool.Create(n: Integer);
var
  i: Integer;
begin
  inherited Create;
  SetLength(threads, n - 1);
  SetLength(startEv, n - 1);
  SetLength(doneEv, n - 1);
  for i := 0 to n - 2 do
  begin
    startEv[i] := RTLEventCreate;
    doneEv[i] := RTLEventCreate;
    threads[i] := TPoolThread.Create(Self, i);
  end;
end;

destructor TTaskPool.Destroy;
var
  i: Integer;
begin
  stopping := True;
  for i := 0 to High(threads) do
    RTLEventSetEvent(startEv[i]);
  for i := 0 to High(threads) do
  begin
    threads[i].WaitFor;
    threads[i].Free;
    RTLEventDestroy(startEv[i]);
    RTLEventDestroy(doneEv[i]);
  end;
  inherited Destroy;
end;

procedure TTaskPool.Work;
var
  i: LongInt;
begin
  while True do
  begin
    i := InterLockedIncrement(next) - 1;
    if i >= count then
      Break;
    proc(i);
  end;
end;

procedure TTaskPool.Run(aCount: SizeInt; aProc: TParallelProc);
var
  i: Integer;
begin
  if aCount <= 0 then
    Exit;
  proc := aProc;
  count := aCount;
  next := 0;
  if (Length(threads) = 0) or (aCount = 1) then
  begin
    Work;
    Exit;
  end;
  for i := 0 to High(threads) do
    RTLEventSetEvent(startEv[i]);
  failed := False;
  try
    Work;
  finally
    for i := 0 to High(threads) do
      RTLEventWaitFor(doneEv[i]);
  end;
  if failed then
    raise EOutOfMemory.Create('out of memory');
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

initialization
  CrcInit;
end.
