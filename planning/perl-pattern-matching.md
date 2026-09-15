# Pattern matching for Perl

This document specifies the initial design for adding semantics inspired by
Elixir pattern matching to Perl. It is a planning document only; it does not
change the language.

## Implementation status

The `yves/pattern_match` branch currently has the experimental `dispatch_on`
feature plumbing, conflict-free lexer/parser support for the required
`dispatch (EXPR) { on (PATTERN) { ... } }` shape, a dedicated scalar matcher,
typed numeric/string literal matching, the wildcard pattern `_`, and recursive
array/hash matching. Captures are committed only after a complete match, and
fixed or open composites are supported with `...` boundary markers, including
leftmost subsequence matching when both boundaries are present, boolean regex
leaf patterns, and one-time case-subject snapshots that preserve writes to the
original lvalue. Numeric and string literals now require the subject to have
the corresponding scalar kind rather than silently coercing between kinds. A
dispatch subject may be named with `dispatch my $name (EXPR)`; without a name, its
value is temporarily localized in `$_`. A named subject leaves `$_` alone.
The dispatch subject is an ordinary Perl expression, so users can apply any
conversion they need with ordinary Perl functions and operators.
Dynamic scalar expressions nested inside array and hash patterns are compared
using their own evaluated values. The outer case body now accepts only direct
on clauses, while each clause retains a normal Perl block for its body. Focused
compiler tests cover feature gating, multiple clauses, `$_` restoration, typed
literals, wildcard matching, nested captures, rollback after failure, and open
composites. The current parser still uses the existing `given`/`when` optree
for block control, with case-specific context state layered onto it. Patterns
now have a dedicated, optree-owned auxiliary representation: the representation
retains structural nodes while the expression optree retains ownership of the
executable expressions. Array and hash traversal uses those compiled nodes,
and malformed ellipsis placement is rejected while compiling the pattern.
Pins are direct reads of existing lexical values at the point each comparison
is made; there is no case-entry pin snapshot or `with` clause. `redo` retries
the clauses with the current subject without reevaluating its expression.

Simple scalar constant patterns now take a direct comparison fast path in the
runtime matcher.  This covers `undef`, boolean, numeric, and string constants
without changing the source-order clause selection rule.

The next constant-case optimization will use separate, compile-time-selected
lookup strategies.  A case is eligible only when every direct clause is an
unguarded simple constant.  Any guard, dynamic expression, capture, pin,
composite pattern, regex, wildcard, or other non-constant form keeps the
existing source-ordered dynamic matcher.

The optimized representation has one domain description for each of `undef`,
boolean, IV, NV, and PV values.  The `undef` domain uses a presence flag; the
boolean domain uses separate presence flags for false and true.  IV, NV, and
PV domains use parallel arrays: one sorted array of constant values and one
array of clause indexes.  The arrays should use ordinary Perl-owned `AV`/`SV`
building blocks wherever practical, rather than introducing collections of
custom tuple objects.  Clause indexes are ordinary integer SVs, while the value
arrays own normal constant SV references.

The array and hash strategies are deliberately distinct.  The array strategy
compares directly against the typed values, using a linear probe for small
tables and binary search for larger tables.  The hash strategy constructs a
canonical typed key only after the subject has passed the applicable domain
checks, then performs an HV lookup whose value is a clause index.  It must not
fall back to array searching, and the array strategy must not construct hash
keys.  Initial thresholds are provisional and must be benchmarked.

Both strategies share domain metadata: string minimum/maximum length, exact
integer minimum/maximum bounds, and floating-point minimum/maximum bounds.
The bounds are used to reject impossible subjects before comparisons or key
construction.  Integer bounds must preserve IV/UV values exactly and must not
be converted through NV.  Missing domains are represented by explicit counts
or flags, never by zero-valued sentinels.

The initial selection policy uses sorted arrays for numeric domains, with
linear search for small tables and binary search for larger ones. PV constants
use an HV in the fast path. The exact numeric thresholds belong to
benchmark-driven tuning, not the language semantics. Duplicate simple
constants must retain deterministic first-clause behavior; duplicate detection
and diagnostics will be specified separately from guarded or dynamic clauses,
whose source-order evaluation and side effects must remain unchanged.

#### Constant-dispatch benchmarking

Before selecting thresholds, add a standalone benchmark which exercises the
actual compiled case machinery rather than benchmarking abstract Perl hashes
or searches.  It should generate cases with 1, 2, 4, 8, 16, 32, 64, and larger
constant clauses, and probe hits near the beginning, middle, and end as well as
misses.  Run the matrix separately for IV, NV, and PV domains, varying PV
lengths as well.  The measurements must compare:

