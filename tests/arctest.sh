#!/bin/sh
# arctest — the archiver end to end: syc a, l, i, t on a tree, the same
# archive whatever the threads, refusals and exit codes, and damage: every
# byte flip found by syc t (exit 3), truncations and trailing junk.
# Usage: tests/arctest.sh SAMPLES-DIR WORK-DIR   (WORK-DIR: new or empty;
#        SAMPLES-DIR is copied, never written)
set -e
SYC=${SYC:-$(cd "$(dirname "$0")/.." && pwd)/out/syc}
src=$1
work=$2
[ -d "$src" ] && [ -n "$work" ] || { echo "usage: $0 SAMPLES-DIR WORK-DIR" >&2; exit 2; }
mkdir -p "$work"
cd "$work"
fail=0
check() {   # check WHAT EXPECTED-EXIT COMMAND...
  what=$1; want=$2; shift 2
  set +e; "$@" >out.txt 2>err.txt; got=$?; set -e
  if [ "$got" != "$want" ]; then
    echo "FAIL: $what: exit $got, expected $want"; cat err.txt; fail=1
  fi
}

# the tree: the samples, a duplicate, an empty file and directory, a link
rm -rf tree
mkdir tree
cp -r "$src" tree/samples
first=$(find tree/samples -type f | head -1)
cp "$first" tree/copy
: > tree/empty
mkdir tree/emptydir
ln -s copy tree/link

# version time (bytes 16..23) masked: the rest must match
masked() { python3 -c "import sys;d=bytearray(open(sys.argv[1],'rb').read());d[16:24]=bytes(8);sys.stdout.buffer.write(d)" "$1"; }

rm -f *.syc
check "a" 0 "$SYC" a -q t1.syc tree
check "a -t 4" 0 "$SYC" a -q -t 4 t4.syc tree
masked t1.syc > m1; masked t4.syc > m4
cmp -s m1 m4 || { echo "FAIL: -t 1 and -t 4 archives differ"; fail=1; }
check "a -ec -9 -b 1 -t 3" 0 "$SYC" a -q -ec -9 -b 1 -t 3 te.syc tree
check "a to stdout" 0 sh -c "'$SYC' a -q - tree > ts.syc"
for f in t1 te ts; do check "t $f" 0 "$SYC" t -q -t 2 $f.syc; done
check "t from stdin" 0 sh -c "'$SYC' t -q - < t1.syc"
check "l" 0 "$SYC" l t1.syc
n=$(cd tree && find . -mindepth 1 | wc -l)
[ "$(wc -l < out.txt)" -eq "$((n + 1))" ] || { echo "FAIL: l lists $(wc -l < out.txt) entries, the tree has $((n + 1))"; fail=1; }
check "l -l filter" 0 "$SYC" l -l t1.syc tree/copy
check "l no match" 1 "$SYC" l t1.syc nothing/here
check "i" 0 "$SYC" i t1.syc
check "i from stdin" 0 sh -c "'$SYC' i - < t1.syc"

# refusals
check "existing archive" 2 "$SYC" a t1.syc tree
check "path with .." 2 "$SYC" a x.syc ../tree
check "nothing to add" 1 "$SYC" a x.syc -X '*' tree
[ ! -e x.syc ] || { echo "FAIL: nothing to add wrote an archive"; fail=1; }
check "missing path" 1 "$SYC" a y.syc tree/copy no-such-file

# damage, on a small archive: every flipped byte is found
mkdir -p small
head -c 300000 "$first" > small/a
printf 'small' > small/b
"$SYC" a -q -b 1 sm.syc small
python3 - "$SYC" <<'EOF' || fail=1
import random, subprocess, sys
syc = sys.argv[1]
orig = open('sm.syc', 'rb').read()
random.seed(1)
bad = 0
for i in range(200):
    d = bytearray(orig)
    k = random.randrange(len(d))
    d[k] ^= 1 << random.randrange(8)
    open('fz.syc', 'wb').write(d)
    r = subprocess.run([syc, 't', '-q', 'fz.syc'], capture_output=True).returncode
    if r != 3:
        print('FAIL: byte %d flipped: t exit %d' % (k, r)); bad += 1
    for cmd in ('l', 'i'):
        r = subprocess.run([syc, cmd, 'fz.syc'], capture_output=True).returncode
        if r not in (0, 3):
            print('FAIL: byte %d flipped: %s exit %d' % (k, cmd, r)); bad += 1
for n in range(0, len(orig), max(1, len(orig) // 100)):
    open('fz.syc', 'wb').write(orig[:n])
    r = subprocess.run([syc, 't', '-q', 'fz.syc'], capture_output=True).returncode
    if r != 3:
        print('FAIL: truncated to %d: t exit %d' % (n, r)); bad += 1
open('fz.syc', 'wb').write(orig + b'junk after the commit')
r = subprocess.run([syc, 't', '-q', 'fz.syc'], capture_output=True).returncode
if r != 1:
    print('FAIL: trailing junk: t exit %d' % r); bad += 1
sys.exit(1 if bad else 0)
EOF

if [ $fail = 0 ]; then echo "arctest: ok"; else echo "arctest: FAILED"; exit 1; fi
