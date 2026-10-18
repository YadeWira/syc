{ sylzstats — sequence statistics of a sylz block (format v2).

  Usage: sylzstats COMPRESSED
  (COMPRESSED from: SYLZ_DUMP=prefix sylzbench ...)

  Prints literal-length, match-length and offset histograms, plus how often
  a sequence reuses one of the previous offsets: the inputs for choosing
  token layout. }
program sylzstats;

{$mode objfpc}{$H+}
{$R-}{$Q-}

uses
  SysUtils, Classes, Math, sylz;

const
  MINMATCH = 4;
  JL = 64;    { joint histogram: literal lengths 0..JL-2, JL-1 = "more" }
  JM = 128;   { match lengths - 4: 0..JM-2, JM-1 = "more" }
  HEADER = 4;

var
  buf: TBytes;
  n, ip, cend: SizeInt;
  b: Byte;
  e: UInt32;
  ll, ml, off, rep0, rep1: SizeInt;
  seqs, repHits0, repHits1, litBytes, matchBytes: Int64;
  llHist, mlHist: array[0..64] of Int64;   { 64 = "64 or more" }
  offHist: array[0..17] of Int64;           { by bit length of the offset }
  joint: array[0..JL - 1, 0..JM - 1] of Int64;   { (literals, match - 4), capped }
  pairs: array of Int64;
  inline35, escapes: Int64;
  i, k: Integer;
  acc: Int64;

function BitLen(v: SizeInt): Integer;
begin
  Result := 0;
  while v > 0 do
  begin
    Inc(Result);
    v := v shr 1;
  end;
end;

procedure PrintHist(const title: string; const h: array of Int64; base: Integer);
var
  k: Integer;
  total, run: Int64;
begin
  total := 0;
  for k := 0 to High(h) do
    Inc(total, h[k]);
  WriteLn(title);
  run := 0;
  for k := 0 to High(h) do
  begin
    Inc(run, h[k]);
    if h[k] > 0 then
      WriteLn(Format('  %4d%s %12d  %6.2f%%  cum %6.2f%%',
        [k + base, BoolToStr(k = High(h), '+', ' '), h[k], h[k] * 100.0 / total, run * 100.0 / total]));
  end;
end;

begin
  if ParamCount <> 1 then
  begin
    WriteLn(StdErr, 'usage: sylzstats COMPRESSED');
    Halt(1);
  end;
  with TFileStream.Create(ParamStr(1), fmOpenRead) do
  try
    n := Size;
    SetLength(buf, n);
    ReadBuffer(buf[0], n);
  finally
    Free;
  end;

  seqs := 0; repHits0 := 0; repHits1 := 0; litBytes := 0; matchBytes := 0;
  inline35 := 0; escapes := 0;
  FillChar(llHist, SizeOf(llHist), 0);
  FillChar(mlHist, SizeOf(mlHist), 0);
  FillChar(offHist, SizeOf(offHist), 0);
  FillChar(joint, SizeOf(joint), 0);
  rep0 := -1;
  rep1 := -1;
  cend := HEADER + (buf[0] or (SizeInt(buf[1]) shl 8) or (SizeInt(buf[2]) shl 16) or (SizeInt(buf[3]) shl 24));
  ip := HEADER;
  while ip < cend do
  begin
    e := SYLZ_TOKENS[buf[ip]];
    off := (buf[ip + 1] or (SizeInt(buf[ip + 2]) shl 8)) + 1;
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
    if e > $FFFF then
      Inc(escapes);

    Inc(seqs);
    Inc(litBytes, ll);
    Inc(matchBytes, ml);
    if ll > 64 then Inc(llHist[64]) else Inc(llHist[ll]);
    Inc(joint[Min(ll, JL - 1), Min(ml - MINMATCH, JM - 1)]);
    if (ll < 7) and (ml - MINMATCH < 31) then
      Inc(inline35);
    if ml - MINMATCH > 64 then Inc(mlHist[64]) else Inc(mlHist[ml - MINMATCH]);
    Inc(offHist[BitLen(off)]);
    if off = rep0 then
      Inc(repHits0)
    else if off = rep1 then
      Inc(repHits1);
    if off <> rep0 then
    begin
      rep1 := rep0;
      rep0 := off;
    end;
  end;
  WriteLn(Format('control %d bytes, literal stream %d bytes', [cend - HEADER, n - cend]));

  WriteLn(Format('sequences %d, literal bytes %d, match bytes %d, avg match %.2f',
    [seqs, litBytes, matchBytes, matchBytes / Max(seqs, 1)]));
  WriteLn(Format('offset == previous offset: %.2f%%, == the one before: %.2f%%',
    [repHits0 * 100.0 / Max(seqs, 1), repHits1 * 100.0 / Max(seqs, 1)]));
  PrintHist('literal length:', llHist, 0);
  PrintHist('match length (from 4):', mlHist, MINMATCH);
  WriteLn('offset bit length (offset < 2^k):');
  acc := 0;
  for i := 1 to 17 do
  begin
    Inc(acc, offHist[i]);
    if offHist[i] > 0 then
      WriteLn(Format('  < %6d  %12d  %6.2f%%  cum %6.2f%%',
        [1 shl i, offHist[i], offHist[i] * 100.0 / Max(seqs, 1), acc * 100.0 / Max(seqs, 1)]));
  end;
  { how many sequences a table of the k most frequent exact (literals,
    match) pairs would cover, against the 3/5 bit split }
  SetLength(pairs, 0);
  for i := 0 to JL - 2 do
    for k := 0 to JM - 2 do
      if joint[i, k] > 0 then
      begin
        SetLength(pairs, Length(pairs) + 1);
        pairs[High(pairs)] := joint[i, k];
      end;
  for i := 1 to High(pairs) do
  begin
    acc := pairs[i];
    k := i - 1;
    while (k >= 0) and (pairs[k] < acc) do
    begin
      pairs[k + 1] := pairs[k];
      Dec(k);
    end;
    pairs[k + 1] := acc;
  end;
  WriteLn(Format('escape tokens (an extended length): %.2f%%', [escapes * 100.0 / Max(seqs, 1)]));
  WriteLn(Format('v1 3/5 bit split would need no extension for: %.2f%%', [inline35 * 100.0 / Max(seqs, 1)]));
  acc := 0;
  for i := 0 to Min(High(pairs), 255) do
  begin
    Inc(acc, pairs[i]);
    if ((i + 1) mod 64 = 0) or ((i + 1) in [160, 208, 216, 224, 232, 240, 248]) then
      WriteLn(Format('top %3d exact pairs: %.2f%%', [i + 1, acc * 100.0 / Max(seqs, 1)]));
  end;
end.
