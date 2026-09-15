# `dispatch`/`on` follow-up work

## September 10 correctness follow-up

The post-scheduler review is recorded in
[`dispatch_on_post_scheduler_review.md`](dispatch_on_post_scheduler_review.md).
Its regex source-order and hash-wildcard fixes passed the full threaded
DEBUGGING suite (1,406,121 tests). Empty exact container shapes are now
complete: dispatch/on plus Deparse-core passed 4,400 tests, and the porting
suite passed 53,264 tests on the threaded DEBUGGING build.

Duplicate capture names are now rejected at compile time within each clause;
pins and regex named captures retain their separate rules. Dispatch/on plus
Deparse-core passed 4,400 tests, and porting passed 53,273 tests under
threaded DEBUGGING. The old nested-search reproducer reused a capture
name and is now invalid; reassess that item using legal shapes before treating
it as outstanding implementation work.

The eleven problem groups in
[`dispatch_on_coverage_review.md`](dispatch_on_coverage_review.md) are fixed.
The expanded regression suite covers native scalar provenance, encoding and
byte mode, sparse arrays, reference identity, one-fetch capture binding,
hash-key validation, invalid referent kinds, and subject/field-view ownership.
The subsequent capture-ownership and constraint-first implementation is
also complete. Full suites pass on threaded DEBUGGING (1,406,315 tests)
and nonthreaded production (1,394,063 tests) builds, each across 3,084 files.
Focused ASan/LSan validation passes all 439 tests with full destruction
enabled. See
[`dispatch_on_constraint_first.md`](dispatch_on_constraint_first.md)
for configurations, completion times and the validation scope.

This document records the remaining work for the experimental
`dispatch_on` feature on the `xperl/dispatch_on` branch.  It is intentionally
implementation-focused: the broader language proposal remains in
[`perl-pattern-matching.md`](perl-pattern-matching.md).

The September 9 implementation review found six defects in previously
covered areas: escaped capture lifetime, multi-regex capture discovery,
nested builtin booleans, silent size limits, slurp-minimum overflow, and
duplicate hash keys. Fixes and expanded regressions are complete; broad
validation is tracked in
[`dispatch_on_review_fixes.md`](dispatch_on_review_fixes.md).

Status labels mean: `COMPLETE` is implemented and has focused coverage;
`PARTIALLY COMPLETE` has a working baseline but still needs specified
extensions or broader hardening; `OPEN` is unfinished; and `DEFERRED` is
intentionally postponed.

## Capture correctness and numeric-semantics review

### Capture lifetime across pattern calls — COMPLETE

Tentative captures now use indices into a lazy mortal owner AV. Recursive
values and containers remain alive across callbacks, and publication storage
has exception-safe ownership. Capture-only reads wait for structural success.
Mutation, exception, growth and sanitizer regressions pass. Source scalar
updates remain observable by design; retention is not snapshotting.

The original issue and investigation are preserved for historical context in
[`dispatch_on_followup_review_20260910.md`](dispatch_on_followup_review_20260910.md).
Further callback probes and repair options are recorded in
[`dispatch_on_capture_lifetime_analysis.md`](dispatch_on_capture_lifetime_analysis.md).
The final implementation and validation record is
[`dispatch_on_constraint_first.md`](dispatch_on_constraint_first.md).

### Integer versus float distinctions and HV equality — DEFERRED

As part of deciding whether matching should distinguish integers and floats,
assess the consequences of Perl's scalar type tracking for every backend.
Currently forced HV dispatch distinguishes integer and floating-point keys:
`1.0` misses `on(1)` and `1` misses `on(1.0)`, unlike the other backends.
Keep this discrepancy recorded rather than changing numeric semantics now.

Reconciling the representations may be impractical within this feature's
scope. HV dispatch is retained for performance comparisons, is not the
automatic default, and may be removed because of its performance. Revisit
its equality behavior only alongside the numeric-type decision and the
decision whether to retain that backend. Preserve the existing opt-in
reproducers for comparison; do not treat the discrepancy as fixed.

