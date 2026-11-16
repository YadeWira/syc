#!/usr/bin/env python3
"""fuzzarc.py - long fuzzing of whole .syc archives and .sylz streams.

Builds seed files of every format (archives of three versions: plain,
-ec, -F 2, multi-block, encrypted, --visible-names; streams likewise;
plus what released versions wrote, tests/compat/), damages copies of
them and runs syc t, l, i and x (streams: t, i, d) on each, with a
time and a memory limit. A finding is:

- a crash: a signal, a runtime error (range check, overflow, access
  violation...) or exit 4 (syc's catch-all), a hang (timeout), an exit
  other than 0, 1, 3;
- a wrong answer: x (or d) exits 0 with what is not one of the seed's
  versions (the stream's data); t passes and x does not;
- an escape: x writes outside its -o directory;
- with --ref: syc and the reference reader (tools/syc_ref.py) disagree
  on whether the file is sound, or on what its last version holds.

Mutations: bit flips, bytes and u32s set to edge values, truncation,
cut, insert, duplicated range, splice of two seeds; and through the
format: the index of a version re-emitted with a valid CRC-32 (or
sealed again with the key, when encrypted) after damaging its bytes or
its fields (paths with .., absolute paths, symlinks then files under
them, counts in the billions, references out of range...), and a
block's payload damaged with its CRC-32 (or seal) made valid again.

    fuzzarc.py SYC WORKDIR [--chk SYC2] [--vg SYC3 [--vg-rate R]]
                           [--jobs N] [--minutes M] [--seed S] [--ref RATE]

SYC2 (a build with -Cr -Co: range and overflow checks) runs every
other case; SYC3 (built with -Facmem: the C heap, which valgrind sees)
runs under valgrind on a share R of them (default 0.05). --ref RATE:
the reference reader on that share of the cases (all the index ones). Findings go to WORKDIR/findings/ (the file and a .json with
the command lines, exits and stderr), one per kind and message;
WORKDIR/fuzz.log has a line a minute. Linux (resource limits, symlinks).
"""
import argparse
import hashlib
import json
import multiprocessing as mp
import os
import random
import re
import resource
import shutil
import stat
import struct
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import syc_ref  # noqa: E402

PW = 'fuzz'
CRASH = re.compile(r'range check|overflow|access violation|invalid pointer|runtime error|'
                   r'stack|heap|internal error|division by zero|invalid operation|'
                   r'out of memory|EInOutError|Exception', re.I)
TIMEOUT = 30
MEM_LIMIT = 3 << 30
KDF_MAX = 64            # MiB: syc --kdf-mem-max, and what the reference will compute


# ── seeds ────────────────────────────────────────────────────────────────

def write(path, data, mtime=1767341045):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    os.utime(path, (mtime, mtime))


def make_trees(base):
    """v1, v2, v3: text, random, repeats, empty, a symlink, a subdir"""
    r = random.Random(2026)
    words = ('versions fragments blocks deduplicated modest hardware sylz archive '
             'the of and to each every once').split()
    text = ' '.join(r.choice(words) for _ in range(9000)).encode()
    rnd = bytes(r.getrandbits(8) for _ in range(6000))
    t = os.path.join(base, 'v1', 'tree')
    write(t + '/text.txt', text)
    write(t + '/random.bin', rnd)
    write(t + '/sub/again.txt', text[:9000] + rnd[:700])
    write(t + '/sub/deep/x.txt', b'x' * 3000 + text[:2000])
    write(t + '/empty', b'')
    os.symlink('text.txt', t + '/link')
    os.symlink('sub/deep', t + '/dlink')
    shutil.copytree(base + '/v1', base + '/v2', symlinks=True)
    t2 = os.path.join(base, 'v2', 'tree')
    write(t2 + '/text.txt', text[:4000] + b'changed in v2' + text[4000:])
    os.remove(t2 + '/random.bin')
    write(t2 + '/sub/new.txt', b'added in version 2\n' * 40)
    shutil.copytree(base + '/v2', base + '/v3', symlinks=True)
    t3 = os.path.join(base, 'v3', 'tree')
    shutil.rmtree(t3 + '/sub/deep')
    write(t3 + '/sub/new.txt', rnd[:3000] + text[:3000])
    write(t3 + '/z.bin', bytes(r.getrandbits(8) for _ in range(2000)) * 3)
    # a bigger tree, for several blocks with -b 1
    big = os.path.join(base, 'big1', 'tree')
    blob = bytes(r.getrandbits(8) for _ in range(700000))
    write(big + '/a.bin', blob)
    write(big + '/b.txt', text * 30)
    shutil.copytree(base + '/big1', base + '/big2', symlinks=True)
    write(base + '/big2/tree/a.bin', blob[:300000] + b'v2' + blob[300000:])
    for v in ('v1', 'v2', 'v3', 'big1', 'big2'):
        for root, dirs, files in os.walk(os.path.join(base, v)):
            for n in dirs:
                os.utime(os.path.join(root, n), (1767341045, 1767341045))
    write(base + '/stream.bin', text + rnd + text[:20000])
    write(base + '/streambig.bin', blob + text * 10)


def rmtree(d):
    """chmod and rm: paths past PATH_MAX, modes of 0 (an index can give both)"""
    if os.path.lexists(d):
        subprocess.run(['chmod', '-R', 'u+rwx', d], stderr=subprocess.DEVNULL)
        subprocess.run(['rm', '-rf', d], stderr=subprocess.DEVNULL)


