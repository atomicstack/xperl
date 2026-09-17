# Perl function-call profiling

This note records a small, reproducible investigation of Perl subroutine-call
cost.  Measurements were made on 2026-09-12 on x86-64 Linux.  The main build
was a non-threaded, non-`DEBUGGING` perl configured with `-O3` and frame
pointers.  A separate blead tree was built with the same options.

## Workloads

The permanent Cachegrind cases are in `t/perf/benchmarks`.  They distinguish:

* an empty direct, qualified, and coderef call;
* constant and temporary arguments;
* manual `@_` unpacking and signatures;
* a direct call with an invocant, object-method lookup, and class-method
  lookup;
* resuming a generator which immediately yields.

`planning/scripts/call-profile.pl` supplies long-running, one-workload-per-
process loops for hardware counters and sampling.  It also has an `amp`
control: bare `&direct_empty` reuses the caller's `@_`, so the callee's context
does not have `CXp_HASARGS` and does not install and clear a new `@_`.

Run the deterministic instruction-count suite from the repository root with:

```sh
./perl -Ilib Porting/bench.pl \
  --tests='/^call::(sub::(empty|qualified_empty|coderef_empty|args3_unused|args3_temps_unused|args3|signature_empty|signature_args3)|method::(direct_empty|object_empty|class_empty))$/' \
  --show --raw --fields=Ir,Dr,Dw,COND,IND -- ./perl=prod
```

Run hardware counters and sampling with:

```sh
perf stat -r 3 \
  -e cycles:u,instructions:u,branches:u,branch-misses:u \
  -- ./perl -Ilib planning/scripts/call-profile.pl empty 50000000

perf record -F 999 -e cycles:u -g --call-graph fp \
  -o ../tmp/call-profiles/prod-fp-empty.perf.data -- \
  ./perl -Ilib planning/scripts/call-profile.pl empty 100000000

perf report --stdio --no-children --sort=symbol \
  -i ../tmp/call-profiles/prod-fp-empty.perf.data
perf annotate --stdio --no-source --symbol Perl_pp_entersub \
  -i ../tmp/call-profiles/prod-fp-empty.perf.data
```

Measure `baseline` with the same iteration count and subtract it from the
selected workload before dividing by the iteration count.  The `generator`
workload is also available for hardware measurement of repeated context
switches.

## Deterministic results

The following are Cachegrind instructions per benchmark iteration.  All
columns use non-threaded, non-`DEBUGGING`, `-O3 -fno-omit-frame-pointer`
builds.  `pointer` is commit `8f28d1a71c21` before the change described below,
`inline` is the same tree with the active context embedded, and blead is
`ebfe444c32fa`.

| Workload | pointer | inline | blead | inline - pointer |
| --- | ---: | ---: | ---: | ---: |
| empty direct call | 402 | 383 | 359 | -19 |
| qualified empty call | 402 | 383 | 359 | -19 |
| coderef empty call | 398 | 380 | 357 | -18 |
| three constant args, unused | 545 | 511 | 472 | -34 |
| three temporary args, unused | 1,377 | 1,309 | 1,245 | -68 |
| three args, manual lexical unpack | 1,423 | 1,359 | 1,288 | -64 |
| empty signature | 513 | 489 | 457 | -24 |
| three signature parameters | 1,412 | 1,340 | 1,291 | -72 |
| direct call with invocant | 485 | 460 | 432 | -25 |
| object method | 675 | 649 | 622 | -26 |
| class method | 821 | 794 | 766 | -27 |
| bare `&sub` / reuse `@_` | 358 | 339 | 315 | -19 |

The raw paired runs are in `../tmp/call-bench-prod-v-blead.json`,
`../tmp/call-bench-inline-v-pointer.json`, and
`../tmp/call-bench-inline-v-blead.json`.

Some useful controlled differences are more stable than the absolute totals:

* Constructing a fresh empty `@_` costs 44 instructions on both branches:
  normal empty call minus bare `&sub`.
* Object-method lookup costs 190 instructions on both branches: object method
  minus a direct call with the same invocant.
* Class-name dispatch adds another 144--146 instructions.
* A signature is not an entry fast path.  Even an empty signature adds about
  100 instructions over an ordinary empty body, and three-parameter signature
  binding is about as expensive as manual lexical unpacking.
* Temporary expressions dwarf call dispatch.  They require value operations
  and mortal handling, so they should not be used as a proxy for the fixed
  call cost.

### Separating `@_` from the rest of the frame

