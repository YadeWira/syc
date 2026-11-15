{ syc — the command line: parses it (syccli) and runs the command.

    syc a / x / l / i archives (sycarc)
    syc c / d / t     one file or stdin as a .sylz stream (sycstream); t
                      checks archives too
    syc i             also a .sylz stream's header and blocks
    syc k             a new password for encrypted ones (syckey)
    syc b / s / r     benchmark, self-test, report (sycdev) }
program syc;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  {$ifdef windows}Windows,{$endif}
  SysUtils, sycblocks, sycui, syccli, sycstream, sycarc, syckey, sycdev, sycenc;

var
  opts: TOptions;
  t0: UInt64;
begin
  t0 := NowNs;
{$ifdef windows}
  { strings are UTF-8, as the archive stores paths: file names, the
    command line and the console go through it instead of the ANSI code
    page, which cannot hold most names }
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteFileSystemCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);
  { and what goes to stdout and stderr is UTF-8 too, a pipe included:
    otherwise the RTL converts it to the ANSI code page }
  SetTextCodePage(Output, CP_UTF8);
  SetTextCodePage(StdErr, CP_UTF8);
{$else}
  { "\" is part of a name on Unix: the RTL's path functions (ExtractFileDir,
    ForceDirectories) would otherwise split names at it }
  AllowDirectorySeparators := ['/'];
{$endif}
  try
    ParseCommandLine(opts);
    KdfMemMaxKiB := UInt32(opts.kdfMemMaxMiB) * 1024;
    case opts.cmd of
      'a', 'x', 'l':
        ExitCode := RunArchiveCommand(opts);
      'i':
        if IsStreamFile(opts.operands[0]) then
          ExitCode := StreamInfo(opts, opts.operands[0])
        else
          ExitCode := RunArchiveCommand(opts);
      'k': ExitCode := RunKeyCommand(opts);
      'b': ExitCode := RunBenchCommand(opts);
      's': ExitCode := RunSelfTestCommand(opts);
      'r': ExitCode := RunReportCommand(opts);
    else
      ExitCode := RunStreamCommand(opts);
    end;
  except
    on E: ESycError do
    begin
      ShowError(E, E.code);
      ExitCode := E.code;
    end;
    on E: Exception do
    begin
      ShowError(E, EXIT_FATAL);
      ExitCode := EXIT_FATAL;
    end;
  end;
  { (a usage error comes before a command ran: nothing to show for it) }
  if ExitCode <> EXIT_USAGE then
  begin
    if opts.stats then
      ShowStats(opts.threads, t0);
    ShowPhases;
  end;
  { the passwords given on the command line, cleared (best effort: the
    process's arguments still hold them) }
  if opts.passwordInline <> '' then
  begin
    UniqueString(opts.passwordInline);
    FillChar(opts.passwordInline[1], Length(opts.passwordInline), 0);
  end;
  if opts.newPasswordInline <> '' then
  begin
    UniqueString(opts.newPasswordInline);
    FillChar(opts.newPasswordInline[1], Length(opts.newPasswordInline), 0);
  end;
end.
