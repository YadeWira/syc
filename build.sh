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
for prog in src/syc.pas bench/sylzbench.pas; do
  "$FPC" -O3 -XX -Xs -CX -vewn -FUout/units -Foout/units -Fusrc -FEout "$@" "$prog"
done
