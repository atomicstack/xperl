# XPerl structured exceptions implementation plan

## Status

This document turns the structured-error proposal in
`planning/xperl-ai-agent-design.md` into an implementation plan.  It is an
analysis document, not a commitment to a final API.

The working module name is `XError`.  The `X` prefix makes it clear that this
is part of the XPerl distribution rather than an attempt to extend Perl's
existing exception behavior for every program.  The name should be settled
alongside `XGraph`, `XTensor`, and the rest of the first-party naming scheme
before implementation starts.

## Goal

New XPerl libraries should be able to throw one interoperable error object
whose stable, machine-readable contract is independent of its human-readable
rendering:

```perl
$error->code;
$error->message;
$error->cause;
$error->data;
$error->file;
$error->line;
$error->trace;
```

The object must work naturally with existing Perl mechanisms:

```perl
use feature 'try';

try {
    XGraph->from_json($input);
}
catch ($error) {
    if ($error isa XError && $error->code eq 'XPERL.GRAPH.INVALID_EDGE') {
        ...
    }
    die $error;
}
```

This design is intended for `XGraph`, filesystem, process, HTTP, JSON,
parser, and package-management APIs.  Compiler diagnostics may eventually
use the same vocabulary, but their command-line transport and diagnostic-code
scheme are a separate project.

## Constraints and non-goals

- Do not change the meaning of `die`, `$@`, `eval`, or existing string
  exceptions.
- Do not automatically wrap every core or third-party exception.  New XPerl
  APIs opt into `XError`; callers can explicitly wrap errors at boundaries.
- Do not add new `try`, typed `catch`, or catch-filter syntax for version 1.
  Perl's existing `try`/`catch` already preserves the thrown value.
- Do not make formatted text, a class name, or a stack trace the recovery
  contract.  Recovery decisions should normally use `code` and structured
  `data`.
- Do not make JSON support a dependency of the base exception module.
- Do not add a public C API until real XS consumers demonstrate that the
  existing exception APIs are inadequate.
- Do not attempt to make arbitrary Perl values losslessly serializable.
- Distribution through CPAN or PAUSE is not a design requirement.  `XError`
  is a bundled XPerl component and should be buildable and testable from the
  XPerl source tree.

## Existing behavior to build on

Perl already supplies most of the required transport semantics:

- `die $object` preserves a reference in `$@`.  At the top level the object is
  stringified for human-readable output.
- `try`/`catch` places the exact thrown value in the catch lexical, including
  false values and objects with false boolean overloading.
- `catch` localizes the exception state, so nested exception handling does not
  require a second global error slot.
- `die;` rethrows the active exception.  If an object implements
  `PROPAGATE($file, $line)`, Perl invokes that method while propagating it.
- XS can throw an SV, including an object, with `croak_sv()` or `die_sv()`.
  `G_EVAL` and `G_RETHROW` already provide the corresponding embedding path.

The first implementation should therefore be a library contract plus tests,
not a new interpreter exception mechanism.  This keeps the project small and
lets it validate the public semantics in real XPerl libraries before any core
optimization is considered.

There is one relevant semantic gap: when a `defer` or `finally` block throws
while another exception is unwinding, Perl deliberately leaves the outcome
unspecified beyond guaranteeing that some exception reaches the caller.  A
deterministic chaining rule is useful, but it should be investigated and
implemented as a later, separately reviewed interpreter change.

## Proposed public contract

### Construction

The minimum valid error has a `code` and `message`:

```perl
my $error = XError->new(
    code    => 'XPERL.GRAPH.INVALID_EDGE',
    message => 'The edge references an unknown vertex',
    data    => {
        edge   => $edge_id,
        vertex => $vertex_id,
    },
);
```

Proposed fields are:

- `code`: required, non-empty stable identifier intended for programs.
- `message`: required human-readable summary.  Its wording is not stable API.
- `cause`: optional earlier exception that explains why this one exists.
- `data`: optional map of domain-specific, machine-readable details.
- `file` and `line`: the origin of the error, captured by default.
- `trace`: an ordered list of structured call frames captured at the origin.

The initial object should be immutable after construction.  In particular,
accessors must not allow a caller to mutate internal `data`, `trace`, or cause
state accidentally.  The implementation design must choose either defensive
copies or deeply read-only values and test the choice explicitly.

Constructor validation should reject unknown field names, invalid codes,
invalid line numbers, cycles, and unsupported values in structured data.
Failure to construct an error is itself a programming error and may remain a
plain exception during bootstrap; it must not recursively attempt to create
another malformed `XError`.

