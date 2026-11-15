/* Native implementation included by XStats.xs.
 * The kernels and bindings share one compilation unit. */

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <stddef.h>
#include "xstats_sum.h"
#include "xstats_squares.h"
#include "xstats_wide.h"
#include "xstats_root.h"
#include "xstats_order.h"
#define XS_SIZE_MAX ((STRLEN) ~(STRLEN)0)
#define XS_VALID_HEADER ((U32)1)
#define XS_VALID_SQUARES ((U32)2)

typedef struct {
    /* Centred state is in units of 2**exponent; total is an exact dyadic sum. */
    NV mean, mean_error;
    NV m2, m2_error, m2_scale;
    NV min, max, sum_result, mean_result, squares_result;
    XStatsSumStatus sum_status, squares_status;
    XStatsExactSum total;
    U32 min_index, max_index;
    I32 exponent;
} XStatsSummary;
typedef struct {
    U32 count;
    U32 valid;
    XStatsSummary summary;
    NV values[1];
} XStatsData;

typedef struct {
    U32 count;
    U32 valid;
    XStatsSummary summary;
    XStatsSquares squares;
} XStatsSparseData;

STATIC_ASSERT_DECL(offsetof(XStatsData, values) == offsetof(XStatsSparseData, squares));

static void
xs_condition_detail(pTHX_ const char *condition, const char *operation, U32 actual,
                    U32 required, bool argument_condition)
{
    dSP;
    SV *exception;
    HV *values;
    const PERL_CONTEXT *caller = caller_cx(0, NULL);
    const COP *site = caller ? caller->blk_oldcop : PL_curcop;
    ENTER;
    SAVETMPS;
    values = newHV();
    if (strEQ(condition, "RESULT_OVERFLOW"))
        (void)hv_stores(values, "statistic", newSVpv(operation, 0));
    else if (argument_condition) {
        (void)hv_stores(values, "argument", newSVpv(operation, 0));
    } else {
        (void)hv_stores(values, "operation", newSVpv(operation, 0));
        if (strEQ(condition, "INSUFFICIENT_OBSERVATIONS")) {
            (void)hv_stores(values, "actual", newSVuv(actual));
            (void)hv_stores(values, "required", newSVuv(required));
        }
    }
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVpv(condition, 0)));
    XPUSHs(sv_2mortal(newRV_noinc(MUTABLE_SV(values))));
    XPUSHs(sv_2mortal(newSVpv(site ? OutCopFILE(site) : "", 0)));
    XPUSHs(sv_2mortal(newSVuv(site ? CopLINE(site) : 0)));
    PUTBACK;
    call_pv("XStats::_exception_at", G_SCALAR);
    SPAGAIN;
    exception = sv_2mortal(newSVsv(POPs));
    PUTBACK;
    /* The unwind releases this temporary scope and its call arguments. */
    croak_sv(exception);
}

static void
xs_condition(pTHX_ const char *condition, const char *operation, U32 actual,
             U32 required)
{
    xs_condition_detail(aTHX_ condition, operation, actual, required, FALSE);
}

static void
xs_argument(pTHX_ const char *condition, const char *argument)
{
    xs_condition_detail(aTHX_ condition, argument, 0, 0, TRUE);
}

static NV
xs_nv_from_sv(pTHX_ SV *value, const char *argument)
{
    STRLEN len;
    const char *text;
    U32 flags;
    NV result;
    if (SvMAGICAL(value) || !SvOK(value) || SvROK(value))
        xs_argument(aTHX_ "INVALID_NUMERIC_VALUE", argument);

    /* Numeric SVs retain their numeric value, including dualvars.  Parse
     * strings directly as NV without populating a numeric cache. */
    if (SvNOK(value))
        return (NV)SvNVX(value);
    if (SvIOK(value))
        return SvIsUV(value) ? (NV)SvUVX(value) : (NV)SvIVX(value);

    text = SvPV(value, len);
    result = parse_nv(text, len, &flags);
    if (!flags || (flags & IS_NUMBER_TRAILING))
        xs_argument(aTHX_ "INVALID_NUMERIC_VALUE", argument);
    if ((flags & PERL_PARSE_OVERFLOW) ||
        ((flags & PERL_PARSE_UNDERFLOW) && result == 0))
        xs_argument(aTHX_ "INPUT_OUT_OF_RANGE", argument);
    return result;
}

static void
xs_two_sum(NV a, NV b, NV *high, NV *low)
{
    /* Every step must round to NV, including on x87 evaluation stacks. */
    volatile NV a0 = a, b0 = b;
    volatile NV sum = a0 + b0;
    volatile NV bv = sum - a0, av = sum - bv;
    volatile NV br = b0 - bv, ar = a0 - av;
    volatile NV error = ar + br;
    *high = sum;
    *low = error;
}

static void
xs_accumulate(NV *sum, NV *error, NV x)
{
    NV high, low;
    xs_two_sum(*sum, x, &high, &low);
    xs_two_sum(high, *error + low, sum, error);
}

static void
xs_difference(NV a, NV b, NV *high, NV *low)
{
    xs_two_sum(a, -b, high, low);
}

static void
xs_rescale(XStatsSummary *s, I32 exponent)
{
    I32 shift = s->exponent - exponent;
    s->mean = Perl_ldexp(s->mean, shift);
    s->mean_error = Perl_ldexp(s->mean_error, shift);
    s->m2_scale = Perl_ldexp(s->m2_scale, shift);
    s->exponent = exponent;
}

/* Keep squared deviations scaled so a representable SD survives underflow. */
static void
xs_moment(XStatsSummary *s, NV delta, NV weight)
{
    NV magnitude = Perl_fabs(delta), ratio;
    if (!magnitude || !weight)
        return;
    if (magnitude > s->m2_scale) {
        ratio = s->m2_scale / magnitude;
        s->m2 *= ratio * ratio;
        s->m2_error *= ratio * ratio;
        s->m2_scale = magnitude;
        ratio = 1;
    } else
        ratio = delta / s->m2_scale;
    xs_accumulate(&s->m2, &s->m2_error, ratio * ratio * weight);
}

static void
xs_sum_failure(pTHX_ XStatsSumStatus status)
{
    if (status == XS_SUM_UNSUPPORTED)
        croak("XStats: unsupported numerical backend");
    if (status == XS_SUM_OVERFLOW)
        xs_condition(aTHX_ "RESULT_OVERFLOW", "sum", 0, 0);
    croak("XStats: invalid exact sum storage");
}

static NV
xs_total(pTHX_ const XStatsSummary *s, U32 divisor)
{
    NV value;
    XStatsSumStatus status = xs_sum_value(&s->total, divisor, &value);
    if (status != XS_SUM_OK)
        xs_sum_failure(aTHX_ status);
    return value;
}

static void
xs_finish(pTHX_ XStatsSummary *s, U32 n)
{
    s->sum_status = xs_sum_value(&s->total, 1, &s->sum_result);
    if (s->sum_status != XS_SUM_OK && s->sum_status != XS_SUM_OVERFLOW)
        xs_sum_failure(aTHX_ s->sum_status);
    if (s->sum_status == XS_SUM_OVERFLOW)
        s->sum_result = 0;
    s->mean_result = n ? xs_total(aTHX_ s, n) : 0;
}

