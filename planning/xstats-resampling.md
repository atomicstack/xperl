# XStats resampling and probability capabilities

Integrate Statistics::CaseResampling capabilities into Full and Functions.
No compatibility namespace or calling convention is required.

## Intervals

`bootstrap_interval` accepts `method => 'percentile'|'basic'` and the existing
mean/median, seed, repeat-count and confidence options.  It generates packed
NV statistics and processes them directly, without an intermediate SV array.

`interval_from_distribution` treats the receiver's stored values as bootstrap
statistics, with an explicit `estimate`, confidence and method.  Functions
accept the corresponding array reference.  Both return the same result schema.
Supplied distributions have undefined seed and statistic metadata.

For confidence c, use quantile positions (n-1)*(1-c)/2 and (n-1)*(1+c)/2.
Evaluate positions from exact converted NV confidence, including subnormals.
Quantiles round once to NV.  Basic bounds reflect the rounded quantiles about
the supplied estimate with checked exact arithmetic.  Standard error is the
sample SD of at least two bootstrap statistics.

Use native selection for bootstrap medians and owned work buffers throughout.
Keep local xoshiro128** state and validate streams and rejection sampling with
an independent integer oracle, including bounds near U32_MAX.

## Probability functions

Export scalar functions from XStats::Functions: erf, erfc, erf_inv, erfc_inv,
normal_cdf, normal_survival, normal_quantile, normal_inverse_survival,
sigma_to_alpha and alpha_to_sigma.  Sigma/alpha conversions use two-sided
normal tail probability.  Explicit survival functions preserve small tails.

Use the configured NV libm functions.  Inverses use monotone brackets with
native error functions, with log-erfc asymptotics for subnormal tails.
Do not claim correctly rounded transcendental results.  Accept meaningful
infinite endpoints and reject NaN and invalid domains with module conditions.

Validate known high-precision values, symmetry, monotonicity, round trips,
endpoints and tiny tails.  Use reference approximations only at their stated
accuracy, rather than reproducing their domain restrictions or cancellation.

References:

- [xoshiro128** reference](https://prng.di.unimi.it/xoshiro128starstar.c)
- [NIST complementary-error asymptotics](https://dlmf.nist.gov/7.12)
- [SciPy bootstrap terminology](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.bootstrap.html)

## Implementation and review

Both stages are implemented in the ordinary framework.  Module-local
compile/link probes test the exact configured-NV erf/erfc symbols and never
run target programs.  They use bootstrap-safe Perl code because CBuilder's
transitive dependencies cannot load under core miniperl.  Unknown VMS probes
leave the backend explicitly unsupported rather than guessing symbol support.

The tiny-central inverse uses its linear limit before forward erf values
become quantized.  The far-tail inverse uses the DLMF expansion below NV_MIN.
Independent 100-digit fixtures cover the center and minimum subnormal tails
for binary64, x87 extended and binary128.  Astra independently checked 16
binary64 inverse-erfc targets with a 450-digit power series, including the
minimum subnormal, and found errors below 0.81 ulp on this machine.  This is
validation evidence, not a universal correct-rounding guarantee.