### Throwing and propagation

The useful convenience operations are expected to be small:

```perl
XError->throw(
    code    => 'XPERL.FS.NOT_FOUND',
    message => 'Configuration file was not found',
    data    => { path => $path },
);

$error->rethrow;

XError->wrap(
    $cause,
    code    => 'XPERL.GRAPH.LOAD_FAILED',
    message => 'Unable to load graph',
    data    => { path => $path },
)->throw;
```

Exact spelling is an API decision for phase 0, but the semantics must be:

- `throw` captures origin and trace once, then throws the object.
- `rethrow` throws the same object without replacing its origin or trace.
- `wrap` creates a new boundary error and retains the earlier exception as
  its cause.
- `PROPAGATE` returns the same object.  It must not rewrite the original
  location or grow the trace every time `die;` crosses a boundary.
- Throwing must preserve object identity through both `eval`/`$@` and
  `try`/`catch`.

Code should only wrap an exception when it adds a meaningful abstraction
boundary.  Blindly wrapping at every call site produces noisy cause chains
and obscures the useful error code.

### Codes

Use uppercase, dot-separated names owned by the producing subsystem:

```text
XPERL.FS.NOT_FOUND
XPERL.PROCESS.TIMEOUT
XPERL.HTTP.PROTOCOL_ERROR
XPERL.JSON.INVALID_INPUT
XPERL.GRAPH.INVALID_EDGE
```

The exact grammar needs to be frozen before implementation.  Once published,
a code must not be reused or silently change meaning.  Messages and extra
`data` keys may evolve; consumers must tolerate unrecognized data keys.

Subclass tests such as `$error isa XGraph::Error` may be useful for broad
classification, but subclasses must not replace codes as the normal recovery
mechanism.  A subclass must continue to satisfy the complete `XError`
contract.

Maintain one source-tree registry documenting each first-party code, its
meaning, producing component, and required or optional data keys.  The
registry is governance and documentation, not a run-time global enum which
prevents third-party extension.

Compiler diagnostic identifiers such as `XPERL-E0123` should not be collapsed
into this namespace without a separate compatibility analysis.  A compiler
diagnostic can be carried by an `XError`, but diagnostic identity and runtime
exception identity serve different audiences.

## Related investigation: split eval compilation and execution

Track the proposal in `planning/IDEAS.md` to bring the ideas from Zefram's
split-eval modules into core.  The proposed shape separates dynamic source
compilation from execution:

```perl
my $code = eval_compile $source;
my $result = eval_execute $code;
```

This is not required to deliver `XError`, but it is an important consumer of
the exception contract.  Splitting the operations would let callers
distinguish compilation diagnostics from failures raised by the compiled
program without parsing `$@`.  Add an explicit research task before either
API is frozen:

1. Identify the exact Zefram distributions, versions, source, tests, and any
   associated perl5-porters design discussion.  Record their public behavior
   rather than relying on recollection of the API.
2. Determine how those modules retain an optree and its pad, hints, feature
   state, package, source location, and interpreter ownership between the two
   stages.
3. Map the implementation onto current core mechanisms such as
   `doeval_compile()`, `eval_sv()`, CV ownership, `G_EVAL`, and `G_RETHROW`.
   Prefer an internal prototype before choosing keywords or builtins.
4. Specify two distinct failure surfaces.  `eval_compile` should return or
   throw structured compilation diagnostics; `eval_execute` should propagate
   runtime exception values, including `XError`, without replacing identity.
5. Decide whether multiple compiler diagnostics are represented by one
   exception containing a diagnostic list, an aggregate error, or a separate
   result object.  Do not force a many-diagnostic compile result into a
   single-message exception model.
6. Define `$@`, `$!`, warning, `BEGIN`/`CHECK`/`UNITCHECK`, source-filter,
   debugger, taint, and `__DIE__` behavior independently for compilation and
   execution.
7. Test repeated execution, nested compilation, lexical capture, recursion,
   thread cloning, fork behavior, destruction, and exceptions during cleanup.
8. Decide whether the retained compiled value is a public object, an opaque
   core value, or an implementation detail hidden by a small module API.

Keep ordinary `eval STRING` unchanged.  Any core integration should begin as
an experimental, opt-in API and should have its own parser/runtime plan.  The
structured-exception project should define compatible transport semantics,
but should not absorb optree lifetime management or the eval split into the
`XError` implementation.

