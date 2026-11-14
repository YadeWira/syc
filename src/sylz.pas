{ sylz — syc fast LZ codec.

  Format v2 (one block = one call; the caller stores the decoded size):

    block    := ctrlLen:u32le  control[ctrlLen]  literals[...]
    control  := sequence*
    sequence := token  offset:u16le  [litlen-ext]  [matchlen-ext]
    token    := index into SYLZ_TOKENS, whose entry gives a literal length,
                a match length and which of them is extended:
                  0..209    an exact (literals, match) pair, literals <= 15,
                            match <= 32: no extension
                  210..225  literals = code - 210, match = 4 + ext
                  226..254  literals = ext, match = 4 + code - 226
                  255       literals = ext, match = 4 + ext
    offset   := distance - 1, so distances run 1..65536
    ext      := a value in 255-run bytes: each byte adds itself, 255 means
                another byte follows; the literal extension comes first

  Format v3 is v2 plus optionally entropy-coded literals. A v2 block is a
  valid v3 block; a v3 block sets bit 31 of the first u32 (the control
  length is then bits 0..30), which a v2 decoder rejects as an
  impossible length instead of misreading it:

    block    := hdr:u32le  control[ctrlLen]  litsection
    hdr      := ctrlLen | (bit 31: literals entropy-coded)
    litsection, bit 31 clear := literals[...] as in v2
    litsection, bit 31 set   := litCount:u32le  chunk*
    chunk    := see sylzhuf.pas; chunks of 65536 literals (the last one
                shorter) cover litCount, each raw or Huffman-coded

  Literals live in their own stream, in order. Each sequence takes its
  literals from the front of that stream, then copies its match; whatever
  is left in the literal stream after the last sequence is the block's
  tail.

  Why two streams: the next token is always 3 bytes further on (plus the
  rare extension), whatever the literal length, so the decoder's loads for
  the next sequence don't wait on the current one.

  Why a table: v1 split the token 3/5 bits (literals 0..6, match 4..34) and
  15% of level-1 sequences on silesia.tar needed an extension; each one is
  a branch the decoder can't predict. The 210 exact pairs are the most
  frequent ones (bench/sylztable.pas, over Silesia and a mixed corpus at
  levels 1 and 9), and leave 8-12% of sequences extended. Exact pairs fit
  fixed 16-byte literal and 32-byte match copies.

  Formats v4 and v5 (SYLZ_V4; frozen at syc v0.8.0, the layout of 0.7.0): three streams,
  tokens, offsets and literals, so that a token is one byte and a
  sequence takes two offset bytes only when it needs them; v5 is v4 with
  the literals in chunks like v3's, whose Huffman chunks have eight
  streams (sylzhuf.pas, mode 3). Bit 30 of the first u32 tells them from
  v2 and v3:

    block    := hdr:u32le  tokens[tokLen]  [offCount]  offsets[2 * offCount]
                litsection
    hdr      := tokLen (bits 0..28) | (bit 30) | (bit 31: literals
                entropy-coded, v5); or, with bit 29 set, a block of one
                chunk: tokLen (bits 0..13), offCount (bits 14..27), the
                chunk header's bit 0 (bit 28); that chunk has no header
                then, and no offCount follows the tokens
    offCount := 1 to 5 bytes, 7 bits each, low bits first, bit 7 set on
                all but the last; none when tokLen = 0 (no offsets)
    tokens   := chunk*
    chunk    := chdr  [update]  token-bytes[n]
    chdr     := 2 bytes (u16le, n = bits 2..15) when bit 1 is clear,
                4 bytes (u32le, n = bits 2..31) when it is set;
                bit 0: a table update follows
    update   := (count - 1):u8  (code:u8  entry:u16le) * count
    offsets  := (distance - 1):u16le *
    token    := index into the table, whose entry gives a literal length
                (0..16, or extended), a match length (0..32, or extended)
                and whether the match is at a new offset (the next two
                offset bytes) or at the previous sequence's
    ext      := as in v2, in the token bytes; the match extension counts
                from 4 at a new offset, from 2 at the previous one

  The table is SYLZ_TOKENS4 when a block starts; a chunk's update replaces
  the entries it lists, for that chunk and the ones after it. A block
  that a v4 or v5 encoder writes may also be a v2 or v3 block, where
  that layout is smaller (a small block with few matches at the previous
  offset): decoders take each block by its header. A block with no
  tokens is its header and the literals: syc writes one where the block
  would come out bigger than its input.

  syc's encoder (not the format): levels 0-3 record a chunk's first
  FAST_PREFIX4 sequences, make the update from them, and write the rest
  of the chunk's tokens as the sequences are found (an open chunk, up to
  CHUNK4_TOKENS token bytes); levels 4-10 record CHUNK4_SEQS sequences
  and make each chunk's update from all of them.

  A match at the previous sequence's offset costs a token and no offset
  bytes: in structured data a fifth to a half of the matches are such.
  A token with match length 0 is literals only, and one with no literals
  at the previous offset continues a match, so what has no code of its
  own is written as two or three plain tokens, which the decoder's loop
  takes without a branch, instead of an escape and an extension; only
  literal runs over 32 and matches over 64 are extended. Each chunk of
  the token stream can change the table for the pairs it uses most, at
  three bytes for each entry it replaces. }
unit sylz;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$inline on}
{$pointermath on}

interface

const
  SYLZ_MINMATCH = 4;
  SYLZ_MAXDIST  = 65536;
  { Levels 0..10: 0-1 are the fast single-hash levels (1 has the bigger
    table); 2-3 use two hash tables (2 greedy, 3 lazy); 4-8 hash chains
    with lz4hc's parse; 9 and 10 a decode-aware optimal parser. 1 is the
    default. }
  SYLZ_MINLEVEL = 0;
  SYLZ_MAXLEVEL = 10;
  SYLZ_DEFLEVEL = 1;

  { Token table, generated by bench/sylztable.pas. Entry: bits 0..7
    literal length (base), 8..15 match length (base), bit 16 literal
    length extended, bit 17 match length extended. }
  SYLZ_TOK_LLEXT = $10000;
  SYLZ_TOK_MLEXT = $20000;
  SYLZ_TOKENS: array[0..255] of UInt32 = (
    $00400, $00500, $00600, $00700, $00800, $00900, $00A00, $00B00,
    $00C00, $00D00, $00E00, $00F00, $01000, $01100, $01200, $01300,
    $01400, $01500, $01600, $01700, $01800, $01900, $01A00, $01B00,
    $01C00, $01D00, $01E00, $01F00, $02000, $00401, $00501, $00601,
    $00701, $00801, $00901, $00A01, $00B01, $00C01, $00D01, $00E01,
    $00F01, $01001, $01101, $01201, $01301, $01401, $01501, $01601,
    $01701, $01801, $01901, $01A01, $01B01, $01C01, $01D01, $01E01,
    $01F01, $02001, $00402, $00502, $00602, $00702, $00802, $00902,
    $00A02, $00B02, $00C02, $00D02, $00E02, $00F02, $01002, $01102,
    $01202, $01302, $01402, $01502, $01602, $01702, $01802, $01A02,
    $01E02, $01F02, $00403, $00503, $00603, $00703, $00803, $00903,
    $00A03, $00B03, $00C03, $00D03, $00E03, $00F03, $01003, $01103,
    $01203, $01303, $00404, $00504, $00604, $00704, $00804, $00904,
    $00A04, $00B04, $00C04, $00D04, $00E04, $00F04, $01004, $01204,
    $01304, $00405, $00505, $00605, $00705, $00805, $00905, $00A05,
    $00B05, $00C05, $00D05, $00E05, $00F05, $01205, $01305, $01705,
    $00406, $00506, $00606, $00706, $00806, $00906, $00A06, $00B06,
    $00C06, $00D06, $00E06, $01206, $00407, $00507, $00607, $00707,
    $00807, $00907, $00A07, $00B07, $00D07, $01107, $00408, $00508,
    $00608, $00708, $00808, $00908, $00A08, $00B08, $00C08, $00409,
    $00509, $00609, $00709, $00809, $00909, $00A09, $00B09, $01309,
    $0040A, $0050A, $0060A, $0070A, $0080A, $00A0A, $00E0A, $0140A,
    $0040B, $0050B, $0060B, $0070B, $0080B, $0090B, $00D0B, $0140B,
    $0150B, $0040C, $0050C, $0060C, $0070C, $0080C, $00C0C, $0140C,
    $0040D, $0050D, $0060D, $0070D, $00B0D, $0040E, $0050E, $0060E,
    $0070E, $0080E, $0090E, $00A0E, $0040F, $0050F, $0060F, $0070F,
    $0080F, $0090F, $20400, $20401, $20402, $20403, $20404, $20405,
    $20406, $20407, $20408, $20409, $2040A, $2040B, $2040C, $2040D,
    $2040E, $2040F, $10400, $10500, $10600, $10700, $10800, $10900,
    $10A00, $10B00, $10C00, $10D00, $10E00, $10F00, $11000, $11100,
    $11200, $11300, $11400, $11500, $11600, $11700, $11800, $11900,
    $11A00, $11B00, $11C00, $11D00, $11E00, $11F00, $12000, $30400
  );


