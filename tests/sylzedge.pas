{ sylzedge — exhaustive edge cases for the sylz compressor and decoder.

  Every input size 0..MAXN, five kinds of data, every level, formats v2
  to v5, and every output capacity 0..SylzBound(n): compress must return
  -1 (and with cap >= SylzBound(n) never does) or a block that fits cap
  and decodes back to the input; nothing may be written past cap, nor
  past the decoded output (canary bytes). About 11 M cases; then a 16 MiB
  run with the capacities around its size, for the room checks of long
  sequences. Last, corrupt blocks whose 255-run extensions sum past 2^32:
  a 32-bit decoder once wrapped them to a small or negative length and
  moved its output pointer before the buffer; they must decode to -1.

  Usage: sylzedge [corrupt]   (corrupt: only the corrupt blocks;
  SYLZ_NOASM=1: Pascal code paths only; SYLZ_C=1: C
  instead of assembler where both exist) }
program sylzedge;

{$mode objfpc}{$H+}

uses
  SysUtils, sylz, sylzhuf;

const
  MAXN = 300;
  CANARY = 64;
  LONG_CANARY = 1024;   { the long run's: an overrun there grows with n }

var
  src, dst, outb: PByte;
  ctx: TSylzCtx;
  n, cap, r, d, i, level, kind, flags, fails: Integer;
  cases: Int64;
  seed: UInt32;

function Rnd: UInt32;
begin
  seed := seed * 1103515245 + 12345;
  Result := seed shr 16;
end;

procedure Fill(kind, n: Integer);
var
  i: Integer;
begin
  for i := 0 to n - 1 do
    case kind of
      0: src[i] := Rnd and 255;
      1: src[i] := Ord('a') + Rnd mod 3;
      2: src[i] := i mod 7;
      3: src[i] := 0;
      4: if (i > 20) and (Rnd mod 4 <> 0) then
           src[i] := src[i - 1 - Integer(Rnd mod 20)]
         else
           src[i] := Rnd and 255;
    end;
end;

{ ── corrupt extensions ── }

type
  TBuf = array of Byte;

procedure Put(var b: TBuf; const x: array of Byte);
var
  i, l: Integer;
begin
  l := Length(b);
  SetLength(b, l + Length(x));
  for i := 0 to High(x) do
    b[l + i] := x[i];
end;

procedure PutU16(var b: TBuf; v: UInt32);
begin
  Put(b, [v and 255, (v shr 8) and 255]);
end;

procedure PutU32(var b: TBuf; v: UInt32);
begin
  Put(b, [v and 255, (v shr 8) and 255, (v shr 16) and 255, v shr 24]);
end;

{ The extension bytes that take base to target (target past 2^32). }
procedure PutExt(var b: TBuf; base, target: Int64);
var
  k, l: Int64;
begin
  k := (target - base) div 255;
  l := Length(b);
  SetLength(b, l + k + 1);
  FillChar(b[l], k, 255);
  b[l + k] := (target - base) mod 255;
end;

procedure PutBytes(var b: TBuf; n: Integer);
var
  i, l: Integer;
begin
  l := Length(b);
  SetLength(b, l + n);
  for i := 0 to n - 1 do
    b[l + i] := i and 255;
end;

{ A v4 table entry for a chunk's update: literals (31: extended), match
  length (63: extended), previous offset }
function Ent4(ll, ml: Integer; rep: Boolean): UInt32;
begin
  Result := ll or (ml shl 5);
  if rep then
    Result := Result or $800;
end;

{ Decodes blk into outputs of dstLen bytes, from the exact length a wrapped
  sum would decode to up to 64 KiB: it must fail and write nothing outside
  the output. }
procedure CheckCorrupt(const name: string; const blk: TBuf; wrapLen: Integer);
const
  GUARD = 4096;
var
  buf: PByte;
  dl, i, r, sizes: Integer;
begin
  for sizes := 0 to 2 do
  begin
    case sizes of
      0: dl := wrapLen;
      1: dl := wrapLen + 64;
    else
      dl := 1 shl 16;
    end;
    Inc(cases);
    buf := GetMem(dl + 2 * GUARD);
    FillChar(buf^, dl + 2 * GUARD, $A5);
    r := SylzDecompress(@blk[0], Length(blk), buf + GUARD, dl);
    if r <> -1 then
    begin
      WriteLn(name, ': decoded to ', r, ' bytes (dstLen ', dl, ')');
      Inc(fails);
    end;
    for i := 0 to GUARD - 1 do
      if (buf[i] <> $A5) or (buf[GUARD + dl + i] <> $A5) then
      begin
        WriteLn(name, ': wrote outside the output (dstLen ', dl, ')');
        Inc(fails);
        Break;
      end;
    FreeMem(buf);
  end;
end;

{ v2: tokens with literals only and a match-extended one; v4: a chunk whose
  update sets code 0 = 16 literals and code 1 = an extended match, both at
  the previous offset (DecodeSeqs4), and code 2 = 16 literals and a new
  offset's 4-byte match, to reach the escape inside the fast loops }
procedure CorruptExtensions;
const
  V2_LLEXT = $10000;
  V2_MLEXT = $20000;
  D = 48;
var
  blk, toks, chunk: TBuf;
  t16, tml, i, j, ll16, ml16, mlbase, wrap: Integer;
  target: Int64;
  e: UInt32;
begin
  t16 := -1;
  tml := -1;
  for i := 0 to 255 do
  begin
    e := SYLZ_TOKENS[i];
    if e and (V2_LLEXT or V2_MLEXT) = 0 then
    begin
      if (t16 < 0) or (e and $FF > SYLZ_TOKENS[t16] and $FF) then
        t16 := i;
    end
    else if (e and V2_MLEXT <> 0) and (e and V2_LLEXT = 0) and (e and $FF = 0)
       and (tml < 0) then
      tml := i;
  end;
  ll16 := SYLZ_TOKENS[t16] and $FF;
  ml16 := (SYLZ_TOKENS[t16] shr 8) and $FF;
  mlbase := (SYLZ_TOKENS[tml] shr 8) and $FF;
  for j := 0 to 1 do
  begin
    { j = 0: the match length wraps to -D; 1: to 10 }
    if j = 0 then
      target := (Int64(1) shl 32) - D
    else
      target := (Int64(1) shl 32) + 10;
    wrap := 21 * (ll16 + ml16) + 10;
    toks := nil;
    Put(toks, [t16, 0, 0, tml, 0, 0]);
    PutExt(toks, mlbase, target);
    for i := 1 to 20 do
      Put(toks, [t16, 0, 0]);
    blk := nil;
    PutU32(blk, Length(toks));
    Put(blk, toks);
    PutBytes(blk, 21 * ll16);
    CheckCorrupt('v2 match extension ' + IntToStr(j), blk, wrap);
  end;
  for j := 0 to 3 do
  begin
    { j = 0, 1: tokens only at the previous offset; 2, 3: an offset first,
      then the escape; even j wraps the match length to -D, odd to 10 }
    if j and 1 = 0 then
      target := (Int64(1) shl 32) - D
    else
      target := (Int64(1) shl 32) + 10;
    toks := nil;
    if j < 2 then
      Put(toks, [0])
    else
      Put(toks, [2, 0, 0, 0, 0]);
    Put(toks, [1]);
    PutExt(toks, 2, target);
    for i := 1 to 40 + 160 * (j shr 1) do
      Put(toks, [0]);
    { the chunk: its header, its update, its tokens }
    chunk := nil;
    PutU32(chunk, (UInt32(Length(toks)) shl 2) or 3);
    Put(chunk, [1 + j shr 1, 0]);
    PutU16(chunk, Ent4(16, 0, True));
    Put(chunk, [1]);
    PutU16(chunk, Ent4(0, 63, True));
    if j >= 2 then
    begin
      Put(chunk, [2]);
      PutU16(chunk, Ent4(16, 4, False));
    end;
    Put(chunk, toks);
    blk := nil;
    PutU32(blk, $40000000 or UInt32(Length(chunk)));
    Put(blk, chunk);
    if j < 2 then
    begin
      Put(blk, [0]);
      wrap := 41 * 16 + 10;
    end
    else
    begin
      Put(blk, [1]);
      PutU16(blk, 15);
      wrap := 205 * 16 + 4 + 10;
    end;
    PutBytes(blk, wrap - 10 - 4 * (j shr 1));
    CheckCorrupt('v4 match extension ' + IntToStr(j), blk, wrap);
  end;
end;

procedure Report(const what: string);
begin
  WriteLn(what, ' n=', n, ' kind=', kind, ' level=', level, ' flags=', flags,
    ' cap=', cap, ' r=', r);
  Inc(fails);
end;

begin
  if GetEnvironmentVariable('SYLZ_NOASM') <> '' then
  begin
    SylzUseAsm := False;
    HufUseAsm := False;
  end;
  if GetEnvironmentVariable('SYLZ_C') <> '' then
  begin
    SylzPreferC := True;
    HufPreferC := True;
  end;
  seed := 1;
  fails := 0;
  cases := 0;
  if ParamStr(1) = 'corrupt' then
  begin
    CorruptExtensions;
    WriteLn('ok: ', cases, ' cases, ', fails, ' failures');
    Halt(Ord(fails > 0));
  end;
  src := GetMem(MAXN + 16);
  dst := GetMem(SylzBound(MAXN) + CANARY);
  outb := GetMem(MAXN + CANARY);
  SylzCtxInit(ctx);
  for kind := 0 to 4 do
    for n := 0 to MAXN do
    begin
      Fill(kind, n);
      for level := SYLZ_MINLEVEL to SYLZ_MAXLEVEL do
        for flags := 0 to 3 do   { SYLZ_ENTROPY, SYLZ_V4 }
          for cap := 0 to SylzBound(n) do
          begin
            Inc(cases);
            FillChar(dst^, cap + CANARY, $A5);
            r := SylzCompressEx(ctx, src, n, dst, cap, level, flags);
            for i := cap to cap + CANARY - 1 do
              if dst[i] <> $A5 then
              begin
                Report('WRITE PAST CAP');
                Break;
              end;
            if r = -1 then
            begin
              if cap >= SylzBound(n) then
                Report('FAILED WITH A SylzBound BUFFER');
              Continue;
            end;
            if (r < 0) or (r > cap) then
            begin
              Report('BAD SIZE');
              Continue;
            end;
            FillChar(outb^, n + CANARY, $5A);
            d := SylzDecompress(dst, r, outb, n);
            if (d <> n) or ((n > 0) and (CompareByte(src^, outb^, n) <> 0)) then
              Report('ROUNDTRIP MISMATCH');
            for i := n to n + CANARY - 1 do
              if outb[i] <> $5A then
              begin
                Report('DECODE WROTE PAST THE OUTPUT');
                Break;
              end;
          end;
      if fails > 20 then
        Halt(1);
    end;
  FreeMem(outb);
  FreeMem(dst);
  FreeMem(src);
  { one long run, with every capacity around what its tokens take: an
    extension byte stands for 255, and v4's room checks once counted one
    per 256 (16 MiB of zeros wrote 244 bytes past cap) }
  n := 16 shl 20;
  src := GetMem(n);
  FillChar(src^, n, 0);
  src[0] := 7;
  dst := GetMem(SylzBound(n) + LONG_CANARY);
  kind := 5;
  for level := SYLZ_MINLEVEL to SYLZ_MAXLEVEL do
    for flags := 0 to 3 do
    begin
      cap := n div 256 - 64;
      while cap < n div 255 + 64 do
      begin
        Inc(cases);
        FillChar(dst^, cap + LONG_CANARY, $A5);
        r := SylzCompressEx(ctx, src, n, dst, cap, level, flags);
        for i := cap to cap + LONG_CANARY - 1 do
          if dst[i] <> $A5 then
          begin
            Report('WRITE PAST CAP');
            Break;
          end;
        if (r < -1) or (r > cap) then
          Report('BAD SIZE');
        Inc(cap, 5);
      end;
    end;
  FreeMem(dst);
  FreeMem(src);
  SylzCtxFree(ctx);
  CorruptExtensions;
  WriteLn('ok: ', cases, ' cases, ', fails, ' failures');
  if fails > 0 then
    Halt(1);
end.
