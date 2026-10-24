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
  SYC_VERSION   = '0.2.14';
  STREAM_SUFFIX = '.sylz';
  DEFAULT_STREAM_BLOCK_MIB = 4;

type
  TVerbosity = (vQuiet, vNormal, vVerbose);

  TOptions = record
    cmd: Char;               { 'c', 'd', 't' }
    level: Integer;
    flags: Integer;          { SYLZ_ENTROPY with -ec }
    blockMiB: Integer;
    threads: Integer;
    outPath: string;         { -o; '' when not given }
    toStdout: Boolean;       { -O }
    force: Boolean;
    removeInput: Boolean;    { --rm }
    verbosity: TVerbosity;
    operands: array of string;
  end;

{ Parses the command line into opts. Prints help or the version and halts
  when asked to; raises ESycError(EXIT_USAGE) on a malformed one. }
procedure ParseCommandLine(out opts: TOptions);

implementation

type
  TOptId = (oLevel, oEc, oBlock, oThreads, oOut, oStdout, oForce, oRm,
    oQuiet, oVerbose, oHelp);

  TOptDef = record
    id: TOptId;
    short, long: string;     { without the dashes; '' when there is none }
    value: Boolean;          { takes a value }
    cmds: string;            { the commands it applies to }
  end;

const
  OPTION_DEFS: array[0..10] of TOptDef = (
    (id: oLevel;   short: '';   long: 'level';      value: True;  cmds: 'c'),
    (id: oEc;      short: 'ec'; long: 'ec';         value: False; cmds: 'c'),
    (id: oBlock;   short: 'b';  long: 'block-size'; value: True;  cmds: 'c'),
    (id: oThreads; short: 't';  long: 'threads';    value: True;  cmds: 'cdt'),
    (id: oOut;     short: 'o';  long: 'out';        value: True;  cmds: 'cd'),
    (id: oStdout;  short: 'O';  long: 'stdout';     value: False; cmds: 'cd'),
    (id: oForce;   short: 'f';  long: 'force';      value: False; cmds: 'cd'),
    (id: oRm;      short: '';   long: 'rm';         value: False; cmds: 'cd'),
    (id: oQuiet;   short: 'q';  long: 'quiet';      value: False; cmds: 'cdt'),
    (id: oVerbose; short: 'v';  long: 'verbose';    value: False; cmds: 'cdt'),
    (id: oHelp;    short: 'h';  long: 'help';       value: False; cmds: 'cdt')
  );

  COMMANDS = 'cdt';

procedure Usage;
begin
  WriteLn('syc ', SYC_VERSION, ' — sylz compressor. Tuned for modest hardware.');
  WriteLn;
  WriteLn('  syc c [options] [FILE...]     compress each FILE to FILE', STREAM_SUFFIX,
    ' (none or -: stdin to stdout)');
  WriteLn('  syc d [options] [FILE...]     decompress each FILE', STREAM_SUFFIX,
    ' to FILE (none or -: stdin to stdout)');
  WriteLn('  syc t [options] [FILE...]     test: decompress and check, write nothing');
  WriteLn('  syc h [CMD]                   help (also syc CMD -h)');
  WriteLn('  syc -V, --version');
  WriteLn;
  WriteLn('Exit status: 0 ok, 1 some inputs skipped or unreadable, 2 usage,');
  WriteLn('3 corrupt data, 4 I/O error or out of memory.');
end;

procedure CmdUsage(cmd: Char);
begin
  case cmd of
    'c':
      begin
        WriteLn('syc c [options] [FILE...]   compress: FILE -> FILE', STREAM_SUFFIX,
          '; no FILE or -: stdin -> stdout');
        WriteLn;
        WriteLn('  -0 .. -', SYLZ_MAXLEVEL, ', --level N');
        WriteLn('              level: 0 fastest .. ', SYLZ_MAXLEVEL, ' best ratio, default ',
          SYLZ_DEFLEVEL);
        WriteLn('              (0-1 single hash, 2-3 two hashes, 4-8 hash chains,');
        WriteLn('              9-10 optimal parsing)');
        WriteLn('  -ec, --ec   extra compression: entropy-coded literals (sylz format v3),');
        WriteLn('              smaller, slower to decode; levels 0..', SYLZ_EC_MAXLEVEL,
          ': 0-8 parse as -', SYLZ_EC_SHIFT, '..-', SYLZ_MAXLEVEL, ' do,');
        WriteLn('              9-10 price literals by their Huffman codes');
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
        WriteLn('syc t [options] [FILE...]   decompress and check every block, write');
        WriteLn('                            nothing; no FILE or -: stdin');
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
  opts.blockMiB := DEFAULT_STREAM_BLOCK_MIB;
  opts.threads := 1;
  opts.verbosity := vNormal;

  if ParamCount < 1 then
  begin
    Usage;
    Halt(EXIT_USAGE);
  end;
  arg := ParamStr(1);
  if (arg = '-h') or (arg = '--help') or (arg = 'h') then
  begin
    if (ParamCount >= 2) and (Length(ParamStr(2)) = 1) and (Pos(ParamStr(2)[1], COMMANDS) > 0) then
      CmdUsage(ParamStr(2)[1])
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
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
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
      if i > ParamCount then
        UsageError(shown + ' needs a value');
      value := ParamStr(i);
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
  if (opts.outPath <> '') and (Length(opts.operands) > 1) then
    UsageError('-o takes one input only');
  if (opts.outPath <> '') and opts.toStdout then
    UsageError('-o and -O together');
  if opts.outPath = '-' then
  begin
    opts.outPath := '';
    opts.toStdout := True;
  end;
end;

end.
