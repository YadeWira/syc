/* sylzc.c — the parts of sylz written in C, where Free Pascal's code
   generation falls short (many values live at once: FPC keeps them on the
   stack). Linked into sylz.pas with {$L}; the Pascal versions stay the
   reference, and the tests check both give the same bytes.

   Freestanding: no libc, no libgcc. Build with
     -O2 -ffreestanding -fno-builtin -fno-tree-loop-distribute-patterns
     -fno-stack-protector -fno-asynchronous-unwind-tables
   so the compiler emits no calls of its own (memset, __chkstk, ...). */

#include <stdint.h>

/* TOptNode in sylz.pas */
typedef struct {
    int32_t cost;   /* quarter bytes, relative to the window's start */
    int32_t ll;     /* pending literals at this node */
    int32_t ml;     /* 0: reached by a literal, else by a match of ml bytes */
    int32_t dist;
} sylzc_node;

/* The constants and prices the DP needs, from sylz.pas (TOptDpArgs). */
typedef struct {
    int32_t exactLL;    /* EXACT_LL: longest literal run without an extension */
    int32_t minMatch;   /* SYLZ_MINMATCH */
    int32_t mtabCols;   /* columns of mtab: lengths MINMATCH .. +mtabCols-1 */
    int32_t subLen;     /* every match length up to this is tried */
    int32_t seq, esc, shortOff;   /* penalties, quarter bytes */
} sylzc_dpargs;

static int32_t ext_bytes(int32_t v) { return v / 255 + 1; }

/* LitStep in sylz.pas */
static int32_t lit_step(int32_t ll, const sylzc_dpargs *a)
{
    if (ll < a->exactLL)
        return 4;
    if (ll == a->exactLL)
        return 4 * (1 + ext_bytes(ll + 1)) + a->esc;
    return 4 * (1 + ext_bytes(ll + 1) - ext_bytes(ll));
}

/* MatchCost in sylz.pas for a length past mtab (so past the exact codes) */
static int32_t long_match_cost(int32_t ll, int32_t ml, int32_t dist,
                               const sylzc_dpargs *a)
{
    int32_t m = ml - a->minMatch;
    int32_t r = 4 * (3 + ext_bytes(m)) + a->seq;
    if (ll <= a->exactLL)
        r += a->esc;
    if (dist < 16)
        r += a->shortOff;
    return r;
}

/* OptDpPas in sylz.pas: the forward DP over one window of w positions.
   nodes[0] is set and nodes[1..w].cost are INT32_MAX on entry. Position i
   has cnt[i] candidates at cands[2 * off[i]] as (length, distance) pairs,
   longest last; cnt[i] < 0: inside a skipped match, no transitions.
   mtab: match prices without the short-offset penalty, by pending run
   (row exactLL + 1: any longer run) and length - MINMATCH. */
void sylzc_opt_dp(sylzc_node *nodes, int32_t w, const int32_t *cands,
                  const int32_t *off, const int32_t *cnt, const int32_t *mtab,
                  const sylzc_dpargs *a)
{
    for (int32_t i = 0; i < w; i++) {
        int32_t k = cnt[i];
        if (k < 0)
            continue;
        int32_t cost = nodes[i].cost;
        int32_t ll = nodes[i].ll;
        int32_t tc = cost + lit_step(ll, a);
        if (tc < nodes[i + 1].cost) {
            nodes[i + 1].cost = tc;
            nodes[i + 1].ll = ll + 1;
            nodes[i + 1].ml = 0;
        }
        if (k == 0)
            continue;
        const int32_t *row = mtab + (ll > a->exactLL ? a->exactLL + 1 : ll) * a->mtabCols;
        const int32_t *cp = cands + 2 * off[i];
        int32_t prevLen = a->minMatch - 1;
        for (int32_t c = 0; c < k; c++) {
            int32_t len = cp[2 * c], dist = cp[2 * c + 1];
            int32_t base = cost + (dist < 16 ? a->shortOff : 0);
            int32_t ml = prevLen;
            while (ml < len) {
                if (ml < a->subLen)
                    ml++;
                else
                    ml = len;
                int32_t j = i + ml;
                if (j > w)
                    break;
                if (ml < a->minMatch + a->mtabCols)
                    tc = base + row[ml - a->minMatch];
                else
                    tc = cost + long_match_cost(ll, ml, dist, a);
                if (tc < nodes[j].cost) {
                    nodes[j].cost = tc;
                    nodes[j].ll = 0;
                    nodes[j].ml = ml;
                    nodes[j].dist = dist;
                }
            }
            prevLen = len;
        }
    }
}

/* ── decoder ──────────────────────────────────────────────────────────── */

/* SYLZ_TOKENS entries: bits 0..7 literals, 8..15 match length, 16 / 17
   their extension flags */
#define TOK_LLEXT 0x10000u
#define TOK_MLEXT 0x20000u

