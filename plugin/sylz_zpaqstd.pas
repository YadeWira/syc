{ sylz_zpaqstd — sylz as a zpaq-std codec plugin (-ma:sylz).

  Builds codecs/sylz.so / sylz.dll for zpaq-std's plugin ABI 1
  (compressors/plug/zs_codec.h in YadeWira/zpaq-std): one exported C
  function, zpaqstd_codec_v1, returning a static zs_codec.

    fpc -O3 -Fu../src plugin/sylz_zpaqstd.pas          (-> libsylz_zpaqstd.so)
    see plugin/build.sh for every target and the expected file names

  The block format is sylz format v2 as frozen at syc tag v0.2.2: zpaq-std
  writes a ZPAQL decoder for exactly that format, so a later sylz format
  needs a new codec name, not a new build of this one.

  CONTRACT with zpaq-std: the library field starts with "sylz format v2 "
  for as long as this plugin writes and reads format v2. zpaq-std uses the
  plugin to decode blocks tagged sylz2 only when it does; a plugin for a
  later format must say "sylz format v3 ..." (and so on), and zpaq-std
  then decodes the old v2 blocks with its own ZPAQL decoder.

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

const
  ZS_CODEC_ABI  = 1;
  ZS_ERR_DATA   = -1;
  ZS_ERR_MEMORY = -2;

  { Blocks larger than this are refused (bound returns 0): match finder
    positions are 32-bit, and the block header's control length is a u32. }
  MAX_BLOCK = SizeUInt($7FFF0000);

type
  { Mirrors struct zs_codec; the packrecords c directive gives C's layout on every
    target (pointers 4 or 8 bytes, ints 4). }
  {$packrecords c}
  TBoundFn      = function(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
  TCompressFn   = function(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
                           level: LongInt): Int64; cdecl;
  TDecompressFn = function(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
                           param: LongInt): Int64; cdecl;
  TQueryFn      = function(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
  TDataFn       = function(what: LongInt; size: PSizeUInt): Pointer; cdecl;

  TZsCodec = record
    abi: LongInt;
    name: PChar;
    library_: PChar;
    min_level, max_level: LongInt;
    bound: TBoundFn;
    compress: TCompressFn;
    decompress: TDecompressFn;
    query: TQueryFn;
    data: TDataFn;
  end;
  PZsCodec = ^TZsCodec;

function CodecBound(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
begin
  if n > MAX_BLOCK then
    Exit(0);
  Result := SizeUInt(SylzBound(SizeInt(n)));
end;

function CodecCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
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

function CodecDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var
  r: SizeInt;
begin
  { param: sylz needs nothing from the block header }
  if (n > SizeUInt(High(SizeInt))) or (cap > MAX_BLOCK) then
    Exit(ZS_ERR_DATA);
  { format v2 only (the contract): bit 31 of a block's first u32 flags
    format v3, which SylzDecompress would read too }
  if (n >= 4) and (PByte(src)[3] and $80 <> 0) then
    Exit(ZS_ERR_DATA);
  r := SylzDecompress(src, SizeInt(n), dst, SizeInt(cap));
  if r < 0 then
    Exit(ZS_ERR_DATA);
  Result := r;
end;

const
  Codec: TZsCodec = (
    abi: ZS_CODEC_ABI;
    name: 'sylz';
    library_: 'sylz format v2 (syc 0.2.13)';
    min_level: SYLZ_MINLEVEL;   { 0 = fastest; the default is 1 }
    max_level: SYLZ_MAXLEVEL;
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
