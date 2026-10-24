{ sycfmt — the .syc archive's format (wiki: syc archive format): the
  fixed records, and the index, encoded and decoded. Decoding checks
  everything a later step relies on, so a damaged index is an error
  (EXIT_CORRUPT), never a crash. }
unit sycfmt;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, blake2s, sycblocks, sycfs;

const
  ARC_MAGIC     = 'SYCA';
  VHEAD_MAGIC   = 'SYCV';
  INDEX_MAGIC   = 'SYCI';
  COMMIT_MAGIC  = 'SYCE';
  ARC_FMT       = 1;
  HEADER_SIZE   = 8;
  VHEAD_SIZE    = 16;
  BLOCKHDR_SIZE = 12;
  COMMIT_SIZE   = 24;

type
  { a growing byte buffer, for the index }
  TByteBuf = record
    data: array of Byte;
    len: SizeInt;
  end;

  { reads a decoded index; any overrun or bad value raises EXIT_CORRUPT }
  TByteReader = record
    p: PByte;
    n, at: SizeInt;
    what: string;     { for messages }
  end;

  TBlockInfo = record
    bytes: Int64;     { header included }
    frags: Int64;
  end;

  TFragInfo = record
    size: UInt32;
    hash: TBlake2sDigest;
  end;

  TEntry = record
    path: string;
    kind: Byte;
    meta: TMeta;      { kind, size, mtime, attrs, uid/gid, target }
    refs: array of Int64;   { fragment numbers, files only }
    local: string;    { syc a: the file it comes from (not stored) }
    ver: SizeInt;     { syc l --all: the version it is from (not stored) }
  end;
  TEntries = array of TEntry;

  TIndex = record
    blocks: array of TBlockInfo;
    frags: array of TFragInfo;
    entries: TEntries;
  end;

procedure BufPut(var b: TByteBuf; p: Pointer; n: SizeInt);
procedure BufByte(var b: TByteBuf; v: Byte);
procedure BufVarint(var b: TByteBuf; v: UInt64);
procedure BufU32(var b: TByteBuf; v: UInt32);
procedure BufI64(var b: TByteBuf; v: Int64);
procedure BufStr(var b: TByteBuf; const s: string);

procedure ReaderInit(out r: TByteReader; p: PByte; n: SizeInt; const what: string);
function ReadByte(var r: TByteReader): Byte;
function ReadVarint(var r: TByteReader): UInt64;
function ReadI64(var r: TByteReader): Int64;
function ReadStr(var r: TByteReader; maxLen: SizeInt): string;

{ The index's bytes. firstFrag: the number of the version's first new
  fragment. }
procedure EncodeIndex(const idx: TIndex; firstFrag: Int64; var b: TByteBuf);
{ Decodes and checks an index: blocks holding all the new fragments,
  fragment sizes 1..maxFrag, references to fragments 1 .. firstFrag +
  Length(frags) - 1, paths valid, sorted and unique. File sizes against
  their fragments are the caller's to check (it has every version's
  fragments). }
procedure DecodeIndex(p: PByte; n: SizeInt; firstFrag, maxFrag: Int64;
  out idx: TIndex; const what: string);

implementation

procedure Grow(var b: TByteBuf; n: SizeInt);
var
  cap: SizeInt;
begin
  if b.len + n <= Length(b.data) then
    Exit;
  cap := Length(b.data) * 2;
  if cap < 4096 then
    cap := 4096;
  while cap < b.len + n do
    cap := cap * 2;
  SetLength(b.data, cap);
end;

procedure BufPut(var b: TByteBuf; p: Pointer; n: SizeInt);
begin
  if n <= 0 then
    Exit;
  Grow(b, n);
  Move(p^, b.data[b.len], n);
  Inc(b.len, n);
end;

procedure BufByte(var b: TByteBuf; v: Byte);
begin
  Grow(b, 1);
  b.data[b.len] := v;
  Inc(b.len);
end;

procedure BufVarint(var b: TByteBuf; v: UInt64);
begin
  Grow(b, 10);
  while v >= $80 do
  begin
    b.data[b.len] := Byte(v) or $80;
    Inc(b.len);
    v := v shr 7;
  end;
  b.data[b.len] := Byte(v);
  Inc(b.len);
end;

procedure BufU32(var b: TByteBuf; v: UInt32);
begin
  v := NtoLE(v);
  BufPut(b, @v, 4);
end;

procedure BufI64(var b: TByteBuf; v: Int64);
begin
  v := NtoLE(v);
  BufPut(b, @v, 8);
end;

