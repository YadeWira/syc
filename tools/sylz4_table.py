#!/usr/bin/env python3
"""Derives SYLZ_TOKENS4, format v4's token table, from sample blocks.

Usage: sylz4_table.py [--table FILE] BLOCK...

Each BLOCK is one v4 block without entropy-coded literals (sylzbench -v4
with SYLZ_DUMP=prefix). They are read with the table in src/sylz.pas (or
--table FILE, the same Pascal constants), their split sequences joined
back, and split again as EmitSequence4 does; the table is the fixed codes
plus the (literals, match) pairs asked for most often, each block weighing
the same. Prints the table as it goes in src/sylz.pas.
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


def read_table(path):
    text = open(path).read()
    start = text.index('SYLZ_TOKENS4: array')
    body = text[start:text.index(');', start)]
    table = [int(x[1:], 16) for x in re.findall(r'\$[0-9A-Fa-f]+', body)]
    assert len(table) == 256
    return table


def sequences(block, table):
    """The block's sequences as (rep, literals, match), splits joined."""
    hdr, off_len = struct.unpack_from('<II', block, 0)
    assert hdr & 0x40000000 and not hdr & 0x80000000
    tok = block[8:8 + (hdr & 0x3FFFFFFF)]
    out = []
    i = 0
    pend = 0             # literals of literal-only tokens
    after_match = False  # the last token was a match
    while i < len(tok):
        e = table[tok[i]]
        i += 1
        ll = e & 0xFF
        ml = (e >> 8) & 0xFF
        if e & LLEXT:
            while True:
                v = tok[i]
                i += 1
                ll += v
                if v != 255:
                    break
        if e & MLEXT:
            while True:
                v = tok[i]
                i += 1
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


def pair_of(k, ll, ml):
    """What EmitSequence4 looks up for a sequence: the pair (kind,
    literals, match), with literals -1 for a run over LIT_SPLIT (an
    extended run and that match in one token, if there is such a code);
    None when nothing is looked up."""
    if ll > LIT_SPLIT:
        return (k, -1, ml) if ml <= MAX_ML else None
    if ll > MAX_LL:
        ll -= MAX_LL
    if ml > ML_SPLIT:
        return None
    if ml > MAX_ML:
        ml = min(MAX_ML, ml - MINREP)
    return (k, ll, ml)


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
        for k, ll, ml in seqs:
            p = pair_of(k, ll, ml)
            if p is not None and p[1] != 0:
                freq[p] = freq.get(p, 0) + 1e6 / len(seqs)
    # fixed: literal-only tokens, matches with no literals, the escapes
    codes = [l for l in range(1, MAX_LL + 1)]                               # (1, l, 0)
    codes += [OFF | m << 8 for m in range(MINMATCH, MAX_ML + 1)]
    codes += [m << 8 for m in range(MINREP, MAX_ML + 1)]
    escapes = [LLEXT,                              # literals only, extended
               LLEXT | OFF | MINMATCH << 8,        # literals extended, a 4-byte match
               MLEXT | OFF | MINMATCH << 8,        # match extended, new offset
               MLEXT | MINREP << 8]                # match extended, previous offset
    room = 256 - len(codes) - len(escapes)
    # (the escape for a long run and a 4-byte match at a new offset is fixed)
    freq.pop((0, -1, MINMATCH), None)
    best = sorted(freq.items(), key=lambda kv: (-kv[1], kv[0]))[:room]
    codes += [(0 if k else OFF) | (LLEXT if ll < 0 else ll) | ml << 8 for (k, ll, ml), _ in best]
    escapes = [e for e in escapes if e not in codes]
    assert len(escapes) == 4
    assert len(codes) == 256 - len(escapes) and len(set(codes)) == len(codes)
    # exact codes (new offset, then previous offset; by literals, then match),
    # then the escapes
    codes.sort(key=lambda e: (1 if e & LLEXT else 0, 0 if e & OFF else 1, e & 0xFF, e >> 8 & 0xFF))
    codes += escapes
    covered = sum(v for _, v in best) / max(sum(freq.values()), 1e-9)
    print('{ %d pairs with literals, %.1f%% of those asked for }' % (len(best), 100 * covered),
          file=sys.stderr)
    for i in range(0, 256, 8):
        print('    ' + ', '.join('$%07X' % e for e in codes[i:i + 8]) + (',' if i < 248 else ''))


if __name__ == '__main__':
    main()
