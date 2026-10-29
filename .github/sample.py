#!/usr/bin/env python3
"""sample.py OUT - writes the CI sample: about 6 MB of text-like and binary
data from a fixed seed, the same bytes on every platform (a checkout may
turn the repository's line endings into CRLF; this does not depend on it)."""
import random
import struct
import sys

r = random.Random(20261029)
words = [''.join(r.choice('etaoinshrdlucmfwypvbgkqjxz') for _ in range(r.randint(1, 9)))
         for _ in range(3000)]
out = bytearray()
while len(out) < 3_000_000:   # text: Zipf-ish words, lines, repeated phrases
    line = ' '.join(words[int(r.paretovariate(1.1)) % len(words)] for _ in range(r.randint(3, 14)))
    out += line.encode() + b'\n'
    if r.random() < 0.05 and len(out) > 10000:
        k = r.randrange(len(out) - 5000)
        out += out[k:k + r.randint(20, 4000)]
for i in range(150_000):      # binary: records with slowly changing fields
    out += struct.pack('<IHhd', i, i % 977, r.randint(-40, 40), i * 0.25)
out += r.randbytes(500_000)   # incompressible
out += bytes(300_000)         # zeros
open(sys.argv[1], 'wb').write(out)
