#!/usr/bin/env python3
"""syc_vectors.py - writes test vectors for syc's archive and stream
formats, for other readers (and tools/syc_ref.py --check).

    syc_vectors.py SYC OUTDIR [SAMPLE]

SYC is the syc binary; SAMPLE a text file for compressible data
(default: generated). For each archive NAME.syc, NAME.syc.json holds what
it must read as: every version's whole state (path, type, mtime in ns,
attributes, uid/gid, size and SHA-256 of files, symlink targets), taken
from the trees syc archived, not from syc; "damaged" says whether bytes
follow the last complete version. For each stream NAME.sylz,
NAME.sylz.json holds the decoded size and SHA-256. Vectors with
"corrupt": true must be refused.
"""
import hashlib
import json
import os
import random
import shutil
import stat
import subprocess
import sys

rnd = random.Random(2026)


def snapshot(root, base):
    """the state syc a stores for base (a directory under root)"""
    out = []
    for dp, dns, fns in os.walk(os.path.join(root, base)):
        dns.sort()
        rel_dir = os.path.relpath(dp, root).replace(os.sep, '/')
        for n in dns + fns:
            p = os.path.join(dp, n)
            st = os.lstat(p)
            d = {'path': rel_dir + '/' + n, 'mtime': st.st_mtime_ns, 'attrKind': 1,
                 'attrs': stat.S_IMODE(st.st_mode), 'uid': st.st_uid, 'gid': st.st_gid}
            if stat.S_ISLNK(st.st_mode):
                d['type'] = 'symlink'
                d['target'] = os.readlink(p)
            elif stat.S_ISDIR(st.st_mode):
                d['type'] = 'dir'
            else:
                d['type'] = 'file'
                data = open(p, 'rb').read()
                d['size'] = len(data)
                d['sha256'] = hashlib.sha256(data).hexdigest()
            out.append(d)
    st = os.lstat(os.path.join(root, base))
    out.append({'path': base, 'type': 'dir', 'mtime': st.st_mtime_ns, 'attrKind': 1,
                'attrs': stat.S_IMODE(st.st_mode), 'uid': st.st_uid, 'gid': st.st_gid})
    order = ['path', 'type', 'mtime', 'attrKind', 'attrs', 'uid', 'gid', 'size', 'sha256', 'target']
    out = [{k: d[k] for k in order if k in d} for d in out]
    return sorted(out, key=lambda d: d['path'].encode())


def touch(p, ns):
    os.utime(p, ns=(ns, ns), follow_symlinks=False)


def write(p, data, ns, mode=0o644):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(data)
    os.chmod(p, mode)
    touch(p, ns)


T0 = 1700000000 * 10**9


def settle(root, base):
    """directory times fixed after their contents changed"""
    for dp, dns, fns in os.walk(os.path.join(root, base), topdown=False):
        touch(dp, T0 + 7 * 10**9 + 123)


