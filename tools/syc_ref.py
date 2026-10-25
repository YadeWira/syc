#!/usr/bin/env python3
"""syc_ref.py - a reference reader for syc's archive (.syc, format 2, and
format 1) and stream (.sylz, version 4, and 1-3) formats.

Written from the wiki's "syc archive format" and "syc stream format"
pages, for clarity, not speed: it reads the whole input into memory and
checks everything the pages require (every range, every CRC-32, every
fragment's BLAKE2s-256), raising SycError on anything malformed. sylz
blocks are decoded by sylz_ref.py, next to this file.

    syc_ref.py t FILE                  check an archive or a stream
    syc_ref.py l ARCHIVE [VERSION]     list the state at VERSION (default: last)
    syc_ref.py x ARCHIVE DIR [VERSION] extract files, directories and symlinks
    syc_ref.py d STREAM OUT            decode a stream
    syc_ref.py --check DIR             check the test vectors in DIR
"""
import hashlib
import importlib.util
import json
import os
import struct
import sys
import zlib

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('sylz_ref', os.path.join(_here, 'sylz_ref.py'))
sylz_ref = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sylz_ref)

MAX_BLOCK = 1 << 29
CODEC_SYLZ = 1
DELETED, FILE, DIR, SYMLINK = 0, 1, 2, 3


