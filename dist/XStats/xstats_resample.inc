typedef struct {
    U32 repeats;
    U32 seed;
    bool median;
} XStatsResampling;

static U32
xs_u32_option(pTHX_ SV *value, const char *name, bool positive)
{
    NV number;
    const char *condition = positive ? "INVALID_RESAMPLE_COUNT" : "INVALID_SEED";

    if (SvMAGICAL(value) || !SvOK(value) || SvROK(value) ||
        (!SvNIOK(value) && !looks_like_number(value)))
        xs_argument(aTHX_ condition, name);

    number = xs_nv_from_sv(aTHX_ value, name);
    if (!Perl_isfinite(number) || number < (positive ? 1 : 0) || number > U32_MAX ||
        Perl_floor(number) != number)
        xs_argument(aTHX_ condition, name);

    return (U32)number;
}

static XStatsResampling
xs_resampling_options(pTHX_ SV *statistic, SV *repeats, SV *seed)
{
    XStatsResampling options;
    STRLEN length;
    const char *name;

    if (SvMAGICAL(statistic) || !SvOK(statistic) || SvROK(statistic))
        xs_argument(aTHX_ "INVALID_BOOTSTRAP_STATISTIC", "statistic");

    name = SvPV(statistic, length);
    options.median = length == 6 && memEQ(name, "median", 6);
    if (!options.median && !(length == 4 && memEQ(name, "mean", 4)))
        xs_argument(aTHX_ "INVALID_BOOTSTRAP_STATISTIC", "statistic");

    options.repeats = xs_u32_option(aTHX_ repeats, "resamples", TRUE);
    options.seed = xs_u32_option(aTHX_ seed, "seed", FALSE);
    return options;
}

static void
xs_seed(U32 *state, U32 seed)
{
    U32 i, mixer = seed;

    for (i = 0; i < 4; ++i) {
        mixer += 0x9e3779b9U;
        state[i] = (mixer ^ (mixer >> 16)) * 0x21f0aaadU;
        state[i] = (state[i] ^ (state[i] >> 15)) * 0x735a2d97U;
        state[i] ^= state[i] >> 15;
    }

    if (!(state[0] | state[1] | state[2] | state[3]))
        state[0] = 1;
}

static SV *
xs_nv_buffer(pTHX_ STRLEN count, const char *argument)
{
    SV *buffer;
    STRLEN bytes;

    if ((UV)count > (XS_SIZE_MAX - 1) / sizeof(NV))
        xs_argument(aTHX_ "TOO_MANY_VALUES", argument);

    bytes = (STRLEN)count * sizeof(NV);
    buffer = sv_2mortal(newSV(bytes));
    SvPOK_on(buffer);
    SvCUR_set(buffer, bytes);
    SvPVX(buffer)[bytes] = 0;
    return buffer;
}

static NV
xs_select(NV *values, U32 count, U32 rank)
{
    U32 lo = 0, hi = count, budget = 0, size = count;

    while (size) {
        size >>= 1;
        budget += 2;
    }

    while (hi - lo > 1) {
        U32 lt = lo, gt = hi, i = lo;
        NV a = values[lo], b = values[lo + (hi - lo) / 2], c = values[hi - 1];
        NV pivot =
            a < b ? (b < c ? b : (a < c ? c : a)) : (a < c ? a : (b < c ? c : b));

        /* Bound adversarial partitions; ordinary samples use selection. */
        if (!budget--) {
            qsort(values + lo, hi - lo, sizeof(NV), xs_compare);
            return values[rank];
        }

        while (i < gt) {
            NV swap = values[i];

            if (swap < pivot) {
                values[i++] = values[lt];
                values[lt++] = swap;
            } else if (swap > pivot) {
                values[i] = values[--gt];
                values[gt] = swap;
            } else {
                ++i;
            }
        }

        if (rank < lt)
            hi = lt;
        else if (rank >= gt)
            lo = gt;
        else
            return pivot;
    }

    return values[rank];
}

static NV
xs_sample_median(pTHX_ NV *values, U32 count)
{
    NV upper = xs_select(values, count, count / 2);
    NV lower;
    U32 i;

    if (count % 2)
        return upper;

    lower = values[0];
    for (i = 1; i < count / 2; ++i) {
        if (values[i] > lower)
            lower = values[i];
    }

    return xs_midpoint(aTHX_ lower, upper);
}

static XStatsData *
xs_resampling_data(pTHX_ SV *object, const char *operation, U32 minimum)
{
    SV *referent;
    XStatsData *data = xs_data(aTHX_ object, &referent);

    if (sv_derived_from(object, "XStats::Sparse"))
        xs_argument(aTHX_ "STORED_DATA_REQUIRED", operation);
    if (data->count < minimum)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", operation, data->count,
                     minimum);

    return data;
}

static SV *
xs_bootstrap_buffer(pTHX_ const XStatsData *data, const XStatsResampling *options,
                    bool raw)
{
    const U32 count = data->count;
    SV *result = xs_nv_buffer(aTHX_ raw ? count : options->repeats, "resamples");
    NV *out = (NV *)SvPVX(result);
    NV *sample = NULL;
    U32 state[4], iteration, i;

    xs_seed(state, options->seed);
    if (raw) {
        for (i = 0; i < count; ++i)
            out[i] = data->values[xs_index(state, count)];

        return result;
    }

    if (options->median)
        sample = (NV *)SvPVX(xs_nv_buffer(aTHX_ count, "values"));

    for (iteration = 0; iteration < options->repeats; ++iteration) {
        XStatsExactSum total;
        XStatsSumStatus status;

        if (options->median) {
            for (i = 0; i < count; ++i)
                sample[i] = data->values[xs_index(state, count)];

            out[iteration] = xs_sample_median(aTHX_ sample, count);
        } else {
            Zero(&total, 1, XStatsExactSum);
            for (i = 0; i < count; ++i) {
                status = xs_sum_add(&total, data->values[xs_index(state, count)]);
                if (status != XS_SUM_OK)
                    xs_paired_status(aTHX_ status, "bootstrap_distribution");
            }

            status = xs_sum_value(&total, count, &out[iteration]);
            if (status != XS_SUM_OK)
                xs_paired_result(aTHX_ status, "bootstrap_distribution");
        }
    }

    return result;
}