procedure BufStr(var b: TByteBuf; const s: string);
begin
  BufVarint(b, Length(s));
  if s <> '' then
    BufPut(b, @s[1], Length(s));
end;

procedure ReaderInit(out r: TByteReader; p: PByte; n: SizeInt; const what: string);
begin
  r.p := p;
  r.n := n;
  r.at := 0;
  r.what := what;
end;

procedure Corrupt(const r: TByteReader; const msg: string);
begin
  Fail(EXIT_CORRUPT, Format('%s: corrupt index (%s at byte %d)', [r.what, msg, r.at]));
end;

function ReadByte(var r: TByteReader): Byte;
begin
  if r.at >= r.n then
    Corrupt(r, 'truncated');
  Result := r.p[r.at];
  Inc(r.at);
end;

function ReadVarint(var r: TByteReader): UInt64;
var
  b: Byte;
  shift: Integer;
begin
  Result := 0;
  shift := 0;
  repeat
    if shift > 63 then
      Corrupt(r, 'varint too long');
    b := ReadByte(r);
    Result := Result or (UInt64(b and $7F) shl shift);
    Inc(shift, 7);
  until b < $80;
end;

function ReadI64(var r: TByteReader): Int64;
begin
  if r.n - r.at < 8 then
    Corrupt(r, 'truncated');
  Result := LEtoN(PInt64(r.p + r.at)^);
  Inc(r.at, 8);
end;

function ReadStr(var r: TByteReader; maxLen: SizeInt): string;
var
  n: UInt64;
begin
  n := ReadVarint(r);
  if (n > UInt64(maxLen)) or (n > UInt64(r.n - r.at)) then
    Corrupt(r, 'string length');
  SetLength(Result, n);
  if n > 0 then
    Move(r.p[r.at], Result[1], n);
  Inc(r.at, n);
end;

{ a count of items taking at least each bytes apiece: no more than the
  bytes left allow, so a damaged one cannot make a huge allocation }
function ReadCount(var r: TByteReader; each: SizeInt; const what: string): SizeInt;
var
  v: UInt64;
begin
  v := ReadVarint(r);
  if v > UInt64((r.n - r.at) div each) then
    Corrupt(r, what);
  Result := SizeInt(v);
end;

function ZigZag(v: Int64): UInt64;
begin
  Result := (UInt64(v) shl 1) xor UInt64(SarInt64(v, 63));
end;

function UnZigZag(v: UInt64): Int64;
begin
  Result := Int64(v shr 1) xor -Int64(v and 1);
end;

procedure EncodeIndex(const idx: TIndex; firstFrag: Int64; var b: TByteBuf);
var
  i, k: SizeInt;
  e: ^TEntry;
begin
  BufVarint(b, Length(idx.blocks));
  for i := 0 to High(idx.blocks) do
  begin
    BufVarint(b, idx.blocks[i].bytes);
    BufVarint(b, idx.blocks[i].frags);
  end;
  BufVarint(b, Length(idx.frags));
  for i := 0 to High(idx.frags) do
  begin
    BufVarint(b, idx.frags[i].size);
    BufPut(b, @idx.frags[i].hash[0], SizeOf(TBlake2sDigest));
  end;
  BufVarint(b, Length(idx.entries));
  for i := 0 to High(idx.entries) do
  begin
    e := @idx.entries[i];
    BufStr(b, e^.path);
    BufByte(b, e^.kind);
    if e^.kind = ET_DELETED then
      Continue;
    BufI64(b, e^.meta.mtime);
    BufByte(b, e^.meta.attrKind);
    BufVarint(b, e^.meta.attrs);
    if e^.meta.attrKind = AK_UNIX then
    begin
      BufVarint(b, e^.meta.uid);
      BufVarint(b, e^.meta.gid);
    end;
    case e^.kind of
      ET_FILE:
        begin
          BufVarint(b, e^.meta.size);
          BufVarint(b, Length(e^.refs));
          if Length(e^.refs) > 0 then
          begin
            BufVarint(b, e^.refs[0]);
            for k := 1 to High(e^.refs) do
              BufVarint(b, ZigZag(e^.refs[k] - (e^.refs[k - 1] + 1)));
          end;
        end;
      ET_SYMLINK:
        BufStr(b, e^.meta.target);
    end;
  end;
end;

{ a stored path: not empty, "/" separated, no "", "." or ".." component }
function ValidPath(const s: string): Boolean;
var
  i, start: Integer;
  part: string;
