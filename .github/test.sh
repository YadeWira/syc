#!/bin/sh
# CI: builds the test programs next to out/syc and runs them, then writes
# hash.txt: the SHA-256 of what syc compresses from a fixed sample (streams
# and raw blocks, both codecs, every level), which must be the same on
# every platform.  Usage: sh .github/test.sh   (FPC: the compiler; FPCOPTS:
# the options out/syc was built with; WINDOWS=1: only the tests that run
# there; PYTHON: python3 by default)
set -e
FPC=${FPC:-fpc}
PY=${PYTHON:-python3}
SYC=$PWD/out/syc
W=$PWD/out/ci
rm -rf "$W"
mkdir -p "$W"

tests="cryptotest sycdedup sylzedge"
[ -n "$WINDOWS" ] || tests="$tests sylzfuzz"   # sylzfuzz: guard pages via mmap
for t in $tests; do
  # shellcheck disable=SC2086
  "$FPC" -O3 -vewn $FPCOPTS -Fusrc -FUout/units -Foout/units -FEout "tests/$t.pas" >/dev/null
done

echo '== cryptotest: the RFC vectors'
out/cryptotest
echo '== cryptotest against hashlib, cryptography, libsodium and Argon2 (C, then Pascal)'
out/cryptotest --dump 100 | "$PY" tools/crypto_xcheck.py
out/cryptotest --dump 50 pascal | "$PY" tools/crypto_xcheck.py
echo '== sycdedup'
out/sycdedup
echo '== sylzedge'
out/sylzedge
SYLZ_NOASM=1 out/sylzedge

"$PY" .github/sample.py "$W/sample"
if [ -z "$WINDOWS" ]; then
  echo '== sylzfuzz'
  out/sylzfuzz 300 "$W/sample" src/*.pas
  echo '== arctest'
  cp -r src "$W/samples"
  cp "$W/sample" "$W/samples/sample.bin"
  SYC=$SYC sh tests/arctest.sh "$W/samples" "$W/arctest"
  echo '== vectors, read back by the reference reader'
  "$PY" tests/syc_vectors.py "$SYC" "$W/vectors" "$W/sample" >/dev/null
  "$PY" tools/syc_ref.py --check "$W/vectors"
fi

echo '== the zpaq-std plugin, loaded as zpaq-std does (both codecs)'
# shellcheck disable=SC2086
pt=$("$FPC" $FPCOPTS -iTO)-$("$FPC" $FPCOPTS -iTP)
tcc="cc -O2 -pthread"
case $pt in
  linux-x86_64) pt=linux-x86_64; lib=sylz.so; tcc="$tcc -ldl" ;;
  linux-aarch64) pt=linux-arm64-native; lib=sylz.so; tcc="$tcc -ldl" ;;
  linux-i386) pt=linux-i386; lib=sylz.so; tcc="gcc -m32 -msse -O2 -pthread -ldl" ;;
  darwin-aarch64) pt=macos-arm64; lib=sylz.dylib ;;
  win64-x86_64) pt=win64; lib=sylz.dll; tcc="gcc -O2" ;;
  win32-i386) pt=win32; lib=sylz.dll; tcc="gcc -O2" ;;
  *) echo "no plugin target for $pt" >&2; exit 1 ;;
esac
# shellcheck disable=SC2086
plugin/build.sh "$pt" $FPCOPTS >/dev/null
# shellcheck disable=SC2086
$tcc plugin/test_plugin.c -o out/test_plugin
"$PY" -c 'import sys; open(sys.argv[2], "wb").write(open(sys.argv[1], "rb").read()[:1000000])' \
  "$W/sample" "$W/psample"
for codec in 0 1; do
  out/test_plugin --codec $codec "out/plugin/$pt/$lib" "$W/psample" src/sylz.pas
done

echo '== the same bytes: streams and raw blocks, sylz and sylzec, every level'
for L in 0 1 2 3 4 5 6 7 8 9 10; do
  for ec in '' -ec; do
    for raw in '' --raw; do
      # shellcheck disable=SC2086
      "$SYC" c -q -f $raw $ec -$L -o "$W/c" "$W/sample"
      [ -n "$raw" ] || { "$SYC" d -q -f -o "$W/d" "$W/c"; cmp "$W/d" "$W/sample"; }
      "$PY" -c 'import hashlib,sys; f,n=sys.argv[1:]; print(hashlib.sha256(open(f,"rb").read()).hexdigest(), n)' \
        "$W/c" "-$L$ec$raw" >> "$W/hashes"
    done
  done
done
# (without the CRs Python's print writes on Windows)
"$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read().replace(b"\r",b"")).hexdigest())' \
  "$W/hashes" > hash.txt
cat "$W/hashes"
echo "all: $(cat hash.txt)"
