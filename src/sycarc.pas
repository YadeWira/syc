{ sycarc — the archiver: syc a, l, i, and t on a .syc archive. The format
  is sycfmt's (wiki: syc archive format).

  syc a walks the PATHs, cuts each file into fragments (syccdc), keeps
  one copy of each fragment by its BLAKE2s-256, packs the new ones into
  solid blocks compressed N at a time (sycblocks' pipeline), then writes
  the version's index and its commit. Reading starts from the last
  commit and goes back version by version, so listing reads no data; an
  archive whose end is not a commit (an interrupted syc a) is scanned
  forward to its last good version instead. }
unit sycarc;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, syccli;

{ syc a, x, l, i; returns the exit code }
function RunArchiveCommand(const opts: TOptions): Integer;
{ syc t on one archive (a seekable file); returns the exit code. name is
  the one to print. }
function TestArchive(const opts: TOptions; const path, name: string): Integer;
{ copies stream s to a new temporary file (whose first bytes are prefix)
  and returns its name: for an archive read from stdin }
function SpoolToTemp(const prefix: array of Byte; s: TStream): string;

implementation

uses
  {$ifdef unix}BaseUnix,{$endif}
  {$ifdef windows}Windows,{$endif}
  Math, sylz, blake2s, syccdc, syccrypto, sycblocks, sycenc, sycfs, sycfmt;

{ ── small helpers ──────────────────────────────────────────────────────── }

function UnixNow: Int64;
{$ifdef windows}
var
  ft: TFileTime;
begin
  GetSystemTimeAsFileTime(ft);
  Result := (Int64(ft.dwHighDateTime) shl 32 or ft.dwLowDateTime - 116444736000000000) div 10000000;
end;
{$else}
begin
  Result := fpTime;
end;
{$endif}

function FormatTime(unixSec: Int64; seconds: Boolean): string;
var
  dt: TDateTime;
begin
  dt := UnixDateDelta + unixSec / 86400 - GetLocalTimeOffset / 1440;
  if seconds then
    Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', dt)
  else
    Result := FormatDateTime('yyyy-mm-dd hh:nn', dt);
end;

{ 1234567 -> "1.2 MB" }
function HumanSize(n: Int64): string;
begin
  if n < 10000 then
    Result := IntToStr(n) + ' B'
  else if n < 10000000 then
    Result := Format('%.1f kB', [n / 1e3])
  else if n < Int64(10000000000) then
    Result := Format('%.1f MB', [n / 1e6])
  else
    Result := Format('%.1f GB', [n / 1e9]);
end;

procedure Warn(const opts: TOptions; const msg: string);
begin
  WriteLn(StdErr, 'syc: ', msg);
end;

procedure Note(const opts: TOptions; const msg: string);
begin
  if opts.verbosity = vVerbose then
    WriteLn(StdErr, msg);
end;

{ path or one of its parent directories matches a pattern }
function Excluded(const patterns: array of string; const path: string): Boolean;
var
  i, k: Integer;
begin
  for i := 0 to High(patterns) do
  begin
    if GlobMatch(patterns[i], path) then
      Exit(True);
    for k := 1 to Length(path) do
      if (path[k] = '/') and GlobMatch(patterns[i], Copy(path, 1, k - 1)) then
        Exit(True);
  end;
  Result := False;
end;

{ path is root or under it ('' holds everything) }
function Under(const root, path: string): Boolean;
begin
  Result := (root = '') or (path = root)
    or ((Length(path) > Length(root)) and (path[Length(root) + 1] = '/')
        and (CompareByte(path[1], root[1], Length(root)) = 0));
end;

function SpoolToTemp(const prefix: array of Byte; s: TStream): string;
var
  f: TFileStream;
  buf: array of Byte;
  n: SizeInt;
begin
  Result := SysUtils.GetTempFileName(GetTempDir(False), 'syc');
  f := TFileStream.Create(Result, fmCreate);
  try
    if Length(prefix) > 0 then
      f.WriteBuffer(prefix[0], Length(prefix));
    SetLength(buf, 1 shl 20);
    repeat
      n := ReadFull(s, @buf[0], Length(buf));
      if n > 0 then
        f.WriteBuffer(buf[0], n);
    until n < Length(buf);
  finally
    f.Free;
  end;
end;

{ ── the dedup table: first 16 bytes of a fragment's hash -> its number ── }

type
  TDedupSlot = record
    k0, k1: UInt64;
    frag: Int64;    { 0: empty }
  end;

  TDedupTable = record
    slots: array of TDedupSlot;
    count: SizeInt;
  end;

procedure DedupInit(var t: TDedupTable);
begin
  SetLength(t.slots, 1 shl 16);
  t.count := 0;
end;

{ the slot holding h, or the empty one where it would go }
function DedupSlot(var t: TDedupTable; const h: TBlake2sDigest): SizeInt;
var
  k0, k1: UInt64;
  mask: SizeInt;
begin
  k0 := PUInt64(@h[0])^;
  k1 := PUInt64(@h[8])^;
  mask := Length(t.slots) - 1;
  Result := SizeInt(k0) and mask;
  while (t.slots[Result].frag <> 0)
        and ((t.slots[Result].k0 <> k0) or (t.slots[Result].k1 <> k1)) do
    Result := (Result + 1) and mask;
end;

function DedupFind(var t: TDedupTable; const h: TBlake2sDigest): Int64;
begin
  Result := t.slots[DedupSlot(t, h)].frag;
end;

procedure DedupAdd(var t: TDedupTable; const h: TBlake2sDigest; frag: Int64);
var
  old: array of TDedupSlot;
  i, s: SizeInt;
begin
  if 2 * (t.count + 1) > Length(t.slots) then
  begin
    old := t.slots;
    t.slots := nil;
    SetLength(t.slots, 2 * Length(old));
    for i := 0 to High(old) do
      if old[i].frag <> 0 then
      begin
        s := SizeInt(old[i].k0) and (Length(t.slots) - 1);
        while t.slots[s].frag <> 0 do
          s := (s + 1) and (Length(t.slots) - 1);
        t.slots[s] := old[i];
      end;
  end;
  s := DedupSlot(t, h);
  t.slots[s].k0 := PUInt64(@h[0])^;
  t.slots[s].k1 := PUInt64(@h[8])^;
  t.slots[s].frag := frag;
  Inc(t.count);
end;

{ ── entries ────────────────────────────────────────────────────────────── }

{ by path, then version (l --all) }
function CompareEntries(const a, b: TEntry): Integer;
begin
  Result := ComparePaths(a.path, b.path);
  if Result = 0 then
    Result := Ord(a.ver > b.ver) - Ord(a.ver < b.ver);
end;

procedure SortEntries(var a: TEntries; lo, hi: SizeInt);
var
  i, j: SizeInt;
  pivot, tmp: TEntry;
begin
  while lo < hi do
  begin
    pivot := a[(lo + hi) div 2];
    i := lo;
    j := hi;
    repeat
      while CompareEntries(a[i], pivot) < 0 do
        Inc(i);
      while CompareEntries(a[j], pivot) > 0 do
        Dec(j);
      if i <= j then
      begin
        tmp := a[i];
        a[i] := a[j];
        a[j] := tmp;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    { the smaller side recursively, the larger one in the loop }
    if j - lo < hi - i then
    begin
      SortEntries(a, lo, j);
      lo := i;
    end
    else
    begin
      SortEntries(a, i, hi);
      hi := j;
    end;
  end;
end;

{ state with a version's entries applied: both sorted by path }
function ApplyVersion(const state, entries: TEntries): TEntries;
var
  i, j, k, c: SizeInt;
begin
  Result := nil;
  SetLength(Result, Length(state) + Length(entries));
  i := 0;
  j := 0;
  k := 0;
  while (i < Length(state)) or (j < Length(entries)) do
  begin
    if i >= Length(state) then
      c := 1
    else if j >= Length(entries) then
      c := -1
    else
      c := ComparePaths(state[i].path, entries[j].path);
    if c < 0 then
    begin
      Result[k] := state[i];
      Inc(k);
      Inc(i);
    end
    else
    begin
      if entries[j].kind <> ET_DELETED then
      begin
        Result[k] := entries[j];
        Inc(k);
      end;
      if c = 0 then
        Inc(i);
      Inc(j);
    end;
  end;
  SetLength(Result, k);
end;

{ ── syc a ──────────────────────────────────────────────────────────────── }

const
  NUM_BATCHES = 3;
  BATCH_SIZE = 8 shl 20;
  HASH_GROUP = 8;   { fragments a hashing task takes: ~110 in a batch }

type
  { fragments cut from the files, in order, not yet hashed }
  TBatch = class
    data: array of Byte;
    len: SizeInt;
    frags: array of record
      off, len, entry: SizeInt;
    end;
    hash: array of TBlake2sDigest;
    n: SizeInt;
    last: Boolean;   { no more after this one }
  end;

  { Seals (writing) or opens (reading) an encrypted archive's blocks, on
    their threads: XChaCha20-Poly1305 with K_aead, AAD "SYCB" vnum k rawLen
    packed, k the block's place in its version }
  TArcSealer = class
    keys: TSycKeys;
    vnum: UInt32;     { writing: the version's number; job.tag = k }
    arc: TObject;     { reading: the TArchive; job.tag = its block number }
    function BlockAad(vn: UInt32; k: Int64; job: TJob): TBytes;
    procedure SealJob(job: TJob);
    procedure OpenJob(job: TJob);
  end;

  TAdder = class
    opts: TOptions;
    enc, indexEnc: Boolean;      { format 3; its index sealed too }
    sealer: TArcSealer;
    gearK: array[0..255] of UInt64;   { the keyed cutter's table }
    status: Integer;
    prm: TCdcParams;
    arcFull, tmpFull: string;   { never added to themselves }
    unreadPaths: array of string;   { could not be read: not deleted }
    entries: TEntries;
    count: SizeInt;
    { output }
    fout: TStream;
    pos: Int64;
    pipe: TPipeline;
    blockSize: SizeInt;
    slot, fill: SizeInt;
    fragsInBlock: Int64;
    blocksSubmitted, blocksWritten: Int64;
    blockFrags: array of Int64;
    idx: TIndex;
    nBlocks, nFrags: SizeInt;
    nextFrag: Int64;
    dedup: TDedupTable;
    { Fragments are cut into batches (by a reader thread with -t 2 and up,
      while the main thread hashes and stores the batch before), hashed N
      at a time, then stored in order. }
    pool: TTaskPool;
    batches: array[0..NUM_BATCHES - 1] of TBatch;
    cur: TBatch;                 { the one being hashed }
    reader: TThread;
    fullEv, freeEv: array[0..NUM_BATCHES - 1] of PRTLEvent;
    readError: string;           { the reader thread's exception, if any }
    { the reader's place: the next entry, the open file, its buffer }
    rdEntry: SizeInt;
    rdFile: TFileStream;
    rdBuf: array of Byte;
    rdStart, rdLen: SizeInt;
    rdEof: Boolean;
    rdTotal: Int64;
    refCount: array of SizeInt;
    prog: TProgress;
    { statistics }
    totalIn, dupBytes: Int64;
    nFiles, nDirs, nLinks: Int64;
    constructor Create(const aOpts: TOptions);
    destructor Destroy; override;
    procedure AddEntry(const local, stored: string; const m: TMeta);
    function Unread(const path: string): Boolean;
    procedure Walk(const local, stored: string);
    procedure WriteSlot(s: SizeInt);
    procedure Submit;
    procedure AddRef(entry: SizeInt; frag: Int64);
    procedure Fragment(p: PByte; n: SizeInt; const h: TBlake2sDigest; entry: SizeInt);
    procedure HashOne(i: SizeInt);
    procedure FillBatch(b: TBatch);
    procedure StoreBatch(b: TBatch);
    procedure ReadAll;
    procedure WriteIndexAndCommit(vstart: Int64);
  end;

constructor TAdder.Create(const aOpts: TOptions);
begin
  inherited Create;
  opts := aOpts;
  prm := CdcParams(CDC_MIN_LOG, CDC_AVG_LOG, CDC_MAX_LOG);
  DedupInit(dedup);
  nextFrag := 1;
end;

destructor TAdder.Destroy;
var
  i: Integer;
begin
  if reader <> nil then
  begin
    { an error stopped the main thread: let the reader end (terminated
      first, so that it stops at its next batch instead of reading on) }
    reader.Terminate;
    for i := 0 to NUM_BATCHES - 1 do
      if freeEv[i] <> nil then
        RTLEventSetEvent(freeEv[i]);
    reader.WaitFor;
    reader.Free;
  end;
  for i := 0 to NUM_BATCHES - 1 do
  begin
    batches[i].Free;
    if fullEv[i] <> nil then
      RTLEventDestroy(fullEv[i]);
    if freeEv[i] <> nil then
      RTLEventDestroy(freeEv[i]);
  end;
  rdFile.Free;
  prog.Free;
  pool.Free;
  pipe.Free;
  if sealer <> nil then
  begin
    WipeKeys(sealer.keys);
    sealer.Free;
  end;
  inherited Destroy;
end;

function TArcSealer.BlockAad(vn: UInt32; k: Int64; job: TJob): TBytes;
var
  packedField: UInt32;
begin
  Result := nil;
  PutBytes(Result, 'SYCB');
  PutU32(Result, vn);
  PutU32(Result, UInt32(k));
  PutU32(Result, UInt32(job.n));
  packedField := UInt32(job.payLen);
  if job.stored then
    packedField := packedField or $80000000;
  PutU32(Result, packedField);
end;

{ after compressing: the payload (compressed, or the raw data when that
  is no smaller), sealed in place }
procedure TArcSealer.SealJob(job: TJob);
begin
  job.stored := job.c >= job.n;
  if job.stored then
  begin
    Move(job.raw^, job.payload^, job.n);
    job.payLen := job.n;
  end
  else
    job.payLen := job.c;
  SealData(keys.aead, BlockAad(vnum, job.tag, job), job.payload, job.payLen, @job.seal[0]);
end;

procedure TAdder.AddEntry(const local, stored: string; const m: TMeta);
begin
  if count = Length(entries) then
    SetLength(entries, Max(64, 2 * count));
  entries[count] := Default(TEntry);
  entries[count].path := stored;
  entries[count].kind := m.kind;
  entries[count].meta := m;
  entries[count].local := local;
  Inc(count);
end;

function TAdder.Unread(const path: string): Boolean;
var
  i: SizeInt;
begin
  for i := 0 to High(unreadPaths) do
    if Under(unreadPaths[i], path) then
      Exit(True);
  Result := False;
end;

procedure TAdder.Walk(const local, stored: string);
var
  m: TMeta;
  names: TStringList;
  i: Integer;
  full: string;
begin
  if (stored <> '') and Excluded(opts.excludes, stored) then
    Exit;
  if not GetMeta(local, m) then
  begin
    Warn(opts, local + ': cannot read, skipped');
    status := Max(status, EXIT_WARN);
    SetLength(unreadPaths, Length(unreadPaths) + 1);
    unreadPaths[High(unreadPaths)] := stored;
    Exit;
  end;
  if m.kind <> ET_DIR then
  begin
    full := ExpandFileName(local);
    if SameFileName(full, arcFull) or SameFileName(full, tmpFull) then
      Exit;
  end;
  case m.kind of
    ET_OTHER:
      Note(opts, local + ': not a file, directory or symlink, skipped');
    ET_DIR:
      begin
        if stored <> '' then
          AddEntry(local, stored, m);
        names := TStringList.Create;
        try
          if not ListDir(local, names) then
          begin
            Warn(opts, local + ': cannot list, skipped');
            status := Max(status, EXIT_WARN);
            SetLength(unreadPaths, Length(unreadPaths) + 1);
            unreadPaths[High(unreadPaths)] := stored;
            Exit;
          end;
          for i := 0 to names.Count - 1 do
            if stored = '' then
              Walk(IncludeTrailingPathDelimiter(local) + names[i], names[i])
            else
              Walk(IncludeTrailingPathDelimiter(local) + names[i], stored + '/' + names[i]);
        finally
          names.Free;
        end;
      end;
  else
    AddEntry(local, stored, m);
  end;
end;

procedure TAdder.WriteSlot(s: SizeInt);
var
  job: TJob;
begin
  pipe.Finish(s);
  job := pipe.jobs[s];
  if not job.ok then
    Fail(EXIT_FATAL, 'out of memory');
  WriteU32(fout, UInt32(job.n));
  if enc then
  begin
    { rawLen, packed, crc32 = 0, nonce, the sealed payload, tag }
    if job.stored then
      WriteU32(fout, UInt32(job.payLen) or $80000000)
    else
      WriteU32(fout, UInt32(job.payLen));
    WriteU32(fout, 0);
    fout.WriteBuffer(job.seal[0], 24);
    fout.WriteBuffer(job.payload^, job.payLen);
    fout.WriteBuffer(job.seal[24], 16);
    idx.blocks[nBlocks].bytes := BLOCKHDR_SIZE + SEAL_SIZE + job.payLen;
  end
  else if job.c < job.n then
  begin
    WriteU32(fout, UInt32(job.c));
    WriteU32(fout, job.crc);
    fout.WriteBuffer(job.payload^, job.c);
    idx.blocks[nBlocks].bytes := BLOCKHDR_SIZE + job.c;
  end
  else
  begin
    WriteU32(fout, UInt32(job.n) or $80000000);
    WriteU32(fout, job.crc);
    fout.WriteBuffer(job.raw^, job.n);
    idx.blocks[nBlocks].bytes := BLOCKHDR_SIZE + job.n;
  end;
  idx.blocks[nBlocks].frags := blockFrags[blocksWritten];
  Inc(pos, idx.blocks[nBlocks].bytes);
  Inc(nBlocks);
  Inc(blocksWritten);
end;

{ the block being filled goes to its thread; the next slot is made free
  by writing the block it held }
procedure TAdder.Submit;
begin
  if fill = 0 then
    Exit;
  pipe.jobs[slot].n := fill;
  pipe.jobs[slot].tag := blocksSubmitted;   { its place in the version (the AAD) }
  pipe.Start(slot);
  if blocksSubmitted >= Length(blockFrags) then
    SetLength(blockFrags, Max(64, 2 * Length(blockFrags)));
  if blocksSubmitted >= Length(idx.blocks) then
    SetLength(idx.blocks, Max(64, 2 * Length(idx.blocks)));
  blockFrags[blocksSubmitted] := fragsInBlock;
  Inc(blocksSubmitted);
  fill := 0;
  fragsInBlock := 0;
  slot := blocksSubmitted mod pipe.Slots;
  if blocksSubmitted >= pipe.Slots then
    WriteSlot(slot);
end;

procedure TAdder.AddRef(entry: SizeInt; frag: Int64);
var
  e: ^TEntry;
begin
  e := @entries[entry];
  if refCount[entry] = Length(e^.refs) then
    SetLength(e^.refs, Max(16, 2 * refCount[entry]));
  e^.refs[refCount[entry]] := frag;
  Inc(refCount[entry]);
end;

{ one fragment, its hash known: a reference to an earlier copy, or a new
  fragment in the block being filled }
procedure TAdder.Fragment(p: PByte; n: SizeInt; const h: TBlake2sDigest; entry: SizeInt);
var
  f: Int64;
begin
  if not opts.noDedup then
  begin
    f := DedupFind(dedup, h);
    if f <> 0 then
    begin
      AddRef(entry, f);
      Inc(dupBytes, n);
      Exit;
    end;
  end;
  f := nextFrag;
  Inc(nextFrag);
  if nFrags = Length(idx.frags) then
    SetLength(idx.frags, Max(1024, 2 * nFrags));
  idx.frags[nFrags].size := n;
  idx.frags[nFrags].hash := h;
  Inc(nFrags);
  if not opts.noDedup then
    DedupAdd(dedup, h, f);
  AddRef(entry, f);
  if fill + n > blockSize then
    Submit;
  Move(p^, pipe.jobs[slot].raw[fill], n);
  Inc(fill, n);
  Inc(fragsInBlock);
end;

{ group i of the batch's fragments (HASH_GROUP of them), hashed together:
  Blake2sMany works four at a time }
procedure TAdder.HashOne(i: SizeInt);
var
  msg: array[0..HASH_GROUP - 1] of PByte;
  len: array[0..HASH_GROUP - 1] of SizeInt;
  k, first, n: SizeInt;
begin
  first := i * HASH_GROUP;
  n := Min(HASH_GROUP, cur.n - first);
  for k := 0 to n - 1 do
  begin
    msg[k] := @cur.data[cur.frags[first + k].off];
    len[k] := cur.frags[first + k].len;
  end;
  if enc then
    Blake2sManyKey(@sealer.keys.frag[0], 32, @msg[0], @len[0], n, @cur.hash[first])
  else
    Blake2sMany(@msg[0], @len[0], n, @cur.hash[first]);
end;

{ Cuts files into b from where the last call stopped, until b is full or
  the files end (b.last). A file that cannot be opened is left out (its
  entry becomes ET_OTHER); its size is what was read. }
procedure TAdder.FillBatch(b: TBatch);
var
  got, cut: SizeInt;
  e: ^TEntry;
begin
  b.len := 0;
  b.n := 0;
  b.last := False;
  while True do
  begin
    if rdFile = nil then
    begin
      { the next file }
      while (rdEntry < count) and (entries[rdEntry].kind <> ET_FILE) do
        Inc(rdEntry);
      if rdEntry >= count then
      begin
        b.last := True;
        Exit;
      end;
      e := @entries[rdEntry];
      try
        rdFile := TFileStream.Create(e^.local, fmOpenRead or fmShareDenyNone);
      except
        on EFOpenError do
        begin
          Warn(opts, e^.local + ': cannot open, skipped');
          status := Max(status, EXIT_WARN);
          e^.kind := ET_OTHER;
          Inc(rdEntry);
          Continue;
        end;
      end;
      rdStart := 0;
      rdLen := 0;
      rdEof := False;
      rdTotal := 0;
    end;
    { at least maxSize bytes ahead, unless the file ends sooner: a cut
      never looks further }
    if (rdLen - rdStart < prm.maxSize) and not rdEof then
    begin
      Move(rdBuf[rdStart], rdBuf[0], rdLen - rdStart);
      rdLen := rdLen - rdStart;
      rdStart := 0;
      got := ReadFull(rdFile, @rdBuf[rdLen], Length(rdBuf) - rdLen);
      prog.Add(got);
      rdEof := rdLen + got < Length(rdBuf);
      Inc(rdLen, got);
    end;
    if rdStart = rdLen then
    begin
      { the file is done: its size is what was read, if it changed
        meanwhile }
      entries[rdEntry].meta.size := rdTotal;
      Inc(totalIn, rdTotal);
      FreeAndNil(rdFile);
      Inc(rdEntry);
      Continue;
    end;
    cut := CdcCut(prm, @rdBuf[rdStart], rdLen - rdStart);
    if b.len + cut > Length(b.data) then
      Exit;   { full: this fragment starts the next batch }
    if b.n = Length(b.frags) then
    begin
      SetLength(b.frags, Max(256, 2 * b.n));
      SetLength(b.hash, Length(b.frags));
    end;
    Move(rdBuf[rdStart], b.data[b.len], cut);
    b.frags[b.n].off := b.len;
    b.frags[b.n].len := cut;
    b.frags[b.n].entry := rdEntry;
    Inc(b.n);
    Inc(b.len, cut);
    Inc(rdStart, cut);
    Inc(rdTotal, cut);
  end;
end;

{ the batch's fragments hashed in parallel, then stored in order: the
  archive does not depend on the number of threads }
procedure TAdder.StoreBatch(b: TBatch);
var
  i: SizeInt;
begin
  cur := b;
  pool.Run((b.n + HASH_GROUP - 1) div HASH_GROUP, @HashOne);
  for i := 0 to b.n - 1 do
    Fragment(@b.data[b.frags[i].off], b.frags[i].len, b.hash[i], b.frags[i].entry);
end;

type
  { cuts the batches ahead of the main thread, which hashes and stores them }
  TReaderThread = class(TThread)
    adder: TAdder;
    constructor Create(a: TAdder);
    procedure Execute; override;
  end;

constructor TReaderThread.Create(a: TAdder);
begin
  adder := a;
  inherited Create(False);
end;

procedure TReaderThread.Execute;
var
  k: Integer;
  b: TBatch;
begin
  k := 0;
  repeat
    RTLEventWaitFor(adder.freeEv[k]);
    b := adder.batches[k];
    if Terminated then
      Break;
    try
      adder.FillBatch(b);
    except
      on E: Exception do
      begin
        adder.readError := E.Message;
        b.n := 0;
        b.last := True;
      end;
    end;
    RTLEventSetEvent(adder.fullEv[k]);
    k := (k + 1) mod NUM_BATCHES;
  until b.last;
end;

{ every file's data: cut, hashed, stored }
procedure TAdder.ReadAll;
var
  i, k: Integer;
  b: TBatch;
begin
  SetLength(rdBuf, 4 * prm.maxSize);
  for i := 0 to NUM_BATCHES - 1 do
  begin
    batches[i] := TBatch.Create;
    SetLength(batches[i].data, BATCH_SIZE);
  end;
  rdEntry := 0;
  if opts.threads = 1 then
  begin
    { one thread: in turn }
    repeat
      FillBatch(batches[0]);
      StoreBatch(batches[0]);
    until batches[0].last;
    Exit;
  end;
  for i := 0 to NUM_BATCHES - 1 do
  begin
    fullEv[i] := RTLEventCreate;
    freeEv[i] := RTLEventCreate;
    RTLEventSetEvent(freeEv[i]);
  end;
  reader := TReaderThread.Create(Self);
  k := 0;
  repeat
    RTLEventWaitFor(fullEv[k]);
    b := batches[k];
    if readError <> '' then
      Fail(EXIT_FATAL, readError);
    StoreBatch(b);
    if not b.last then
      RTLEventSetEvent(freeEv[k]);
    k := (k + 1) mod NUM_BATCHES;
  until b.last;
  reader.WaitFor;
  FreeAndNil(reader);
end;

procedure TAdder.WriteIndexAndCommit(vstart: Int64);
var
  b: TByteBuf;
  ctx: TSylzCtx;
  dst: array of Byte;
  c: SizeInt;
  crc: UInt32;
  commit: array[0..COMMIT_SIZE - 1] of Byte;
  istart: Int64;
  stored: Boolean;
  packedField: UInt32;
  aad: TBytes;
  seal: array[0..SEAL_SIZE - 1] of Byte;
begin
  b := Default(TByteBuf);
  if enc then
    BufI64(b, UnixNow);   { format 3: the version's time, inside the index }
  EncodeIndex(idx, nextFrag - nFrags, b);
  if b.len > MAX_BLOCK then
    Fail(EXIT_FATAL, 'the index is over 512 MiB: too many files for one version');
  SetLength(dst, SylzBound(b.len) + 1);
  SylzCtxInit(ctx);
  try
    c := SylzCompressEx(ctx, @b.data[0], b.len, @dst[0], Length(dst), opts.level, opts.flags);
  finally
    SylzCtxFree(ctx);
  end;
  istart := pos;
  fout.WriteBuffer(INDEX_MAGIC[1], 4);
  WriteU32(fout, b.len);
  if indexEnc then
  begin
    { sealed: AAD "SYCI" vnum rawLen packed; no CRC }
    stored := (c < 0) or (c >= b.len);
    if stored then
    begin
      SetLength(dst, b.len + 1);
      Move(b.data[0], dst[0], b.len);
      c := b.len;
      packedField := UInt32(c) or $80000000;
    end
    else
      packedField := UInt32(c);
    aad := nil;
    PutBytes(aad, 'SYCI');
    PutU32(aad, sealer.vnum);
    PutU32(aad, b.len);
    PutU32(aad, packedField);
    SealData(sealer.keys.aead, aad, @dst[0], c, @seal[0]);
    WriteU32(fout, packedField);
    WriteU32(fout, 0);
    fout.WriteBuffer(seal[0], 24);
    fout.WriteBuffer(dst[0], c);
    fout.WriteBuffer(seal[24], 16);
    Inc(pos, 4 + BLOCKHDR_SIZE + SEAL_SIZE + c);
  end
  else
  begin
  crc := crc32(0, @b.data[0], b.len);
  if (c >= 0) and (c < b.len) then
  begin
    WriteU32(fout, c);
    WriteU32(fout, crc);
    fout.WriteBuffer(dst[0], c);
    Inc(pos, 4 + BLOCKHDR_SIZE + c);
  end
  else
  begin
    WriteU32(fout, UInt32(b.len) or $80000000);
    WriteU32(fout, crc);
    fout.WriteBuffer(b.data[0], b.len);
    Inc(pos, 4 + BLOCKHDR_SIZE + b.len);
  end;
  end;
  { the version's bytes are on the disk before the commit that makes it
    count, and the commit before syc a reports success }
  if fout is TFileStream then
    FileFlush(TFileStream(fout).Handle);
  Move(COMMIT_MAGIC[1], commit[0], 4);
  PInt64(@commit[4])^ := NtoLE(vstart);
  PInt64(@commit[12])^ := NtoLE(istart);
  PUInt32(@commit[20])^ := NtoLE(crc32(0, @commit[0], 20));
  fout.WriteBuffer(commit, COMMIT_SIZE);
  Inc(pos, COMMIT_SIZE);
  if fout is TFileStream then
    FileFlush(TFileStream(fout).Handle);
end;

{ ── reading ────────────────────────────────────────────────────────────── }

type
  TVersion = record
    vnum: UInt32;
    time: Int64;
    vstart, istart, commitPos: Int64;
    firstFrag: Int64;
    firstBlock: SizeInt;
    indexBytes: Int64;    { the index record, header included }
    idx: TIndex;
  end;

  TArcBlock = record
    pos, bytes: Int64;
    rawLen: Int64;
    firstFrag, frags: Int64;
    ver: SizeInt;
  end;

  TArchive = class
    fs: TFileStream;
    name: string;
    size: Int64;
    prm: TCdcParams;
    versions: array of TVersion;
    blocks: array of TArcBlock;
    fragSize: array of UInt32;    { [frag - 1] }
    fragOff: array of UInt32;     { offset in its block }
    fragBlock: array of UInt32;   { its block, in blocks[] }
    damaged: Boolean;             { bytes after the last good commit }
    fmt: Byte;                    { ARC_FMT, 1, or ARC_FMT_ENC }
    vheadSize: Integer;           { VHEAD_SIZE, or VHEAD_SIZE_1 }
    allowEmpty: Boolean;          { an archive with no complete version is not an error }
    { format 3 (encrypted) }
    enc, indexEnc: Boolean;
    dataStart: Int64;             { where the first version starts }
    blockExtra, indexExtra: Integer;   { a sealed record's nonce and tag, 40, else 0 }
    keyHeader, keyRecord: TBytes;
    sealer: TArcSealer;           { with the keys, once the password opened them }
    gearK: array[0..255] of UInt64;
    { needData: blocks will be read (x, t, a), so an encrypted archive's
      key is needed even when its index is readable }
    constructor Open(const path, aName: string; aAllowEmpty, needData: Boolean;
      const opts: TOptions);
    destructor Destroy; override;
    procedure Corrupt(const msg: string);
    function ReadAt(at: Int64; p: Pointer; n: SizeInt): Boolean;
    procedure ScanForward;
    procedure LoadVersion(k: SizeInt);
    procedure LoadBlock(b: SizeInt; job: TJob);
    function State(upTo: SizeInt): TEntries;
  end;

procedure TArchive.Corrupt(const msg: string);
begin
  raise ESycError.Create(EXIT_CORRUPT, name + ': ' + msg);
end;

function TArchive.ReadAt(at: Int64; p: Pointer; n: SizeInt): Boolean;
begin
  if (at < 0) or (at + n > size) then
    Exit(False);
  fs.Position := at;
  Result := ReadFull(fs, p, n) = n;
end;

{ a commit record at pos: its vstart and istart, if it is one }
function ReadCommit(a: TArchive; at: Int64; out vstart, istart: Int64): Boolean;
var
  c: array[0..COMMIT_SIZE - 1] of Byte;
begin
  FillChar(c, SizeOf(c), 0);
  Result := a.ReadAt(at, @c, COMMIT_SIZE) and (CompareByte(c[0], COMMIT_MAGIC[1], 4) = 0)
    and (LEtoN(PUInt32(@c[20])^) = crc32(0, @c[0], 20));
  vstart := LEtoN(PInt64(@c[4])^);
  istart := LEtoN(PInt64(@c[12])^);
  { a version holds at least its head, the end of its blocks and the
    index's header }
  Result := Result and (vstart >= a.dataStart) and (istart >= vstart + a.vheadSize + 4)
    and (istart + 4 + BLOCKHDR_SIZE + a.indexExtra <= at);
end;

constructor TArchive.Open(const path, aName: string; aAllowEmpty, needData: Boolean;
  const opts: TOptions);
var
  hdr: array[0..HEADER_SIZE - 1] of Byte;
  at, vstart, istart: Int64;
  list: array of TVersion;
  n, i: SizeInt;
  ok: Boolean;
  pw: TBytes;
  keys: TSycKeys;
begin
  inherited Create;
  name := aName;
  allowEmpty := aAllowEmpty;
  try
    fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  except
    on EFOpenError do
      raise ESycError.Create(EXIT_WARN, name + ': cannot open');
  end;
  size := fs.Size;
  if not ReadAt(0, @hdr, HEADER_SIZE) or (CompareByte(hdr[0], ARC_MAGIC[1], 4) <> 0) then
    Corrupt('not a syc archive');
  if (hdr[4] <> ARC_FMT) and (hdr[4] <> 1) and (hdr[4] <> ARC_FMT_ENC) then
    Corrupt(Format('archive format %d not supported by syc %s', [hdr[4], SYC_VERSION]));
  fmt := hdr[4];
  if fmt = 1 then
    vheadSize := VHEAD_SIZE_1
  else
    vheadSize := VHEAD_SIZE;
  if not ((hdr[5] >= 6) and (hdr[5] < hdr[6]) and (hdr[6] < hdr[7]) and (hdr[7] <= 24)) then
    Corrupt('bad fragment parameters in the header');
  prm := CdcParams(hdr[5], hdr[6], hdr[7]);
  dataStart := HEADER_SIZE;
  if fmt = ARC_FMT_ENC then
  begin
    { the key record; the password when the index or the data is read }
    enc := True;
    SetLength(keyHeader, HEADER_SIZE);
    Move(hdr, keyHeader[0], HEADER_SIZE);
    SetLength(keyRecord, KEYREC_SIZE);
    if not ReadAt(HEADER_SIZE, @keyRecord[0], KEYREC_SIZE) then
      Corrupt('truncated key record');
    indexEnc := keyRecord[4] and KEYREC_FLAG_INDEX <> 0;
    dataStart := HEADER_SIZE + KEYREC_SIZE;
    blockExtra := SEAL_SIZE;
    if indexEnc then
      indexExtra := SEAL_SIZE;
    if indexEnc or needData then
    begin
      pw := GetPassword(opts, False, name);
      if not OpenKeyRecord(keyHeader, keyRecord, pw, name, keys) then
        Corrupt('wrong password, or a damaged key record');
      Wipe(@pw[0], Length(pw));
      sealer := TArcSealer.Create;
      sealer.keys := keys;
      sealer.arc := Self;
      WipeKeys(keys);
      MakeGear(LEtoN(PUInt64(@sealer.keys.cdc[0])^), gearK);
      prm.gear := @gearK[0];
    end;
  end;

  { back from the end, commit by commit }
  list := nil;
  n := 0;
  at := size;
  ok := True;
  while at > dataStart do
  begin
    if not ReadCommit(Self, at - COMMIT_SIZE, vstart, istart) or (vstart >= at - COMMIT_SIZE) then
    begin
      ok := False;
      Break;
    end;
    if n = Length(list) then
      SetLength(list, Max(16, 2 * n));
    list[n].vstart := vstart;
    list[n].istart := istart;
    list[n].commitPos := at - COMMIT_SIZE;
    Inc(n);
    at := vstart;
  end;
  if ok and (at = dataStart) then
  begin
    SetLength(versions, n);
    for i := 0 to n - 1 do
      versions[i] := list[n - 1 - i];
  end
  else
    ScanForward;
  for i := 0 to High(versions) do
    LoadVersion(i);
end;

destructor TArchive.Destroy;
begin
  fs.Free;
  if sealer <> nil then
  begin
    WipeKeys(sealer.keys);
    sealer.Free;
  end;
  inherited Destroy;
end;

{ before decompressing a block read from the archive: checked and opened
  in place; job.tag is the archive's block number }
procedure TArcSealer.OpenJob(job: TJob);
var
  a: TArchive;
  blk: ^TArcBlock;
begin
  a := TArchive(arc);
  blk := @a.blocks[job.tag];
  if not OpenData(keys.aead, BlockAad(blk^.ver + 1, job.tag - a.versions[blk^.ver].firstBlock, job),
     job.payload, job.payLen, @job.seal[0]) then
  begin
    job.ok := False;
    job.failed := -1;   { the tag }
  end;
end;

{ from the first version on, as far as the versions are whole: their
  blocks' headers lead to the index, and a valid commit follows it }
procedure TArchive.ScanForward;
var
  at, p, vstart, istart, payLen: Int64;
  w: array[0..BLOCKHDR_SIZE - 1] of Byte;
  n: SizeInt;
  good: Boolean;
begin
  versions := nil;
  n := 0;
  payLen := 0;
  FillChar(w, SizeOf(w), 0);
  at := dataStart;
  while at < size do
  begin
    good := ReadAt(at, @w, 4) and (CompareByte(w[0], VHEAD_MAGIC[1], 4) = 0);
    p := at + vheadSize;
    while good do
    begin
      if not ReadAt(p, @w, 4) then
        good := False
      else if PUInt32(@w[0])^ = 0 then
      begin
        Inc(p, 4);
        Break;
      end
      else if not ReadAt(p, @w, BLOCKHDR_SIZE) then
        good := False
      else
      begin
        payLen := LEtoN(PUInt32(@w[4])^) and $7FFFFFFF;
        Inc(p, BLOCKHDR_SIZE + blockExtra + payLen);
      end;
    end;
    if good then
      good := ReadAt(p, @w, 4 + 8) and (CompareByte(w[0], INDEX_MAGIC[1], 4) = 0);
    if good then
    begin
      payLen := LEtoN(PUInt32(@w[8])^) and $7FFFFFFF;
      good := ReadCommit(Self, p + 4 + BLOCKHDR_SIZE + indexExtra + payLen, vstart, istart)
        and (vstart = at) and (istart = p);
    end;
    if not good then
      Break;
    SetLength(versions, n + 1);
    versions[n].vstart := at;
    versions[n].istart := p;
    versions[n].commitPos := p + 4 + BLOCKHDR_SIZE + indexExtra + payLen;
    Inc(n);
    at := versions[n - 1].commitPos + COMMIT_SIZE;
  end;
  damaged := True;
  if (n = 0) and not allowEmpty then
    Corrupt('no complete version (an interrupted syc a?)');
end;

procedure TArchive.LoadVersion(k: SizeInt);
var
  v: ^TVersion;
  head: array[0..VHEAD_SIZE - 1] of Byte;
  ih: array[0..4 + BLOCKHDR_SIZE - 1] of Byte;
  rawLen, packedField, sum, payLen: UInt32;
  payload, raw: array of Byte;
  ctx: TSylzDCtx;
  i, j, nf: SizeInt;
  f: Int64;
  p, blockRaw, firstFrag, total: Int64;
  e: ^TEntry;
  blk: ^TArcBlock;
  seal: array[0..SEAL_SIZE - 1] of Byte;
  aad: TBytes;
begin
  v := @versions[k];
  if not ReadAt(v^.vstart, @head, vheadSize) or (CompareByte(head[0], VHEAD_MAGIC[1], 4) <> 0) then
    Corrupt(Format('version %d: bad header', [k + 1]));
  { format 2: the codec, then three reserved zero bytes }
  if fmt >= 2 then
  begin
    if (head[17] <> 0) or (head[18] <> 0) or (head[19] <> 0) then
      Corrupt(Format('version %d: bad header', [k + 1]));
    if head[16] <> CODEC_SYLZ then
      Corrupt(Format('version %d: codec %d not supported by syc %s', [k + 1, head[16], SYC_VERSION]));
  end;
  v^.vnum := LEtoN(PUInt32(@head[4])^);
  v^.time := LEtoN(PInt64(@head[8])^);
  if v^.vnum <> k + 1 then
    Corrupt(Format('version %d numbered %d', [k + 1, v^.vnum]));

  { the index }
  if not ReadAt(v^.istart, @ih, SizeOf(ih)) or (CompareByte(ih[0], INDEX_MAGIC[1], 4) <> 0) then
    Corrupt(Format('version %d: bad index header', [k + 1]));
  rawLen := LEtoN(PUInt32(@ih[4])^);
  packedField := LEtoN(PUInt32(@ih[8])^);
  sum := LEtoN(PUInt32(@ih[12])^);
  payLen := packedField and $7FFFFFFF;
  if (rawLen > MAX_BLOCK) or (v^.istart + SizeOf(ih) + indexExtra + payLen <> v^.commitPos)
     or ((packedField and $80000000 <> 0) and (payLen <> rawLen))
     or (indexEnc and (sum <> 0)) or (enc and (rawLen < 8)) then
    Corrupt(Format('version %d: bad index header', [k + 1]));
  v^.indexBytes := SizeOf(ih) + indexExtra + payLen;
  SetLength(payload, payLen + 1);
  if indexEnc then
  begin
    { nonce, sealed payload, tag }
    if not ReadAt(v^.istart + SizeOf(ih), @seal[0], 24)
       or not ReadAt(v^.istart + SizeOf(ih) + 24, @payload[0], payLen)
       or not ReadAt(v^.istart + SizeOf(ih) + 24 + payLen, @seal[24], 16) then
      Corrupt(Format('version %d: truncated index', [k + 1]));
    aad := nil;
    PutBytes(aad, 'SYCI');
    PutU32(aad, k + 1);
    PutU32(aad, rawLen);
    PutU32(aad, packedField);
    if not OpenData(sealer.keys.aead, aad, @payload[0], payLen, @seal[0]) then
      Corrupt(Format('version %d: the index does not authenticate', [k + 1]));
  end
  else if not ReadAt(v^.istart + SizeOf(ih), @payload[0], payLen) then
    Corrupt(Format('version %d: truncated index', [k + 1]));
  SetLength(raw, rawLen + 1);
  if packedField and $80000000 <> 0 then
    Move(payload[0], raw[0], rawLen)
  else
  begin
    SylzDCtxInit(ctx);
    try
      if SylzDecompressCtx(ctx, @payload[0], payLen, @raw[0], rawLen) <> SizeInt(rawLen) then
        Corrupt(Format('version %d: corrupt index', [k + 1]));
    finally
      SylzDCtxFree(ctx);
    end;
  end;
  if not indexEnc and (crc32(0, @raw[0], rawLen) <> sum) then
    Corrupt(Format('version %d: index checksum mismatch', [k + 1]));
  payload := nil;
  firstFrag := Length(fragSize) + 1;
  v^.firstFrag := firstFrag;
  if enc then
  begin
    { format 3: the time first, then the index as in format 2 }
    v^.time := LEtoN(PInt64(@raw[0])^);
    DecodeIndex(@raw[8], rawLen - 8, firstFrag, prm.maxSize, blockExtra, v^.idx,
      Format('%s, version %d', [name, k + 1]));
  end
  else
    DecodeIndex(@raw[0], rawLen, firstFrag, prm.maxSize, 0, v^.idx,
      Format('%s, version %d', [name, k + 1]));
  raw := nil;

  { where each block and fragment is }
  nf := Length(v^.idx.frags);
  SetLength(fragSize, firstFrag - 1 + nf);
  SetLength(fragOff, firstFrag - 1 + nf);
  SetLength(fragBlock, firstFrag - 1 + nf);
  v^.firstBlock := Length(blocks);
  SetLength(blocks, Length(blocks) + Length(v^.idx.blocks));
  p := v^.vstart + vheadSize;
  f := 0;
  for i := 0 to High(v^.idx.blocks) do
  begin
    blk := @blocks[v^.firstBlock + i];
    blk^.pos := p;
    blk^.bytes := v^.idx.blocks[i].bytes;
    blk^.firstFrag := firstFrag + f;
    blk^.frags := v^.idx.blocks[i].frags;
    blk^.ver := k;
    blockRaw := 0;
    for j := 0 to blk^.frags - 1 do
    begin
      fragSize[blk^.firstFrag - 1 + j] := v^.idx.frags[f + j].size;
      fragOff[blk^.firstFrag - 1 + j] := blockRaw;
      fragBlock[blk^.firstFrag - 1 + j] := v^.firstBlock + i;
      Inc(blockRaw, v^.idx.frags[f + j].size);
    end;
    if blockRaw > MAX_BLOCK then
      Corrupt(Format('version %d: a block over 512 MiB', [k + 1]));
    blk^.rawLen := blockRaw;
    Inc(f, blk^.frags);
    Inc(p, blk^.bytes);
  end;
  if p + 4 <> v^.istart then
    Corrupt(Format('version %d: the blocks do not lead to the index', [k + 1]));

  { file sizes against their fragments }
  for i := 0 to High(v^.idx.entries) do
  begin
    e := @v^.idx.entries[i];
    if e^.kind <> ET_FILE then
      Continue;
    total := 0;
    for j := 0 to High(e^.refs) do
      Inc(total, fragSize[e^.refs[j] - 1]);
    if total <> e^.meta.size then
      Corrupt(Format('version %d: %s: size does not match its fragments', [k + 1, e^.path]));
  end;
end;

{ block b's record into job, checked against the index: its payload, and
  for format 3 its nonce and tag (the job's pre hook opens it) }
procedure TArchive.LoadBlock(b: SizeInt; job: TJob);
var
  w: array[0..BLOCKHDR_SIZE - 1] of Byte;
  rawLen, packedField, payLen: UInt32;
  blk: ^TArcBlock;
  at: Int64;
begin
  blk := @blocks[b];
  if not ReadAt(blk^.pos, @w, BLOCKHDR_SIZE) then
    Corrupt(Format('truncated block at offset %d', [blk^.pos]));
  rawLen := LEtoN(PUInt32(@w[0])^);
  packedField := LEtoN(PUInt32(@w[4])^);
  payLen := packedField and $7FFFFFFF;
  if (Int64(rawLen) <> blk^.rawLen) or (BLOCKHDR_SIZE + blockExtra + Int64(payLen) <> blk^.bytes)
     or ((packedField and $80000000 <> 0) and (payLen <> rawLen))
     or (enc and (PUInt32(@w[8])^ <> 0)) then
    Corrupt(Format('the block at offset %d does not match the index', [blk^.pos]));
  job.Reserve(rawLen, payLen);
  at := blk^.pos + BLOCKHDR_SIZE;
  if enc then
  begin
    if not ReadAt(at, @job.seal[0], 24) or not ReadAt(at + 24 + payLen, @job.seal[24], 16) then
      Corrupt(Format('truncated block at offset %d', [blk^.pos]));
    Inc(at, 24);
  end;
  if not ReadAt(at, job.payload, payLen) then
    Corrupt(Format('truncated block at offset %d', [blk^.pos]));
  job.n := rawLen;
  job.payLen := payLen;
  job.stored := packedField and $80000000 <> 0;
  job.sum := LEtoN(PUInt32(@w[8])^);
  job.tag := b;
end;

function TArchive.State(upTo: SizeInt): TEntries;
var
  i: SizeInt;
begin
  Result := nil;
  for i := 0 to upTo - 1 do
    Result := ApplyVersion(Result, versions[i].idx.entries);
end;

{ -u: how many versions make the state asked for (all without it) }
function VersionsUntil(a: TArchive; const spec: string): SizeInt;
var
  n, y, mo, d, h, mi, sec: Integer;
  t: Int64;
  ok: Boolean;
begin
  Result := Length(a.versions);
  if spec = '' then
    Exit;
  if TryStrToInt(spec, n) then
  begin
    if (n < 1) or (n > Length(a.versions)) then
      Fail(EXIT_USAGE, Format('%s has versions 1..%d, not %s', [a.name, Length(a.versions), spec]));
    Exit(n);
  end;
  { YYYY-MM-DD[THH:MM[:SS]], local time }
  h := 23;
  mi := 59;
  sec := 59;
  ok := (Length(spec) in [10, 16, 19]) and (spec[5] = '-') and (spec[8] = '-')
    and TryStrToInt(Copy(spec, 1, 4), y) and TryStrToInt(Copy(spec, 6, 2), mo)
    and TryStrToInt(Copy(spec, 9, 2), d);
  if ok and (Length(spec) >= 16) then
    ok := (spec[11] in ['T', ' ']) and (spec[14] = ':') and TryStrToInt(Copy(spec, 12, 2), h)
      and TryStrToInt(Copy(spec, 15, 2), mi);
  if ok and (Length(spec) = 16) then
    sec := 59;
  if ok and (Length(spec) = 19) then
    ok := (spec[17] = ':') and TryStrToInt(Copy(spec, 18, 2), sec);
  ok := ok and (mo in [1..12]) and (d in [1..31]) and (h in [0..23]) and (mi in [0..59])
    and (sec in [0..59]);
  if not ok then
    Fail(EXIT_USAGE, '-u takes a version number or a date YYYY-MM-DD[THH:MM[:SS]], not "' + spec + '"');
  t := Round((EncodeDate(y, mo, d) + EncodeTime(h, mi, sec, 0) - UnixDateDelta) * 86400)
    + Int64(GetLocalTimeOffset) * 60;
  Result := 0;
  while (Result < Length(a.versions)) and (a.versions[Result].time <= t) do
    Inc(Result);
  if Result = 0 then
    Fail(EXIT_USAGE, Format('%s: no version as of %s (the first is from %s)',
      [a.name, spec, FormatTime(a.versions[0].time, True)]));
end;

{ opens ARCHIVE, from stdin through a temporary copy }
function OpenArchive(const path: string; out tmp: string; needData: Boolean;
  const opts: TOptions): TArchive;
var
  s: TStream;
begin
  tmp := '';
  if path = '-' then
  begin
    if IsTerminal(0) then
      Fail(EXIT_USAGE, 'no input: stdin is a terminal');
    s := StdStream(0);
    try
      tmp := SpoolToTemp([], s);
    finally
      s.Free;
    end;
    Result := TArchive.Open(tmp, '(stdin)', False, needData, opts);
  end
  else
    Result := TArchive.Open(path, path, False, needData, opts);
end;

procedure WarnDamaged(a: TArchive; var code: Integer);
begin
  if a.damaged then
  begin
    WriteLn(StdErr, 'syc: ', a.name, ': data after the last complete version (an interrupted',
      ' syc a?), ignored');
    code := Max(code, EXIT_WARN);
  end;
end;

{ ── syc a ──────────────────────────────────────────────────────────────── }

{ the same as the archive has it: nothing to store again }
function SameMeta(const a, b: TMeta): Boolean;
begin
  Result := (a.kind = b.kind) and (a.mtime = b.mtime) and (a.attrKind = b.attrKind)
    and (a.attrs = b.attrs) and (a.uid = b.uid) and (a.gid = b.gid);
  if Result and (a.kind = ET_FILE) then
    Result := a.size = b.size;
  if Result and (a.kind = ET_SYMLINK) then
    Result := a.target = b.target;
end;

{ A new archive, or a new version at the end of one: only what changed
  since the last version (new or modified entries, and deletions under the
  PATHs given), its new fragments deduplicated against every version. The
  old versions are never rewritten: an interrupted syc a leaves bytes
  after the last commit, which readers ignore and the next syc a cuts. }
function AddCommand(const opts: TOptions): Integer;
var
  a: TAdder;
  arc: TArchive;
  arcPath, tmpPath, local, keep: string;
  toStdout, appending: Boolean;
  roots: array of string;
  prev, changed: TEntries;
  i, j, k, nChanged, nDeleted, nSame: SizeInt;
  c: Integer;
  goodEnd, vstart, total: Int64;
  vnum: UInt32;
  fmt: Byte;
  vheadSize: Integer;
  hdr: array[0..HEADER_SIZE - 1] of Byte;
  vhead: array[0..VHEAD_SIZE - 1] of Byte;
  fs: TFileStream;
  hdrB, pw, rec: TBytes;
begin
  arcPath := opts.operands[0];
  toStdout := arcPath = '-';
  appending := not toStdout and FileExists(arcPath);
  if toStdout and IsTerminal(1) then
    Fail(EXIT_USAGE, 'an archive is not written to a terminal');
  tmpPath := '';
  arc := nil;
  a := TAdder.Create(opts);
  try
  try
    a.status := EXIT_OK;
    if not toStdout then
    begin
      a.arcFull := ExpandFileName(arcPath);
      a.tmpFull := a.arcFull + TMP_SUFFIX;
    end;

    { the archive so far: its last state, its fragments for dedup }
    prev := nil;
    goodEnd := 0;
    vnum := 1;
    fmt := ARC_FMT;   { appending: the archive's own }
    if opts.visibleNames and not EncryptionRequested(opts) then
      Fail(EXIT_USAGE, '--visible-names goes with a password (-p)');
    if appending then
    begin
      arc := TArchive.Open(arcPath, arcPath, True, True, opts);
      if arc.enc then
      begin
        { the archive's keys and mode }
        a.enc := True;
        a.indexEnc := arc.indexEnc;
        a.sealer := TArcSealer.Create;
        a.sealer.keys := arc.sealer.keys;
        if opts.visibleNames then
          Fail(EXIT_USAGE, '--visible-names is chosen when an archive is created');
      end
      else if EncryptionRequested(opts) then
        Fail(EXIT_USAGE, arcPath + ' is not encrypted: a version cannot add a password to it');
      a.prm := arc.prm;
      fmt := arc.fmt;
      prev := arc.State(Length(arc.versions));
      for i := 0 to High(arc.versions) do
        with arc.versions[i] do
          for j := 0 to High(idx.frags) do
            DedupAdd(a.dedup, idx.frags[j].hash, firstFrag + j);
      a.nextFrag := Length(arc.fragSize) + 1;
      vnum := Length(arc.versions) + 1;
      if Length(arc.versions) > 0 then
        goodEnd := arc.versions[High(arc.versions)].commitPos + COMMIT_SIZE
      else
        goodEnd := arc.dataStart;
      if goodEnd < arc.size then
      begin
        WriteLn(StdErr, Format('syc: %s: %d bytes after the last complete version (an interrupted '
          + 'syc a) are cut', [arcPath, arc.size - goodEnd]));
      end;
      FreeAndNil(arc);
    end;

    { what is there now, sorted by path, each path once }
    SetLength(roots, Length(opts.operands) - 1);
    for i := 1 to High(opts.operands) do
    begin
      try
        roots[i - 1] := StoredPath(opts.operands[i]);
      except
        on E: EConvertError do
          Fail(EXIT_USAGE, E.Message);
      end;
      if opts.cdDir <> '' then
        local := IncludeTrailingPathDelimiter(opts.cdDir) + opts.operands[i]
      else
        local := opts.operands[i];
      a.Walk(local, roots[i - 1]);
    end;
    SetLength(a.entries, a.count);
    if a.count > 1 then
      SortEntries(a.entries, 0, a.count - 1);
    k := 0;
    for i := 0 to a.count - 1 do
      if (k = 0) or (a.entries[i].path <> a.entries[k - 1].path) then
      begin
        a.entries[k] := a.entries[i];
        Inc(k);
      end;
    SetLength(a.entries, k);
    a.count := k;

    { against the last version: changed or new entries, and deletions of
      what was under the PATHs and is gone (not of what could not be read
      or is excluded: a.failed, Excluded) }
    SetLength(changed, a.count + Length(prev));
    nChanged := 0;
    nDeleted := 0;
    nSame := 0;
    i := 0;
    j := 0;
    while (i < a.count) or (j < Length(prev)) do
    begin
      if i >= a.count then
        c := 1
      else if j >= Length(prev) then
        c := -1
      else
        c := ComparePaths(a.entries[i].path, prev[j].path);
      if c < 0 then
      begin
        changed[nChanged] := a.entries[i];
        Inc(nChanged);
        Inc(i);
      end
      else if c > 0 then
      begin
        if not opts.noDelete and not Excluded(opts.excludes, prev[j].path)
           and not a.Unread(prev[j].path) then
          for k := 0 to High(roots) do
            if Under(roots[k], prev[j].path) then
            begin
              changed[nChanged] := Default(TEntry);
              changed[nChanged].path := prev[j].path;
              changed[nChanged].kind := ET_DELETED;
              Inc(nChanged);
              Inc(nDeleted);
              Break;
            end;
        Inc(j);
      end
      else
      begin
        if SameMeta(a.entries[i].meta, prev[j].meta) then
          Inc(nSame)
        else
        begin
          changed[nChanged] := a.entries[i];
          Inc(nChanged);
        end;
        Inc(i);
        Inc(j);
      end;
    end;
    SetLength(changed, nChanged);
    a.entries := changed;
    a.count := nChanged;
    if a.count = 0 then
    begin
      if appending then
      begin
        if opts.verbosity <> vQuiet then
          WriteLn(StdErr, Format('%s: no changes (%d entries unchanged), no version added',
            [arcPath, nSame]));
        Exit(a.status);
      end;
      Warn(opts, 'nothing to add: no archive written');
      Exit(Max(a.status, EXIT_WARN));
    end;

    { where the version goes: a new file (renamed into place when whole),
      stdout, or the end of the archive }
    if toStdout then
      a.fout := StdStream(1)
    else if appending then
    begin
      fs := TFileStream.Create(arcPath, fmOpenReadWrite or fmShareDenyWrite);
      a.fout := fs;
      fs.Size := goodEnd;
      fs.Position := goodEnd;
    end
    else
    begin
      tmpPath := arcPath + TMP_SUFFIX;
      a.fout := TFileStream.Create(tmpPath, fmCreate);
    end;
    try
      if not appending then
      begin
        Move(ARC_MAGIC[1], hdr[0], 4);
        hdr[4] := ARC_FMT;
        hdr[5] := CDC_MIN_LOG;
        hdr[6] := CDC_AVG_LOG;
        hdr[7] := CDC_MAX_LOG;
        if EncryptionRequested(opts) then
        begin
          { format 3: the key record after the header }
          hdr[4] := ARC_FMT_ENC;
          fmt := ARC_FMT_ENC;
          a.enc := True;
          a.indexEnc := not opts.visibleNames;
          SetLength(hdrB, HEADER_SIZE);
          Move(hdr, hdrB[0], HEADER_SIZE);
          pw := GetPassword(opts, True, arcPath);
          a.sealer := TArcSealer.Create;
          if a.indexEnc then
            NewKeyRecord(hdrB, pw, UInt32(opts.kdfMemMiB) * 1024, KEYREC_FLAG_INDEX, a.sealer.keys, rec)
          else
            NewKeyRecord(hdrB, pw, UInt32(opts.kdfMemMiB) * 1024, 0, a.sealer.keys, rec);
          Wipe(@pw[0], Length(pw));
          a.fout.WriteBuffer(hdr, HEADER_SIZE);
          a.fout.WriteBuffer(rec[0], KEYREC_SIZE);
          goodEnd := HEADER_SIZE + KEYREC_SIZE;
        end
        else
        begin
          a.fout.WriteBuffer(hdr, HEADER_SIZE);
          goodEnd := HEADER_SIZE;
        end;
      end;
      if a.enc then
      begin
        { the keyed cutter, the version's number for the AADs }
        MakeGear(LEtoN(PUInt64(@a.sealer.keys.cdc[0])^), a.gearK);
        a.prm.gear := @a.gearK[0];
        a.sealer.vnum := vnum;
      end;
      vstart := goodEnd;
      if fmt = 1 then
        vheadSize := VHEAD_SIZE_1
      else
        vheadSize := VHEAD_SIZE;
      FillChar(vhead, SizeOf(vhead), 0);
      Move(VHEAD_MAGIC[1], vhead[0], 4);
      PUInt32(@vhead[4])^ := NtoLE(vnum);
      if fmt <> ARC_FMT_ENC then
        PInt64(@vhead[8])^ := NtoLE(UnixNow);   { format 3: 0, the time is in the index }
      vhead[16] := CODEC_SYLZ;   { format 2 only: format 1 ends before }
      a.fout.WriteBuffer(vhead, vheadSize);
      a.pos := vstart + vheadSize;

      a.blockSize := SizeInt(opts.blockMiB) shl 20;
      a.pipe := TPipeline.Create(opts.threads, False, opts.level, opts.flags);
      for i := 0 to a.pipe.Slots - 1 do
        a.pipe.jobs[i].Reserve(a.blockSize, SylzBound(a.blockSize));
      if a.enc then
      begin
        a.pipe.SetPre(nil, True);
        a.pipe.SetPost(@a.sealer.SealJob);
      end;
      a.slot := 0;
      a.pool := TTaskPool.Create(opts.threads);
      SetLength(a.refCount, a.count);
      total := 0;
      for i := 0 to a.count - 1 do
        if a.entries[i].kind = ET_FILE then
          Inc(total, a.entries[i].meta.size);
      a.prog := TProgress.Create(opts.progress, total);
      a.ReadAll;
      for i := 0 to a.count - 1 do
      begin
        case a.entries[i].kind of
          ET_FILE: Inc(a.nFiles);
          ET_DIR: Inc(a.nDirs);
          ET_SYMLINK: Inc(a.nLinks);
        end;
        if a.entries[i].kind = ET_DELETED then
          Note(opts, a.entries[i].path + ' (deleted)')
        else if a.entries[i].kind <> ET_OTHER then
          Note(opts, a.entries[i].path);
      end;
      a.prog.Finish;
      j := 0;
      for i := 0 to a.count - 1 do
        if a.entries[i].kind <> ET_OTHER then
        begin
          SetLength(a.entries[i].refs, a.refCount[i]);
          a.entries[j] := a.entries[i];
          Inc(j);
        end;
      SetLength(a.entries, j);
      a.Submit;
      while a.blocksWritten < a.blocksSubmitted do
        a.WriteSlot(a.blocksWritten mod a.pipe.Slots);
      WriteU32(a.fout, 0);
      Inc(a.pos, 4);
      SetLength(a.idx.blocks, a.nBlocks);
      SetLength(a.idx.frags, a.nFrags);
      a.idx.entries := a.entries;
      a.WriteIndexAndCommit(vstart);
    except
      { an append that fails leaves the archive as it was }
      if appending then
        try
          TFileStream(a.fout).Size := goodEnd;
        except
        end;
      raise;
    end;
    FreeAndNil(a.fout);
    if tmpPath <> '' then
    begin
      if not ReplaceFile(tmpPath, arcPath) then
      begin
        keep := tmpPath;
        tmpPath := '';
        Fail(EXIT_FATAL, 'cannot create ' + arcPath + '; the archive is in ' + keep);
      end;
      tmpPath := '';
    end;
    if opts.verbosity <> vQuiet then
      WriteLn(StdErr, Format('%s: version %d: %d files, %d directories, %d links added or changed, '
        + '%d deleted, %d unchanged; %d bytes read, %d written, %d in repeated fragments',
        [arcPath, vnum, a.nFiles, a.nDirs, a.nLinks, nDeleted, nSame, a.totalIn, a.pos - vstart,
         a.dupBytes]));
    Result := a.status;
  except
    on E: Exception do
    begin
      if tmpPath <> '' then
        SysUtils.DeleteFile(tmpPath);
      arc.Free;
      FreeAndNil(a.fout);
      if E is ESycError then
        raise;
      if E is EOutOfMemory then
        Fail(EXIT_FATAL, arcPath + ': out of memory');
      Fail(EXIT_FATAL, arcPath + ': ' + E.Message);
    end;
  end;
  finally
    a.Free;
  end;
end;

{ ── syc l ──────────────────────────────────────────────────────────────── }

function ModeString(const e: TEntry): string;
const
  RWX = 'rwxrwxrwx';
var
  i: Integer;
begin
  case e.kind of
    ET_DIR: Result := 'd';
    ET_SYMLINK: Result := 'l';
  else
    Result := '-';
  end;
  case e.meta.attrKind of
    AK_UNIX:
      begin
        for i := 0 to 8 do
          if e.meta.attrs and (1 shl (8 - i)) <> 0 then
            Result := Result + RWX[i + 1]
          else
            Result := Result + '-';
        { setuid, setgid, sticky over the x of owner, group, others, as ls
          shows them: lower case when x is set too }
        if e.meta.attrs and $800 <> 0 then
          if Result[4] = 'x' then Result[4] := 's' else Result[4] := 'S';
        if e.meta.attrs and $400 <> 0 then
          if Result[7] = 'x' then Result[7] := 's' else Result[7] := 'S';
        if e.meta.attrs and $200 <> 0 then
          if Result[10] = 'x' then Result[10] := 't' else Result[10] := 'T';
      end;
    AK_WINDOWS:
      begin
        if e.meta.attrs and 1 <> 0 then Result := Result + 'R' else Result := Result + '-';
        if e.meta.attrs and 2 <> 0 then Result := Result + 'H' else Result := Result + '-';
        if e.meta.attrs and 4 <> 0 then Result := Result + 'S' else Result := Result + '-';
        if e.meta.attrs and $20 <> 0 then Result := Result + 'A' else Result := Result + '-';
        Result := Result + '     ';
      end;
  else
    Result := Result + '         ';
  end;
end;

{ path is selected by the filters (none: everything) }
function Selected(const filters: array of string; const path: string): Boolean;
var
  i: Integer;
begin
  if Length(filters) = 0 then
    Exit(True);
  for i := 0 to High(filters) do
    if (path = filters[i]) or GlobMatch(filters[i], path)
       or ((Length(path) > Length(filters[i])) and (Copy(path, 1, Length(filters[i]) + 1) = filters[i] + '/')) then
      Exit(True);
  Result := False;
end;

function ListCommand(const opts: TOptions): Integer;
var
  a: TArchive;
  tmp, line: string;
  st: TEntries;
  filters: array of string;
  i, n, v, upTo: SizeInt;
  shown: Int64;
begin
  Result := EXIT_OK;
  SetLength(filters, Length(opts.operands) - 1);
  for i := 1 to High(opts.operands) do
    filters[i - 1] := StoredPath(opts.operands[i]);
  a := OpenArchive(opts.operands[0], tmp, False, opts);
  try
    WarnDamaged(a, Result);
    upTo := VersionsUntil(a, opts.untilSpec);
    if opts.allVersions then
    begin
      { every entry of every version, by path then version }
      n := 0;
      for v := 0 to upTo - 1 do
        Inc(n, Length(a.versions[v].idx.entries));
      SetLength(st, n);
      n := 0;
      for v := 0 to upTo - 1 do
        for i := 0 to High(a.versions[v].idx.entries) do
        begin
          st[n] := a.versions[v].idx.entries[i];
          st[n].ver := v + 1;
          Inc(n);
        end;
      if n > 1 then
        SortEntries(st, 0, n - 1);
    end
    else
      st := a.State(upTo);
    shown := 0;
    for i := 0 to High(st) do
    begin
      if not Selected(filters, st[i].path) or Excluded(opts.excludes, st[i].path) then
        Continue;
      line := st[i].path;
      if st[i].kind = ET_DELETED then
      begin
        WriteLn(Format('%5d  %s', [st[i].ver, line + '  (deleted)']));
        Inc(shown);
        Continue;
      end;
      if st[i].kind = ET_DIR then
        line := line + '/'
      else if st[i].kind = ET_SYMLINK then
        line := line + ' -> ' + st[i].meta.target;
      if opts.longList then
        line := Format('%s %14d  %s  %s', [ModeString(st[i]), st[i].meta.size,
          FormatTime(st[i].meta.mtime div 1000000000, False), line]);
      if opts.allVersions then
        line := Format('%5d  %s', [st[i].ver, line]);
      WriteLn(line);
      Inc(shown);
    end;
    if (Length(filters) > 0) and (shown = 0) then
    begin
      WriteLn(StdErr, 'syc: nothing matches');
      Result := Max(Result, EXIT_WARN);
    end;
  finally
    a.Free;
    if tmp <> '' then
      SysUtils.DeleteFile(tmp);
  end;
end;

{ ── syc i ──────────────────────────────────────────────────────────────── }

function InfoCommand(const opts: TOptions): Integer;
var
  a: TArchive;
  tmp: string;
  i, j: SizeInt;
  files, dirs, links, deleted, added, newData, stored: Int64;
  st: TEntries;
  totalFiles, totalSize, uniq: Int64;
begin
  Result := EXIT_OK;
  a := OpenArchive(opts.operands[0], tmp, False, opts);
  try
    WarnDamaged(a, Result);
    WriteLn(Format('%s: %d version(s), %d bytes, fragments %d / %d / %d KiB (min / average / max)',
      [a.name, Length(a.versions), a.size, a.prm.minSize shr 10, a.prm.avgSize shr 10,
       a.prm.maxSize shr 10]));
    WriteLn;
    WriteLn('version  date                   files   dirs  links  deleted           added        new data          stored');
    for i := 0 to High(a.versions) do
      with a.versions[i] do
      begin
        files := 0; dirs := 0; links := 0; deleted := 0; added := 0; newData := 0;
        for j := 0 to High(idx.entries) do
          case idx.entries[j].kind of
            ET_FILE:
              begin
                Inc(files);
                Inc(added, idx.entries[j].meta.size);
              end;
            ET_DIR: Inc(dirs);
            ET_SYMLINK: Inc(links);
            ET_DELETED: Inc(deleted);
          end;
        for j := 0 to High(idx.frags) do
          Inc(newData, idx.frags[j].size);
        stored := commitPos + COMMIT_SIZE - vstart;
        WriteLn(Format('%7d  %s  %6d %6d %6d %8d %15d %15d %15d',
          [vnum, FormatTime(time, True), files, dirs, links, deleted, added, newData, stored]));
      end;
    st := a.State(Length(a.versions));
    totalFiles := 0;
    totalSize := 0;
    for i := 0 to High(st) do
      if st[i].kind = ET_FILE then
      begin
        Inc(totalFiles);
        Inc(totalSize, st[i].meta.size);
      end;
    uniq := 0;
    for i := 0 to High(a.fragSize) do
      Inc(uniq, a.fragSize[i]);
    WriteLn;
    WriteLn(Format('latest version: %d files, %s; all versions hold %s of unique data in %d fragments,',
      [totalFiles, HumanSize(totalSize), HumanSize(uniq), Length(a.fragSize)]));
    WriteLn(Format('stored in %s (%.2f%% of the unique data)',
      [HumanSize(a.size), a.size * 100.0 / Max(uniq, 1)]));
  finally
    a.Free;
    if tmp <> '' then
      SysUtils.DeleteFile(tmp);
  end;
end;

{ ── syc t ──────────────────────────────────────────────────────────────── }

type
  { checks each fragment's hash on the thread that decoded its block }
  THashCheck = class
    a: TArchive;
    procedure Check(job: TJob);
  end;

procedure THashCheck.Check(job: TJob);
var
  blk: ^TArcBlock;
  v: ^TVersion;
  first, k, n: SizeInt;   { fragment numbers fit: every fragment has an entry in memory }
  msg: array of PByte;
  len: array of SizeInt;
  h: array of TBlake2sDigest;
begin
  blk := @a.blocks[job.tag];
  v := @a.versions[blk^.ver];
  first := blk^.firstFrag;
  n := blk^.frags;
  SetLength(msg, n);
  SetLength(len, n);
  SetLength(h, n);
  for k := 0 to n - 1 do
  begin
    msg[k] := job.raw + a.fragOff[first + k - 1];
    len[k] := a.fragSize[first + k - 1];
  end;
  if a.enc then
    Blake2sManyKey(@a.sealer.keys.frag[0], 32, @msg[0], @len[0], n, @h[0])
  else
    Blake2sMany(@msg[0], @len[0], n, @h[0]);
  for k := 0 to n - 1 do
    if CompareByte(h[k], v^.idx.frags[first + k - v^.firstFrag].hash, SizeOf(TBlake2sDigest)) <> 0 then
    begin
      job.failed := first + k;
      Exit;
    end;
end;

function TestArchive(const opts: TOptions; const path, name: string): Integer;
var
  a: TArchive;
  pipe: TPipeline;
  hc: THashCheck;
  nb, b, done: SizeInt;
  checkedBytes, total: Int64;
  prog: TProgress;

  { the block in slot s: decoded, its CRC and its fragments' hashes
    checked by the job }
  procedure CheckSlot(s: SizeInt);
  var
    job: TJob;
    blk: ^TArcBlock;
  begin
    pipe.Finish(s);
    job := pipe.jobs[s];
    blk := @a.blocks[done];
    if (not job.ok) and (job.failed = -1) then
      a.Corrupt(Format('the block at offset %d does not authenticate (changed, moved or from '
        + 'another archive)', [blk^.pos]));
    if not job.ok then
      a.Corrupt(Format('the block at offset %d: corrupt data or checksum mismatch', [blk^.pos]));
    if job.failed <> 0 then
      a.Corrupt(Format('fragment %d (block at offset %d): hash mismatch', [job.failed, blk^.pos]));
    Inc(checkedBytes, job.n);
    prog.Add(job.n);
    Inc(done);
  end;

var
  s: SizeInt;
begin
  Result := EXIT_OK;
  a := TArchive.Open(path, name, False, True, opts);
  pipe := nil;
  prog := nil;
  hc := THashCheck.Create;
  hc.a := a;
  try
    WarnDamaged(a, Result);
    pipe := TPipeline.Create(opts.threads, True, 0, 0);
    pipe.SetPost(@hc.Check);
    if a.enc then
      pipe.SetPre(@a.sealer.OpenJob, True);
    nb := Length(a.blocks);
    total := 0;
    for b := 0 to nb - 1 do
      Inc(total, a.blocks[b].rawLen);
    prog := TProgress.Create(opts.progress, total);
    done := 0;
    checkedBytes := 0;
    for b := 0 to nb - 1 do
    begin
      s := b mod pipe.Slots;
      if b >= pipe.Slots then
        CheckSlot(s);
      a.LoadBlock(b, pipe.jobs[s]);
      pipe.Start(s);
    end;
    while done < nb do
      CheckSlot(done mod pipe.Slots);
    prog.Finish;
    if opts.verbosity <> vQuiet then
      WriteLn(StdErr, Format('%s: ok, %d version(s), %d fragments, %d bytes checked',
        [name, Length(a.versions), Length(a.fragSize), checkedBytes]));
  finally
    if prog <> nil then
      prog.Finish;
    prog.Free;
    pipe.Free;
    hc.Free;
    a.Free;
  end;
end;

{ ── syc x ──────────────────────────────────────────────────────────────── }

type
  TAction = (acSkip, acWrite, acReplace);

  { where a file goes that cannot be created: its blocks are still read
    in their turn }
  TDiscard = class(TStream)
    function Write(const Buffer; Count: LongInt): LongInt; override;
  end;

  { Files are written in path order. The blocks they need, in that order
    (a block needed again later is decoded again: memory stays at 2N
    blocks), are decoded ahead by the pipeline, each fragment's hash
    checked on the thread that decoded it. }
  TExtractor = class
    opts: TOptions;
    a: TArchive;
    status: Integer;
    outDir: string;
    pipe: TPipeline;
    hc: THashCheck;
    access: array of SizeInt;     { block numbers, in the order used }
    nAccess, cur: SizeInt;
    nFiles, nDirs, nLinks, bytesOut: Int64;
    prog: TProgress;
    procedure StartAccess(k: SizeInt);
    function JobFor(blk: SizeInt): TJob;
    procedure WriteFile(const e: TEntry; s: TStream);
    function SafeParents(const stored: string): Boolean;
  end;

function TDiscard.Write(const Buffer; Count: LongInt): LongInt;
begin
  Result := Count;
end;

procedure TExtractor.StartAccess(k: SizeInt);
begin
  if k >= nAccess then
    Exit;
  a.LoadBlock(access[k], pipe.jobs[k mod pipe.Slots]);
  pipe.Start(k mod pipe.Slots);
end;

{ the decoded block blk: the next access, by construction }
function TExtractor.JobFor(blk: SizeInt): TJob;
var
  s: SizeInt;
begin
  if (cur < 0) or (access[cur] <> blk) then
  begin
    Inc(cur);
    if (cur >= nAccess) or (access[cur] <> blk) then
      Fail(EXIT_FATAL, 'internal error: blocks out of order');
    { the previous access's slot is free: the next block ahead goes in }
    if cur > 0 then
      StartAccess(cur - 1 + pipe.Slots);
    s := cur mod pipe.Slots;
    pipe.Finish(s);
    if (not pipe.jobs[s].ok) and (pipe.jobs[s].failed = -1) then
      a.Corrupt(Format('the block at offset %d does not authenticate (changed, moved or from '
        + 'another archive)', [a.blocks[blk].pos]));
    if not pipe.jobs[s].ok then
      a.Corrupt(Format('the block at offset %d: corrupt data or checksum mismatch',
        [a.blocks[blk].pos]));
    if pipe.jobs[s].failed <> 0 then
      a.Corrupt(Format('fragment %d (block at offset %d): hash mismatch',
        [pipe.jobs[s].failed, a.blocks[blk].pos]));
  end;
  Result := pipe.jobs[cur mod pipe.Slots];
end;

procedure TExtractor.WriteFile(const e: TEntry; s: TStream);
var
  i: SizeInt;
  f: SizeInt;
  job: TJob;
begin
  for i := 0 to High(e.refs) do
  begin
    f := e.refs[i] - 1;
    job := JobFor(a.fragBlock[f]);
    s.WriteBuffer(job.raw[a.fragOff[f]], a.fragSize[f]);
    prog.Add(a.fragSize[f]);
  end;
  Inc(bytesOut, e.meta.size);
end;

{ no directory on the way to stored is a symlink: writing through one
  could leave the output directory }
function TExtractor.SafeParents(const stored: string): Boolean;
var
  k: Integer;
begin
  for k := 1 to Length(stored) do
    if (stored[k] = '/') and IsLink(LocalPath(outDir, Copy(stored, 1, k - 1))) then
      Exit(False);
  Result := True;
end;

function ExtractCommand(const opts: TOptions): Integer;
var
  x: TExtractor;
  tmp, local, part: string;
  st, sel: TEntries;
  act: array of TAction;
  filters: array of string;
  i, n, k, b, last: SizeInt;
  fout: TStream;
  exists: Boolean;
  total: Int64;
begin
  x := TExtractor.Create;
  x.opts := opts;
  x.status := EXIT_OK;
  x.outDir := opts.outPath;
  SetLength(filters, Length(opts.operands) - 1);
  for i := 1 to High(opts.operands) do
    filters[i - 1] := StoredPath(opts.operands[i]);
  x.a := OpenArchive(opts.operands[0], tmp, True, opts);
  try
    WarnDamaged(x.a, x.status);
    st := x.a.State(VersionsUntil(x.a, opts.untilSpec));
    n := 0;
    SetLength(sel, Length(st));
    for i := 0 to High(st) do
      if Selected(filters, st[i].path) and not Excluded(opts.excludes, st[i].path) then
      begin
        sel[n] := st[i];
        Inc(n);
      end;
    SetLength(sel, n);
    if (Length(filters) > 0) and (n = 0) then
    begin
      WriteLn(StdErr, 'syc: nothing matches');
      Exit(Max(x.status, EXIT_WARN));
    end;

    { what happens to each: decided before any block is read, since the
      blocks are decoded in the order the written files need them }
    SetLength(act, n);
    if opts.toStdout then
    begin
      k := -1;
      for i := 0 to n - 1 do
        if sel[i].kind = ET_FILE then
          if k < 0 then
            k := i
          else
            Fail(EXIT_USAGE, '-O writes one file, and the filters select more');
      if k < 0 then
        Fail(EXIT_USAGE, '-O writes one file, and the filters select none');
      for i := 0 to n - 1 do
        act[i] := acSkip;
      act[k] := acWrite;
    end
    else
      for i := 0 to n - 1 do
      begin
        act[i] := acWrite;
        local := LocalPath(x.outDir, sel[i].path);
        if not x.SafeParents(sel[i].path) then
        begin
          WriteLn(StdErr, 'syc: ', local, ': a directory on the way is a symlink, skipped');
          x.status := Max(x.status, EXIT_WARN);
          act[i] := acSkip;
          Continue;
        end;
        if sel[i].kind = ET_DIR then
          Continue;   { an existing directory is merged into }
        exists := PathExists(local);
        if not exists then
          Continue;
        if DirectoryExists(local) and not IsLink(local) then
        begin
          WriteLn(StdErr, 'syc: ', local, ': a directory is in the way, skipped');
          x.status := Max(x.status, EXIT_WARN);
          act[i] := acSkip;
        end
        else if opts.force then
          act[i] := acReplace
        else
        begin
          act[i] := acSkip;
          if not opts.skipExisting then
          begin
            WriteLn(StdErr, 'syc: ', local, ' exists, skipped (-f replaces, --skip is silent)');
            x.status := Max(x.status, EXIT_WARN);
          end;
        end;
      end;

    { the blocks, in the order the files to write need them }
    last := -1;
    for i := 0 to n - 1 do
      if (act[i] <> acSkip) and (sel[i].kind = ET_FILE) then
        for k := 0 to High(sel[i].refs) do
        begin
          b := x.a.fragBlock[sel[i].refs[k] - 1];
          if b <> last then
          begin
            if x.nAccess = Length(x.access) then
              SetLength(x.access, Max(64, 2 * x.nAccess));
            x.access[x.nAccess] := b;
            Inc(x.nAccess);
            last := b;
          end;
        end;
    x.hc := THashCheck.Create;
    x.hc.a := x.a;
    x.pipe := TPipeline.Create(opts.threads, True, 0, 0);
    x.pipe.SetPost(@x.hc.Check);
    if x.a.enc then
      x.pipe.SetPre(@x.a.sealer.OpenJob, True);
    x.cur := -1;
    total := 0;
    for i := 0 to n - 1 do
      if (act[i] <> acSkip) and (sel[i].kind = ET_FILE) then
        Inc(total, sel[i].meta.size);
    x.prog := TProgress.Create(opts.progress, total);
    for k := 0 to x.pipe.Slots - 1 do
      x.StartAccess(k);

    if opts.toStdout then
    begin
      fout := StdStream(1);
      try
        for i := 0 to n - 1 do
          if act[i] = acWrite then
            x.WriteFile(sel[i], fout);
      finally
        fout.Free;
      end;
    end
    else
    begin
      { files and directories; symlinks once nothing more is written }
      for i := 0 to n - 1 do
      begin
        if act[i] = acSkip then
          Continue;
        local := LocalPath(x.outDir, sel[i].path);
        case sel[i].kind of
          ET_DIR:
            begin
              if not ForceDirectories(local) then
              begin
                WriteLn(StdErr, 'syc: ', local, ': cannot create the directory');
                x.status := Max(x.status, EXIT_WARN);
              end;
              Inc(x.nDirs);
            end;
          ET_FILE:
            begin
              part := ExtractFileDir(local);
              if (part <> '') and not ForceDirectories(part) then
              begin
                WriteLn(StdErr, 'syc: ', part, ': cannot create the directory');
                Fail(EXIT_FATAL, 'cannot go on: the files under it would be out of order');
              end;
              try
                fout := TFileStream.Create(local + TMP_SUFFIX, fmCreate);
              except
                on EFCreateError do
                begin
                  WriteLn(StdErr, 'syc: ', local, ': cannot create, skipped');
                  x.status := Max(x.status, EXIT_WARN);
                  fout := TDiscard.Create;
                  try
                    x.WriteFile(sel[i], fout);
                  finally
                    fout.Free;
                  end;
                  Continue;
                end;
              end;
              try
                x.WriteFile(sel[i], fout);
              except
                fout.Free;
                fout := nil;
                SysUtils.DeleteFile(local + TMP_SUFFIX);
                raise;
              end;
              fout.Free;
              if (act[i] = acReplace) and not RemoveFile(local) then
              begin
                SysUtils.DeleteFile(local + TMP_SUFFIX);
                WriteLn(StdErr, 'syc: ', local, ': cannot replace it');
                x.status := Max(x.status, EXIT_WARN);
                Continue;
              end;
              if not ReplaceFile(local + TMP_SUFFIX, local) then
              begin
                SysUtils.DeleteFile(local + TMP_SUFFIX);
                WriteLn(StdErr, 'syc: ', local, ': cannot create it (from ', local + TMP_SUFFIX, ')');
                x.status := Max(x.status, EXIT_WARN);
                Continue;
              end;
              if not ApplyMeta(local, sel[i].meta, opts.noPerms, opts.noOwner) then
                Note(opts, local + ': some metadata could not be set');
              Note(opts, local);
              Inc(x.nFiles);
            end;
        end;
      end;
      for i := 0 to n - 1 do
        if (act[i] <> acSkip) and (sel[i].kind = ET_SYMLINK) then
        begin
          local := LocalPath(x.outDir, sel[i].path);
          part := ExtractFileDir(local);
          if part <> '' then
            ForceDirectories(part);
          if (act[i] = acReplace) and not RemoveFile(local) then
          begin
            WriteLn(StdErr, 'syc: ', local, ': cannot replace it');
            x.status := Max(x.status, EXIT_WARN);
            Continue;
          end;
          if not MakeSymlink(sel[i].meta, local) then
          begin
            WriteLn(StdErr, 'syc: ', local, ': cannot create the symlink');
            x.status := Max(x.status, EXIT_WARN);
            Continue;
          end;
          ApplyMeta(local, sel[i].meta, opts.noPerms, opts.noOwner);
          Inc(x.nLinks);
        end;
      x.prog.Finish;
      { directories last, deepest first: writing in them changed their times }
      for i := n - 1 downto 0 do
        if (act[i] <> acSkip) and (sel[i].kind = ET_DIR) then
          ApplyMeta(LocalPath(x.outDir, sel[i].path), sel[i].meta, opts.noPerms, opts.noOwner);
      if opts.verbosity <> vQuiet then
        WriteLn(StdErr, Format('%s: %d files, %d directories, %d links extracted (%d bytes)',
          [x.a.name, x.nFiles, x.nDirs, x.nLinks, x.bytesOut]));
    end;
    Result := x.status;
  finally
    if x.prog <> nil then
      x.prog.Finish;
    x.prog.Free;
    x.pipe.Free;
    x.hc.Free;
    x.a.Free;
    x.Free;
    if tmp <> '' then
      SysUtils.DeleteFile(tmp);
  end;
end;

function RunArchiveCommand(const opts: TOptions): Integer;
begin
  case opts.cmd of
    'a': Result := AddCommand(opts);
    'x': Result := ExtractCommand(opts);
    'l': Result := ListCommand(opts);
    'i': Result := InfoCommand(opts);
  else
    Result := EXIT_USAGE;
  end;
end;

end.
