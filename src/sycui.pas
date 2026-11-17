{ sycui — what syc shows and how: terminals and their width, colours,
  sizes and times for people, a clock, the process's peak memory, and
  what --debug and --stats collect while a command runs. }
unit sycui;

{$mode objfpc}{$H+}

interface

uses
  {$ifdef windows}Windows,{$endif}
  {$ifdef unix}BaseUnix, UnixType, termio,{$endif}
  {$ifdef linux}Linux,{$endif}
  SysUtils;

type
  TColorMode = (cmAuto, cmAlways, cmNever);
  TStyle = (stErr, stWarn, stOk, stHead, stDim, stDir, stLink, stBar);

{ handle 0, 1 or 2 is a terminal }
function IsTerminal(std: Integer): Boolean;
function StdHandle(std: Integer): THandle;
{ the terminal's width in columns; 80 when it cannot be told }
function TermWidth(std: Integer): Integer;

{ --color: auto (the default) colours what goes to a terminal, unless
  NO_COLOR is set or TERM is dumb }
procedure SetColorMode(mode: TColorMode);
function UseColor(std: Integer): Boolean;
{ s in a style, for stdout (1) or stderr (2); s itself without colours }
function Paint(std: Integer; st: TStyle; const s: string): string;
var
  { called before an error or a warning is written: a progress line
    clears itself, so the message starts on a clean line }
  BeforeMessage: procedure = nil;

{ the start of an error or a warning on stderr: "✗ " / "⚠ " on a
  terminal that shows Unicode, else "syc: " }
function ErrTag: string;
function WarnTag: string;

{ Symbols and separators. "Fancy" output (✓, →, ·) goes to a terminal
  that shows Unicode: on Unix a UTF-8 locale and a TERM other than linux
  or dumb, on Windows a console that takes escape sequences (Windows 10
  and later). Elsewhere, and into pipes and files, plain ASCII. }
function Fancy(std: Integer): Boolean;
{ "→" or "->" }
function Arrow(std: Integer): string;

type
  TMark = (mkOk, mkWarn, mkErr, mkNone);

{ A command's result line: fancy "✓ name  a · b · c", plain "name: a, b, c". }
function Summary(std: Integer; mark: TMark; const name: string;
  const parts: array of string): string;
{ the parts with " · " (fancy) or ", " between them; '' parts left out }
function Joined(std: Integer; const parts: array of string): string;
{ a line under it: "  a · b" / "  a, b" }
function Detail(std: Integer; const parts: array of string): string;
{ s when c, else '' (a part a summary leaves out) }
function When(c: Boolean; const s: string): string;
{ "1 file", "2 files"; plural '' adds an s }
function Count(n: Int64; const singular: string; const plural: string = ''): string;
{ the columns s takes on a terminal: escape sequences take none, a UTF-8
  character one }
function DisplayWidth(const s: string): Integer;
{ s as it may go to a terminal: control characters (escape sequences
  could set the title, the clipboard, hide lines) and bytes that are not
  UTF-8 as \xNN }
function Printable(const s: string): string;
{ Printable(s) when std is a terminal, else s as it is (pipes and files
  get the bytes the archive holds) }
function Shown(std: Integer; const s: string): string;
{ s n times (a multi-byte character too) }
function Repeated(const s: string; n: Integer): string;
{ s cut to at most width columns, with "…" (or "...") where it was cut }
function Ellipsize(std: Integer; const s: string; width: Integer): string;

{ 1234567 -> "1.2 MB" }
function HumanSize(n: Int64): string;
{ "0.68 s", "1:05", "2:03:10" }
function HumanTime(seconds: Double): string;
{ n bytes in seconds, as "311.7 MB/s"; '' when it took no time }
function HumanSpeed(n: Int64; seconds: Double): string;
{ ", 0.68 s, 311.7 MB/s" after a summary: what n bytes took since startNs }
function TimeAndSpeed(n: Int64; startNs: UInt64): string;

{ the time since startNs, "0.68 s"; and the speed of n bytes in it,
  "311.7 MB/s" ('' when n is 0 or it took no time) }
function Elapsed(startNs: UInt64): string;
function SpeedSince(n: Int64; startNs: UInt64): string;
{ "747.4 kB → 287.2 kB (38.43%)": a size before and after }
function SizeChange(std: Integer; before, after: Int64): string;

{ a clock that only goes forward, in nanoseconds }
function NowNs: UInt64;
{ the most memory the process has held, in bytes; 0 when unknown }
function PeakMemory: Int64;
{ the processors the system has online }
function CpuCount: Integer;

var
  { --debug: errors say where they come from, and the phases' times are
    shown at the end }
  SycDebug: Boolean = False;

  { False: ShowError shows nothing (the self-test runs commands that
    must fail) }
  ErrorsShown: Boolean = True;

{ Flushes stdout; raises EInOutError when a write to it failed (Text
  writes do not raise: a full disk would go unsaid) }
procedure CheckOutput;

{ --debug's context, kept by the main thread: the file being worked on,
  and the block and offset when there are any (-1: none) }
procedure SetWhere(const name: string; block, offset: Int64);
procedure ClearWhere;
{ An error's line on stderr; with --debug also its class, the exit code,
  where it happened, and how to report it. }
procedure ShowError(E: Exception; code: Integer);

{ --debug: a new phase starts (ending the one before); '' ends the last }
procedure Phase(const name: string);
procedure ShowPhases;

{ --stats: what a command read and wrote }
procedure StatAdd(bytesIn, bytesOut: Int64);
procedure ShowStats(threads: Integer; startNs: UInt64; compressing: Boolean);

implementation

{$ifdef darwin}
const
  CLOCK_MONOTONIC = 6;   { macOS 10.12 and later }

function clock_gettime(clk: LongInt; tp: PTimeSpec): LongInt;
  cdecl; external 'c' name 'clock_gettime';
{$endif}

{$ifdef unix}
function getrusage(who: LongInt; usage: Pointer): LongInt; cdecl; external 'c' name 'getrusage';
function sysconf(name: LongInt): PtrInt; cdecl; external 'c' name 'sysconf';

const
  SC_NPROCESSORS_ONLN = {$ifdef darwin}58{$else}84{$endif};
{$endif}

{$ifdef windows}
const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = 4;

type
  TProcessMemoryCounters = record
    cb: DWORD;
    PageFaultCount: DWORD;
    PeakWorkingSetSize, WorkingSetSize: PtrUInt;
    QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage: PtrUInt;
    QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage: PtrUInt;
    PagefileUsage, PeakPagefileUsage: PtrUInt;
  end;

function GetProcessMemoryInfo(process: THandle; out counters: TProcessMemoryCounters;
  cb: DWORD): BOOL; stdcall; external 'psapi.dll' name 'GetProcessMemoryInfo';
{$endif}

function StdHandle(std: Integer): THandle;
begin
  case std of
    0: Result := StdInputHandle;
    1: Result := StdOutputHandle;
  else
    Result := StdErrorHandle;
  end;
end;

function IsTerminal(std: Integer): Boolean;
{$ifdef windows}
var
  mode: DWORD;
{$endif}
begin
{$ifdef windows}
  { a console: a character device that has a console mode (NUL is a
    character device too, but not a console) }
  Result := (GetFileType(StdHandle(std)) = FILE_TYPE_CHAR)
    and GetConsoleMode(StdHandle(std), mode);
{$else}
  Result := IsATTY(StdHandle(std)) = 1;
{$endif}
end;

function TermWidth(std: Integer): Integer;
{$ifdef windows}
var
  info: TConsoleScreenBufferInfo;
begin
  Result := 80;
  if GetConsoleScreenBufferInfo(StdHandle(std), info) then
    Result := info.srWindow.Right - info.srWindow.Left + 1;
  if Result < 20 then
    Result := 80;
end;
{$else}
var
  ws: TWinSize;
begin
  Result := 80;
  FillChar(ws, SizeOf(ws), 0);
  if (fpIOCtl(StdHandle(std), TIOCGWINSZ, @ws) = 0) and (ws.ws_col >= 20) then
    Result := ws.ws_col;
end;
{$endif}

{ ── colours ────────────────────────────────────────────────────────────── }

var
  colorMode: TColorMode = cmAuto;
  colorKnown: array[1..2] of Boolean;
  colorOn: array[1..2] of Boolean;

procedure SetColorMode(mode: TColorMode);
begin
  colorMode := mode;
  colorKnown[1] := False;
  colorKnown[2] := False;
end;

{ Windows 10 and later take the escape sequences once the console is told
  to; earlier ones (and a failed call) get no colours }
function TerminalTakesColors(std: Integer): Boolean;
{$ifdef windows}
var
  mode: DWORD;
begin
  Result := GetConsoleMode(StdHandle(std), mode)
    and ((mode and ENABLE_VIRTUAL_TERMINAL_PROCESSING <> 0)
      or SetConsoleMode(StdHandle(std), mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING));
end;
{$else}
begin
  Result := GetEnvironmentVariable('TERM') <> 'dumb';
end;
{$endif}

function UseColor(std: Integer): Boolean;
begin
  if (std < 1) or (std > 2) then
    Exit(False);
  if not colorKnown[std] then
  begin
    case colorMode of
      cmAlways: colorOn[std] := True;
      cmNever: colorOn[std] := False;
    else
      colorOn[std] := IsTerminal(std) and (GetEnvironmentVariable('NO_COLOR') = '')
        and TerminalTakesColors(std);
    end;
{$ifdef windows}
    { --color always into a console still needs the console told }
    if colorOn[std] and IsTerminal(std) then
      TerminalTakesColors(std);
{$endif}
    colorKnown[std] := True;
  end;
  Result := colorOn[std];
end;

function Paint(std: Integer; st: TStyle; const s: string): string;
const
  CODES: array[TStyle] of string = ('1;31', '33', '32', '1', '2', '1;34', '36', '32');
begin
  if (s = '') or not UseColor(std) then
    Result := s
  else
    Result := #27'[' + CODES[st] + 'm' + s + #27'[0m';
end;

{ ── symbols ────────────────────────────────────────────────────────────── }

var
  fancyKnown: array[1..2] of Boolean;
  fancyOn: array[1..2] of Boolean;

function LocaleIsUtf8: Boolean;
{$ifdef unix}
var
  v: string;
begin
  { the first of these that is set decides, as setlocale() does }
  v := GetEnvironmentVariable('LC_ALL');
  if v = '' then
    v := GetEnvironmentVariable('LC_CTYPE');
  if v = '' then
    v := GetEnvironmentVariable('LANG');
  v := UpperCase(v);
  Result := (Pos('UTF-8', v) > 0) or (Pos('UTF8', v) > 0);
end;
{$else}
begin
  Result := True;   { syc sets the console's output code page to UTF-8 }
end;
{$endif}

function Fancy(std: Integer): Boolean;
var
  term: string;
begin
  if (std < 1) or (std > 2) then
    Exit(False);
  if not fancyKnown[std] then
  begin
    term := GetEnvironmentVariable('TERM');
    fancyOn[std] := IsTerminal(std) and LocaleIsUtf8
      {$ifdef unix}and (term <> 'dumb') and (term <> 'linux'){$endif}
      {$ifdef windows}and TerminalTakesColors(std){$endif};
    fancyKnown[std] := True;
  end;
  Result := fancyOn[std];
end;

function Arrow(std: Integer): string;
begin
  if Fancy(std) then
    Result := '→'
  else
    Result := '->';
end;

function MarkOf(std: Integer; mark: TMark): string;
begin
  case mark of
    mkOk: Result := Paint(std, stOk, '✓');
    mkWarn: Result := Paint(std, stWarn, '⚠');
    mkErr: Result := Paint(std, stErr, '✗');
  else
    Result := ' ';
  end;
end;

function ErrTag: string;
begin
  if Assigned(BeforeMessage) then
    BeforeMessage;
  if Fancy(2) then
    Result := MarkOf(2, mkErr) + ' '
  else
    Result := Paint(2, stErr, 'syc:') + ' ';
end;

function WarnTag: string;
begin
  if Assigned(BeforeMessage) then
    BeforeMessage;
  if Fancy(2) then
    Result := MarkOf(2, mkWarn) + ' '
  else
    Result := Paint(2, stWarn, 'syc:') + ' ';
end;

function Joined(std: Integer; const parts: array of string): string;
var
  i: Integer;
  sep: string;
begin
  if Fancy(std) then
    sep := Paint(std, stDim, ' · ')
  else
    sep := ', ';
  Result := '';
  for i := 0 to High(parts) do
    if parts[i] <> '' then
    begin
      if Result <> '' then
        Result := Result + sep;
      Result := Result + parts[i];
    end;
end;

function Summary(std: Integer; mark: TMark; const name: string;
  const parts: array of string): string;
begin
  if Fancy(std) then
  begin
    Result := MarkOf(std, mark) + ' ' + Paint(std, stHead, name);
    if Length(parts) > 0 then
      Result := Result + '  ' + Joined(std, parts);
  end
  else
  begin
    Result := name;
    if Length(parts) > 0 then
      Result := Result + ': ' + Joined(std, parts);
  end;
end;

function Detail(std: Integer; const parts: array of string): string;
begin
  Result := '  ' + Joined(std, parts);
end;

function When(c: Boolean; const s: string): string;
begin
  if c then
    Result := s
  else
    Result := '';
end;

function Count(n: Int64; const singular: string; const plural: string): string;
begin
  if n = 1 then
    Result := '1 ' + singular
  else if plural <> '' then
    Result := IntToStr(n) + ' ' + plural
  else
    Result := IntToStr(n) + ' ' + singular + 's';
end;

function DisplayWidth(const s: string): Integer;
var
  i: Integer;
begin
  Result := 0;
  i := 1;
  while i <= Length(s) do
  begin
    if s[i] = #27 then
    begin
      { ESC [ ... a letter }
      Inc(i);
      while (i <= Length(s)) and not (s[i] in ['A'..'Z', 'a'..'z']) do
        Inc(i);
    end
    else if Byte(s[i]) and $C0 <> $80 then   { not a UTF-8 continuation byte }
      Inc(Result);
    Inc(i);
  end;
end;

function Printable(const s: string): string;
var
  i, n, k: Integer;
  c: Byte;
  cp: UInt32;
  ok: Boolean;

  procedure Hex(b: Byte);
  begin
    Result := Result + '\x' + IntToHex(b, 2);
  end;

begin
  Result := '';
  i := 1;
  while i <= Length(s) do
  begin
    c := Byte(s[i]);
    if c < $80 then
    begin
      if (c < $20) or (c = $7F) then
        Hex(c)
      else
        Result := Result + s[i];
      Inc(i);
      Continue;
    end;
    { a UTF-8 sequence: its length from the lead byte, then checked }
    if c and $E0 = $C0 then
      n := 2
    else if c and $F0 = $E0 then
      n := 3
    else if c and $F8 = $F0 then
      n := 4
    else
      n := 0;
    ok := (n > 0) and (i + n - 1 <= Length(s));
    cp := 0;
    if ok then
    begin
      cp := c and ($7F shr n);
      for k := 1 to n - 1 do
        if Byte(s[i + k]) and $C0 <> $80 then
          ok := False
        else
          cp := cp shl 6 or (Byte(s[i + k]) and $3F);
    end;
    { overlong forms, surrogates, past U+10FFFF, and the C1 controls }
    ok := ok and not ((n = 2) and (cp < $80)) and not ((n = 3) and (cp < $800))
      and not ((n = 4) and (cp < $10000)) and not ((cp >= $D800) and (cp <= $DFFF))
      and (cp <= $10FFFF) and not ((cp >= $80) and (cp <= $9F));
    if ok then
    begin
      Result := Result + Copy(s, i, n);
      Inc(i, n);
    end
    else
    begin
      Hex(c);
      Inc(i);
    end;
  end;
end;

function Shown(std: Integer; const s: string): string;
begin
  if IsTerminal(std) then
    Result := Printable(s)
  else
    Result := s;
end;

function Repeated(const s: string; n: Integer): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to n do
    Result := Result + s;
end;

function Ellipsize(std: Integer; const s: string; width: Integer): string;
var
  dots: string;
  keep, i, w: Integer;
begin
  if DisplayWidth(s) <= width then
    Exit(s);
  if Fancy(std) then
    dots := '…'
  else
    dots := '...';
  keep := width - DisplayWidth(dots);
  if keep < 1 then
    Exit(Copy(dots, 1, Length(dots)));
  { keep the end, the part of a path that tells most: "…/dir/name" }
  i := Length(s) + 1;
  w := 0;
  while (i > 1) and (w < keep) do
  begin
    Dec(i);
    if Byte(s[i]) and $C0 <> $80 then
      Inc(w);
  end;
  Result := dots + Copy(s, i, MaxInt);
end;

{ ── sizes and times ────────────────────────────────────────────────────── }

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

function HumanTime(seconds: Double): string;
var
  s: Int64;
begin
  if seconds < 60 then
    Exit(Format('%.2f s', [seconds]));
  s := Round(seconds);
  if s < 3600 then
    Result := Format('%d:%.2d', [s div 60, s mod 60])
  else
    Result := Format('%d:%.2d:%.2d', [s div 3600, s div 60 mod 60, s mod 60]);
end;

function HumanSpeed(n: Int64; seconds: Double): string;
begin
  if seconds <= 0 then
    Exit('');
  Result := Format('%.1f MB/s', [n / 1e6 / seconds]);
end;

function TimeAndSpeed(n: Int64; startNs: UInt64): string;
var
  secs: Double;
begin
  secs := (NowNs - startNs) / 1e9;
  Result := ', ' + HumanTime(secs);
  if (n > 0) and (secs >= 0.001) then
    Result := Result + ', ' + HumanSpeed(n, secs);
end;

function Elapsed(startNs: UInt64): string;
begin
  Result := HumanTime((NowNs - startNs) / 1e9);
end;

function SpeedSince(n: Int64; startNs: UInt64): string;
var
  secs: Double;
begin
  secs := (NowNs - startNs) / 1e9;
  { under a megabyte or a twentieth of a second, a speed says nothing }
  if (n >= 1000000) and (secs >= 0.05) then
    Result := HumanSpeed(n, secs)
  else
    Result := '';
end;

function SizeChange(std: Integer; before, after: Int64): string;
var
  pct: Double;
begin
  if before > 0 then
    pct := after * 100.0 / before
  else
    pct := 0;
  Result := Format('%s %s %s (%.2f%%)', [HumanSize(before), Arrow(std), HumanSize(after), pct]);
end;

function NowNs: UInt64;
{$ifdef unix}
var
  ts: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @ts);
  Result := UInt64(ts.tv_sec) * 1000000000 + UInt64(ts.tv_nsec);
end;
{$endif}
{$ifdef windows}
var
  c, f: Int64;
begin
  QueryPerformanceCounter(c);
  QueryPerformanceFrequency(f);
  Result := UInt64(Round(c / f * 1e9));
end;
{$endif}

function PeakMemory: Int64;
{$ifdef windows}
var
  pmc: TProcessMemoryCounters;
begin
  Result := 0;
  FillChar(pmc, SizeOf(pmc), 0);
  pmc.cb := SizeOf(pmc);
  if GetProcessMemoryInfo(GetCurrentProcess, pmc, SizeOf(pmc)) then
    Result := pmc.PeakWorkingSetSize;
end;
{$else}
var
  { struct rusage: two timevals (two longs each), then ru_maxrss, a long:
    kilobytes on Linux, bytes on macOS }
  ru: array[0..31] of PtrInt;
begin
  Result := 0;
  FillChar(ru, SizeOf(ru), 0);
  if getrusage(0, @ru[0]) = 0 then
    Result := Int64(ru[4]){$ifndef darwin} * 1024{$endif};
end;
{$endif}

function CpuCount: Integer;
{$ifdef windows}
var
  info: TSystemInfo;
begin
  GetSystemInfo(info);
  Result := info.dwNumberOfProcessors;
end;
{$else}
begin
  Result := sysconf(SC_NPROCESSORS_ONLN);
  if Result < 1 then
    Result := 1;
end;
{$endif}

{ ── stdout ─────────────────────────────────────────────────────────────── }

procedure CheckOutput;
var
  r: Integer;
begin
  r := IOResult;   { a write that failed (and cleared, so stderr works) }
  try
    Flush(Output);
  except
    on E: EInOutError do
      raise EInOutError.Create('cannot write to stdout: ' + E.Message);
  end;
  if r = 0 then
    r := IOResult;
  if r <> 0 then
    raise EInOutError.CreateFmt('cannot write to stdout (I/O error %d)', [r]);
end;

{ ── --debug ────────────────────────────────────────────────────────────── }

var
  whereName: string;
  whereBlock: Int64 = -1;
  whereOffset: Int64 = -1;
  phaseNames: array of string;
  phaseNs: array of UInt64;
  phaseStart: UInt64;
  phaseOpen: Boolean;

procedure SetWhere(const name: string; block, offset: Int64);
begin
  whereName := name;
  whereBlock := block;
  whereOffset := offset;
end;

procedure ClearWhere;
begin
  SetWhere('', -1, -1);
end;

procedure ShowError(E: Exception; code: Integer);
var
  where: string;
begin
  if not ErrorsShown then
    Exit;
  InOutRes := 0;   { a failed write to stdout would skip this one too }
  WriteLn(StdErr, ErrTag, E.Message);
  Flush(StdErr);   { now: at exit stdout is closed first, and its failure would skip it }
  if not SycDebug then
    Exit;
  where := '';
  if whereName <> '' then
  begin
    where := whereName;
    if whereBlock >= 0 then
      where := where + Format(', block %d', [whereBlock]);
    if whereOffset >= 0 then
      where := where + Format(', offset %d', [whereOffset]);
  end;
  WriteLn(StdErr, Paint(2, stDim, Format('  debug: %s, exit code %d, raised at $%s',
    [E.ClassName, code, HexStr(ExceptAddr)])));
  if where <> '' then
    WriteLn(StdErr, Paint(2, stDim, '  debug: while working on ' + where));
  WriteLn(StdErr, Paint(2, stDim, '  debug: to report it, attach the output of "syc report" '
    + 'and this command line'));
end;

procedure Phase(const name: string);
var
  now: UInt64;
begin
  if not SycDebug then
    Exit;
  now := NowNs;
  if phaseOpen then
    phaseNs[High(phaseNs)] := now - phaseStart;
  phaseOpen := name <> '';
  if phaseOpen then
  begin
    SetLength(phaseNames, Length(phaseNames) + 1);
    SetLength(phaseNs, Length(phaseNames));
    phaseNames[High(phaseNames)] := name;
    phaseStart := now;
  end;
end;

procedure ShowPhases;
var
  i: Integer;
begin
  if not SycDebug then
    Exit;
  Phase('');
  for i := 0 to High(phaseNames) do
    WriteLn(StdErr, Paint(2, stDim, Format('  debug: %9.3f s  %s', [phaseNs[i] / 1e9, phaseNames[i]])));
end;

{ ── --stats ────────────────────────────────────────────────────────────── }

var
  statIn, statOut: Int64;

procedure StatAdd(bytesIn, bytesOut: Int64);
begin
  Inc(statIn, bytesIn);
  Inc(statOut, bytesOut);
end;

procedure ShowStats(threads: Integer; startNs: UInt64; compressing: Boolean);
var
  secs: Double;
  mem: Int64;

  procedure Row(const what, value: string);
  begin
    WriteLn(StdErr, Paint(2, stHead, Format('  %-12s', [what])), value);
  end;

begin
  secs := (NowNs - startNs) / 1e9;
  WriteLn(StdErr, Paint(2, stHead, 'stats'));
  Row('in', Format('%d bytes (%s)', [statIn, HumanSize(statIn)]));
  Row('out', Format('%d bytes (%s)', [statOut, HumanSize(statOut)]));
  { the compressed size over the raw one: out over in when compressing,
    in over out when decompressing (also when one grew) }
  if compressing and (statIn > 0) then
    Row('ratio', Format('%.2f%% (out / in)', [statOut * 100.0 / statIn]))
  else if not compressing and (statOut > 0) then
    Row('ratio', Format('%.2f%% (in / out)', [statIn * 100.0 / statOut]));
  Row('time', HumanTime(secs));
  if secs >= 0.001 then
    Row('speed', Format('%s in, %s out', [HumanSpeed(statIn, secs), HumanSpeed(statOut, secs)]));
  Row('threads', IntToStr(threads));
  mem := PeakMemory;
  if mem > 0 then
    Row('peak memory', Format('%.1f MiB', [mem / 1048576]));
end;

end.
