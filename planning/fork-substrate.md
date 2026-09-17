# Fork substrate and cooperative process supervision

## Purpose

The low-level `fork` primitive is widely used by existing Perl modules. A new
fork manager should therefore be able to cooperate with other managers rather
than maintaining an isolated PID table. The preferred architecture is to put
process tracking underneath the manager layer, in the Perl core, while keeping
the existing observable `fork` API unchanged.

## Layering

    OS process creation and reaping
             |
    core child-process records and lifecycle updates
             |
    Fork::Supervisor, other fork managers, and application policy

`fork` and `fork_child` should use the same internal process record. A raw
`fork` would create a minimal record and still return the normal integer PID.
`fork_child` would enrich the same record with its callback, timeout, pool, and
other supervisor-specific metadata, and could expose it as a `Fork::Process`
object.

## Core record

The internal record should contain, as appropriate:

- child PID and creating/parent PID;
- start time and lifecycle state;
- exit status, terminating signal, and core-dump information;
- reaped or externally-reaped state;
- optional manager-owned metadata.

The record need not initially be a Perl object. A compact core record avoids
allocation and destruction effects for programs that only use ordinary `fork`.
An object can be created lazily when a manager or caller requests one.

## Fork and wait hooks

At the lowest practical level:

- `pp_fork` registers the child in the parent without changing the return
  values or error behavior of `fork`;
- the child resets its active view of inherited running-child records before
  continuing;
- `pp_wait` and `pp_waitpid` update the record whenever they reap a registered
  child;
- `WNOHANG` leaves a live record pending when no child has exited;
- `waitpid(-1, ...)` updates whichever registered child the kernel returns;
- failed or externally reaped children receive an explicit state rather than
  being silently treated as normally completed.

The child-side reset is important because `fork` gives the child a copy-on-
write snapshot of the parent's memory. A child must not try to wait for the
parent's children merely because it inherited their records. If the child
later forks, its new records belong to the child and are kept in its own view.

## Public registry considerations

`@{^FORK_POOL}` is attractive as a conventional process-global registry because
caret variables are forced into `main`. It should nevertheless be treated as a
view or query interface unless its mutation semantics are carefully specified.
User code can otherwise delete or replace records and make independent
managers disagree about ownership.

An alternative is `%{^RUNNING_FORKS}` keyed by child PID, with each record
retaining `owner_pid`. A nested owner/child map makes ownership explicit. The
internal core registry should remain authoritative either way.

The child reset can make a single active pool work naturally for nested
`fork_child` calls. The existing `owner_pid` remains useful as destructor
protection: releasing inherited records in a child must never make their
destructors wait for the parent's children.

## Compatibility constraints

Raw `fork` must preserve:

- its current return values and zero-argument behavior;
- compile-time diagnostics for invalid calls;
- signal and failure behavior;
- behavior of existing modules which wrap or override it.

The core should not make `fork` return a `Fork::Process` object. That would be
a major compatibility break. Instead, provide internal lookup/adoption APIs so
modules can obtain or enrich the record associated with an existing PID.

Wait interception cannot observe every possible reaping path. XS code and
external libraries may call the operating system directly, so the registry
must represent status-unavailable or externally-reaped cases. It must not
assume every child is observed through Perl's `wait` functions.

Threaded builds, pseudo-fork platforms, `vfork`, and at-fork locking also need
explicit review. Registry updates must occur through the existing Perl at-fork
and interpreter lifecycle machinery.

## Fork::Supervisor integration

Once the substrate is stable, `Fork::Supervisor` should become a policy layer:

- core supplies child records and wait synchronization;
- `fork_child` attaches callback and timeout policy;
- `wait_for_children` selects children owned by the current process;
- `Fork::Process` wraps a core record;
- `do_parallel` remains a convenience API;
- other managers can adopt or observe the same records.

The first bundled implementation should remain pure Perl. XS is not needed
until profiling identifies overhead in the policy layer or record access.

## Staged implementation plan

1. Define the internal record and registry without changing `fork` behavior.
2. Register ordinary `fork` children and reset inherited state in the child.
3. Update records from core `wait` and `waitpid` paths.
4. Add lookup and adoption APIs for supervisor modules.
5. Refactor `Fork::Supervisor` to consume the common records.
6. Add comprehensive tests for nested forks, signals, timeouts, external
   reaping, threads, and fork-disabled platforms.
7. Expose a documented public running-forks view only after the internal
   semantics are stable.

## Non-goals for the first version

- changing raw `fork` to accept callback arguments;
- changing raw `fork`'s return type;
- requiring all XS modules to use the new registry;
- guaranteeing visibility of a child's descendants in its parent after a
  normal OS `fork`;
- replacing application-level IPC with shared in-memory state.
