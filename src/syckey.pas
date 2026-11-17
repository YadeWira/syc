{ syckey — syc k: a new password for encrypted archives (.syc format 3)
  and streams (.sylz version 5), in place and without recompressing
  (wiki: syc encryption). The data key stays: the key record's other slot
  gets it wrapped with the new password, the file is flushed, then the
  old slot is zeroed and the file flushed again. Interrupted, the file
  opens with the old password or the new one, never neither. }
unit syckey;

{$mode objfpc}{$H+}

interface

uses
  syccli;

{ runs syc k on every operand; returns the exit code }
function RunKeyCommand(const opts: TOptions): Integer;

implementation

uses
  {$ifdef unix}Unix,{$endif}
  {$ifdef windows}Windows,{$endif}
  SysUtils, Classes, Math, syccrypto, sycblocks, sycui, sycenc, sycfmt, sycfs;

const
  STREAM_MAGIC = 'SYZ0';
  STREAM_FMT_ENC1 = 5;
  STREAM_FMT_ENC = 6;
  STREAM_PREFIX = 7;   { "SYZ0" version codec level }

{ the file's bytes on the disk, not only in the system's cache }
procedure Flush(f: TFileStream; const name: string);
begin
{$ifdef unix}
  if fpFsync(f.Handle) <> 0 then
{$else}
  if not FlushFileBuffers(f.Handle) then
{$endif}
    Fail(EXIT_FATAL, name + ': cannot flush to the disk');
end;

procedure WriteRecord(f: TFileStream; at: Int64; const rec: TBytes; const name: string);
begin
  f.Position := at;
  f.WriteBuffer(rec[0], Length(rec));
  Flush(f, name);
end;

function ChangeOne(const opts: TOptions; const name: string; const oldPw, newPw: TBytes): Integer;
var
  f: TFileStream;
  hdr: array[0..7] of Byte;
  prefix, rec, withBoth, withNew: TBytes;
  keys, check: TSycKeys;
  slot, checkSlot, n, recSize: Integer;
  memKiB: UInt32;
  ok: Boolean;
  lockH: THandle;
begin
  Result := EXIT_OK;
  { an append (or another syc k) at the same time would write a key record
    of its own }
  if not LockFile(name, lockH) then
    Fail(EXIT_FATAL, name + ': another syc is changing it (try again when it is done)');
  try
  try
    f := TFileStream.Create(name, fmOpenReadWrite or fmShareDenyWrite);
  except
    on E: EFOpenError do
    begin
      WriteLn(StdErr, WarnTag, name, ': cannot open for writing, skipped');
      Exit(EXIT_WARN);   { the lock goes in the finally }
    end;
  end;
  try
    FillChar(hdr, SizeOf(hdr), 0);
    n := f.Read(hdr, SizeOf(hdr));
    if (n = SizeOf(hdr)) and (CompareByte(hdr[0], ARC_MAGIC[1], 4) = 0) then
    begin
      if not (hdr[4] in [ARC_FMT_ENC, ARC_FMT_ENC2]) then
        raise EInputUsage.Create(EXIT_USAGE, name + ': not encrypted (syc k changes the password of encrypted files)');
      SetLength(prefix, HEADER_SIZE);
      recSize := KEYREC_SIZE;
      if hdr[4] = ARC_FMT_ENC then
        recSize := KEYREC_SIZE_1;
    end
    else if (n >= STREAM_PREFIX) and (CompareByte(hdr[0], STREAM_MAGIC[1], 4) = 0) then
    begin
      if not (hdr[4] in [STREAM_FMT_ENC1, STREAM_FMT_ENC]) then
        raise EInputUsage.Create(EXIT_USAGE, name + ': not encrypted (syc k changes the password of encrypted files)');
      SetLength(prefix, STREAM_PREFIX);
      recSize := KEYREC_SIZE;
      if hdr[4] = STREAM_FMT_ENC1 then
        recSize := KEYREC_SIZE_1;
    end
    else
      Fail(EXIT_CORRUPT, name + ': not a syc archive or stream');
    Move(hdr, prefix[0], Length(prefix));
    SetLength(rec, recSize);
    f.Position := Length(prefix);
    if f.Read(rec[0], recSize) <> recSize then
      Fail(EXIT_CORRUPT, name + ': truncated key record');

    if not OpenKeyRecordSlot(prefix, rec, oldPw, name, keys, slot) then
      Fail(EXIT_CORRUPT, name + ': wrong password, or a damaged key record');
    try
      memKiB := 0;
      if opts.kdfMemSet then
        memKiB := UInt32(opts.kdfMemMiB) * 1024;
      RewrapKeyRecord(prefix, rec, slot, keys, newPw, memKiB, withBoth, withNew);
      { what is written opens, with the new password, to the same key }
      ok := OpenKeyRecordSlot(prefix, withNew, newPw, name, check, checkSlot)
        and (CompareByte(check.k, keys.k, SizeOf(keys.k)) = 0);
      WipeKeys(check);
      if not ok then
        Fail(EXIT_FATAL, name + ': the new key record does not open (nothing was written)');
      WriteRecord(f, Length(prefix), withBoth, name);
      WriteRecord(f, Length(prefix), withNew, name);
    finally
      WipeKeys(keys);
    end;
    if opts.verbosity <> vQuiet then
      WriteLn(StdErr, Summary(2, mkOk, name, ['password changed']));
  finally
    f.Free;
  end;
  finally
    Unlock(lockH);
  end;
end;

function RunKeyCommand(const opts: TOptions): Integer;
var
  oldPw, newPw: TBytes;
  what: string;
  i, j, r: Integer;
  files: array of string;
  dup: Boolean;
begin
  for i := 0 to High(opts.operands) do
    if opts.operands[i] = '-' then
      Fail(EXIT_USAGE, 'syc k changes files in place: no stdin');
  { the files first: a missing one is said before any password is asked,
    and a file named twice is changed once }
  files := nil;
  Result := EXIT_OK;
  for i := 0 to High(opts.operands) do
    if not FileExists(opts.operands[i]) then
    begin
      WriteLn(StdErr, WarnTag, opts.operands[i], ': cannot open, skipped');
      Result := EXIT_WARN;
    end
    else
    begin
      dup := False;
      for j := 0 to High(files) do
        if SameFileName(ExpandFileName(files[j]), ExpandFileName(opts.operands[i])) then
          dup := True;
      if not dup then
      begin
        SetLength(files, Length(files) + 1);
        files[High(files)] := opts.operands[i];
      end;
    end;
  if files = nil then
    Exit;
  if Length(files) = 1 then
    what := files[0]
  else
    what := 'the files';
  oldPw := GetPassword(opts, False, what);
  newPw := GetNewPassword(opts, what);
  try
    for i := 0 to High(files) do
    begin
      try
        SetWhere(files[i], -1, -1);
        r := ChangeOne(opts, files[i], oldPw, newPw);
      except
        on E: ESycError do
        begin
          if (E.code = EXIT_USAGE) and not (E is EInputUsage) then
            raise;
          ShowError(E, E.code);
          r := E.code;
        end;
        on E: EStreamError do
        begin
          E.Message := files[i] + ': ' + E.Message;
          ShowError(E, EXIT_FATAL);
          r := EXIT_FATAL;
        end;
      end;
      Result := Max(Result, r);
    end;
  finally
    Wipe(@oldPw[0], Length(oldPw));
    Wipe(@newPw[0], Length(newPw));
  end;
end;

end.