* a direct linear probe over the sorted numeric value/clause arrays;
* binary search over those same arrays; and
* canonical numeric-key construction followed by an HV lookup.

PV dispatch already uses an HV. Its earlier benchmark found hash lookup
competitive for small sets and generally faster for hits in larger sets, with
the result depending on key length and hit/miss mix. Numeric HV lookup remains
an open benchmark question: test exact IV/UV and NV comparison semantics,
including mixed numeric constants and first-source-clause selection, before
considering a backend change.

The benchmark should include the cost of subject classification and the
domain-bound check, since those are part of the real dispatch path.  It must
also verify that all strategies select the same first clause when numeric and
string comparisons overlap, as well as for misses and mixed IV/NV constants. Thresholds
are implementation tuning parameters: record the machine, compiler, build
mode, and representative results, but do not make correctness depend on a
particular measured crossover point.

For repeatable comparisons, provide a developer-only strategy override (for
example, `PERL_CONST_DISPATCH_STRATEGY=none|array-linear|array-binary|hv|auto`).  The
default is `auto`; the forced modes are for measurement and diagnostics, not a
language interface.  The override may select among representations only
after the case has passed the pure-simple-constant eligibility check, and an
unknown or unavailable mode must fall back safely rather than changing case
semantics.

The dispatch recognizes eligible complete cases and inserts a case-level
opcode. Its runtime searches numeric arrays and a string-keyed HV for every
defined, non-overloaded subject and selects the earliest matching clause
across both; the per-clause matcher remains responsible for binding and clause
entry. Automatic dispatch selects linear probing for numeric arrays below 16
clauses and binary search at 16 clauses or above; the threshold is provisional.
String constants use the HV in every enabled dispatch mode. The legacy C<hv>
strategy setting selects binary search for numeric arrays; it does not change
the PV representation. Small
pure-constant cases are expected to gain a later compiler lowering to an
ordinary conditional tree, with the crossover threshold tuned separately for
the scalar domains rather than treated as a language-visible guarantee.
`PERL_CONST_DISPATCH_STRATEGY=none|array-linear|array-binary|hv|auto` can select the
currently available numeric modes for development comparisons. The binary mode uses
stable value ordering and scans equal values for the earliest source clause.
The dispatch metadata tracks exact signed/unsigned integer bounds,
floating-point bounds, and string length bounds; checks reject only subjects
which are provably outside the corresponding domain.  Automatic threshold
selection and the benchmark driver remain to be added.  The focused regression suite includes mixed typed
constants, duplicate constants, and misses to verify that this optimization
preserves first-clause behavior.  A wildcard clause can serve as the dispatch
fallback: constants before it remain eligible for lookup, while the wildcard
and all clauses after it are handled as the source-ordered fallback suffix.  A
case containing only a wildcard does not receive a dispatch opcode because it
has no useful lookup work to optimize.

Boolean patterns use Perl truth-value semantics: `on(true)` compares the
subject with `SvTRUE`, and `on(false)` compares it with the negation of
`SvTRUE`.  They therefore match defined true and false values as well as the
internal boolean scalar values.  `on(undef)` remains the separate pattern
for testing undefinedness.  A future `on(defined)` predicate should be
introduced as a dedicated pattern form; the current bare `defined` expression
is an ordinary Perl expression and is not yet that predicate.

The implemented first version intentionally stops at scalar, array-reference,
and hash-reference patterns, lexical captures and pins, guards, the wildcard,
regex predicates and simple
concatenation patterns. Object/class
destructuring, regex named captures, alternatives, ranges, optional fields,
user-defined pattern protocols, and signature dispatch remain follow-up work;
they are not silently implied by the current implementation.

## What “pattern matching” means here

Elixir uses patterns in several related situations:

* matching a value against a shape, such as a tuple, list, or map;
* binding names while the match succeeds;
* requiring an existing value through a separate pinning mechanism, rather
  than rebinding it;
* selecting a clause with `dispatch` or function-head patterns;
* optionally applying an ordinary Perl guard expression after the shape
  matches.

The key semantic difference from ordinary assignment is that a pattern is a
constraint. A match either succeeds and establishes all bindings, or fails
without leaving partial bindings behind.

For example, in an Elixir-like notation:

```text
{name, age} = {"Ada", 36}
^name = "Ada"
```

The first form destructures and binds. The second checks an existing binding.
The exact meaning of “binding” needs special care in Perl because Perl
variables are mutable, aliases and references are common, and assignment is
normally reversible and context-sensitive.

## Perl constraints and opportunities

Perl already has several pieces which overlap with pattern matching:

* list and hash assignment destructure values;
* signatures bind positional, named, slurpy, and defaulted parameters;
* `given`/`when` provides a clause-oriented conditional framework, but its
  historical smartmatch-based semantics are complicated;
