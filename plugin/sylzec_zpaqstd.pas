{ sylzec_zpaqstd — sylz format v3 as a zpaq-std codec plugin (-ma:sylzec).

  Builds codecs/sylzec.so / sylzec.dll, beside sylz's (plugin/build.sh
  builds both): one exported C function, zpaqstd_codec_v1, returning a
  static zs_codec named "sylzec".

  The block format is sylz format v3 as frozen at syc tag v0.2.14 (the
  wiki's sylz-format page): v2 plus Huffman-coded literals. A block is
  format v3 when that is smaller, else plain v2 (a v2 block is a valid v3
  block), so a decoder for sylzec reads both.

  CONTRACT with zpaq-std: the library field starts with "sylz format v3 "
  for as long as this plugin writes and reads format v3; zpaq-std tags its
  blocks sylzec3 and decodes them with the plugin only when it says so,
  else with its own ZPAQL decoder. A later format gets a new codec name.

  Levels 0..10 (syc's -ec levels), default 1. Thread-safe as sylz's. }
library sylzec_zpaqstd;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils,   { turns a failed GetMem into an exception (ZS_ERR_MEMORY) }
  sylz;

{$i zs_codec.inc}

function CodecCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
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

function CodecDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var
  r: SizeInt;
begin
  { param: sylzec needs nothing from the block header }
  if (n > SizeUInt(High(SizeInt))) or (cap > MAX_BLOCK) then
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

const
  Codec: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'sylzec';
    library_: 'sylz format v3 (syc 0.3.0)';
    min_level: SYLZ_MINLEVEL;    { 0 .. 10; the default is 1 }
    max_level: SYLZ_EC_MAXLEVEL;
    bound: @CodecBound;
    compress: @CodecCompress;
    decompress: @CodecDecompress;
    query: nil;
    data: nil
  );

function zpaqstd_codec_v1: PZsCodec; cdecl;
begin
  Result := @Codec;
end;

exports
  zpaqstd_codec_v1 name 'zpaqstd_codec_v1';

begin
  IsMultiThread := True;
end.