static XStatsSumStatus
xs_scaled_value(NV coefficient, I32 exponent, NV *out)
{
    I32 adjustment;
    if (!Perl_isfinite(coefficient) || coefficient < 0)
        return XS_SUM_INVALID;
    if (!coefficient) {
        *out = 0;
        return XS_SUM_OK;
    }
    (void)xs_nv_parts(coefficient, &adjustment);
    if (adjustment + exponent > NV_MAX_EXP)
        return XS_SUM_OVERFLOW;
    *out = Perl_ldexp(coefficient, exponent);
    return Perl_isfinite(*out) ? XS_SUM_OK : XS_SUM_OVERFLOW;
}

static XStatsSumStatus
xs_spread_value(const XStatsSummary *s, U32 divisor, bool deviation, NV *out)
{
    NV normalized, scale, factor, coefficient;
    I32 scale_exponent, factor_exponent, exponent;
    if (!divisor || !Perl_isfinite(s->m2) || !Perl_isfinite(s->m2_error) ||
        !Perl_isfinite(s->m2_scale) || s->m2_scale < 0)
        return XS_SUM_INVALID;
    normalized = (s->m2 + s->m2_error) / divisor;
    if (!Perl_isfinite(normalized) || normalized < 0)
        return XS_SUM_INVALID;
    if (!s->m2_scale || !normalized) {
        *out = 0;
        return XS_SUM_OK;
    }
    scale = xs_nv_parts(s->m2_scale, &scale_exponent);
    factor =
        xs_nv_parts(deviation ? Perl_sqrt(normalized) : normalized, &factor_exponent);
    coefficient = deviation ? scale * factor : scale * scale * factor;
    exponent = deviation ? scale_exponent + factor_exponent + s->exponent
                         : 2 * scale_exponent + factor_exponent + 2 * s->exponent;
    return xs_scaled_value(coefficient, exponent, out);
}

static NV
xs_spread(pTHX_ const XStatsSummary *s, U32 divisor, bool deviation,
          const char *operation)
{
    NV value;
    XStatsSumStatus status = xs_spread_value(s, divisor, deviation, &value);
    if (status == XS_SUM_OVERFLOW)
        xs_condition(aTHX_ "RESULT_OVERFLOW", operation, 0, 0);
    if (status != XS_SUM_OK)
        xs_condition(aTHX_ "NUMERICAL_INVARIANT", operation, 0, 0);
    return value;
}

static XStatsSumStatus
xs_difference_value(NV upper, NV lower, NV *out)
{
    XStatsExactSum total;
    XStatsSumStatus status;
    Zero(&total, 1, XStatsExactSum);
    status = xs_sum_add(&total, upper);
    if (status == XS_SUM_OK)
        status = xs_sum_add(&total, -lower);
    return status == XS_SUM_OK ? xs_sum_value(&total, 1, out) : status;
}

static XStatsSumStatus
xs_range_value(const XStatsSummary *s, NV *out)
{
    return xs_difference_value(s->max, s->min, out);
}

static NV
xs_midpoint(pTHX_ NV a, NV b)
{
    XStatsExactSum total;
    XStatsSumStatus status;
    NV result;
    Zero(&total, 1, XStatsExactSum);
    status = xs_sum_add(&total, a);
    if (status == XS_SUM_OK)
        status = xs_sum_add(&total, b);
    if (status == XS_SUM_OK)
        status = xs_sum_value(&total, 2, &result);
    if (status != XS_SUM_OK)
        xs_sum_failure(aTHX_ status);
    return result;
}

static void
xs_push(pTHX_ XStatsSummary *s, U32 n, NV x)
{
    NV high, low, scaled, divisor = n + (NV)1;
    I32 exponent;
    XStatsSumStatus status;
    if (!n)
        Zero(s, 1, XStatsSummary);
    if (x) {
        (void)xs_nv_parts(x, &exponent);
        if (!n || (s->min == 0 && s->max == 0) || exponent > s->exponent)
            xs_rescale(s, exponent);
    }
    scaled = Perl_ldexp(x, -s->exponent);
    if (!n)
        s->min = s->max = x, s->mean = scaled;
    else {
        xs_difference(scaled, s->mean, &high, &low);
        low -= s->mean_error;
        xs_moment(s, high + low, (NV)n / divisor);
        xs_accumulate(&s->mean, &s->mean_error, high / divisor);
        xs_accumulate(&s->mean, &s->mean_error, low / divisor);
    }
    status = xs_sum_add(&s->total, x);
    if (status != XS_SUM_OK)
        xs_sum_failure(aTHX_ status);
    if (x < s->min)
        s->min = x, s->min_index = n;
    if (x > s->max)
        s->max = x, s->max_index = n;
    if (!Perl_isfinite(s->mean) || !Perl_isfinite(s->mean_error) ||
        !Perl_isfinite(s->m2) || !Perl_isfinite(s->m2_error) ||
        !Perl_isfinite(s->m2_scale))
        croak("XStats: numerical overflow");
}

static SV *
xs_input_named(pTHX_ SV *arg, const char *argument)
{
    AV *av;
    SSize_t last, i;
    SV *buf;
    NV *v;
    if (!SvROK(arg) || SvTYPE(SvRV(arg)) != SVt_PVAV) {
        if (argument)
            xs_argument(aTHX_ "INVALID_NUMERIC_ARRAY", argument);
        croak("XStats: expected an array reference");
    }
    av = (AV *)SvRV(arg);
    if (SvMAGICAL((SV *)av)) {
        if (argument)
            xs_argument(aTHX_ "INVALID_NUMERIC_ARRAY", argument);
        croak("XStats: magical arrays are unsupported");
    }
    last = av_len(av);
    if ((UV)(last + 1) > U32_MAX || (UV)(last + 1) > (XS_SIZE_MAX - 1) / sizeof(NV)) {
        if (argument)
            xs_argument(aTHX_ "TOO_MANY_VALUES", argument);
        croak("XStats: too many observations");
    }
    buf = sv_2mortal(newSVpvn("", 0));
    SvGROW(buf, (STRLEN)(last + 1) * sizeof(NV) + 1);
    SvPOK_on(buf);
    SvCUR_set(buf, (STRLEN)(last + 1) * sizeof(NV));
    v = (NV *)SvPVX(buf);
    for (i = 0; i <= last; ++i) {
        SV **slot = av_fetch(av, i, 0);
        SV *x = slot ? *slot : NULL;
        if (!x || SvMAGICAL(x) || !SvOK(x) || SvROK(x) ||
            (!SvNIOK(x) && !looks_like_number(x))) {
            if (argument)
                xs_argument(aTHX_ "INVALID_NUMERIC_ARRAY", argument);
            croak("XStats: observation %" IVdf " is not a plain number", (IV)i);
        }
        v[i] = xs_nv_from_sv(aTHX_ x, argument ? argument : "values");
        if (!Perl_isfinite(v[i])) {
            if (argument)
                xs_argument(aTHX_ "INVALID_NUMERIC_ARRAY", argument);
            croak("XStats: observations must be finite");
        }
    }
    SvPVX(buf)[SvCUR(buf)] = 0;
    return buf;
}

static SV *
xs_input(pTHX_ SV *arg)
{
    return xs_input_named(aTHX_ arg, NULL);
}

