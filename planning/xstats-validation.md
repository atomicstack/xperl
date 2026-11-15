# XStats implementation and validation

The initial implementation covers stored and incremental descriptive
statistics, order statistics, case resampling, bootstrap percentile intervals,
and paired covariance, correlation, and linear regression.  Full, Sparse and
the functional API share the compiled extension.  Native structures live in
scalar PV buffers with no persistent native pointers. The stored count is authoritative;
XStatsSummary does not duplicate it. Basic summaries are updated eagerly.

## Selected conventions

- Plain finite numbers and numeric strings are accepted. Undef, references,
  holes, magical observations, tied arrays, NaN, and infinity are rejected.
- Values become NVs. Large integers can lose precision during conversion.
  Converted observations accumulate exactly for scalar sum and mean, which
  round once using nearest-even. Sum overflow is a query error and does not
  prevent finite means, medians or later cancellation. Centred moments use
  scaled compensated state.  Paired products and centred numerators use exact
  exponent-aware accumulation with final nearest-even rounding.
- Empty count and sum are zero. Other empty statistics are errors. Sample
  variance requires two observations. Population variance permits one.
- mean_stddev requires list context and returns exactly two values. Its XS
  implementation validates the object and returns both cached results once.
- add and merge return the receiver. Batch conversion and summary calculation
  complete before mutation. Failed additions leave the object unchanged.
- Incremental self-merge doubles the observations. Counts are limited to U32.
- Quantiles use type 7 interpolation. Even medians average the middle pair.
  MAD is raw and unscaled. Temporary sorting preserves stored order.
- Resampling uses local seeded xoshiro128** state and rejection sampling for
  bounded indices. The default seed is 1. It does not change Perl RNG state.
- Bootstrap defaults to 10,000 mean resamples. Median is also supported.
  Intervals are percentile intervals, with sample standard deviation of the
  bootstrap distribution reported as standard_error. See module POD for API.
- Covariance is sample covariance. Correlation requires both inputs to vary.
  Regression requires varying x and returns slope, intercept, count, correlation,
  R squared and residual RMS, with explicit unavailability for constant responses.

## Reference comparison

The optional reference test uses Statistics::Descriptive 3.0801 from
`../tmp/part2-work/release-sbQ2oh3j/Statistics-Descriptive-3.0801/lib` and
Statistics::CaseResampling 0.18 from
`../tmp/hash-investigation/cpanm/work/1794583312.387814/Statistics-CaseResampling-0.18/blib`.
Paths are relative to the xperl checkout. Neither is a runtime dependency.

Reference distributions load independently, so an unavailable resampling XS
module does not suppress descriptive comparisons. The expanded comparisons
include observation copies, extrema positions before reference sorting,
ranges, sorted copies and clear. XStats preserves insertion order after
order-statistic queries; the reference can sort its stored observations.

An active-XPerl build of CaseResampling is available under
`tmp/xstats-reference-active`. For Descriptive, use its source library and
the installed List::MoreUtils pure-Perl backend (`LIST_MOREUTILS_PP=1`).

Descriptive quantile accepts quartile numbers 0 through 4, mapped to XStats
probabilities 0 through 1. Their quartile interpolation and even median
conventions agree on the comparison cases. CaseResampling selects the lower
middle observation for even-sized datasets. Its reflected/basic interval
formula differs from XStats percentile intervals. The test records the lower
median convention rather than treating its different answer as a failure.

Matching mean and sample standard deviation definitions are compared against
both distributions. Constant bootstrap means agree. Nonconstant seeded
bootstrap streams are not directly comparable because the RNGs differ.
Independent tests verify that each built-in bootstrap statistic agrees with
calculating it from an identical seeded case resample.

## Validation commands and configurations

The exact paired stage passes complete XStats tests on active and threaded
RC-stack XPerl. Dedicated 32-bit and binary128 DEBUGGING builds each pass
3,392 tests including the catalog checks. Their narrow extension lists include
the standard Cwd, regex and PerlIO dependencies needed by test preparation.
The 32-bit build selects available standard libraries rather than the host's
64-bit Berkeley DB library.

Independent integer, product, rational and square-root rounding oracles run
26,105 binary64, 26,945 x87 and 26,937 binary128 checks. These include full NV
significands, ties, subnormals and all four hardware rounding modes. UBSan is
enabled for all three; binary64 also passes with ASan. The public tests compare
exact rational answers and exact squared correlation rounding boundaries.

