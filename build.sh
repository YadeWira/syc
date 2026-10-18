#!/bin/sh
# Builds the syc CLI and the sylz benchmark into out/.
# Usage: ./build.sh [extra fpc options]   (e.g. -dSYLZ_PUREPASCAL, -Twin64)
set -e
cd "$(dirname "$0")"
mkdir -p out/units
for prog in src/syc.pas bench/sylzbench.pas; do
  fpc -O3 -XX -Xs -CX -vewn -FUout/units -Fusrc -FEout "$@" "$prog"
done
