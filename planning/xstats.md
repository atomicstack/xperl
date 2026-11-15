# XStats implementation plan

Status: initial implementation exists in `dist/XStats`, implemented by Sol.
The scope now includes the full capabilities of Statistics::Descriptive and
Statistics::CaseResampling through a clean XStats API. See
[the coverage and review](xstats-coverage.md) for the expanded inventory,
numerical findings and implementation order.
See [implementation validation](xstats-validation.md) for tested configurations,
selected conventions, and remaining validation. This document retains the
architecture and acceptance criteria for subsequent review and development.

## Objective

Provide an XS statistics library with explicit numerical behavior. External
math and statistics libraries are permitted when they improve correctness or
coverage. Convert Perl values at the boundary and perform
numerical work on native arrays and summary structures. Share the numerical
implementation across functional, stored-data, and incremental interfaces.

XStats targets XPerl. Ordinary Perl compatibility must not restrict the
implementation. Use structured exceptions and other XPerl facilities where
they improve the API, correctness or performance. Use XStats to explore
[reusable module support for exceptions](exception-module-dogfooding.md).

The scope includes descriptive statistics, case resampling, probability
helpers, regression, smoothing and outlier workflows. API compatibility with
the reference distributions is not a requirement. Use sensible, explicit
definitions and validate known reference discrepancies independently.

## Reference implementations and validation

Use Statistics::Descriptive and Statistics::CaseResampling as design references
and differential-test subjects. Read their documentation, implementation,
and tests before implementing the corresponding operations. Record the exact
versions and source locations used in validation reports.

- Statistics::Descriptive: examine descriptive operations, stored versus
  incremental capabilities, naming, edge cases, and numerical algorithms.
- Statistics::CaseResampling: examine resampling, bootstrap statistics,
  interval conventions, randomness, and its test coverage.

These are development references, not runtime dependencies. Keep optional
comparison tests separate from the ordinary core-only test suite. Existing
workspace installations or unpacked sources may be used for comparisons.
Do not bundle either distribution as part of this task.

For each comparison, establish that both implementations use the same
definition: sample or population variance, quantile interpolation, MAD
scaling, interval method, and missing-value policy. Document intentional
differences. Do not treat another module's output as the specification when
the numerical convention differs or the result appears wrong.

Include independent tests with known answers, invariants, and adversarial
inputs. For randomized operations, matching seeds across different RNGs does
not imply matching draws. Compare using controlled identical resamples where
possible, plus deterministic small cases and distributional checks with
justified tolerances. Avoid flaky statistical assertions in the normal suite.

## Public packages

| Package | Responsibility |
| --- | --- |
| `XStats` | Own observations and cache results for repeated calculations |
| `XStats::Functions` | Export explicitly requested functions taking array references |
| `XStats::Incremental` | Maintain summaries without retaining observations |

All packages use one compiled XS extension. Incremental is not a subclass of
XStats: it cannot implement operations requiring stored observations.

```perl
use XStats::Functions qw(mean_stddev);
my ($mean, $stddev) = mean_stddev(\@values);

use XStats;
my $stats = XStats->new(\@values);
($mean, $stddev) = $stats->mean_stddev;
$stats->add(\@more);

use XStats::Incremental;
my $running = XStats::Incremental->new;
$running->add(\@batch);
$running->merge($other);
($mean, $stddev) = $running->mean_stddev;
```

`mean_stddev` returns exactly mean and standard deviation, in that order.
Do not add further positional results. Define scalar-context behavior before
implementation. Sample variance and standard deviation use denominator
`n - 1`. Population calculations must be explicit. The spelling of population
options and the remaining operation names must be documented consistently
before implementing their wrappers.

Functions convert inputs for each call. Stored objects copy and convert them
once, and later changes to the input array do not affect the object.
Incremental objects support adding batches and merging summaries.

## Native representation

Both object types are blessed scalar references. The referent's ordinary,
owned PV buffer contains native data. Do not use a separately allocated
structure addressed by an integer pointer in the scalar.

The agreed stored-data layout is:

```c
typedef struct {
    U32 count;
    U32 valid;
    XStatsSummary summary;
    NV values[1];
} XStatsData;
```