## Documentation-derived design questions

### Tail capture copying versus aliasing — OPEN

Tail bindings currently copy element values rather than alias source slots.
References retain their referent identity; aggregates are not deep-copied.
Before settling the API, decide once and for all whether tail bindings
should continue to copy or should alias instead. Until that decision,
implementation, tests and documentation must consistently use copying.

Also settle retention versus snapshotting for scalar observations made by
constraints. The current runtime retains the original SV until publication,
so in-place callback assignments remain visible; it does not freeze the
observed value. Distinguish this choice from aliasing the final pad scalar:
publication still copies into that scalar.

These questions were extracted from the dispatch/on guide and do not change
the current documented spellings.

### Naming value-kind criteria — OPEN

The current names are `DefinedVal`, `ScalarVal`, `RefVal`, and `ObjectVal`.
Decide whether future aliases or replacements should instead mirror existing
builtins such as `defined`, `scalar`, `ref`, and `blessed`.  Do not change the
current names until the language design is settled.

### Naming native numeric criteria — OPEN

The current names are `Int` and `Float`.  Decide whether they should remain
distinct from `Num`, or whether a more regular naming scheme is wanted before
exposing them as stable syntax.

### Documentation organization and examples — COMPLETE

Naming and pinning now appear alongside bindings and guards.  The guide has
runnable opening and closing examples with expected output, a boolean
comparison table, separate explanations of the two Strict forms, and concrete
aggregate, class, and conversion examples.  The closing example draws on
`t/comp/dispatch_on_examples.t`, which remains the broader feature tour.

## Documentation-derived implementation items — COMPLETE

The recent documentation notes are now reflected in the implementation and
focused tests:

- `DefinedVal()` performs a defined-value check and can bind one scalar target;
- `Int()` and `Float()` distinguish native integer and floating-point values;
- `true` and `false` retain boolean-value matching, while `TRUE` and `FALSE`
  use ordinary truth-value matching inside a data-shape;
- `Strict(NumEq(...))` rejects strings with no numeric prefix without causing
  the ordinary numeric warning;
- array slurp minima are stored in the full pattern count rather than being
  limited to 255.

## Current baseline

The branch currently provides:

- `use feature 'dispatch_on'` and the block-only form
  `dispatch (EXPR) { on (PATTERN) { ... } }`;
- one-time subject evaluation, named subjects with `dispatch my $name (EXPR)`, and
  unnamed dispatches that localize `$_`;
- direct pattern pinning with `^$name`, reading the existing scalar lexical at
  each comparison rather than taking a dispatch-entry snapshot;
- scalar patterns for `undef`, booleans, numeric literals, string literals,
  and the wildcard `_`;
- numeric criteria `Int`, `Float`, `IntStr`, `FloatStr`, `Num`, and `NumStr`,
  with optional `Strict` checks, plus matching-only `NumEq` using Perl's
  numeric equality semantics;
- value-kind criteria `DefinedVal`, `ScalarVal`, `RefVal`, and `ObjectVal`,
  plus the `TRUE` and `FALSE` truth-value criteria;
- ordinary Perl expressions as dispatch subjects, with conversions supplied by
  the user where needed;
- tentative lexical bindings with commit/rollback behavior;
- exact and open nested array/hash-reference patterns using edge `...`
  markers, including leftmost subsequence matching;
- regex data-shape patterns, including ordinary captures and clause-local
  bindings for named captures;
- string concatenation patterns with multiple scalar captures, including
  prefix, suffix, sandwich, pinned, empty, and leftmost-shortest captures;
- scalar and nested scalar-reference patterns, such as `\$value` and
  `\\$value`, which bind the referent rather than the outer reference;
- unrestricted ordinary Perl guards inside `on (...)`;
- labels and ordinary block control flow in clause bodies;
- constant-only dispatch using linear arrays, binary search, or an HV lookup,
  with development selection through `PERL_CONST_DISPATCH_STRATEGY`;