* `isa`, `ref`, `keys`, regex matching, and overloaded operators can inspect
  values;
* class fields and role/interface information provide useful object shape;
* `map`, `grep`, `~~`, and chained conditionals already occupy likely
  syntax territory.

Pattern matching should not silently redefine `=` or inherit all of
smartmatch's type-dependent behavior. The preferred direction is to replace
`given`/`when` with new keywords and explicit pattern matching. The
implementation may reuse suitable internal control-flow machinery, but the
public grammar and semantic implementation must be separate. This avoids
creating a second meaning for the old keywords and gives the project a clear
path to eventually remove them.

The intended long-term form is therefore conceptually:

```perl
dispatch ($message) {
    on({ type => "ok", value => $value }) {
        process($value);
    }
    on({ type => "error", error => $error }) {
        report($error);
    }
    on(_) {
        ignore($message);
    }
}
```

Here `dispatch` evaluates its subject once, each `on` tests a pattern, and the
selected on clause receives the pattern bindings. `on` never means an implicit
smartmatch. A separate expression form may still be useful later, but the
statement-oriented `dispatch` construct is the primary design target.

When every clause consists only of simple constant patterns, a future
implementation may compile the case into a larger lookup or dispatch
structure. The current implementation keeps the observable source-order
first-match rule and applies only the safe direct-comparison fast path. If any
clause contains a dynamic expression or other non-constant pattern, the
implementation must evaluate the clauses in source order.

The subject may optionally receive a dispatch-local name:

```perl
dispatch my $message (fetch_message()) {
    on({ type => "ok", value => $value }) {
        process($message, $value);
    }
}

```

`dispatch my $name (EXPR)` evaluates `EXPR` once and binds the result to a fresh
case-local lexical. The unnamed `dispatch (EXPR)` form remains available and
localizes `$_`. Pins use `^$name` to read an enclosing lexical directly.

The subject expression is evaluated once before any clause is tested. The
matcher does not silently convert a pattern literal from one scalar kind to
another merely because Perl's ordinary comparison operators would do so. This
permits numeric and string clauses to remain distinguishable, for example:

```perl
dispatch ($value) {
    on(1)   { print "1"; }
    on("1") { print "one"; }
}
```

With strict typed-literal matching, a numeric subject selects the first clause
and a string subject selects the second. Dual-valued and magical scalars need
explicit rules; those rules must not accidentally turn the construct back
into coercive smartmatch.

The design also needs to distinguish:

* **shape matching**: does this value have the requested structure?
* **binding**: which names become available, and when?
* **equality**: must a value equal an already-bound value?
* **identity**: must it be the same reference or object?
* **guarding**: when and in what context an ordinary Perl expression runs
  after a structural match.

Conflating these would make the feature difficult to reason about and would
repeat problems associated with implicit smartmatch dispatch.

## Candidate patterns

An initial implementation should probably support only a small, predictable
set:

| Pattern | Meaning |
| --- | --- |
| `_` | Match anything without binding; usable as a nested placeholder |
| Literal scalar | Match by a specified equality rule |
| `$name` | Bind a lexical on successful match |
| `^$name` | Compare with the current value of an existing lexical |
| `[$a, $b]` | Match an array reference with exactly two elements |
| `[$head, @tail]` | Match a prefix and bind the remaining elements |
| `[..., $a, $b]` | Match a suffix at the end of an array reference |
| `{ key => $value }` | Match a hash reference with exactly the listed keys |
| `{ key => $value, ... }` | Match selected keys while allowing additional keys |
| `Type(...)` | Match an object/class and selected fields, subject to a defined object API |
| `pattern if GUARD` | Apply a guard after structural matching |

Questions such as optional fields, defaults, nested slurps, regex patterns,
ranges, alternatives, and object destructuring should be added only after the
core transaction and failure semantics are stable.

The `_` pattern is the general placeholder value. It succeeds for any value
without introducing a binding, and may appear wherever a nested pattern is
allowed, for example `[$first, _, $third]` or `{ name => _, id => $id }`.
It is a wildcard pattern, not a request to inspect or bind Perl's special
`$_` variable.

The initial design should use array references for tuple-like data, such as
`[$a, $b]`. Parenthesised Perl lists are temporary list-context expressions,
not scalar values that can be passed to the planned scalar `dispatch` subject, so
`($a, $b)` is not a separate tuple pattern.

### Composite scalar patterns

Patterns may also combine literal scalar fragments with clause-local bindings.
For strings, the implemented concatenation form makes common prefix, suffix,
and sandwich matches concise:

```perl
dispatch ($text) {
    on("x" . $suffix) {
        do_something($suffix);
    }
    on("x" . $inner . "z") {
        do_something_else($inner);
    }
}
```