static XStatsData *
xs_data(pTHX_ SV *obj, SV **referent)
{
    SV *sv;
    XStatsData *d;
    STRLEN bytes;
    if (!SvROK(obj) ||
        !(sv_derived_from(obj, "XStats") || sv_derived_from(obj, "XStats::Sparse")))
        croak("XStats: expected an XStats object");
    sv = SvRV(obj);
    if (SvTYPE(sv) >= SVt_PVAV || SvMAGICAL(sv) || !SvPOK(sv) || !SvLEN(sv) ||
        SvUTF8(sv) || SvOOK(sv) || SvCUR(sv) < offsetof(XStatsData, values))
        croak("XStats: invalid object storage");
    d = (XStatsData *)SvPVX(sv);
    if (d->summary.exponent < NV_MIN_EXP - NV_MANT_DIG + 1 ||
        d->summary.exponent > NV_MAX_EXP)
        croak("XStats: invalid object exponent");
    if (!xs_sum_valid(&d->summary.total))
        croak("XStats: invalid exact sum storage");
    if (sv_derived_from(obj, "XStats::Sparse")) {
        if (d->valid != (XS_VALID_HEADER | XS_VALID_SQUARES) ||
            SvCUR(sv) != sizeof(XStatsSparseData))
            croak("XStats: invalid incremental storage");
        if (!xs_squares_valid(&((XStatsSparseData *)d)->squares))
            croak("XStats: invalid incremental square storage");
        *referent = sv;
        return d;
    }
    if (!(d->valid & XS_VALID_HEADER) ||
        (d->valid & ~(XS_VALID_HEADER | XS_VALID_SQUARES)) ||
        (STRLEN)d->count > (SvCUR(sv) - offsetof(XStatsData, values)) / sizeof(NV))
        croak("XStats: invalid object header");
    bytes = offsetof(XStatsData, values) + (STRLEN)d->count * sizeof(NV);
    if (bytes < sizeof(XStatsData))
        bytes = sizeof(XStatsData);
    if (bytes != SvCUR(sv))
        croak("XStats: invalid object extent");
    *referent = sv;
    return d;
}

/* qsort requires an int return type for its comparison callback. */
static int
xs_compare(const void *a, const void *b)
{
    NV x = *(const NV *)a, y = *(const NV *)b;
    return (x > y) - (x < y);
}

/* Local state keeps resampling independent of the application's RNG. */
static U32
xs_rotate(U32 x, U8 k)
{
    return (x << k) | (x >> (32 - k));
}

static U32
xs_random(U32 *s)
{
    U32 result = xs_rotate(s[1] * 5, 7) * 9;
    U32 t = s[1] << 9;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = xs_rotate(s[3], 11);
    return result;
}

static U32
xs_index(U32 *s, U32 bound)
{
    U32 x, threshold = (U32)(0U - bound) % bound;
    do {
        x = xs_random(s);
    } while (x < threshold);
    return x % bound;
}

enum {
    XS_PAIR_SX,
    XS_PAIR_SY,
    XS_PAIR_QXX,
    XS_PAIR_QXY,
    XS_PAIR_C,
    XS_PAIR_VX,
    XS_PAIR_TEMP0,
    XS_PAIR_TEMP1,
    XS_PAIR_NUMERATOR,
    XS_PAIR_REMAINDER,
    XS_PAIR_DENOMINATOR,
    XS_PAIR_QUOTIENT,
    XS_PAIR_BASIC_BUFFERS,
    XS_PAIR_QYY = XS_PAIR_BASIC_BUFFERS,
    XS_PAIR_VY,
    XS_PAIR_ROOT,
    XS_PAIR_RESIDUAL,
    XS_PAIR_TRIAL,
    XS_PAIR_BUFFERS
};

typedef struct {
    XStatsExactSum y_total;
    XStatsWide value[1];
} XStatsPairScratch;

static void
xs_paired_status(pTHX_ XStatsSumStatus status, const char *operation)
{
    if (status == XS_SUM_UNSUPPORTED)
        xs_sum_failure(aTHX_ status);
    xs_condition(aTHX_ "NUMERICAL_INVARIANT", operation, 0, 0);
}

static void
xs_paired_result(pTHX_ XStatsSumStatus status, const char *operation)
{
    if (status == XS_SUM_OVERFLOW)
        xs_condition(aTHX_ "RESULT_OVERFLOW", operation, 0, 0);
    xs_paired_status(aTHX_ status, operation);
}

static void
xs_fit_diagnostics(pTHX_ XStatsWide *w, U32 n, HV *result)
{
    HV *unavailable = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    XStatsSumStatus status;
    NV value;

    /* Form the centred response sum and the covariance determinant exactly. */
    status = xs_wide_multiply_u32(&w[XS_PAIR_VY], &w[XS_PAIR_QYY], n);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply(&w[XS_PAIR_TEMP0], &w[XS_PAIR_SY], &w[XS_PAIR_SY]);
    if (status == XS_SUM_OK)
        status = xs_wide_add(&w[XS_PAIR_VY], &w[XS_PAIR_TEMP0], TRUE);
    if (status != XS_SUM_OK || w[XS_PAIR_VY].sign < 0)
        xs_paired_status(aTHX_ status, "linear_regression");

    status = xs_wide_multiply(&w[XS_PAIR_DENOMINATOR], &w[XS_PAIR_VX], &w[XS_PAIR_VY]);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply(&w[XS_PAIR_NUMERATOR], &w[XS_PAIR_C], &w[XS_PAIR_C]);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, "linear_regression");

    w[XS_PAIR_TEMP0] = w[XS_PAIR_DENOMINATOR];
    status = xs_wide_add(&w[XS_PAIR_TEMP0], &w[XS_PAIR_NUMERATOR], TRUE);
    if (status != XS_SUM_OK || w[XS_PAIR_TEMP0].sign < 0)
        xs_paired_status(aTHX_ status, "linear_regression");

    if (w[XS_PAIR_VY].sign) {
        status = xs_wide_ratio(&w[XS_PAIR_NUMERATOR], &w[XS_PAIR_DENOMINATOR], 0,
                               &value, &w[XS_PAIR_REMAINDER], &w[XS_PAIR_TEMP1],
                               &w[XS_PAIR_QUOTIENT]);
        if (status != XS_SUM_OK)
            xs_paired_result(aTHX_ status, "regression_r_squared");

        (void)hv_stores(result, "r_squared", newSVnv(value));

        status = xs_wide_sqrt_ratio(&w[XS_PAIR_NUMERATOR], &w[XS_PAIR_DENOMINATOR],
                                    w[XS_PAIR_C].sign, &value, &w[XS_PAIR_REMAINDER],
                                    &w[XS_PAIR_QUOTIENT], &w[XS_PAIR_ROOT],
                                    &w[XS_PAIR_RESIDUAL], &w[XS_PAIR_TRIAL]);
        if (status != XS_SUM_OK)
            xs_paired_result(aTHX_ status, "regression_correlation");

        (void)hv_stores(result, "correlation", newSVnv(value));
    } else {
        (void)hv_stores(result, "correlation", newSV(0));
        (void)hv_stores(result, "r_squared", newSV(0));
        (void)hv_stores(unavailable, "correlation", newSVpvs("constant_response"));
        (void)hv_stores(unavailable, "r_squared", newSVpvs("constant_response"));
    }

    /* RMS^2 = (Vx*Vy-C^2)/(n^2*Vx), in units of 2**(2*XS_SUM_ORIGIN).
     * Computing it before rounding the fitted coefficients preserves exact fits. */
    status = xs_wide_multiply_u32(&w[XS_PAIR_TEMP1], &w[XS_PAIR_VX], n);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply_u32(&w[XS_PAIR_DENOMINATOR], &w[XS_PAIR_TEMP1], n);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, "regression_residual_rms");

    status = xs_wide_sqrt_ratio_scaled(
        &w[XS_PAIR_TEMP0], &w[XS_PAIR_DENOMINATOR], 2 * XS_SUM_ORIGIN, 1, &value,
        &w[XS_PAIR_REMAINDER], &w[XS_PAIR_TEMP1], &w[XS_PAIR_QUOTIENT],
        &w[XS_PAIR_ROOT], &w[XS_PAIR_RESIDUAL], &w[XS_PAIR_TRIAL]);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, "regression_residual_rms");

    (void)hv_stores(result, "residual_rms", newSVnv(value));
    (void)hv_stores(result, "unavailable", newRV_inc(MUTABLE_SV(unavailable)));
}

