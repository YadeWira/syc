#!/bin/bash
# Writes tests/compat/: streams and archives written by released syc
# versions, one for each format they wrote, and MANIFEST.json, what each
# must read as (the SHA-256 of a stream's data; of every file of an
# archive, per version). CI checks that this syc still reads them all
# (tests/compat/check.py). Run once, from the repository root, with the
# release binaries (Linux x86-64) of the versions below in OLDBINS
# (syc-vX.Y.Z); the files it writes are committed and never regenerated:
# they are what those versions wrote.
#   OLDBINS=/path/to/bins bash tests/compat/make.sh
set -euo pipefail
B=${OLDBINS:?OLDBINS: the directory with syc-vX.Y.Z}
out=$PWD/tests/compat
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# the data: text (compressible), random bytes, a repeat (for matches
# across files and for deduplication), an empty file
python3 - <<'EOF'
import os, random
r = random.Random(1015)
words = ('the archive keeps every version of every file that was added to it and '
         'each fragment once however many files hold it sylz blocks compress '
         'quickly on modest hardware').split()
text = ' '.join(r.choice(words) for _ in range(5000)).encode()
rnd = bytes(r.getrandbits(8) for _ in range(3000))
os.makedirs('v1/tree/sub', exist_ok=True)
open('v1/tree/text.txt', 'wb').write(text)
open('v1/tree/random.bin', 'wb').write(rnd)
open('v1/tree/sub/again.txt', 'wb').write(text[:8000] + rnd[:500])
open('v1/tree/empty', 'wb').write(b'')
open('data', 'wb').write(text + rnd + text[:10000])
EOF
cp -r v1 v2
printf 'added in version 2\n' > v2/tree/sub/new.txt
python3 -c "import sys; d=open('v2/tree/text.txt','rb').read(); open('v2/tree/text.txt','wb').write(d[:5000]+b'changed'+d[5000:])"
rm v2/tree/random.bin
touch -d '2026-01-02 03:04:05' v1/tree/* v1/tree/sub/* v2/tree/* v2/tree/sub/* v1/tree/sub v2/tree/sub v1/tree v2/tree

rm -rf "$out"/*.sylz "$out"/*.syc
stream() {   # stream NAME VERSION ARGS...   (0.2.x: c ARGS INPUT OUTPUT)
  local name=$1 v=$2; shift 2
  case $v in
    v0.2.*) "$B/syc-$v" c "$@" data "$out/$name.sylz" >/dev/null ;;
    *) "$B/syc-$v" c -q -f "$@" -o "$out/$name.sylz" data ;;
  esac
}
archive() {  # archive NAME VERSION ARGS...   (two versions: v1, then v2)
  local name=$1 v=$2; shift 2
  (cd v1 && "$B/syc-$v" a -q "$@" "$out/$name.syc" tree)
  # (the second version without what only a new archive takes)
  local later=() skip=0 x
  for x in "$@"; do
    if [ $skip = 1 ]; then skip=0; continue; fi
    case $x in --visible-names) continue ;; --kdf-mem) skip=1; continue ;; esac
    later+=("$x")
  done
  (cd v2 && "$B/syc-$v" a -q "${later[@]}" "$out/$name.syc" tree)
}
pw=compat
stream s-0.2.2 v0.2.2                         # stream version 1, sylz v2
stream s-0.2.5-e v0.2.5 -e                    # version 2, sylz v3 chunks of mode 1
stream s-0.2.13-ec v0.2.13 -ec -9             # version 2
stream s-0.2.14 v0.2.14 -5                    # version 3
stream s-0.2.14-ec v0.2.14 -ec                # version 3, v3 chunks of mode 2
archive a-0.3.4 v0.3.4                        # archive format 1
stream s-0.3.4-ec v0.3.4 -ec -10
archive a-0.4.2 v0.4.2                        # archive format 2, codec 1
stream s-0.4.2 v0.4.2 -3                      # stream version 4
archive a-0.5.4-enc v0.5.4 -p$pw --kdf-mem 8  # archive format 3
archive a-0.5.4-encv v0.5.4 -p$pw --kdf-mem 8 --visible-names
stream s-0.5.4-enc v0.5.4 -p$pw --kdf-mem 8   # stream version 5
archive a-0.7.0-F4 v0.7.0 -F 4                # codec 2: sylz v4 (0.7.0's layout, frozen)
stream s-0.7.0-F4-ec v0.7.0 -F 4 -ec -9       # sylz v5
archive a-0.8.0-F4-ec v0.8.0 -F 4 -ec
stream s-0.8.0-F4 v0.8.0 -F 4 -10
archive a-0.9.0 v0.9.0                        # v4 by default
stream s-0.9.0-ec v0.9.0 -ec -4

python3 - "$out" <<'EOF'
import hashlib, json, os, sys
out = sys.argv[1]
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
m = {'password': 'compat',
     'stream': hashlib.sha256(open('data', 'rb').read()).hexdigest(),
     'versions': [state('v1'), state('v2')]}
json.dump(m, open(os.path.join(out, 'MANIFEST.json'), 'w'), indent=1, sort_keys=True)
EOF
ls -l "$out"
