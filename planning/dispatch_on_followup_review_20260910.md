# Dispatch/on follow-up review — September 10

Reviewed the implementation, `pod/perldispatchon.pod`, and related tests after
`62d0b6e423`. Straightforward fixes are included in this review. More complex
issues are left unchanged for the user's review.

## Fixed during this review

1. Corrected the signed/unsigned comparisons in
   `S_dispatch_on_iv_in_bounds`. A negative minimum incorrectly rejected
   every unsigned subject. The analogous maximum test also used the wrong
   condition. Tests cover all dispatch modes, unsigned maximum, nearby
   misses, mixed bounds, and wholly negative bounds without assuming a
   specific UV width.
2. Both plain and class-qualified tied hash shapes now use `EXISTS` before
   `FETCH`. A tied fetch returns a proxy even for a missing key, so matching
   its undefined value previously confused absence with a present undef.
   Tests check exact/open shapes, both outcomes, and callback counts.
3. Documented that a false guard advances to the next clause, not another
   open-array candidate or longer concatenation capture. Added a side-effect
   test proving only the first structural candidate reaches the guard.
4. Distinguished copied named lexical captures from ordinary regex capture
   variables. Added a recursive control test comparing dispatch/on with
   ordinary matching. Also repaired an awkwardly wrapped slurp paragraph.

## Unresolved implementation issues

### 1. Borrowed captures can be invalidated by a pattern call — high priority

**Status: COMPLETE.** The later capture-owner and constraint-first changes
retain values across callbacks and provide exception-safe cleanup. Ordinary
SVs are retained, not frozen. The analysis below records the original bug;
see [`dispatch_on_constraint_first.md`](dispatch_on_constraint_first.md)
for the implemented contract and completed cross-build validation.

This can lose the captured reference or raise an internal copy error:

```perl
use feature qw(dispatch_on say);
my @values = (bless({}, 'Object'), 1);
sub remove_first { shift @values; 1 }

dispatch (\@values) {
    on ([$captured, remove_first()]) { say ref $captured }
}
```

The first capture records a borrowed SV pointer with `owned = FALSE`.
The supported zero-argument call then removes that source element before
`pp_on` publishes the bindings. The pointer is no longer safely
retained. The opt-in test has printed an empty reference type instead of
`Object`; a probe retaining a weak observer produced
`Bizarre copy of ARRAY in dispatch pattern match`. The precise symptom depends
on allocation/lifetime details. Use-after-free is the mechanism suggested
by the source, not a fresh ASan diagnosis.

This needs an ownership solution, not a ban on side effects in callbacks.
Decide where ordinary captured values are snapshotted/retained, how partial
matches own them, and how they are released on retries, exceptions and
successful publication. A reference capture should retain reference identity,
not recursively copy its object or aggregate.

The same audit should inspect current subject pointers across calls and
owned tentative regex/concat captures: their normal cleanup path is
`S_case_free_bindings`, which can be bypassed by an exception. Also inspect
pending-binding AVs and slurp AVs during callbacks. These are source-level
cleanup concerns, not separately demonstrated leaks in this review.

### 2. HV numeric keys do not implement the other backends' equality

**Status: DEFERRED.** The user has parked this under the integer-versus-float
semantics decision in [`dispatch_on_todo.md`](dispatch_on_todo.md). HV dispatch
is currently retained for algorithm comparisons and may be removed for
performance reasons. The analysis below records the discrepancy and possible
fix considerations, not a commitment to implement a fix.

With `PERL_CONST_DISPATCH_STRATEGY=hv`, a native `1.0` misses `on(1)`, and native
`1` misses `on(1.0)`. The unoptimized, linear, and binary implementations
match both. The HV keys use different `i:` and `n:` prefixes, so numeric
equality across those representations cannot find the same entry.

HV is not the automatic default, but a selectable optimization must preserve
the same matching semantics. A safe fix needs to handle integer/float
equivalence, IV/UV precision, signed zero, and values outside exact NV integer
precision. Simply converting every integer to NV would introduce new errors.
Prefer specifying a canonical numeric-key scheme or explicitly comparing
candidate values across domains with an exactness-preserving fallback.

## Semantics/documentation questions

### 3. Tail bindings currently alias source slots

**Resolved in follow-up:** tail bindings now copy element values, retaining
reference identity without slot aliasing. The final alias-versus-copy design
decision is tracked in `dispatch_on_todo.md`. The example and analysis below
describe the behavior before that fix.

```perl
my $source = [1, 2];
dispatch ($source) {
    on ([@tail]) { $tail[0] = 99 }
}
say $source->[0];                 # 99
```

Ordinary scalar capture assignment does not have this effect. The current
guide explains lexical lifetime and reference identity, but does not specify
whether a captured tail aliases element SVs or copies their values. Decide
which contract is intended before documenting or changing this behavior.
Add tests for writes, deletion, escaped closures, tied elements and referenced
objects under that contract.

### 4. Equality for repeated ordinary scalar bindings is underspecified

**Resolved in follow-up:** undefined and defined values compare unequal;
two undefined values compare equal. Defined non-reference values retain
string equality. Tests cover repeated bindings and both pin spellings.
The paragraph below records the original finding.

`on([$item,$item])` currently treats undef and the empty string as equal.
References have the now-documented identity rule, but ordinary scalars use
string equality. Literal shapes otherwise distinguish scalar kinds.
Clarify whether this permissive scalar comparison is intended for repeated
bindings and pins, rather than changing it as part of an unrelated fix.

## An apparent regex bug that the control experiment rejected

Recursive reuse of one regex can leave `$1` describing the innermost match
while a copied named lexical still holds the outer text. The same behavior
occurs with ordinary regex code in both the current interpreter and the
system Perl. It is not evidence of a dispatch/on-specific regression.
The new test compares the two code paths instead of asserting different
regex semantics for cases.

## Original follow-up coverage and reproducers

The coverage discussion below records the review before implementation.
Capture lifetime is now fixed and the opt-in reproducer uses a typed capture
to require observation before the mutating callback. HV numeric equality
remains deferred; its failing tests are still intentionally outside the
default harness. Current validation is recorded in
[`dispatch_on_constraint_first.md`](dispatch_on_constraint_first.md).

Run the opt-in failing regressions from the repository root:

```sh
./perl -Ilib planning/scripts/dispatch-on-review-open.pl
```

The file intentionally remains outside the default harness while the complex
fixes await review. It records the borrowed-capture error and compares
integer/float behavior across all four explicit dispatch modes. Each program
is checked for output and process status; failures are not hidden as TODOs.

Further testing should cover mutation from pattern calls and overloads,
destructor re-entry, exceptions after partial regex/concat/slurp matching,
numeric-key edge values, cloned compiled cases, and generator suspension in
combination with those states. Repeat under DEBUGGING and ASan/LSan after
the ownership design is fixed. Current validation uses the nonthreaded,
non-DEBUGGING `-O3` interpreter; no fresh sanitizer build was configured.

## Validation at the time of the original review

The updated core review file passes all 204 assertions. The porting suite
passes all 53,265 tests across 40 files. The full suite passes all 1,393,830
tests across 3,084 files. Thread-specific tests are skipped in this build.
The opt-in reproducer retains failures for the two unresolved implementation
issues above; those failures are not part of the passing full-suite count.
