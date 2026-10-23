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

static void copy8(uint8_t *d, const uint8_t *s) { __builtin_memcpy(d, s, 8); }
static void copy16(uint8_t *d, const uint8_t *s) { __builtin_memcpy(d, s, 16); }

/* DecodeSafe in sylz.pas: exact, fully checked, to the end of the block */
static intptr_t decode_safe(const uint8_t *ctrl, const uint8_t *cend,
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
intptr_t sylzc_decode(const uint8_t *ctrl, const uint8_t *cend,
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
