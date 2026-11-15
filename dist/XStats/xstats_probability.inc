/* Match the configured NV, without narrowing long double or binary128. */
#ifdef XSTATS_HAS_NV_ERF
#if defined(USE_QUADMATH)
#define XSTATS_ERF erfq
#elif defined(USE_LONG_DOUBLE)
#define XSTATS_ERF erfl
#else
#define XSTATS_ERF erf
#endif
#endif

#ifdef XSTATS_HAS_NV_ERFC
#if defined(USE_QUADMATH)
#define XSTATS_ERFC erfcq
#elif defined(USE_LONG_DOUBLE)
#define XSTATS_ERFC erfcl
#else
#define XSTATS_ERFC erfc
#endif
#endif

static NV
xs_erf(pTHX_ NV value, bool complement)
{
    PERL_UNUSED_ARG(value);

    if (complement) {
#ifdef XSTATS_ERFC
        return XSTATS_ERFC(value);
#else
        xs_condition(aTHX_ "UNSUPPORTED_MATH", "erfc", 0, 0);
#endif
    } else {
#ifdef XSTATS_ERF
        return XSTATS_ERF(value);
#else
        xs_condition(aTHX_ "UNSUPPORTED_MATH", "erf", 0, 0);
#endif
    }

    return 0;
}

static NV
xs_log_erfc(pTHX_ NV value)
{
    NV tail = xs_erf(aTHX_ value, TRUE);
    NV square, term = 1, sum = 1;
    U32 i;

    if (tail >= NV_MIN)
        return Perl_log(tail);

    /* Inverting a subnormal tail needs more information than rounded erfc.
     * DLMF 7.12.1 bounds the positive-real asymptotic remainder by the first
     * neglected term.  Here value is large, so terms decrease rapidly. */
    square = value * value;
    for (i = 1; i <= NV_MANT_DIG; ++i) {
        NV next = -term * ((NV)(2 * i - 1) / (2 * square));
        NV updated = sum + next;

        if (updated == sum)
            return -square - Perl_log(value) - Perl_log(Perl_atan2((NV)0, (NV)-1)) / 2 +
                   Perl_log(sum);

        if (Perl_fabs(next) >= Perl_fabs(term))
            xs_condition(aTHX_ "NUMERICAL_RESOLUTION", "erfc_inv", 0, 0);

        sum = updated;
        term = next;
    }

    xs_condition(aTHX_ "NUMERICAL_RESOLUTION", "erfc_inv", 0, 0);
    return 0;
}

/* The central inverse avoids subtracting nearly equal error functions. */
static NV
xs_small_erf_inverse(pTHX_ NV target)
{
    NV lo = 0, hi = 2 * target;
    U32 i;

    if (!target)
        return target;

    /* The cubic correction is below NV precision here.  Direct scaling
     * avoids inverting a forward value quantized to a few subnormal steps. */
    if (target < Perl_ldexp((NV)1, -(NV_MANT_DIG / 2 + 2)))
        return target * (Perl_sqrt(Perl_atan2((NV)0, (NV)-1)) / 2);

    for (i = 0; i < NV_MANT_DIG + 16; ++i) {
        NV mid = lo + (hi - lo) / 2;
        NV value;

        if (mid == lo || mid == hi)
            break;

        value = xs_erf(aTHX_ mid, FALSE);
        if (value == target)
            return mid;
        if (value < target)
            lo = mid;
        else
            hi = mid;
    }

    return Perl_fabs(xs_erf(aTHX_ lo, FALSE) - target) <=
                   Perl_fabs(xs_erf(aTHX_ hi, FALSE) - target)
               ? lo
               : hi;
}

static NV
xs_erfc_inverse(pTHX_ NV target)
{
    NV logarithm, lo, hi;
    U32 i;

    if (target == 0)
        return NV_INF;
    if (target == 2)
        return -NV_INF;
    if (target > 1)
        return -xs_erfc_inverse(aTHX_ 2 - target);
    if (target >= (NV)0.5)
        return xs_small_erf_inverse(aTHX_ 1 - target);

    logarithm = Perl_log(target);
    lo = 0;
    hi = 1 + Perl_sqrt(-logarithm);

    for (i = 0; i < NV_MANT_DIG + 16; ++i) {
        NV mid = lo + (hi - lo) / 2;
        NV value;

        if (mid == lo || mid == hi)
            break;

        value = xs_log_erfc(aTHX_ mid);
        if (value == logarithm)
            return mid;
        if (value > logarithm)
            lo = mid;
        else
            hi = mid;
    }

    return Perl_fabs(xs_log_erfc(aTHX_ lo) - logarithm) <=
                   Perl_fabs(xs_log_erfc(aTHX_ hi) - logarithm)
               ? lo
               : hi;
}

static NV
xs_normal_quantile(pTHX_ NV probability)
{
    NV root_two = Perl_sqrt((NV)2);

    if (probability <= (NV)0.5)
        return -root_two * xs_erfc_inverse(aTHX_ 2 * probability);

    return root_two * xs_erfc_inverse(aTHX_ 2 * (1 - probability));
}

static NV
xs_probability_function(pTHX_ SV *input, const char *operation)
{
    NV value = xs_nv_from_sv(aTHX_ input, operation);
    NV root_two = Perl_sqrt((NV)2);

    if (Perl_isnan(value))
        xs_argument(aTHX_ "INVALID_NUMERIC_VALUE", operation);

    if (strEQ(operation, "erf") || strEQ(operation, "erfc"))
        return xs_erf(aTHX_ value, strEQ(operation, "erfc"));

    if (strEQ(operation, "normal_cdf"))
        return xs_erf(aTHX_ - value / root_two, TRUE) / 2;
    if (strEQ(operation, "normal_survival"))
        return xs_erf(aTHX_ value / root_two, TRUE) / 2;

    if (strEQ(operation, "erf_inv")) {
        NV magnitude = Perl_fabs(value), result;

        if (magnitude > 1)
            xs_argument(aTHX_ "INVALID_MATH_DOMAIN", operation);
        if (magnitude <= (NV)0.5)
            result = xs_small_erf_inverse(aTHX_ magnitude);
        else
            result = xs_erfc_inverse(aTHX_ 1 - magnitude);

        return value < 0 ? -result : result;
    }

    if (strEQ(operation, "erfc_inv")) {
        if (value < 0 || value > 2)
            xs_argument(aTHX_ "INVALID_MATH_DOMAIN", operation);

        return xs_erfc_inverse(aTHX_ value);
    }

    if (strEQ(operation, "sigma_to_alpha")) {
        if (value < 0)
            xs_argument(aTHX_ "INVALID_MATH_DOMAIN", operation);

        return xs_erf(aTHX_ value / root_two, TRUE);
    }

    if (value < 0 || value > 1)
        xs_argument(aTHX_ "INVALID_PROBABILITY", operation);

    if (strEQ(operation, "alpha_to_sigma"))
        return root_two * xs_erfc_inverse(aTHX_ value);
    if (strEQ(operation, "normal_quantile"))
        return xs_normal_quantile(aTHX_ value);
    if (strEQ(operation, "normal_inverse_survival"))
        return -xs_normal_quantile(aTHX_ value);

    xs_condition(aTHX_ "NUMERICAL_INVARIANT", operation, 0, 0);
    return 0;
}
