# Constraint-first matching and capture ownership

## Agreed behavior

Check structural prerequisites and literal constraints before capture-only
reads, including for magical values. Preserve leftmost candidate selection
and run guards only after structural success and pad publication. A rejected
guard advances to the next clause. Cache observations rather than repeating
callbacks during capture collection.

Use a lazy mortal AV as an append-only owner. Binding records hold indices;
ordinary values are retained, not snapshotted. Tail elements remain copies.
Keep retention versus snapshotting under the existing copy/alias decision.
Retain containers across callbacks; use initial array candidate bounds and
live subsequent reads. Missing array slots are undef; missing keys are absent.

## Implementation stages

1. COMPLETE: Regression tests, indexed AV ownership, exception-safe
   publication storage and traversal retention (`6b778208fc`).
2. COMPLETE: Compiled constraint ranks and deferred capture locations,
   including nested shapes, repeated bindings and cached regex observations.
   Enclosing-dispatch capacity is used for initial owner reservation
   (`193542e2a7`).
3. COMPLETE: User guide, release delta, blead delta, diagnostics and planning
   records updated; validation results are recorded below.

## Completed validation — September 10, 2026

- Threaded DEBUGGING, `-g3 -ggdb3`: full harness PASS, 3,084 files and
  1,406,315 tests, 507 seconds; completed at 12:53:24.
- Threaded DEBUGGING with AddressSanitizer, `-g -O1`: focused dispatch/on
  harness PASS, 6 files and 439 tests, 7 seconds; completed at 13:02:54.
  Tests used `PERL_DESTRUCT_LEVEL=2` and
  `ASAN_OPTIONS=detect_leaks=1:abort_on_error=1`. No ASan or LSan errors
  were reported. Leak detection was disabled during Configure and make.
- Nonthreaded, non-DEBUGGING, `-O3`: full harness PASS, 3,084 files and
  1,394,063 tests, 168 seconds; completed at 13:25:39.
- Porting suite PASS, 40 files and 53,257 tests. Regeneration with the
  system Perl also completed successfully before the full validation runs.

The final configurations and builds were run by the user, sequentially in
the main checkout. Results above were verified from their logs. Earlier
interrupted parallel validation attempts are not counted as passes.
Sanitizer coverage is the focused suite, not the entire core harness.

## Remaining design follow-ups

The HV numeric-domain issue remains deferred. Final decisions on tail
aliasing versus copying and retained scalar observations versus snapshots
remain in `dispatch_on_todo.md`. These are separate from the completed
lifetime-safety implementation. No parser syntax was changed. Presizing
is a reservation, not a limit; append paths handle growth and overflow.
