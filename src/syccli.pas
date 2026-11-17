{ syccli — syc's command line: the commands, their options, and help.

  syc CMD [options] OPERANDS. Options may come before or after the
  operands; "--" ends them. Short options are not grouped (-ec is one
  option, not -e -c); a value follows as the next argument or attached
  (-t 4, -t4, --threads 4, --threads=4). }
unit syccli;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, sylz, sycblocks, sycui;

const
  SYC_VERSION   = '0.10.3';
  STREAM_SUFFIX = '.sylz';
  RAW_SUFFIX    = '.sylzraw';
  DEFAULT_STREAM_BLOCK_MIB = 4;
  DEFAULT_ARCHIVE_BLOCK_MIB = 16;
  { the sylz block format written by default: v4 (v5 with -ec) since syc
    0.9.0; -F 2 for v2 (v3 with -ec), which syc before 0.7.0 reads too }
  DEFAULT_FLAGS = SYLZ_V4;

type
  TVerbosity = (vQuiet, vNormal, vVerbose);
  TIntArray = array of Integer;

  TOptions = record
    cmd: Char;               { 'a', 'x', 'l', 'i', 'c', 'd', 't', 'k', 'b', 's', 'r' }
    level: Integer;
    levelSet: Boolean;       { a level was given (b: only that one) }
    flags: Integer;          { SYLZ_V4 unless -F 2 or 3; SYLZ_ENTROPY with -ec }
    blockMiB: Integer;       { the command's default unless -b }
    threads: Integer;
    outPath: string;         { -o; '' when not given (x: the directory) }
    toStdout: Boolean;       { -O }
    force: Boolean;
    skipExisting: Boolean;   { x --skip }
    removeInput: Boolean;    { --rm }
    raw: Boolean;            { c/d/t --raw: one bare sylz block }
    passwordFlag: Boolean;   { -p / --password: encrypt (a, c), password from the sources }
    passwordInline: string;  { -pPASSWORD / --password=PASSWORD }
    passwordFile: string;    { --password-file }
    visibleNames: Boolean;   { a --visible-names }
    kdfMemMiB: Integer;      { --kdf-mem }
    kdfMemSet: Boolean;      { --kdf-mem given (k: else the current slot's) }
    kdfMemMaxMiB: Integer;   { --kdf-mem-max: a key needing more is refused }
    newPasswordInline: string;   { k --new-password=PASSWORD }
    newPasswordFile: string;     { k --new-password-file }
    rawSize: Integer;        { d/t --size: its decoded size; -1 not given }
    verbosity: TVerbosity;
    progress: Boolean;       { --progress / --no-progress; default: stderr is a terminal }
    cdDir: string;           { -C }
    excludes: array of string;   { -X }
    noDedup, noDelete: Boolean;
    allVersions: Boolean;    { l --all }
    longList: Boolean;       { l -l }
    nullSep: Boolean;        { l --null }
    untilSpec: string;       { -u: a version number or a date; '' latest }
    noPerms, noOwner: Boolean;
    stats: Boolean;          { --stats }
    debug: Boolean;          { --debug }
    benchLevels: TIntArray;  { b --levels; none: every level }
    benchSeconds: Double;    { b --time }
    operands: array of string;
  end;

{ Parses the command line into opts. Prints help or the version and halts
  when asked to; raises ESycError(EXIT_USAGE) on a malformed one. --color,
  --debug and --paths (or SYC_PATHS) take effect here. }
procedure ParseCommandLine(out opts: TOptions);

{ Which code paths run: 'auto' the fastest built in (assembler on x86-64,
  C elsewhere), 'c' the C ones instead of the assembler, 'pascal' the
  reference Pascal only. Every path writes the same bytes; a difference
  is a bug in a fast path. False when name is none of them. }
function SetCodePaths(const name: string): Boolean;
{ the paths built into this binary and the ones in use, in words }
function CodePathsBuilt: string;
function CodePathsInUse: string;
{ "syc 0.9.0" and, on a second line, the commit, compiler and target }
function VersionLines: string;

implementation

uses
  {$ifdef windows}Windows,{$endif}
  sylzhuf, blake2s, syccdc, syccrypto, sycbuild;

{$ifdef windows}

function CommandLineToArgvW(cmd: PWideChar; out argc: LongInt): PPWideChar;
  stdcall; external 'shell32.dll' name 'CommandLineToArgvW';

var
  args: array of string;   { UTF-8; ParamStr would give the ANSI code page's }

procedure LoadArgs;
var
  argv: PPWideChar;
  argc, i: LongInt;
begin
  argv := CommandLineToArgvW(GetCommandLineW, argc);
  SetLength(args, argc);
  for i := 0 to argc - 1 do
    args[i] := UTF8Encode(UnicodeString(argv[i]));
  LocalFree(HLOCAL(argv));
end;

function CmdArgCount: Integer;
begin
  if args = nil then
    LoadArgs;
  Result := Length(args) - 1;
end;

function CmdArg(i: Integer): string;
begin
  if args = nil then
    LoadArgs;
  Result := args[i];
end;
{$else}
function CmdArgCount: Integer;
begin
  Result := ParamCount;
end;

function CmdArg(i: Integer): string;
begin
  Result := ParamStr(i);
end;
{$endif}

type
  TOptId = (oLevel, oEc, oFormat, oBlock, oThreads, oOut, oStdout, oForce, oRm,
    oCd, oExclude, oNoDedup, oNoDelete, oAll, oNull, oLong, oSkip, oUntil, oNoPerms, oNoOwner,
    oRaw, oSize, oPassword, oPasswordFile, oNewPassword, oNewPasswordFile, oVisibleNames, oKdfMem, oKdfMemMax, oProgress, oNoProgress,
    oLevels, oTime, oStats, oDebug, oPaths, oColor, oQuiet, oVerbose, oHelp);

  TOptDef = record
    id: TOptId;
    short, long: string;     { without the dashes; '' when there is none }
    value: Boolean;          { takes a value }
    cmds: string;            { the commands it applies to }
  end;

const
  OPTION_DEFS: array[0..39] of TOptDef = (
    (id: oLevel;   short: '';   long: 'level';      value: True;  cmds: 'acb'),
    (id: oEc;      short: 'ec'; long: 'ec';         value: False; cmds: 'acb'),
    (id: oFormat;  short: 'F';  long: 'format';     value: True;  cmds: 'acb'),
    (id: oBlock;   short: 'b';  long: 'block-size'; value: True;  cmds: 'acb'),
    (id: oThreads; short: 't';  long: 'threads';    value: True;  cmds: 'axcdt'),
    (id: oOut;     short: 'o';  long: 'out';        value: True;  cmds: 'xcd'),
    (id: oStdout;  short: 'O';  long: 'stdout';     value: False; cmds: 'xcd'),
    (id: oForce;   short: 'f';  long: 'force';      value: False; cmds: 'xcd'),
    (id: oRm;      short: '';   long: 'rm';         value: False; cmds: 'cd'),
    (id: oCd;      short: 'C';  long: 'cd';         value: True;  cmds: 'a'),
    (id: oExclude; short: 'X';  long: 'exclude';    value: True;  cmds: 'axl'),
    (id: oNoDedup; short: '';   long: 'no-dedup';   value: False; cmds: 'a'),
    (id: oNoDelete; short: '';  long: 'no-delete';  value: False; cmds: 'a'),
    (id: oAll;     short: '';   long: 'all';        value: False; cmds: 'l'),
    (id: oNull;    short: '';   long: 'null';       value: False; cmds: 'l'),
    (id: oLong;    short: 'l';  long: 'long';       value: False; cmds: 'l'),
    (id: oSkip;    short: '';   long: 'skip';       value: False; cmds: 'x'),
    (id: oUntil;   short: 'u';  long: 'until';      value: True;  cmds: 'xl'),
    (id: oNoPerms; short: '';   long: 'no-perms';   value: False; cmds: 'x'),
    (id: oNoOwner; short: '';   long: 'no-owner';   value: False; cmds: 'x'),
    (id: oRaw;     short: '';   long: 'raw';        value: False; cmds: 'cdt'),
    (id: oSize;    short: '';   long: 'size';       value: True;  cmds: 'dt'),
    (id: oPassword; short: '';  long: 'password';   value: False; cmds: 'axlicdtk'),
    (id: oPasswordFile; short: ''; long: 'password-file'; value: True; cmds: 'axlicdtk'),
    (id: oNewPassword; short: ''; long: 'new-password'; value: True; cmds: 'k'),
    (id: oNewPasswordFile; short: ''; long: 'new-password-file'; value: True; cmds: 'k'),
    (id: oVisibleNames; short: ''; long: 'visible-names'; value: False; cmds: 'a'),
    (id: oKdfMem;  short: '';   long: 'kdf-mem';    value: True;  cmds: 'ack'),
    (id: oKdfMemMax; short: ''; long: 'kdf-mem-max'; value: True; cmds: 'axlidtk'),
    (id: oProgress; short: '';  long: 'progress';   value: False; cmds: 'axcdt'),
    (id: oNoProgress; short: ''; long: 'no-progress'; value: False; cmds: 'axcdt'),
    (id: oLevels;  short: '';   long: 'levels';     value: True;  cmds: 'b'),
    (id: oTime;    short: '';   long: 'time';       value: True;  cmds: 'b'),
    (id: oStats;   short: '';   long: 'stats';      value: False; cmds: 'axcdt'),
    (id: oDebug;   short: '';   long: 'debug';      value: False; cmds: 'axlicdtkbsr'),
    (id: oPaths;   short: '';   long: 'paths';      value: True;  cmds: 'axlicdtkbsr'),
    (id: oColor;   short: '';   long: 'color';      value: True;  cmds: 'axlicdtkbsr'),
    (id: oQuiet;   short: 'q';  long: 'quiet';      value: False; cmds: 'axlicdtkbsr'),
    (id: oVerbose; short: 'v';  long: 'verbose';    value: False; cmds: 'axlicdtkbsr'),
    (id: oHelp;    short: 'h';  long: 'help';       value: False; cmds: 'axlicdtkbsr')
  );

  COMMANDS = 'axlicdtkbsr';
  { each command's word, in COMMANDS' order }
  COMMAND_WORDS: array[1..11] of string = ('add', 'extract', 'list', 'info', 'compress',
    'decompress', 'test', 'key', 'bench', 'selftest', 'report');

{ the command a letter or a word names; #0 when none }
function CommandOf(const arg: string): Char;
var
  i: Integer;
begin
  Result := #0;
  if (Length(arg) = 1) and (Pos(arg[1], COMMANDS) > 0) then
    Exit(arg[1]);
  for i := Low(COMMAND_WORDS) to High(COMMAND_WORDS) do
    if arg = COMMAND_WORDS[i] then
      Exit(COMMANDS[i]);
end;

{ ── the code paths ─────────────────────────────────────────────────────── }

function SetCodePaths(const name: string): Boolean;
var
  fast: Boolean;
begin
  Result := (name = 'auto') or (name = 'c') or (name = 'pascal');
  if not Result then
    Exit;
  fast := name <> 'pascal';
  SylzUseAsm := fast;
  SylzPreferC := name = 'c';
  HufUseAsm := fast;
  HufPreferC := name = 'c';
{$ifndef SYLZ_PUREPASCAL}
  Blake2sUseC := fast;
  CdcUseC := fast;
  CryptoUseC := fast;
  CrcUseC := fast;
{$endif}
end;

function CodePathsBuilt: string;
begin
{$if defined(SYLZ_PUREPASCAL)}
  Result := 'Pascal only (built with -dSYLZ_PUREPASCAL)';
{$elseif defined(CPUX86_64)}
  Result := 'x86-64 assembler, C, Pascal';
{$else}
  Result := 'C, Pascal';
{$endif}
end;

function CodePathsInUse: string;
begin
{$if defined(SYLZ_PUREPASCAL)}
  Result := 'Pascal';
{$else}
  if not SylzUseAsm then
    Result := 'Pascal'
  else
  begin
  {$ifdef CPUX86_64}
    if SylzPreferC then
      Result := 'C'
    else if HufUseBmi2 then
      Result := 'assembler (with BMI2) and C'
    else
      Result := 'assembler (no BMI2) and C';
  {$else}
    Result := 'C';
    {$ifdef CPUI386}
    Result := Result + ' (the decoder takes SSE2 when the CPU has it)';
    {$endif}
  {$endif}
  end;
{$endif}
end;

function VersionLines: string;
begin
  Result := 'syc ' + SYC_VERSION + LineEnding
    + Format('commit %s (%s), Free Pascal %s, %s; paths: %s',
        [BUILD_COMMIT, BUILD_DATE, BUILD_FPC, BUILD_TARGET, CodePathsInUse]);
end;

{ ── help ───────────────────────────────────────────────────────────────── }

const
  OPT_COL = 26;   { where an option's text starts }

{ the width help is wrapped to: the terminal's, at most 100 }
function HelpWidth: Integer;
begin
  if IsTerminal(1) then
    Result := TermWidth(1)
  else
    Result := 80;
  if Result > 100 then
    Result := 100;
end;

{ text wrapped at the help's width, its lines starting at column indent;
  the first line starts at column first (where the cursor already is) }
procedure Wrapped(const text: string; first, indent: Integer);
var
  words: TStringArray;
  col, i: Integer;
begin
  words := text.Split([' '], TStringSplitOptions.ExcludeEmpty);
  col := first;
  for i := 0 to High(words) do
  begin
    if (col > indent) and (col + 1 + DisplayWidth(words[i]) > HelpWidth) then
    begin
      WriteLn;
      Write(StringOfChar(' ', indent));
      col := indent;
    end
    else if col > indent then
    begin
      Write(' ');
      Inc(col);
    end;
    Write(words[i]);
    Inc(col, DisplayWidth(words[i]));
  end;
  WriteLn;
end;

procedure Section(const title: string);
begin
  WriteLn;
  WriteLn(Paint(1, stHead, title));
end;

{ "  -t, --threads N        what it does ..." }
procedure Opt(const flags, text: string);
var
  w: Integer;
begin
  w := 2 + DisplayWidth(flags);
  Write('  ', Paint(1, stOk, flags));
  if w + 2 > OPT_COL then
  begin
    WriteLn;
    Write(StringOfChar(' ', OPT_COL));
  end
  else
    Write(StringOfChar(' ', OPT_COL - w));
  Wrapped(text, OPT_COL, OPT_COL);
end;

procedure Para(const text: string);
begin
  Write('  ');
  Wrapped(text, 2, 2);
end;

{ "syc a — what it does", then "Usage: syc a [options] ARCHIVE PATH..." }
procedure Title(cmd: Char; const args, what: string);
begin
  WriteLn(Paint(1, stHead, 'syc ' + cmd), ' — ', what);
  WriteLn;
  WriteLn(Paint(1, stHead, 'Usage: '), Paint(1, stOk, 'syc ' + cmd), ' ', args);
end;

procedure Usage;

  procedure Cmd(const cmd, args, what: string);
  begin
    WriteLn('  ', Paint(1, stOk, Format('%-18s', [cmd])), Format('%-30s', [args]), what);
  end;

begin
  WriteLn(Paint(1, stHead, 'syc ' + SYC_VERSION), ' — sylz archiver and compressor. Tuned for modest hardware.');
  Section('Archives (.syc: files and directories, versions, deduplicated)');
  Cmd('syc a, add', '[options] ARCHIVE PATH...', 'a new archive, or a new version');
  Cmd('syc x, extract', '[options] ARCHIVE [FILTER...]', 'extract');
  Cmd('syc l, list', '[options] ARCHIVE [FILTER...]', 'list');
  Section('One file (.sylz stream; no FILE or -: stdin to stdout)');
  Cmd('syc c, compress', '[options] [FILE...]', 'FILE to FILE' + STREAM_SUFFIX);
  Cmd('syc d, decompress', '[options] [FILE...]', 'FILE' + STREAM_SUFFIX + ' to FILE');
  Section('Archives and streams');
  Cmd('syc t, test', '[options] [FILE...]', 'check them, write nothing');
  Cmd('syc i, info', '[options] FILE', 'versions, blocks, sizes, deduplication');
  Cmd('syc k, key', '[options] FILE...', 'change the password of encrypted ones');
  Section('This build, on this machine');
  Cmd('syc b, bench', '[options] FILE...', 'speed and ratio of each level, in memory');
  Cmd('syc s, selftest', '', 'check that this build works here');
  Cmd('syc r, report', '', 'what to paste into a bug report');
  WriteLn;
  Cmd('syc h CMD', '(or syc CMD -h)', 'a command''s options');
  Cmd('syc -V', '(or --version)', 'the version and the build');
  WriteLn;
  Wrapped('Every command takes -q / -v, --color auto|always|never, --debug and '
    + '--paths auto|c|pascal; a, x, c, d and t also --stats and --progress. '
    + 'An ARCHIVE of - is stdin (stdout for a new one).', 0, 0);
  WriteLn;
  WriteLn(Paint(1, stHead, 'Exit status: '), '0 ok, 1 something skipped or unreadable, 2 usage,');
  WriteLn('  3 corrupt data, 4 I/O error or out of memory');
end;

procedure LevelUsage;
begin
  Opt('-0 .. -' + IntToStr(SYLZ_MAXLEVEL) + ', --level N',
    Format('level: 0 fastest .. %d best ratio, default %d (0-1 single hash, 2-3 two hashes, '
      + '4-8 hash chains, 9-10 optimal parsing)', [SYLZ_MAXLEVEL, SYLZ_DEFLEVEL]));
  Opt('-ec, --ec', Format('extra compression: entropy-coded literals (sylz format v5; v3 with -F 2), '
    + 'smaller, slower to decode; levels 0..%d: 0-8 parse as -%d..-%d do, 9-10 price literals '
    + 'by their Huffman codes', [SYLZ_EC_MAXLEVEL, SYLZ_EC_SHIFT, SYLZ_MAXLEVEL]));
  Opt('-F, --format N', 'the sylz block format: 4 (default; 5 with -ec), read by syc 0.7.0 and '
    + 'later; or 2 (3 with -ec), larger and slower but read by every syc since 0.2.14');
end;

procedure PasswordUsage(cmd: Char);
begin
  if cmd in ['a', 'c'] then
  begin
    Opt('-p, --password', 'encrypt (XChaCha20-Poly1305, key from Argon2id); the password comes '
      + 'from -pPASSWORD / --password=PASSWORD (seen by other users: avoid), --password-file FILE, '
      + 'SYC_PASSWORD, else the terminal');
    Opt('--kdf-mem MIB', 'Argon2id''s memory, default 64');
    if cmd = 'a' then
      Opt('--visible-names', 'encrypt the data only: names, sizes, dates stay listable');
  end
  else if cmd in ['x', 'l', 'i', 't', 'd'] then
    Opt('-pPASSWORD, --password-file FILE', 'for encrypted files (or SYC_PASSWORD, or asked)')
  else if cmd = 'k' then
  begin
    Opt('-pPASSWORD, --password-file FILE', 'the current password (or SYC_PASSWORD, or asked)');
    Opt('--new-password=PASSWORD, --new-password-file FILE',
      'the new one (or SYC_NEW_PASSWORD, or asked twice)');
    Opt('--kdf-mem MIB', 'Argon2id''s memory for the new password, default: as the current one''s');
  end;
  if cmd in ['a', 'x', 'l', 'i', 't', 'd', 'k'] then
    Opt('--kdf-mem-max MIB', 'refuse files whose key needs more memory, default 1024');
end;

{ the options every command takes }
procedure CommonUsage(cmd: Char);
begin
  Section('Output');
  Opt('-q, --quiet', 'only errors and warnings');
  Opt('-v, --verbose', 'more detail: exact bytes, every step');
  if cmd in ['a', 'x', 'c', 'd', 't'] then
  begin
    Opt('--progress, --no-progress', 'progress on stderr (default: if it is a terminal)');
    Opt('--stats', 'at the end: bytes in and out, time, speed, threads, peak memory');
  end;
  Opt('--color WHEN', 'colours: auto (on a terminal, unless NO_COLOR is set), always, never');
  Opt('--debug', 'an error says its kind and where it happened; the time each phase took, '
    + 'at the end');
  Opt('--paths WHICH', 'auto: the fastest code built in; c: C instead of assembler; pascal: '
    + 'the reference Pascal only (the same bytes, slower: to tell a fast path''s bug from '
    + 'a format''s). Also SYC_PATHS');
end;

procedure EncryptionUsage(cmd: Char);
begin
  Section('Encryption');
  PasswordUsage(cmd);
end;

procedure CmdUsage(cmd: Char);
begin
  case cmd of
    'a':
      begin
        Title(cmd, '[options] ARCHIVE PATH...', 'add files and directories (recursively)');
        WriteLn;
        Para('A new ARCHIVE, or a new version at the end of an existing one with what changed '
          + 'since its last version; - writes a new one to stdout. Paths are stored relative: '
          + 'a leading / or drive letter is dropped, and a path with .. is refused (use -C).');
        Section('Compression');
        LevelUsage;
        Opt('-b, --block-size MIB', Format('solid block size, default %d, 1..%d',
          [DEFAULT_ARCHIVE_BLOCK_MIB, MAX_BLOCK shr 20]));
        Opt('-t, --threads N', 'blocks compressed N at a time, default 1 (the archive is the '
          + 'same whatever N)');
        Section('What goes in');
        Opt('-C, --cd DIR', 'PATHs are relative to DIR (stored without it)');
        Opt('-X, --exclude PATTERN', 'skip what matches (repeatable): * and ? within a name, '
          + '** across directories; a PATTERN without / matches names, with / whole paths');
        Opt('--no-dedup', 'store repeated fragments again');
        Opt('--no-delete', 'what is gone from under the PATHs stays in the new version (by '
          + 'default it is marked deleted; older versions keep it either way: syc x -u)');
        EncryptionUsage(cmd);
        CommonUsage(cmd);
      end;
    'x':
      begin
        Title(cmd, '[options] ARCHIVE [FILTER...]', 'extract');
        WriteLn;
        Para('Everything, or what the FILTERs select (as in syc l).');
        Section('Where and how');
        Opt('-o, --out DIR', 'extract under DIR, default the current directory');
        Opt('-f, --force', 'replace files that exist');
        Opt('--skip', 'leave files that exist, silently (neither: they are left, with a '
          + 'warning, exit 1)');
        Opt('-O, --stdout', 'write the one selected file to stdout');
        Opt('-u, --until V', 'the archive as of version V (a number, or a date: '
          + 'YYYY-MM-DD[THH:MM[:SS]], local time)');
        Opt('-X, --exclude PATTERN', 'leave out what matches (repeatable)');
        Opt('--no-perms', 'do not set permissions / attributes');
        Opt('--no-owner', 'do not set the owner (only root sets it anyway)');
        Opt('-t, --threads N', 'blocks decompressed N at a time, default 1');
        EncryptionUsage(cmd);
        CommonUsage(cmd);
      end;
    'l':
      begin
        Title(cmd, '[options] ARCHIVE [FILTER...]', 'list the files');
        WriteLn;
        Para('A FILTER is a path, a directory with everything in it, or a pattern as in -X.');
        Section('What and how');
        Opt('-l, --long', 'permissions, size, date (on a terminal sizes are rounded and a '
          + 'total follows; -v: exact bytes)');
        Opt('-u, --until V', 'as of version V (a number or a date, as in syc x)');
        Opt('--all', 'every version of each path, deletions included');
        Opt('--null', 'end each entry with a NUL byte, not a newline (for scripts: names '
          + 'may hold newlines; plain, no colours)');
        Opt('-X, --exclude PATTERN', 'leave out what matches (repeatable)');
        EncryptionUsage(cmd);
        CommonUsage(cmd);
      end;
    'i':
      begin
        Title(cmd, '[options] FILE', 'what an archive or a stream holds');
        WriteLn;
        Para('An archive: each version''s date, entries, data added, stored size, and the '
          + 'deduplication. A ' + STREAM_SUFFIX + ' stream: its format, level, blocks and '
          + 'sizes (no password needed). -v: exact bytes; an archive''s blocks per version, '
          + 'each block of a stream.');
        EncryptionUsage(cmd);
        CommonUsage(cmd);
      end;
    'b':
      begin
        Title(cmd, '[options] FILE...', 'benchmark');
        WriteLn;
        Para('Each FILE compressed and decompressed in memory at each level, on one thread; '
          + 'the best of the repetitions, in MB/s (10^6 bytes) of FILE.');
        Section('What to measure');
        Opt('--levels LIST', 'levels to run: 1,4,9 or 0-10 or both; default all (-N: only '
          + 'level N)');
        Opt('-ec, --ec', 'entropy-coded literals (format v5; v3 with -F 2)');
        Opt('-F, --format N', 'the sylz block format: 4 (default; 5 with -ec) or 2');
        Opt('--time SECONDS', 'least time per measurement, default 1');
        Opt('-b, --block-size MIB', Format('blocks of MIB, as syc c makes them; default: FILE '
          + 'as one block (up to %d MiB)', [MAX_BLOCK shr 20]));
        CommonUsage(cmd);
      end;
    's':
      begin
        Title(cmd, '[options]', 'self-test');
        WriteLn;
        Para('The codec at every level and format through every code path built in (the '
          + 'same bytes from each), damaged input, the checksums, hashes and ciphers against '
          + 'known answers, and a stream and an archive written and read back in the '
          + 'temporary directory. Exit status 0, or 4 when a check fails. -q: only the '
          + 'failures and the summary; -v: every check.');
        CommonUsage(cmd);
      end;
    'r':
      begin
        Title(cmd, '[options]', 'what to paste into a bug report');
        WriteLn;
        Para('This build (version, commit, compiler, target, code paths), this machine '
          + '(system, CPU, memory), the SYC_* variables that are set (their names only) and '
          + 'the self-test''s result, to paste into a bug report at '
          + 'https://github.com/YadeWira/syc/issues');
        CommonUsage(cmd);
      end;
    'c':
      begin
        Title(cmd, '[options] [FILE...]', 'compress');
        WriteLn;
        Para('FILE ' + Arrow(1) + ' FILE' + STREAM_SUFFIX + '; no FILE or -: stdin '
          + Arrow(1) + ' stdout.');
        Section('Compression');
        LevelUsage;
        Opt('-b, --block-size MIB', Format('block size, default %d, 1..%d',
          [DEFAULT_STREAM_BLOCK_MIB, MAX_BLOCK shr 20]));
        Opt('-t, --threads N', 'blocks compressed N at a time, default 1 (the output is the '
          + 'same whatever N)');
        Opt('--raw', Format('one bare sylz block (v4, v5 with -ec; -F 2: v2, v3), what the '
          + 'zpaq-std plugins'' compress() returns: no header, size or CRC; FILE up to %d MiB, '
          + '%s FILE%s', [MAX_BLOCK shr 20, Arrow(1), RAW_SUFFIX]));
        Section('Where');
        Opt('-o, --out FILE', 'output file (one FILE only); - is stdout');
        Opt('-O, --stdout', 'write to stdout');
        Opt('-f, --force', 'overwrite an existing output; write to a terminal');
        Opt('--rm', 'delete FILE once it is compressed');
        EncryptionUsage(cmd);
        CommonUsage(cmd);
      end;
    'd':
      begin
        Title(cmd, '[options] [FILE...]', 'decompress');
        WriteLn;
        Para('FILE' + STREAM_SUFFIX + ' ' + Arrow(1) + ' FILE; no FILE or -: stdin '
          + Arrow(1) + ' stdout.');
        Section('Where and how');
        Opt('-t, --threads N', 'blocks decompressed N at a time, default 1');
        Opt('-o, --out FILE', 'output file (one FILE only); - is stdout');
        Opt('-O, --stdout', 'write to stdout');
        Opt('-f, --force', 'overwrite an existing output');
        Opt('--rm', 'delete FILE once it is decompressed');
        Opt('--raw --size N', 'FILE is one bare sylz block of N bytes decoded (syc c --raw; '
          + 'FILE' + RAW_SUFFIX + ' ' + Arrow(1) + ' FILE)');
        EncryptionUsage(cmd);
        CommonUsage(cmd);
      end;
    'k':
      begin
        Title(cmd, '[options] FILE...', 'change the password of encrypted files');
        WriteLn;
        Para('Archives and streams, in place, without recompressing: the data key is wrapped '
          + 'again. If interrupted, the old or the new password opens FILE, never neither.');
        EncryptionUsage(cmd);
        CommonUsage(cmd);
      end;
    't':
      begin
        Title(cmd, '[options] [FILE...]', 'check archives and streams');
        WriteLn;
        Para('Archives (.syc) and streams (' + STREAM_SUFFIX + '), writing nothing; no FILE '
          + 'or -: stdin. Every block''s CRC-32 (or, encrypted, its tag); in an archive also '
          + 'the index and each fragment''s BLAKE2s-256.');
        Section('How');
        Opt('-t, --threads N', 'blocks checked N at a time, default 1');
        Opt('--raw --size N', 'FILE is one bare sylz block of N bytes decoded');
        EncryptionUsage(cmd);
        CommonUsage(cmd);
      end;
  end;
end;

{ -X as the archive's paths are: "./a/b/", "/a/b" and "a\b" (Windows)
  match the stored "a/b", as a PATH or a FILTER given that way does }
function ExcludePattern(const value: string): string;
begin
  Result := value;
{$ifdef windows}
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
{$endif}
  if Pos('/', Result) = 0 then
    Exit;
  while Copy(Result, 1, 2) = './' do
    Delete(Result, 1, 2);
  while Copy(Result, 1, 1) = '/' do
    Delete(Result, 1, 1);
  while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  if Result = '' then
    Result := value;
end;

procedure UsageError(const msg: string);
begin
  Fail(EXIT_USAGE, msg + ' (syc -h for help)');
end;

function IntArg(const name, s0: string; lo, hi: Integer): Integer;
var
  i: Integer;
  digits: Boolean;
  s: string;
begin
  s := Trim(s0);   { "  123", as macOS's wc -c prints a size }
  { decimal digits only (TryStrToInt also takes $4, 0x4 and spaces) }
  digits := (s <> '') and (Length(s) <= 9);
  for i := 1 to Length(s) do
    if not (s[i] in ['0'..'9']) and not ((i = 1) and (s[i] = '-') and (Length(s) > 1)) then
      digits := False;
  if not digits or not TryStrToInt(s, Result) or (Result < lo) or (Result > hi) then
    UsageError(Format('%s takes a number %d..%d, not "%s"', [name, lo, hi, s0]));
end;

{ --levels: numbers and ranges, 1,4,9 or 0-10 or 0-3,9 }
procedure ParseLevels(const name, spec: string; out levels: TIntArray);
var
  parts: TStringArray;
  i, k, lo, hi, dash: Integer;
begin
  levels := nil;
  parts := spec.Split([',']);
  for i := 0 to High(parts) do
  begin
    dash := Pos('-', parts[i]);
    if dash > 0 then
    begin
      lo := IntArg(name, Copy(parts[i], 1, dash - 1), SYLZ_MINLEVEL, SYLZ_MAXLEVEL);
      hi := IntArg(name, Copy(parts[i], dash + 1, MaxInt), lo, SYLZ_MAXLEVEL);
    end
    else
    begin
      lo := IntArg(name, parts[i], SYLZ_MINLEVEL, SYLZ_MAXLEVEL);
      hi := lo;
    end;
    for k := lo to hi do
    begin
      SetLength(levels, Length(levels) + 1);
      levels[High(levels)] := k;
    end;
  end;
end;

procedure ParseCommandLine(out opts: TOptions);
var
  i, j, k: Integer;
  arg, name, value, shown: string;
  hasValue, noMore: Boolean;
  progressSet: Integer;   { -1: not given }
  paths: string;
  fmtEc: Integer;         { the last -F: 1 an -ec format (3, 5), 0 not, -1 none }
begin
  progressSet := -1;
  fmtEc := -1;
  { SYC_PATHS first, so that syc -V tells what it selects; a wrong value
    is reported below }
  paths := SysUtils.GetEnvironmentVariable('SYC_PATHS');
  if paths <> '' then
    SetCodePaths(paths);
  opts := Default(TOptions);
  opts.level := SYLZ_DEFLEVEL;
  opts.flags := DEFAULT_FLAGS;
  opts.blockMiB := 0;
  opts.threads := 1;
  opts.verbosity := vNormal;
  opts.rawSize := -1;
  opts.kdfMemMiB := 64;
  opts.kdfMemMaxMiB := 1024;
  opts.benchSeconds := 1;

  if CmdArgCount < 1 then
  begin
    Usage;
    Halt(EXIT_USAGE);
  end;
  arg := CmdArg(1);
  if (arg = '-h') or (arg = '--help') or (arg = 'h') or (arg = 'help') then
  begin
    if CmdArgCount >= 2 then
    begin
      if CommandOf(CmdArg(2)) = #0 then
        UsageError('unknown command "' + CmdArg(2) + '"');
      CmdUsage(CommandOf(CmdArg(2)));
    end
    else
      Usage;
    CheckOutput;
    Halt(EXIT_OK);
  end;
  if (arg = '-V') or (arg = '--version') then
  begin
    WriteLn(VersionLines);
    CheckOutput;
    Halt(EXIT_OK);
  end;
  opts.cmd := CommandOf(arg);
  if opts.cmd = #0 then
    UsageError('unknown command "' + arg + '"');

  noMore := False;
  i := 2;
  while i <= CmdArgCount do
  begin
    arg := CmdArg(i);
    Inc(i);
    if noMore or (arg = '-') or (Length(arg) < 2) or (arg[1] <> '-') then
    begin
      SetLength(opts.operands, Length(opts.operands) + 1);
      opts.operands[High(opts.operands)] := arg;
      Continue;
    end;
    if arg = '--' then
    begin
      noMore := True;
      Continue;
    end;

    { -N: a level }
    if (arg[2] in ['0'..'9']) then
    begin
      opts.level := IntArg('the level', Copy(arg, 2, MaxInt), SYLZ_MINLEVEL, SYLZ_MAXLEVEL);
      opts.levelSet := True;
      if Pos(opts.cmd, OPTION_DEFS[Ord(oLevel)].cmds) = 0 then
        UsageError(Format('syc %s takes no level', [opts.cmd]));
      Continue;
    end;

    { -p, -pPASSWORD, --password=PASSWORD: the value is optional }
    if (Copy(arg, 1, 2) = '-p') or (Copy(arg, 1, 11) = '--password=') then
    begin
      if Pos(opts.cmd, OPTION_DEFS[Ord(oPassword)].cmds) = 0 then
        UsageError(Format('syc %s takes no password', [opts.cmd]));
      if arg = '-p' then
        opts.passwordFlag := True
      else if Copy(arg, 1, 2) = '-p' then
        opts.passwordInline := Copy(arg, 3, MaxInt)
      else
        opts.passwordInline := Copy(arg, 12, MaxInt);
      if (arg <> '-p') and (opts.passwordInline = '') then
        UsageError('an empty password');
      Continue;
    end;

    { find the option: long (--name or --name=value), or short (-x, -xVALUE) }
    k := -1;
    hasValue := False;
    value := '';
    if arg[2] = '-' then
    begin
      name := Copy(arg, 3, MaxInt);
      j := Pos('=', name);
      if j > 0 then
      begin
        value := Copy(name, j + 1, MaxInt);
        name := Copy(name, 1, j - 1);
        hasValue := True;
      end;
      for j := 0 to High(OPTION_DEFS) do
        if OPTION_DEFS[j].long = name then
          k := j;
      shown := '--' + name;
    end
    else
    begin
      name := Copy(arg, 2, MaxInt);
      { the exact name first (-ec), then a one-letter one with its value
        attached (-t4) }
      for j := 0 to High(OPTION_DEFS) do
        if OPTION_DEFS[j].short = name then
          k := j;
      if k < 0 then
        for j := 0 to High(OPTION_DEFS) do
          if (Length(OPTION_DEFS[j].short) = 1) and OPTION_DEFS[j].value and (name[1] = OPTION_DEFS[j].short[1]) then
          begin
            k := j;
            value := Copy(name, 2, MaxInt);
            hasValue := True;
          end;
      shown := '-' + Copy(name, 1, Length(name) - Length(value));
    end;
    if k < 0 then
      UsageError('unknown option ' + shown);
    if Pos(opts.cmd, OPTION_DEFS[k].cmds) = 0 then
      UsageError(Format('syc %s does not take %s', [opts.cmd, shown]));
    if OPTION_DEFS[k].value and not hasValue then
    begin
      if i > CmdArgCount then
        UsageError(shown + ' needs a value');
      value := CmdArg(i);
      Inc(i);
    end
    else if hasValue and not OPTION_DEFS[k].value then
      UsageError(shown + ' takes no value');

    case OPTION_DEFS[k].id of
      oLevel:
        begin
          opts.level := IntArg(shown, value, SYLZ_MINLEVEL, SYLZ_MAXLEVEL);
          opts.levelSet := True;
        end;
      oEc: opts.flags := opts.flags or SYLZ_ENTROPY;
      oFormat:
        { 2 and 4 are the plain formats, 3 and 5 those with -ec }
        begin
          { the last -F decides; -ec adds entropy coding whatever -F says }
          case IntArg(shown, value, 2, 5) of
            2, 3: opts.flags := opts.flags and not SYLZ_V4;
            4, 5: opts.flags := opts.flags or SYLZ_V4;
          end;
          fmtEc := Ord(value[Length(value)] in ['3', '5']);
        end;
      oBlock: opts.blockMiB := IntArg(shown, value, 1, MAX_BLOCK shr 20);
      oThreads: opts.threads := IntArg(shown, value, 1, MAX_THREADS);
      oOut:
        begin
          if value = '' then
            UsageError(shown + ' needs a file name');
          opts.outPath := value;
        end;
      oStdout: opts.toStdout := True;
      oForce: opts.force := True;
      oRm: opts.removeInput := True;
      oCd:
        begin
          if value = '' then
            UsageError(shown + ' needs a directory');
          opts.cdDir := value;
        end;
      oExclude:
        begin
          SetLength(opts.excludes, Length(opts.excludes) + 1);
          opts.excludes[High(opts.excludes)] := ExcludePattern(value);
        end;
      oNoDedup: opts.noDedup := True;
      oNoDelete: opts.noDelete := True;
      oRaw: opts.raw := True;
      oPassword: opts.passwordFlag := True;
      oPasswordFile:
        begin
          if value = '' then
            UsageError(shown + ' needs a file');
          opts.passwordFile := value;
        end;
      oVisibleNames: opts.visibleNames := True;
      oKdfMem:
        begin
          opts.kdfMemMiB := IntArg(shown, value, 8, 4096);
          opts.kdfMemSet := True;
        end;
      oKdfMemMax: opts.kdfMemMaxMiB := IntArg(shown, value, 8, 4096);
      oNewPassword:
        begin
          if value = '' then
            UsageError('an empty password');
          opts.newPasswordInline := value;
        end;
      oNewPasswordFile:
        begin
          if value = '' then
            UsageError(shown + ' needs a file');
          opts.newPasswordFile := value;
        end;
      oSize: opts.rawSize := IntArg(shown, value, 0, MAX_BLOCK);
      oAll: opts.allVersions := True;
      oNull: opts.nullSep := True;
      oLong: opts.longList := True;
      oSkip: opts.skipExisting := True;
      oUntil:
        begin
          if value = '' then
            UsageError(shown + ' needs a version or a date');
          opts.untilSpec := value;
        end;
      oNoPerms: opts.noPerms := True;
      oNoOwner: opts.noOwner := True;
      oProgress: progressSet := 1;
      oNoProgress: progressSet := 0;
      oLevels: ParseLevels(shown, value, opts.benchLevels);
      oTime:
        begin
          { digits and a point only: Val takes "nan" and "inf", and
            comparing a NaN raises }
          k := 0;
          for j := 1 to Length(value) do
            if not (value[j] in ['0'..'9', '.']) then
              k := j;
          if (k = 0) and (value <> '') then
            Val(value, opts.benchSeconds, k);
          if (k <> 0) or (value = '') or (opts.benchSeconds > 3600) then
            UsageError(Format('%s takes seconds, 0..3600, not "%s"', [shown, value]));
        end;
      oStats: opts.stats := True;
      oDebug: opts.debug := True;
      oPaths: paths := value;
      oColor:
        if value = 'auto' then
          SetColorMode(cmAuto)
        else if value = 'always' then
          SetColorMode(cmAlways)
        else if value = 'never' then
          SetColorMode(cmNever)
        else
          UsageError(Format('%s takes auto, always or never, not "%s"', [shown, value]));
      oQuiet: opts.verbosity := vQuiet;
      oVerbose: opts.verbosity := vVerbose;
      oHelp:
        begin
          CmdUsage(opts.cmd);
          CheckOutput;
          Halt(EXIT_OK);
        end;
    end;
  end;

  SycDebug := opts.debug;
  if fmtEc = 1 then
    opts.flags := opts.flags or SYLZ_ENTROPY;
  { a key that needs more memory than readers allow by default: each of
    them will have to give --kdf-mem-max }
  if opts.kdfMemSet and (opts.cmd in ['a', 'c', 'k']) and (opts.kdfMemMiB > 1024) then
    WriteLn(StdErr, WarnTag, Format('--kdf-mem %d: reading it will need --kdf-mem-max %d '
      + '(the default limit is 1024)', [opts.kdfMemMiB, opts.kdfMemMiB]));
  if (paths <> '') and not SetCodePaths(paths) then
    UsageError(Format('--paths (or SYC_PATHS) takes auto, c or pascal, not "%s"', [paths]));
  if (opts.flags and SYLZ_ENTROPY <> 0) and (opts.level > SYLZ_EC_MAXLEVEL) then
    UsageError(Format('with -ec the levels are %d..%d', [SYLZ_MINLEVEL, SYLZ_EC_MAXLEVEL]));
  if (opts.cmd in ['c', 'd']) and (opts.outPath <> '') and (Length(opts.operands) > 1) then
    UsageError('-o takes one input only');
  if (opts.outPath <> '') and opts.toStdout then
    UsageError('-o and -O together');
  if opts.cmd = 'c' then
  begin
    { two streams one after the other are not a stream: syc d refuses
      what follows the first one's end }
    k := 0;
    for j := 0 to High(opts.operands) do
      if opts.toStdout or (opts.operands[j] = '-') then
        Inc(k);
    if k > 1 then
      UsageError('syc c writes one stream to stdout, from one input');
  end;
  if opts.force and opts.skipExisting then
    UsageError('-f and --skip together');
  if opts.raw and (opts.cmd in ['d', 't']) and (opts.rawSize < 0) then
    UsageError('--raw needs --size N: a bare block does not hold its decoded size');
  if (opts.rawSize >= 0) and not opts.raw then
    UsageError('--size goes with --raw');
  if opts.raw and (opts.passwordFlag or (opts.passwordInline <> '') or (opts.passwordFile <> '')) then
    UsageError('--raw writes a bare sylz block: it cannot be encrypted');
  if opts.raw and (opts.blockMiB > 0) then
    UsageError('--raw writes one block: no -b');
  if (opts.cmd in ['c', 'd']) and (opts.outPath = '-') then
  begin
    opts.outPath := '';
    opts.toStdout := True;
  end;
  if progressSet >= 0 then
    opts.progress := progressSet = 1
  else
    opts.progress := (opts.verbosity <> vQuiet) and IsTerminal(2);
  if (opts.blockMiB = 0) and (opts.cmd <> 'b') then   { b: 0 is the whole file }
    if opts.cmd = 'a' then
      opts.blockMiB := DEFAULT_ARCHIVE_BLOCK_MIB
    else
      opts.blockMiB := DEFAULT_STREAM_BLOCK_MIB;
  case opts.cmd of
    'a': if Length(opts.operands) < 2 then
           UsageError('syc a needs an ARCHIVE and at least one PATH');
    'l', 'x':
         if Length(opts.operands) < 1 then
           UsageError(Format('syc %s needs an ARCHIVE', [opts.cmd]));
    'i': if Length(opts.operands) <> 1 then
           UsageError('syc i takes one FILE');
    'b': if Length(opts.operands) < 1 then
           UsageError('syc b needs a FILE');
    's', 'r':
         if Length(opts.operands) > 0 then
           UsageError(Format('syc %s takes no operands', [opts.cmd]));
    'k': if Length(opts.operands) < 1 then
           UsageError('syc k needs a FILE');
  end;
end;

end.
