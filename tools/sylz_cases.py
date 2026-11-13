#!/usr/bin/env python3
"""sylz_cases.py - hand-made sylz blocks of formats v4 and v5, for decoders.

Each case covers one rule of the format (wiki: sylz format): good-* blocks
must decode to the size given, bad-* blocks must be rejected, each for
exactly the reason its description gives (a bad block is a good one with
one change). tools/sylz_ref.py checks every case as it is written.

    python3 sylz_cases.py DIR    write DIR/NAME.blk, DIR/NAME.size (the
                                 decoded size, which the container gives)
                                 and DIR/MANIFEST.txt (what each covers)
    python3 sylz_cases.py --list the cases

A decoder is right on these if it decodes every good block to the bytes
sylz_ref.py gives and rejects every bad one: syc does (`syc t --raw
--size N NAME.blk` exits with 0 or 3), and CI checks it on every path.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sylz_ref as R   # noqa: E402

# codes of the built-in table (TOKENS4), looked up by (literals, match, kind)
CODE = {}
for _c, _e in enumerate(R.TOKENS4):
    _key = ('ext' if _e & R.LLEXT4 else _e & 0xFF,
            'ext' if _e & R.MLEXT4 else (_e >> 8) & 0xFF,
            'new' if _e & R.OFF4 else 'prev')
    CODE.setdefault(_key, _c)


def code(ll, ml, kind):
    return CODE[(ll, ml, kind)]


def varint(v):
    out = bytearray()
    while True:
        b = v & 127
        v >>= 7
        if v:
            out.append(b | 128)
        else:
            out.append(b)
            return bytes(out)


def block4(chunks, offsets, lits, v5=False, one=False, upd_one=False):
    """A v4 (or v5) block. chunks: the token stream's bytes, already with
    their chunk headers (or, with one, the single chunk's bytes, its update
    first if upd_one); offsets: distances; lits: the literal section."""
    toks = b''.join(chunks)
    offb = b''.join(struct.pack('<H', d - 1) for d in offsets)
    hdr = 0x40000000 | (0x80000000 if v5 else 0)
    if one:
        hdr |= 0x20000000 | len(toks) | len(offsets) << 14 | (0x10000000 if upd_one else 0)
        return struct.pack('<I', hdr) + toks + offb + lits
    hdr |= len(toks)
    cnt = varint(len(offsets)) if toks else b''
    return struct.pack('<I', hdr) + toks + cnt + offb + lits


def chdr(n, update=False, long=False):
    if long:
        return struct.pack('<I', n << 2 | 2 | int(update))
    return struct.pack('<H', n << 2 | int(update))


def entry(ll, ml, prev):
    return ll | ml << 5 | (0x800 if prev else 0)


def raw_section(lits):
    """v5's literal section with one raw chunk (mode 0)."""
    return struct.pack('<I', len(lits)) + b'\x00' + lits


def huff_section(lits, nsyms_override=None, mode=3, damage=None):
    """v5's literal section with one Huffman chunk (mode 3, eight streams).
    The code: symbol 0 one bit, symbols 1..128 eight bits each (a complete
    prefix code), so mostly-zero literals come out small."""
    c = len(lits) if nsyms_override is None else nsyms_override
    lens = [1] + [8] * 128 + [0] * 127
    if damage == 'code-length-12':
        lens[1] = 12
    if damage == 'incomplete-code':
        lens[1] = 9
    lengths = bytes(lens[2 * k] | lens[2 * k + 1] << 4 for k in range(128))
    codes = R.canonical_codes([1] + [8] * 128 + [0] * 127)
    streams = []
    for k in range(8):
        bits = 0
        nbits = 0
        out = bytearray()
        for sym in lits[k::8]:
            cd, ln = codes[sym]
            # LSB first: the code's bits reversed
            rev = int('{:0{}b}'.format(cd, ln)[::-1], 2)
            bits |= rev << nbits
            nbits += ln
            while nbits >= 8:
                out.append(bits & 255)
                bits >>= 8
                nbits -= 8
        if nbits:
            out.append(bits & 255)
        streams.append(bytes(out))
    sizes = [len(x) for x in streams]
    if damage == 'short-stream':
        sizes[3] -= 1
        streams[3] = streams[3][:-1]
    return (struct.pack('<I', c) + bytes([mode]) + lengths
            + b''.join(struct.pack('<H', x) for x in sizes) + b''.join(streams))


def zero_lits(n):
    """mostly zero bytes, some of 1..128: literals the code above suits"""
    return bytes(0 if i % 5 else 1 + i % 128 for i in range(n))




