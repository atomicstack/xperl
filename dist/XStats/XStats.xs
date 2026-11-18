#include "xstats_impl.inc"

MODULE = XStats PACKAGE = XStats::Full
PROTOTYPES: DISABLE

void
_invalid_argument(condition, argument)
    const char *condition
    const char *argument
  CODE:
    xs_argument(aTHX_ condition, argument);

SV *
_summary(obj)
    SV *obj
  CODE:
    RETVAL = xs_summary(aTHX_ obj);
  OUTPUT: RETVAL

SV *
_histogram(obj, specification, bins, closed, explicit_edges, explicit_range)
    SV *obj
    SV *specification
    SV *bins
    SV *closed
    bool explicit_edges
    bool explicit_range
  CODE:
    RETVAL = xs_histogram(aTHX_ obj, specification, bins, closed, explicit_edges, explicit_range);
  OUTPUT: RETVAL

SV *
new(package, input)
    const char *package
    SV *input
  PREINIT:
    SV *buf, *sv;
    XStatsData *d;
    STRLEN bytes;
    U32 n, i;
  CODE:
    buf = xs_input(aTHX_ input);
    n = (U32)(SvCUR(buf) / sizeof(NV));
    if (SvCUR(buf) > XS_SIZE_MAX - sizeof(XStatsData) - 1)
        croak("XStats: too many observations");
    bytes = offsetof(XStatsData, values) + (STRLEN)n * sizeof(NV);
    if (bytes < sizeof(XStatsData)) bytes = sizeof(XStatsData);
    sv = sv_2mortal(newSV(bytes));
    SvPOK_on(sv);
    SvCUR_set(sv, bytes);
    Zero(SvPVX(sv), bytes + 1, char);
    d = (XStatsData *)SvPVX(sv);
    d->count = n;
    d->valid = XS_VALID_HEADER;
    Copy(SvPVX(buf), d->values, (STRLEN)n * sizeof(NV), char);
    for (i = 0; i < n; ++i) xs_push(aTHX_ &d->summary, i, d->values[i]);
    xs_finish(aTHX_ &d->summary, n);
    RETVAL = newRV_inc(sv);
    sv_bless(RETVAL, gv_stashpv(package, GV_ADD));
  OUTPUT: RETVAL

SV *
_stat(obj, operation, population = 0)
    SV *obj
    const char *operation
    bool population
  PREINIT:
    SV *sv;
    XStatsData *d;
    NV value;
    bool unsigned_result = FALSE;
    XStatsSumStatus status;
  CODE:
    d = xs_data(aTHX_ obj, &sv);
    if (strEQ(operation, "count")) value = d->count, unsigned_result = TRUE;
    else if (strEQ(operation, "sum")) {
        if (d->summary.sum_status != XS_SUM_OK)
            xs_sum_failure(aTHX_ d->summary.sum_status);
        value = d->summary.sum_result;
    }
    else if (strEQ(operation, "sum_of_squares")) {
        if (d->valid & XS_VALID_SQUARES) {
            value = d->summary.squares_result;
            status = d->summary.squares_status;
        }
        else {
            status = xs_stored_squares(aTHX_ d, &value);
            if (!SvREADONLY(sv)) {
                sv_force_normal(sv);
                d = (XStatsData *)SvPVX(sv);
                d->summary.squares_result = value;
                d->summary.squares_status = status;
                d->valid |= XS_VALID_SQUARES;
            }
        }
        if (status != XS_SUM_OK) xs_paired_result(aTHX_ status, "sum_of_squares");
    }
    else {
        if (!d->count) xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", operation, 0, 1);
        if (strEQ(operation, "mean")) value = d->summary.mean_result;
        else if (strEQ(operation, "min")) value = d->summary.min;
        else if (strEQ(operation, "max")) value = d->summary.max;
        else if (strEQ(operation, "min_index")) value = d->summary.min_index, unsigned_result = TRUE;
        else if (strEQ(operation, "max_index")) value = d->summary.max_index, unsigned_result = TRUE;
        else if (strEQ(operation, "range")) {
            status = xs_range_value(&d->summary, &value);
            if (status != XS_SUM_OK) xs_paired_result(aTHX_ status, "range");
        }
        else if (strEQ(operation, "variance") || strEQ(operation, "standard_deviation")) {
            if (!population && d->count < 2) croak("XStats: sample variance requires two observations");
            value = xs_spread(aTHX_ &d->summary,
                d->count - (population ? 0 : 1),
                strEQ(operation, "standard_deviation"), population
                    ? (strEQ(operation, "standard_deviation") ? "population_standard_deviation" : "population_variance")
                    : operation);
        }
        else croak("XStats: unknown statistic");
    }
    RETVAL = unsigned_result ? newSVuv((UV)value) : newSVnv(value);
  OUTPUT: RETVAL

