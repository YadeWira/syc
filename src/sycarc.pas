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
  Math, sylz, blake2s, syccdc, sycblocks, sycfs, sycfmt;

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

type
  TAdder = class
    opts: TOptions;
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
    { fragments cut but not yet hashed: hashed N at a time, then stored in
      order }
    pool: TTaskPool;
    batch: array of Byte;
    batchLen: SizeInt;
    bFrags: array of record
      off, len, entry: SizeInt;
    end;
    bHash: array of TBlake2sDigest;
    nb: SizeInt;
    refCount: array of SizeInt;
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
    procedure FlushBatch;
    function AddFile(ei: SizeInt): Boolean;
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
begin
  pool.Free;
  pipe.Free;
  inherited Destroy;
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
  if job.c < job.n then
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

procedure TAdder.HashOne(i: SizeInt);
begin
  Blake2s256(@batch[bFrags[i].off], bFrags[i].len, bHash[i]);
end;

{ the batch's fragments hashed in parallel, then stored in order: the
  archive does not depend on the number of threads }
procedure TAdder.FlushBatch;
var
  i: SizeInt;
begin
  pool.Run(nb, @HashOne);
  for i := 0 to nb - 1 do
    Fragment(@batch[bFrags[i].off], bFrags[i].len, bHash[i], bFrags[i].entry);
  nb := 0;
  batchLen := 0;
end;

{ reads and cuts one file into the batch; False when it could not be
  opened }
function TAdder.AddFile(ei: SizeInt): Boolean;
var
  f: TFileStream;
  buf: array of Byte;
  start, len, got, cut: SizeInt;
  eof: Boolean;
  total: Int64;
begin
  try
    f := TFileStream.Create(entries[ei].local, fmOpenRead or fmShareDenyNone);
  except
    on EFOpenError do
    begin
      Warn(opts, entries[ei].local + ': cannot open, skipped');
      status := Max(status, EXIT_WARN);
      SetLength(unreadPaths, Length(unreadPaths) + 1);
      unreadPaths[High(unreadPaths)] := entries[ei].path;
      Exit(False);
    end;
  end;
  try
    SetLength(buf, 4 * prm.maxSize);
    start := 0;
    len := 0;
    eof := False;
    total := 0;
    while True do
    begin
      { at least maxSize bytes ahead, unless the file ends sooner: a cut
        never looks further }
      if (len - start < prm.maxSize) and not eof then
      begin
        Move(buf[start], buf[0], len - start);
        len := len - start;
        start := 0;
        got := ReadFull(f, @buf[len], Length(buf) - len);
        eof := len + got < Length(buf);
        Inc(len, got);
      end;
      if start = len then
        Break;
      cut := CdcCut(prm, @buf[start], len - start);
      if batchLen + cut > Length(batch) then
        FlushBatch;
      if nb = Length(bFrags) then
      begin
        SetLength(bFrags, Max(256, 2 * nb));
        SetLength(bHash, Length(bFrags));
      end;
      Move(buf[start], batch[batchLen], cut);
      bFrags[nb].off := batchLen;
      bFrags[nb].len := cut;
      bFrags[nb].entry := ei;
      Inc(nb);
      Inc(batchLen, cut);
      Inc(start, cut);
      Inc(total, cut);
    end;
  finally
    f.Free;
  end;
  entries[ei].meta.size := total;   { what was read, if the file changed meanwhile }
  Inc(totalIn, total);
  Result := True;
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
begin
  b := Default(TByteBuf);
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
  crc := crc32(0, @b.data[0], b.len);
  istart := pos;
  fout.WriteBuffer(INDEX_MAGIC[1], 4);
  WriteU32(fout, b.len);
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
    allowEmpty: Boolean;          { an archive with no complete version is not an error }
    constructor Open(const path, aName: string; aAllowEmpty: Boolean = False);
    destructor Destroy; override;
    procedure Corrupt(const msg: string);
    function ReadAt(at: Int64; p: Pointer; n: SizeInt): Boolean;
    procedure ScanForward;
    procedure LoadVersion(k: SizeInt);
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
  Result := Result and (vstart >= HEADER_SIZE) and (istart >= vstart + VHEAD_SIZE + 4)
    and (istart + 4 + BLOCKHDR_SIZE <= at);
