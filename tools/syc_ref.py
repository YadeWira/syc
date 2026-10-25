#!/usr/bin/env python3
"""syc_ref.py - a reference reader for syc's archive (.syc, formats 1-3)
and stream (.sylz, versions 1-5) formats.

Written from the wiki's "syc archive format", "syc stream format" and
"syc encryption" pages, for clarity, not speed: it reads the whole input
into memory and checks everything the pages require (every range, every
CRC-32 and tag, every fragment's BLAKE2s-256), raising SycError on
anything malformed. sylz blocks are decoded by sylz_ref.py, next to this
file; encrypted files through libsodium (PyNaCl: Argon2id, XChaCha20-
Poly1305) and hashlib (keyed BLAKE2s), or OpenSSL for Argon2id with more
than one lane.

    syc_ref.py [-pPASSWORD] t FILE                  check an archive or a stream
    syc_ref.py [-pPASSWORD] l ARCHIVE [VERSION]     list the state at VERSION
    syc_ref.py [-pPASSWORD] x ARCHIVE DIR [VERSION] extract files, directories, symlinks
    syc_ref.py [-pPASSWORD] d STREAM OUT            decode a stream
    syc_ref.py --check DIR                          check the test vectors in DIR

The password can also come from SYC_PASSWORD.
"""
import hashlib
import importlib.util
import json
import os
import struct
import subprocess
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


# ── encryption (wiki: syc encryption) ────────────────────────────────────

KEYREC_SIZE, SLOT_SIZE, SEAL = 216, 104, 40


def argon2id(pw, salt, t, m, p):
    """32 bytes; libsodium for one lane, OpenSSL for more"""
    if p == 1:
        from nacl import bindings
        return bindings.crypto_pwhash_alg(32, pw, salt, t, m * 1024,
                                          bindings.crypto_pwhash_ALG_ARGON2ID13)
    out = subprocess.run(['openssl', 'kdf', '-keylen', '32', '-kdfopt', 'hexpass:' + pw.hex(),
                          '-kdfopt', 'hexsalt:' + salt.hex(), '-kdfopt', 'iter:%d' % t,
                          '-kdfopt', 'memcost:%d' % m, '-kdfopt', 'lanes:%d' % p,
                          '-kdfopt', 'threads:1', 'ARGON2ID'],
                         capture_output=True, text=True, check=True).stdout
    return bytes.fromhex(out.strip().replace(':', ''))


def aead_open(key, nonce, ct_tag, aad, what):
    from nacl import bindings, exceptions
    try:
        return bindings.crypto_aead_xchacha20poly1305_ietf_decrypt(ct_tag, aad, nonce, key)
    except exceptions.CryptoError:
        raise SycError(what + ' does not authenticate')


class Keys:
    """the data key from a key record (after `prefix`, the header)"""
    def __init__(self, prefix, rec, password):
        need(len(rec) == KEYREC_SIZE and rec[:4] == b'SYCK', 'key record')
        need(rec[4] & ~1 == 0 and rec[5:8] == b'\0\0\0', 'key record flags')
        self.index_sealed = bool(rec[4] & 1)
        need(password is not None, 'encrypted: a password is needed')
        slots = []
        for i in range(2):
            sl = rec[8 + i * SLOT_SIZE:8 + (i + 1) * SLOT_SIZE]
            gen = u32(sl, 0)
            if gen == 0:
                need(sl == bytes(SLOT_SIZE), 'an empty slot is not zero')
                continue
            kdf, lanes, mem, passes = sl[4], sl[5], u32(sl, 8), u32(sl, 12)
            need(kdf == 1 and 1 <= lanes <= 16 and sl[6:8] == b'\0\0'
                 and 8 * lanes <= mem <= 4194304 and 1 <= passes <= 256, 'slot parameters')
            slots.append((gen, sl))
        need(slots, 'no slot')
        self.k = None
        for gen, sl in sorted(slots, key=lambda g: -g[0]):
            kek = argon2id(password, sl[16:32], u32(sl, 12), u32(sl, 8), sl[5])
            try:
                self.k = aead_open(kek, sl[32:56], sl[56:104], prefix + rec[:8] + sl[:16], 'slot')
                break
            except SycError:
                pass
        need(self.k is not None, 'wrong password, or a damaged key record')
        sub = lambda label: hashlib.blake2s(label, key=self.k).digest()
        self.aead, self.frag, self.cdc = sub(b'syc aead'), sub(b'syc fragment'), sub(b'syc cdc')