static SV *
xs_exact_paired(pTHX_ const XStatsData *data, const NV *y, const char *operation)
{
    bool correlation = strEQ(operation, "correlation");
    bool regression = strEQ(operation, "linear_regression");
    STRLEN bytes =
        offsetof(XStatsPairScratch, value) +
        ((correlation || regression) ? XS_PAIR_BUFFERS : XS_PAIR_BASIC_BUFFERS) *
            sizeof(XStatsWide);
    SV *storage = sv_2mortal(newSV(bytes));
    XStatsPairScratch *scratch;
    XStatsWide *w;
    U32 i, n = data->count;
    NV value, slope, intercept;
    HV *result;
    XStatsSumStatus status;
    SvPOK_on(storage);
    SvCUR_set(storage, bytes);
    Zero(SvPVX(storage), bytes + 1, char);
    scratch = (XStatsPairScratch *)SvPVX(storage);
    w = scratch->value;
    xs_wide_scalar(&w[XS_PAIR_SX], &data->summary.total);
    for (i = 0; i < n; ++i) {
        status = xs_sum_add(&scratch->y_total, y[i]);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        status = xs_wide_product(&w[XS_PAIR_QXY], data->values[i], y[i]);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        if (regression || correlation) {
            status = xs_wide_product(&w[XS_PAIR_QXX], data->values[i], data->values[i]);
            if (status != XS_SUM_OK)
                xs_paired_status(aTHX_ status, operation);
        }
        if (correlation || regression) {
            status = xs_wide_product(&w[XS_PAIR_QYY], y[i], y[i]);
            if (status != XS_SUM_OK)
                xs_paired_status(aTHX_ status, operation);
        }
    }
    xs_wide_scalar(&w[XS_PAIR_SY], &scratch->y_total);
    status = xs_wide_multiply_u32(&w[XS_PAIR_C], &w[XS_PAIR_QXY], n);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    status = xs_wide_multiply(&w[XS_PAIR_TEMP0], &w[XS_PAIR_SX], &w[XS_PAIR_SY]);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    status = xs_wide_add(&w[XS_PAIR_C], &w[XS_PAIR_TEMP0], TRUE);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    if (strEQ(operation, "covariance")) {
        xs_wide_u32(&w[XS_PAIR_TEMP0], n);
        status = xs_wide_multiply_u32(&w[XS_PAIR_TEMP1], &w[XS_PAIR_TEMP0], n - 1);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        status = xs_wide_ratio(&w[XS_PAIR_C], &w[XS_PAIR_TEMP1], 2 * XS_SUM_ORIGIN,
                               &value, &w[XS_PAIR_REMAINDER], &w[XS_PAIR_DENOMINATOR],
                               &w[XS_PAIR_QUOTIENT]);
        if (status != XS_SUM_OK)
            xs_paired_result(aTHX_ status, operation);
        return newSVnv(value);
    }
    status = xs_wide_multiply_u32(&w[XS_PAIR_VX], &w[XS_PAIR_QXX], n);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    status = xs_wide_multiply(&w[XS_PAIR_TEMP0], &w[XS_PAIR_SX], &w[XS_PAIR_SX]);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    status = xs_wide_add(&w[XS_PAIR_VX], &w[XS_PAIR_TEMP0], TRUE);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    if (w[XS_PAIR_VX].sign < 0)
        xs_paired_status(aTHX_ XS_SUM_INVALID, operation);
    if (!w[XS_PAIR_VX].sign)
        xs_condition(aTHX_ "UNDEFINED_STATISTIC", operation, 0, 0);
    if (correlation) {
        status = xs_wide_multiply_u32(&w[XS_PAIR_VY], &w[XS_PAIR_QYY], n);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        status = xs_wide_multiply(&w[XS_PAIR_TEMP0], &w[XS_PAIR_SY], &w[XS_PAIR_SY]);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        status = xs_wide_add(&w[XS_PAIR_VY], &w[XS_PAIR_TEMP0], TRUE);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        if (w[XS_PAIR_VY].sign < 0)
            xs_paired_status(aTHX_ XS_SUM_INVALID, operation);
        if (!w[XS_PAIR_VY].sign)
            xs_condition(aTHX_ "UNDEFINED_STATISTIC", operation, 0, 0);
        status = xs_wide_multiply(&w[XS_PAIR_NUMERATOR], &w[XS_PAIR_C], &w[XS_PAIR_C]);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        status =
            xs_wide_multiply(&w[XS_PAIR_DENOMINATOR], &w[XS_PAIR_VX], &w[XS_PAIR_VY]);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        status = xs_wide_sqrt_ratio(&w[XS_PAIR_NUMERATOR], &w[XS_PAIR_DENOMINATOR],
                                    w[XS_PAIR_C].sign, &value, &w[XS_PAIR_REMAINDER],
                                    &w[XS_PAIR_QUOTIENT], &w[XS_PAIR_ROOT],
                                    &w[XS_PAIR_RESIDUAL], &w[XS_PAIR_TRIAL]);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
        return newSVnv(value);
    }
    status =
        xs_wide_ratio(&w[XS_PAIR_C], &w[XS_PAIR_VX], 0, &slope, &w[XS_PAIR_REMAINDER],
                      &w[XS_PAIR_DENOMINATOR], &w[XS_PAIR_QUOTIENT]);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, "regression_slope");
    status = xs_wide_multiply(&w[XS_PAIR_NUMERATOR], &w[XS_PAIR_QXX], &w[XS_PAIR_SY]);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    status = xs_wide_multiply(&w[XS_PAIR_TEMP0], &w[XS_PAIR_SX], &w[XS_PAIR_QXY]);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    status = xs_wide_add(&w[XS_PAIR_NUMERATOR], &w[XS_PAIR_TEMP0], TRUE);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);
    status = xs_wide_ratio(&w[XS_PAIR_NUMERATOR], &w[XS_PAIR_VX], XS_SUM_ORIGIN,
                           &intercept, &w[XS_PAIR_REMAINDER], &w[XS_PAIR_DENOMINATOR],
                           &w[XS_PAIR_QUOTIENT]);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, "regression_intercept");
    result = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    (void)hv_stores(result, "slope", newSVnv(slope));
    (void)hv_stores(result, "intercept", newSVnv(intercept));
    (void)hv_stores(result, "count", newSVuv(n));

    xs_fit_diagnostics(aTHX_ w, n, result);

    return newRV_inc(MUTABLE_SV(result));
}

static SV *
xs_linear_trend(pTHX_ const XStatsData *data)
{
    const U32 n = data->count;
    STRLEN bytes = offsetof(XStatsData, values) + (STRLEN)n * sizeof(NV);
    SV *storage = sv_2mortal(newSV(bytes));
    XStatsData *predictors;
    XStatsSumStatus status;
    U32 i;

    /* The paired kernel needs only packed predictors and their exact sum. */
    SvPOK_on(storage);
    SvCUR_set(storage, bytes);
    Zero(SvPVX(storage), bytes + 1, char);

    predictors = (XStatsData *)SvPVX(storage);
    predictors->count = n;

    for (i = 0; i < n; ++i) {
        predictors->values[i] = (NV)i + 1;
        status = xs_sum_add(&predictors->summary.total, predictors->values[i]);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, "linear_trend");
    }

    return xs_exact_paired(aTHX_ predictors, data->values, "linear_regression");
}

