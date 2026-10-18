{ sylztable — derives sylz's token table from sample parses.

  Usage: sylztable BLOCK...   (sylz blocks, e.g. from SYLZ_DUMP)

  Reads the (literal length, match length) of every sequence, gives each
  input the same total weight, and picks the EXACT_CODES most frequent
  pairs inside the fixed-copy region (literals <= 15, match <= 32) as the
  table's exact codes. Prints the table as Pascal source for sylz.pas, and
  for each input the share of sequences that need no extension with the
  v1 3/5 bit split and with the new table. }
program sylztable;

{$mode objfpc}{$H+}
{$modeswitch nestedprocvars}
{$R-}{$Q-}

uses
  SysUtils, Classes, Math, sylz;

const
  MINMATCH    = 4;
  MAX_LL      = 15;                  { exact codes: literals 0..15 }
  MAX_M       = 28;                  { exact codes: match - 4 in 0..28 (match <= 32) }
  EXACT_CODES = 256 - (MAX_LL + 1) - (MAX_M + 1) - 1;   { 210 }

type
  TJoint = array[0..MAX_LL, 0..MAX_M] of Double;

var
  score: TJoint;
  chosen: array[0..MAX_LL, 0..MAX_M] of Boolean;
  files: array of string;

{ Calls back with (literals, match) for every sequence of a block. The
  parse doesn't depend on the token table, so a block written with the
  current table is as good an input as any. }
type
  TSeqProc = procedure(ll, ml: SizeInt) is nested;

procedure ForEachSequence(const path: string; f: TSeqProc);
var
  buf: TBytes;
  n, ip, cend, ll, ml: SizeInt;
  b: Byte;
  e: UInt32;
begin
  with TFileStream.Create(path, fmOpenRead) do
  try
    n := Size;
    SetLength(buf, n);
    ReadBuffer(buf[0], n);
  finally
    Free;
  end;
  cend := 4 + (buf[0] or (SizeInt(buf[1]) shl 8) or (SizeInt(buf[2]) shl 16) or (SizeInt(buf[3]) shl 24));
  ip := 4;
  while ip < cend do
  begin
    e := SYLZ_TOKENS[buf[ip]];
    Inc(ip, 3);
    ll := e and $FF;
    if e and SYLZ_TOK_LLEXT <> 0 then
      repeat
        b := buf[ip];
        Inc(ip);
        Inc(ll, b);
      until b <> 255;
    ml := (e shr 8) and $FF;
    if e and SYLZ_TOK_MLEXT <> 0 then
      repeat
        b := buf[ip];
        Inc(ip);
        Inc(ml, b);
      until b <> 255;
    f(ll, ml);
  end;
end;

procedure Accumulate(const path: string);
var
  counts: TJoint;
  total: Int64;
  i, k: Integer;

  procedure Count(ll, ml: SizeInt);
  begin
    Inc(total);
    if (ll <= MAX_LL) and (ml - MINMATCH <= MAX_M) then
      counts[ll, ml - MINMATCH] := counts[ll, ml - MINMATCH] + 1;
  end;

begin
  FillChar(counts, SizeOf(counts), 0);
  total := 0;
  ForEachSequence(path, @Count);
  for i := 0 to MAX_LL do
    for k := 0 to MAX_M do
      score[i, k] := score[i, k] + counts[i, k] / Max(total, 1);
end;

procedure Choose;
var
  n, i, k, bi, bk: Integer;
  best: Double;
begin
  FillChar(chosen, SizeOf(chosen), 0);
  for n := 1 to EXACT_CODES do
  begin
    best := -1;
    bi := 0;
    bk := 0;
    for i := 0 to MAX_LL do
      for k := 0 to MAX_M do
        if not chosen[i, k] and (score[i, k] > best) then
        begin
          best := score[i, k];
          bi := i;
          bk := k;
        end;
    chosen[bi, bk] := True;
  end;
end;

procedure Report(const path: string);
var
  total, v1, v2: Int64;

  procedure Count(ll, ml: SizeInt);
  begin
    Inc(total);
    if (ll < 7) and (ml - MINMATCH < 31) then
      Inc(v1);   { the v1 3/5 bit split, for comparison }
    if (ll <= MAX_LL) and (ml - MINMATCH <= MAX_M) and chosen[ll, ml - MINMATCH] then
      Inc(v2);
  end;

begin
  total := 0;
  v1 := 0;
  v2 := 0;
  ForEachSequence(path, @Count);
  WriteLn(StdErr, Format('%-40s no extension: v1 %6.2f%%  v2 %6.2f%%',
    [ExtractFileName(path), v1 * 100.0 / Max(total, 1), v2 * 100.0 / Max(total, 1)]));
end;

procedure PrintTable;
var
  i, k, code, col: Integer;
  entries: array[0..255] of UInt32;
begin
  { exact pairs in (literals, match) order, then the escapes }
  code := 0;
  for i := 0 to MAX_LL do
    for k := 0 to MAX_M do
      if chosen[i, k] then
      begin
        entries[code] := UInt32(i) or (UInt32(k + MINMATCH) shl 8);
        Inc(code);
      end;
  for i := 0 to MAX_LL do
  begin
    entries[code] := UInt32(i) or (UInt32(MINMATCH) shl 8) or (2 shl 16);   { match extended }
    Inc(code);
  end;
  for k := 0 to MAX_M do
  begin
    entries[code] := UInt32(k + MINMATCH) shl 8 or (1 shl 16);   { literals extended }
    Inc(code);
  end;
  entries[code] := (UInt32(MINMATCH) shl 8) or (3 shl 16);       { both extended }
  WriteLn('  SYLZ_TOKENS: array[0..255] of UInt32 = (');
  col := 0;
  for code := 0 to 255 do
  begin
    if col = 0 then
      Write('   ');
    Write(Format(' $%.5x', [entries[code]]));
    if code < 255 then
      Write(',');
    Inc(col);
    if col = 8 then
    begin
      WriteLn;
      col := 0;
    end;
  end;
  WriteLn('  );');
end;

var
  i: Integer;
begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'usage: sylztable BLOCK...');
    Halt(1);
  end;
  FillChar(score, SizeOf(score), 0);
  for i := 1 to ParamCount do
    Accumulate(ParamStr(i));
  Choose;
  for i := 1 to ParamCount do
    Report(ParamStr(i));
  PrintTable;
end.