begin
  if (s = '') or (s[1] = '/') or (s[Length(s)] = '/') or (Pos(#0, s) > 0) then
    Exit(False);
  start := 1;
  for i := 1 to Length(s) + 1 do
    if (i > Length(s)) or (s[i] = '/') then
    begin
      part := Copy(s, start, i - start);
      if (part = '') or (part = '.') or (part = '..') then
        Exit(False);
      start := i + 1;
    end;
  Result := True;
end;

procedure DecodeIndex(p: PByte; n: SizeInt; firstFrag, maxFrag: Int64;
  out idx: TIndex; const what: string);
var
  r: TByteReader;
  count, i, k: SizeInt;
  v: UInt64;
  sum, lastFrag, ref: Int64;
  e: ^TEntry;
begin
  idx := Default(TIndex);
  ReaderInit(r, p, n, what);
  count := ReadCount(r, 2, 'block count');
  SetLength(idx.blocks, count);
  sum := 0;
  for i := 0 to count - 1 do
  begin
    v := ReadVarint(r);
    if (v < BLOCKHDR_SIZE) or (v > BLOCKHDR_SIZE + MAX_BLOCK) then
      Corrupt(r, 'block size');
    idx.blocks[i].bytes := v;
    v := ReadVarint(r);
    if (v < 1) or (v > MAX_BLOCK) then
      Corrupt(r, 'fragments in a block');
    idx.blocks[i].frags := v;
    Inc(sum, idx.blocks[i].frags);
  end;
  count := ReadCount(r, 33, 'fragment count');
  if count <> sum then
    Corrupt(r, 'fragment count');
  SetLength(idx.frags, count);
  for i := 0 to count - 1 do
  begin
    v := ReadVarint(r);
    if (v < 1) or (v > UInt64(maxFrag)) then
      Corrupt(r, 'fragment size');
    idx.frags[i].size := v;
    if r.n - r.at < SizeOf(TBlake2sDigest) then
      Corrupt(r, 'truncated');
    Move(r.p[r.at], idx.frags[i].hash[0], SizeOf(TBlake2sDigest));
    Inc(r.at, SizeOf(TBlake2sDigest));
  end;
  lastFrag := firstFrag + count - 1;
  count := ReadCount(r, 2, 'entry count');
  SetLength(idx.entries, count);
  for i := 0 to count - 1 do
  begin
    e := @idx.entries[i];
    e^.path := ReadStr(r, 65535);
    if not ValidPath(e^.path) then
      Corrupt(r, 'path');
    if (i > 0) and (ComparePaths(idx.entries[i - 1].path, e^.path) >= 0) then
      Corrupt(r, 'paths out of order');
    e^.kind := ReadByte(r);
    e^.meta.kind := e^.kind;
    if e^.kind = ET_DELETED then
      Continue;
    if not (e^.kind in [ET_FILE, ET_DIR, ET_SYMLINK]) then
      Corrupt(r, 'entry type');
    e^.meta.mtime := ReadI64(r);
    e^.meta.attrKind := ReadByte(r);
    if e^.meta.attrKind > AK_WINDOWS then
      Corrupt(r, 'attribute kind');
    v := ReadVarint(r);
    if v > High(UInt32) then
      Corrupt(r, 'attributes');
    e^.meta.attrs := v;
    if e^.meta.attrKind = AK_UNIX then
    begin
      v := ReadVarint(r);
      if v > High(UInt32) then
        Corrupt(r, 'uid');
      e^.meta.uid := v;
      v := ReadVarint(r);
      if v > High(UInt32) then
        Corrupt(r, 'gid');
      e^.meta.gid := v;
    end;
    case e^.kind of
      ET_FILE:
        begin
          v := ReadVarint(r);
          if v > UInt64(High(Int64)) then
            Corrupt(r, 'file size');
          e^.meta.size := v;
          k := ReadCount(r, 1, 'reference count');
          if (k = 0) <> (e^.meta.size = 0) then
            Corrupt(r, 'file size or reference count');
          SetLength(e^.refs, k);
          ref := 0;
          for k := 0 to High(e^.refs) do
          begin
            v := ReadVarint(r);
            if k = 0 then
            begin
              if v > UInt64(lastFrag) then
                Corrupt(r, 'fragment reference');
              ref := v;
            end
            else
              ref := ref + 1 + UnZigZag(v);
            if (ref < 1) or (ref > lastFrag) then
              Corrupt(r, 'fragment reference');
            e^.refs[k] := ref;
          end;
        end;
      ET_SYMLINK:
        e^.meta.target := ReadStr(r, 65535);
    end;
  end;
  if r.at <> n then
    Corrupt(r, 'bytes after the entries');
end;

end.