The first pattern matches a string beginning with `x` and binds the remaining
text to `$suffix`. The second matches a string beginning with `x` and ending
with `z`, binding the intervening text to `$inner`. These are pattern
concatenations, not ordinary concatenations evaluated before matching: a
literal fragment constrains the subject and an unpinned name captures the
corresponding fragment. Empty captures are allowed, so the first form also
matches exactly `x` and the second also matches `xz`.

The first implementation supports one unpinned scalar capture surrounded by
literal fragments. A pinned scalar contributes its existing value instead of
capturing, so `dispatch ($text) { on("x" . ^$p) { ... } }` compares
against the complete composed value. Multiple unpinned captures and more
general expression operands remain follow-up work; they are not silently
treated as ordinary Perl expressions by the concatenation matcher.

## Syntax options

### Option A: `dispatch`/`on` (primary direction)

```perl
dispatch ($person) {
    on({ name => $n, age => $a }) if $a >= 18 {
        [ $n, $a ];
    }
    on({ name => $n }) {
        [ $n, undef ];
    }
    on(_) {
        undef;
    }
}
```

Advantages:

* provides a dedicated construct whose semantics can be designed cleanly;
* clearly separates pattern matching from assignment and smartmatch;
* a clause list gives a natural home for guards and alternatives;
* existing `given`/`when` control-flow implementation may be reusable
  internally without retaining its public semantics;
* the block's final expression naturally supplies the `dispatch` result without
  requiring a second clause syntax.

Costs:

* requires new pattern grammar and likely new opcodes or match frames;
* compatibility behavior must be selected explicitly;
* binding scope inside each clause needs precise rules;
* expression-valued matching would need a separate extension.

This is the initial clause form: every clause is a block. The block supplies a
lexical boundary and may contain multiple statements, declarations, control
flow, and a final expression whose value becomes the value of the `dispatch`.
Expression and arrow clauses are deferred and are not part of the initial
language design.

### Deferred clause-body forms

The following forms are plausible and should be compared against the actual
Perl grammar before syntax is fixed:

```perl
# A block clause
on("x" . $suffix) {
    do_something($suffix);
}

# An expression or block following an arrow
on("x" . $suffix) => do_something($suffix);
on("x" . $suffix) => {
    do_something($suffix);
}
```

The block form fits Perl's existing statement and scope model particularly
well: it gives every clause an unambiguous lexical boundary and leaves room for
multiple statements, declarations, control flow, and a future value-producing
form. An arrow form could make short clauses more compact and could naturally
support expression-valued `dispatch`, but `=>` already participates in hash
constructors and fat-comma parsing. It would therefore need careful grammar
and precedence rules, especially for nested patterns and blocks.

The initial language deliberately supports only `on(PATTERN) BLOCK`.
`on(PATTERN) => EXPR` and `on(PATTERN) => BLOCK` are deferred until
there is a demonstrated need for shorter clauses. Any later form must preserve
clause-local lexical scope and must not make a pattern indistinguishable from an
ordinary hash constructor.

### Other rejected alternatives

The following alternatives were considered and rejected as primary syntax
because they are not sufficiently compatible with Perl's grammar or do not
provide a good replacement for a clause-oriented match construct:

* **A binary match operator:** spellings such as `:=` introduce precedence,
  binding-rollback, and list-context problems. `=~` is already regex matching,
  and `~~` must not acquire a second meaning.
* **Pattern-aware signatures:** useful as a later extension, but signatures
  describe calls rather than general values; function-head dispatch would be a
  separate feature with its own ambiguity and scope rules.
* **A pure-Perl pattern object API:** useful for tiny exploratory experiments,
  but it cannot naturally express compiler-managed lexical bindings, rollback,
  clause scope, or the required grammar. It is not a viable implementation or
  public API for this feature.

These may still inform implementation or future convenience APIs. They are not
alternative public syntaxes for the initial feature.

## Recommended direction

The safest progression is:

1. Define the pattern representation and matcher in Perl core, initially
   behind internal interfaces and with no public syntax. Pure Perl may be used
   for isolated semantic experiments, but not as the implementation strategy.
2. Define a transactional binding result: successful matches return bindings;
   failed matches do not modify lexical variables.
3. Add experimental `dispatch` and `on` keywords, reusing suitable subject
   evaluation and clause-control machinery while replacing implicit smartmatch
   with explicit patterns.
4. Add `_`, literals, scalar bindings, array/hash destructuring, pinned values,
   and ordinary Perl guard expressions.
5. Enable the new keywords with `use feature 'dispatch_on'`; do not change the meaning of legacy
   `given`/`when` under that feature.
