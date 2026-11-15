#ifndef XSTATS_ROOT_H
#define XSTATS_ROOT_H

/* Restoring square root consumes two input bits per step. Residual is J-M*M. */
static XStatsSumStatus
xs_wide_isqrt(const XStatsWide *j, XStatsWide *root, XStatsWide *residual,
              XStatsWide *trial)
{
    I32 pair;
    U16 digit, increment;
    bool taken;
    XStatsSumStatus status;
    const XStatsWide *buffers[] = {j, root, residual, trial};
    U8 i, k;
    for (i = 1; i < C_ARRAY_LENGTH(buffers); ++i)
        for (k = 0; k < i; ++k)
            if (buffers[i] == buffers[k])
                return XS_SUM_INVALID;
    if (j->sign < 0 || xs_wide_bits(j) > 2 * NV_MANT_DIG)
        return XS_SUM_INVALID;
    Zero(root, 1, XStatsWide);
    Zero(residual, 1, XStatsWide);
    xs_wide_u32(trial, 1);
    if (!j->sign)
        return XS_SUM_OK;
    for (pair = (xs_wide_bits(j) - 1) / 2; pair >= 0; --pair) {
        status = xs_wide_shift(residual, residual, 2);
        if (status != XS_SUM_OK)
            return XS_SUM_INVALID;
        digit = (U16)((xs_wide_word(j, pair / 8) >> (2 * (pair % 8))) & 3);
        status = xs_wide_add_words(residual, &digit, 0, 1, 1);
        if (status != XS_SUM_OK)
            return XS_SUM_INVALID;
        taken = xs_wide_compare(residual, 0, trial, 0) >= 0;
        if (taken) {
            status = xs_wide_subtract_shift(residual, trial, 0);
            if (status != XS_SUM_OK)
                return XS_SUM_INVALID;
        }
        status = xs_wide_shift(root, root, 1);
        if (status != XS_SUM_OK)
            return XS_SUM_INVALID;
        if (taken) {
            increment = 1;
            status = xs_wide_add_words(root, &increment, 0, 1, 1);
            if (status != XS_SUM_OK)
                return XS_SUM_INVALID;
        }
        /* trial=4*root+1. Updating it avoids copying a full scratch buffer. */
        status = xs_wide_shift(trial, trial, 1);
        if (status != XS_SUM_OK)
            return XS_SUM_INVALID;
        increment = taken ? 3 : 1;
        status = xs_wide_add_words(trial, &increment, 0, 1, taken ? 1 : -1);
        if (status != XS_SUM_OK)
            return XS_SUM_INVALID;
    }
    return XS_SUM_OK;
}

/* Round sqrt((a/b) * 2**origin) once, including subnormal results.
 * All scratch buffers are distinct from the inputs and each other. */
static XStatsSumStatus
xs_wide_sqrt_ratio_scaled(const XStatsWide *a, const XStatsWide *b, I32 origin, I8 sign,
                          NV *out, XStatsWide *remainder, XStatsWide *denominator,
                          XStatsWide *quotient, XStatsWide *root, XStatsWide *residual,
                          XStatsWide *trial)
{
    const XStatsWide *buffers[] = {a,        b,    remainder, denominator,
                                   quotient, root, residual,  trial};
    XStatsSumStatus status;
    I32 exponent, quantum, shift;
    I8 comparison;
    NV value;
    U16 one = 1;
    U8 i, j;

    if (!XS_SUM_SUPPORTED)
        return XS_SUM_UNSUPPORTED;

    for (i = 2; i < C_ARRAY_LENGTH(buffers); ++i)
        for (j = 0; j < i; ++j)
            if (buffers[i] == buffers[j])
                return XS_SUM_INVALID;

    if (a->sign < 0 || b->sign <= 0 || origin < 2 * XS_SUM_ORIGIN ||
        origin > 2 * NV_MAX_EXP)
        return XS_SUM_INVALID;

    if (!a->sign) {
        *out = 0;
        return XS_SUM_OK;
    }

    if (sign != -1 && sign != 1)
        return XS_SUM_INVALID;

    if (!origin && !xs_wide_compare(a, 0, b, 0)) {
        *out = sign < 0 ? -(NV)1 : (NV)1;
        return XS_SUM_OK;
    }

    exponent = xs_wide_bits(a) - xs_wide_bits(b);
    comparison = exponent >= 0 ? xs_wide_compare(a, 0, b, exponent)
                               : xs_wide_compare(a, -exponent, b, 0);
    if (comparison < 0)
        --exponent;

    exponent += origin;
    exponent = exponent >= 0 ? exponent / 2 : -((-exponent + 1) / 2);

    if (exponent >= NV_MAX_EXP)
        return XS_SUM_OVERFLOW;

    if (exponent < XS_SUM_ORIGIN - 1) {
        *out = sign < 0 ? -(NV)0 : (NV)0;
        return XS_SUM_OK;
    }

    quantum = exponent - NV_MANT_DIG + 1;
    if (quantum < XS_SUM_ORIGIN)
        quantum = XS_SUM_ORIGIN;

    /* Move the scale to whichever integer can accommodate a left shift. */
    *remainder = *a;
    *denominator = *b;
    shift = origin - 2 * quantum;

    status = shift >= 0 ? xs_wide_shift(remainder, remainder, shift)
                        : xs_wide_shift(denominator, denominator, -shift);
    if (status != XS_SUM_OK)
        return XS_SUM_INVALID;

    status = xs_wide_divide(remainder, denominator, quotient);
    if (status != XS_SUM_OK)
        return status;

    status = xs_wide_isqrt(quotient, root, residual, trial);
    if (status != XS_SUM_OK)
        return status;

    /* Compare against the exact squared midpoint before rounding. */
    comparison = xs_wide_compare(residual, 0, root, 0);
    if (!comparison)
        comparison = xs_wide_compare(remainder, 2, denominator, 0);

    if (comparison > 0 || (!comparison && (root->limb[0] & 1))) {
        status = xs_wide_add_words(root, &one, 0, 1, 1);
        if (status != XS_SUM_OK)
            return XS_SUM_INVALID;
    }

    if (xs_wide_bits(root) + quantum > NV_MAX_EXP)
        return XS_SUM_OVERFLOW;

    value = Perl_ldexp(xs_wide_coefficient(root), quantum);
    if (!Perl_isfinite(value))
        return XS_SUM_OVERFLOW;

    *out = sign < 0 ? -value : value;
    return XS_SUM_OK;
}

/* Correlation's exact squared ratio is in [0,1]. */
static XStatsSumStatus
xs_wide_sqrt_ratio(const XStatsWide *a, const XStatsWide *b, I8 sign, NV *out,
                   XStatsWide *remainder, XStatsWide *quotient, XStatsWide *root,
                   XStatsWide *residual, XStatsWide *trial)
{
    XStatsWide denominator;

    if (a->sign < 0 || b->sign <= 0 || xs_wide_compare(a, 0, b, 0) > 0)
        return XS_SUM_INVALID;

    return xs_wide_sqrt_ratio_scaled(a, b, 0, sign, out, remainder, &denominator,
                                     quotient, root, residual, trial);
}

#endif