class SycError(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise SycError(msg)


def u32(b, i):
    need(i + 4 <= len(b), 'truncated')
    return struct.unpack_from('<I', b, i)[0]


def u64(b, i):
    need(i + 8 <= len(b), 'truncated')
    return struct.unpack_from('<Q', b, i)[0]


def i64(b, i):
    need(i + 8 <= len(b), 'truncated')
    return struct.unpack_from('<q', b, i)[0]


def crc32(b):
    return zlib.crc32(b) & 0xFFFFFFFF


def decode_block(b, i, magic=b''):
    """a block (or the index record, with its magic) at i: (raw data, the
    offset after it)"""
    if magic:
        need(b[i:i + 4] == magic, 'bad record magic')
        i += 4
    raw_len, packed, crc = u32(b, i), u32(b, i + 4), u32(b, i + 8)
    i += 12
    pay_len = packed & 0x7FFFFFFF
    need(1 <= raw_len <= MAX_BLOCK, 'block size out of range')
    need(i + pay_len <= len(b), 'truncated block')
    payload = bytes(b[i:i + pay_len])
    if packed & 0x80000000:
        need(pay_len == raw_len, 'stored block of the wrong size')
        raw = payload
    else:
        try:
            raw = sylz_ref.decode_block(payload, raw_len)
        except sylz_ref.SylzError as e:
            raise SycError('sylz block: %s' % e)
    need(len(raw) == raw_len, 'block decodes to the wrong size')
    need(crc32(raw) == crc, 'block CRC-32 mismatch')
    return raw, i + pay_len


# ── the stream ───────────────────────────────────────────────────────────

def read_stream(b):
    need(b[:4] == b'SYZ0' and len(b) >= 6, 'not a .sylz stream')
    version = b[4]
    need(1 <= version <= 4, 'stream version %d not known' % version)
    if version == 4:
        need(len(b) >= 7, 'truncated')
        need(b[5] == CODEC_SYLZ, 'codec %d not known' % b[5])
        i = 7
    else:
        i = 6
    out = []
    while True:
        if u32(b, i) == 0:
            i += 4
            break
        raw, i = decode_block(b, i)
        out.append(raw)
    need(i == len(b), 'bytes after the end of the stream')
    return b''.join(out)


# ── the archive ──────────────────────────────────────────────────────────

class Reader:
    def __init__(self, b, at=0):
        self.b, self.at = b, at

    def byte(self):
        need(self.at < len(self.b), 'index truncated')
        self.at += 1
        return self.b[self.at - 1]

    def varint(self):
        v, shift = 0, 0
        while True:
            need(shift <= 63, 'varint too long')
            c = self.byte()
            v |= (c & 0x7F) << shift
            shift += 7
            if c < 0x80:
                break
        need(v < 1 << 64, 'varint out of range')
        return v

    def i64(self):
        v = i64(self.b, self.at)
        self.at += 8
        return v

    def raw(self, n):
        need(self.at + n <= len(self.b), 'index truncated')
        self.at += n
        return self.b[self.at - n:self.at]

    def text(self, lo, hi, what):
        n = self.varint()
        need(lo <= n <= hi, what + ' length out of range')
        return self.raw(n).decode('utf-8')


def valid_path(p):
    parts = p.split('/')
    return all(x not in ('', '.', '..') for x in parts) and '\0' not in p


def parse_index(b, first_frag, max_frag):
    r = Reader(b)
    blocks = [(r.varint(), r.varint()) for _ in range(r.varint())]
    for nbytes, nfr in blocks:
        need(12 <= nbytes <= 12 + MAX_BLOCK and nfr >= 1, 'block entry out of range')
    frags = []
    for _ in range(r.varint()):
        size = r.varint()
        need(1 <= size <= max_frag, 'fragment size out of range')
        frags.append((size, r.raw(32)))
    need(len(frags) == sum(n for _, n in blocks), 'fragment count')
    last = first_frag + len(frags) - 1
    entries = []
    for _ in range(r.varint()):
        path = r.text(1, 65535, 'path')
        need(valid_path(path), 'bad path')
        need(not entries or entries[-1]['path'].encode() < path.encode(), 'paths out of order')
        e = {'path': path, 'type': r.byte()}
        entries.append(e)
        if e['type'] == DELETED:
            continue
        need(e['type'] in (FILE, DIR, SYMLINK), 'entry type')
        e['mtime'] = r.i64()
        e['attrKind'] = r.byte()
        need(e['attrKind'] <= 2, 'attribute kind')
        e['attrs'] = r.varint()
        need(e['attrs'] < 1 << 32, 'attributes')
        if e['attrKind'] == 1:
            e['uid'], e['gid'] = r.varint(), r.varint()
            need(e['uid'] < 1 << 32 and e['gid'] < 1 << 32, 'uid/gid')
        if e['type'] == FILE:
            e['size'] = r.varint()
            n = r.varint()
            need((n == 0) == (e['size'] == 0), 'size and references')
            refs = []
            for k in range(n):
                v = r.varint()
                if k == 0:
                    ref = v
                else:
                    ref = refs[-1] + 1 + ((v >> 1) ^ -(v & 1))
                need(1 <= ref <= last, 'fragment reference out of range')
                refs.append(ref)
            e['refs'] = refs
        elif e['type'] == SYMLINK:
            e['target'] = r.text(0, 65535, 'symlink target')
    need(r.at == len(b), 'bytes after the entries')
    return blocks, frags, entries


def find_versions(b, vhead_size):
    """[(vstart, istart, commit)] of the complete versions, by structure
    only (block lengths); and whether bytes follow the last one"""
    out, at = [], 8
    while at < len(b):
        try:
            need(b[at:at + 4] == b'SYCV', 'no version head')
            p = at + vhead_size
            while u32(b, p) != 0:
                p += 12 + (u32(b, p + 4) & 0x7FFFFFFF)
            p += 4
            need(b[p:p + 4] == b'SYCI', 'no index')
            q = p + 16 + (u32(b, p + 8) & 0x7FFFFFFF)
            c = b[q:q + 24]
            need(len(c) == 24 and c[:4] == b'SYCE', 'no commit')
            need(crc32(c[:20]) == u32(c, 20), 'commit CRC-32')
            need(u64(c, 4) == at and u64(c, 12) == p, 'commit offsets')
        except SycError:
            return out, True
        out.append((at, p, q))
        at = q + 24
    return out, False


def read_archive(b):
    """every complete version, checked: (versions, damaged) where each
    version is (vnum, time, entries); fragment data is checked against
    its hash, files' sizes against their fragments"""
    need(b[:4] == b'SYCA' and len(b) >= 8, 'not a syc archive')
    fmt = b[4]
    need(fmt in (1, 2), 'archive format %d not known' % fmt)
    mn, avg, mx = b[5], b[6], b[7]
    need(6 <= mn < avg < mx <= 24, 'fragment parameters')
    vhead_size = 20 if fmt == 2 else 16
    found, damaged = find_versions(b, vhead_size)
    frag_data = []          # [fragment number - 1] -> bytes
    versions = []
    for k, (vstart, istart, commit) in enumerate(found):
        need(u32(b, vstart + 4) == k + 1, 'version number')
        time = i64(b, vstart + 8)
        if fmt == 2:
            need(b[vstart + 16] == CODEC_SYLZ, 'codec %d not known' % b[vstart + 16])
            need(b[vstart + 17:vstart + 20] == b'\0\0\0', 'reserved bytes')
        index, end = decode_block(b, istart, b'SYCI')
        need(end == commit, 'the index does not end at the commit')
        blocks, frags, entries = parse_index(index, len(frag_data) + 1, 1 << mx)
        p, f = vstart + vhead_size, 0
        for nbytes, nfr in blocks:
            raw, after = decode_block(b, p)
            need(after - p == nbytes, 'block size differs from the index')
            off = 0
            for size, digest in frags[f:f + nfr]:
                piece = raw[off:off + size]
                need(len(piece) == size, 'fragments overrun their block')
                need(hashlib.blake2s(piece).digest() == digest, 'fragment hash mismatch')
                frag_data.append(piece)
                off += size
            need(off == len(raw), 'block longer than its fragments')
            f += nfr
            p = after
        need(u32(b, p) == 0 and p + 4 == istart, 'the blocks do not lead to the index')
        for e in entries:
            if e['type'] == FILE:
                need(sum(len(frag_data[r - 1]) for r in e['refs']) == e['size'],
                     e['path'] + ': size does not match its fragments')
        versions.append((k + 1, time, entries))
    return versions, damaged, frag_data


def state_at(versions, n):
    state = {}
    for _, _, entries in versions[:n]:
        for e in entries:
            if e['type'] == DELETED:
                state.pop(e['path'], None)
            else:
                state[e['path']] = e
    return [state[p] for p in sorted(state, key=lambda s: s.encode())]


def describe(e, frag_data):
    d = {'path': e['path'], 'type': ['deleted', 'file', 'dir', 'symlink'][e['type']],
         'mtime': e['mtime'], 'attrKind': e['attrKind'], 'attrs': e['attrs']}
    if e['attrKind'] == 1:
        d['uid'], d['gid'] = e['uid'], e['gid']
    if e['type'] == FILE:
        d['size'] = e['size']
        h = hashlib.sha256()
        for r in e['refs']:
            h.update(frag_data[r - 1])
        d['sha256'] = h.hexdigest()
    if e['type'] == SYMLINK:
        d['target'] = e['target']
    return d


def extract(versions, frag_data, n, out):
    links = []
    for e in state_at(versions, n):
        dest = os.path.join(out, *e['path'].split('/'))
        if e['type'] == DIR:
            os.makedirs(dest, exist_ok=True)
        elif e['type'] == FILE:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, 'wb') as f:
                for r in e['refs']:
                    f.write(frag_data[r - 1])
            os.utime(dest, ns=(e['mtime'], e['mtime']))
        else:
            links.append((e, dest))
    for e, dest in links:      # after every file: nothing written through them
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        os.symlink(e['target'], dest)


