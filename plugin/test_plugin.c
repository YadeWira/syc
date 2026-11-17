/* test_plugin — loads a sylz zpaq-std plugin (sylz, sylzec, sylz4 or sylz5) the way zpaq-std does and
   checks it against zs_codec.h's contract.

   Usage: test_plugin [--codec N] PLUGIN FILE...

   - zpaqstd_codec_v1 is exported, abi/name/levels are as expected; with
     --codec N, zpaqstd_codecs_v1(N) is the codec tested, (0) is what
     zpaqstd_codec_v1 returns, and the list ends with NULL after sylz5
   - loading the plugin leaves the floating-point state (MXCSR, x87 control
     word) of the process unchanged
   - every file, at every level: compress with bound() bytes, decompress
     into exactly the original size, compare
   - compress never writes past cap (guard bytes), also when cap is too
     small, and then returns a negative number
   - corrupted and truncated streams: decompress returns a negative number
     or the original size, never writes past cap
   - each codec reads the block formats it should and refuses the others:
     a v3 block (sylzec, sylz5 read it) and a v4 block with no tokens
     (sylz4, sylz5 read it)
   - blocks of 0 to 16 bytes, with every value of the header's top byte,
     placed flush against a page the process may not read: decompress
     must not read past them (a 4-byte block once did)
   - several threads compress and decompress at the same time

   Build (Linux):  cc -O2 -pthread plugin/test_plugin.c -o out/test_plugin -ldl
                   (32-bit: gcc -m32 -msse ...; macOS: cc without -ldl)
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
#include <sys/mman.h>
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
static int fmt;     /* the codec's format: 2 sylz, 3 sylzec, 4 sylz4, 5 sylz5 */

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

/* n bytes ending exactly at a page with no access; *base and *total for
   guarded_free. The page size is a multiple of every target's (Apple
   arm64: 16 KiB). */
