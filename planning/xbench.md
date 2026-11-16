# XBench

Build an XPerl-only benchmarking module inspired by Dumbbench 0.505.
Use XStats for descriptive statistics, bootstrap intervals and filtering.
All dependencies must be supplied with XPerl.

Implemented in `dist/XBench`, including the `xbench` command-line tool.

## Framework

`XBench->new(%options)` owns an ordered collection of cases.  `add` accepts
a name and a code reference or command array, with optional baseline,
before-sample and after-sample callbacks.  `run` returns Result objects;
`report` formats them explicitly.  Export single-case convenience functions
for code references and commands, plus an ordered multi-case comparison.

Use native classes, field parameters/readers, signatures, shape dispatch,
defer and two-variable catches.  Module-owned diagnostics describe argument,
state, clock and command failures.  Callback errors retain their canonical
exception, gain benchmark context and preserve cleanup failures in order.

## Measurement and analysis

Use the monotonic clock.  Warm up, then calibrate a fixed batch size by
doubling until a minimum sample duration is reached.  Commands use one
execution per sample.  Normalize all samples to seconds per operation.
Treat batches, rather than individual loop iterations, as observations.

Retain raw and adjusted samples.  Baseline subtraction and MAD/SD filtering
are explicit options.  Alternate baseline order between samples and retain
negative adjusted values.  Zero MAD does not justify discarding observations.

Report mean, sample SD, standard error, median, MAD, bootstrap confidence
interval, counts, batch size, rejected samples and stop reason.  Keep result
data immutable through copying.  Use confidence half-width, with a clock
resolution floor, for relative/absolute precision stopping.  Respect sample
and elapsed-time limits and report when the target was not met.

The time limit is checked at batch boundaries; it cannot interrupt a running
callback or command.  Collect at least two measured samples for statistics.
Sequential samples and optional filtering do not create a universal coverage
guarantee; document the meaning of the reported empirical interval.

## Validation

Use a deterministic clock in tests to prove calibration, normalization,
baseline pairing, stopping, filtering and raw-data retention.  Test actual
monotonic-clock execution and commands without fragile timing thresholds.
Exercise callback and cleanup exceptions, state transitions, result copies,
reporting and interpreter cloning.  Check module packaging and the core-only
dependency list, then use XBench on representative XStats operations.

Validation on 2026-11-15:

- Native binary64: 115 XBench assertions and 5,236 XStats assertions pass,
  including optional Statistics::Descriptive and CaseResampling comparisons.
- Threaded binary128 with DEBUGGING and PERL_RC_STACK: 120 XBench assertions
  pass, including interpreter cloning.
- 32-bit DEBUGGING: 115 XBench assertions pass.
- Manifest, POD, extension discovery, maintainers and argument-assertion
  checks: 32,659 assertions pass.
- Valgrind reports no definite leaks or memory errors in measurement and
  exception tests with PERL_DESTRUCT_LEVEL=2.

Diagnostics preserve the public caller's location and lexical language.
Deterministic tests cover this for argument errors and appended case context.
Real-clock smoke measurements exercise cached XStats summaries, construction
and weighted smoothing.  Raw records are in
`../tmp/xbench-stats-smoke.json`; these are usage checks, not speed comparisons.

Reference: Dumbbench 0.505 by Steffen Mueller, distributed under Perl's terms.
Its robust sampling and calibration motivate the design; compatibility with
its classes, external plotting or Number::WithError API is not required.

## Hash benchmark integration

`measure` cases accept a total duration returned by a callback, with a fixed
operation count and an explicit measurement-clock resolution.  This replaces
the custom Dumbbench `single_run` hook in
`planning/scripts/bench-hash-locality.pl`.  Worker setup, process startup and
JSON decoding count against the driver's elapsed-time budget but do not enter
the reported hash-operation time.  Reported batches bypass calibration.

The driver preserves the worker's hash loops, seeded query order, plain and
interned queries, locality modes and correctness checks.  It records mean,
sample SD, bootstrap confidence bounds, stopping metadata and raw timings.
These are XBench arithmetic-mean intervals, not Dumbbench robust estimates.

Use `--sizes`, `--operations`, `--min-samples`, `--max-samples` and
`--resamples` to screen the integration quickly.  A 20-case, two-sample run
at nine keys passed against the existing matching O2 blead and eight-key
XPerl comparison builds.  This checks the harness; it is not a new performance
comparison of current main.

Reported-timing validation passes 149 XBench assertions on native binary64,
154 on threaded binary128 with PERL_RC_STACK and DEBUGGING, and 149 on the
32-bit DEBUGGING build.  POD and manifest checks pass 18,800 assertions.

## Paired hash index comparison

`planning/scripts/bench-hash-index-xbench.pl` compares SC with independently
growing OA entry storage. Both builds run the same Perl worker. The worker
reports its timed loop duration, excluding process startup, key preparation,
warmup, and storage diagnostics. Each sample uses matching hash seeds and
operation counts. XBench alternates which build runs first.

```sh
taskset -c 7 ./perl -Ilib planning/scripts/bench-hash-index-xbench.pl \
    --sc /path/to/perldev/xperl \
    --oa /path/to/perldev/tmp/xperl-oa-independent \
    --output /path/to/perldev/tmp/hash-index-xbench
```

Choose an available CPU for `taskset`. The driver records its CPU affinity,
CPU model, executable hashes, source revisions, compiler settings, and worker
and driver hashes. The output retains pilot and warmup measurements as well
as every measured pair.

Reported-duration cases bypass XBench's callback-loop calibration. The driver
therefore pilots both builds and fixes a common operation count that makes
each pilot last at least 0.1 seconds. XBench then collects at least 30 paired
samples, with filtering disabled. The maximum is 120 pairs or 60 seconds per
case. These limits include worker setup and analysis time, but setup does not
enter the reported operation duration.

The OA callback is the measured case and SC is its paired baseline. The
adjusted samples are OA minus SC seconds per operation. This subtraction
compares algorithms rather than estimating interpreter overhead. An absolute
precision target permits a negative difference or a difference near zero:
the maximum distance from the paired mean to either confidence bound must
fit within two percent of the SC pilot time per operation. The target,
observed error, and stopping reason are retained in each XBench result.

XStats supplies bootstrap intervals for the paired mean difference, per-build
mean times, and mean of the paired OA/SC ratios. Intervals for the difference
that contain zero do not establish a direction. A negative difference favors
OA, and a positive difference favors SC. A precision target can be met even
when neither build has a resolved advantage. XBench's positive-only `resolved`
accessor is not used to classify a negative algorithm difference.

Use `--sizes` and `--modes` to select follow-up cases. The sampling and budget
options are `--min-samples`, `--max-samples`, `--max-seconds`, `--precision`,
and `--sample-time`. Time-limited cases retain their observations and report
unmet precision. The fixed-count Python screening run is preliminary evidence;
its medians should not be mixed with these XBench mean estimates.