A one-million-call Cachegrind run on the final split-runloop build gives a
more precise decomposition.  Bare `&f` reuses the caller's `@_` and therefore
does not set `CXp_HASARGS`; an ordinary `f()` installs the callee's reusable
pad-zero AV even when there are no arguments.

| Hot function | bare `&f` | ordinary `f()` | cost of `@_` |
| --- | ---: | ---: | ---: |
| `Perl_pp_entersub` instructions | 162 | 180 | 18 |
| `Perl_pp_entersub` reads / writes | 66 / 31 | 74 / 34 | 8 / 3 |
| `Perl_pp_leavesub` instructions | 63 | 89 | 26 |
| `Perl_pp_leavesub` reads / writes | 30 / 14 | 42 / 18 | 12 / 4 |
| entry plus exit instructions | 225 | 269 | 44 |
| entry plus exit reads / writes | 96 / 45 | 116 / 52 | 20 / 7 |

This is AV bookkeeping rather than a heap allocation on every call.  Each
CV's pad contains a reusable argument AV.  Entry saves the previous global
`@_`, installs the callee AV, and establishes its fill and element pointers;
exit restores the previous AV and either clears the callee AV cheaply or
abandons it if magic, reification, or an escaped reference requires that.

The `pp_entersub` instruction count for unused constant arguments is 180,
198, 209, 220, 231, and 275 for zero, one, two, three, four, and eight
arguments respectively.  `pp_leavesub` remains at 89 instructions.  Thus the
first argument adds 18 entry instructions and each subsequent argument adds
11 on this build.  For three arguments, entry also adds nine reads and five
writes.  The slope includes both copying `SV *` slots into the argument AV
and scanning arguments to keep PADTMP/temporary values alive; removing only
the pointer `Copy()` will not remove most of it.

The no-new-`@_` control still spends 225 instructions in `pp_entersub` plus
`pp_leavesub`, and about 319 instructions on the complete empty-call
benchmark.  Consequently an `@_` optimization has a measured upper bound of
44 instructions (about 12% of this empty call) unless it also simplifies the
general activation record.  Hardware counters put the same difference at
about 20 cycles per call, 132 versus 112 cycles for the normal and no-new-`@_`
paths in that run.

Signatures currently pay for both representations: ordinary entry first
builds `@_`, then `pp_multiparam` fetches from that AV and copies values into
pad lexicals.  For a three-parameter signature, flat Cachegrind attribution
per call includes 164 instructions in `pp_multiparam`, 105 in `av_fetch`, and
192 in `sv_setsv_flags`; even an empty signature executes 64 instructions in
`pp_multiparam`.  This makes direct signature binding from the incoming
argument vector the best-supported parameter-specific experiment.  It can
avoid the AV fetch round trip, but eliminating `@_` setup as well requires an
explicit semantic contract or a correct lazy-materialization mechanism.

Static absence of an `@_` op in a CV is not by itself such a contract.  String
`eval`, bare `&sub`, `goto &sub`, debugger/`caller` support, and XS code which
accesses `GvAV(PL_defgv)` can observe or propagate the current argument AV.
A semantics-preserving lazy scheme therefore needs a frame-owned argument
descriptor plus audited materialization/deoptimization points; it cannot
safely retain a raw pointer above the value-stack pointer because stack
growth, cleanup, magic, and re-entry can invalidate or overwrite it.

For the remaining frame cost, the next useful controlled experiment is a
compact sub-frame snapshot, not merely shrinking the `PERL_CONTEXT` union.
`cx_pushblock` and `cx_pushsub` save return context and watermarks for the
value, mark, save, scope, temporary and pad state, while `cx_popsub` and
`cx_popblock` restore them.  Grouping the subset that is captured/restored
together may let the compiler use fewer loads and stores, as long as unwind,
`caller`, debugger, lvalue, recursion, regex-capture, magic and exception
semantics remain unchanged.  Patch variants which omit individual fields are
needed to attribute the 225-instruction no-`@_` entry/exit cost; the current
profiles do not justify claiming that the physical context-slot size itself
is responsible.

### Classical argument unpacking

A DWARF-enabled follow-up used a cleaner pair of one-million-call workloads
which differed only in the callee body:

```perl
sub f { }                       # control
sub f { my ($a, $b, $c) = @_ } # measured form
```

Both were called as `f(1, 2, 3)`.  Adding the classical unpack costs 792
instructions, 200 reads, 106 writes, 129 conditional branches, and three
indirect branches per call on this branch.  The corresponding blead costs are
777 instructions, 198 reads, 102 writes, 129 conditional branches, and three
indirect branches.