/* On 32-bit x86 the decoder comes twice: compiled for SSE2 (its 16-byte
   copies become one load and one store, +22-27% decode on Windows 7
   32-bit) and for plain i686; sylzc_decode picks one with cpuid on its
   first call, so one binary runs on any x86 and uses SSE2 where there is
   one. -DSYLZC_NO_SSE2 keeps only the i686 one. The compressors stay
   i686: with -msse2 gcc moved their 64-bit compares into xmm registers,
   10% slower (levels 3, 8). */
#define DECODER_INLINE static inline __attribute__((always_inline))

static void copy8(uint8_t *d, const uint8_t *s) { __builtin_memcpy(d, s, 8); }
static void copy16(uint8_t *d, const uint8_t *s) { __builtin_memcpy(d, s, 16); }

/* DecodeSafe in sylz.pas: exact, fully checked, to the end of the block */
DECODER_INLINE intptr_t decode_safe(const uint8_t *ctrl, const uint8_t *cend,
                            const uint8_t *lit, const uint8_t *lend,
                            uint8_t *op, uint8_t *oend, uint8_t *dst,
                            const uint32_t *tokens)
{
    while (ctrl < cend) {
        if (cend - ctrl < 3)
            return -1;
        uint32_t e = tokens[ctrl[0]];
        intptr_t off = (intptr_t)(ctrl[1] | (uint32_t)ctrl[2] << 8) + 1;
        ctrl += 3;
        intptr_t ll = e & 0xFF, ml = (e >> 8) & 0xFF;
        if (e & TOK_LLEXT) {
            uint8_t b;
            do {
                if (ctrl >= cend)
                    return -1;
                b = *ctrl++;
                ll += b;
            } while (b == 255);
        }
        if (e & TOK_MLEXT) {
            uint8_t b;
            do {
                if (ctrl >= cend)
                    return -1;
                b = *ctrl++;
                ml += b;
            } while (b == 255);
        }
        if (ll > lend - lit || ll > oend - op)
            return -1;
        for (intptr_t i = 0; i < ll; i++)
            op[i] = lit[i];
        op += ll;
        lit += ll;
        if (off > op - dst || ml > oend - op)
            return -1;
        const uint8_t *m = op - off;
        while (ml-- > 0)
            *op++ = *m++;
    }
    /* the rest of the literal stream is the block's tail */
    if (lend - lit != oend - op)
        return -1;
    while (lit < lend)
        *op++ = *lit++;
    return oend - dst;
}

/* DecodePas in sylz.pas, the same fast loop and margins: a sequence starts
   in it only with 3 control bytes, 16 literal bytes and 64 output bytes
   left, so the common sequence copies without bounds checks. The limits
   are integers (a pointer before a buffer's start would be undefined in
   C), computed once, and the token table is a local: passed as a 7th
   argument it stayed on the stack, read again for every sequence. */