6. Use block-only clause bodies initially. The selected clause returns the value of
   its last expression using ordinary Perl context rules; no-match returns
   `undef` in scalar context and an empty list in list context.
7. Consider a compact operator only after precedence, rollback, and context
   behavior are proven.
8. Extend signatures and function-head dispatch separately.

The matcher, binding transaction, and syntax must live in core. A module-level
implementation would either lack the required compiler access or reimplement
large portions of the parser and pad machinery in fragile ways. Pure Perl can
still be useful for testing isolated matching policies, but it should not be
the implementation foundation or the public API.

The primary user-visible construct should therefore be new `dispatch`/`on`
keywords. They provide room for alternatives without assigning new semantics
to `=`, `=~`, or `~~`, and give the project a coherent path toward removing
legacy `given`/`when` rather than entrenching it.

## Relationship to legacy `given`/`when`

The new construct should preserve useful control-flow ideas from the old
framework while using new keywords and new semantics:

| Concern | Existing framework | Pattern-matching replacement |
| --- | --- | --- |
| Subject | `given` evaluates a subject | `dispatch` evaluates the subject once and retains the matched value |
| Clause test | `when` performs implicit smartmatch/boolean behavior | `on(PATTERN)` evaluates an explicit pattern, then an optional guard |
| Binding | No general structural bindings | Tentative bindings committed only after pattern and guard success |
| Fall-through | Existing `continue`/control-flow rules | No implicit fall-through; exactly one clause executes |
| Default clause | Common idiom using `default` or a catch-all | `_` catch-all pattern, with a defined no-match policy |
| Failure | Legacy behavior depends on smartmatch and context | Explicit no-clause-match behavior |
| Feature gate | Existing `switch`/smartmatch controls | New experimental `dispatch_on` feature |

The project should avoid silently changing the behavior of old source. During
the transition, legacy `given`/`when` can remain available under its existing
feature while new code opts into `dispatch`/`on`. Later, the project can remove
the old keywords and their feature as a deliberate language change. The new
keywords must not become aliases for the old smartmatch implementation merely
to ease the transition.

## Binding and failure semantics

These rules need to be decided before grammar work:

### Lexical scope

Each `on` clause should be its own lexical block. Pattern-bound names should
always be new lexicals whose lifetime and visibility are limited to that clause
and to nested code it invokes, subject to normal closure rules. They should
not implicitly assign to or rebind variables from the surrounding scope.

The exact syntax for introducing a clause-local pattern binding remains a grammar
decision. It is separate from ordinary variable declarations and should not
make those declarations part of every pattern.

### Existing names and pinning

An unpinned pattern name introduces a clause-local lexical. Prefix an existing
lexical with `^` to pin its current value:

```perl
dispatch my $subject ($value) {
    on({ ^$x => $result }) {
        process($subject, $result);
    }
}
```

Pins are read directly from the existing lexical at each comparison. Without
the caret, a pattern name introduces a clause-local binding.

The named subject is case-local and mutable. Assigning to it changes the value
observed by a later `redo`, while the original subject expression is not
reevaluated.

### Partial failure

Bindings must be tentative until the complete pattern and guard succeed. The
compiler can implement this with a temporary binding frame, followed by a
commit on success or a rollback on failure. It must not rely on user-visible
`local` behavior for this transaction.

### Aliasing and references

The feature must specify whether a binding aliases the matched value or copies
it. For scalars, ordinary Perl assignment usually copies a value while
references preserve referential identity. Array/hash destructuring must define
whether nested references are retained, cloned, or merely inspected. The
default should preserve references and avoid recursive copying.

### Context

The matcher should have explicit scalar/list behavior. A successful match can
return a true match object, a boolean, or bindings, but mixing these based on
context would be hard to teach. A `dispatch` expression should return the
selected clause's last expression, using ordinary Perl scalar, list, or void
context, while the clause's bindings remain lexical. If no clause matches, `dispatch`
returns `undef` in scalar context and an empty list in list context.

### Failure behavior

No-match is not an exception in the initial design: `dispatch` returns `undef` in
scalar context and an empty list in list context. A catch-all `on(_)` clause is
the normal way to make a case exhaustive, following the Elixir strategy. No
clause falls through to another clause; exactly one matching clause executes. A
dedicated exception class is not introduced for no-match in the first version.

## Data and object patterns

### Arrays and array references

Perl arrays are mutable and may contain aliases, magic, or tied behavior. The
pattern subject should be an array reference; a parenthesised Perl list is not
a first-class scalar value. An array pattern without `...` is exact: it must
match an array reference with exactly the specified number of elements. A
trailing `...` permits an arbitrary suffix, while a leading `...` permits an
arbitrary prefix:

