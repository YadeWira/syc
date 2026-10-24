{ syccli — syc's command line: the commands, their options, and help.

  syc CMD [options] OPERANDS. Options may come before or after the
  operands; "--" ends them. Short options are not grouped (-ec is one
  option, not -e -c); a value follows as the next argument or attached
  (-t 4, -t4, --threads 4, --threads=4). }
unit syccli;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, sylz, sycblocks;

const
  SYC_VERSION   = '0.3.1';
  STREAM_SUFFIX = '.sylz';
  DEFAULT_STREAM_BLOCK_MIB = 4;
  DEFAULT_ARCHIVE_BLOCK_MIB = 16;

type
  TVerbosity = (vQuiet, vNormal, vVerbose);

  TOptions = record
    cmd: Char;               { 'a', 'x', 'l', 'i', 'c', 'd', 't' }
    level: Integer;
    flags: Integer;          { SYLZ_ENTROPY with -ec }
    blockMiB: Integer;       { the command's default unless -b }
    threads: Integer;
    outPath: string;         { -o; '' when not given (x: the directory) }
    toStdout: Boolean;       { -O }
    force: Boolean;
    skipExisting: Boolean;   { x --skip }
    removeInput: Boolean;    { --rm }
    verbosity: TVerbosity;
    cdDir: string;           { -C }
    excludes: array of string;   { -X }
    noDedup: Boolean;
    longList: Boolean;       { l -l }
    untilSpec: string;       { -u: a version number or a date; '' latest }
    noPerms, noOwner: Boolean;
    operands: array of string;
  end;

{ Parses the command line into opts. Prints help or the version and halts
  when asked to; raises ESycError(EXIT_USAGE) on a malformed one. }
procedure ParseCommandLine(out opts: TOptions);

implementation

{$ifdef windows}
uses
  Windows;

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
  TOptId = (oLevel, oEc, oBlock, oThreads, oOut, oStdout, oForce, oRm,
    oCd, oExclude, oNoDedup, oLong, oSkip, oUntil, oNoPerms, oNoOwner,
    oQuiet, oVerbose, oHelp);

  TOptDef = record
    id: TOptId;
    short, long: string;     { without the dashes; '' when there is none }
    value: Boolean;          { takes a value }
    cmds: string;            { the commands it applies to }
  end;

const
  OPTION_DEFS: array[0..18] of TOptDef = (
    (id: oLevel;   short: '';   long: 'level';      value: True;  cmds: 'ac'),
    (id: oEc;      short: 'ec'; long: 'ec';         value: False; cmds: 'ac'),
    (id: oBlock;   short: 'b';  long: 'block-size'; value: True;  cmds: 'ac'),
    (id: oThreads; short: 't';  long: 'threads';    value: True;  cmds: 'axcdt'),
    (id: oOut;     short: 'o';  long: 'out';        value: True;  cmds: 'xcd'),
    (id: oStdout;  short: 'O';  long: 'stdout';     value: False; cmds: 'xcd'),
    (id: oForce;   short: 'f';  long: 'force';      value: False; cmds: 'xcd'),
    (id: oRm;      short: '';   long: 'rm';         value: False; cmds: 'cd'),
    (id: oCd;      short: 'C';  long: 'cd';         value: True;  cmds: 'a'),
    (id: oExclude; short: 'X';  long: 'exclude';    value: True;  cmds: 'axl'),
    (id: oNoDedup; short: '';   long: 'no-dedup';   value: False; cmds: 'a'),
    (id: oLong;    short: 'l';  long: 'long';       value: False; cmds: 'l'),
    (id: oSkip;    short: '';   long: 'skip';       value: False; cmds: 'x'),
    (id: oUntil;   short: 'u';  long: 'until';      value: True;  cmds: 'xl'),
    (id: oNoPerms; short: '';   long: 'no-perms';   value: False; cmds: 'x'),
    (id: oNoOwner; short: '';   long: 'no-owner';   value: False; cmds: 'x'),
    (id: oQuiet;   short: 'q';  long: 'quiet';      value: False; cmds: 'axlicdt'),
    (id: oVerbose; short: 'v';  long: 'verbose';    value: False; cmds: 'axlicdt'),
    (id: oHelp;    short: 'h';  long: 'help';       value: False; cmds: 'axlicdt')
  );

  COMMANDS = 'axlicdt';

procedure Usage;
begin
  WriteLn('syc ', SYC_VERSION, ' — sylz compressor. Tuned for modest hardware.');
  WriteLn;
  WriteLn('Archives (.syc: files and directories, versions, deduplicated):');
  WriteLn('  syc a [options] ARCHIVE PATH...   add PATHs: a new archive (- is stdout)');
  WriteLn('  syc x [options] ARCHIVE [FILTER...]   extract');
  WriteLn('  syc l [options] ARCHIVE [FILTER...]   list');
  WriteLn('  syc i ARCHIVE                     versions, sizes, deduplication');
  WriteLn;
  WriteLn('One file (.sylz stream):');
  WriteLn('  syc c [options] [FILE...]     compress each FILE to FILE', STREAM_SUFFIX,
    ' (none or -: stdin to stdout)');
  WriteLn('  syc d [options] [FILE...]     decompress each FILE', STREAM_SUFFIX,
    ' to FILE (none or -: stdin to stdout)');
  WriteLn;
  WriteLn('  syc t [options] [FILE...]     test archives and streams: check, write nothing');
  WriteLn('  syc h [CMD]                   help (also syc CMD -h)');
  WriteLn('  syc -V, --version');
  WriteLn;
  WriteLn('Exit status: 0 ok, 1 some inputs skipped or unreadable, 2 usage,');
  WriteLn('3 corrupt data, 4 I/O error or out of memory.');
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
    ': 0-8 parse as -', SYLZ_EC_SHIFT, '..-', SYLZ_MAXLEVEL, ' do,');
  WriteLn('              9-10 price literals by their Huffman codes');
