#!/bin/sh
# arctest — the archiver end to end: syc a, x, l, i, t on a tree, the same
# archive whatever the threads, the tree back exactly (contents, types,
# permissions, times to the ns, symlinks), overwrite rules, refusals and
# exit codes, and damage: every byte flip found by syc t (exit 3),
# truncations and trailing junk.
# Usage: tests/arctest.sh SAMPLES-DIR WORK-DIR   (WORK-DIR: new or empty;
#        SAMPLES-DIR is copied, never written)
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
SYC=${SYC:-$here/out/syc}
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
chmod 600 tree/copy
chmod 700 tree/emptydir
touch -d '2001-02-03 04:05:06.123456789' tree/copy

# the same tree: types, contents, permissions, mtime (ns), link targets
treecmp() {
  python3 - "$1" "$2" <<'PY'
import os, stat, sys
def walk(root):
    out = {}
    for dp, dns, fns in os.walk(root):
        for n in dns + fns:
            p = os.path.join(dp, n)
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                v = ('link', os.readlink(p), st.st_mtime_ns)
            elif stat.S_ISDIR(st.st_mode):
                v = ('dir', stat.S_IMODE(st.st_mode), st.st_mtime_ns)
            else:
                v = ('file', stat.S_IMODE(st.st_mode), st.st_mtime_ns, open(p, 'rb').read())
            out[os.path.relpath(p, root)] = v
    return out
a, b = walk(sys.argv[1]), walk(sys.argv[2])
bad = [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
for k in bad[:10]:
    print('FAIL: differs after extraction:', k)
sys.exit(1 if bad else 0)
PY
}

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

# extraction
rm -rf o1 o4 os of ev
check "x" 0 "$SYC" x -q -o o1 t1.syc
treecmp tree o1/tree || fail=1
check "x -t 4 (-ec archive)" 0 "$SYC" x -q -t 4 -o o4 te.syc
treecmp tree o4/tree || fail=1
check "x from stdin" 0 sh -c "'$SYC' x -q -o os - < ts.syc"
treecmp tree os/tree || fail=1
check "x over existing files" 1 "$SYC" x -q -o o1 t1.syc
check "x --skip" 0 "$SYC" x -q --skip -o o1 t1.syc
check "x -f" 0 "$SYC" x -q -f -o o1 t1.syc
treecmp tree o1/tree || fail=1
check "x -O one file" 0 sh -c "'$SYC' x -O t1.syc tree/copy > copy.out"
cmp -s copy.out tree/copy || { echo "FAIL: x -O"; fail=1; }
check "x -O several" 2 "$SYC" x -O t1.syc tree
check "x filter" 0 "$SYC" x -q -o of t1.syc tree/emptydir tree/copy
got=$(cd of && find . | sort | tr '\n' ' ')
[ "$got" = ". ./tree ./tree/copy ./tree/emptydir " ] || { echo "FAIL: x filter extracted: $got"; fail=1; }
check "x -u 2 of 1 version" 2 "$SYC" x -o ou t1.syc -u 2
mkdir -p ev/tree
ln -s /tmp ev/tree/samples
check "x through a symlinked directory" 1 "$SYC" x -q -o ev t1.syc tree/samples

# versions: change, add, delete; each version extracts as it was
rm -rf vt snap1 snap2 ov1 ov2 ov3
cp -a tree vt
check "a version 1" 0 "$SYC" a -q v.syc vt
cp -a vt snap1
sleep 1
printf 'more\n' >> vt/copy
rm -r vt/emptydir
echo new > vt/new
check "a version 2" 0 "$SYC" a -q -t 2 v.syc vt
cp -a vt snap2
check "a, no changes" 0 "$SYC" a -q v.syc vt
"$SYC" i v.syc > out.txt
[ "$(grep -c '^ *[0-9]' out.txt)" = 2 ] || { echo "FAIL: a with no changes added a version"; fail=1; }
check "x -u 1" 0 "$SYC" x -q -u 1 -o ov1 v.syc
treecmp snap1 ov1/vt || fail=1
check "x (version 2)" 0 "$SYC" x -q -o ov2 v.syc
treecmp snap2 ov2/vt || fail=1
check "l --all" 0 "$SYC" l --all v.syc vt/emptydir
grep -q '2  vt/emptydir  (deleted)' out.txt || { echo "FAIL: l --all does not show the deletion"; cat out.txt; fail=1; }
rm vt/new
check "a --no-delete" 0 "$SYC" a -q --no-delete v.syc vt
check "x (version 3 kept vt/new)" 0 "$SYC" x -q -o ov3 v.syc vt/new

# an interrupted append: the next syc a cuts it and the archive is whole
cp v.syc base.syc
echo later > vt/later
"$SYC" a -q v.syc vt
python3 - "$SYC" <<'PY' || fail=1
import os, subprocess, sys
syc = sys.argv[1]
base, full = os.path.getsize('base.syc'), os.path.getsize('v.syc')
data = open('v.syc', 'rb').read()
bad = 0
for n in sorted(set([base + 1, base + 16, base + 17, full - 25, full - 24, full - 1, (base + full) // 2])):
    open('cut.syc', 'wb').write(data[:n])
    r1 = subprocess.run([syc, 't', '-q', 'cut.syc'], capture_output=True).returncode
    r2 = subprocess.run([syc, 'a', '-q', 'cut.syc', 'vt'], capture_output=True).returncode
    r3 = subprocess.run([syc, 't', '-q', 'cut.syc'], capture_output=True).returncode
    r4 = subprocess.run([syc, 'l', 'cut.syc', 'vt/later'], capture_output=True).returncode
    if (r1, r2, r3, r4) != (1, 0, 0, 0):
        print('FAIL: cut at %d: t %d, a %d, t %d, l %d' % (n, r1, r2, r3, r4)); bad += 1
sys.exit(1 if bad else 0)
PY

# encryption: both modes, a second version, the password's sources
rm -rf oe oe2 oe3
check "a -p (format 3)" 0 "$SYC" a -q -pS3cret --kdf-mem 8 -t 3 enc.syc tree
check "x -p" 0 "$SYC" x -q -pS3cret -t 2 -o oe enc.syc
treecmp tree oe/tree || fail=1
check "l, wrong password" 3 "$SYC" l -pnope enc.syc
check "l, no password, no terminal" 2 sh -c "'$SYC' l enc.syc < /dev/null"
echo S3cret > pw.txt
check "t --password-file" 0 "$SYC" t -q --password-file pw.txt enc.syc
check "t SYC_PASSWORD" 0 env SYC_PASSWORD=S3cret "$SYC" t -q enc.syc
if grep -q -a "emptydir" enc.syc; then echo "FAIL: a name in an encrypted archive"; fail=1; fi
check "a -p --visible-names" 0 "$SYC" a -q -pS3cret --kdf-mem 8 --visible-names encv.syc tree
check "l --visible-names, no password" 0 sh -c "'$SYC' l encv.syc < /dev/null"
check "x --visible-names, no password" 2 sh -c "'$SYC' x -o oe3 encv.syc < /dev/null"
cp -a tree tree2
echo another > tree2/added
check "a -p, a second version" 0 "$SYC" a -q -pS3cret enc.syc tree2
check "x -p -u 1" 0 "$SYC" x -q -pS3cret -u 1 -o oe2 enc.syc
treecmp tree oe2/tree || fail=1
rm -rf tree2
check "c -p / d -p" 0 sh -c "'$SYC' c -q -pS3cret --kdf-mem 8 -O '$first' | '$SYC' d -q -pS3cret -O > enc.out"
cmp -s enc.out "$first" || { echo "FAIL: encrypted stream round trip"; fail=1; }

# the test vectors: written by this syc, read by the reference reader
# (tools/syc_ref.py, from the wiki's format pages) and by syc
rm -rf vectors
python3 -I "$here/tests/syc_vectors.py" "$SYC" vectors "$first" || { echo "FAIL: writing the vectors"; fail=1; }
python3 -I "$here/tools/syc_ref.py" --check vectors > out.txt || { echo "FAIL: the reference reader"; cat out.txt; fail=1; }
for f in vectors/*.syc vectors/*.sylz; do
  case $f in
    */bad-*) want=3 ;;
    *-tail.syc) want=1 ;;
    *) want=0 ;;
  esac
  pw=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('password',''))" "$f.json")
  if [ -n "$pw" ]; then
    check "syc t $f" $want "$SYC" t -q "-p$pw" "$f"
  else
    check "syc t $f" $want "$SYC" t -q "$f" </dev/null
  fi
done

# --raw: one bare sylz block, back with --size
size=$(wc -c < "$first")
check "c --raw -ec" 0 "$SYC" c -q -f --raw -ec -5 -o raw.blk "$first"
check "t --raw" 0 "$SYC" t -q --raw --size "$size" raw.blk
check "d --raw" 0 "$SYC" d -q -f --raw --size "$size" -o raw.out raw.blk
cmp -s raw.out "$first" || { echo "FAIL: --raw round trip"; fail=1; }
check "d --raw, wrong size" 3 "$SYC" d -q -f --raw --size "$((size + 1))" -o raw.out raw.blk
check "d --raw without --size" 2 "$SYC" d -q --raw raw.blk

# refusals
echo notanarchive > fake.syc
check "a on a file that is not an archive" 3 "$SYC" a fake.syc tree
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