### Trace and location

Capture `file`, `line`, and `trace` when the error is created or first thrown,
not when it is formatted.  A trace frame should contain only predictable
metadata, initially:

```perl
{
    package => $package,
    file    => $file,
    line    => $line,
    subname => $subname,
}
```

Do not capture argument values, lexical values, source snippets, or object
snapshots.  They create privacy risks, retain otherwise dead objects, and are
hard to serialize safely.  Internal constructor and `throw` frames should be
removed by a documented rule rather than by fragile string post-processing.

Trace capture happens only on an error path, but its cost and retention still
need measurement.  Phase 0 should decide whether the default trace is full,
bounded to a fixed number of frames, or controlled by an XPerl-wide policy.
Whichever rule is selected must be deterministic and reported in serialized
output when truncation occurs.

`file` and `line` describe the origin independently of trace rendering.  They
must remain useful when trace capture is disabled.

### Human rendering

String overloading should produce a concise message suitable for normal
uncaught-exception output, including at least the message, stable code, and
origin.  Rendering must:

- be deterministic;
- end in a newline so `die` does not append a misleading second location;
- avoid invoking arbitrary overload methods in `data` or foreign causes;
- tolerate a rendering failure without masking the original exception;
- avoid dumping the complete trace or private structured data by default.

A verbose formatter can render causes and traces for a human.  Formatting is
a layer over the object, not the object contract itself.  Color, terminal
detection, and localization do not belong in `XError` version 1.

### Machine representation

`as_hash` should return plain data under a versioned schema.  A candidate form
is:

```perl
{
    schema   => 'xperl.error/1',
    type     => 'XGraph::Error',
    code     => 'XPERL.GRAPH.INVALID_EDGE',
    message  => 'The edge references an unknown vertex',
    data     => { edge => 12, vertex => 99 },
    location => { file => 'job.pl', line => 41 },
    trace    => [ ... ],
    cause    => { ... },
}
```

The base module should not expose `to_json`; the JSON library encodes the
plain representation.  This avoids a dependency cycle when the JSON library
itself needs to throw an `XError`.

The schema must define treatment of bytes versus text, non-finite numbers,
missing values, foreign exception objects, and cause-depth limits.  A safe
default for unsupported foreign causes is a tagged, bounded string rendering,
not object introspection.  Cause cycles must be detected.  Serialization must
never recurse forever or throw a replacement exception merely because error
reporting is already in progress.

## Package and implementation shape

Start as a first-party distribution under a provisional layout such as:

```text
dist/XError/
    Changes
    Makefile.PL
    lib/XError.pm
    t/...
```

Prefer a Perl implementation for the reference version.  It makes the
contract easy to inspect and iterate, and exception construction is already
an error-path operation.  XPerl's class syntax is a possible implementation
tool, but the bootstrap and compatibility consequences must be settled first:
if low-level libraries need `XError` before the class feature is available,
an ordinary package may be the safer foundation.

XS callers do not initially need an `XError`-specific C API.  They can create
the object through a small Perl-level constructor helper and pass its SV to
`croak_sv()`.  Add a private helper only if pilot modules reveal unacceptable
boilerplate or benchmarks show a material cost.  Promote such a helper to the
public embedding API only after its ownership and reference-counting contract
has been exercised by more than one consumer.

Do not use `$SIG{__DIE__}` to convert exceptions globally.  The hook is
action-at-a-distance, also sees exceptions inside `eval`, and must instead be
treated as an interoperability surface that receives the original object.

## Adoption pattern

Each XPerl API should document:

- the codes it can produce directly;
- the structured data associated with each code;
- whether lower-level errors are propagated unchanged or wrapped;
- which conditions are returned normally rather than thrown.

Adopt the contract first in one small library with both Perl and XS call
paths.  `XGraph` is a good candidate because invalid vertices, malformed
input, algorithm preconditions, and callback failures exercise distinct
error categories.  A filesystem or process library should follow to validate
OS error data and chained failures.

For an existing foreign exception:

- propagate it unchanged if the current layer adds no useful context;
- wrap it with a new stable code at a public XPerl boundary;
- never infer a stable code by parsing its formatted message.

Adapters for `autodie::exception` or other established exception classes can
be added after the base contract is stable.  They are compatibility adapters,
not ancestors of `XError`.

## Implementation phases

### Phase 0: freeze the contract

1. Settle the public name and first-party `X` prefix policy.
2. Decide whether the implementation uses XPerl class syntax or a traditional
   package for bootstrap reasons.