NV
_shape(obj, fourth, adjusted)
    SV *obj
    bool fourth
    bool adjusted
  PREINIT:
    SV *sv;
    XStatsData *data;
  CODE:
    data = xs_data(aTHX_ obj, &sv);
    if (sv_derived_from(obj, "XStats::Sparse"))
        xs_argument(aTHX_ "STORED_DATA_REQUIRED", fourth ? "excess_kurtosis" : "skewness");
    RETVAL = xs_shape(aTHX_ data, fourth, adjusted);
  OUTPUT: RETVAL

NV
_nonlinear_mean(obj, harmonic)
    SV *obj
    bool harmonic
  PREINIT:
    SV *sv;
    XStatsData *data;
  CODE:
    data = xs_data(aTHX_ obj, &sv);
    if (sv_derived_from(obj, "XStats::Sparse"))
        xs_argument(aTHX_ "STORED_DATA_REQUIRED", harmonic ? "harmonic_mean" : "geometric_mean");
    RETVAL = harmonic ? xs_harmonic_mean(aTHX_ data) : xs_geometric_mean(aTHX_ data);
  OUTPUT: RETVAL

NV
_quantile(obj, probability, method = NULL)
    SV *obj
    SV *probability
    SV *method
  PREINIT:
    NV *values, p;
    const char *name;
    STRLEN length;
    U32 n;
    XStatsWide *work;
    XStatsSumStatus status;
    bool empirical;
  CODE:
    p = xs_probability(aTHX_ probability, "probability");
    empirical = FALSE;
    if (method) {
        if (SvMAGICAL(method) || !SvOK(method) || SvROK(method) || !SvPOK(method))
            xs_argument(aTHX_ "INVALID_QUANTILE_METHOD", "method");
        name = SvPV(method, length);
        empirical = length == 9 && memEQ(name, "empirical", 9);
        if (!empirical && !(length == 6 && memEQ(name, "linear", 6)))
            xs_argument(aTHX_ "INVALID_QUANTILE_METHOD", "method");
    }
    values = xs_sorted_copy(aTHX_ obj, "quantile", &n);
    if (!n) xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "quantile", 0, 1);
    work = xs_order_scratch(aTHX_ empirical ? 2 : 5);
    status = xs_quantile_value(values, n, p, empirical, work, &RETVAL);
    if (status != XS_SUM_OK) xs_paired_result(aTHX_ status, "quantile");
  OUTPUT: RETVAL

NV
_interquartile_range(obj)
    SV *obj
  PREINIT:
    NV *values, lower, upper;
    U32 n;
    XStatsWide *work;
    XStatsSumStatus status;
  CODE:
    values = xs_sorted_copy(aTHX_ obj, "interquartile_range", &n);
    if (!n)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "interquartile_range", 0, 1);

    work = xs_order_scratch(aTHX_ 5);
    status = xs_quantile_value(values, n, 0.25, FALSE, work, &lower);
    if (status == XS_SUM_OK)
        status = xs_quantile_value(values, n, 0.75, FALSE, work, &upper);
    if (status == XS_SUM_OK)
        status = xs_difference_value(upper, lower, &RETVAL);
    if (status != XS_SUM_OK)
        xs_paired_result(aTHX_ status, "interquartile_range");
  OUTPUT: RETVAL

