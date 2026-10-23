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
