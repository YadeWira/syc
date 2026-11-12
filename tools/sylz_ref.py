#!/usr/bin/env python3
"""sylz_ref.py - a reference decoder for sylz blocks, formats v2 to v5.

Written from the format description (the wiki's sylz-format page) for
clarity, not speed: an oracle to check other decoders against (zpaq-std
writes its ZPAQL decoders against it). It reads one block, the bytes
sylz's compress() wrote (zpaq-std's u32 size prefix not included), and
the decoded size, and raises SylzError on anything malformed: it never
reads past the block, writes past the size, or loops without bound.

    python3 sylz_ref.py BLOCK SIZE OUT    decode one block
    python3 sylz_ref.py --check DIR       check every vector in DIR
                                          (NAME.orig, NAME.blk)
"""
import os
import sys

# SYLZ_TOKENS (src/sylz.pas): bits 0-7 literal length, 8-15 match length,
# bit 16 literal length extended, bit 17 match length extended.
TOKENS = [
    0x00400, 0x00500, 0x00600, 0x00700, 0x00800, 0x00900, 0x00A00, 0x00B00,
    0x00C00, 0x00D00, 0x00E00, 0x00F00, 0x01000, 0x01100, 0x01200, 0x01300,
    0x01400, 0x01500, 0x01600, 0x01700, 0x01800, 0x01900, 0x01A00, 0x01B00,
    0x01C00, 0x01D00, 0x01E00, 0x01F00, 0x02000, 0x00401, 0x00501, 0x00601,
    0x00701, 0x00801, 0x00901, 0x00A01, 0x00B01, 0x00C01, 0x00D01, 0x00E01,
    0x00F01, 0x01001, 0x01101, 0x01201, 0x01301, 0x01401, 0x01501, 0x01601,
    0x01701, 0x01801, 0x01901, 0x01A01, 0x01B01, 0x01C01, 0x01D01, 0x01E01,
    0x01F01, 0x02001, 0x00402, 0x00502, 0x00602, 0x00702, 0x00802, 0x00902,
    0x00A02, 0x00B02, 0x00C02, 0x00D02, 0x00E02, 0x00F02, 0x01002, 0x01102,
    0x01202, 0x01302, 0x01402, 0x01502, 0x01602, 0x01702, 0x01802, 0x01A02,
    0x01E02, 0x01F02, 0x00403, 0x00503, 0x00603, 0x00703, 0x00803, 0x00903,
    0x00A03, 0x00B03, 0x00C03, 0x00D03, 0x00E03, 0x00F03, 0x01003, 0x01103,
    0x01203, 0x01303, 0x00404, 0x00504, 0x00604, 0x00704, 0x00804, 0x00904,
    0x00A04, 0x00B04, 0x00C04, 0x00D04, 0x00E04, 0x00F04, 0x01004, 0x01204,
    0x01304, 0x00405, 0x00505, 0x00605, 0x00705, 0x00805, 0x00905, 0x00A05,
    0x00B05, 0x00C05, 0x00D05, 0x00E05, 0x00F05, 0x01205, 0x01305, 0x01705,
    0x00406, 0x00506, 0x00606, 0x00706, 0x00806, 0x00906, 0x00A06, 0x00B06,
    0x00C06, 0x00D06, 0x00E06, 0x01206, 0x00407, 0x00507, 0x00607, 0x00707,
    0x00807, 0x00907, 0x00A07, 0x00B07, 0x00D07, 0x01107, 0x00408, 0x00508,
    0x00608, 0x00708, 0x00808, 0x00908, 0x00A08, 0x00B08, 0x00C08, 0x00409,
    0x00509, 0x00609, 0x00709, 0x00809, 0x00909, 0x00A09, 0x00B09, 0x01309,
    0x0040A, 0x0050A, 0x0060A, 0x0070A, 0x0080A, 0x00A0A, 0x00E0A, 0x0140A,
    0x0040B, 0x0050B, 0x0060B, 0x0070B, 0x0080B, 0x0090B, 0x00D0B, 0x0140B,
    0x0150B, 0x0040C, 0x0050C, 0x0060C, 0x0070C, 0x0080C, 0x00C0C, 0x0140C,
    0x0040D, 0x0050D, 0x0060D, 0x0070D, 0x00B0D, 0x0040E, 0x0050E, 0x0060E,
    0x0070E, 0x0080E, 0x0090E, 0x00A0E, 0x0040F, 0x0050F, 0x0060F, 0x0070F,
    0x0080F, 0x0090F, 0x20400, 0x20401, 0x20402, 0x20403, 0x20404, 0x20405,
    0x20406, 0x20407, 0x20408, 0x20409, 0x2040A, 0x2040B, 0x2040C, 0x2040D,
    0x2040E, 0x2040F, 0x10400, 0x10500, 0x10600, 0x10700, 0x10800, 0x10900,
    0x10A00, 0x10B00, 0x10C00, 0x10D00, 0x10E00, 0x10F00, 0x11000, 0x11100,
    0x11200, 0x11300, 0x11400, 0x11500, 0x11600, 0x11700, 0x11800, 0x11900,
    0x11A00, 0x11B00, 0x11C00, 0x11D00, 0x11E00, 0x11F00, 0x12000, 0x30400,
]
LLEXT = 0x10000
MLEXT = 0x20000
MINMATCH = 4