def valid_base():
    """'abcd' then 'abcd' again at distance 4, then 'xy' at the previous
    distance... as tokens: (4 literals, match 4 new), (0, match 4 prev),
    then 2 tail literals: output 'abcdabcdabcdxy' (14 bytes)."""
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    return [chdr(len(toks)) + toks], [4], b'abcdxy', 14


CASES = []


def case(name, why):
    def deco(f):
        CASES.append((name, why, f))
        return f
    return deco


@case('base', 'not damaged: one chunk, a match at a new offset then one at the previous offset, then the tail (most bad cases change this block)')
def _ok():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs, lits), n, False


@case('update-example', "not damaged: the wiki's worked example of a table update (a control)")
def _ex():
    toks = b'\x05\x00' + b'\x00\x07\x84\x00' + b'\x07' + b'\x04\x00' + b'\x07'
    blk = struct.pack('<I', 0x40000000 | len(toks)) + toks + b'\x02' + struct.pack('<HH', 3, 3) + b'abcdefgh'
    if R.decode_block(blk, 16) != b'abcdabcdefghefgh':
        raise SystemExit('update-example: not what the wiki says')
    return blk, 16, False


@case('tok-len-past-block', 'tokLen larger than the block')
def _a():
    ch, offs, lits, n = valid_base()
    b = bytearray(block4(ch, offs, lits))
    struct.pack_into('<I', b, 0, 0x40000000 | (len(b) + 10))
    return bytes(b), n, True


@case('offcount-past-block', 'more offsets than the block holds')
def _b():
    ch, offs, lits, n = valid_base()
    toks = b''.join(ch)
    b = struct.pack('<I', 0x40000000 | len(toks)) + toks + varint(1000) + b'\x03\x00' + lits
    return b, n, True


@case('offcount-6-bytes', 'an offset count of more than 5 bytes')
def _c():
    ch, offs, lits, n = valid_base()
    toks = b''.join(ch)
    b = struct.pack('<I', 0x40000000 | len(toks)) + toks + b'\x81\x80\x80\x80\x80\x00' + b'\x03\x00' + lits
    return b, n, True


@case('offcount-over-32-bits', 'a 5-byte offset count whose last byte is over 15')
def _d():
    ch, offs, lits, n = valid_base()
    toks = b''.join(ch)
    b = struct.pack('<I', 0x40000000 | len(toks)) + toks + b'\x81\x80\x80\x80\x10' + b'\x03\x00' + lits
    return b, n, True


@case('chunk-past-tokens', "a chunk header's n past the token stream")
def _e():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    return block4([chdr(5) + toks], [4], b'abcdxy'), 14, True


@case('long-chunk-past-tokens', "a 4-byte chunk header's n past the token stream")
def _f():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    return block4([chdr(1 << 20, long=True) + toks], [4], b'abcdxy'), 14, True


@case('chunk-header-cut', 'the token stream ends inside a chunk header')
def _g():
    ch, offs, lits, n = valid_base()
    return block4(ch + [b'\x00'], offs, lits), n, True


@case('update-past-chunk', 'an update longer than the token stream')
def _h():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    upd = bytes([3]) + bytes([7]) + struct.pack('<H', entry(4, 4, False))   # says 4 entries, has 1
    return block4([chdr(len(toks), update=True) + upd + toks], [4], b'abcdxy'), 14, True


@case('update-entry-bits-12-15', 'a table entry with bits 12-15 set')
def _i():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    upd = bytes([0, 200]) + struct.pack('<H', 0x1000 | entry(4, 4, False))
    return block4([chdr(len(toks), update=True) + upd + toks], [4], b'abcdxy'), 14, True


@case('update-entry-literals-17', 'a table entry with 17 literals (only 0..16 or 31)')
def _j():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    upd = bytes([0, 200]) + struct.pack('<H', entry(17, 4, False))
    return block4([chdr(len(toks), update=True) + upd + toks], [4], b'abcdxy'), 14, True


@case('update-entry-match-33', 'a table entry with a match of 33 (only 0..32 or 63)')
def _k():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    upd = bytes([0, 200]) + struct.pack('<H', entry(0, 33, False))
    return block4([chdr(len(toks), update=True) + upd + toks], [4], b'abcdxy'), 14, True


@case('extension-past-chunk', "a token's extension runs past its chunk (into the next)")
def _l():
    t1 = bytes([code('ext', 0, 'prev'), 255])          # 255-run that goes on
    t2 = bytes([0])
    return block4([chdr(len(t1)) + t1, chdr(len(t2)) + t2], [], b'x' * 300), 300, True