NV
_order_statistic(obj, rank)
    SV *obj
    SV *rank
  PREINIT:
    NV *values, position;
    U32 n;
  CODE:
    if (SvMAGICAL(rank) || !SvOK(rank) || SvROK(rank) || (!SvNIOK(rank) && !looks_like_number(rank)))
        xs_argument(aTHX_ "INVALID_RANK", "rank");
    position = SvNV(rank);
    if (!Perl_isfinite(position) || position < 1 || position > U32_MAX
        || Perl_floor(position) != position)
        xs_argument(aTHX_ "INVALID_RANK", "rank");
    values = xs_sorted_copy(aTHX_ obj, "order_statistic", &n);
    if (!n) xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "order_statistic", 0, 1);
    if (position > n) xs_argument(aTHX_ "INVALID_RANK", "rank");
    RETVAL = values[(U32)position - 1];
  OUTPUT: RETVAL

NV
_trimmed_mean(obj, lower, upper)
    SV *obj
    SV *lower
    SV *upper
  PREINIT:
    NV low, high, *values;
    U32 n, lo, hi, i;
    XStatsExactSum total;
    XStatsWide *work;
    XStatsSumStatus status;
  CODE:
    low = xs_probability(aTHX_ lower, "lower");
    high = xs_probability(aTHX_ upper, "upper");
    Zero(&total, 1, XStatsExactSum);
    status = xs_sum_add(&total, low);
    if (status == XS_SUM_OK) status = xs_sum_add(&total, high);
    if (status == XS_SUM_OK) status = xs_sum_add(&total, -1);
    if (status != XS_SUM_OK) xs_paired_status(aTHX_ status, "trimmed_mean");
    if (total.sign >= 0) xs_argument(aTHX_ "INVALID_TRIM_FRACTIONS", "trim fractions");
    values = xs_sorted_copy(aTHX_ obj, "trimmed_mean", &n);
    if (!n) xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "trimmed_mean", 0, 1);
    work = xs_order_scratch(aTHX_ 2);
    status = xs_order_position(&work[0], &work[1], low, n, &lo);
    if (status == XS_SUM_OK) status = xs_order_position(&work[0], &work[1], high, n, &hi);
    if (status != XS_SUM_OK) xs_paired_status(aTHX_ status, "trimmed_mean");
    if (lo >= n || hi >= n - lo) xs_paired_status(aTHX_ XS_SUM_INVALID, "trimmed_mean");
    Zero(&total, 1, XStatsExactSum);
    for (i = lo; i < n - hi; ++i) {
        status = xs_sum_add(&total, values[i]);
        if (status != XS_SUM_OK) xs_paired_status(aTHX_ status, "trimmed_mean");
    }
    status = xs_sum_value(&total, n - lo - hi, &RETVAL);
    if (status != XS_SUM_OK) xs_paired_result(aTHX_ status, "trimmed_mean");
  OUTPUT: RETVAL

SV *
_mode(obj)
    SV *obj
  PREINIT:
    NV *values;
    U32 n, i, end, frequency, best = 0;
    AV *modes;
    HV *result;
  CODE:
    values = xs_sorted_copy(aTHX_ obj, "mode", &n);
    modes = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    for (i = 0; i < n; i = end) {
        end = i + 1;
        while (end < n && values[end] == values[i]) ++end;
        frequency = end - i;
        if (frequency > best) {
            av_clear(modes);
            best = frequency;
        }
        if (frequency == best) av_push(modes, newSVnv(values[i]));
    }
    result = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    (void)hv_stores(result, "values", newRV_inc(MUTABLE_SV(modes)));
    (void)hv_stores(result, "frequency", newSVuv(best));
    RETVAL = newRV_inc(MUTABLE_SV(result));
  OUTPUT: RETVAL

SV *
_values(obj, sorted = 0)
    SV *obj
    bool sorted
  PREINIT:
    SV *sv, *copy;
    XStatsData *d;
    AV *out;
    NV *values;
    U32 i, n;
  CODE:
    d = xs_data(aTHX_ obj, &sv);
    if (sv_derived_from(obj, "XStats::Sparse")) croak("XStats: operation requires stored data");
    n = d->count;
    values = d->values;
    if (sorted && n > 1) {
        copy = sv_2mortal(newSVpvn((char *)values, (STRLEN)n * sizeof(NV)));
        values = (NV *)SvPVX(copy);
        qsort(values, n, sizeof(NV), xs_compare);
    }
    out = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    if (n) av_extend(out, (SSize_t)n - 1);
    for (i = 0; i < n; ++i) av_push(out, newSVnv(values[i]));
    RETVAL = newRV_inc(MUTABLE_SV(out));
  OUTPUT: RETVAL