3. Freeze constructor, accessors, `throw`, `rethrow`, `wrap`, `PROPAGATE`, and
   `as_hash` semantics.
4. Freeze code grammar, code ownership, and the registry format.
5. Specify accepted `data` values, immutability, cause normalization, depth
   limits, trace limits, and the `xperl.error/1` schema.
6. Write examples showing `eval`, native `try`/`catch`, wrapping, rethrowing,
   and an XS throw.
7. Cross-review the split-eval investigation so compile-stage and
   execute-stage failures can use the contract without conflating compiler
   diagnostics with runtime exceptions.

Deliverable: a reviewed API/schema note with every unresolved item below
answered or explicitly deferred.

### Phase 1: reference module

1. Add the bundled `XError` distribution and metadata.
2. Implement validation, immutable storage, accessors, origin and trace
   capture, safe stringification, propagation, and serialization.
3. Test legacy `die`/`eval` behavior and native `try`/`catch` behavior without
   changing the interpreter.
4. Add an internal test-only XS path using `croak_sv()` to prove that identity
   and reference counts survive the C boundary.
5. Document the contract, code stability policy, and safe logging guidance.

Deliverable: a self-contained module whose test suite passes in threaded and
non-threaded builds without changes to exception opcodes or parser syntax.

### Phase 2: pilot adoption

1. Integrate `XError` into one first-party XPerl library, preferably
   `XGraph`.
2. Define and register that library's initial codes and data fields.
3. Exercise callback exceptions, validation errors, wrapped parser errors,
   and direct XS errors.
4. Add a separate formatter/CLI adapter which can emit either concise text or
   the versioned machine representation.
5. Gather API friction, allocation cost, trace cost, and retained-memory data.

Deliverable: evidence from a real API that consumers can branch on codes,
display errors, and serialize them without inspecting messages.

### Phase 3: harden interoperability

1. Pilot a second, OS-facing library to validate errno, paths, process
   status, signals, and timeouts as structured data.
2. Add narrowly scoped adapters for important foreign exception types.
3. Decide from measured evidence whether XS construction helpers are needed.
4. Audit `$SIG{__DIE__}`, nested `eval`, destructor exceptions, overload
   failures, threads, cloning, and interpreter teardown.
5. Freeze schema version 1 and the compatibility rules for adding fields.

Deliverable: a stable contract suitable for broader first-party adoption.

### Phase 4: cleanup/finally exception chaining

Treat this as a distinct core project after the library contract has proved
itself.

1. Characterize current behavior for `defer`, `finally`, destructors, and
   scope-unwind callbacks when both the body and cleanup throw.
2. Specify precedence.  The leading candidate is that the cleanup failure is
   the primary error and the interrupted exception becomes its cause, because
   execution cannot honestly report successful cleanup.  Compare this with
   preserving the original as primary and recording cleanup separately.
3. Define behavior for combinations of `XError`, foreign objects, and strings.
   Do not silently impose `XError` wrapping on legacy programs without a
   compatibility decision.
4. Prototype preservation of the active exception across cleanup and add
   focused scope-stack, reference-counting, magic, and reentrancy tests.
5. Update the documented `defer`/`finally` guarantee only after the behavior
   is deterministic across supported builds.

This phase needs its own design review.  It touches exception unwinding and
save-stack behavior and has substantially greater compatibility and memory
safety risk than the module.

### Phase 5: broad adoption

1. Convert new XPerl libraries at their public boundaries.
2. Publish and review the central error-code registry.
3. Add user-facing documentation and release notes.
4. Evaluate whether compiler diagnostics should use `XError` internally or
   merely share the serialization conventions.
5. Consider typed catch or pattern-matching conveniences only after usage
   demonstrates a recurring problem that ordinary `catch` plus `isa`/`code`
   cannot express cleanly.

## Test matrix

The reference module needs focused tests for:

- required and unknown constructor fields;
- empty, false, Unicode, byte, NUL-containing, and overloaded values;
- defensive copying or read-only behavior of `data` and `trace`;
- origin selection and trace filtering through nested calls, `eval`, and
  `try`;
- deterministic stringification, trailing newlines, and rendering failures;
- exact object identity through `die`, `$@`, `catch`, `die;`, `rethrow`, and
  `PROPAGATE`;
- false-valued exception objects;
- nested handling and restoration of an outer `$@`;
- behavior observed by `$SIG{__DIE__}` without using the hook for conversion;
- cause chains, foreign causes, cycles, excessive depth, and serialization
  truncation;
