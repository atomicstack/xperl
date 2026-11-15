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