SV *
clear(obj)
    SV *obj
  PREINIT:
    SV *sv;
    XStatsData *d;
    STRLEN bytes;
    bool incremental;
  CODE:
    d = xs_data(aTHX_ obj, &sv);
    PERL_UNUSED_VAR(d);
    if (SvREADONLY(sv)) croak("XStats: read-only object");
    incremental = sv_derived_from(obj, "XStats::Sparse");
    bytes = incremental ? sizeof(XStatsSparseData) : sizeof(XStatsData);
    sv_force_normal(sv);
    Zero(SvPVX(sv), bytes + 1, char);
    SvCUR_set(sv, bytes);
    ((XStatsData *)SvPVX(sv))->valid = XS_VALID_HEADER | (incremental ? XS_VALID_SQUARES : 0);
    RETVAL = newSVsv(obj);
  OUTPUT: RETVAL

SV *
add(obj, input)
    SV *obj
    SV *input
  PREINIT:
    SV *buf, *sv, *work;
    XStatsData *d;
    XStatsSummary summary;
    U32 n, old, i;
    STRLEN bytes, capacity;
    NV *values;
    bool incremental;
    XStatsSparseData *combined;
    XStatsSumStatus status;
  CODE:
    buf = xs_input(aTHX_ input);
    d = xs_data(aTHX_ obj, &sv);
    if (SvREADONLY(sv)) croak("XStats: read-only object");
    n = (U32)(SvCUR(buf) / sizeof(NV));
    old = d->count;
    incremental = sv_derived_from(obj, "XStats::Sparse");
    if (n > U32_MAX - old || (!incremental
        && (STRLEN)n > (XS_SIZE_MAX - SvCUR(sv) - 1) / sizeof(NV)))
        croak("XStats: too many observations");
    values = (NV *)SvPVX(buf);
    if (incremental) {
        work = sv_2mortal(newSVpvn(SvPVX(sv), SvCUR(sv)));
        combined = (XStatsSparseData *)SvPVX(work);
        for (i = 0; i < n; ++i) {
            xs_push(aTHX_ &combined->summary, old + i, values[i]);
            status = xs_squares_add(&combined->squares, values[i]);
            if (status != XS_SUM_OK) xs_paired_status(aTHX_ status, "sum_of_squares");
        }
        xs_finish(aTHX_ &combined->summary, old + n);
        combined->count = old + n;
        xs_incremental_finish_squares(aTHX_ combined);
        sv_force_normal(sv);
        Copy(SvPVX(work), SvPVX(sv), SvCUR(work) + 1, char);
    }
    else {
        summary = d->summary;
        for (i = 0; i < n; ++i) xs_push(aTHX_ &summary, old + i, values[i]);
        xs_finish(aTHX_ &summary, old + n);
        bytes = offsetof(XStatsData, values) + (STRLEN)(old + n) * sizeof(NV);
        if (bytes < sizeof(XStatsData)) bytes = sizeof(XStatsData);
        sv_force_normal(sv);
        capacity = bytes + 1;
        if (capacity > SvLEN(sv) && capacity <= XS_SIZE_MAX - capacity / 2)
            capacity += capacity / 2;
        SvGROW(sv, capacity);
        d = (XStatsData *)SvPVX(sv);
        Copy(values, d->values + old, n, NV);
        d->count = old + n;
        d->summary = summary;
        d->valid = XS_VALID_HEADER;
        SvCUR_set(sv, bytes);
        SvPVX(sv)[bytes] = 0;
    }
    RETVAL = newSVsv(obj);
  OUTPUT: RETVAL


SV *
_sparse_new(package)
    const char *package
  PREINIT:
    SV *sv;
    STRLEN bytes;
  CODE:
    bytes = sizeof(XStatsSparseData);
    sv = sv_2mortal(newSV(bytes));
    SvPOK_on(sv);
    SvCUR_set(sv, bytes);
    Zero(SvPVX(sv), bytes + 1, char);
    ((XStatsData *)SvPVX(sv))->valid = XS_VALID_HEADER | XS_VALID_SQUARES;
    RETVAL = newRV_inc(sv);
    sv_bless(RETVAL, gv_stashpv(package, GV_ADD));
  OUTPUT: RETVAL

