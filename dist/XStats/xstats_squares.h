#ifndef XSTATS_SQUARES_H
#define XSTATS_SQUARES_H

#define XS_SQUARES_BITS (2 * (NV_MAX_EXP - XS_SUM_ORIGIN) + 32)
#define XS_SQUARES_LIMBS ((XS_SQUARES_BITS + 15) / 16)

/* Squares cannot cancel. Keep only unsigned magnitude and active bounds. */
typedef struct {
    U16 limb[XS_SQUARES_LIMBS];
    U16 lo, hi;
} XStatsSquares;

static bool
xs_squares_valid(const XStatsSquares *s)
{
    if (!s->hi)
        return s->lo == 0;
    return s->lo < s->hi && s->hi <= XS_SQUARES_LIMBS && s->limb[s->lo] &&
           s->limb[s->hi - 1];
}

static XStatsSumStatus
xs_squares_words(XStatsSquares *s, const U16 *source, U32 lo, U32 hi)
{
    U32 i, word, carry = 0, start, end;
    if (lo >= hi)
        return XS_SUM_OK;
    if (hi > XS_SQUARES_LIMBS)
        return XS_SUM_OVERFLOW;
    start = !s->hi || lo < s->lo ? lo : s->lo;
    end = hi > s->hi ? hi : s->hi;
    for (i = start; i < end; ++i) {
        word = (U32)s->limb[i] + carry;
        if (i >= lo && i < hi)
            word += source[i - lo];
        s->limb[i] = (U16)(word & 0xffff);
        carry = word >> 16;
    }
    if (carry) {
        if (end == XS_SQUARES_LIMBS)
            return XS_SUM_OVERFLOW;
        s->limb[end++] = (U16)carry;
    }
    while (end > start && !s->limb[end - 1])
        --end;
    while (start < end && !s->limb[start])
        ++start;
    s->lo = start == end ? 0 : (U16)start;
    s->hi = start == end ? 0 : (U16)end;
    return XS_SUM_OK;
}

static XStatsSumStatus
xs_squares_add(XStatsSquares *s, NV value)
{
    U16 term[XS_TERM_LIMBS], product[2 * XS_TERM_LIMBS];
    U32 lo, hi, i, j, word, carry, length;
    I8 sign;
    XStatsSumStatus status = xs_sum_term(value, term, &lo, &hi, &sign);
    if (status != XS_SUM_OK)
        return status;
    if (!sign)
        return XS_SUM_OK;
    length = hi - lo;
    Zero(product, 2 * XS_TERM_LIMBS, U16);
    for (i = 0; i < length; ++i) {
        carry = 0;
        for (j = 0; j < length; ++j) {
            word = (U32)term[i] * term[j] + product[i + j] + carry;
            product[i + j] = (U16)(word & 0xffff);
            carry = word >> 16;
        }
        product[i + length] = (U16)carry;
    }
    return xs_squares_words(s, product, 2 * lo, 2 * hi);
}

static XStatsSumStatus
xs_squares_merge(XStatsSquares *s, const XStatsSquares *other)
{
    return xs_squares_words(s, other->limb + other->lo, other->lo, other->hi);
}

static XStatsSumStatus
xs_squares_value(const XStatsSquares *s, NV *out)
{
    if (!xs_squares_valid(s))
        return XS_SUM_INVALID;
    return xs_raw_round(s->limb, s->lo, s->hi, s->hi ? 1 : 0, 2 * XS_SUM_ORIGIN, 0, 1,
                        out);
}

#endif
