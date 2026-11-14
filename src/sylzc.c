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
    int32_t seq, esc, shortOff;   /* penalties, bits */
    int32_t scale;      /* OPT_SCALE: a byte's price */
    const int32_t *litPrice;      /* a literal's price by byte value, bits */
    const uint8_t *wsrc;          /* the window's input */
} sylzc_dpargs;

static int32_t ext_bytes(int32_t v) { return v / 255 + 1; }

/* LitStep in sylz.pas */
static int32_t lit_step(int32_t ll, const sylzc_dpargs *a)
{
    int32_t s = a->scale;
    if (ll < a->exactLL)
        return s;
    if (ll == a->exactLL)
        return s * (1 + ext_bytes(ll + 1)) + a->esc;
    return s * (1 + ext_bytes(ll + 1) - ext_bytes(ll));
}

/* MatchCost in sylz.pas for a length past mtab (so past the exact codes) */
static int32_t long_match_cost(int32_t ll, int32_t ml, int32_t dist,
                               const sylzc_dpargs *a)
{
    int32_t m = ml - a->minMatch;
    int32_t r = a->scale * (3 + ext_bytes(m)) + a->seq;
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
        /* the byte's price, and what the run's growing costs beyond a byte */
        int32_t tc = cost + a->litPrice[a->wsrc[i]] + lit_step(ll, a) - a->scale;
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
/* EXT_LIMIT and EXT_CAPPED in sylz.pas: an extension summing past this
   is corrupt; only a 32-bit intptr_t can reach it (and wrap). */
#define EXT_LIMIT (INTPTR_MAX >> 1)
#define EXT_OVER(v) (sizeof(intptr_t) < 8 && (v) > EXT_LIMIT)

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
static uint16_t read16(const uint8_t *p) { uint16_t v; __builtin_memcpy(&v, p, 2); return v; }

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
                if (EXT_OVER(ll))
                    return -1;
            } while (b == 255);
        }
        if (e & TOK_MLEXT) {
            uint8_t b;
            do {
                if (ctrl >= cend)
                    return -1;
                b = *ctrl++;
                ml += b;
                if (EXT_OVER(ml))
                    return -1;
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
                    if (EXT_OVER(ll)) { ll = -1; break; }
                } while (m[-1] == 255);
            }
            if ((e & TOK_MLEXT) && ll >= 0) {
                do {
                    if (m >= cend) { ll = -1; break; }
                    ml += *m++;
                    if (EXT_OVER(ml)) { ll = -1; break; }
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

/* ── format v4's decoder ──────────────────────────────────────────────── */

/* SYLZ_TOKENS4 entries: bits 0..7 literals, 8..15 match length, 16..23
   the offset bytes the sequence takes (2 or 0), 24 / 25 the extension
   flags */
#define TOK4_LLEXT 0x1000000u
#define TOK4_MLEXT 0x2000000u
#define MAXDIST 65536   /* SYLZ_MAXDIST */
/* the output, 512 bytes ahead of p (an address, never used as a pointer) */
#define PREFETCH(p) __builtin_prefetch((const void *)((uintptr_t)(p) + 512))

/* TDecode4State in sylz.pas */
typedef struct {
    const uint8_t *tok, *offp, *lit;
    uint8_t *op;
    const uint8_t *tend, *offend, *lend;
    uint8_t *oend, *dst;
    intptr_t rep;
    intptr_t status;
    const uint32_t *tokens;
    const uint32_t *fast;
    const uint8_t *offs0;
    const void *shorts;
    /* (format v5's literal fields follow; only sylz.pas reads them) */
} sylzc_d4;

/* A match of any length at a distance under 16, in 8-byte steps (ml may
   be 0: nothing kept) */
DECODER_INLINE uint8_t *copy_short(uint8_t *op, uintptr_t off, intptr_t ml)
{
    static const uint8_t period[8] = {0, 8, 8, 9, 8, 10, 12, 14};
    const uint8_t *m = op - off;
    if (off < 8) {
        /* the first 8 bytes one by one; they repeat with period off, so
           the rest copies from the nearest multiple of off that is >= 8 */
        op[0] = m[0]; op[1] = m[1]; op[2] = m[2]; op[3] = m[3];
        op[4] = m[4]; op[5] = m[5]; op[6] = m[6]; op[7] = m[7];
        op += 8;
        m = op - period[off];
        ml -= 8;
    }
    while (ml > 0) {
        copy8(op, m);
        op += 8;
        m += 8;
        ml -= 8;
    }
    return op + ml;
}

/* The same for an exact code's match (32 bytes at most), with no loop:
   8-byte steps that each read what the one before wrote, 16 bytes, and
   16 more for a match over 16. Under 8 the first step is the period
   spread over 8 bytes by a multiplication (the low `off` bytes, times a
   1 in every byte a copy of them starts at), and the others read the
   nearest multiple of off that is >= 8 back. */
DECODER_INLINE void copy_short32(uint8_t *op, uintptr_t off, uintptr_t ml)
{
    static const uint8_t period[8] = {0, 8, 8, 9, 8, 10, 12, 14};
    static const uint64_t spread[8] = {
        0, 0x0101010101010101u, 0x0001000100010001u, 0x0001000001000001u,
        0x0000000100000001u, 0x0000010000000001u, 0x0001000000000001u,
        0x0100000000000001u};
    const uint8_t *m = op - off;
    if (off >= 8)
        copy8(op, m);
    else {
        uint64_t v;
        __builtin_memcpy(&v, m, 8);
        v = (v & (~(uint64_t)0 >> (64 - 8 * off))) * spread[off];
        __builtin_memcpy(op, &v, 8);
        m = op - period[off];
    }
    copy8(op + 8, m + 8);
    if (ml > 16) {
        copy8(op + 16, m + 16);
        copy8(op + 24, m + 24);
    }
}

/* The fast loop of format v4's decoder (DecodeFast4Pas in sylz.pas): 0
   when it stops, with everything at the token it stopped at, or -1 on
   corrupt input. The block must have read an offset (DecodeChunk4 does
   the sequences before that).

   The fast loop: a sequence with an exact code takes one token, at most
   2 offset bytes and 16 literals, and writes inside 64 bytes of output
   (16 literal bytes, then 32 match bytes after at most 16 literals), so
   k = min(tokens, offset bytes / 2, literals / 16, output / 64) of them
   need no bounds check: the inner loop counts k down. Once the block has
   read an offset, the previous distance is the offset before the next one in the stream: a
   token advances the stream by the bytes it takes and reads the two
   before it, with nothing to choose. One test sends a token off the
   straight path: a distance under 16, or, in the block's first
   SYLZ_MAXDIST bytes, any distance (`far` is 0 there), since only then
   can one reach before the output's start. The output is fetched 512
   bytes ahead: its lines are new to the cache, and the stores wait for
   them otherwise. An escape is checked on its own, then k is counted
   again. The loop stops when k = 0 or an escape has no room for the
   wide copies: the caller (DecodeChunk4) takes it from there, exactly,
   and refills format v5's literals. */
DECODER_INLINE intptr_t decode4_core(sylzc_d4 *st)
{
    const uint32_t *tokens = st->tokens;
    const uint8_t *tok = st->tok, *tend = st->tend;
    const uint8_t *offp = st->offp, *offend = st->offend;
    const uint8_t *lit = st->lit, *lend = st->lend;
    uint8_t *op = st->op, *oend = st->oend, *dst = st->dst;
    uintptr_t rep = (uintptr_t)st->rep;

    for (;;) {
        intptr_t k = tend - tok, c;
        c = (offend - offp) >> 1;
        if (c < k) k = c;
        c = (lend - lit) >> 4;
        if (c < k) k = c;
        c = (oend - op) >> 6;
        if (c < k) k = c;
        if (k <= 0)
            break;
        uintptr_t far = MAXDIST;
        if (op - dst < MAXDIST) {
            /* a few sequences, then count again */
            far = 0;
            if (k > 16) k = 16;
        }
        do {
            uint32_t e = tokens[*tok];
            if (__builtin_expect(e > 0xFFFFFF, 0))
                goto escape;
            tok++;
            copy16(op, lit);
            op += e & 0xFF;
            lit += e & 0xFF;
            offp += (e >> 16) & 0xFF;   /* 2 or 0 */
            rep = (uintptr_t)read16(offp - 2) + 1;
            const uint8_t *m = op - rep;
            if (__builtin_expect(rep - 16 >= far, 0)) {
                if (rep > (uintptr_t)(op - dst))
                    return -1;
                if (rep < 16) {
                    copy_short32(op, rep, (e >> 8) & 0xFF);
                    goto matched;
                }
            }
            copy16(op, m);
            copy16(op + 16, m + 16);
matched:
            op += (e >> 8) & 0xFF;
            PREFETCH(op);
        } while (--k);
        continue;
escape:
        {
            /* extended field(s): read through m, so giving up leaves
               everything at the token, nothing written yet */
            uint32_t e = tokens[*tok];
            const uint8_t *m = tok + 1;
            intptr_t ll = e & 0xFF, ml = (e >> 8) & 0xFF;
            uintptr_t off = rep;
            if (e & TOK4_LLEXT) {
                do {
                    if (m >= tend) { ll = -1; break; }
                    ll += *m++;
                    if (EXT_OVER(ll)) { ll = -1; break; }
                } while (m[-1] == 255);
            }
            if ((e & TOK4_MLEXT) && ll >= 0) {
                do {
                    if (m >= tend) { ll = -1; break; }
                    ml += *m++;
                    if (EXT_OVER(ml)) { ll = -1; break; }
                } while (m[-1] == 255);
            }
            /* room for the wide copies: 16 literal bytes past the run, 128
               output bytes past the sequence */
            if (ll < 0 || ll > lend - lit - 16 || ll + ml > oend - op - 128)
                break;   /* the caller does this sequence exactly */
            if (e & 0xFF0000) {
                /* k > 0: the offset stream has these 2 bytes */
                off = (uintptr_t)read16(offp) + 1;
                offp += 2;
            }
            tok = m;
            if (__builtin_expect(lend - lit >= 128, 1)) {
                /* 128 bytes with no test on the run's length: most runs
                   end in them, and a loop's exit would be mispredicted
                   for nearly every run */
                intptr_t i;
                for (i = 0; i < 128; i += 16)
                    copy16(op + i, lit + i);
                /* past the run only its 16 bytes of room are there */
                for (; i + 16 < ll; i += 32) {
                    copy16(op + i, lit + i);
                    copy16(op + i + 16, lit + i + 16);
                    PREFETCH(op + i);
                }
                if (i < ll)
                    copy16(op + i, lit + i);
            } else {
                for (intptr_t i = 0; i < ll; i += 16)
                    copy16(op + i, lit + i);
            }
            op += ll;
            lit += ll;
            rep = off;
            if (off > (uintptr_t)(op - dst))
                return -1;
            if (off >= 16) {
                const uint8_t *s = op - off;
                copy16(op, s);
                copy16(op + 16, s + 16);
                if (ml > 32) {
                    /* the same for a match: 128 bytes in all, then a loop */
                    for (int i = 32; i < 128; i += 16)
                        copy16(op + i, s + i);
                    for (intptr_t i = 128; i < ml; i += 32) {
                        copy16(op + i, s + i);
                        copy16(op + i + 16, s + i + 16);
                        PREFETCH(op + i);
                    }
                }
                op += ml;
            } else
                op = copy_short(op, off, ml);
        }
    }
    st->tok = tok;
    st->offp = offp;
    st->lit = lit;
    st->op = op;
    st->rep = (intptr_t)rep;
    return 0;
}

#if defined(__i386__) && !defined(SYLZC_NO_SSE2)
__attribute__((target("sse2")))
static intptr_t decode4_sse2(sylzc_d4 *st)
{
    return decode4_core(st);
}

static intptr_t decode4_i686(sylzc_d4 *st)
{
    return decode4_core(st);
}

intptr_t sylzc_decode4(sylzc_d4 *st)
{
    int kind = decoder_kind;
    if (kind == 0) {
        unsigned a, b, c, d;
        kind = __get_cpuid(1, &a, &b, &c, &d) && (d & bit_SSE2) ? 2 : 1;
        decoder_kind = kind;
    }
    if (kind == 2)
        return decode4_sse2(st);
    return decode4_i686(st);
}
#else
intptr_t sylzc_decode4(sylzc_d4 *st)
{
    return decode4_core(st);
}
#endif

/* ── compressor helpers ───────────────────────────────────────────────── */

#define MINMATCH  4
#define EXACT_LL  15
#define EXACT_M   28
#define ESC_ML    210
#define ESC_LL    226
#define ESC_BOTH  255
#define MINREP    2      /* v4: shortest match at the previous offset */

static uint32_t read32(const uint8_t *p) { uint32_t v; __builtin_memcpy(&v, p, 4); return v; }
static uint64_t read64(const uint8_t *p) { uint64_t v; __builtin_memcpy(&v, p, 8); return v; }

/* CountMatch in sylz.pas: the common prefix of a and b, a not read at or
   past limit (b is behind a) */
static inline __attribute__((always_inline)) intptr_t count_match_inl(const uint8_t *a,
    const uint8_t *b, const uint8_t *limit)
{
    const uint8_t *start = a;
    while (limit - a >= 8) {
        uint64_t diff = read64(a) ^ read64(b);
        if (diff) {
#if UINTPTR_MAX == 0xFFFFFFFF && !defined(_WIN32)
            /* two 32-bit counts: some gcc versions (Ubuntu's 13, -m32)
               call libgcc's __ctzdi2 for a 64-bit one, and FPC does not
               link libgcc; mingw inlines it (and the win32 plugin keeps
               its bytes) */
            uint32_t lo = (uint32_t)diff;
            return (a - start) + ((lo ? __builtin_ctz(lo) : 32 + __builtin_ctz((uint32_t)(diff >> 32))) >> 3);
#else
            return (a - start) + (__builtin_ctzll(diff) >> 3);
#endif
        }
        a += 8;
        b += 8;
    }
    while (a < limit && *a == *b) {
        a++;
        b++;
    }
    return a - start;
}

static intptr_t count_match(const uint8_t *a, const uint8_t *b, const uint8_t *limit)
{
    return count_match_inl(a, b, limit);
}

/* FastDist in sylz.pas: the distance from pos to a stored low-16-bit
   position, 0 meaning 65536 */
static intptr_t fast_dist(intptr_t pos, uint16_t stored)
{
    intptr_t d = (uint32_t)(pos - stored) & 0xFFFF;
    return d ? d : 65536;
}

struct sylzc_codes4;

/* The encoder's output streams (TEmit's write pointers). */
typedef struct {
    uint8_t *ctrl, *lit;          /* control and literal write pointers */
    const uint8_t *srcEnd;        /* bounds the wide literal reads */
    const uint8_t *exact;         /* ExactCode[0..EXACT_LL][0..EXACT_M] */
    intptr_t rep;                 /* format v4: the previous sequence's distance */
    uint16_t *rec, *recEnd;       /* v4: where the next sequence is recorded */
    void (*flush)(void *);        /* v4: called with this struct when rec == recEnd,
                                     or (direct) when ctrl has reached tokEnd */
    void *owner;                  /* v4: sylz.pas's TEmit */
    /* v4, levels 0-3: a chunk is open and the sequences go into it as
       tokens at ctrl (up to tokEnd), by its codes; their offsets at off */
    intptr_t direct;
    uint8_t *tokEnd, *off;
    const struct sylzc_codes4 *codes;
} sylzc_emit;

/* TCodes4 in sylz.pas: the codes of a format v4 token table by cell,
   [0 new offset / 1 previous offset][row][column], 255 = no code (not
   asked of the cells every table has). Row: the literals, ROW4_EXT
   extended; column: the match length, COL4_EXT extended. */
#define MAX_LL4    16
#define MAX_ML4    32
#define LIT_SPLIT4 32
#define ML_SPLIT4  64
#define ROW4_EXT   (MAX_LL4 + 1)
#define COL4_EXT   (MAX_ML4 + 1)
struct sylzc_codes4 {
    uint8_t cell[2][ROW4_EXT + 1][COL4_EXT + 1];
};

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

/* EmitSequence4 in sylz.pas: the sequence is recorded (three u16:
   literals, match length, distance - 1; literals = 0xFFFF: the lengths
   follow as two u32) and its literals copied. sylz.pas writes the
   tokens, a chunk at a time. */
static void emit_sequence4(sylzc_emit *e, const uint8_t *lit, intptr_t litLen,
                           intptr_t dist, intptr_t matchLen)
{
    uint16_t *r;
    if (e->rec >= e->recEnd)
        e->flush(e);
    r = e->rec;
    r[2] = (uint16_t)(dist - 1);
    if (__builtin_expect(litLen < 0xFFFF && matchLen <= 0xFFFF, 1)) {
        r[0] = (uint16_t)litLen;
        r[1] = (uint16_t)matchLen;
        e->rec = r + 3;
    } else {
        uint32_t v;
        r[0] = 0xFFFF;
        r[1] = 0;
        v = (uint32_t)litLen;
        __builtin_memcpy(r + 3, &v, 4);
        v = (uint32_t)matchLen;
        __builtin_memcpy(r + 5, &v, 4);
        e->rec = r + 9;
    }
    e->rep = dist;
    if (litLen <= 16 && e->srcEnd - lit >= 16)
        copy16(e->lit, lit);
    else
        for (intptr_t i = 0; i < litLen; i++)
            e->lit[i] = lit[i];
    e->lit += litLen;
}

/* FindSplit4 in sylz.pas: the split of ll literals (up to LIT_SPLIT4)
   and a match of ml (up to ML_SPLIT4) that has a code, *b literals with
   the first *m bytes of the match; 0: none (the first one tried) */
static int find_split4(const struct sylzc_codes4 *t, int k, intptr_t ll, intptr_t ml,
                       intptr_t *b, intptr_t *m)
{
    intptr_t b0 = ll, bmax = ll, m0 = ml, mmin = ml, i;
    if (ll > MAX_LL4) {
        b0 = ll - MAX_LL4;
        bmax = MAX_LL4;
    }
    if (ml > MAX_ML4) {
        m0 = MAX_ML4;
        if (ml - m0 < MINREP)
            m0 = ml - MINREP;
        mmin = ml - MAX_ML4;
        if (mmin < (k ? MINREP : MINMATCH))
            mmin = k ? MINREP : MINMATCH;
    }
    *b = b0;
    *m = m0;
    if (t->cell[k][b0][m0] != 255)
        return 1;
    for (i = b0 + 1; i <= bmax; i++)
        if (t->cell[k][i][m0] != 255) {
            *b = i;
            return 1;
        }
    for (i = m0 - 1; i >= mmin; i--)
        if (t->cell[k][b0][i] != 255) {
            *m = i;
            return 1;
        }
    return 0;
}

/* PutTokens4 in sylz.pas, past its first case: a sequence with no exact
   code */
static __attribute__((noinline)) uint8_t *put_tokens4(const struct sylzc_codes4 *t,
    uint8_t *p, int k, intptr_t ll, intptr_t ml)
{
    intptr_t b, m;
    if (ll > LIT_SPLIT4) {
        if (ml <= MAX_ML4) {
            if (t->cell[k][ROW4_EXT][ml] != 255) {
                *p++ = t->cell[k][ROW4_EXT][ml];
                put_ext(&p, ll);
                return p;
            }
        } else if (t->cell[k][ROW4_EXT][COL4_EXT] != 255) {
            *p++ = t->cell[k][ROW4_EXT][COL4_EXT];
            put_ext(&p, ll);
            put_ext(&p, ml - (k ? MINREP : MINMATCH));
            return p;
        }
        *p++ = t->cell[1][ROW4_EXT][0];
        put_ext(&p, ll);
        ll = 0;
    } else if (ll > MAX_LL4 && k == 0 && ml == MINMATCH) {
        *p++ = t->cell[0][ROW4_EXT][MINMATCH];
        put_ext(&p, ll);
        return p;
    }
    if (ml > ML_SPLIT4) {
        if (ll > MAX_LL4) {
            *p++ = t->cell[1][MAX_LL4][0];
            ll -= MAX_LL4;
        }
        if (ll > 0 && t->cell[k][ll][COL4_EXT] == 255) {
            *p++ = t->cell[1][ll][0];
            ll = 0;
        }
        *p++ = t->cell[k][ll][COL4_EXT];
        put_ext(&p, ml - (k ? MINREP : MINMATCH));
        return p;
    }
    if (!find_split4(t, k, ll, ml, &b, &m))
        b = 0;
    ll -= b;
    if (ll > MAX_LL4) {
        *p++ = t->cell[1][MAX_LL4][0];
        ll -= MAX_LL4;
    }
    if (ll > 0)
        *p++ = t->cell[1][ll][0];
    *p++ = t->cell[k][b][m];
    if (ml > m)
        *p++ = t->cell[1][0][ml - m];
    return p;
}

/* The write state of a loop that emits as EmitDirect4 / EmitSequence4 do
   (levels 0-3), kept in one local of the loop: only inline code takes its
   address, so its fields can stay in registers. The emitter (sylzc_emit)
   is passed by address to the Pascal flush, and after that every byte the
   loop stores could change it as far as the compiler knows: with the
   fields read from it, gcc for arm64 loaded direct, tokEnd, codes and
   srcEnd from the stack again for each sequence. (About the same speed on
   linux-arm64; with the fields used once a sequence in memory, levels 1-2
   were 1-2% slower.) */
typedef struct {
    uint16_t *rec;                /* the next record (not direct) */
    uint8_t *tok, *off, *lit;     /* token (direct), offset and literal write pointers */
    intptr_t direct;
    const uint8_t *tokEnd;        /* direct: the open chunk's end */
    const uint16_t *recEnd;       /* the records' end */
    const uint8_t *codes;         /* sylzc_codes4, as bytes: [kind][row][column] */
    const uint8_t *srcEnd;
    uint8_t *memo;                /* direct: the split tokens (split4_memo) */
} open4_state;

#define CELLS4_KIND ((ROW4_EXT + 1) * (COL4_EXT + 1))   /* a kind's cells in sylzc_codes4 */

/* The tokens put_tokens4 writes for a sequence of up to LIT_SPLIT4
   literals and a match of up to ML_SPLIT4 (16% of the sequences at level
   0 on silesia.tar, 7% at level 2: a call each, and find_split4's search
   of the table), remembered per open chunk, whose codes do not change: a
   u32 by kind, literals and match length, the tokens in its low bytes
   (at most 4 of them) and 0xFF in the others (no code is 255), all 0xFF
   for one not asked for yet. Kept in the record buffer after the records
   of levels 0-3: 8 words after recEnd, past a long record that starts
   before it (sylz.pas checks the buffer holds it; a field of its own in
   sylzc_emit made the struct the v2 loops copy bigger, and the 32-bit v2
   level 0 4% slower). */
#define SPLIT4_MEMO_N ((LIT_SPLIT4 + 1) * (ML_SPLIT4 + 1))   /* a kind's entries */
#define SPLIT4_MEMO_BYTES (2 * SPLIT4_MEMO_N * 4)

/* every entry not asked for: by sylzc_put_chunk4, which each flush that
   leaves a chunk open calls with its table (in FlushChunk4) */
static void split4_clear(uint8_t *memo)
{
    for (intptr_t i = 0; i < SPLIT4_MEMO_BYTES; i += 8) {
        uint64_t v = ~(uint64_t)0;
        __builtin_memcpy(memo + i, &v, 8);
    }
}

/* the entry for k, ll, ml, from put_tokens4 */
static __attribute__((noinline)) uint32_t split4_fill(uint8_t *at, const uint8_t *codes,
    int k, intptr_t ll, intptr_t ml)
{
    uint8_t b[16], *end;
    uint32_t v = 0;
    end = put_tokens4((const struct sylzc_codes4 *)codes, b, k, ll, ml);
    for (intptr_t i = 3; i >= 0; i--)
        v = (v << 8) | (b + i < end ? b[i] : 255);
    __builtin_memcpy(at, &v, 4);
    return v;
}

static void open4_load(open4_state *w, const sylzc_emit *e)
{
    w->rec = e->rec;
    w->tok = e->ctrl;
    w->off = e->off;
    w->lit = e->lit;
    w->direct = e->direct;
    w->tokEnd = e->tokEnd;
    w->recEnd = e->recEnd;
    w->codes = &e->codes->cell[0][0][0];
    w->srcEnd = e->srcEnd;
    w->memo = (uint8_t *)(e->recEnd + 8);
}

static void open4_store(sylzc_emit *e, const open4_state *w, intptr_t rep)
{
    e->rec = w->rec;
    e->ctrl = w->tok;
    e->off = w->off;
    e->lit = w->lit;
    e->rep = rep;
}

/* emit_open4's way out, out of the loop's code: a full chunk is closed and
   full records are flushed, which may leave their chunk open, until one of
   them takes the sequence (the flush changes rec, tok, off, direct and
   tokEnd) */
static __attribute__((noinline)) void open4_turn(sylzc_emit *e, open4_state *w, intptr_t prev)
{
    do {
        open4_store(e, w, prev);
        e->flush(e);
        open4_load(w, e);
    } while (w->direct ? w->tok >= w->tokEnd : w->rec >= w->recEnd);
}

/* The tokens of a sequence that has no code of its own at p (by the
   memo when it is one of up to LIT_SPLIT4 literals and a match of up to
   ML_SPLIT4); returns where they end. All 4 bytes of a memo entry are
   stored, the tokens kept: the token stream stays far below dst's end
   (SylzBound counts each input byte as a literal, and these tokens cover
   2 bytes or more each). */
static inline __attribute__((always_inline)) uint8_t *put_split4(uint8_t *p,
    const uint8_t *codes, uint8_t *memo, int k, intptr_t ll, intptr_t ml)
{
    if (ll <= LIT_SPLIT4 && ml <= ML_SPLIT4) {
        uint8_t *at = memo + 4 * ((k ? SPLIT4_MEMO_N : 0) + ll * (ML_SPLIT4 + 1) + ml);
        uint32_t v;
        __builtin_memcpy(&v, at, 4);
        if (__builtin_expect(v == ~(uint32_t)0, 0))
            v = split4_fill(at, codes, k, ll, ml);
        __builtin_memcpy(p, &v, 4);
        return p + ((39 - __builtin_clz(~v)) >> 3);
    }
    return put_tokens4((const struct sylzc_codes4 *)codes, p, k, ll, ml);
}

/* emit_sequence4 for levels 0-3, where only a chunk's first sequences are
   recorded and the ones after them go into it as tokens (w->direct), as
   EmitDirect4 in sylz.pas writes them. prev: the distance before this
   sequence. */
static inline __attribute__((always_inline)) void emit_open4(sylzc_emit *e,
    open4_state *w, const uint8_t *lit, intptr_t litLen, intptr_t dist, intptr_t matchLen,
    intptr_t prev)
{
    uint8_t *d;
    if (__builtin_expect(w->direct ? w->tok >= w->tokEnd : w->rec >= w->recEnd, 0)) {
        /* (the loop's copy of w goes through memory only here) */
        open4_state t = *w;
        open4_turn(e, &t, prev);
        *w = t;
    }
    if (__builtin_expect(w->direct, 1)) {
        uint8_t *p = w->tok;
        int k = dist == prev, code = 255;
        uint16_t o = (uint16_t)(dist - 1);
        if (litLen <= MAX_LL4 && matchLen <= MAX_ML4)
            code = w->codes[(k ? CELLS4_KIND : 0) + litLen * (COL4_EXT + 1) + matchLen];
        if (__builtin_expect(code != 255, 1))
            *p++ = (uint8_t)code;
        else
            p = put_split4(p, w->codes, w->memo, k, litLen, matchLen);
        w->tok = p;
        /* little-endian, as the offset stream (every target sylz has) */
        __builtin_memcpy(w->off, &o, 2);
        w->off += 2 - 2 * k;
    } else {
        uint16_t *r = w->rec;
        r[2] = (uint16_t)(dist - 1);
        if (__builtin_expect(litLen < 0xFFFF && matchLen <= 0xFFFF, 1)) {
            r[0] = (uint16_t)litLen;
            r[1] = (uint16_t)matchLen;
            r += 3;
        } else {
            uint32_t v;
            r[0] = 0xFFFF;
            r[1] = 0;
            v = (uint32_t)litLen;
            __builtin_memcpy(r + 3, &v, 4);
            v = (uint32_t)matchLen;
            __builtin_memcpy(r + 5, &v, 4);
            r += 9;
        }
        w->rec = r;
    }
    /* 16-byte steps while the reads stay inside the input (the scratch
       stream has 16 bytes of slack), as the assembler copies them */
    d = w->lit;
    if (__builtin_expect(w->srcEnd - lit >= litLen + 16, 1)) {
        copy16(d, lit);
        for (intptr_t i = 16; i < litLen; i += 16)
            copy16(d + i, lit + i);
    } else
        for (intptr_t i = 0; i < litLen; i++)
            d[i] = lit[i];
    w->lit = d + litLen;
}

static void count_split4(const struct sylzc_codes4 *t, uint32_t *cnt, int k, intptr_t ll,
                         intptr_t ml);

/* TPut4C in sylz.pas */
typedef struct {
    const uint16_t *rec, *rend;
    uint8_t *p, *off;             /* in/out: token and offset write pointers */
    intptr_t prev;                /* in/out: the distance before the records */
    const struct sylzc_codes4 *codes;
    uint8_t *memo;                /* levels 0-3: the split tokens' memo (cleared here), or 0 */
} sylzc_put4;

/* FlushChunk4's last loop in sylz.pas, without its room checks (the
   caller has room for SylzBound): the recorded sequences' tokens and
   offsets */
void sylzc_put_chunk4(sylzc_put4 *st)
{
    const uint16_t *r = st->rec, *rend = st->rend;
    const struct sylzc_codes4 *t = st->codes;
    uint8_t *p = st->p, *off = st->off, *memo = st->memo;
    intptr_t prev = st->prev;
    if (memo)
        split4_clear(memo);
    while (r < rend) {
        intptr_t ll = r[0], ml = r[1], dist = (intptr_t)r[2] + 1;
        int k, code = 255;
        uint16_t o = (uint16_t)(dist - 1);
        r += 3;
        if (__builtin_expect(ll == 0xFFFF, 0)) {
            uint32_t v;
            __builtin_memcpy(&v, r, 4);
            ll = v;
            __builtin_memcpy(&v, r + 2, 4);
            ml = v;
            r += 6;
        }
        k = dist == prev;
        prev = dist;
        if (ll <= MAX_LL4 && ml <= MAX_ML4)
            code = t->cell[k][ll][ml];
        if (__builtin_expect(code != 255, 1))
            *p++ = (uint8_t)code;
        else if (memo)
            p = put_split4(p, &t->cell[0][0][0], memo, k, ll, ml);
        else
            p = put_tokens4(t, p, k, ll, ml);
        __builtin_memcpy(off, &o, 2);
        off += 2 - 2 * k;
    }
    st->p = p;
    st->off = off;
    st->prev = prev;
}

/* TCount4C in sylz.pas */
typedef struct {
    const uint16_t *rec, *rend;
    intptr_t prev;                /* the distance before the records */
    const struct sylzc_codes4 *codes;
    uint32_t *cnt;                /* TPairCounts4 */
} sylzc_count4;

/* CountAll4's count in sylz.pas, without its sums (FlushChunk4 wants only
   the count for a chunk it leaves open): the cell each record looks up */
void sylzc_count_chunk4(sylzc_count4 *st)
{
    const uint16_t *r = st->rec, *rend = st->rend;
    uint32_t *cnt = st->cnt;
    intptr_t prev = st->prev;
    while (r < rend) {
        intptr_t ll = r[0], ml = r[1], dist = (intptr_t)r[2] + 1;
        int k;
        r += 3;
        if (__builtin_expect(ll == 0xFFFF, 0)) {
            uint32_t v;
            __builtin_memcpy(&v, r, 4);
            ll = v;
            __builtin_memcpy(&v, r + 2, 4);
            ml = v;
            r += 6;
        }
        k = dist == prev;
        prev = dist;
        if (ll <= MAX_LL4 && ml <= MAX_ML4)
            cnt[(k * (ROW4_EXT + 1) + ll) * (COL4_EXT + 1) + ml]++;
        else
            count_split4(st->codes, cnt, k, ll, ml);
    }
}

/* ── levels 0-1 ───────────────────────────────────────────────────────── */

#define SKIP_STRENGTH 6

/* HashFast in sylz.pas: 6 bytes on every target (the same blocks on x86
   and x64; 32-bit ones hashed 4 until syc 0.5.1) */
static uint32_t hash_fast(const uint8_t *p, int hashLog)
{
    return (uint32_t)(((read64(p) << 16) * 889523592379ull) >> (64 - hashLog));
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

/* HashFast with the shift by 16 folded into the multiplier (the same
   product modulo 2^64) */
#define FAST_MULT16 (889523592379ull << 16)
/* FAST_LOG0, FAST_LOG1 in sylz.pas */
#define FAST_LOG0 13
#define FAST_LOG1 15

/* The probes as written below for gcc; clang (macOS) compiles the first
   form better (on macos-arm64 levels 0-1 were 5-6% slower with this one,
   and on linux-arm64 with gcc 4-5% faster) and keeps it */
#if defined(__clang__)
#define FAST4_PROBES_GCC 0
#else
#define FAST4_PROBES_GCC 1
#endif

/* The 4 bytes at the probe ip: on 64-bit targets carried from the load
   for its hash (cur), on 32-bit ones read again (one register more kept
   across the loop made it 9% slower on i386) */
#if UINTPTR_MAX > 0xFFFFFFFF
#define FAST4_CUR(ip) cur
#else
#define FAST4_CUR(ip) read32(src + (ip))
#endif

/* CompressFastCore4 in sylz.pas, same output byte for byte. Inlined once
   per level, with the hash shift a constant (a shift by a variable takes
   three operations on x86 without BMI2), and with the probes that step
   one byte (the first 64 after a match, the only ones that try the
   previous offset) in a loop of their own, its one counter bounded by
   both the 64 and mflimit. The candidate is ip less fast_dist's distance
   without its branch (a remainder of 0 is 65536 as the mask wraps), and
   no candidate is checked against the start of the input: an entry is an
   earlier position, or 0 (src) in the table cleared for this input, so
   below position 65536 the distance to it is exact and never reaches
   past src. */
static inline __attribute__((always_inline)) void compress_fast4(sylzc_fast *st,
    int hashLog)
{
    const uint8_t *src = st->src;
    intptr_t n = st->n;
    uint16_t *table = st->table;
    sylzc_emit e = st->e;
    open4_state w;
    intptr_t anchor = 0, ip, fwd, ref = 0, len, probes, mflimit, rep = 1;
    uint32_t h, fwdH, cur __attribute__((unused));   /* (FAST4_CUR) */
    uint64_t next;
#if FAST4_PROBES_GCC
    intptr_t lim;
#else
    intptr_t d;
    int i;
#endif

    open4_load(&w, &e);
    if (w.direct)
        split4_clear(w.memo);
    if (n < 12 + 1)
        goto done;
    mflimit = n - 12;
    ip = 1;
    next = read64(src + ip);
    for (;;) {
#if FAST4_PROBES_GCC
        /* next: the 8 bytes at ip, its hash fwdH; cur: the 4 at the probe,
           carried from the hash's load (the table stores in between could
           alias src as far as the compiler knows, so it read them again) */
        fwdH = (uint32_t)((next * FAST_MULT16) >> (64 - hashLog));
        cur = (uint32_t)next;
        /* step one byte, up to 64 probes (fwd the probe after this one):
           the previous offset one byte on, then the table's candidate */
        lim = ip + (1 << SKIP_STRENGTH);
        if (lim > mflimit)
            lim = mflimit;
        for (fwd = ip + 1; fwd <= lim; fwd++) {
            const uint8_t *q = src + fwd;
            uint32_t c;
            h = fwdH;
            ip = fwd - 1;
            next = read64(q);
            c = table[h];
            table[h] = (uint16_t)ip;
            fwdH = (uint32_t)((next * FAST_MULT16) >> (64 - hashLog));
            if (read32(q - rep) == (uint32_t)next) {
                ip = fwd;
                ref = ip - rep;
                goto found;
            }
            ref = (ip - 1) - ((ip - 1 - c) & 0xFFFF);
            if (read32(src + ref) == FAST4_CUR(ip))
                goto found;
            cur = (uint32_t)next;
        }
        if (fwd > mflimit)
            goto done;
        fwd--;
        /* then further and further */
        probes = 2 << SKIP_STRENGTH;
        for (;;) {
            uint32_t c;
            h = fwdH;
            ip = fwd;
            fwd += probes >> SKIP_STRENGTH;
            probes++;
            if (fwd > mflimit)
                goto done;
            next = read64(src + fwd);
            c = table[h];
            table[h] = (uint16_t)ip;
            fwdH = (uint32_t)((next * FAST_MULT16) >> (64 - hashLog));
            ref = (ip - 1) - ((ip - 1 - c) & 0xFFFF);
            if (read32(src + ref) == FAST4_CUR(ip))
                break;
            cur = (uint32_t)next;
        }
#else
        fwdH = (uint32_t)((next * FAST_MULT16) >> (64 - hashLog));
        fwd = ip;
        /* step one byte: the previous offset, one byte on, then the
           table's candidate */
        for (i = 0; i < (1 << SKIP_STRENGTH); i++) {
            h = fwdH;
            ip = fwd++;
            if (fwd > mflimit)
                goto done;
            d = ((ip - table[h] - 1) & 0xFFFF) + 1;
            fwdH = (uint32_t)((read64(src + fwd) * FAST_MULT16) >> (64 - hashLog));
            table[h] = (uint16_t)ip;
            if (read32(src + fwd - rep) == read32(src + fwd)) {
                ip = fwd;
                ref = ip - rep;
                goto found;
            }
            ref = ip - d;
            if (read32(src + ref) == read32(src + ip))
                goto found;
        }
        /* then further and further */
        probes = 2 << SKIP_STRENGTH;
        for (;;) {
            h = fwdH;
            ip = fwd;
            fwd += probes >> SKIP_STRENGTH;
            probes++;
            if (fwd > mflimit)
                goto done;
            d = ((ip - table[h] - 1) & 0xFFFF) + 1;
            fwdH = (uint32_t)((read64(src + fwd) * FAST_MULT16) >> (64 - hashLog));
            table[h] = (uint16_t)ip;
            ref = ip - d;
            if (read32(src + ref) == read32(src + ip))
                break;
        }
#endif
    found:
        while (ip > anchor && ref > 0 && src[ip - 1] == src[ref - 1]) {
            ip--;
            ref--;
        }
        len = MINMATCH + count_match_inl(src + ip + MINMATCH, src + ref + MINMATCH, src + n);
        emit_open4(&e, &w, src + anchor, ip - anchor, ip - ref, len, rep);
        rep = ip - ref;
        ip += len;
        anchor = ip;
        if (ip > mflimit)
            goto done;
        /* the search goes on at the match's end */
        table[(uint32_t)((read64(src + ip - 2) * FAST_MULT16) >> (64 - hashLog))] = (uint16_t)(ip - 2);
        next = read64(src + ip);
    }
done:
    open4_store(&e, &w, rep);
    st->anchor = anchor;
    st->e = e;
}

void sylzc_compress_fast4(sylzc_fast *st)
{
    if (st->hashLog == FAST_LOG0)
        compress_fast4(st, FAST_LOG0);
    else if (st->hashLog == FAST_LOG1)
        compress_fast4(st, FAST_LOG1);
    else
        compress_fast4(st, (int)st->hashLog);
}

/* ── levels 2-3 ───────────────────────────────────────────────────────── */

static uint32_t hash4(uint32_t v, int hashLog)
{
    return (uint32_t)(v * 2654435761u) >> (32 - hashLog);
}

/* MidHashLong / MidHashShort in sylz.pas */
static uint32_t mid_hash_long(const uint8_t *p, int hashLog)
{
    /* 6 bytes on every target, as MidHashLong */
    return (uint32_t)(((read64(p) << 16) * 889523592379ull) >> (64 - hashLog));
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

/* CompressMidCore in sylz.pas for format v2, same output byte for byte
   (compress_mid4_core below is v4's) */
static inline __attribute__((always_inline)) void compress_mid_core(sylzc_mid *st,
    const int hashLog, const intptr_t lazy,
    const intptr_t skip, const intptr_t lazyEnough, const intptr_t nextBelow)
{
    const uint8_t *src = st->src;
    intptr_t n = st->n;
    uint16_t *tl = st->tl, *ts = st->ts;
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
                pos += 1 + ((pos - anchor) >> skip);
                continue;
            }
        }
        len = MINMATCH + count_match(src + pos + MINMATCH, src + pos - dist + MINMATCH, src + n);
        if (lazy) {
            /* both tables one byte later, while that finds a longer match */
            while (len < lazyEnough && pos + 1 < mflimit) {
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
        } else if (len < nextBelow && pos + 1 < mflimit) {
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

void sylzc_compress_mid(sylzc_mid *st)
{
    compress_mid_core(st, (int)st->hashLog, st->lazy, st->skip, st->lazyEnough,
                      st->nextBelow);
}

/* v4's levels 2-3 inline the match count on 64-bit targets: a call
   there makes the loop keep fewer of its variables in registers (on
   win32, mingw would then call libgcc's __ctzdi2, which FPC does not
   link) */
#if UINTPTR_MAX > 0xFFFFFFFF
#define MID4_COUNT(a, b, l) count_match_inl(a, b, l)
#else
#define MID4_COUNT(a, b, l) count_match(a, b, l)
#endif

/* MidHashLong and MidHashShort of the 8 bytes v at a position (the shift
   by 16 folded into the multiplier, as FAST_MULT16), kl and ks the
   multipliers */
#define MID4_HL(v) ((uint32_t)(((v) * kl) >> (64 - hashLog)))
#define MID4_HS(v) ((uint32_t)((uint32_t)(v) * ks) >> (32 - hashLog))

/* mid_cand with the 4 bytes at pos given (v), on the candidate's
   position, fast_dist's without its branch (as compress_fast4): two
   operations fewer than the distance and its test, which gcc for arm64
   made with a select (levels 2-3 4% faster there) */
static inline __attribute__((always_inline)) intptr_t mid4_cand(uint16_t *table, uint32_t h,
    const uint8_t *src, intptr_t pos, uint32_t v)
{
    /* the candidate's position (a distance over pos: before src) */
    intptr_t r = (pos - 1) - ((pos - 1 - table[h]) & 0xFFFF);
    table[h] = (uint16_t)pos;
    if (r < 0 || read32(src + r) != v)
        return 0;
    return pos - r;
}

/* CompressMidCore in sylz.pas for format v4, same output byte for byte.
   Inlined once per level with its parameters constants (a shift by a
   variable takes three operations on x86 without BMI2, and the fields of
   st would be read again after each byte stored). A position's 8 bytes
   are loaded once, before the tables are written: both hashes and the
   candidates' test take them from that load (the stores to the tables
   could alias src as far as the compiler knows, and it read them again
   after each). */
static inline __attribute__((always_inline)) void compress_mid4_core(sylzc_mid *st,
    const int hashLog, const intptr_t lazy, const intptr_t skip, const intptr_t lazyEnough,
    const intptr_t nextBelow)
{
    const uint8_t *src = st->src;
    intptr_t n = st->n;
    uint16_t *tl = st->tl, *ts = st->ts;
    sylzc_emit e = st->e;
    open4_state w;
    intptr_t anchor = 0, pos, len, dist, len2, dist2, dshort, k = 0, mend, mflimit, rep = 1;
    uint64_t v, v1 = 0;
#if UINTPTR_MAX > 0xFFFFFFFF
    /* the previous offset's test, one byte on: srep1[pos] against the 4
       bytes of v after its first (on 32-bit targets from rep and src: two
       registers more made i386 slower) */
    const uint8_t *srep1 = src;
#endif
    /* the hashes' multipliers (MID4_HL, MID4_HS) */
    uint64_t kl = FAST_MULT16;
    uint32_t ks = 2654435761u;
#if defined(__aarch64__)
    /* hidden from the compiler: gcc for arm64 made them again at each
       position (five instructions) for want of registers in this loop, and
       levels 2-3 were 3-7% slower; in a register they stay. (x86 multiplies
       by an immediate: there the asm only takes a register.) */
    __asm__("" : "+r"(kl), "+r"(ks));
#endif

    open4_load(&w, &e);
    if (w.direct)
        split4_clear(w.memo);
    if (n < 12 + 1)
        goto done;
    mflimit = n - 12;
    pos = 0;
    while (pos < mflimit) {
        v = read64(src + pos);
        /* (rep <= pos always: 1 at first, then a match's distance, which
           is at most its position) */
#if UINTPTR_MAX > 0xFFFFFFFF
        if (read32(srep1 + pos) == (uint32_t)(v >> 8)) {
#else
        if (read32(src + pos + 1 - rep) == read32(src + pos + 1)) {
#endif
            /* the previous offset, one byte on, or the long table's
               candidate here if that match is short and this one longer */
            len = MINMATCH + MID4_COUNT(src + pos + 1 + MINMATCH, src + pos + 1 - rep + MINMATCH, src + n);
            dist = 0;
            if (len < nextBelow)
                dist = mid4_cand(tl, MID4_HL(v), src, pos, (uint32_t)v);
            else
                tl[MID4_HL(v)] = (uint16_t)pos;
            ts[MID4_HS(v)] = (uint16_t)pos;
            len2 = 0;
            if (dist > 0)
                len2 = MINMATCH + MID4_COUNT(src + pos + MINMATCH, src + pos - dist + MINMATCH, src + n);
            if (len2 > len + 1)
                len = len2;
            else {
                pos++;
                dist = rep;
            }
            goto found;
        }
        dist = mid4_cand(tl, MID4_HL(v), src, pos, (uint32_t)v);
        if (dist > 0)
            ts[MID4_HS(v)] = (uint16_t)pos;
        else {
            dist = mid4_cand(ts, MID4_HS(v), src, pos, (uint32_t)v);
            if (dist == 0) {
                pos += 1 + ((pos - anchor) >> skip);
                continue;
            }
        }
        len = MINMATCH + MID4_COUNT(src + pos + MINMATCH, src + pos - dist + MINMATCH, src + n);
        if (lazy) {
            /* both tables one byte later, while that finds a longer match */
            while (len < lazyEnough && pos + 1 < mflimit) {
                k = pos + 1;
                v1 = read64(src + k);
                dist2 = mid4_cand(tl, MID4_HL(v1), src, k, (uint32_t)v1);
                dshort = mid4_cand(ts, MID4_HS(v1), src, k, (uint32_t)v1);
                if (dist2 == 0)
                    dist2 = dshort;
                if (dist2 == 0)
                    break;
                len2 = MINMATCH + MID4_COUNT(src + k + MINMATCH, src + k - dist2 + MINMATCH, src + n);
                if (len2 <= len)
                    break;
                pos = k;
                len = len2;
                dist = dist2;
            }
        } else if (len < nextBelow && pos + 1 < mflimit) {
            /* a short match: a long one one byte later? */
            k = pos + 1;
            v1 = read64(src + k);
            dist2 = mid4_cand(tl, MID4_HL(v1), src, k, (uint32_t)v1);
            if (dist2 > 0) {
                len2 = MINMATCH + MID4_COUNT(src + k + MINMATCH, src + k - dist2 + MINMATCH, src + n);
                if (len2 > len) {
                    pos = k;
                    len = len2;
                    dist = dist2;
                }
            }
        }
found:
        while (pos > anchor && pos > dist && src[pos - 1] == src[pos - 1 - dist]) {
            pos--;
            len++;
        }
        emit_open4(&e, &w, src + anchor, pos - anchor, dist, len, rep);
        rep = dist;
#if UINTPTR_MAX > 0xFFFFFFFF
        srep1 = src + 1 - rep;
#endif
        mend = pos + len;
        if (mend < mflimit) {
            v = read64(src + pos + 1);
            v1 = read64(src + mend - 2);
            tl[MID4_HL(v)] = (uint16_t)(pos + 1);
            ts[MID4_HS(v >> 8)] = (uint16_t)(pos + 2);
            tl[MID4_HL(v1)] = (uint16_t)(mend - 2);
            ts[MID4_HS(v1 >> 8)] = (uint16_t)(mend - 1);
        }
        pos = mend;
        anchor = pos;
    }
done:
    open4_store(&e, &w, rep);
    st->anchor = anchor;
    st->e = e;
}

/* MID_MAXLOG, MID_SKIP, MID_LAZY_ENOUGH, MID_NEXT_BELOW in sylz.pas */
#define MID_MAXLOG 16
#define MID_SKIP 9
#define MID_LAZY_ENOUGH 32
#define MID_NEXT_BELOW 8

void sylzc_compress_mid4(sylzc_mid *st)
{
    if (st->skip == MID_SKIP && st->lazyEnough == MID_LAZY_ENOUGH
        && st->nextBelow == MID_NEXT_BELOW) {
        if (!st->lazy && st->hashLog == MID_MAXLOG - 1) {
            compress_mid4_core(st, MID_MAXLOG - 1, 0, MID_SKIP, MID_LAZY_ENOUGH, MID_NEXT_BELOW);
            return;
        }
        if (st->lazy && st->hashLog == MID_MAXLOG) {
            compress_mid4_core(st, MID_MAXLOG, 1, MID_SKIP, MID_LAZY_ENOUGH, MID_NEXT_BELOW);
            return;
        }
    }
    compress_mid4_core(st, (int)st->hashLog, st->lazy, st->skip, st->lazyEnough,
                      st->nextBelow);
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
#define HC_REP_ENOUGH 8    /* format v4: see CompressHCCore in sylz.pas */
#define HC_REP_GAIN 2

/* In/out of sylzc_compress_hc (THcCState in sylz.pas). search is the
   chain search to use: the x86_64 assembler one (it follows the C calling
   convention) or sylzc_hc_search. */
typedef struct {
    sylzc_hc *s;
    void (*search)(sylzc_hc *);
    intptr_t anchor;              /* out */
    sylzc_emit e;
    uint32_t *cnt;                /* v4: TEmit's cell counts (TPairCounts4) */
    intptr_t accel;               /* v4: HC_ACCEL4 */
} sylzc_hcparse;

static intptr_t hc_find(sylzc_hcparse *st, intptr_t pos, intptr_t lowLimit, intptr_t longest)
{
    st->s->pos = pos;
    st->s->lowLimit = lowLimit;
    st->s->longest = longest;
    st->search(st->s);
    return st->s->longest;
}

/* PairOf4 in sylz.pas for a sequence that is not one token: the cell it
   looks up first, counted. */
static __attribute__((noinline)) void count_split4(const struct sylzc_codes4 *t,
    uint32_t *cnt, int k, intptr_t ll, intptr_t ml)
{
    intptr_t row = ll, col = ml;
    if (ll > LIT_SPLIT4) {
        row = ROW4_EXT;
        if (ml > MAX_ML4)
            col = COL4_EXT;
    } else if (ml > ML_SPLIT4) {
        if (ll > MAX_LL4)
            row -= MAX_LL4;
        col = COL4_EXT;
        if (row == 0)
            return;
    } else {
        if (ll > MAX_LL4 && k == 0 && ml == MINMATCH)
            return;
        find_split4(t, k, ll, ml, &row, &col);
    }
    cnt[(k * (ROW4_EXT + 1) + row) * (COL4_EXT + 1) + col]++;
}

/* Emit in CompressHCCore: a match shorter than MINMATCH stays literals.
   v4: the cell the sequence looks up is counted as it is recorded
   (CountAll4's count without its pass over the records; after a flush:
   it is the next chunk's, with the table that flush left) */
static inline __attribute__((always_inline)) void hc_emit(sylzc_hcparse *st, intptr_t p,
    intptr_t len, intptr_t r, const int v4)
{
    if (len < MINMATCH)
        return;
    if (v4) {
        sylzc_emit *e = &st->e;
        intptr_t ll = p - st->anchor;
        int k = p - r == e->rep;
        if (e->rec >= e->recEnd)
            e->flush(e);
        if (__builtin_expect(ll <= MAX_LL4 && len <= MAX_ML4, 1))
            st->cnt[(k * (ROW4_EXT + 1) + ll) * (COL4_EXT + 1) + len]++;
        else
            count_split4(e->codes, st->cnt, k, ll, len);
        emit_sequence4(e, st->s->src + st->anchor, ll, p - r, len);
    } else
        emit_sequence(&st->e, st->s->src + st->anchor, p - st->anchor, p - r, len);
    st->anchor = p + len;
}

/* Format v4's search at a position with no match yet (state 0 of
   CompressHCCore in sylz.pas), for as long as it finds nothing: each
   position's test of the previous offset one byte on, then
   sylzc_hc_search with lowLimit = pos (same candidates, same result),
   here so that a run of literals stays in one loop with its values in
   registers. Returns 0 at scanEnd, 1 with a chain match at s->pos
   (s->longest, s->mpos), 2 when the previous offset matches at s->pos + 1. */
static inline __attribute__((always_inline)) int hc_scan4(sylzc_hc *s, intptr_t rep,
    intptr_t anchor, intptr_t scanEnd, intptr_t accel)
{
    const uint8_t *src = s->src, *iend = s->iend;
    uint16_t *head = s->head, *chain = s->chain;
    intptr_t pos = s->pos, next = s->nextToInsert;
    const intptr_t attempts = s->attempts;
    int kind = 0;
    do {
        const uint8_t *ip = src + pos;
        uint32_t first = read32(ip), h, d;
        if (rep <= pos && read32(ip + 1 - rep) == read32(ip + 1)) {
            kind = 2;
            break;
        }
        for (; next < pos; next++) {
            h = hash4(read32(src + next), HC_HASHLOG);
            d = (uint32_t)(next - head[h]) & 0xFFFF;
            if (d > next)
                d = 0;                 /* 0 terminates the chain */
            chain[next & 0xFFFF] = (uint16_t)d;
            head[h] = (uint16_t)next;
        }
        /* pos goes in now: the next search would insert it the same */
        h = hash4(first, HC_HASHLOG);
        d = (uint32_t)(pos - head[h]) & 0xFFFF;
        if (d > pos)
            d = 0;
        chain[pos & 0xFFFF] = (uint16_t)d;
        head[h] = (uint16_t)pos;
        next = pos + 1;
        if (d) {
            intptr_t cand = pos - d, tries = attempts, longest = MINMATCH - 1;
            for (;;) {
                if (read32(src + cand) == first) {
                    intptr_t fwd = MINMATCH + count_match_inl(ip + MINMATCH,
                        src + cand + MINMATCH, iend);
                    if (fwd > longest) {
                        longest = fwd;
                        s->mpos = cand;
                    }
                }
                if (--tries == 0)
                    break;
                d = chain[cand & 0xFFFF];
                if (d == 0)
                    break;
                cand -= d;
                if (cand < 0 || pos - cand > HC_MAXDIST)
                    break;
            }
            if (longest >= MINMATCH) {
                s->longest = longest;
                kind = 1;
                break;
            }
        }
        pos += 1 + ((pos - anchor) >> accel);
    } while (pos < scanEnd);
    s->pos = pos;
    s->nextToInsert = next;
    return kind;
}

/* CompressHCCore in sylz.pas (LZ4HC_compress_hashChain), same output; the
   state machine as there: 0 search at pos, 2 / 3 lz4hc's _Search2 /
   _Search3. The caller set s's src, iend, nextToInsert and attempts. */
static inline __attribute__((always_inline)) void compress_hc_core(sylzc_hcparse *st, const int v4)
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
            if (v4) {
                const uint8_t *src = s->src;
                intptr_t rp = st->e.rep, kind;
                s->pos = pos;
                kind = hc_scan4(s, rp, st->anchor, mfl, st->accel);
                pos = s->pos;
                if (kind == 0)
                    break;
                ml = s->longest;
                if (kind == 2) {
                    /* the previous offset matches one byte on: taken, back
                       to where it starts, unless the chains have a match
                       over HC_REP_GAIN bytes longer here */
                    intptr_t rs = pos + 1;
                    intptr_t rl = MINMATCH + count_match(src + rs + MINMATCH,
                        src + rs - rp + MINMATCH, s->iend);
                    ml = 0;
                    if (rl < HC_REP_ENOUGH)
                        ml = hc_find(st, pos, pos, MINMATCH - 1);
                    if (rl + HC_REP_GAIN >= ml) {
                        while (rs > st->anchor && rs > rp && src[rs - 1] == src[rs - 1 - rp]) {
                            rs--;
                            rl++;
                        }
                        hc_emit(st, rs, rl, rs - rp, v4);
                        pos = rs + rl;
                        continue;
                    }
                }
                ref = s->mpos;
                /* the scan may have stepped over the match's first bytes */
                while (pos > st->anchor && ref > 0 && src[pos - 1] == src[ref - 1]) {
                    pos--;
                    ref--;
                    ml++;
                }
            } else {
                ml = hc_find(st, pos, pos, MINMATCH - 1);
                if (ml < MINMATCH) {
                    pos++;
                    continue;
                }
                ref = s->mpos;
            }
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
                hc_emit(st, pos, ml, ref, v4);
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
            hc_emit(st, pos, ml, ref, v4);
            hc_emit(st, start2, ml2, ref2, v4);
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
                hc_emit(st, pos, ml, ref, v4);
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
        hc_emit(st, pos, ml, ref, v4);
        pos = start2; ref = ref2; ml = ml2;
        start2 = start3; ref2 = ref3; ml2 = ml3;
        state = 3;
    }
}

void sylzc_compress_hc(sylzc_hcparse *st)
{
    compress_hc_core(st, 0);
}

void sylzc_compress_hc4(sylzc_hcparse *st)
{
    compress_hc_core(st, 1);
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

/* ── Huffman bulk loops (sylzhuf.pas) ─────────────────────────────────── */

/* The bulk loops of HufDecodeChunk (v3's four streams) and HufDecodeChunk8
   (v5's eight), for where there is no x86-64 assembler (arm64, 32-bit x86,
   macOS). FPC's aarch64 code for the Pascal loops keeps the streams'
   state in memory, and v5 decoded 4-12% slower than v3 there; here every
   stream's buffer stays in a register. Same contract as HufBulkX64 and
   HufBulk8X64: the caller has counted the rounds the input allows, the
   kernel runs exactly those, and the Pascal tails finish the chunk.

   A table entry (THufTable): the code's length in the low byte, the
   symbol in the high one. A length is at most HUF_MAXBITS (11), so a
   shift by the whole entry & 63 is a shift by the length (arm64 and x86
   shift by the count's low 6 bits anyway, so the mask costs nothing). */
#define HUF_MASK 2047   /* HUF_TABLESIZE - 1 */

/* THufBulk in sylzhuf.pas: fixed field order (same offsets on 32-bit
   targets: q falls on 88 either way) */
typedef struct {
    uint64_t buf[4];         /* in/out: the streams' bit buffers */
    int64_t cnt[4];          /* in/out: valid bits in each */
    const uint8_t *p[4];     /* in/out: the next bytes to load */
    const uint16_t *table;
    uint8_t *out0;           /* in/out: stream 0's next output */
    int64_t q;               /* symbols per stream: the outputs' stride */
    uint8_t *outEnd;         /* out0 after the last round to run */
} sylzc_hufbulk;

/* A stream's refill (Giesen's, branch-free): the 8 bytes at p go above
   the c valid bits, p moves by the whole bytes that fit; 56 or more bits
   are valid after it, enough for five codes. The bits above c are the
   stream's next ones, so oring them in again changes nothing. c keeps
   its count in the low byte only (each symbol subtracts its whole
   entry: see HUF4_SYM), so the refill takes that byte. */
#define HUF4_REFILL(b, c, p) do {                     \
        uint32_t cc_ = (c) & 255;                     \
        (b) |= read64(p) << cc_;                      \
        (p) += (63 - cc_) >> 3;                       \
        (c) = cc_ | 56;                               \
    } while (0)

/* One symbol: the low byte of c stays exact because the length never
   borrows from the bits above it (five codes take at most 55 of the 56
   or more bits a refill leaves, whatever the input). */
#define HUF4_SYM(b, c, o, j) do {                     \
        uint32_t v_ = t[(b) & HUF_MASK];              \
        (o)[j] = (uint8_t)(v_ >> 8);                  \
        (b) >>= v_ & 63;                              \
        (c) -= v_;                                    \
    } while (0)

/* The j-th symbol of every stream: the four chains interleaved, each
   symbol waiting for its own stream's previous one only. On 64-bit
   targets the five rows are written out: gcc -O2 kept the loop (a counter
   and a branch per four symbols). On 32-bit x86 the loop was 4-7% faster
   (its eight halves of buffers do not fit the registers either way, and
   the loop is smaller). */
#define HUF4_ROW(j) do {                              \
        HUF4_SYM(b0, c0, o0, j);                      \
        HUF4_SYM(b1, c1, o1, j);                      \
        HUF4_SYM(b2, c2, o2, j);                      \
        HUF4_SYM(b3, c3, o3, j);                      \
    } while (0)
#if UINTPTR_MAX > 0xFFFFFFFFu
#define HUF4_ROWS() do {                              \
        HUF4_ROW(0);                                  \
        HUF4_ROW(1);                                  \
        HUF4_ROW(2);                                  \
        HUF4_ROW(3);                                  \
        HUF4_ROW(4);                                  \
    } while (0)
#else
#define HUF4_ROWS() do {                              \
        for (int j_ = 0; j_ < 5; j_++)                \
            HUF4_ROW(j_);                             \
    } while (0)
#endif

/* Rounds of a refill and five symbols per stream until out0 reaches
   outEnd (at least one round). A round reads 8 bytes at each p and moves
   it by at most 7: the caller's count keeps those reads inside the
   chunk. */
void sylzc_huf_bulk4(sylzc_hufbulk *st)
{
    const uint16_t *t = st->table;
    uint64_t b0 = st->buf[0], b1 = st->buf[1], b2 = st->buf[2], b3 = st->buf[3];
    uint32_t c0 = (uint32_t)st->cnt[0], c1 = (uint32_t)st->cnt[1],
             c2 = (uint32_t)st->cnt[2], c3 = (uint32_t)st->cnt[3];
    const uint8_t *p0 = st->p[0], *p1 = st->p[1], *p2 = st->p[2], *p3 = st->p[3];
    intptr_t q = (intptr_t)st->q;
    /* one output pointer per stream: four adds a round, where indexing by
       q, 2q, 3q would take a register each and an add per store on arm64 */
    uint8_t *o0 = st->out0, *o1 = o0 + q, *o2 = o0 + 2 * q, *o3 = o0 + 3 * q;
    uint8_t *end = st->outEnd;
    do {
        HUF4_REFILL(b0, c0, p0);
        HUF4_REFILL(b1, c1, p1);
        HUF4_REFILL(b2, c2, p2);
        HUF4_REFILL(b3, c3, p3);
        HUF4_ROWS();
        o0 += 5;
        o1 += 5;
        o2 += 5;
        o3 += 5;
    } while (o0 < end);
    st->buf[0] = b0;
    st->buf[1] = b1;
    st->buf[2] = b2;
    st->buf[3] = b3;
    st->cnt[0] = c0 & 255;
    st->cnt[1] = c1 & 255;
    st->cnt[2] = c2 & 255;
    st->cnt[3] = c3 & 255;
    st->p[0] = p0;
    st->p[1] = p1;
    st->p[2] = p2;
    st->p[3] = p3;
    st->out0 = o0;
}

/* THufBulk8 in sylzhuf.pas: fixed field order */
typedef struct {
    uint64_t pos[8];         /* in/out: each stream's next bit, as its address times 8 */
    const uint16_t *table;
    uint8_t *out0;           /* in/out: the next output byte */
    uint8_t *outEnd;         /* out0 after the last round to run */
} sylzc_hufbulk8;


/* A stream's load at the start of a round: the 8 bytes at its bit
   position r (from base), shifted so that its next bit is bit 0: 57 bits
   or more, enough for five codes. On 64-bit targets bit 63 is then set
   as a mark (it takes the place of a bit no code of the round reaches):
   it moves down with the bits taken, so at the round's end its leading
   zeros are the bits the round took, one clz, as HufBulk8X64 does. On
   32-bit ones a 64-bit clz is two (a branch between them); there the
   round adds up the entries instead (HUF8_TAKE). */
#if UINTPTR_MAX > 0xFFFFFFFFu
#define HUF8_MARK ((uint64_t)1 << 63)
#define HUF8_TAKE(c, v) ((void)(c))
#define HUF8_TAKEN(b, c) ((uintptr_t)__builtin_clzll(b))
#else
#define HUF8_MARK 0
/* c adds up the whole entries: their low bytes are the lengths, which
   sum to 55 at most in a round (no carry out of the byte) */
#define HUF8_TAKE(c, v) ((c) += (v))
#define HUF8_TAKEN(b, c) ((uintptr_t)((c) & 255))
#endif
#define HUF8_LOAD(b, r) ((b) = (read64(base + ((r) >> 3)) >> ((r) & 7)) | HUF8_MARK)

/* One symbol of stream k, the j-th of the round, to o[8j + k] */
#define HUF8_SYM(b, c, k, j) do {                     \
        uint32_t v_ = t[(b) & HUF_MASK];              \
        o[8 * (j) + (k)] = (uint8_t)(v_ >> 8);        \
        (b) >>= v_ & 63;                              \
        HUF8_TAKE(c, v_);                             \
    } while (0)

