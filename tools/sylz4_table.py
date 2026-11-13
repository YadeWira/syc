#!/usr/bin/env python3
"""Derives SYLZ_TOKENS4, format v4's token table, from sample blocks.

Usage: sylz4_table.py [--table FILE] BLOCK...

Each BLOCK is one v4 block without entropy-coded literals (sylzbench -v4
with SYLZ_DUMP=prefix; a block the encoder left in format v2's layout is
skipped). They are read with the table in src/sylz.pas (or --table FILE,
the same Pascal constants) and their updates of it, their split
sequences joined back, and each sequence asked what PutTokens4 looks up
for it first (PairOf4, before it tries other splits); the table is the
fixed codes plus the cells asked for most often, each block weighing the
same. Prints the table as it goes in src/sylz.pas.
"""
import re
import struct
import sys

OFF = 0x20000        # the sequence takes 2 bytes from the offset stream
LLEXT = 0x1000000
MLEXT = 0x2000000
MAX_LL = 16          # exact codes: literals 0..16, match up to 32
MAX_ML = 32
LIT_SPLIT = 32       # literal runs up to here are split, longer ones extended
ML_SPLIT = 64        # the same for matches
MINMATCH = 4
MINREP = 2
ROW_EXT = MAX_LL + 1   # a cell's row: the literals, or extended
COL_EXT = MAX_ML + 1   # its column: the match length, or extended


def read_table(path):
    text = open(path).read()
    start = text.index('SYLZ_TOKENS4: array')
    body = text[start:text.index(');', start)]
    table = [int(x[1:], 16) for x in re.findall(r'\$[0-9A-Fa-f]+', body)]
    assert len(table) == 256
    return table


def table_entry(v):
    """An update's 16-bit entry as a table value."""
    ll = v & 31
    ml = (v >> 5) & 63
    prev = (v >> 11) & 1
    e = 0 if prev else OFF
    e |= LLEXT if ll == 31 else ll
    if ml == 63:
        e |= MLEXT | (MINREP if prev else MINMATCH) << 8
    else:
        e |= ml << 8
    return e


def sequences(block, static):
    """The block's sequences as (kind, literals, match), splits joined;
    None for a block in format v2's layout."""
    hdr, = struct.unpack_from('<I', block, 0)
    assert not hdr & 0x80000000
    if not hdr & 0x40000000:
        return None
    one = hdr & 0x20000000   # one chunk: no chunk header, its flag in bit 28
    tok_end = 4 + (hdr & 0x3FFF if one else hdr & 0x1FFFFFFF)
    table = list(static)
    out = []
    c = 4
    pend = 0             # literals of literal-only tokens
    after_match = False  # the last token was a match
    while c < tok_end:
        if one:
            chdr = (hdr >> 28) & 1
        else:
            chdr = block[c] | block[c + 1] << 8
            c += 2
            if chdr & 2:
                chdr |= block[c] << 16 | block[c + 1] << 24
                c += 2
        if chdr & 1:
            count = block[c] + 1
            c += 1
            for _ in range(count):
                table[block[c]] = table_entry(block[c + 1] | block[c + 2] << 8)
                c += 3
        cend = tok_end if one else c + (chdr >> 2)
        while c < cend:
            e = table[block[c]]
            c += 1
            ll = e & 0xFF
            ml = (e >> 8) & 0xFF
            if e & LLEXT:
                while True:
                    v = block[c]
                    c += 1
                    ll += v
                    if v != 255:
                        break
            if e & MLEXT:
                while True:
                    v = block[c]
                    c += 1
                    ml += v
                    if v != 255:
                        break
            rep = 0 if e & OFF else 1
            if ml == 0:
                pend += ll
                after_match = False
            elif rep and ll == 0 and pend == 0 and after_match:
                k, l, m = out[-1]          # the rest of a split match
                out[-1] = (k, l, m + ml)
            else:
                out.append((rep, pend + ll, ml))
                pend = 0
                after_match = True
    return out


def cell_of(k, ll, ml):
    """PairOf4 in sylz.pas: the cell (kind, row, column) a sequence asks
    for first, or None when it only takes codes every table has."""
    if ll > LIT_SPLIT:
        return (k, ROW_EXT, COL_EXT if ml > MAX_ML else ml)
    if ll > MAX_LL:
        if k == 0 and ml == MINMATCH:
            return None
        ll -= MAX_LL
    if ml > ML_SPLIT:
        return (k, ll, COL_EXT) if ll else None
    if ml > MAX_ML:
        ml = min(MAX_ML, ml - MINREP)
    return (k, ll, ml)


def fixed(k, row, col):
    """FixedCell4 in sylz.pas: the cells the encoder falls back on."""
    return row == 0 or (k == 1 and col == 0) or (k == 0 and row == ROW_EXT and col == MINMATCH)


def entry_of(k, row, col):
    e = 0 if k else OFF
    e |= LLEXT if row == ROW_EXT else row
    if col == COL_EXT:
        e |= MLEXT | (MINREP if k else MINMATCH) << 8
    else:
        e |= col << 8
    return e


def main():
    args = sys.argv[1:]
    path = __file__.rsplit('/', 2)[0] + '/src/sylz.pas'
    if args and args[0] == '--table':
        path = args[1]
        args = args[2:]
    table = read_table(path)
    freq = {}
    for name in args:
        seqs = sequences(open(name, 'rb').read(), table)
        if not seqs:
            continue
        for k, ll, ml in seqs:
            p = cell_of(k, ll, ml)
            if p is not None and not fixed(*p):
                freq[p] = freq.get(p, 0) + 1e6 / len(seqs)
    # fixed: literal-only tokens, matches with no literals, the escapes
    codes = [entry_of(1, l, 0) for l in range(1, MAX_LL + 1)]
    codes += [entry_of(0, 0, m) for m in range(MINMATCH, MAX_ML + 1)]
    codes += [entry_of(1, 0, m) for m in range(MINREP, MAX_ML + 1)]
    escapes = [entry_of(1, ROW_EXT, 0),            # literals only, extended
               entry_of(0, ROW_EXT, MINMATCH),     # literals extended, a 4-byte match
               entry_of(0, 0, COL_EXT),            # match extended, new offset
               entry_of(1, 0, COL_EXT)]            # match extended, previous offset
    room = 256 - len(codes) - len(escapes)
    best = sorted(freq.items(), key=lambda kv: (-kv[1], kv[0]))[:room]
    codes += [entry_of(*p) for p, _ in best]
    assert len(codes) == 256 - len(escapes) and len(set(codes + escapes)) == 256
    # exact codes (new offset, then previous offset; by literals, then match),
    # then the escapes: the fixed ones last, code 255 one of them
    codes.sort(key=lambda e: (1 if e & (LLEXT | MLEXT) else 0, 0 if e & OFF else 1,
                              e & 0xFF, e >> 8 & 0xFF))
    codes += escapes
    covered = sum(v for _, v in best) / max(sum(freq.values()), 1e-9)
    print('{ %d cells besides the fixed ones, %.1f%% of those asked for }' % (len(best), 100 * covered),
          file=sys.stderr)
    for i in range(0, 256, 8):
        print('    ' + ', '.join('$%07X' % e for e in codes[i:i + 8]) + (',' if i < 248 else ''))


if __name__ == '__main__':
    main()