@case('no-offset-left', 'a new-offset token when the offsets are used up')
def _m():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'new')])
    return block4([chdr(len(toks)) + toks], [4], b'abcdxy'), 14, True


@case('offsets-left-over', 'offsets left when the tokens end')
def _n():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs + [1], lits), n, True


@case('literals-past-stream', 'a literal run longer than the literals left')
def _o():
    toks = bytes([code(16, 4, 'new')])
    return block4([chdr(1) + toks], [4], b'abcd'), 20, True


@case('match-before-start', 'a match whose distance reaches before the output')
def _p():
    toks = bytes([code(2, 4, 'new')])
    return block4([chdr(1) + toks], [3], b'ab'), 6, True


@case('prev-match-at-start', 'the previous offset (1) at the very start, match 2')
def _q():
    toks = bytes([code(0, 2, 'prev')])
    return block4([chdr(1) + toks], [], b'ab'), 4, True


@case('zero-match-before-start', 'a match of 0 bytes whose distance reaches before the output')
def _r():
    t = bytes([code(1, 0, 'prev')])
    upd = bytes([0, 60]) + struct.pack('<H', entry(1, 0, False))   # code 60: (1, 0, new)
    return block4([chdr(1, update=True) + upd + bytes([60])], [5], b'ab'), 2, True


@case('match-past-output', 'a match that goes past the decoded size')
def _s():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs, b''), 12, True


@case('tail-short', 'tail literals that do not fill the block (decoded size too big)')
def _t():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs, lits), n + 1, True


@case('tail-long', 'tail literals past the decoded size')
def _u():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs, lits), n - 1, True


@case('one-chunk-offsets-past', 'a block of one chunk whose header counts more offsets than there are')
def _v():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    b = bytearray(block4([toks], [4], b'abcdxy', one=True))
    struct.pack_into('<I', b, 0, 0x60000000 | len(toks) | 900 << 14)
    return bytes(b), 14, True


@case('one-chunk-update-no-tokens', 'a block of one chunk with the update flag (bit 28) and no token bytes')
def _v2():
    return struct.pack('<I', 0x70000000) + b'abc', 3, True


@case('one-chunk-ok', 'not damaged: a block of one chunk (a control)')
def _w():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    return block4([toks], [4], b'abcdxy', one=True), 14, False


@case('v5-ok-raw', 'not damaged: v5 with a raw literal chunk (a control)')
def _x():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs, raw_section(lits), v5=True), n, False


@case('v5-ok-huffman', 'not damaged: v5 with an eight-stream Huffman chunk (a control)')
def _y():
    lits = zero_lits(900)
    return block4([], [], huff_section(lits), v5=True), len(lits), False


@case('v5-litcount-zero', 'a literal count of 0')
def _z():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs, struct.pack('<I', 0)), n, True


@case('v5-litcount-past-size', 'a literal count over the decoded size')
def _aa():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs, struct.pack('<I', 1000) + b'\x00' + lits), n, True


@case('v5-chunk-mode-2', 'a literal chunk of mode 2 (v3 only)')
def _ab():
    lits = zero_lits(900)
    s = bytearray(huff_section(lits))
    s[4] = 2
    return block4([], [], bytes(s), v5=True), len(lits), True


@case('v5-chunk-mode-1', 'a literal chunk of mode 1 (v3 only)')
def _ac():
    lits = zero_lits(900)
    s = bytearray(huff_section(lits))
    s[4] = 1
    return block4([], [], bytes(s), v5=True), len(lits), True


@case('v5-huffman-under-256', 'a Huffman chunk of fewer than 256 symbols')
def _ad():
    lits = zero_lits(200)
    return block4([], [], huff_section(lits), v5=True), len(lits), True


@case('v5-code-length-12', 'a code length over 11')
def _ae():
    lits = zero_lits(900)
    return block4([], [], huff_section(lits, damage='code-length-12'), v5=True), len(lits), True


@case('v5-incomplete-code', 'code lengths that are not a complete prefix code')
def _af():
    lits = zero_lits(900)
    return block4([], [], huff_section(lits, damage='incomplete-code'), v5=True), len(lits), True


@case('v5-stream-too-short', "a stream whose codes end past its size")
def _ag():
    lits = zero_lits(900)
    return block4([], [], huff_section(lits, damage='short-stream'), v5=True), len(lits), True


@case('v5-bytes-after-chunks', 'bytes left after the literal chunks')
def _ah():
    ch, offs, lits, n = valid_base()
    return block4(ch, offs, raw_section(lits) + b'\x00'), n, True


@case('v3-chunk-mode-3', 'a v3 block with an eight-stream chunk (mode 3 is v5 only)')
def _ai():
    lits = zero_lits(900)
    sec = huff_section(lits)
    return struct.pack('<I', 0x80000000) + sec, len(lits), True


