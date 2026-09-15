# XPerl differences from mainline Perl

This document summarizes the intentional and material differences between
the current XPerl branch and mainline Perl's `blead` branch. It is a guide
to the shape of the fork, not an exhaustive patch listing. The exact changes
can be inspected with:

```text
git diff origin/blead..HEAD
```

## AI policy is now permissive

We have removed the AI-POLICY document, it was divisive and unbecomming of Perl.

## Language and runtime features

### Generators and resumable execution

The fork contains an experimental generator implementation with
`use feature 'generator'`, `gen` blocks, and explicit `yield` operations.
Generator objects expose running, completed, failed, and exhausted lifecycle
states through functions and methods. Initial arguments may be supplied through
an ordinary `@_` body or a signature, while later calls can send values back
to a suspended `yield` without rebinding the initial arguments. List-valued
yields and scalar-context handling are preserved.

Generator continuation ownership is one-shot, with diagnostics for invalid
resumption. Exception, cleanup, destruction, garbage collection, callback
context, and re-entry behavior are handled across opcode-boundary suspension
and resumption. The saved process state preserves the Perl execution context
across each suspension.

The active `PL_*` variables retain their direct interpreter or global storage.
Only the marked execution state is copied into a generator process state when
a generator is suspended or resumed. This avoids adding an execution-context
pointer dereference to ordinary calls while still allowing generator stacks
and execution state to be switched safely. Threaded and unthreaded
initialization, exports, generated access macros, and lifecycle handling were
updated for this model.

The members of the threaded context structure were also reordered to keep the
hottest execution fields together, improving ordinary subroutine calls by
several instructions per call.

Generators provide cooperative resumable execution: callers explicitly choose
which suspended generator to resume, and no threads or implicit scheduler are
created. A minimal generator can be written as:

```perl
use generator;

my $letters = gen {
    for my $letter ("A".."E") {
        yield $letter;
    }
};

my $numbers = gen {
    for my $number (1..5) {
        yield $number;
    }
};


for (1..5) {
    say $letters->(), $numbers->(), " ";
}
say "done" if $letters->exhausted;

# Outputs:
# A1 B2 C3 D4 E5 done
```

The interface is documented in `pod/perlgenerator.pod` and `lib/generator.pm`;
related feature, syntax, diagnostic, and release documentation was updated.
The runtime and callable-object behavior is covered by the generator and XS
API runtime tests.

The experimental `iterator` package generalizes the callable lifecycle
protocol to ordinary blessed code references. It distinguishes an ordinary
empty return value from completion and exposes running, completed, failed,
and derived exhausted states; generator continuation states remain private to
the generator runtime.

An uncaught exception escaping an iterator body is rethrown without silently
changing its state. The iterator contract requires code presenting itself as
an iterator to report completion accurately, so `exhausted` remains reliable
when an empty list is a valid ordinary result. The protocol also defines
`restartable` and `restart`; iterators are non-restartable by default and the
default restart method reports that restarting is unsupported.

The iterator API is documented in `pod/perliterator.pod` and `lib/iterator.pm`
and is covered by `t/op/iterator.t`.

### Class objects and Data::Dumper

Class objects now understand shallow class-object/hash conversion APIs for
serializer support. `Data::Dumper` uses the new representation in both its XS
and pure-Perl paths, with compatibility guards for building the distribution
on older Perl versions. The class-object support is documented and tested.

The relevant APIs and integration are described in `pod/perlclass.pod` and
the class-object and Data::Dumper tests cover the conversion behavior.

## Compatibility posture

Most existing Perl behavior is intentionally preserved where practical, and
the branch contains compatibility fixes for feature-disabled code, `CORE`
handling, threaded builds, and bundled distributions. 