`valid` records which cached results are available. Use Perl's configured
`NV` type throughout. The summary fields will follow the selected stable
algorithms: variance state, compensated sum, and extrema. Resolve whether
the summary itself includes a count, and if so document and test the
invariant between that count and the outer count. Do not silently maintain
two independent counts.

The Incremental PV contains a fixed-size summary including its count. Neither
persistent representation should contain native pointers. Perl owns the PV
allocation and releases it with the scalar.

Storage requirements:

- Allocate from `offsetof(XStatsData, values)` plus checked element storage,
  with at least `sizeof(XStatsData)` available for the declared structure and
  room for the PV terminator. Define `SvCUR` consistently as the logical byte
  extent. `SvLEN` is allocated byte capacity, including terminator space.
- Enforce the U32 observation-count limit and the platform allocation-size
  limit before arithmetic or mutation. Define the incremental count limit too.
- Grow using `sv_grow()`. Reacquire all structure and array pointers afterward.
  Choose and document geometric capacity growth to avoid repeated copying.
- A normally allocated PV provides the required alignment. Keep the buffer
  owned and unoffset; do not permit an OOK buffer to reach structure access.
- Handle copy-on-write before writes. Validate the object class, referent
  type, PV state, extent, count, and flags before dereferencing native data.
- Perl code can replace or edit a blessed scalar's bytes. Reject malformed
  storage safely. The bytes are not a public serialization format.
- Treat data as binary storage, not UTF-8 text. Inspect Perl PV APIs and nearby
  implementations to establish the correct flags and ownership operations.
- Adding data must invalidate affected caches. Establish exception safety for
  conversion failures and magical inputs; avoid leaving a partially updated
  header or summary. Document whether failed batch additions are atomic.
- Do not retain PV pointers across callbacks, coercion, or other operations
  that can run Perl code. Test reentrancy hazards rather than assuming input
  conversion is inert.
- Verify ithread cloning and copied-scalar behavior. Pointer-free storage is
  helpful but does not by itself establish safe mutation or cloning behavior.

Median and quantiles initially use a temporary sorted copy, preserving stored
observation order. Temporary native allocations need cleanup on exceptions.

## Numerical contract: first implementation deliverable

Write the contract in module POD and tests before exposing the operations.
The architecture above is agreed. The following details remain to be chosen;
Luna should propose a coherent set of defaults and flag material API choices
for review instead of treating this list as already settled:

- Numeric strings, undef, references, overloaded and magical values, and
  sparse array slots: accepted values, coercion, or rejection.
- Empty-input behavior for each statistic and insufficient observations for
  sample variance. Keep count and sum behavior explicit as well.
- NaN and infinity handling. Do not silently discard observations.
- Conversion of IV/UV values to NV, including integers not exactly
  representable in the configured floating-point type.
- Sample/population selection, scalar context for tuple operations, unknown
  options, return values of mutators, and self-merge behavior.
- Quantile endpoints and interpolation method; raw MAD versus normal-scaled
  MAD. Never conflate these definitions.
- Overflow of sums or variance state, roundoff near zero variance, and error
  tolerances appropriate to the configured NV format.

Use stable summation and variance algorithms. Evaluate compensated summation
and Welford-style update/merge algorithms against the reference modules and
independent cases. Stored and incremental paths should share definitions and
helpers, but floating-point rounding need not be bit-identical across batch
partitions. Document the expected numerical agreement.

## Implementation stages and acceptance checks

### 1. Storage and basic statistics

Implement object storage, input conversion, and the Functions interface.
Provide count, sum, minimum, maximum, mean, sample/population variance and
standard deviation, and `mean_stddev`. Reuse numerical work for the pair.

Acceptance: known-answer tests, constant values, singleton/empty cases,
large offsets with small spread, cancellation, mixed magnitudes, conversion
failures, and the defined non-finite behavior. Test growth boundaries, cache
invalidation, input-array independence, malformed objects, and COW behavior.
Compare matching operations with Statistics::Descriptive.

### 2. Incremental statistics

Implement fixed-size storage, batch addition, and summary merging using the
same numerical contract. Define empty merges and self-merge explicitly.

