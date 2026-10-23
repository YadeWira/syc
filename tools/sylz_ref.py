#!/usr/bin/env python3
"""sylz_ref.py - a reference decoder for sylz blocks, formats v2 and v3.

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


def decode_block(b, n):
    """One sylz block (v2 or v3) of n decoded bytes."""
    hdr = u32(b, 0)
    ctrl_len = hdr & 0x7FFFFFFF
    if ctrl_len > len(b) - 4:
        raise SylzError("control length past the block")
    ctrl = b[4:4 + ctrl_len]
    i = 4 + ctrl_len
    if not hdr >> 31:
        return decode_sequences(ctrl, b[i:], n)   # format v2
    lit_count = u32(b, i)
    if lit_count == 0 or lit_count > n:
        raise SylzError("literal count out of range")
    i += 4
    lits = bytearray()
    while len(lits) < lit_count:
        c = min(LIT_CHUNK, lit_count - len(lits))
        chunk, i = decode_chunk(b, i, c)
        lits += chunk
    if i != len(b):
        raise SylzError("the chunks do not take the rest of the block")
    return decode_sequences(ctrl, bytes(lits), n)


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