DECODER_INLINE intptr_t decode_core(const uint8_t *ctrl, const uint8_t *cend,
                      const uint8_t *lit, const uint8_t *lend,
                      uint8_t *dst, intptr_t dstLen, const uint32_t *tokens_)
{
    static const uint8_t period[8] = {0, 8, 8, 9, 8, 10, 12, 14};
    const uint32_t *tokens = tokens_;
    uint8_t *op = dst, *oend = dst + dstLen;
    /* the fast loop runs while ctrl <= cfast, lit <= lfast, op <= ofast;
       a limit below its buffer (short block) is 0: nothing runs */
    uintptr_t cfast = cend - ctrl >= 3 ? (uintptr_t)cend - 3 : 0;
    uintptr_t lfast = lend - lit >= 16 ? (uintptr_t)lend - 16 : 0;
    uintptr_t ofast = dstLen >= 64 ? (uintptr_t)oend - 64 : 0;

    while ((uintptr_t)ctrl <= cfast && (uintptr_t)lit <= lfast && (uintptr_t)op <= ofast) {
        uint32_t e = tokens[ctrl[0]];
        uintptr_t off = (uintptr_t)(ctrl[1] | (uint32_t)ctrl[2] << 8) + 1;
        intptr_t ll, ml;
        ctrl += 3;
        if (__builtin_expect(e <= 0xFFFF, 1)) {
            /* exact pair: literals <= 15, match <= 32 */
            ll = e & 0xFF;
            ml = e >> 8;
            copy16(op, lit);
            op += ll;
            lit += ll;
        } else {
            /* extended field(s): read through m, so giving up leaves
               everything at the token, nothing written yet */
            const uint8_t *m = ctrl;
            ll = e & 0xFF;
            ml = (e >> 8) & 0xFF;
            if (e & TOK_LLEXT) {
                do {
                    if (m >= cend) { ll = -1; break; }
                    ll += *m++;
                } while (m[-1] == 255);
            }
            if ((e & TOK_MLEXT) && ll >= 0) {
                do {
                    if (m >= cend) { ll = -1; break; }
                    ml += *m++;
                } while (m[-1] == 255);
            }
            if (ll < 0 || ll > (intptr_t)(lfast - (uintptr_t)lit)
                || ll + ml > (intptr_t)(ofast - (uintptr_t)op) + 16) {
                ctrl -= 3;   /* decode_safe redoes this sequence exactly */
                break;
            }
            ctrl = m;
            /* count down; the last step overshoots by -ll, taken back */
            do {
                copy16(op, lit);
                op += 16;
                lit += 16;
                ll -= 16;
            } while (ll > 0);
            op += ll;
            lit += ll;
        }

        /* match */
        if (__builtin_expect((intptr_t)off > op - dst, 0))
            return -1;
        const uint8_t *m = op - off;
        if (__builtin_expect(off >= 16, 1)) {
            copy16(op, m);
            copy16(op + 16, m + 16);
            if (__builtin_expect(ml > 32, 0)) {
                op += 32;
                m += 32;
                ml -= 32;
                do {
                    copy16(op, m);
                    op += 16;
                    m += 16;
                    ml -= 16;
                } while (ml > 0);
            }
            op += ml;   /* ml <= 32: one step; else ml <= 0, the overshoot */
        } else if (off >= 8) {
            do {
                copy8(op, m);
                op += 8;
                m += 8;
                ml -= 8;
            } while (ml > 0);
            op += ml;
        } else {
            /* off < 8: the first 8 bytes one by one; they repeat with
               period off, so the rest copies from the nearest multiple of
               off that is >= 8, in 8-byte steps */
            op[0] = m[0]; op[1] = m[1]; op[2] = m[2]; op[3] = m[3];
            op[4] = m[4]; op[5] = m[5]; op[6] = m[6]; op[7] = m[7];
            op += 8;
            m = op - period[off];
            ml -= 8;
            while (ml > 0) {
                copy8(op, m);
                op += 8;
                m += 8;
                ml -= 8;
            }
            op += ml;
        }
    }
    return decode_safe(ctrl, cend, lit, lend, op, oend, dst, tokens);
}

#if defined(__i386__) && !defined(SYLZC_NO_SSE2)
#include <cpuid.h>   /* header only: inline asm, no libc */

__attribute__((target("sse2")))
static intptr_t decode_sse2(const uint8_t *ctrl, const uint8_t *cend,
                            const uint8_t *lit, const uint8_t *lend,
                            uint8_t *dst, intptr_t dstLen, const uint32_t *tokens)
{
    return decode_core(ctrl, cend, lit, lend, dst, dstLen, tokens);
}

static intptr_t decode_i686(const uint8_t *ctrl, const uint8_t *cend,
                            const uint8_t *lit, const uint8_t *lend,
                            uint8_t *dst, intptr_t dstLen, const uint32_t *tokens)
{
    return decode_core(ctrl, cend, lit, lend, dst, dstLen, tokens);
}

/* 0 not checked yet, 1 i686, 2 SSE2 (cpuid leaf 1, edx bit 26). Threads
   racing here all store the same value. */
static volatile int decoder_kind;

intptr_t sylzc_decode(const uint8_t *ctrl, const uint8_t *cend,
                      const uint8_t *lit, const uint8_t *lend,
                      uint8_t *dst, intptr_t dstLen, const uint32_t *tokens)
{
    int kind = decoder_kind;
    if (kind == 0) {
        unsigned a, b, c, d;
        kind = __get_cpuid(1, &a, &b, &c, &d) && (d & bit_SSE2) ? 2 : 1;
        decoder_kind = kind;
    }
    if (kind == 2)
        return decode_sse2(ctrl, cend, lit, lend, dst, dstLen, tokens);
    return decode_i686(ctrl, cend, lit, lend, dst, dstLen, tokens);
}
#else
intptr_t sylzc_decode(const uint8_t *ctrl, const uint8_t *cend,
                      const uint8_t *lit, const uint8_t *lend,
                      uint8_t *dst, intptr_t dstLen, const uint32_t *tokens)
{
    return decode_core(ctrl, cend, lit, lend, dst, dstLen, tokens);
}
#endif

/* ── compressor helpers ───────────────────────────────────────────────── */

#define MINMATCH  4
#define EXACT_LL  15
#define EXACT_M   28
#define ESC_ML    210
#define ESC_LL    226
#define ESC_BOTH  255

static uint32_t read32(const uint8_t *p) { uint32_t v; __builtin_memcpy(&v, p, 4); return v; }
static uint64_t read64(const uint8_t *p) { uint64_t v; __builtin_memcpy(&v, p, 8); return v; }

/* CountMatch in sylz.pas: the common prefix of a and b, a not read at or
   past limit (b is behind a) */