- domain metadata and min/max rejection for string lengths, integer values,
  and floating-point values;
- documentation in `pod/perldispatchon.pod`, `pod/perlsyn.pod`, and
  `BLEAD-DELTA.md`;
- focused compiler/runtime coverage in `t/comp/dispatch_on.t`;
- a single readable feature showcase in `t/comp/dispatch_on_examples.t`.

The dispatch/on implementation now has dedicated dispatch and dispatch-on
clause operations. It does not construct dispatch-on clauses through the legacy
given/when block builder. Its runtime dispatch is separate from given/when
semantics. The remaining work is hardening and extension, not a replacement
of the basic control-flow representation.

## Priority 1: make the basic implementation correct and maintainable

### Native-class implicit capture regression — COMPLETE

Running the proposed guide example exposed a defect on 2026-09-09:

```perl
use feature qw(dispatch_on say class);
class Position {
    field $x :param;
    field $y :param;
}
dispatch (Position->new(x => 3, y => 4)) {
    on (Position { '$x' => $x, '$y' => $y }) {
        say "position: $x, $y";
    }
}
```

This previously exited with SIGSEGV.  Using different undeclared capture
names avoided the crash but produced empty values.  Predeclared targets hid
the defect because the pattern compiler incorrectly redirected captures to
older same-named declarations, including class field pad entries.

Pattern preparation now replaces captures closed by the temporary parser
scope with new declarations in the dispatch-on clause, before parsing the guard
and body.  Pattern pad references are updated by index, and the fallback
search for older names has been removed.  Tests cover field-name collisions,
guards, shadowing, nested objects, array tails, pins, typed captures, UTF-8
names, and repeated execution.  The guide now uses implicit field captures.

The broader validation also exposed a separate slurp cleanup defect: the
minimum count in `OP_DISPATCHCOERCE::op_targ` was passed to `pad_free()` as a pad
index.  Opcode cleanup now clears that count before generic pad cleanup.
A fresh-process regression repeatedly compiles and destroys a pattern using
the maximum U32 minimum without allocating a correspondingly large array.

### 1a. Never silently ignore unsupported syntax — COMPLETE

Status: the validator and concat matcher now reject unsupported structural
syntax instead of treating it as a non-match or silently evaluating it as
ordinary Perl.

This is a permanent dispatch/on invariant.  Every pattern form must either be
implemented according to its documented data-shape rules or throw an explicit
exception.  In particular, unsupported operators, calls, malformed
concatenation boundaries, duplicate capture targets, and adjacent captures
must not be discarded or misinterpreted.  New pattern forms must add focused
negative tests proving that unsupported variants fail visibly.

### 1. Make pattern compilation ownership explicit — COMPLETE

Status: the ownership audit is complete for the current v0 representation.
The auxiliary pattern object owns the detached pattern optree, its compiled
node graph, its static-pin AV, and the retained regex metadata.  Node `OP` and
class-SV pointers are borrowed from the detached optree; they are not released
independently.  Dispatch tables own their ordinary AV/SV values and their
parallel target array, while target `OP` pointers are borrowed from the same
refcounted optree.  The dispatch reference count accounts for the dispatch op
and every pattern clause that points at the table.

This ownership is now stated next to the structures and release functions,
so future changes have an explicit rule to preserve.  The cleanup order frees
the node graph before the pattern optree, and releases dispatch data through
its separate reference count.  Existing exception, guard rollback, escaped
binding, destruction, nested-dispatch, and threaded-clone tests cover the runtime
paths; a new repeated compile-failure test exercises disposal when a later
syntax error discards an otherwise compiled pattern optree.

The simple concatenation implementation still marks concat operations so the
normal multiconcat optimizer leaves their structure intact.  That optimizer
contract remains a future maintenance concern, not an unresolved ownership
bug.  The broader non-threaded, ASAN, and valid LSan matrix is tracked under
item 9 rather than duplicated here.

### 2. Duplicate constant patterns — COMPLETE

