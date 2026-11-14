{ sylz_zpaqstd — sylz as zpaq-std codec plugins: sylz (format v2,
  -ma:sylz), sylzec (format v3, -ma:sylzec), sylz4 (format v4) and sylz5
  (format v5) in one file.

  Builds codecs/sylz.so / sylz.dll for zpaq-std's plugin ABI 1
  (compressors/plug/zs_codec.h in YadeWira/zpaq-std). Two exported C
  functions: zpaqstd_codec_v1, returning sylz (what zpaq-std 1.7 and
  earlier load), and zpaqstd_codecs_v1(i), returning codec i: 0 sylz, 1
  sylzec, 2 sylz4, 3 sylz5, NULL after. Before syc 0.4.2 sylzec was a
  file of its own; sylz4 and sylz5 came with syc 0.8.0.

    fpc -O3 -Fu../src plugin/sylz_zpaqstd.pas          (-> libsylz_zpaqstd.so)
    see plugin/build.sh for every target and the expected file names

  The block format is sylz format v2 as frozen at syc tag v0.2.2: zpaq-std
  writes a ZPAQL decoder for exactly that format, so a later sylz format
  needs a new codec name, not a new build of this one.

  CONTRACT with zpaq-std: sylz's library field starts with "sylz format
  v2 " for as long as it writes and reads format v2, sylzec's with "sylz
  format v3 " for format v3 (frozen at syc v0.2.14: v2 plus Huffman-coded
  literals; a block is v3 when that is smaller, else plain v2, so sylzec
  reads both); sylz4's with "sylz format v4 " (frozen at syc v0.8.0; it
  writes v4, or a v2 block where that is smaller, and reads both), and
  sylz5's with "sylz format v5 " (v5, or v2, v3 or v4 blocks, and reads
  all four). zpaq-std decodes blocks with the plugin only when the
  string says so, else with its own ZPAQL decoders; a later format gets a
  new codec name.

  zpaq-std calls these from several threads at once: the RTL is told it is
  multi-threaded (cthreads on Unix, IsMultiThread) so the heap behind each
  call's compression context is thread-safe. sylz keeps no mutable global
  state. }
library sylz_zpaqstd;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils,   { turns a failed GetMem into an exception (ZS_ERR_MEMORY)
                instead of a runtime error that would end the host }
  sylz;

{$i zs_codec.inc}

function V2Compress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var
  r: SizeInt;
begin
  if n > MAX_BLOCK then
    Exit(ZS_ERR_DATA);
  if cap > SizeUInt(High(SizeInt)) then
    cap := SizeUInt(High(SizeInt));
  try
    r := SylzCompress(src, SizeInt(n), dst, SizeInt(cap), level);
  except
    { the only thing that raises in there is GetMem running out }
    Exit(ZS_ERR_MEMORY);
  end;
  if r < 0 then
    Exit(ZS_ERR_DATA);   { cap too small }
  Result := r;
end;

function V2Decompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var
  r: SizeInt;
begin
  { param: sylz needs nothing from the block header }
  if (n > SizeUInt(High(SizeInt))) or (cap > MAX_BLOCK) then
    Exit(ZS_ERR_DATA);
  { format v2 only (the contract): bit 31 of a block's first u32 flags
    format v3, which SylzDecompress would read too }
  if (n >= 4) and (PByte(src)[3] and $C0 <> 0) then
    Exit(ZS_ERR_DATA);   { bit 30: formats v4 and v5 }
  r := SylzDecompress(src, SizeInt(n), dst, SizeInt(cap));
  if r < 0 then
    Exit(ZS_ERR_DATA);
  Result := r;
end;

{ sylzec: format v3 (-ec), and v2 }

function ECCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var
  r: SizeInt;
  ctx: TSylzCtx;
begin
  if n > MAX_BLOCK then
    Exit(ZS_ERR_DATA);
  if cap > SizeUInt(High(SizeInt)) then
    cap := SizeUInt(High(SizeInt));
  SylzCtxInit(ctx);
  try
    try
      r := SylzCompressEx(ctx, src, SizeInt(n), dst, SizeInt(cap), level, SYLZ_ENTROPY);
    except
      { the only thing that raises in there is GetMem running out }
      Exit(ZS_ERR_MEMORY);
    end;
  finally
    SylzCtxFree(ctx);
  end;
  if r < 0 then
    Exit(ZS_ERR_DATA);   { cap too small }
  Result := r;
end;

function ECDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var
  r: SizeInt;
begin
  { param: sylzec needs nothing from the block header }
  if (n > SizeUInt(High(SizeInt))) or (cap > MAX_BLOCK) then
    Exit(ZS_ERR_DATA);
  { v2 or v3 only: bit 30 of the first u32 flags formats v4 and v5 }
  if (n >= 4) and (PByte(src)[3] and $40 <> 0) then
    Exit(ZS_ERR_DATA);
  try
    r := SylzDecompress(src, SizeInt(n), dst, SizeInt(cap));   { v2 or v3 }
  except
    Exit(ZS_ERR_MEMORY);   { the v3 literal buffer }
  end;
  if r < 0 then
    Exit(ZS_ERR_DATA);
  Result := r;
