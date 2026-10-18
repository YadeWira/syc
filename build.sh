#!/bin/sh
# Builds the syc CLI and the sylz benchmark into out/.
# Usage: [FPC=compiler] ./build.sh [extra fpc options]
#   ./build.sh -Twin64                       Windows x86-64
#   ./build.sh -dSYLZ_PUREPASCAL             no assembler
#   FPC=ppcross386 ./build.sh -Twin32        Windows 32-bit (cross compiler)
#   FPC=ppcrossa64 ./build.sh -XPaarch64-linux-gnu-   Linux arm64
set -e
cd "$(dirname "$0")"
FPC=${FPC:-fpc}
mkdir -p out/units
for prog in src/syc.pas bench/sylzbench.pas; do
  "$FPC" -O3 -XX -Xs -CX -vewn -FUout/units -Fusrc -FEout "$@" "$prog"
done