Status: implemented and covered by focused tests.  Duplicate pure-constant
patterns warn and retain the earliest reachable clause; guarded and dynamic
patterns remain distinct.

For pure constant cases, duplicate values cannot select different clauses: only
the earliest source clause is reachable.  The implementation currently retains
the earliest clause for dispatch purposes.  The compiler now emits a C<syntax>
warning saying that the duplicate pattern will never match, while preserving
first-clause semantics.

Guarded and dynamic clauses must not be deduplicated because their evaluation may
have side effects and their guards can distinguish otherwise equal patterns.
The warning identifies the duplicate value and its source location.  Reporting
the original clause's source location as well remains optional diagnostic
polish rather than a semantic gap.

## Post-v0 follow-up: dispatch optimization

The following work is intentionally outside the v0 completion checklist.  The
current dispatch implementations are functional and covered by development
benchmarks; these items can be revisited after the semantics and ownership
model have stabilized.

### Post-v0.1. Audit optimized representations and cloning

Status: the array and HV dispatch forms exist and are usable.  Their ownership
and cloning rules are covered by the v0 audit above; performance and broader
cross-build comparisons remain intentionally deferred while the feature
semantics settle.

Keep the array and HV strategies distinct:

- array strategy: typed value arrays plus parallel clause-index arrays;
- HV strategy: canonical typed key construction followed by HV lookup;
- neither strategy should construct data structures belonging to the other;
- all retained values should use normal Perl-owned `AV`/`SV` structures where
  that is practical for cloning and cleanup.

The domain model should explicitly represent whether each domain is present:

- `undef` presence;
- boolean true/false presence;
- sorted IV values;
- sorted NV values;
- sorted PV values.

Absent domains must not be represented by ambiguous zero values.  IV and UV
  bounds must remain exact and must not be converted through NV.  String
  bounds must use scalar lengths without constructing unnecessary temporary
  strings.

### Post-v0.2. Improve dispatch selection

Status: provisional strategy selection is implemented and benchmark tooling has
been used during development.  The thresholds and build/type-specific tuning
are not considered final.

The current automatic policy is provisional: linear probing below 16 clauses and
binary search at 16 clauses or above.  Benchmark and tune the crossover by:

- scalar domain;
- clause count, including 2 through at least 2048;
- first, middle, and last hits;
- misses below the minimum, above the maximum, and inside the range;
- short and long strings;
- threaded and non-threaded builds;
- debugging and production optimization levels.

The benchmark must compare:

- ordinary `if`/`elsif`/`else` code;
- existing optree dispatch execution;
- array-linear dispatch;
- binary dispatch;
- HV dispatch;
- later, compiler-generated conditional trees.

Use sufficiently long timed runs to avoid “not enough iterations” warnings,
but keep ordinary measurements practical.  Record the build configuration,
compiler, CPU, and exact benchmark command.  Keep benchmark scripts and
results under `planning/scripts/`; they are developer tools, not language
interfaces.

### Post-v0.3. Add conditional-tree lowering

Status: not implemented. Current constant dispatch still uses its dedicated
dispatch machinery; no conditional optree is generated yet.

For small pure constant dispatches with no guards, generate an ordinary conditional
optree when it is faster than the generic dispatch machinery. The generated
structure must preserve:

- typed constant semantics;
- first-clause behavior after duplicate handling;
- wildcard/default placement, including a default in the middle;
- miss behavior;
- dispatch result context;
- dispatch labels and `last`/`next`/`redo` behavior;
- one-time subject fetching.

The generated tree should be visible to `B::Deparse` as the corresponding
conditional structure when deparsing at the relevant level.  Choose a subject
temporary that cannot collide with names used by the dispatch or clause bodies, and
ensure its lifetime covers the complete generated conditional.

Do not lower dispatches containing dynamic patterns, captures, pins, guards, or
unsupported composite forms.  Add a development-only way to disable lowering
for comparison tests.

## Priority 2: complete pattern semantics

### Explicit pin syntax — COMPLETE