# SYLZ_TOKENS4 (src/sylz.pas), formats v4 and v5's built-in table (they are
# provisional: it may still change): bits 0-7 literal length, 8-15 match
# length, bit 17 a new offset (2 bytes of the offset stream; clear: the
# previous sequence's), bit 24 literal length extended, bit 25 match length
# extended.
TOKENS4 = [
    0x0020400, 0x0020500, 0x0020600, 0x0020700, 0x0020800, 0x0020900, 0x0020A00, 0x0020B00,
    0x0020C00, 0x0020D00, 0x0020E00, 0x0020F00, 0x0021000, 0x0021100, 0x0021200, 0x0021300,
    0x0021400, 0x0021500, 0x0021600, 0x0021700, 0x0021800, 0x0021900, 0x0021A00, 0x0021B00,
    0x0021C00, 0x0021D00, 0x0021E00, 0x0021F00, 0x0022000, 0x0020401, 0x0020501, 0x0020601,
    0x0020701, 0x0020801, 0x0020901, 0x0020A01, 0x0020B01, 0x0020C01, 0x0020D01, 0x0020E01,
    0x0020F01, 0x0021001, 0x0021101, 0x0021201, 0x0021301, 0x0021401, 0x0021501, 0x0021701,
    0x0021B01, 0x0021E01, 0x0021F01, 0x0022001, 0x0020402, 0x0020502, 0x0020602, 0x0020702,
    0x0020802, 0x0020902, 0x0020A02, 0x0020B02, 0x0020C02, 0x0020D02, 0x0020E02, 0x0020F02,
    0x0021002, 0x0021202, 0x0021502, 0x0021E02, 0x0022002, 0x0020403, 0x0020503, 0x0020603,
    0x0020703, 0x0020803, 0x0020903, 0x0020A03, 0x0020B03, 0x0020C03, 0x0020D03, 0x0020E03,
    0x0022003, 0x0020404, 0x0020504, 0x0020604, 0x0020704, 0x0020804, 0x0020904, 0x0020A04,
    0x0020B04, 0x0020C04, 0x0022004, 0x0020405, 0x0020505, 0x0020605, 0x0020705, 0x0020805,
    0x0020905, 0x0020A05, 0x0020B05, 0x0020D05, 0x0020406, 0x0020506, 0x0020606, 0x0020706,
    0x0020806, 0x0020906, 0x0020A06, 0x0020C06, 0x0020407, 0x0020507, 0x0020607, 0x0020707,
    0x0020807, 0x0020907, 0x0020408, 0x0020508, 0x0020608, 0x0020708, 0x0020808, 0x0020409,
    0x0020509, 0x0020609, 0x0020709, 0x0020809, 0x002040A, 0x002050A, 0x002060A, 0x002070A,
    0x002080A, 0x002040B, 0x002050B, 0x002060B, 0x002070B, 0x002140B, 0x002040C, 0x002060C,
    0x002070C, 0x002140C, 0x002040D, 0x002050D, 0x002060D, 0x002070D, 0x002040E, 0x002060E,
    0x002040F, 0x002050F, 0x002060F, 0x002070F, 0x002080F, 0x0020410, 0x0020610, 0x0000200,
    0x0000300, 0x0000400, 0x0000500, 0x0000600, 0x0000700, 0x0000800, 0x0000900, 0x0000A00,
    0x0000B00, 0x0000C00, 0x0000D00, 0x0000E00, 0x0000F00, 0x0001000, 0x0001100, 0x0001200,
    0x0001300, 0x0001400, 0x0001500, 0x0001600, 0x0001700, 0x0001800, 0x0001900, 0x0001A00,
    0x0001B00, 0x0001C00, 0x0001D00, 0x0001E00, 0x0001F00, 0x0002000, 0x0000001, 0x0000401,
    0x0000501, 0x0000601, 0x0000701, 0x0000801, 0x0000901, 0x0000A01, 0x0000B01, 0x0000C01,
    0x0000D01, 0x0000E01, 0x0000F01, 0x0001001, 0x0001101, 0x0001301, 0x0001401, 0x0001501,
    0x0001701, 0x0001B01, 0x0002001, 0x0000002, 0x0000402, 0x0000502, 0x0000602, 0x0000702,
    0x0000802, 0x0000A02, 0x0000E02, 0x0001202, 0x0001602, 0x0001E02, 0x0002002, 0x0000003,
    0x0000403, 0x0000503, 0x0000903, 0x0000D03, 0x0000004, 0x0000404, 0x0000504, 0x0000005,
    0x0000405, 0x0000605, 0x0000705, 0x0000B05, 0x0000006, 0x0000406, 0x0000606, 0x0000A06,
    0x0000007, 0x0000407, 0x0000507, 0x0000607, 0x0000008, 0x0000009, 0x000000A, 0x000000B,
    0x000050B, 0x000000C, 0x000040C, 0x000000D, 0x000000E, 0x000000F, 0x0000010, 0x1020500,
    0x1020600, 0x1020700, 0x1020800, 0x1020900, 0x1000000, 0x1020400, 0x2020400, 0x2000200,
]
OFF4 = 0x20000
LLEXT4 = 0x1000000
MLEXT4 = 0x2000000
MINREP = 2
LIT_CHUNK = 65536
MAXBITS = 11
MIN_HUFF_SYMBOLS = 256


