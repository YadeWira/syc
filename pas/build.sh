#!/bin/sh
# Builds the sylz benchmark. Usage: ./build.sh [extra fpc options]
set -e
cd "$(dirname "$0")"
mkdir -p out/units
fpc -O3 -XX -Xs -CX -vewn -FUout/units -Fusrc -FEout "$@" bench/sylzbench.pas