Every pin uses the pattern-only `^$x` form. A bare `$x` always introduces a
capture, including when its name matches the dispatch subject or an outer lexical.
The old implicit-subject pin and its compile-time diagnostic have been
removed.



### 3. Composite scalar patterns — COMPLETE

Status: multiple-capture literal concatenation is implemented and tested for
prefix, suffix, sandwich, pinned, empty, and repeated-boundary cases.  The
matcher resolves captures left to right and chooses the shortest value bounded
by the next non-empty literal or pinned fragment.

The v0 rules for completing this form are now settled:

- multiple non-adjacent captures are allowed;
- captures are resolved left-to-right using the shortest value bounded by the
  next literal or pinned fragment;
- adjacent unbounded captures are illegal and must throw an exception;
- a capture name may occur at most once in a concatenation pattern, so repeated
  captures such as `$x . "-" . $x` are also illegal;
- empty captures are allowed;
- concatenation is the only structural expression supported for now;
- operands must be strings or values with usable overloaded stringification;
  numeric coercion is not part of this pattern form;
- normal Perl string, magic, Unicode, byte, and overload semantics apply;
- the subject and pinned operands are evaluated once per match attempt.

The following extensions remain deliberately deferred: richer structural
operators, numeric coercion within concatenation, repeated capture names, and
regex fragments embedded in string concatenation.  Unsupported forms must
continue to throw rather than silently falling back to another interpretation.

Zero-argument function and method calls remain supported as standalone scalar
pattern values.  They are not admitted as concatenation components.  Do not
silently evaluate calls with arguments, arithmetic, or other arbitrary Perl
expressions as pattern syntax.  If richer pattern expressions are eventually
allowed, specify exactly which operators are structural and how bindings are
obtained.

### 4. Regex-pattern hardening — COMPLETE

Status: the currently specified static-regex behavior is implemented and
covered, including named captures, nonparticipating captures, localization,
open searches, and rejection of dynamic regex patterns and regex code blocks.

Regex data shapes, ordinary captures, named clause-local bindings, `undef`
for nonparticipating named captures, duplicate-capture delegation to the regex
engine, static compile-time compilation, open-search reuse, and dispatch-local
capture restoration are implemented.  Regex code blocks are rejected rather
than silently discarded.  Dynamic regex construction is deliberately rejected
in a data-shape pattern for now; only a regular expression written as a static
pattern is accepted there.  Runtime-built regular expressions belong in the
ordinary Perl guard after `if`, where their normal evaluation rules apply.

Unicode and byte-string behavior remains the responsibility of the regex
engine, and the focused tests verify that the dispatch matcher does not interfere
with it.  Future work may revisit dynamic regex patterns or regex code blocks,
but either change would need a separate specification for evaluation count,
side effects, and repeated candidates.

A non-participating named capture is a named group whose branch was not taken
by the successful regex match.  It remains a clause-local binding with the
undefined value, following the regex engine's result.

### 5. Object and class patterns — PARTIALLY COMPLETE

Status: the initial structural object-pattern slice and native class
field-map/PTROBJ support are implemented and covered by focused acceptance
tests.  Blessed hash, array, and scalar-reference objects can be matched and
destructured; object captures are resolved to clause lexicals at compile time,
and array slurp targets retain their underlying array pads.

The first structural object-pattern slice is implemented and documented.  A
class-qualified pattern can now match and destructure blessed hash references,
blessed array references, and blessed scalar references.  Hash fields use
quoted field names, array fields are positional, and a trailing hash ellipsis
allows extra fields.  Class compatibility is checked without calling
constructors, accessors, overload methods, or arbitrary user methods.
For v0, a class-qualified pattern requires the object's exact class;
inheritance and role membership do not satisfy it.

Regression coverage is in `t/comp/dispatch_on.t` for captures, exact versus open
hash shapes, positional array shapes, scalar-reference shapes, and class
mismatches.  The implementation resolves captures from the temporary lexical
scope produced by the class-qualified parser form to the clause's lexicals
during pattern compilation.

