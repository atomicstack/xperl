# Dispatch/on coverage review — September 9, 2026

## Resolution update — September 10

All eleven confirmed implementation problem groups below have been fixed.
The original report and failing counts are retained as historical evidence,
not as the current test status. Additional regressions cover byte-mode
dispatch and captures, one-time overload conversion, and computed scalar
kind comparisons. Cross-build and sanitizer validation remain follow-ups.

Validation on the current nonthreaded, non-DEBUGGING `-O3` build:

- All 367 applicable dispatch/on tests pass, including the expanded
  176-assertion review file. The thread-only file skips in this build.
- Full harness: PASS, 3,084 files and 1,393,802 tests in 177 seconds.
  This includes the porting checks and generated-file consistency tests.
- Command: `TEST_JOBS=16 make -j10 test_harness`.
- Full log: workspace `tmp/dispatch-fixes-full.log`.

## Original review

This review compares `pod/perldispatchon.pod`, the implementation, and the
tests after commit `da987fd99f`. It does not change runtime or compiler code.
The user requested additional tests to expose gaps before implementing fixes.

## Results

The new `t/comp/dispatch_on_review.t` contains 160 assertions: 80 isolated
programs, each checked for its output and exit status. **126 assertions pass
and 34 fail.** One failing program accounts for both an output and an exit
status failure. These failures are not marked TODO or suppressed.

The current interpreter is nonthreaded, non-DEBUGGING, with `-O3`. No new
threaded, DEBUGGING, ASan, LSan, or coverage-instrumented build was made.
Passing tests establish behavior for their inputs, not complete coverage.

The previous five-file suite still passes its 191 applicable tests after
strengthening several assertions; the threaded file skips in this build.
The new regressions expose previously untested behavior rather than a new
implementation change. A normal full test run will now report their failures.

## Confirmed implementation problems

1. **Subject ownership leak.** `pp_enterdispatch` overwrites an owned subject
   pointer with a snapshot without releasing the original reference.
   A weak reference remains live after ordinary lexical scope exit. Existing
   tests that explicitly undefine the source variable hide this problem.

2. **Native field-view exception leak.** A hash view returned by
   `Perl_class_object_to_hash` is explicitly released only after matching
   returns. If a field's stringification throws, the view and aliased field
   values can remain live. The regression explicitly clears the source
   variables to isolate this from problem 1.

3. **Repeated matcher-internal FETCH.** Recursive matching fetches a tied
   element, but publishing its capture uses `sv_setsv`, fetching it again.
   Consequently `Int($captured)` can succeed on an integer and publish a
   string instead. The matcher must retain the value it checked. Reads
   explicitly performed by guards and clause bodies remain unrestricted;
   the corresponding new test passes.

4. **Inconsistent scalar-kind comparisons.** With dispatch disabled, a
   numeric subject can match a string literal. Nested literals have the same
   problem. The generic constant path uses string equality without the
   subject-kind restriction enforced by optimized top-level dispatch.

5. **Numeric caching bypasses type and Strict checks.** After numeric use,
   an original string can match `Int`, `Float`, or `Num`. Worse,
   `Strict(NumStr())` starts accepting padded strings it rejected before
   numeric use. Classification must respect POK precedence, following
   `created_as_number`, rather than accepting IOK/NOK irrespective of POK.
   This affects both criteria and optimized dispatch domain selection.

6. **Typed repeated references lose identity semantics.** Two distinct
   objects that stringify identically fail `[$item,$item]`, but pass
   `[RefVal($item),RefVal($item)]`. `ObjectVal` and `DefinedVal` show the same
   inconsistency. The typed-binding path uses `sv_eq` rather than the common
   identity-aware comparison helper.

7. **Sparse-array holes fail instead of matching undef.** Exact arrays,
   open searches, and tail captures reject absent AV slots. Treat holes as
   undef without filling the source array. Capturing the tail may naturally
   create values in the destination array.

8. **Malformed hash shapes compile silently.** `{a}`, `{$key=>1}` with an
   unpinned key, and `{a=>...}` compile rather than report unsupported syntax.
   Tests compile anonymous subs without calling them, so they distinguish
   compile-time validation from errors deferred until execution.

9. **Scalar-reference patterns accept unsuitable referent bodies.**
   Applying `on(\$value)` to a CODE reference attempts to copy the CV as
   a scalar and throws `Bizarre copy of CODE in dispatch pattern match`.
   A non-scalar reference should simply fail this structural shape. The
   separately corrected two-layer reference regression passes.

10. **Optimized string bounds depend on internal encoding.** A string
    containing the same characters stops matching after `utf8::upgrade`.
    `none` matches both representations; linear, binary, HV, and automatic
    dispatch reject the upgraded one. Min/max bounds use `SvCUR` bytes,
    which cannot reject character-equivalent representations safely.

11. **Concatenation does not implement its documented string semantics.**
    Equivalent byte and UTF-8-upgraded subject/pin combinations fail because
    fragments are compared as raw bytes. Numeric subjects are also silently
    stringified, contrary to the guide's explicit restriction. Separate
    regressions cover each issue.