end;

constructor TArchive.Open(const path, aName: string; aAllowEmpty: Boolean);
var
  hdr: array[0..HEADER_SIZE - 1] of Byte;
  at, vstart, istart: Int64;
  list: array of TVersion;
  n, i: SizeInt;
  ok: Boolean;
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
  if hdr[4] <> ARC_FMT then
    Corrupt(Format('archive format %d not supported by syc %s', [hdr[4], SYC_VERSION]));
  if not ((hdr[5] >= 6) and (hdr[5] < hdr[6]) and (hdr[6] < hdr[7]) and (hdr[7] <= 24)) then
    Corrupt('bad fragment parameters in the header');
  prm := CdcParams(hdr[5], hdr[6], hdr[7]);

  { back from the end, commit by commit }
  list := nil;
  n := 0;
  at := size;
  ok := True;
  while at > HEADER_SIZE do
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
  if ok and (at = HEADER_SIZE) then
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
  inherited Destroy;
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
  at := HEADER_SIZE;
  while at < size do
  begin
    good := ReadAt(at, @w, 4) and (CompareByte(w[0], VHEAD_MAGIC[1], 4) = 0);
    p := at + VHEAD_SIZE;
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
        Inc(p, BLOCKHDR_SIZE + payLen);
      end;
    end;
    if good then
      good := ReadAt(p, @w, 4 + 8) and (CompareByte(w[0], INDEX_MAGIC[1], 4) = 0);
    if good then
    begin
      payLen := LEtoN(PUInt32(@w[8])^) and $7FFFFFFF;
      good := ReadCommit(Self, p + 4 + BLOCKHDR_SIZE + payLen, vstart, istart)
        and (vstart = at) and (istart = p);
    end;
    if not good then
      Break;
    SetLength(versions, n + 1);
    versions[n].vstart := at;
    versions[n].istart := p;
    versions[n].commitPos := p + 4 + BLOCKHDR_SIZE + payLen;
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
begin
  v := @versions[k];
  if not ReadAt(v^.vstart, @head, VHEAD_SIZE) or (CompareByte(head[0], VHEAD_MAGIC[1], 4) <> 0) then
    Corrupt(Format('version %d: bad header', [k + 1]));
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
  if (rawLen > MAX_BLOCK) or (v^.istart + SizeOf(ih) + payLen <> v^.commitPos)
     or ((packedField and $80000000 <> 0) and (payLen <> rawLen)) then
    Corrupt(Format('version %d: bad index header', [k + 1]));
  v^.indexBytes := SizeOf(ih) + payLen;
  SetLength(payload, payLen + 1);
  if not ReadAt(v^.istart + SizeOf(ih), @payload[0], payLen) then
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
  if crc32(0, @raw[0], rawLen) <> sum then
    Corrupt(Format('version %d: index checksum mismatch', [k + 1]));
  payload := nil;
  firstFrag := Length(fragSize) + 1;
  v^.firstFrag := firstFrag;
  DecodeIndex(@raw[0], rawLen, firstFrag, prm.maxSize, v^.idx,
    Format('%s, version %d', [name, k + 1]));
  raw := nil;

  { where each block and fragment is }
  nf := Length(v^.idx.frags);
  SetLength(fragSize, firstFrag - 1 + nf);
  SetLength(fragOff, firstFrag - 1 + nf);
  SetLength(fragBlock, firstFrag - 1 + nf);
  v^.firstBlock := Length(blocks);
  SetLength(blocks, Length(blocks) + Length(v^.idx.blocks));
  p := v^.vstart + VHEAD_SIZE;
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
function OpenArchive(const path: string; out tmp: string): TArchive;
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
    Result := TArchive.Open(tmp, '(stdin)');
  end
  else
    Result := TArchive.Open(path, path);
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
  goodEnd, vstart: Int64;
  vnum: UInt32;
  hdr: array[0..HEADER_SIZE - 1] of Byte;
  vhead: array[0..VHEAD_SIZE - 1] of Byte;
  fs: TFileStream;
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
    if appending then
    begin
      arc := TArchive.Open(arcPath, arcPath, True);
      a.prm := arc.prm;
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
        goodEnd := HEADER_SIZE;
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
        a.fout.WriteBuffer(hdr, HEADER_SIZE);
        goodEnd := HEADER_SIZE;
      end;
      vstart := goodEnd;
      Move(VHEAD_MAGIC[1], vhead[0], 4);
      PUInt32(@vhead[4])^ := NtoLE(vnum);
      PInt64(@vhead[8])^ := NtoLE(UnixNow);
      a.fout.WriteBuffer(vhead, VHEAD_SIZE);
      a.pos := vstart + VHEAD_SIZE;

      a.blockSize := SizeInt(opts.blockMiB) shl 20;
      a.pipe := TPipeline.Create(opts.threads, False, opts.level, opts.flags);
      for i := 0 to a.pipe.Slots - 1 do
        a.pipe.jobs[i].Reserve(a.blockSize, SylzBound(a.blockSize));
      a.slot := 0;
      a.pool := TTaskPool.Create(opts.threads);
      SetLength(a.batch, 8 shl 20);
      SetLength(a.refCount, a.count);
      for i := 0 to a.count - 1 do
      begin
        case a.entries[i].kind of
          ET_FILE:
            if a.AddFile(i) then
              Inc(a.nFiles)
            else
              a.entries[i].kind := ET_OTHER;   { left out below }
          ET_DIR: Inc(a.nDirs);
          ET_SYMLINK: Inc(a.nLinks);
        end;
        if a.entries[i].kind = ET_DELETED then
          Note(opts, a.entries[i].path + ' (deleted)')
        else if a.entries[i].kind <> ET_OTHER then
          Note(opts, a.entries[i].path);
      end;
      a.FlushBatch;
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
      for i := 0 to 8 do
        if e.meta.attrs and (1 shl (8 - i)) <> 0 then
          Result := Result + RWX[i + 1]
        else
          Result := Result + '-';
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
  a := OpenArchive(opts.operands[0], tmp);
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
  a := OpenArchive(opts.operands[0], tmp);
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
  k: SizeInt;   { fragment numbers fit: every fragment has an entry in memory }
  h: TBlake2sDigest;