static SV *
xs_buffer_array(pTHX_ SV *buffer)
{
    const NV *values = (const NV *)SvPVX(buffer);
    U32 count = (U32)(SvCUR(buffer) / sizeof(NV)), i;
    AV *result = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));

    if (count)
        av_extend(result, count - 1);

    for (i = 0; i < count; ++i)
        av_push(result, newSVnv(values[i]));

    return newRV_inc(MUTABLE_SV(result));
}

static bool
xs_interval_method(pTHX_ SV *method)
{
    STRLEN length;
    const char *name;

    if (SvMAGICAL(method) || !SvOK(method) || SvROK(method))
        xs_argument(aTHX_ "INVALID_INTERVAL_METHOD", "method");

    name = SvPV(method, length);
    if (length == 5 && memEQ(name, "basic", 5))
        return TRUE;
    if (length == 10 && memEQ(name, "percentile", 10))
        return FALSE;

    xs_argument(aTHX_ "INVALID_INTERVAL_METHOD", "method");
    return FALSE;
}

static NV
xs_confidence(pTHX_ SV *value)
{
    NV confidence = xs_probability(aTHX_ value, "confidence");

    if (confidence == 0 || confidence == 1)
        xs_argument(aTHX_ "INVALID_CONFIDENCE", "confidence");

    return confidence;
}

/* Retain the extra fractional bit in (1 +/- confidence)/2. */
static NV
xs_interval_quantile(pTHX_ const NV *values, U32 count, NV confidence, bool upper,
                     XStatsWide *work)
{
    U32 rank;
    NV result;
    XStatsSumStatus status = xs_order_nv(&work[0], 1);

    if (status == XS_SUM_OK)
        status = xs_order_nv(&work[1], confidence);
    if (status == XS_SUM_OK)
        status = xs_wide_add(&work[0], &work[1], !upper);
    if (status == XS_SUM_OK)
        status = xs_wide_multiply_u32(&work[1], &work[0], count - 1);
    if (status != XS_SUM_OK)
        xs_paired_status(aTHX_ status, "bootstrap_interval");

    xs_order_split(&work[1], XS_SUM_ORIGIN - 1, &rank);
    if (!work[1].sign)
        return values[rank];

    status = xs_order_interpolate_scaled(values[rank], values[rank + 1], &work[1],
                                         XS_SUM_ORIGIN - 1, &work[2], &result);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, "bootstrap_interval");

    return result;
}

static NV
xs_reflect(pTHX_ NV estimate, NV quantile)
{
    XStatsExactSum total;
    NV result;
    XStatsSumStatus status;

    Zero(&total, 1, XStatsExactSum);
    status = xs_sum_add(&total, estimate);
    if (status == XS_SUM_OK)
        status = xs_sum_add(&total, estimate);
    if (status == XS_SUM_OK)
        status = xs_sum_add(&total, -quantile);
    if (status == XS_SUM_OK)
        status = xs_sum_value(&total, 1, &result);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, "bootstrap_interval");

    return result;
}

static SV *
xs_interval(pTHX_ SV *buffer, NV estimate, NV confidence, bool basic,
            const XStatsResampling *options)
{
    NV *values = (NV *)SvPVX(buffer);
    U32 count = (U32)(SvCUR(buffer) / sizeof(NV)), i;
    XStatsSummary summary;
    NV lower, upper, error;
    XStatsWide *work;
    HV *result;

    if (count < 2)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "bootstrap_interval", count, 2);

    for (i = 0; i < count; ++i)
        xs_push(aTHX_ & summary, i, values[i]);

    error = xs_spread(aTHX_ & summary, count - 1, TRUE, "bootstrap_standard_error");
    qsort(values, count, sizeof(NV), xs_compare);
    work = xs_order_scratch(aTHX_ 6);
    lower = xs_interval_quantile(aTHX_ values, count, confidence, FALSE, work);
    upper = xs_interval_quantile(aTHX_ values, count, confidence, TRUE, work);

    if (basic) {
        NV reflected_lower = xs_reflect(aTHX_ estimate, upper);
        upper = xs_reflect(aTHX_ estimate, lower);
        lower = reflected_lower;
    }

    result = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    (void)hv_stores(result, "estimate", newSVnv(estimate));
    (void)hv_stores(result, "lower", newSVnv(lower));
    (void)hv_stores(result, "upper", newSVnv(upper));
    (void)hv_stores(result, "standard_error", newSVnv(error));
    (void)hv_stores(result, "confidence", newSVnv(confidence));
    (void)hv_stores(result, "method", newSVpv(basic ? "basic" : "percentile", 0));
    (void)hv_stores(result, "statistic",
                    options ? newSVpv(options->median ? "median" : "mean", 0)
                            : newSV(0));
    (void)hv_stores(result, "seed", options ? newSVuv(options->seed) : newSV(0));
    (void)hv_stores(result, "resamples", newSVuv(count));
    return newRV_inc(MUTABLE_SV(result));
}