Flat source attribution for the 792 current-branch instructions is dominated
by:

| Function | Instructions per call |
| --- | ---: |
| `Perl_pp_aassign` | 244 |
| `Perl_pp_padrange` | 133 |
| `S_pushav` | 73 |
| `Perl_sv_setsv_flags` | 186 |
| `Perl_leave_scope` | 131 |

These account for 767 of the 792 instructions.  The compiler already marks
this exact `my (...) = @_` form by setting `OPf_SPECIAL` on `pp_padrange`.
That op currently pushes all of `@_` as a synthetic RHS, pushes the pad
lexicals as a synthetic LHS, and hands both lists to the fully general
`pp_aassign` implementation.  A fused classical-argument-unpack path can
instead copy the selected argument slots directly into the pad lexicals while
leaving the real `@_` installed and observable.  It therefore does not require
escape analysis for later `\@_`, shifting, mutation, debugger use, or XS
access.  It must retain ordinary scalar-assignment magic, alias/commonality,
save-stack, exception, and reference-counted-stack semantics.

## Hardware-counter results

For 50 million iterations, after subtracting the loop-only workload:

| Empty call | instructions/call | cycles/call | branches/call |
| --- | ---: | ---: | ---: |
| pointer context | 390.0 | 131.7 | 53.0 |
| inline context | 371.0 | 119.8 | not remeasured |
| blead | 347.0 | 106.2 | 49.0 |

The pointer-based branch adds 43 instructions (12.4%) and about 25.5 cycles
(24%) to the incremental empty-call cost.  Embedding the active context
recovers exactly 19 of those instructions and roughly 12 cycles in this run.
The instruction result is deterministic; the cycle result should be treated
as approximate.  Branch misses are effectively absent: the pointer-context
empty workload produced only about 7,500 more misses than its baseline over
50 million calls.  The incremental code runs at roughly three retired
instructions per cycle.  This is predictable bookkeeping, not cache or
branch-predictor failure.

The `@_` control on the pointer build costs about 346 instructions and 112
cycles per call, versus 390 instructions and 132 cycles for a normal empty
call.  Avoiding new `@_` setup therefore helps, but leaves most of the fixed
call machinery.

## Where the cycles go

The empty pointer-build sample attributes 33.4% of all cycles to
`Perl_pp_entersub` and 15.9% to `Perl_pp_leavesub`.  The equivalent blead
sample reports 34.9% and 16.0%.  About half of the whole tight loop is
therefore entry and exit on both branches; the rest includes the loop ops and
dispatch.

The hot path in `pp_hot.c` and the inlined helpers in `inline.h` perform:

1. CV validation and special-case checks (autoloading, debugger, lvalue,
   recursion and XSUB paths must remain possible);
2. creation of a `PERL_CONTEXT`, saving stack, mark, scope, temporary, context,
   return-op, CV-depth, pad and current-COP state;
3. pad-depth selection and switching `PL_comppad`/`PL_curpad`;
4. swapping in the callee's pad-zero AV as `@_`, copying argument pointers,
   and recording the previous `@_`;
5. on return, result-stack adjustment, save-scope unwinding, clearing or
   abandoning the callee's `@_`, restoring the pad/CV/context state, and
   popping the context.

Assembly sampling puts visible weight on pad selection and on the `@_` swap in
`pp_entersub`.  In `pp_leavesub`, the `cx_popsub_args` path checks whether the
argument AV is simple enough to clear in place, then clears/restores it before
the common pad and CV restoration.  Exact instruction-level percentages
should not be over-interpreted because sampled PMU events skid; the function-
level result and deterministic counts are the stronger evidence.

Signatures currently go through the same initial `@_` installation.  Their
body then runs `pp_multiparam`, whose sampled callees include `av_fetch`,
`sv_setsv_flags`, and save-stack cleanup.  A profitable experiment would be a
guarded signature/no-`@_` fast path that binds directly from the argument
stack when observable Perl semantics permit it.

For object calls, `pp_method_named` plus its `Perl_hv_common` child account for
about 24% of the sampled method workload.  This corresponds to the cached
stash hash lookup in `METHOD_CHECK_CACHE`; it is separate from the ordinary
`pp_entersub` cost.

## Inline active-context experiment

This branch had moved many of the hottest interpreter globals behind a
pointer-valued `PL_execution_context`.  Fields such as `PL_op`, `PL_stack_sp`,
`PL_stack_base`, `PL_curstackinfo`, `PL_comppad`, `PL_curpad`, and the
save/scope/mark stacks therefore acquired an extra load on ordinary accesses.