class SylzError(Exception):
    pass


def u16(b, i):
    if i + 2 > len(b):
        raise SylzError("truncated")
    return b[i] | b[i + 1] << 8


def u32(b, i):
    if i + 4 > len(b):
        raise SylzError("truncated")
    return b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24


# ── format v2's sequences ─────────────────────────────────────────────────

def decode_sequences(ctrl, lits, n):
    """The control stream over the literal stream: n output bytes."""
    out = bytearray()
    c = 0
    lp = 0
    while c < len(ctrl):
        if len(ctrl) - c < 3:
            raise SylzError("control stream ends inside a sequence")
        e = TOKENS[ctrl[c]]
        off = (ctrl[c + 1] | ctrl[c + 2] << 8) + 1
        c += 3
        ll = e & 0xFF
        ml = (e >> 8) & 0xFF
        for flag in (LLEXT, MLEXT):
            if e & flag:
                while True:   # 255-runs: at most len(ctrl) steps
                    if c >= len(ctrl):
                        raise SylzError("extension runs past the control stream")
                    v = ctrl[c]
                    c += 1
                    if flag == LLEXT:
                        ll += v
                    else:
                        ml += v
                    if v != 255:
                        break
        if ll > len(lits) - lp or ll > n - len(out):
            raise SylzError("literal run too long")
        out += lits[lp:lp + ll]
        lp += ll
        if off > len(out) or ml > n - len(out):
            raise SylzError("match before the start or past the end")
        start = len(out) - off
        for i in range(ml):   # byte by byte: the match may overlap itself
            out.append(out[start + i])
    # the rest of the literal stream is the block's tail
    if len(lits) - lp != n - len(out):
        raise SylzError("tail literals do not fill the block")
    out += lits[lp:]
    return bytes(out)


# ── format v3's literal chunks ────────────────────────────────────────────

