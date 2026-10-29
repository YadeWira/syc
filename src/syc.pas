{ syc — the command line: parses it (syccli) and runs the command.

    syc a / x / l / i archives (sycarc)
    syc c / d / t     one file or stdin as a .sylz stream (sycstream); t
                      checks archives too
    syc k             a new password for encrypted ones (syckey) }
program syc;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  {$ifdef windows}Windows,{$endif}
  SysUtils, sycblocks, syccli, sycstream, sycarc, syckey;

var
  opts: TOptions;
begin
{$ifdef windows}
  { strings are UTF-8, as the archive stores paths: file names, the
    command line and the console go through it instead of the ANSI code
    page, which cannot hold most names }
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteFileSystemCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);
{$endif}
  try
    ParseCommandLine(opts);
    if opts.cmd in ['a', 'x', 'l', 'i'] then
      ExitCode := RunArchiveCommand(opts)
    else if opts.cmd = 'k' then
      ExitCode := RunKeyCommand(opts)
    else
      ExitCode := RunStreamCommand(opts);
  except
    on E: ESycError do
    begin
      WriteLn(StdErr, 'syc: ', E.Message);
      ExitCode := E.code;
    end;
    on E: Exception do
    begin
      WriteLn(StdErr, 'syc: ', E.Message);
      ExitCode := EXIT_FATAL;
    end;
  end;
end.
