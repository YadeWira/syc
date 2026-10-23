{ sylzvectors — test vectors for other sylz decoders (zpaq-std's ZPAQL).

  Writes DIR/sylzec/NAME.orig and NAME.LEVEL.blk (format v3: what the
  sylzec plugin's compress() returns, levels 0..10) and DIR/sylz/... the
  same for format v2 (the sylz plugin). A .blk is the block alone: no size
  prefix. tools/sylz_ref.py --check DIR/sylzec checks them.

  Usage: sylzvectors DIR [TEXT-FILE BINARY-FILE]   (samples for the text
  and binary cases; without them, generated stand-ins) }
program sylzvectors;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, sylz;

var
  seed: UInt32 = 12345;
  outDir: string;
  textSample, binSample: TBytes;

function Rnd: UInt32;
begin
  seed := seed * 1103515245 + 12345;
  Result := seed shr 8;
end;

procedure SaveFile(const path: string; p: PByte; n: SizeInt);
begin
  with TFileStream.Create(path, fmCreate) do
  try
    if n > 0 then
      WriteBuffer(p^, n);
  finally
    Free;
  end;
end;

function LoadFile(const path: string): TBytes;
begin
  with TFileStream.Create(path, fmOpenRead) do
  try
    SetLength(Result, Size);
    if Size > 0 then
      ReadBuffer(Result[0], Size);
  finally
    Free;
  end;
end;

{ one case: the original, and every level's block in both formats }
procedure Emit(const name: string; const data: TBytes);
var
  ctx: TSylzCtx;
  dst, back: TBytes;
  n, r, level, fmt: SizeInt;
  dir: string;
begin
  n := Length(data);
  SetLength(dst, SylzBound(n) + 1);
  SetLength(back, n + 1);
  SylzCtxInit(ctx);
  for fmt := 0 to 1 do
  begin
    if fmt = 0 then
      dir := outDir + '/sylzec/'
    else
      dir := outDir + '/sylz/';
    ForceDirectories(dir);
    if n > 0 then
      SaveFile(dir + name + '.orig', @data[0], n)
    else
      SaveFile(dir + name + '.orig', nil, 0);
    for level := SYLZ_MINLEVEL to SYLZ_MAXLEVEL do
    begin
      if fmt = 0 then
        r := SylzCompressEx(ctx, PByte(data), n, @dst[0], Length(dst), level, SYLZ_ENTROPY)
      else
        r := SylzCompressEx(ctx, PByte(data), n, @dst[0], Length(dst), level, 0);
      if r < 0 then
        raise Exception.Create(name + ': compression failed');
      { every vector decodes back here first }
      if (SylzDecompress(@dst[0], r, @back[0], n) <> n)
         or ((n > 0) and (CompareByte(back[0], data[0], n) <> 0)) then
        raise Exception.Create(name + ': does not roundtrip');
      SaveFile(Format('%s%s.%d.blk', [dir, name, level]), @dst[0], r);
    end;
  end;
  SylzCtxFree(ctx);
end;

function Repeated(b: Byte; n: SizeInt): TBytes;
begin
  SetLength(Result, n);
  if n > 0 then
    FillChar(Result[0], n, b);
end;

function RandomBytes(n: SizeInt): TBytes;
var
  i: SizeInt;
begin
  SetLength(Result, n);
  for i := 0 to n - 1 do
    Result[i] := Byte(Rnd);
end;

{ Literals with a steep distribution and no repeats long enough to match:
  symbol k (k = 0..11) with probability ~2^-(k+1), the rest spread, so the
  rare ones get the longest codes (11 bits). Each byte is mixed with a
  position-dependent one, so 4-byte matches are rare. }
function SteepLiterals(n: SizeInt): TBytes;
var
  i, k: SizeInt;
  r: UInt32;
begin
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    r := Rnd;
    k := 0;
    while (k < 16) and (r and 1 = 1) do
    begin
      Inc(k);
      r := r shr 1;
    end;
    if k >= 16 then
      Result[i] := Byte(32 + Rnd mod 200)
    else
      Result[i] := Byte(k);
  end;
end;

{ text with long repeats and many literals: words drawn from a small
  vocabulary }
function GeneratedText(n: SizeInt): TBytes;
const
  words: array[0..15] of string = ('the ', 'of ', 'and ', 'syc ', 'sylz ',
    'block ', 'literal ', 'match ', 'chunk ', 'stream ', 'code ', 'table ',
    'format ', 'level ', 'decoder ', 'Huffman ');
var
  s: string;
begin
  s := '';
  while Length(s) < n do
  begin
    s := s + words[Rnd mod 16];
    if Rnd mod 9 = 0 then
      s := s + IntToStr(Rnd mod 100000) + '. ';
  end;
  SetLength(Result, n);
  Move(s[1], Result[0], n);
end;

function Slice(const b: TBytes; n: SizeInt): TBytes;
begin
  if n > Length(b) then
    n := Length(b);
  SetLength(Result, n);
  if n > 0 then
    Move(b[0], Result[0], n);
end;

var
  one: TBytes;
begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'usage: sylzvectors DIR [TEXT-FILE BINARY-FILE]');
    Halt(1);
  end;
  outDir := ParamStr(1);
  if ParamCount >= 3 then
  begin
    textSample := LoadFile(ParamStr(2));
    binSample := LoadFile(ParamStr(3));
  end
  else
  begin
    textSample := GeneratedText(400000);
    binSample := RandomBytes(400000);
  end;
  SetLength(one, 1);
  one[0] := $41;
  Emit('empty', nil);
  Emit('one-byte', one);
  Emit('all-equal', Repeated($41, 100000));
  Emit('random', RandomBytes(100000));                 { raw chunks }
  Emit('text', Slice(textSample, 200000));
  Emit('binary', Slice(binSample, 200000));
  Emit('multi-chunk', Slice(textSample, 400000));      { > 65536 literals, short last chunk }
  Emit('max-length-codes', SteepLiterals(150000));     { codes up to 11 bits }
  Emit('generated-text', GeneratedText(300000));
  Emit('tiny-text', Slice(textSample, 300));           { under 256 literals: a raw chunk }
  WriteLn('vectors written to ', outDir);
end.
