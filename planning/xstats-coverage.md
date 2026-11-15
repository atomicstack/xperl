# XStats capability coverage

The objective is to replace the capabilities of Statistics::Descriptive and
Statistics::CaseResampling through a coherent XStats API. Their names,
calling conventions, error messages and historical bugs are not requirements.
Mathematical definitions and independent known answers take precedence over
matching another implementation.

XStats is XPerl-only. Structured diagnostics and reusable exception support
are part of the design; see
[the exception-module experiments](exception-module-dogfooding.md).

References reviewed: Statistics::Descriptive 3.0801, including its smoother
classes, and Statistics::CaseResampling 0.18. Source locations are recorded in
[the validation notes](xstats-validation.md).

Statistics::Descriptive and Statistics::CaseResampling capability coverage is
implemented with NV-only Full and Sparse objects and the functional API.
Per-object numeric formats are deferred.  Resampling is integrated with
native basic/percentile intervals, supplied distributions and scalar
probability helpers.  XBench is the next consumer.

All Statistics::Descriptive capability groups now have counterparts, including
its smoother classes and single-candidate outlier filtering.  The descriptive
review found two numerical defects, now fixed: unresolved signed harmonic
cancellation and unchecked IQR overflow.  MAD reports an explicit range limit
when an individual deviation cannot fit NV, even if its median could fit.
New query domain and range failures use module-owned structured conditions.

## Capability inventory

| Capability | Current XStats | Validation and limits |
| --- | --- | --- |
| Count, sum, extrema, mean | Stored and incremental | Exact scalar sums and independent sum-overflow state |
| Sample/population variance and SD | Stored and incremental | Scaled compensated moments with documented NV approximation |
| Combined mean and SD | `mean_stddev` | Keep the two-value contract |
| Incremental updates and merges | Present | Partition and merge checks, bounded U32 counts and atomic failure |
| Sum of squares | Exact stored and incremental | Independent subnormal, rounding and capacity checks |
| Range and extrema positions | Stored and incremental | First ties, insertion order and checked range overflow |
| Clear and observation access | Present | Owned copies, safe reuse and interpreter-clone independence |
| Summary result | Fixed schema with independent availability reasons | One quartile sort and independent stored/incremental availability |
| Median, quantiles, IQR and raw MAD | Exact interpolation, midpoints and checked differences | One sort for IQR and summary quartiles; MAD requires finite deviations |
| Rank selection and discrete percentiles | One-based ranks and empirical quantiles | Treat converted NV probabilities exactly |
| Trimmed mean | Exact asymmetric trimming | Exact retained sum with one final rounded division |
| Harmonic/geometric means | Stored queries and functions | Signed harmonic cancellation guard; nonnegative geometric inputs; documented NV approximation |
| Mode | Every tied mode and its frequency | Numeric ordering and all-distinct data |
| Skewness and excess kurtosis | Stored queries and functions, adjusted or unadjusted | Centred scaled NV products; exact sums of rounded terms; constant-data and range diagnostics |
| Frequency distributions | Explicit or exact equal-width edges; either closure | Point bins, outside counts and collapsed-edge rejection |
| Covariance and correlation | Exact products and final rounding | Independent rational and squared-midpoint validation |
| Linear regression | Exact slope/intercept, correlation, R squared, residual RMS; linear trend | Constant-response availability and exact residual numerator |
| Outlier filtering | One exact extreme candidate, caller predicate and independent snapshot | First insertion tie, configurable minimum and callback mutation/exception safety |
| Exponential smoothing | Stored query and function; alpha weights the current observation | Exact affine recurrence, insertion order and independent endpoints |
| Weighted exponential smoothing | Positive per-observation weights with an exact rational recurrence | Rounded NV state per step; weights do not alter ordinary statistics |
| Case resampling | Present | Independent BigInt stream oracle and rejection checks through U32_MAX |
| Mean/median bootstrap distributions | Packed native generation | Exact mean sums and native median selection |
| Percentile bootstrap intervals | Native generation and bounds | Exact converted confidence positions and nonconstant rational fixtures |
| Basic/reflected bootstrap intervals | Present | Correct two-sided tails and checked exact reflection of NV quantiles |
| Intervals from supplied distributions | Full method and function | Explicit estimate, method and confidence; independent generation metadata |
| Error function and inverse | erf/erfc and both inverses in Functions | Native NV symbols, explicit domains/endpoints and subnormal inverse tails |
| Normal probability / sigma conversions | CDF/survival and inverses; two-sided sigma/alpha | Explicit conventions, direct tails and independent high-precision fixtures |

Names for missing operations are provisional. Prefer consistent array-reference
inputs, explicit options and result structures. Compatibility namespaces,
writable legacy accessors, a `presorted` hint and cached-histogram access are
unnecessary; their underlying capabilities must still be efficient.

## Astra review

The initial 102 active tests missed these confirmed errors:

