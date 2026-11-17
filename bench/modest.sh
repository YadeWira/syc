#!/bin/bash
# modest.sh — what each level costs on one core: speed and peak memory of
# syc c / d (every level, with and without -ec; d writes to /dev/null:
# put WORK on a RAM disk for the streams), of syc a / x with 1, 2
# and 4 threads, of the block size, and of the password's key (Argon2id).
# Peak memory and speeds are syc's own (--stats: the process's peak
# resident set, VmHWM on Linux, PeakWorkingSetSize on Windows).
#   bench/modest.sh SYC INPUT DIR WORK [RUNNER...]
# SYC: the binary; INPUT: one file (silesia.tar); DIR: a tree for a / x
# (silesia/); WORK: scratch (archives, extracted trees); RUNNER: what runs
# syc (taskset -c 20, qemu-aarch64, ...); AWORK: scratch for a / x (default
# WORK). Writes tab-separated tables on
# stdout. PARTS=cabkp picks the parts (default all): c = streams, a =
# archives, b = block size, k = the key, p = the plain levels only.
set -u
SYC=$1 IN=$2 DIR=$3 WORK=$4
shift 4
RUN=("$@")
PARTS=${PARTS:-cabk}
AWORK=${AWORK:-$WORK}   # for a / x (a disk: what they write is bigger)
mkdir -p "$WORK" "$AWORK"
size=$(wc -c < "$IN")

# runs syc with --stats; prints "seconds MB/s peakMiB ratio%": the speed
# of the raw data (c: in, d: out)
stats() {
  local err
  err=$("${RUN[@]}" "$SYC" "$@" --stats 2>&1 >/dev/null)
  local rc=$?
  [ $rc -eq 0 ] || { echo "FAILED ($rc): $* : $err" >&2; echo "- - - -"; return; }
  awk '
    /^  time /        { t = $2 }
    /^  speed /       { si = $2; so = $5 }
    /^  peak memory / { m = $3; if ($4 == "GiB") m *= 1024; if ($4 == "KiB") m /= 1024 }
    /^  ratio /       { r = $2; sub("%", "", r) }
    END { printf "%s %s %s %s\n", t, (cmd == "d" ? so : si), m, r }' cmd="$1" <<< "$err"
}

if [[ $PARTS == *c* ]]; then
  echo "# streams: syc c / d, -t 1, $(basename "$IN") ($size bytes), default block (4 MiB)"
  printf 'level\tratio%%\tc MB/s\tc MiB\td MB/s\td MiB\n'
  for ec in "" -ec; do
    [[ $PARTS == *p* && -n $ec ]] && continue
    for l in 0 1 2 3 4 5 6 7 8 9 10; do
      read -r _ cs cm r < <(stats c -q -f -t 1 $ec -$l -o "$WORK/s.sylz" "$IN")
      read -r _ ds dm _ < <(stats d -q -t 1 -O "$WORK/s.sylz")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${ec:+-ec }-$l" "$r" "$cs" "$cm" "$ds" "$dm"
    done
  done
  rm -f "$WORK/s.sylz"
  echo
fi

if [[ $PARTS == *b* ]]; then
  echo "# block size: syc c -b N, -t 1 (peak MiB)"
  printf 'level'; for b in 1 4 16 64; do printf '\t-b %s' $b; done; echo
  for l in -1 -5 -9 "-ec -9"; do
    printf '%s' "$l"
    for b in 1 4 16 64; do
      # shellcheck disable=SC2086
      read -r _ _ m _ < <(stats c -q -f -t 1 $l -b $b -o "$WORK/s.sylz" "$IN")
      printf '\t%s' "$m"
    done
    echo
  done
  rm -f "$WORK/s.sylz"
  echo
fi

if [[ $PARTS == *a* ]]; then
  echo "# archives: syc a / x of $(basename "$DIR")/, default block (16 MiB)"
  printf 'level\tthreads\ta s\ta MiB\tx s\tx MiB\n'
  for l in -1 -5 -9 "-ec -9"; do
    for t in 1 2 4; do
      rm -rf "$AWORK/a.syc" "$AWORK/x"
      # shellcheck disable=SC2086
      read -r as _ am _ < <(stats a -q -t $t $l "$AWORK/a.syc" -C "$(dirname "$DIR")" "$(basename "$DIR")")
      read -r xs _ xm _ < <(stats x -q -t $t -o "$AWORK/x" "$AWORK/a.syc")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$l" $t "$as" "$am" "$xs" "$xm"
    done
  done
  rm -rf "$AWORK/a.syc" "$AWORK/x"
  echo
fi

if [[ $PARTS == *k* ]]; then
  echo "# the key: syc t -p of a small stream, Argon2id --kdf-mem N (t = 3, one lane)"
  printf 'MiB\tseconds\tpeak MiB\n'
  head -c 100000 "$IN" > "$WORK/k.bin"
  for k in 8 64 256; do
    SYC_PASSWORD=bench "${RUN[@]}" "$SYC" c -q -f -p --kdf-mem $k -o "$WORK/k.sylz" "$WORK/k.bin"
    read -r ks _ km _ < <(SYC_PASSWORD=bench stats t -q "$WORK/k.sylz")
    printf '%s\t%s\t%s\n' $k "$ks" "$km"
  done
  rm -f "$WORK/k.bin" "$WORK/k.sylz"
fi
