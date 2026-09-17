# Generator and Coro context audit

This document records the relationship between the generator implementation in
the `perl/` checkout, Perl's interpreter-variable machinery, and the mature
Coro implementation in `../Coro-6.57`. It is design material, not a promise
that every item described here should become part of the generator ABI.

## Executive summary

Perl execution has two broad kinds of state:

* **Execution state** determines where an operation resumes and includes the
  current op, value and mark stacks, save and scope stacks, pads, and the
  current stack-info chain.
* **Execution environment** consists of values and pointers which ordinary
  Perl code can observe or modify, such as `$_`, `@_`, `$@`, `$/`, hints, and
  die/warn hooks.

The generator implementation primarily swaps execution state through
`PERL_EXECUTION_CONTEXT`. It also has generator-owned storage for `$_` and
`@_`, because those values are GV-backed and cannot be isolated by swapping
the `PL_defgv` pointer alone. This was added in commit
`f42ed7a676` and is covered by `t/op/generator.t`.

Coro does both jobs. It switches a native C execution context and explicitly
saves/restores a larger collection of Perl interpreter slots and environment
values. Coro is cooperative: a coroutine gives up control at explicit
transfer points, although an application scheduler can arrange frequent
transfers.

The important design implication is that a future coroutine facility should
probably have a small, clearly defined execution-state record and a separate
execution-environment record. Generators need the former plus the specific
dynamic values whose semantics require isolation. A coroutine or scheduler
may need both records.

## Current Perl context machinery

`intrpvar.h` is the source of truth for interpreter variables. Its declaration
macros are expanded differently to produce interpreter globals, threaded
interpreter members, or members of `PERL_EXECUTION_CONTEXT`; `embedvar.h`
provides the corresponding access macros. In other words, `intrpvar.h`
describes the variables and `embedvar.h` describes how C code reaches them in
the current build model.

The current context record is generated from the `PERLVARCTX` declarations in
`intrpvar.h` and is defined in `cop.h`. The process-state wrapper contains a
pointer to the active record plus inline storage used when a process is first
captured. Saving and restoring an already captured process is therefore a
pointer update; initial capture still copies the record into its storage.

The current `PERLVARCTX` set is principally:

| Group | Current fields | Role |
| --- | --- | --- |
| Dispatch | `op`, `restartop`, `curcop`, `curcopdb` | Resume location and current compilation/execution cop |
| Pads | `curpad`, `comppad` | Active lexical and temporary storage |
| Value stack | `stack_sp`, `stack_base`, `stack_max` | Current value-stack extent |
| Stack chain | `curstack`, `curstackinfo` | Active Perl stack and context chain |
| Control stacks | `markstack`, `markstack_ptr`, `markstack_max`; `savestack`, `savestack_ix`, `savestack_max`; `scopestack`, `scopestack_ix`, `scopestack_max` | Operator marks and deferred cleanup/scope state |
| Regex/taint | `curpm`, `curpm_under`, `tainting`, `tainted`, `delaymagic`, `dowarn` | Dynamic execution state used by regex and magic handling |
| Package/default glob | `curstash`, `defgv` | Current package and the GV used by default variables |
| Evaluation | `localizing`, `in_eval` | Scope-localization and exception behavior |
| Miscellaneous | `multideref_pc` | In-progress multideref execution |

The record deliberately does not contain a `JMPENV`. A `JMPENV` is a C-stack
exception boundary and must be established afresh by each generator resume;
keeping one in a heap-resident continuation would be invalid.

Several related variables remain outside this record, including `errgv`,
`rs`, `defoutgv`, `diehook`, `warnhook`, `hints`, `parser`, `runops`, and
compilation-state fields. They are interpreter-wide or are not yet treated as
part of a generator's execution state.

## Generator state

The generator owns a `PERL_PROCESS_STATE` and private continuation stacks. Its
state also stores initial and resume arguments, yielded and returned values,
terminal status, and an error value.

At each resume it:

1. saves the caller's process-state pointer;
2. restores the generator's process state;
3. establishes a fresh exception boundary;
4. runs until an opcode boundary reports a yield, normal completion, or
   failure;
5. restores the caller's process state.

The boundary is reached only after `pp_*()` returns, so a generator cannot be
suspended halfway through an opcode. A yielded continuation remains owned by
the generator and its stack-info chain is detached while the caller runs.

### `$_` and `@_`

`PL_defgv` is context-local, but the payloads behind the GV are not merely
interpreter variables:

* `GvSV(PL_defgv)` is the storage for `$_`;
* `GvAV(PL_defgv)` participates in the implementation of `@_` and argument
  donation between subroutine contexts.

Changing only `PL_defgv` therefore does not isolate these values. The current
generator gives each generator an owned scalar and array payload. While the
generator is running, the original GV identity remains in use and the scalar
head and array payload are exchanged with the generator-owned values. Keeping
the GV/SV identity compatible with the existing save stack is important for
`local $_`, argument setup, and subroutine return cleanup.

The regression tests demonstrate all of the intended properties:

* a caller's changes to `$_` do not affect a suspended generator;
* a generator's changes to `$_` do not affect its caller;
* a generator's initial `@_` is preserved across suspension;
* changing the caller's `@_` does not alter the generator's `@_`;
* modifying the generator's `@_` does not alter the caller's `@_`.

This is deliberately narrower than declaring every dynamic Perl variable to
be generator-local. `$@`, `$/`, output defaults, hints, and hooks remain open
design questions.