```perl
dispatch ($items) {
    on([$a, $b, $c]) {
        exactly_three($a, $b, $c);
    }
    on([$a, $b, $c, ...]) {
        starts_with_three($a, $b, $c);
    }
    on([... , "foo", $value, "bar", ...]) {
        contains_subsequence($value);
    }
}
```

With both a leading and trailing `...`, the fixed portion is a contiguous
subsequence that may occur anywhere in the array. The matcher chooses the
leftmost position at which the fixed portion can match. A scalar binding such
as `$value` consumes one element; `...` consumes any prefix or suffix without
binding it. Empty prefixes and suffixes are allowed, so the same form also
matches an array whose contents are exactly `("foo", VALUE, "bar")`.

The matching and binding rules for multiple adjacent variable-length captures
must be specified separately. The initial design should keep `...` as a
boundary marker, with the fixed portion matched as one contiguous sequence,
and should avoid implicit regex-like backtracking beyond the defined
leftmost-choice rule.

### Hashes and maps

The implementation should distinguish “these keys must exist” from “the hash
has exactly these keys”. A hash pattern without `...` is closed and requires
exactly the listed keys:

```perl
dispatch ($record) {
    on({ foo => $value }) {
        one_key_only($value);
    }
    on({ foo => $value, ... }) {
        foo_with_other_keys($value);
    }
}
```

In a hash pattern, `...` is a final open marker. It does not bind the other
keys, and `{ ... }` matches any hash reference. The rules for magical and tied
hashes, overloaded values, and undef-valued keys must still be specified.

The `...` marker is meaningful only in pattern syntax. Outside a pattern,
Perl's existing yada-yada behavior is unchanged, and `..` retains its normal
range meaning.

### Objects and classes

Object patterns should not call constructors or arbitrary user methods merely
to inspect an object. A possible first rule is:

```perl
Point(x => $x, y => $y)
```

matches only objects with a declared class-field map and reads fields through a
core introspection interface. This could eventually cooperate with the
existing class field machinery and `implements` metadata. Blessed hashes and
unrelated modules should require an explicit adapter or pattern method.

### Regexes and user-defined patterns

Regexes should be usable as explicit leaf patterns against the `dispatch` subject:

```perl
dispatch ($text) {
    on(/^\d+$/) {
        process_number($text);
    }
    on(/^x(?<inner>.*)z$/) {
        process_inner($inner);
    }
}
```

The first form is a predicate pattern. The second also captures the text
between `x` and `z`. Named captures should become clause-local pattern bindings,
committed only after the complete regex match succeeds, rather than exposing
the clause through the ordinary global-ish `$1`, `$2`, or `%+` interfaces. A
regex pattern must operate on the explicitly supplied subject, never an
implicit `$_`, and the subject and regex should each be evaluated once.

The initial implementation should support regexes as predicate patterns and
named-capture bindings together. It must define duplicate named captures,
captures that did not participate, stringification and Unicode behavior, and
reject regex code blocks such as `(?{ ... })` and `(??{ ... })` in pattern
regexes.
Regex patterns should use normal Perl regex matching rules where possible, but
must not become a route for arbitrary hidden method dispatch. User-defined
patterns should likewise be an explicit protocol, not arbitrary overload
dispatch hidden inside a structural match.

## Compiler and runtime work

An implementation will likely need:

1. A feature gate and experimental warning category.
2. Grammar productions for the chosen construct and pattern forms.
3. A pattern AST or auxiliary op tree which preserves source locations.
   **Implemented for the supported structural forms; clause-specific source
   diagnostics remain a follow-up.**
4. Compile-time validation of duplicate bindings, illegal slurps, and scope.
   **Ellipsis placement is implemented; duplicate-binding and scope rules
   remain tied to the existing lexical compiler checks.**
5. Runtime matching operations for scalar, array, hash, and object shapes.
6. A temporary binding frame with commit/rollback behavior.
7. Scalar-kind-aware literal matching. **Implemented.**
8. Defined guard evaluation order and context. Guards are unrestricted,
   ordinary Perl expressions and may have side effects; the implementation
   must not pretend that those effects can be statically prevented.
9. Diagnostics for invalid pattern forms. **Implemented for the supported
   ellipsis errors and missing compiled representation.** Diagnostics naming a
   failed clause or exact pattern source location remain a follow-up.
10. `B::Deparse`, opcode tables, `regen` outputs, and syntax tooling updates.
11. Threaded/unthreaded, taint, magic, tied-variable, and destructor tests.

If matching is implemented as ordinary op sequences rather than one large
opcode, the compiler must still ensure that temporary bindings cannot leak
when a later subpattern fails. A dedicated match frame or save-stack record is
likely clearer than trying to undo arbitrary assignments after the fact.

