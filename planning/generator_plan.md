# Trial generators using one-shot continuations

Working branch: `xperl/main`.

This plan was restored during a completion audit because the previous removal
was not supported by sufficient evidence.

## Audit status

- [x] Process snapshots, opcode-boundary hooks, and private stack ownership
- [x] Generator syntax, one-shot resume protocol, and explicit `yield`
- [x] Nested eval, failure propagation, exhaustion, and re-entrancy
- [x] Feature/compiler diagnostics and documentation metadata
- [x] DEBUGGING and sanitizer validation
- [x] Destruction, GC, callback-context, and scheduler edge-case coverage
- [x] Final full relevant validation and cleanup

The DEBUGGING threaded build passes the focused generator, eval, loop, and
thread tests.  An isolated ASAN/DEBUGGING threaded build also passes the
generator and threaded smoke paths.  The agent sandbox cannot run
LeakSanitizer because it is ptrace-restricted, so the full generator test was
also run from the host terminal with `PERL_DESTRUCT_LEVEL=2`: all 46 tests
passed, and the direct generator smoke produced no leak report.  That full
test process still reports the two documented DEBUGGING temporary-SV teardown
diagnostics and a 176-byte indirect allocation retained by the test-process
teardown; neither reproduces in the direct generator smoke.  Cleanup coverage
includes dropping a suspended generator with a lexical object, callback
diagnostics, process-state round trips, and deterministic quantum-one
scheduler alternation.

The final scoped native harness passes all five relevant files (274 tests),
and the XS scheduler test passes all three checks.  The DEBUGGING generator
test still reports two non-fatal temporary-SV teardown diagnostics; minimal
runtime reproductions do not reproduce them, so they remain documented as a
test-harness teardown limitation rather than suppressed.

The process-local `PL_*` fields now resolve through a generated execution
context record.  Process switching installs the record pointer rather than
copying the individual fields.  The default record is embedded in the
interpreter, with an unthreaded bootstrap path that initializes its global
pointer before any context variable is used.  Threaded DEBUGGING, unthreaded
DEBUGGING, focused generator/runtime tests, `test_porting`, and the final
DEBUGGING `make_test` run pass.

The implementation now uses `gen` and `yield`.  Generators are callable
references blessed into `generator`; the non-advancing predicates are methods
and package functions named `running`, `completed`, `failed`, and `exhausted`.
The `generator` pragma enables both the generator and signatures features.
The old long spellings are not compatibility aliases.
The final DEBUGGING `make_test` run completed 2,947 files and 1,398,115 tests.
All generator tests passed.  Its diagnostic failures were the four generator
messages added after that run began; a subsequent standalone diagnostic check
confirmed those messages are documented.  The only remaining version-check
notice is the generated `B::Op_private` file, whose version is tied to the
unchanged core Perl version.

## Generator naming and object API follow-up — complete

Review feedback identified two related usability problems in the current
interface: the names are unnecessarily long, and a bare CODE reference does
not make it obvious in a debugger that it represents a suspended computation.
The next generator revision should address both at once.

### Target API

The generator-producing keyword becomes `gen`, and the suspension keyword
becomes `yield`:

    use feature 'generator';

    my $numbers = gen {
        yield 1;
        yield 2;
    };

`gen` is documented as the generator equivalent of `sub`: it creates a
callable body without running it, while `yield` returns values to the caller
and suspends the body until its next call.  The existing parameterized-call,
list-context, scalar-context, resume-argument, empty-yield, return, exception,
and one-shot-continuation semantics remain unchanged by the spelling change.

Each created callable is blessed into package `generator`.  It must remain
callable with the existing `$generator->(@args)` syntax, but its package name
must make its special continuation state visible to debuggers and ordinary
introspection.  Blessing must not copy the CODE reference or duplicate the
suspended process state.

The four state predicates move out of `builtin` and become methods and package
functions in `generator`:

    $generator->exhausted();
    generator::exhausted($generator);

The same dual calling convention applies to `completed` and `failed`.  For
`running`, the package form retains the useful list-filtering behavior:

    my @live = generator::running(@generators);

The object form, `$generator->running()`, is the scalar predicate for one
generator.  The implementation should define the exact context behavior in
tests before changing the public documentation.  Invalid arguments should
retain the established distinction between “not a generator” (`undef`) and a
valid generator whose predicate is false.