/* The j-th symbol of every stream, in stream order: the eight chains
   interleaved (a chain is a table load and a shift, ~6-7 cycles; eight of
   them hide it where four cannot). The five rows written out on 64-bit
   targets, the loop on 32-bit ones, as for HUF4_ROWS. */
#define HUF8_ROW(j) do {                              \
        HUF8_SYM(b0, c0, 0, j);                       \
        HUF8_SYM(b1, c1, 1, j);                       \
        HUF8_SYM(b2, c2, 2, j);                       \
        HUF8_SYM(b3, c3, 3, j);                       \
        HUF8_SYM(b4, c4, 4, j);                       \
        HUF8_SYM(b5, c5, 5, j);                       \
        HUF8_SYM(b6, c6, 6, j);                       \
        HUF8_SYM(b7, c7, 7, j);                       \
    } while (0)
#if UINTPTR_MAX > 0xFFFFFFFFu
#define HUF8_ROWS() do {                              \
        HUF8_ROW(0);                                  \
        HUF8_ROW(1);                                  \
        HUF8_ROW(2);                                  \
        HUF8_ROW(3);                                  \
        HUF8_ROW(4);                                  \
    } while (0)
#else
#define HUF8_ROWS() do {                              \
        for (int j_ = 0; j_ < 5; j_++)                \
            HUF8_ROW(j_);                             \
    } while (0)
