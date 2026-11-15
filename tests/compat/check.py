#!/usr/bin/env python3
"""Checks that this syc reads what released versions wrote
(tests/compat/, written once by make.sh with those versions' binaries):
every stream decodes to the data, every archive gives, version by
version, the files (contents and mtimes) and directories of MANIFEST.json,
and syc t passes on each. The reference reader (tools/syc_ref.py) reads
them too when REF=1 (it needs PyNaCl).

    check.py SYC WORKDIR
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))


def state(d):
    files = {}
    for root, dirs, names in os.walk(d):
        for n in names:
            p = os.path.join(root, n)
            files[os.path.relpath(p, d).replace(os.sep, '/')] = '%s %d' % (
                hashlib.sha256(open(p, 'rb').read()).hexdigest(), int(os.stat(p).st_mtime))
        for n in dirs:
            files[os.path.relpath(os.path.join(root, n), d).replace(os.sep, '/') + '/'] = 'dir'
    return files


def main():
    syc, work = sys.argv[1], sys.argv[2]
    m = json.load(open(os.path.join(here, 'MANIFEST.json')))
    pw = ['-p' + m['password']]
    ref = os.environ.get('REF') == '1'
    os.makedirs(work, exist_ok=True)
    bad = n = 0

    def run(*args):
        return subprocess.run([syc] + list(args), capture_output=True)

    for name in sorted(os.listdir(here)):
        path = os.path.join(here, name)
        enc = pw if '-enc' in name else []
        if name.endswith('.sylz'):
            n += 1
            r = run('d', '-q', *enc, '-O', path)
            if r.returncode != 0 or hashlib.sha256(r.stdout).hexdigest() != m['stream']:
                print('FAIL: %s: d exit %d, %s' % (name, r.returncode, r.stderr.decode().strip()))
                bad += 1
        elif name.endswith('.syc'):
            n += 1
            for v, want in enumerate(m['versions'], 1):
                out = os.path.join(work, name + '-%d' % v)
                shutil.rmtree(out, ignore_errors=True)
                r = run('x', '-q', *enc, '-u', str(v), '-o', out, path)
                got = state(out) if os.path.isdir(out) else {}
                if r.returncode != 0 or got != want:
                    print('FAIL: %s: version %d: x exit %d, %s' % (name, v, r.returncode,
                          r.stderr.decode().strip() or 'not the same files'))
                    for k in sorted(set(got) | set(want)):
                        if got.get(k) != want.get(k):
                            print('   %s: %s, want %s' % (k, got.get(k), want.get(k)))
                    bad += 1
                shutil.rmtree(out, ignore_errors=True)
        else:
            continue
        r = run('t', '-q', *enc, path)
        if r.returncode != 0:
            print('FAIL: %s: t exit %d, %s' % (name, r.returncode, r.stderr.decode().strip()))
            bad += 1
        if ref:
            r = subprocess.run([sys.executable, '-I', os.path.join(here, '..', '..', 'tools', 'syc_ref.py')]
                               + (['-p' + m['password']] if enc else []) + ['t', path],
                               capture_output=True)
            if r.returncode != 0:
                print('FAIL: %s: the reference reader: %s' % (name, r.stdout.decode().strip()))
                bad += 1
    print('compat: %d files written by syc 0.2.2 to 0.9.0, %s' % (n, 'FAILED' if bad else 'all read'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
