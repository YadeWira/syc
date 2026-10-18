/* test_plugin — loads the sylz zpaq-std plugin the way zpaq-std does and
   checks it against zs_codec.h's contract.

   Usage: test_plugin PLUGIN FILE...

   - zpaqstd_codec_v1 is exported, abi/name/levels are as expected
   - loading the plugin leaves the floating-point state (MXCSR, x87 control
     word) of the process unchanged
   - every file, at every level: compress with bound() bytes, decompress
     into exactly the original size, compare
   - compress never writes past cap (guard bytes), also when cap is too
     small, and then returns a negative number
   - corrupted and truncated streams: decompress returns a negative number
     or the original size, never writes past cap
   - several threads compress and decompress at the same time

   Build (Linux):  cc -O2 -pthread plugin/test_plugin.c -o out/test_plugin -ldl
   Build (Windows, mingw): i686-w64-mingw32-gcc / x86_64-w64-mingw32-gcc
                   -O2 plugin/test_plugin.c -o test_plugin.exe */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

#ifdef _WIN32
#include <windows.h>
typedef HANDLE thread_t;
#else
#include <dlfcn.h>
#include <pthread.h>
typedef pthread_t thread_t;
#endif

#if defined(__x86_64__) || defined(__i386__) || defined(_M_X64) || defined(_M_IX86)
#include <xmmintrin.h>
#define HAVE_X86 1
#endif

/* zs_codec.h, ABI 1 */
typedef struct zs_codec {
    int abi;
    const char* name;
    const char* library;
    int min_level, max_level;
    size_t (*bound)(size_t n, int level);
    long long (*compress)(const void* src, size_t n, void* dst, size_t cap, int level);
    long long (*decompress)(const void* src, size_t n, void* dst, size_t cap, int param);
    long long (*query)(int what, const void* src, size_t n);
    const void* (*data)(int what, size_t* size);
} zs_codec;
typedef const zs_codec* (*zs_codec_entry)(void);

static const zs_codec* C;
static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); failures++; } } while (0)

#define GUARD 64
#define GUARD_BYTE 0xA5

static unsigned char* load(const char* path, size_t* n)
{
    FILE* f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END);
    *n = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char* b = malloc(*n + 1);
    if (fread(b, 1, *n, f) != *n) { perror(path); exit(2); }
    fclose(f);
    return b;
}

static int guard_ok(const unsigned char* p)
{
    for (int i = 0; i < GUARD; i++)
        if (p[i] != GUARD_BYTE) return 0;
    return 1;
}

static unsigned rng = 12345;
static unsigned rnd(void) { rng = rng * 1103515245u + 12345u; return rng >> 8; }

/* one file at one level, all checks; returns 0 on success */
static int check_one(const unsigned char* src, size_t n, int level, int quiet_corrupt)
{
    int bad = 0;
    size_t cap = C->bound(n, level);
    unsigned char* comp = malloc(cap + GUARD);
    unsigned char* out = malloc(n + GUARD + 1);
    memset(comp + cap, GUARD_BYTE, GUARD);
    long long c = C->compress(src, n, comp, cap, level);
    if (c < 0 || (size_t)c > cap) { printf("FAIL: compress level %d returned %lld (cap %zu)\n", level, c, cap); bad = 1; goto done; }
    if (!guard_ok(comp + cap)) { printf("FAIL: compress level %d wrote past cap\n", level); bad = 1; }

    memset(out + n, GUARD_BYTE, GUARD);
    long long d = C->decompress(comp, (size_t)c, out, n, 0);
    if (d != (long long)n || memcmp(out, src, n) != 0) { printf("FAIL: roundtrip level %d (got %lld of %zu)\n", level, d, n); bad = 1; }
    if (!guard_ok(out + n)) { printf("FAIL: decompress wrote past cap\n"); bad = 1; }

    if (!quiet_corrupt && c > 8) {
        /* too small an output buffer for compress: negative, nothing past cap */
        size_t small = (size_t)c / 2;
        unsigned char* tiny = malloc(small + GUARD);
        memset(tiny + small, GUARD_BYTE, GUARD);
        long long r = C->compress(src, n, tiny, small, level);
        if (r >= 0 && (size_t)r > small) { printf("FAIL: compress with small cap returned %lld > cap %zu\n", r, small); bad = 1; }
        if (!guard_ok(tiny + small)) { printf("FAIL: compress with small cap wrote past it\n"); bad = 1; }
        free(tiny);

        /* corrupted copies and a truncated one */
        unsigned char* cc = malloc((size_t)c);
        for (int k = 0; k < 20; k++) {
            memcpy(cc, comp, (size_t)c);
            for (int f = 0; f < 1 + k % 4; f++) cc[rnd() % (size_t)c] = (unsigned char)rnd();
            memset(out + n, GUARD_BYTE, GUARD);
            long long r2 = C->decompress(cc, (size_t)c, out, n, 0);
            if (r2 >= 0 && r2 != (long long)n) { printf("FAIL: corrupt stream returned %lld\n", r2); bad = 1; }
            if (!guard_ok(out + n)) { printf("FAIL: corrupt stream wrote past cap\n"); bad = 1; }
        }
        long long r3 = C->decompress(comp, (size_t)c - 1 - rnd() % ((size_t)c - 1), out, n, 0);
        if (r3 == (long long)n && n > 0) { printf("FAIL: truncated stream accepted\n"); bad = 1; }
        free(cc);
    }
done:
    free(comp);
    free(out);
    return bad;
}