- `[1e16, 1, -1e16]` returned sum 1 but mean 0 instead of 1/3.
- `[1e16, 1e16+2]` returned sample variance 4 or 0 depending on order;
  the correct answer is 2.
- Pairing those x values with `[0,2]` returned correlation about 0.707 and
  regression slope 0.5 instead of 1 for each.
- `[1e-200,-1e-200]` returned SD 0 despite its SD being representable.
- Constant minimum-subnormal values lost their median during interpolation.
- The public bootstrap method accepted the private `cases` operation and
  silently returned a different output shape.

The first repair uses a compensated public sum, an internal mean residual,
scaled compensated second moments and shared interpolation. Paired operations
use centred, scaled sums. New tests use rational answers, reversed inputs,
batch partitions and singleton merges. Relative checks on tiny results must
reject zero rather than accepting it under a large absolute tolerance.

The exact scalar-sum stage separates sum overflow from construction and other
queries. A finite mean or median remains available, and later cancellation
can restore a finite sum. Additional validation must cover
alternate NV formats, nonfinite inputs, actual magic/ties, malformed storage,
read-only updates, COW, U32 limits and different merge trees.

Paired products with extreme dynamic range exposed another failure. For x values
`[1e200,-1e200,1e-200,-1e-200]` and y values
`[1e200,1e200,1e200,-1e200]`, the large products cancel and the small products
give covariance about 2/3. Common-scale arithmetic loses those small terms.
The first repair rejected detected normalization/product underflow rather than
returning a false zero. The exact paired stage now retains those terms and
supports this wider range without the normalization guard.

Paired operations form exact raw products and centred numerators, then round
each requested result once to nearest-even NV. Regression computes its
intercept independently from its slope. Correlation uses exact square-root
rounding boundaries, not an approximate quotient clamped to [-1,1].
See [the paired arithmetic plan](xstats-exact-paired.md) for the formulas,
capacity bounds and library assessment. Scalar variance remains a separate,
scaled compensated calculation and can differ in its last bits.

## Reference discrepancies

Keep the average of the middle pair as the ordinary even-sized median. Rank
selection supplies discrete order statistics when those are wanted.

A two-sided confidence level `c` leaves `(1-c)/2` in each tail. The
CaseResampling 0.18 interval code uses `1-c` in each tail. Its nominal coverage
must not become the specification for XStats.

Weighted smoothing must follow the recurrence and hand-computed examples.
Its reference POD has a multiplication typo where the implementation divides
by the combined weight. Sample weights do not change ordinary statistics.

Reference outlier filtering considers one most-extreme candidate per call.
Do not describe it as general automatic outlier rejection.

## Implementation order

An external math or statistics library is permitted when it improves
correctness or capability. Evaluate the algorithm, supported NV formats,
licence, portability and maintenance before choosing one. Core-only runtime
dependencies are no longer a design requirement. Keep reference-module
validation independent of the implementation library.

The scalar-sum accumulator stores a signed magnitude in fixed U16 limbs,
with U32 carry/borrow and active bounds.
Its unit is `2**(NV_MIN_EXP-NV_MANT_DIG)`. The U32 observation-count bound
determines the required headroom. This preserves fixed-size incremental
storage and keeps the persistent PV pointer-free.

For converted observations on supported binary64, x87 extended and binary128
NV formats, accumulation and merge are exact. Sum and mean round once to NV,
using nearest-even. Mean divides the integer accumulator before rounding, so
an overflowing sum does not prevent a finite mean. Sum overflow is a query
error and must not invalidate the object or prevent later cancellation.

The limb payload is 268 bytes for binary64, 4,108 for x87 extended and 4,114
for binary128, before metadata. This wider-NV cost must be measured. Do not
claim support for other formats, such as IBM double-double, without proving
their decomposition and rounding rules. The kernel returns status codes;
the XS layer owns structured exception construction and delivery.

The exact paired kernels are separate from the scalar accumulator. Their
scratch is temporary and leaves persistent object size unchanged. Numerical
invariant failures use a module-owned internal diagnostic, while final result
overflow uses the existing result-overflow condition.

1. Repair summaries, paired calculations, interpolation and options. Settle
   scaled state and overflow semantics, then validate them independently.
2. Add data access, clear, range, sum of squares, extrema positions and a
   structured summary. Retain pointer-free scalar-PV storage.
3. Complete selection and descriptive operations, sharing native helpers.
4. Complete resampling, standard basic intervals, intervals from supplied
   distributions and normal probability helpers. Keep distribution processing
   native rather than converting results to SVs and back.
5. Complete regression diagnostics, smoothing and callback-based outlier
   filtering. Do not borrow PV pointers across callbacks.
6. Validate ordinary, RC-stack, threaded, alternate-NV and 32-bit builds.
   Run sanitizers and leak checks, then compare construction, functions,
   stored queries, updates, selection, bootstrap and memory separately.

Completion means every capability has a documented counterpart and meaningful
tests. Optional reference comparisons supplement independent answers and are
not runtime dependencies.
