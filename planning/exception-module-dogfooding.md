# Using X modules to develop exception extensions

Status: design notes and experiments to pursue, not an approved public API.
XStats is the first concrete consumer. X modules target XPerl and can use its
features directly. Ordinary Perl compatibility is not a requirement.

## Aim

Make structured errors pleasant to define and use in modules. A module should
be able to declare its own conditions, attach typed semantic parameters, add
operation context and propagate an existing exception without reducing it to
text. Reusable parts of that work may belong in modules shared by XStats,
XGraph, Tensor and other X modules.

Use real consumers to discover the right boundaries. Do not treat every
exception helper as core machinery merely because the first implementation
was written there. Conversely, moving code into a module must preserve the
bootstrap, lifetime and performance requirements of its existing callers.

## Current implementation constraints

- The exception container, diagnostic classes and their basic methods are
  compiled into Perl and miniperl. The module files mainly document them.
- `XPerl::Exception::_new` and `XPerl::Diagnostic::_new` are private
  constructors. They are useful implementation references, not a public
  module-extension contract.
- Core diagnostics are defined in `diag_conf.pl`. Generated metadata and
  numeric identifiers drive construction, classification and rendering.
- Language packs render that catalog. Registering another language pack does
  not by itself provide an independent module-owned diagnostic catalog.
- Constructing a diagnostic with an unknown code does not automatically give
  it a renderer. Blessing a hash or overriding an ordinary Perl method is not
  an adequate module-extension design.

See `xperl_exception.inc`, `pp_ctl.c`, `diagpack.h`,
[perlexcept](../pod/perlexcept.pod) and
[perlexcephack](../pod/perlexcephack.pod) for the implementation and contracts.

## Candidate reusable pieces

These are responsibilities, not settled package names.

| Responsibility | Candidate module support | Core requirements to preserve |
| --- | --- | --- |
| Diagnostic definitions | Module-owned names, classes, typed parameters and templates | Validate definitions and prevent identity collisions |
| Construction | Convenient builders with validated inputs and source locations | Owned values, correct severity and safe failure handling |
| Accumulation and context | Append diagnostics and attach operation context | Encounter order, containment and original exception identity |
| Presentation | Optional formatting and inspection tools | Structured data stays canonical; rendering must not load arbitrary modules implicitly |
| Validation and testing | Assertions over codes, classes, parameters and diagnostic trees | Tests must not depend on translated English text |

A small shared Perl layer may be sufficient for declaration and convenience
APIs. Native capture and delivery can remain in C. Investigate this before
creating a second framework or adding one-off constructors in every X module.

## XStats as the first consumer

Define statistical conditions in terms callers can inspect:

- Invalid input: operation, argument role and observation index where useful.
- Invalid options: option name and expected domain.
- Insufficient observations: operation, actual count and required count.
- Statistical domain errors: operation and the failed precondition, such as
  a constant predictor or an out-of-range quantile probability.
- Numerical range errors: requested statistic and the operation that could
  not retain or represent the required result.
- Invalid native object storage: a distinct invariant failure, rather than
  an ordinary statistical domain error.

Keep diagnostic classification separate from the shared exception wrapper.
Whether the classes live under `XStats::Diagnostic` or another namespace is
an open naming decision. Do not invent numeric core IDs for module-local
conditions before deciding how module catalogs are registered.

When a callback fails, propagate its exception with identity and diagnostics
intact. Add XStats context through the agreed mechanism. Do not replace it
with a new string saying that the callback failed, or hold borrowed PV
pointers across the callback.

## Questions for the prototype

1. Can a module declare a small catalog without changing the global core
   catalog or copying private object layouts?
2. What identifies a module condition across versions and processes? How do
   namespace ownership, numeric lookup and metadata introspection interact?
3. Which construction and validation operations need a native entry point,
   and which can be ordinary module code?
4. How should context be attached while preserving an exception already in
   flight? When should context own contained diagnostics?
5. How do module templates participate in explicit language selection,
   fallback and structured JSON/Dumper output?
6. What must work in miniperl or during destruction, and what can require an
   explicitly loaded support module?
7. How are definitions retained across ithread cloning, reloading, rendering
   callbacks and interpreter destruction?

## Experiments and acceptance

Start with two or three real XStats conditions rather than migrating every
message immediately. Exercise construction, catching, inspection, rendering
and rethrowing. Use the same support from a second X module before settling
the general API.

Check error and warning disposition, hook delivery, accumulated diagnostics,
callback failures, nested context, original identity, language fallback,
structured serialization, malformed definitions and ithreads. Measure the
normal successful path as well as error construction and rendering. The
support layer must not add work to each observation in a numerical loop.

Record each experiment and its outcome here. Keep proposals distinct from
implemented interfaces, and update the public manuals only when the interface
has a concrete implementation and a reviewed contract.

## First prototype

`XPerl::Diagnostic::Catalog` supplies declarative definitions and ordinary Perl
builders. Native registration compiles named placeholders into literal and
parameter tokens. It retains immutable SV descriptors without raw native
pointers in an interpreter-owned registry. Each diagnostic owns a reference
to its descriptor.
Rendering uses those tokens directly without callbacks or implicit loading.

Module conditions have namespace-qualified codes and no core number. Their
classes inherit from existing diagnostic classes. Typed numeric values are
captured in numeric SVs, discarding unrelated dualvar text. Repeating an
identical definition returns the registered catalog. Conflicting definitions,
invalid schemas and invalid values produce a generic core catalog-API error.
Module condition definitions stay outside `diag_conf.pl`.

The public methods are `define`, `diagnostic`, `exception` and `emit`.
Construction does not record a throw. Emission records the first origin and
uses ordinary warning or error delivery. Builders capture the public caller's
source location and lexical language. An XS boundary can use the private
capture entry point with an explicit wrapper depth. This is not a stable XS
interface.

The first XStats conditions are `XStats::RESULT_OVERFLOW` for sum queries and
`XStats::INSUFFICIENT_OBSERVATIONS` for empty-data summary queries. Numerical
success paths perform no catalog lookup. Remaining XStats conditions must be
migrated as their numerical and domain contracts are settled.

Keep this API experimental until a second real X module uses it. Extend
validation to callback context, translated definitions, interpreter cloning,
destruction and normal-path cost before treating it as a general extension
contract. Current focused tests cover copied definitions, typed dualvars,
lexical language and explicit override, containment/rethrow identity, hook
promotion, malformed declarations and bounded render fallback.

## XBench second-client experiment

XBench uses native classes, two-variable catches and defer with module-owned
conditions.  Callback failures retain the canonical exception.  Phase and
case notes add context, and cleanup failures append their diagnostic roots
to the original collector in encounter order.  An empty collector is tested
for definedness rather than boolean severity.  The runner retains completed
results and records a failed state during unwinding.

Tests cover canonical identity, original plus cleanup diagnostics, public
caller locations and lexical language, phase/case context, state restoration
and interpreter cloning.  This supplies a second real catalog client without
changing shared exception machinery.  Public-site capture is duplicated in XStats and
XBench; a future explicit-location catalog builder could replace their
private capture calls once this use establishes the required interface.