static void
xs_incremental_finish_squares(pTHX_ XStatsSparseData *data)
{
    XStatsSumStatus status =
        xs_squares_value(&data->squares, &data->summary.squares_result);
    if (status != XS_SUM_OK && status != XS_SUM_OVERFLOW)
        xs_paired_status(aTHX_ status, "sum_of_squares");
    if (status == XS_SUM_OVERFLOW)
        data->summary.squares_result = 0;
    data->summary.squares_status = status;
    data->valid = XS_VALID_HEADER | XS_VALID_SQUARES;
}

static XStatsSumStatus
xs_stored_squares(pTHX_ const XStatsData *data, NV *result)
{
    SV *storage = sv_2mortal(newSV(sizeof(XStatsSquares)));
    XStatsSquares *squares;
    XStatsSumStatus status;
    U32 i;
    SvPOK_on(storage);
    SvCUR_set(storage, sizeof(XStatsSquares));
    Zero(SvPVX(storage), sizeof(XStatsSquares) + 1, char);
    squares = (XStatsSquares *)SvPVX(storage);
    for (i = 0; i < data->count; ++i) {
        status = xs_squares_add(squares, data->values[i]);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, "sum_of_squares");
    }
    status = xs_squares_value(squares, result);
    if (status != XS_SUM_OK && status != XS_SUM_OVERFLOW)
        xs_paired_status(aTHX_ status, "sum_of_squares");
    if (status == XS_SUM_OVERFLOW)
        *result = 0;
    return status;
}

static XStatsWide *
xs_order_scratch(pTHX_ U32 count)
{
    STRLEN bytes = (STRLEN)count * sizeof(XStatsWide);
    SV *storage = sv_2mortal(newSV(bytes));
    SvPOK_on(storage);
    SvCUR_set(storage, bytes);
    Zero(SvPVX(storage), bytes + 1, char);
    return (XStatsWide *)SvPVX(storage);
}

/* Scale reciprocals before dividing, then round their exact NV sum only
 * in the final ratio.  This avoids both reciprocal and numerator overflow. */
static NV
xs_harmonic_mean(pTHX_ const XStatsData *data)
{
    const char *operation = "harmonic_mean";
    const U32 n = data->count;
    const NV *values = data->values;

    XStatsExactSum reciprocal, numerator;
    XStatsWide *work;
    XStatsSumStatus status;
    NV scale, term, result;
    U32 i;

    if (!n)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", operation, 0, 1);

    if (data->summary.min == data->summary.max) {
        if (!data->summary.min)
            xs_condition(aTHX_ "NONZERO_OBSERVATIONS_REQUIRED", operation, 0, 0);

        return data->summary.min;
    }

    scale = Perl_fabs(values[0]);
    for (i = 0; i < n; ++i) {
        if (!values[i])
            xs_condition(aTHX_ "NONZERO_OBSERVATIONS_REQUIRED", operation, 0, 0);

        if (Perl_fabs(values[i]) < scale)
            scale = Perl_fabs(values[i]);
    }

    Zero(&reciprocal, 1, XStatsExactSum);
    for (i = 0; i < n; ++i) {
        term = scale / values[i];
        if (!term)
            xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

        status = xs_sum_add(&reciprocal, term);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
    }

    if (!reciprocal.sign)
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

    /* Opposite signs can expose reciprocal rounding as a false denominator.
     * Each scaled quotient has magnitude at most one, so one ulp at one
     * per term bounds division error even under directed rounding. */
    if (data->summary.min < 0 && data->summary.max > 0) {
        NV denominator, error_bound = Perl_ldexp((NV)n, 1 - NV_MANT_DIG);

        status = xs_sum_value(&reciprocal, 1, &denominator);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);

        if (Perl_fabs(denominator) <= error_bound)
            xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);
    }

    /* Keep n*scale outside NV so an overflowing numerator is harmless. */
    Zero(&numerator, 1, XStatsExactSum);
    status = xs_sum_add(&numerator, scale);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    work = xs_order_scratch(aTHX_ 6);
    xs_wide_scalar(&work[0], &numerator);
    xs_wide_scalar(&work[1], &reciprocal);

    status = xs_wide_multiply_u32(&work[2], &work[0], n);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    work[2].sign = work[1].sign;
    work[1].sign = 1;

    status =
        xs_wide_ratio(&work[2], &work[1], 0, &result, &work[3], &work[4], &work[5]);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, operation);

    if (!result || ((data->summary.min > 0 || data->summary.max < 0) &&
                    (result < data->summary.min || result > data->summary.max))) {
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);
    }

    return result;
}

/* Keep binary exponents integral so their sum can cancel exactly before
 * using libm on the bounded mantissas. */
static NV
xs_geometric_mean(pTHX_ const XStatsData *data)
{
    const char *operation = "geometric_mean";
    const U32 n = data->count;

    XStatsExactSum logs;
    XStatsSumStatus status;
    I64 exponent_sum = 0, remainder;
    I32 exponent, integer_exponent;
    NV mantissa, mean_log, result;
    U32 i;

    if (!n)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", operation, 0, 1);

    if (data->summary.min < 0)
        xs_condition(aTHX_ "NONNEGATIVE_OBSERVATIONS_REQUIRED", operation, 0, 0);

    if (!data->summary.min)
        return 0;

    if (data->summary.min == data->summary.max)
        return data->summary.min;

    Zero(&logs, 1, XStatsExactSum);
    for (i = 0; i < n; ++i) {
        mantissa = 2 * xs_nv_parts(data->values[i], &exponent);
        exponent_sum += (I64)exponent - 1;

        status = xs_sum_add(&logs, Perl_log(mantissa));
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
    }

    /* Average the exponent before converting its fractional part to NV. */
    integer_exponent = (I32)(exponent_sum / (I64)n);
    remainder = exponent_sum % (I64)n;

    if (!logs.sign && !remainder)
        return Perl_ldexp((NV)1, integer_exponent);

    status = xs_sum_value(&logs, n, &mean_log);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    mean_log += ((NV)remainder / n) * Perl_log((NV)2);
    result = Perl_ldexp(Perl_exp(mean_log), integer_exponent);

    if (!Perl_isfinite(result) || result < data->summary.min ||
        result > data->summary.max) {
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);
    }

    return result;
}

static NV
xs_shape_position(pTHX_ NV value, NV minimum, I32 exponent, NV span,
                  const char *operation)
{
    NV scaled = Perl_ldexp(value, -exponent);
    NV high, low, position;

    if (value && !scaled)
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

    xs_difference(scaled, minimum, &high, &low);
    position = (high + low) / span;
    if (!Perl_isfinite(position) || position < 0 || position > 1)
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

    return position;
}

/* Centring relative to the minimum preserves small ranges at large offsets.
 * Exact accumulation removes summation-order error from the rounded terms. */
