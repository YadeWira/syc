{ zs_codec.inc — zpaq-std's plugin ABI 1 (compressors/plug/zs_codec.h in
  YadeWira/zpaq-std) and the bound both codecs of sylz_zpaqstd.pas give. }

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