## Compatibility risks

The feature must avoid changing existing behavior outside its experimental
scope. In particular:

* do not redefine `=`;
* do not alter `~~` or legacy `given`/`when` dispatch;
* do not change list-assignment or signature semantics;
* do not make barewords or braces ambiguous in ordinary code;
* do not invoke overloaded methods merely because a value appears in a
  pattern;
* do not make pattern variables visible outside their clause unexpectedly.

The grammar should be regenerated with the system Perl, and conflict counts
must be checked after every parser change. Syntax tests should run both from
the repository root and from `t/` using the established `@INC` setup.

## Test matrix

Before implementation, tests should be written for the intended semantics:

* literals, `_`, scalar bindings, and pinned bindings;
* numeric and string literal distinctions;
* nested arrays, hashes, and mixed shapes;
* exact, partial, optional, and slurpy forms;
* failed matches leave no bindings behind;
* duplicate and conflicting bindings;
* guards and guard failure;
* multiple clauses and default behavior;
* scalar, list, and void contexts;
* references, aliases, magic, tied values, and overloaded objects;
* classes and declared fields;
* recursion and nested matches;
* exceptions and destructors during matching;
* signatures and generators, if integration is supported;
* threaded and non-threaded builds;
* DEBUGGING and sanitizer builds with `PERL_DESTRUCT_LEVEL=2`.

## Open design decisions

The project should settle these questions before committing to public syntax:

1. What exact grammar introduces a new clause-local binding?
2. How are dual-valued and magical scalars classified for typed matching?
3. How should overloaded pinned values participate in equality comparison?
4. Are patterns matching values, references, object fields, or all three?
5. What evaluation order and context should unrestricted Perl guard
   expressions use, and how should their side effects interact with failed
   clauses?
6. How should tied, magical, overloaded, and blessed values participate?
7. Should pattern matching integrate with signatures and function dispatch in
   the first version or remain separate?
8. What, if anything, should be required for exhaustiveness checking?

The strongest initial design is an experimental `dispatch`/`on` construct with
lexically scoped transactional bindings, explicit pinning, a small structural
pattern set, and no implicit smartmatch dispatch. Legacy `given`/`when` may
remain temporarily for compatibility, but the new construct must have a
separate semantic implementation.

## Non-negotiable safeguards

The replacement must not repeat the historical failure by merely renaming
smartmatch. Before implementation is considered complete, the design should
meet all of these constraints:

1. The pattern syntax statically selects the matching operation.
2. Subject and pattern have fixed, visible roles.
3. Structural recursion is explicit in the pattern.
4. Object matching does not invoke arbitrary overload or conversion code.
5. Bindings are tentative and rolled back on any failed subpattern or guard.
6. No hidden assignment to `$_`, caller lexicals, or package variables occurs.
7. The subject is evaluated once, with documented context and lifetime.
8. Clauses do not fall through; exactly one clause executes after a successful match.
9. A no-match result is specified independently of pattern truth: `undef` in
   scalar context and an empty list in list context.
10. Legacy `given`/`when` and `~~` are not silently reinterpreted outside the
    new feature mode.

These safeguards also affect the implementation plan. Reusing the existing
`given`/`when` control-flow skeleton internally may be reasonable; reusing its
implicit smartmatch evaluator is not. The compiler should lower each pattern
into a known matcher or a dedicated pattern op tree, with a match frame for
temporary bindings and explicit clause dispatch.

## What the literature says went wrong with `given`/`when`

