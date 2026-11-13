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
  SYC_VERSION   = '0.7.0';
  STREAM_SUFFIX = '.sylz';
  RAW_SUFFIX    = '.sylzraw';
  DEFAULT_STREAM_BLOCK_MIB = 4;
  DEFAULT_ARCHIVE_BLOCK_MIB = 16;

type
  TVerbosity = (vQuiet, vNormal, vVerbose);
  TIntArray = array of Integer;

  TOptions = record
    cmd: Char;               { 'a', 'x', 'l', 'i', 'c', 'd', 't', 'k', 'b', 's', 'r' }
    level: Integer;
    levelSet: Boolean;       { a level was given (b: only that one) }
    flags: Integer;          { SYLZ_ENTROPY with -ec }
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
{ "syc 0.7.0" and, on a second line, the commit, compiler and target }
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
    oCd, oExclude, oNoDedup, oNoDelete, oAll, oLong, oSkip, oUntil, oNoPerms, oNoOwner,
    oRaw, oSize, oPassword, oPasswordFile, oNewPassword, oNewPasswordFile, oVisibleNames, oKdfMem, oProgress, oNoProgress,
    oLevels, oTime, oStats, oDebug, oPaths, oColor, oQuiet, oVerbose, oHelp);

  TOptDef = record
    id: TOptId;
    short, long: string;     { without the dashes; '' when there is none }
    value: Boolean;          { takes a value }
    cmds: string;            { the commands it applies to }
  end;