## What Coro saves and restores

Coro has two related mechanisms. Its native `coro_cctx` switches the machine
execution context (stack/register state), while its `perl_slots` record saves
Perl interpreter state. It also has an explicit list of SV payloads to swap
when entering and leaving a coroutine.

The following is the practical comparison:

| Interpreter value | Current generator | Coro | Notes |
| --- | --- | --- | --- |
| Current op / op-save | `PERL_EXECUTION_CONTEXT::op` | `op` or `opsave` | Resume location |
| Value stack pointers | Context record | `stack_sp`, `stack_base`, `stack_max` | The stack storage itself is separately managed |
| Mark stack | Context record | `markstack`, `markstack_ptr`, `markstack_max` | Required for nested operators |
| Save stack | Context record | `savestack`, `savestack_ix`, `savestack_max` | Required for localization and cleanup |
| Scope stack | Context record | `scopestack`, indexes, and optional names | Required for `LEAVE` behavior |
| Temporary stack | Context record | `tmps_stack`, `tmps_ix`, `tmps_floor`, `tmps_max` | Required for mortal lifetime |
| Current pad | Context record | `curpad` | Lexical execution state |
| Current stack/context chain | Context record | `curstack`, `curstackinfo` | Includes `PERL_CONTEXT` frames |
| Current cop | Context record | `curcop` | Current source location and hints source |
| `PL_defgv` pointer | Context record | `defgv` slot | Pointer alone is insufficient for `$_`/`@_` |
| `$_` payload | Generator-owned SV, exchanged with the active GV | `defsv` | Coro swaps SV heads to preserve object identity |
| `@_` payload | Generator-owned AV, exchanged with the active GV | `defav` | Coro explicitly saves the default argument AV |
| `$@` payload | Not isolated | `errsv` | Backed by `GvSV(PL_errgv)` |
| `$/` | Not isolated | `irsgv` | Coro saves the GV-backed input record separator |
| Hints | Not isolated | `hinthv` | Coro treats the hints hash as coroutine-local |
| Default output GV | Not isolated | `defoutgv` | Environment-sensitive output behavior |
| Regex state | `curpm` and related context fields | `curpm` | Current generator coverage is narrower in surrounding state |
| Sort state | Not isolated | `sortcop`, `sortstash` | Needed for callbacks and sort execution |
| Die/warn hooks | Not isolated | `diehook`, `warnhook` | Important for independent task behavior |
| Evaluation flags | `in_eval`, `localizing` | `in_eval`, `localizing` | Fresh `JMPENV` still needed for each run |
| Compilation state | `comppad`; other fields remain global | `compcv`, `comppad`, pad names/floors | More relevant to general coroutine switching |
| Runops/parser/hints machinery | Mostly not isolated | `runops`, `parser`, `hints` | Coro supports its own execution/tracing requirements |

Coro also walks active context frames and records CV pad-list/depth details.
That is separate from simply copying the interpreter slots: the active
subroutine contexts contain ownership and cleanup information which must remain
consistent with the copied stacks.

## Why Coro has more state

Coro is a general cooperative task-switching system. A task may be suspended
while arbitrary Perl code is active and later resumed alongside unrelated Perl
tasks. To make that model useful, Coro seals or swaps values that would
otherwise be visible through shared interpreter globals. Its SV-swapping API
also lets applications explicitly designate additional SVs whose contents
should follow a coroutine.

A generator has a stronger protocol guarantee: it runs along a deterministic
single continuation, and suspension occurs only at its explicit yield points.
That makes it reasonable to begin with a smaller environment boundary. It does
not make shared values automatically safe; the caller can still change a
shared variable between two resumes, as the pre-fix tests for `$_` and `@_`
demonstrated.

The distinction is therefore semantic, not merely performance-related:

* **Generator:** one-shot, explicitly resumed continuation; swap execution
  state and only those environment values defined as generator-local.
* **Coroutine/task:** independently scheduled execution context; likely swap
  execution state plus a larger environment record and possibly native C
  context state.

## Recommendations

1. Keep the generated `PERL_EXECUTION_CONTEXT` as the execution-state layer.
   Continue deriving it from `intrpvar.h` so threaded and unthreaded builds
   use the same declarations and `embedvar.h` remains the access layer.
2. Treat GV-backed payloads as a separate audit category. A context-local GV
   pointer does not imply context-local `SV`, `AV`, or `HV` contents.
3. Keep `JMPENV` out of heap-resident state. Establish exception boundaries at
   each run/resume, as the generator currently does.
4. For future coroutine support, introduce an explicit environment record or
   payload-swap table rather than silently expanding generator semantics for
   every interpreter variable.
5. Audit variables by observable semantics: whether a value changed inside a
   suspended computation should be visible to the caller, whether caller
   changes should be visible on resume, and whether `local` already provides
   the required dynamic extent.
6. Use Coro as implementation prior art for difficult cases—especially SV
   head swapping, pad/CV-depth preservation, stack ownership, and cleanup—but
   verify every assumption against current core internals.

## Open questions for the next audit

The next environment audit should cover `$@`, `$/`, `$,`, `\`, `$;`, `$|`,
`$^H`, die/warn hooks, default output, regex state, sort state, and signal or
locale-related interpreter values. Each should be classified as:

* generator-local;
* dynamically inherited at the beginning of a generator phase;
* shared intentionally; or
* coroutine-only state outside the initial generator contract.

Tests should establish the desired behavior before any additional state is
moved into the generator record.