static intptr_t count_match(const uint8_t *a, const uint8_t *b, const uint8_t *limit)
{
    const uint8_t *start = a;
    while (limit - a >= 8) {
        uint64_t diff = read64(a) ^ read64(b);
        if (diff)
            return (a - start) + (__builtin_ctzll(diff) >> 3);
        a += 8;
        b += 8;
    }
    while (a < limit && *a == *b) {
        a++;
        b++;
    }
    return a - start;
}

/* FastDist in sylz.pas: the distance from pos to a stored low-16-bit
   position, 0 meaning 65536 */
static intptr_t fast_dist(intptr_t pos, uint16_t stored)
{
    intptr_t d = (uint32_t)(pos - stored) & 0xFFFF;
    return d ? d : 65536;
}

/* The encoder's output streams (TEmit's write pointers). */
typedef struct {
    uint8_t *ctrl, *lit;          /* control and literal write pointers */
    const uint8_t *srcEnd;        /* bounds the wide literal reads */
    const uint8_t *exact;         /* ExactCode[0..EXACT_LL][0..EXACT_M] */
} sylzc_emit;

static void put_ext(uint8_t **pp, intptr_t v)
{
    uint8_t *p = *pp;
    while (v >= 255) {
        *p++ = 255;
        v -= 255;
    }
    *p++ = (uint8_t)v;
    *pp = p;
}

/* EmitSequence in sylz.pas without its capacity check: callers only take
   the C path when dst holds SylzBound(n). */
static void emit_sequence(sylzc_emit *e, const uint8_t *lit, intptr_t litLen,
                          intptr_t dist, intptr_t matchLen)
{
    intptr_t m = matchLen - MINMATCH;
    uint8_t *c = e->ctrl;
    uint8_t *p = c + 3;
    int code = 255;
    c[1] = (uint8_t)(dist - 1);
    c[2] = (uint8_t)((dist - 1) >> 8);
    if (litLen <= EXACT_LL && m <= EXACT_M)
        code = e->exact[litLen * (EXACT_M + 1) + m];
    if (code != 255)
        c[0] = (uint8_t)code;
    else if (litLen <= EXACT_LL) {
        c[0] = (uint8_t)(ESC_ML + litLen);
        put_ext(&p, m);
    } else if (m <= EXACT_M) {
        c[0] = (uint8_t)(ESC_LL + m);
        put_ext(&p, litLen);
    } else {
        c[0] = ESC_BOTH;
        put_ext(&p, litLen);
        put_ext(&p, m);
    }
    e->ctrl = p;
    /* the scratch buffer has 16 spare bytes */
    if (litLen <= 16 && e->srcEnd - lit >= 16)
        copy16(e->lit, lit);
    else
        for (intptr_t i = 0; i < litLen; i++)
            e->lit[i] = lit[i];
    e->lit += litLen;
}

/* ── levels 0-1 ───────────────────────────────────────────────────────── */

#define SKIP_STRENGTH 6

/* HashFast in sylz.pas: 6 bytes where a 64-bit multiply is cheap, else 4 */
static uint32_t hash_fast(const uint8_t *p, int hashLog)
{
#if UINTPTR_MAX > 0xFFFFFFFFu
    return (uint32_t)(((read64(p) << 16) * 889523592379ull) >> (64 - hashLog));
#else
    return (uint32_t)(read32(p) * 2654435761u) >> (32 - hashLog);
#endif
}

/* In/out of sylzc_compress_fast (TFastCState in sylz.pas). */
typedef struct {
    const uint8_t *src;
    intptr_t n;
    uint16_t *table;
    intptr_t hashLog;
    intptr_t anchor;              /* out: start of the tail literals */
    sylzc_emit e;
} sylzc_fast;

/* CompressFastCore in sylz.pas, same output byte for byte; positions are
   offsets (fwd can run past the input, a pointer could not). */
void sylzc_compress_fast(sylzc_fast *st)
{
    const uint8_t *src = st->src;
    intptr_t n = st->n;
    uint16_t *table = st->table;
    int hashLog = (int)st->hashLog;
    sylzc_emit e = st->e;
    intptr_t anchor = 0, ip, fwd, ref = 0, d, len, probes, mflimit;
    uint32_t h, fwdH;

    if (n < 12 + 1)
        goto done;
    mflimit = n - 12;
    ip = 1;
    fwdH = hash_fast(src + ip, hashLog);
    for (;;) {
        /* find a match; the probe step grows with the number of misses */
        fwd = ip;
        probes = 1 << SKIP_STRENGTH;
        for (;;) {
            h = fwdH;
            ip = fwd;
            fwd += probes >> SKIP_STRENGTH;
            probes++;
            if (fwd > mflimit)
                goto done;
            d = fast_dist(ip, table[h]);
            fwdH = hash_fast(src + fwd, hashLog);
            table[h] = (uint16_t)ip;
            ref = ip - d;
            if (d <= ip && read32(src + ref) == read32(src + ip))
                break;
        }
        while (ip > anchor && ref > 0 && src[ip - 1] == src[ref - 1]) {
            ip--;
            ref--;
        }
        /* emit, then chain straight into a match at the next position */
        for (;;) {
            len = MINMATCH + count_match(src + ip + MINMATCH, src + ref + MINMATCH, src + n);
            emit_sequence(&e, src + anchor, ip - anchor, ip - ref, len);
            ip += len;
            anchor = ip;
            if (ip > mflimit)
                goto done;
            table[hash_fast(src + ip - 2, hashLog)] = (uint16_t)(ip - 2);
            h = hash_fast(src + ip, hashLog);
            d = fast_dist(ip, table[h]);
            table[h] = (uint16_t)ip;
            ref = ip - d;
            if (d > ip || read32(src + ref) != read32(src + ip))
                break;
        }
        ip++;
        fwdH = hash_fast(src + ip, hashLog);
    }
done:
    st->anchor = anchor;
    st->e = e;
}

