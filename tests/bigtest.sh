#!/bin/bash
# Files over 4 GiB: a stream and an archive of a 4.6 GB file (random
# bytes, then text), both ways, unencrypted and encrypted; a second
# version appended past 4 GiB; pipes; syc t. Not in CI (it needs about
# 14 GB of disk): run by hand, above all with the 32-bit binaries
# (linux-i386; windows-i386 through wine with a wrapper script).
#   tests/bigtest.sh SYC WORKDIR
set -u
S=$1; D=$2
mkdir -p "$D/in" && cd "$D" || exit 2
if [ ! -f big.sha ]; then
  { head -c 4400000000 /dev/urandom
    python3 -c "
import random, sys
r = random.Random(4)
w = 'the archive keeps every version of every file that was added to it'.split()
sys.stdout.write(' '.join(r.choice(w) for _ in range(45000000)))" | head -c 211957760
  } > in/big.bin
  sha256sum in/big.bin | cut -c1-64 > big.sha
fi
W=$(cat big.sha); bad=0
ok() { if [ "$2" = 0 ] || [ "$2" = OK ]; then echo "  $1"; else echo "FAIL: $1: $2"; bad=1; fi; }
sha() { [ "$(sha256sum | cut -c1-64)" = "$W" ] && echo OK || echo 'not the same data'; }

"$S" c -q -f -o b.sylz in/big.bin; ok 'c' $?
ok 'd' "$("$S" d -q -O b.sylz | sha)"
ok 'd from stdin' "$("$S" d -q < b.sylz | sha)"
ok 'c from stdin' "$(cat in/big.bin | "$S" c -q - | "$S" d -q | sha)"
rm -f b.sylz

"$S" a -q b.syc in; ok 'a' $?
printf 'version 2\n' > in/small.txt
"$S" a -q b.syc in; ok 'a, a second version past 4 GiB' $?
rm in/small.txt
"$S" t -q b.syc; ok 't' $?
"$S" l -l b.syc | grep -q ' 4611957760 '; ok 'l -l: the size' $?
rm -rf ex; "$S" x -q -u 1 -o ex b.syc; ok 'x' $?
ok 'x: the data' "$(sha < ex/in/big.bin)"
rm -rf ex; "$S" x -q -o ex b.syc in/small.txt; ok 'x version 2' $?
grep -qx 'version 2' ex/in/small.txt; ok 'x version 2: the data' $?
rm -rf ex b.syc
ok 'a to stdout' "$("$S" a -q - in | "$S" t -q - >/dev/null 2>&1; echo $?)"

"$S" c -q -f -pbig --kdf-mem 8 -o e.sylz in/big.bin; ok 'c -p' $?
ok 'd -p' "$("$S" d -q -pbig -O e.sylz | sha)"
rm -f e.sylz
"$S" a -q -pbig --kdf-mem 8 e.syc in; ok 'a -p' $?
"$S" t -q -pbig e.syc; ok 't -p' $?
rm -rf ex; "$S" x -q -pbig -o ex e.syc; ok 'x -p' $?
ok 'x -p: the data' "$(sha < ex/in/big.bin)"
rm -rf ex e.syc

[ $bad = 0 ] && echo 'bigtest: all passed' || echo 'bigtest: FAILED'
exit $bad