# ── test vectors ─────────────────────────────────────────────────────────

def check_vectors(d):
    bad = total = 0
    for name in sorted(os.listdir(d)):
        path = os.path.join(d, name)
        if name.endswith('.json'):
            continue
        total += 1
        want_file = path + '.json'
        want = json.load(open(want_file)) if os.path.exists(want_file) else None
        data = open(path, 'rb').read()
        try:
            if name.endswith('.sylz'):
                out = read_stream(data)
                ok = hashlib.sha256(out).hexdigest() == want['sha256'] and len(out) == want['size']
            else:
                versions, damaged, frags = read_archive(data)
                got = [[describe(e, frags) for e in state_at(versions, n)]
                       for n in range(1, len(versions) + 1)]
                ok = got == want['versions'] and damaged == want['damaged']
            if want.get('corrupt'):
                ok = False
        except SycError as e:
            ok = bool(want and want.get('corrupt'))
            if not ok:
                print('%s: %s' % (name, e))
        if not ok:
            print('FAIL: %s' % name)
            bad += 1
    print('%d of %d vectors ok' % (total - bad, total))
    return bad == 0


def main(argv):
    if len(argv) == 3 and argv[1] == '--check':
        return 0 if check_vectors(argv[2]) else 1
    if len(argv) >= 3:
        data = open(argv[2], 'rb').read()
        try:
            if argv[1] == 't':
                if data[:4] == b'SYZ0':
                    print('%s: ok, %d bytes' % (argv[2], len(read_stream(data))))
                else:
                    versions, damaged, frags = read_archive(data)
                    print('%s: ok, %d version(s)%s' % (argv[2], len(versions),
                          ', data after the last one' if damaged else ''))
                return 0
            if argv[1] == 'd' and len(argv) == 4:
                open(argv[3], 'wb').write(read_stream(data))
                return 0
            versions, damaged, frags = read_archive(data)
            if argv[1] == 'l':
                n = int(argv[3]) if len(argv) > 3 else len(versions)
                for e in state_at(versions, n):
                    print(json.dumps(describe(e, frags), ensure_ascii=False))
                return 0
            if argv[1] == 'x' and len(argv) >= 4:
                n = int(argv[4]) if len(argv) > 4 else len(versions)
                extract(versions, frags, n, argv[3])
                return 0
        except SycError as e:
            print('%s: %s' % (argv[2], e), file=sys.stderr)
            return 3
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
