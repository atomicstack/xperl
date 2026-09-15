# Dispatch/on review follow-up

The September 9 review found six reproducible defects. Fix each with
regressions, preserve the documented semantics, and validate with focused
dispatch/on and porting tests before a full harness run.

1. **Complete:** preserve escaped scalar and array bindings when the
   clause exits, including repeated executions, rejected guards, and
   exceptions. Closures and references retain the captured lexical values.
2. **Complete:** discover and bind every static regex's named captures,
   including regexes inside object shapes and open-array searches. Preserve
   UTF-8 capture names and ordinary regex capture localization.
3. **Complete:** apply actual-boolean matching consistently to nested
   constants, including imported builtin booleans.
4. **Complete:** remove silent 64-element and 64-binding limits. Regression
   tests cover up to 256 array elements and bindings, and 65 concatenation
   and named regex captures.
5. **Complete:** reject slurp minima outside `0 .. 2**32 - 1` without
   overflowing during decimal parsing.
6. **Complete:** reject statically known duplicate hash keys. Runtime key
   collisions must not raise duplicate-key errors or let an exact shape
   accept unspecified keys.

Runtime keys are stringified once so lookup and coverage cannot disagree
when a key has stateful overload. The regression suite also includes a
thread-cloning test for multiple regexes and an escaped closure; that test
is skipped in the current nonthreaded build.

## Validation

All fixes are committed. Validation on September 9 used the existing
nonthreaded, non-DEBUGGING `-O3` configuration:

- Focused dispatch/on coverage: 185 tests passed; the thread-only test file
  skipped because threads are unavailable in this build.
- The ordinary regex suite `re/pat.t` and diagnostics inventory passed.
- `make regen` completed using the installed Perl, with no generated-file
  differences. The full run also passed `porting/regen.t`.
- Final full harness: **PASS**, 3,083 files, 1,393,619 tests, 178 seconds.
  Command: `TEST_JOBS=16 make -j10 test_harness`.
- The initial broad run exposed an incomplete, file-specific bootstrap
  pragma allowlist. After correcting it, all 724 bootstrap checks passed
  through the harness, followed by the successful full rerun above.

No new sanitizer or threaded build has been configured for this review.
Logs are retained outside the source tree in the workspace directory
`tmp/dispatch-on-review-20260909/`.

Keep fixes in incremental commits. Update user documentation and the main
TODO where appropriate. Build and regeneration commands run in the visible
tmux build window; do not change the user's build configuration.