def canonical_codes(lengths):
    """symbol -> (code, length), deflate's canonical assignment."""
    count = [0] * (MAXBITS + 2)
    for l in lengths:
        if l:
            count[l] += 1
    used = sum(count[1:])
    kraft = sum(count[b] << (MAXBITS - b) for b in range(1, MAXBITS + 1))
    if used < 2 or kraft != 1 << MAXBITS:
        raise SylzError("not a complete prefix code over two or more symbols")
    nxt = [0] * (MAXBITS + 2)
    for b in range(1, MAXBITS + 1):
        nxt[b + 1] = (nxt[b] + count[b]) << 1
    codes = {}
    for sym, l in enumerate(lengths):
        if l:
            codes[sym] = (nxt[l], l)
            nxt[l] += 1
    return codes


class BitReader:
    """LSB first over data[start:end]: a code's first bit is the lowest
    unused bit. Bits past end read as 0; reading past it is an error the
    caller checks with overrun()."""

    def __init__(self, data, start, end):
        self.data, self.start, self.end = data, start, end
        self.bit = 0   # bits consumed

    def read(self):
        i = self.start + (self.bit >> 3)
        v = 0
        if i < self.end:
            v = (self.data[i] >> (self.bit & 7)) & 1
        self.bit += 1
        return v

    def overrun(self):
        return self.bit > (self.end - self.start) * 8

    def bytes_used(self):
        return (self.bit + 7) >> 3


def decode_huffman_run(reader, decode_map, count):
    out = bytearray()
    for _ in range(count):
        code = 0
        for length in range(1, MAXBITS + 1):
            # the first bit read is the code's most significant one
            code = code << 1 | reader.read()
            sym = decode_map.get((code, length))
            if sym is not None:
                out.append(sym)
                break
        else:
            raise SylzError("no code matches")   # cannot happen: the code is complete
        if reader.overrun():
            raise SylzError("stream runs past its bytes")
    return out


def decode_chunk(b, i, c):
    """The chunk at b[i:] holding c literals: (literals, next i)."""
    if i >= len(b):
        raise SylzError("truncated")
    mode = b[i]
    if mode == 0:
        if len(b) - (i + 1) < c:
            raise SylzError("truncated raw chunk")
        return bytes(b[i + 1:i + 1 + c]), i + 1 + c
    if mode not in (1, 2):
        raise SylzError("unknown chunk mode %d" % mode)
    if c < MIN_HUFF_SYMBOLS:
        raise SylzError("Huffman chunk under 256 symbols")
    nsizes = 4 if mode == 2 else 3
    head = 1 + 128 + 2 * nsizes
    if len(b) - i < head:
        raise SylzError("truncated chunk header")
    lengths = []
    for k in range(128):
        v = b[i + 1 + k]
        lengths += [v & 15, v >> 4]
    if max(lengths) > MAXBITS:
        raise SylzError("code length over 11")
    codes = canonical_codes(lengths)
    decode_map = {cl: sym for sym, cl in codes.items()}
    sizes = [u16(b, i + 129 + 2 * k) for k in range(nsizes)]
    p = i + head
    q = (c + 3) // 4
    runs = [q, q, q, c - 3 * q]
    out = bytearray()
    for k in range(4):
        if k < 3 or mode == 2:
            end = p + sizes[k]
            if end > len(b):
                raise SylzError("stream past the block")
        else:
            end = len(b)   # mode 1: stream 4 ends where its last code does
        r = BitReader(b, p, end)
        out += decode_huffman_run(r, decode_map, runs[k])
        p = end if (k < 3 or mode == 2) else p + r.bytes_used()
    return bytes(out), p


# ── formats v4 and v5 ─────────────────────────────────────────────────────

def table_entry(v):
    """A chunk table's 16-bit entry as a TOKENS4 value."""
    ll = v & 31
    ml = (v >> 5) & 63
    if v >> 12 or (ll > 16 and ll != 31) or (ml > 32 and ml != 63):
        raise SylzError("malformed table entry")
    prev = (v >> 11) & 1
    e = 0 if prev else OFF4
    e |= LLEXT4 if ll == 31 else ll
    if ml == 63:
        e |= MLEXT4 | (MINREP if prev else MINMATCH) << 8
    else:
        e |= ml << 8
    return e