The additional hardening coverage now includes tied blessed hash fields,
overloaded nested field values, reference-identity captures from object
fields, mutation of the original object after capture, and rollback after a
failed object guard.  These tests treat post-capture mutation as
caller-controlled: the matcher must not throw, but it does not promise that a
capture is a live alias or an immutable snapshot.

Still open for this item, all intentionally deferred beyond v0:

- a post-v0 `isa` pattern/operator for inheritance checks, followed by a
  separate decision about role-membership matching;
- a cleaner grammar path for class-qualified reference forms that avoids the
  ordinary indirect-method-call representation.

The v0 acceptance cases now verify these settled rules:

- a pinned reference compares by identity, while a reference capture binds the
  referent normally and does not clone it;
- native class fields are read directly, without accessors or arbitrary
  methods, and a missing field is a non-match unless field access itself
  raises an exception;
- tied or magical nested values follow ordinary Perl read semantics;
- overloaded nested values are invoked only when the selected pattern requires
  string, numeric, or boolean conversion; structural object matching does not
  stringify the whole object;
- captured references preserve their original identity.

## Post-v0 follow-up: additional pattern forms

These language extensions are intentionally outside the v0 completion
checklist.  They require separate grammar and semantic decisions after the
current structural matcher has settled.

### Post-v0.4. Additional pattern forms

Status: not implemented beyond the currently supported single final array
slurp and minimum-length form.  Alternatives, ranges, optional fields,
multiple variable-length captures, user protocols, and expression-valued
clauses remain intentionally deferred.

These remain deliberately deferred until the current foundation is stable:

- alternatives;
- ranges;
- optional fields;
- richer array slurps and multiple variable-length captures;
- user-defined pattern protocols;
- signature and function-head dispatch;
- expression-valued or arrow-form clauses.

Each form needs grammar, binding, rollback, context, error, and optimizer
rules before implementation.

## Priority 3: context, exceptions, and compatibility

### 6. Context and result behavior — COMPLETE

Status: the supported v0 pattern forms have been audited in scalar, list, and
void contexts by the focused compiler/runtime and hardening suites.

The implementation confirms that:

- the selected clause supplies the `dispatch` result;
- scalar/list behavior is ordinary Perl behavior;
- no-match returns `undef` in scalar context and an empty list in list
  context;
- an empty result from a matched clause is distinguishable from no match only by
  the documented result/context rules;
- subject evaluation and pattern evaluation do not accidentally change
  context.

### 7. Exception and cleanup behavior — COMPLETE

Status: the supported v0 exception and cleanup paths have focused coverage.
The remaining sanitizer work is tracked under item 9 and is validation work,
not an unresolved v0 semantic rule.

The focused suite verifies nested and outer `eval`, `die` in subjects, patterns,
guards, and clause bodies, plus cleanup and destruction paths.  It confirms:

- tentative bindings roll back on every failure path;
- `$@`, `$!`, localization, and scope restoration follow normal Perl rules;
- cleanup runs with the correct dispatch state installed;
- nested dispatches restore their parent state;
- fatal interpreter-wide failures remain interpreter-wide.

### 8. Magic, aliases, and mutation — COMPLETE

Status: the supported v0 magic, alias, identity, mutation, and lifetime
semantics have focused coverage.

The focused suite covers:

- tied scalar, array, and hash subjects;
- overloaded values;
- read callbacks occurring only as specified;
- writes from a clause to the original subject;
- aliases and references preserving identity;
- localization and destruction of bound values;
- mutation of the subject from the clause and its effect on later code.

The dispatch subject should be fetched once for matching, while the clause body must
still be able to modify the original lvalue.

### 9. Threaded and cloning support — PARTIALLY COMPLETE

Status: threaded dispatch contexts, cloned pattern representations, DEBUGGING, and
destruction-level focused runs pass.  Full sanitizer and cross-configuration
validation remain open.

