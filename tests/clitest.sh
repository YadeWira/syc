#!/bin/sh
# clitest — the commands and switches about the build and the machine
# (syc b, s, r, i on streams, --stats, --debug, --paths, --color), and
# that what scripts read stays plain. Runs on Unix and under Git Bash.
# Usage: [SYC=path/to/syc] sh tests/clitest.sh SAMPLE WORKDIR
#   SAMPLE: any file of a few hundred kB or more; WORKDIR is created (and
#   removed first if it exists)
SYC=${SYC:-$PWD/out/syc}
sample=$1
work=$2
[ -f "$sample" ] && [ -n "$work" ] || { echo "usage: clitest.sh SAMPLE WORKDIR" >&2; exit 2; }
rm -rf "$work"
mkdir -p "$work/tree/sub"
cp "$sample" "$work/data"
cp "$sample" "$work/tree/one"
cp "$sample" "$work/tree/sub/two"
start=$PWD
cd "$work" || exit 2
fail=0
esc=$(printf '\033')

# check NAME EXPECTED-EXIT command...: runs it, stdout to out.txt, stderr
# to err.txt
check() {
  name=$1; want=$2; shift 2
  "$@" > out.txt 2> err.txt
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: $name: exit $got, expected $want"; sed 's/^/    /' err.txt | head -5; fail=1
  fi
}
# has NAME FILE PATTERN / hasnot: a line of FILE matches (does not match)
has() { grep -q -- "$3" "$2" || { echo "FAIL: $1: no \"$3\" in $2"; sed 's/^/    /' "$2" | head -8; fail=1; }; }
hasnot() { if grep -q -- "$3" "$2"; then echo "FAIL: $1: \"$3\" in $2"; fail=1; fi; }

check "-V" 0 "$SYC" -V
has "-V, the version" out.txt '^syc [0-9]'
has "-V, the build" out.txt '^commit .*Free Pascal .*paths: '
check "the usage screen" 0 "$SYC" -h
has "usage names the new commands" out.txt 'syc b, bench'
for c in a x l i c d t k b s r add extract list info compress decompress test key bench selftest report; do
  check "syc h $c" 0 "$SYC" h $c
  has "syc h $c shows its options" out.txt '^syc [a-z]'
done
check "an unknown command" 2 "$SYC" frobnicate
check "syc s with an operand" 2 "$SYC" s data

# the words do what the letters do
check "compress" 0 "$SYC" compress -q -o w.sylz data
check "c" 0 "$SYC" c -q -o l.sylz data
cmp -s w.sylz l.sylz || { echo "FAIL: syc compress and syc c differ"; fail=1; }
check "test" 0 "$SYC" test -q w.sylz
check "decompress" 0 "$SYC" decompress -q -o back w.sylz
cmp -s back data || { echo "FAIL: decompress does not give the file back"; fail=1; }
check "add" 0 "$SYC" add -q w.syc tree
check "list" 0 "$SYC" list w.syc
has "list" out.txt '^tree/sub/two'
check "extract" 0 "$SYC" extract -q -o ox w.syc
cmp -s ox/tree/sub/two data || { echo "FAIL: extract does not give the file back"; fail=1; }

# the code paths write the same bytes
for p in auto c pascal; do
  check "c --paths $p" 0 "$SYC" c -q -4 --paths $p -o p-$p.sylz data
  check "c -ec --paths $p" 0 "$SYC" c -q -ec -2 --paths $p -o e-$p.sylz data
  check "d --paths $p" 0 "$SYC" d -q -f --paths $p -o back e-auto.sylz
  cmp -s back data || { echo "FAIL: d --paths $p does not give the file back"; fail=1; }
done
cmp -s p-auto.sylz p-pascal.sylz && cmp -s p-auto.sylz p-c.sylz ||
  { echo "FAIL: --paths auto, c and pascal write different streams"; fail=1; }
cmp -s e-auto.sylz e-pascal.sylz && cmp -s e-auto.sylz e-c.sylz ||
  { echo "FAIL: --paths auto, c and pascal write different -ec streams"; fail=1; }
check "SYC_PATHS" 0 env SYC_PATHS=pascal "$SYC" -V
has "SYC_PATHS=pascal in -V" out.txt 'paths: Pascal'
check "a wrong SYC_PATHS" 2 env SYC_PATHS=fastest "$SYC" t -q w.sylz
check "a wrong --paths" 2 "$SYC" t -q --paths fastest w.sylz

# syc i on streams, without a password for an encrypted one
check "i on a stream" 0 "$SYC" i w.sylz
has "i: the header" out.txt 'stream, format version 4, codec sylz, written at level 1; not encrypted'
has "i: the blocks" out.txt '^blocks'
has "i: the raw size" out.txt "^raw size *$(wc -c < data | tr -d ' ') bytes"
check "c -b 1 -pPASSWORD" 0 "$SYC" c -q -b 1 -pclitest --kdf-mem 8 -o enc.sylz data
check "i on an encrypted stream" 0 "$SYC" i -v enc.sylz
has "i: encrypted" out.txt 'format version 5.*encrypted (XChaCha20-Poly1305, key from Argon2id over 8 MiB)'
has "i -v: a line per block" out.txt '^ *0 '
check "i -v on an -ec stream" 0 "$SYC" i -v e-auto.sylz
has "i -v: the blocks' format" out.txt '  sylz v[23]'
check "i on an archive" 0 "$SYC" i w.syc
has "i: the archive's versions" out.txt '^ *1  [0-9][0-9][0-9][0-9]-'
check "i -v on an archive" 0 "$SYC" i -v w.syc
has "i -v: the archive's format" out.txt '^archive format 2, not encrypted'
has "i -v: the version's blocks" out.txt 'block(s): .* new fragment(s); index '
head -c 100 w.sylz > cut.sylz
check "i on a cut stream" 3 "$SYC" i cut.sylz

