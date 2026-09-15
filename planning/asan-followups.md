# ASan and inherited test follow-ups

This note records results from the ASan build used to validate the experimental
dispatch/on feature.  It separates dispatch/on results from failures in unrelated
bundled modules and inherited thread tests.

## Build and commands

The build was configured with threaded DEBUGGING and AddressSanitizer.  The
full harness was run with:

```sh
PERL_DESTRUCT_LEVEL=2 \
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 \
make -j8 test_harness TEST_JOBS=16
```

The dispatch/on focused test passed under ASan with leak checking disabled:

```sh
PERL_DESTRUCT_LEVEL=2 \
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 \
./perl -Ilib t/comp/dispatch_on.t
```

All 128 tests passed.  The focused five-file dispatch/on harness also passes
under this configuration, as does a 100-run stress loop of the threaded case
test.

LeakSanitizer must remain disabled in the restricted agent environment.  A run
with `detect_leaks=1` aborts with:

```text
LeakSanitizer has encountered a fatal error.
LeakSanitizer does not work under ptrace
```

A valid LSan result requires a run outside that ptrace-restricted environment,
and must use `PERL_DESTRUCT_LEVEL=2`.

## Dispatch/on LSan result

The first direct LSan run of `t/comp/dispatch_on.t` completed all 128 tests,
then reported this leak:

```text
Indirect leak of 32072 byte(s) in 21 object(s)
    S_new_slab ... op.c:280
Indirect leak of 392 byte(s) in 7 object(s)
    S_link_freed_op ... op.c:311
SUMMARY: AddressSanitizer: 32464 byte(s) leaked in 28 allocation(s)
```

The cause was an ownership bug in the grammar for childless case criteria.
`newUNOP(OP_DISPATCHCOERCE, 0, NULL)` creates an implicit `OP_STUB` child.  The
grammar then made the node childless by clearing `op_first` and `OPf_KIDS`,
but did not free that stub.  The orphaned ops retained their slabs until
shutdown, where LSan reported them as indirect leaks.

The grammar now frees the implicit stub before clearing the child pointer for
the no-argument `RefVal()`, `ScalarVal()`, and `ObjectVal()` criteria, and for
the no-argument `IntStr()`, `FloatStr()`, `Num()`, and `NumStr()` criteria.
The generated parser files were regenerated with `make regen_perly`.

After the fix, the direct LSan run of `t/comp/dispatch_on.t` completed all 128
tests with no leak report.  The same focused prefixes that isolated the
original leak were also clean.  The dispatch/on op-slab leak is therefore
resolved; the unrelated ASan follow-ups below remain open.

## TODO tests that passed

The full ASan run reported TODO passes for GH 16522, GH 16863, GH 16869, and
GH 16876.  These tests check that DEBUGGING assertion failures do not occur.
Git history shows the tests being added or their status being adjusted, but no
specific dispatch/on or xperl commit that fixes the underlying issues.  The
current result therefore means that these old failures are not reproduced in
this build; it does not identify a new fix.  They should remain TODO until the
corresponding upstream tests are intentionally promoted.

`PERL_DESTRUCT_LEVEL=2` is not the reason these tests pass.  That setting
controls shutdown cleanup and leak visibility; these tests exercise assertions
in unrelated compiler, glob, and regexp paths.

## Cpanel::JSON::XS ASan failures

The full harness reported:

```text
cpan/Cpanel-JSON-XS/t/00_load.t       SIGABRT
cpan/Cpanel-JSON-XS/xt/gh70-asan.t    SIGABRT
```

Both reproduce with leak detection disabled.  ASan reports a heap-buffer
over-read in:

```text
cpan/Cpanel-JSON-XS/XS.xs:5064
XS_Cpanel__JSON__XS_new
```

The failing read is the GH70 short-class-name case.  The `xt/gh70-asan.t`
test intentionally exercises this over-read, so its abort is expected when the
test is run under ASan.  The ordinary `00_load.t` test reaches the same code
through the short subclass name `J` and exposes the same bundled-module bug.

This is unrelated to dispatch/on.  Follow-up options are:

1. fix the Cpanel::JSON::XS constructor's bounded class-name comparison;
2. keep the intentional GH70 test out of a purportedly clean full ASan
   harness, while retaining it as a negative ASan regression test; and
3. rerun the module's ordinary tests after that fix.

Do not mark the full ASan harness clean while these tests are included.

## `threads/t/libc.t` failures

The full run reported ten failures in the thread-safe `localtime()` stress
test.  A direct run reproduces the issue both with and without
`PERL_DESTRUCT_LEVEL=2`; the failures are not leak-checking failures.  Typical
results are nonzero error counts such as 1 through 9 from the worker threads.

The test precomputes scalar `localtime()` results in the parent, then calls
`localtime()` 20,000 times in each of ten Perl threads and compares the result.
The normal threaded DEBUGGING `make_test` passed this test, while the ASan
build fails repeatedly.  This points to an ASan/thread scheduling or libc
interaction, but it has not yet been reduced to a minimal reproducer.

Follow-up work:

- compare the same test on a threaded non-ASan production build;
- run it repeatedly under ASan and capture complete worker results;
- inspect Perl's threaded `localtime()` implementation and the libc calls it
  selects;
- determine whether the failure is a pre-existing sanitizer-only race or a
  real thread-safety regression;
- if it is sanitizer-specific, document the limitation rather than weakening
  the test; otherwise fix the implementation and add a focused regression.

## Current conclusion

Dispatch/on passes its direct ASan and valid LSan memory-error coverage and
threaded stress coverage.  A completely clean full ASan run is additionally
blocked by the unrelated Cpanel::JSON::XS GH70 over-read and the threaded
`localtime()` stress failures.  These issues must be tracked separately from
one another.