const
  OPTION_DEFS: array[0..37] of TOptDef = (
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

procedure Usage;

  procedure Head(const title: string);
  begin
    WriteLn;
    WriteLn(Paint(1, stHead, title));
  end;

  procedure Cmd(const cmd, args, what: string);
  begin
    WriteLn('  ', Paint(1, stOk, Format('%-18s', [cmd])), Format('%-30s', [args]), what);
  end;

begin
  WriteLn(Paint(1, stHead, 'syc ' + SYC_VERSION), ' — sylz archiver and compressor. Tuned for modest hardware.');
  Head('Archives (.syc: files and directories, versions, deduplicated)');
  Cmd('syc a, add', '[options] ARCHIVE PATH...', 'a new archive, or a new version');
  Cmd('syc x, extract', '[options] ARCHIVE [FILTER...]', 'extract');
  Cmd('syc l, list', '[options] ARCHIVE [FILTER...]', 'list');
  Head('One file (.sylz stream; no FILE or -: stdin to stdout)');
  Cmd('syc c, compress', '[options] [FILE...]', 'FILE to FILE' + STREAM_SUFFIX);
  Cmd('syc d, decompress', '[options] [FILE...]', 'FILE' + STREAM_SUFFIX + ' to FILE');
  Head('Archives and streams');
  Cmd('syc t, test', '[options] [FILE...]', 'check them, write nothing');
  Cmd('syc i, info', '[options] FILE', 'versions, blocks, sizes, deduplication');
  Cmd('syc k, key', '[options] FILE...', 'change the password of encrypted ones');
  Head('This build, on this machine');
  Cmd('syc b, bench', '[options] FILE...', 'speed and ratio of each level, in memory');
  Cmd('syc s, selftest', '', 'check that this build works here');
  Cmd('syc r, report', '', 'what to paste into a bug report');
  WriteLn;
  Cmd('syc h CMD', '(or syc CMD -h)', 'a command''s options');
  Cmd('syc -V', '(or --version)', 'the version and the build');
  WriteLn;
  WriteLn('Every command takes -q / -v, --color auto|always|never, --debug and');
  WriteLn('--paths auto|c|pascal; a, x, c, d and t also --stats and --progress.');
  WriteLn('An ARCHIVE of - is stdin (stdout for a new one). Exit status: 0 ok,');
  WriteLn('1 something skipped or unreadable, 2 usage, 3 corrupt data, 4 I/O error');
  WriteLn('or out of memory.');
end;

procedure LevelUsage;
begin
  WriteLn('  -0 .. -', SYLZ_MAXLEVEL, ', --level N');
  WriteLn('              level: 0 fastest .. ', SYLZ_MAXLEVEL, ' best ratio, default ',
    SYLZ_DEFLEVEL);
  WriteLn('              (0-1 single hash, 2-3 two hashes, 4-8 hash chains,');
  WriteLn('              9-10 optimal parsing)');
  WriteLn('  -ec, --ec   extra compression: entropy-coded literals (sylz format v3),');
  WriteLn('              smaller, slower to decode; levels 0..', SYLZ_EC_MAXLEVEL,
    ': 0-8 parse as -', SYLZ_EC_SHIFT, '..-', SYLZ_MAXLEVEL, ' do');
  WriteLn('              (format 5 too), 9-10 price literals by');
  WriteLn('              their Huffman codes');
  WriteLn('  -F, --format N   the sylz block format: 2 (default; 3 with -ec), or 4');
  WriteLn('              (5 with -ec): smaller and faster to compress and decompress');
  WriteLn('              at every level; read by syc 0.7.0 and later');
end;

procedure PasswordUsage(cmd: Char);
begin
  if cmd in ['a', 'c'] then
  begin
    WriteLn('  -p, --password         encrypt (XChaCha20-Poly1305, key from Argon2id); the');
    WriteLn('                         password comes from -pPASSWORD / --password=PASSWORD');
    WriteLn('                         (seen by other users: avoid), --password-file FILE,');
    WriteLn('                         SYC_PASSWORD, else the terminal');
    WriteLn('  --kdf-mem MIB          Argon2id''s memory, default 64');
    if cmd = 'a' then
      WriteLn('  --visible-names        encrypt the data only: names, sizes, dates stay listable');
  end
  else if cmd in ['x', 'l', 'i', 't', 'd'] then
    WriteLn('  -pPASSWORD, --password-file FILE   for encrypted files (or SYC_PASSWORD, or asked)')
  else if cmd = 'k' then
  begin
    WriteLn('  -pPASSWORD, --password-file FILE   the current password (or SYC_PASSWORD,');
    WriteLn('                         or asked)');
    WriteLn('  --new-password=PASSWORD, --new-password-file FILE   the new one (or');
    WriteLn('                         SYC_NEW_PASSWORD, or asked twice)');
    WriteLn('  --kdf-mem MIB          Argon2id''s memory for the new password, default: as');
    WriteLn('                         the current one''s');
  end;
end;

{ the options every command takes }
procedure CommonUsage;
begin
  WriteLn('  --color WHEN           colours: auto (on a terminal, unless NO_COLOR is set),');
  WriteLn('                         always, never');
  WriteLn('  --debug                an error says its kind and where it happened; the');
  WriteLn('                         time each phase took, at the end');
  WriteLn('  --paths WHICH          auto: the fastest code built in; c: C instead of');
  WriteLn('                         assembler; pascal: the reference Pascal only (the');
  WriteLn('                         same bytes, slower: to tell a fast path''s bug from');
  WriteLn('                         a format''s). Also SYC_PATHS');
end;

procedure ProgressUsage(cmd: Char);
begin
  PasswordUsage(cmd);
  if cmd in ['a', 'x', 'c', 'd', 't'] then
  begin
    WriteLn('  --progress, --no-progress   progress on stderr (default: if it is a terminal)');
    WriteLn('  --stats                at the end: bytes in and out, time, speed, threads,');
    WriteLn('                         peak memory');
  end;
  CommonUsage;
end;

procedure CmdUsage(cmd: Char);
begin
  case cmd of
    'a':
      begin
        WriteLn('syc a [options] ARCHIVE PATH...   add files and directories (recursively):');
        WriteLn('                                  a new ARCHIVE, or a new version at the end');
        WriteLn('                                  of an existing one with what changed since');
        WriteLn('                                  its last version; - writes a new one to stdout');
        WriteLn;
        LevelUsage;
        WriteLn('  -b, --block-size MIB   solid block size, default ', DEFAULT_ARCHIVE_BLOCK_MIB,
          ', 1..', MAX_BLOCK shr 20);
        WriteLn('  -t, --threads N        blocks compressed N at a time, default 1');
        WriteLn('                         (the archive is the same whatever N)');
        WriteLn('  -C, --cd DIR           PATHs are relative to DIR (stored without it)');
        WriteLn('  -X, --exclude PATTERN  skip what matches (repeatable): * and ? within');
        WriteLn('                         a name, ** across directories; a PATTERN');
        WriteLn('                         without / matches names, with / whole paths');
        WriteLn('  --no-dedup             store repeated fragments again');
        WriteLn('  --no-delete            what is gone from under the PATHs stays in the new');
        WriteLn('                         version (by default it is marked deleted; older');
        WriteLn('                         versions keep it either way: syc x -u)');
        WriteLn('  -q, --quiet / -v, --verbose');
        ProgressUsage(cmd);
        WriteLn;
        WriteLn('Paths are stored relative: a leading / or drive letter is dropped, and');
        WriteLn('a path with .. is refused (use -C).');
      end;
    'x':
      begin
        WriteLn('syc x [options] ARCHIVE [FILTER...]   extract (everything, or what the');
        WriteLn('                                      FILTERs select: as in syc l)');
        WriteLn;
        WriteLn('  -o, --out DIR          extract under DIR, default the current directory');
        WriteLn('  -f, --force            replace files that exist');
        WriteLn('  --skip                 leave files that exist, silently');
        WriteLn('                         (neither: they are left, with a warning, exit 1)');
        WriteLn('  -O, --stdout           write the one selected file to stdout');
        WriteLn('  -u, --until V          the archive as of version V (a number, or a date:');
        WriteLn('                         YYYY-MM-DD[THH:MM[:SS]], local time)');
        WriteLn('  -X, --exclude PATTERN  leave out what matches (repeatable)');
        WriteLn('  --no-perms             do not set permissions / attributes');
        WriteLn('  --no-owner             do not set the owner (only root sets it anyway)');
        WriteLn('  -t, --threads N        blocks decompressed N at a time, default 1');
        WriteLn('  -q, --quiet / -v, --verbose');
        ProgressUsage(cmd);
      end;
    'l':
      begin
        WriteLn('syc l [options] ARCHIVE [FILTER...]   list the files (a FILTER is a path,');
        WriteLn('                                      a directory with everything in it,');
        WriteLn('                                      or a pattern as in -X)');
        WriteLn;
        WriteLn('  -l, --long             permissions, size, date (on a terminal sizes are');
        WriteLn('                         rounded and a total follows; -v: exact bytes)');
        WriteLn('  -u, --until V          as of version V (a number or a date, as in syc x)');
        WriteLn('  --all                  every version of each path, deletions included');
        WriteLn('  -X, --exclude PATTERN  leave out what matches (repeatable)');
        WriteLn('  -q, --quiet / -v, --verbose');
        ProgressUsage(cmd);
      end;
    'i':
      begin
        WriteLn('syc i [options] FILE   an archive: each version''s date, entries, data added,');
        WriteLn('                       stored size, and the deduplication; a ', STREAM_SUFFIX, ' stream:');
        WriteLn('                       its format, level, blocks and sizes (no password');
        WriteLn('                       needed)');
        WriteLn;
        WriteLn('  -v, --verbose          exact bytes; an archive''s blocks per version, each');
        WriteLn('                         block of a stream');
        ProgressUsage(cmd);
      end;
    'b':
      begin
        WriteLn('syc b [options] FILE...   benchmark: each FILE compressed and decompressed');
        WriteLn('                          in memory at each level, on one thread; the best');
        WriteLn('                          of the repetitions, in MB/s (10^6 bytes) of FILE');
        WriteLn;
        WriteLn('  --levels LIST          levels to run: 1,4,9 or 0-10 or both; default all');
        WriteLn('                         (-N: only level N)');
        WriteLn('  -ec, --ec              format v3 (entropy-coded literals)');
        WriteLn('  --time SECONDS         least time per measurement, default 1');
        WriteLn('  -b, --block-size MIB   blocks of MIB, as syc c makes them; default: FILE as');
        WriteLn('                         one block (up to ', MAX_BLOCK shr 20, ' MiB)');
        WriteLn('  -q, --quiet / -v, --verbose');
        CommonUsage;
      end;
    's':
      begin
        WriteLn('syc s [options]   self-test: the codec at every level and format through');
        WriteLn('                  every code path built in (the same bytes from each),');
        WriteLn('                  damaged input, the checksums, hashes and ciphers against');
        WriteLn('                  known answers, and a stream and an archive written and');
        WriteLn('                  read back in the temporary directory. Exit status 0, or');
        WriteLn('                  4 when a check fails');
        WriteLn;
        WriteLn('  -q, --quiet            only the failures and the summary');
        WriteLn('  -v, --verbose          every check');
        CommonUsage;
      end;
    'r':
      begin
        WriteLn('syc r [options]   report: this build (version, commit, compiler, target,');
        WriteLn('                  code paths), this machine (system, CPU, memory), the');
        WriteLn('                  SYC_* variables that are set (their names only) and the');
        WriteLn('                  self-test''s result, to paste into a bug report at');
        WriteLn('                  https://github.com/YadeWira/syc/issues');
        WriteLn;
        CommonUsage;
      end;
    'c':
      begin
        WriteLn('syc c [options] [FILE...]   compress: FILE -> FILE', STREAM_SUFFIX,
          '; no FILE or -: stdin -> stdout');
        WriteLn;
        LevelUsage;
        WriteLn('  -b, --block-size MIB   block size, default ', DEFAULT_STREAM_BLOCK_MIB,
          ', 1..', MAX_BLOCK shr 20);
        WriteLn('  -t, --threads N        blocks compressed N at a time, default 1');
        WriteLn('                         (the output is the same whatever N)');
        WriteLn('  -o, --out FILE         output file (one FILE only); - is stdout');
        WriteLn('  -O, --stdout           write to stdout');
        WriteLn('  -f, --force            overwrite an existing output; write to a terminal');
        WriteLn('  --rm                   delete FILE once it is compressed');
        WriteLn('  --raw                  one bare sylz block (v2, v3 with -ec; -F), what the');
        WriteLn('                         zpaq-std plugins'' compress() returns: no header,');
        WriteLn('                         size or CRC; FILE up to ', MAX_BLOCK shr 20, ' MiB, -> FILE', RAW_SUFFIX);
        WriteLn('  -q, --quiet / -v, --verbose');
        ProgressUsage(cmd);
      end;
    'd':
      begin
        WriteLn('syc d [options] [FILE...]   decompress: FILE', STREAM_SUFFIX,
          ' -> FILE; no FILE or -: stdin -> stdout');
        WriteLn;
        WriteLn('  -t, --threads N        blocks decompressed N at a time, default 1');
        WriteLn('  -o, --out FILE         output file (one FILE only); - is stdout');
        WriteLn('  -O, --stdout           write to stdout');
        WriteLn('  -f, --force            overwrite an existing output');
        WriteLn('  --rm                   delete FILE once it is decompressed');
        WriteLn('  --raw --size N         FILE is one bare sylz block of N bytes decoded');
        WriteLn('                         (syc c --raw; FILE', RAW_SUFFIX, ' -> FILE)');
        WriteLn('  -q, --quiet / -v, --verbose');
        ProgressUsage(cmd);
      end;
    'k':
      begin
        WriteLn('syc k [options] FILE...   change the password of encrypted archives and');
        WriteLn('                          streams in place, without recompressing: the data');
        WriteLn('                          key is wrapped again; if interrupted, the old or');
        WriteLn('                          the new password opens FILE, never neither');
        WriteLn;
        PasswordUsage(cmd);
        WriteLn('  -q, --quiet / -v, --verbose');
        CommonUsage;
      end;
    't':
      begin
        WriteLn('syc t [options] [FILE...]   check archives (.syc) and streams (', STREAM_SUFFIX, '),');
        WriteLn('                            write nothing; no FILE or -: stdin');
        WriteLn('                            (every block''s CRC-32; in an archive also the');
        WriteLn('                            index and each fragment''s BLAKE2s-256)');
        WriteLn;
        WriteLn('  -t, --threads N        blocks checked N at a time, default 1');
        WriteLn('  --raw --size N         FILE is one bare sylz block of N bytes decoded');
        WriteLn('  -q, --quiet / -v, --verbose');
        ProgressUsage(cmd);
      end;
  end;
end;

procedure UsageError(const msg: string);
begin
  Fail(EXIT_USAGE, msg + ' (syc -h for help)');
end;

function IntArg(const name, s: string; lo, hi: Integer): Integer;
begin
  if not TryStrToInt(s, Result) or (Result < lo) or (Result > hi) then
    UsageError(Format('%s takes a number %d..%d, not "%s"', [name, lo, hi, s]));
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
begin
  progressSet := -1;
  { SYC_PATHS first, so that syc -V tells what it selects; a wrong value
    is reported below }
  paths := SysUtils.GetEnvironmentVariable('SYC_PATHS');
  if paths <> '' then
    SetCodePaths(paths);
  opts := Default(TOptions);
  opts.level := SYLZ_DEFLEVEL;
  opts.blockMiB := 0;
  opts.threads := 1;
  opts.verbosity := vNormal;
  opts.rawSize := -1;
  opts.kdfMemMiB := 64;
  opts.benchSeconds := 1;

  if CmdArgCount < 1 then
  begin
    Usage;
    Halt(EXIT_USAGE);
  end;
  arg := CmdArg(1);
  if (arg = '-h') or (arg = '--help') or (arg = 'h') or (arg = 'help') then
  begin
    if (CmdArgCount >= 2) and (CommandOf(CmdArg(2)) <> #0) then
      CmdUsage(CommandOf(CmdArg(2)))
    else
      Usage;
    Halt(EXIT_OK);
  end;
  if (arg = '-V') or (arg = '--version') then
  begin
    WriteLn(VersionLines);
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
        case IntArg(shown, value, 2, 5) of
          2: opts.flags := opts.flags and not SYLZ_V4;
          3: opts.flags := opts.flags and not SYLZ_V4 or SYLZ_ENTROPY;
          4: opts.flags := opts.flags or SYLZ_V4;
          5: opts.flags := opts.flags or SYLZ_V4 or SYLZ_ENTROPY;
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
          opts.excludes[High(opts.excludes)] := value;
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
          Val(value, opts.benchSeconds, k);
          if (k <> 0) or (opts.benchSeconds < 0) or (opts.benchSeconds > 3600) then
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
          Halt(EXIT_OK);
        end;
    end;
  end;

  SycDebug := opts.debug;
  if (paths <> '') and not SetCodePaths(paths) then
    UsageError(Format('--paths (or SYC_PATHS) takes auto, c or pascal, not "%s"', [paths]));
  if (opts.flags and SYLZ_ENTROPY <> 0) and (opts.level > SYLZ_EC_MAXLEVEL) then
    UsageError(Format('with -ec the levels are %d..%d', [SYLZ_MINLEVEL, SYLZ_EC_MAXLEVEL]));
  if (opts.cmd in ['c', 'd']) and (opts.outPath <> '') and (Length(opts.operands) > 1) then
    UsageError('-o takes one input only');
  if (opts.outPath <> '') and opts.toStdout then
    UsageError('-o and -O together');
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
