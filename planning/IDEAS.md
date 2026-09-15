# Perl language and runtime ideas

This file collects possible future work that is not currently part of an
active implementation plan.

## Zero-argument constants in dispatch/on patterns

Allow a data-shape in a `dispatch`/`on` statement to contain zero-argument
constant forms such as `Foo::BAR`, `DEBUG`, and `Foo::Bar::Baz()`. These
forms should contribute their returned value to the data-shape; they must
not become implicit bindings merely because they look like bare words.

Argument-bearing calls such as `Foo($x + 1)` are deliberately deferred. If
they are supported later, parentheses will be mandatory and their contents
will use ordinary Perl expression rules. Before adding that extension, define
its evaluation timing, context, side effects, and interaction with dispatch.

## AI-oriented benchmark and comparison tools

Develop developer-facing tools for AI-assisted Perl work that can turn
benchmark measurements into compact, reproducible comparison tables. The
tools should accept named implementations and scenarios, record the Perl
revision, compiler, build mode, machine, and relevant environment, and emit
plain text and Markdown tables with rates, relative speedups, and variability.
They should make it easy to compare generated code, optree variants, XS and
pure-Perl implementations, and alternative runtime strategies without each
experiment needing to invent its own reporting format. Keep the output useful
for both human review and later machine-assisted analysis, and ensure the
measurement layer does not hide warm-up, compilation, or setup costs.

## Block-scoped namespace declarations

The experimental `namespaces` feature currently supports only declarations
terminated by a semicolon, such as `namespace My::Application;`. It does not
support a block form such as `namespace My::Application { ... }` whose
namespace would automatically end at the closing brace.

Consider adding block-scoped namespace declarations. The design should make
the interaction with nested blocks, `package` declarations, relative names,
explicit `:::` boundaries, `__NAMESPACE__`, and `use PACKAGE as ALIAS`
unambiguous. Add parser, lexical-scope, error-reporting, and documentation
tests if this syntax is implemented.

## Split dynamic evaluation into compilation and execution

Investigate adding experimental keywords or builtins that split Perl's
dynamic `eval STRING` operation into two explicit stages:

```perl
my $code = eval_compile $source;
my $result = eval_execute $code;
```

The first stage would parse and compile source text, returning a compiled
representation suitable for later execution. The second stage would execute
that representation, with the caller choosing when and possibly where the
execution occurs. The final names and whether these are keywords, builtins,
or a small wrapper pragma remain open.

Research prior art in Zefram's modules, including how the compiled form is
represented, which lexical/package context it retains, how errors are
reported, and whether compilation and execution can be separated without
changing Perl's existing `eval` semantics.

Questions to answer before implementation:

* Does compilation capture the current hints, feature state, pad, stash, and
  source location, or does execution supply some of them later?
* What object or internal op-tree representation is safe to retain across
  calls, threads, forks, and interpreter destruction?
* How are compile-time side effects, `BEGIN` blocks, checks, and warnings
  handled when compilation is separated from execution?
* Which `$@`, `$!`, context, and exception-boundary rules apply to each stage?
* Can the compiled form be executed more than once, and if so what state is
  shared or cloned between executions?
* How should taint, debugging, source filters, `require`, and pragmata work?
* Can this be implemented using existing `eval_sv`, `call_sv`, and optree
  ownership machinery rather than exposing an unstable raw optree API?
* Is the feature useful as a foundation for schedulable or deferred code,
  without coupling it to generators or continuations?

The existing `eval STRING` behavior must remain unchanged outside an
experimental feature or explicitly opted-in API. This work should begin with
code archaeology and a small internal prototype, followed by tests for
lexical capture, repeated execution, exceptions, cleanup, and interpreter
threading before any public syntax is selected.