/* ── levels 2-3 ───────────────────────────────────────────────────────── */

static uint32_t hash4(uint32_t v, int hashLog)
{
    return (uint32_t)(v * 2654435761u) >> (32 - hashLog);
}

/* MidHashLong / MidHashShort in sylz.pas */
static uint32_t mid_hash_long(const uint8_t *p, int hashLog)
{
#if UINTPTR_MAX > 0xFFFFFFFFu
    return (uint32_t)(((read64(p) << 16) * 889523592379ull) >> (64 - hashLog));
#else
    return hash4(read32(p) + (uint32_t)(read32(p + 2) * 2246822519u), hashLog);
#endif
}

static uint32_t mid_hash_short(const uint8_t *p, int hashLog)
{
    return hash4(read32(p), hashLog);
}

/* MidCand in sylz.pas: looks up and replaces table[h] with pos; the
   candidate's distance if its first 4 bytes match, else 0 */
static intptr_t mid_cand(uint16_t *table, uint32_t h, const uint8_t *src, intptr_t pos)
{
    intptr_t d = fast_dist(pos, table[h]);
    table[h] = (uint16_t)pos;
    if (d > pos || read32(src + pos - d) != read32(src + pos))
        return 0;
    return d;
}

/* In/out of sylzc_compress_mid (TMidCState in sylz.pas). */
typedef struct {
    const uint8_t *src;
    intptr_t n;
    uint16_t *tl, *ts;            /* long and short tables */
    intptr_t hashLog;
    intptr_t lazy;                /* level 3 */
    intptr_t skip, lazyEnough, nextBelow;   /* MID_SKIP, MID_LAZY_ENOUGH, MID_NEXT_BELOW */
    intptr_t anchor;              /* out */
    sylzc_emit e;
} sylzc_mid;

/* CompressMidCore in sylz.pas, same output byte for byte. */
void sylzc_compress_mid(sylzc_mid *st)
{
    const uint8_t *src = st->src;
    intptr_t n = st->n;
    uint16_t *tl = st->tl, *ts = st->ts;
    int hashLog = (int)st->hashLog;
    sylzc_emit e = st->e;
    intptr_t anchor = 0, pos, len, dist, len2, dist2, dshort, k, mend, mflimit;

    if (n < 12 + 1)
        goto done;
    mflimit = n - 12;
    pos = 0;
    while (pos < mflimit) {
        dist = mid_cand(tl, mid_hash_long(src + pos, hashLog), src, pos);
        if (dist > 0)
            ts[mid_hash_short(src + pos, hashLog)] = (uint16_t)pos;
        else {
            dist = mid_cand(ts, mid_hash_short(src + pos, hashLog), src, pos);
            if (dist == 0) {
                pos += 1 + ((pos - anchor) >> st->skip);
                continue;
            }
        }
        len = MINMATCH + count_match(src + pos + MINMATCH, src + pos - dist + MINMATCH, src + n);
        if (st->lazy) {
            /* both tables one byte later, while that finds a longer match */
            while (len < st->lazyEnough && pos + 1 < mflimit) {
                k = pos + 1;
                dist2 = mid_cand(tl, mid_hash_long(src + k, hashLog), src, k);
                dshort = mid_cand(ts, mid_hash_short(src + k, hashLog), src, k);
                if (dist2 == 0)
                    dist2 = dshort;
                if (dist2 == 0)
                    break;
                len2 = MINMATCH + count_match(src + k + MINMATCH, src + k - dist2 + MINMATCH, src + n);
                if (len2 <= len)
                    break;
                pos = k;
                len = len2;
                dist = dist2;
            }
        } else if (len < st->nextBelow && pos + 1 < mflimit) {
            /* a short match: a long one one byte later? */
            k = pos + 1;
            dist2 = mid_cand(tl, mid_hash_long(src + k, hashLog), src, k);
            if (dist2 > 0) {
                len2 = MINMATCH + count_match(src + k + MINMATCH, src + k - dist2 + MINMATCH, src + n);
                if (len2 > len) {
                    pos = k;
                    len = len2;
                    dist = dist2;
                }
            }
        }
        while (pos > anchor && pos > dist && src[pos - 1] == src[pos - 1 - dist]) {
            pos--;
            len++;
        }
        emit_sequence(&e, src + anchor, pos - anchor, dist, len);
        mend = pos + len;
        if (mend < mflimit) {
            tl[mid_hash_long(src + pos + 1, hashLog)] = (uint16_t)(pos + 1);
            ts[mid_hash_short(src + pos + 2, hashLog)] = (uint16_t)(pos + 2);
            tl[mid_hash_long(src + mend - 2, hashLog)] = (uint16_t)(mend - 2);
            ts[mid_hash_short(src + mend - 1, hashLog)] = (uint16_t)(mend - 1);
        }
        pos = mend;
        anchor = pos;
    }
done:
    st->anchor = anchor;
    st->e = e;
}

