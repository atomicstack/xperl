#ifndef XSTATS_ORDER_H
#define XSTATS_ORDER_H

static XStatsSumStatus
xs_order_nv(XStatsWide *out, NV value)
{
    U16 term[XS_TERM_LIMBS];
    U32 lo, hi;
    I8 sign;
    XStatsSumStatus status;
    Zero(out, 1, XStatsWide);
    status = xs_sum_term(value, term, &lo, &hi, &sign);
    if (status != XS_SUM_OK)
        return status;
    return xs_wide_add_words(out, term, lo, hi, sign);
}

/* Separate an exact nonnegative position into its rank and fraction. */
static void
xs_order_split(XStatsWide *fraction, I32 origin, U32 *whole)
{
    U32 i, boundary = (U32)-origin;
    U32 word = boundary / 16, part = boundary % 16, end;

    *whole = 0;
    for (i = 32; i-- > 0;)
        *whole = (*whole << 1) | xs_raw_bit(fraction->limb, fraction->lo, fraction->hi,
                                            (I32)(boundary + i));
    end = word;
    if (part) {
        fraction->limb[word] &= (U16)(((U32)1 << part) - 1);
        ++end;
    }
    if (fraction->hi > end)
        Zero(fraction->limb + end, fraction->hi - end, U16);
    xs_wide_trim(fraction, fraction->lo, fraction->hi);
}

/* Split count*p exactly.  The fraction retains units of 2**XS_SUM_ORIGIN. */
static XStatsSumStatus
xs_order_position(XStatsWide *fraction, XStatsWide *work, NV p, U32 count, U32 *whole)
{
    XStatsSumStatus status = xs_order_nv(work, p);

    if (status == XS_SUM_OK)
        status = xs_wide_multiply_u32(fraction, work, count);
    if (status != XS_SUM_OK)
        return status;

    xs_order_split(fraction, XS_SUM_ORIGIN, whole);
    return XS_SUM_OK;
}

/* Evaluate a + (b-a)*fraction without rounding the difference or products. */
static XStatsSumStatus
xs_order_interpolate_scaled(NV a, NV b, const XStatsWide *fraction, I32 origin,
                            XStatsWide *w, NV *out)
{
    XStatsSumStatus status;
    if (a == b || !fraction->sign) {
        *out = a;
        return XS_SUM_OK;
    }
    status = xs_order_nv(&w[0], a);
    if (status != XS_SUM_OK)
        return status;
    status = xs_order_nv(&w[1], b);
    if (status != XS_SUM_OK)
        return status;
    status = xs_wide_add(&w[1], &w[0], TRUE);
    if (status != XS_SUM_OK)
        return status;
    status = xs_wide_multiply(&w[2], &w[1], fraction);
    if (status != XS_SUM_OK)
        return status;
    status = xs_wide_shift(&w[3], &w[0], -origin);
    if (status != XS_SUM_OK)
        return status;
    status = xs_wide_add(&w[2], &w[3], FALSE);
    if (status != XS_SUM_OK)
        return status;
    return xs_raw_round(w[2].limb, w[2].lo, w[2].hi, w[2].sign, XS_SUM_ORIGIN + origin,
                        0, 1, out);
}

static XStatsSumStatus
xs_order_interpolate(NV a, NV b, const XStatsWide *fraction, XStatsWide *w, NV *out)
{
    return xs_order_interpolate_scaled(a, b, fraction, XS_SUM_ORIGIN, w, out);
}

/* Generate an edge from an exact affine numerator before dividing by count. */
static XStatsSumStatus
xs_order_edge(NV a, NV b, U32 index, U32 count, XStatsWide *w, NV *out)
{
    XStatsSumStatus status;
    if (!count || index > count)
        return XS_SUM_INVALID;
    if (!index) {
        *out = a;
        return XS_SUM_OK;
    }
    if (index == count) {
        *out = b;
        return XS_SUM_OK;
    }
    status = xs_order_nv(&w[0], a);
    if (status != XS_SUM_OK)
        return status;
    status = xs_order_nv(&w[1], b);
    if (status != XS_SUM_OK)
        return status;
    status = xs_wide_multiply_u32(&w[2], &w[0], count - index);
    if (status != XS_SUM_OK)
        return status;
    status = xs_wide_multiply_u32(&w[0], &w[1], index);
    if (status != XS_SUM_OK)
        return status;
    status = xs_wide_add(&w[0], &w[2], FALSE);
    if (status != XS_SUM_OK)
        return status;
    xs_wide_u32(&w[1], count);
    return xs_wide_ratio(&w[0], &w[1], XS_SUM_ORIGIN, out, &w[2], &w[3], &w[4]);
}

#endif
