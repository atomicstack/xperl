# Function Arguments in Dispatch Patterns

This document records the design work needed to support arguments in function
and method calls used as `dispatch`/`on` data-shape values.  Implementation is
deliberately deferred.

## Current behavior

The dispatch/on implementation currently supports zero-argument function calls
and statically named zero-argument class-method calls as scalar pattern values.
For example:

```perl
dispatch ($version) {
    on (current_version()) { ... }
    on (Version->number()) { ... }
}
```

Calls with arguments are rejected with `unsupported dispatch pattern call`.
Unsupported Perl operators in the data-shape portion are rejected rather than
being silently evaluated with ordinary Perl semantics.

## Why arguments require separate handling

The compiler parses the complete `on (...)` expression into an ordinary
optree, but then deliberately prevents that optree from executing.  It keeps
the tree in `dispatch_pattern_aux` and interprets it as a restricted data-shape
language.  The executable child of `OP_DISPATCH_ON` is only an `undef`
placeholder.

This separation prevents arithmetic, calls, and other Perl expressions from
being accidentally treated as pattern syntax.  It also means that an argument
such as `$x + 1` has no ordinary runtime execution path inside the matcher.

## Proposed semantics

When eventually implemented:

- the call itself remains a supported pattern construct;
- each argument is ordinary Perl code;
- each argument is evaluated in scalar context;
- existing lexicals and pinned values may be referenced;
- newly destructured bindings are not available before the enclosing match
  succeeds;
- exceptions from argument evaluation or the called function propagate
  normally;
- unsupported operators outside call arguments remain errors;
- side effects are allowed, but should be documented clearly.

Argument expressions should be evaluated once when their clause is tried.
They should not be reevaluated repeatedly while an open or nested structural
pattern searches for a candidate match.

Examples of the intended future form:

```perl
sub add { $_[0] + $_[1] }

dispatch ($value) {
    on (add($base, 1)) { ... }
}
```

## Required implementation shape

The implementation needs a separate representation for executable arguments:

1. Identify supported function and method calls during compilation.
2. Extract their argument expressions while the parser and lexical pad are
   still active.
3. Compile each argument expression into an independently owned executable
   representation, such as a closure/CV.
4. Replace the extracted argument subtree in the retained pattern with an
   inert placeholder.
5. Store the argument evaluators in call-specific pattern auxiliary data.
6. Evaluate the arguments in scalar context when the clause is tried.
7. Invoke the function or method with the resulting values.
8. Preserve ordinary exception behavior and clean up all owned objects.

The retained pattern tree must never refer to an argument subtree after that
subtree has been transferred to another owner.  Any closure, CV, or detached
optree must have an unambiguous owner and must be released by the pattern
auxiliary-data destructor.

## Ownership and cloning risks

The pattern auxiliary data is attached to an optree and already owns the
retained pattern tree and several Perl arrays.  Adding executable argument
objects requires an audit of:

- `Perl_dispatch_pattern_free`;
- optree destruction order;
- threaded and cloned optrees;
- lexical pad ownership and closure lifetime;
- exceptions during argument compilation and evaluation.

Constructing anonymous CVs from nodes that are still owned by the retained
pattern tree is unsafe unless the nodes are explicitly detached or cloned.
Transferring an argument subtree without updating the original tree can cause
double frees, dangling pointers, or crashes during compilation and teardown.

## Testing required before implementation is accepted

Tests should cover:

- function calls with literal arguments;
- arguments using existing lexicals;
- arithmetic and concatenation inside arguments;
- static class-method calls with arguments;
- calls nested inside arrays and hashes;
- multiple calls in one structural pattern;
- calls used during open-array candidate searches;
- side effects and the once-per-clause evaluation rule;
- exceptions from arguments and called functions;
- closures, lexical capture, destruction, and threaded/cloned optrees;
- rejection of unsupported expressions outside call arguments.

Until this work is implemented and validated, function and method calls in
patterns should remain zero-argument only.