/* ── levels 4-8: the hash-chain search ────────────────────────────────── */

#define HC_HASHLOG 16
#define HC_MAXDIST 65535

/* THcState in sylz.pas */
typedef struct {
    const uint8_t *src, *iend;
    uint16_t *head, *chain;
    intptr_t nextToInsert;
    intptr_t pos, lowLimit, longest;   /* in; longest in/out */
    intptr_t mpos, spos;               /* out */
    intptr_t attempts;
} sylzc_hc;

/* HcSearchPas in sylz.pas: insert the positions before pos, then the
   longest match through pos among `attempts` chain candidates, which may
   start before pos down to lowLimit. Same results. */
void sylzc_hc_search(sylzc_hc *s)
{
    const uint8_t *src = s->src, *iend = s->iend;
    uint16_t *head = s->head, *chain = s->chain;
    intptr_t pos = s->pos, lowLimit = s->lowLimit, longest = s->longest;
    intptr_t i, d, cand, tries;

    for (i = s->nextToInsert; i < pos; i++) {
        uint32_t h = hash4(read32(src + i), HC_HASHLOG);
        d = fast_dist(i, head[h]);
        if (d > i || d > HC_MAXDIST)
            d = 0;                     /* 0 terminates the chain */
        chain[i & 0xFFFF] = (uint16_t)d;
        head[h] = (uint16_t)i;
    }
    s->nextToInsert = pos;

    const uint8_t *ip = src + pos;
    uint32_t first = read32(ip);
    d = fast_dist(pos, head[hash4(first, HC_HASHLOG)]);
    cand = (d > pos || d > HC_MAXDIST) ? -1 : pos - d;
    tries = s->attempts;
    while (tries > 0 && cand >= 0 && pos - cand <= HC_MAXDIST) {
        if (read32(src + cand) == first) {
            intptr_t fwd = MINMATCH + count_match(ip + MINMATCH, src + cand + MINMATCH, iend);
            intptr_t back = 0;
            while (pos - back > lowLimit && cand - back > 0
                   && src[pos - back - 1] == src[cand - back - 1])
                back++;
            if (fwd + back > longest) {
                longest = fwd + back;
                s->mpos = cand - back;
                s->spos = pos - back;
            }
        }
        tries--;
        d = chain[cand & 0xFFFF];
        if (d == 0)
            break;
        cand -= d;
    }
    s->longest = longest;
}

/* ── levels 9-10: the binary tree ─────────────────────────────────────── */

#define BT_HASHLOG 16
#define BT_WINDOW  65536
#define OPT_MAXCAND 64

/* TBtState in sylz.pas */
typedef struct {
    const uint8_t *src, *iend;
    uint32_t *head, *son;
    intptr_t nextToInsert;
    intptr_t cut, maxLen;
    intptr_t pos;
    int32_t *cands;
    intptr_t count;               /* out */
} sylzc_bt;

/* BtInsertPas in sylz.pas: insert pos into the tree; with cands, record
   every match longer than the previous one as (length, distance). */
