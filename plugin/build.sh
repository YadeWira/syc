#!/bin/sh
# Builds the zpaq-std plugins: out/plugin/<target>/sylz.so and sylzec.so
# (or .dll): sylz is format v2, sylzec format v3.
# Usage: [FPC=compiler] plugin/build.sh TARGET [extra fpc options]
#   linux-x86_64                   (default compiler)
#   win64        -> -Twin64
#   win32        FPC=ppcross386 plugin/build.sh win32 -Fu<rtl>/units/i386-win32
#   linux-arm64  FPC=ppcrossa64 plugin/build.sh linux-arm64 -Fu<rtl>/units/aarch64-linux
set -e
cd "$(dirname "$0")/.."
FPC=${FPC:-fpc}
target=${1:-linux-x86_64}
[ $# -gt 0 ] && shift
case $target in
  linux-x86_64) opts="-Cg";                       pre=lib; ext=so ;;
  linux-arm64)  opts="-Cg -XPaarch64-linux-gnu-"; pre=lib; ext=so ;;
  win64)        opts="-Twin64";                   pre=;    ext=dll ;;
  win32)        opts="-Twin32";                   pre=;    ext=dll ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac
dir=out/plugin/$target
mkdir -p "$dir/units"
. ./build-c.sh
# shellcheck disable=SC2086
build_c "$dir/units" $opts "$@"
# one file, both codecs: sylz (format v2) and sylzec (format v3)
"$FPC" -O3 -XX -Xs -vewn $opts -Fusrc -Fuplugin -FU"$dir/units" -Fo"$dir/units" -FE"$dir" "$@" \
  plugin/sylz_zpaqstd.pas
mv -f "$dir/${pre}sylz_zpaqstd.$ext" "$dir/sylz.$ext"
echo "$dir/sylz.$ext"