def state(d):
    """path -> 'sha mtime' | 'dir' | 'link:target', with every parent dir
    (through directory descriptors: paths can pass PATH_MAX)"""
    subprocess.run(['chmod', '-R', 'u+rwx', d], stderr=subprocess.DEVNULL)
    out = {}
    for root, dirs, names, rfd in os.fwalk(d):
        rel0 = os.path.relpath(root, d).replace(os.sep, '/')
        for n in dirs + names:
            rel = n if rel0 == '.' else rel0 + '/' + n
            st = os.stat(n, dir_fd=rfd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                out[rel] = 'link:' + os.readlink(n, dir_fd=rfd)
            elif stat.S_ISDIR(st.st_mode):
                out[rel + '/'] = 'dir'
            else:
                fd = os.open(n, os.O_RDONLY, dir_fd=rfd)
                with os.fdopen(fd, 'rb') as f:
                    out[rel] = '%s %d' % (hashlib.sha256(f.read()).hexdigest(), int(st.st_mtime))
    return out


def with_parents(s):
    s = dict(s)
    for p in list(s):
        parts = p.rstrip('/').split('/')
        for k in range(1, len(parts)):
            s.setdefault('/'.join(parts[:k]) + '/', 'dir')
    return s


def make_seeds(syc, work):
    """[(name, kind, password, expected)]: expected is a list of states
    (archives) or the stream's data"""
    sd = os.path.join(work, 'seeds')
    if os.path.isdir(sd):
        with open(os.path.join(sd, 'seeds.json')) as f:
            return json.load(f)
    tmp = os.path.join(work, 'seedsrc')
    shutil.rmtree(tmp, ignore_errors=True)
    make_trees(tmp)
    os.makedirs(sd + '.tmp', exist_ok=True)
    seeds = []
    pwo = ['-p' + PW, '--kdf-mem', '8']
    archives = [
        ('p', [], ['v1', 'v2', 'v3']),
        ('ec9', ['-ec', '-9'], ['v1', 'v2', 'v3']),
        ('f2', ['-F', '2', '-4'], ['v1', 'v2', 'v3']),
        ('f2ec', ['-F', '2', '-ec'], ['v1', 'v2', 'v3']),
        ('big', ['-b', '1', '-3'], ['big1', 'big2']),
        ('enc', pwo, ['v1', 'v2', 'v3']),
        ('encv', pwo + ['--visible-names'], ['v1', 'v2', 'v3']),
        ('encbig', pwo + ['-b', '1', '-ec'], ['big1', 'big2']),
    ]
    for name, opts, vers in archives:
        path = os.path.join(sd + '.tmp', name + '.syc')
        exp = []
        for i, v in enumerate(vers):
            # the same stored path in every version: v1/tree -> tree; what
            # only creating takes, only then
            o = opts if i == 0 else [x for x in opts if x not in ('--visible-names', '--kdf-mem', '8')]
            subprocess.run([syc, 'a', '-q'] + o + [path, '-C', os.path.join(tmp, v), 'tree'],
                           check=True)
            exp.append(state(os.path.join(tmp, v)))
        seeds.append((name + '.syc', 'arc', PW if '-p' + PW in opts else None, exp))
    streams = [('s', [], 'stream.bin'), ('sec', ['-ec', '-10'], 'stream.bin'),
               ('sf2', ['-F', '2'], 'stream.bin'), ('sf2ec', ['-F', '2', '-ec'], 'stream.bin'),
               ('sbig', ['-b', '1', '-2'], 'streambig.bin'), ('senc', pwo, 'stream.bin'),
               ('sencbig', pwo + ['-b', '1'], 'streambig.bin')]
    for name, opts, src in streams:
        path = os.path.join(sd + '.tmp', name + '.sylz')
        subprocess.run([syc, 'c', '-q'] + opts + ['-o', path, os.path.join(tmp, src)], check=True)
        with open(os.path.join(tmp, src), 'rb') as f:
            seeds.append((name + '.sylz', 'stream', PW if opts[:1] == pwo[:1] else None,
                          hashlib.sha256(f.read()).hexdigest()))
    cdir = os.path.join(HERE, 'compat')
    with open(os.path.join(cdir, 'MANIFEST.json')) as f:
        m = json.load(f)
    for n in sorted(os.listdir(cdir)):
        if n.endswith('.syc') or n.endswith('.sylz'):
            shutil.copy(os.path.join(cdir, n), os.path.join(sd + '.tmp', 'compat-' + n))
            pw = m['password'] if '-enc' in n else None
            if n.endswith('.syc'):
                exp = [{('tree/' + k[5:] if k.startswith('tree/') else k): v
                        for k, v in ver.items()} for ver in m['versions']]
                seeds.append(('compat-' + n, 'arc', pw, exp))
            else:
                seeds.append(('compat-' + n, 'stream', pw, m['stream']))
    seeds = [(n, k, pw, [with_parents(s) for s in e] if k == 'arc' else e)
             for n, k, pw, e in seeds]
    with open(os.path.join(sd + '.tmp', 'seeds.json'), 'w') as f:
        json.dump(seeds, f)
    os.rename(sd + '.tmp', sd)
    shutil.rmtree(tmp)
    return seeds


# ── format helpers (the index, re-emitted) ───────────────────────────────

def varint(v):
    out = bytearray()
    v &= (1 << 64) - 1
    while True:
        c = v & 0x7F
        v >>= 7
        if v:
            out.append(c | 0x80)
        else:
            out.append(c)
            return bytes(out)


def serialize_index(blocks, frags, entries, counts=None):
    counts = counts or {}
    o = bytearray(varint(counts.get('blocks', len(blocks))))
    for nb, nf in blocks:
        o += varint(nb) + varint(nf)
    o += varint(counts.get('frags', len(frags)))
    for size, h in frags:
        o += varint(size) + h
    o += varint(counts.get('entries', len(entries)))
    for e in entries:
        p = e['path'] if isinstance(e['path'], bytes) else e['path'].encode('utf-8', 'surrogateescape')
        o += varint(e.get('plen', len(p))) + p + bytes([e['type'] & 0xFF])
        if e['type'] == syc_ref.DELETED:
            continue
        o += struct.pack('<q', e.get('mtime', 0))
        o.append(e.get('attrKind', 0) & 0xFF)
        o += varint(e.get('attrs', 0o644))
        if e.get('attrKind') == 1:
            o += varint(e.get('uid', 0)) + varint(e.get('gid', 0))
        if e['type'] == syc_ref.FILE:
            refs = e.get('refs', [])
            o += varint(e.get('size', 0)) + varint(e.get('nrefs', len(refs)))
            prev = None
            for r in refs:
                if prev is None:
                    o += varint(r)
                else:
                    d = r - prev - 1
                    o += varint(2 * d if d >= 0 else -2 * d - 1)
                prev = r
        elif e['type'] == syc_ref.SYMLINK:
            t = e.get('target', '')
            t = t if isinstance(t, bytes) else t.encode('utf-8', 'surrogateescape')
            o += varint(len(t)) + t
    return bytes(o)


class Layout:
    """where the versions of an archive are, and its keys"""
    def __init__(self, b, password):
        self.b = b
        self.fmt = b[4]
        self.vhead = 16 if self.fmt == 1 else 20
        self.keys, self.start, self.bx, self.ix = None, 8, 0, 0
        if self.fmt >= 3:
            ver = self.fmt - 2
            self.keys = syc_ref.Keys(b[:8], b[8:8 + syc_ref.KEYREC_SIZE[ver]], password, ver)
            self.start, self.bx = 8 + syc_ref.KEYREC_SIZE[ver], syc_ref.SEAL
            self.ix = syc_ref.SEAL if self.keys.index_sealed or self.fmt == 4 else 0
        self.versions, _ = syc_ref.find_versions(b, self.vhead, self.start, self.bx, self.ix)

    def prev_tag(self, k):
        """fmt 4: the tag of version k-1's index (k 0-based)"""
        if k == 0:
            return bytes(16)
        _, _, commit = self.versions[k - 1]
        return self.b[commit - 16:commit]

    def read_index(self, k):
        """(raw index, raw_len, packed) of version k"""
        b = self.b
        vstart, istart, commit = self.versions[k]
        if self.fmt == 4:
            raw_len, packed, crc = struct.unpack_from('<III', b, istart + 4)
            pay_len = packed & 0x7FFFFFFF
            nonce = b[istart + 16:istart + 40]
            pay = b[istart + 40:istart + 40 + pay_len]
            tag = b[istart + 40 + pay_len:istart + 56 + pay_len]
            if self.keys.index_sealed:
                aad = b'SYCI' + b[vstart:vstart + 20] + self.prev_tag(k) + struct.pack('<II', raw_len, packed)
                pay = syc_ref.aead_open(self.keys.aead, nonce, pay + tag, aad, 'index')
            return syc_ref.unpack_payload(pay, raw_len, packed)
        if self.keys and self.keys.index_sealed:
            payload, raw_len, packed, _ = syc_ref.open_sealed(
                b, istart + 4, self.keys.aead,
                lambda rl, pk: b'SYCI' + struct.pack('<III', k + 1, rl, pk), 'index')
            return syc_ref.unpack_payload(payload, raw_len, packed)
        return syc_ref.decode_block(b, istart, b'SYCI')[0]

    def emit_index(self, k, raw, nonce):
        """the archive up to version k's commit, with its index record
        made from raw (stored, valid CRC-32 or seal)"""
        from nacl import bindings
        b = self.b
        vstart, istart, commit = self.versions[k]
        rl, pk = len(raw), len(raw) | 0x80000000
        if self.fmt == 4:
            aad = b'SYCI' + b[vstart:vstart + 20] + self.prev_tag(k) + struct.pack('<II', rl, pk)
            if self.keys.index_sealed:
                ct = bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(raw, aad, nonce, self.keys.aead)
                rec = b'SYCI' + struct.pack('<III', rl, pk, 0) + nonce + ct
            else:
                tag = bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(b'', aad + raw, nonce,
                                                                          self.keys.aead)
                rec = b'SYCI' + struct.pack('<III', rl, pk, zlib.crc32(raw)) + nonce + raw + tag
        elif self.keys and self.keys.index_sealed:
            aad = b'SYCI' + struct.pack('<III', k + 1, rl, pk)
            ct = bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(raw, aad, nonce, self.keys.aead)
            rec = b'SYCI' + struct.pack('<III', rl, pk, 0) + nonce + ct
        else:
            rec = b'SYCI' + struct.pack('<III', rl, pk, zlib.crc32(raw)) + raw
        return b[:istart] + rec + b[commit:commit + 24]

    def blocks(self, k):
        """[(offset, header and payload end)] of version k's blocks"""
        b = self.b
        vstart, istart, _ = self.versions[k]
        p, out = vstart + self.vhead, []
        while struct.unpack_from('<I', b, p)[0] != 0:
            end = p + 12 + self.bx + (struct.unpack_from('<I', b, p + 4)[0] & 0x7FFFFFFF)
            out.append((p, end))
            p = end
        return out


# ── mutations ────────────────────────────────────────────────────────────

EDGE32 = [0, 1, 2, 3, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000,
          0x80000001, 0xFFFFFFFE, 0xFFFFFFFF, 1 << 29, (1 << 29) + 1]
EDGE64 = [0, 1, 0x7F, 0x80, 1 << 31, 1 << 32, 1 << 40, 1 << 62, (1 << 63) - 1, 1 << 63, (1 << 64) - 1]


def m_flip(r, b, ctx):
    b = bytearray(b)
    for _ in range(r.choice([1, 1, 1, 2, 3, 8])):
        b[r.randrange(len(b))] ^= 1 << r.randrange(8)
    return bytes(b)


def m_bytes(r, b, ctx):
    b = bytearray(b)
    for _ in range(r.randint(1, 3)):
        b[r.randrange(len(b))] = r.choice([0, 1, 0x7F, 0x80, 0xFF, r.randrange(256)])
    return bytes(b)


def m_u32(r, b, ctx):
    b = bytearray(b)
    i = r.randrange(max(1, len(b) - 3))
    old = struct.unpack_from('<I', b, i)[0] if i + 4 <= len(b) else 0
    v = r.choice(EDGE32 + [len(b), len(b) - i, old + 1, old - 1, old * 2, old >> 1,
                           r.randrange(1 << 32)]) & 0xFFFFFFFF
    struct.pack_into('<I', b, i, v)
    return bytes(b)


def m_head(r, b, ctx):
    """the first 300 bytes: header, key record, the first version head"""
    b = bytearray(b)
    for _ in range(r.randint(1, 2)):
        b[r.randrange(min(len(b), 300))] ^= 1 << r.randrange(8)
    return bytes(b)


def m_truncate(r, b, ctx):
    return b[:r.randrange(len(b))]


def m_cut(r, b, ctx):
    i = r.randrange(len(b))
    return b[:i] + b[i + r.randint(1, 64):]


def m_insert(r, b, ctx):
    i = r.randrange(len(b) + 1)
    return b[:i] + bytes(r.getrandbits(8) for _ in range(r.randint(1, 64))) + b[i:]


def m_dup(r, b, ctx):
    i = r.randrange(len(b))
    n = r.randint(1, 4096)
    j = r.randrange(len(b) + 1)
    return b[:j] + b[i:i + n] + b[j:]


def m_splice(r, b, ctx):
    other = ctx['other'](r)
    return b[:r.randrange(len(b) + 1)] + other[r.randrange(len(other) + 1):]


def m_append(r, b, ctx):
    """a version again at the end (its offsets now wrong), or garbage"""
    if r.random() < 0.5:
        return b + b[r.randrange(len(b)):]
    return b + bytes(r.getrandbits(8) for _ in range(r.randint(1, 100)))


BYTE_MUTATORS = [m_flip, m_flip, m_bytes, m_u32, m_u32, m_head, m_truncate, m_cut, m_insert,
                 m_dup, m_splice, m_append]

EVIL_PATHS = ['..', '../x', 'a/../../x', 'tree/../../x', '/abs', '//x', 'a//b', '.', './a',
              'a/.', '', 'a/', 'x\\..\\..\\y', 'C:\\x', 'a\x00b', 'nul', 'CON.txt', 'a\nb',
              'é' * 200, 'x' * 70000, 'a/' * 3000 + 'b']


def idx_semantic(r, raw, ctx, lay, k):
    """damage the parsed index of version k, re-serialize"""
    pre = b''
    if lay.fmt >= 3:
        pre, raw = raw[:8], raw[8:]
    first = 1
    for praw in ctx['prev_raw']:
        first += len(syc_ref.parse_index(praw, first, 1 << 30, lay.bx)[1])
    blocks, frags, entries = syc_ref.parse_index(raw, first, 1 << 30, lay.bx)
    blocks, frags = list(blocks), list(frags)
    entries = [dict(e) for e in entries]
    files = [e for e in entries if e['type'] == syc_ref.FILE]
    last = first + len(frags) - 1
    counts = {}
    what = r.randrange(16)
    escape = ctx['escape']
    if what == 0 and entries:              # a hostile path
        e = r.choice(entries)
        e['path'] = r.choice(EVIL_PATHS + [escape + '/abs'])
    elif what == 1:                        # a symlink out, then a file under it
        tgt = r.choice(['..', '../..', '../../..', escape, '/', '.'])
        ref = files[0]['refs'][:1] if files and files[0].get('refs') else []
        size = frags[ref[0] - first][0] if ref and ref[0] >= first else 0
        name = r.choice(['tree/aaa', 'aaa', 'tree/link', 'tree/dlink'])
        entries = [e for e in entries if e['path'] != name]
        entries.append({'path': name, 'type': syc_ref.SYMLINK, 'mtime': 0, 'attrKind': 0,
                        'attrs': 0o777, 'target': tgt})
        entries.append({'path': name + '/pwned', 'type': syc_ref.FILE, 'mtime': 0,
                        'attrKind': 0, 'attrs': 0o644, 'size': size if ref else 0,
                        'refs': ref if size else []})
        if r.random() < 0.7:
            entries.sort(key=lambda e: e['path'].encode())
    elif what == 2:                        # a count in the billions
        counts[r.choice(['blocks', 'frags', 'entries'])] = r.choice(EDGE64 + [len(entries) + 1])
    elif what == 3 and files:              # a file's reference count
        e = r.choice(files)
        e['nrefs'] = r.choice(EDGE64 + [len(e.get('refs', [])) + 1])
    elif what == 4 and files:              # references out of range
        e = r.choice(files)
        if e.get('refs'):
            i = r.randrange(len(e['refs']))
            e['refs'][i] = r.choice([0, last + 1, first - 1, last, 1 << 40, (1 << 63) - 1,
                                     e['refs'][i] + r.randint(-3, 3)])
    elif what == 5 and files:              # sizes
        e = r.choice(files)
        e['size'] = r.choice(EDGE64 + [e['size'] + 1, max(0, e['size'] - 1)])
    elif what == 6 and frags:
        i = r.randrange(len(frags))
        frags[i] = (r.choice(EDGE64 + [frags[i][0] + 1, frags[i][0] - 1]), frags[i][1])
    elif what == 7 and blocks:
        i = r.randrange(len(blocks))
        nb, nf = blocks[i]
        blocks[i] = r.choice([(nb + 1, nf), (nb - 1, nf), (nb, nf + 1), (nb, max(0, nf - 1)),
                              (r.choice(EDGE64), nf), (nb, r.choice(EDGE64))])
    elif what == 8 and entries:            # type, attributes, owner
        e = r.choice(entries)
        f = r.choice(['type', 'attrKind', 'attrs', 'uid', 'mtime'])
        if f == 'type':
            e['type'] = r.choice([0, 1, 2, 3, 4, 255])
            e.setdefault('size', 0)
        elif f == 'attrKind':
            e['attrKind'] = r.choice([0, 1, 2, 3, 255])
        elif f == 'attrs':
            e['attrs'] = r.choice(EDGE64 + [0o4777, 0o7777, 0, 0o170000])
        elif f == 'uid':
            e['attrKind'] = 1
            e['uid'], e['gid'] = r.choice(EDGE64), r.choice(EDGE64)
        else:
            e['mtime'] = r.choice([-(1 << 63), (1 << 63) - 1, -1, 0, 1 << 62, -(10 ** 18)])
    elif what == 9 and len(entries) > 1:   # order: swapped, duplicated
        i = r.randrange(len(entries) - 1)
        if r.random() < 0.5:
            entries[i], entries[i + 1] = entries[i + 1], entries[i]
        else:
            entries.insert(i, dict(entries[i]))
    elif what == 10 and entries:           # a path's length varint
        e = r.choice(entries)
        e['plen'] = r.choice(EDGE64 + [0, 65535, 65536])
    elif what == 11:                       # a directory and a file of the same name
        if files:
            e = dict(r.choice(files))
            e['path'] = e['path'] + '/inside'
            entries.append(e)
            entries.sort(key=lambda e: e['path'].encode())
    elif what == 12 and files:             # a deleted entry for what exists / does not
        entries.append({'path': r.choice(['zzz', files[0]['path'], 'tree']), 'type': 0})
        entries.sort(key=lambda e: e['path'].encode())
    elif what == 13 and files:             # two files sharing fragments, refs repeated
        e = r.choice(files)
        if e.get('refs'):
            e['refs'] = e['refs'] + e['refs'][:1]
    elif what == 14 and entries:           # a symlink target
        links = [e for e in entries if e['type'] == syc_ref.SYMLINK]
        if links:
            r.choice(links)['target'] = r.choice(['', '/', '..', escape, 'x' * 70000, '\x00'])
    else:                                  # nothing left: a raw byte of it
        return pre + m_flip(r, raw, ctx), 'idx-raw'
    return pre + serialize_index(blocks, frags, entries, counts), 'idx-sem-%d' % what


def m_index(r, b, ctx):
    """version k's index, damaged and re-emitted valid; the archive cut
    after it (later versions would point at moved offsets)"""
    lay = ctx['layout']
    if not lay or not lay.versions:
        return m_flip(r, b, ctx), 'flip'
    k = r.randrange(len(lay.versions))
    if lay.fmt == 4:
        k = len(lay.versions) - 1 if r.random() < 0.7 else k   # the chain of tags
    raw = lay.read_index(k)
    ctx['prev_raw'] = [lay.read_index(j)[8 if lay.fmt >= 3 else 0:] for j in range(k)]
    if r.random() < 0.3:
        new, tag = m_flip(r, raw, ctx) if r.random() < 0.5 else (
            m_cut(r, raw, ctx) if r.random() < 0.5 else m_insert(r, raw, ctx)), 'idx-raw'
    else:
        try:
            new, tag = idx_semantic(r, raw, ctx, lay, k)
        except syc_ref.SycError:
            new, tag = m_flip(r, raw, ctx), 'idx-raw'
    nonce = bytes(r.getrandbits(8) for _ in range(24))
    return lay.emit_index(k, new, nonce), tag


def m_block(r, b, ctx):
    """a block's payload damaged, its CRC-32 (seal) made valid again: the
    fragment hashes must catch it"""
    from nacl import bindings
    lay = ctx['layout']
    if not lay or not lay.versions:
        return m_flip(r, b, ctx), 'flip'
    k = r.randrange(len(lay.versions))
    bl = lay.blocks(k)
    if not bl:
        return m_flip(r, b, ctx), 'flip'
    kb = r.randrange(len(bl))
    p, end = bl[kb]
    vstart = lay.versions[k][0]
    raw_len, packed, crc = struct.unpack_from('<III', b, p)
    if lay.keys:
        if lay.fmt != 4:
            return m_flip(r, b, ctx), 'flip'
        vhead = b[vstart:vstart + 20]
        aad = b'SYCB' + vhead + struct.pack('<III', kb, raw_len, packed)
        nonce = b[p + 12:p + 36]
        pay = syc_ref.aead_open(lay.keys.aead, nonce, b[p + 36:end + 0], aad, 'block')
    else:
        pay = b[p + 12:end]
    for _ in range(20):
        new = bytearray(pay)
        for _ in range(r.randint(1, 3)):
            new[r.randrange(len(new))] ^= 1 << r.randrange(8)
        new = bytes(new)
        try:
            raw = syc_ref.unpack_payload(new, raw_len, packed)
        except syc_ref.SycError:
            continue
        if len(raw) != raw_len:
            continue
        if lay.keys:
            ct = bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(new, aad, nonce, lay.keys.aead)
            return b[:p + 36] + ct + b[end:], 'block-sealed'
        return b[:p + 8] + struct.pack('<I', zlib.crc32(raw)) + new + b[end:], 'block-crc'
    return m_flip(r, b, ctx), 'flip'


# ── running syc ──────────────────────────────────────────────────────────

def limits():
    resource.setrlimit(resource.RLIMIT_AS, (MEM_LIMIT, MEM_LIMIT))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (256 << 20, 256 << 20))