The focused suite has been run under the current threaded DEBUGGING build and
with `PERL_DESTRUCT_LEVEL=2`, including thread-clone and nested-context tests.
Still to do is the same focused matrix under a non-threaded build, followed by
ASAN and LSan configurations.  Leak runs must use `PERL_DESTRUCT_LEVEL=2`;
reports from ptrace-restricted processes are not valid LSan evidence.

### 10. Debugger integration — OPEN

Verify that the Perl debugger works correctly with the new execution paths
introduced by generators, callable iterators, lexical namespaces, and
dispatch/on.  The debugger must be able to set and hit breakpoints, step into
and over the relevant code, report the correct current file and line, unwind
through exceptions, and display the active lexical variables without exposing
stale or transient implementation details.

Add focused debugger tests for ordinary calls, generator suspension and
resumption, iterator failure and restart, nested namespace scopes, and dispatch
subjects, captures, guards, and clause bodies.  Run them in both threaded and
non-threaded builds, including DEBUGGING where the execution-context changes
are most likely to expose incorrect debugger state.

### Current hardening-pass findings

The focused hardening pass is in
`t/comp/dispatch_on_hardening.t` and
`t/comp/dispatch_on_hardening_tail.t`, together with
`t/comp/dispatch_on_threads.t`.  All five dispatch/on files pass: 158 tests in
the current focused harness.

The coverage now verifies:

- scalar, list, and void result behavior, including a matched empty list;
- one-time tied scalar subject fetches and writes from a clause;
- tied array and hash reads through normal magic;
- overloaded scalar matching without applying stringification to structural
  object matching;
- reference-capture identity and mutation of original aggregate subjects;
- exception propagation from subjects, zero-argument patterns, guards, and
  clause bodies;
- nested `eval` catching a dispatch-internal exception;
- binding rollback after a guard exception;
- normal localization cleanup;
- release of captured scalar and array values at the dispatch boundary;
- nested dispatch state restoration after both ordinary success and cleanup.

The hardening work fixed three real defects: dispatch binding cleanup used the old
two-field representation after array bindings became triples, tied aggregate
matching bypassed magic-aware size/value access, and optimized dispatch could
ignore stringification overloads.  A guard exception that used to SIGSEGV now
rolls back bindings and propagates normally.

The focused object hardening additions bring the five dispatch/on files to 163
tests in the current harness.  Remaining limitations are tracked by the
numbered items above.  In
particular, selected clause expressions receive scalar, list, or void
context, as verified by calls to real subroutines. Sanitizer and
cross-configuration validation remain under item 9; items 6–8 are complete
for the supported v0 semantics.

## Documentation maintenance

The main documentation for the currently implemented feature is in place.
Whenever semantics change, update the related documents together:

- `pod/perldispatchon.pod` in a beginner-friendly, CS-101 style;
- `pod/perlsyn.pod` for syntax and precise semantics;
- `pod/perlfunc.pod` if new pattern-related functions or keywords require
  entries;
- `pod/perldiag.pod` for diagnostics;
- `pod/perlexperiment.pod` for experimental status;
- `pod/perldelta.pod` and `BLEAD-DELTA.md` for branch-visible differences;
- `B::Deparse` and its tests;
- keyword/opcode regeneration inputs and all generated outputs.

Every parser or opcode change must be followed by the appropriate regeneration
using the system Perl, and the grammar must remain conflict-free.  Focused
tests should be runnable from both the repository root and the `t/` directory.

## Suggested execution order for the remaining work

1. Complete the non-threaded/cloning/sanitizer validation.
2. Synchronize documentation and generated files as semantics change.
3. Run focused suites, porting checks, `make regen`, and finally `make_test`.

Post-v0 work begins with the dispatch optimization section above, followed by
the additional pattern forms section.

Do not mark the v0 feature complete until the active implementation,
exception/cleanup paths, documentation, and the full relevant test matrix all
agree with one another.  The dispatch and language-extension sections above
are explicitly post-v0 follow-up work and are not prerequisites for that
milestone.