Temporary arithmetic arenas contain one scalar accumulator plus 12 wide
integers for covariance or 17 for correlation and regression diagnostics.
Binary128 correlation uses 284,450 bytes, about 278 KiB, excluding the
converted response array.
Query scratch does not increase persistent object size. Query timing remains
to be measured separately from construction and input conversion.

The numerical foundation was validated with binary64, binary128 and 32-bit
Perl builds, a host threaded interpreter and an RC-stack debug interpreter.
Those standalone copies predate the module-catalog integration. XStats now
requires XPerl's native diagnostic support. Ordinary Perl compatibility is
not an objective. Use XPerl builds for subsequent whole-module validation.

The catalog prototype and XStats integration pass the active build's focused
tests. A separate threaded, RC-stack, DEBUGGING XPerl build under
`tmp/xstats-catalog-rc` passes the catalog, exception, language-pack and XStats
tests with `PERL_DESTRUCT_LEVEL=2`: 6,934 tests. This includes actual
interpreter-clone tests for catalog handles, descriptors and XStats objects.

From xperl, build with:

```sh
./miniperl -Ilib make_ext.pl --target=all XStats MAKE=make
./perl -Ilib -Idist/XStats/lib -MTest::Harness \
    -e 'runtests(glob "dist/XStats/t/*.t")'
```

Standalone source copies are under the workspace tmp directory:

- `tmp/xstats-rc-stage1`: Perl 5.45.4 with PERL_RC_STACK, DEBUGGING, and
  DEBUG_LEAKING_SCALARS. `PERL_DESTRUCT_LEVEL=2 make test` passes. Optional
  reference and ithread tests skip on this interpreter.
- `tmp/xstats-host`: system Perl 5.38.2, threaded, GCC, -O2 -g. Tests pass with
  both reference distributions added to PERL5LIB. The ithread test confirms
  cloned stored and incremental objects can mutate independently.
- Active xperl: nonthreaded build. Core-only tests pass.

Focused Valgrind runs of statistics.t and resampling.t on the RC-stack debug
interpreter passed with PERL_DESTRUCT_LEVEL=2, full leak checking, and an
error exit code. Both log files were empty. This is focused validation, not
an exhaustive sanitizer audit. The generated XS C also passes GCC syntax
checking with -Wall -Wextra -Wc++-compat -Werror.

## Preliminary performance checks

`tmp/xstats-host/bench.pl` and `benchmark.tsv` record a small same-interpreter
comparison with Descriptive 3.0801 at 100, 1,000, and 10,000 observations.
The script separates construction, stored mean/stddev, and functional
mean/stddev. It reports mean elapsed seconds per operation and sample SD
across seven repetitions, each containing 1,000 operations. This is a quick
check, not a confidence-interval study or a comprehensive performance claim.

## Further validation and development

Expand adversarial numerical tests across NV formats and 32-bit builds.
Run ASan/UBSan and broader leak checks. Expand nonconstant resampling checks
and independently validate the RNG stream. Benchmark resampling, merging,
uncached order statistics, and memory separately, using a controlled harness.
The numerical helper/source separation can be refined as the API settles;
the initial implementation keeps native helpers with the XS source.

## Exact sum of squares (2026-11-15)

Stored and incremental objects expose `sum_of_squares`. Stored objects compute
and cache a result on demand. Incremental objects retain unsigned exact product
limbs in a separate fixed tail. Products are accumulated in units of twice the
minimum-subnormal exponent and rounded only when the result is requested.
The unsigned state occupies 534 bytes for binary64, 8,216 for x87 extended,
and 8,228 for binary128, including its active bounds. The shared summary adds
a cached NV and status. Stored objects do not retain the product limbs.

The native fixture in `dist/XStats/t/squares.t` has 189 assertions covering
empty input, copies, clear/reuse, atomic rejection, read-only queries,
truncated tails, subnormal ties, full-width significands, exact rational
nearest-neighbour checks, maximum U32 counts with maximum observations,
overflow boundaries and all four hardware rounding modes. These assertions
pass in the active -Werror build, threaded RC-stack DEBUGGING build, binary128
DEBUGGING build and 32-bit DEBUGGING build. The full XStats suites pass on
those builds. Optional Descriptive comparisons map the operation to `sumsq`.