end;

{ sylz4 and sylz5: formats v4 and v5, which may write blocks of the
  formats below them where those are smaller }

function Compress4(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt; flags: Integer): Int64;
var
  r: SizeInt;
  ctx: TSylzCtx;
begin
  if n > MAX_BLOCK4 then
    Exit(ZS_ERR_DATA);
  if cap > SizeUInt(High(SizeInt)) then
    cap := SizeUInt(High(SizeInt));
  SylzCtxInit(ctx);
  try
    try
      r := SylzCompressEx(ctx, src, SizeInt(n), dst, SizeInt(cap), level, flags);
    except
      { the only thing that raises in there is GetMem running out }
      Exit(ZS_ERR_MEMORY);
    end;
  finally
    SylzCtxFree(ctx);
  end;
  if r < 0 then
    Exit(ZS_ERR_DATA);   { cap too small }
  Result := r;
end;

{ maxFormat: the newest block format the codec reads (4: v2 and v4; 5:
  every one); SylzBlockFormat tells them by the first u32 }
function Decompress4(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  maxFormat: Integer): Int64;
var
  r: SizeInt;
  f: Integer;
begin
  if (n > SizeUInt(High(SizeInt))) or (cap > MAX_BLOCK4) then
    Exit(ZS_ERR_DATA);
  f := SylzBlockFormat(src, SizeInt(n));
  if (maxFormat = 4) and (f = 3) or (f > maxFormat) then
    Exit(ZS_ERR_DATA);
  try
    r := SylzDecompress(src, SizeInt(n), dst, SizeInt(cap));
  except
    Exit(ZS_ERR_MEMORY);   { the v5 literal buffer }
  end;
  if r < 0 then
    Exit(ZS_ERR_DATA);
  Result := r;
end;

function V4Compress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
begin
  Result := Compress4(src, n, dst, cap, level, SYLZ_V4);
end;

function V4Decompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
begin
  Result := Decompress4(src, n, dst, cap, 4);
end;

function V5Compress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
begin
  Result := Compress4(src, n, dst, cap, level, SYLZ_V4 or SYLZ_ENTROPY);
end;

function V5Decompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
begin
  Result := Decompress4(src, n, dst, cap, 5);
end;

const
  Codec: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'sylz';
    library_: 'sylz format v2 (syc 0.8.0)';
    min_level: SYLZ_MINLEVEL;   { 0 = fastest; the default is 1 }
    max_level: SYLZ_MAXLEVEL;
    bound: @CodecBound;
    compress: @V2Compress;
    decompress: @V2Decompress;
    query: nil;
    data: nil
  );

  CodecEC: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'sylzec';
    library_: 'sylz format v3 (syc 0.8.0)';
    min_level: SYLZ_MINLEVEL;    { 0 .. 10; the default is 1 }
    max_level: SYLZ_EC_MAXLEVEL;
    bound: @CodecBound;
    compress: @ECCompress;
    decompress: @ECDecompress;
    query: nil;
    data: nil
  );

  Codec4: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'sylz4';
    library_: 'sylz format v4 (syc 0.8.0)';
    min_level: SYLZ_MINLEVEL;    { 0 .. 10; the default is 1 }
    max_level: SYLZ_MAXLEVEL;
    bound: @CodecBound4;
    compress: @V4Compress;
    decompress: @V4Decompress;
    query: nil;
    data: nil
  );

  Codec5: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'sylz5';
    library_: 'sylz format v5 (syc 0.8.0)';
    min_level: SYLZ_MINLEVEL;    { 0 .. 10 (-ec's); the default is 1 }
    max_level: SYLZ_EC_MAXLEVEL;
    bound: @CodecBound4;
    compress: @V5Compress;
    decompress: @V5Decompress;
    query: nil;
    data: nil
  );

function zpaqstd_codec_v1: PZsCodec; cdecl;
begin
  Result := @Codec;
end;

{ every codec of the file: 0 sylz, 1 sylzec, 2 sylz4, 3 sylz5, then NULL }
function zpaqstd_codecs_v1(i: LongInt): PZsCodec; cdecl;
begin
  case i of
    0: Result := @Codec;
    1: Result := @CodecEC;
    2: Result := @Codec4;
    3: Result := @Codec5;
  else
    Result := nil;
  end;
end;

{ FPC 3.2.2 exports these names as written; on macOS a C symbol has a
  leading underscore (dlsym adds it), so there it is written in }
exports
  zpaqstd_codec_v1 name {$ifdef darwin}'_zpaqstd_codec_v1'{$else}'zpaqstd_codec_v1'{$endif},
  zpaqstd_codecs_v1 name {$ifdef darwin}'_zpaqstd_codecs_v1'{$else}'zpaqstd_codecs_v1'{$endif};

begin
  IsMultiThread := True;
end.