#define GPAGE 16384
static unsigned char* guarded(size_t n, void** base, size_t* total)
{
    size_t body = (n + GPAGE - 1) / GPAGE * GPAGE;
    if (body == 0) body = GPAGE;
    *total = body + GPAGE;
#ifdef _WIN32
    unsigned char* b = VirtualAlloc(NULL, *total, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    DWORD old;
    if (!b || !VirtualProtect(b + body, GPAGE, PAGE_NOACCESS, &old)) { printf("FAIL: VirtualAlloc\n"); exit(2); }
#else
    unsigned char* b = mmap(NULL, *total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (b == MAP_FAILED || mprotect(b + body, GPAGE, PROT_NONE) != 0) { perror("mmap"); exit(2); }
#endif
    *base = b;
    return b + body - n;
}

static void guarded_free(void* base, size_t total)
{
#ifdef _WIN32
    (void)total;
    VirtualFree(base, 0, MEM_RELEASE);
#else
    munmap(base, total);
#endif
}

/* blocks of 0..16 bytes against a guard page, every top byte, a few
   fillings; into outputs of 0 and 64 bytes, also against a guard page.
   A read past the block or a write past cap faults. Returns failures. */
static int short_blocks(void)
{
    int bad = 0;
    void *ob, *ib;
    size_t ot, it;
    for (size_t len = 0; len <= 16; len++)
        for (int top = 0; top < 256; top++) {
            if (len < 4 && top > 0) break;
            for (int fill = 0; fill < 4; fill++) {
                unsigned char* in = guarded(len, &ib, &it);
                for (size_t i = 0; i < len; i++)
                    in[i] = fill == 0 ? 0 : fill == 1 ? 0xFF : (unsigned char)rnd();
                if (len >= 4) in[3] = (unsigned char)top;
                for (size_t cap = 0; cap <= 64; cap += 64) {
                    unsigned char* out = guarded(cap, &ob, &ot);
                    long long r = C->decompress(in, len, out, cap, 0);
                    if (r > (long long)cap) {
                        printf("FAIL: a %u-byte block decoded to %lld bytes, cap %u\n",
                               (unsigned)len, r, (unsigned)cap);
                        bad++;
                    }
                    guarded_free(ob, ot);
                }
                guarded_free(ib, it);
            }
        }
    return bad;
}

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
        /* a valid format v3 block (no sequences, the literals as one raw
           chunk) and a valid format v4 block (no tokens, the literals as
           the tail): each codec reads exactly the formats it should */
        if (n > 0 && n <= 65536) {
            unsigned char* v3 = malloc(n + 9);
            v3[0] = 0; v3[1] = 0; v3[2] = 0; v3[3] = 0x80;          /* ctrlLen 0, v3 */
            v3[4] = (unsigned char)n; v3[5] = (unsigned char)(n >> 8);
            v3[6] = (unsigned char)(n >> 16); v3[7] = 0;             /* literal count */
            v3[8] = 0;                                                 /* raw chunk */
            memcpy(v3 + 9, src, n);
            long long r4 = C->decompress(v3, n + 9, out, n, 0);
            int want3 = fmt == 3 || fmt == 5;
            if (!want3 && r4 >= 0) { printf("FAIL: format v3 block accepted (%lld)\n", r4); bad = 1; }
            if (want3 && (r4 != (long long)n || memcmp(out, src, n) != 0)) {
                printf("FAIL: format v3 block not decoded (%lld)\n", r4); bad = 1;
            }
            unsigned char* v4 = v3;
            v4[0] = 0; v4[1] = 0; v4[2] = 0; v4[3] = 0x40;          /* tokLen 0, v4 */
            memcpy(v4 + 4, src, n);
            long long r5 = C->decompress(v4, n + 4, out, n, 0);
            int want4 = fmt >= 4;
            if (!want4 && r5 >= 0) { printf("FAIL: format v4 block accepted (%lld)\n", r5); bad = 1; }
            if (want4 && (r5 != (long long)n || memcmp(out, src, n) != 0)) {
                printf("FAIL: format v4 block not decoded (%lld)\n", r5); bad = 1;
            }
            free(v3);
        }
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
    int pick = -1;
    if (argc >= 3 && strcmp(argv[1], "--codec") == 0) {
        pick = atoi(argv[2]);
        argv += 2;
        argc -= 2;
    }
    if (argc < 3) { fprintf(stderr, "usage: test_plugin [--codec N] PLUGIN FILE...\n"); return 2; }

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
    typedef const zs_codec* (*zs_list_entry)(int);
#ifdef _WIN32
    zs_list_entry list = (zs_list_entry)(void*)GetProcAddress(h, "zpaqstd_codecs_v1");
#else
    zs_list_entry list = (zs_list_entry)dlsym(h, "zpaqstd_codecs_v1");
#endif

#ifdef HAVE_X86
    CHECK(_mm_getcsr() == mxcsr0, "loading the plugin changed MXCSR %08x -> %08x", mxcsr0, _mm_getcsr());
#if defined(__i386__) || defined(_M_IX86)
    unsigned short cw1; __asm__ __volatile__("fnstcw %0" : "=m"(cw1));
    CHECK(cw1 == cw0, "loading the plugin changed the x87 control word %04x -> %04x", cw0, cw1);
#endif
#endif

    C = entry();
    CHECK(C != NULL, "zpaqstd_codec_v1 returned NULL");
    if (pick >= 0) {
        CHECK(list != NULL, "zpaqstd_codecs_v1 not exported");
        if (!list) return 1;
        CHECK(list(0) == C, "zpaqstd_codecs_v1(0) is not what zpaqstd_codec_v1 returns");
        CHECK(list(4) == NULL, "zpaqstd_codecs_v1(4) is not NULL");
        C = list(pick);
        CHECK(C != NULL, "zpaqstd_codecs_v1(%d) returned NULL", pick);
    }
    if (!C) return 1;
    CHECK(C->abi == 1, "abi %d", C->abi);
    static const char* const names[] = { "sylz", "sylzec", "sylz4", "sylz5" };
    fmt = 0;
    for (int i = 0; i < 4; i++)
        if (C->name && strcmp(C->name, names[i]) == 0) fmt = i + 2;
    CHECK(fmt != 0, "name %s", C->name ? C->name : "(null)");
    if (!fmt) return 1;
    char prefix[16];
    snprintf(prefix, sizeof prefix, "sylz format v%d ", fmt);
    CHECK(C->library && strncmp(C->library, prefix, 15) == 0,
          "library %s", C->library ? C->library : "(null)");
    CHECK(C->min_level == 0 && C->max_level == 10, "levels %d..%d", C->min_level, C->max_level);
    CHECK(C->bound && C->compress && C->decompress, "missing function");
    CHECK(C->query == NULL && C->data == NULL, "query/data should be NULL");
    CHECK(C->bound((size_t)1 << 31, 1) == 0, "bound for a 2 GiB block should be 0");
    if (fmt >= 4)
        CHECK(C->bound(((size_t)512 << 20) + 1, 1) == 0, "bound past 512 MiB should be 0 (formats v4, v5)");
    printf("plugin: %s, %s, levels %d..%d\n", C->name, C->library, C->min_level, C->max_level);

    int nfiles = argc - 2;
    unsigned char** data = malloc(sizeof(*data) * nfiles);
    size_t* sizes = malloc(sizeof(*sizes) * nfiles);
    for (int i = 0; i < nfiles; i++) data[i] = load(argv[i + 2], &sizes[i]);

    /* empty input */
    failures += check_one((const unsigned char*)"", 0, 1, 1);

    failures += short_blocks();
    printf("short blocks against a guard page: done\n");

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
        jobs[t].level = t % 4 * 3;       /* 0, 3, 6, 9 */
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