typedef struct { const unsigned char* src; size_t n; int level; int bad; } job_t;

#ifdef _WIN32
static DWORD WINAPI worker(LPVOID p)
#else
static void* worker(void* p)
#endif
{
    job_t* j = (job_t*)p;
    for (int rep = 0; rep < 4; rep++)
        j->bad |= check_one(j->src, j->n, j->level, 1);
    return 0;
}

int main(int argc, char** argv)
{
    if (argc < 3) { fprintf(stderr, "usage: test_plugin PLUGIN FILE...\n"); return 2; }

#ifdef HAVE_X86
    unsigned mxcsr0 = _mm_getcsr();
#if defined(__i386__) || defined(_M_IX86)
    unsigned short cw0; __asm__ __volatile__("fnstcw %0" : "=m"(cw0));
#endif
#endif

#ifdef _WIN32
    HMODULE h = LoadLibraryA(argv[1]);
    if (!h) { printf("FAIL: LoadLibrary %s: error %lu\n", argv[1], GetLastError()); return 1; }
    zs_codec_entry entry = (zs_codec_entry)(void*)GetProcAddress(h, "zpaqstd_codec_v1");
#else
    void* h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("FAIL: dlopen: %s\n", dlerror()); return 1; }
    zs_codec_entry entry = (zs_codec_entry)dlsym(h, "zpaqstd_codec_v1");
#endif
    if (!entry) { printf("FAIL: zpaqstd_codec_v1 not exported\n"); return 1; }

#ifdef HAVE_X86
    CHECK(_mm_getcsr() == mxcsr0, "loading the plugin changed MXCSR %08x -> %08x", mxcsr0, _mm_getcsr());
#if defined(__i386__) || defined(_M_IX86)
    unsigned short cw1; __asm__ __volatile__("fnstcw %0" : "=m"(cw1));
    CHECK(cw1 == cw0, "loading the plugin changed the x87 control word %04x -> %04x", cw0, cw1);
#endif
#endif

    C = entry();
    CHECK(C != NULL, "zpaqstd_codec_v1 returned NULL");
    if (!C) return 1;
    CHECK(C->abi == 1, "abi %d", C->abi);
    CHECK(C->name && strcmp(C->name, "sylz") == 0, "name %s", C->name ? C->name : "(null)");
    CHECK(C->min_level == -2 && C->max_level == 12, "levels %d..%d", C->min_level, C->max_level);
    CHECK(C->bound && C->compress && C->decompress, "missing function");
    CHECK(C->query == NULL && C->data == NULL, "query/data should be NULL");
    CHECK(C->bound((size_t)1 << 31, 1) == 0, "bound for a 2 GiB block should be 0");
    printf("plugin: %s, %s, levels %d..%d\n", C->name, C->library, C->min_level, C->max_level);

    int nfiles = argc - 2;
    unsigned char** data = malloc(sizeof(*data) * nfiles);
    size_t* sizes = malloc(sizeof(*sizes) * nfiles);
    for (int i = 0; i < nfiles; i++) data[i] = load(argv[i + 2], &sizes[i]);

    /* empty input */
    failures += check_one((const unsigned char*)"", 0, 1, 1);

    for (int i = 0; i < nfiles; i++)
        for (int level = C->min_level; level <= C->max_level; level++)
            failures += check_one(data[i], sizes[i], level, 0);
    printf("single-threaded: %d files x %d levels done\n", nfiles, C->max_level - C->min_level + 1);

    enum { THREADS = 8 };
    job_t jobs[THREADS];
    thread_t th[THREADS];
    for (int t = 0; t < THREADS; t++) {
        jobs[t].src = data[t % nfiles];
        jobs[t].n = sizes[t % nfiles];
        jobs[t].level = -2 + t % 4 * 4;  /* -2, 2, 6, 10 */
        jobs[t].bad = 0;
#ifdef _WIN32
        th[t] = CreateThread(NULL, 0, worker, &jobs[t], 0, NULL);
#else
        pthread_create(&th[t], NULL, worker, &jobs[t]);
#endif
    }
    for (int t = 0; t < THREADS; t++) {
#ifdef _WIN32
        WaitForSingleObject(th[t], INFINITE);
#else
        pthread_join(th[t], NULL);
#endif
        failures += jobs[t].bad;
    }
    printf("multi-threaded: %d threads done\n", THREADS);

    printf(failures ? "FAILED: %d\n" : "ok\n", failures);
    return failures ? 1 : 0;
}