`generator::exhausted($generator)` remains the union predicate: it is true
after normal completion or uncaught failure.  `completed` and `failed` remain
mutually exclusive terminal-state predicates, and `running` is the inverse
of `exhausted` for valid generator objects.  None of these predicates resumes
or advances a generator.

### Implementation phases

1. **Freeze the API contract.** Add focused tests describing blessed
   generator identity, callable behavior after blessing, method and package
   predicate calls, scalar/list context, invalid arguments, and the four
   terminal states.  Confirm that predicates do not advance the continuation.
2. **Add the Perl package.** Implement package `generator` in Perl with the
   predicate methods and package functions.  Keep the low-level continuation
   state private; methods must inspect it through the existing internal
   representation rather than reconstructing it from user-visible values.
3. **Bless at construction.** Change generator creation to bless the returned
   CODE reference into `generator`.  Verify that closures, reference counts,
   destruction of suspended state, recursion, re-entrancy checks, and threaded
   cloning remain correct.  Add debugger/introspection assertions where the
   existing test tools support them.
4. **Rename the syntax.** Change the feature grammar, keyword tables, opcode
   metadata, diagnostics, compiler checks, deparser expectations, and
   generated files from `generator_create`/`generator_yield` to `gen`/`yield`.
   Regenerate all derived parser, keyword, feature, opcode, and documentation
   files with the normal regeneration targets.
5. **Remove predicate builtin exports.** Delete the four predicate exports
   from `builtin` and make `use generator` provide the package API while still
   enabling the `generator` and `signatures` features.  `use builtin` must no
   longer be required for generator predicates.  Check for namespace and
   `CORE` interactions before finalizing this step.
6. **Update documentation and diagnostics.** Revise `perlgenerator.pod`,
   `perlfunc.pod`, `perlsyn.pod`, `perlexperiment.pod`, `perldiag.pod`, and
   `perldelta.pod` to use only the new public names.  Explain `gen` as the
   `sub` counterpart, show both predicate calling forms, and document that
   the callable is blessed.  Do not describe the old spellings as supported
   syntax; they were experimental and have not been released.
7. **Validate and commit incrementally.** Run focused generator, feature,
   builtin, deparse, diagnostic, and threaded tests after each phase; run
   `make regen` using the system Perl where required; run `test_porting` before
   the final `make_test` in window 3.  Include DEBUGGING, ASAN/LSAN with
   `PERL_DESTRUCT_LEVEL=2`, and both threaded and unthreaded validation where
   available.  Keep the rename, object API, predicate migration, and docs in
   separate commits.

All seven implementation phases are complete.  The focused generator suite
passes all 89 tests, including callable blessed-object behavior and
suspended-state cleanup; the core opcode and deparse suites used for the
rename also pass.  The runtime and documentation were committed separately
as `a0f58fab58` and `c38ffbeb67`.

### Open design checks

- Decide whether `generator::running()` with no arguments is an error, an
  empty list, or a scalar false value; do not infer this from Perl's ordinary
  method-call defaults.
- Ensure a user can still call a blessed generator as a CODE reference and
  that method lookup cannot accidentally invoke or resume the continuation.
- Decide whether package functions should accept subclasses of `generator`
  and whether users may subclass the package without exposing continuation
  internals.
- Check how `UNIVERSAL::can`, `ref`, `Scalar::Util::blessed`, the debugger,
  serialization tools, and cloning report the new object.
- Confirm that a `yield` keyword remains restricted to a `gen` body and that
  ordinary Perl `yield` names, if any, are unaffected when the feature is
  disabled.

## Execution-context indirection follow-up

The current `PERL_PROCESS_STATE` is a field-by-field snapshot in `run.c`.
That is correct for the existing trial implementation, but it makes every
generator switch copy the same group of interpreter variables.  Investigate a
generated execution-context record so a switch can install one pointer rather
than copying those values.

### Design constraints established during investigation

- `intrpvar.h` is a multi-purpose input.  It generates the threaded
  `struct interpreter`, the unthreaded global declarations, initialization
  code, the handshake layout, exports, and `embedvar.h` access macros.  Any
  annotation must therefore have defined behavior in every one of those
  passes; it cannot be an ordinary C declaration added to only one pass.