def open_sealed(b, i, key, aad_of, what):
    """an encrypted block (or index record without its magic) at i: (its
    plaintext payload, raw_len, packed, the offset after it)"""
    raw_len, packed, crc = u32(b, i), u32(b, i + 4), u32(b, i + 8)
    pay_len = packed & 0x7FFFFFFF
    need(1 <= raw_len <= MAX_BLOCK and crc == 0, what + ' header')
    need(i + 12 + SEAL + pay_len <= len(b), 'truncated ' + what)
    nonce = b[i + 12:i + 36]
    ct_tag = b[i + 36:i + 36 + pay_len + 16]
    payload = aead_open(key, nonce, ct_tag, aad_of(raw_len, packed), what)
    return payload, raw_len, packed, i + 12 + SEAL + pay_len


def unpack_payload(payload, raw_len, packed):
    if packed & 0x80000000:
        need(len(payload) == raw_len, 'stored block of the wrong size')
        return payload
    try:
        raw = sylz_ref.decode_block(payload, raw_len)
    except sylz_ref.SylzError as e:
        raise SycError('sylz block: %s' % e)
    need(len(raw) == raw_len, 'block decodes to the wrong size')
    return raw


# ── the stream ───────────────────────────────────────────────────────────

def read_stream(b, password=None):
    need(b[:4] == b'SYZ0' and len(b) >= 6, 'not a .sylz stream')
    version = b[4]
    need(1 <= version <= 5, 'stream version %d not known' % version)
    if version >= 4:
        need(len(b) >= 7, 'truncated')
        need(b[5] == CODEC_SYLZ, 'codec %d not known' % b[5])
        i = 7
    else:
        i = 6
    keys = None
    if version == 5:
        keys = Keys(b[:7], b[7:7 + KEYREC_SIZE], password)
        i = 7 + KEYREC_SIZE
    out = []
    while True:
        if u32(b, i) == 0:
            i += 4
            break
        if keys:
            k = len(out)
            payload, raw_len, packed, i = open_sealed(
                b, i, keys.aead,
                lambda rl, pk: b'SYZB' + struct.pack('<QII', k, rl, pk), 'block %d' % k)
            out.append(unpack_payload(payload, raw_len, packed))
        else:
            raw, i = decode_block(b, i)
            out.append(raw)
    if keys:
        # the end, sealed with the number of blocks
        need(i + SEAL <= len(b), 'truncated end')
        aead_open(keys.aead, b[i:i + 24], b[i + 24:i + 40], b'SYZE' + struct.pack('<Q', len(out)),
                  'the end')
        i += SEAL
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


def parse_index(b, first_frag, max_frag, extra=0):
    r = Reader(b)
    blocks = [(r.varint(), r.varint()) for _ in range(r.varint())]
    for nbytes, nfr in blocks:
        need(12 + extra <= nbytes <= 12 + extra + MAX_BLOCK and nfr >= 1, 'block entry out of range')
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


def find_versions(b, vhead_size, start=8, block_extra=0, index_extra=0):
    """[(vstart, istart, commit)] of the complete versions, by structure
    only (block lengths); and whether bytes follow the last one"""
    out, at = [], start
    while at < len(b):
        try:
            need(b[at:at + 4] == b'SYCV', 'no version head')
            p = at + vhead_size
            while u32(b, p) != 0:
                p += 12 + block_extra + (u32(b, p + 4) & 0x7FFFFFFF)
            p += 4
            need(b[p:p + 4] == b'SYCI', 'no index')
            q = p + 16 + index_extra + (u32(b, p + 8) & 0x7FFFFFFF)
            c = b[q:q + 24]
            need(len(c) == 24 and c[:4] == b'SYCE', 'no commit')
            need(crc32(c[:20]) == u32(c, 20), 'commit CRC-32')
            need(u64(c, 4) == at and u64(c, 12) == p, 'commit offsets')
        except SycError:
            return out, True
        out.append((at, p, q))
        at = q + 24
    return out, False


