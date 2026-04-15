#!/usr/bin/env bash
# Sweep LZMA params on python3.13 docs to find best config for l5-l9.
# Target: beat ARC -m5 (0.146) for l5, move toward -m9 (0.139) for l6+.
set -e
export LC_ALL=C
DATA=/usr/share/doc/python3.13
WORK=/tmp/syc_sweep
SYC=/home/forum/git/syc/target/release/syc
mkdir -p $WORK
rm -f $WORK/*.syc
DB=$(du -sb $DATA | awk '{print $1}')
LOG=$WORK/sweep.log
: > $LOG

run() {
    local label="$1"; shift
    local out=$WORK/$label.syc
    rm -f $out
    local t0 t1 sz r e
    t0=$(date +%s.%N)
    "$@" $SYC a $out $DATA -level 5 -threads 4 >/dev/null 2>&1
    t1=$(date +%s.%N)
    sz=$(stat -c%s $out 2>/dev/null || echo 0)
    r=$(awk -v s=$sz -v b=$DB 'BEGIN{printf "%.4f", s/b}')
    e=$(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.0f", b-a}')
    printf "%-40s  ratio=%s  comp=%ss  size=%s\n" "$label" "$r" "$e" "$sz" | tee -a $LOG
}

echo "Dataset: $DATA ($DB B)" | tee -a $LOG
echo "Baseline ARC -m5 = 0.146, -m6..m9/mx = 0.139" | tee -a $LOG
echo "Current syc -l5 = 0.1479 (dict=64M, lc=4, lp=0, pb=0, nice=273)" | tee -a $LOG
echo "" | tee -a $LOG

# Sweep: dict x lc x pb, nice=273 fixed
for dict_mib in 128 256; do
    for lc in 3 4; do
        for pb in 0 1 2; do
            dict_b=$(($dict_mib * 1024 * 1024))
            run "d${dict_mib}_lc${lc}_pb${pb}" env SYC_DICT=$dict_b SYC_LC=$lc SYC_PB=$pb SYC_NICE=273
        done
    done
done

# Also try nice=192 (faster compression, slight ratio loss) and nice=128
for nice in 128 192; do
    run "d128_lc4_pb0_nice${nice}" env SYC_DICT=$((128*1024*1024)) SYC_LC=4 SYC_PB=0 SYC_NICE=$nice
done

echo "" | tee -a $LOG
echo "Results saved to $LOG" | tee -a $LOG