# ── more good blocks: one rule of the format each ──────────────────────────

def upd(*pairs):
    """an update: (code, entry) pairs, in order"""
    return bytes([len(pairs) - 1]) + b''.join(bytes([c]) + struct.pack('<H', e) for c, e in pairs)


@case('chunk-header-4-bytes', 'not damaged: a 4-byte chunk header (bit 1) for a small chunk')
def _g1():
    toks = bytes([code(4, 4, 'new'), code(0, 4, 'prev')])
    return block4([chdr(len(toks), long=True) + toks], [4], b'abcdxy'), 14, False


@case('chunk-n0-update', 'not damaged: a chunk of 0 token bytes with an update; the next chunk uses it')
def _g2():
    return block4([chdr(0, update=True) + upd((60, entry(4, 4, False))), chdr(1) + bytes([60])],
                  [4], b'abcd'), 8, False


@case('update-code-twice', 'not damaged: an update that lists one code twice: the later entry wins')
def _g3():
    u = upd((60, entry(2, 4, False)), (60, entry(4, 4, False)))
    return block4([chdr(1, update=True) + u + bytes([60])], [4], b'abcd'), 8, False


@case('update-256', 'not damaged: an update of 256 entries (count byte 255), every code replaced')
def _g4():
    # every code becomes (4, 4, new) but code 0, which becomes (0, 4, prev)
    pairs = [(c, entry(4, 4, False)) for c in range(1, 256)] + [(0, entry(0, 4, True))]
    # (300 more matches, so that the block is no longer than SylzBound(n))
    toks = bytes([7] + [0] * 300)
    return block4([chdr(len(toks), update=True) + upd(*pairs) + toks], [4], b'abcd'), 8 + 4 * 300, False


@case('extensions-both', 'not damaged: one token with its literal and match lengths both extended (literals first, base 0 and 4)')
def _g5():
    u = upd((60, entry(31, 63, False)))
    toks = bytes([60, 20, 40])           # 20 literals, a match of 4 + 40
    lits = bytes(range(65, 85))
    return block4([chdr(len(toks), update=True) + u + toks], [20], lits), 64, False


@case('extension-255-run', 'not damaged: a literal extension of 255 then 45 (300 literals)')
def _g5b():
    toks = bytes([code('ext', 0, 'prev'), 255, 45])
    return block4([chdr(len(toks)) + toks], [], bytes(300)), 300, False


@case('extension-byte-0', 'not damaged: a literal extension of one byte 0 (no literals), then a match')
def _g6():
    u = upd((60, entry(31, 4, True)))
    toks = bytes([code(1, 0, 'prev'), 60, 0])   # 1 literal; then 0 literals and 4 at distance 1
    return block4([chdr(len(toks), update=True) + u + toks], [], b'a'), 5, False


@case('offcount-2-bytes', 'not damaged: 200 offsets, so a 2-byte offset count')
def _g7():
    toks = bytes([code(4, 4, 'new')] + [code(0, 4, 'new')] * 199)
    return block4([chdr(len(toks)) + toks], [4] * 200, b'abcd'), 4 + 4 * 200, False


@case('overlapping-match', 'not damaged: a match longer than its distance (distance 1, 100 bytes)')
def _g8():
    u = upd((60, entry(1, 63, False)))
    toks = bytes([60, 96])
    return block4([chdr(len(toks), update=True) + u + toks], [1], b'z'), 101, False


@case('prev-offset-at-start', 'not damaged: the previous offset at the start of a block is 1')
def _g9():
    toks = bytes([code(1, 4, 'prev')])
    return block4([chdr(1) + toks], [], b'q'), 5, False


@case('new-offset-match-0', 'not damaged: a new offset with a match of 0 consumes its 2 bytes and becomes the previous offset')
def _g10():
    u = upd((60, entry(2, 0, False)))
    toks = bytes([60, code(0, 4, 'prev')])
    return block4([chdr(len(toks), update=True) + u + toks], [2], b'ab'), 6, False


@case('short-matches', 'not damaged: entries with matches of 1, 2 and 3 bytes (new and previous offsets)')
def _g11():
    u = upd((60, entry(2, 1, False)), (61, entry(0, 2, False)), (62, entry(1, 3, True)), (63, entry(0, 1, True)))
    toks = bytes([60, 61, 62, 63])
    return block4([chdr(len(toks), update=True) + u + toks], [1, 2], b'abc'), 2 + 1 + 2 + 1 + 3 + 1, False