static NV
xs_shape(pTHX_ const XStatsData *data, bool fourth, bool adjusted)
{
    const char *operation = fourth ? "excess_kurtosis" : "skewness";
    const U32 n = data->count;
    const U32 required = adjusted ? (fourth ? 4 : 3) : 2;
    const I32 exponent = data->summary.exponent;

    XStatsExactSum total, residual, moments[2];
    XStatsSumStatus status;
    NV minimum, span, position;
    NV mean, mean_error;
    NV high, low, delta, square, term;
    NV a2, ap, result;
    NV count = (NV)n;
    U32 i;

    if (n < required)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", operation, n, required);

    if (data->summary.min == data->summary.max)
        xs_condition(aTHX_ "UNDEFINED_STATISTIC", operation, 0, 0);

    if (n == 2)
        return fourth ? -(NV)2 : 0;

    minimum = Perl_ldexp(data->summary.min, -exponent);
    span = Perl_ldexp(data->summary.max, -exponent) - minimum;
    if (!span || !Perl_isfinite(span))
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

    Zero(&total, 1, XStatsExactSum);
    for (i = 0; i < n; ++i) {
        position = xs_shape_position(aTHX_ data->values[i], minimum, exponent, span,
                                     operation);
        status = xs_sum_add(&total, position);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
    }

    status = xs_sum_value(&total, n, &mean);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    /* Retain the mean rounding residual for the centred differences. */
    residual = total;
    for (i = 0; i < n; ++i) {
        status = xs_sum_add(&residual, -mean);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
    }

    status = xs_sum_value(&residual, n, &mean_error);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    if (residual.sign && !mean_error)
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

    Zero(moments, 2, XStatsExactSum);
    for (i = 0; i < n; ++i) {
        position = xs_shape_position(aTHX_ data->values[i], minimum, exponent, span,
                                     operation);

        xs_difference(position, mean, &high, &low);
        delta = high + (low - mean_error);
        square = delta * delta;
        term = square * (fourth ? square : delta);

        if (delta && (!square || !term))
            xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

        status = xs_sum_add(&moments[0], square);
        if (status == XS_SUM_OK)
            status = xs_sum_add(&moments[1], term);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, operation);
    }

    status = xs_sum_value(&moments[0], 1, &a2);
    if (status == XS_SUM_OK)
        status = xs_sum_value(&moments[1], 1, &ap);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    if (!a2 || (moments[1].sign && !ap))
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

    /* Form count products in NV rather than overflowing U32 arithmetic. */
    if (fourth) {
        result = count * (ap / a2) / a2 - 3;
        if (adjusted)
            result =
                (count - 1) / ((count - 2) * (count - 3)) * ((count + 1) * result + 6);
    } else {
        result = ap * Perl_sqrt(count / a2) / a2;

        if (adjusted)
            result *= Perl_sqrt(count * (count - 1)) / (count - 2);

        if (ap && !result)
            xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);
    }

    if (!Perl_isfinite(result))
        xs_condition(aTHX_ "NUMERICAL_RESOLUTION", operation, 0, 0);

    return result;
}

static NV *
xs_sorted_copy(pTHX_ SV *obj, const char *operation, U32 *count)
{
    SV *sv, *copy;
    XStatsData *data = xs_data(aTHX_ obj, &sv);
    if (sv_derived_from(obj, "XStats::Sparse"))
        croak("XStats: %s requires stored data", operation);
    *count = data->count;
    copy = sv_2mortal(newSVpvn((char *)data->values, (STRLEN)*count * sizeof(NV)));
    if (*count > 1)
        qsort(SvPVX(copy), *count, sizeof(NV), xs_compare);
    return (NV *)SvPVX(copy);
}

/* Compare the two endpoint distances without rounding the mean.
 * The sign of 2*sum - count*(min+max) selects the farther endpoint. */
static SV *
xs_outlier_candidate(pTHX_ const XStatsData *data, U32 minimum)
{
    const char *operation = "filter_outlier";
    XStatsWide *work;
    XStatsSumStatus status;
    U32 index;

    if (data->count < minimum)
        return newSV(0);

    work = xs_order_scratch(aTHX_ 3);
    xs_wide_scalar(&work[0], &data->summary.total);
    status = xs_wide_multiply_u32(&work[1], &work[0], 2);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    status = xs_order_nv(&work[0], data->summary.min);
    if (status == XS_SUM_OK)
        status = xs_order_nv(&work[2], data->summary.max);
    if (status == XS_SUM_OK)
        status = xs_wide_add(&work[0], &work[2], FALSE);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply_u32(&work[2], &work[0], data->count);
    if (status == XS_SUM_OK)
        status = xs_wide_add(&work[1], &work[2], TRUE);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    if (work[1].sign < 0)
        index = data->summary.max_index;
    else if (work[1].sign > 0)
        index = data->summary.min_index;
    else
        index = data->summary.min_index < data->summary.max_index
                    ? data->summary.min_index
                    : data->summary.max_index;

    return newSVuv(index);
}

enum {
    XS_SMOOTH_PREVIOUS_WEIGHT,
    XS_SMOOTH_CURRENT_WEIGHT,
    XS_SMOOTH_LEFT,
    XS_SMOOTH_RIGHT,
    XS_SMOOTH_DENOMINATOR,
    XS_SMOOTH_NUMERATOR,
    XS_SMOOTH_TEMP,
    XS_SMOOTH_PREVIOUS_VALUE,
    XS_SMOOTH_CURRENT_VALUE,
    XS_SMOOTH_REMAINDER,
    XS_SMOOTH_DIVISOR,
    XS_SMOOTH_QUOTIENT,
    XS_SMOOTH_ALPHA,
    XS_SMOOTH_ONE_MINUS_ALPHA,
    XS_SMOOTH_BUFFERS
};

/* Compute both recurrences from exact dyadic weights before rounding.
 * The common denominator cancels the scale even for extreme weights. */
static void
xs_weighted_smoothing_step(pTHX_ NV previous, NV current, NV previous_weight,
                           NV current_weight, XStatsWide *w, NV *value, NV *weight)
{
    const char *operation = "exponential_smoothing";
    XStatsSumStatus status;

    status = xs_order_nv(&w[XS_SMOOTH_PREVIOUS_WEIGHT], previous_weight);
    if (status == XS_SUM_OK)
        status = xs_order_nv(&w[XS_SMOOTH_CURRENT_WEIGHT], current_weight);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply(&w[XS_SMOOTH_LEFT], &w[XS_SMOOTH_PREVIOUS_WEIGHT],
                                  &w[XS_SMOOTH_ONE_MINUS_ALPHA]);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply(&w[XS_SMOOTH_RIGHT], &w[XS_SMOOTH_CURRENT_WEIGHT],
                                  &w[XS_SMOOTH_ALPHA]);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    w[XS_SMOOTH_DENOMINATOR] = w[XS_SMOOTH_LEFT];
    status = xs_wide_add(&w[XS_SMOOTH_DENOMINATOR], &w[XS_SMOOTH_RIGHT], FALSE);
    if (status != XS_SUM_OK || w[XS_SMOOTH_DENOMINATOR].sign <= 0)
        xs_paired_status(aTHX_ status, operation);

    status = xs_order_nv(&w[XS_SMOOTH_PREVIOUS_VALUE], previous);
    if (status == XS_SUM_OK)
        status = xs_order_nv(&w[XS_SMOOTH_CURRENT_VALUE], current);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply(&w[XS_SMOOTH_NUMERATOR], &w[XS_SMOOTH_PREVIOUS_VALUE],
                                  &w[XS_SMOOTH_LEFT]);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply(&w[XS_SMOOTH_TEMP], &w[XS_SMOOTH_CURRENT_VALUE],
                                  &w[XS_SMOOTH_RIGHT]);
    if (status == XS_SUM_OK)
        status = xs_wide_add(&w[XS_SMOOTH_NUMERATOR], &w[XS_SMOOTH_TEMP], FALSE);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    status = xs_wide_ratio(&w[XS_SMOOTH_NUMERATOR], &w[XS_SMOOTH_DENOMINATOR],
                           XS_SUM_ORIGIN, value, &w[XS_SMOOTH_REMAINDER],
                           &w[XS_SMOOTH_DIVISOR], &w[XS_SMOOTH_QUOTIENT]);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, operation);

    status = xs_wide_multiply(&w[XS_SMOOTH_NUMERATOR], &w[XS_SMOOTH_PREVIOUS_WEIGHT],
                              &w[XS_SMOOTH_LEFT]);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply(&w[XS_SMOOTH_TEMP], &w[XS_SMOOTH_CURRENT_WEIGHT],
                                  &w[XS_SMOOTH_RIGHT]);
    if (status == XS_SUM_OK)
        status = xs_wide_add(&w[XS_SMOOTH_NUMERATOR], &w[XS_SMOOTH_TEMP], FALSE);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    status = xs_wide_ratio(&w[XS_SMOOTH_NUMERATOR], &w[XS_SMOOTH_DENOMINATOR],
                           XS_SUM_ORIGIN, weight, &w[XS_SMOOTH_REMAINDER],
                           &w[XS_SMOOTH_DIVISOR], &w[XS_SMOOTH_QUOTIENT]);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, operation);
}

