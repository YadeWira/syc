{ syc — the command line: parses it (syccli) and runs the command.

    syc c / d / t     one file or stdin as a .sylz stream (sycstream) }
program syc;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, sycblocks, syccli, sycstream;

var
  opts: TOptions;
begin
  try
    ParseCommandLine(opts);
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
