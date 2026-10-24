{ sycfs — the file system side of the archiver: paths as the archive
  stores them, directory listings, metadata, and glob patterns. }
unit sycfs;

{$mode objfpc}{$H+}

interface

uses
  {$ifdef unix}BaseUnix,{$endif}
  {$ifdef windows}Windows,{$endif}
  SysUtils, Classes;

const
  { entry types, as the index stores them }
  ET_DELETED = 0;
  ET_FILE    = 1;
  ET_DIR     = 2;
  ET_SYMLINK = 3;
  ET_OTHER   = 255;   { a device, socket, FIFO: not stored }

  { attrKind }
  AK_NONE    = 0;
  AK_UNIX    = 1;
  AK_WINDOWS = 2;

type
  TMeta = record
    kind: Byte;
    size: Int64;
    mtime: Int64;      { ns since 1970 UTC }
    attrKind: Byte;
    attrs: UInt32;
    uid, gid: UInt32;
    target: string;    { a symlink's }
  end;

{ The metadata of path, not following a symlink; False when it cannot be
  read. }
function GetMeta(const path: string; out m: TMeta): Boolean;
{ The names in directory dir (not . and ..), sorted bytewise; False when
  it cannot be read. }
function ListDir(const dir: string; names: TStringList): Boolean;

{ An operand as the archive stores it: "/" separators, no leading "/" or
  drive letter, no "." components, no trailing "/". Raises EConvertError
  on a path that leaves its directory (a ".." component). '' is the
  current directory. }
function StoredPath(const path: string): string;
{ a stored path (always valid, checked by the reader) as a local one under
  dir }
function LocalPath(const dir, stored: string): string;

{ Glob: * and ? within a component, ** across them. A pattern without "/"
  matches the last component of path, one with "/" the whole path. }
function GlobMatch(const pattern, path: string): Boolean;

{ bytewise comparison, the archive's order of paths }
function ComparePaths(const a, b: string): Integer;

implementation

function ComparePaths(const a, b: string): Integer;
var
  n: SizeInt;
begin
  n := Length(a);
  if Length(b) < n then
    n := Length(b);
  if n > 0 then
    Result := CompareByte(a[1], b[1], n)
  else
    Result := 0;
  if Result = 0 then
    Result := Length(a) - Length(b);
end;

function BytewiseCompare(list: TStringList; i, j: Integer): Integer;
begin
  Result := ComparePaths(list[i], list[j]);
end;

{$ifdef unix}

function GetMeta(const path: string; out m: TMeta): Boolean;
var
  st: Stat;
begin
  m := Default(TMeta);
  if fpLStat(path, st) <> 0 then
    Exit(False);
  if fpS_ISREG(st.st_mode) then
    m.kind := ET_FILE
  else if fpS_ISDIR(st.st_mode) then
    m.kind := ET_DIR
  else if fpS_ISLNK(st.st_mode) then
  begin
    m.kind := ET_SYMLINK;
    m.target := fpReadLink(path);
  end
  else
    m.kind := ET_OTHER;
  if m.kind = ET_FILE then
    m.size := st.st_size;
  m.mtime := Int64(st.st_mtime) * 1000000000 + Int64(st.st_mtime_nsec);
  m.attrKind := AK_UNIX;
  m.attrs := st.st_mode and $FFF;
  m.uid := st.st_uid;
  m.gid := st.st_gid;
  Result := True;
end;

function ListDir(const dir: string; names: TStringList): Boolean;
var
  d: pDir;
  e: pDirent;
  name: string;
begin
  names.Clear;
  d := fpOpenDir(dir);
  if d = nil then
    Exit(False);
  try
    while True do
    begin
      e := fpReadDir(d^);
      if e = nil then
        Break;
      name := StrPas(PChar(@e^.d_name[0]));
      if (name <> '.') and (name <> '..') then
        names.Add(name);
    end;
  finally
    fpCloseDir(d^);
  end;
  names.CustomSort(@BytewiseCompare);
  Result := True;
end;

{$else}

{ 100 ns intervals since 1601 -> ns since 1970 }
function FileTimeToNs(const ft: TFileTime): Int64;
begin
  Result := (Int64(ft.dwHighDateTime) shl 32 or ft.dwLowDateTime - 116444736000000000) * 100;
end;

function GetMeta(const path: string; out m: TMeta): Boolean;
var
  data: TWin32FileAttributeData;
  w: UnicodeString;
begin
  m := Default(TMeta);
  w := UnicodeString(path);
  if not GetFileAttributesExW(PWideChar(w), GetFileExInfoStandard, @data) then
    Exit(False);
  if data.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT <> 0 then
    m.kind := ET_OTHER   { symlinks and junctions: not stored yet }
  else if data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY <> 0 then
    m.kind := ET_DIR
  else
  begin
    m.kind := ET_FILE;
    m.size := Int64(data.nFileSizeHigh) shl 32 or data.nFileSizeLow;
  end;
  m.mtime := FileTimeToNs(data.ftLastWriteTime);
  m.attrKind := AK_WINDOWS;
  m.attrs := data.dwFileAttributes and (FILE_ATTRIBUTE_READONLY or FILE_ATTRIBUTE_HIDDEN
    or FILE_ATTRIBUTE_SYSTEM or FILE_ATTRIBUTE_ARCHIVE);
  Result := True;
end;

function ListDir(const dir: string; names: TStringList): Boolean;
var
  h: THandle;
  fd: TWin32FindDataW;
  w: UnicodeString;
  name: string;
begin
  names.Clear;
  w := UnicodeString(IncludeTrailingPathDelimiter(dir) + '*');
  h := FindFirstFileW(PWideChar(w), @fd);
  if h = INVALID_HANDLE_VALUE then
    Exit(GetLastError = ERROR_FILE_NOT_FOUND);
  try
    repeat
      name := UTF8Encode(UnicodeString(PWideChar(@fd.cFileName[0])));
      if (name <> '.') and (name <> '..') then
        names.Add(name);
    until not FindNextFileW(h, @fd);
  finally
    Windows.FindClose(h);
  end;
  names.CustomSort(@BytewiseCompare);
  Result := True;
end;

{$endif}

function StoredPath(const path: string): string;
var
  s, part: string;
  i, start: Integer;
begin
  s := StringReplace(path, '\', '/', [rfReplaceAll]);
  { a drive letter; leading slashes go with the empty components }
  if (Length(s) >= 2) and (s[2] = ':') and (UpCase(s[1]) in ['A'..'Z']) then
    Delete(s, 1, 2);
  Result := '';
  start := 1;
  for i := 1 to Length(s) + 1 do
    if (i > Length(s)) or (s[i] = '/') then
    begin
      part := Copy(s, start, i - start);
      start := i + 1;
      if (part = '') or (part = '.') then
        Continue;
      if part = '..' then
        raise EConvertError.Create(path + ': a path with ".." is not stored (use -C)');
      if Result <> '' then
        Result := Result + '/';
      Result := Result + part;
    end;
end;

function LocalPath(const dir, stored: string): string;
begin
  Result := stored;
{$ifdef windows}
  Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
{$endif}
  if dir <> '' then
    Result := IncludeTrailingPathDelimiter(dir) + Result;
end;

{ p[pi..] against s[si..] }
function GlobAt(const p: string; pi: Integer; const s: string; si: Integer): Boolean;
var
  k: Integer;
begin
  while pi <= Length(p) do
  begin
    case p[pi] of
      '*':
        if (pi < Length(p)) and (p[pi + 1] = '*') then
        begin
          { **: anything, "/" included; "**/" also matches nothing }
          Inc(pi, 2);
          if (pi <= Length(p)) and (p[pi] = '/') and GlobAt(p, pi + 1, s, si) then
            Exit(True);
          for k := si to Length(s) + 1 do
            if GlobAt(p, pi, s, k) then
              Exit(True);
          Exit(False);
        end
        else
        begin
          Inc(pi);
          k := si;
          while True do
          begin
            if GlobAt(p, pi, s, k) then
              Exit(True);
            if (k > Length(s)) or (s[k] = '/') then
              Exit(False);
            Inc(k);
          end;
        end;
      '?':
        begin
          if (si > Length(s)) or (s[si] = '/') then
            Exit(False);
          Inc(pi);
          Inc(si);
        end;
    else
      if (si > Length(s)) or (s[si] <> p[pi]) then
        Exit(False);
      Inc(pi);
      Inc(si);
    end;
  end;
  Result := si > Length(s);
end;

function GlobMatch(const pattern, path: string): Boolean;
var
  k: Integer;
begin
  if Pos('/', pattern) = 0 then
  begin
    k := Length(path);
    while (k > 0) and (path[k] <> '/') do
      Dec(k);
    Result := GlobAt(pattern, 1, Copy(path, k + 1, MaxInt), 1);
  end
  else
    Result := GlobAt(pattern, 1, path, 1);
end;

end.
