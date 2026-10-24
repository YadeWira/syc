{ syccdc — content-defined chunking: where the archive cuts a file into
  fragments. A gear rolling hash, FastCDC-style with normalization; the
  cut points depend only on the bytes, so an insertion moves the cuts
  near it and leaves the rest where they were. The exact rule is part of
  the archive format (wiki: syc archive format, "Fragments"): another
  implementation must cut at the same places to deduplicate against
  archives syc wrote. }
unit syccdc;

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

const
  CDC_MIN_LOG = 14;   { 16 KiB }
  CDC_AVG_LOG = 16;   { 64 KiB }
  CDC_MAX_LOG = 19;   { 512 KiB }

type
  TCdcParams = record
    minSize, avgSize, maxSize: SizeInt;
    strictShift, looseShift: Integer;   { 64 - (avgLog +- 2) }
  end;

{ the parameters from their logs (as an archive's header stores them) }
function CdcParams(minLog, avgLog, maxLog: Integer): TCdcParams;
{ The length of the fragment starting at p, with n > 0 bytes left in the
  file: 1 .. min(n, maxSize). }
function CdcCut(const prm: TCdcParams; p: PByte; n: SizeInt): SizeInt;

var
  { gear[b]: the hash's 64-bit value for byte b }
  gear: array[0..255] of UInt64;
  { the C loop (when built in); False: the Pascal one }
  CdcUseC: Boolean = {$ifdef SYLZ_PUREPASCAL}False{$else}True{$endif};

{ the Pascal loop, the reference: CdcCut is it or its C copy }
function CdcCutPas(const prm: TCdcParams; p: PByte; n: SizeInt): SizeInt;

implementation

{$ifndef SYLZ_PUREPASCAL}
uses
  sylz;   { links sylzc.o }

function sylzc_cdc_cut(p: PByte; n, minSize, avgSize, maxSize: SizeInt;
  strictShift, looseShift: LongInt; g: PUInt64): SizeInt; cdecl; external name 'sylzc_cdc_cut';
{$endif}

function CdcParams(minLog, avgLog, maxLog: Integer): TCdcParams;
begin
  Result.minSize := SizeInt(1) shl minLog;
  Result.avgSize := SizeInt(1) shl avgLog;
  Result.maxSize := SizeInt(1) shl maxLog;
  Result.strictShift := 64 - (avgLog + 2);
  Result.looseShift := 64 - (avgLog - 2);
end;

{ The spec's loop, in two parts: while the fragment would be shorter than
  avgSize a cut needs avgLog + 2 zero bits at the top of the hash, then
  avgLog - 2. }
function CdcCut(const prm: TCdcParams; p: PByte; n: SizeInt): SizeInt;
begin
{$ifndef SYLZ_PUREPASCAL}
  if CdcUseC then
    Exit(sylzc_cdc_cut(p, n, prm.minSize, prm.avgSize, prm.maxSize, prm.strictShift,
      prm.looseShift, @gear[0]));
{$endif}
  Result := CdcCutPas(prm, p, n);
end;

function CdcCutPas(const prm: TCdcParams; p: PByte; n: SizeInt): SizeInt;
var
  h: UInt64;
  i, lim, e1: SizeInt;
begin
  if n <= prm.minSize then
    Exit(n);
  lim := n;
  if lim > prm.maxSize then
    lim := prm.maxSize;
  e1 := prm.avgSize - 1;
  if e1 > lim then
    e1 := lim;
  h := 0;
  i := prm.minSize;
  while i < e1 do
  begin
    h := (h shl 1) + gear[p[i]];
    Inc(i);
    if h shr prm.strictShift = 0 then
      Exit(i);
  end;
  while i < lim do
  begin
    h := (h shl 1) + gear[p[i]];
    Inc(i);
    if h shr prm.looseShift = 0 then
      Exit(i);
  end;
  Result := lim;
end;

{ splitmix64 from "SYCACDC1" }
procedure GearInit;
var
  state, z: UInt64;
  i: Integer;
begin
  state := UInt64($5359434143444331);
  for i := 0 to 255 do
  begin
    state := state + UInt64($9E3779B97F4A7C15);
    z := state;
    z := (z xor (z shr 30)) * UInt64($BF58476D1CE4E5B9);
    z := (z xor (z shr 27)) * UInt64($94D049BB133111EB);
    gear[i] := z xor (z shr 31);
  end;
end;

initialization
  GearInit;
end.