The implementation now embeds the active `PERL_EXECUTION_CONTEXT` directly in
the interpreter (or in the global state for a non-multiplicity build), while
retaining the grouped structure.  Generated `PL_*` accessors use a direct
member expression.  Suspended `PERL_PROCESS_STATE` objects contain the same
structure and save/restore it with a C structure assignment.  This preserves
the organizational and self-documenting value of the execution-context
record without taxing every ordinary interpreter-state access.

For an empty call, this changes 402 instructions and 178 data accesses to 383
instructions and 158 data accesses.  It recovers 19 of the 43 instructions in
the pointer build's regression relative to blead.  The remaining 24
instructions include five conditional branches and are not explained by the
context pointer.

The cost moves to actual context switches.  On this build the record is 224
bytes, and GCC lowers one structure assignment to 14 unaligned vector loads
and 14 vector stores rather than an out-of-line `memcpy`.  A normal suspended
generator resume/yield performs four such copies: save caller, restore
generator, save generator, restore caller.  The deterministic immediate-yield
benchmark initially rose from 2,158 to 2,260 instructions per yield (+102),
with 39 more reads, 109 more writes, and 56 more conditional branches.  Direct
suspension from an owning-stack `yield`, described below, reduces the inline
result slightly to 2,254 instructions.  In the generic
round-robin scheduler, saving at every opcode boundary would have made this
far worse, so the scheduler now copies only when `PL_runops` actually returns
to switch processes.

This is the intended trade: ordinary Perl calls and ops become cheaper, while
the uncommon operation of suspending or resuming an execution context pays
for an explicit, auditable snapshot.  If context switching later becomes a
dominant workload, the next experiment should be dirty tracking or separating
the frequently changed continuation fields from colder state—not restoring
the pointer on every hot access.

## Remaining runops-boundary cost

After embedding the active context, an empty call remains 24 instructions and
five conditional branches above blead.  Differential Cachegrind profiles over
one million calls attribute that gap exactly:

| Function | inline | blead | difference per call |
| --- | ---: | ---: | ---: |
| `Perl_runops_standard` | 40 | 20 | +20 |
| `Perl_pp_entersub` | 180 | 178 | +2 |
| `Perl_pp_leavesub` | 89 | 88 | +1 |
| `Perl_pp_gv` | 20 | 19 | +1 |

The 20 instructions in `Perl_runops_standard` are the inactive
`PL_runops_boundary_hook` check.  The empty-call optree dispatches five ops;
each dispatch pays four instructions and one predictable conditional branch
even though the hook is null.  The check was introduced by commit
`009b29bb18a73004ddbe8904a66486c4d6f7f46c` (`add a generator syntax`,
2026-08-28).

This effect is not call-specific.  Eight existing `loop::*` benchmarks have
between three and 29 op dispatches per iteration.  Their instruction gaps are
13, 23, 35, 59, 29, 86, 55, and 105 respectively.  Subtracting four
instructions per dispatch leaves +1, +3, +3, +3, +1, +2, -5, and -11.  Their
conditional-branch gaps similarly follow one branch per dispatch.

The implementation now has two runops paths.  `Perl_runops_standard` contains
only the original fast dispatch loop; generator resumes call a private
boundary-aware loop explicitly, and the experimental scheduler temporarily
selects that loop as `PL_runops` so nested runops invocations remain
preemptible.  Keeping the functions structurally separate matters: an initial
version selected the boundary loop with a branch inside
`Perl_runops_standard`, but GCC inlined both loops and introduced an extra
register move on every fast dispatch.

After the structural split, the empty-call benchmark is 363 instructions
versus blead's 359, down from 383 before the split.  Conditional and indirect
branch counts are now identical to blead.  Existing loop benchmarks likewise
retain only small aggregate-layout/code-generation differences: block +1,
`do` +3, `for next4` +2, one-iteration `while` +3, and four-iteration `while`
+5 instructions.  The raw paired call results are in
`../tmp/call-bench-split-v-blead.json`.

`pp_yield` also attempts suspension directly after removing its operands.  It
uses the same owning-`PL_curstackinfo` identity check as the old boundary
callback, and publishes the continuation op before saving process state.  If
the yield is reached from a nested runops invocation, it remains pending until
the boundary-aware owning loop regains control; a regression test using a
Perl sort callback verifies that the active C sort operation completes before
suspension.  Immediate-yield cost is 2,254 instructions, six fewer than the
boundary-only inline implementation.  Raw data are in
`../tmp/generator-yield-direct.json`.

