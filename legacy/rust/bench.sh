#!/usr/bin/env bash
# Benchmark honesto: syc vs tar+zstd en tu máquina.
# Uso: ./bench.sh <dataset-dir>
set -e
export LC_ALL=C
DATA="${1:-/usr/share/doc}"
WORK="${WORK:-/tmp/syc_bench}"
SYC="$(dirname "$(readlink -f "$0")")/target/release/syc"

mkdir -p "$WORK"
rm -f "$WORK"/*.bin "$WORK"/*.syc

echo "Dataset: $DATA"
du -sh "$DATA" 2>/dev/null | head -1
DATA_BYTES=$(du -sb "$DATA" 2>/dev/null | awk '{print $1}')

run() {
    local label="$1"; shift
    local out="$1"; shift
    # drop caches NOT attempted (requires root); rely on same file system
    local t0 t1 elapsed size mbps ratio
    sync
    t0=$(date +%s.%N)
    "$@" >/dev/null 2>&1
    t1=$(date +%s.%N)
    elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
    size=$(stat -c%s "$out" 2>/dev/null || echo 0)
    mbps=$(awk -v b="$DATA_BYTES" -v t="$elapsed" 'BEGIN{printf "%.1f", (b/1048576)/t}')
    ratio=$(awk -v s="$size" -v b="$DATA_BYTES" 'BEGIN{printf "%.3f", s/b}')
    printf "%-32s  %8.2f s  %7.1f MiB/s  %10d B  ratio %s\n" \
        "$label" "$elapsed" "$mbps" "$size" "$ratio"
}

echo "--- compress ---"
for L in 3 9 19; do
    for J in 1 4; do
        OUT="$WORK/tar_zstd_l${L}_j${J}.bin"
        run "tar | zstd -${L} -T${J}"       "$OUT" \
            bash -c "tar -C '$(dirname "$DATA")' -cf - '$(basename "$DATA")' | zstd -${L} -T${J} -q -o '$OUT'"

        OUT="$WORK/syc_l${L}_j${J}.syc"
        run "syc  a  -level ${L} -threads ${J}"  "$OUT" \
            "$SYC" a "$OUT" "$DATA" -level "$L" -threads "$J"
    done
done

echo
echo "--- decompress (level 9, j=4 archive) ---"
REST="$WORK/restore"
rm -rf "$REST"; mkdir -p "$REST"
run "tar | zstd -d"    "$REST/done.flag" \
    bash -c "zstd -d -q < '$WORK/tar_zstd_l9_j4.bin' | tar -C '$REST' -xf - && touch '$REST/done.flag'"

rm -rf "$REST"; mkdir -p "$REST"
run "syc  x"            "$REST/done.flag" \
    bash -c "'$SYC' x '$WORK/syc_l9_j4.syc' -to '$REST' && touch '$REST/done.flag'"

echo
echo "Artifacts in $WORK"