#endif

/* Rounds of five symbols from each of the eight streams (40 output
   bytes: symbol j of stream k at out0 + 8j + k) until out0 reaches outEnd
   (at least one round). Each round reads the 8 bytes at each stream's
   position; the caller's count keeps them inside the chunk. Unlike
   HufBulk8X64 nothing is read after the last round.

   The positions are kept as bit offsets from the lowest stream's byte,
   in uintptr_t (a chunk is under 2^20 bytes), where the record's address
   times 8 needs 64 bits on 32-bit targets. Eight buffers, eight offsets,
   the table and the output: 19 registers, which arm64 has. */
void sylzc_huf_bulk8(sylzc_hufbulk8 *st)
{
    const uint16_t *t = st->table;
    uint64_t lo = st->pos[0];
    for (int k = 1; k < 8; k++)
        if (st->pos[k] < lo)
            lo = st->pos[k];
    const uint8_t *base = (const uint8_t *)(uintptr_t)(lo >> 3);
    uint64_t base8 = lo & ~(uint64_t)7;
    uintptr_t r0 = (uintptr_t)(st->pos[0] - base8), r1 = (uintptr_t)(st->pos[1] - base8),
              r2 = (uintptr_t)(st->pos[2] - base8), r3 = (uintptr_t)(st->pos[3] - base8),
              r4 = (uintptr_t)(st->pos[4] - base8), r5 = (uintptr_t)(st->pos[5] - base8),
              r6 = (uintptr_t)(st->pos[6] - base8), r7 = (uintptr_t)(st->pos[7] - base8);
    uint8_t *o = st->out0, *end = st->outEnd;
    do {
        uint64_t b0, b1, b2, b3, b4, b5, b6, b7;
        uint32_t c0 = 0, c1 = 0, c2 = 0, c3 = 0, c4 = 0, c5 = 0, c6 = 0, c7 = 0;
        HUF8_LOAD(b0, r0);
        HUF8_LOAD(b1, r1);
        HUF8_LOAD(b2, r2);
        HUF8_LOAD(b3, r3);
        HUF8_LOAD(b4, r4);
        HUF8_LOAD(b5, r5);
        HUF8_LOAD(b6, r6);
        HUF8_LOAD(b7, r7);
        HUF8_ROWS();
        r0 += HUF8_TAKEN(b0, c0);
        r1 += HUF8_TAKEN(b1, c1);
        r2 += HUF8_TAKEN(b2, c2);
        r3 += HUF8_TAKEN(b3, c3);
        r4 += HUF8_TAKEN(b4, c4);
        r5 += HUF8_TAKEN(b5, c5);
        r6 += HUF8_TAKEN(b6, c6);
        r7 += HUF8_TAKEN(b7, c7);
        o += 40;
    } while (o < end);
    st->pos[0] = base8 + r0;
    st->pos[1] = base8 + r1;
    st->pos[2] = base8 + r2;
    st->pos[3] = base8 + r3;
    st->pos[4] = base8 + r4;
    st->pos[5] = base8 + r5;
    st->pos[6] = base8 + r6;
    st->pos[7] = base8 + r7;
    st->out0 = o;
}


