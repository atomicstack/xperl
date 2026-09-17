# Pattern matching for Perl

This document explores what would be needed to add semantics inspired by
Elixir pattern matching to Perl. It is a design study only; it does not change
the language.

## What “pattern matching” means here

Elixir uses patterns in several related situations:

* matching a value against a shape, such as a tuple, list, or map;
* binding names while the match succeeds;
* requiring an existing value through a separate pinning mechanism, rather
  than rebinding it;
* selecting a clause with `case` or function-head patterns;
* optionally applying a restricted guard expression after the shape matches.

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
case $message {
    match { type => "ok", value => $value } {
        process($value);
    }
    match { type => "error", error => $error } {
        report($error);
    }
    match _ {
        ignore($message);
    }
}
```

Here `case` evaluates its subject once, each `match` tests a pattern, and the
selected arm receives the pattern bindings. `match` never means an implicit
smartmatch. A separate expression form may still be useful later, but the
statement-oriented `case` construct is the primary design target.

The subject may optionally receive a case-local name:

```perl
case (fetch_message() as $message) {
    match { type => "ok", value => $value } {
        process($message, $value);
    }
}
```

`case (EXPR as $name)` evaluates `EXPR` once and binds the result to a fresh
case-local lexical. The unnamed `case (EXPR)` form remains available. This
subject binding is distinct from a pin introduced by `with`: the former names
the value being matched, while the latter supplies existing values that
patterns must compare against.

The design also needs to distinguish:

* **shape matching**: does this value have the requested structure?
* **binding**: which names become available, and when?
* **equality**: must a value equal an already-bound value?
* **identity**: must it be the same reference or object?
* **guarding**: which expressions are allowed after a structural match?

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
| `$name` listed by `with` | Compare with the value pinned by the enclosing `case` |
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
not scalar values that can be passed to the planned scalar `case` subject, so
`($a, $b)` is not a separate tuple pattern.

### Composite scalar patterns

Patterns may also combine literal scalar fragments with arm-local bindings.
For strings, this makes common prefix, suffix, and sandwich matches concise:

```perl
case ($text) {
    match("x" . $suffix) {
        do_something($suffix);
    }
    match("x" . $inner . "z") {
        do_something_else($inner);
    }
}
```

The first pattern matches a string beginning with `x` and binds the remaining
text to `$suffix`. The second matches a string beginning with `x` and ending
with `z`, binding the intervening text to `$inner`. These are pattern
concatenations, not ordinary concatenations evaluated before matching: a
literal fragment constrains the subject and an unpinned name captures the
corresponding fragment. Empty captures should be allowed, so the first form
also matches exactly `x` and the second also matches `xz`.

The matching and binding rules for multiple adjacent captures, including how
ambiguous splits are selected, must be specified before that generalisation
is implemented. The initial implementation can restrict composite patterns
to an unambiguous literal/capture arrangement while preserving these basic
prefix, suffix, and sandwich forms.

## Syntax options

### Option A: `case`/`match` (primary direction)

```perl
case $person {
    match { name => $n, age => $a } if $a >= 18 {
        [ $n, $a ];
    }
    match { name => $n } {
        [ $n, undef ];
    }
    match _ {
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
* the arm can still have a value-producing form if expression semantics are
  added later.

Costs:

* requires new pattern grammar and likely new opcodes or match frames;
* compatibility behavior must be selected explicitly;
* binding scope inside each arm needs precise rules;
* expression-valued matching would need a separate extension.

This is the clearest initial form to prototype, but it is not a final
commitment about the spelling of an arm body. The proposal should remain open
to a block form, an expression form, or a syntax that supports both.

### Arm-body forms still under consideration

The following forms are plausible and should be compared against the actual
Perl grammar before syntax is fixed:

```perl
# A block arm
match("x" . $suffix) {
    do_something($suffix);
}

# An expression or block following an arrow
match("x" . $suffix) => do_something($suffix);
match("x" . $suffix) => {
    do_something($suffix);
}
```

The block form fits Perl's existing statement and scope model particularly
well: it gives every arm an unambiguous lexical boundary and leaves room for
multiple statements, declarations, control flow, and a future value-producing
form. An arrow form could make short arms more compact and could naturally
support expression-valued `case`, but `=>` already participates in hash
constructors and fat-comma parsing. It would therefore need careful grammar
and precedence rules, especially for nested patterns and blocks.

`match(PATTERN) BLOCK`, `match(PATTERN) => EXPR`, and
`match(PATTERN) => BLOCK` should remain design candidates until parser
prototypes and representative examples show which combination is least
surprising. The selected form must preserve arm-local lexical scope and must
not make a pattern indistinguishable from an ordinary hash constructor.

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
  arm scope, or the required grammar. It is not a viable implementation or
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
3. Add experimental `case` and `match` keywords, reusing suitable subject
   evaluation and arm-control machinery while replacing implicit smartmatch
   with explicit patterns.
4. Add `_`, literals, scalar bindings, array/hash destructuring, pinned values,
   and a deliberately small guard language.
5. Enable the new keywords with `use feature 'pattern_matching'` or another
   dedicated experimental feature name; do not change the meaning of legacy
   `given`/`when` under that feature.
6. Consider an expression-level `match` form only if real programs need a
   value-producing form that statement-oriented `case` cannot provide cleanly.
7. Consider a compact operator only after precedence, rollback, and context
   behavior are proven.
8. Extend signatures and function-head dispatch separately.

The matcher, binding transaction, and syntax must live in core. A module-level
implementation would either lack the required compiler access or reimplement
large portions of the parser and pad machinery in fragile ways. Pure Perl can
still be useful for testing isolated matching policies, but it should not be
the implementation foundation or the public API.

The primary user-visible construct should therefore be new `case`/`match`
keywords. They provide room for alternatives without assigning new semantics
to `=`, `=~`, or `~~`, and give the project a coherent path toward removing
legacy `given`/`when` rather than entrenching it.

## Relationship to legacy `given`/`when`

The new construct should preserve useful control-flow ideas from the old
framework while using new keywords and new semantics:

| Concern | Existing framework | Pattern-matching replacement |
| --- | --- | --- |
| Subject | `given` evaluates a subject | `case` evaluates the subject once and retains the matched value |
| Clause test | `when` performs implicit smartmatch/boolean behavior | `match` evaluates an explicit pattern, then an optional guard |
| Binding | No general structural bindings | Tentative bindings committed only after pattern and guard success |
| Fall-through | Existing `continue`/control-flow rules | Preserve only after auditing interaction with arm scopes |
| Default arm | Common idiom using `default` or a catch-all | `_` catch-all pattern, with a defined no-match policy |
| Failure | Legacy behavior depends on smartmatch and context | Explicit no-arm-match behavior |
| Feature gate | Existing `switch`/smartmatch controls | New experimental `pattern_matching` feature |

The project should avoid silently changing the behavior of old source. During
the transition, legacy `given`/`when` can remain available under its existing
feature while new code opts into `case`/`match`. Later, the project can remove
the old keywords and their feature as a deliberate language change. The new
keywords must not become aliases for the old smartmatch implementation merely
to ease the transition.

## Binding and failure semantics

These rules need to be decided before grammar work:

### Lexical scope

Each `match` arm should be its own lexical block. Pattern-bound names should
always be new lexicals whose lifetime and visibility are limited to that arm
and to nested code it invokes, subject to normal closure rules. They should
not implicitly assign to or rebind variables from the surrounding scope.

The exact syntax for introducing an arm-local pattern binding remains a grammar
decision. It is separate from ordinary variable declarations and should not
make those declarations part of every pattern.

### Existing names and pinning

An unpinned pattern name introduces an arm-local lexical. An existing value can
instead be made a pinned value for the whole `case` with a `with` clause:

```perl
case ($value as $subject) with ($x, $y, length($text) as $length) {
    match({ $x => $result }) {
        process($subject, $result);
    }
}
```

`with ($x)` evaluates and pins the current value of `$x`, using `$x` as its
pattern name. `with (EXPR as $x)` evaluates `EXPR` once and creates a case-local
pin named `$x`; it does not assign to the surrounding `$x`. Pin expressions
are evaluated from left to right before matching begins, and duplicate pin
names should be a compile-time error. A pinned name is compared, never
rebound, while all other names in the pattern remain arm-local bindings.

The `as` syntax in `case` and `with` therefore has parallel but different
roles: `case (EXPR as $name)` names the subject with a fresh binding, whereas
`with (EXPR as $name)` names a value that is pinned for matching. A case-local
subject or pin may shadow an outer variable with the same spelling, but it
must not assign to that outer variable.

This avoids giving `^` another contextual meaning on top of its existing Perl
uses, while making the values that participate in pinning visible at the
`case` boundary. The comparison semantics for a pin—ordinary scalar equality,
or a separately defined pattern-equality operation—remain to be specified.

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
context would be hard to teach. A `match` expression should likely return the
selected arm's value, while the arm's bindings remain lexical.

### Failure behavior

Possible policies are a false value, an empty list, a dedicated match-failure
exception, or a required default arm. A `case` construct can reasonably throw
when no arm matches; an operator used in `if` should probably return false.
The policy may differ by construct, but the difference must be explicit.

## Data and object patterns

### Arrays and array references

Perl arrays are mutable and may contain aliases, magic, or tied behavior. The
pattern subject should be an array reference; a parenthesised Perl list is not
a first-class scalar value. An array pattern without `...` is exact: it must
match an array reference with exactly the specified number of elements. A
trailing `...` permits an arbitrary suffix, while a leading `...` permits an
arbitrary prefix:

```perl
case ($items) {
    match([$a, $b, $c]) {
        exactly_three($a, $b, $c);
    }
    match([$a, $b, $c, ...]) {
        starts_with_three($a, $b, $c);
    }
    match([... , "foo", $value, "bar", ...]) {
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
case ($record) {
    match({ foo => $value }) {
        one_key_only($value);
    }
    match({ foo => $value, ... }) {
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

Regexes should be usable as explicit leaf patterns against the `case` subject:

```perl
case ($text) {
    match(/^\d+$/) {
        process_number($text);
    }
    match(/^x(?<inner>.*)z$/) {
        process_inner($inner);
    }
}
```

The first form is a predicate pattern. The second also captures the text
between `x` and `z`. Named captures should become arm-local pattern bindings,
committed only after the complete regex match succeeds, rather than exposing
the arm through the ordinary global-ish `$1`, `$2`, or `%+` interfaces. A
regex pattern must operate on the explicitly supplied subject, never an
implicit `$_`, and the subject and regex should each be evaluated once.

The initial implementation should support regexes as predicate patterns and
then add named-capture bindings once their interaction with transactional arm
bindings is specified. It must define duplicate named captures, captures that
did not participate, stringification and Unicode behavior, and whether regex
code blocks such as `(?{ ... })` and `(??{ ... })` are forbidden or isolated.
Regex patterns should use normal Perl regex matching rules where possible, but
must not become a route for arbitrary hidden method dispatch. User-defined
patterns should likewise be an explicit protocol, not arbitrary overload
dispatch hidden inside a structural match.

## Compiler and runtime work

An implementation will likely need:

1. A feature gate and experimental warning category.
2. Grammar productions for the chosen construct and pattern forms.
3. A pattern AST or auxiliary op tree which preserves source locations.
4. Compile-time validation of duplicate bindings, illegal slurps, and scope.
5. Runtime matching operations for scalar, array, hash, and object shapes.
6. A temporary binding frame with commit/rollback behavior.
7. Defined guard evaluation rules and protection against arbitrary context
   changes during a structural match.
8. Diagnostics that identify the failed arm and pattern location.
9. `B::Deparse`, opcode tables, `regen` outputs, and syntax tooling updates.
10. Threaded/unthreaded, taint, magic, tied-variable, and destructor tests.

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
* do not make pattern variables visible outside their arm unexpectedly.

The grammar should be regenerated with the system Perl, and conflict counts
must be checked after every parser change. Syntax tests should run both from
the repository root and from `t/` using the established `@INC` setup.

## Test matrix

Before implementation, tests should be written for the intended semantics:

* literals, `_`, scalar bindings, and pinned bindings;
* nested arrays, hashes, and mixed shapes;
* exact, partial, optional, and slurpy forms;
* failed matches leave no bindings behind;
* duplicate and conflicting bindings;
* guards and guard failure;
* multiple arms and default behavior;
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

1. Is the primary construct an expression (`match`) or a statement (`case`)?
2. What exact grammar introduces a new arm-local binding?
3. What comparison semantics apply to values named by a `with` clause?
4. Are patterns matching values, references, object fields, or all three?
5. Are guards restricted to side-effect-free operations, or merely documented
   as ordinary Perl expressions?
6. Does no match return false, return an empty list, or throw?
7. Does a successful match return the arm value, a boolean, or a binding map?
8. How should tied, magical, overloaded, and blessed values participate?
9. Should pattern matching integrate with signatures and function dispatch in
   the first version or remain separate?
10. What, if anything, should be required for exhaustiveness checking?

The strongest initial design is an experimental `case`/`match` construct with
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
8. Arms do not fall through unless an explicit, documented construct requests
   it.
9. A no-match result or exception is specified independently of pattern truth.
10. Legacy `given`/`when` and `~~` are not silently reinterpreted outside the
    new feature mode.

These safeguards also affect the implementation plan. Reusing the existing
`given`/`when` control-flow skeleton internally may be reasonable; reusing its
implicit smartmatch evaluator is not. The compiler should lower each pattern
into a known matcher or a dedicated pattern op tree, with a match frame for
temporary bindings and explicit arm dispatch.

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
operation. A successful arm creates explicitly scoped bindings; a failed arm
creates none. The arm's result value is separate from the match decision, and
there is no hidden assignment to `$_` or to caller variables.

### 6. Dynamic topic and control-flow behavior is too magical

`given` localizes or assigns the topic variable, and `when` has special
behavior in both `given` blocks and loops. `continue`, `break`, `next`, nested
loops, and statement modifiers interact with that hidden dynamic context. The
documentation also notes that the argument to `given` and `when` is scalar
context, another fact that is easy to miss.

**Protection for the new design:** evaluate the subject exactly once and make
it available by an explicit name or a well-defined read-only match subject.
Patterns and guards must have specified context. Arm entry, fall-through,
`next`, `last`, `redo`, and nested-loop behavior must be tested independently.
The new mode should not depend on ambient `$_` as the subject.

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
