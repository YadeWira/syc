#!/usr/bin/env python3
"""crypto_xcheck.py - recomputes `cryptotest --dump N` with independent
implementations: hashlib (BLAKE2b, keyed BLAKE2s), cryptography (ChaCha20, Poly1305),
libsodium through PyNaCl (XChaCha20-Poly1305; Argon2id with one lane),
OpenSSL's command line (Argon2id with any lanes; OpenSSL 3.2 or later,
or else argon2-cffi, which wraps the reference implementation).

    cryptotest --dump 500 | python3 crypto_xcheck.py
"""
import hashlib
import subprocess
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
from cryptography.hazmat.primitives.poly1305 import Poly1305
from nacl import bindings


def unhex(s):
    return b'' if s == '-' else bytes.fromhex(s)


def argon2_openssl(t, m, p, pwd, salt, n):
    # an empty password is given as an empty text one
    password = 'hexpass:' + pwd.hex() if pwd else 'pass:'
    args = ['openssl', 'kdf', '-keylen', str(n), '-kdfopt', password,
            '-kdfopt', 'hexsalt:' + salt.hex(), '-kdfopt', 'iter:%d' % t,
            '-kdfopt', 'memcost:%d' % m, '-kdfopt', 'lanes:%d' % p,
            '-kdfopt', 'threads:1', 'ARGON2ID']
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    return bytes.fromhex(out.strip().replace(':', ''))


def argon2_cffi(t, m, p, pwd, salt, n):
    from argon2.low_level import Type, hash_secret_raw
    return hash_secret_raw(pwd, salt, t, m, p, n, Type.ID)


def argon2_any_lanes():
    try:
        argon2_openssl(1, 8, 1, b'p', b'saltsalt', 32)
        return argon2_openssl
    except (OSError, subprocess.CalledProcessError):
        return argon2_cffi   # an OpenSSL without ARGON2ID (before 3.2)


def main():
    counts, bad = {}, 0
    argon2 = argon2_any_lanes()
    for line in sys.stdin:
        f = line.split()
        kind = f[0]
        if kind == 'blake2b':
            ok = hashlib.blake2b(unhex(f[2]), digest_size=int(f[1])).digest() == unhex(f[3])
        elif kind == 'blake2s':
            ok = hashlib.blake2s(unhex(f[2]), key=unhex(f[1])).digest() == unhex(f[3])
        elif kind == 'chacha20':
            key, nonce, counter, msg, out = unhex(f[1]), unhex(f[2]), int(f[3]), unhex(f[4]), unhex(f[5])
            enc = Cipher(algorithms.ChaCha20(key, counter.to_bytes(4, 'little') + nonce), None).encryptor()
            ok = enc.update(msg) == out
        elif kind == 'poly1305':
            ok = Poly1305.generate_tag(unhex(f[1]), unhex(f[2])) == unhex(f[3])
        elif kind == 'xchacha':
            key, nonce, aad, msg, out = (unhex(x) for x in f[1:6])
            ok = bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(msg, aad, nonce, key) == out
            ok = ok and bindings.crypto_aead_xchacha20poly1305_ietf_decrypt(out, aad, nonce, key) == msg
        elif kind == 'argon2id':
            t, m, p = int(f[1]), int(f[2]), int(f[3])
            pwd, salt, out = unhex(f[4]), unhex(f[5]), unhex(f[6])
            ok = argon2(t, m, p, pwd, salt, len(out)) == out
            if ok and p == 1 and len(out) >= 16 and m >= 8:
                # libsodium: one lane, memory in bytes, its own minimums
                try:
                    ok = bindings.crypto_pwhash_alg(len(out), pwd, salt, t, m * 1024,
                                                    bindings.crypto_pwhash_ALG_ARGON2ID13) == out
                    kind = 'argon2id+sodium'
                except Exception:
                    pass   # below libsodium's limits (t < 1 or m < 8 KiB): the other one only
        else:
            raise SystemExit('unknown line: ' + line[:40])
        counts[kind] = counts.get(kind, 0) + 1
        if not ok:
            bad += 1
            print('MISMATCH: ' + line[:200])
    print(', '.join('%s %d' % kv for kv in sorted(counts.items())), '- mismatches: %d' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
