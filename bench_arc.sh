#!/usr/bin/env bash
# syc vs ARC.exe (FreeArc 0.67.1 via wine).
# Mission: beat ARC in (ratio) AND (decompression speed).
set -e
export LC_ALL=C
export WINEDEBUG=-all
DATA="${1:-/usr/share/doc/python3.13}"
WORK="${WORK:-/home/forum/bench_scratch/syc_vs_arc}"
SYC="$(dirname "$(readlink -f "$0")")/target/release/syc"
ARC="/home/forum/git/syc/Arc.exe"

mkdir -p "$WORK"
rm -f "$WORK"/*.arc "$WORK"/*.syc
rm -rf "$WORK"/restore

DATA_BYTES=$(du -sb "$DATA" 2>/dev/null | awk '{print $1}')
DATA_MIB=$(awk -v b="$DATA_BYTES" 'BEGIN{printf "%.1f", b/1048576}')
echo "Dataset: $DATA   ($DATA_MIB MiB, $DATA_BYTES B)"

now()  { date +%s.%N; }
elap() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }

measure() {
    # $1=label $2=out-file $3..=command
    local label="$1"; local out="$2"; shift 2
    sync
    local t0 t1 dt sz ratio mbps
    t0=$(now)
    "$@" >/dev/null 2>&1
    t1=$(now)
    dt=$(elap "$t0" "$t1")
    sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
    ratio=$(awk -v s="$sz" -v b="$DATA_BYTES" 'BEGIN{if(b>0)printf "%.3f", s/b; else print "-"}')
    mbps=$(awk -v b="$DATA_BYTES" -v t="$dt" 'BEGIN{if(t>0)printf "%.1f", (b/1048576)/t; else print "-"}')
    printf "%-30s  c=%6ss  %6s MiB/s  out=%10d  ratio=%s\n" "$label" "$dt" "$mbps" "$sz" "$ratio"
    # stash for later decomp
    echo "$label|$out|$sz|$dt|$ratio" >> "$WORK/artifacts.txt"
}

measure_decomp() {
    local label="$1"; local archive="$2"; shift 2
    rm -rf "$WORK/restore"; mkdir -p "$WORK/restore"
    sync
    local t0 t1 dt mbps
    t0=$(now)
    "$@" >/dev/null 2>&1
    t1=$(now)
    dt=$(elap "$t0" "$t1")
    mbps=$(awk -v b="$DATA_BYTES" -v t="$dt" 'BEGIN{if(t>0)printf "%.1f", (b/1048576)/t; else print "-"}')
    printf "%-30s  d=%6ss  %6s MiB/s\n" "$label" "$dt" "$mbps"
}

rm -f "$WORK/artifacts.txt"

echo
echo "=========== COMPRESSION ==========="
# ARC -m1 .. -m9 + -mx, always with -mt4
for M in 1 2 3 4 5 6 7 8 9 x; do
    OUT="$WORK/arc_m${M}.arc"
    measure "ARC -m${M} -mt4" "$OUT" \
        wine "$ARC" a -m${M} -mt4 "$OUT" "$DATA"
done

# syc: level 1/3/5/9 at -threads 4 (niveles válidos 0..=10; 5 es sweet-spot lzma)
for L in 1 3 5 9; do
    OUT="$WORK/syc_l${L}.syc"
    measure "syc -level ${L} -threads 4" "$OUT" \
        "$SYC" a "$OUT" "$DATA" -level "$L" -threads 4
done

echo
echo "=========== DECOMPRESSION ==========="
for M in 1 3 5 7 9 x; do
    ARCV="$WORK/arc_m${M}.arc"
    [ -f "$ARCV" ] && measure_decomp "ARC x (m${M})" "$ARCV" \
        wine "$ARC" x -o+ -dp"$WORK/restore" "$ARCV"
done
for L in 1 3 5 9; do
    SYCV="$WORK/syc_l${L}.syc"
    [ -f "$SYCV" ] && measure_decomp "syc x (l${L})" "$SYCV" \
        "$SYC" x "$SYCV" -to "$WORK/restore"
done

echo
echo "Artifacts: $WORK"
