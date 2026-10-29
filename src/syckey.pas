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
  SysUtils, Classes, Math, syccrypto, sycblocks, sycenc, sycfmt;

const
  STREAM_MAGIC = 'SYZ0';
  STREAM_FMT_ENC = 5;
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
  f.WriteBuffer(rec[0], KEYREC_SIZE);
  Flush(f, name);
end;

function ChangeOne(const opts: TOptions; const name: string; const oldPw, newPw: TBytes): Integer;
var
  f: TFileStream;
  hdr: array[0..7] of Byte;
  prefix, rec, withBoth, withNew: TBytes;
  keys, check: TSycKeys;
  slot, checkSlot, n: Integer;
  memKiB: UInt32;
  ok: Boolean;
begin
  Result := EXIT_OK;
  try
    f := TFileStream.Create(name, fmOpenReadWrite or fmShareDenyWrite);
  except
    on E: EFOpenError do
    begin
      WriteLn(StdErr, 'syc: ', name, ': cannot open for writing, skipped');
      Exit(EXIT_WARN);
    end;
  end;
  try
    FillChar(hdr, SizeOf(hdr), 0);
    n := f.Read(hdr, SizeOf(hdr));
    if (n = SizeOf(hdr)) and (CompareByte(hdr[0], ARC_MAGIC[1], 4) = 0) then
    begin
      if hdr[4] <> ARC_FMT_ENC then
        Fail(EXIT_USAGE, name + ': not encrypted (syc k changes the password of encrypted files)');
      SetLength(prefix, HEADER_SIZE);
    end
    else if (n >= STREAM_PREFIX) and (CompareByte(hdr[0], STREAM_MAGIC[1], 4) = 0) then
    begin
      if hdr[4] <> STREAM_FMT_ENC then
        Fail(EXIT_USAGE, name + ': not encrypted (syc k changes the password of encrypted files)');
      SetLength(prefix, STREAM_PREFIX);
    end
    else
      Fail(EXIT_CORRUPT, name + ': not a syc archive or stream');
    Move(hdr, prefix[0], Length(prefix));
    SetLength(rec, KEYREC_SIZE);
    f.Position := Length(prefix);
    if f.Read(rec[0], KEYREC_SIZE) <> KEYREC_SIZE then
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
      WriteLn(StdErr, name, ': password changed');
  finally
    f.Free;
  end;
end;

function RunKeyCommand(const opts: TOptions): Integer;
var
  oldPw, newPw: TBytes;
  what: string;
  i, r: Integer;
begin
  for i := 0 to High(opts.operands) do
    if opts.operands[i] = '-' then
      Fail(EXIT_USAGE, 'syc k changes files in place: no stdin');
  if Length(opts.operands) = 1 then
    what := opts.operands[0]
  else
    what := 'the files';
  oldPw := GetPassword(opts, False, what);
  newPw := GetNewPassword(opts, what);
  Result := EXIT_OK;
  try
    for i := 0 to High(opts.operands) do
    begin
      try
        r := ChangeOne(opts, opts.operands[i], oldPw, newPw);
      except
        on E: ESycError do
        begin
          if E.code = EXIT_USAGE then
            raise;
          WriteLn(StdErr, 'syc: ', E.Message);
          r := E.code;
        end;
        on E: EStreamError do
        begin
          WriteLn(StdErr, 'syc: ', opts.operands[i], ': ', E.Message);
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