void sylzc_bt_insert(sylzc_bt *b)
{
    const uint8_t *src = b->src;
    intptr_t pos = b->pos;
    const uint8_t *cur = src + pos;
    int32_t *cands = b->cands;
    intptr_t lenLimit = b->iend - cur, count = 0;
    if (lenLimit > b->maxLen)
        lenLimit = b->maxLen;
    uint32_t h = hash4(read32(cur), BT_HASHLOG);
    intptr_t curMatch = (intptr_t)b->head[h] - 1;
    b->head[h] = (uint32_t)(pos + 1);
    uint32_t *ptr1 = b->son + ((pos & (BT_WINDOW - 1)) << 1);
    uint32_t *ptr0 = ptr1 + 1;
    intptr_t len0 = 0, len1 = 0, best = MINMATCH - 1, cut = b->cut;
    for (;;) {
        intptr_t delta = pos - curMatch;
        if (curMatch < 0 || cut == 0 || delta >= BT_WINDOW) {
            *ptr0 = 0;
            *ptr1 = 0;
            break;
        }
        cut--;
        uint32_t *pair = b->son + ((curMatch & (BT_WINDOW - 1)) << 1);
        const uint8_t *pb = cur - delta;
        intptr_t len = len0 < len1 ? len0 : len1;
        if (pb[len] == cur[len]) {
            len++;
            while (len < lenLimit && pb[len] == cur[len])
                len++;
            if (len > best) {
                best = len;
                if (cands && count < OPT_MAXCAND) {
                    cands[2 * count] = (int32_t)len;
                    cands[2 * count + 1] = (int32_t)delta;
                    count++;
                }
                if (len >= lenLimit) {
                    *ptr1 = pair[0];
                    *ptr0 = pair[1];
                    break;
                }
            }
        }
        if (pb[len] < cur[len]) {
            *ptr1 = (uint32_t)(curMatch + 1);
            ptr1 = pair + 1;
            curMatch = (intptr_t)*ptr1 - 1;
            len1 = len;
        } else {
            *ptr0 = (uint32_t)(curMatch + 1);
            ptr0 = pair;
            curMatch = (intptr_t)*ptr0 - 1;
            len0 = len;
        }
    }
    b->count = count;
}

/* ── levels 4-8: lz4hc's parse ────────────────────────────────────────── */

#define HCW_OPTIMAL_ML 18

/* In/out of sylzc_compress_hc (THcCState in sylz.pas). search is the
   chain search to use: the x86_64 assembler one (it follows the C calling
   convention) or sylzc_hc_search. */
typedef struct {
    sylzc_hc *s;
    void (*search)(sylzc_hc *);
    intptr_t anchor;              /* out */
    sylzc_emit e;
} sylzc_hcparse;

static intptr_t hc_find(sylzc_hcparse *st, intptr_t pos, intptr_t lowLimit, intptr_t longest)
{
    st->s->pos = pos;
    st->s->lowLimit = lowLimit;
    st->s->longest = longest;
    st->search(st->s);
    return st->s->longest;
}

/* Emit in CompressHCCore: a match shorter than MINMATCH stays literals */
static void hc_emit(sylzc_hcparse *st, intptr_t p, intptr_t len, intptr_t r)
{
    if (len < MINMATCH)
        return;
    emit_sequence(&st->e, st->s->src + st->anchor, p - st->anchor, p - r, len);
    st->anchor = p + len;
}

/* CompressHCCore in sylz.pas (LZ4HC_compress_hashChain), same output; the
   state machine as there: 0 search at pos, 2 / 3 lz4hc's _Search2 /
   _Search3. The caller set s's src, iend, nextToInsert and attempts. */
