#!/bin/sh
# Builds the zpaq-std plugin: out/plugin/<target>/sylz.so or sylz.dll.
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
  linux-x86_64) opts="-Cg";                       lib=libsylz_zpaqstd.so; out=sylz.so ;;
  linux-arm64)  opts="-Cg -XPaarch64-linux-gnu-"; lib=libsylz_zpaqstd.so; out=sylz.so ;;
  win64)        opts="-Twin64";                   lib=sylz_zpaqstd.dll;   out=sylz.dll ;;
  win32)        opts="-Twin32";                   lib=sylz_zpaqstd.dll;   out=sylz.dll ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac
dir=out/plugin/$target
mkdir -p "$dir/units"
. ./build-c.sh
# shellcheck disable=SC2086
build_c "$dir/units" $opts "$@"
"$FPC" -O3 -XX -Xs -vewn $opts -Fusrc -FU"$dir/units" -Fo"$dir/units" -FE"$dir" "$@" plugin/sylz_zpaqstd.pas
mv -f "$dir/$lib" "$dir/$out"
echo "$dir/$out"