The official Perl documentation is unusually direct about this history. The
Perl 5.38 delta says that smartmatch and the switch feature had changed
significantly between 5.10.0 and 5.10.1, remained experimental for years, and
were declared a failed experiment after repeated proposals to fix or
supplement them. It specifically groups the `given`/`when` framework with the
smartmatch operator. See
[perl5380delta, “Switch and Smart Match operator”](https://perldoc.perl.org/perl5380delta#Switch-and-Smart-Match-operator).

The syntax documentation warns that `when` has “tricky behaviours” and says
not to rely on its current implementation. It also documents that `when`
conditions are interpreted through implicit smartmatch and that their exact
meaning is hard to describe precisely because the implementation guesses what
the programmer wants. See
[perlsyn, “Experimental Details on given and when”](https://perldoc.perl.org/perlsyn#Experimental-Details-on-given-and-when).

The smartmatch documentation identifies the underlying source of the problem:
smartmatch infers a comparison from the runtime types of both operands,
recurses into arrays, treats hashes specially, has a direction-sensitive
table, and can invoke object overloading. See
[perlop, “Smartmatch Operator”](https://perldoc.perl.org/perlop#Smartmatch-Operator).

The recurring failure modes are therefore:

### 1. One operator secretly means many unrelated relations

`~~` is not one relation such as equality or containment. Its meaning changes
depending on whether operands are scalars, arrays, hashes, regexes, code
references, objects, or undef. A programmer cannot determine the operation from
the operator alone; they must remember a dispatch table and its precedence.

**Protection for the new design:** a pattern must determine the operation.
`[ $x, $y ]` means sequence matching, `{ key => $v }` means record matching,
and `Type(...)` means an explicit object pattern. The subject's runtime type
may cause a clean mismatch, but must not silently select a different relation.

### 2. Operand direction is surprising

Smartmatch is commonly described as containment, so `small ~~ large` can mean
something different from `large ~~ small`. This is especially difficult when
the operands are arrays or hashes and the result depends on which side owns
the type-directed rule.

**Protection for the new design:** the syntax must have fixed roles:
`case SUBJECT` supplies the value and `match PATTERN` supplies the constraint.
There is no symmetric binary pattern operator in the first version. If an
operator is added later, its left/right roles must be stated in the grammar and
documentation and must not be inferred from operand types.

### 3. Recursive matching is implicit and under-specified

Smartmatch recursively compares nested arrays and has special behavior for
cycles. That makes a shallow-looking comparison potentially perform arbitrary
deep traversal, with surprising results for partially nested structures.

**Protection for the new design:** recursion occurs only where the pattern is
syntactically nested. Cycle handling must be explicit and bounded by the
matcher implementation. A pattern must never become recursive merely because
the subject happens to contain nested references. The first implementation
should use identity tracking for cycles and document whether a repeated
reference is accepted, rejected, or compared by identity.

### 4. Objects can execute arbitrary user code during a comparison

Smartmatch can invoke object overloading. That means a comparison that appears
to be a test may dispatch into user code, have side effects, throw, or return a
result unrelated to the object's actual shape.

**Protection for the new design:** structural patterns must not invoke
`~~`, stringification, numeric conversion, constructors, or arbitrary methods
implicitly. Object matching should use a defined class/field introspection
contract. An explicit user-defined pattern protocol may run code, but that
should be visible in the pattern and documented as effectful.

### 5. Testing and boolean selection are conflated with destructuring

The old framework mainly answers “does this condition match?”, while the
language people often expect from pattern matching also answers “what values
were extracted?” Smartmatch itself returns a boolean and provides no coherent
binding model. Users consequently combine it with ad hoc tests and assignments.

**Protection for the new design:** matching and binding are one transactional
operation. A successful clause creates explicitly scoped bindings; a failed clause
creates none. The clause's result value is separate from the match decision, and
there is no hidden assignment to `$_` or to caller variables.

### 6. Dynamic topic and control-flow behavior is too magical

`given` localizes or assigns the topic variable, and `when` has special
behavior in both `given` blocks and loops. `continue`, `break`, `next`, nested
loops, and statement modifiers interact with that hidden dynamic context. The
documentation also notes that the argument to `given` and `when` is scalar
context, another fact that is easy to miss.

**Protection for the new design:** evaluate the subject exactly once and make
it available by an explicit name or a well-defined read-only match subject.
Patterns and guards must have specified context. Clause entry, `next`, `last`,
`redo`, and nested-loop behavior must be tested independently. Guard side
effects are ordinary Perl side effects and are not rolled back merely because
the guard returns false.
The new mode should not depend on ambient `$_` as the subject.

## Current implementation checkpoint

The initial implementation and its focused regression tests are complete for
the supported language described above.  The implementation has been checked
with the built DEBUGGING interpreter, including the compiler-facing
`coreamp`, `coresubs`, and `B::Deparse-core` tests after a clean rebuild.
Simple scalar constants have a direct runtime comparison fast path; this is
an intentionally conservative first optimization and does not reorder clauses.

Before expanding the pattern language, the next full validation should be a
fresh `test_porting` run followed by `make_test`.  Any failure in generated
parser/opcode files must be fixed at its source and regenerated, not repaired
by hand.  The next feature work should be separately planned for object
patterns, richer scalar/string patterns, and a true constant dispatch table.

### 7. The semantics changed repeatedly while the syntax stayed familiar

The same surface syntax survived significant changes in implementation and
meaning. The feature was later retroactively classified as experimental, then
deprecated as a failed experiment, and later retained behind a feature for
compatibility in current Perl documentation. This is a warning about semantic
instability, not merely about the warning category.

**Protection for the new design:** make the pattern language a deliberately
small, named semantic system. Feature-gate the entire replacement mode, give
each pattern form stable rules before adding sugar, test compiler output and
diagnostics, and do not overload legacy smartmatch behavior to obtain a quick
implementation.