void sylzc_compress_hc(sylzc_hcparse *st)
{
    sylzc_hc *s = st->s;
    intptr_t n = s->iend - s->src;
    intptr_t mfl, pos = 0, ml = 0, ref = 0, ml0 = 0, ref0 = 0, start0 = 0,
             ml2 = 0, ref2 = 0, start2 = 0, ml3 = 0, ref3 = 0, start3 = 0,
             newMl, corr;
    int state = 0;

    st->anchor = 0;
    if (n < 12 + 1)
        return;
    mfl = n - 12;
    while (pos < mfl) {
        if (state == 0) {
            ml = hc_find(st, pos, pos, MINMATCH - 1);
            if (ml < MINMATCH) {
                pos++;
                continue;
            }
            ref = s->mpos;
            start0 = pos; ref0 = ref; ml0 = ml;
            state = 2;
        }
        if (state == 2) {
            if (pos + ml <= mfl) {
                ml2 = hc_find(st, pos + ml - 2, pos, ml);
                ref2 = s->mpos;
                start2 = s->spos;
            } else
                ml2 = ml;
            if (ml2 == ml) {
                hc_emit(st, pos, ml, ref);
                pos += ml;
                state = 0;
                continue;
            }
            if (start0 < pos && start2 < pos + ml0) {
                pos = start0; ref = ref0; ml = ml0;
            }
            if (start2 - pos < 3) {
                ml = ml2; pos = start2; ref = ref2;
                continue;   /* state 2 again */
            }
            state = 3;
        }
        /* state 3: ml2 > ml, ml >= MINMATCH */
        if (start2 - pos < HCW_OPTIMAL_ML) {
            newMl = ml;
            if (newMl > HCW_OPTIMAL_ML)
                newMl = HCW_OPTIMAL_ML;
            if (pos + newMl > start2 + ml2 - MINMATCH)
                newMl = start2 - pos + ml2 - MINMATCH;
            corr = newMl - (start2 - pos);
            if (corr > 0) {
                start2 += corr; ref2 += corr; ml2 -= corr;
            }
        }
        if (start2 + ml2 <= mfl) {
            ml3 = hc_find(st, start2 + ml2 - 3, start2, ml2);
            ref3 = s->mpos;
            start3 = s->spos;
        } else
            ml3 = ml2;
        if (ml3 == ml2) {
            /* no better match: ML1 then ML2 */
            if (start2 < pos + ml)
                ml = start2 - pos;
            hc_emit(st, pos, ml, ref);
            hc_emit(st, start2, ml2, ref2);
            pos = start2 + ml2;
            state = 0;
            continue;
        }
        if (start3 < pos + ml + 3) {
            /* no room for match 2 */
            if (start3 >= pos + ml) {
                if (start2 < pos + ml) {
                    corr = pos + ml - start2;
                    start2 += corr; ref2 += corr; ml2 -= corr;
                    if (ml2 < MINMATCH) {
                        start2 = start3; ref2 = ref3; ml2 = ml3;
                    }
                }
                hc_emit(st, pos, ml, ref);
                pos = start3; ref = ref3; ml = ml3;
                start0 = start2; ref0 = ref2; ml0 = ml2;
                state = 2;
                continue;
            }
            start2 = start3; ref2 = ref3; ml2 = ml3;
            state = 3;
            continue;
        }
        /* three ascending matches: write the first */
        if (start2 < pos + ml) {
            if (start2 - pos < HCW_OPTIMAL_ML) {
                if (ml > HCW_OPTIMAL_ML)
                    ml = HCW_OPTIMAL_ML;
                if (pos + ml > start2 + ml2 - MINMATCH)
                    ml = start2 - pos + ml2 - MINMATCH;
                corr = ml - (start2 - pos);
                if (corr > 0) {
                    start2 += corr; ref2 += corr; ml2 -= corr;
                }
            } else
                ml = start2 - pos;
        }
        hc_emit(st, pos, ml, ref);
        pos = start2; ref = ref2; ml = ml2;
        start2 = start3; ref2 = ref3; ml2 = ml3;
        state = 3;
    }
}

/* ── levels 9-10: the candidate pass ──────────────────────────────────── */

/* In/out of sylzc_opt_cands (TOptCandsC in sylz.pas): the first pass of
   CompressOptCore's window, BtFindAll included. insert is the tree insert
   to use (the x86_64 assembler one, or sylzc_bt_insert). */
typedef struct {
    sylzc_bt *b;
    void (*insert)(sylzc_bt *);
    intptr_t start, w;            /* in; w out, cut at a forced match */
    intptr_t sufficient, skipLen;
    int32_t *cands, *off, *cnt;
    intptr_t forced, forcedLen, forcedDist;   /* out */
} sylzc_optcands;

/* BtFindAll in sylz.pas: insert the positions before pos, then pos with
   its candidates; a match that reached the tree's compare length goes on
   as far as the bytes do. */
static intptr_t bt_find_all(sylzc_optcands *st, intptr_t pos, int32_t *cands)
{
    sylzc_bt *b = st->b;
    while (b->nextToInsert < pos) {
        b->pos = b->nextToInsert;
        b->cands = 0;
        st->insert(b);
        b->nextToInsert++;
    }
    b->pos = pos;
    b->cands = cands;
    st->insert(b);
    b->nextToInsert = pos + 1;
    intptr_t k = b->count;
    if (k > 0) {
        intptr_t len = cands[2 * (k - 1)];
        if (len >= b->maxLen) {
            intptr_t dist = cands[2 * (k - 1) + 1];
            const uint8_t *cur = b->src + pos;
            len += count_match(cur + len, cur + len - dist, b->iend);
            cands[2 * (k - 1)] = (int32_t)len;
        }
    }
    return k;
}

/* Pass 1 of CompressOptCore's window in sylz.pas, same results. */
void sylzc_opt_cands(sylzc_optcands *st)
{
    intptr_t w = st->w, total = 0, i = 0, k, len, j;
    int32_t *cands = st->cands, *off = st->off, *cnt = st->cnt;
    st->forced = 0;
    st->forcedLen = 0;
    st->forcedDist = 0;
    while (i < w) {
        k = bt_find_all(st, st->start + i, cands + 2 * total);
        off[i] = (int32_t)total;
        cnt[i] = (int32_t)k;
        if (k > 0) {
            len = cands[2 * (total + k - 1)];
            if (len >= st->sufficient) {
                st->forced = 1;
                st->forcedLen = len;
                st->forcedDist = cands[2 * (total + k - 1) + 1];
                w = i;
                break;
            }
            total += k;
            /* inside a long match: skip to its end (see sylz.pas) */
            if (len >= st->skipLen && i + len <= w) {
                for (j = i + 1; j < i + len; j++)
                    cnt[j] = -1;
                i += len - 1;
            }
        }
        i++;
    }
    st->w = w;
}
