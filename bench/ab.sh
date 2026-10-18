#!/bin/sh
# A/B comparison of two sylzbench builds on the same CPU, alternating
# runs so both see the same machine load; prints the best compress and
# decompress speed of each, and the ratio.
#
# Usage: bench/ab.sh A B LEVELS FILE... (env: CPU=20 ROUNDS=3 T=1 FLAGS=)
#   A, B    sylzbench binaries (or "env VAR=x path" wrapped in quotes)
#   LEVELS  comma-separated, as for sylzbench -l
set -e
a=$1; b=$2; levels=$3; shift 3
cpu=${CPU:-20}; rounds=${ROUNDS:-3}; t=${T:-1}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for f in "$@"; do
  r=1
  while [ $r -le "$rounds" ]; do
    for side in A B; do
      [ $side = A ] && cmd=$a || cmd=$b
      # shellcheck disable=SC2086
      taskset -c "$cpu" $cmd $FLAGS -l "$levels" -t "$t" "$f" | tail -n +2 >> "$tmp/$side"
    done
    r=$((r + 1))
  done
done
for side in A B; do
  echo "== $side"
  # best compress / decompress per (level, file); ratio is the same each run
  awk '{ key = $2 " " $9; c = $3; d = $5;
         if (c > bc[key]) bc[key] = c; if (d > bd[key]) bd[key] = d; ratio[key] = $8 }
       END { for (k in bc) printf "  level %-14s compress %8.2f  decompress %8.2f  ratio %6.2f\n", k, bc[k], bd[k], ratio[k] }' "$tmp/$side" | sort -k2,2n -k3
done
