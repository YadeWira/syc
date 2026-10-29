{ sycenc — syc's encryption, between the primitives (syccrypto) and the
  formats (wiki: syc encryption): the key record, the subkeys, sealing
  and opening blocks, and getting the password. }
unit sycenc;

{$mode objfpc}{$H+}

interface

uses
  {$ifdef windows}Windows,{$endif}
  {$ifdef unix}BaseUnix, termio,{$endif}
  SysUtils, Classes, sycblocks, syccli, syccrypto, blake2s;

const
  KEYREC_SIZE = 216;
  SLOT_SIZE = 104;
  KDF_ARGON2ID = 1;
  SEAL_SIZE = 40;          { a block's nonce and tag }
  KEYREC_FLAG_INDEX = 1;   { the archive's index is encrypted }
  MAX_PASSWORD = 1024;

type
  TSycKeys = record
    k: TKey32;               { the data key }
    aead, frag, cdc: TKey32; { its subkeys }
    flags: Byte;
  end;

{ A new data key, and the key record wrapping it with the password (slot
  0, gen 1; Argon2id t = 3, p = 1, memKiB). prefix: the file's bytes
  before the key record (the header). }
procedure NewKeyRecord(const prefix: TBytes; const pw: TBytes; memKiB: UInt32; flags: Byte;
  out keys: TSycKeys; out rec: TBytes);
{ The data key from a key record; False when no slot opens with the
  password. Raises ESycError(EXIT_CORRUPT) on a record that breaks the
  format. name is for the messages. }
function OpenKeyRecord(const prefix, rec, pw: TBytes; const name: string;
  out keys: TSycKeys): Boolean;
{ the same, and the slot that opened (0 or 1) }
function OpenKeyRecordSlot(const prefix, rec, pw: TBytes; const name: string;
  out keys: TSycKeys; out slot: Integer): Boolean;
{ A new password for a key record that slot opened, in two steps
  (wiki: syc encryption): withBoth has the data key wrapped with newPw in
  the other slot, at a higher generation, and slot as it was; withNew has
  slot zeroed too. memKiB 0: the opened slot's. }
procedure RewrapKeyRecord(const prefix, rec: TBytes; slot: Integer; const keys: TSycKeys;
  const newPw: TBytes; memKiB: UInt32; out withBoth, withNew: TBytes);
procedure WipeKeys(var keys: TSycKeys);

{ seals data[0..n) in place with key: a random nonce, the tag (into
  seal) }
procedure SealData(const key: TKey32; const aad: TBytes; data: PByte; n: SizeInt; seal: PByte);
{ checks and opens it in place; False when the tag does not match }
function OpenData(const key: TKey32; const aad: TBytes; data: PByte; n: SizeInt; seal: PByte): Boolean;

{ The password, UTF-8: -pPASSWORD / --password=, --password-file, the
  environment's SYC_PASSWORD, else the terminal (twice when creating).
  Raises ESycError(EXIT_USAGE) when there is none to be had. }
function GetPassword(const opts: TOptions; creating: Boolean; const what: string): TBytes;
{ syc k's new password: --new-password=, --new-password-file,
  SYC_NEW_PASSWORD, else the terminal (twice) }
function GetNewPassword(const opts: TOptions; const what: string): TBytes;
{ a new archive or stream is to be encrypted }
function EncryptionRequested(const opts: TOptions): Boolean;

{ little helpers for the AADs }
procedure PutBytes(var b: TBytes; const s: string);
procedure PutU32(var b: TBytes; v: UInt32);
procedure PutU64(var b: TBytes; v: UInt64);

implementation

procedure PutBytes(var b: TBytes; const s: string);
var
  n: SizeInt;
begin
  n := Length(b);
  SetLength(b, n + Length(s));
  if s <> '' then
    Move(s[1], b[n], Length(s));
end;

procedure PutU32(var b: TBytes; v: UInt32);
var
  n: SizeInt;
begin
  n := Length(b);
  SetLength(b, n + 4);
  PUInt32(@b[n])^ := NtoLE(v);
end;

procedure PutU64(var b: TBytes; v: UInt64);
var
  n: SizeInt;
begin
  n := Length(b);
  SetLength(b, n + 8);
  PUInt64(@b[n])^ := NtoLE(v);
end;

procedure Subkey(const k: TKey32; const lbl: string; out sub: TKey32);
var
  d: TBlake2sDigest;
begin
  Blake2s256Key(@k[0], 32, @lbl[1], Length(lbl), d);
  Move(d, sub, 32);
  Wipe(@d, SizeOf(d));
end;

procedure DeriveSubkeys(var keys: TSycKeys);
begin
  Subkey(keys.k, 'syc aead', keys.aead);
  Subkey(keys.k, 'syc fragment', keys.frag);
  Subkey(keys.k, 'syc cdc', keys.cdc);
end;

procedure WipeKeys(var keys: TSycKeys);
begin
  Wipe(@keys, SizeOf(keys));
end;

{ the slot's AAD: the header, the record's first 8 bytes, the slot's
  first 16 }
function SlotAad(const prefix, rec: TBytes; slotAt: SizeInt): TBytes;
begin
  Result := Copy(prefix);
  SetLength(Result, Length(prefix) + 8 + 16);
  Move(rec[0], Result[Length(prefix)], 8);
  Move(rec[slotAt], Result[Length(prefix) + 8], 16);
end;

{ fills the slot at rec[s]: gen, Argon2id (t = 3, p = 1, memKiB), a new
  salt and nonce, and the data key k wrapped with the password }
procedure FillSlot(const prefix: TBytes; var rec: TBytes; s: SizeInt; gen: UInt32;
  const k: TKey32; const pw: TBytes; memKiB: UInt32);
const
  PASSES = 3;
  LANES = 1;
var
  kek: TKey32;
  aad: TBytes;
  tag: TTag16;
begin
  FillChar(rec[s], SLOT_SIZE, 0);
  PUInt32(@rec[s])^ := NtoLE(gen);
  rec[s + 4] := KDF_ARGON2ID;
  rec[s + 5] := LANES;
  PUInt32(@rec[s + 8])^ := NtoLE(memKiB);
  PUInt32(@rec[s + 12])^ := NtoLE(UInt32(PASSES));
  RandomBytes(@rec[s + 16], 16);                 { salt }
  RandomBytes(@rec[s + 32], 24);                 { nonce }
  Argon2id(@pw[0], Length(pw), @rec[s + 16], 16, nil, 0, nil, 0, PASSES, memKiB, LANES,
    @kek[0], 32);
  Move(k, rec[s + 56], 32);
  aad := SlotAad(prefix, rec, s);
  XChaChaPolyEncrypt(kek, PNonce24(@rec[s + 32])^, @aad[0], Length(aad), @rec[s + 56], 32, tag);
  Move(tag, rec[s + 88], 16);
  Wipe(@kek, SizeOf(kek));
end;

procedure NewKeyRecord(const prefix: TBytes; const pw: TBytes; memKiB: UInt32; flags: Byte;
  out keys: TSycKeys; out rec: TBytes);
begin
  keys := Default(TSycKeys);
  RandomBytes(@keys.k[0], 32);
  keys.flags := flags;
  DeriveSubkeys(keys);
  rec := nil;
  SetLength(rec, KEYREC_SIZE);
  FillChar(rec[0], KEYREC_SIZE, 0);
  Move(PChar('SYCK')^, rec[0], 4);
  rec[4] := flags;
  FillSlot(prefix, rec, 8, 1, keys.k, pw, memKiB);   { slot 0, gen 1 }
end;

procedure RewrapKeyRecord(const prefix, rec: TBytes; slot: Integer; const keys: TSycKeys;
  const newPw: TBytes; memKiB: UInt32; out withBoth, withNew: TBytes);
var
  s, o: SizeInt;
  gen, other: UInt32;
begin
  s := 8 + slot * SLOT_SIZE;
  o := 8 + (1 - slot) * SLOT_SIZE;
  gen := LEtoN(PUInt32(@rec[s])^);
  other := LEtoN(PUInt32(@rec[o])^);
  if other > gen then
    gen := other;
  if gen = High(UInt32) then
    Fail(EXIT_CORRUPT, 'the key record''s generation cannot go higher');
  if memKiB = 0 then
    memKiB := LEtoN(PUInt32(@rec[s + 8])^);
  withBoth := Copy(rec);
  FillSlot(prefix, withBoth, o, gen + 1, keys.k, newPw, memKiB);
  withNew := Copy(withBoth);
  FillChar(withNew[s], SLOT_SIZE, 0);
end;

function OpenKeyRecord(const prefix, rec, pw: TBytes; const name: string;
  out keys: TSycKeys): Boolean;
var
  slot: Integer;
begin
  Result := OpenKeyRecordSlot(prefix, rec, pw, name, keys, slot);
end;

function OpenKeyRecordSlot(const prefix, rec, pw: TBytes; const name: string;
  out keys: TSycKeys; out slot: Integer): Boolean;
var
  gens: array[0..1] of UInt32;
  order: array[0..1] of Integer;
  i, k, s: Integer;
  lanes: Byte;
  memKiB, passes: UInt32;
  kek: TKey32;
  aad: TBytes;
  key: array[0..31] of Byte;

  procedure Bad(const what: string);
  begin
    Fail(EXIT_CORRUPT, name + ': damaged key record (' + what + ')');
  end;

begin
  Result := False;
  slot := -1;
  keys := Default(TSycKeys);
  if (Length(rec) <> KEYREC_SIZE) or (CompareByte(rec[0], PChar('SYCK')^, 4) <> 0) then
    Bad('no "SYCK"');
  if (rec[4] and not KEYREC_FLAG_INDEX <> 0) or (rec[5] or rec[6] or rec[7] <> 0) then
    Bad('flags');
  { the slots' structure, before any Argon2id }
  for i := 0 to 1 do
  begin
    s := 8 + i * SLOT_SIZE;
    gens[i] := LEtoN(PUInt32(@rec[s])^);
    if gens[i] = 0 then
    begin
      for k := s to s + SLOT_SIZE - 1 do
        if rec[k] <> 0 then
          Bad('an empty slot is not zero');
      Continue;
    end;
    lanes := rec[s + 5];
    memKiB := LEtoN(PUInt32(@rec[s + 8])^);
    passes := LEtoN(PUInt32(@rec[s + 12])^);
    if (rec[s + 4] <> KDF_ARGON2ID) or (lanes < 1) or (lanes > 16) or (rec[s + 6] or rec[s + 7] <> 0)
       or (memKiB < 8 * UInt32(lanes)) or (memKiB > 4194304) or (passes < 1) or (passes > 256) then
      Bad('slot parameters');
  end;
  if (gens[0] = 0) and (gens[1] = 0) then
    Bad('no slot');
  { the higher generation first }
  if gens[1] > gens[0] then
  begin
    order[0] := 1;
    order[1] := 0;
  end
  else
  begin
    order[0] := 0;
    order[1] := 1;
  end;
  for k := 0 to 1 do
  begin
    i := order[k];
    if gens[i] = 0 then
      Continue;
    s := 8 + i * SLOT_SIZE;
    Argon2id(@pw[0], Length(pw), @rec[s + 16], 16, nil, 0, nil, 0,
      LEtoN(PUInt32(@rec[s + 12])^), LEtoN(PUInt32(@rec[s + 8])^), rec[s + 5], @kek[0], 32);
    Move(rec[s + 56], key, 32);
    aad := SlotAad(prefix, rec, s);
    if XChaChaPolyDecrypt(kek, PNonce24(@rec[s + 32])^, @aad[0], Length(aad), @key[0], 32,
       PTag16(@rec[s + 88])^) then
    begin
      Move(key, keys.k, 32);
      keys.flags := rec[4];
      DeriveSubkeys(keys);
      slot := i;
      Result := True;
    end;
    Wipe(@key, SizeOf(key));
    Wipe(@kek, SizeOf(kek));
    if Result then
      Exit;
  end;
end;

procedure SealData(const key: TKey32; const aad: TBytes; data: PByte; n: SizeInt; seal: PByte);
var
  tag: TTag16;
begin
  RandomBytes(seal, 24);
  XChaChaPolyEncrypt(key, PNonce24(seal)^, @aad[0], Length(aad), data, n, tag);
  Move(tag, seal[24], 16);
end;

function OpenData(const key: TKey32; const aad: TBytes; data: PByte; n: SizeInt; seal: PByte): Boolean;
begin
  Result := XChaChaPolyDecrypt(key, PNonce24(seal)^, @aad[0], Length(aad), data, n,
    PTag16(seal + 24)^);
end;

{ ── the password ─────────────────────────────────────────────────────── }

function EncryptionRequested(const opts: TOptions): Boolean;
begin
  Result := opts.passwordFlag or (opts.passwordInline <> '') or (opts.passwordFile <> '');
end;

function AsBytes(const s: string): TBytes;
begin
  SetLength(Result, Length(s));
  if s <> '' then
    Move(s[1], Result[0], Length(s));
end;

{$ifdef unix}
{ a line from the terminal, without echo; '' and False when there is none }
function ReadTerminal(const prompt: string; out line: string): Boolean;
var
  fd: cint;
  old, t: TermIOS;
  c: Char;
  got: TSsize;
  echoOff: Boolean;
begin
  line := '';
  fd := fpOpen('/dev/tty', O_RDWR);
  if fd < 0 then
    Exit(False);
  try
    fpWrite(fd, prompt[1], Length(prompt));
    echoOff := TCGetAttr(fd, old) = 0;
    if echoOff then
    begin
      t := old;
      t.c_lflag := t.c_lflag and not ECHO;
      TCSetAttr(fd, TCSANOW, t);
    end;
    try
      while True do
      begin
        got := fpRead(fd, c, 1);
        if (got <= 0) or (c = #10) then
          Break;
        if c <> #13 then
          line := line + c;
        if Length(line) > MAX_PASSWORD then
          Break;
      end;
    finally
      if echoOff then
        TCSetAttr(fd, TCSANOW, old);
      fpWrite(fd, #10, 1);
    end;
    Result := True;
  finally
    fpClose(fd);
  end;
end;
{$else}
function ReadTerminal(const prompt: string; out line: string): Boolean;
var
  hin, hout: THandle;
  mode, got, wrote: DWORD;
  wp: UnicodeString;
  buf: array[0..1] of WideChar;
  w: UnicodeString;
begin
  line := '';
  hin := CreateFileW('CONIN$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, 0, 0);
  if hin = INVALID_HANDLE_VALUE then
    Exit(False);
  hout := CreateFileW('CONOUT$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, 0, 0);
  try
    if hout <> INVALID_HANDLE_VALUE then
    begin
      wp := UnicodeString(prompt);
      WriteConsoleW(hout, PWideChar(wp), Length(wp), wrote, nil);
    end;
    if not GetConsoleMode(hin, mode) then
      Exit(False);
    SetConsoleMode(hin, mode and not ENABLE_ECHO_INPUT);
    try
      w := '';
      while True do
      begin
        if not ReadConsoleW(hin, @buf[0], 1, got, nil) or (got = 0) then
          Break;
        if buf[0] = #10 then
          Break;
        if buf[0] <> #13 then
          w := w + buf[0];
        if Length(w) > MAX_PASSWORD then
          Break;
      end;
    finally
      SetConsoleMode(hin, mode);
      if hout <> INVALID_HANDLE_VALUE then
        WriteConsoleW(hout, PWideChar(UnicodeString(#13#10)), 2, wrote, nil);
    end;
    line := UTF8Encode(w);
    Result := True;
  finally
    CloseHandle(hin);
    if hout <> INVALID_HANDLE_VALUE then
      CloseHandle(hout);
  end;
end;
{$endif}

{ the variable var (SYC_PASSWORD), UTF-8 (on Windows through the UTF-16
  environment: the ANSI one turns most characters into "?") }
function EnvPassword(const v: string): string;
{$ifdef windows}
var
  w: UnicodeString;
  n: DWORD;
begin
  Result := '';
  n := GetEnvironmentVariableW(PWideChar(UnicodeString(v)), nil, 0);
  if n = 0 then
    Exit;
  SetLength(w, n);
  n := GetEnvironmentVariableW(PWideChar(UnicodeString(v)), PWideChar(w), n);
  SetLength(w, n);
  Result := UTF8Encode(w);
end;
{$else}
begin
  Result := GetEnvironmentVariable(v);
end;
{$endif}

{ the password from inline, else the file's first line, else the
  variable envVar, else the terminal (prompt; twice when twice); missing:
  the message when none can be had }
function PasswordFrom(const inline, fileName, envVar, prompt: string; twice: Boolean;
  const missing: string): TBytes;
var
  pw, again: string;
  f: TextFile;
begin
  if inline <> '' then
    pw := inline
  else if fileName <> '' then
  begin
    AssignFile(f, fileName);
    try
      Reset(f);
      try
        ReadLn(f, pw);
      finally
        CloseFile(f);
      end;
    except
      on E: EInOutError do
        Fail(EXIT_USAGE, fileName + ': cannot read the password');
    end;
    if (pw <> '') and (pw[Length(pw)] = #13) then
      SetLength(pw, Length(pw) - 1);
    { a UTF-8 byte order mark (Notepad writes one) is not the password }
    if Copy(pw, 1, 3) = #$EF#$BB#$BF then
      Delete(pw, 1, 3);
  end
  else if EnvPassword(envVar) <> '' then
    pw := EnvPassword(envVar)
  else
  begin
    if not ReadTerminal(prompt, pw) then
      Fail(EXIT_USAGE, missing);
    if twice then
    begin
      ReadTerminal('Again: ', again);
      if again <> pw then
        Fail(EXIT_USAGE, 'the two passwords differ');
      if again <> '' then
        Wipe(@again[1], Length(again));
    end;
  end;
  if pw = '' then
    Fail(EXIT_USAGE, 'an empty password');
  if Length(pw) > MAX_PASSWORD then
    Fail(EXIT_USAGE, Format('a password of more than %d bytes', [MAX_PASSWORD]));
  Result := AsBytes(pw);
  { our own copy (pw may share opts' string), then cleared }
  UniqueString(pw);
  Wipe(@pw[1], Length(pw));
end;

function GetPassword(const opts: TOptions; creating: Boolean; const what: string): TBytes;
begin
  Result := PasswordFrom(opts.passwordInline, opts.passwordFile, 'SYC_PASSWORD',
    'Password for ' + what + ': ', creating,
    what + ' is encrypted: give the password (-pPASSWORD, --password-file '
    + 'FILE or SYC_PASSWORD), or run where it can be asked');
end;

function GetNewPassword(const opts: TOptions; const what: string): TBytes;
begin
  Result := PasswordFrom(opts.newPasswordInline, opts.newPasswordFile, 'SYC_NEW_PASSWORD',
    'New password for ' + what + ': ', True,
    'give the new password (--new-password=PASSWORD, --new-password-file FILE or '
    + 'SYC_NEW_PASSWORD), or run where it can be asked');
end;

end.