SV *
_merge(obj, other)
    SV *obj
    SV *other
  PREINIT:
    SV *sv, *other_sv, *work;
    XStatsData *a, *b;
    XStatsSummary result, incoming;
    U32 n;
    NV high, low, weight, ratio;
    XStatsSumStatus status;
    XStatsSparseData *combined;
  CODE:
    if (!sv_derived_from(obj, "XStats::Sparse") || !sv_derived_from(other, "XStats::Sparse"))
        croak("XStats: merge requires incremental objects");
    a = xs_data(aTHX_ obj, &sv);
    b = xs_data(aTHX_ other, &other_sv);
    if (SvREADONLY(sv)) croak("XStats: read-only object");
    if (b->count > U32_MAX - a->count) croak("XStats: too many observations");
    n = a->count + b->count;
    result = a->summary;
    if (!a->count) result = b->summary;
    else if (b->count) {
        incoming = b->summary;
        if ((result.min == 0 && result.max == 0)
            || ((incoming.min != 0 || incoming.max != 0)
                && incoming.exponent > result.exponent))
            xs_rescale(&result, incoming.exponent);
        else xs_rescale(&incoming, result.exponent);
        xs_difference(incoming.mean, result.mean, &high, &low);
        low += incoming.mean_error - result.mean_error;
        weight = (NV)b->count / n;
        xs_accumulate(&result.mean, &result.mean_error, high * weight);
        xs_accumulate(&result.mean, &result.mean_error, low * weight);
        if (incoming.m2_scale > result.m2_scale) {
            ratio = result.m2_scale / incoming.m2_scale;
            result.m2 *= ratio * ratio;
            result.m2_error *= ratio * ratio;
            result.m2_scale = incoming.m2_scale;
        }
        if (incoming.m2_scale) {
            ratio = incoming.m2_scale / result.m2_scale;
            xs_accumulate(&result.m2, &result.m2_error,
                incoming.m2 * ratio * ratio);
            xs_accumulate(&result.m2, &result.m2_error,
                incoming.m2_error * ratio * ratio);
        }
        xs_moment(&result, high + low, a->count * weight);
        status = xs_sum_merge(&result.total, &b->summary.total);
        if (status != XS_SUM_OK) xs_sum_failure(aTHX_ status);
        if (b->summary.min < result.min) {
            result.min = b->summary.min;
            result.min_index = a->count + b->summary.min_index;
        }
        if (b->summary.max > result.max) {
            result.max = b->summary.max;
            result.max_index = a->count + b->summary.max_index;
        }
    }
    if (!Perl_isfinite(result.mean) || !Perl_isfinite(result.mean_error)
        || !Perl_isfinite(result.m2) || !Perl_isfinite(result.m2_error)
        || !Perl_isfinite(result.m2_scale))
        croak("XStats: numerical overflow");
    xs_finish(aTHX_ &result, n);
    work = sv_2mortal(newSVpvn(SvPVX(sv), SvCUR(sv)));
    combined = (XStatsSparseData *)SvPVX(work);
    combined->summary = result;
    combined->count = n;
    status = xs_squares_merge(&combined->squares, &((XStatsSparseData *)b)->squares);
    if (status != XS_SUM_OK) xs_paired_status(aTHX_ status, "sum_of_squares");
    xs_incremental_finish_squares(aTHX_ combined);
    sv_force_normal(sv);
    Copy(SvPVX(work), SvPVX(sv), SvCUR(work) + 1, char);
    RETVAL = newSVsv(obj);
  OUTPUT: RETVAL


SV *
_resample(obj, statistic, repeats, seed, raw = 0)
    SV *obj
    SV *statistic
    SV *repeats
    SV *seed
    bool raw
  PREINIT:
    XStatsResampling options;
    XStatsData *data;
  CODE:
    options = xs_resampling_options(aTHX_ statistic, repeats, seed);
    data = xs_resampling_data(aTHX_ obj, "resample", 1);
    RETVAL = xs_buffer_array(aTHX_ xs_bootstrap_buffer(aTHX_ data, &options, raw));
  OUTPUT: RETVAL