The independent integer driver under `tmp/xstats-wide` checks square products,
carry propagation, exact totals, self-merges, capacity and final rounding:
38,477 binary64 checks, 39,141 x87 checks and 39,029 binary128 checks. All
three run with UBSan and all four rounding modes. Binary64 also runs with
ASan, with leak detection disabled. Existing wide/root integer checks and
1,007 scalar-sum Fraction cases pass after sharing the raw rounding helper.
Astra reviewed storage, aliasing, lifetime, capacity and rounding invariants.

## Exact selection and trimming (2026-11-15)

`order_statistic` uses one-based ranks. Linear quantiles evaluate the exact
converted probability times n-1 and round the affine combination once.
Empirical quantiles use exact ceil(n*p). Trimming removes the exact floor
counts at each end and sums retained observations exactly before division.
Mode reports every tied numeric value and a common frequency. All operations
work on copied observations and preserve insertion order.

`dist/XStats/t/order.t` has 357 assertions: rank boundaries, all-distinct and
tied modes, adjacent NV keys, asymmetric trimming, exact probability semantics,
subnormals, extreme endpoints, independent rational nearest-neighbour checks,
argument rejection, public diagnostic locations and all hardware rounding
modes. Bootstrap midpoint fixtures use endpoints for which the old scaled
midpoint was one ulp wrong. Midpoints now use exact scalar sum divided by two.

The independent driver runs 19,973 checks for each of binary64, x87 extended
and binary128 with UBSan. It covers full-width probabilities, U32 count
boundaries, exact position/remainder extraction, extreme interpolation and all
four hardware modes. The binary64 driver also passes ASan with leak detection
disabled. XStats tests run in the active -Werror build, threaded RC-stack
DEBUGGING build, binary128 DEBUGGING build and 32-bit DEBUGGING build.
Reference checks compare symmetric trims with Statistics::Descriptive.

Argument conditions have separate stable codes and catalog-owned templates.
They inherit from a predeclared `XStats::Diagnostic::InvalidArgument` class.
The catalog supports this existing ancestry without overwriting it. Validation
rules are not English fragments carried in diagnostic parameters.

## Histograms and structured summaries (2026-11-15)

Histograms accept explicit edges or a positive U32 bin count, with optional
range and left/right closure.  Generated edges use exact affine numerators
and rational division before nearest-even rounding.  Endpoints are copied.
Collapsed adjacent edges are rejected.  A constant range becomes one point
bin, retaining requested_bins.  Outside observations are counted separately.
Summary results have a fixed schema and independent unavailability reasons.
Incremental summaries expose the same schema and mark quartiles as requiring
stored data.  One owned sorted copy serves all three stored-data quartiles.

Scalar and summary queries share nonthrowing spread/range status helpers.
Range uses exact subtraction.  Spread checks the scaled coefficient's binary
exponent before ldexp, since directed rounding can saturate overflow to a
finite maximum.  Invalid moment state throws NUMERICAL_INVARIANT rather than
being hidden as an overflow reason.  Variance and SD availability are
independent.  Scalar variance/SD remain compensated approximations, not exact
raw-moment calculations.

The new tests contain 159 histogram assertions and 370 summary assertions.
They cover endpoint equality and adjacent NVs, both closures, point bins,
empty input, copies, read-only storage, sparse/tied input rejection, collapsed
edges, U32 requests, 32-bit allocation overflow, independent overflow states,
forged negative moments, public diagnostic locations and hardware modes.
Threaded tests exercise cloned summaries and histograms.  Reference validation
compares right-closed counts with Statistics::Descriptive.

The active -Werror build passes 4,514 XStats assertions with both reference
modules.  Threaded RC-stack DEBUGGING passes 4,419, and binary128 DEBUGGING
and 32-bit DEBUGGING each pass 4,410.  Optional references skip in those
isolated builds.  Each native edge driver passes 10,184 independent integer
checks for binary64, x87 extended and binary128, including U32_MAX counts,
indices near both endpoints and all four hardware modes.  All run with UBSan;
binary64 also passes ASan with leak detection disabled.

Focused Valgrind checks of histogram.t and summary.t in the RC-stack build
pass with PERL_DESTRUCT_LEVEL=2, full definite-leak checking and an error exit
code.  Both memory log files are empty.  Astra reviewed bounds, arithmetic,
closure semantics, scratch aliasing, ownership and diagnostic consistency.

## Source layout and formatting

The native implementation lives in `dist/XStats/xstats_impl.inc`, included
by `XStats.xs` so the kernels and bindings share one compilation unit.
Use the system clang-format with the distribution's `.clang-format` for the
implementation and kernel headers.  Do not run it over XS binding syntax.
Use perltidy with `-npro -i=4 -l=88` for Perl sources and tests.

