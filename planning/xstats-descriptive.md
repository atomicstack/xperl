# XStats descriptive statistics

Implement the capabilities of Statistics::Descriptive with explicit numerical
contracts. Reference fixtures help validate ordinary data. Independent exact
answers decide disputed edge cases. API compatibility is not required.

All six implementation stages below are present.  Validation and review are
recorded in [the validation notes](xstats-validation.md).  CaseResampling
extensions follow separately.

## Implementation sequence

1. Exact sum of squares (implemented). Store unsigned product limbs only in
   incremental objects. Stored objects cache the final result on demand.
2. Shared sorted copies, rank selection, empirical quantiles, exact linear
   quantiles, trimmed means and mode. Preserve insertion order.
3. Histograms and structured summaries (implemented).  Reuse one sorted copy for a summary.
4. Harmonic and geometric means with explicit domains and error bounds.
5. Adjusted and unadjusted skewness and excess kurtosis, using centred,
   scaled two-pass calculations with explicit numerical range errors.
6. Regression diagnostics, smoothing and caller-directed outlier filtering.

## Selection and trimming

`order_statistic($rank)` accepts ranks from 1 through the observation count.
`quantile($p, method => 'linear'|'empirical')` accepts probabilities in [0,1].
Linear interpolation uses zero-based position (n-1)*p and rounds the exact
affine combination once. Empirical quantiles select rank max(1,ceil(n*p)).
The default is linear (type 7). Median uses linear probability 0.5.

Treat the converted NV probability exactly. Do not add an epsilon at rank
boundaries. For example, binary64 0.1 is slightly greater than 1/10, so the
empirical quantile of ten observations at that probability has rank 2.
Callers who need an exact rank should use `order_statistic`.

`trimmed_mean(lower => $fraction, upper => $fraction)` defaults both fractions
to zero. Both must be nonnegative and their exact sum must be less than one.
Remove floor(n*lower) and floor(n*upper) observations from the respective ends.
Sum retained converted observations exactly, then divide and round once.

`mode` always returns `{values => [...], frequency => N}`. Return every mode
in increasing numeric order. Empty input returns no modes and frequency zero.
All-distinct input returns every observation with frequency one. Compare
converted NVs directly, without converting numeric keys to strings.

## Histograms and summaries

Histograms accept explicit ordered finite edges or an equal-width bin count.
Return copied edges, integer counts, underflow, overflow and the total count.
Default bins are left-closed/right-open, except the last upper edge is included.
Offer right-closed bins explicitly. Generate equal-width edges from exact
rational affine combinations and reject collapsed interior boundaries.
Constant data gets one point bin. Empty input needs explicit boundaries.

`summary` returns a fixed schema including count, sum, sum of squares, extrema
and their positions, range, mean, sample variance/SD and quartiles. Unavailable
results are undef with reasons in an `unavailable` map. Reasons distinguish
empty input, insufficient observations, overflow and requires_stored_data.
Read native statuses directly rather than catching arbitrary exceptions.
Incremental summaries use the same schema and mark order statistics unavailable.

## Means and shape

Harmonic mean accepts nonzero signed observations. Scale by the minimum absolute observation
to bound reciprocal terms, and document the resulting approximation contract.
Geometric mean accepts nonnegative observations. Validate negative observations
before returning zero. Separate exact binary exponents from logarithms of
bounded mantissas and keep the answer inside the input extrema.

Harmonic mean scales by the minimum absolute observation and uses an exact
sum of rounded NV reciprocals before a final rational division.  Zero or
unresolved reciprocal sums are errors.  Geometric mean separates an exact
I64 exponent sum from native mantissa logarithms.  Constants and integral
mean binary exponents have exact shortcuts.

Skewness and excess kurtosis default to adjusted estimators. Adjusted skewness
requires at least three observations; adjusted kurtosis requires four.
Unadjusted estimators require varying data with at least two observations.
Constants have undefined shape. Use centred and scaled observations and compensated or exact accumulation
of rounded powers.  Document the approximation and reject numerical range
loss instead of introducing a degree-six arbitrary-precision engine.

## Regression, smoothing and outliers

`linear_regression(\@y)` returns slope, intercept, count, correlation, R
squared and residual RMS, with independent availability for constant-response
correlation and R squared.  `linear_trend` uses predictors 1 through count.
Residual RMS uses the exact covariance determinant before square-root
rounding, so rounded coefficients do not introduce false residuals.

`exponential_smoothing(alpha => $alpha, weights => \@weights)` returns a new
array in insertion order.  Alpha weights the current observation.  Optional
positive finite weights follow the reference weighted recurrence, evaluated
as exact dyadic numerators and denominators before each NV result is rounded.
Equal weights reproduce ordinary smoothing.  Empty and singleton inputs are
accepted, with explicit alpha-zero and alpha-one behavior.

`filter_outlier(\&predicate, min_count => 4)` selects one extreme observation
using exact endpoint distances from the arithmetic mean.  First insertion
breaks ties.  The predicate receives an independent Full snapshot, candidate
and index after the native helper returns.  Its mutations and exceptions do
not invalidate a borrowed PV.  Return a separate values array plus optional
removed index and value.  Fewer observations than the minimum skip the
predicate.