end;

procedure CmdUsage(cmd: Char);
begin
  case cmd of
    'a':
      begin
        WriteLn('syc a [options] ARCHIVE PATH...   add files and directories (recursively)');
        WriteLn('                                  to a new ARCHIVE; - writes it to stdout');
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
        WriteLn('  -q, --quiet / -v, --verbose');
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
      end;
    'l':
      begin
        WriteLn('syc l [options] ARCHIVE [FILTER...]   list the files (a FILTER is a path,');
        WriteLn('                                      a directory with everything in it,');
        WriteLn('                                      or a pattern as in -X)');
        WriteLn;
        WriteLn('  -l, --long             permissions, size, date');
        WriteLn('  -u, --until V          as of version V (a number or a date, as in syc x)');
        WriteLn('  -X, --exclude PATTERN  leave out what matches (repeatable)');
        WriteLn('  -q, --quiet / -v, --verbose');
      end;
    'i':
      begin
        WriteLn('syc i ARCHIVE   each version: date, entries, data added, stored size,');
        WriteLn('                deduplication');
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
        WriteLn('  -q, --quiet / -v, --verbose');
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
        WriteLn('  -q, --quiet / -v, --verbose');
      end;
    't':
      begin
        WriteLn('syc t [options] [FILE...]   check archives (.syc) and streams (', STREAM_SUFFIX, '),');
        WriteLn('                            write nothing; no FILE or -: stdin');
        WriteLn('                            (every block''s CRC-32; in an archive also the');
        WriteLn('                            index and each fragment''s BLAKE2s-256)');
        WriteLn;
        WriteLn('  -t, --threads N        blocks checked N at a time, default 1');
        WriteLn('  -q, --quiet / -v, --verbose');
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

procedure ParseCommandLine(out opts: TOptions);
var
  i, j, k: Integer;
  arg, name, value, shown: string;
  hasValue, noMore: Boolean;
begin
  opts := Default(TOptions);
  opts.level := SYLZ_DEFLEVEL;
  opts.blockMiB := 0;
  opts.threads := 1;
  opts.verbosity := vNormal;

  if CmdArgCount < 1 then
  begin
    Usage;
    Halt(EXIT_USAGE);
  end;
  arg := CmdArg(1);
  if (arg = '-h') or (arg = '--help') or (arg = 'h') then
  begin
    if (CmdArgCount >= 2) and (Length(CmdArg(2)) = 1) and (Pos(CmdArg(2)[1], COMMANDS) > 0) then
      CmdUsage(CmdArg(2)[1])
    else
      Usage;
    Halt(EXIT_OK);
  end;
  if (arg = '-V') or (arg = '--version') then
  begin
    WriteLn('syc ', SYC_VERSION);
    Halt(EXIT_OK);
  end;
  if (Length(arg) <> 1) or (Pos(arg[1], COMMANDS) = 0) then
    UsageError('unknown command "' + arg + '"');
  opts.cmd := arg[1];

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
      if Pos(opts.cmd, OPTION_DEFS[Ord(oLevel)].cmds) = 0 then
        UsageError(Format('syc %s takes no level', [opts.cmd]));
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
        opts.level := IntArg(shown, value, SYLZ_MINLEVEL, SYLZ_MAXLEVEL);
      oEc: opts.flags := opts.flags or SYLZ_ENTROPY;
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
      oQuiet: opts.verbosity := vQuiet;
      oVerbose: opts.verbosity := vVerbose;
      oHelp:
        begin
          CmdUsage(opts.cmd);
          Halt(EXIT_OK);
        end;
    end;
  end;

  if (opts.flags and SYLZ_ENTROPY <> 0) and (opts.level > SYLZ_EC_MAXLEVEL) then
    UsageError(Format('with -ec the levels are %d..%d', [SYLZ_MINLEVEL, SYLZ_EC_MAXLEVEL]));
  if (opts.cmd in ['c', 'd']) and (opts.outPath <> '') and (Length(opts.operands) > 1) then
    UsageError('-o takes one input only');
  if (opts.outPath <> '') and opts.toStdout then
    UsageError('-o and -O together');
  if opts.force and opts.skipExisting then
    UsageError('-f and --skip together');
  if (opts.cmd in ['c', 'd']) and (opts.outPath = '-') then
  begin
    opts.outPath := '';
    opts.toStdout := True;
  end;
  if opts.blockMiB = 0 then
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
           UsageError('syc i takes one ARCHIVE');
  end;
end;

end.