- Existing interpreter members cannot simply be removed or reordered.  The
  interpreter-size handshake and embedding compatibility depend on the
  historical prefix and on new members being appended.  The first safe design
  should append an active-context pointer and retain legacy storage unless an
  explicit compatibility decision permits an ABI change.
- In a threaded/multiplicity build, the active pointer belongs in the
  interpreter object.  In an unthreaded build, it must be a global pointer.
  The `PL_*` access layer must resolve annotated variables through that pointer
  in both modes, while initialization and compatibility declarations continue
  to work.
- A generated context record should contain only execution-local state.  It
  must not contain `JMPENV` or other C-stack addresses, interpreter-wide
  allocators, global hooks, or state whose ownership/GC rules are not local to
  the suspended execution.  Exception environments continue to be created
  for each generator invocation.

### Proposed implementation shape

1. Introduce an annotation macro, tentatively `PERLVARCTX`, beside the
   existing `PERLVAR` family.  Mark the variables currently listed in
   `PERL_PROCESS_STATE`, after auditing omissions and variables that must stay
   interpreter-wide.
2. Add a generated `perl_execution_context` structure using the same annotated
   declarations.  Generate it from `intrpvar.h` so field names and types have
   one source of truth; do not hand-maintain a second list in `run.c`.
3. Add an active-context pointer to the interpreter/global state.  Generate
   `PL_*` accessors for annotated variables so threaded and unthreaded builds
   both dereference the active pointer.  Arrange declaration order so the
   unthreaded compatibility declarations do not collide with those macros.
4. Make `PERL_PROCESS_STATE` either contain, or point at, the generated record
   and change save/restore to install the pointer.  Keep an explicit slow
   compatibility path while validating the generated layout and nested
   generator behavior.
5. Audit cloning (`perl_clone`), interpreter initialization/destruction,
   debugger/runops wrappers, `PERL_RC_STACK`, regex execution, and embedding
   headers before enabling the pointer path by default.
6. Add a debug-only consistency check comparing the generated context fields
   against the legacy fields during the transition, then remove the duplicate
   copying only after DEBUGGING, threaded, sanitizer, and full `make_test`
   runs pass.

The preferred ownership model is to keep one default context record embedded
in each interpreter and have the interpreter's active pointer initially refer
to it.  This makes ordinary thread/interpreter creation and destruction follow
the existing interpreter allocation lifecycle.  A generator or scheduler that
needs an independent context owns an additional record, and its cleanup must
release that record only after its stacks and temporary references have been
disposed of.  `perl_clone()` must clone the active/default record according to
the existing `CLONEf_COPY_STACKS` rules rather than blindly copying stack
pointers; a cloned active pointer must point at the clone's embedded record,
not at the source interpreter or a generator-owned record.

### State classification to audit

The first candidate set is `op`, `curcop`, `comppad`, `curpad`, the active
stack pointers and stackinfo, the mark/save/scope/temporary stacks, `curpm`,
`curpm_under`, `reg_curpm`, `multideref_pc`, `defgv`, `curstash`, `curcopdb`,
taint flags, `delaymagic`, `dowarn`, `in_eval`, `localizing`, and `restartop`.
The audit must explicitly consider `regmatch_state`, debugger state, current
context-stack ownership, `PL_restartjmpenv`, and runops boundary hooks before
classifying them as swappable.  `top_env`, `start_env`, and `JMPENV` objects
remain excluded.

### Validation gates

- First validate generated declarations and offsets in both multiplicity and
  non-multiplicity builds without changing runtime behavior.
- Then benchmark and test process-state switching, nested generators, eval and
  exception paths, callbacks, destruction, DEBUGGING, threaded, and ASAN
  builds.
- Run `make_test` in tmux window 3 at the end of each implementation phase.

## Execution-context indirection follow-up

The current `PERL_PROCESS_STATE` is a field-by-field snapshot in `run.c`.
That is correct for the existing trial implementation, but it makes every
generator switch copy the same group of interpreter variables.  Investigate a
generated execution-context record so a switch can install one pointer rather
than copying those values.

### Design constraints established during investigation

- `intrpvar.h` is a multi-purpose input.  It generates the threaded
  `struct interpreter`, the unthreaded global declarations, initialization
  code, the handshake layout, exports, and `embedvar.h` access macros.  Any
  annotation must therefore have defined behavior in every one of those
  passes; it cannot be an ordinary C declaration added to only one pass.