Acceptance: compare functions, stored objects, one-at-a-time additions,
different batch partitions, and merges of independently accumulated data.
Use justified tolerances. Verify count limits and failed-update behavior.

### 3. Order statistics

Implement median, quantiles, interquartile range, and median absolute
deviation. Document interpolation and scaling. Preserve input order.

Acceptance: odd/even sizes, duplicates, constant data, quantile endpoints,
invalid probabilities, and hand-computable examples. Compare with reference
modules only where conventions match. Verify temporary-storage cleanup.

### 4. Case resampling and bootstrap

This stage is required scope, before paired statistics. Provide it through
XStats methods and XStats::Functions, not XStats::Incremental.

Case resampling selects observations uniformly with replacement. The default
resample size is the original observation count. Repeatedly calculating a
statistic on such resamples produces a bootstrap distribution.

Provide a way to obtain case resamples, bootstrap distributions, standard
errors, and confidence intervals. Begin with built-in mean and median. Keep
the resampling/statistic loop in C, reuse working storage, and materialize
Perl values only for requested outputs. Arbitrary Perl callbacks are deferred.

Specify API names, output shapes, interval method, confidence level, number
of resamples, and RNG ownership/seed behavior before implementation. Results
must distinguish standard deviation, standard error, and confidence interval.
A plain result hash is the initial proposal for intervals, carrying estimate,
lower/upper bounds, confidence level, method, statistic, and resample count.

Inspect the existing core RNG facilities before selecting a generator.
Require reproducible explicit seeds, unbiased bounded index selection, and
documented guarantees about streams and repeatability. Do not silently alter
the application's unrelated RNG state. Preserve this isolation if an external
library supplies random-number generation.

Acceptance: validate against Statistics::CaseResampling under matching
definitions, enumerate tiny cases independently where practical, test seed
repeatability, constant data, invalid options, empty data, and allocation
limits. Document the independence/representativeness assumptions of ordinary
case resampling. Block bootstrap and automatic handling of correlated data
are outside the initial scope.

### 5. Paired statistics

Add covariance, correlation, and simple linear regression after resampling.
First define paired-input validation, length mismatches, degenerate inputs,
and result shapes. If paired resampling is later added, draw whole pairs
together rather than independently resampling columns.

## Source organization

```text
dist/XStats/
    Makefile.PL
    lib/XStats.pm
    lib/XStats/Functions.pm
    lib/XStats/Incremental.pm
    XStats.xs
    xstats.h
    xstats.c
    t/
```

XS owns Perl argument handling, object validation, lifetime rules, and errors.
C helpers operate on arrays and summaries. Split resampling into another C
file when its size warrants it. Keep one compiled extension and use ordinary
core module loading and export conventions.

## Workflow for Luna

1. Read `AGENTS.md` and the XS, SV/memory, and build/test skills. Inspect the
   existing scaffold and relevant core APIs. Preserve unrelated working-tree
   changes. Do not change generic core infrastructure to accommodate XStats.
2. Read and inventory the two reference distributions. Write a comparison
   table of operations, definitions, and intentional differences. Resolve the
   first-stage numerical contract before expanding the API.
3. Implement one stage at a time, with POD and focused tests in the same
   change. Report the implemented contract and remaining decisions at each
   milestone. Do not implement later speculative features during stage 1.
4. Validate ordinary and RC-stack builds, then threaded configurations where
   available. Use the workspace build/debug guidance for sanitizer runs.
   Check stack ownership for every XS return path, particularly tuple returns.
5. Add new distribution files to both manifests, update Maintainers metadata
   as needed, run `make manisort`, and consider release notes once functionality
   exists. Keep optional external comparison tests out of mandatory core tests.
6. Benchmark functional conversion plus computation, stored construction,
   repeated cached/uncached operations, incremental updates, and bootstrap
   loops separately. Compare equivalent operations and inputs against the
   reference modules. Report build settings, sizes, repetitions, uncertainty,
   and memory costs. Use Perl tooling; Dumbbench may be a development-only
   tool. Do not claim performance gains before measuring them.

For each stage, record commands, build configuration, test results, reference
versions, and known limitations. Completion requires implemented behavior,
documentation, and passing relevant checks, not just a working happy path.