# --stats, --debug
check "c --stats" 0 "$SYC" c -f --stats -t 2 -o s.sylz data
has "--stats: bytes in" err.txt "^  in  *$(wc -c < data | tr -d ' ') bytes"
has "--stats: threads" err.txt '^  threads  *2'
has "the summary has the time" err.txt 'bytes (.*%), [0-9]'
check "t --stats" 0 "$SYC" t --stats w.syc
has "t --stats on an archive" err.txt '^  out  *[1-9]'
check "x --stats" 0 "$SYC" x -f --stats -o ox2 w.syc
has "x --stats" err.txt '^  time'
check "t on a cut stream" 3 "$SYC" t cut.sylz
hasnot "no debug lines unless asked" err.txt 'debug:'
check "t --debug on a cut stream" 3 "$SYC" t --debug cut.sylz
has "--debug: the error's class" err.txt 'debug: ESycError, exit code 3'
has "--debug: where" err.txt 'debug: while working on cut.sylz'
has "--debug: how to report" err.txt 'syc report'
check "c --debug" 0 "$SYC" c -q -f --debug -o s.sylz data
has "--debug: the phases" err.txt 'debug: .* s  c: read, compress, write'

# colours only when asked (nothing here is a terminal), never in what
# scripts read
check "l" 0 "$SYC" l -l w.syc
hasnot "l -l into a file has no colours" out.txt "$esc"
has "l -l into a file has exact sizes" out.txt " $(wc -c < data | tr -d ' ')  [0-9][0-9][0-9][0-9]-"
check "t, an error" 3 "$SYC" t cut.sylz
hasnot "errors into a file have no colours" err.txt "$esc"
check "t --color always" 3 "$SYC" t --color always cut.sylz
has "--color always colours the error" err.txt "$esc"
check "NO_COLOR with --color always" 3 env NO_COLOR=1 "$SYC" t --color always cut.sylz
has "--color always wins over NO_COLOR" err.txt "$esc"
check "--color never" 3 "$SYC" t --color never cut.sylz
hasnot "--color never" err.txt "$esc"
check "a wrong --color" 2 "$SYC" t --color blue cut.sylz

# syc b
check "b" 0 "$SYC" b --levels 0,2-3 --time 0 data
has "b: a row per level" out.txt '^ *3  *[0-9][0-9]*  *[0-9.]*%  *[0-9.]* MB/s  *[0-9.]* MB/s'
[ "$(grep -c 'MB/s' out.txt)" = 3 ] || { echo "FAIL: b --levels 0,2-3 did not run 3 levels"; cat out.txt; fail=1; }
check "b -ec -N -b" 0 "$SYC" b -ec -1 -b 1 --time 0 data data
[ "$(grep -c 'MB/s' out.txt)" = 2 ] || { echo "FAIL: b -1 on two files did not print 2 rows"; cat out.txt; fail=1; }
has "b -ec" out.txt 'sylz format v3'
check "b on a missing file" 4 "$SYC" b --time 0 no-such-file
check "b, wrong levels" 2 "$SYC" b --levels 3-1 data
check "b without a file" 2 "$SYC" b

# syc s, syc r
check "s" 0 "$SYC" s
has "s: the summary" out.txt '^ok: [0-9]* checks passed'
hasnot "s: nothing failed" out.txt 'FAILED'
has "s: the codec" out.txt '^ok  *sylz format v3 (-ec), text, levels 0-10'
has "s: a stream and an archive" out.txt 'an encrypted archive of two versions written, checked and extracted'
[ ! -s err.txt ] || { echo "FAIL: syc s wrote to stderr:"; head -5 err.txt; fail=1; }
check "s -q --paths pascal" 0 "$SYC" s -q --paths pascal
[ "$(grep -c . out.txt)" = 1 ] || { echo "FAIL: s -q is more than its summary"; cat out.txt; fail=1; }
check "r" 0 env SYC_PASSWORD=clitest-secret-value SYC_PATHS=auto "$SYC" r
for row in version commit compiler target 'paths built' 'paths in use' system cpu memory terminal environment self-test; do
  has "r: $row" out.txt "^$row "
done
has "r: the self-test's result" out.txt '^self-test  *ok: [0-9]* checks passed'
has "r: the variables' names" out.txt 'SYC_PASSWORD'
hasnot "r: never a variable's value" out.txt 'clitest-secret-value'
has "r: where to report" out.txt 'github.com/YadeWira/syc/issues'

cd "$start" || exit 2
[ "$fail" = 0 ] && echo "clitest: all ok" && rm -rf "$work"
exit $fail
