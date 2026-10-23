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