@case('v4-no-tokens', 'not damaged: a v4 block with no tokens (tokLen 0): the literals are the tail')
def _g12():
    return struct.pack('<I', 0x40000000) + b'hello', 5, False


@case('v4-empty', 'not damaged: the block of 0 bytes, 00 00 00 40')
def _g13():
    return struct.pack('<I', 0x40000000), 0, False


@case('v5-no-tokens-raw', 'not damaged: a v5 block with no tokens and a raw literal chunk')
def _g14():
    return struct.pack('<I', 0xC0000000) + raw_section(b'hello'), 5, False


@case('v5-chunks-mixed', 'not damaged: v5 literal chunks of mode 3, then mode 0, then a last chunk of 100 (raw: under 256)')
def _g15():
    a = zero_lits(65536)
    h = huff_section(a)[4:]                     # the chunk without the count
    b = bytes((i * 7) & 255 for i in range(65536))
    c = bytes(range(100))
    sec = struct.pack('<I', 65536 * 2 + 100) + h + b'\x00' + b + b'\x00' + c
    return struct.pack('<I', 0xC0000000) + sec, 65536 * 2 + 100, False


@case('v5-huffman-padding', 'not damaged: a stream whose padding bits are not 0 (they are ignored)')
def _g16():
    lits = zero_lits(900)
    sec = bytearray(huff_section(lits))
    base = 4 + 1 + 128
    size0 = struct.unpack_from('<H', sec, base)[0]
    sec[base + 16 + size0 - 1] |= 0x80
    return block4([], [], bytes(sec), v5=True), 900, False


@case('v5-huffman-stream-slack', 'not damaged: a stream with a byte after its last code (its size counts it)')
def _g17():
    lits = zero_lits(900)
    sec = bytearray(huff_section(lits))
    base = 4 + 1 + 128
    size0 = struct.unpack_from('<H', sec, base)[0]
    s0 = base + 16
    sec = sec[:s0 + size0] + b'\x00' + sec[s0 + size0:]
    struct.pack_into('<H', sec, base, size0 + 1)
    return block4([], [], bytes(sec), v5=True), 900, False


@case('v2-block', 'not damaged: a v2 block, as sylz4 and sylz5 may write (v2 token 98: 4 literals, match 4)')
def _g18():
    ctrl = bytes([98]) + struct.pack('<H', 3)
    return struct.pack('<I', len(ctrl)) + ctrl + b'abcdxy', 10, False


@case('v3-block', 'not damaged: a v3 block (a raw literal chunk), as sylz5 may write')
def _g19():
    ctrl = bytes([98]) + struct.pack('<H', 3)
    return struct.pack('<I', 0x80000000 | len(ctrl)) + ctrl + struct.pack('<I', 6) + b'\x00abcdxy', 10, False


@case('v5-empty-header', 'a v5 header (C0 00 00 00) with nothing after it: a v5 block has literals (the empty block is v4)')
def _b20():
    return struct.pack('<I', 0xC0000000), 0, True


def build():
    out = []
    for name, why, f in CASES:
        blk, n, bad = f()
        try:
            got = R.decode_block(blk, n)
            ok = True
        except R.SylzError:
            ok = False
        if bad and ok:
            raise SystemExit('%s: sylz_ref.py decodes it, but it must be rejected' % name)
        if not bad and not ok:
            raise SystemExit('%s: sylz_ref.py rejects a block that must decode' % name)
        out.append((name, why, blk, n, bad))
    return out


def main(argv):
    if len(argv) == 2 and argv[1] == '--list':
        for name, why, _ in CASES:
            print('%-30s %s' % (name, why))
        return 0
    if len(argv) != 2:
        print(__doc__)
        return 2
    d = argv[1]
    os.makedirs(d, exist_ok=True)
    cases = build()
    man = ['# sylz v4/v5 decoder cases: NAME  decoded-size  blk-bytes  what it covers',
           '# good-*: must decode to decoded-size bytes (tools/sylz_ref.py gives them);',
           '# bad-*: must be rejected. Written by tools/sylz_cases.py.']
    for name, why, blk, n, bad in cases:
        prefix = 'bad-' if bad else 'good-'
        open(os.path.join(d, prefix + name + '.blk'), 'wb').write(blk)
        open(os.path.join(d, prefix + name + '.size'), 'w').write('%d\n' % n)
        man.append('%-36s %8d %8d  %s' % (prefix + name, n, len(blk), why))
    open(os.path.join(d, 'MANIFEST.txt'), 'w').write('\n'.join(man) + '\n')
    print('%d cases (%d damaged), all as sylz_ref.py expects' % (len(cases), sum(c[4] for c in cases)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