static SV *
xs_smooth(pTHX_ const XStatsData *data, NV alpha, const NV *weights)
{
    const char *operation = "exponential_smoothing";
    const U32 n = data->count;
    AV *out = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    XStatsWide *work, *fraction;
    XStatsSumStatus status;
    NV previous, previous_weight = 0;
    U32 i;

    if (weights) {
        for (i = 0; i < n; ++i) {
            if (weights[i] <= 0)
                xs_argument(aTHX_ "INVALID_SMOOTHING_WEIGHTS", "weights");
        }
    }

    if (!n)
        return newRV_inc(MUTABLE_SV(out));

    av_extend(out, n - 1);
    previous = data->values[0];
    av_push(out, newSVnv(previous));

    if (n == 1 || alpha == 0 || alpha == 1 || data->summary.min == data->summary.max) {
        for (i = 1; i < n; ++i)
            av_push(out, newSVnv(alpha == 1 ? data->values[i] : previous));

        return newRV_inc(MUTABLE_SV(out));
    }

    work = xs_order_scratch(aTHX_ weights ? XS_SMOOTH_BUFFERS : 5);
    fraction = &work[weights ? XS_SMOOTH_ALPHA : 4];

    status = xs_order_nv(fraction, alpha);
    if (weights && status == XS_SUM_OK) {
        status = xs_order_nv(&work[XS_SMOOTH_ONE_MINUS_ALPHA], 1);
        if (status == XS_SUM_OK)
            status = xs_wide_add(&work[XS_SMOOTH_ONE_MINUS_ALPHA], fraction, TRUE);

        previous_weight = weights[0];
    }
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, operation);

    for (i = 1; i < n; ++i) {
        if (weights && weights[i] != previous_weight) {
            xs_weighted_smoothing_step(aTHX_ previous, data->values[i], previous_weight,
                                       weights[i], work, &previous, &previous_weight);
        } else if (alpha == (NV)0.5) {
            previous = xs_midpoint(aTHX_ previous, data->values[i]);
        } else {
            status = xs_order_interpolate(previous, data->values[i], fraction, work,
                                          &previous);
            if (status != XS_SUM_OK)
                xs_paired_result(aTHX_ status, operation);
        }

        av_push(out, newSVnv(previous));
    }

    return newRV_inc(MUTABLE_SV(out));
}

static NV
xs_probability(pTHX_ SV *value, const char *argument)
{
    NV p;
    if (SvMAGICAL(value) || !SvOK(value) || SvROK(value) ||
        (!SvNIOK(value) && !looks_like_number(value)))
        xs_argument(aTHX_ "INVALID_PROBABILITY", argument);
    p = xs_nv_from_sv(aTHX_ value, argument);
    if (!Perl_isfinite(p) || p < 0 || p > 1)
        xs_argument(aTHX_ "INVALID_PROBABILITY", argument);
    return p;
}

static XStatsSumStatus
xs_quantile_value(const NV *values, U32 n, NV p, bool empirical, XStatsWide *work,
                  NV *out)
{
    U32 lo;
    XStatsSumStatus status;
    if (!n)
        return XS_SUM_INVALID;
    status = xs_order_position(&work[0], &work[1], p, empirical ? n : n - 1, &lo);
    if (status != XS_SUM_OK)
        return status;
    if (empirical) {
        if (work[0].sign)
            ++lo;
        *out = values[lo ? lo - 1 : 0];
        return XS_SUM_OK;
    }
    if (!work[0].sign) {
        *out = values[lo];
        return XS_SUM_OK;
    }
    return xs_order_interpolate(values[lo], values[lo + 1], &work[0], &work[1], out);
}

static void
xs_summary_unavailable(pTHX_ HV *result, HV *unavailable, const char *key,
                       const char *reason)
{
    I32 length = (I32)strlen(key);
    (void)hv_store(result, key, length, newSV(0), 0);
    (void)hv_store(unavailable, key, length, newSVpv(reason, 0), 0);
}

static void
xs_summary_value(pTHX_ HV *result, HV *unavailable, const char *key, NV value,
                 XStatsSumStatus status)
{
    if (status == XS_SUM_OVERFLOW) {
        xs_summary_unavailable(aTHX_ result, unavailable, key, "overflow");
        return;
    }
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, key);
    (void)hv_store(result, key, (I32)strlen(key), newSVnv(value), 0);
}

static SV *
xs_summary(pTHX_ SV *obj)
{
    SV *sv;
    XStatsData *data = xs_data(aTHX_ obj, &sv);
    const XStatsSummary *s = &data->summary;
    U32 n = data->count, sorted_count;
    bool incremental = sv_derived_from(obj, "XStats::Sparse");
    HV *result = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    HV *unavailable = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    const char *const basic[] = {"min",       "max",   "min_index",
                                 "max_index", "range", "mean"};
    const char *const spread[] = {"variance", "standard_deviation",
                                  "population_variance",
                                  "population_standard_deviation"};
    const char *const quartile[] = {"q1", "median", "q3"};
    XStatsWide *work;
    NV value = 0, *values;
    XStatsSumStatus status;
    U8 i;
    (void)hv_stores(result, "count", newSVuv(n));
    xs_summary_value(aTHX_ result, unavailable, "sum", s->sum_result, s->sum_status);
    if (data->valid & XS_VALID_SQUARES) {
        value = s->squares_result;
        status = s->squares_status;
    } else
        status = xs_stored_squares(aTHX_ data, &value);
    xs_summary_value(aTHX_ result, unavailable, "sum_of_squares", value, status);
    if (!n) {
        for (i = 0; i < C_ARRAY_LENGTH(basic); ++i)
            xs_summary_unavailable(aTHX_ result, unavailable, basic[i], "empty");
    } else {
        (void)hv_stores(result, "min", newSVnv(s->min));
        (void)hv_stores(result, "max", newSVnv(s->max));
        (void)hv_stores(result, "min_index", newSVuv(s->min_index));
        (void)hv_stores(result, "max_index", newSVuv(s->max_index));
        (void)hv_stores(result, "mean", newSVnv(s->mean_result));
        status = xs_range_value(s, &value);
        xs_summary_value(aTHX_ result, unavailable, "range", value, status);
    }
    for (i = 0; i < C_ARRAY_LENGTH(spread); ++i) {
        if (!n || (i < 2 && n < 2)) {
            xs_summary_unavailable(aTHX_ result, unavailable, spread[i],
                                   n ? "insufficient_observations" : "empty");
            continue;
        }
        status = xs_spread_value(s, n - (i < 2 ? 1 : 0), i & 1, &value);
        xs_summary_value(aTHX_ result, unavailable, spread[i], value, status);
    }
    if (incremental || !n) {
        for (i = 0; i < C_ARRAY_LENGTH(quartile); ++i)
            xs_summary_unavailable(aTHX_ result, unavailable, quartile[i],
                                   incremental ? "requires_stored_data" : "empty");
    } else {
        values = xs_sorted_copy(aTHX_ obj, "summary", &sorted_count);
        work = xs_order_scratch(aTHX_ 5);
        for (i = 0; i < C_ARRAY_LENGTH(quartile); ++i) {
            status = xs_quantile_value(values, sorted_count, (i + (NV)1) / 4, FALSE,
                                       work, &value);
            xs_summary_value(aTHX_ result, unavailable, quartile[i], value, status);
        }
    }
    (void)hv_stores(result, "unavailable", newRV_inc(MUTABLE_SV(unavailable)));
    return newRV_inc(MUTABLE_SV(result));
}

