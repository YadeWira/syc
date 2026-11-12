#!/bin/sh
# Builds the syc CLI and the sylz benchmark into out/.
# Usage: [FPC=compiler] [CC=c-compiler] ./build.sh [extra fpc options]
#   ./build.sh -Twin64                       Windows x86-64
#   ./build.sh -dSYLZ_PUREPASCAL             no assembler, no C
#   FPC=ppcross386 ./build.sh -Twin32        Windows 32-bit (cross compiler)
#   FPC=ppcrossa64 ./build.sh -XPaarch64-linux-gnu-   Linux arm64
# src/sylzc.c is compiled with the target's C compiler (gcc, mingw,
# aarch64-linux-gnu-gcc, picked from the options above; CC overrides).
set -e
cd "$(dirname "$0")"
FPC=${FPC:-fpc}
. ./build-c.sh
mkdir -p out/units
build_c out/units "$@"
# what syc -V and syc report say it was built from (src/sycbuild.pas, compiled
# again each time); SYC_COMMIT in the environment overrides, for a build
# outside a git checkout
if [ -z "$SYC_COMMIT" ]; then
  SYC_COMMIT=$(git rev-parse --short=12 HEAD 2>/dev/null) || SYC_COMMIT=unknown
  SYC_COMMIT_DATE=$(git log -1 --format=%cs 2>/dev/null) || SYC_COMMIT_DATE=unknown
  [ "$SYC_COMMIT" = unknown ] || git diff --quiet HEAD 2>/dev/null ||
    SYC_COMMIT="$SYC_COMMIT, with changes"
fi
export SYC_COMMIT SYC_COMMIT_DATE="${SYC_COMMIT_DATE:-unknown}"
rm -f out/units/sycbuild.*
for prog in src/syc.pas bench/sylzbench.pas; do
  "$FPC" -O3 -XX -Xs -CX -vewn -FUout/units -Foout/units -Fusrc -FEout "$@" "$prog"
done
