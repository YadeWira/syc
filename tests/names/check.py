#!/usr/bin/env python3
"""Names: what syc x does with names, on every platform.

- hostile.syc (written on Linux, below) holds names that Linux allows and
  Windows does not take as they are: separators (..\\..\\escaped.txt,
  C:\\Users\\Public\\..., \\root), a drive (C:x), a data stream (a:b),
  devices (CON, nul.txt, com1.log), a trailing dot or space, ? and a
  control character, and a directory with a colon. On Windows syc x skips
  them (exit 1) and writes nothing outside the output directory; elsewhere
  it extracts every one as it is.
- Unicode names (accents, Greek, Cyrillic, Arabic, Japanese, emoji, a
  combining accent, a 300-character path) go through a, l, l --null and x
  unchanged; so does a Unicode password, given with -p, SYC_PASSWORD and
  --password-file.

    check.py SYC WORKDIR

hostile.syc was written once, from a directory holding those names:
    syc a hostile.syc .
"""
import os
import shutil
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
WINDOWS = os.name == 'nt'
HOSTILE = ['..\\..\\escaped.txt', 'C:\\Users\\Public\\syc-hostile.txt', '\\syc-hostile-root.txt',
           'C:drive-relative.txt', 'ads:stream', 'CON', 'nul.txt', 'com1.log', 'trailing.',
           'trailing ', 'q?.txt', 'ctl\x01.txt', 'bad:dir/', 'bad:dir/inner.txt']
GOOD = ['ok.txt', 'sub/', 'sub/ok2.txt', 'año/', 'año/ñ.txt']
UNICODE = ['año/canción.txt', 'Ελληνικά/αρχείο.txt', 'кириллица.txt', 'عربي.txt',
           '日本語フォルダ/ファイル.txt', 'emoji 😀🎉.txt', 'e\u0301-combining.txt',
           'con espacios y tildes áéíóú.txt',
           '/'.join('carpeta_%02d_ñññ' % i for i in range(16)) + '/al_final.txt']

bad = 0


def fail(msg):
    global bad
    print('FAIL: ' + msg.encode('ascii', 'backslashreplace').decode())
    bad += 1


def tree(d):
    got = set()
    for root, dirs, names in os.walk(d):
        rel = os.path.relpath(root, d).replace(os.sep, '/')
        rel = '' if rel == '.' else rel + '/'
        got.update(rel + n + '/' for n in dirs)
        got.update(rel + n for n in names)
    return got


def lpath(p):
    """a path Windows opens past 260 characters"""
    p = os.path.abspath(p)
    return '\\\\?\\' + p if WINDOWS else p