SV *
_bootstrap_interval(obj, statistic, repeats, seed, confidence, method)
    SV *obj
    SV *statistic
    SV *repeats
    SV *seed
    SV *confidence
    SV *method
  PREINIT:
    XStatsResampling options;
    XStatsData *data;
    NV level, estimate;
    bool basic;
    SV *buffer;
  CODE:
    options = xs_resampling_options(aTHX_ statistic, repeats, seed);
    level = xs_confidence(aTHX_ confidence);
    basic = xs_interval_method(aTHX_ method);
    if (options.repeats < 2)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "bootstrap_interval", options.repeats, 2);

    data = xs_resampling_data(aTHX_ obj, "bootstrap_interval", 1);
    if (options.median) {
        buffer = sv_2mortal(newSVpvn((const char *)data->values, (STRLEN)data->count * sizeof(NV)));
        estimate = xs_sample_median(aTHX_ (NV *)SvPVX(buffer), data->count);
    } else {
        estimate = data->summary.mean_result;
    }

    buffer = xs_bootstrap_buffer(aTHX_ data, &options, FALSE);
    RETVAL = xs_interval(aTHX_ buffer, estimate, level, basic, &options);
  OUTPUT: RETVAL

SV *
_interval_from_distribution(obj, estimate, confidence, method)
    SV *obj
    SV *estimate
    SV *confidence
    SV *method
  PREINIT:
    XStatsData *data;
    NV point, level;
    bool basic;
    SV *buffer;
  CODE:
    point = xs_nv_from_sv(aTHX_ estimate, "estimate");
    if (!Perl_isfinite(point))
        xs_argument(aTHX_ "INVALID_NUMERIC_VALUE", "estimate");

    level = xs_confidence(aTHX_ confidence);
    basic = xs_interval_method(aTHX_ method);
    data = xs_resampling_data(aTHX_ obj, "interval_from_distribution", 2);
    buffer = sv_2mortal(newSVpvn((const char *)data->values, (STRLEN)data->count * sizeof(NV)));
    RETVAL = xs_interval(aTHX_ buffer, point, level, basic, NULL);
  OUTPUT: RETVAL

SV *
_rng_indices(seed, bound, count)
    SV *seed
    SV *bound
    SV *count
  PREINIT:
    U32 state[4], limit, repeats, i;
    AV *result;
  CODE:
    xs_seed(state, xs_u32_option(aTHX_ seed, "seed", FALSE));
    limit = xs_u32_option(aTHX_ bound, "bound", TRUE);
    repeats = xs_u32_option(aTHX_ count, "resamples", TRUE);
    result = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
    for (i = 0; i < repeats; ++i)
        av_push(result, newSVuv(xs_index(state, limit)));
    RETVAL = newRV_inc(MUTABLE_SV(result));
  OUTPUT: RETVAL

NV
_mad(obj, center)
    SV *obj
    NV center
  PREINIT:
    SV *sv, *copy;
    XStatsData *d;
    NV *v;
    U32 n, i;
    XStatsSumStatus status;
  CODE:
    d = xs_data(aTHX_ obj, &sv);
    if (sv_derived_from(obj, "XStats::Sparse"))
        xs_argument(aTHX_ "STORED_DATA_REQUIRED", "median_absolute_deviation");

    n = d->count;
    if (!n)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "median_absolute_deviation", 0, 1);

    copy = sv_2mortal(newSVpvn((char *)d->values, (STRLEN)n * sizeof(NV)));
    v = (NV *)SvPVX(copy);

    for (i = 0; i < n; ++i) {
        status = xs_difference_value(v[i], center, &v[i]);
        if (status == XS_SUM_OVERFLOW)
            xs_condition(aTHX_ "NUMERICAL_RESOLUTION", "median_absolute_deviation", 0, 0);
        if (status != XS_SUM_OK)
            xs_paired_status(aTHX_ status, "median_absolute_deviation");

        v[i] = Perl_fabs(v[i]);
    }

    qsort(v, n, sizeof(NV), xs_compare);
    RETVAL = n % 2 ? v[n / 2] : xs_midpoint(aTHX_ v[n / 2 - 1], v[n / 2]);
  OUTPUT: RETVAL