begin
  blk := @a.blocks[job.tag];
  v := @a.versions[blk^.ver];
  for k := SizeInt(blk^.firstFrag) to SizeInt(blk^.firstFrag + blk^.frags - 1) do
  begin
    Blake2s256(job.raw + a.fragOff[k - 1], a.fragSize[k - 1], h);
    if CompareByte(h, v^.idx.frags[k - v^.firstFrag].hash, SizeOf(h)) <> 0 then
    begin
      job.failed := k;
      Exit;
    end;
  end;
end;

function TestArchive(const opts: TOptions; const path, name: string): Integer;
var
  a: TArchive;
  pipe: TPipeline;
  hc: THashCheck;
  nb, b, done: SizeInt;
  checkedBytes: Int64;

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
    if not job.ok then
      a.Corrupt(Format('the block at offset %d: corrupt data or checksum mismatch', [blk^.pos]));
    if job.failed <> 0 then
      a.Corrupt(Format('fragment %d (block at offset %d): hash mismatch', [job.failed, blk^.pos]));
    Inc(checkedBytes, job.n);
    Inc(done);
  end;

var
  w: array[0..BLOCKHDR_SIZE - 1] of Byte;
  rawLen, packedField, payLen: UInt32;
  job: TJob;
  s: SizeInt;
  blk: ^TArcBlock;