- Existing interpreter members cannot simply be removed or reordered.  The
  interpreter-size handshake and embedding compatibility depend on the
  historical prefix and on new members being appended.  The first safe design
  should append an active-context pointer and retain legacy storage unless an
  explicit compatibility decision permits an ABI change.
- In a threaded/multiplicity build, the active pointer belongs in the
  interpreter object.  In an unthreaded build, it must be a global pointer.
  The `PL_*` access layer must resolve annotated variables through that pointer
  in both modes, while initialization and compatibility declarations continue
  to work.
- A generated context record should contain only execution-local state.  It
  must not contain `JMPENV` or other C-stack addresses, interpreter-wide
  allocators, global hooks, or state whose ownership/GC rules are not local to
  the suspended execution.  Exception environments continue to be created
  for each generator invocation.

### Proposed implementation shape

1. Introduce an annotation macro, tentatively `PERLVARCTX`, beside the
   existing `PERLVAR` family.  Mark the variables currently listed in
   `PERL_PROCESS_STATE`, after auditing omissions and variables that must stay
   interpreter-wide.
2. Add a generated `perl_execution_context` structure using the same annotated
   declarations.  Generate it from `intrpvar.h` so field names and types have
   one source of truth; do not hand-maintain a second list in `run.c`.
3. Add an active-context pointer to the interpreter/global state.  Generate
   `PL_*` accessors for annotated variables so threaded and unthreaded builds
   both dereference the active pointer.  Arrange declaration order so the
   unthreaded compatibility declarations do not collide with those macros.
4. Make `PERL_PROCESS_STATE` either contain, or point at, the generated record
   and change save/restore to install the pointer.  Keep an explicit slow
   compatibility path while validating the generated layout and nested
   generator behavior.
5. Audit cloning (`perl_clone`), interpreter initialization/destruction,
   debugger/runops wrappers, `PERL_RC_STACK`, regex execution, and embedding
   headers before enabling the pointer path by default.
6. Add a debug-only consistency check comparing the generated context fields
   against the legacy fields during the transition, then remove the duplicate
   copying only after DEBUGGING, threaded, sanitizer, and full `make_test`
   runs pass.

The preferred ownership model is to keep one default context record embedded
in each interpreter and have the interpreter's active pointer initially refer
to it.  This makes ordinary thread/interpreter creation and destruction follow
the existing interpreter allocation lifecycle.  A generator or scheduler that
needs an independent context owns an additional record, and its cleanup must
release that record only after its stacks and temporary references have been
disposed of.  `perl_clone()` must clone the active/default record according to
the existing `CLONEf_COPY_STACKS` rules rather than blindly copying stack
pointers; a cloned active pointer must point at the clone's embedded record,
not at the source interpreter or a generator-owned record.

### State classification to audit

The first candidate set is `op`, `curcop`, `comppad`, `curpad`, the active
stack pointers and stackinfo, the mark/save/scope/temporary stacks, `curpm`,
`curpm_under`, `reg_curpm`, `multideref_pc`, `defgv`, `curstash`, `curcopdb`,
taint flags, `delaymagic`, `dowarn`, `in_eval`, `localizing`, and `restartop`.
The audit must explicitly consider `regmatch_state`, debugger state, current
context-stack ownership, `PL_restartjmpenv`, and runops boundary hooks before
classifying them as swappable.  `top_env`, `start_env`, and `JMPENV` objects
remain excluded.

### Validation gates

- First validate generated declarations and offsets in both multiplicity and
  non-multiplicity builds without changing runtime behavior.
- Then benchmark and test process-state switching, nested generators, eval and
  exception paths, callbacks, destruction, DEBUGGING, threaded, and ASAN
  builds.
- Run `make_test` in tmux window 3 at the end of each implementation phase.

## Parameterized generator continuation work

- [x] Preserve initial invocation arguments for normal `@_` and signature binding
- [x] Return resume arguments from `generator_yield` with Perl context semantics
- [x] Preserve zero, one, and many yielded values, including `yield ()`
- [x] Preserve explicit list-valued returns on exhaustion
- [x] Accept generator signatures in `generator_create (...) { ... }`
- [x] Add focused regression coverage, diagnostics, and documentation
- [x] Run the relevant DEBUGGING, threaded, sanitizer, and `make_test` validation
