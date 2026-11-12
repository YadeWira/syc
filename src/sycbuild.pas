{ sycbuild — what this binary was built from, for syc -V and syc report.
  build.sh passes the commit and its date in the environment and compiles
  this unit again each time; built by hand, they read "unknown". }
unit sycbuild;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  BUILD_FPC    = {$I %FPCVERSION%};

{ linux-x86_64, win64-x86_64, darwin-aarch64, ... }
function BUILD_TARGET: string;
function BUILD_COMMIT: string;
function BUILD_DATE: string;

implementation

function OrUnknown(const s: string): string;
begin
  if s = '' then
    Result := 'unknown'
  else
    Result := s;
end;

function BUILD_TARGET: string;
begin
  Result := LowerCase({$I %FPCTARGETOS%} + '-' + {$I %FPCTARGETCPU%});
end;

function BUILD_COMMIT: string;
begin
  Result := OrUnknown({$I %SYC_COMMIT%});
end;

function BUILD_DATE: string;
begin
  Result := OrUnknown({$I %SYC_COMMIT_DATE%});
end;

end.