def main():
    syc, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    text = open(sys.argv[3], 'rb').read() if len(sys.argv) > 3 else None
    if not text:
        words = [b'the ', b'syc ', b'archive ', b'fragment ', b'block ', b'version ', b'of ', b'and ']
        text = b''.join(rnd.choice(words) for _ in range(400000))
    work = os.path.join(out, '.work')
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    os.makedirs(out, exist_ok=True)

    def syc_run(*args):
        subprocess.run([syc] + list(args), check=True, cwd=work, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)

    def archive(name, states, opts=(), base='t'):
        """states: functions building the tree in turn; one version each"""
        dest = os.path.join(out, name + '.syc')
        if os.path.exists(dest):
            os.remove(dest)
        shutil.rmtree(os.path.join(work, base), ignore_errors=True)
        versions = []
        for build in states:
            build(os.path.join(work, base))
            settle(work, base)
            versions.append(snapshot(work, base))
            syc_run('a', '-q', *opts, dest, base)
        json.dump({'versions': versions, 'damaged': False}, open(dest + '.json', 'w'), indent=0,
                  ensure_ascii=False)
        return dest, versions

    # one version: sizes around the block and fragment limits, links,
    # empty file and directory, permissions, a non-ASCII name
    def basic(t):
        write(t + '/empty', b'', T0)
        write(t + '/one', b'x', T0 + 1)
        for n in (63, 64, 65, 1000):
            write(t + '/size%d' % n, text[:n], T0 + n)
        write(t + '/text', text[:300000], T0 + 2, 0o600)
        write(t + '/random', bytes(rnd.getrandbits(8) for _ in range(700000)), T0 + 3, 0o4755)
        write(t + '/sub/deep/file', text[1000:5000], T0 + 4)
        write(t + '/ñandú-日本.txt', 'hola'.encode(), T0 + 5)
        os.makedirs(t + '/emptydir')
        os.chmod(t + '/emptydir', 0o700)
        os.symlink('text', t + '/link')
        os.symlink('/no/such/target', t + '/dangling')
        touch(t + '/link', T0 + 6)
        touch(t + '/dangling', T0 + 6)
    archive('basic', [basic])

    # duplicates inside one version
    def dups(t):
        for k in range(5):
            write(t + '/copy%d' % k, text[:200000], T0 + k)
        write(t + '/half', text[100000:200000], T0 + 9)
    archive('dedup', [dups])

    # versions: change, append, delete, come back, a type change, a link
    # retargeted, data shared with earlier versions
    def v1(t):
        write(t + '/a', text[:150000], T0)
        write(t + '/b', text[150000:250000], T0)
        write(t + '/dir/c', b'c', T0)
        os.symlink('a', t + '/link')

    def v2(t):
        with open(t + '/a', 'ab') as f:
            f.write(b'appended')
        touch(t + '/a', T0 + 10)
        os.remove(t + '/b')
        shutil.rmtree(t + '/dir')
        write(t + '/copy-of-a', open(t + '/a', 'rb').read(), T0 + 11)

    def v3(t):
        write(t + '/b', b'b is back', T0 + 20)
        os.makedirs(t + '/a2')
        write(t + '/a2/x', b'x', T0 + 20)
        os.remove(t + '/link')
        os.symlink('b', t + '/link')
        touch(t + '/link', T0 + 21)

    def v4(t):
        os.remove(t + '/copy-of-a')
        os.makedirs(t + '/copy-of-a')        # a file becomes a directory
        os.chmod(t + '/a', 0o640)
        touch(t + '/a', T0 + 10)
    dest, versions = archive('versions', [v1, v2, v3, v4])

    # bytes after the last version: a reader keeps the versions before
    damaged = os.path.join(out, 'versions-tail.syc')
    data = open(dest, 'rb').read()
    open(damaged, 'wb').write(data + b'SYCV\x05\x00\x00\x00 an interrupted version')
    json.dump({'versions': versions, 'damaged': True}, open(damaged + '.json', 'w'), indent=0,
              ensure_ascii=False)

    # several blocks (-b 1), extra compression, stored (random) blocks
    def big(t):
        write(t + '/text', text[:2500000] if len(text) >= 2500000 else (text * 7)[:2500000], T0)
        write(t + '/random', bytes(rnd.getrandbits(8) for _ in range(1500000)), T0)
    archive('blocks-ec', [big], ('-ec', '-9', '-b', '1'))
    archive('blocks-v2', [big], ('-6', '-b', '1'))

    # damaged ones, to be refused (exit 3 from syc)
    good = open(os.path.join(out, 'basic.syc'), 'rb').read()
    for name, pos in (('bad-data', len(good) // 3), ('bad-index', len(good) - 40),
                      ('bad-header', 4)):
        d = bytearray(good)
        d[pos] ^= 0x10
        open(os.path.join(out, name + '.syc'), 'wb').write(d)
        json.dump({'corrupt': True}, open(os.path.join(out, name + '.syc.json'), 'w'))

    # streams
    def stream(name, data, opts=()):
        src = os.path.join(work, name)
        open(src, 'wb').write(data)
        dest = os.path.join(out, name + '.sylz')
        syc_run('c', '-q', '-f', *opts, '-o', dest, name)
        json.dump({'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()},
                  open(dest + '.json', 'w'))
    stream('empty', b'')
    stream('one-byte', b'x')
    stream('text', text[:1000000])
    stream('text-ec', text[:1000000], ('-ec', '-10'))
    stream('three-blocks', (text * 3)[:2600000], ('-b', '1'))
    stream('random', bytes(rnd.getrandbits(8) for _ in range(300000)))
    shutil.rmtree(work)


if __name__ == '__main__':
    main()