def read_archive(b, password=None):
    """every complete version, checked: (versions, damaged) where each
    version is (vnum, time, entries); fragment data is checked against
    its hash, files' sizes against their fragments"""
    need(b[:4] == b'SYCA' and len(b) >= 8, 'not a syc archive')
    fmt = b[4]
    need(fmt in (1, 2, 3), 'archive format %d not known' % fmt)
    mn, avg, mx = b[5], b[6], b[7]
    need(6 <= mn < avg < mx <= 24, 'fragment parameters')
    vhead_size = 16 if fmt == 1 else 20
    keys, start, bx, ix = None, 8, 0, 0
    if fmt == 3:
        keys = Keys(b[:8], b[8:8 + KEYREC_SIZE], password)
        start, bx = 8 + KEYREC_SIZE, SEAL
        ix = SEAL if keys.index_sealed else 0
    found, damaged = find_versions(b, vhead_size, start, bx, ix)
    frag_data = []          # [fragment number - 1] -> bytes
    versions = []
    for k, (vstart, istart, commit) in enumerate(found):
        vnum = k + 1
        need(u32(b, vstart + 4) == vnum, 'version number')
        time = i64(b, vstart + 8)
        if fmt >= 2:
            need(b[vstart + 16] == CODEC_SYLZ, 'codec %d not known' % b[vstart + 16])
            need(b[vstart + 17:vstart + 20] == b'\0\0\0', 'reserved bytes')
        if keys and keys.index_sealed:
            need(b[istart:istart + 4] == b'SYCI', 'bad record magic')
            payload, raw_len, packed, end = open_sealed(
                b, istart + 4, keys.aead,
                lambda rl, pk: b'SYCI' + struct.pack('<III', vnum, rl, pk), 'the index')
            index = unpack_payload(payload, raw_len, packed)
        else:
            index, end = decode_block(b, istart, b'SYCI')
        need(end == commit, 'the index does not end at the commit')
        if fmt == 3:
            need(time == 0 and len(index) >= 8, 'format 3: the time is in the index')
            time, index = struct.unpack_from('<q', index, 0)[0], index[8:]
        blocks, frags, entries = parse_index(index, len(frag_data) + 1, 1 << mx, bx)
        p, f = vstart + vhead_size, 0
        for kb, (nbytes, nfr) in enumerate(blocks):
            if keys:
                payload, raw_len, packed, after = open_sealed(
                    b, p, keys.aead,
                    lambda rl, pk: b'SYCB' + struct.pack('<IIII', vnum, kb, rl, pk),
                    'block %d of version %d' % (kb, vnum))
                raw = unpack_payload(payload, raw_len, packed)
            else:
                raw, after = decode_block(b, p)
            need(after - p == nbytes, 'block size differs from the index')
            off = 0
            for size, digest in frags[f:f + nfr]:
                piece = raw[off:off + size]
                need(len(piece) == size, 'fragments overrun their block')
                ident = (hashlib.blake2s(piece, key=keys.frag) if keys else hashlib.blake2s(piece)).digest()
                need(ident == digest, 'fragment hash mismatch')
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
        pw = want.get('password') if want else None
        pw = pw.encode() if pw is not None else None
        try:
            if name.endswith('.sylz'):
                out = read_stream(data, pw)
                ok = hashlib.sha256(out).hexdigest() == want['sha256'] and len(out) == want['size']
            else:
                versions, damaged, frags = read_archive(data, pw)
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
    pw = os.environ.get('SYC_PASSWORD')
    if len(argv) > 1 and argv[1].startswith('-p'):
        pw = argv[1][2:]
        argv = argv[:1] + argv[2:]
    pw = pw.encode() if pw else None
    if len(argv) >= 3:
        data = open(argv[2], 'rb').read()
        try:
            if argv[1] == 't':
                if data[:4] == b'SYZ0':
                    print('%s: ok, %d bytes' % (argv[2], len(read_stream(data, pw))))
                else:
                    versions, damaged, frags = read_archive(data, pw)
                    print('%s: ok, %d version(s)%s' % (argv[2], len(versions),
                          ', data after the last one' if damaged else ''))
                return 0
            if argv[1] == 'd' and len(argv) == 4:
                open(argv[3], 'wb').write(read_stream(data, pw))
                return 0
            versions, damaged, frags = read_archive(data, pw)
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