Formatters do not replace logical grouping.  Separate validation, setup,
accumulation and final evaluation with blank lines, and add short comments
where they explain a numerical invariant or a non-obvious step.

## Completed descriptive capabilities (2026-11-15)

The Statistics::Descriptive inventory now has counterparts for every
capability group, including ordinary and weighted exponential smoothing and
single-candidate outlier filtering.  API compatibility is not a goal.
Reference comparisons supplement exact rational fixtures and boundary checks.

The final native build uses GCC, -O3, binary64 NV and -Werror.  It passes
4,825 XStats assertions with Statistics::Descriptive enabled, plus 29,931
focused numeric-parser and porting assertions.  Optional CaseResampling
comparisons are separate from this descriptive milestone.

A threaded binary128 RC-stack DEBUGGING build passes 4,740 XStats assertions,
including interpreter cloning.  A 32-bit binary64 DEBUGGING build passes
4,730.  Those isolated builds omit optional reference modules.  Four later
harmonic-cancellation checks pass separately on each build under nearest,
downward, upward and toward-zero rounding.  The final midpoint smoothing
shortcut also passes focused smoothing and clone tests on binary128 RC-stack
and smoothing tests on 32-bit.

Astra reviewed the new numerical helpers, scratch bounds and aliases,
smoothing recurrences and outlier callback ownership.  The review found two
numerical defects, now covered by regressions: reciprocal-rounding noise
could become a false mixed-sign harmonic denominator, and IQR subtraction
could overflow without a structured condition.  MAD now reports its explicit
intermediate range limit, and undefined constant-input paired statistics use
module-owned conditions.

Focused Valgrind runs of smoothing and outlier tests use
PERL_DESTRUCT_LEVEL=2, full definite-leak checking and an error exit code.
Both complete with empty memory-error logs.  The later midpoint shortcut
reuses the existing scalar exact-sum helper and is covered by the focused
cross-build tests.

Preliminary query timings on this machine use five batches of 20 calls over
1,000 stored values, x[i] = 1 + ((i+1) % 19), with GCC -O3 binary64 NV.
Ordinary alpha-0.5 smoothing falls from 237 to 203 microseconds per query
when it uses the exact midpoint helper (sample SDs 3.9 and 2.9 microseconds).
The reference smoother is about 100--108 microseconds on these runs; its
separately rounded arithmetic has a different numerical contract.  Weighted
smoothing with w[i] = 1 + ((i+1) % 7) is about 1.8--1.9 milliseconds for
XStats and 2.0 milliseconds for the reference.  These small local timings
include result-array creation and exclude construction and input generation.
They are preliminary cost checks, not general speed claims or a tuned
benchmark suite.  Scripts and raw results are in workspace tmp under
xstats-descriptive-timing*.

Remaining CaseResampling capabilities, XBench and broader performance work
are tracked separately in [the coverage inventory](xstats-coverage.md).

## CaseResampling capabilities (2026-11-15)

CaseResampling capabilities are integrated into Full and Functions.  Native
bootstrap buffers feed basic or percentile intervals directly; supplied
bootstrap statistics use the same interval helper.  Exact confidence-tail
positions retain the extra division-by-two bit.  Bootstrap medians use
selection with bounded adversarial partitions.  A BigInt oracle validates
seeding, xoshiro128** transitions and bounded rejection through U32_MAX.

Probability functions include erf/erfc and inverses, normal CDF/survival and
inverses, and explicit two-sided sigma/alpha conversions.  Native symbol
probes run under miniperl without loading XS dependencies or running target
programs.  Missing functions have a structured UNSUPPORTED_MATH path.

The native -Werror build passes 5,236 XStats assertions with both references,
plus 29,941 focused parser/porting assertions.  The threaded binary128
RC-stack DEBUGGING build passes 5,142 assertions without optional references.
The 32-bit build passes all 446 focused resampling, interval, RNG and
probability assertions.  A deliberately disabled math backend compiles with
-Werror, reports UNSUPPORTED_MATH and skips dependent numerical assertions;
its normal backend is restored after the check.

Valgrind runs of intervals, probability and the independent RNG checks use
PERL_DESTRUCT_LEVEL=2 and definite-leak error exits.  All complete with empty
memory-error logs.  Astra reviewed interval arithmetic, selection, ownership,
probability algorithms and backend availability.  See
[the resampling plan](xstats-resampling.md) for numerical contracts and
independent high-precision evidence.