def run(cmd, cwd, timeout=TIMEOUT):
    t = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout, preexec_fn=limits,
                           env=dict(os.environ, NO_COLOR='1'))
        return p.returncode, p.stdout, p.stderr.decode('utf-8', 'replace'), time.time() - t
    except subprocess.TimeoutExpired:
        return 'timeout', b'', '', timeout


def same_state(got, ref):
    if set(got) != set(ref):
        return False
    for k, v in ref.items():
        if v.endswith(' *'):
            if got[k].split(' ')[0] != v.split(' ')[0]:
                return False
        elif got[k] != v:
            return False
    return True


def ref_verdict(kind, b, pw):
    """(sound, state of the last version or the stream's sha256)"""
    try:
        if kind == 'stream':
            return True, hashlib.sha256(syc_ref.read_stream(b, pw)).hexdigest()
        versions, damaged, frag_data = syc_ref.read_archive(b, pw)
        if damaged or not versions:
            return False, None
        st = {}
        for e in syc_ref.state_at(versions, len(versions)):
            p = e['path']
            if e['type'] == syc_ref.DIR:
                st[p + '/'] = 'dir'
            elif e['type'] == syc_ref.SYMLINK:
                st[p] = 'link:' + e['target']
            else:
                h = hashlib.sha256(b''.join(frag_data[x - 1] for x in e['refs'])).hexdigest()
                t = int(e['mtime'] / 10 ** 9)
                st[p] = '%s %s' % (h, t if -(1 << 31) <= t < (1 << 31) else '*')
        return True, with_parents(st)
    except Exception as e:      # SycError, and anything garbage makes it throw
        return False, '%s: %s' % (type(e).__name__, e)