begin
  Result := EXIT_OK;
  a := TArchive.Open(path, name);
  pipe := nil;
  hc := THashCheck.Create;
  hc.a := a;
  try
    WarnDamaged(a, Result);
    pipe := TPipeline.Create(opts.threads, True, 0, 0);
    pipe.SetPost(@hc.Check);
    nb := Length(a.blocks);
    done := 0;
    checkedBytes := 0;
    for b := 0 to nb - 1 do
    begin
      s := b mod pipe.Slots;
      if b >= pipe.Slots then
        CheckSlot(s);
      blk := @a.blocks[b];
      if not a.ReadAt(blk^.pos, @w, BLOCKHDR_SIZE) then
        a.Corrupt(Format('truncated block at offset %d', [blk^.pos]));
      rawLen := LEtoN(PUInt32(@w[0])^);
      packedField := LEtoN(PUInt32(@w[4])^);
      payLen := packedField and $7FFFFFFF;
      if (Int64(rawLen) <> blk^.rawLen) or (BLOCKHDR_SIZE + Int64(payLen) <> blk^.bytes)
         or ((packedField and $80000000 <> 0) and (payLen <> rawLen)) then
        a.Corrupt(Format('the block at offset %d does not match the index', [blk^.pos]));
      job := pipe.jobs[s];
      job.Reserve(rawLen, payLen);
      if not a.ReadAt(blk^.pos + BLOCKHDR_SIZE, job.payload, payLen) then
        a.Corrupt(Format('truncated block at offset %d', [blk^.pos]));
      job.n := rawLen;
      job.payLen := payLen;
      job.stored := packedField and $80000000 <> 0;
      job.sum := LEtoN(PUInt32(@w[8])^);
      job.tag := b;
      pipe.Start(s);
    end;
    while done < nb do
      CheckSlot(done mod pipe.Slots);
    if opts.verbosity <> vQuiet then
      WriteLn(StdErr, Format('%s: ok, %d version(s), %d fragments, %d bytes checked',
        [name, Length(a.versions), Length(a.fragSize), checkedBytes]));
  finally
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
var
  w: array[0..BLOCKHDR_SIZE - 1] of Byte;
  rawLen, packedField, payLen: UInt32;
  job: TJob;
  blk: ^TArcBlock;
begin
  if k >= nAccess then
    Exit;
  blk := @a.blocks[access[k]];
  if not a.ReadAt(blk^.pos, @w, BLOCKHDR_SIZE) then
    a.Corrupt(Format('truncated block at offset %d', [blk^.pos]));
  rawLen := LEtoN(PUInt32(@w[0])^);
  packedField := LEtoN(PUInt32(@w[4])^);
  payLen := packedField and $7FFFFFFF;
  if (Int64(rawLen) <> blk^.rawLen) or (BLOCKHDR_SIZE + Int64(payLen) <> blk^.bytes)
     or ((packedField and $80000000 <> 0) and (payLen <> rawLen)) then
    a.Corrupt(Format('the block at offset %d does not match the index', [blk^.pos]));
  job := pipe.jobs[k mod pipe.Slots];
  job.Reserve(rawLen, payLen);
  if not a.ReadAt(blk^.pos + BLOCKHDR_SIZE, job.payload, payLen) then
    a.Corrupt(Format('truncated block at offset %d', [blk^.pos]));
  job.n := rawLen;
  job.payLen := payLen;
  job.stored := packedField and $80000000 <> 0;
  job.sum := LEtoN(PUInt32(@w[8])^);
  job.tag := access[k];
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
begin
  x := TExtractor.Create;
  x.opts := opts;
  x.status := EXIT_OK;
  x.outDir := opts.outPath;
  SetLength(filters, Length(opts.operands) - 1);
  for i := 1 to High(opts.operands) do
    filters[i - 1] := StoredPath(opts.operands[i]);
  x.a := OpenArchive(opts.operands[0], tmp);
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
    x.cur := -1;
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
          if not MakeSymlink(sel[i].meta.target, local) then
          begin
            WriteLn(StdErr, 'syc: ', local, ': cannot create the symlink');
            x.status := Max(x.status, EXIT_WARN);
            Continue;
          end;
          ApplyMeta(local, sel[i].meta, opts.noPerms, opts.noOwner);
          Inc(x.nLinks);
        end;
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
