{ sylzedge — exhaustive edge cases for the sylz compressor and decoder.

  Every input size 0..MAXN, five kinds of data, every level, format v2
  and v3, and every output capacity 0..SylzBound(n): compress must return
  -1 (and with cap >= SylzBound(n) never does) or a block that fits cap
  and decodes back to the input; nothing may be written past cap, nor
  past the decoded output (canary bytes). About 5.7 M cases.

  Usage: sylzedge   (SYLZ_NOASM=1: Pascal code paths only) }
program sylzedge;

{$mode objfpc}{$H+}

uses
  SysUtils, sylz;

const
  MAXN = 300;
  CANARY = 64;

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

procedure Report(const what: string);
begin
  WriteLn(what, ' n=', n, ' kind=', kind, ' level=', level, ' flags=', flags,
    ' cap=', cap, ' r=', r);
  Inc(fails);
end;

begin
  if GetEnvironmentVariable('SYLZ_NOASM') <> '' then
    SylzUseAsm := False;
  seed := 1;
  fails := 0;
  cases := 0;
  src := GetMem(MAXN + 16);
  dst := GetMem(SylzBound(MAXN) + CANARY);
  outb := GetMem(MAXN + CANARY);
  SylzCtxInit(ctx);
  for kind := 0 to 4 do
    for n := 0 to MAXN do
    begin
      Fill(kind, n);
      for level := SYLZ_MINLEVEL to SYLZ_MAXLEVEL do
        for flags := 0 to 1 do
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
  SylzCtxFree(ctx);
  FreeMem(outb);
  FreeMem(dst);
  FreeMem(src);
  WriteLn('ok: ', cases, ' cases, ', fails, ' failures');
  if fails > 0 then
    Halt(1);
end.