type
  { Reusable compression context: the literal scratch buffer and the match
    finder tables, allocated on first use and kept between calls. Reusing
    one saves the allocation and the page faults of a fresh scratch buffer
    the size of the input on every call. One context per thread. }
  TSylzCtx = record
    scratch: PByte;
    scratchSize: SizeInt;
    table: PUInt16;      { levels 0-3: hash tables (low 16 bits of positions) }
    head: PUInt16;       { levels 4+: hash heads (low 16 bits of positions) }
    chain: PUInt16;      { levels 4+: chain deltas }
    opt: PByte;          { optimal parser: nodes, candidates, path }
    bt: PUInt32;         { optimal parser: binary-tree match finder }
    flags: Integer;      { of the current call }
    offs: PByte;         { format v4: the offset stream's scratch buffer }
    offsSize: SizeInt;
    recs: PUInt16;       { format v4: a chunk's sequences }
  end;


procedure SylzCtxInit(out ctx: TSylzCtx);
procedure SylzCtxFree(var ctx: TSylzCtx);

type
  { Reusable decompression context: the literal buffer a v3 block decodes
    into, kept between calls. }
  TSylzDCtx = record
    lits: PByte;
    litsSize: SizeInt;
  end;

procedure SylzDCtxInit(out dctx: TSylzDCtx);
procedure SylzDCtxFree(var dctx: TSylzDCtx);

{ Worst-case compressed size of n input bytes. }
function SylzBound(n: SizeInt): SizeInt;

{ Compresses src[0..n) into dst (capacity cap, at least SylzBound(n)).
  level 0..1 = fast greedy, 2..3 = two hash tables (2 greedy, 3 lazy),
  4..8 = hash chains with lz4hc's parse, 9..SYLZ_MAXLEVEL = optimal
  parsing (see SYLZ_MINLEVEL).
  Returns the compressed size, or -1 if cap is too small. }
function SylzCompress(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt;
  level: Integer): SizeInt;

{ SylzCompress with a caller-kept context; same output. }
function SylzCompressCtx(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; level: Integer): SizeInt;

const
  { SylzCompressEx flags }
  SYLZ_ENTROPY = 1;   { format v3: Huffman-code the literals where it pays }
  { With SYLZ_ENTROPY the levels are 0..SYLZ_EC_MAXLEVEL: 0..8 parse as
    format v2's level N + SYLZ_EC_SHIFT (v2's levels 0 and 1 leave so many
    literals that, Huffman-coded, they decode slower than level 2's parse
    and compress worse: silesia.tar 40.11% / 1655 MB/s, 39.21% / 1795,
    against 38.80% / 2209); 9 and 10 run the optimal parser with each
    literal priced by its Huffman code (CompressOptEC). Format v5 (with
    SYLZ_V4) takes V5_LEVELS, the same parses with v4's parsers. }
  SYLZ_EC_SHIFT = 2;
  SYLZ_EC_MAXLEVEL = SYLZ_MAXLEVEL;   { 9 and 10: entropy-aware prices }
  SYLZ_V4 = 2;        { format v4; with SYLZ_ENTROPY, v5 }

  { Format v4's token table (bench/sylztable.pas). Entry: bits 0..7
    literal length (base), 8..15 match length (base), 16..23 the bytes the
    sequence takes from the offset stream (2: a new offset, 0: the previous
    sequence's), bit 24 literal length extended, bit 25 match length
    extended. }
  SYLZ_TOK4_OFF   = $20000;
  SYLZ_TOK4_LLEXT = $1000000;
  SYLZ_TOK4_MLEXT = $2000000;
  SYLZ_MINREP = 2;    { shortest match at the previous offset }
  SYLZ_TOKENS4: array[0..255] of UInt32 = (
    $0020400, $0020500, $0020600, $0020700, $0020800, $0020900, $0020A00, $0020B00,
    $0020C00, $0020D00, $0020E00, $0020F00, $0021000, $0021100, $0021200, $0021300,
    $0021400, $0021500, $0021600, $0021700, $0021800, $0021900, $0021A00, $0021B00,
    $0021C00, $0021D00, $0021E00, $0021F00, $0022000, $0020401, $0020501, $0020601,
    $0020701, $0020801, $0020901, $0020A01, $0020B01, $0020C01, $0020D01, $0020E01,
    $0020F01, $0021001, $0021101, $0021201, $0021301, $0021401, $0021501, $0021701,
    $0021B01, $0021E01, $0021F01, $0022001, $0020402, $0020502, $0020602, $0020702,
    $0020802, $0020902, $0020A02, $0020B02, $0020C02, $0020D02, $0020E02, $0020F02,
    $0021002, $0021202, $0021502, $0021E02, $0022002, $0020403, $0020503, $0020603,
    $0020703, $0020803, $0020903, $0020A03, $0020B03, $0020C03, $0020D03, $0020E03,
    $0022003, $0020404, $0020504, $0020604, $0020704, $0020804, $0020904, $0020A04,
    $0020B04, $0020C04, $0022004, $0020405, $0020505, $0020605, $0020705, $0020805,
    $0020905, $0020A05, $0020B05, $0020D05, $0020406, $0020506, $0020606, $0020706,
    $0020806, $0020906, $0020A06, $0020C06, $0020407, $0020507, $0020607, $0020707,
    $0020807, $0020907, $0020408, $0020508, $0020608, $0020708, $0020808, $0020409,
    $0020509, $0020609, $0020709, $0020809, $002040A, $002050A, $002060A, $002070A,
    $002080A, $002040B, $002050B, $002060B, $002070B, $002140B, $002040C, $002060C,
    $002070C, $002140C, $002040D, $002050D, $002060D, $002070D, $002040E, $002060E,
    $002040F, $002050F, $002060F, $002070F, $002080F, $0020410, $0020610, $0000200,
    $0000300, $0000400, $0000500, $0000600, $0000700, $0000800, $0000900, $0000A00,
    $0000B00, $0000C00, $0000D00, $0000E00, $0000F00, $0001000, $0001100, $0001200,
    $0001300, $0001400, $0001500, $0001600, $0001700, $0001800, $0001900, $0001A00,
    $0001B00, $0001C00, $0001D00, $0001E00, $0001F00, $0002000, $0000001, $0000401,
    $0000501, $0000601, $0000701, $0000801, $0000901, $0000A01, $0000B01, $0000C01,
    $0000D01, $0000E01, $0000F01, $0001001, $0001101, $0001301, $0001401, $0001501,
    $0001701, $0001B01, $0002001, $0000002, $0000402, $0000502, $0000602, $0000702,
    $0000802, $0000A02, $0000E02, $0001202, $0001602, $0001E02, $0002002, $0000003,
    $0000403, $0000503, $0000903, $0000D03, $0000004, $0000404, $0000504, $0000005,
    $0000405, $0000605, $0000705, $0000B05, $0000006, $0000406, $0000606, $0000A06,
    $0000007, $0000407, $0000507, $0000607, $0000008, $0000009, $000000A, $000000B,
    $000050B, $000000C, $000040C, $000000D, $000000E, $000000F, $0000010, $1020500,
    $1020600, $1020700, $1020800, $1020900, $1000000, $1020400, $2020400, $2000200
  );

{ SylzCompressCtx with flags. Without SYLZ_ENTROPY the output is format v2
  (what SylzCompress writes); with it, format v3 if that is smaller, else
  v2, and levels go 0..SYLZ_EC_MAXLEVEL (see SYLZ_EC_SHIFT). SylzDecompress
  reads both. }
function SylzCompressEx(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; level: Integer; flags: Integer): SizeInt;

{ Decompresses a format v2 or v3 block src[0..n) into exactly dstLen bytes
  at dst. Safe on corrupt input: never reads or writes out of bounds.
  Returns dstLen, or -1 on corrupt input. A v3 block with coded literals
  takes a temporary buffer of its literal count. }
function SylzDecompress(src: PByte; n: SizeInt; dst: PByte; dstLen: SizeInt): SizeInt;

{ The format of the block at src, by its header: 2 .. 5, or 0 if it is too
  short to tell. }
function SylzBlockFormat(src: PByte; n: SizeInt): Integer;

{ The format SylzCompressEx writes with these flags, 2 .. 5 (with
  SYLZ_ENTROPY a block may also come out as the format below it). }
function SylzFlagsFormat(flags: Integer): Integer;

{ SylzDecompress with a caller-kept context; same results. }
function SylzDecompressCtx(var dctx: TSylzDCtx; src: PByte; n: SizeInt; dst: PByte;
  dstLen: SizeInt): SizeInt;

var
  { Use the assembler (x86_64) and C fast paths where there are any,
    unless built with -dSYLZ_PUREPASCAL. Every path produces the same
    results; tests turn this off to exercise the Pascal ones. }
  SylzUseAsm: Boolean = True;
  { On x86_64, take the C paths instead of the assembler ones where both
    exist (tests and benchmarks; elsewhere C is the fast path anyway). }
  SylzPreferC: Boolean = False;

implementation

uses
  sylzhuf;

{ C parts (sylzc.c, built by build.sh into the object path): every
  target, unless SYLZ_PUREPASCAL }
{$ifndef SYLZ_PUREPASCAL}
{$define SYLZ_C}
{$L sylzc.o}
{$endif}

{$if defined(CPUX86_64) and not defined(SYLZ_PUREPASCAL)}
{$define SYLZ_ASM_X64}
{$asmmode intel}
{$endif}

const
  HEADER_SIZE  = 4;
  SMALL_BLOCK4 = 65536;   { SylzCompressEx: v4/v5 blocks this small are also tried as v2/v3 }
  HEADER4_SIZE = 8;                   { SylzBound's share for a header; v4's
                                        is HEADER_SIZE, and the offset count
                                        (OFFCOUNT_MAX bytes) after the tokens }
  OFFCOUNT_MAX = 5;
  HDR_V4       = UInt32($40000000);   { v4 layout: tokens, offsets, literals }
  HDR_TOKMASK  = UInt32($1FFFFFFF);
  { v4, a block of one chunk under 2^HDR4_BITS token bytes: the header has
    them in bits 0..13, the offset count in bits 14..27 and the chunk's
    CHUNK4_UPDATE in bit 28, and neither a chunk header nor a count
    follows }
  HDR4_ONE     = UInt32($20000000);
  HDR4_BITS    = 14;
  HDR4_UPDATE  = UInt32($10000000);
  HDR_ENTROPY  = UInt32($80000000);   { v3: literals entropy-coded }
  HDR_CTRLMASK = UInt32($7FFFFFFF);
  LIT_CHUNK    = 65536;               { v3 literal chunk }
  EXACT_LL     = 15;    { exact codes cover literals 0..EXACT_LL }
  EXACT_M      = 28;    { and match - 4 in 0..EXACT_M (match <= 32) }
  ESC_ML       = 210;   { + literals: literals exact, match extended }
  ESC_LL       = 226;   { + match - 4: literals extended, match exact }
  ESC_BOTH     = 255;
  SEARCH_TAIL  = 12;    { no match search within this many bytes of the end }
  { The fast levels hash 6 bytes (64-bit targets): against 5, fewer and
    longer matches, so 6% fewer decode cycles (silesia.tar), and faster
    compression; the ratio lost is won back by the table size per level. }
  FAST_HASH_BYTES = 6;
  SKIP_STRENGTH = 6;
  HC_HASHLOG   = 16;
  HC_MAXDIST   = 65535; { chain deltas are UInt16 }
  HC_CHAINSIZE = 1 shl 16;
  HC_CHAINMASK = HC_CHAINSIZE - 1;
  { hash chain depth of levels 4..8 }
  HC_ATTEMPTS: array[4..8] of Integer = (2, 4, 8, 16, 64);
  { format v4, levels 4..8: see CompressHCCore }
  HC_REP_ENOUGH = 8;
  HC_REP_GAIN  = 2;
  { format v4, levels 4..8: a literal run is searched every
    1 + run shr HC_ACCEL4 bytes (see CompressHCCore) }
  HC_ACCEL4 = 7;
  { levels 2-3: two hash tables, one keyed on 6 bytes (long matches), one
    on 4; 2^15 entries each at level 2, 2^16 at level 3 }
  MID_MAXLOG   = 16;
  MID_SKIP     = 9;     { probe step 1 + (literals so far) shr MID_SKIP }
  MID_STEP1    = 1 shl MID_SKIP;   { so one byte below this many literals }
  MID_LAZY_ENOUGH = 32; { level 3 stops looking one byte later at this length }
  MID_NEXT_BELOW = 8;   { level 2 looks one byte later below this length }
  SCRATCH_SLACK = 16;
  { TSylzCtx.table: 2^17 entries, the two tables of level 3 (the fast
    levels use at most 2^15) }
  CTX_TABLELOG = MID_MAXLOG + 1;   { literal scratch overshoot room for Copy16 }

function SylzBound(n: SizeInt): SizeInt;
begin
  Result := HEADER4_SIZE + n + n div 255 + 16;
end;

function Read32(p: PByte): UInt32; inline;
begin
  Result := PUInt32(p)^;
end;

function Read64(p: PByte): UInt64; inline;
begin
  Result := PUInt64(p)^;
end;

procedure Copy8(d, s: PByte); inline;
begin
  PUInt64(d)^ := PUInt64(s)^;
end;

procedure Copy16(d, s: PByte); inline;
begin
  PUInt64(d)^ := PUInt64(s)^;
  PUInt64(d + 8)^ := PUInt64(s + 8)^;
end;

function Hash4(v: UInt32; hashLog: Integer): UInt32; inline;
begin
  { FPC widens UInt32*UInt32 to the native int on 64-bit targets: truncate
    before shifting or the high bits leak into the index }
  Result := UInt32(v * UInt32(2654435761)) shr (32 - hashLog);
end;

{ Hash of the bytes at p for the fast levels: FAST_HASH_BYTES of them, on
  every target. 32-bit ones hashed 4 bytes until syc 0.5.1 (a 64-bit
  multiply costs more there) and wrote other, equally valid blocks; zpaq-std
  asked for the same bytes on x86 and x64. }
function HashFast(p: PByte; hashLog: Integer): UInt32; inline;
begin
  Result := UInt32((Read64(p) shl (64 - 8 * FAST_HASH_BYTES)) * UInt64(889523592379) shr (64 - hashLog));
end;

{ hash table size of each fast level }
const
  FAST_LOG0 = 13;
  FAST_LOG1 = 15;

function FastHashLog(level: Integer): Integer;
begin
  if level = 0 then
    Result := FAST_LOG0
  else
    Result := FAST_LOG1;
end;

{ Length of the common prefix of a and b, not reading at or past limit
  (limit applies to a; b is always behind a). }
function CountMatch(a, b, limit: PByte): SizeInt; inline;
var
  start: PByte;
  diff: UInt64;
begin
  start := a;
  while a + 8 <= limit do
  begin
    diff := Read64(a) xor Read64(b);
    if diff <> 0 then
    begin
      Result := (a - start) + SizeInt(BsfQWord(diff) shr 3);
      Exit;
    end;
    Inc(a, 8);
    Inc(b, 8);
  end;
  while (a < limit) and (a^ = b^) do
  begin
    Inc(a);
    Inc(b);
  end;
  Result := a - start;
end;

{ ── encoder output ───────────────────────────────────────────────────────── }

const
  { format v4: exact codes cover literals 0..MAX_LL4 (one 16-byte copy) and
    matches up to MAX_ML4 (one 32-byte copy). What has no code of its own
    is split into tokens that do, so the decoder's fast loop takes it
    without a branch: a literal-only token (match length 0, previous
    offset) before the match, and the rest of a long match as tokens at
    the previous offset with no literals. Only literal runs over
    LIT_SPLIT4 and matches over ML_SPLIT4 take an escape (an extension). }
  MAX_LL4    = 16;
  MAX_ML4    = 32;
  LIT_SPLIT4 = 32;
  ML_SPLIT4  = 64;
  { a table entry's cell: its kind (0 a new offset, 1 the previous one),
    its row (the literals, ROW4_EXT: extended) and its column (the match
    length, COL4_EXT: extended) }
  ROW4_EXT   = MAX_LL4 + 1;
  COL4_EXT   = MAX_ML4 + 1;
  ROWS4      = ROW4_EXT + 1;
  COLS4      = COL4_EXT + 1;
  NCELLS4    = 2 * ROWS4 * COLS4;   { a cell's index: (kind * ROWS4 + row) * COLS4 + column }
  { the shortest match of each kind: what a match extension counts from }
  MINML4: array[0..1] of SizeInt = (SYLZ_MINMATCH, SYLZ_MINREP);
  { The token stream comes in chunks of CHUNK4_SEQS sequences. The table
    is SYLZ_TOKENS4 when a block starts; a chunk can replace entries of it
    (UPDATE4_BYTES each, and a byte for their count) with the pairs its
    sequences use more, and the chunks after it go on from that table. }
  CHUNK4_SEQS     = 131072;
  UPDATE4_BYTES   = 3;
  UPDATE4_MAX     = 256;
  { chunk header: 2 bytes, the token bytes in bits 2..15, or with
    CHUNK4_LONG 4 bytes and bits 2..31; CHUNK4_UPDATE: an update follows }
  CHUNK4_UPDATE   = 1;
  CHUNK4_LONG     = 2;
  CHUNK4_SHORTMAX = 1 shl 14;   { a 2-byte header holds fewer token bytes than this }
  CHUNK4_MAX      = 1 shl 30;   { and a 4-byte one fewer than this }
  CELL4_KEPT  = UInt32($40000000);
  CELL4_SHORT = UInt32($80000000);
  CELL4_ENTRY = UInt32($3FFFFFFF);
  { table entry (u16): bits 0..4 literals (TAB4_EXT: extended), 5..10
    match length (TAB4_EXT_ML: extended), bit 11 previous offset }
  TAB4_EXT    = 31;
  TAB4_EXT_ML = 63;
  TAB4_REP    = $800;
  { Levels 0..3 record only a chunk's first FAST_PREFIX4 sequences: the
    table's update for the chunk is made from them, and the sequences
    after them are written as tokens as they are found, until the chunk
    holds CHUNK4_TOKENS token bytes. (Recording them all and writing the
    tokens in a second pass cost levels 0-1 15% of their time, levels 2-3
    6-8%.) }
  FAST_PREFIX4  = 8192;
  CHUNK4_TOKENS = 131072;
  { the update for such a chunk counts each of those sequences as this
    many: the chunk goes on for about that many times as many }
  OPEN4_SCALE   = CHUNK4_TOKENS div FAST_PREFIX4;
  { A recorded sequence: three u16, literals, match length, distance - 1;
    literals = REC4_ESC: the lengths follow as two u32 (and 4 unused
    bytes), REC4_LONG records in all. }
  REC4_ESC  = $FFFF;
  REC4_LONG = 3;

type
  { The codes of a token table by cell, [kind, row, column]; sylzc.c reads
    it in this layout. 255 = no code, except in the cells every table has
    (FixedCell4), which are not asked: one of them holds code 255. Row
    ROW4_EXT: column 0 the literal-only escape, a match length the escape
    for a long run and that match; column COL4_EXT: the match extended,
    after the row's literals. }
  TCodes4 = array[0..1, 0..ROW4_EXT, 0..COL4_EXT] of Byte;
  TTable4 = array[0..255] of UInt32;
  { each code's cell, as an index into TCodes4 }
  TCells4 = array[0..255] of UInt16;
  { what a chunk's sequences look up, by cell (PairOf4) }
  TPairCounts4 = array[0..1, 0..ROWS4 - 1, 0..COLS4 - 1] of UInt32;

type
  { The control stream is written straight into dst (after the header);
    literals go to a scratch buffer and are appended when the block ends. }
  TEmit = record
    dst, ctrl, oend: PByte;
    lits, lit: PByte;
    srcEnd: PByte;    { end of the input: bounds the wide literal reads }
    entropy: Boolean; { finish as format v3 when that is smaller }
    v4: Boolean;      { format v4: ctrl holds tokens only, offsets go to offs }
    offs, off: PByte;
    rep: SizeInt;     { v4: the previous sequence's distance }
    { v4: the sequences not yet written as tokens (PutRec4); the distance
      before them; the table after the last chunk's update, its codes and
      a count of the chunks, for the optimal parser's prices }
    recs, rec, recEnd: PUInt16;
    tokRep: SizeInt;
    table: TTable4;
    codes: TCodes4;
    cells: TCells4;
    codesGen: SizeInt;
    ctrl2: SizeInt;   { v4: the last chunk's sequences as format v2's control
                        stream, in bytes; -1: not counted, or not possible }
    whole: Boolean;   { v4: the chunk to write is the whole block }
    lay2: Boolean;    { v4: the block goes out in format v2's layout }
    { v4, levels 0..3 (prefix > 0): that many sequences are recorded, then
      (direct) the next ones go as tokens into the chunk at head, whose
      tokens start at body (after its update), until they reach tokEnd }
    prefix: SizeInt;
    direct: Boolean;
    head, body, tokEnd: PByte;
    { v4: the compressor counts what each sequence looks up as it records
      it (levels 4-8 in C), into cnt: FlushChunk4 then takes those }
    counted: Boolean;
    cnt: TPairCounts4;
    roomy: Boolean;   { dst holds SylzBound(n): no sequence can run out of room }
    failed: Boolean;  { a flush called from C found no room }
  end;
  PEmit = ^TEmit;

const
  { Ext2's "format v2 has no such match": more than the extension bytes
    of a chunk that is counted as format v2 (EXT2_SEQS sequences at most),
    and CHUNK4_SEQS times it is under 2^32 }
  EXT2_NONE = 1 shl 14;
  EXT2_SEQS = 1 shl 14;

var
  { the extension bytes format v2 takes for (literals, match), in the
    lengths one v4 token holds }
  Ext2: array[0..MAX_LL4, 0..MAX_ML4] of UInt16;
  { SYLZ_TOKENS4's codes and cells, and which of its codes are of cells
    every table has (they never change) }
  Codes4: TCodes4;
  Cells4: TCells4;
  Fixed4: array[0..255] of Boolean;
  { each cell's table entry, with CELL4_KEPT on the cells a chunk's update
    leaves alone (those every table has, and those the encoder has no use
    for) and CELL4_SHORT on the matches under SYLZ_MINMATCH at the
    previous offset }
  CellInfo4: array[0..NCELLS4 - 1] of UInt32;

procedure EmitInit(out e: TEmit; dst: PByte; cap: SizeInt; scratch, srcEnd: PByte;
  flags: Integer; offs: PByte; recs: PUInt16);
begin
  e.v4 := flags and SYLZ_V4 <> 0;
  e.offs := offs;
  e.off := offs;
  e.rep := 1;
  e.recs := recs;
  e.rec := recs;
  e.recEnd := recs + 3 * (CHUNK4_SEQS - REC4_LONG);
  e.roomy := False;
  e.tokRep := 1;
  e.codesGen := 0;
  e.ctrl2 := -1;
  e.whole := False;
  e.lay2 := False;
  e.prefix := 0;
  e.direct := False;
  e.head := nil;
  e.body := nil;
  e.counted := False;
  e.tokEnd := nil;
  e.failed := False;
  e.srcEnd := srcEnd;
  e.entropy := flags and SYLZ_ENTROPY <> 0;
  e.dst := dst;
  e.ctrl := dst + HEADER_SIZE;
  e.oend := dst + cap;
  e.lits := scratch;
  e.lit := scratch;
  if e.v4 then
  begin
    e.table := SYLZ_TOKENS4;
    e.codes := Codes4;
    e.cells := Cells4;
  end;
end;

var
  { exact code of each (literals, match - 4) pair, 255 = none; built from
    SYLZ_TOKENS at unit initialization }
  ExactCode: array[0..EXACT_LL, 0..EXACT_M] of Byte;

procedure BuildExactCodes;
var
  code: Integer;
  e: UInt32;
begin
  FillChar(ExactCode, SizeOf(ExactCode), 255);
  for code := 0 to 255 do
  begin
    e := SYLZ_TOKENS[code];
    if e and (SYLZ_TOK_LLEXT or SYLZ_TOK_MLEXT) = 0 then
      ExactCode[e and $FF, ((e shr 8) and $FF) - SYLZ_MINMATCH] := Byte(code)
    else if not (((code >= ESC_ML) and (code < ESC_ML + EXACT_LL + 1)
                  and (e = UInt32(code - ESC_ML) or (SYLZ_MINMATCH shl 8) or SYLZ_TOK_MLEXT))
              or ((code >= ESC_LL) and (code < ESC_LL + EXACT_M + 1)
                  and (e = UInt32(code - ESC_LL + SYLZ_MINMATCH) shl 8 or SYLZ_TOK_LLEXT))
              or ((code = ESC_BOTH)
                  and (e = (SYLZ_MINMATCH shl 8) or SYLZ_TOK_LLEXT or SYLZ_TOK_MLEXT))) then
      RunError(201);   { SYLZ_TOKENS doesn't have the escapes where the encoder puts them }
  end;
end;

procedure PutExt(var p: PByte; v: SizeInt); inline;
begin
  while v >= 255 do
  begin
    p^ := 255;
    Inc(p);
    Dec(v, 255);
  end;
  p^ := Byte(v);
  Inc(p);
end;

{ The extension bytes of a sequence in format v2's control stream. }
function Ctrl2Ext(ll, ml: SizeInt): SizeInt;
var
  m: SizeInt;
begin
  m := ml - SYLZ_MINMATCH;
  if ll <= EXACT_LL then
  begin
    if m > EXACT_M then
      Result := m div 255 + 1
    else
      Result := Ord(ExactCode[ll, m] = 255);
  end
  else if m <= EXACT_M then
    Result := ll div 255 + 1
  else
    Result := ll div 255 + m div 255 + 2;
end;

{ A sequence as format v2 has it (EmitSequence), at p. }
procedure PutSeq2(var p: PByte; ll, ml, dist: SizeInt);
var
  m, code: SizeInt;
  q: PByte;
begin
  m := ml - SYLZ_MINMATCH;
  p[1] := Byte(dist - 1);
  p[2] := Byte((dist - 1) shr 8);
  q := p + 3;
  code := 255;
  if (ll <= EXACT_LL) and (m <= EXACT_M) then
    code := ExactCode[ll, m];
  if code <> 255 then
    p[0] := Byte(code)
  else if ll <= EXACT_LL then
  begin
    p[0] := Byte(ESC_ML + ll);
    PutExt(q, m);
  end
  else if m <= EXACT_M then
  begin
    p[0] := Byte(ESC_LL + m);
    PutExt(q, ll);
  end
  else
  begin
    p[0] := ESC_BOTH;
    PutExt(q, ll);
    PutExt(q, m);
  end;
  p := q;
end;

{ Whether the encoder falls back on the code of this cell (kind, row:
  literals 0..MAX_LL4 or ROW4_EXT, col: match 0..MAX_ML4 or COL4_EXT), so
  that every table must have it: the matches with no literals (and their
  escapes), the literal-only tokens (and theirs), and the escape for a
  long run and a 4-byte match at a new offset (SylzBound). }
function FixedCell4(k, row, col: SizeInt): Boolean; inline;
begin
  Result := (row = 0) or ((k = 1) and (col = 0))
    or ((k = 0) and (row = ROW4_EXT) and (col = SYLZ_MINMATCH));
end;

{ Whether the encoder has a use for the cell: a match of its kind's
  shortest length or more, or literals only (some, at the previous
  offset). }
function ValidCell4(k, row, col: SizeInt): Boolean; inline;
begin
  if col = 0 then
    Result := (k = 1) and (row <> 0)
  else
    Result := col >= MINML4[k];
end;

{ The cell of a table entry: false when the encoder has no use for it. }
function CellOf4(e: UInt32; out k, row, col: SizeInt): Boolean;
begin
  k := Ord(e and SYLZ_TOK4_OFF = 0);
  row := e and $FF;
  col := (e shr 8) and $FF;
  Result := (row <= MAX_LL4) and (col <= MAX_ML4);
  if e and SYLZ_TOK4_LLEXT <> 0 then
  begin
    Result := Result and (row = 0);
    row := ROW4_EXT;
  end;
  if e and SYLZ_TOK4_MLEXT <> 0 then
  begin
    Result := Result and (col = MINML4[k]);
    col := COL4_EXT;
  end;
  Result := Result and ValidCell4(k, row, col);
end;

{ The entry of a cell. }
function EntryOf4(k, row, col: SizeInt): UInt32;
begin
  Result := 0;
  if k = 0 then
    Result := SYLZ_TOK4_OFF;
  if row = ROW4_EXT then
    Result := Result or SYLZ_TOK4_LLEXT
  else
    Result := Result or UInt32(row);
  if col = COL4_EXT then
    Result := Result or SYLZ_TOK4_MLEXT or (UInt32(MINML4[k]) shl 8)
  else
    Result := Result or (UInt32(col) shl 8);
end;

{ The codes of a table an encoder can use, or false: no entry twice, a
  code for every cell the encoder falls back on (FixedCell4), and code
  255, "none" in c, on an escape the encoder takes without asking: the
  literal-only one or a match's with no literals. }
function BuildCodes4(const t: TTable4; out c: TCodes4): Boolean;
var
  code: Integer;
  k, row, col: SizeInt;
begin
  Result := False;
  FillChar(c, SizeOf(c), 255);
  for code := 0 to 254 do
  begin
    if not CellOf4(t[code], k, row, col) or (c[k, row, col] <> 255) then
      Exit;
    c[k, row, col] := Byte(code);
  end;
  if not CellOf4(t[255], k, row, col) or (c[k, row, col] <> 255)
     or not (((row = 0) and (col = COL4_EXT)) or ((row = ROW4_EXT) and (col = 0))) then
    Exit;
  { every fixed cell but code 255's has its code by now }
  for k := 0 to 1 do
    for row := 0 to ROW4_EXT do
      for col := 0 to COL4_EXT do
        if FixedCell4(k, row, col) and ValidCell4(k, row, col)
           and (c[k, row, col] = 255) and (t[255] <> EntryOf4(k, row, col)) then
          Exit;
  Result := True;
end;

{ SYLZ_TOKENS4 as the encoder uses it. }
procedure InitTable4;
var
  code: Integer;
  k, row, col: SizeInt;
  e: UInt32;
begin
  if not BuildCodes4(SYLZ_TOKENS4, Codes4) then
    RunError(201);
  for row := 0 to MAX_LL4 do
    for col := 0 to MAX_ML4 do
      if col < SYLZ_MINMATCH then
        Ext2[row, col] := EXT2_NONE
      else
        Ext2[row, col] := UInt16(Ctrl2Ext(row, col));
  for code := 0 to 255 do
  begin
    CellOf4(SYLZ_TOKENS4[code], k, row, col);
    Cells4[code] := UInt16((k * ROWS4 + row) * COLS4 + col);
    Fixed4[code] := FixedCell4(k, row, col);
  end;
  for k := 0 to 1 do
    for row := 0 to ROW4_EXT do
      for col := 0 to COL4_EXT do
      begin
        e := EntryOf4(k, row, col);
        if FixedCell4(k, row, col) or not ValidCell4(k, row, col) then
          e := e or CELL4_KEPT
        else if (k = 1) and (col < SYLZ_MINMATCH) and (row <= MAX_LL4) then
          e := e or CELL4_SHORT;
        CellInfo4[(k * ROWS4 + row) * COLS4 + col] := e;
      end;
end;

{ A table entry as the block stores it, and back; false: not an entry. }
function PackEntry4(e: UInt32): UInt16;
begin
  Result := UInt16(e and $FF) or UInt16(((e shr 8) and $FF) shl 5);
  if e and SYLZ_TOK4_LLEXT <> 0 then
    Result := (Result and not UInt16($1F)) or TAB4_EXT;
  if e and SYLZ_TOK4_MLEXT <> 0 then
    Result := (Result and not UInt16($7E0)) or (TAB4_EXT_ML shl 5);
  if e and SYLZ_TOK4_OFF = 0 then
    Result := Result or TAB4_REP;
end;

function UnpackEntry4(v: UInt16; out e: UInt32): Boolean;
var
  ll, ml: UInt32;
begin
  ll := v and $1F;
  ml := (v shr 5) and $3F;
  e := 0;
  if v and TAB4_REP = 0 then
    e := SYLZ_TOK4_OFF;
  if ll = TAB4_EXT then
    e := e or SYLZ_TOK4_LLEXT
  else
    e := e or ll;
  if ml = TAB4_EXT_ML then
  begin
    if v and TAB4_REP = 0 then
      e := e or SYLZ_TOK4_MLEXT or (SYLZ_MINMATCH shl 8)
    else
      e := e or SYLZ_TOK4_MLEXT or (SYLZ_MINREP shl 8);
  end
  else
    e := e or (ml shl 8);
  { what the decoder's copies allow: 16 literals and a 32-byte match
    without an extension }
  Result := (v shr 12 = 0) and ((ll <= MAX_LL4) or (ll = TAB4_EXT))
    and ((ml <= MAX_ML4) or (ml = TAB4_EXT_ML));
end;

{ How a sequence of kind k that is not one token is split into plain
  tokens, when a split with a code exists: of ll literals (up to
  LIT_SPLIT4) b stay with the match and the others go in a literal-only
  token before it; of a match of ml (up to ML_SPLIT4) m bytes are in that
  token and the rest in one at the previous offset. Tried first: MAX_LL4
  literals on their own and the longest first part; then the other splits
  of the literals; then the shorter first parts. False: no split has a
  code (b and m are then the first tried). }
function FindSplit4(const c: TCodes4; k, ll, ml: SizeInt; out b, m: SizeInt): Boolean;
var
  bMax, mMin, i: SizeInt;
begin
  b := ll;
  bMax := ll;
  if ll > MAX_LL4 then
  begin
    b := ll - MAX_LL4;
    bMax := MAX_LL4;
  end;
  m := ml;
  mMin := ml;
  if ml > MAX_ML4 then
  begin
    { no part under its kind's shortest match, none over MAX_ML4 }
    m := MAX_ML4;
    if ml - m < SYLZ_MINREP then
      m := ml - SYLZ_MINREP;
    mMin := ml - MAX_ML4;
    if mMin < MINML4[k] then
      mMin := MINML4[k];
  end;
  if c[k, b, m] <> 255 then
    Exit(True);
  for i := b + 1 to bMax do
    if c[k, i, m] <> 255 then
    begin
      b := i;
      Exit(True);
    end;
  for i := m - 1 downto mMin do
    if c[k, b, i] <> 255 then
    begin
      m := i;
      Exit(True);
    end;
  Result := False;
end;

{ What PutTokens4 looks up in table c for a sequence of kind k: the cell
  (row: the literals its match's token carries, ROW4_EXT for a run over
  LIT_SPLIT4; col: the match length, COL4_EXT for one over ML_SPLIT4, or
  over MAX_ML4 after such a run); false when it only takes codes every
  table has. The chunks' table updates are made from the counts of these;
  a sequence that is split counts the cell its split takes, which keeps
  that code in the table. }
function PairOf4(const c: TCodes4; k, ll, ml: SizeInt; out row, col: SizeInt): Boolean; inline;
begin
  Result := True;
  col := ml;
  row := ll;
  if ll > LIT_SPLIT4 then
  begin
    row := ROW4_EXT;
    if ml > MAX_ML4 then
      col := COL4_EXT;
    Exit;
  end;
  if ml > ML_SPLIT4 then
  begin
    if ll > MAX_LL4 then
      Dec(row, MAX_LL4);
    col := COL4_EXT;
    Exit(row <> 0);
  end;
  if (ll > MAX_LL4) or (ml > MAX_ML4) then
  begin
    if (ll > MAX_LL4) and (k = 0) and (ml = SYLZ_MINMATCH) then
      Exit(False);
    FindSplit4(c, k, ll, ml, row, col);
  end;
end;

{ The tokens of one sequence (ll literals, a match of ml, kind k) at p;
  returns where they end. }
function PutTokens4(const c: TCodes4; p: PByte; k, ll, ml: SizeInt): PByte;
var
  b, m: SizeInt;
begin
  if (ll <= MAX_LL4) and (ml <= MAX_ML4) and (c[k, ll, ml] <> 255) then
  begin
    p^ := c[k, ll, ml];
    Exit(p + 1);
  end;
  if ll > LIT_SPLIT4 then
  begin
    { a long run: with its match in one token and its extensions, where
      the table has that code }
    if ml <= MAX_ML4 then
    begin
      if c[k, ROW4_EXT, ml] <> 255 then
      begin
        p^ := c[k, ROW4_EXT, ml];
        Inc(p);
        PutExt(p, ll);
        Exit(p);
      end;
    end
    else if c[k, ROW4_EXT, COL4_EXT] <> 255 then
    begin
      p^ := c[k, ROW4_EXT, COL4_EXT];
      Inc(p);
      PutExt(p, ll);
      PutExt(p, ml - MINML4[k]);
      Exit(p);
    end;
    p^ := c[1, ROW4_EXT, 0];
    Inc(p);
    PutExt(p, ll);
    ll := 0;
  end
  else if (ll > MAX_LL4) and (k = 0) and (ml = SYLZ_MINMATCH) then
  begin
    { a 4-byte match at a new offset takes the run's escape, which every
      table has, from MAX_LL4 literals on: split, it could cost more
      bytes than it saves, and SylzBound would not hold }
    p^ := c[0, ROW4_EXT, SYLZ_MINMATCH];
    Inc(p);
    PutExt(p, ll);
    Exit(p);
  end;
  if ml > ML_SPLIT4 then
  begin
    if ll > MAX_LL4 then
    begin
      p^ := c[1, MAX_LL4, 0];
      Inc(p);
      Dec(ll, MAX_LL4);
    end;
    { the literals in the escape's token, or in one of their own before it }
    if (ll > 0) and (c[k, ll, COL4_EXT] = 255) then
    begin
      p^ := c[1, ll, 0];
      Inc(p);
      ll := 0;
    end;
    p^ := c[k, ll, COL4_EXT];
    Inc(p);
    PutExt(p, ml - MINML4[k]);
    Exit(p);
  end;
  { plain tokens: the literals the match's token does not take, in one or
    two of their own before it; what is left of a match over MAX_ML4, in a
    token at the previous offset (this match's) after it }
  if not FindSplit4(c, k, ll, ml, b, m) then
    b := 0;
  Dec(ll, b);
  if ll > MAX_LL4 then
  begin
    p^ := c[1, MAX_LL4, 0];
    Inc(p);
    Dec(ll, MAX_LL4);
  end;
  if ll > 0 then
  begin
    p^ := c[1, ll, 0];
    Inc(p);
  end;
  p^ := c[k, b, m];
  Inc(p);
  if ml > m then
  begin
    p^ := c[1, 0, ml - m];
    Inc(p);
  end;
  Result := p;
end;

{ The token bytes of a sequence that is not one token, apart from the one
  token and the one more it takes when the cell PairOf4 gives has no
  code: what no table changes. }
function Extra4(k, ll, ml: SizeInt): SizeInt;
begin
  if ll > LIT_SPLIT4 then
  begin
    Result := ll div 255 + 1;
    if ml > MAX_ML4 then
      Inc(Result, (ml - MINML4[k]) div 255 + 1);
  end
  else if ml > ML_SPLIT4 then
    Result := (ml - MINML4[k]) div 255 + 1 + Ord(ll > MAX_LL4)
  else if (ll > MAX_LL4) and (k = 0) and (ml = SYLZ_MINMATCH) then
    Result := 1
  else
    Result := Ord(ll > MAX_LL4) + Ord(ml > MAX_ML4);
end;

const
  COUNT4_MAX = $FFFFF;    { a sort key's count: 20 bits over 12 of cell or code }

type
  TUpdate4 = array[0..UPDATE4_MAX - 1] of Byte;

{ v[0..n) in descending order (Shell sort: a few hundred keys at most). }
procedure SortDown4(v: PUInt32; n: SizeInt);
var
  gap, i, j: SizeInt;
  x: UInt32;
begin
  gap := n div 2;
  while gap > 0 do
  begin
    for i := gap to n - 1 do
    begin
      x := v[i];
      j := i;
      while (j >= gap) and (v[j - gap] < x) do
      begin
        v[j] := v[j - gap];
        Dec(j, gap);
      end;
      v[j] := x;
    end;
    gap := gap div 2;
  end;
end;

{ The table t (its codes in c, its cells in cells) changed for the chunk
  whose lookups cnt counts, one sequence in sample: the cells asked for
  most take the codes of the cells asked for least, while that saves more
  token bytes than the UPDATE4_BYTES a replacement costs, and at most
  maxRepl of them; the codes the encoder falls back on stay. A match
  under SYLZ_MINMATCH at the previous offset gets a code whatever it
  saves, and keeps it while the chunk uses it: the optimal parser chose it
  for the price of one token (SylzBound). Returns how many codes changed,
  listed in repl; ties go to the lower cell (kind, row, column) and the
  lower code. miss: the lookups counted that find no code afterwards. }
function UpdateTable4(const cnt: TPairCounts4; sample, maxRepl: SizeInt;
  var t: TTable4; var c: TCodes4; var cells: TCells4; out repl: TUpdate4;
  out miss: SizeInt): SizeInt;
var
  add: array[0..NCELLS4 - 1] of UInt32;   { count shl 12 or (4095 - cell) }
  del: array[0..255] of UInt32;          { (COUNT4_MAX - count) shl 12 or (255 - code) }
  free: array[0..255] of Byte;           { codes of cells not asked for, ascending }
  cf: PUInt32;
  pc: PByte;
  na, nd, nf, code, i, cell: SizeInt;
  v, a, d, least, info: UInt32;
begin
  cf := @cnt[0, 0, 0];
  pc := @c[0, 0, 0];
  { what one more code must be asked for to pay for itself, at best }
  least := UInt32((UPDATE4_BYTES + sample + sample - 1) div sample);
  na := 0;
  miss := 0;
  for cell := 0 to NCELLS4 - 1 do
  begin
    v := cf[cell];
    if (v = 0) or (pc[cell] <> 255) then
      Continue;
    { (the cell with code 255 is one of those kept; a sampled record's
      stray count can fall on a cell of no use) }
    info := CellInfo4[cell];
    if info and CELL4_KEPT <> 0 then
      Continue;
    Inc(miss, v);
    if info and CELL4_SHORT <> 0 then
      v := COUNT4_MAX
    else if v < least then
      Continue
    else if v > COUNT4_MAX - 1 then
      v := COUNT4_MAX - 1;
    add[na] := (v shl 12) or UInt32(4095 - cell);
    Inc(na);
  end;
  if na = 0 then
    Exit(0);
  { the codes that can go: first those of cells not asked for at all, in
    code order, then the others from the least asked for }
  nd := 0;
  nf := 0;
  for code := 0 to 254 do
  begin
    if Fixed4[code] then
      Continue;
    v := cf[cells[code]];
    if v = 0 then
    begin
      free[nf] := Byte(code);
      Inc(nf);
    end
    else if CellInfo4[cells[code]] and CELL4_SHORT = 0 then
    begin
      if v > COUNT4_MAX then
        v := COUNT4_MAX;
      del[nd] := ((COUNT4_MAX - v) shl 12) or UInt32(255 - code);
      Inc(nd);
    end;
  end;
  SortDown4(@add[0], na);
  if na > nf then
    SortDown4(@del[0], nd);
  if na > nf + nd then
    na := nf + nd;
  Result := 0;
  for i := 0 to na - 1 do
  begin
    a := add[i] shr 12;
    if i < nf then
    begin
      d := 0;
      code := free[i];
    end
    else
    begin
      d := COUNT4_MAX - (del[i - nf] shr 12);
      code := 255 - SizeInt(del[i - nf] and 255);
    end;
    if a <> COUNT4_MAX then
    begin
      { the first replacement also pays the byte of their count; a
        sampled count has to say more than the same }
      if (Result >= maxRepl) or (a <= d)
         or (SizeInt(a - d) * sample < UPDATE4_BYTES + sample + Ord(Result = 0)) then
        Break;
    end;
    pc[cells[code]] := 255;
    cell := 4095 - SizeInt(add[i] and 4095);
    Inc(miss, SizeInt(d) - SizeInt(cf[cell]));
    cells[code] := UInt16(cell);
    pc[cell] := Byte(code);
    t[code] := CellInfo4[cell] and CELL4_ENTRY;
    repl[Result] := Byte(code);
    Inc(Result);
  end;
end;

{ The record at r: its lengths and distance; r moves past it. }
procedure GetRec4(var r: PUInt16; out ll, ml, dist: SizeInt); inline;
begin
  ll := r[0];
  ml := r[1];
  dist := SizeInt(r[2]) + 1;
  Inc(r, 3);
  if ll = REC4_ESC then
  begin
    ll := PUInt32(r)^;
    ml := PUInt32(r + 2)^;
    Inc(r, 6);
  end;
end;

type
  { what CountAll4 adds up besides the counts }
  TSums4 = record
    seqs, reps, x4: SizeInt;   { sequences, those at the previous offset, Extra4 }
    x2: UInt32;                { format v2's extension bytes (EXT2_NONE: no v2) }
  end;

{ CountAll4's sequences that are not one token: the cell counted (into
  cf), and in the result Extra4 (high 32 bits) and what format v2 adds
  for it (low 32 bits: EXT2_NONE for a match it does not have). }
function CountSplit4(const codes: TCodes4; cf: PUInt32; k, ll, ml: SizeInt): UInt64;
var
  row, col: SizeInt;
begin
  if PairOf4(codes, k, ll, ml, row, col) then
    Inc(cf[(k * ROWS4 + row) * COLS4 + col]);
  if ml < SYLZ_MINMATCH then
    Result := EXT2_NONE
  else
    Result := UInt32(Ctrl2Ext(ll, ml));
  Inc(Result, UInt64(Extra4(k, ll, ml)) shl 32);
end;

{ The cells that the records r..rend look up, counted in cnt, and what
  the same sequences take in format v2 (3 bytes each and x2; a match
  under SYLZ_MINMATCH, which v2 does not have, adds EXT2_NONE) and in this
  one (a token each, Extra4, the offsets of the matches not at the
  previous offset). Its own routine, with the records read in place and
  nothing passed by reference inside the loop, so that its variables
  live in registers (with GetRec4 and the counts by reference FPC kept
  them in memory: 70 instructions a record at level 4, now about 20).
  Once x2 reaches EXT2_NONE only that it did counts. }
procedure CountAll4(r, rend: PUInt16; prev: SizeInt; const codes: TCodes4;
  var cnt: TPairCounts4; out sums: TSums4);
var
  ll, ml, dist, k, seqs, reps, x4: SizeInt;
  x2: UInt32;
  cf: PUInt32;
  e2: PUInt16;
  d: UInt64;
begin
  seqs := 0;
  reps := 0;
  x4 := 0;
  x2 := 0;
  cf := @cnt[0, 0, 0];
  e2 := @Ext2[0, 0];
  while r < rend do
  begin
    ll := r[0];
    ml := r[1];
    dist := SizeInt(r[2]) + 1;
    Inc(r, 3);
    if ll = REC4_ESC then
    begin
      ll := PUInt32(r)^;
      ml := PUInt32(r + 2)^;
      Inc(r, 6);
    end;
    k := Ord(dist = prev);
    prev := dist;
    if (ll <= MAX_LL4) and (ml <= MAX_ML4) then
    begin
      Inc(cf[(k * ROWS4 + ll) * COLS4 + ml]);
      Inc(x2, e2[ll * (MAX_ML4 + 1) + ml]);
    end
    else
    begin
      d := CountSplit4(codes, cf, k, ll, ml);
      Inc(x4, SizeInt(d shr 32));
      Inc(x2, UInt32(d));
    end;
    Inc(seqs);
    Inc(reps, k);
  end;
  sums.seqs := seqs;
  sums.reps := reps;
  sums.x4 := x4;
  sums.x2 := x2;
end;

{$ifdef SYLZ_C}
type
  { sylzc_put4 in sylzc.c: fixed field order }
  TPut4C = record
    rec, rend: PUInt16;
    p, off: PByte;             { in/out: token and offset write pointers }
    prev: SizeInt;             { in/out: the distance before the records }
    codes: Pointer;            { TCodes4 }
    memo: PByte;               { levels 0-3: the C loops' memo of split tokens, or nil }
  end;

  { sylzc_count4 in sylzc.c: fixed field order }
  TCount4C = record
    rec, rend: PUInt16;
    prev: SizeInt;             { the distance before the records }
    codes: Pointer;            { TCodes4 }
    cnt: PUInt32;              { TPairCounts4 }
  end;

procedure sylzc_put_chunk4(st: Pointer); cdecl; external name 'sylzc_put_chunk4';
procedure sylzc_count_chunk4(st: Pointer); cdecl; external name 'sylzc_count_chunk4';
{$endif}

{ The header of the chunk at e.head, whose tokens start at e.body (after
  its update) and end at e.ctrl: 2 bytes when the token bytes fit them,
  and all after it moves down into the 2 it leaves; else 4. After an open
  chunk (e.direct) the next sequences are recorded again, the first one
  after e.rep. False: more token bytes than a chunk holds. }
function CloseChunk4(var e: TEmit): Boolean;
var
  i: SizeInt;
  w: UInt32;
  head: PByte;
begin
  if e.direct then
    e.tokRep := e.rep;
  e.direct := False;
  head := e.head;
  i := e.ctrl - e.body;
  if i >= CHUNK4_MAX then
    Exit(False);
  w := (UInt32(i) shl 2) or UInt32(Ord(e.body > head + 4) * CHUNK4_UPDATE);
  if i < CHUNK4_SHORTMAX then
  begin
    Move(head[4], head[2], e.ctrl - (head + 4));
    Dec(e.ctrl, 2);
  end
  else
  begin
    w := w or CHUNK4_LONG;
    head[2] := Byte(w shr 16);
    head[3] := Byte(w shr 24);
  end;
  head[0] := Byte(w);
  head[1] := Byte(w shr 8);
  Result := True;
end;

{ The recorded sequences as a chunk of the token stream: its header, the
  table's update if replacing entries pays, its tokens; their offsets to
  the offset stream. False when dst has no room. With e.prefix (levels
  0..3) and not at the block's end (last), the chunk stays open: the
  sequences after these go into it as tokens (EmitDirect4) with the table
  as these leave it, and CloseChunk4 writes its header. }
function FlushChunk4(var e: TEmit; last: Boolean = False): Boolean;
var
  cnt: TPairCounts4;
  repl: TUpdate4;
  r, rend: PUInt16;
  head, p, limit, off: PByte;
  prev, k, row, col, ll, ml, dist, i, code, sample, nrepl, maxRepl, miss: SizeInt;
  sums: TSums4;
  w: UInt32;
  open: Boolean;
{$ifdef SYLZ_C}
  pc: TPut4C;
  cc: TCount4C;
{$endif}
begin
  Result := True;
  e.ctrl2 := -1;
  if e.rec = e.recs then
    Exit;
  rend := e.rec;
  e.rec := e.recs;
  { the sequences' cells are counted, all of them; the count of an open
    chunk's first FAST_PREFIX4 stands for the whole chunk (a chunk that
    ends within them, at the block's end, is counted as it is) }
  open := (e.prefix > 0) and not last;
  sample := 1;
  maxRepl := UPDATE4_MAX;
  i := (rend - e.recs) div 3;
  if open then
  begin
    { the chunk goes on after these for about OPEN4_SCALE times as many:
      each one counted stands for that many, so no more update than these
      sequences leave room for under SylzBound (4 bytes each, a byte in
      255, less the count's byte and the header). The margin is thin: a
      long record counts as 3 sequences here, and on x-ray an L0 block
      reached 82% of the bound's slack. Bytes added per sequence at levels
      0..3, or rep matches under 4 bytes there, would break the roomy
      paths of the asm and C, which skip room checks. }
    sample := OPEN4_SCALE;
    maxRepl := (i div 64 - 5) div UPDATE4_BYTES;
    if maxRepl < 0 then
      maxRepl := 0;
  end;
  FillChar(cnt, SizeOf(cnt), 0);
  r := e.recs;
  prev := e.tokRep;
  if e.counted and not e.whole then
    Move(e.cnt, cnt, SizeOf(cnt))   { counted as recorded; no v2 layout to weigh }
{$ifdef SYLZ_C}
  else if open and SylzUseAsm then
  begin
    { an open chunk wants only the count: in C (FPC's aarch64 code for
      CountAll4 took 1% of level 0 on GitHub's linux-arm64) }
    cc.rec := r;
    cc.rend := rend;
    cc.prev := prev;
    cc.codes := @e.codes;
    cc.cnt := @cnt[0, 0, 0];
    sylzc_count_chunk4(@cc);
  end
{$endif}
  else
  begin
    CountAll4(r, rend, prev, e.codes, cnt, sums);
    if not open and (sums.x2 < EXT2_NONE) and (sums.seqs <= EXT2_SEQS) then
      e.ctrl2 := 3 * sums.seqs + SizeInt(sums.x2);
  end;
  if e.counted then
    FillChar(e.cnt, SizeOf(e.cnt), 0);   { for the next chunk }
  nrepl := UpdateTable4(cnt, sample, maxRepl, e.table, e.codes, e.cells, repl, miss);
  if e.whole and (e.ctrl2 >= 0) then
  begin
    { The chunk is the whole block, and format v2's control stream for it
      is e.ctrl2 bytes. This format's tokens and offsets: a token for each
      sequence and one more where its cell has no code, Extra4, two offset
      bytes for each match not at the previous offset, the update. Where
      v2's is smaller the block goes out in v2's layout (EmitFinish) and
      the tokens are not written. }
    i := sums.seqs + sums.x4 + miss + 2 * (sums.seqs - sums.reps);
    if nrepl > 0 then
      Inc(i, 1 + UPDATE4_BYTES * nrepl);
    if e.ctrl2 < i then
    begin
      e.lay2 := True;
      Exit;
    end;
  end;
  { room: what is left of dst after the offsets and literals so far }
  limit := e.oend - (e.off - e.offs) - (e.lit - e.lits);
  head := e.ctrl;
  p := head + 4;
  if nrepl > 0 then
  begin
    if p + 1 + UPDATE4_BYTES * nrepl > limit then
      Exit(False);
    p^ := Byte(nrepl - 1);
    Inc(p);
    for i := 0 to nrepl - 1 do
    begin
      w := PackEntry4(e.table[repl[i]]);
      p[0] := repl[i];
      p[1] := Byte(w);
      p[2] := Byte(w shr 8);
      Inc(p, UPDATE4_BYTES);
    end;
    Inc(e.codesGen);
  end;
  e.head := head;
  e.body := p;
  r := e.recs;
  prev := e.tokRep;
  off := e.off;
{$ifdef SYLZ_C}
  if SylzUseAsm and e.roomy then
  begin
    pc.rec := r;
    pc.rend := rend;
    pc.p := p;
    pc.off := off;
    pc.prev := prev;
    pc.codes := @e.codes;
    { levels 0-3: the memo of the C loops (sylzc.c), 8 words past the
      records, cleared and filled here for the chunk's table }
    pc.memo := nil;
    if e.prefix > 0 then
      pc.memo := PByte(e.recs + 3 * FAST_PREFIX4 + 8);
    sylzc_put_chunk4(@pc);
    p := pc.p;
    off := pc.off;
    prev := pc.prev;
    r := rend;
  end;
{$endif}
  while r < rend do
  begin
    GetRec4(r, ll, ml, dist);
    k := Ord(dist = prev);
    prev := dist;
    { the tokens of a sequence, at most: 2 and a literal extension, 3 and
      the rest of a split match or a match extension; and its offset. An
      extension is a byte per 255, not per 256: with shr 8 a long run in a
      block of a few MiB wrote past cap. }
    if p + 8 + (ll + ml) div 255 + 2 > limit then
      Exit(False);
    code := 255;
    if (ll <= MAX_LL4) and (ml <= MAX_ML4) then
      code := e.codes[k, ll, ml];
    if code <> 255 then
    begin
      p^ := Byte(code);
      Inc(p);
    end
    else
      p := PutTokens4(e.codes, p, k, ll, ml);
    { written either way, kept if the sequence takes it }
    off[0] := Byte(dist - 1);
    off[1] := Byte((dist - 1) shr 8);
    Inc(off, 2 - 2 * k);
    Dec(limit, 2 - 2 * k);
  end;
  e.off := off;
  e.tokRep := prev;
  e.ctrl := p;
  if open then
  begin
    e.direct := True;
    e.tokEnd := e.body + CHUNK4_TOKENS;
  end
  else
    Result := CloseChunk4(e);
end;

{ One sequence into the open chunk (e.direct), as FlushChunk4 writes a
  recorded one, and its literals copied. }
function EmitDirect4(var e: TEmit; lit: PByte; litLen, dist, matchLen: SizeInt): Boolean;
var
  k, code: SizeInt;
begin
  k := Ord(dist = e.rep);
  { its tokens at most (see FlushChunk4), its offset, and every literal
    so far }
  if e.ctrl + 8 + (litLen + matchLen) div 255 + 2
     > e.oend - (e.off - e.offs) - (e.lit - e.lits) - litLen then
    Exit(False);
  code := 255;
  if (litLen <= MAX_LL4) and (matchLen <= MAX_ML4) then
    code := e.codes[k, litLen, matchLen];
  if code <> 255 then
  begin
    e.ctrl^ := Byte(code);
    Inc(e.ctrl);
  end
  else
    e.ctrl := PutTokens4(e.codes, e.ctrl, k, litLen, matchLen);
  e.off[0] := Byte(dist - 1);
  e.off[1] := Byte((dist - 1) shr 8);
  Inc(e.off, 2 - 2 * k);
  e.rep := dist;
  if (litLen <= 16) and (lit + 16 <= e.srcEnd) then
    Copy16(e.lit, lit)
  else
    Move(lit^, e.lit^, litLen);
  Inc(e.lit, litLen);
  Result := True;
end;

{ What a compressor that writes the sequences itself (assembler, C) calls
  when its records or its open chunk are full, with e as it left it: the
  open chunk is closed, or the records flushed. EmitSequence4 does the
  same. }
function TurnChunk4(var e: TEmit): Boolean;
begin
  if e.direct then
    Result := CloseChunk4(e)
  else
    Result := FlushChunk4(e);
end;

{ EmitSequence for format v4: the sequence is recorded, and its literals
  copied; FlushChunk4 writes the tokens and offsets of a chunk of
  sequences at a time (levels 0..3: a chunk's first sequences, and the
  ones after them go straight in, EmitDirect4). A match at the previous
  sequence's offset may be as short as SYLZ_MINREP. }
function EmitSequence4(var e: TEmit; lit: PByte; litLen, dist, matchLen: SizeInt): Boolean;
begin
  { a full chunk is closed and full records are flushed, which may leave
    their chunk open, until one of them takes the sequence }
  while True do
    if e.direct then
    begin
      if e.ctrl < e.tokEnd then
        Exit(EmitDirect4(e, lit, litLen, dist, matchLen));
      if not CloseChunk4(e) then
        Exit(False);
    end
    else if e.rec < e.recEnd then
      Break
    else if not FlushChunk4(e) then
      Exit(False);
  e.rec[2] := UInt16(dist - 1);
  if (litLen < REC4_ESC) and (matchLen <= $FFFF) then
  begin
    e.rec[0] := UInt16(litLen);
    e.rec[1] := UInt16(matchLen);
    Inc(e.rec, 3);
  end
  else
  begin
    e.rec[0] := REC4_ESC;
    e.rec[1] := 0;
    PUInt32(e.rec + 3)^ := UInt32(litLen);
    PUInt32(e.rec + 5)^ := UInt32(matchLen);
    Inc(e.rec, 3 * REC4_LONG);
  end;
  e.rep := dist;
  if (litLen <= 16) and (lit + 16 <= e.srcEnd) then
    Copy16(e.lit, lit)
  else
    Move(lit^, e.lit^, litLen);
  Inc(e.lit, litLen);
  Result := True;
end;

{ One sequence: litLen literals starting at lit, then a match. Returns false
  when the block would no longer fit in dst. }
{ Not inline on purpose: inlined, its locals and its Move call add to the
  compressor loop's register pressure, and that loop is the hotter one
  (measured: 273 -> 285 MB/s at level 1). }
function EmitSequence(var e: TEmit; lit: PByte; litLen, dist, matchLen: SizeInt): Boolean;
var
  l, m: SizeInt;
  p: PByte;
begin
  if e.v4 then
    Exit(EmitSequence4(e, lit, litLen, dist, matchLen));
  { control so far + this entry, worst case + all literals so far }
  if e.ctrl + 3 + litLen div 255 + 1 + matchLen div 255 + 1
     + (e.lit - e.lits) + litLen > e.oend then
    Exit(False);
  m := matchLen - SYLZ_MINMATCH;
  e.ctrl[1] := Byte(dist - 1);
  e.ctrl[2] := Byte((dist - 1) shr 8);
  p := e.ctrl + 3;
  l := 255;
  if (litLen <= EXACT_LL) and (m <= EXACT_M) then
    l := ExactCode[litLen, m];
  if l <> 255 then
    e.ctrl[0] := Byte(l)
  else if litLen <= EXACT_LL then
  begin
    e.ctrl[0] := Byte(ESC_ML + litLen);
    PutExt(p, m);
  end
  else if m <= EXACT_M then
  begin
    e.ctrl[0] := Byte(ESC_LL + m);
    PutExt(p, litLen);
  end
  else
  begin
    e.ctrl[0] := ESC_BOTH;
    PutExt(p, litLen);
    PutExt(p, m);
  end;
  e.ctrl := p;
  { the scratch buffer has SCRATCH_SLACK spare bytes }
  if (litLen <= 16) and (lit + 16 <= e.srcEnd) then
    Copy16(e.lit, lit)
  else
    Move(lit^, e.lit^, litLen);
  Inc(e.lit, litLen);
  Result := True;
end;

{ Appends the block's tail literals and the literal stream; returns the
  block size or -1. }
{ The block's literals as format v3 chunks at p, in no more than cap
  bytes. Returns the section size, or -1 if it does not fit. (Until syc
  0.2.13 cap was the v2 layout's size, and a chunk needed room for its raw
  form there: a block with one chunk never became v3.) Format v5's
  chunks (eight: true) have eight streams. }
function EncodeLiteralChunks(lits: PByte; count: SizeInt; p: PByte; cap: SizeInt;
  eight: Boolean): SizeInt;
var
  pos, c, r, used: SizeInt;
begin
  if cap < 4 then
    Exit(-1);
  PUInt32(p)^ := UInt32(count);
  used := 4;
  pos := 0;
  while pos < count do
  begin
    c := count - pos;
    if c > LIT_CHUNK then
      c := LIT_CHUNK;
    if eight then
      r := HufEncodeChunk8(lits + pos, c, p + used, cap - used)
    else
      r := HufEncodeChunk(lits + pos, c, p + used, cap - used);
    if r < 0 then
      Exit(-1);
    Inc(used, r);
    Inc(pos, c);
  end;
  Result := used;
end;

{ The block's last sequences leave it while a sequence costs as much as
  its match saves: after a long run of literals its extension is paid for
  that match alone, and without the sequence the run is part of the tail,
  which costs nothing (one 4-byte match after a megabyte of literals:
  4 KiB). lit and litLen: the tail, which takes their bytes. }
procedure DropTail4(var e: TEmit; var lit: PByte; var litLen: SizeInt);
var
  r, last: PUInt16;
  ll, ml, dist, prev, k: SizeInt;

  { whether a long record may end at q: only from the first one on can
    that be told }
  function LongBefore(q: PUInt16): Boolean;
  begin
    Result := (q - e.recs >= 3 * REC4_LONG) and ((q - 3 * REC4_LONG)^ = REC4_ESC);
  end;

begin
  while e.rec > e.recs do
  begin
    { the last record, and the distance before it }
    last := e.rec - 3;
    prev := e.tokRep;
    if LongBefore(e.rec) or ((last > e.recs) and LongBefore(last)) then
    begin
      r := e.recs;
      while r < e.rec do
      begin
        if r > e.recs then
          prev := dist;
        last := r;
        GetRec4(r, ll, ml, dist);
      end;
    end
    else if last > e.recs then
      prev := SizeInt(last[-1]) + 1;
    r := last;
    GetRec4(r, ll, ml, dist);
    { at the least one token and the run's extension, and the offset at a
      new distance }
    k := 2;
    if dist = prev then
      k := 0;
    if (ll <= LIT_SPLIT4) or (ll div 255 + 2 + k < ml) then
      Break;
    e.rec := last;
    Dec(e.lit, ll);
    Dec(lit, ll + ml);
    Inc(litLen, ll + ml);
  end;
end;

{ Move for EmitFinish's copies into dst (from buffers that do not overlap
  it). FPC 3.2.2 has no Move of its own for aarch64: the generic one goes
  a byte at a time unless source and destination have the same alignment
  mod 8, which for the literals and offsets is chance (on GitHub's
  linux-arm64, silesia.tar: 8% of format v2's compression at level 0, 4%
  of v4's at level 2). Unaligned 8-byte moves are fine there. }
procedure CopyOut(src, dst: PByte; n: SizeInt);{$ifndef CPUAARCH64} inline;{$endif}
begin
{$ifdef CPUAARCH64}
  while n >= 16 do
  begin
    PUInt64(dst)^ := PUInt64(src)^;
    PUInt64(dst + 8)^ := PUInt64(src + 8)^;
    Inc(src, 16);
    Inc(dst, 16);
    Dec(n, 16);
  end;
  while n > 0 do
  begin
    dst^ := src^;
    Inc(src);
    Inc(dst);
    Dec(n);
  end;
{$else}
  Move(src^, dst^, n);
{$endif}
end;

function EmitFinish(var e: TEmit; lit: PByte; litLen: SizeInt): SizeInt;
var
  ctrlLen, litTotal, v3, offLen: SizeInt;
  hdr: UInt32;
  one: Boolean;
  r, rend: PUInt16;
  p: PByte;
  ll, ml, dist: SizeInt;
begin
  if e.v4 then
  begin
    { the token chunks, the offsets behind their count (none of either
      without a token), then the literals: raw, or v3's chunks when
      smaller }
    if e.failed then
      Exit(-1);
    if e.direct then
    begin
      { an open chunk: its sequences are written (DropTail4 is for
        records) }
      one := e.head = e.dst + HEADER_SIZE;
      rend := e.rec;
      if not CloseChunk4(e) then
        Exit(-1);
    end
    else
    begin
      one := e.ctrl = e.dst + HEADER_SIZE;   { no chunk before this one }
      DropTail4(e, lit, litLen);
      rend := e.rec;
      e.whole := one;
      if not FlushChunk4(e, True) then
        Exit(-1);
    end;
    litTotal := (e.lit - e.lits) + litLen;
    p := e.dst + HEADER_SIZE;
    if not e.lay2 then
    begin
      ctrlLen := e.ctrl - p;
      offLen := e.off - e.offs;
      hdr := HDR_V4;
      v3 := 0;   { the count's bytes }
      if one and (ctrlLen > 0) and (p^ and CHUNK4_LONG = 0)
         and (ctrlLen - 2 < 1 shl HDR4_BITS) then
      begin
        { one small chunk: what its header and the count say, in the
          block's header }
        if p^ and CHUNK4_UPDATE <> 0 then
          hdr := hdr or HDR4_UPDATE;
        Move(p[2], p^, ctrlLen - 2);
        Dec(ctrlLen, 2);
        Dec(e.ctrl, 2);
        hdr := hdr or HDR4_ONE or (UInt32(offLen shr 1) shl HDR4_BITS);
      end
      else if ctrlLen > 0 then
        repeat
          Inc(v3);
        until (offLen shr 1) shr (7 * v3) = 0;
      if ctrlLen > SizeInt(HDR_TOKMASK) then
        Exit(-1);
      hdr := hdr or UInt32(ctrlLen);
      { what FlushChunk4 could only estimate }
      e.lay2 := one and (e.ctrl2 >= 0) and (e.ctrl2 < ctrlLen + v3 + offLen);
    end;
    if e.lay2 then
    begin
      { The same sequences in format v2's layout, which is smaller here (a
        small block with few matches at the previous offset pays for this
        layout's missing codes and gets nothing back): every decoder takes
        each block by its header. }
      if p + e.ctrl2 + litTotal > e.oend then
        Exit(-1);
      r := e.recs;
      while r < rend do
      begin
        GetRec4(r, ll, ml, dist);
        PutSeq2(p, ll, ml, dist);
      end;
      e.ctrl := p;
    end
    else
    begin
      if e.ctrl + v3 + offLen + litTotal > e.oend then
        Exit(-1);
      if v3 > 0 then
      begin
        v3 := offLen shr 1;
        while v3 >= 128 do
        begin
          e.ctrl^ := Byte(v3) or 128;
          Inc(e.ctrl);
          v3 := v3 shr 7;
        end;
        e.ctrl^ := Byte(v3);
        Inc(e.ctrl);
      end;
      CopyOut(e.offs, e.ctrl, offLen);
      Inc(e.ctrl, offLen);
      PUInt32(e.dst)^ := hdr;
      if e.entropy and (litTotal > 0) then
      begin
        CopyOut(lit, e.lit, litLen);
        v3 := EncodeLiteralChunks(e.lits, litTotal, e.ctrl, e.oend - e.ctrl, True);
        if (v3 >= 0) and (v3 < litTotal) then
        begin
          PUInt32(e.dst)^ := hdr or HDR_ENTROPY;
          Exit(e.ctrl - e.dst + v3);
        end;
        CopyOut(e.lits, e.ctrl, litTotal);
        Exit(e.ctrl - e.dst + litTotal);
      end;
      { the tail straight from the input: incompressible data is all tail }
      CopyOut(e.lits, e.ctrl, e.lit - e.lits);
      CopyOut(lit, e.ctrl + (e.lit - e.lits), litLen);
      Exit(e.ctrl - e.dst + litTotal);
    end;
  end;
  ctrlLen := e.ctrl - (e.dst + HEADER_SIZE);
  litTotal := (e.lit - e.lits) + litLen;
  if e.ctrl + litTotal > e.oend then
    Exit(-1);
  if e.entropy and (litTotal > 0) then
  begin
    { all literals in the scratch stream (it holds n + slack bytes), then
      code them; only kept when smaller than the v2 layout }
    CopyOut(lit, e.lit, litLen);
    v3 := EncodeLiteralChunks(e.lits, litTotal, e.ctrl, e.oend - e.ctrl, False);
    if (v3 >= 0) and (v3 < litTotal) then
    begin
      PUInt32(e.dst)^ := UInt32(ctrlLen) or HDR_ENTROPY;
      Exit(HEADER_SIZE + ctrlLen + v3);
    end;
    PUInt32(e.dst)^ := UInt32(ctrlLen);
    CopyOut(e.lits, e.ctrl, litTotal);
    Exit(HEADER_SIZE + ctrlLen + litTotal);
  end;
  PUInt32(e.dst)^ := UInt32(ctrlLen);
  CopyOut(e.lits, e.ctrl, e.lit - e.lits);
  CopyOut(lit, e.ctrl + (e.lit - e.lits), litLen);
  Result := HEADER_SIZE + ctrlLen + litTotal;
end;

{ ── levels 0-1: greedy, single hash table, accelerating skip ────────────── }

{ The hot loops take raw, preallocated buffers and leave allocation to a
  wrapper: a try/finally or a managed local (dynamic array) gives a routine
  an exception frame built on fpc_setjmp, and with one the compressor loop
  kept nearly every local on the stack. }
{ The fast levels' hash tables keep only the low 16 bits of a position:
  the window is 64 KiB, so the distance to a candidate is the difference of
  low halves, mod 2^16, with 0 meaning 65536. An entry older than 64 KiB
  was useless anyway and now aliases to some position inside the window,
  which the 4-byte check sorts out. Half the memory: level 1's table is
  32 KiB and fits in L1. }
function FastDist(pos: SizeInt; stored: UInt16): SizeInt; inline;
begin
  Result := (UInt32(pos) - stored) and $FFFF;
  if Result = 0 then
    Result := 65536;
end;

function CompressFastCore(src: PByte; n: SizeInt; var e: TEmit; table: PUInt16;
  hashLog: Integer): SizeInt;
{ (written without labels/goto: the goto version kept more of its locals
  on the stack, 127 vs 104 references, and ran at 226 vs 273 MB/s) }
var
  ip, anchor, iend, mflimit, ref, fwd: PByte;
  h, fwdH: UInt32;
  len, probes, d: SizeInt;
begin
  anchor := src;
  iend := src + n;
  ref := src;   { only read after a successful probe; silences a warning }
  if n >= SEARCH_TAIL + 1 then
  begin
    mflimit := iend - SEARCH_TAIL;
    ip := src + 1;
    fwdH := HashFast(ip, hashLog);
    while True do
    begin
      { find a match; the probe step grows with the number of misses }
      fwd := ip;
      probes := 1 shl SKIP_STRENGTH;
      repeat
        h := fwdH;
        ip := fwd;
        Inc(fwd, probes shr SKIP_STRENGTH);
        Inc(probes);
        if fwd > mflimit then
          Break;
        d := FastDist(ip - src, table[h]);
        fwdH := HashFast(fwd, hashLog);
        table[h] := UInt16(ip - src);
        ref := ip - d;
      until (d <= ip - src) and (Read32(ref) = Read32(ip));
      if fwd > mflimit then
        Break;

      while (ip > anchor) and (ref > src) and (ip[-1] = ref[-1]) do
      begin
        Dec(ip);
        Dec(ref);
      end;

      { emit, then chain straight into a match at the next position: it
        needs no literals }
      repeat
        len := SYLZ_MINMATCH + CountMatch(ip + SYLZ_MINMATCH, ref + SYLZ_MINMATCH, iend);
        if not EmitSequence(e, anchor, ip - anchor, ip - ref, len) then
          Exit(-1);
        Inc(ip, len);
        anchor := ip;
        if ip > mflimit then
          Break;
        table[HashFast(ip - 2, hashLog)] := UInt16(ip - 2 - src);
        h := HashFast(ip, hashLog);
        d := FastDist(ip - src, table[h]);
        table[h] := UInt16(ip - src);
        ref := ip - d;
      until (d > ip - src) or (Read32(ref) <> Read32(ip));
      if ip > mflimit then
        Break;

      Inc(ip);
      fwdH := HashFast(ip, hashLog);
    end;
  end;
  Result := EmitFinish(e, anchor, iend - anchor);
end;

{ CompressFastCore for format v4: at each probe the previous sequence's
  offset is tried one byte on before the table's candidate (what zstd's
  fast levels do); such a match costs a token and no offset. Only the
  probes that step one byte try it (the first 64 after a match): further
  on, where the data has had no match for a while, it found next to
  nothing (0.01 points on silesia.tar, 0.04 on the mixed corpus) and cost
  a cache miss a probe. (That offset never reaches before the input: an
  earlier match used it.) }
function CompressFastCore4(src: PByte; n: SizeInt; var e: TEmit; table: PUInt16;
  hashLog: Integer): SizeInt;
var
  ip, anchor, iend, mflimit, ref, fwd: PByte;
  h, fwdH: UInt32;
  len, probes, d, rep: SizeInt;
begin
  anchor := src;
  iend := src + n;
  ref := src;
  rep := 1;
  if n >= SEARCH_TAIL + 1 then
  begin
    mflimit := iend - SEARCH_TAIL;
    ip := src + 1;
    fwdH := HashFast(ip, hashLog);
    while True do
    begin
      fwd := ip;
      probes := 1 shl SKIP_STRENGTH;
      while True do
      begin
        h := fwdH;
        ip := fwd;
        Inc(fwd, probes shr SKIP_STRENGTH);
        Inc(probes);
        if fwd > mflimit then
          Break;
        d := FastDist(ip - src, table[h]);
        fwdH := HashFast(fwd, hashLog);
        table[h] := UInt16(ip - src);
        if (probes <= 2 shl SKIP_STRENGTH) and (Read32(ip + 1 - rep) = Read32(ip + 1)) then
        begin
          Inc(ip);
          ref := ip - rep;
          Break;
        end;
        ref := ip - d;
        if (d <= ip - src) and (Read32(ref) = Read32(ip)) then
          Break;
      end;
      if fwd > mflimit then
        Break;

      while (ip > anchor) and (ref > src) and (ip[-1] = ref[-1]) do
      begin
        Dec(ip);
        Dec(ref);
      end;

      len := SYLZ_MINMATCH + CountMatch(ip + SYLZ_MINMATCH, ref + SYLZ_MINMATCH, iend);
      if not EmitSequence4(e, anchor, ip - anchor, ip - ref, len) then
        Exit(-1);
      rep := ip - ref;
      Inc(ip, len);
      anchor := ip;
      if ip > mflimit then
        Break;
      { the search goes on at the match's end }
      table[HashFast(ip - 2, hashLog)] := UInt16(ip - 2 - src);
      fwdH := HashFast(ip, hashLog);
    end;
  end;
  Result := EmitFinish(e, anchor, iend - anchor);
end;

{$ifdef SYLZ_ASM_X64}
type
  { In/out state of the assembler fast compressor; fixed field order. }
  TFastEncState = record
    src, iend, mflimit: PByte;   {  0,  8, 16: in }
    table: PUInt16;              { 24: in }
    ctrl, lit: PByte;            { 32, 40: in/out (control and literal write pointers) }
    anchor: PByte;               { 48: out (start of the tail literals) }
    exact: PByte;                { 56: in, ExactCode }
    hashShift: Int64;            { 64: in, 64 - hash table log }
  end;
  PFastEncState = ^TFastEncState;

{ CompressFastCore in x86_64 assembler, same algorithm and the same output
  byte for byte (tests check it). Only used when the output buffer holds
  SylzBound(n): that bound guarantees every sequence fits, so it skips the
  capacity checks of EmitSequence.
  Registers: r8 ip, r9 anchor, r10 src, r11 table (u16 entries), r13 iend,
  r14 control write pointer, r15 literal write pointer, rbx fwd, rbp probe
  count, esi hash of ip, edi hash of fwd, rax match candidate, cl the hash
  shift (set once: no reload per hash), r12/rdx scratch. The stack holds
  mflimit [rsp] (compared from memory, freeing r12), the hash shift, the
  exact-code map, the hash multiplier and the state. }
procedure CompressFastX64(st: PFastEncState); assembler; nostackframe;
asm
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  push rax                        { [rsp+32]: state }
  mov rcx, 889523592379
  push rcx                        { [rsp+24]: hash multiplier }
  push qword ptr [rax + 56]       { [rsp+16]: exact code map }
  push qword ptr [rax + 64]       { [rsp+8]: hash shift }
  push qword ptr [rax + 16]       { [rsp]: mflimit }
  mov rcx, [rsp + 8]              { cl = hash shift, for the whole routine }
  mov r10, [rax]
  mov r13, [rax + 8]
  mov r11, [rax + 24]
  mov r14, [rax + 32]
  mov r15, [rax + 40]
  mov r9, r10                     { anchor = src }
  lea r8, [r10 + 1]               { ip = src + 1 }
  mov rdx, [r8]
  shl rdx, 64 - 8 * FAST_HASH_BYTES
  imul rdx, [rsp + 24]
  shr rdx, cl
  mov edi, edx                    { fwdH = hash(ip) }

@search:
  mov rbx, r8                     { fwd = ip }
  mov ebp, 1 shl SKIP_STRENGTH    { probes; step = probes shr SKIP_STRENGTH }
@probe:
  mov esi, edi                    { h = fwdH }
  mov r8, rbx                     { ip = fwd }
  mov rdx, rbp
  shr rdx, SKIP_STRENGTH
  add rbx, rdx                    { fwd += step }
  add rbp, 1
  cmp rbx, [rsp]
  ja @last
  movzx eax, word ptr [r11 + rsi * 2]   { low 16 bits of the candidate's position }
  mov rdx, [rbx]
  shl rdx, 64 - 8 * FAST_HASH_BYTES
  imul rdx, [rsp + 24]
  shr rdx, cl
  mov edi, edx                    { fwdH = hash(fwd) }
  mov rdx, r8
  sub rdx, r10                    { pos = ip - src }
  mov [r11 + rsi * 2], dx         { table[h] = pos (low 16 bits) }
  sub edx, eax
  and edx, $FFFF                  { distance mod 2^16 ... }
  mov r12d, 65536
  test edx, edx
  cmovz edx, r12d                 { ... with 0 meaning 65536 }
  mov rax, r8
  sub rax, rdx                    { ref = ip - distance }
  cmp rax, r10
  jb @probe                       { before the start of the input }
  mov edx, [rax]
  cmp edx, [r8]
  jne @probe

@back:
  { extend the match backwards over the pending literals }
  cmp r8, r9
  jbe @emit
  cmp rax, r10
  jbe @emit
  movzx edx, byte ptr [r8 - 1]
  cmp dl, [rax - 1]
  jne @emit
  sub r8, 1
  sub rax, 1
  jmp @back

@emit:
  { match end -> r12 }
  lea r12, [r8 + SYLZ_MINMATCH]
  lea rdx, [rax + SYLZ_MINMATCH]
@cm8:
  lea rsi, [r12 + 8]
  cmp rsi, r13
  ja @cmTail
  mov rsi, [r12]
  xor rsi, [rdx]
  jnz @cmDiff
  add r12, 8
  add rdx, 8
  jmp @cm8
@cmDiff:
  bsf rsi, rsi
  shr esi, 3
  add r12, rsi
  jmp @cmDone
@cmTail:
  cmp r12, r13
  jae @cmDone
  movzx esi, byte ptr [r12]
  cmp sil, [rdx]
  jne @cmDone
  add r12, 1
  add rdx, 1
  jmp @cmTail
@cmDone:
  { rbx = literal length, rbp = match length - MINMATCH }
  mov rbx, r8
  sub rbx, r9
  mov rbp, r12
  sub rbp, r8
  sub rbp, SYLZ_MINMATCH
  mov rdx, r8
  sub rdx, rax
  sub rdx, 1
  mov [r14 + 1], dx               { offset = distance - 1 }
  { token: the exact code if the pair has one, else an escape and the
    extension(s), chosen as in EmitSequence }
  cmp rbx, EXACT_LL
  ja @tokLitBig
  cmp rbp, EXACT_M
  ja @tokEscMatch
  imul esi, ebx, EXACT_M + 1
  add esi, ebp
  mov rdx, [rsp + 16]
  movzx esi, byte ptr [rdx + rsi]
  cmp esi, 255
  je @tokEscMatch
  mov [r14], sil
  add r14, 3
  jmp @noMlExt
@tokEscMatch:
  lea esi, [rbx + ESC_ML]         { literals exact, match extended }
  mov [r14], sil
  add r14, 3
  jmp @putMatch
@tokLitBig:
  mov byte ptr [r14], ESC_BOTH
  cmp rbp, EXACT_M
  ja @tokBoth
  mov esi, ebp                    { literals extended, match exact }
  add esi, ESC_LL                 { (no [rbp + n]: FPC reads that as a frame access) }
  mov [r14], sil
@tokBoth:
  add r14, 3
  mov rdx, rbx
@litExt:
  cmp rdx, 255
  jb @litExtEnd
  mov byte ptr [r14], 255
  add r14, 1
  sub rdx, 255
  jmp @litExt
@litExtEnd:
  mov [r14], dl
  add r14, 1
  cmp rbp, EXACT_M
  jbe @noMlExt
@putMatch:
  mov rdx, rbp
@mlExt:
  cmp rdx, 255
  jb @mlExtEnd
  mov byte ptr [r14], 255
  add r14, 1
  sub rdx, 255
  jmp @mlExt
@mlExtEnd:
  mov [r14], dl
  add r14, 1
@noMlExt:
  { literals to the scratch stream: 16-byte steps when the reads stay
    inside the input, else byte by byte }
  test rbx, rbx
  jz @litDone
  lea rdx, [r9 + rbx + 16]
  cmp rdx, r13
  ja @litBytes
  mov rsi, r9
  mov rdi, r15
  mov rdx, rbx
@lit16:
  movdqu xmm0, [rsi]
  movdqu [rdi], xmm0
  add rsi, 16
  add rdi, 16
  sub rdx, 16
  jg @lit16
  jmp @litDone
@litBytes:
  xor edx, edx
@litByte:
  movzx esi, byte ptr [r9 + rdx]
  mov [r15 + rdx], sil
  add rdx, 1
  cmp rdx, rbx
  jb @litByte
@litDone:
  add r15, rbx
  mov r8, r12                     { ip = match end }
  mov r9, r12                     { anchor = ip }
  cmp r8, [rsp]
  ja @last
  { table[hash(ip - 2)] = ip - 2 - src }
  mov rdx, [r8 - 2]
  shl rdx, 64 - 8 * FAST_HASH_BYTES
  imul rdx, [rsp + 24]
  shr rdx, cl
  lea r12, [r8 - 2]
  sub r12, r10
  mov [r11 + rdx * 2], r12w
  { a match right here needs no literals }
  mov rdx, [r8]
  shl rdx, 64 - 8 * FAST_HASH_BYTES
  imul rdx, [rsp + 24]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov r12, r8
  sub r12, r10
  mov [r11 + rdx * 2], r12w
  sub r12d, eax
  and r12d, $FFFF
  mov edx, 65536
  test r12d, r12d
  cmovz r12d, edx
  mov rax, r8
  sub rax, r12
  cmp rax, r10
  jb @next
  mov r12d, [rax]
  cmp r12d, [r8]
  je @emit
@next:
  add r8, 1
  mov rdx, [r8]
  shl rdx, 64 - 8 * FAST_HASH_BYTES
  imul rdx, [rsp + 24]
  shr rdx, cl
  mov edi, edx
  jmp @search

@last:
  pop rcx                         { mflimit }
  pop rcx                         { hash shift }
  pop rcx                         { exact code map }
  pop rcx                         { multiplier }
  pop rax                         { state }
  mov [rax + 32], r14
  mov [rax + 40], r15
  mov [rax + 48], r9
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
end;

type
  { In/out state of format v4's assembler fast compressor; fixed field
    order. It writes each sequence where out points: a record
    (EmitSequence4), or with direct = 1 its tokens (EmitDirect4), and
    returns with more = 1 when out has reached outEnd, at a match it has
    found (ip, ref): the caller turns the chunk and calls again. }
  TFast4EncState = record
    src, iend, mflimit: PByte;   {   0,  8, 16: in }
    table: PUInt16;              {  24: in }
    outp: PByte;                 {  32: in/out, where the next record or token goes }
    lit: PByte;                  {  40: in/out, literal write pointer }
    anchor: PByte;               {  48: in/out (first: src) }
    outEnd: PByte;               {  56: in }
    hashShift: Int64;            {  64: in, 64 - hash table log }
    ip: PByte;                   {  72: in/out (first: src + 1) }
    rep: SizeInt;                {  80: in/out, the previous distance (first: 1) }
    ref: PByte;                  {  88: out, with more }
    more: SizeInt;               {  96: in/out (first: 0) }
    direct: SizeInt;             { 104: in }
    codes: Pointer;              { 112: in, with direct: the chunk's TCodes4 }
    off: PByte;                  { 120: in/out, with direct: offset write pointer }
  end;
  PFast4EncState = ^TFast4EncState;

const
  { TCodes4's layout, for the assembler }
  CODES4_ROW   = COLS4;                 { bytes per row (literal length) }
  CODES4_KIND  = ROWS4 * CODES4_ROW;    { and per kind }
  { HashFast's multiplier, shifted: the 8 bytes read times this is the 6
    bytes hashed, shifted, times the multiplier (one instruction less in
    the chain from a position to its candidate) }
  FAST_MULT16  = UInt64(889523592379) shl (64 - 8 * FAST_HASH_BYTES);

{ CompressFastCore4 in x86_64 assembler, the same output byte for byte
  (tests check it). Each sequence is recorded (EmitSequence4) or, in an
  open chunk, written as tokens (EmitDirect4).
  The hash table holds the low 16 bits of addresses, not of positions (the
  caller fills it with src's): the distances are the same, and a probe
  needs neither the position nor a check against the start of the input
  (a candidate is an earlier address, or src itself).
  The first 64 probes after a match step one byte (@dense: 15
  instructions each); the ones after them (@probe) step further and
  further. @dense and the hashing before it come once per level, with the
  shift a constant: a shift by cl is three operations, and the time goes
  in waiting for the table's entry and the candidate's bytes behind a
  branch nothing predicts, so what shortens that wait pays: the constant
  shift 3% of the whole, the match's first 8 bytes compared through the
  probe's own address (@hit, @repHit) 1%.
  Registers: r8 ip, r9 anchor, r10 offset write pointer, r11 table, r13
  minus the previous distance, r14 record or token write pointer, r15
  literal write pointer, rdi hash of the next probe, cl the hash shift;
  rbx the dense probes' end, or the next probe (fwd) with rbp the probe
  count; rax candidate; r12 the hash multiplier while probing, the match's
  end from a hit on; the rest scratch. }
procedure CompressFast4X64(st: PFast4EncState); assembler; nostackframe;
asm
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  mov rdx, [rax + 8]
  sub rdx, 16
  push rdx                        { [rsp+88]: iend - 16 }
  push qword ptr [rax]            { [rsp+80]: src }
  push rax                        { [rsp+72]: state }
  add rdx, 8
  push rdx                        { [rsp+64]: iend - 8 }
  mov rdx, [rax + 112]
  push rdx                        { [rsp+56]: the chunk's codes: a new offset's, }
  add rdx, CODES4_KIND
  push rdx                        { [rsp+48]: the previous offset's }
  push qword ptr [rax + 104]      { [rsp+40]: tokens (1) or records (0) }
  push qword ptr [rax + 8]        { [rsp+32]: iend }
  mov rcx, FAST_MULT16
  push rcx                        { [rsp+24]: hash multiplier }
  push qword ptr [rax + 56]       { [rsp+16]: where the records or the chunk end }
  push qword ptr [rax + 64]       { [rsp+8]: hash shift }
  push qword ptr [rax + 16]       { [rsp]: mflimit }
  mov rcx, [rsp + 8]              { cl = hash shift, for the whole routine }
  mov r11, [rax + 24]
  mov r14, [rax + 32]
  mov r15, [rax + 40]
  mov r9, [rax + 48]
  mov r8, [rax + 72]
  mov r10, [rax + 120]
  mov r13, [rax + 80]
  neg r13
  cmp qword ptr [rax + 96], 0
  je @fresh
  mov rax, [rax + 88]             { back after a turn: the match it stopped at }
  jmp @emit
@fresh:
  mov r12, [rsp + 24]
  mov rbp, [r8]
  mov rdi, rbp
  imul rdi, r12
  shr rdi, cl                     { hash(ip) }
  lea rbx, [r8 + (1 shl SKIP_STRENGTH)]
  cmp rbx, [rsp]
  jbe @searchGo
@searchEnd:
  mov rbx, [rsp]                  { the last probes of the input }
  cmp r8, rbx
  jae @last
@searchGo:
  cmp cl, 64 - FAST_LOG1
  je @dense
  jmp @dense0

@denseEnd:
  cmp r8, [rsp]
  jae @last
  mov rbx, r8                     { fwd = ip }
  mov ebp, 2 shl SKIP_STRENGTH    { probes; step = probes shr SKIP_STRENGTH }
@probe:
  mov esi, edi                    { h = hash(fwd) }
  mov r8, rbx                     { ip = fwd }
  mov rdx, rbp
  shr rdx, SKIP_STRENGTH
  add rbx, rdx                    { fwd += step }
  add rbp, 1
  cmp rbx, [rsp]
  ja @last
  movzx eax, word ptr [r11 + rsi * 2]
  mov rdi, [rbx]
  imul rdi, r12
  shr rdi, cl                     { hash(fwd) }
  mov [r11 + rsi * 2], r8w
  sub ax, r8w
  mov edx, [r8 + rax - 65536]
  cmp edx, [r8]
  jne @probe
@hit:
  { the match's end -> r12, its first 8 bytes read through the candidate
    as the probe left it (a probe is at least 12 bytes from the end) }
  mov rdx, [r8 + rax - 65536 + SYLZ_MINMATCH]
  mov rsi, [r8 + SYLZ_MINMATCH]
  lea r12, [r8 + SYLZ_MINMATCH]
  add rax, r8
  sub rax, 65536                  { ref = ip - distance }
  xor rsi, rdx
  jz @cmFar
  bsf rsi, rsi
  shr esi, 3
  add r12, rsi
@cmDone:
  cmp r14, [rsp + 16]
  jae @full                       { no room: the caller turns the chunk, then back here }

@back:
  { extend the match backwards over the pending literals }
  cmp r8, r9
  jbe @backDone
  cmp rax, [rsp + 80]
  jbe @backDone
  movzx edx, byte ptr [r8 - 1]
  cmp dl, [rax - 1]
  jne @backDone
  sub r8, 1
  sub rax, 1
  jmp @back
@backDone:
  mov rbx, r8
  sub rbx, r9                     { rbx = literals }
  mov rsi, rax
  sub rsi, r8                     { rsi = minus the distance }
  sub r8, r12
  neg r8                          { r8 = match length (ip comes back from r12) }
  cmp qword ptr [rsp + 40], 0
  je @record
  { the tokens, as EmitDirect4 writes them. rdx = 1 at a new distance, rdi
    = the exact codes of the match's kind }
  xor edx, edx
  cmp rsi, r13
  setne dl
  mov rdi, [rsp + 48 + rdx * 8]
  mov r13, rsi                    { the previous distance from here on }
  not rsi
  mov [r10], si                   { distance - 1: written either way, kept at a new distance }
  lea r10, [r10 + rdx * 2]
  cmp rbx, MAX_LL4
  ja @dLong
  cmp r8, MAX_ML4
  ja @dLong
  imul eax, ebx, CODES4_ROW
  add rax, r8
  movzx eax, byte ptr [rdi + rax]
  cmp eax, 255
  je @dNoCode
  mov [r14], al
  add r14, 1

@lits:
  { up to 16 literals to the scratch stream: 16 bytes at once (it has
    room for them) when the read stays inside the input }
  cmp r9, [rsp + 88]
  ja @litBytes
  movdqu xmm0, [r9]
  movdqu [r15], xmm0
@litDone:
  add r15, rbx
  mov r8, r12                     { ip = match end }
  mov r9, r12                     { anchor = ip }
  lea rbx, [r8 + (1 shl SKIP_STRENGTH)]   { one byte at a time up to here }
  cmp rbx, [rsp]
  ja @nearEnd
  mov r12, [rsp + 24]
  cmp cl, 64 - FAST_LOG1
  jne @next0
  { table[hash(ip - 2)] = ip - 2 }
  mov rdx, [r8 - 2]
  imul rdx, r12
  shr rdx, 64 - FAST_LOG1
  lea eax, [r8 - 2]
  mov [r11 + rdx * 2], ax
  { the search goes on at the match's end }
  mov rbp, [r8]
  mov rdi, rbp
  imul rdi, r12
  shr rdi, 64 - FAST_LOG1
@dense:
  { rdi = hash(ip), rbp = the bytes at ip }
  movzx eax, word ptr [r11 + rdi * 2]   { low 16 bits of the candidate's address }
  mov [r11 + rdi * 2], r8w
  mov rdx, [r8 + 1]
  mov rdi, rdx
  imul rdi, r12
  shr rdi, 64 - FAST_LOG1         { hash(ip + 1) }
  cmp edx, [r8 + r13 + 1]         { the previous distance, one byte on }
  je @repHit
  sub ax, r8w                     { 65536 - distance (0: 65536) }
  cmp ebp, [r8 + rax - 65536]
  je @hit
  mov rbp, rdx
  add r8, 1
  cmp r8, rbx
  jb @dense
  jmp @denseEnd

@repHit:
  add r8, 1
  lea r12, [r8 + SYLZ_MINMATCH]
  mov rsi, [r8 + SYLZ_MINMATCH]
  xor rsi, [r8 + r13 + SYLZ_MINMATCH]
  lea rax, [r8 + r13]             { ref = ip - previous distance }
  jz @cmFar
  bsf rsi, rsi
  shr esi, 3
  add r12, rsi
  jmp @cmDone

  { the same for level 0's table }
@next0:
  mov rdx, [r8 - 2]
  imul rdx, r12
  shr rdx, 64 - FAST_LOG0
  lea eax, [r8 - 2]
  mov [r11 + rdx * 2], ax
  mov rbp, [r8]
  mov rdi, rbp
  imul rdi, r12
  shr rdi, 64 - FAST_LOG0
@dense0:
  movzx eax, word ptr [r11 + rdi * 2]
  mov [r11 + rdi * 2], r8w
  mov rdx, [r8 + 1]
  mov rdi, rdx
  imul rdi, r12
  shr rdi, 64 - FAST_LOG0
  cmp edx, [r8 + r13 + 1]
  je @repHit
  sub ax, r8w
  cmp ebp, [r8 + rax - 65536]
  je @hit
  mov rbp, rdx
  add r8, 1
  cmp r8, rbx
  jb @dense0
  jmp @denseEnd

@nearEnd:
  { a match that ends within 64 bytes of the last probe, or past it }
  cmp r8, [rsp]
  ja @last
  mov r12, [rsp + 24]
  mov rdx, [r8 - 2]
  imul rdx, r12
  shr rdx, cl
  lea eax, [r8 - 2]
  mov [r11 + rdx * 2], ax
  mov rbp, [r8]
  mov rdi, rbp
  imul rdi, r12
  shr rdi, cl
  jmp @searchEnd

@emit:
  { a match at r8, from rax (after a turn): its end -> r12 }
  lea r12, [r8 + SYLZ_MINMATCH]
  lea rdx, [rax + SYLZ_MINMATCH]
  jmp @cm8
@cmFar:
  add r12, 8
  lea rdx, [rax + SYLZ_MINMATCH + 8]
@cm8:
  cmp r12, [rsp + 64]
  ja @cmTail
  mov rsi, [r12]
  xor rsi, [rdx]
  jz @cmMore
  bsf rsi, rsi
  shr esi, 3
  add r12, rsi
  jmp @cmDone
@cmMore:
  add r12, 8
  add rdx, 8
  jmp @cm8
@cmTail:
  cmp r12, [rsp + 32]
  jae @cmDone
  movzx esi, byte ptr [r12]
  cmp sil, [rdx]
  jne @cmDone
  add r12, 1
  add rdx, 1
  jmp @cmTail

@litsAny:
  { a run of any length: the rest of a long one in 16-byte steps, when
    their reads stay inside the input; at its end, byte by byte }
  cmp rbx, 16
  jbe @lits
  lea rdx, [r9 + rbx + 16]
  cmp rdx, [rsp + 32]
  ja @litBytes
  mov rsi, r9
  mov rdi, r15
  mov rdx, rbx
@lit16:
  movdqu xmm0, [rsi]
  movdqu [rdi], xmm0
  add rsi, 16
  add rdi, 16
  sub rdx, 16
  jg @lit16
  jmp @litDone
@litBytes:
  test rbx, rbx
  jz @litDone
  xor edx, edx
@litByte:
  movzx esi, byte ptr [r9 + rdx]
  mov [r15 + rdx], sil
  add rdx, 1
  cmp rdx, rbx
  jb @litByte
  jmp @litDone

@record:
  { the record, as EmitSequence4 writes it: literals, match length,
    distance - 1 }
  mov r13, rsi
  not rsi
  mov [r14 + 4], si
  cmp rbx, REC4_ESC
  jae @recLong
  cmp r8, $FFFF
  ja @recLong
  mov [r14], bx
  mov [r14 + 2], r8w
  add r14, 6
  jmp @litsAny
@recLong:
  mov word ptr [r14], REC4_ESC    { the lengths as two u32 after it }
  mov word ptr [r14 + 2], 0
  mov [r14 + 6], ebx
  mov [r14 + 10], r8d
  add r14, 18
  jmp @litsAny

@dNoCode:
  { a literal-only token, then the match's }
  mov rdx, [rsp + 56]
  imul eax, ebx, CODES4_ROW
  movzx eax, byte ptr [rdx + rax + CODES4_KIND]
  mov [r14], al
  movzx eax, byte ptr [rdi + r8]
  mov [r14 + 1], al
  add r14, 2
  jmp @lits

@dLong:
  { over MAX_LL4 literals or a match over MAX_ML4: PutTokens4 (in
    Pascal, with the registers it may change and the loop needs saved;
    rbp is free here). edx = 1 at a new distance. }
  push rcx
  push r9
  push r10
  push r11
  xor edx, 1                      { k }
  mov rbp, rsp
  and rsp, -16
  sub rsp, 48
{$ifdef WIN64}
  mov [rsp + 32], r8              { ml }
  mov r9, rbx                     { ll }
  mov r8, rdx                     { k }
  mov rdx, r14                    { p }
  mov rcx, [rbp + 32 + 56]        { the chunk's codes }
{$else}
  mov rcx, rbx                    { ll; r8 = ml }
  mov rsi, r14                    { p; rdx = k }
  mov rdi, [rbp + 32 + 56]        { the chunk's codes }
{$endif}
  call PutTokens4
  mov rsp, rbp
  mov r14, rax
  pop r11
  pop r10
  pop r9
  pop rcx
  jmp @litsAny

@full:
  mov rdx, [rsp + 72]
  mov [rdx + 72], r8
  mov [rdx + 88], rax
  mov qword ptr [rdx + 96], 1
  jmp @out
@last:
  mov rdx, [rsp + 72]
  mov qword ptr [rdx + 96], 0
@out:
  add rsp, 72
  pop rax                         { state }
  add rsp, 16
  neg r13
  mov [rax + 80], r13
  mov [rax + 120], r10
  mov [rax + 32], r14
  mov [rax + 40], r15
  mov [rax + 48], r9
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
end;
{$endif}

{$ifdef SYLZ_C}
type
  { sylzc_emit / sylzc_fast in sylzc.c: fixed field order }
  TEmitC = record
    ctrl, lit: PByte;
    srcEnd: PByte;
    exact: PByte;              { ExactCode }
    rep: SizeInt;              { format v4: the previous sequence's distance }
    rec, recEnd: PUInt16;      { v4: where the next sequence is recorded }
    flush: Pointer;            { v4: called with this record when rec = recEnd,
                                 or (direct) when ctrl has reached tokEnd }
    owner: Pointer;            { v4: the TEmit }
    { v4, levels 0-3: TEmit's open chunk (ctrl: its token write pointer) }
    direct: SizeInt;
    tokEnd, off: PByte;
    codes: Pointer;            { TCodes4 }
  end;
  PEmitC = ^TEmitC;

const
  { sylzc.c's v4 levels 0-3 keep a memo of split tokens in the record
    buffer, 8 words after their recEnd (3 * FAST_PREFIX4 words, a long
    record started before it reaching 6 more) }
  SPLIT4_MEMO_BYTES = 2 * (LIT_SPLIT4 + 1) * (ML_SPLIT4 + 1) * 4;
{$if (3 * FAST_PREFIX4 + 8) * 2 + SPLIT4_MEMO_BYTES > 3 * 2 * CHUNK4_SEQS}
  {$error the split token memo does not fit after the levels 0-3 records}
{$endif}

{ sylzc.c's v4 emitters call this when their records or their open chunk
  are full. The C compressors run only with room for SylzBound(n), so the
  flush finds room; if it ever did not, the block fails at its end. }
procedure Flush4FromC(c: PEmitC); cdecl;
var
  e: PEmit;
begin
  e := c^.owner;
  e^.lit := c^.lit;
  if e^.direct then
  begin
    { the open chunk's pointers were the C loop's }
    e^.ctrl := c^.ctrl;
    e^.off := c^.off;
    e^.rep := c^.rep;
  end
  else
    e^.rec := c^.rec;
  if not TurnChunk4(e^) then
  begin
    e^.failed := True;
    e^.rec := e^.recs;
  end;
  c^.rec := e^.rec;
  c^.direct := Ord(e^.direct);
  c^.ctrl := e^.ctrl;
  c^.tokEnd := e^.tokEnd;
  c^.off := e^.off;
end;


procedure EmitToC(var e: TEmit; out c: TEmitC; srcEnd: PByte);
begin
  c.ctrl := e.ctrl;
  c.lit := e.lit;
  c.srcEnd := srcEnd;
  c.exact := @ExactCode[0, 0];
  c.rep := e.rep;
  c.rec := e.rec;
  c.recEnd := e.recEnd;
  c.flush := @Flush4FromC;
  c.owner := @e;
  c.direct := Ord(e.direct);
  c.tokEnd := e.tokEnd;
  c.off := e.off;
  c.codes := @e.codes;
end;

procedure EmitFromC(var e: TEmit; const c: TEmitC);
begin
  e.lit := c.lit;
  if not e.v4 then
    e.ctrl := c.ctrl
  else if e.direct then
  begin
    e.ctrl := c.ctrl;
    e.off := c.off;
  end
  else
    e.rec := c.rec;   { ctrl is the flushes' }
  e.rep := c.rep;
end;

type  TFastCState = record
    src: PByte;
    n: SizeInt;
    table: PUInt16;
    hashLog: SizeInt;
    anchor: SizeInt;           { out: start of the tail literals }
    e: TEmitC;
  end;

procedure sylzc_compress_fast(st: Pointer); cdecl; external name 'sylzc_compress_fast';
procedure sylzc_compress_fast4(st: Pointer); cdecl; external name 'sylzc_compress_fast4';
{$endif}

function CompressFast(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; level: Integer): SizeInt;
var
  e: TEmit;
  table: PUInt16;
  hashLog: Integer;
{$ifdef SYLZ_ASM_X64}
  st: TFastEncState;
  s4: TFast4EncState;
{$endif}
{$ifdef SYLZ_C}
  sc: TFastCState;
{$endif}
begin
  if ctx.table = nil then
    ctx.table := GetMem(SizeOf(UInt16) shl CTX_TABLELOG);
  table := ctx.table;
  hashLog := FastHashLog(level);
  begin
    EmitInit(e, dst, cap, ctx.scratch, src + n, ctx.flags, ctx.offs, ctx.recs);
    e.roomy := cap >= SylzBound(n);
    e.prefix := FAST_PREFIX4;
    e.recEnd := e.recs + 3 * FAST_PREFIX4;
{$ifdef SYLZ_ASM_X64}
    if SylzUseAsm and e.v4 and not SylzPreferC and (cap >= SylzBound(n))
       and (n >= SEARCH_TAIL + 1) then
    begin
      { the table as the assembler keeps it: the low halves of addresses,
        each entry the start of the input for now }
      FillWord(table^, 1 shl hashLog, UInt16(PtrUInt(src)));
      s4.src := src;
      s4.iend := src + n;
      s4.mflimit := src + n - SEARCH_TAIL;
      s4.table := table;
      s4.lit := e.lit;
      s4.anchor := src;
      s4.hashShift := 64 - hashLog;
      s4.ip := src + 1;
      s4.rep := 1;
      s4.more := 0;
      s4.codes := @e.codes;
      repeat
        s4.direct := Ord(e.direct);
        s4.off := e.off;
        if e.direct then
        begin
          s4.outp := e.ctrl;
          s4.outEnd := e.tokEnd;
        end
        else
        begin
          s4.outp := PByte(e.rec);
          s4.outEnd := PByte(e.recEnd);
        end;
        CompressFast4X64(@s4);
        if e.direct then
        begin
          e.ctrl := s4.outp;
          e.off := s4.off;
        end
        else
          e.rec := PUInt16(s4.outp);
        e.lit := s4.lit;
        e.rep := s4.rep;
        if s4.more = 0 then
          Break;
        if not TurnChunk4(e) then   { the records or the chunk were full }
          Exit(-1);
      until False;
      Exit(EmitFinish(e, s4.anchor, src + n - s4.anchor));
    end;
{$endif}
    FillChar(table^, SizeOf(UInt16) shl hashLog, 0);
{$ifdef SYLZ_ASM_X64}
    if SylzUseAsm and not e.v4 and not SylzPreferC and (cap >= SylzBound(n)) and (n >= SEARCH_TAIL + 1) then
    begin
      st.src := src;
      st.iend := src + n;
      st.mflimit := src + n - SEARCH_TAIL;
      st.table := table;
      st.ctrl := e.ctrl;
      st.lit := e.lit;
      st.exact := @ExactCode[0, 0];
      st.hashShift := 64 - hashLog;
      CompressFastX64(@st);
      e.ctrl := st.ctrl;
      e.lit := st.lit;
      Exit(EmitFinish(e, st.anchor, src + n - st.anchor));
    end;
{$endif}
{$ifdef SYLZ_C}
    if SylzUseAsm and not e.v4 and (cap >= SylzBound(n)) and (n >= SEARCH_TAIL + 1) then
    begin
      sc.src := src;
      sc.n := n;
      sc.table := table;
      sc.hashLog := hashLog;
      sc.e.ctrl := e.ctrl;
      sc.e.lit := e.lit;
      sc.e.srcEnd := src + n;
      sc.e.exact := @ExactCode[0, 0];
      sylzc_compress_fast(@sc);
      e.ctrl := sc.e.ctrl;
      e.lit := sc.e.lit;
      Exit(EmitFinish(e, src + sc.anchor, n - sc.anchor));
    end;
{$endif}
{$ifdef SYLZ_C}
    if SylzUseAsm and e.v4 and (cap >= SylzBound(n)) and (n >= SEARCH_TAIL + 1) then
    begin
      sc.src := src;
      sc.n := n;
      sc.table := table;
      sc.hashLog := hashLog;
      EmitToC(e, sc.e, src + n);
      sylzc_compress_fast4(@sc);
      EmitFromC(e, sc.e);
      Exit(EmitFinish(e, src + sc.anchor, n - sc.anchor));
    end;
{$endif}
    if e.v4 then
      Exit(CompressFastCore4(src, n, e, table, hashLog));
    Result := CompressFastCore(src, n, e, table, hashLog);
  end;
end;

{ ── levels 2-3: two hash tables ────────────────────────────────────────── }

{ After LZ4's "mid" parser (lz4hc levels 1-2): a table keyed on 6 bytes,
  tried first, finds the long matches; one keyed on 4 bytes the short
  ones. Both keep the low 16 bits of a position (FastDist). Only a few
  positions of each match are inserted (its second and third, and the two
  before its end), and the probe step grows with the literals since the
  last match. Level 2 is greedy, with one look at the next byte's long
  candidate after a match shorter than MID_NEXT_BELOW; level 3 has tables
  twice as big and looks one byte later in both while that gives a longer
  match (lazy). Against hash chains, which insert and search every
  position and were bound by the latency of their head table: silesia.tar
  level 3 39.99% at 139 MB/s in Pascal, where 2-attempt hash chains made
  40.75% at 71 MB/s. }

{ 6 bytes on every target (32-bit ones mixed two 4-byte words until syc
  0.5.1: the same blocks everywhere now, as HashFast) }
function MidHashLong(p: PByte; hashLog: Integer): UInt32; inline;
begin
  Result := UInt32((Read64(p) shl 16) * UInt64(889523592379) shr (64 - hashLog));
end;

function MidHashShort(p: PByte; hashLog: Integer): UInt32; inline;
begin
  Result := Hash4(Read32(p), hashLog);
end;

{ Looks up and replaces table[h] with pos: the candidate's distance if its
  first 4 bytes match, else 0. }
function MidCand(table: PUInt16; h: UInt32; src: PByte; pos: SizeInt): SizeInt; inline;
begin
  Result := FastDist(pos, table[h]);
  table[h] := UInt16(pos);
  if (Result > pos) or (Read32(src + pos - Result) <> Read32(src + pos)) then
    Result := 0;
end;

function CompressMidCore(src: PByte; n: SizeInt; var e: TEmit; tl, ts: PUInt16;
  hashLog: Integer; lazy: Boolean): SizeInt;
var
  iend, mflimit: PByte;
  pos, anchor, len, dist, len2, dist2, dshort, k, mend, rep: SizeInt;
begin
  iend := src + n;
  anchor := 0;
  rep := 1;
  if n >= SEARCH_TAIL + 1 then
  begin
    mflimit := iend - SEARCH_TAIL;
    pos := 0;
    while src + pos < mflimit do
    begin
      if e.v4 and (rep <= pos + 1) and (Read32(src + pos + 1 - rep) = Read32(src + pos + 1)) then
      begin
        { format v4: the previous offset, one byte on; when that match is
          shorter than MID_NEXT_BELOW, the long table's candidate here
          instead if it reaches further (binary data has many short
          repeats in the way of a long match: 64 KiB of mozilla, level 2,
          16279 -> 15879 bytes) }
        len := SYLZ_MINMATCH + CountMatch(src + pos + 1 + SYLZ_MINMATCH,
          src + pos + 1 - rep + SYLZ_MINMATCH, iend);
        dist := 0;
        if len < MID_NEXT_BELOW then
          dist := MidCand(tl, MidHashLong(src + pos, hashLog), src, pos)
        else
          tl[MidHashLong(src + pos, hashLog)] := UInt16(pos);
        ts[MidHashShort(src + pos, hashLog)] := UInt16(pos);
        len2 := 0;
        if dist > 0 then
          len2 := SYLZ_MINMATCH + CountMatch(src + pos + SYLZ_MINMATCH,
            src + pos - dist + SYLZ_MINMATCH, iend);
        if len2 > len + 1 then
          len := len2
        else
        begin
          Inc(pos);
          dist := rep;
        end;
      end
      else
      begin
      dist := MidCand(tl, MidHashLong(src + pos, hashLog), src, pos);
      if dist > 0 then
        ts[MidHashShort(src + pos, hashLog)] := UInt16(pos)
      else
      begin
        dist := MidCand(ts, MidHashShort(src + pos, hashLog), src, pos);
        if dist = 0 then
        begin
          Inc(pos, 1 + (pos - anchor) shr MID_SKIP);
          Continue;
        end;
      end;
      len := SYLZ_MINMATCH + CountMatch(src + pos + SYLZ_MINMATCH,
        src + pos - dist + SYLZ_MINMATCH, iend);

      if lazy then
        { both tables one byte later, while that finds a longer match }
        while (len < MID_LAZY_ENOUGH) and (src + pos + 1 < mflimit) do
        begin
          k := pos + 1;
          dist2 := MidCand(tl, MidHashLong(src + k, hashLog), src, k);
          dshort := MidCand(ts, MidHashShort(src + k, hashLog), src, k);
          if dist2 = 0 then
            dist2 := dshort;
          if dist2 = 0 then
            Break;
          len2 := SYLZ_MINMATCH + CountMatch(src + k + SYLZ_MINMATCH,
            src + k - dist2 + SYLZ_MINMATCH, iend);
          if len2 <= len then
            Break;
          pos := k;
          len := len2;
          dist := dist2;
        end
      else if (len < MID_NEXT_BELOW) and (src + pos + 1 < mflimit) then
      begin
        { a short match: a long one one byte later? }
        k := pos + 1;
        dist2 := MidCand(tl, MidHashLong(src + k, hashLog), src, k);
        if dist2 > 0 then
        begin
          len2 := SYLZ_MINMATCH + CountMatch(src + k + SYLZ_MINMATCH,
            src + k - dist2 + SYLZ_MINMATCH, iend);
          if len2 > len then
          begin
            pos := k;
            len := len2;
            dist := dist2;
          end;
        end;
      end;

      end;

      while (pos > anchor) and (pos > dist) and (src[pos - 1] = src[pos - 1 - dist]) do
      begin
        Dec(pos);
        Inc(len);
      end;
      if not EmitSequence(e, src + anchor, pos - anchor, dist, len) then
        Exit(-1);
      rep := dist;
      mend := pos + len;
      if src + mend < mflimit then
      begin
        tl[MidHashLong(src + pos + 1, hashLog)] := UInt16(pos + 1);
        ts[MidHashShort(src + pos + 2, hashLog)] := UInt16(pos + 2);
        tl[MidHashLong(src + mend - 2, hashLog)] := UInt16(mend - 2);
        ts[MidHashShort(src + mend - 1, hashLog)] := UInt16(mend - 1);
      end;
      pos := mend;
      anchor := pos;
    end;
  end;
  Result := EmitFinish(e, src + anchor, n - anchor);
end;

{$ifdef SYLZ_ASM_X64}
type
  { In/out state of the assembler two-table compressor; fixed field order. }
  TMidEncState = record
    src, iend, mflimit: PByte;   {  0,  8, 16: in }
    tl, ts: PUInt16;             { 24, 32: in, long and short tables }
    ctrl, lit: PByte;            { 40, 48: in/out }
    anchor: PByte;               { 56: out }
    exact: PByte;                { 64: in, ExactCode }
    hashShift: Int64;            { 72: in, 64 - table log }
    lazy: Int64;                 { 80: in, 1 = level 3 }
  end;
  PMidEncState = ^TMidEncState;

{ CompressMidCore in x86_64 assembler, same output byte for byte (tests
  check it); only used when dst holds SylzBound(n), as CompressFastX64.
  Registers: r8 ip, r9 anchor, r10 src, r11 long table, r12 short table,
  r13 iend, r14 control and r15 literal write pointers, rdi distance, rbp
  match length, cl the long hash's shift (the short hash's 32-bit shift
  is the same cl mod 32); rax, rbx, rdx, rsi scratch. Stack: [rsp]
  mflimit, [rsp+8] long hash multiplier, [rsp+16] exact-code map, [rsp+24]
  state, [rsp+32] lazy flag, [rsp+40] a candidate distance. }
procedure CompressMidX64(st: PMidEncState); assembler; nostackframe;
asm
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  sub rsp, 48
  mov [rsp + 24], rax             { state }
  mov rdx, [rax + 16]
  mov [rsp], rdx                  { mflimit }
  mov rdx, 889523592379
  mov [rsp + 8], rdx              { long hash multiplier }
  mov rdx, [rax + 64]
  mov [rsp + 16], rdx             { exact code map }
  mov rdx, [rax + 80]
  mov [rsp + 32], rdx             { lazy }
  mov rcx, [rax + 72]             { cl = hash shift, for the whole routine }
  mov r10, [rax]
  mov r13, [rax + 8]
  mov r11, [rax + 24]
  mov r12, [rax + 32]
  mov r14, [rax + 40]
  mov r15, [rax + 48]
  mov r9, r10                     { anchor = src }
  mov r8, r10                     { ip = src }

@loop:
  cmp r8, [rsp]
  jae @last
  mov rsi, r8
  sub rsi, r10                    { pos }
  { long table }
  mov rdx, [r8]
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov [r11 + rdx * 2], si
  mov edi, esi
  sub edi, eax
  and edi, $FFFF
  mov eax, 65536
  test edi, edi
  cmovz edi, eax                  { distance, 0 meaning 65536 }
  cmp rdi, rsi
  ja @short
  mov rax, r8
  sub rax, rdi
  mov edx, [rax]
  cmp edx, [r8]
  jne @short
  { long hit: ip goes into the short table too }
  mov edx, [r8]
  imul edx, edx, -1640531535
  shr edx, cl
  mov [r12 + rdx * 2], si
  jmp @found
@short:
  mov edx, [r8]
  imul edx, edx, -1640531535
  shr edx, cl
  movzx eax, word ptr [r12 + rdx * 2]
  mov [r12 + rdx * 2], si
  mov edi, esi
  sub edi, eax
  and edi, $FFFF
  mov eax, 65536
  test edi, edi
  cmovz edi, eax
  cmp rdi, rsi
  ja @miss
  mov rax, r8
  sub rax, rdi
  mov edx, [rax]
  cmp edx, [r8]
  je @found
@miss:
  mov rdx, r8
  sub rdx, r9
  shr rdx, MID_SKIP
  lea r8, [r8 + rdx + 1]
  jmp @loop

@found:
  { rbp = match length at ip, distance rdi }
  lea rdx, [r8 + SYLZ_MINMATCH]
  mov rsi, r8
  sub rsi, rdi
  add rsi, SYLZ_MINMATCH
@cm1:
  lea rax, [rdx + 8]
  cmp rax, r13
  ja @cm1Tail
  mov rax, [rdx]
  xor rax, [rsi]
  jnz @cm1Diff
  add rdx, 8
  add rsi, 8
  jmp @cm1
@cm1Diff:
  bsf rax, rax
  shr eax, 3
  add rdx, rax
  jmp @cm1Done
@cm1Tail:
  cmp rdx, r13
  jae @cm1Done
  movzx eax, byte ptr [rdx]
  cmp al, [rsi]
  jne @cm1Done
  add rdx, 1
  add rsi, 1
  jmp @cm1Tail
@cm1Done:
  mov rbp, rdx
  sub rbp, r8

  cmp qword ptr [rsp + 32], 0
  jne @lazy
  { level 2: a short match, and a long one a byte later? }
  cmp rbp, MID_NEXT_BELOW
  jae @back
  lea rbx, [r8 + 1]
  cmp rbx, [rsp]
  jae @back
  mov rsi, rbx
  sub rsi, r10                    { pos + 1 }
  mov rdx, [rbx]
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov [r11 + rdx * 2], si
  mov edx, esi
  sub edx, eax
  and edx, $FFFF
  mov eax, 65536
  test edx, edx
  cmovz edx, eax
  cmp rdx, rsi
  ja @back
  mov rax, rbx
  sub rax, rdx
  mov esi, [rax]
  cmp esi, [rbx]
  jne @back
  mov [rsp + 40], rdx
  call @count                     { rdx = match end at rbx, distance [rsp + 40] }
  sub rdx, rbx
  cmp rdx, rbp
  jbe @back
  mov r8, rbx
  mov rbp, rdx
  mov rdi, [rsp + 40]
  jmp @back

@lazy:
  { level 3: both tables a byte later, while that finds a longer match }
  cmp rbp, MID_LAZY_ENOUGH
  jae @back
  lea rbx, [r8 + 1]
  cmp rbx, [rsp]
  jae @back
  mov rsi, rbx
  sub rsi, r10
  mov rdx, [rbx]
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov [r11 + rdx * 2], si
  mov edx, esi
  sub edx, eax
  and edx, $FFFF
  mov eax, 65536
  test edx, edx
  cmovz edx, eax
  cmp rdx, rsi
  ja @lzNoLong
  mov rax, rbx
  sub rax, rdx
  mov eax, [rax]
  cmp eax, [rbx]
  je @lzLong
@lzNoLong:
  xor edx, edx
@lzLong:
  mov [rsp + 40], rdx             { long candidate's distance, or 0 }
  mov edx, [rbx]
  imul edx, edx, -1640531535
  shr edx, cl
  movzx eax, word ptr [r12 + rdx * 2]
  mov [r12 + rdx * 2], si
  cmp qword ptr [rsp + 40], 0
  jne @lzHave
  mov edx, esi
  sub edx, eax
  and edx, $FFFF
  mov eax, 65536
  test edx, edx
  cmovz edx, eax
  cmp rdx, rsi
  ja @back
  mov rax, rbx
  sub rax, rdx
  mov eax, [rax]
  cmp eax, [rbx]
  jne @back
  mov [rsp + 40], rdx
@lzHave:
  call @count
  sub rdx, rbx
  cmp rdx, rbp
  jbe @back
  mov r8, rbx
  mov rbp, rdx
  mov rdi, [rsp + 40]
  jmp @lazy

@count:
  { rdx = end of the match at rbx with distance [rsp + 48] (one return
    address pushed): prefix length from 4 on, reads before iend }
  lea rdx, [rbx + SYLZ_MINMATCH]
  mov rsi, rbx
  sub rsi, [rsp + 48]
  add rsi, SYLZ_MINMATCH
@cm2:
  lea rax, [rdx + 8]
  cmp rax, r13
  ja @cm2Tail
  mov rax, [rdx]
  xor rax, [rsi]
  jnz @cm2Diff
  add rdx, 8
  add rsi, 8
  jmp @cm2
@cm2Diff:
  bsf rax, rax
  shr eax, 3
  add rdx, rax
  ret
@cm2Tail:
  cmp rdx, r13
  jae @cm2Done
  movzx eax, byte ptr [rdx]
  cmp al, [rsi]
  jne @cm2Done
  add rdx, 1
  add rsi, 1
  jmp @cm2Tail
@cm2Done:
  ret

@back:
  { extend backwards over the pending literals }
  cmp r8, r9
  jbe @emit
  mov rax, r8
  sub rax, rdi
  cmp rax, r10
  jbe @emit
  movzx edx, byte ptr [r8 - 1]
  cmp dl, [rax - 1]
  jne @emit
  sub r8, 1
  add rbp, 1
  jmp @back

@emit:
  lea rax, [r8 + rbp]             { match end, kept to the end of the emit }
  mov rbx, r8
  sub rbx, r9                     { literal length }
  sub rbp, SYLZ_MINMATCH
  lea rdx, [rdi - 1]
  mov [r14 + 1], dx               { offset = distance - 1 }
  cmp rbx, EXACT_LL
  ja @tokLitBig
  cmp rbp, EXACT_M
  ja @tokEscMatch
  imul esi, ebx, EXACT_M + 1
  add esi, ebp
  mov rdx, [rsp + 16]
  movzx esi, byte ptr [rdx + rsi]
  cmp esi, 255
  je @tokEscMatch
  mov [r14], sil
  add r14, 3
  jmp @noMlExt
@tokEscMatch:
  lea esi, [rbx + ESC_ML]
  mov [r14], sil
  add r14, 3
  jmp @putMatch
@tokLitBig:
  mov byte ptr [r14], ESC_BOTH
  cmp rbp, EXACT_M
  ja @tokBoth
  mov esi, ebp
  add esi, ESC_LL
  mov [r14], sil
@tokBoth:
  add r14, 3
  mov rdx, rbx
@litExt:
  cmp rdx, 255
  jb @litExtEnd
  mov byte ptr [r14], 255
  add r14, 1
  sub rdx, 255
  jmp @litExt
@litExtEnd:
  mov [r14], dl
  add r14, 1
  cmp rbp, EXACT_M
  jbe @noMlExt
@putMatch:
  mov rdx, rbp
@mlExt:
  cmp rdx, 255
  jb @mlExtEnd
  mov byte ptr [r14], 255
  add r14, 1
  sub rdx, 255
  jmp @mlExt
@mlExtEnd:
  mov [r14], dl
  add r14, 1
@noMlExt:
  test rbx, rbx
  jz @litDone
  lea rdx, [r9 + rbx + 16]
  cmp rdx, r13
  ja @litBytes
  mov rsi, r9
  mov rdi, r15
  mov rdx, rbx
@lit16:
  movdqu xmm0, [rsi]
  movdqu [rdi], xmm0
  add rsi, 16
  add rdi, 16
  sub rdx, 16
  jg @lit16
  jmp @litDone
@litBytes:
  xor edx, edx
@litByte:
  movzx esi, byte ptr [r9 + rdx]
  mov [r15 + rdx], sil
  add rdx, 1
  cmp rdx, rbx
  jb @litByte
@litDone:
  add r15, rbx
  cmp rax, [rsp]
  jae @noInsert
  { insert the match's second and third, and the two before its end }
  mov rsi, r8
  sub rsi, r10
  add rsi, 1
  mov rdx, [r8 + 1]
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  mov [r11 + rdx * 2], si
  add rsi, 1
  mov edx, [r8 + 2]
  imul edx, edx, -1640531535
  shr edx, cl
  mov [r12 + rdx * 2], si
  mov rsi, rax
  sub rsi, r10
  sub rsi, 2
  mov rdx, [rax - 2]
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  mov [r11 + rdx * 2], si
  add rsi, 1
  mov edx, [rax - 1]
  imul edx, edx, -1640531535
  shr edx, cl
  mov [r12 + rdx * 2], si
@noInsert:
  mov r8, rax
  mov r9, rax
  jmp @loop

@last:
  mov rax, [rsp + 24]
  mov [rax + 40], r14
  mov [rax + 48], r15
  mov [rax + 56], r9
  add rsp, 48
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
end;

type
  { In/out state of format v4's assembler compressor of levels 2-3; fixed
    field order. It writes each sequence at tok: a record (EmitSequence4),
    or with direct = 1 its tokens and offset (EmitDirect4). With more = 1
    it stopped at a sequence (ip - anchor literals, a match of mlen at
    dist) because tok reached outEnd: the caller turns the chunk and calls
    again. }
  TMid4EncState = record
    src, iend, mflimit: PByte;   {   0,   8,  16: in }
    tl, ts: PUInt16;             {  24,  32: in, long and short tables }
    tok: PByte;                  {  40: in/out, token or record write pointer }
    lit: PByte;                  {  48: in/out }
    anchor: PByte;               {  56: in/out (first: src) }
    off: PByte;                  {  64: in/out, offset write pointer }
    hashShift: Int64;            {  72: in, 64 - table log }
    lazy: Int64;                 {  80: in, 1 = level 3 }
    ip: PByte;                   {  88: in/out (first: src) }
    rep: SizeInt;                {  96: in/out, the previous distance (first: 1) }
    mlen, k: SizeInt;            { 104, 112: out, with more }
    more: SizeInt;               { 120: in/out (first: 0) }
    codes: Pointer;              { 128: in, the table's TCodes4 }
    outEnd: PByte;               { 136: in, where the records or the open chunk end }
    dist: SizeInt;               { 144: out, with more }
    direct: SizeInt;             { 152: in, tokens at tok (1) or records (0) }
  end;
  PMid4EncState = ^TMid4EncState;

{ CompressMidCore for format v4 in x86_64 assembler, the same output byte
  for byte (tests check it); only used when dst holds SylzBound(n).
  Against CompressMidX64: the previous distance tried one byte on at each
  position (with CompressMidCore's longer match one byte before a short
  repeat); each sequence recorded (EmitSequence4) or, in an open chunk,
  its tokens and offset written apart with the chunk's table
  (EmitDirect4; PutTokens4 called for what is not one token or a pair);
  and a shorter probe, 24 instructions where that one takes 36:
  - the tables hold the low 16 bits of ip, not of the position, so the
    caller fills them with those of src (what a position of 0 is) and no
    position is kept; the 16-bit difference with ip is 65536 - distance,
    and the candidate sits at ip + that - 65536;
  - the 8 bytes at ip stay in a register for both hashes and compares;
  - the step is one byte up to MID_STEP1 literals, so the loop compares ip
    with where that ends (or mflimit, if that comes first) and only works
    the step out past it;
  - the first probe after a match, the one whose short candidate must
    match 5 bytes, has its own copy of the probe.
  Position 0 is not looked up (it has no candidate), so every table entry
  is a position before the one probed, or src, and no candidate can lie
  before src: the distance needs no check, and neither does the previous
  distance, never over the position of the match that set it. A match is
  looked for before mflimit, 12 bytes from the end, so the first 8 bytes
  compared after its 4 are inside the input.
  Registers: r8 ip, r9 anchor, r10 src, r11 long table, r12 short table,
  r13 iend, r14 token and r15 literal write pointers, rbx minus the
  previous distance and rbp the 8 bytes at ip while probing, then rdi
  distance and rbp match length, cl the long hash's shift (the short
  hash's 32-bit shift is the same cl mod 32); rax, rbx, rdx, rsi scratch.
  Stack: [rsp] mflimit, [rsp+8] long hash multiplier, [rsp+16] offset
  write pointer, [rsp+24] state, [rsp+32] lazy, [rsp+40] a candidate
  distance, [rsp+48] the previous distance, [rsp+56] the codes, [rsp+64]
  where the one-byte step ends, [rsp+72] iend - 16, [rsp+80] the open
  chunk's end (0 while recording: every sequence goes back to the caller,
  with more = 2), [rsp+88] scratch. }
procedure CompressMid4X64(st: PMid4EncState); assembler; nostackframe;
asm
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  sub rsp, 112
  mov [rsp + 24], rax             { state }
  mov rdx, [rax + 136]
  mov [rsp + 80], rdx             { where the records or the open chunk end }
  mov rdx, [rax + 152]
  mov [rsp + 96], rdx             { tokens (1) or records (0) }
  mov rdx, [rax + 16]
  mov [rsp], rdx                  { mflimit }
  mov rdx, 889523592379
  mov [rsp + 8], rdx              { long hash multiplier }
  mov rdx, [rax + 64]
  mov [rsp + 16], rdx             { offset write pointer }
  mov rdx, [rax + 80]
  mov [rsp + 32], rdx             { lazy }
  mov rdx, [rax + 96]
  mov [rsp + 48], rdx             { the previous distance }
  mov rdx, [rax + 128]
  mov [rsp + 56], rdx             { codes }
  mov rcx, [rax + 72]             { cl = hash shift, for the whole routine }
  mov r10, [rax]
  mov r13, [rax + 8]
  lea rdx, [r13 - 16]
  mov [rsp + 72], rdx             { iend - 16 }
  mov r11, [rax + 24]
  mov r12, [rax + 32]
  mov r14, [rax + 40]
  mov r15, [rax + 48]
  mov r9, [rax + 56]              { anchor }
  mov r8, [rax + 88]              { ip }
  cmp qword ptr [rax + 120], 0
  je @first

@resumed:
  { back after a turn: the sequence it stopped at (ip, mlen, dist) }
  mov rbp, [rax + 104]
  mov rdi, [rax + 144]
  lea rax, [r8 + rbp]
  mov rbx, r8
  sub rbx, r9
  jmp @emitGo

@first:
  { position 0: only the previous distance (1), one byte on }
  lea rax, [r8 + MID_STEP1]
  cmp rax, [rsp]
  cmova rax, [rsp]
  mov [rsp + 64], rax
  mov rbx, -1
  mov rbp, [r8]
  cmp ebp, [r8 + 1]
  je @repHit
  jmp @miss

@loop:
  { the first probe after a match: no literals pending }
  mov rbx, [rsp + 48]
  neg rbx                         { minus the previous distance, while probing }
  lea rax, [r8 + MID_STEP1]
  cmp rax, [rsp]
  cmova rax, [rsp]
  mov [rsp + 64], rax             { the step is one byte up to here }
  cmp r8, [rsp]
  jae @last
  mov rbp, [r8]
  mov edx, [r8 + rbx + 1]
  cmp edx, [r8 + 1]
  je @repHit
  mov rdx, rbp
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov [r11 + rdx * 2], r8w
  sub ax, r8w
  cmp ebp, [r8 + rax - 65536]
  je @longHit
  imul edx, ebp, -1640531535
  shr edx, cl
  movzx eax, word ptr [r12 + rdx * 2]
  mov [r12 + rdx * 2], r8w
  sub ax, r8w
  cmp ebp, [r8 + rax - 65536]
  je @shortHit
@miss:
  add r8, 1
  cmp r8, [rsp + 64]
  jae @far
@probe:
  mov rbp, [r8]
  { the previous distance, one byte on: taken as it is }
  mov edx, [r8 + rbx + 1]
  cmp edx, [r8 + 1]
  je @repHit
  { long table }
  mov rdx, rbp
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov [r11 + rdx * 2], r8w
  sub ax, r8w                     { 65536 - distance }
  cmp ebp, [r8 + rax - 65536]
  je @longHit
  { short table }
  imul edx, ebp, -1640531535
  shr edx, cl
  movzx eax, word ptr [r12 + rdx * 2]
  mov [r12 + rdx * 2], r8w
  sub ax, r8w
  cmp ebp, [r8 + rax - 65536]
  jne @miss
@shortHit:
  mov edi, 65536
  sub rdi, rax                    { the distance }
  jmp @found

@far:
  { MID_STEP1 literals or more pending: the step grows with them; or
    mflimit }
  lea rdx, [r8 - 1]
  sub rdx, r9
  shr rdx, MID_SKIP
  add r8, rdx
  cmp r8, [rsp]
  jb @probe
  jmp @last

@repHit:
  { the previous distance one byte on (rbp = the 8 bytes at ip); when its
    match is shorter than MID_NEXT_BELOW, the long table's candidate at ip
    instead if it reaches 2 bytes further (CompressMidCore) }
  mov rdx, rbp
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov [r11 + rdx * 2], r8w        { ip into both tables }
  sub ax, r8w                     { the long candidate: 65536 - distance }
  mov [rsp + 88], rax
  imul edx, ebp, -1640531535
  shr edx, cl
  mov [r12 + rdx * 2], r8w
  mov rdi, [rsp + 48]
  lea rbx, [r8 + 1]
  mov [rsp + 40], rdi
  call @count                     { rdx = match end at rbx, distance [rsp + 40] }
  mov rbp, rdx
  sub rbp, rbx
  cmp rbp, MID_NEXT_BELOW
  jae @repTake
  mov rax, [rsp + 88]
  test eax, eax
  jnz @repCand
  { an entry equal to ip's low 16 bits: a distance of 65536, before src
    under that position }
  mov rdx, r8
  sub rdx, r10
  cmp rdx, 65536
  jb @repTake
@repCand:
  mov edx, [r8 + rax - 65536]
  cmp edx, [r8]
  jne @repTake
  mov edx, 65536
  sub rdx, rax
  mov [rsp + 40], rdx
  mov rbx, r8
  call @count
  sub rdx, r8
  lea rax, [rbp + 1]
  cmp rdx, rax
  jbe @repTake
  mov rbp, rdx
  mov rdi, [rsp + 40]
  jmp @back
@repTake:
  add r8, 1
  mov rdi, [rsp + 48]
  jmp @back

@longHit:
  mov edi, 65536
  sub rdi, rax
  { ip goes into the short table too }
  imul edx, ebp, -1640531535
  shr edx, cl
  mov [r12 + rdx * 2], r8w
@found:
  { rbp = match length at ip, distance rdi }
  mov rsi, r8
  sub rsi, rdi
  mov rax, [r8 + SYLZ_MINMATCH]
  xor rax, [rsi + SYLZ_MINMATCH]
  jnz @cm1First                   { most matches end in these 8 bytes }
  lea rdx, [r8 + SYLZ_MINMATCH + 8]
  add rsi, SYLZ_MINMATCH + 8
@cm1:
  lea rax, [rdx + 8]
  cmp rax, r13
  ja @cm1Tail
  mov rax, [rdx]
  xor rax, [rsi]
  jnz @cm1Diff
  add rdx, 8
  add rsi, 8
  jmp @cm1
@cm1Diff:
  bsf rax, rax
  shr eax, 3
  add rdx, rax
  jmp @cm1Done
@cm1Tail:
  cmp rdx, r13
  jae @cm1Done
  movzx eax, byte ptr [rdx]
  cmp al, [rsi]
  jne @cm1Done
  add rdx, 1
  add rsi, 1
  jmp @cm1Tail
@cm1First:
  bsf rax, rax
  shr eax, 3
  lea rbp, [rax + SYLZ_MINMATCH]
  jmp @counted
@cm1Done:
  mov rbp, rdx
  sub rbp, r8
@counted:
  cmp qword ptr [rsp + 32], 0
  jne @lazy
  { level 2: a short match, and a long one a byte later? }
  cmp rbp, MID_NEXT_BELOW
  jae @back
  lea rbx, [r8 + 1]
  cmp rbx, [rsp]
  jae @back
  mov rdx, [rbx]
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov [r11 + rdx * 2], bx
  sub ax, bx
  mov esi, [rbx + rax - 65536]
  cmp esi, [rbx]
  jne @back
  mov edx, 65536
  sub rdx, rax
  mov [rsp + 40], rdx
  call @count                     { rdx = match end at rbx, distance [rsp + 40] }
  sub rdx, rbx
  cmp rdx, rbp
  jbe @back
  mov r8, rbx
  mov rbp, rdx
  mov rdi, [rsp + 40]
  jmp @back

@lazy:
  { level 3: both tables a byte later, while that finds a longer match }
  cmp rbp, MID_LAZY_ENOUGH
  jae @back
  lea rbx, [r8 + 1]
  cmp rbx, [rsp]
  jae @back
  mov rsi, [rbx]                  { the 8 bytes there }
  mov rdx, rsi
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  movzx eax, word ptr [r11 + rdx * 2]
  mov [r11 + rdx * 2], bx
  sub ax, bx
  mov edx, 65536
  sub rdx, rax                    { the long candidate's distance }
  cmp esi, [rbx + rax - 65536]
  je @lzLong
  xor edx, edx
@lzLong:
  mov [rsp + 40], rdx             { or 0 }
  imul edx, esi, -1640531535
  shr edx, cl
  movzx eax, word ptr [r12 + rdx * 2]
  mov [r12 + rdx * 2], bx
  cmp qword ptr [rsp + 40], 0
  jne @lzHave
  sub ax, bx
  cmp esi, [rbx + rax - 65536]
  jne @back
  mov edx, 65536
  sub rdx, rax
  mov [rsp + 40], rdx
@lzHave:
  call @count
  sub rdx, rbx
  cmp rdx, rbp
  jbe @back
  mov r8, rbx
  mov rbp, rdx
  mov rdi, [rsp + 40]
  jmp @lazy

@count:
  { rdx = end of the match at rbx (before mflimit) with distance [rsp +
    48] (one return address pushed): prefix length from 4 on, reads
    before iend }
  mov rsi, rbx
  sub rsi, [rsp + 48]
  mov rax, [rbx + SYLZ_MINMATCH]
  xor rax, [rsi + SYLZ_MINMATCH]
  jnz @cm2First
  lea rdx, [rbx + SYLZ_MINMATCH + 8]
  add rsi, SYLZ_MINMATCH + 8
@cm2:
  lea rax, [rdx + 8]
  cmp rax, r13
  ja @cm2Tail
  mov rax, [rdx]
  xor rax, [rsi]
  jnz @cm2Diff
  add rdx, 8
  add rsi, 8
  jmp @cm2
@cm2Diff:
  bsf rax, rax
  shr eax, 3
  add rdx, rax
  ret
@cm2Tail:
  cmp rdx, r13
  jae @cm2Done
  movzx eax, byte ptr [rdx]
  cmp al, [rsi]
  jne @cm2Done
  add rdx, 1
  add rsi, 1
  jmp @cm2Tail
@cm2Done:
  ret
@cm2First:
  bsf rax, rax
  shr eax, 3
  lea rdx, [rbx + rax + SYLZ_MINMATCH]
  ret

@back:
  { extend backwards over the pending literals: one test for "the bytes
    before differ, or no literal is pending" (which of the two it is the
    branch predictor cannot tell) }
  mov rax, r8
  sub rax, rdi
  cmp rax, r10
  jbe @emit                       { the match starts the input }
  movzx edx, byte ptr [r8 - 1]
  xor dl, [rax - 1]
  cmp r8, r9
  sete sil
  or dl, sil
  jnz @emit
  sub r8, 1
  add rbp, 1
  jmp @back

@emit:
  lea rax, [r8 + rbp]             { match end, kept to the end of the emit }
  mov rbx, r8
  sub rbx, r9                     { literal length }
  { the records or the open chunk full: the caller turns it, then back
    here }
  cmp r14, [rsp + 80]
  jae @full
@emitGo:
  cmp qword ptr [rsp + 96], 0
  je @recordIt
  { the offset, distance - 1: written either way, kept (the pointer
    moves on) if the distance is not the previous one }
  mov rdx, [rsp + 16]
  lea esi, [rdi - 1]
  mov [rdx], si
  xor esi, esi
  cmp rdi, [rsp + 48]
  setne sil
  mov [rsp + 48], rdi             { the previous distance from here on }
  lea rdx, [rdx + rsi * 2]
  mov [rsp + 16], rdx
  xor esi, 1                      { k: 1 = at the previous distance }
  { the tokens, as PutTokens4 writes them }
  cmp rbx, MAX_LL4
  ja @tokOut
  cmp rbp, MAX_ML4
  ja @tokLong
  imul esi, esi, CODES4_KIND
  imul edx, ebx, CODES4_ROW
  add esi, edx
  add rsi, [rsp + 56]             { exact[k, literals] }
  movzx edx, byte ptr [rsi + rbp]
  cmp edx, 255
  je @tokPair
  mov [r14], dl
  add r14, 1
@tokDone:
  { the literals, MAX_LL4 at most: one 16-byte copy (also when there are
    none: no branch on that) }
  cmp r9, [rsp + 72]
  ja @litBytes
  movdqu xmm0, [r9]
  movdqu [r15], xmm0
@litDone:
  add r15, rbx
  cmp rax, [rsp]
  jae @noInsert
  { insert the match's second and third, and the two before its end }
  mov rdx, [r8 + 1]
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  lea esi, [r8 + 1]
  mov [r11 + rdx * 2], si
  imul edx, dword ptr [r8 + 2], -1640531535
  shr edx, cl
  add esi, 1
  mov [r12 + rdx * 2], si
  mov rdx, [rax - 2]
  shl rdx, 16
  imul rdx, [rsp + 8]
  shr rdx, cl
  lea esi, [rax - 2]
  mov [r11 + rdx * 2], si
  imul edx, dword ptr [rax - 1], -1640531535
  shr edx, cl
  add esi, 1
  mov [r12 + rdx * 2], si
@noInsert:
  mov r8, rax
  mov r9, rax
  jmp @loop

@litLong:
  { any number of literals, 16 bytes at a time }
  lea rdx, [r9 + rbx + 16]
  cmp rdx, r13
  ja @litBytes
  mov rsi, r9
  mov rdi, r15
  mov rdx, rbx
@lit16:
  movdqu xmm0, [rsi]
  movdqu [rdi], xmm0
  add rsi, 16
  add rdi, 16
  sub rdx, 16
  jg @lit16
  jmp @litDone
@litBytes:
  xor edx, edx
@litByte:
  movzx esi, byte ptr [r9 + rdx]
  mov [r15 + rdx], sil
  add rdx, 1
  cmp rdx, rbx
  jb @litByte
  jmp @litDone

@tokPair:
  { no code for the pair: the literals' token (literals only), then the
    match's (no literals) }
  imul edx, ebx, CODES4_ROW
  sub rsi, rdx                    { exact[k, 0] }
  add rdx, [rsp + 56]
  movzx edx, byte ptr [rdx + CODES4_KIND]   { exact[1, literals, 0] }
  mov [r14], dl
  movzx edx, byte ptr [rsi + rbp]
  mov [r14 + 1], dl
  add r14, 2
  jmp @tokDone

@tokLong:
  { a match of MAX_ML4 + 1 .. ML_SPLIT4: its first MAX_ML4 bytes (one
    less when that would leave a single byte) where the pair has a code,
    then the rest as a token at the same distance, no literals; another
    split is PutTokens4's }
  cmp rbp, ML_SPLIT4
  ja @tokOut
  lea edi, [rbp - SYLZ_MINREP]
  mov edx, MAX_ML4
  cmp edi, edx
  cmova edi, edx                  { the first part }
  mov [rsp + 88], rdi
  imul edx, esi, CODES4_KIND
  imul edi, ebx, CODES4_ROW
  add rdx, rdi
  add rdx, [rsp + 56]
  add rdx, [rsp + 88]
  movzx edx, byte ptr [rdx]       { codes[k, literals, first part] }
  cmp edx, 255
  je @tokOut
  mov [r14], dl
  mov rdx, rbp
  sub rdx, [rsp + 88]             { the rest }
  add rdx, [rsp + 56]
  movzx edx, byte ptr [rdx + CODES4_KIND]   { codes[1, 0, rest] }
  mov [r14 + 1], dl
  add r14, 2
  jmp @tokDone

@recordIt:
  { the record, as EmitSequence4 writes it: literals, match length,
    distance - 1; then the literals }
  mov [rsp + 48], rdi             { the previous distance from here on }
  lea edx, [rdi - 1]
  mov [r14 + 4], dx
  cmp rbx, REC4_ESC
  jae @recLong
  cmp rbp, $FFFF
  ja @recLong
  mov [r14], bx
  mov [r14 + 2], bp
  add r14, 6
  jmp @litLong
@recLong:
  mov word ptr [r14], REC4_ESC    { the lengths as two u32 after it }
  mov word ptr [r14 + 2], 0
  mov [r14 + 6], ebx
  mov [r14 + 10], ebp
  add r14, 18
  jmp @litLong

@full:
  mov rax, [rsp + 24]
  mov [rax + 88], r8
  mov [rax + 104], rbp
  mov [rax + 144], rdi
  mov qword ptr [rax + 120], 2
  jmp @out

@tokOut:
  { PutTokens4's other cases, in Pascal: rbx literals, rbp match, esi k;
    with the registers it may change and the loop needs saved (rbp is
    free after this) }
  push rax
  push rcx
  push r8
  push r9
  push r10
  push r11
  mov rdx, [rsp + 48 + 56]        { the codes }
{$ifdef WIN64}
  mov r9, rbx                     { ll }
  mov r8, rsi                     { k }
  mov rcx, rdx                    { codes }
  mov rdx, r14                    { p }
  mov rax, rbp                    { ml }
  mov rbp, rsp
  and rsp, -16
  sub rsp, 48
  mov [rsp + 32], rax
{$else}
  mov rdi, rdx                    { codes }
  mov rdx, rsi                    { k }
  mov rsi, r14                    { p }
  mov rcx, rbx                    { ll }
  mov r8, rbp                     { ml }
  mov rbp, rsp
  and rsp, -16
{$endif}
  call PutTokens4
  mov rsp, rbp
  mov r14, rax
  pop r11
  pop r10
  pop r9
  pop r8
  pop rcx
  pop rax
  cmp rbx, MAX_LL4
  ja @litLong
  jmp @tokDone
@last:
  mov rax, [rsp + 24]
  mov qword ptr [rax + 120], 0
@out:
  mov rdx, [rsp + 48]
  mov [rax + 96], rdx
  mov rdx, [rsp + 16]
  mov [rax + 64], rdx
  mov [rax + 40], r14
  mov [rax + 48], r15
  mov [rax + 56], r9
  add rsp, 112
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
end;
{$endif}

{$ifdef SYLZ_C}
type
  { sylzc_mid in sylzc.c: fixed field order }
  TMidCState = record
    src: PByte;
    n: SizeInt;
    tl, ts: PUInt16;
    hashLog, lazy: SizeInt;
    skip, lazyEnough, nextBelow: SizeInt;
    anchor: SizeInt;           { out }
    e: TEmitC;
  end;

procedure sylzc_compress_mid(st: Pointer); cdecl; external name 'sylzc_compress_mid';
procedure sylzc_compress_mid4(st: Pointer); cdecl; external name 'sylzc_compress_mid4';
{$endif}

function CompressMid(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; level: Integer): SizeInt;
var
  e: TEmit;
  hashLog: Integer;
{$ifdef SYLZ_ASM_X64}
  st: TMidEncState;
  s4: TMid4EncState;
{$endif}
{$ifdef SYLZ_C}
  sc: TMidCState;
{$endif}
begin
  if ctx.table = nil then
    ctx.table := GetMem(SizeOf(UInt16) shl CTX_TABLELOG);
  EmitInit(e, dst, cap, ctx.scratch, src + n, ctx.flags, ctx.offs, ctx.recs);
  e.roomy := cap >= SylzBound(n);
  { level 3's tables (2^16 entries each) fill a 256 KiB L2 cache and one
    probe in nine leaves it; format v4 keeps them all the same: level 2's
    were 20% faster at level 3 but 0.3 points bigger (silesia.tar, 38.97%
    against 39.25%), and v4's level 3 is faster than v2's with them }
  if level = 2 then
    hashLog := MID_MAXLOG - 1
  else
    hashLog := MID_MAXLOG;
  { v4: a chunk's first sequences recorded, the ones after them written
    at once (FlushChunk4, EmitDirect4) }
  e.prefix := FAST_PREFIX4;
  e.recEnd := e.recs + 3 * FAST_PREFIX4;
{$ifdef SYLZ_ASM_X64}
  if SylzUseAsm and not e.v4 and not SylzPreferC and (cap >= SylzBound(n)) and (n >= SEARCH_TAIL + 1) then
  begin
    FillChar(ctx.table^, SizeOf(UInt16) shl (hashLog + 1), 0);
    st.src := src;
    st.iend := src + n;
    st.mflimit := src + n - SEARCH_TAIL;
    st.tl := ctx.table;
    st.ts := ctx.table + (1 shl hashLog);
    st.ctrl := e.ctrl;
    st.lit := e.lit;
    st.exact := @ExactCode[0, 0];
    st.hashShift := 64 - hashLog;
    st.lazy := Ord(level = 3);
    CompressMidX64(@st);
    e.ctrl := st.ctrl;
    e.lit := st.lit;
    Exit(EmitFinish(e, st.anchor, src + n - st.anchor));
  end;
  if SylzUseAsm and e.v4 and not SylzPreferC and (cap >= SylzBound(n))
     and (n >= SEARCH_TAIL + 1) then
  begin
    { CompressMid4X64's tables hold the low 16 bits of pointers: src's are
      what 0, the position, is in the others }
    FillWord(ctx.table^, 2 shl hashLog, UInt16(PtrUInt(src)));
    s4.src := src;
    s4.iend := src + n;
    s4.mflimit := src + n - SEARCH_TAIL;
    s4.tl := ctx.table;
    s4.ts := ctx.table + (1 shl hashLog);
    s4.anchor := src;
    s4.hashShift := 64 - hashLog;
    s4.lazy := Ord(level = 3);
    s4.ip := src;
    s4.more := 0;
    s4.codes := @e.codes;
    repeat
      s4.direct := Ord(e.direct);
      s4.off := e.off;
      if e.direct then
      begin
        s4.tok := e.ctrl;
        s4.outEnd := e.tokEnd;
      end
      else
      begin
        s4.tok := PByte(e.rec);
        s4.outEnd := PByte(e.recEnd);
      end;
      s4.lit := e.lit;
      s4.rep := e.rep;
      CompressMid4X64(@s4);
      if e.direct then
      begin
        e.ctrl := s4.tok;
        e.off := s4.off;
      end
      else
        e.rec := PUInt16(s4.tok);
      e.lit := s4.lit;
      e.rep := s4.rep;
      if s4.more = 0 then
        Break;
      if not TurnChunk4(e) then   { the records or the chunk were full }
        Exit(-1);
    until False;
    Exit(EmitFinish(e, s4.anchor, src + n - s4.anchor));
  end;
{$endif}
  FillChar(ctx.table^, SizeOf(UInt16) shl (hashLog + 1), 0);
{$ifdef SYLZ_C}
  if SylzUseAsm and (cap >= SylzBound(n)) and (n >= SEARCH_TAIL + 1) then
  begin
    sc.src := src;
    sc.n := n;
    sc.tl := ctx.table;
    sc.ts := ctx.table + (1 shl hashLog);
    sc.hashLog := hashLog;
    sc.lazy := Ord(level = 3);
    sc.skip := MID_SKIP;
    sc.lazyEnough := MID_LAZY_ENOUGH;
    sc.nextBelow := MID_NEXT_BELOW;
    EmitToC(e, sc.e, src + n);
    if e.v4 then
      sylzc_compress_mid4(@sc)
    else
      sylzc_compress_mid(@sc);
    EmitFromC(e, sc.e);
    Exit(EmitFinish(e, src + sc.anchor, n - sc.anchor));
  end;
{$endif}
  Result := CompressMidCore(src, n, e, ctx.table, ctx.table + (1 shl hashLog),
    hashLog, level = 3);
end;

{ ── levels 4-8: hash chains, lz4hc's parse ──────────────────────────────── }

type
  { Hash-chain match finder state. Fixed field order: HcSearchX64 reads
    it by offset. }
  THcState = record
    src, iend: PByte;         {  0,  8 }
    head: PUInt16;            { 16: last position with this hash, low 16 bits (FastDist) }
    chain: PUInt16;           { 24: distance to the previous position with the same hash }
    nextToInsert: SizeInt;    { 32 }
    pos, lowLimit: SizeInt;   { 40, 48: HcSearch's arguments }
    longest: SizeInt;         { 56: in/out }
    mpos, spos: SizeInt;      { 64, 72: out }
    attempts: SizeInt;        { 80 }
  end;
  PHcState = ^THcState;

procedure HcInsertUpTo(var s: THcState; pos: SizeInt); inline;
var
  i, delta: SizeInt;
  h: UInt32;
  src: PByte;
  head, chain: PUInt16;
begin
  i := s.nextToInsert;
  src := s.src;
  head := s.head;
  chain := s.chain;
  while i < pos do
  begin
    h := Hash4(Read32(src + i), HC_HASHLOG);
    delta := FastDist(i, head[h]);
    if (delta > i) or (delta > HC_MAXDIST) then
      delta := 0;               { 0 terminates the chain }
    chain[i and HC_CHAINMASK] := UInt16(delta);
    head[h] := UInt16(i);
    Inc(i);
  end;
  s.nextToInsert := pos;
end;

{ The head candidate for pos, whose hash is h, or -1. }
function HcHead(const s: THcState; h: UInt32; pos: SizeInt): SizeInt; inline;
begin
  Result := FastDist(pos, s.head[h]);
  if (Result > pos) or (Result > HC_MAXDIST) then
    Result := -1
  else
    Result := pos - Result;
end;

{ The longest match through s.pos longer than s.longest, among s.attempts
  candidates of its hash chain; a match may start before s.pos, back to
  s.lowLimit (with lowLimit = pos, only at pos). Inserts the positions up
  to s.pos first. Returns the new s.longest, with the match's start in
  s.spos and its source in s.mpos when it grew. }
function HcSearchPas(var s: THcState): SizeInt;
var
  ip, ref, src: PByte;
  pos, cand, delta, fwd, back, tries, longest: SizeInt;
  first: UInt32;
begin
  HcInsertUpTo(s, s.pos);
  src := s.src;
  pos := s.pos;
  longest := s.longest;
  ip := src + pos;
  first := Read32(ip);
  cand := HcHead(s, Hash4(first, HC_HASHLOG), pos);
  tries := s.attempts;
  while (tries > 0) and (cand >= 0) and (pos - cand <= HC_MAXDIST) do
  begin
    ref := src + cand;
    if Read32(ref) = first then
    begin
      fwd := SYLZ_MINMATCH + CountMatch(ip + SYLZ_MINMATCH, ref + SYLZ_MINMATCH, s.iend);
      back := 0;
      while (pos - back > s.lowLimit) and (cand - back > 0)
            and (src[pos - back - 1] = src[cand - back - 1]) do
        Inc(back);
      if fwd + back > longest then
      begin
        longest := fwd + back;
        s.mpos := cand - back;
        s.spos := pos - back;
      end;
    end;
    Dec(tries);
    delta := s.chain[cand and HC_CHAINMASK];
    if delta = 0 then
      Break;
    Dec(cand, delta);
  end;
  s.longest := longest;
  Result := longest;
end;

{$ifdef SYLZ_ASM_X64}
{ HcSearchPas in x86_64 assembler, same results (tests check it).
  Registers: r8 src, r9 iend, r10 head, r11 chain, r12 pos, r13 lowLimit,
  r14 longest, r15 tries, rbx candidate, rdi ip; rax, rcx, rdx, rsi
  scratch; the state pointer on the stack ([rsp]). }
procedure HcSearchX64(st: PHcState); assembler; nostackframe;
asm
  push rbx
  push r12
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  push rax                        { [rsp]: state }
  mov r8, [rax]
  mov r9, [rax + 8]
  mov r10, [rax + 16]
  mov r11, [rax + 24]
  mov r12, [rax + 40]
  mov r13, [rax + 48]
  mov r14, [rax + 56]
  mov r15, [rax + 80]
  mov rcx, [rax + 32]
  mov [rax + 32], r12             { nextToInsert = pos }
  { insert the positions before pos }
  cmp rcx, r12
  jae @inserted
@ins:
  mov eax, [r8 + rcx]
  imul eax, eax, -1640531535
  shr eax, 32 - HC_HASHLOG
  movzx edx, word ptr [r10 + rax * 2]
  mov [r10 + rax * 2], cx
  mov esi, ecx
  sub esi, edx
  and esi, $FFFF                  { distance; 0 would be 65536: none }
  xor edx, edx
  cmp rsi, rcx
  cmova esi, edx                  { before the input: none }
  movzx eax, cx
  mov [r11 + rax * 2], si
  add rcx, 1
  cmp rcx, r12
  jb @ins
@inserted:
  lea rdi, [r8 + r12]             { ip }
  mov eax, [rdi]
  imul eax, eax, -1640531535
  shr eax, 32 - HC_HASHLOG
  movzx edx, word ptr [r10 + rax * 2]
  mov eax, r12d
  sub eax, edx
  and eax, $FFFF
  jz @done
  cmp rax, r12
  ja @done
  mov rbx, r12
  sub rbx, rax                    { first candidate }
  test r15, r15
  jle @done

@walk:
  mov eax, [r8 + rbx]
  cmp eax, [rdi]
  jne @next
  { forward length, from 4 on }
  lea rdx, [rdi + SYLZ_MINMATCH]
  lea rsi, [r8 + rbx + SYLZ_MINMATCH]
@cm:
  lea rax, [rdx + 8]
  cmp rax, r9
  ja @cmTail
  mov rax, [rdx]
  xor rax, [rsi]
  jnz @cmDiff
  add rdx, 8
  add rsi, 8
  jmp @cm
@cmDiff:
  bsf rax, rax
  shr eax, 3
  add rdx, rax
  jmp @cmDone
@cmTail:
  cmp rdx, r9
  jae @cmDone
  movzx eax, byte ptr [rdx]
  cmp al, [rsi]
  jne @cmDone
  add rdx, 1
  add rsi, 1
  jmp @cmTail
@cmDone:
  sub rdx, rdi                    { fwd }
  { backwards, down to lowLimit and the start of the input }
  xor ecx, ecx                    { back }
@bk:
  mov rax, r12
  sub rax, rcx
  cmp rax, r13
  jle @bkDone
  mov rsi, rbx
  sub rsi, rcx
  jle @bkDone
  movzx eax, byte ptr [r8 + rax - 1]
  cmp al, [r8 + rsi - 1]
  jne @bkDone
  add rcx, 1
  jmp @bk
@bkDone:
  add rdx, rcx                    { fwd + back }
  cmp rdx, r14
  jle @next
  mov r14, rdx
  mov rsi, [rsp]
  mov rax, rbx
  sub rax, rcx
  mov [rsi + 64], rax             { mpos }
  mov rax, r12
  sub rax, rcx
  mov [rsi + 72], rax             { spos }
@next:
  sub r15, 1
  jz @done
  movzx eax, bx
  movzx eax, word ptr [r11 + rax * 2]
  test eax, eax
  jz @done
  sub rbx, rax
  js @done
  mov rax, r12
  sub rax, rbx
  cmp rax, HC_MAXDIST
  jbe @walk

@done:
  pop rax
  mov [rax + 56], r14
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
end;
{$endif}

{$ifdef SYLZ_C}
procedure sylzc_hc_search(st: PHcState); cdecl; external name 'sylzc_hc_search';
{$endif}

function HcSearch(var s: THcState; pos, lowLimit, longest: SizeInt): SizeInt; inline;
begin
  s.pos := pos;
  s.lowLimit := lowLimit;
  s.longest := longest;
{$ifdef SYLZ_ASM_X64}
  if SylzUseAsm and not SylzPreferC then
  begin
    HcSearchX64(@s);
    Exit(s.longest);
  end;
{$endif}
{$ifdef SYLZ_C}
  if SylzUseAsm then
  begin
    sylzc_hc_search(@s);
    Exit(s.longest);
  end;
{$endif}
  Result := HcSearchPas(s);
end;

{ The parse of levels 4-8 is lz4hc's (LZ4HC_compress_hashChain): after a
  match, search at its end for a "wider" one, which may start inside it
  and extend backwards; with three overlapping candidates, trim the
  earlier ones so each still pays for itself (an overlap is cut at
  HCW_OPTIMAL_ML bytes). Against the plain lazy parse with the same
  attempts, silesia.tar: 4 attempts 39.35% -> 37.74%, 64 attempts 36.89%
  -> 36.38%, at 10-15% less speed per attempt count (far more speed at
  equal ratio). }
const
  HCW_OPTIMAL_ML = 18;

function CompressHCCore(src: PByte; n: SizeInt; var e: TEmit; var s: THcState;
  attempts: Integer): SizeInt;
var
  iend: PByte;
  mfl, pos, anchor, ml, ref, ml0, ref0, start0, ml2, ref2, start2,
    ml3, ref3, start3, newMl, corr, rl, rs, run: SizeInt;
  state: Integer;   { 0 search at pos, 2 / 3 lz4hc's _Search2 / _Search3 }

  function Emit(p, len, r: SizeInt): Boolean;
  begin
    Result := True;
    if len < SYLZ_MINMATCH then
      Exit;   { left as literals }
    Result := EmitSequence(e, src + anchor, p - anchor, p - r, len);
    anchor := p + len;
  end;

begin
  iend := src + n;
  anchor := 0;
  if n >= SEARCH_TAIL + 1 then
  begin
    s.src := src;
    s.iend := iend;
    s.nextToInsert := 0;
    s.attempts := attempts;
    mfl := n - SEARCH_TAIL;
    pos := 0;
    ml := 0; ref := 0; ml0 := 0; ref0 := 0; start0 := 0;
    ml2 := 0; ref2 := 0; start2 := 0; ml3 := 0; ref3 := 0; start3 := 0;
    state := 0;
    while pos < mfl do
    begin
      if state = 0 then
      begin
        if e.v4 then
        begin
          { format v4. A match at the previous offset costs a token and no
            offset bytes: before each search, that offset is tried one
            byte on (as levels 2-3 do: the byte in between is often what
            changed), and its match is taken, back to where it starts,
            unless the chains have one over HC_REP_GAIN bytes longer at
            pos (not searched for from HC_REP_ENOUGH bytes on).
            silesia.tar, level 4: 37.89 -> 37.57%, the searches it saves
            paying for the tests.
            A run of literals is searched every 1 + run shr HC_ACCEL4
            bytes, as the fast levels do: data with nothing to find costs
            a fraction of the time (mixed corpus, level 4: -40% cycles
            for +0.2 points; silesia.tar -5% for +0.03), and a match
            found after a step is extended back over what was stepped
            over. HC_ACCEL4 = 7, not 6: with 6, x-ray came out 130-190
            bytes bigger than v2's at levels 6-8 (mixed corpus 6-12% more
            cycles with 7, still 40-45% under v2's). }
          run := pos - anchor;
          if (e.rep <= pos) and (Read32(src + pos + 1 - e.rep) = Read32(src + pos + 1)) then
          begin
            rs := pos + 1;
            rl := SYLZ_MINMATCH + CountMatch(src + rs + SYLZ_MINMATCH,
              src + rs - e.rep + SYLZ_MINMATCH, iend);
            ml := 0;
            if rl < HC_REP_ENOUGH then
              ml := HcSearch(s, pos, pos, SYLZ_MINMATCH - 1);
            if rl + HC_REP_GAIN >= ml then
            begin
              while (rs > anchor) and (rs > e.rep) and (src[rs - 1] = src[rs - 1 - e.rep]) do
              begin
                Dec(rs);
                Inc(rl);
              end;
              if not Emit(rs, rl, rs - e.rep) then
                Exit(-1);
              pos := rs + rl;
              Continue;
            end;
          end
          else
            ml := HcSearch(s, pos, pos, SYLZ_MINMATCH - 1);
          if ml < SYLZ_MINMATCH then
          begin
            pos := pos + 1 + run shr HC_ACCEL4;
            Continue;
          end;
          ref := s.mpos;
          while (pos > anchor) and (ref > 0) and (src[pos - 1] = src[ref - 1]) do
          begin
            Dec(pos);
            Dec(ref);
            Inc(ml);
          end;
        end
        else
        begin
          ml := HcSearch(s, pos, pos, SYLZ_MINMATCH - 1);
          if ml < SYLZ_MINMATCH then
          begin
            Inc(pos);
            Continue;
          end;
          ref := s.mpos;
        end;
        start0 := pos; ref0 := ref; ml0 := ml;
        state := 2;
      end;
      if state = 2 then
      begin
        if pos + ml <= mfl then
        begin
          ml2 := HcSearch(s, pos + ml - 2, pos, ml);
          ref2 := s.mpos;
          start2 := s.spos;
        end
        else
          ml2 := ml;
        if ml2 = ml then
        begin
          if not Emit(pos, ml, ref) then
            Exit(-1);
          pos := pos + ml;
          state := 0;
          Continue;
        end;
        if (start0 < pos) and (start2 < pos + ml0) then
        begin
          pos := start0; ref := ref0; ml := ml0;
        end;
        if start2 - pos < 3 then
        begin
          ml := ml2; pos := start2; ref := ref2;
          Continue;   { state 2 again }
        end;
        state := 3;
      end;
      { state 3: ml2 > ml, ml >= MINMATCH }
      if start2 - pos < HCW_OPTIMAL_ML then
      begin
        newMl := ml;
        if newMl > HCW_OPTIMAL_ML then
          newMl := HCW_OPTIMAL_ML;
        if pos + newMl > start2 + ml2 - SYLZ_MINMATCH then
          newMl := start2 - pos + ml2 - SYLZ_MINMATCH;
        corr := newMl - (start2 - pos);
        if corr > 0 then
        begin
          Inc(start2, corr); Inc(ref2, corr); Dec(ml2, corr);
        end;
      end;
      if start2 + ml2 <= mfl then
      begin
        ml3 := HcSearch(s, start2 + ml2 - 3, start2, ml2);
        ref3 := s.mpos;
        start3 := s.spos;
      end
      else
        ml3 := ml2;
      if ml3 = ml2 then
      begin
        { no better match: ML1 then ML2 }
        if start2 < pos + ml then
          ml := start2 - pos;
        if not Emit(pos, ml, ref) then
          Exit(-1);
        if not Emit(start2, ml2, ref2) then
          Exit(-1);
        pos := start2 + ml2;
        state := 0;
        Continue;
      end;
      if start3 < pos + ml + 3 then
      begin
        { no room for match 2 }
        if start3 >= pos + ml then
        begin
          if start2 < pos + ml then
          begin
            corr := pos + ml - start2;
            Inc(start2, corr); Inc(ref2, corr); Dec(ml2, corr);
            if ml2 < SYLZ_MINMATCH then
            begin
              start2 := start3; ref2 := ref3; ml2 := ml3;
            end;
          end;
          if not Emit(pos, ml, ref) then
            Exit(-1);
          pos := start3; ref := ref3; ml := ml3;
          start0 := start2; ref0 := ref2; ml0 := ml2;
          state := 2;
          Continue;
        end;
        start2 := start3; ref2 := ref3; ml2 := ml3;
        state := 3;
        Continue;
      end;
      { three ascending matches: write the first }
      if start2 < pos + ml then
      begin
        if start2 - pos < HCW_OPTIMAL_ML then
        begin
          if ml > HCW_OPTIMAL_ML then
            ml := HCW_OPTIMAL_ML;
          if pos + ml > start2 + ml2 - SYLZ_MINMATCH then
            ml := start2 - pos + ml2 - SYLZ_MINMATCH;
          corr := ml - (start2 - pos);
          if corr > 0 then
          begin
            Inc(start2, corr); Inc(ref2, corr); Dec(ml2, corr);
          end;
        end
        else
          ml := start2 - pos;
      end;
      if not Emit(pos, ml, ref) then
        Exit(-1);
      pos := start2; ref := ref2; ml := ml2;
      start2 := start3; ref2 := ref3; ml2 := ml3;
      state := 3;
    end;
  end;
  Result := EmitFinish(e, src + anchor, n - anchor);
end;

{$ifdef SYLZ_C}
type
  { sylzc_hcparse in sylzc.c: fixed field order }
  THcCState = record
    s: PHcState;
    search: Pointer;           { HcSearchX64 or sylzc_hc_search }
    anchor: SizeInt;           { out }
    e: TEmitC;
    cnt: PUInt32;              { v4: e.cnt, counted as the sequences are recorded }
    accel: SizeInt;            { v4: HC_ACCEL4 }
  end;

procedure sylzc_compress_hc(st: Pointer); cdecl; external name 'sylzc_compress_hc';
procedure sylzc_compress_hc4(st: Pointer); cdecl; external name 'sylzc_compress_hc4';
{$endif}

function CompressHC(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; attempts: Integer): SizeInt;
var
  e: TEmit;
  s: THcState;
  i: Integer;
{$ifdef SYLZ_C}
  sc: THcCState;
{$endif}
begin
  if ctx.head = nil then
    ctx.head := GetMem(SizeOf(UInt16) shl HC_HASHLOG);
  if ctx.chain = nil then
    ctx.chain := GetMem(SizeOf(UInt16) * HC_CHAINSIZE);
  s.head := ctx.head;
  s.chain := ctx.chain;
  for i := 0 to (1 shl HC_HASHLOG) - 1 do
    s.head[i] := 0;
  EmitInit(e, dst, cap, ctx.scratch, src + n, ctx.flags, ctx.offs, ctx.recs);
  e.roomy := cap >= SylzBound(n);
{$ifdef SYLZ_C}
  { the parse in C (FPC kept its many live values on the stack), over the
    assembler chain search on x86_64 }
  if SylzUseAsm and (cap >= SylzBound(n)) and (n >= SEARCH_TAIL + 1) then
  begin
    s.src := src;
    s.iend := src + n;
    s.nextToInsert := 0;
    s.attempts := attempts;
    sc.s := @s;
    sc.search := @sylzc_hc_search;
{$ifdef SYLZ_ASM_X64}
    if not SylzPreferC then
      sc.search := @HcSearchX64;
{$endif}
    EmitToC(e, sc.e, src + n);
    if e.v4 then
    begin
      e.counted := True;
      FillChar(e.cnt, SizeOf(e.cnt), 0);
      sc.cnt := @e.cnt[0, 0, 0];
      sc.accel := HC_ACCEL4;
      sylzc_compress_hc4(@sc);
    end
    else
      sylzc_compress_hc(@sc);
    EmitFromC(e, sc.e);
    Exit(EmitFinish(e, src + sc.anchor, n - sc.anchor));
  end;
{$endif}
  Result := CompressHCCore(src, n, e, s, attempts);
end;

{ ── optimal parser ──────────────────────────────────────────────────────── }

{ A forward dynamic program over windows of OPT_WINDOW positions: node i is
  the cheapest way found to encode up to window position i, with its
  pending literal count. Each position offers one literal and, for every
  match candidate, every match length up to the candidate's (each length
  priced with the nearest candidate that reaches it). The price is in
  bytes plus decode-time penalties (TSylzOptParams), so the parse can
  trade a byte for fewer, cheaper sequences. A match of `sufficient`
  bytes or more is taken as is, which keeps repetitive data linear. }

const
  OPT_WINDOW  = 4096;
  OPT_MAXCAND = 64;
  OPT_NOSKIP  = High(Int32);
  OPT_FORCED_KEEP4 = 64;   { see CompressOptCore }
  OPT_FORCED_STEP4 = 4;


type
  TSylzOptParams = record
    btCut: Integer;             { match finder: binary tree depth }
    btMaxLen: Integer;          { its longest compared match }
    sufficient: Integer;        { a match at least this long is taken as is }
    pSeq, pEsc, pShort: Single; { decode-time penalties, in bytes: per
                                  sequence, per escape token, per offset < 16 }
    subLen: Integer;            { every match length up to this is tried; past
                                  it, only each candidate's full length (format
                                  v4: under OPT4_COLS, sylzc_opt_dp4 prices
                                  them from the table without a test) }
    skipLen: Integer;           { after a match this long, the positions it
                                  covers start no transitions of their own }
    minRep: Integer;            { format v4: the shortest match tried at the
                                  previous offset }
  end;

const
  { Levels 9 and 10 (silesia.tar, NOTES.md): 36.04% and 36.03%, where the
    hash-chain versions made 36.37% and 36.12% at half the speed; level
    10's depth pays on very redundant data (zpaq-std's mixed sample:
    17.73% -> 17.59%). Depth 16 was too shallow there (17.93%, worse than
    level 8's 17.71%). Mild
    penalties (half a byte per sequence) buy decode speed almost for free
    (pure byte prices: 0.01 points smaller, ~4% slower to decode); past
    depth 128 and matches of 1024 the ratio stops improving; skipping
    inside long matches costs more ratio than it saves time. }
  OPT_LEVEL9: TSylzOptParams = (btCut: 32; btMaxLen: 256; sufficient: 128;
    pSeq: 0.5; pEsc: 1.0; pShort: 0.5; subLen: 36; skipLen: OPT_NOSKIP; minRep: 2);
  OPT_LEVEL10: TSylzOptParams = (btCut: 256; btMaxLen: 1024; sufficient: 512;
    pSeq: 0.5; pEsc: 1.0; pShort: 0.5; subLen: 36; skipLen: OPT_NOSKIP; minRep: 2);
  { Formats v4 and v5 at level 10: depth 128 finds what 256 does
    (silesia.tar, the mixed corpus, nci, xml: within 0.004 points) in
    3-4% fewer cycles, a margin over v2's speed at this level. }
  OPT4_LEVEL10: TSylzOptParams = (btCut: 128; btMaxLen: 1024; sufficient: 512;
    pSeq: 0.5; pEsc: 1.0; pShort: 0.5; subLen: 36; skipLen: OPT_NOSKIP; minRep: 2);

{ Level 10's parameters for the format flags asks for. }
function OptLevel10(flags: Integer): TSylzOptParams;
begin
  if flags and SYLZ_V4 <> 0 then
    Result := OPT4_LEVEL10
  else
    Result := OPT_LEVEL10;
end;

type
  TOptNode = record
    cost: Int32;    { in bits, relative to the window's start }
    ll: Int32;      { pending literals at this node }
    ml: Int32;      { 0: reached by a literal, else by a match of ml bytes }
    dist: Int32;    { the match's distance; format v4: of the path's last
                      match, whatever reached the node }
  end;
  POptNode = ^TOptNode;

const
  OPT_NODES_BYTES = (OPT_WINDOW + 1) * SizeOf(TOptNode);
  { every position's candidates, at most OPT_MAXCAND pairs each }
  OPT_CANDS_BYTES = OPT_WINDOW * OPT_MAXCAND * 2 * SizeOf(Int32);
  OPT_PATH_BYTES  = (OPT_WINDOW + 1) * 3 * SizeOf(Int32);
  OPT_INDEX_BYTES = (OPT_WINDOW + 1) * SizeOf(Int32);   { off, cnt }
  OPT_WORK_BYTES  = OPT_NODES_BYTES + OPT_CANDS_BYTES + OPT_PATH_BYTES
                    + 2 * OPT_INDEX_BYTES;   { off, cnt }

{ The optimal parser's match finder: a binary tree (LZMA's bt4 without
  its 2- and 3-byte hashes). Every position is inserted into a binary
  search tree of the window's suffixes, rooted per 4-byte hash, and
  walking down to insert it meets the longest matches, so it is nearly
  exhaustive at a fixed cost per position. Against the hash chain it
  replaced (silesia.tar): depth 16 made 36.18% where 64 chain attempts
  made 36.37% and 1024 made 36.05% at 1 MB/s; depth 32 made 36.09%. }
const
  BT_HASHLOG = 16;
  BT_WINDOW = 65536;           { cyclic: son pairs of the last 64 KiB }

type
  { Fixed field order: BtInsertX64 reads it by offset. }
  TBtState = record
    src, iend: PByte;          {  0,  8 }
    head: PUInt32;             { 16: root per hash: position + 1, 0 = none }
    son: PUInt32;              { 24: two links per cyclic position }
    nextToInsert: SizeInt;     { 32 }
    cut, maxLen: SizeInt;      { 40, 48 }
    pos: SizeInt;              { 56: BtInsertX64's arguments }
    cands: PInt32;             { 64 }
    count: SizeInt;            { 72: out }
  end;
  PBtState = ^TBtState;

{ Inserts pos; with cands <> nil, records every match longer than the
  previous one, shortest first, as (length, distance) pairs. }
function BtInsertPas(var b: TBtState; pos: SizeInt; cands: PInt32): Integer;
var
  cur, pb: PByte;
  h: UInt32;
  curMatch, delta, len, len0, len1, lenLimit, maxLen, cut: SizeInt;
  ptr0, ptr1, pair: PUInt32;
begin
  Result := 0;
  cur := b.src + pos;
  lenLimit := b.iend - cur;
  if lenLimit > b.maxLen then
    lenLimit := b.maxLen;
  h := Hash4(Read32(cur), BT_HASHLOG);
  curMatch := SizeInt(b.head[h]) - 1;
  b.head[h] := UInt32(pos + 1);
  ptr0 := b.son + ((pos and (BT_WINDOW - 1)) shl 1) + 1;
  ptr1 := b.son + ((pos and (BT_WINDOW - 1)) shl 1);
  len0 := 0;
  len1 := 0;
  maxLen := SYLZ_MINMATCH - 1;
  cut := b.cut;
  while True do
  begin
    delta := pos - curMatch;
    if (curMatch < 0) or (cut = 0) or (delta >= BT_WINDOW) then
    begin
      ptr0^ := 0;
      ptr1^ := 0;
      Exit;
    end;
    Dec(cut);
    pair := b.son + ((curMatch and (BT_WINDOW - 1)) shl 1);
    pb := cur - delta;
    len := len0;
    if len1 < len then
      len := len1;
    if pb[len] = cur[len] then
    begin
      Inc(len);
      while (len < lenLimit) and (pb[len] = cur[len]) do
        Inc(len);
      if len > maxLen then
      begin
        maxLen := len;
        if (cands <> nil) and (Result < OPT_MAXCAND) then
        begin
          cands[2 * Result] := Int32(len);
          cands[2 * Result + 1] := Int32(delta);
          Inc(Result);
        end;
        if len >= lenLimit then
        begin
          ptr1^ := pair[0];
          ptr0^ := pair[1];
          Exit;
        end;
      end;
    end;
    if pb[len] < cur[len] then
    begin
      ptr1^ := UInt32(curMatch + 1);
      ptr1 := pair + 1;
      curMatch := SizeInt(ptr1^) - 1;
      len1 := len;
    end
    else
    begin
      ptr0^ := UInt32(curMatch + 1);
      ptr0 := pair;
      curMatch := SizeInt(ptr0^) - 1;
      len0 := len;
    end;
  end;
end;

{$ifdef SYLZ_ASM_X64}
{ BtInsertPas in x86_64 assembler, same results (tests check it).
  Registers: rdi cur, r8 son, r9 length limit, r10 ptr0, r11 ptr1, r12
  len0, r13 len1, r14 longest so far, r15 cut, rbx candidate, rbp count
  (a plain value: FPC reads [rbp + n] as a frame access, so never an
  address), rsi pair, rdx candidate bytes, rcx length; rax scratch.
  Stack: [rsp] state, [rsp+8] pos, [rsp+16] cands. }
procedure BtInsertX64(st: PBtState); assembler; nostackframe;
asm
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx
{$else}
  mov rax, rdi
{$endif}
  push qword ptr [rax + 64]       { [rsp+16] cands }
  push qword ptr [rax + 56]       { [rsp+8] pos }
  push rax                        { [rsp] state }
  mov rdi, [rax]
  add rdi, [rax + 56]             { cur = src + pos }
  mov r9, [rax + 8]
  sub r9, rdi                     { iend - cur }
  cmp r9, [rax + 48]
  jbe @limOk
  mov r9, [rax + 48]
@limOk:
  mov r8, [rax + 24]              { son }
  mov r15, [rax + 40]             { cut }
  mov ecx, [rdi]
  imul ecx, ecx, -1640531535
  shr ecx, 32 - BT_HASHLOG
  mov rdx, [rax + 16]             { head }
  mov ebx, [rdx + rcx * 4]
  sub rbx, 1                      { candidate, -1 = none }
  mov rsi, [rsp + 8]
  lea eax, [rsi + 1]
  mov [rdx + rcx * 4], eax        { head = pos + 1 }
  and esi, BT_WINDOW - 1
  lea r11, [r8 + rsi * 8]         { ptr1 = son[2 * cyc] }
  lea r10, [r11 + 4]              { ptr0 = son[2 * cyc + 1] }
  xor r12d, r12d
  xor r13d, r13d
  mov r14d, SYLZ_MINMATCH - 1
  xor ebp, ebp

@loop:
  test rbx, rbx
  js @stop
  test r15, r15
  jz @stop
  mov rax, [rsp + 8]
  sub rax, rbx                    { delta }
  cmp rax, BT_WINDOW
  jae @stop
  sub r15, 1
  mov esi, ebx
  and esi, BT_WINDOW - 1
  lea rsi, [r8 + rsi * 8]         { pair }
  mov rdx, rdi
  sub rdx, rax                    { pb = cur - delta }
  mov rcx, r12
  cmp r13, rcx
  cmovb rcx, r13                  { len = min(len0, len1) }
  movzx eax, byte ptr [rdx + rcx]
  cmp al, [rdi + rcx]
  jne @cmpOrder
  add rcx, 1
@ext8:
  lea rax, [rcx + 8]
  cmp rax, r9
  ja @ext1
  mov rax, [rdx + rcx]
  xor rax, [rdi + rcx]
  jnz @extDiff
  add rcx, 8
  jmp @ext8
@extDiff:
  bsf rax, rax
  shr eax, 3
  add rcx, rax
  jmp @extDone
@ext1:
  cmp rcx, r9
  jae @extDone
  movzx eax, byte ptr [rdx + rcx]
  cmp al, [rdi + rcx]
  jne @extDone
  add rcx, 1
  jmp @ext1
@extDone:
  cmp rcx, r14
  jbe @cmpOrder
  mov r14, rcx                    { a longer match }
  mov rax, [rsp + 16]
  test rax, rax
  jz @noRecord
  cmp rbp, OPT_MAXCAND
  jae @noRecord
  mov [rax + rbp * 8], ecx        { length }
  push rcx
  mov rcx, [rsp + 16]             { pos (one push deeper) }
  sub rcx, rbx
  mov [rax + rbp * 8 + 4], ecx    { distance }
  pop rcx
  add rbp, 1
@noRecord:
  cmp rcx, r9
  jb @cmpOrder
  { as long as allowed: the new node takes over the old one's subtrees }
  mov eax, [rsi]
  mov [r11], eax
  mov eax, [rsi + 4]
  mov [r10], eax
  jmp @done
@cmpOrder:
  movzx eax, byte ptr [rdx + rcx]
  cmp al, [rdi + rcx]
  jae @right
  lea eax, [rbx + 1]
  mov [r11], eax                  { ptr1^ = candidate + 1 }
  lea r11, [rsi + 4]
  mov ebx, [r11]
  sub rbx, 1
  mov r13, rcx
  jmp @loop
@right:
  lea eax, [rbx + 1]
  mov [r10], eax                  { ptr0^ = candidate + 1 }
  mov r10, rsi
  mov ebx, [r10]
  sub rbx, 1
  mov r12, rcx
  jmp @loop
@stop:
  mov dword ptr [r10], 0
  mov dword ptr [r11], 0
@done:
  pop rax
  mov [rax + 72], rbp
  add rsp, 16
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
end;
{$endif}

{$ifdef SYLZ_C}
procedure sylzc_bt_insert(st: PBtState); cdecl; external name 'sylzc_bt_insert';
{$endif}

function BtInsert(var b: TBtState; pos: SizeInt; cands: PInt32): Integer; inline;
begin
  b.pos := pos;
  b.cands := cands;
{$ifdef SYLZ_ASM_X64}
  if SylzUseAsm and not SylzPreferC then
    BtInsertX64(@b)
  else
{$endif}
{$ifdef SYLZ_C}
  if SylzUseAsm then
    sylzc_bt_insert(@b)
  else
{$endif}
    b.count := BtInsertPas(b, pos, cands);
  Result := Integer(b.count);
end;

function BtFindAll(var b: TBtState; pos: SizeInt; cands: PInt32): Integer;
var
  len, dist: SizeInt;
  cur: PByte;
begin
  while b.nextToInsert < pos do
  begin
    BtInsert(b, b.nextToInsert, nil);
    Inc(b.nextToInsert);
  end;
  Result := BtInsert(b, pos, cands);
  { the tree compares up to maxLen bytes: a match that reached it goes on
    as far as the bytes do (in a long run, maxLen-byte pieces would cost
    a sequence each) }
  if Result > 0 then
  begin
    len := cands[2 * (Result - 1)];
    if len >= b.maxLen then
    begin
      dist := cands[2 * (Result - 1) + 1];
      cur := b.src + pos;
      Inc(len, CountMatch(cur + len, cur + len - dist, b.iend));
      cands[2 * (Result - 1)] := Int32(len);
    end;
  end;
  b.nextToInsert := pos + 1;
end;

function ExtBytes(v: SizeInt): SizeInt; inline;
begin
  Result := v div 255 + 1;
end;

{ Prices, in bytes plus decode penalties, split the way EmitSequence
  encodes. A run of ll pending literals is priced as it grows (a literal
  byte each, plus the literal extension and the escape penalty once the run
  passes EXACT_LL), so a node's price already covers its pending literals
  and comparing nodes with different runs is fair. Charging the literal
  extension to the match that ends a run instead made a match after a long
  run look prohibitive, and the parse then never ended a run. }
{ Prices are integers in bits (OPT_SCALE per byte): the penalties are
  multiples of a quarter, so the sums are exact, as they were in Single,
  and the DP picks the same path, without the float code FPC compiled
  poorly. }
const
  OPT_SCALE = 8;
  OPT_MTAB_COLS = 64;   { match lengths priced from a table: MINMATCH .. +63 }

type
  TOptPrices = record
    seq, esc, short: Int32;    { penalties, in quarter bytes }
  end;

{ The price of growing a literal run of ll to ll + 1. }
function LitStep(ll: SizeInt; const q: TOptPrices): Int32; inline;
begin
  if ll < EXACT_LL then
    Result := OPT_SCALE
  else if ll = EXACT_LL then   { the run becomes an extension and an escape }
    Result := OPT_SCALE * (1 + ExtBytes(ll + 1)) + q.esc
  else
    Result := OPT_SCALE * (1 + ExtBytes(ll + 1) - ExtBytes(ll));
end;

{ The match's share of a sequence: ll is the pending run, already priced. }
function MatchCost(ll, ml, dist: SizeInt; const q: TOptPrices): Int32; inline;
var
  m: SizeInt;
begin
  m := ml - SYLZ_MINMATCH;
  if ll <= EXACT_LL then
  begin
    if (m <= EXACT_M) and (ExactCode[ll, m] <> 255) then
      Result := OPT_SCALE * 3 + q.seq
    else
      Result := OPT_SCALE * (3 + ExtBytes(m)) + q.seq + q.esc;   { ESC_ML }
  end
  else if m <= EXACT_M then
    Result := OPT_SCALE * 3 + q.seq                             { ESC_LL, paid by the run }
  else
    Result := OPT_SCALE * (3 + ExtBytes(m)) + q.seq;            { ESC_BOTH }
  if dist < 16 then
    Inc(Result, q.short);
end;

type
  { What the DP needs besides the window; fixed layout, the C version
    (sylzc_dpargs in sylzc.c) reads it. }
  TOptDpArgs = record
    exactLL, minMatch, mtabCols, subLen: Int32;
    seq, esc, short: Int32;     { penalties, bits }
    scale: Int32;               { OPT_SCALE }
    litPrice: PInt32;           { a literal's price by byte value, bits }
    wsrc: PByte;                { the window's input }
  end;
  POptDpArgs = ^TOptDpArgs;

{ The forward DP over one window of w positions: nodes[0] is set and
  nodes[1..w].cost are High(Int32). Position i has cnt[i] candidates at
  cands[2 * off[i]], (length, distance) pairs, longest last; cnt[i] < 0:
  inside a skipped match, no transitions at all. mtab: match prices
  without the short-offset penalty, by pending run (row EXACT_LL + 1: any
  longer run) and length - MINMATCH. }
procedure OptDpPas(nodes: POptNode; w: SizeInt; cands, off, cnt, mtab: PInt32;
  const a: TOptDpArgs);
var
  i, j, k, c, ml, len, dist, prevLen, ll: SizeInt;
  cost, tc, base: Int32;
  row, cp: PInt32;
  q: TOptPrices;
begin
  q.seq := a.seq;
  q.esc := a.esc;
  q.short := a.short;
  for i := 0 to w - 1 do
  begin
    k := cnt[i];
    if k < 0 then
      Continue;
    cost := nodes[i].cost;
    ll := nodes[i].ll;
    { the byte's price, and what the run's growing costs beyond a byte }
    tc := cost + a.litPrice[a.wsrc[i]] + LitStep(ll, q) - OPT_SCALE;
    if tc < nodes[i + 1].cost then
    begin
      nodes[i + 1].cost := tc;
      nodes[i + 1].ll := Int32(ll + 1);
      nodes[i + 1].ml := 0;
    end;
    if k = 0 then
      Continue;
    if ll > EXACT_LL then
      row := mtab + (EXACT_LL + 1) * OPT_MTAB_COLS
    else
      row := mtab + ll * OPT_MTAB_COLS;
    cp := cands + 2 * off[i];
    prevLen := SYLZ_MINMATCH - 1;
    for c := 0 to k - 1 do
    begin
      len := cp[2 * c];
      dist := cp[2 * c + 1];
      base := cost;
      if dist < 16 then
        Inc(base, q.short);
      ml := prevLen;
      while ml < len do
      begin
        { every length up to subLen, then straight to the full one }
        if ml < a.subLen then
          Inc(ml)
        else
          ml := len;
        j := i + ml;
        if j > w then
          Break;
        if ml < SYLZ_MINMATCH + OPT_MTAB_COLS then
          tc := base + row[ml - SYLZ_MINMATCH]
        else
          tc := cost + MatchCost(ll, ml, dist, q);
        if tc < nodes[j].cost then
        begin
          nodes[j].cost := tc;
          nodes[j].ll := 0;
          nodes[j].ml := Int32(ml);
          nodes[j].dist := Int32(dist);
        end;
      end;
      prevLen := len;
    end;
  end;
end;

{ ── format v4's prices ── }

const
  { mtab4: [kind, row, match length]: rows 0..LIT_SPLIT4 by the literals
    before the match, row OPT4_ROW_LONG after a run over LIT_SPLIT4 (an
    extension: no literals left for the match's token) }
  OPT4_ROW_LONG = LIT_SPLIT4 + 1;
  OPT4_ROWS = LIT_SPLIT4 + 2;
  OPT4_COLS = 2 * MAX_ML4 + 2;   { lengths 0 .. 2 * MAX_ML4 + 1 }
  OPT4_NEVER = High(Int32) div 4;
  { Off the price of a pair with no code of its own (two tokens), in
    bytes: the chunk's update gives codes to the pairs the parse uses, so
    at the full price the parse keeps to the table it started with and
    the table never learns. Level 9, twelve Silesia files, off 0 / 0.5 /
    0.75 / 1: 74 049 235, 73 968 067, 73 937 832, 73 963 946 bytes; -ec 9,
    off 0 / 0.75 / 1 / 1.25: 68 666 254, 68 547 466, 68 555 596,
    68 568 476. }
  OPT4_MISS = 0.75;

type
  { What format v4's DP needs besides the window; fixed layout, the C
    version (sylzc_dp4args in sylzc.c) reads it. }
  TOptDp4Args = record
    subLen, minRep: Int32;
    seq, esc, short: Int32;     { penalties, bits }
    scale: Int32;               { OPT_SCALE }
    miss: Int32;                { OPT4_MISS, bits }
    litPrice: PInt32;           { a literal's price by byte value, bits }
    wsrc: PByte;                { the window's input }
    before: SizeInt;            { input bytes before the window }
    mtab: PInt32;               { mtab4 }
    codes: Pointer;             { Codes4 }
  end;
  POptDp4Args = ^TOptDp4Args;

{ The row of mtab4 for a pending run of ll literals. }
function Opt4Row(ll: SizeInt): SizeInt; inline;
begin
  if ll <= LIT_SPLIT4 then
    Result := ll
  else
    Result := OPT4_ROW_LONG;
end;

{ What growing a literal run from ll to ll + 1 costs beyond the byte: the
  literal-only token of a run over MAX_LL4, then the extension that
  replaces it past LIT_SPLIT4 (PutTokens4). }
function LitStep4(ll: SizeInt; const a: TOptDp4Args): Int32; inline;
begin
  if ll < LIT_SPLIT4 then
  begin
    if ll = MAX_LL4 then
      Result := a.scale + a.seq
    else
      Result := 0;
  end
  else if ll = LIT_SPLIT4 then
    Result := a.scale * ExtBytes(ll + 1) + a.esc
  else
    Result := a.scale * (ExtBytes(ll + 1) - ExtBytes(ll));
end;

{ The match's share of a sequence as PutTokens4 codes it: its tokens,
  its offset bytes (kind 0), its extension; row as Opt4Row gives it (the
  literal-only token of a run over MAX_LL4 is in LitStep4's price). A
  match under SYLZ_MINMATCH at the previous offset is only worth a token
  of its own: with none, never. }
function MatchCost4(row, ml, kind: SizeInt; const a: TOptDp4Args): Int32;
var
  tok: Int32;
  l, b, m: SizeInt;
  c: ^TCodes4;
begin
  c := a.codes;
  tok := a.scale + a.seq;
  l := row;
  if row = OPT4_ROW_LONG then
    l := 0;
  Result := 0;
  if kind = 0 then
    Result := 2 * a.scale;
  if (row = OPT4_ROW_LONG) and (ml > MAX_ML4) and (c^[kind, ROW4_EXT, COL4_EXT] <> 255) then
  begin
    { the run's token is the match's too, with a second extension }
    Inc(Result, a.scale * Int32(ExtBytes(ml - MINML4[kind])));
    Exit;
  end;
  if ml > ML_SPLIT4 then
  begin
    { the literals in the escape's token where it has that code }
    if l > MAX_LL4 then
      Dec(l, MAX_LL4);
    if (l > 0) and (c^[kind, l, COL4_EXT] = 255) then
      Inc(Result, tok);
    Inc(Result, tok + a.scale * Int32(ExtBytes(ml - MINML4[kind])) + a.esc);
    Exit;
  end;
  { what is left of a match over MAX_ML4: a token at the previous offset }
  if ml > MAX_ML4 then
    Inc(Result, tok);
  if (row = OPT4_ROW_LONG) and (ml <= MAX_ML4) and (c^[kind, ROW4_EXT, ml] <> 255) then
    { the run's token is the match's too }
  else if FindSplit4(c^, kind, l, ml, b, m) then
    Inc(Result, tok)
  else if ml < SYLZ_MINMATCH then
    Result := OPT4_NEVER
  else
    Inc(Result, 2 * tok - a.miss);
  if (row = OPT4_ROW_LONG) and (ml < SYLZ_MINMATCH) then
    Result := OPT4_NEVER;   { an extended run and 2 or 3 bytes: SylzBound }
end;

{ OptDpPas for format v4. Each node carries the distance of the last
  match on its path (its dist, nodes[0]'s set by the caller), which a
  match can take again for a token and no offset bytes: tried first at
  every position, every length from a.minRep. Its first bytes are
  compared before the match is counted: most positions have none. }
procedure OptDp4Pas(nodes: POptNode; w: SizeInt; cands, off, cnt: PInt32;
  const a: TOptDp4Args);
var
  i, j, k, c, ml, len, dist, prevLen, ll, r, rl, row: SizeInt;
  cost, tc, base: Int32;
  rowN, rowR, cp: PInt32;
begin
  for i := 0 to w - 1 do
  begin
    k := cnt[i];
    if k < 0 then
      Continue;
    cost := nodes[i].cost;
    ll := nodes[i].ll;
    r := nodes[i].dist;
    tc := cost + a.litPrice[a.wsrc[i]] + LitStep4(ll, a);
    if tc < nodes[i + 1].cost then
    begin
      nodes[i + 1].cost := tc;
      nodes[i + 1].ll := Int32(ll + 1);
      nodes[i + 1].ml := 0;
      nodes[i + 1].dist := Int32(r);
    end;
    row := Opt4Row(ll);
    rowN := a.mtab + row * OPT4_COLS;
    rowR := rowN + OPT4_ROWS * OPT4_COLS;
    { the previous distance }
    if (r <= a.before + i)
       and (((a.minRep >= 4) and (Read32(a.wsrc + i) = Read32(a.wsrc + i - r)))
            or ((a.minRep < 4) and (PUInt16(a.wsrc + i)^ = PUInt16(a.wsrc + i - r)^))) then
    begin
      rl := CountMatch(a.wsrc + i, a.wsrc + i - r, a.wsrc + w);
      if rl >= a.minRep then
      begin
        base := cost;
        if r < 16 then
          Inc(base, a.short);
        ml := a.minRep - 1;
        while ml < rl do
        begin
          if ml < a.subLen then
            Inc(ml)
          else
            ml := rl;
          j := i + ml;
          if ml < OPT4_COLS then
            tc := base + rowR[ml]
          else
            tc := base + MatchCost4(row, ml, 1, a);
          if tc < nodes[j].cost then
          begin
            nodes[j].cost := tc;
            nodes[j].ll := 0;
            nodes[j].ml := Int32(ml);
            nodes[j].dist := Int32(r);
          end;
        end;
      end;
    end;
    if k = 0 then
      Continue;
    cp := cands + 2 * off[i];
    prevLen := SYLZ_MINMATCH - 1;
    for c := 0 to k - 1 do
    begin
      len := cp[2 * c];
      dist := cp[2 * c + 1];
      if dist = r then
      begin
        prevLen := len;   { priced above, at least as long }
        Continue;
      end;
      base := cost;
      if dist < 16 then
        Inc(base, a.short);
      ml := prevLen;
      while ml < len do
      begin
        if ml < a.subLen then
          Inc(ml)
        else
          ml := len;
        j := i + ml;
        if j > w then
          Break;
        if ml < OPT4_COLS then
          tc := base + rowN[ml]
        else
          tc := base + MatchCost4(row, ml, 0, a);
        if tc < nodes[j].cost then
        begin
          nodes[j].cost := tc;
          nodes[j].ll := 0;
          nodes[j].ml := Int32(ml);
          nodes[j].dist := Int32(dist);
        end;
      end;
      prevLen := len;
    end;
  end;
end;

{$ifdef SYLZ_C}
procedure sylzc_opt_dp(nodes: POptNode; w: Int32; cands, off, cnt, mtab: PInt32;
  a: POptDpArgs); cdecl; external name 'sylzc_opt_dp';
procedure sylzc_opt_dp4(nodes: POptNode; w: Int32; cands, off, cnt: PInt32;
  a: POptDp4Args); cdecl; external name 'sylzc_opt_dp4';

type
  { sylzc_optcands in sylzc.c: fixed field order }
  TOptCandsC = record
    b: PBtState;
    insert: Pointer;           { BtInsertX64 or sylzc_bt_insert }
    start, w: SizeInt;
    sufficient, skipLen: SizeInt;
    cands, off, cnt: PInt32;
    forced, forcedLen, forcedDist: SizeInt;
  end;

procedure sylzc_opt_cands(st: Pointer); cdecl; external name 'sylzc_opt_cands';
{$endif}

{ Each window in three passes: the candidates of every position (the
  binary tree), the DP over them (OptDpPas, or its C version), and the
  cheapest path, emitted. }
const
  { regions of the input with their own literal prices (format v3's
    entropy-aware levels): 256 KiB; 64 KiB, closer to the literal chunks,
    did no better (silesia.tar 33.72 vs 33.70% without the penalty) }
  OPT_REGION_SHIFT = 18;
  { added to each literal's code length: the first parse's lengths miss the
    chunk's table and the second parse's own literals; 1 bit made both a
    smaller output (silesia.tar 33.70 -> 33.60%) and a faster decode, 2
    bits decode as fast as level 8's parse but give the gain back }
  OPT_LIT_PENALTY = 1;

{ Count the literals of src[from..upto) into hist, by region. }
procedure CountLiterals(src: PByte; from, upto: SizeInt; hist: PUInt32);
var
  i: SizeInt;
begin
  for i := from to upto - 1 do
    Inc(hist[(i shr OPT_REGION_SHIFT) * 256 + src[i]]);
end;

{ prices: per region of 2^OPT_REGION_SHIFT input bytes, 256 literal prices
  in bits (nil: 8 bits each, format v2's byte). hist: when set, nothing is
  emitted; the parse's literals are counted into it by region instead. }
function CompressOptCore(src: PByte; n: SizeInt; var e: TEmit; var b: TBtState;
  work: PByte; const p: TSylzOptParams; prices: PInt32; hist: PUInt32): SizeInt;
var
  nodes: POptNode;
  cands, path, off, cnt: PInt32;
  limit, anchor, start, w, i, j, k, len, npath, t, total,
    pos, forcedLen, forcedDist: SizeInt;
  forced: Boolean;
  q: TOptPrices;
  a: TOptDpArgs;
  flat: array[0..255] of Int32;
{$ifdef SYLZ_C}
  oc: TOptCandsC;
{$endif}
  { match prices without the short-offset penalty, by pending run (row
    EXACT_LL + 1: any longer run) and length - MINMATCH }
  mtab: array[0..EXACT_LL + 1, 0..OPT_MTAB_COLS - 1] of Int32;
  { format v4 }
  a4: TOptDp4Args;
  mtab4: array[0..1, 0..OPT4_ROWS - 1, 0..OPT4_COLS - 1] of Int32;
  lastDist, mtabGen: SizeInt;
begin
  q.seq := Round(p.pSeq * OPT_SCALE);
  q.esc := Round(p.pEsc * OPT_SCALE);
  q.short := Round(p.pShort * OPT_SCALE);
  for i := 0 to EXACT_LL + 1 do
    for j := 0 to OPT_MTAB_COLS - 1 do
      mtab[i, j] := MatchCost(i, j + SYLZ_MINMATCH, 16, q);
  a.exactLL := EXACT_LL;
  a.minMatch := SYLZ_MINMATCH;
  a.mtabCols := OPT_MTAB_COLS;
  a.subLen := p.subLen;
  a.seq := q.seq;
  a.esc := q.esc;
  a.short := q.short;
  a.scale := OPT_SCALE;
  for i := 0 to 255 do
    flat[i] := OPT_SCALE;
  a.litPrice := @flat[0];
  nodes := POptNode(work);
  cands := PInt32(work + OPT_NODES_BYTES);
  path := PInt32(work + OPT_NODES_BYTES + OPT_CANDS_BYTES);
  off := PInt32(work + OPT_NODES_BYTES + OPT_CANDS_BYTES + OPT_PATH_BYTES);
  cnt := off + (OPT_WINDOW + 1);
  lastDist := 1;
  if e.v4 then
  begin
    a4.subLen := p.subLen;
    a4.minRep := p.minRep;
    a4.seq := q.seq;
    a4.esc := q.esc;
    a4.short := q.short;
    a4.scale := OPT_SCALE;
    a4.miss := Round(OPT4_MISS * OPT_SCALE);
    a4.litPrice := @flat[0];
    a4.codes := @e.codes;
    mtabGen := 0;
    a4.mtab := @mtab4[0, 0, 0];
    for k := 0 to 1 do
      for i := 0 to OPT4_ROWS - 1 do
        for j := 0 to OPT4_COLS - 1 do
          if j < MINML4[k] then
            mtab4[k, i, j] := OPT4_NEVER
          else
            mtab4[k, i, j] := MatchCost4(i, j, k, a4);
  end;
{$ifdef SYLZ_C}
  oc.b := @b;
  oc.insert := @sylzc_bt_insert;
{$ifdef SYLZ_ASM_X64}
  if not SylzPreferC then
    oc.insert := @BtInsertX64;
{$endif}
  oc.sufficient := p.sufficient;
  oc.skipLen := p.skipLen;
  oc.cands := cands;
  oc.off := off;
  oc.cnt := cnt;
{$endif}
  anchor := 0;
  if n >= SEARCH_TAIL + 1 then
  begin
    limit := n - SEARCH_TAIL;
    start := 0;
    while start < limit do
    begin
      w := OPT_WINDOW;
      if start + w > limit then
        w := limit - start;

      { 1: candidates }
      forced := False;
      forcedLen := 0;
      forcedDist := 0;
{$ifdef SYLZ_C}
      if SylzUseAsm then
      begin
        { in C: FPC kept BtFindAll's and this loop's values on the stack }
        oc.start := start;
        oc.w := w;
        sylzc_opt_cands(@oc);
        w := oc.w;
        forced := oc.forced <> 0;
        forcedLen := oc.forcedLen;
        forcedDist := oc.forcedDist;
      end
      else
{$endif}
      begin
      total := 0;
      i := 0;
      while i < w do
      begin
        k := BtFindAll(b, start + i, cands + 2 * total);
        off[i] := Int32(total);
        cnt[i] := Int32(k);
        if k > 0 then
        begin
          len := cands[2 * (total + k - 1)];
          if len >= p.sufficient then
          begin
            forced := True;
            forcedLen := len;
            forcedDist := cands[2 * (total + k - 1) + 1];
            w := i;
            Break;
          end;
          Inc(total, k);
          { inside a long match, searching every position costs a lot and
            rarely finds a better parse: skip to its end. Only when the
            match ends inside the window: its full-length transition then
            sets that node, so the path stays valid (skipped positions
            start no transitions, so none of them can become a parent) }
          if (len >= p.skipLen) and (i + len <= w) then
          begin
            for j := i + 1 to i + len - 1 do
              cnt[j] := -1;
            i := i + len - 1;
          end;
        end;
        Inc(i);
      end;
      end;

      { 2: the DP }
      a.wsrc := src + start;
      if prices <> nil then
        a.litPrice := prices + (start shr OPT_REGION_SHIFT) * 256;
      nodes[0].cost := 0;
      nodes[0].ll := Int32(start - anchor);
      nodes[0].ml := 0;
      for i := 1 to w do
        nodes[i].cost := High(Int32);
      if e.v4 then
      begin
        if mtabGen <> e.codesGen then
        begin
          { a chunk went out with another table: its codes price the next }
          mtabGen := e.codesGen;
          for k := 0 to 1 do
            for i := 0 to OPT4_ROWS - 1 do
              for j := 0 to OPT4_COLS - 1 do
                if j < MINML4[k] then
                  mtab4[k, i, j] := OPT4_NEVER
                else
                  mtab4[k, i, j] := MatchCost4(i, j, k, a4);
        end;
        a4.wsrc := a.wsrc;
        a4.litPrice := a.litPrice;
        a4.before := start;
        nodes[0].dist := Int32(lastDist);
{$ifdef SYLZ_C}
        if SylzUseAsm then
          sylzc_opt_dp4(nodes, Int32(w), cands, off, cnt, @a4)
        else
{$endif}
          OptDp4Pas(nodes, w, cands, off, cnt, a4);
      end
      else
{$ifdef SYLZ_C}
      if SylzUseAsm then
        sylzc_opt_dp(nodes, Int32(w), cands, off, cnt, @mtab[0, 0], @a)
      else
{$endif}
        OptDpPas(nodes, w, cands, off, cnt, @mtab[0, 0], a);

      { 3: the cheapest path to node w, back to front }
      npath := 0;
      j := w;
      while j > 0 do
        if nodes[j].ml = 0 then
          Dec(j)
        else
        begin
          path[3 * npath] := Int32(j - nodes[j].ml);
          path[3 * npath + 1] := nodes[j].ml;
          path[3 * npath + 2] := nodes[j].dist;
          Inc(npath);
          Dec(j, nodes[j].ml);
        end;
      for t := npath - 1 downto 0 do
      begin
        pos := start + path[3 * t];
        if hist <> nil then
          CountLiterals(src, anchor, pos, hist)
        else if not EmitSequence(e, src + anchor, pos - anchor, path[3 * t + 2], path[3 * t + 1]) then
          Exit(-1);
        lastDist := path[3 * t + 2];
        anchor := pos + path[3 * t + 1];
      end;
      if forced then
      begin
        pos := start + w;
        if hist <> nil then
          CountLiterals(src, anchor, pos, hist)
        else if not EmitSequence(e, src + anchor, pos - anchor, forcedDist, forcedLen) then
          Exit(-1);
        lastDist := forcedDist;
        anchor := pos + forcedLen;
        start := anchor;
        { format v4: of a match taken as is, only every
          OPT_FORCED_STEP4-th position and the last ones go into the tree.
          Each one costs a walk and a long compare, and what they would
          find later the match's source mostly has too. With none of
          them (level 9: silesia.tar -7% cycles), a 1 MiB piece of samba
          came out 7% bigger than with all of them: later matches into
          the long match's bytes went unfound. Every 4th: silesia.tar -4%
          cycles, mixed corpus -8%, that piece within 0.6% }
        if e.v4 and (anchor - OPT_FORCED_KEEP4 > b.nextToInsert) then
        begin
          k := b.nextToInsert;
          while k < anchor - OPT_FORCED_KEEP4 do
          begin
            BtInsert(b, k, nil);
            Inc(k, OPT_FORCED_STEP4);
          end;
          b.nextToInsert := anchor - OPT_FORCED_KEEP4;
        end;
      end
      else
        start := start + w;
    end;
  end;
  if hist <> nil then
  begin
    CountLiterals(src, anchor, n, hist);
    Exit(0);
  end;
  Result := EmitFinish(e, src + anchor, n - anchor);
end;

function CompressOpt(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; const p: TSylzOptParams): SizeInt;
var
  e: TEmit;
  b: TBtState;
begin
  if ctx.opt = nil then
    ctx.opt := GetMem(OPT_WORK_BYTES);
  if ctx.bt = nil then
    ctx.bt := GetMem(SizeOf(UInt32) * ((1 shl BT_HASHLOG) + 2 * BT_WINDOW));
  FillChar(ctx.bt^, SizeOf(UInt32) shl BT_HASHLOG, 0);
  b.src := src;
  b.iend := src + n;
  b.head := ctx.bt;
  b.son := ctx.bt + (1 shl BT_HASHLOG);
  b.nextToInsert := 0;
  b.cut := p.btCut;
  b.maxLen := p.btMaxLen;
  EmitInit(e, dst, cap, ctx.scratch, src + n, ctx.flags, ctx.offs, ctx.recs);
  e.roomy := cap >= SylzBound(n);
  Result := CompressOptCore(src, n, e, b, ctx.opt, p, nil, nil);
end;

{ Literal prices from counted literals, per region: each region's Huffman
  code lengths, as HufEncodeChunk would build them; 8 bits where Huffman
  would not pay (the chunk stays raw) or a region has no literals; absent
  symbols get HUF_MAXBITS + 1. }
procedure LiteralPrices(hist: PUInt32; regions: SizeInt; prices: PInt32);
var
  r, i: SizeInt;
  len: array[0..255] of Byte;
  total, bits: UInt64;
  h: PUInt32;
  pr: PInt32;
begin
  for r := 0 to regions - 1 do
  begin
    h := hist + r * 256;
    pr := prices + r * 256;
    total := 0;
    for i := 0 to 255 do
      Inc(total, h[i]);
    for i := 0 to 255 do
      pr[i] := OPT_SCALE;
    if total = 0 then
      Continue;
    HufLengths(h, @len[0]);
    bits := 0;
    for i := 0 to 255 do
      Inc(bits, UInt64(h[i]) * len[i]);
    if bits * 100 > total * 8 * (100 - HUF_MIN_GAIN_PCT) then
      Continue;   { would stay raw }
    for i := 0 to 255 do
      if len[i] > 0 then
        pr[i] := len[i] + OPT_LIT_PENALTY
      else
        pr[i] := HUF_MAXBITS + 1 + OPT_LIT_PENALTY;
  end;
end;

{ Format v3's levels 9 and 10: the optimal parser pricing each literal by
  its Huffman code. A first parse (format v2's prices) counts the
  literals per region, and their code lengths price the parse that is
  emitted. Against -ec 8 (level 10's parse priced as v2), silesia.tar
  33.98 -> 33.61% (-ec 9) / 33.60% (-ec 10), mixed 57.15 -> 56.94 /
  56.91%, at about half the speed (two parses) and ~5% slower decode (more
  literals). A third parse, priced from the second's literals, gained
  0.02 points (33.58%). The first parse runs with stats, the second with
  p (format v3: the same; format v5's -ec 9: a first parse with a
  shallow tree, V5_OPT_STATS). }
function CompressOptEC(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; const stats, p: TSylzOptParams): SizeInt;
var
  e: TEmit;
  b: TBtState;
  regions: SizeInt;
  hist: PUInt32;
  prices: PInt32;

  procedure ResetTree(const q: TSylzOptParams);
  begin
    FillChar(ctx.bt^, SizeOf(UInt32) shl BT_HASHLOG, 0);
    b.src := src;
    b.iend := src + n;
    b.head := ctx.bt;
    b.son := ctx.bt + (1 shl BT_HASHLOG);
    b.nextToInsert := 0;
    b.cut := q.btCut;
    b.maxLen := q.btMaxLen;
  end;

begin
  if ctx.opt = nil then
    ctx.opt := GetMem(OPT_WORK_BYTES);
  if ctx.bt = nil then
    ctx.bt := GetMem(SizeOf(UInt32) * ((1 shl BT_HASHLOG) + 2 * BT_WINDOW));
  regions := (n shr OPT_REGION_SHIFT) + 1;
  hist := GetMem(regions * 256 * SizeOf(UInt32));
  prices := GetMem(regions * 256 * SizeOf(Int32));
  try
    FillChar(hist^, regions * 256 * SizeOf(UInt32), 0);
    ResetTree(stats);
    { nothing is emitted in this pass, but the parse depends on the format }
    EmitInit(e, dst, cap, ctx.scratch, src + n, ctx.flags, ctx.offs, ctx.recs);
    e.roomy := cap >= SylzBound(n);
    CompressOptCore(src, n, e, b, ctx.opt, stats, nil, hist);
    LiteralPrices(hist, regions, prices);
    ResetTree(p);
    EmitInit(e, dst, cap, ctx.scratch, src + n, ctx.flags, ctx.offs, ctx.recs);
    e.roomy := cap >= SylzBound(n);
    Result := CompressOptCore(src, n, e, b, ctx.opt, p, prices, nil);
  finally
    FreeMem(prices);
    FreeMem(hist);
  end;
end;

procedure SylzCtxInit(out ctx: TSylzCtx);
begin
  FillChar(ctx, SizeOf(ctx), 0);
end;

procedure SylzCtxFree(var ctx: TSylzCtx);
begin
  FreeMem(ctx.scratch);
  FreeMem(ctx.offs);
  FreeMem(ctx.recs);
  FreeMem(ctx.table);
  FreeMem(ctx.bt);
  FreeMem(ctx.head);
  FreeMem(ctx.chain);
  FreeMem(ctx.opt);
  SylzCtxInit(ctx);
end;

function SylzCompressCtx(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; level: Integer): SizeInt;
begin
  Result := SylzCompressEx(ctx, src, n, dst, cap, level, 0);
end;

type
  TV5Level = record
    parse, attempts: Integer;
  end;

const
  { Format v5's levels 0..8: the parse (format v4's level) and, at the
    hash chain levels, the chain attempts (0: HC_ATTEMPTS). Since the
    branches were integrated (2026-11-13) these are v3's (v2's level +
    SYLZ_EC_SHIFT): one level lower, as the v4-v5-entropy branch had it
    on master's parsers, left whole Silesia files up to 6% bigger than
    v3's at -ec 0..7 (text at the hash chain levels, binary data at the
    fast parse of -ec 0), and v4's faster parsers keep v5 ahead of v3 at
    v3's levels: silesia.tar -3.5 to -12% cycles to compress at -ec 0..6,
    the mixed corpus -16 to -43%. }
  V5_LEVELS: array[0..8] of TV5Level = (
    (parse: 2; attempts: 0), (parse: 3; attempts: 0), (parse: 4; attempts: 0),
    (parse: 5; attempts: 0), (parse: 6; attempts: 0), (parse: 7; attempts: 0),
    (parse: 8; attempts: 0), (parse: 9; attempts: 0), (parse: 10; attempts: 0));

  { Format v5's -ec 9: the first parse of CompressOptEC only counts the
    literals, and a shallow tree counts nearly the same ones: silesia.tar
    69.22 MB against 68.98 with OPT_LEVEL9's, in 629 M cycles per MB
    instead of 895 (v3's -ec 9: 71.23 MB, 823). -ec 10 counts them the
    same way and parses with OPT4_LEVEL10 (since the integration: with
    OPT_LEVEL9 in both parses, mr came out 0.02% bigger than v3's -ec
    10; silesia.tar 68.63 MB against 68.69). }
  V5_OPT_STATS: TSylzOptParams = (btCut: 2; btMaxLen: 256; sufficient: 16;
    pSeq: 0.5; pEsc: 1.0; pShort: 0.5; subLen: 36; skipLen: OPT_NOSKIP; minRep: 2);

function CompressAny(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; level: Integer; flags: Integer): SizeInt;
var
  attempts: Integer;
begin
  ctx.flags := flags;
  attempts := 0;   { HC_ATTEMPTS[level] }
  if cap < HEADER4_SIZE then
    Exit(-1);
  { v4's offsets: 2 bytes for each match at a new offset, of 4 bytes or more }
  if (flags and SYLZ_V4 <> 0) and (ctx.offsSize < n div 2 + SCRATCH_SLACK) then
  begin
    FreeMem(ctx.offs);
    ctx.offsSize := n div 2 + SCRATCH_SLACK;
    ctx.offs := GetMem(ctx.offsSize);
  end;
  if (flags and SYLZ_V4 <> 0) and (ctx.recs = nil) then
    ctx.recs := GetMem(3 * SizeOf(UInt16) * CHUNK4_SEQS);
  if level < SYLZ_MINLEVEL then
    level := SYLZ_MINLEVEL;
  if flags and SYLZ_ENTROPY <> 0 then
  begin
    if level > SYLZ_EC_MAXLEVEL then
      level := SYLZ_EC_MAXLEVEL;
    if level >= SYLZ_MAXLEVEL - SYLZ_EC_SHIFT + 1 then
    begin
      if ctx.scratchSize < n + SCRATCH_SLACK then
      begin
        FreeMem(ctx.scratch);
        ctx.scratchSize := n + SCRATCH_SLACK;
        ctx.scratch := GetMem(ctx.scratchSize);
      end;
      if flags and SYLZ_V4 <> 0 then
      begin
        if level = SYLZ_MAXLEVEL - 1 then
          Exit(CompressOptEC(ctx, src, n, dst, cap, V5_OPT_STATS, OPT_LEVEL9))
        else
          Exit(CompressOptEC(ctx, src, n, dst, cap, V5_OPT_STATS, OPT4_LEVEL10));
      end;
      if level = SYLZ_MAXLEVEL - 1 then
        Exit(CompressOptEC(ctx, src, n, dst, cap, OPT_LEVEL9, OPT_LEVEL9))
      else
        Exit(CompressOptEC(ctx, src, n, dst, cap, OPT_LEVEL10, OPT_LEVEL10));
    end;
    if flags and SYLZ_V4 <> 0 then
    begin
      attempts := V5_LEVELS[level].attempts;
      level := V5_LEVELS[level].parse;
    end
    else
      Inc(level, SYLZ_EC_SHIFT);
  end;
  if level > SYLZ_MAXLEVEL then
    level := SYLZ_MAXLEVEL;
  if ctx.scratchSize < n + SCRATCH_SLACK then
  begin
    FreeMem(ctx.scratch);
    ctx.scratchSize := n + SCRATCH_SLACK;
    ctx.scratch := GetMem(ctx.scratchSize);
  end;
  if level <= 1 then
    Result := CompressFast(ctx, src, n, dst, cap, level)
  else if level <= 3 then
    Result := CompressMid(ctx, src, n, dst, cap, level)
  else if level = 9 then
    Result := CompressOpt(ctx, src, n, dst, cap, OPT_LEVEL9)
  else if level = 10 then
    Result := CompressOpt(ctx, src, n, dst, cap, OptLevel10(flags))
  else
  begin
    if attempts = 0 then
      attempts := HC_ATTEMPTS[level];
    Result := CompressHC(ctx, src, n, dst, cap, attempts);
  end;
end;

function SylzCompressEx(var ctx: TSylzCtx; src: PByte; n: SizeInt; dst: PByte;
  cap: SizeInt; level: Integer; flags: Integer): SizeInt;
var
  alt: PByte;
  r: SizeInt;
begin
  Result := CompressAny(ctx, src, n, dst, cap, level, flags);
  { formats v4 and v5, a small block: the format below's block too (v2,
    or v3 for v5), and the smaller of the two. On a few KiB of text, with
    few matches at the previous offset, v4's table and parse can lose a
    few bytes to v2's; on large blocks v4 is always the smaller, and the
    second compression would cost time for nothing }
  if (flags and SYLZ_V4 <> 0) and (n <= SMALL_BLOCK4) and (n > 0) then
  begin
    alt := GetMem(SylzBound(n));
    try
      r := CompressAny(ctx, src, n, alt, SylzBound(n), level, flags and not SYLZ_V4);
      if (r >= 0) and (r <= cap) and ((Result < 0) or (r < Result)) then
      begin
        Move(alt^, dst^, r);
        Result := r;
      end;
    finally
      FreeMem(alt);
    end;
  end;
  { formats v4 and v5: a block bigger than its input, or one that did not
    fit cap, goes out as a block with no sequences: its header and the
    input as the tail literals }
  if (flags and SYLZ_V4 <> 0) and ((Result < 0) or (Result > HEADER_SIZE + n))
     and (cap >= HEADER_SIZE + n) then
  begin
    PUInt32(dst)^ := HDR_V4;
    Move(src^, dst[HEADER_SIZE], n);
    Result := HEADER_SIZE + n;
  end;
end;

function SylzCompress(src: PByte; n: SizeInt; dst: PByte; cap: SizeInt;
  level: Integer): SizeInt;
var
  ctx: TSylzCtx;
begin
  SylzCtxInit(ctx);
  try
    Result := SylzCompressCtx(ctx, src, n, dst, cap, level);
  finally
    SylzCtxFree(ctx);
  end;
end;

{ ── decoder ──────────────────────────────────────────────────────────────── }

const
  { The longest length an extension may sum to. No block is that long
    (MAX_BLOCK in sycstream is 512 MiB); the cap keeps a 32-bit sum of
    255-runs from wrapping to a small or negative length, which every room
    check would pass, and keeps the sum of two lengths from wrapping too.
    With a 64-bit SizeInt no input is long enough to reach it, so the test
    is only compiled where SizeInt is smaller (not CPU64), and the decoders
    there reject any longer extension, as the 64-bit ones do (no room for
    it). }
  EXT_LIMIT = High(SizeInt) shr 1;

{ Reads a 255-run extension at p, not reading at or past pend. Returns
  false if it runs off the end or past EXT_LIMIT. }
function GetExt(var p: PByte; pend: PByte; var v: SizeInt): Boolean; inline;
var
  b: SizeInt;
begin
  repeat
    if p >= pend then
      Exit(False);
    b := p^;
    Inc(p);
    Inc(v, b);
{$ifndef CPU64}
    if v > EXT_LIMIT then
      Exit(False);
{$endif}
  until b <> 255;
  Result := True;
end;

{ Exact, fully checked decoding from the given stream positions to the end
  of the block. Handles the block tail and any sequence that doesn't fit
  the fast loop's margins. Kept out of line: its Move calls would force
  the fast loop's variables out of registers. }
function DecodeSafe(ctrl, cend, lit, lend, op, oend, dst: PByte): SizeInt;
var
  m: PByte;
  e: UInt32;
  ll, ml, off: SizeInt;
begin
  Result := -1;
  while ctrl < cend do
  begin
    if cend - ctrl < 3 then
      Exit;
    e := SYLZ_TOKENS[ctrl[0]];
    off := SizeInt(ctrl[1] or (UInt32(ctrl[2]) shl 8)) + 1;
    Inc(ctrl, 3);
    ll := e and $FF;
    ml := (e shr 8) and $FF;
    if (e and SYLZ_TOK_LLEXT <> 0) and not GetExt(ctrl, cend, ll) then
      Exit;
    if (e and SYLZ_TOK_MLEXT <> 0) and not GetExt(ctrl, cend, ml) then
      Exit;
    if (ll > lend - lit) or (ll > oend - op) then
      Exit;
    Move(lit^, op^, ll);
    Inc(op, ll);
    Inc(lit, ll);
    if (off > op - dst) or (ml > oend - op) then
      Exit;
    m := op - off;
    if off >= ml then
    begin
      Move(m^, op^, ml);
      Inc(op, ml);
    end
    else
      while ml > 0 do
      begin
        op^ := m^;
        Inc(op);
        Inc(m);
        Dec(ml);
      end;
  end;
  { the rest of the literal stream is the block's tail }
  if lend - lit <> oend - op then
    Exit;
  Move(lit^, op^, lend - lit);
  Result := oend - dst;
end;

const
  { A token table as the fast loops read it: bits 0..7 literal length,
    bit 8 a new offset, 9..15 match length (their bases in an escape), so
    that one shift leaves the match length and the offset bit in the
    carry; bits 29 / 30 literal / match length extended, 31 either (an
    escape: the sign). }
  FAST4_OFF   = UInt32($100);
  FAST4_MLSH  = 9;
  FAST4_LLEXT = UInt32($20000000);
  FAST4_MLEXT = UInt32($40000000);
  FAST4_ESC   = UInt32($80000000);

type
  TFast4 = array[0..255] of UInt32;
  { What a match at a distance under 16 is made of without reading back
    what it writes, each array indexed by 16 - distance (the assembler has
    the distance negative). Its bytes are one period, the first `distance`
    source bytes, repeated: 8 source bytes and mask leave the period (all
    8 from distance 8 on); times mul gives output bytes 0..7, and in the
    product's high half what the last copy has past them; times mulh gives
    the copies in bytes 8..15; from distance 9 on source bytes 8.. (mask2)
    come before those. Bytes 16..31 are copied from back16 before them,
    the nearest multiple of the distance that is at least 16 (stored as
    64 - the multiple). Fixed field order: the assembler reads it. }
  TShort4 = record
    mask, mul, mulh, mask2: array[0..15] of UInt64;   { 0, 128, 256, 384 }
    back16: array[0..15] of Byte;                     { 512 }
  end;

  { Where format v4's decoding stands, in and out of each chunk's
    decoders; fixed field order (the assembler and sylzc.c read it). }
  TDecode4State = record
    tok, offp, lit, op: PByte;               {  0,  8, 16, 24: in/out }
    tend, offend, lend, oend, dst: PByte;    { 32, 40, 48, 56, 64: in }
    rep: SizeInt;                            { 72: in/out, the previous distance }
    status: SizeInt;                         { 80: out, 0 = stopped, -1 = corrupt }
    tokens: PUInt32;                         { 88: in, the chunk's table }
    fast: PUInt32;                           { 96: in, the same as a TFast4 }
    offs0: PByte;                            { 104: in, where the block's offsets start }
    short: Pointer;                          { 112: in, Short4 }
    { format v5 (the fast loops do not read these): the literal chunks not
      decoded yet, the literals in them, and the buffer lit .. lend is in }
    litSrc, litSrcEnd: PByte;
    litLeft: SizeInt;
    litBuf: PByte;
  end;
  PDecode4State = ^TDecode4State;

const
  { Format v5's literal chunks are decoded one at a time, when the
    sequences get to them, into a buffer of one chunk that stays in the
    cache; the whole literal stream decoded first went out to memory and
    came back (silesia.tar, -ec 0: 35 MB of it). The buffer starts with
    room for the literals of the chunk before that are not used yet:
    under LITBUF_KEEP, where the fast loops stop. }
  LITBUF_KEEP = 16;
  LITBUF_SIZE = LITBUF_KEEP + LIT_CHUNK + 16;

{ Format v5: the next literal chunk, after the literals decoded and not
  used yet. False on corrupt input, or with no chunk left. }
function RefillLits4(var st: TDecode4State): Boolean;
var
  keep, c, r: SizeInt;
begin
  Result := False;
  keep := st.lend - st.lit;
  if (st.litLeft <= 0) or (keep > LITBUF_KEEP) then
    Exit;
  c := st.litLeft;
  if c > LIT_CHUNK then
    c := LIT_CHUNK;
  Move(st.lit^, (st.litBuf + LITBUF_KEEP - keep)^, keep);
  r := HufDecodeChunk8(st.litSrc, st.litSrcEnd - st.litSrc, st.litBuf + LITBUF_KEEP, c);
  if r < 0 then
    Exit;
  Inc(st.litSrc, r);
  Dec(st.litLeft, c);
  st.lit := st.litBuf + LITBUF_KEEP - keep;
  st.lend := st.litBuf + LITBUF_KEEP + c;
  Result := True;
end;

var
  Fast4: TFast4;     { SYLZ_TOKENS4's }
  Short4: TShort4;

{ One table entry as the fast loops read it }
function FastEntry4(e: UInt32): UInt32;
begin
  Result := (e and $FF) or (((e shr 8) and $FF) shl FAST4_MLSH);
  if e and SYLZ_TOK4_OFF <> 0 then
    Result := Result or FAST4_OFF;
  if e and SYLZ_TOK4_LLEXT <> 0 then
    Result := Result or FAST4_LLEXT or FAST4_ESC;
  if e and SYLZ_TOK4_MLEXT <> 0 then
    Result := Result or FAST4_MLEXT or FAST4_ESC;
end;

procedure BuildFast4(const t: TTable4; out f: TFast4);
var
  i: Integer;
begin
  for i := 0 to 255 do
    f[i] := FastEntry4(t[i]);
end;

procedure BuildShort4;
var
  d, i, k, m: Integer;
begin
  FillChar(Short4, SizeOf(Short4), 0);
  for d := 1 to 15 do
  begin
    i := 16 - d;
    Short4.mask[i] := High(UInt64);
    if d < 8 then
      Short4.mask[i] := (UInt64(1) shl (8 * d)) - 1;
    if d > 8 then
      Short4.mask2[i] := (UInt64(1) shl (8 * (d - 8))) - 1;
    { the period's copies start every d bytes: those that start in bytes
      0..7, those that start in bytes 8..15 }
    k := 0;
    while k < 8 do
    begin
      Short4.mul[i] := Short4.mul[i] or (UInt64(1) shl (8 * k));
      Inc(k, d);
    end;
    while k < 16 do
    begin
      Short4.mulh[i] := Short4.mulh[i] or (UInt64(1) shl (8 * (k - 8)));
      Inc(k, d);
    end;
    m := d;
    while m < 16 do
      Inc(m, d);
    Short4.back16[i] := 64 - m;
  end;
end;

const
  { A sequence starts in the fast loop only with this much room left. The
    common sequence (literal and match fields not extended) copies 8
    literal bytes and up to 48 match bytes unconditionally, so it never
    needs a bounds check; extended ones are checked one by one. }
  CTRL_MARGIN = 3;
  LIT_MARGIN  = 16;
  OUT_MARGIN  = 64;
  { smallest multiple of off that is >= 8, for off in 1..7 }
  PERIOD_STRIDE: array[1..7] of Byte = (8, 8, 9, 8, 10, 12, 14);

{ The fast loop is register-starved under FPC: 14 GPRs, and when they run
  out its allocator may spill exactly the pointer on the critical path.
  So the values used only in comparisons (the fast limits and dst) live in
  a record, which FPC never keeps in registers: a compare against an L1
  stack slot is cheap and off the dependency chain, and the registers go
  to ctrl, lit, op and the sequence fields. }
type
  TDecodeLimits = record
    cfast, lfast, ofast, dst: PByte;
  end;

function DecodePas(ctrl, cend, lit, lend, dst: PByte; dstLen: SizeInt): SizeInt;
var
  lim: TDecodeLimits;
  op, m: PByte;
  e, off: SizeUInt;
  ll, ml: SizeInt;   { signed: the copy loops count them down past zero }
begin
  lim.cfast := cend - CTRL_MARGIN;
  lim.lfast := lend - LIT_MARGIN;
  lim.ofast := dst + dstLen - OUT_MARGIN;
  lim.dst := dst;
  op := dst;

  while (ctrl <= lim.cfast) and (lit <= lim.lfast) and (op <= lim.ofast) do
  begin
    e := SYLZ_TOKENS[ctrl[0]];
    off := SizeUInt(PUInt16(ctrl + 1)^) + 1;
    Inc(ctrl, 3);

    if e <= $FFFF then
    begin
      { exact pair: literals <= 15, match <= 32 }
      ll := e and $FF;
      ml := e shr 8;
      Copy16(op, lit);
      Inc(op, ll);
      Inc(lit, ll);
    end
    else
    begin
      { extended field(s): read them through m so that giving up leaves
        everything at the token, nothing written yet }
      { (written out instead of calling GetExt: passing ll/ml/m by var,
        even to an inline function, would pin them to the stack) }
      ll := e and $FF;
      ml := (e shr 8) and $FF;
      m := ctrl;
      if e and SYLZ_TOK_LLEXT <> 0 then
        repeat
          if m >= lim.cfast + CTRL_MARGIN then
          begin
            ll := -1;
            Break;
          end;
          Inc(ll, m^);
          Inc(m);
{$ifndef CPU64}
          if ll > EXT_LIMIT then
          begin
            ll := -1;
            Break;
          end;
{$endif}
        until m[-1] <> 255;
      if (e and SYLZ_TOK_MLEXT <> 0) and (ll >= 0) then
        repeat
          if m >= lim.cfast + CTRL_MARGIN then
          begin
            ll := -1;
            Break;
          end;
          Inc(ml, m^);
          Inc(m);
{$ifndef CPU64}
          if ml > EXT_LIMIT then
          begin
            ll := -1;
            Break;
          end;
{$endif}
        until m[-1] <> 255;
      if (ll < 0) or (ll > lim.lfast - lit) or (ll + ml > lim.ofast - op + 16) then
      begin
        Dec(ctrl, 3);   { DecodeSafe redoes this sequence exactly }
        Break;
      end;
      ctrl := m;
      { count down; the last step overshoots by -ll bytes, taken back after }
      repeat
        Copy16(op, lit);
        Inc(op, 16);
        Inc(lit, 16);
        Dec(ll, 16);
      until ll <= 0;
      Inc(op, ll);
      Inc(lit, ll);
    end;

    { match }
    if SizeInt(off) > op - lim.dst then
      Exit(-1);
    m := op - off;
    if off >= 16 then
    begin
      Copy16(op, m);
      Copy16(op + 16, m + 16);
      if ml > 32 then
      begin
        Inc(op, 32);
        Inc(m, 32);
        Dec(ml, 32);
        repeat
          Copy16(op, m);
          Inc(op, 16);
          Inc(m, 16);
          Dec(ml, 16);
        until ml <= 0;
      end;
      Inc(op, ml);   { ml <= 32: a single step; else ml <= 0, the overshoot }
    end
    else if off >= 8 then
    begin
      repeat
        Copy8(op, m);
        Inc(op, 8);
        Inc(m, 8);
        Dec(ml, 8);
      until ml <= 0;
      Inc(op, ml);
    end
    else
    begin
      { off < 8: the first 8 bytes byte by byte. They repeat with period
        off, so the rest can be copied from the nearest multiple of off
        that is >= 8, which allows 8-byte steps }
      op[0] := m[0]; op[1] := m[1]; op[2] := m[2]; op[3] := m[3];
      op[4] := m[4]; op[5] := m[5]; op[6] := m[6]; op[7] := m[7];
      Inc(op, 8);
      m := op - PERIOD_STRIDE[off];
      Dec(ml, 8);
      while ml > 0 do
      begin
        Copy8(op, m);
        Inc(op, 8);
        Inc(m, 8);
        Dec(ml, 8);
      end;
      Inc(op, ml);
    end;
  end;
  Result := DecodeSafe(ctrl, lim.cfast + CTRL_MARGIN, lit, lim.lfast + LIT_MARGIN,
    op, lim.ofast + OUT_MARGIN, dst);
end;

{$ifdef SYLZ_ASM_X64}

type
  { In/out state of the assembler fast loop. Field order is fixed: the
    assembler addresses the fields by these offsets. }
  TDecodeState = record
    ctrl, lit, op: PByte;              {  0,  8, 16: in/out }
    cfast, lfast, ofast, dst: PByte;   { 24, 32, 40, 48: in }
    status: SizeInt;                   { 56: out, 0 = stopped at a margin, -1 = corrupt }
    tokens: PUInt32;                   { 64: in, SYLZ_TOKENS }
  end;
  PDecodeState = ^TDecodeState;

{ The fast loop of DecodePas in x86_64 assembler, same results: decodes
  while all three streams are inside their margins, and stops at the token
  of the first sequence it can't do with unchecked wide copies, leaving it
  to DecodeSafe.

  Two modes. Checked: the loop of DecodePas, three margin compares and an
  offset check per sequence. Counted: once the output is past the first
  SYLZ_MAXDIST bytes no offset can reach before its start, and a sequence
  with an exact token uses 3 control bytes, at most 15 literals and at
  most 47 output bytes, so k = min(ctrl room / 4, literal room / 16,
  output room / 64) of them fit the margins: the loop then only counts
  down k. An escape checks itself and forces a recount.

  Registers: r8 ctrl, r9 lit, r10 op, r11 cfast, r12 lfast, r13 ofast,
  r14 dst, r15 k, rdi token table, eax token / table entry, rcx offset,
  rbx literal length, rbp match length, rsi match source, rdx scratch,
  xmm0/xmm1 16-byte copies (SSE2 is baseline on x86_64). The state
  pointer is kept on the stack. }
procedure DecodeFastX64(st: PDecodeState); assembler; nostackframe;
asm
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov rax, rcx            { Win64: first argument in rcx; rsi/rdi are callee-saved }
{$else}
  mov rax, rdi            { SysV: first argument in rdi }
{$endif}
  push rax                { the state pointer, popped at @done }
  mov r8, [rax]
  mov r9, [rax + 8]
  mov r10, [rax + 16]
  mov r11, [rax + 24]
  mov r12, [rax + 32]
  mov r13, [rax + 40]
  mov r14, [rax + 48]
  mov rdi, [rax + 64]     { token table }
  mov qword ptr [rax + 56], 0

@recount:
  { counted mode needs op - dst >= SYLZ_MAXDIST and k > 0 }
  mov rdx, r10
  sub rdx, r14
  cmp rdx, 65536
  jb @checked
  cmp r8, r11
  ja @done
  cmp r9, r12
  ja @done
  cmp r10, r13
  ja @done
  mov r15, r11
  sub r15, r8
  shr r15, 2
  mov rdx, r12
  sub rdx, r9
  shr rdx, 4
  cmp rdx, r15
  cmovb r15, rdx
  mov rdx, r13
  sub rdx, r10
  shr rdx, 6
  cmp rdx, r15
  cmovb r15, rdx
  test r15, r15
  jz @checked

@counted:
  { An exact token has match <= 32, so this path copies 32 bytes with no
    length test, and keeps the stored offset (distance - 1) in rcx with
    the -1 folded into the address displacement: 22 instructions for a
    sequence. The rare ways out restore rcx = distance first. }
  movzx eax, byte ptr [r8]
  movzx ecx, word ptr [r8 + 1]   { distance - 1 }
  add r8, 3
  mov eax, [rdi + rax * 4]
  cmp eax, $FFFF
  ja @countedExt          { an escape: a length is extended }
  movzx ebp, ah           { match length, 4..32 }
  movzx eax, al           { literal length, 0..15 }
  movdqu xmm0, [r9]
  movdqu [r10], xmm0      { 16 literal bytes, unconditionally }
  add r10, rax
  add r9, rax
  mov rsi, r10
  sub rsi, rcx            { match source + 1 }
  cmp ecx, 15
  jb @countedShort        { distance < 16 }
  movdqu xmm0, [rsi - 1]
  movdqu [r10], xmm0
  movdqu xmm1, [rsi + 15]
  movdqu [r10 + 16], xmm1 { 32 match bytes, unconditionally }
  add r10, rbp
  sub r15, 1
  jnz @counted
  jmp @recount
@countedExt:
  add rcx, 1
  jmp @ext
@countedShort:
  add rcx, 1
  sub rsi, 1
  jmp @short

@checked:
  mov r15, 1              { one sequence, then recount }
  cmp r8, r11
  ja @done
  cmp r9, r12
  ja @done
  cmp r10, r13
  ja @done
  movzx eax, byte ptr [r8]
  movzx ecx, word ptr [r8 + 1]
  add rcx, 1
  add r8, 3
  mov eax, [rdi + rax * 4]
  cmp eax, $FFFF
  ja @ext
  movzx ebp, ah
  movzx eax, al
  movdqu xmm0, [r9]
  movdqu [r10], xmm0
  add r10, rax
  add r9, rax
  mov rdx, r10
  sub rdx, r14
  cmp rcx, rdx
  ja @corrupt             { offset reaches before the start of the output }

@match:
  { copy the match, then continue counting down or recount }
  mov rsi, r10
  sub rsi, rcx
  cmp rcx, 16
  jb @short
  movdqu xmm0, [rsi]
  movdqu [r10], xmm0
  movdqu xmm1, [rsi + 16]
  movdqu [r10 + 16], xmm1
  cmp rbp, 32
  ja @long
  add r10, rbp
  sub r15, 1
  jnz @counted
  jmp @recount
@long:
  { match > 32 (escapes only): 32 more bytes unconditionally, and a loop
    only past 64, so most long matches take no loop exit to mispredict }
  movdqu xmm0, [rsi + 32]
  movdqu [r10 + 32], xmm0
  movdqu xmm1, [rsi + 48]
  movdqu [r10 + 48], xmm1
  cmp rbp, 64
  ja @longer
  add r10, rbp
  sub r15, 1
  jnz @counted
  jmp @recount
@longer:
  add r10, 64
  add rsi, 64
  sub rbp, 64
@long16:
  movdqu xmm0, [rsi]
  movdqu [r10], xmm0
  add r10, 16
  add rsi, 16
  sub rbp, 16
  jg @long16
  add r10, rbp            { rbp <= 0: take back the overshoot }
  sub r15, 1
  jnz @counted
  jmp @recount

@short:
  cmp rcx, 8
  jb @tiny
@short8:
  mov rdx, [rsi]
  mov [r10], rdx
  add r10, 8
  add rsi, 8
  sub rbp, 8
  jg @short8
  add r10, rbp
  sub r15, 1
  jnz @counted
  jmp @recount

@tiny:
  { offset < 8: 8 bytes one at a time, then 8-byte steps from the nearest
    multiple of the offset that is >= 8: 8,8,9,8,10,12,14 for 1..7, packed
    one per byte }
  movzx edx, byte ptr [rsi]
  mov [r10], dl
  movzx edx, byte ptr [rsi + 1]
  mov [r10 + 1], dl
  movzx edx, byte ptr [rsi + 2]
  mov [r10 + 2], dl
  movzx edx, byte ptr [rsi + 3]
  mov [r10 + 3], dl
  movzx edx, byte ptr [rsi + 4]
  mov [r10 + 4], dl
  movzx edx, byte ptr [rsi + 5]
  mov [r10 + 5], dl
  movzx edx, byte ptr [rsi + 6]
  mov [r10 + 6], dl
  movzx edx, byte ptr [rsi + 7]
  mov [r10 + 7], dl
  add r10, 8
  mov rdx, $000E0C0A08090808
  lea ecx, [rcx * 8 - 8]
  shr rdx, cl
  movzx edx, dl
  mov rsi, r10
  sub rsi, rdx
  sub rbp, 8
  jle @tinyDone
@tiny8:
  mov rdx, [rsi]
  mov [r10], rdx
  add r10, 8
  add rsi, 8
  sub rbp, 8
  jg @tiny8
@tinyDone:
  add r10, rbp
  sub r15, 1
  jnz @counted
  jmp @recount

@ext:
  { an escape, from either mode: eax = its table entry. Read the
    extensions through rsi so that giving up leaves ctrl at the token,
    nothing written yet. rdi (the table) is borrowed as scratch and
    restored on every way out. }
  push rdi
  movzx ebx, al           { literal length base }
  movzx ebp, ah           { match length base }
  shr eax, 16             { bit 0: literals extended, bit 1: match extended }
  mov rsi, r8
  lea rdx, [r11 + 3]      { end of the control stream }
  test eax, 1
  jz @mlExt
@llExtLoop:
  cmp rsi, rdx
  jae @bail
  movzx edi, byte ptr [rsi]
  add rsi, 1
  add rbx, rdi
  cmp edi, 255
  je @llExtLoop
@mlExt:
  test eax, 2
  jz @extDone
@mlExtLoop:
  cmp rsi, rdx
  jae @bail
  movzx edi, byte ptr [rsi]
  add rsi, 1
  add rbp, rdi
  cmp edi, 255
  je @mlExtLoop
@extDone:
  pop rdi
  mov rdx, r12
  sub rdx, r9
  cmp rbx, rdx
  ja @bailPopped          { literals would read past the literal margin }
  lea rax, [rbx + rbp]
  mov rdx, r13
  sub rdx, r10
  add rdx, 16
  cmp rax, rdx
  ja @bailPopped          { literals + match would write past the output margin }
  mov rdx, r12
  sub rdx, r9
  cmp rdx, 16
  jb @bailPopped          { too close to the end for a 32-byte literal read }
  mov r8, rsi
  { 32 literal bytes unconditionally, a loop only past 32 }
  movdqu xmm0, [r9]
  movdqu [r10], xmm0
  movdqu xmm1, [r9 + 16]
  movdqu [r10 + 16], xmm1
  cmp rbx, 32
  jbe @litDone
  add r9, 32
  add r10, 32
  sub rbx, 32
@lit16:
  movdqu xmm0, [r9]
  movdqu [r10], xmm0
  add r9, 16
  add r10, 16
  sub rbx, 16
  jg @lit16
@litDone:
  add r9, rbx
  add r10, rbx
  mov rdx, r10
  sub rdx, r14
  cmp rcx, rdx
  ja @corrupt
  mov r15, 1              { the counted budget no longer holds: recount }
  jmp @match

@bail:
  pop rdi
@bailPopped:
  sub r8, 3               { back to the token: DecodeSafe redoes this sequence }
  jmp @done
@corrupt:
  mov rax, [rsp]
  mov qword ptr [rax + 56], -1
@done:
  pop rax
  mov [rax], r8
  mov [rax + 8], r9
  mov [rax + 16], r10
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
end;

function DecodeAsm(ctrl, cend, lit, lend, dst: PByte; dstLen: SizeInt): SizeInt;
var
  st: TDecodeState;
begin
  st.ctrl := ctrl;
  st.lit := lit;
  st.op := dst;
  st.cfast := cend - CTRL_MARGIN;
  st.lfast := lend - LIT_MARGIN;
  st.ofast := dst + dstLen - OUT_MARGIN;
  st.dst := dst;
  st.tokens := @SYLZ_TOKENS[0];
  DecodeFastX64(@st);
  if st.status < 0 then
    Exit(-1);
  Result := DecodeSafe(st.ctrl, st.cfast + CTRL_MARGIN, st.lit, st.lfast + LIT_MARGIN,
    st.op, st.ofast + OUT_MARGIN, dst);
end;
{$endif}

{$ifdef SYLZ_C}
function sylzc_decode(ctrl, cend, lit, lend, dst: PByte; dstLen: SizeInt;
  tokens: PUInt32): SizeInt; cdecl; external name 'sylzc_decode';
{$endif}

function DecodeStreams(ctrl, cend, lit, lend, dst: PByte; dstLen: SizeInt): SizeInt;
begin
{$ifdef SYLZ_ASM_X64}
  if SylzUseAsm and not SylzPreferC then
    Exit(DecodeAsm(ctrl, cend, lit, lend, dst, dstLen));
{$endif}
{$ifdef SYLZ_C}
  if SylzUseAsm then
    Exit(sylzc_decode(ctrl, cend, lit, lend, dst, dstLen, @SYLZ_TOKENS[0]));
{$endif}
  Result := DecodePas(ctrl, cend, lit, lend, dst, dstLen);
end;

{$ifdef SYLZ_ASM_X64}
{ Format v4's fast loop: sequences with an exact code only. Such a
  sequence takes one token, at most 2 offset bytes and 16 literals, and
  writes inside 64 bytes of output, so k = min(tokens, offset bytes / 2,
  literals / 16, output / 64) of them need no bounds check and the loop
  counts k down, then counts again. It stops, with everything at the
  token, at an escape it has no room for (DecodeEscape4 does it) or when
  k = 0.

  Two loops. Counted, 20 instructions for a sequence: once the output is
  SYLZ_MAXDIST bytes long no distance can reach before its start, and
  once the block has read an offset, the previous distance is the offset
  before the next one in the stream: a token advances the stream by its
  offset bit (one shift leaves the match length and that bit in the
  carry) and reads the two bytes before it, so there is nothing to
  select and no register to keep. Checked, until then: every distance
  against the output's start, the previous one in r12.

  The output is fetched 512 bytes ahead: its lines are new to the cache,
  and without that the stores wait for them (silesia.tar, level 1: 13%
  fewer cycles).

  Registers: r9 literals, r10 op, r13 the state, r14 dst, rdi the token
  table (TFast4), eax the table entry, then the match length, rbx
  literal length, rcx the distance, rdx scratch. Counted loop: r8 the
  end of the k tokens, r15 minus the tokens left of them, rsi the offset
  stream when the loop started, r11 the offsets read since, rcx minus
  the distance; for a distance under 16, r12 Short4 and rbp the match
  length (r12 and not rbp as the base: FPC takes [rbp + n] in an
  assembler procedure for a parameter, and warns). Elsewhere: r8 tokens, r11 offsets, r12 the previous
  distance - 1, rcx distance - 1, rsi match source + 1, rbp match
  length. }
procedure DecodeFast4X64(st: PDecode4State); assembler; nostackframe;
asm
  push rbx
  push rbp
  push r12
  push r13
  push r14
  push r15
{$ifdef WIN64}
  push rsi
  push rdi
  mov r13, rcx
{$else}
  mov r13, rdi
{$endif}
  mov r8, [r13]
  mov r11, [r13 + 8]
  mov r9, [r13 + 16]
  mov r10, [r13 + 24]
  mov r14, [r13 + 64]
  mov r12, [r13 + 72]
  sub r12, 1
  mov rdi, [r13 + 96]
  mov qword ptr [r13 + 80], 0

@recount:
  mov r15, [r13 + 32]
  sub r15, r8
  mov rdx, [r13 + 40]
  sub rdx, r11
  shr rdx, 1
  cmp rdx, r15
  cmovb r15, rdx
  mov rdx, [r13 + 48]
  sub rdx, r9
  shr rdx, 4
  cmp rdx, r15
  cmovb r15, rdx
  mov rdx, [r13 + 56]
  sub rdx, r10
  shr rdx, 6
  cmp rdx, r15
  cmovb r15, rdx
  test r15, r15
  jz @done
  mov rdx, r10
  sub rdx, r14
  cmp rdx, 65536
  jb @checkedFew
  cmp r11, [r13 + 104]
  je @checkedFew                 { no offset read yet: the previous one is not in the stream }
  mov rsi, r11
  xor r11d, r11d
  add r8, r15
  neg r15

@counted:
  movzx eax, byte ptr [r8 + r15]
  mov eax, [rdi + rax * 4]
  movdqu xmm0, [r9]
  movdqu [r10], xmm0             { 16 literal bytes, unconditionally }
  test eax, eax
  js @cEscape
  movzx ebx, al                  { literal length, 0..16 }
  shr eax, 9                     { match length, 0..32; carry: a new offset }
  adc r11, 0
  movzx ecx, word ptr [rsi + r11 * 2 - 2]
  add r9, rbx
  add r10, rbx
  not rcx                        { minus the distance }
  cmp rcx, -15
  jae @cShort                    { distance < 16 }
  movdqu xmm0, [r10 + rcx]
  movdqu [r10], xmm0
  movdqu xmm1, [r10 + rcx + 16]
  movdqu [r10 + 16], xmm1        { 32 match bytes, unconditionally }
  add r10, rax
  prefetcht0 [r10 + 512]
  add r15, 1
  jnz @counted
@cLeave:
  lea r11, [rsi + r11 * 2]
  movzx r12d, word ptr [r11 - 2]
  jmp @recount

@cShort:
  { distance < 16 (rcx = minus it), up to 32 bytes, with no branch on the
    distance and no load of what it has just written (see TShort4): 16
    bytes made from the period, and for a match over 16, 16 copied from a
    multiple of the distance before them. The match length may be 0: the
    bytes written past it are overwritten later. }
  mov r12, [r13 + 112]
  mov ebp, eax                   { the match length: mul takes rax and rdx }
  mov rax, [r10 + rcx]
  and rax, [r12 + rcx * 8 + 128]
  mov rbx, rax
  mul qword ptr [r12 + rcx * 8 + 256]
  imul rbx, [r12 + rcx * 8 + 384]
  or rdx, rbx
  mov rbx, [r10 + rcx + 8]
  and rbx, [r12 + rcx * 8 + 512]
  or rdx, rbx
  mov [r10], rax
  mov [r10 + 8], rdx
  cmp ebp, 16
  ja @cShortMore
@cShortDone:
  add r10, rbp
  add r15, 1
  jnz @counted
  jmp @cLeave
@cShortMore:
  movzx ebx, byte ptr [r12 + rcx + 528]
  movdqu xmm0, [r10 + rbx - 48]
  movdqu [r10 + 16], xmm0
  jmp @cShortDone

@cEscape:
  add r8, r15
  lea r11, [rsi + r11 * 2]
  movzx r12d, word ptr [r11 - 2]
  jmp @escape

@checkedFew:
  { a few sequences, then count again: the counted loop takes over as
    soon as it can }
  mov edx, 16
  cmp r15, rdx
  cmova r15, rdx
@checked:
  movzx eax, byte ptr [r8]
  movzx ecx, word ptr [r11]      { distance - 1, if the token takes one }
  mov eax, [rdi + rax * 4]
  test eax, eax
  js @escape
  add r8, 1
  movzx ebx, al
  movdqu xmm0, [r9]
  movdqu [r10], xmm0
  add r9, rbx
  add r10, rbx
  shr eax, 9
  lea rdx, [r11 + 2]
  cmovc r11, rdx                 { a new offset: taken, and kept }
  cmovc r12, rcx
  mov ebp, eax
  mov rcx, r12
  mov rdx, r10
  sub rdx, r14
  cmp rcx, rdx
  jae @corrupt                   { reaches before the start of the output }
  mov rsi, r10
  sub rsi, rcx                   { match source + 1 }
  cmp rcx, 15
  jb @short
  movdqu xmm0, [rsi - 1]
  movdqu [r10], xmm0
  movdqu xmm1, [rsi + 15]
  movdqu [r10 + 16], xmm1
  add r10, rbp
  sub r15, 1
  jnz @checked
  jmp @recount

@short:
  { distance < 16 (rcx = distance - 1, rsi = source + 1), any length; the
    match length may be 0 }
  sub rsi, 1
  cmp rcx, 7
  jb @tiny
@short8:
  mov rdx, [rsi]
  mov [r10], rdx
  add r10, 8
  add rsi, 8
  sub rbp, 8
  jg @short8
  add r10, rbp
  jmp @recount

@tiny:
  { distance < 8: 8 bytes one at a time, then 8-byte steps from the nearest
    multiple of the distance that is >= 8: 8,8,9,8,10,12,14 for 1..7 }
  movzx edx, byte ptr [rsi]
  mov [r10], dl
  movzx edx, byte ptr [rsi + 1]
  mov [r10 + 1], dl
  movzx edx, byte ptr [rsi + 2]
  mov [r10 + 2], dl
  movzx edx, byte ptr [rsi + 3]
  mov [r10 + 3], dl
  movzx edx, byte ptr [rsi + 4]
  mov [r10 + 4], dl
  movzx edx, byte ptr [rsi + 5]
  mov [r10 + 5], dl
  movzx edx, byte ptr [rsi + 6]
  mov [r10 + 6], dl
  movzx edx, byte ptr [rsi + 7]
  mov [r10 + 7], dl
  add r10, 8
  mov rdx, $000E0C0A08090808
  shl ecx, 3                     { (distance - 1) * 8 }
  shr rdx, cl
  movzx edx, dl
  mov rsi, r10
  sub rsi, rdx
  sub rbp, 8
  jle @tinyDone
@tiny8:
  mov rdx, [rsi]
  mov [r10], rdx
  add r10, 8
  add rsi, 8
  sub rbp, 8
  jg @tiny8
@tinyDone:
  add r10, rbp
  jmp @recount

@escape:
  { eax = the entry; a sequence fits (k > 0), so the offset stream has 2
    bytes. The extensions are read through rsi and nothing moves until
    the sequence is known to fit the wide copies: 128 literal bytes from
    a run's start, 128 output bytes past the sequence. If it does not, the
    loop stops at the token. r15 is scratch: k is counted again. }
  movzx ebx, al
  mov ebp, eax
  shr ebp, 9
  and ebp, 127
  lea rsi, [r8 + 1]
  mov rdx, [r13 + 32]
  test eax, $20000000
  jz @escMl
@escLlLoop:
  cmp rsi, rdx
  jae @done
  movzx r15d, byte ptr [rsi]
  add rsi, 1
  add rbx, r15
  cmp r15d, 255
  je @escLlLoop
@escMl:
  test eax, $40000000
  jz @escFits
@escMlLoop:
  cmp rsi, rdx
  jae @done
  movzx r15d, byte ptr [rsi]
  add rsi, 1
  add rbp, r15
  cmp r15d, 255
  je @escMlLoop
@escFits:
  lea r15, [rbx + rbp]
  mov rdx, [r13 + 56]
  sub rdx, r10
  sub rdx, 128
  cmp r15, rdx
  jg @done
  test eax, $20000000
  jnz @escRun
  { no run: the token's literals, 16 at most (k > 0: 16 are there) }
  mov r8, rsi
  movzx ecx, word ptr [r11]
  lea rdx, [r11 + 2]
  bt eax, 8
  cmovc r11, rdx                 { a new offset: taken, and kept }
  cmovc r12, rcx
  movdqu xmm0, [r9]
  movdqu [r10], xmm0
  add r9, rbx
  add r10, rbx
  jmp @escMatch

@escRun:
  mov rdx, [r13 + 48]
  sub rdx, r9
  sub rdx, 128
  cmp rbx, rdx
  jg @done
  mov r8, rsi
  movzx ecx, word ptr [r11]
  lea rdx, [r11 + 2]
  bt eax, 8
  cmovc r11, rdx
  cmovc r12, rcx
  { 128 literal bytes with no test on the run's length: most runs end in
    them, and a loop's exit would be mispredicted for nearly every run }
  movdqu xmm0, [r9]
  movdqu xmm1, [r9 + 16]
  movdqu [r10], xmm0
  movdqu [r10 + 16], xmm1
  movdqu xmm0, [r9 + 32]
  movdqu xmm1, [r9 + 48]
  movdqu [r10 + 32], xmm0
  movdqu [r10 + 48], xmm1
  movdqu xmm0, [r9 + 64]
  movdqu xmm1, [r9 + 80]
  movdqu [r10 + 64], xmm0
  movdqu [r10 + 80], xmm1
  movdqu xmm0, [r9 + 96]
  movdqu xmm1, [r9 + 112]
  movdqu [r10 + 96], xmm0
  movdqu [r10 + 112], xmm1
  cmp rbx, 128
  jbe @escRunEnd
  add r9, 128
  add r10, 128
  sub rbx, 128
@escRunLoop:
  movdqu xmm0, [r9]
  movdqu xmm1, [r9 + 16]
  movdqu [r10], xmm0
  movdqu [r10 + 16], xmm1
  prefetcht0 [r10 + 512]
  add r9, 32
  add r10, 32
  sub rbx, 32
  jg @escRunLoop
@escRunEnd:
  add r9, rbx                    { past 128, rbx <= 0: take back the overshoot }
  add r10, rbx

@escMatch:
  mov rcx, r12
  mov rdx, r10
  sub rdx, r14
  cmp rcx, rdx
  jae @corrupt
  mov rsi, r10
  sub rsi, rcx
  cmp rcx, 15
  jb @short
  movdqu xmm0, [rsi - 1]
  movdqu [r10], xmm0
  movdqu xmm1, [rsi + 15]
  movdqu [r10 + 16], xmm1
  cmp rbp, 32
  ja @escLong
  add r10, rbp
  jmp @recount
@escLong:
  { a match over 32: 128 bytes in all with no test, then a loop }
  movdqu xmm0, [rsi + 31]
  movdqu [r10 + 32], xmm0
  movdqu xmm1, [rsi + 47]
  movdqu [r10 + 48], xmm1
  movdqu xmm0, [rsi + 63]
  movdqu [r10 + 64], xmm0
  movdqu xmm1, [rsi + 79]
  movdqu [r10 + 80], xmm1
  movdqu xmm0, [rsi + 95]
  movdqu [r10 + 96], xmm0
  movdqu xmm1, [rsi + 111]
  movdqu [r10 + 112], xmm1
  cmp rbp, 128
  jbe @escLongEnd
  add rsi, 128
  add r10, 128
  sub rbp, 128
@escLongLoop:
  movdqu xmm0, [rsi - 1]
  movdqu [r10], xmm0
  movdqu xmm1, [rsi + 15]
  movdqu [r10 + 16], xmm1
  prefetcht0 [r10 + 512]
  add rsi, 32
  add r10, 32
  sub rbp, 32
  jg @escLongLoop
@escLongEnd:
  add r10, rbp
  jmp @recount

@corrupt:
  mov qword ptr [r13 + 80], -1
@done:
  mov [r13], r8
  mov [r13 + 8], r11
  mov [r13 + 16], r9
  mov [r13 + 24], r10
  add r12, 1
  mov [r13 + 72], r12
{$ifdef WIN64}
  pop rdi
  pop rsi
{$endif}
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbp
  pop rbx
end;

{$endif}

{ A match of any length at a distance under 16, in 8-byte steps (they
  may write up to 15 bytes past it); the match length may be 0. Returns
  the output past the match. }
function CopyShort4(op: PByte; d, ml: SizeInt): PByte;
var
  m: PByte;
begin
  m := op - d;
  if d < 8 then
  begin
    { the first 8 bytes one by one; they repeat with period d, so the
      rest copies from the nearest multiple of d that is >= 8 }
    op[0] := m[0]; op[1] := m[1]; op[2] := m[2]; op[3] := m[3];
    op[4] := m[4]; op[5] := m[5]; op[6] := m[6]; op[7] := m[7];
    Inc(op, 8);
    m := op - PERIOD_STRIDE[d];
    Dec(ml, 8);
  end;
  while ml > 0 do
  begin
    Copy8(op, m);
    Inc(op, 8);
    Inc(m, 8);
    Dec(ml, 8);
  end;
  Result := op + ml;
end;

{ n bytes from s to d in 16-byte steps, at least one: up to 15 bytes
  past both are read and written. A step may read what the one before
  wrote (a match at a distance of 16 or more). On its own, not inlined,
  so that FPC keeps the count in a register: in DecodeEscape4 it went to
  the stack, and the loop waited on it. }
procedure CopyWide16(d, s: PByte; n: SizeInt);
begin
  repeat
    Copy16(d, s);
    Inc(d, 16);
    Inc(s, 16);
    Dec(n, 16);
  until n <= 0;
end;

{ A chunk's sequences from st.tok on, exact and fully checked: tokens
  (with their extensions), 2-byte offsets from st.offp for those that
  take one. It goes on to st.tend, or stops after a sequence whose
  literals went on into the next literal chunk (format v5: the fast loop
  has literals again), and with toOffset as soon as the block has read
  an offset (the fast loops want one). False on corrupt input. }
function DecodeSeqs4(var st: TDecode4State; toOffset: Boolean): Boolean;
var
  tok, offp, lit, op, m: PByte;
  e: UInt32;
  ll, ml, rep, c: SizeInt;
  refilled: Boolean;
begin
  Result := False;
  tok := st.tok;
  offp := st.offp;
  lit := st.lit;
  op := st.op;
  rep := st.rep;
  refilled := False;
  while (tok < st.tend) and not refilled and not (toOffset and (offp <> st.offs0)) do
  begin
    e := st.tokens[tok^];
    Inc(tok);
    ll := e and $FF;
    ml := (e shr 8) and $FF;
    if (e and SYLZ_TOK4_LLEXT <> 0) and not GetExt(tok, st.tend, ll) then
      Exit;
    if (e and SYLZ_TOK4_MLEXT <> 0) and not GetExt(tok, st.tend, ml) then
      Exit;
    if e and SYLZ_TOK4_OFF <> 0 then
    begin
      if st.offend - offp < 2 then
        Exit;
      rep := SizeInt(offp[0] or (UInt32(offp[1]) shl 8)) + 1;
      Inc(offp, 2);
    end;
    if ll > st.oend - op then
      Exit;
    while ll > st.lend - lit do
    begin
      { what is decoded of the run, then the next literal chunk }
      c := st.lend - lit;
      Move(lit^, op^, c);
      Inc(op, c);
      Dec(ll, c);
      st.lit := st.lend;
      if not RefillLits4(st) then
        Exit;
      lit := st.lit;
      refilled := True;
    end;
    Move(lit^, op^, ll);
    Inc(op, ll);
    Inc(lit, ll);
    if (rep > op - st.dst) or (ml > st.oend - op) then
      Exit;
    m := op - rep;
    if rep >= ml then
    begin
      Move(m^, op^, ml);
      Inc(op, ml);
    end
    else if ml > st.oend - op - 16 then
      while ml > 0 do
      begin
        op^ := m^;
        Inc(op);
        Inc(m);
        Dec(ml);
      end
    { with room past the match, in wide steps: a block can open with
      megabytes of one byte repeated at the first distance }
    else if rep >= 16 then
    begin
      CopyWide16(op, m, ml);
      Inc(op, ml);
    end
    else
      op := CopyShort4(op, rep, ml);
  end;
  st.tok := tok;
  st.offp := offp;
  st.lit := lit;
  st.op := op;
  st.rep := rep;
  Result := True;
end;

{ The sequence at st.tok if it is an escape and fits what is left of the
  streams and the output; false (nothing done) otherwise: DecodeSeqs4
  then finishes the chunk, or rejects it. With room past the sequence
  (16 literal bytes, 64 output bytes) it is copied in wide steps, as the
  fast loops copy; without, exactly. }
function DecodeEscape4(var st: TDecode4State): Boolean;
const
  LONG_COPY = 1024;   { from here on Move, not 16-byte steps }
var
  p, m, lit, op: PByte;
  e: UInt32;
  ll, ml, d: SizeInt;
  roomy: Boolean;
begin
  Result := False;
  if st.tok >= st.tend then
    Exit;
  e := st.tokens[st.tok^];
  if e and (SYLZ_TOK4_LLEXT or SYLZ_TOK4_MLEXT) = 0 then
    Exit;
  p := st.tok + 1;
  ll := e and $FF;
  ml := (e shr 8) and $FF;
  if (e and SYLZ_TOK4_LLEXT <> 0) and not GetExt(p, st.tend, ll) then
    Exit;
  if (e and SYLZ_TOK4_MLEXT <> 0) and not GetExt(p, st.tend, ml) then
    Exit;
  d := st.rep;
  if e and SYLZ_TOK4_OFF <> 0 then
  begin
    if st.offend - st.offp < 2 then
      Exit;
    d := SizeInt(st.offp[0] or (UInt32(st.offp[1]) shl 8)) + 1;
  end;
  if (ll > st.lend - st.lit) or (ll > st.oend - st.op)
     or (ml > st.oend - st.op - ll) or (d > st.op + ll - st.dst) then
    Exit;
  if e and SYLZ_TOK4_OFF <> 0 then
    Inc(st.offp, 2);
  st.rep := d;
  st.tok := p;
  lit := st.lit;
  op := st.op;
  roomy := (ll <= st.lend - lit - 16) and (ll + ml <= st.oend - op - 64);
  st.lit := lit + ll;
  if roomy and (ll < LONG_COPY) then
  begin
    CopyWide16(op, lit, ll);
    Inc(op, ll);
  end
  else
  begin
    Move(lit^, op^, ll);
    Inc(op, ll);
  end;
  m := op - d;
  if (d >= ml) and ((ml >= LONG_COPY) or not roomy) then
  begin
    Move(m^, op^, ml);
    Inc(op, ml);
  end
  else if not roomy then
    while ml > 0 do
    begin
      op^ := m^;
      Inc(op);
      Inc(m);
      Dec(ml);
    end
  else if d >= 16 then
  begin
    CopyWide16(op, m, ml);
    Inc(op, ml);
  end
  else
    op := CopyShort4(op, d, ml);
  st.op := op;
  Result := True;
end;

{ DecodeFast4X64's counted loop in Pascal, same results: it stops, with
  everything at the token, at an escape or when no sequence is sure to
  fit (k = 0); st.status = -1 on corrupt input. The block must have read
  an offset already: the previous distance is then the offset before the
  next one in the stream, so a token advances the stream by the bytes it
  takes and reads the two before it, with nothing to choose.

  A distance under 16 is copied with no loop, in 8-byte steps that each
  read what the one before wrote: 16 bytes, and 16 more for a match over
  16. Under 8 the first step is the period spread over 8 bytes by a
  multiplication (see TShort4), and the others read the nearest multiple
  of the distance that is at least 8 back. The escapes are
  DecodeEscape4's: with them in here FPC kept the output pointer on the
  stack. }
procedure DecodeFast4Pas(var st: TDecode4State);
var
  lim: TDecodeLimits;   { dst only: see TDecodeLimits }
  tok, offp, lit, op, m: PByte;
  tokens: PUInt32;
  e: UInt32;
  k, c, rep: SizeInt;
begin
  tok := st.tok;
  offp := st.offp;
  lit := st.lit;
  op := st.op;
  rep := st.rep;
  tokens := st.tokens;
  lim.dst := st.dst;
  st.status := 0;
  repeat
    k := st.tend - tok;
    c := (st.offend - offp) shr 1;
    if c < k then
      k := c;
    c := (st.lend - lit) shr 4;
    if c < k then
      k := c;
    c := (st.oend - op) shr 6;
    if c < k then
      k := c;
    if k <= 0 then
      Break;
    repeat
      e := tokens[tok^];
      if e > $FFFFFF then
        Break;   { an escape }
      Inc(tok);
      Copy16(op, lit);
      c := e and $FF;
      Inc(op, c);
      Inc(lit, c);
      Inc(offp, (e shr 16) and 2);
      rep := SizeInt(PUInt16(offp - 2)^) + 1;
      if rep > op - lim.dst then
      begin
        st.status := -1;
        Exit;
      end;
      m := op - rep;
      if rep >= 16 then
      begin
        Copy16(op, m);
        Copy16(op + 16, m + 16);
      end
      else
      begin
        if rep >= 8 then
          Copy8(op, m)
        else
        begin
          PUInt64(op)^ := (PUInt64(m)^ and Short4.mask[16 - rep]) * Short4.mul[16 - rep];
          m := op - PERIOD_STRIDE[rep];
        end;
        Copy8(op + 8, m + 8);
        if e and $FF00 > $1000 then
        begin
          Copy8(op + 16, m + 16);
          Copy8(op + 24, m + 24);
        end;
      end;
      Inc(op, (e shr 8) and $FF);
      Dec(k);
    until k = 0;
  until k > 0;
  st.tok := tok;
  st.offp := offp;
  st.lit := lit;
  st.op := op;
  st.rep := rep;
end;

{$ifdef SYLZ_C}
function sylzc_decode4(st: PDecode4State): SizeInt; cdecl; external name 'sylzc_decode4';
{$endif}

{ One chunk of sequences: st.tok .. st.tend with the table st.tokens. }
function DecodeChunk4(var st: TDecode4State): Boolean;
begin
  Result := False;
  while st.tok < st.tend do
  begin
    { the fast loops want the block to have read an offset: the previous
      distance is then the offset before the next one in the stream }
    if st.offp = st.offs0 then
    begin
      if not DecodeSeqs4(st, True) then
        Exit;
      Continue;
    end;
    { the fast loop stops at an escape it has no room for, when the
      literals decoded so far run short (format v5), and near the ends of
      the streams }
{$ifdef SYLZ_ASM_X64}
    if SylzUseAsm and not SylzPreferC then
      DecodeFast4X64(@st)
    else
{$endif}
{$ifdef SYLZ_C}
    if SylzUseAsm then
      st.status := sylzc_decode4(@st)
    else
{$endif}
      DecodeFast4Pas(st);
    if st.status < 0 then
      Exit;
    if st.tok >= st.tend then
      Break;
    if DecodeEscape4(st) then
      Continue;
    if (st.litLeft > 0) and (st.lend - st.lit < LITBUF_KEEP) then
    begin
      if not RefillLits4(st) then
        Exit;
      Continue;
    end;
    { exactly: to the chunk's end, or past a literal run that goes on in
      the next literal chunk }
    if not DecodeSeqs4(st, False) then
      Exit;
  end;
  Result := True;
end;

{ A format v4 block's sequences into st.op .. st.oend: the token chunks
  sec .. secEnd, with SYLZ_TOKENS4 as their updates leave it, then the
  tail literals. The caller sets the offsets, the literals and the output
  in st. one < 0: each chunk behind its header; else one chunk, sec to
  secEnd, and one is what its header would say besides the length
  (CHUNK4_UPDATE). }
function DecodeStreams4(var st: TDecode4State; sec, secEnd: PByte; one: Int32): Boolean;
var
  own: TTable4;
  ownFast: TFast4;
  w: UInt32;
  c: SizeInt;
begin
  Result := False;
  st.rep := 1;
  st.offs0 := st.offp;
  st.short := @Short4;
  st.tokens := @SYLZ_TOKENS4[0];
  st.fast := @Fast4[0];
  while sec < secEnd do
  begin
    if one >= 0 then
      w := UInt32(one)
    else
    begin
      { the header: 2 bytes, or 4 }
      if secEnd - sec < 2 then
        Exit;
      w := sec[0] or (UInt32(sec[1]) shl 8);
      if w and CHUNK4_LONG <> 0 then
      begin
        if secEnd - sec < 4 then
          Exit;
        w := w or (UInt32(sec[2]) shl 16) or (UInt32(sec[3]) shl 24);
        Inc(sec, 2);
      end;
      Inc(sec, 2);
    end;
    if w and CHUNK4_UPDATE <> 0 then
    begin
      { entries replaced, from this chunk on }
      if sec >= secEnd then
        Exit;
      c := SizeInt(sec^) + 1;
      Inc(sec);
      if secEnd - sec < UPDATE4_BYTES * c then
        Exit;
      if st.tokens <> @own[0] then
      begin
        own := SYLZ_TOKENS4;
        ownFast := Fast4;
        st.tokens := @own[0];
        st.fast := @ownFast[0];
      end;
      while c > 0 do
      begin
        if not UnpackEntry4(sec[1] or (UInt16(sec[2]) shl 8), own[sec[0]]) then
          Exit;
        ownFast[sec[0]] := FastEntry4(own[sec[0]]);
        Inc(sec, UPDATE4_BYTES);
        Dec(c);
      end;
    end;
    st.tok := sec;
    if one >= 0 then
      st.tend := secEnd
    else
    begin
      if SizeInt(w shr 2) > secEnd - sec then
        Exit;
      st.tend := sec + (w shr 2);
    end;
    if not DecodeChunk4(st) then
      Exit;
    sec := st.tend;
  end;
  { every offset used; the rest of the literals, decoded or still in
    their chunks, is the block's tail }
  if st.offp <> st.offend then
    Exit;
  repeat
    c := st.lend - st.lit;
    if c > st.oend - st.op then
      Exit;
    Move(st.lit^, st.op^, c);
    Inc(st.op, c);
    st.lit := st.lend;
    if st.litLeft = 0 then
      Break;
    if not RefillLits4(st) then
      Exit;
  until False;
  { the output filled, and the literal chunks took the rest of the block }
  Result := (st.op = st.oend) and (st.litSrc = st.litSrcEnd);
end;

procedure SylzDCtxInit(out dctx: TSylzDCtx);
begin
  dctx.lits := nil;
  dctx.litsSize := 0;
end;

procedure SylzDCtxFree(var dctx: TSylzDCtx);
begin
  FreeMem(dctx.lits);
  SylzDCtxInit(dctx);
end;

function SylzDecompressCtx(var dctx: TSylzDCtx; src: PByte; n: SizeInt; dst: PByte;
  dstLen: SizeInt): SizeInt;
var
  hdr, count, b: UInt32;
  one: Int32;
  ctrlLen, offLen, litCount, pos, c, r: SizeInt;
  ctrl, cend, send, p: PByte;
  st: TDecode4State;
begin
  if n < HEADER_SIZE then
    Exit(-1);
  hdr := PUInt32(src)^;
  send := src + n;
  one := -1;
  if hdr and HDR_V4 <> 0 then
  begin
    { v4: tokens, offsets, literals (raw, or v3's chunks with bit 31: v5) }
    ctrlLen := hdr and HDR_TOKMASK;
    if hdr and HDR4_ONE <> 0 then
      ctrlLen := hdr and (1 shl HDR4_BITS - 1);
    if ctrlLen > n - HEADER_SIZE then
      Exit(-1);
    ctrl := src + HEADER_SIZE;
    cend := ctrl + ctrlLen;
    offLen := 0;
    if hdr and HDR4_ONE <> 0 then
    begin
      { one chunk; its header's flag and the offsets' count are in hdr }
      one := Ord(hdr and HDR4_UPDATE <> 0) * CHUNK4_UPDATE;
      { an update needs bytes to be in: with no tokens, the flag is wrong }
      if (one <> 0) and (ctrlLen = 0) then
        Exit(-1);
      count := (hdr shr HDR4_BITS) and (1 shl HDR4_BITS - 1);
      if count > UInt32((send - cend) shr 1) then
        Exit(-1);
      offLen := 2 * SizeInt(count);
    end
    else if ctrlLen > 0 then
    begin
      { the offsets' count: up to OFFCOUNT_MAX bytes, 32 bits }
      count := 0;
      c := 0;
      repeat
        if (cend >= send) or (c = 7 * OFFCOUNT_MAX) then
          Exit(-1);
        b := cend^;
        Inc(cend);
        if (c = 7 * (OFFCOUNT_MAX - 1)) and (b > 15) then
          Exit(-1);
        count := count or ((b and 127) shl c);
        Inc(c, 7);
      until b < 128;
      if count > UInt32((send - cend) shr 1) then
        Exit(-1);
      offLen := 2 * SizeInt(count);
    end;
    Inc(cend, offLen);   { where the literal section starts }
    st.offp := cend - offLen;
    st.offend := cend;
    st.op := dst;
    st.oend := dst + dstLen;
    st.dst := dst;
    if hdr and HDR_ENTROPY = 0 then
    begin
      st.lit := cend;
      st.lend := send;
      st.litSrc := nil;
      st.litSrcEnd := nil;
      st.litLeft := 0;
      st.litBuf := nil;
    end
    else
    begin
      { v5: the literal chunks are decoded as the sequences get to them }
      if send - cend < 4 then
        Exit(-1);
      litCount := PUInt32(cend)^;
      { (a u32 of 2^31 or more is negative in a 32-bit SizeInt) }
      if (litCount > dstLen) or (litCount <= 0) then
        Exit(-1);
      if dctx.litsSize < LITBUF_SIZE then
      begin
        FreeMem(dctx.lits);
        dctx.lits := GetMem(LITBUF_SIZE);
        dctx.litsSize := LITBUF_SIZE;
      end;
      st.litBuf := dctx.lits;
      st.lit := dctx.lits;
      st.lend := dctx.lits;
      st.litSrc := cend + 4;
      st.litSrcEnd := send;
      st.litLeft := litCount;
    end;
    if DecodeStreams4(st, ctrl, ctrl + ctrlLen, one) then
      Exit(dstLen);
    Exit(-1);
  end;
  ctrlLen := hdr and HDR_CTRLMASK;
  if ctrlLen > n - HEADER_SIZE then
    Exit(-1);
  ctrl := src + HEADER_SIZE;
  cend := ctrl + ctrlLen;
  if hdr and HDR_ENTROPY = 0 then
    Exit(DecodeStreams(ctrl, cend, cend, send, dst, dstLen));

  { v3: decode the literal chunks first, then the sequences over them }
  if send - cend < 4 then
    Exit(-1);
  litCount := PUInt32(cend)^;
  { (a u32 of 2^31 or more is negative in a 32-bit SizeInt) }
  if (litCount > dstLen) or (litCount <= 0) then
    Exit(-1);
  if dctx.litsSize < litCount then
  begin
    FreeMem(dctx.lits);
    dctx.lits := GetMem(litCount);
    dctx.litsSize := litCount;
  end;
  p := cend + 4;
  pos := 0;
  while pos < litCount do
  begin
    c := litCount - pos;
    if c > LIT_CHUNK then
      c := LIT_CHUNK;
    r := HufDecodeChunk(p, send - p, dctx.lits + pos, c);
    if r < 0 then
      Exit(-1);
    Inc(p, r);
    Inc(pos, c);
  end;
  if p <> send then   { the chunks must take the rest of the block exactly }
    Exit(-1);
  Result := DecodeStreams(ctrl, cend, dctx.lits, dctx.lits + litCount, dst, dstLen);
end;

function SylzBlockFormat(src: PByte; n: SizeInt): Integer;
begin
  if n < HEADER_SIZE then
    Exit(0);
  Result := 2;
  if src[3] and $40 <> 0 then
    Result := 4;
  if src[3] and $80 <> 0 then
    Inc(Result);
end;

function SylzFlagsFormat(flags: Integer): Integer;
begin
  Result := 2;
  if flags and SYLZ_V4 <> 0 then
    Result := 4;
  if flags and SYLZ_ENTROPY <> 0 then
    Inc(Result);
end;

function SylzDecompress(src: PByte; n: SizeInt; dst: PByte; dstLen: SizeInt): SizeInt;
var
  dctx: TSylzDCtx;
begin
  SylzDCtxInit(dctx);
  Result := SylzDecompressCtx(dctx, src, n, dst, dstLen);
  SylzDCtxFree(dctx);
end;

initialization
  BuildExactCodes;
  InitTable4;
  BuildFast4(SYLZ_TOKENS4, Fast4);
  BuildShort4;
end.