static STRLEN
xs_bin_extent(pTHX_ STRLEN bins, STRLEN width, STRLEN extra)
{
    if (bins > (XS_SIZE_MAX - 1) / width - extra)
        xs_argument(aTHX_ "INVALID_BIN_COUNT", "bins");
    return (bins + extra) * width;
}

static SV *
xs_histogram(pTHX_ SV *obj, SV *specification, SV *bin_count, SV *closure,
             bool explicit_edges, bool explicit_range)
{
    SV *sv, *edges_buffer, *counts_buffer;
    XStatsData *data = xs_data(aTHX_ obj, &sv);
    NV *edges, *v = data->values, lower, upper, requested;
    STRLEN length, bytes;
    const char *closed;
    bool right;
    U32 bins, requested_bins = 0, *counts, underflow = 0, overflow = 0;
    U32 i, lo, hi, mid;
    HV *result;
    AV *edge_values, *count_values;
    XStatsWide *work;
    XStatsSumStatus status;
    if (sv_derived_from(obj, "XStats::Sparse"))
        xs_argument(aTHX_ "STORED_DATA_REQUIRED", "histogram");
    if (SvMAGICAL(closure) || !SvOK(closure) || SvROK(closure) || !SvPOK(closure))
        xs_argument(aTHX_ "INVALID_BIN_CLOSURE", "closed");
    closed = SvPV(closure, length);
    right = length == 5 && memEQ(closed, "right", 5);
    if (!right && !(length == 4 && memEQ(closed, "left", 4)))
        xs_argument(aTHX_ "INVALID_BIN_CLOSURE", "closed");
    if (explicit_edges) {
        edges_buffer = xs_input_named(aTHX_ specification, "edges");
        length = SvCUR(edges_buffer) / sizeof(NV);
        if (length < 2)
            xs_argument(aTHX_ "INVALID_BIN_EDGES", "edges");
        bins = (U32)(length - 1);
        edges = (NV *)SvPVX(edges_buffer);
        for (i = 0; i < bins; ++i)
            if (edges[i] >= edges[i + 1])
                xs_argument(aTHX_ "INVALID_BIN_EDGES", "edges");
    } else {
        if (SvMAGICAL(bin_count) || !SvOK(bin_count) || SvROK(bin_count) ||
            (!SvNIOK(bin_count) && !looks_like_number(bin_count)))
            xs_argument(aTHX_ "INVALID_BIN_COUNT", "bins");
        requested = SvNV(bin_count);
        if (!Perl_isfinite(requested) || requested < 1 || requested > U32_MAX ||
            Perl_floor(requested) != requested)
            xs_argument(aTHX_ "INVALID_BIN_COUNT", "bins");
        requested_bins = (U32)requested;
        if (explicit_range) {
            edges_buffer = xs_input_named(aTHX_ specification, "range");
            if (SvCUR(edges_buffer) != 2 * sizeof(NV))
                xs_argument(aTHX_ "INVALID_BIN_RANGE", "range");
            lower = ((NV *)SvPVX(edges_buffer))[0];
            upper = ((NV *)SvPVX(edges_buffer))[1];
            if (lower > upper)
                xs_argument(aTHX_ "INVALID_BIN_RANGE", "range");
        } else {
            if (!data->count)
                xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "histogram", 0, 1);
            lower = data->summary.min;
            upper = data->summary.max;
        }
        bins = lower == upper ? 1 : requested_bins;
        bytes = xs_bin_extent(aTHX_ bins, sizeof(NV), 1);
        edges_buffer = sv_2mortal(newSV(bytes));
        SvPOK_on(edges_buffer);
        SvCUR_set(edges_buffer, bytes);
        SvPVX(edges_buffer)[bytes] = 0;
        edges = (NV *)SvPVX(edges_buffer);
        edges[0] = lower;
        edges[bins] = upper;
        if (bins > 1) {
            work = xs_order_scratch(aTHX_ 5);
            for (i = 1; i < bins; ++i) {
                status = xs_order_edge(lower, upper, i, bins, work, &edges[i]);
                if (status != XS_SUM_OK)
                    xs_paired_status(aTHX_ status, "histogram");
                if (edges[i] <= edges[i - 1] || edges[i] >= upper)
                    xs_argument(aTHX_ "COLLAPSED_BIN_EDGES", "bins");
            }
        }
    }
    bytes = xs_bin_extent(aTHX_ bins, sizeof(U32), 0);
    counts_buffer = sv_2mortal(newSV(bytes));
    SvPOK_on(counts_buffer);
    SvCUR_set(counts_buffer, bytes);
    Zero(SvPVX(counts_buffer), SvCUR(counts_buffer) + 1, char);
    counts = (U32 *)SvPVX(counts_buffer);
    for (i = 0; i < data->count; ++i) {
        if (v[i] < edges[0])
            ++underflow;
        else if (v[i] > edges[bins])
            ++overflow;
        else {
            lo = 1;
            hi = bins;
            while (lo < hi) {
                mid = lo + (hi - lo) / 2;
                if (v[i] < edges[mid] || (right && v[i] == edges[mid]))
                    hi = mid;
                else
                    lo = mid + 1;
            }
            ++counts[lo - 1];
        }
    }
    result = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    edge_values = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    count_values = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    av_extend(edge_values, (SSize_t)bins);
    av_extend(count_values, (SSize_t)bins - 1);
    for (i = 0; i < bins; ++i) {
        av_push(edge_values, newSVnv(edges[i]));
        av_push(count_values, newSVuv(counts[i]));
    }
    av_push(edge_values, newSVnv(edges[bins]));
    (void)hv_stores(result, "edges", newRV_inc(MUTABLE_SV(edge_values)));
    (void)hv_stores(result, "counts", newRV_inc(MUTABLE_SV(count_values)));
    (void)hv_stores(result, "underflow", newSVuv(underflow));
    (void)hv_stores(result, "overflow", newSVuv(overflow));
    (void)hv_stores(result, "count", newSVuv(data->count));
    (void)hv_stores(result, "closed", newSVpv(right ? "right" : "left", 0));
    if (!explicit_edges)
        (void)hv_stores(result, "requested_bins", newSVuv(requested_bins));
    return newRV_inc(MUTABLE_SV(result));
}

#include "xstats_resample.inc"

#include "xstats_probability.inc"