def decode_block4(b, n):
    """A format v4 or v5 block of n decoded bytes."""
    hdr = u32(b, 0)
    tok_len = hdr & 0x3FFFFFFF
    off_len = u32(b, 4)
    if tok_len > len(b) - 8 or off_len > len(b) - 8 - tok_len or off_len & 1:
        raise SylzError("stream lengths past the block")
    tok_end = 8 + tok_len
    offs = b[tok_end:tok_end + off_len]
    i = tok_end + off_len
    if hdr >> 31:
        lits, i = decode_literal_section(b, i, n)
        if i != len(b):
            raise SylzError("the chunks do not take the rest of the block")
    else:
        lits = b[i:]
    out = bytearray()
    lp = 0   # literals used
    op = 0   # offset bytes used
    dist = 1
    c = 8
    while c < tok_end:
        chdr = u32(b[:tok_end], c)
        c += 4
        if chdr & 0x40000000:
            raise SylzError("chunk header bit 30")
        table = TOKENS4
        if chdr >> 31:
            if tok_end - c < 512:
                raise SylzError("truncated table")
            table = [table_entry(b[c + 2 * k] | b[c + 2 * k + 1] << 8) for k in range(256)]
            c += 512
        cend = c + (chdr & 0x3FFFFFFF)
        if cend > tok_end:
            raise SylzError("chunk past the token stream")
        while c < cend:
            e = table[b[c]]
            c += 1
            ll = e & 0xFF
            ml = (e >> 8) & 0xFF
            for flag in (LLEXT4, MLEXT4):
                if e & flag:
                    while True:   # 255-runs: at most the chunk's bytes
                        if c >= cend:
                            raise SylzError("extension runs past the chunk")
                        v = b[c]
                        c += 1
                        if flag == LLEXT4:
                            ll += v
                        else:
                            ml += v
                        if v != 255:
                            break
            if e & OFF4:
                if len(offs) - op < 2:
                    raise SylzError("no offset left")
                dist = (offs[op] | offs[op + 1] << 8) + 1
                op += 2
            if ll > len(lits) - lp or ll > n - len(out):
                raise SylzError("literal run too long")
            out += lits[lp:lp + ll]
            lp += ll
            if dist > len(out) or ml > n - len(out):
                raise SylzError("match before the start or past the end")
            start = len(out) - dist
            for k in range(ml):   # byte by byte: the match may overlap itself
                out.append(out[start + k])
    if op != len(offs):
        raise SylzError("offsets left over")
    if len(lits) - lp != n - len(out):
        raise SylzError("tail literals do not fill the block")
    out += lits[lp:]
    return bytes(out)


def decode_literal_section(b, i, n):
    """v3's and v5's coded literals at b[i:]: (literals, next i)."""
    lit_count = u32(b, i)
    if lit_count == 0 or lit_count > n:
        raise SylzError("literal count out of range")
    i += 4
    lits = bytearray()
    while len(lits) < lit_count:
        c = min(LIT_CHUNK, lit_count - len(lits))
        chunk, i = decode_chunk(b, i, c)
        lits += chunk
    return bytes(lits), i


def decode_block(b, n):
    """One sylz block (v2 to v5) of n decoded bytes."""
    hdr = u32(b, 0)
    if hdr & 0x40000000:
        return decode_block4(b, n)
    ctrl_len = hdr & 0x7FFFFFFF
    if ctrl_len > len(b) - 4:
        raise SylzError("control length past the block")
    ctrl = b[4:4 + ctrl_len]
    i = 4 + ctrl_len
    if not hdr >> 31:
        return decode_sequences(ctrl, b[i:], n)   # format v2
    lits, i = decode_literal_section(b, i, n)
    if i != len(b):
        raise SylzError("the chunks do not take the rest of the block")
    return decode_sequences(ctrl, lits, n)


def main(argv):
    if len(argv) == 3 and argv[1] == "--check":
        d = argv[2]
        names = sorted(f[:-4] for f in os.listdir(d) if f.endswith(".blk"))
        bad = 0
        for name in names:
            base = name.rsplit(".", 1)[0]
            orig = open(os.path.join(d, base + ".orig"), "rb").read()
            blk = open(os.path.join(d, name + ".blk"), "rb").read()
            try:
                ok = decode_block(blk, len(orig)) == orig
            except SylzError as e:
                ok = False
                print("%s: %s" % (name, e))
            if not ok:
                bad += 1
                print("FAIL", name)
        print("%d vectors, %d failed" % (len(names), bad))
        return 1 if bad else 0
    if len(argv) != 4:
        print(__doc__)
        return 2
    blk = open(argv[1], "rb").read()
    out = decode_block(blk, int(argv[2]))
    open(argv[3], "wb").write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
