#!/usr/bin/env python3
"""Reference for the syc archive's fragments, written from the wiki's
"syc archive format" page (section Fragments): the cut points and each
fragment's BLAKE2s-256.

  syc_cdc_ref.py FILE                      print: offset length blake2s
  syc_cdc_ref.py --check FILE DUMP         compare with `sycdedup --dump FILE`
"""
import hashlib
import sys

MASK64 = (1 << 64) - 1


def gear_table():
    state = 0x5359434143444331  # "SYCACDC1"
    gear = []
    for _ in range(256):
        state = (state + 0x9E3779B97F4A7C15) & MASK64
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        gear.append(z ^ (z >> 31))
    return gear


GEAR = gear_table()


def cut(data, s, min_log=14, avg_log=16, max_log=19):
    """length of the fragment starting at s"""
    mn, avg, mx = 1 << min_log, 1 << avg_log, 1 << max_log
    n = len(data) - s
    if n <= mn:
        return n
    h = 0
    i = mn
    lim = min(n, mx)
    while i < lim:
        h = ((h << 1) + GEAR[data[s + i]]) & MASK64
        i += 1
        bits = avg_log + 2 if i < avg else avg_log - 2
        if h >> (64 - bits) == 0:
            return i
    return lim


def fragments(data):
    s = 0
    while s < len(data):
        n = cut(data, s)
        yield s, n, hashlib.blake2s(data[s:s + n]).hexdigest()
        s += n


def main():
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "--check":
        data = open(args[1], "rb").read()
        want = [tuple(l.split()) for l in open(args[2]) if l.strip()]
        got = [(str(o), str(n), h) for o, n, h in fragments(data)]
        if got != want:
            for k, (a, b) in enumerate(zip(got, want)):
                if a != b:
                    print("fragment %d differs: reference %s, dump %s" % (k, a, b))
                    break
            else:
                print("fragment counts differ: reference %d, dump %d" % (len(got), len(want)))
            sys.exit(1)
        print("ok: %d fragments match" % len(got))
    elif len(args) == 1:
        for o, n, h in fragments(open(args[0], "rb").read()):
            print(o, n, h)
    else:
        print(__doc__.strip())
        sys.exit(2)


if __name__ == "__main__":
    main()