Capture names repeated across separate regexes are no longer an unresolved
policy question: the recent warning and first-binding behavior remain covered
by `dispatch_on_hardening_tail.t`. Duplicate names within one regex continue
to use the regex engine's first-participating-capture API.

## Coverage added and strengthened

| Area | New or improved coverage | Result |
| --- | --- | --- |
| Dispatch backends | none, linear, binary, HV, auto; source order and encoding | Exposes kind and encoding failures |
| Dispatch sizes | 1, 15, 16, 17, 65 clauses; integer, float, string; with/without default | Pass |
| Dispatch searches | Every hit; misses below, inside, above bounds | Pass for tested ordinary representations |
| Context | Real subroutine scalar/list/void context, not file-scope wantarray | Pass |
| Numeric criteria | Native kinds, cached strings, padding, whitespace, exponent forms | Cached-string failures |
| Value kinds | undef, ordinary scalars, arrays, hashes, CODE refs, objects | Pass for criteria |
| Booleans | Actual boolean values versus ordinary truth values | Pass |
| Magic | Changing tied source and separate user guard/body reads | Matcher FETCH failure |
| Repeated bindings | Same object versus distinct equal-string objects | Typed-binding identity failure |
| Arrays | Sparse exact, open and slurping forms; slurp minimum boundaries | Sparse failures |
| Invalid syntax | Malformed hashes, invalid ellipses/slurps, calls with arguments, invalid criteria | Hash validation failures |
| Reference layers | Actual two-level reference, non-scalar referent | CODE-reference failure |
| Concatenation | Mixed internal encodings and numeric subjects | Fail |
| Ownership | Natural scope exit and native field exception | Fail |
| Generators | Suspension in body and guard, true/false guard resumption | Pass |
| Lexical scope | Dispatch-local names, direct live pins, recursion, escaped slurps | Pass |
| Regex state | Guard exceptions and successful open-search retry | Pass |

Existing tests were strengthened without changing their expected semantics:

- Three open-shape tests no longer return an unconditional success after the
  dispatch statement. They must actually select the expected clause.
- The reference-layer test now preserves two backslashes through its outer
  `q{...}` string. Previously both the subject and pattern collapsed to one
  layer, accidentally making the nominal two-layer test pass.
- The context test calls real subroutines. File-scope `wantarray` cannot test
  whether a selected clause propagates its caller's context.
- The bootstrap allowlist now covers the new review file and the narrowly
  scoped fatal-warning test introduced by the preceding capture-warning
  change. These are test infrastructure changes, not warning suppression.

## Remaining coverage work

1. After correcting the failures, repeat the same corpus in threaded and
   nonthreaded builds, DEBUGGING and production configurations, and ASan.
   Run LSan with `PERL_DESTRUCT_LEVEL=2` outside ptrace. Existing historical
   successes are not proof for the current code and new failure paths.
2. Expand threaded cloning tests beyond their six assertions: clone compiled
   dispatch tables in every mode, large auxiliary shapes, native class field
   maps, escaped scalar/slurp/regex bindings, and generators containing dispatches.
3. Add bounded generated differential tests between `none` and each optimized
   mode. Compare results, selected clause, warning/exception behavior, and
   side-effect counts. Include IV/UV boundaries, signed zero, infinities,
   NaNs, embedded NULs, dual representations, and non-ASCII text. Maintain
   independent expected results so agreement cannot hide a shared bug.
4. Broaden exact read-count tests to tied hashes, tied arrays, field magic,
   pins, and overlapping open-search candidates. Keep user-code reads
   separate from matcher reads. Check exceptions on each relevant read.
5. Audit all allocations across success, failure, retry, and exception:
   concat buffers, computed-value results, temporary regex matcher ops,
   pending bindings, class field views, and subject snapshots. Add natural
   scope-exit/destructor tests as well as sanitizer checks.
6. Add a consistent reference-kind matrix: SCALAR, REF, ARRAY, HASH, CODE,
   GLOB, REGEXP and native objects, blessed/unblessed where applicable.
   Structural mismatches should not invoke arbitrary conversions or produce
   internal copy errors.
7. Extend control-flow coverage to labelled last/next/redo, enclosing loops,
   exceptions, recursion, generator suspension and localizations in
   combination. Add targeted B::Deparse round trips and feature-off tests
   for the newer nested syntax where coverage is absent.

## Documentation and tracking

Do not change the documented POK, string, identity or sparse-array semantics
to accommodate these bugs. Fix the implementation against the agreed rules.

The guide should explicitly describe sparse holes and repeated binding
equality. The TODO document needs a status reconciliation: its ownership,
cleanup, magic and syntax claims are stronger than the new evidence supports.
Its old assertion that clause expressions do not inherit list context is
also contradicted by the corrected context tests.

Recommended order: ownership and invalid reference handling; one-fetch and
identity behavior; consistent scalar classification and encoding; sparse
arrays and hash validation; then the broader configuration/cleanup matrix.

Logs for this review are in the workspace `tmp/` directory, under names
starting `dispatch-on-review-` and `dispatch-review-`, not in the source tree.