The other four empty-call instructions are compiler code-generation changes,
not source changes: `pp_hot.c` is byte-identical between these two builds.  For
example, grouping the globals in one structure makes this GCC build reload
`PL_op` in `pp_gv`, where the separate-global blead build retains it in a
register.  This made member layout worth testing after the per-op hook tax was
removed.

Reordering only the execution-context members puts the ordinary call working
set at the front of the record: stack pointer, current op and pad, stack base,
stack-info pointer, compilation pad, default glob, and current COP occupy the
first 64 bytes.  Mark-stack, current-match, temporary-stack, save/scope indices,
and small execution flags follow.  Capacity pointers and less common state are
last.  The record remains 224 bytes, so context-copy cost is unchanged.

Paired Cachegrind runs against an otherwise identical pre-layout build show
exactly two fewer instructions and two fewer data reads for every non-recursive
call workload, with no change in writes or branch counts.  A recursive workload
executes two calls per iteration and saves four of each.  Flat attribution puts
one saved instruction/read in `Perl_pp_entersub` and one in
`Perl_pp_leavesub`.  In the latter, for example, GCC can retain the now-nearby
`PL_curstackinfo` value instead of reloading it before updating `si_cxsubix`.
This is a code-generation/register-retention gain in an L1-hot benchmark, not
evidence of fewer hardware cache misses.

The empty-call count is consequently 361 instructions versus blead's 359.
Classical three-argument unpack is 1,309 versus 1,288, while a three-argument
signature is 1,294 versus 1,291.  Thus layout recovers half of the residual
empty-call aggregate cost, but it does not explain or cure the remaining
classical-argument-unpack gap.  Representative arithmetic, aggregate, and loop
benchmarks did not regress.

The original 43-instruction empty-call regression can consequently be divided
into 19 instructions from the execution-context pointer, 20 from the inactive
boundary-hook check, and four from residual aggregate-layout code generation.
The member-order experiment recovers two of those final four instructions.

## Interpretation

The data do not support the claim that Perl's original author did not
understand call stacks.  They show an expensive interpreter call protocol
that preserves unusually broad dynamic semantics, plus a measurable new
regression in this development branch.  The criticism worth retaining is
more precise: Perl has no sufficiently cheap leaf-call path, and indirection
in very hot state access has a large multiplicative cost.

Likely next experiments, in order of evidential support, are:

1. keep the active execution context inline and measure the context-switch
   tradeoff on real generator workloads;
2. fuse the compiler-recognized classical `my (...) = @_` unpack without
   removing or virtualizing `@_`;
3. replace general `av_fetch` calls on the fresh signature argument AV with
   safe direct indexing, then bind eligible signature parameters directly
   from the incoming argument stack;
4. consider omitting `@_` only for signatures with an explicit semantic
   contract; a general lazy argument AV is not justified by the fixed
   44-instruction saving alone;
5. investigate a smaller leaf-call frame only after defining exactly which
   `caller`, `wantarray`, debugger, magic, lvalue, recursion, `local`, `eval`,
   `goto &sub`, and exception semantics it may omit;
6. treat method-cache lookup as a separate optimization problem.

## Profiling build

Both the branch and blead trees were subsequently rebuilt as non-threaded,
non-multiplicity, non-`DEBUGGING` perls with `-O3`, frame pointers, and DWARF.
Their reported architecture, compiler flags, optimizer flags, and threading
settings match, and both contain `.debug_info` and `.debug_line` sections.
This configuration supports production-like deterministic benchmarking,
frame-pointer `perf` call graphs, and Cachegrind source-line annotation.

Perl's `Configure` deliberately removes a literal `-g` from `optimize` when
`DEBUGGING` is explicitly undefined.  Append it to `ccflags` after hints have
run instead:

```sh
CCACHE_DIR=/home/demerphq/git_tree/perldev/.ccache \
./Configure -des \
  -Dusedevel \
  -Uusethreads \
  -Uusemultiplicity \
  -UDEBUGGING \
  -Darchname=x86_64-linux \
  -Dcc='ccache gcc' \
  -Dccflags='-fwrapv -fno-strict-aliasing -pipe -fstack-protector-strong -I/usr/local/include -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64' \
  -Doptimize='-O3 -fno-omit-frame-pointer' \
  -A ccflags=-g

CCACHE_DIR=/home/demerphq/git_tree/perldev/.ccache make -j8 perl
```

Verify the result with `./perl -Ilib -V:optimize -V:ccflags` and
`readelf -S ./perl`; `.debug_info` and `.debug_line` should be present, while
the C preprocessor macro `DEBUGGING` remains disabled.