def main():
    syc, work = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    shutil.rmtree(lpath(work), ignore_errors=True)

    def run(*args, cwd=None, env=None):
        return subprocess.run([syc] + list(args), capture_output=True, cwd=cwd, env=env)

    # hostile names: extracted into work/a/b, into the current directory and with -o
    for how in ('cwd', '-o'):
        base = os.path.join(work, how)
        cwd = os.path.join(base, 'a', 'b')
        os.makedirs(cwd)
        out = cwd if how == 'cwd' else os.path.join(cwd, 'out')
        r = run('x', '-q', os.path.join(here, 'hostile.syc'), *(['-o', out] if how == '-o' else []),
                cwd=cwd)
        got = tree(out)
        if WINDOWS:
            skipped = r.stderr.decode('utf-8', 'replace').count('not a valid name on Windows')
            if r.returncode != 1 or got != set(GOOD) or skipped != len(HOSTILE):
                fail('hostile.syc (%s): exit %d, %d skipped, extracted %s' % (
                    how, r.returncode, skipped, sorted(got)))
            pre = 'a/b/' if how == 'cwd' else 'a/b/out/'
            outside = tree(base) - {'a/', 'a/b/', 'a/b/out/'} - {pre + p for p in got}
            if outside:
                fail('hostile.syc (%s): written outside: %s' % (how, sorted(outside)))
            for p in ('C:\\Users\\Public\\syc-hostile.txt', '\\syc-hostile-root.txt'):
                if os.path.exists(p):
                    fail('hostile.syc (%s): wrote %s' % (how, p))
                    os.remove(p)
        elif r.returncode != 0 or got != set(GOOD + HOSTILE):
            fail('hostile.syc (%s): exit %d, %s, extracted %s' % (
                how, r.returncode, r.stderr.decode('utf-8', 'replace').strip(), sorted(got)))

    # Unicode names, both ways
    src = os.path.join(work, 'u', 'tree')
    for i, p in enumerate(UNICODE):
        f = lpath(os.path.join(src, p))
        os.makedirs(os.path.dirname(f), exist_ok=True)
        with open(f, 'wb') as fh:
            fh.write(('%d %s\n' % (i, p)).encode())
    want = {'tree/' + p for p in tree(lpath(src))} | {'tree/'}
    arc = os.path.join(work, 'u', 'u.syc')
    r = run('a', '-q', arc, 'tree', cwd=os.path.join(work, 'u'))
    if r.returncode != 0:
        fail('a, Unicode names: exit %d, %s' % (r.returncode, r.stderr.decode('utf-8', 'replace')))
    r = run('l', arc)
    if set(r.stdout.decode('utf-8').splitlines()) != want:
        fail('l, Unicode names: %r' % r.stdout.decode('utf-8', 'replace'))
    r = run('l', '--null', arc)
    if set(r.stdout.decode('utf-8').split('\0')[:-1]) != want:
        fail('l --null, Unicode names: %r' % r.stdout)
    out = os.path.join(work, 'u', 'x')
    r = run('x', '-q', '-o', out, arc)
    got = {'tree/' + p for p in tree(lpath(os.path.join(out, 'tree')))} | {'tree/'}
    if r.returncode != 0 or got != want:
        fail('x, Unicode names: exit %d, %s, %s' % (r.returncode, r.stderr.decode('utf-8', 'replace')[-400:],
                                                    sorted(got ^ want)))
    for i, p in enumerate(UNICODE):
        f = lpath(os.path.join(out, 'tree', p))
        if os.path.isfile(f) and open(f, 'rb').read() != ('%d %s\n' % (i, p)).encode():
            fail('x, Unicode names: %s: not the same contents' % p)
    r = run('x', '-q', '-O', arc, 'tree/' + UNICODE[5])
    if r.stdout != ('5 %s\n' % UNICODE[5]).encode():
        fail('x -O NAME, a Unicode name: %r %r' % (r.stdout, r.stderr))

    # a Unicode password, three ways
    pw = 'contraseña ключ 🔑'
    enc = os.path.join(work, 'u', 'e.syc')
    r = run('a', '-q', '-p' + pw, '--kdf-mem', '8', enc, 'tree', cwd=os.path.join(work, 'u'))
    if r.returncode != 0:
        fail('a -p, a Unicode password: exit %d, %s' % (r.returncode, r.stderr))
    env = dict(os.environ, SYC_PASSWORD=pw)
    r = run('t', '-q', enc, env=env)
    if r.returncode != 0:
        fail('t, a Unicode SYC_PASSWORD: exit %d, %s' % (r.returncode, r.stderr))
    pf = os.path.join(work, 'u', 'pw.txt')
    with open(pf, 'wb') as fh:
        fh.write(pw.encode() + b'\n')
    r = run('t', '-q', '--password-file', pf, enc)
    if r.returncode != 0:
        fail('t --password-file, a Unicode password: exit %d, %s' % (r.returncode, r.stderr))
    r = run('t', '-q', '-pcontrasena', enc)
    if r.returncode != 3:
        fail('t, a wrong password: exit %d, want 3' % r.returncode)

    shutil.rmtree(lpath(work), ignore_errors=True)
    print('names: %s' % ('FAILED' if bad else 'all as expected'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