def nacl_argon_guard():
    real = syc_ref.argon2id

    def guarded(pw, salt, t, m, p):
        if m > KDF_MAX * 1024 or t > 16:
            raise syc_ref.SycError('kdf too costly for the fuzzer')
        return real(pw, salt, t, m, p)
    syc_ref.argon2id = guarded


# ── a worker ─────────────────────────────────────────────────────────────

def worker(wid, a, seeds, stop_at, q):
    try:
        work_loop(wid, a, seeds, stop_at, q)
    except BaseException:
        import traceback
        q.put(('note', 'worker %d died: %s' % (wid, traceback.format_exc())))
    q.put(('done', wid))


def work_loop(wid, a, seeds, stop_at, q):
    nacl_argon_guard()
    r = random.Random('%d-%d' % (a.seed, wid))
    sd = os.path.join(a.work, 'seeds')
    data = {n: open(os.path.join(sd, n), 'rb').read() for n, _, _, _ in seeds}
    layouts = {}
    for n, k, pw, _ in seeds:
        if k == 'arc':
            try:
                layouts[n] = Layout(data[n], pw)
            except Exception:
                layouts[n] = None
    base = os.path.join(a.work, 'run', 'w%d' % wid)
    escape = os.path.join(a.work, 'escape', 'w%d' % wid)
    os.makedirs(escape, exist_ok=True)
    stats = {}
    n = 0
    while time.time() < stop_at:
        n += 1
        name, kind, pw, exp = r.choice(seeds)
        b = data[name]
        same = [s for s in seeds if s[1] == kind]
        ctx = {'layout': layouts.get(name), 'escape': escape,
               'other': lambda rr: data[rr.choice(same)[0]]}
        muts = BYTE_MUTATORS + ([m_index] * 6 + [m_block] * 2 if kind == 'arc' else [])
        mut = r.choice(muts)
        try:
            res = mut(r, b, ctx)
        except Exception as e:      # a mutation that could not apply here
            res = m_flip(r, b, ctx), 'flip'
            if not isinstance(e, (syc_ref.SycError, IndexError, ValueError)):
                q.put(('note', '%s on %s: %r' % (mut.__name__, name, e)))
        if isinstance(res, tuple):
            m, mname = res
        else:
            m, mname = res, mut.__name__[2:]
        if m == b:
            continue
        binary = a.chk if (a.chk and n % 2 == 0) else a.syc
        paths = r.choice(['auto', 'c', 'pascal'])
        rmtree(base)
        sand = os.path.join(base, 's1', 's2')
        os.makedirs(sand)
        f = os.path.join(sand, 'in.' + ('syc' if kind == 'arc' else 'sylz'))
        with open(f, 'wb') as fh:
            fh.write(m)
        opt = ['--paths', paths, '--kdf-mem-max', str(KDF_MAX)]
        if pw:
            opt.append('-p' + pw)
        res = {}
        if kind == 'arc':
            cmds = {'t': ['t', '-q', '--no-progress'], 'l': ['l', '-l'], 'i': ['i', '-v'],
                    'x': ['x', '-q', '--no-progress', '-o', 'out']}
        else:
            cmds = {'t': ['t', '-q', '--no-progress'], 'i': ['i', '-v'],
                    'd': ['d', '-q', '--no-progress', '-O']}
        for c, args in cmds.items():
            res[c] = run([binary] + args[:1] + opt + args[1:] + [f], sand)
        problems = []
        for c, (rc, out, err, dt) in res.items():
            if rc == 'timeout':
                problems.append(('timeout', c, ''))
            elif rc == 4 and 'over the limit of %d' % KDF_MAX in err:
                pass        # a key that needs more memory than --kdf-mem-max
            elif rc == 2 and ('not encrypted, but a password was given' in err or
                              (not pw and 'is encrypted: give the password' in err)):
                pass        # the format byte says plain now: refused as a usage error
            elif rc == 4 and c == 'x' and mname.startswith('idx') and \
                    'cannot create the directory' in err:
                pass        # the same: an entry under a file
            elif rc not in (0, 1, 3):
                problems.append(('exit%s' % rc, c, err.strip().splitlines()[-1:] or ['']))
            elif CRASH.search(err):
                problems.append(('crash', c, CRASH.search(err).group(0)))
        # escapes: s1 holds only s2, s2 only the input and out, escape/ empty
        if sorted(os.listdir(os.path.join(base, 's1'))) != ['s2'] or \
                set(os.listdir(sand)) - {os.path.basename(f), 'out'} or os.listdir(escape) or \
                sorted(os.listdir(base)) != ['s1']:
            problems.append(('escape', 'x', ''))
            shutil.rmtree(escape, ignore_errors=True)
            os.makedirs(escape, exist_ok=True)
        rt = res['t'][0]
        if kind == 'arc':
            rx = res['x'][0]
            got = with_parents(state(os.path.join(sand, 'out'))) if os.path.isdir(
                os.path.join(sand, 'out')) else {}
            idx = mname.startswith('idx')
            if rx == 0 and not idx and got not in exp:
                problems.append(('wrong-x', 'x', ''))
            # known, harmless: an index (valid by its format) with an entry
            # under a file or a symlink; t passes it, x cannot make the
            # directory (exit 4) or the symlink (exit 1). No writer makes one.
            conflict = idx and re.search(r'cannot create the (directory|symlink)|cannot create, skipped',
                                         res['x'][2])
            if rt == 0 and rx != 0 and not conflict:
                problems.append(('t-ok-x-%s' % rx, 'x', res['x'][2].strip()[-200:]))
        else:
            rd = res['d'][0]
            if rd == 0 and hashlib.sha256(res['d'][1]).hexdigest() != exp:
                problems.append(('wrong-d', 'd', ''))
            if rt == 0 and rd != 0:
                problems.append(('t-ok-d-%s' % rd, 'd', res['d'][2].strip()[-200:]))
        if a.ref and (r.random() < a.ref or mname.startswith('idx')) and len(m) < 400000:
            sound, ref_st = ref_verdict(kind, m, pw)
            if sound != (rt == 0):
                problems.append(('ref-%s-syc-%s' % ('ok' if sound else 'bad', rt), 't',
                                 '' if sound else str(ref_st)[:120]))
            elif sound and kind == 'arc' and rx == 0 and not same_state(got, ref_st):
                problems.append(('ref-state', 'x', ''))
            elif sound and kind == 'stream' and rd == 0 and \
                    hashlib.sha256(res['d'][1]).hexdigest() != ref_st:
                problems.append(('ref-data', 'd', ''))
        if a.vg and r.random() < a.vg_rate:
            # memcheck on a build with the C heap (-Facmem): reads and
            # writes outside what was allocated
            c = 't' if r.random() < 0.5 or kind != 'arc' else 'x'
            args = cmds[c]
            if c == 'x':
                args = args[:-1] + ['outvg']
            rc, _, err, _ = run(['valgrind', '-q', '--error-exitcode=99'] + [a.vg] + args[:1] + opt
                                + args[1:] + [f], sand, timeout=TIMEOUT * 10)
            if rc == 99 or rc == 'timeout':
                first = re.search(r'(Invalid \w+ of size \d+|Conditional jump[^\n]*|'
                                  r'Use of uninitialised[^\n]*|Syscall param[^\n]*)', err)
                problems.append(('valgrind', c, first.group(0) if first else str(rc)))
                res['vg-' + c] = (rc, b'', err, 0)
        key = (name.split('.')[-1], mname)
        st = stats.setdefault('%s/%s' % key, [0, 0, 0])
        st[0] += 1
        st[1 if rt == 0 else 2] += 1
        for kindp, c, msg in problems:
            q.put(('finding', kindp, c, msg, name, mname, binary, paths, m,
                   {c2: (v[0], v[2][-2000:], round(v[3], 2)) for c2, v in res.items()}))
        if n % 50 == 0:
            q.put(('stats', wid, n, stats))
            stats = {}
    q.put(('stats', wid, n, stats))
    rmtree(base)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('syc')
    ap.add_argument('work')
    ap.add_argument('--chk')
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--minutes', type=float, default=10)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--ref', type=float, default=0.0)
    ap.add_argument('--vg', help='a build with -Facmem, run under valgrind on some cases')
    ap.add_argument('--vg-rate', type=float, default=0.05)
    a = ap.parse_args()
    a.syc = os.path.abspath(a.syc)
    a.chk = os.path.abspath(a.chk) if a.chk else None
    a.vg = os.path.abspath(a.vg) if a.vg else None
    a.work = os.path.abspath(a.work)
    os.makedirs(a.work, exist_ok=True)
    seeds = make_seeds(a.syc, a.work)
    fd = os.path.join(a.work, 'findings')
    os.makedirs(fd, exist_ok=True)
    seen = set(os.path.splitext(x)[0] for x in os.listdir(fd))
    log = open(os.path.join(a.work, 'fuzz.log'), 'a')
    stop_at = time.time() + a.minutes * 60
    q = mp.Queue()
    procs = [mp.Process(target=worker, args=(w, a, seeds, stop_at, q)) for w in range(a.jobs)]
    for p in procs:
        p.start()
    total, totals, done, nfind, last = 0, {}, 0, 0, time.time()
    log.write('start %s seed %d jobs %d minutes %g\n' % (time.ctime(), a.seed, a.jobs, a.minutes))
    while done < a.jobs:
        try:
            msg = q.get(timeout=5)
        except Exception:
            msg = None
            if not any(p.is_alive() for p in procs):
                break
        if msg and msg[0] == 'done':
            done += 1
        elif msg and msg[0] == 'note':
            log.write('note: %s\n' % msg[1])
            log.flush()
            if 'died' in msg[1]:
                print(msg[1], flush=True)
        elif msg and msg[0] == 'stats':
            for k, v in msg[3].items():
                t = totals.setdefault(k, [0, 0, 0])
                for i in range(3):
                    t[i] += v[i]
        elif msg and msg[0] == 'finding':
            _, kindp, c, msg_, name, mname, binary, paths, m, res = msg
            m_ = re.sub(r'\S*/\S*', '', str(msg_))
            m_ = re.sub(r'[0-9]+', 'N', m_)
            if kindp.startswith('ref-bad') and 'UnicodeDecodeError' in m_:
                m_ = 'UnicodeDecodeError'
            sig = re.sub(r'[^A-Za-z0-9]+', '_', '%s-%s-%s' % (kindp, c, m_))[:100]
            nfind += 1
            if sig not in seen:
                seen.add(sig)
                ext = '.syc' if name.endswith('.syc') else '.sylz'
                with open(os.path.join(fd, sig + ext), 'wb') as fh:
                    fh.write(m)
                with open(os.path.join(fd, sig + '.json'), 'w') as fh:
                    json.dump({'kind': kindp, 'command': c, 'seed': name, 'mutation': mname,
                               'binary': binary, 'paths': paths, 'results': res}, fh, indent=1)
                log.write('FINDING %s (%s, %s)\n' % (sig, name, binary))
                print('FINDING', sig, flush=True)
        if time.time() - last > 60:
            last = time.time()
            total = sum(v[0] for v in totals.values())
            log.write('%s cases %d findings %d (unique %d)\n' % (time.strftime('%H:%M:%S'), total,
                                                                  nfind, len(seen)))
            log.flush()
    for p in procs:
        p.join()
    total = sum(v[0] for v in totals.values())
    log.write('end %s cases %d findings %d\n' % (time.ctime(), total, nfind))
    for k in sorted(totals):
        log.write('  %-28s %7d  t ok %6d  t refused %6d\n' % (k, *totals[k]))
    log.close()
    print('cases %d, findings %d (unique %d)' % (total, nfind, len(seen)))
    for k in sorted(totals):
        print('  %-28s %7d  t ok %6d  t refused %6d' % (k, *totals[k]))
    return 1 if nfind else 0


if __name__ == '__main__':
    sys.exit(main())
