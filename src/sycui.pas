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
{ the "syc: " that starts an error or a warning on stderr }
function ErrTag: string;
function WarnTag: string;

{ 1234567 -> "1.2 MB" }
function HumanSize(n: Int64): string;
{ "0.68 s", "1:05", "2:03:10" }
function HumanTime(seconds: Double): string;
{ n bytes in seconds, as "311.7 MB/s"; '' when it took no time }
function HumanSpeed(n: Int64; seconds: Double): string;
{ ", 0.68 s, 311.7 MB/s" after a summary: what n bytes took since startNs }
function TimeAndSpeed(n: Int64; startNs: UInt64): string;

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
procedure ShowStats(threads: Integer; startNs: UInt64);

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
begin
{$ifdef windows}
  Result := GetFileType(StdHandle(std)) = FILE_TYPE_CHAR;
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

function ErrTag: string;
begin
  Result := Paint(2, stErr, 'syc:') + ' ';
end;

function WarnTag: string;
begin
  Result := Paint(2, stWarn, 'syc:') + ' ';
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
  WriteLn(StdErr, ErrTag, E.Message);
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

procedure ShowStats(threads: Integer; startNs: UInt64);
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
  { the compressed side over the other, whichever way the data went }
  if (statIn > 0) and (statOut <= statIn) then
    Row('out / in', Format('%.2f%%', [statOut * 100.0 / statIn]))
  else if statOut > 0 then
    Row('in / out', Format('%.2f%%', [statIn * 100.0 / statOut]));
  Row('time', HumanTime(secs));
  if secs >= 0.001 then
    Row('speed', Format('%s in, %s out', [HumanSpeed(statIn, secs), HumanSpeed(statOut, secs)]));
  Row('threads', IntToStr(threads));
  mem := PeakMemory;
  if mem > 0 then
    Row('peak memory', Format('%.1f MiB', [mem / 1048576]));
end;

end.