/* ── CRC-32 (for syc's container) ─────────────────────────────────────── */

/* crc32 in syc.pas: CRC-32 (IEEE, reflected, $EDB88320), as zlib's, by
   slicing 8. tables: the 8 x 256 table syc.pas builds. FPC ran its version
   at ~1.2 GB/s, 40% of a syc decompression. */
uint32_t sylzc_crc32(uint32_t crc, const uint8_t *p, intptr_t n, const uint32_t *tables)
{
    const uint32_t *t0 = tables, *t1 = tables + 256, *t2 = tables + 512, *t3 = tables + 768,
                   *t4 = tables + 1024, *t5 = tables + 1280, *t6 = tables + 1536,
                   *t7 = tables + 1792;
    crc = ~crc;
    while (n >= 8) {
        uint32_t a = (p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24) ^ crc;
        uint32_t b = p[4] | (uint32_t)p[5] << 8 | (uint32_t)p[6] << 16 | (uint32_t)p[7] << 24;
        crc = t7[a & 0xFF] ^ t6[(a >> 8) & 0xFF] ^ t5[(a >> 16) & 0xFF] ^ t4[a >> 24]
            ^ t3[b & 0xFF] ^ t2[(b >> 8) & 0xFF] ^ t1[(b >> 16) & 0xFF] ^ t0[b >> 24];
        p += 8;
        n -= 8;
    }
    while (n-- > 0)
        crc = t0[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

/* ── the archive's fragment cutter (syccdc.pas) ───────────────────────── */

/* CdcCut in syccdc.pas, the reference: the length of the fragment at p
   with n > 0 bytes left. FPC's loop ran at ~450-900 MB/s. */
intptr_t sylzc_cdc_cut(const uint8_t *p, intptr_t n, intptr_t minSize, intptr_t avgSize,
                       intptr_t maxSize, int strictShift, int looseShift, const uint64_t *gear)
{
    uint64_t h = 0;
    intptr_t i, lim, e1;
    if (n <= minSize)
        return n;
    lim = n < maxSize ? n : maxSize;
    e1 = avgSize - 1 < lim ? avgSize - 1 : lim;
    i = minSize;
    while (i < e1) {
        h = (h << 1) + gear[p[i]];
        i++;
        if ((h >> strictShift) == 0)
            return i;
    }
    while (i < lim) {
        h = (h << 1) + gear[p[i]];
        i++;
        if ((h >> looseShift) == 0)
            return i;
    }
    return lim;
}

/* ── BLAKE2s (blake2s.pas): the archive's fragment hash ─────────────────── */

/* Compress in blake2s.pas: FPC's code for it ran at ~160 MB/s. n blocks of
   64 bytes from p; the counter *t goes up 64 a block, and the last block
   gets the final flag when last is set. */
static const uint32_t b2s_iv[8] = {
    0x6A09E667u, 0xBB67AE85u, 0x3C6EF372u, 0xA54FF53Au,
    0x510E527Fu, 0x9B05688Cu, 0x1F83D9ABu, 0x5BE0CD19u };

static const uint8_t b2s_sigma[10][16] = {
    { 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15},
    {14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3},
    {11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4},
    { 7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8},
    { 9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13},
    { 2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9},
    {12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11},
    {13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10},
    { 6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5},
    {10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0} };

#define B2S_ROR(x, c) (((x) >> (c)) | ((x) << (32 - (c))))
#define B2S_G(a, b, c, d, x, y)                                     \
    do {                                                            \
        a += b + (x); d = B2S_ROR(d ^ a, 16);                       \
        c += d;       b = B2S_ROR(b ^ c, 12);                       \
        a += b + (y); d = B2S_ROR(d ^ a, 8);                        \
        c += d;       b = B2S_ROR(b ^ c, 7);                        \
    } while (0)

void sylzc_blake2s_blocks(uint32_t *h, const uint8_t *p, intptr_t n, uint64_t *t, int last)
{
    for (; n > 0; n--, p += 64) {
        uint32_t m[16], v[16];
        int i;
        for (i = 0; i < 16; i++)
            m[i] = p[4 * i] | (uint32_t)p[4 * i + 1] << 8 | (uint32_t)p[4 * i + 2] << 16
                 | (uint32_t)p[4 * i + 3] << 24;
        *t += 64;
        for (i = 0; i < 8; i++) {
            v[i] = h[i];
            v[i + 8] = b2s_iv[i];
        }
        v[12] ^= (uint32_t)*t;
        v[13] ^= (uint32_t)(*t >> 32);
        if (last && n == 1)
            v[14] = ~v[14];
        /* the ten rounds unrolled, sigma's indices constant: m stays in
           registers (with a loop over b2s_sigma, ~2/3 of the speed) */
#define B2S_ROUND(r)                                                                  \
        B2S_G(v[0], v[4], v[8],  v[12], m[b2s_sigma[r][0]],  m[b2s_sigma[r][1]]);     \
        B2S_G(v[1], v[5], v[9],  v[13], m[b2s_sigma[r][2]],  m[b2s_sigma[r][3]]);     \
        B2S_G(v[2], v[6], v[10], v[14], m[b2s_sigma[r][4]],  m[b2s_sigma[r][5]]);     \
        B2S_G(v[3], v[7], v[11], v[15], m[b2s_sigma[r][6]],  m[b2s_sigma[r][7]]);     \
        B2S_G(v[0], v[5], v[10], v[15], m[b2s_sigma[r][8]],  m[b2s_sigma[r][9]]);     \
        B2S_G(v[1], v[6], v[11], v[12], m[b2s_sigma[r][10]], m[b2s_sigma[r][11]]);    \
        B2S_G(v[2], v[7], v[8],  v[13], m[b2s_sigma[r][12]], m[b2s_sigma[r][13]]);    \
        B2S_G(v[3], v[4], v[9],  v[14], m[b2s_sigma[r][14]], m[b2s_sigma[r][15]]);
        B2S_ROUND(0) B2S_ROUND(1) B2S_ROUND(2) B2S_ROUND(3) B2S_ROUND(4)
        B2S_ROUND(5) B2S_ROUND(6) B2S_ROUND(7) B2S_ROUND(8) B2S_ROUND(9)
#undef B2S_ROUND
        for (i = 0; i < 8; i++)
            h[i] ^= v[i] ^ v[i + 8];
    }
}


/* Many messages at once, four lanes: lane k of every vector is a message
   of its own. A lane whose message ends takes the next one, so lanes stay
   busy whatever the lengths; the last message or two finish on the
   scalar code. GCC's vector extensions: SSE2 on x86, NEON on arm64. The
   reference is hashing each message on its own (Blake2sMany in
   blake2s.pas); tests/sycdedup compares them. */
typedef uint32_t b2s_v4 __attribute__((vector_size(16)));

#define B2S_VROR(x, c) (((x) >> (c)) | ((x) << (32 - (c))))
#define B2S_VG(a, b, c, d, x, y)                                    \
    do {                                                            \
        a += b + (x); d = B2S_VROR(d ^ a, 16);                      \
        c += d;       b = B2S_VROR(b ^ c, 12);                      \
        a += b + (y); d = B2S_VROR(d ^ a, 8);                       \
        c += d;       b = B2S_VROR(b ^ c, 7);                       \
    } while (0)

static __attribute__((unused)) uint32_t b2s_load32(const uint8_t *p)
{
    return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* h after its blocks, then the last (partial or empty) block: the digest.
   kpad: the key block still to go first (keyed, RFC 7693 3.3), or NULL */
static void b2s_finish(uint32_t *h, uint64_t t, const uint8_t *kpad, const uint8_t *p,
                       intptr_t left, uint8_t *out)
{
    uint8_t last[64];
    intptr_t i, full;
    if (kpad) {
        /* with an empty message the key block is the last one */
        sylzc_blake2s_blocks(h, kpad, 1, &t, left == 0);
        if (left == 0)
            goto done;
    }
    full = left > 0 ? (left - 1) / 64 : 0;
    sylzc_blake2s_blocks(h, p, full, &t, 0);
    p += 64 * full;
    left -= 64 * full;
    for (i = 0; i < 64; i++)
        last[i] = i < left ? p[i] : 0;
    t = t + left - 64;   /* the final block counts its bytes only */
    sylzc_blake2s_blocks(h, last, 1, &t, 1);
done:
    for (i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)h[i];
        out[4 * i + 1] = (uint8_t)(h[i] >> 8);
        out[4 * i + 2] = (uint8_t)(h[i] >> 16);
        out[4 * i + 3] = (uint8_t)(h[i] >> 24);
    }
}

#define B2S_LANES 4

static __attribute__((unused)) void b2s_many_core(const uint8_t *kpad, int keyLen,
                          const uint8_t *const *msg, const intptr_t *len, intptr_t count,
                          uint8_t *out)
{
    static const uint8_t zero[64];
    b2s_v4 h[8];
    const uint8_t *p[B2S_LANES];
    intptr_t left[B2S_LANES], which[B2S_LANES], next = 0;
    uint64_t t[B2S_LANES];
    uint8_t pad[B2S_LANES][64];
    int keyFirst[B2S_LANES], advance[B2S_LANES];
    int l, i, active = 0;

    for (l = 0; l < B2S_LANES; l++)
        which[l] = -1;
    for (;;) {
        const uint8_t *blk[B2S_LANES];
        b2s_v4 m[16], v[16], tlo, thi, fin;
        int last[B2S_LANES];

        /* idle lanes take the next messages */
        for (l = 0; l < B2S_LANES; l++)
            if (which[l] < 0 && next < count) {
                which[l] = next;
                p[l] = msg[next];
                left[l] = len[next];
                t[l] = 0;
                for (i = 0; i < 8; i++)
                    h[i][l] = b2s_iv[i];
                h[0][l] ^= 0x01010000u ^ ((uint32_t)keyLen << 8) ^ 32;
                keyFirst[l] = keyLen > 0;
                next++;
                active++;
            }
        if (active < 2)
            break;
        for (l = 0; l < B2S_LANES; l++) {
            last[l] = 0;
            advance[l] = 1;
            if (which[l] < 0)
                blk[l] = zero;
            else if (keyFirst[l]) {
                /* keyed: the key block first, the last one when the
                   message is empty */
                blk[l] = kpad;
                t[l] += 64;
                last[l] = left[l] == 0;
                keyFirst[l] = 0;
                advance[l] = 0;
            } else if (left[l] > 64) {
                blk[l] = p[l];
                t[l] += 64;
            } else {
                for (i = 0; i < 64; i++)
                    pad[l][i] = i < left[l] ? p[l][i] : 0;
                blk[l] = pad[l];
                t[l] += left[l];
                last[l] = 1;
            }
        }
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
        /* four words of each lane, then a 4x4 transpose: word i of every
           lane in m[i] (clang spells gcc's __builtin_shuffle its own way) */
#if defined(__clang__)
#define B2S_SHUF(a, b, i0, i1, i2, i3) __builtin_shufflevector(a, b, i0, i1, i2, i3)
#else
#define B2S_SHUF(a, b, i0, i1, i2, i3) __builtin_shuffle(a, b, (b2s_v4){ i0, i1, i2, i3 })
#endif
        for (i = 0; i < 16; i += 4) {
            typedef b2s_v4 b2s_v4u __attribute__((aligned(1), may_alias));
            const b2s_v4 r0 = *(const b2s_v4u *)(blk[0] + 4 * i);
            const b2s_v4 r1 = *(const b2s_v4u *)(blk[1] + 4 * i);
            const b2s_v4 r2 = *(const b2s_v4u *)(blk[2] + 4 * i);
            const b2s_v4 r3 = *(const b2s_v4u *)(blk[3] + 4 * i);
            const b2s_v4 t0 = B2S_SHUF(r0, r1, 0, 4, 1, 5);
            const b2s_v4 t1 = B2S_SHUF(r2, r3, 0, 4, 1, 5);
            const b2s_v4 t2 = B2S_SHUF(r0, r1, 2, 6, 3, 7);
            const b2s_v4 t3 = B2S_SHUF(r2, r3, 2, 6, 3, 7);
            m[i] = B2S_SHUF(t0, t1, 0, 1, 4, 5);
            m[i + 1] = B2S_SHUF(t0, t1, 2, 3, 6, 7);
            m[i + 2] = B2S_SHUF(t2, t3, 0, 1, 4, 5);
            m[i + 3] = B2S_SHUF(t2, t3, 2, 3, 6, 7);
        }
#else
        for (i = 0; i < 16; i++)
            m[i] = (b2s_v4){ b2s_load32(blk[0] + 4 * i), b2s_load32(blk[1] + 4 * i),
                             b2s_load32(blk[2] + 4 * i), b2s_load32(blk[3] + 4 * i) };
#endif
        tlo = (b2s_v4){ (uint32_t)t[0], (uint32_t)t[1], (uint32_t)t[2], (uint32_t)t[3] };
        thi = (b2s_v4){ (uint32_t)(t[0] >> 32), (uint32_t)(t[1] >> 32),
                        (uint32_t)(t[2] >> 32), (uint32_t)(t[3] >> 32) };
        fin = (b2s_v4){ last[0] ? ~0u : 0, last[1] ? ~0u : 0, last[2] ? ~0u : 0, last[3] ? ~0u : 0 };
        for (i = 0; i < 8; i++) {
            v[i] = h[i];
            v[i + 8] = (b2s_v4){ b2s_iv[i], b2s_iv[i], b2s_iv[i], b2s_iv[i] };
        }
        v[12] ^= tlo;
        v[13] ^= thi;
        v[14] ^= fin;
#define B2S_VROUND(r)                                                                         \
        B2S_VG(v[0], v[4], v[8],  v[12], m[b2s_sigma[r][0]],  m[b2s_sigma[r][1]]);            \
        B2S_VG(v[1], v[5], v[9],  v[13], m[b2s_sigma[r][2]],  m[b2s_sigma[r][3]]);            \
        B2S_VG(v[2], v[6], v[10], v[14], m[b2s_sigma[r][4]],  m[b2s_sigma[r][5]]);            \
        B2S_VG(v[3], v[7], v[11], v[15], m[b2s_sigma[r][6]],  m[b2s_sigma[r][7]]);            \
        B2S_VG(v[0], v[5], v[10], v[15], m[b2s_sigma[r][8]],  m[b2s_sigma[r][9]]);            \
        B2S_VG(v[1], v[6], v[11], v[12], m[b2s_sigma[r][10]], m[b2s_sigma[r][11]]);           \
        B2S_VG(v[2], v[7], v[8],  v[13], m[b2s_sigma[r][12]], m[b2s_sigma[r][13]]);           \
        B2S_VG(v[3], v[4], v[9],  v[14], m[b2s_sigma[r][14]], m[b2s_sigma[r][15]]);
        B2S_VROUND(0) B2S_VROUND(1) B2S_VROUND(2) B2S_VROUND(3) B2S_VROUND(4)
        B2S_VROUND(5) B2S_VROUND(6) B2S_VROUND(7) B2S_VROUND(8) B2S_VROUND(9)
#undef B2S_VROUND
        for (i = 0; i < 8; i++)
            h[i] ^= v[i] ^ v[i + 8];
        for (l = 0; l < B2S_LANES; l++) {
            if (which[l] < 0)
                continue;
            if (last[l]) {
                uint8_t *o = out + 32 * which[l];
                for (i = 0; i < 8; i++) {
                    uint32_t w = h[i][l];
                    o[4 * i] = (uint8_t)w;
                    o[4 * i + 1] = (uint8_t)(w >> 8);
                    o[4 * i + 2] = (uint8_t)(w >> 16);
                    o[4 * i + 3] = (uint8_t)(w >> 24);
                }
                which[l] = -1;
                active--;
            } else if (advance[l]) {
                p[l] += 64;
                left[l] -= 64;
            }
        }
    }
    /* a lane still busy (no more messages to share the vectors with) */
    for (l = 0; l < B2S_LANES; l++)
        if (which[l] >= 0) {
            uint32_t hs[8];
            for (i = 0; i < 8; i++)
                hs[i] = h[i][l];
            b2s_finish(hs, t[l], keyFirst[l] ? kpad : 0, p[l], left[l], out + 32 * which[l]);
        }
}

#if defined(__i386__)
/* 32-bit x86 has 8 vector registers for the 16 vectors of the state: the
   lanes spill and ran slower than one message at a time (196 MB/s against
   310, under wine) */
static void b2s_many_one(const uint8_t *kpad, int keyLen, const uint8_t *const *msg,
                         const intptr_t *len, intptr_t count, uint8_t *out)
{
    intptr_t k;
    for (k = 0; k < count; k++) {
        uint32_t h[8];
        int i;
        for (i = 0; i < 8; i++)
            h[i] = b2s_iv[i];
        h[0] ^= 0x01010000u ^ ((uint32_t)keyLen << 8) ^ 32;
        b2s_finish(h, 0, keyLen > 0 ? kpad : 0, msg[k], len[k], out + 32 * k);
    }
}
#endif

/* key: keyLen (0..32) bytes; with none, plain BLAKE2s-256 */
void sylzc_blake2s_many(const uint8_t *key, int keyLen, const uint8_t *const *msg,
                        const intptr_t *len, intptr_t count, uint8_t *out)
{
    uint8_t kpad[64];
    int i;
    for (i = 0; i < 64; i++)
        kpad[i] = i < keyLen ? key[i] : 0;
#if defined(__i386__)
    b2s_many_one(kpad, keyLen, msg, len, count, out);
#else
    b2s_many_core(kpad, keyLen, msg, len, count, out);
#endif
    for (i = 0; i < 64; i++)
        ((volatile uint8_t *)kpad)[i] = 0;
}

/* ── the encryption's primitives (syccrypto.pas, the reference) ─────── */

/* ChaCha20 (RFC 8439): data[0..n) xor the key stream from block counter,
   in place. Four blocks at a time in vector lanes while 256 bytes remain
   (lane k is block counter + k), then one at a time. FPC's loop ran at
   ~80 MB/s with the MAC. */
#define CHA_QR(a, b, c, d)                                          \
    do {                                                            \
        a += b; d ^= a; d = (d << 16) | (d >> 16);                  \
        c += d; b ^= c; b = (b << 12) | (b >> 20);                  \
        a += b; d ^= a; d = (d << 8) | (d >> 24);                   \
        c += d; b ^= c; b = (b << 7) | (b >> 25);                   \
    } while (0)

#define CHA_ROUNDS(x)                                               \
    for (r = 0; r < 10; r++) {                                      \
        CHA_QR(x[0], x[4], x[8],  x[12]);                           \
        CHA_QR(x[1], x[5], x[9],  x[13]);                           \
        CHA_QR(x[2], x[6], x[10], x[14]);                           \
        CHA_QR(x[3], x[7], x[11], x[15]);                           \
        CHA_QR(x[0], x[5], x[10], x[15]);                           \
        CHA_QR(x[1], x[6], x[11], x[12]);                           \
        CHA_QR(x[2], x[7], x[8],  x[13]);                           \
        CHA_QR(x[3], x[4], x[9],  x[14]);                           \
    }

static void cha_store32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

void sylzc_chacha20_xor(const uint8_t *key, const uint8_t *nonce12, uint32_t counter,
                        uint8_t *data, intptr_t n)
{
    uint32_t st[16];
    int i, r;
    st[0] = 0x61707865u; st[1] = 0x3320646Eu; st[2] = 0x79622D32u; st[3] = 0x6B206574u;
    for (i = 0; i < 8; i++)
        st[4 + i] = b2s_load32(key + 4 * i);
    st[12] = counter;
    st[13] = b2s_load32(nonce12);
    st[14] = b2s_load32(nonce12 + 4);
    st[15] = b2s_load32(nonce12 + 8);
#if !defined(__i386__)
    while (n >= 256) {
        b2s_v4 x[16], s[16];
        uint8_t ks[256];
        int l;
        for (i = 0; i < 16; i++)
            s[i] = (b2s_v4){ st[i], st[i], st[i], st[i] };
        s[12] += (b2s_v4){ 0, 1, 2, 3 };
        for (i = 0; i < 16; i++)
            x[i] = s[i];
        CHA_ROUNDS(x)
        for (i = 0; i < 16; i++) {
            x[i] += s[i];
            for (l = 0; l < 4; l++)
                cha_store32(ks + 64 * l + 4 * i, x[i][l]);
        }
        for (i = 0; i < 256; i++)
            data[i] ^= ks[i];
        data += 256;
        n -= 256;
        st[12] += 4;
    }
#endif
    while (n > 0) {
        uint32_t x[16];
        uint8_t ks[64];
        intptr_t take = n < 64 ? n : 64;
        for (i = 0; i < 16; i++)
            x[i] = st[i];
        CHA_ROUNDS(x)
        for (i = 0; i < 16; i++)
            cha_store32(ks + 4 * i, x[i] + st[i]);
        for (i = 0; i < take; i++)
            data[i] ^= ks[i];
        data += take;
        n -= take;
        st[12]++;
    }
}

/* Poly1305 over whole 16-byte blocks (hibit: 1 << 24 for full blocks, 0
   for the padded last one), state kept between calls in st: r, h, pad as
   5 x 26 bits (the Pascal's layout, 15 words). 64-bit products; with a
   128-bit type the limbs would be 44 bits, kept 26 for one layout. */
void sylzc_poly1305_blocks(uint32_t *st, const uint8_t *m, intptr_t nblocks, uint32_t hibit)
{
    const uint64_t r0 = st[0], r1 = st[1], r2 = st[2], r3 = st[3], r4 = st[4];
    const uint64_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;
    uint64_t h0 = st[5], h1 = st[6], h2 = st[7], h3 = st[8], h4 = st[9];
    for (; nblocks > 0; nblocks--, m += 16) {
        uint32_t t0 = b2s_load32(m), t1 = b2s_load32(m + 4), t2 = b2s_load32(m + 8),
                 t3 = b2s_load32(m + 12);
        uint64_t d0, d1, d2, d3, d4, c;
        h0 += t0 & 0x3FFFFFF;
        h1 += ((t0 >> 26) | (t1 << 6)) & 0x3FFFFFF;
        h2 += ((t1 >> 20) | (t2 << 12)) & 0x3FFFFFF;
        h3 += ((t2 >> 14) | (t3 << 18)) & 0x3FFFFFF;
        h4 += (t3 >> 8) | hibit;
        d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1;
        d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2;
        d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3;
        d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4;
        d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
        c = d0 >> 26; h0 = d0 & 0x3FFFFFF;
        d1 += c; c = d1 >> 26; h1 = d1 & 0x3FFFFFF;
        d2 += c; c = d2 >> 26; h2 = d2 & 0x3FFFFFF;
        d3 += c; c = d3 >> 26; h3 = d3 & 0x3FFFFFF;
        d4 += c; c = d4 >> 26; h4 = d4 & 0x3FFFFFF;
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3FFFFFF;
        h1 += c;
    }
    st[5] = (uint32_t)h0; st[6] = (uint32_t)h1; st[7] = (uint32_t)h2; st[8] = (uint32_t)h3;
    st[9] = (uint32_t)h4;
}

/* Argon2's G (RFC 9106 3.5): next = P(prev ^ ref) ^ (prev ^ ref)
   [^ next, after the first pass]; FillBlock in syccrypto.pas. */
#define A2_ROR(x, c) (((x) >> (c)) | ((x) << (64 - (c))))
#define A2_GB(a, b, c, d)                                                   \
    do {                                                                    \
        a = a + b + 2 * (uint64_t)(uint32_t)a * (uint32_t)b; d = A2_ROR(d ^ a, 32); \
        c = c + d + 2 * (uint64_t)(uint32_t)c * (uint32_t)d; b = A2_ROR(b ^ c, 24); \
        a = a + b + 2 * (uint64_t)(uint32_t)a * (uint32_t)b; d = A2_ROR(d ^ a, 16); \
        c = c + d + 2 * (uint64_t)(uint32_t)c * (uint32_t)d; b = A2_ROR(b ^ c, 63); \
    } while (0)
#define A2_P(v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15) \
    do {                                                                    \
        A2_GB(v0, v4, v8, v12); A2_GB(v1, v5, v9, v13);                     \
        A2_GB(v2, v6, v10, v14); A2_GB(v3, v7, v11, v15);                   \
        A2_GB(v0, v5, v10, v15); A2_GB(v1, v6, v11, v12);                   \
        A2_GB(v2, v7, v8, v13); A2_GB(v3, v4, v9, v14);                     \
    } while (0)

void sylzc_argon2_fill(const uint64_t *prev, const uint64_t *ref, uint64_t *next, int withXor)
{
    uint64_t r[128], t[128];
    int i;
    for (i = 0; i < 128; i++)
        r[i] = prev[i] ^ ref[i];
    for (i = 0; i < 128; i++)
        t[i] = withXor ? r[i] ^ next[i] : r[i];
    for (i = 0; i < 8; i++)
        A2_P(r[16 * i], r[16 * i + 1], r[16 * i + 2], r[16 * i + 3],
             r[16 * i + 4], r[16 * i + 5], r[16 * i + 6], r[16 * i + 7],
             r[16 * i + 8], r[16 * i + 9], r[16 * i + 10], r[16 * i + 11],
             r[16 * i + 12], r[16 * i + 13], r[16 * i + 14], r[16 * i + 15]);
    for (i = 0; i < 8; i++)
        A2_P(r[2 * i], r[2 * i + 1], r[2 * i + 16], r[2 * i + 17],
             r[2 * i + 32], r[2 * i + 33], r[2 * i + 48], r[2 * i + 49],
             r[2 * i + 64], r[2 * i + 65], r[2 * i + 80], r[2 * i + 81],
             r[2 * i + 96], r[2 * i + 97], r[2 * i + 112], r[2 * i + 113]);
    for (i = 0; i < 128; i++)
        next[i] = t[i] ^ r[i];
}

/* ── arm64 Linux: FPC 3.2.2's program startup ─────────────────────────── */

#if defined(__aarch64__) && defined(__linux__)
/* FPC 3.2.2's aarch64 cprt0.o (the startup of programs linked with libc,
   which cthreads makes syc one) passes these to __libc_start_main; glibc
   2.34 removed them and ignores those arguments (it runs the init arrays
   itself), so empty ones only satisfy the linker. */
void __libc_csu_init(void) {}
void __libc_csu_fini(void) {}
#endif

/* ── format v4's optimal-parser DP ────────────────────────────────────── */

#define OPT4_ROW_LONG (LIT_SPLIT4 + 1)
#define OPT4_ROWS     (LIT_SPLIT4 + 2)
#define OPT4_COLS     (2 * MAX_ML4 + 2)
#define OPT4_NEVER    (INT32_MAX / 4)

/* TOptDp4Args in sylz.pas */
typedef struct {
    int32_t subLen, minRep;
    int32_t seq, esc, shortOff;   /* penalties, bits */
    int32_t scale;
    int32_t miss;                 /* off the price of a pair with no code, bits */
    const int32_t *litPrice;
    const uint8_t *wsrc;
    intptr_t before;              /* input bytes before the window */
    const int32_t *mtab;          /* [kind][row][length] */
    const struct sylzc_codes4 *codes;
} sylzc_dp4args;

/* LitStep4 in sylz.pas */
static int32_t lit_step4(int32_t ll, const sylzc_dp4args *a)
{
    if (ll < LIT_SPLIT4)
        return ll == MAX_LL4 ? a->scale + a->seq : 0;
    if (ll == LIT_SPLIT4)
        return a->scale * ext_bytes(ll + 1) + a->esc;
    return a->scale * (ext_bytes(ll + 1) - ext_bytes(ll));
}

/* MatchCost4 in sylz.pas */
static int32_t match_cost4(int32_t row, int32_t ml, int kind, const sylzc_dp4args *a)
{
    const struct sylzc_codes4 *c = a->codes;
    int32_t tok = a->scale + a->seq, r;
    intptr_t l = row == OPT4_ROW_LONG ? 0 : row, b, m;
    r = kind == 0 ? 2 * a->scale : 0;
    if (row == OPT4_ROW_LONG && ml > MAX_ML4 && c->cell[kind][ROW4_EXT][COL4_EXT] != 255)
        return r + a->scale * ext_bytes(ml - (kind ? MINREP : MINMATCH));
    if (ml > ML_SPLIT4) {
        if (l > MAX_LL4)
            l -= MAX_LL4;
        if (l > 0 && c->cell[kind][l][COL4_EXT] == 255)
            r += tok;
        return r + tok + a->scale * ext_bytes(ml - (kind ? MINREP : MINMATCH)) + a->esc;
    }
    if (ml > MAX_ML4)
        r += tok;   /* what is left of the match: a token at the previous offset */
    if (row == OPT4_ROW_LONG && ml <= MAX_ML4 && c->cell[kind][ROW4_EXT][ml] != 255)
        ;   /* the run's token is the match's too */
    else if (find_split4(c, kind, l, ml, &b, &m))
        r += tok;
    else if (ml < MINMATCH)
        r = OPT4_NEVER;
    else
        r += 2 * tok - a->miss;
    if (row == OPT4_ROW_LONG && ml < MINMATCH)
        r = OPT4_NEVER;
    return r;
}

/* OptDp4Pas in sylz.pas, same nodes. Each match is relaxed in two
   parts: every length up to subLen (a counted loop over the row: no
   bounds or table tests), then its full length. */
static inline void relax4(sylzc_node *nd, int32_t tc, int32_t ml, int32_t dist)
{
    if (tc < nd->cost) {
        nd->cost = tc;
        nd->ll = 0;
        nd->ml = ml;
        nd->dist = dist;
    }
}

void sylzc_opt_dp4(sylzc_node *nodes, int32_t w, const int32_t *cands,
                   const int32_t *off, const int32_t *cnt, const sylzc_dp4args *a)
{
    const uint8_t *wsrc = a->wsrc;
    const int32_t minRep = a->minRep, subLen = a->subLen;
    /* repDom[row]: in that row a match at the previous distance never
       costs more than another of the same length, even with the short
       offset penalty against none (past the table too: one extension
       byte more at most, against two offset bytes). There, once the
       previous distance has priced the lengths up to some top, no
       candidate can do better at those: they are not tried (same parse,
       2% fewer instructions at level 9). */
    uint8_t repDom[OPT4_ROWS];
    for (int32_t row = 0; row < OPT4_ROWS; row++) {
        const int32_t *rn = a->mtab + row * OPT4_COLS, *rr = rn + OPT4_ROWS * OPT4_COLS;
        int dom = minRep <= MINMATCH;
        for (int32_t ml = MINMATCH; ml < OPT4_COLS; ml++)
            dom &= rr[ml] + a->shortOff <= rn[ml];
        repDom[row] = (uint8_t)dom;
    }
    for (int32_t i = 0; i < w; i++) {
        int32_t k = cnt[i];
        if (k < 0)
            continue;
        sylzc_node *nd = nodes + i;
        int32_t cost = nd->cost;
        int32_t ll = nd->ll;
        int32_t r = nd->dist;
        int32_t tc = cost + a->litPrice[wsrc[i]] + lit_step4(ll, a);
        if (tc < nd[1].cost) {
            nd[1].cost = tc;
            nd[1].ll = ll + 1;
            nd[1].ml = 0;
            nd[1].dist = r;
        }
        int32_t row = ll <= LIT_SPLIT4 ? ll : OPT4_ROW_LONG;
        const int32_t *rowN = a->mtab + row * OPT4_COLS;
        const int32_t *rowR = rowN + OPT4_ROWS * OPT4_COLS;
        int32_t prevLen = MINMATCH - 1;
        /* the previous distance: its first bytes, then the count */
        if (r <= a->before + i
            && (minRep >= 4 ? read32(wsrc + i) == read32(wsrc + i - r)
                            : read16(wsrc + i) == read16(wsrc + i - r))) {
            int32_t rl = (int32_t)count_match_inl(wsrc + i, wsrc + i - r, wsrc + w);
            int32_t base = cost + (r < 16 ? a->shortOff : 0);
            int32_t top = rl < subLen ? rl : subLen;
            for (int32_t ml = minRep; ml <= top; ml++)
                relax4(nd + ml, base + rowR[ml], ml, r);
            if (rl > top && rl >= minRep)
                relax4(nd + rl, base + (rl < OPT4_COLS ? rowR[rl] : match_cost4(row, rl, 1, a)), rl, r);
            if (repDom[row] && top > prevLen)
                prevLen = top;
        }
        if (k == 0)
            continue;
        const int32_t *cp = cands + 2 * off[i];
        const int32_t room = w - i;
        for (int32_t c = 0; c < k; c++) {
            int32_t len = cp[2 * c], dist = cp[2 * c + 1];
            if (dist == r) {
                if (len > prevLen)
                    prevLen = len;   /* priced above, at least as long */
                continue;
            }
            int32_t base = cost + (dist < 16 ? a->shortOff : 0);
            int32_t top = len < subLen ? len : subLen;
            if (top > room)
                top = room;
            for (int32_t ml = prevLen + 1; ml <= top; ml++)
                relax4(nd + ml, base + rowN[ml], ml, dist);
            if (len > subLen && len > prevLen && len <= room)
                relax4(nd + len, base + (len < OPT4_COLS ? rowN[len] : match_cost4(row, len, 0, a)), len, dist);
            if (len > prevLen)
                prevLen = len;
        }
    }
}