SV *
_outlier_candidate(obj, minimum)
    SV *obj
    SV *minimum
  PREINIT:
    SV *sv;
    XStatsData *data;
    NV count;
  CODE:
    data = xs_data(aTHX_ obj, &sv);

    if (sv_derived_from(obj, "XStats::Sparse"))
        xs_argument(aTHX_ "STORED_DATA_REQUIRED", "filter_outlier");

    if (SvMAGICAL(minimum) || !SvOK(minimum) || SvROK(minimum)
        || (!SvNIOK(minimum) && !looks_like_number(minimum)))
        xs_argument(aTHX_ "INVALID_MINIMUM_COUNT", "min_count");

    count = xs_nv_from_sv(aTHX_ minimum, "min_count");
    if (!Perl_isfinite(count) || count < 1 || count > U32_MAX
        || Perl_floor(count) != count)
        xs_argument(aTHX_ "INVALID_MINIMUM_COUNT", "min_count");

    RETVAL = xs_outlier_candidate(aTHX_ data, (U32)count);
  OUTPUT: RETVAL

SV *
_smooth(obj, alpha, weights, weighted)
    SV *obj
    SV *alpha
    SV *weights
    bool weighted
  PREINIT:
    SV *sv, *buffer = NULL;
    XStatsData *data;
    const NV *weight_values = NULL;
    NV coefficient;
  CODE:
    data = xs_data(aTHX_ obj, &sv);

    if (sv_derived_from(obj, "XStats::Sparse"))
        xs_argument(aTHX_ "STORED_DATA_REQUIRED", "exponential_smoothing");

    coefficient = xs_probability(aTHX_ alpha, "alpha");

    if (weighted) {
        buffer = xs_input_named(aTHX_ weights, "weights");

        if (SvCUR(buffer) / sizeof(NV) != data->count)
            xs_argument(aTHX_ "INVALID_SMOOTHING_WEIGHTS", "weights");

        weight_values = (const NV *)SvPVX(buffer);
    }

    RETVAL = xs_smooth(aTHX_ data, coefficient, weight_values);
  OUTPUT: RETVAL

SV *
_linear_trend(obj)
    SV *obj
  PREINIT:
    SV *sv;
    XStatsData *data;
  CODE:
    data = xs_data(aTHX_ obj, &sv);

    if (sv_derived_from(obj, "XStats::Sparse"))
        xs_argument(aTHX_ "STORED_DATA_REQUIRED", "linear_trend");

    if (data->count < 2)
        xs_condition(aTHX_ "INSUFFICIENT_OBSERVATIONS", "linear_trend", data->count, 2);

    RETVAL = xs_linear_trend(aTHX_ data);
  OUTPUT: RETVAL

SV *
_paired(obj, input, operation)
    SV *obj
    SV *input
    const char *operation
  PREINIT:
    SV *buffer, *sv;
    XStatsData *d;
    U32 n;
  CODE:
    buffer = xs_input(aTHX_ input);
    d = xs_data(aTHX_ obj, &sv);
    if (sv_derived_from(obj, "XStats::Sparse")) croak("XStats: paired operations require stored data");
    n = d->count;
    if (SvCUR(buffer) / sizeof(NV) != n) croak("XStats: paired lengths differ");
    if (n < 2) croak("XStats: paired statistics require two observations");
    if (strNE(operation, "covariance") && strNE(operation, "correlation")
        && strNE(operation, "linear_regression")) croak("XStats: unknown paired operation");
    RETVAL = xs_exact_paired(aTHX_ d, (NV *)SvPVX(buffer), operation);
  OUTPUT: RETVAL

void
_mean_stddev(obj, population = 0)
    SV *obj
    bool population
  PREINIT:
    SV *sv;
    XStatsData *d;
    NV mean, sd;
  PPCODE:
    d = xs_data(aTHX_ obj, &sv);
    if (!d->count || (!population && d->count < 2))
        croak("XStats: insufficient observations for mean_stddev");
    mean = d->summary.mean_result;
    sd = xs_spread(aTHX_ &d->summary, d->count - (population ? 0 : 1), 1,
        population ? "population_standard_deviation" : "standard_deviation");
    EXTEND(SP, 2);
    mPUSHn(mean);
    mPUSHn(sd);

NV
_probability_function(value, operation)
    SV *value
    const char *operation
  CODE:
    RETVAL = xs_probability_function(aTHX_ value, operation);
  OUTPUT: RETVAL