- subclass behavior and code-based matching;
- exceptions from callbacks invoked by Perl and XS;
- `croak_sv()`, `G_EVAL`, and `G_RETHROW` interoperability;
- destructors, magic, overload reentrancy, global destruction, and threads;
- top-level uncaught formatting and unchanged process-exit behavior.

Phase 4 additionally needs a matrix covering normal and exceptional exits
through one or more `defer`/`finally` blocks, including a second exception at
each cleanup depth.  Run the low-level work under `DEBUGGING`, threaded and
non-threaded builds, and ASan/LSan with `PERL_DESTRUCT_LEVEL=2`.  Exercise at
least a 32-bit build and Windows before changing a documented unwind
guarantee.

## Expected implementation touch points

Phase 1 should be limited primarily to the new distribution, its tests, build
metadata, and user documentation.  Existing exception implementation files
are evidence and test surfaces, not expected edit targets.

If phase 4 is approved, likely review areas include:

- `pp_ctl.c` for `try`/`catch`, defer/finally invocation, and unwind state;
- `util.c` for thrown-SV and message handling;
- `scope.c` and save-stack cleanup behavior;
- `t/op/try.t`, `t/op/defer.t`, and `t/op/die.t`;
- `ext/XS-APItest/` for the XS and embedding paths;
- `pod/perlsyn.pod`, `pod/perlfunc.pod`, and release notes.

That list is deliberately provisional.  A phase-4 investigation must trace
the actual unwind path before identifying an edit set.

## Risks and mitigations

- **A universal base class becomes a bottleneck.** Keep the base contract
  small; put domain behavior and codes in producing libraries.
- **Callers parse messages anyway.** State clearly that only codes and
  documented data fields are machine contracts, and provide useful accessors
  and examples.
- **Traces retain secrets or large object graphs.** Store frame metadata only;
  never capture arguments or lexicals.
- **Serialization fails while reporting an error.** Restrict values, detect
  cycles and depth, and use bounded fallback representations for foreign
  causes.
- **Wrapping destroys identity or origin.** Distinguish `rethrow` from `wrap`
  and test both across Perl and XS boundaries.
- **String overload masks the original failure.** Keep rendering simple,
  guarded, and independent of arbitrary structured values.
- **The exception module creates a bootstrap cycle.** Keep version 1 small and
  dependency-light; do not depend on JSON, HTTP, or other consumers.
- **Core cleanup changes break legacy code.** Gate phase 4 separately and
  define behavior for non-`XError` exceptions before changing documentation.
- **Naming becomes tied to CPAN assumptions.** Treat `XError` as an XPerl
  first-party name and make installation metadata serve the XPerl build first.

## Open decisions

The following questions must be answered during phase 0:

1. Is the public name `XError`, and is `X` the standard prefix for bundled
   XPerl modules?
2. Does bootstrap permit XPerl class syntax, or must the base use a traditional
   package?
3. Is trace capture always on, bounded by default, or policy-controlled?
4. Are `data` and returned serialization structures copied, deeply read-only,
   or both?
5. Which scalar distinctions are guaranteed by `xperl.error/1`, especially
   bytes versus text and numeric versus string values?
6. How are foreign causes rendered without running unsafe or recursive
   overload code?
7. Is `type` part of the stable serialized contract or informational only?
8. What code and data-key compatibility promises apply before XPerl 1.0?
9. Should a cleanup error replace the active exception, be secondary to it, or
   form a dedicated aggregate error in phase 4?
10. Does the code registry live in one XPerl document or alongside each module
    with a generated combined index?
11. For a future split-eval API, does compilation failure throw an `XError`,
    return a diagnostic collection, or return a result object containing
    diagnostics, and how is that distinct from an exception thrown during
    execution?

## Completion criteria

The structured-exception work is ready for broad use when:

- the name, object contract, code policy, and schema are documented and
  versioned;
- the same object survives `die`/`eval`, native `try`/`catch`, rethrow, and XS
  boundaries without losing identity or origin;
- human formatting and machine serialization cannot mask the original error;
- two materially different XPerl libraries use the contract without parsing
  messages or depending on each other's exception subclasses;
- trace, cause, mutation, and serialization limits are explicit and tested;
- the test matrix passes across the supported threaded, non-threaded, debug,
  sanitizer, 32-bit, and Windows configurations relevant to touched code;
- any cleanup/finally semantic change has completed its separate compatibility
  and core review.
