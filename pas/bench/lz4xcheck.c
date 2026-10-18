/* lz4xcheck — decodes a sylz v0 stream with the reference LZ4 decoder.

   sylz format v0 is byte-compatible with the LZ4 block format, so the same
   compressed bytes can be timed with both decoders: the difference is pure
   codegen (Free Pascal vs the C compiler), with parsing held equal.

   Build: cc -O3 -I<lz4>/lib bench/lz4xcheck.c <lz4>/lib/lz4.c -o out/lz4xcheck
   Usage: lz4xcheck ORIGINAL COMPRESSED [SECONDS]
   (COMPRESSED from: SYLZ_DUMP=prefix sylzbench ...) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "lz4.h"

static char *load(const char *path, long *size)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    *size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(*size + 1);
    if (fread(buf, 1, *size, f) != (size_t)*size) { perror(path); exit(1); }
    fclose(f);
    return buf;
}

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: lz4xcheck ORIGINAL COMPRESSED [SECONDS]\n");
        return 1;
    }
    long n, csize;
    char *orig = load(argv[1], &n);
    char *comp = load(argv[2], &csize);
    double minTime = argc > 3 ? atof(argv[3]) : 3.0;
    char *out = malloc(n + 1);

    double best = 1e30, total = 0;
    int r = 0;
    do {
        double t0 = now();
        r = LZ4_decompress_safe(comp, out, (int)csize, (int)n);
        double t = now() - t0;
        if (t < best) best = t;
        total += t;
    } while (total < minTime);

    if (r != n || memcmp(orig, out, n) != 0) {
        fprintf(stderr, "MISMATCH: LZ4 decoded %d of %ld bytes\n", r, n);
        return 2;
    }
    printf("LZ4_decompress_safe  %9.2f MB/s  (%ld -> %ld bytes)\n", n / best / 1e6, csize, n);
    return 0;
}
