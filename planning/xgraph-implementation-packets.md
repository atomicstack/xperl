# XGraph implementation packets

## Purpose

This file converts `planning/xgraph.md` into small implementation assignments
which can be executed by a cost-sensitive coding model without asking it to
redesign the module.  The canonical plan remains authoritative.  This file
controls task boundaries and handoff discipline.

Do not assign “implement XGraph” as one task.  Assign exactly one packet, or
one explicitly named sub-packet, at a time.

## Agent operating rules

Every implementation assignment must include these rules:

1. Read the applicable workspace/repository instructions and skills, the
   canonical plan, and this packet completely before editing.  For standalone
   Packets 00 through 13, work in `../XGraph` and read the plans from
   `../perl/planning/`.  For Packets 14 through 16, work in the Perl repository
   and read them from `planning/`.
2. Treat the normative version-one decisions and baseline API as fixed.
3. Do not add convenience APIs, aliases, overloads, handle classes, payloads,
   edge IDs, serialization, iterators, or core changes unless the assigned
   packet explicitly requires them.
4. Do not make scalar/list context change an API's meaning.
5. Keep compact and wide entry logic behind the named representation helpers.
6. Add or update focused tests in the same packet as behavior.
7. Run the packet's focused validation before broader tests.
8. Preserve unrelated worktree changes and do not reformat unrelated files.
9. If a stop condition occurs, report the exact evidence and stop.  Do not
   invent a replacement contract.
10. Use high or xhigh reasoning for XS ownership, mutation, algorithms, or
    debugging packets.

## Global stop conditions

The agent must stop and report rather than improvise when:

- `planning/xgraph.md` and this file specify different public behavior;
- the assigned packet requires changing a Perl core C file or exported API,
  except for the final explicitly approved core-import packet;
- the minimum `XError` construction/throw contract required by the packet is
  absent;
- an API result or error condition is not specified;
- a required edit overlaps unrelated user changes which cannot be preserved;
- a compact/wide behavioral difference appears;
- transactional mutation cannot be implemented without partial publication;
- an ownership path has no clear single owner or paired free operation;
- ithread work would depart from the fixed frozen-store ownership design;
  or
- passing a test would require weakening an invariant or deleting coverage.

Unavailable optional platform or sanitizer infrastructure is not by itself a
reason to redesign code.  Record the unrun validation for later execution.

## Fixed standalone source layout

Development begins in the existing workspace sibling repository `../XGraph`,
not under Perl's `dist/` directory.  It currently contains a committed
h2xs-style skeleton.  Packet 01 adopts that skeleton and extends it to this
repository-root layout:

```text
Changes
Makefile.PL
MANIFEST
README
XGraph.xs
xgraph.h
xgraph.c
lib/XGraph.pm
ppport.h
t/00-load.t
t/10-contract.t
t/20-vertices.t
t/30-labels.t
t/40-edges.t
t/50-adjacency.t
t/60-paths.t
t/70-components.t
t/80-transformations.t
t/90-errors-magic.t
t/91-clone.t
t/92-threads.t
t/95-randomized.t
t/lib/XGraph/Reference.pm
```

`xgraph.h` contains private types, constants, assertions, and function
declarations.  `xgraph.c` contains storage and algorithm helpers.
`XGraph.xs` performs argument normalization, Perl/native conversion, and thin
method dispatch.  Do not place substantial algorithms directly in XS glue.

Packet 01 replaces or divides the existing stub `t/XGraph.t` into the focused
test files above.  Generated MakeMaker files remain ignored and are not source.

The standalone distribution is authoritative until the final import packet.
That packet must choose either a one-time permanent move or a documented
upstream snapshot process.  It must not leave two writable authoritative
copies.

## Fixed internal vocabulary

Use these concepts consistently:

```text
vertex ID       graph-assigned numeric identity
vertex name     optional unique normalized Perl string
label           undef, empty, or registered relationship string
label ID        private graph-local numeric encoding
edge tuple      (from vertex ID, to vertex ID, label ID)
entry           packed (neighbor vertex ID, label ID)
topology gen    changes when vertices or edges change
naming gen      changes when vertex names or label registry changes
```

Do not call a vertex name a payload or use “edge ID” for an edge tuple.

## Packet 00: prerequisite audit

### Objective

Verify that implementation prerequisites exist without modifying source.

### Required checks

- Confirm `../XGraph` is the selected standalone repository, record its branch,
  initial revision, tracked skeleton, ignored build products, and worktree
  status.
- Confirm the supported Perl versions and the available C dialect and
  fixed-width integer facilities.
- Confirm that all pre-import errors can route through one private factory,
  whether or not the target Perl already supplies `XError`.
- Record how a later `dist/XGraph` import is registered and built in Perl core,
  without making that import now.
- Locate nearby XS distributions using extension magic, private `.c/.h`
  helpers, `CLONE_SKIP`, and DEBUGGING-only invariant functions.
- Record the exact focused and broad standalone test commands.

### Deliverable

A short audit note in the implementation handoff.  Do not edit XGraph files.

### Stop conditions

Stop if the private error-factory seam cannot represent the fixed error codes
without committing to a conflicting public exception representation.

## Packet 01: distribution skeleton and contract fixtures

### Prerequisites

- Packet 00 complete.
- Public API tables in `planning/xgraph.md` unchanged.

### Scope

Normalize the existing h2xs-style skeleton, add the load test and private
reference-model location, and add table-driven contract fixtures.  Public
methods may initially report a single “not implemented” condition through the
private error factory.

### Required results

- `use XGraph` succeeds from the build tree.
- The constructor recognizes only `acyclic` and `strict_labels`.
- Unknown constructor options are represented in contract fixtures.
- Every normative public method has at least one named fixture describing its
  arguments, result shape, and expected error code.
- No native graph storage is implemented yet.

### Forbidden scope

- No algorithm implementation.
- No iterator API.
- No Perl core edits or `dist/XGraph` import.
- No public error contract invented in the absence of `XError`.

### Validation

Run `t/00-load.t` and the contract-fixture test directly with the built Perl.

## Packet 02: pure-Perl reference model

### Objective

Implement the complete normative behavior in
`t/lib/XGraph/Reference.pm`, using ordinary Perl arrays and hashes without
performance optimization.

### Required semantics

- IDs start at 1, never reuse, and fail at the configured test limit.
- Anonymous versus empty-name behavior follows the canonical plan.
- Name and label normalization fetches magic once and rejects references.
- Strict and loose labels, reserved IDs, duplicate names, duplicate edge
  tuples, acyclicity, rename, and deletion follow the normative rules.
- Public edge results expose labels, never label IDs.
- All algorithm results use vertex IDs and the specified result shapes.
- Condensation returns `{ graph, components, component_of }`.
- `freeze`, frozen mutation rejection, `clone`, and `mutable_copy` follow the
  fixed state-preservation rules.  Derived subgraphs and condensations are
  mutable.

### Required tests

- Empty, singleton, looped, parallel-label, disconnected, cyclic, and DAG
  fixtures.
- Every public success, absence, and failure shape.
- Byte/UTF-8 and numeric/string HV-key behavior recorded from Perl itself.
- Random small operation sequences and invariant checks.

### Stop conditions

Stop if any public behavior needed by the reference model is absent from the
canonical plan.  Do not settle it inside the model.

### Exit criterion

The reference suite is internally consistent and no XS file is needed to run
it.

## Packet 03: representation helpers

### Objective

Implement and test compact and wide entry encoding without graph mutation.

### Fixed interface responsibilities

Private helpers must cover:

- representation maximum vertex and label IDs;
- checked `encode(vertex,label)`;
- `entry_vertex(entry)` and `entry_label(entry)`;
- unsigned entry comparison;
- lower and upper bounds for one neighbor's label range;
- overflow-checked adjacency allocation size; and
- count/capacity growth using 32-bit fields.

### Configuration

Use one compile-time macro selected by the distribution build for tests:

```text
compact: xg_adj_entry_t is uint32_t with 24/8 fields
wide:    xg_adj_entry_t is uint64_t with 32/32 fields
```

Do not make this a public run-time option.

### Required tests

- Zero and maximum boundaries.
- Reserved and maximum label IDs.
- Round trips.
- Numeric ordering equal to `(vertex,label)` ordering.
- Neighbor range behavior at minimum and maximum IDs.
- The valid compact value `UINT32_MAX` is not treated as a sentinel.
- Allocation overflow rejection.
- Identical logical results in compact and wide test builds.

### Forbidden scope

No graph object, Perl maps, edges, or algorithms.

## Packet 04: graph owner and vertex slots

### Objective

Implement the opaque graph object, constructor, destructor, vertex-slot
growth, anonymous vertex creation, deletion tombstones, counts, and explicit
`clone` without names or edges.

### Fixed ownership

- Blessed scalar referent with extension magic.
- Magic pointer exclusively owns an interpreter-local `xg_graph` handle.
- The handle owns the four initially empty AV/HV containers and one
  `xg_store` reference.
- `xg_store` owns vertex slots, adjacency, native counts, generations, and no
  `SV *` values.
- All store allocation and release goes through private helpers so the XPerl
  import packet can substitute shared allocation and thread-safe retention
  without changing algorithms.
- `vertices[0]` is invalid.
- Newly grown records are zeroed.
- The free hook detaches its pointer before freeing children.
- Partial construction uses the same idempotent cleanup path.
- Standalone code supplies `CLONE_SKIP`; do not implement magic duplication or
  ithread sharing here.

### Required behavior

- `new`, anonymous `add_vertex`, `has_vertex_id`, `delete_vertex_by_id`,
  `vertex_ids`, `vertex_count`, `clone`, and `mutable_copy`.
- Deleting does not rewind or recycle `next_vertex_id`.
- Clone preserves IDs/tombstones but subsequent mutation is independent.

### Tests

Wrong-class, forged, already-destroyed, partial-construction, repeated
create/delete/clone/destroy, limit injection, global destruction, and leak
tests.

### Stop conditions

Stop before adding ithread duplication, shared allocation, or changing any
Perl core file.

## Packet 05: name and label registries

### Objective

Implement boundary normalization and the four AV/HV registries without edge
topology.

### Required behavior

- Named `add_vertex` and duplicate-name error.
- `vertex_id_by_name`, `vertex_name_by_id`, and atomic `rename_vertex`.
- Name-map removal during vertex deletion.
- Reserved label AV entries for `undef` and empty string.
- `declare_label`, atomic `declare_labels`, `labels`, and `label_count`.
- Loose and strict lookup helpers for later edge mutation.
- Label ID is `AvFILLp(labels_by_id) + 1`; no separate counter.

### Normalization sequence

For each supplied scalar:

1. fetch get-magic at most once inside XGraph after call entry;
2. handle `undef` according to name or label context;
3. reject `SvROK`;
4. stringify once into an owned ordinary scalar; and
5. perform HV lookup before native mutation.

Do not invoke reference stringification or retain the original magical value.

### Required tests

Tied/magical values, magic exceptions, dualvars, numeric strings, byte/UTF-8
keys, empty name, anonymous name, `undef` versus empty label, strict typo,
atomic bulk declaration, collision rollback, and label-limit injection.

## Packet 06: sorted adjacency and transactional edges

### Objective

Implement sorted native adjacency arrays and exact edge mutation.

### Required behavior

- `add_edge_by_ids`, `has_edge_by_ids`, and `delete_edge_by_ids`.
- Name methods are thin Perl or XS wrappers around ID methods.
- Both incoming and outgoing entries remain sorted and duplicate-free.
- Exact duplicate insertion throws.
- Missing exact deletion returns false.
- Acyclic graphs reject loops and reachability-producing insertions before
  publication.
- Edge count and topology generation change exactly once per committed edge.

### Transaction rule

Resolve inputs, locate both positions, check duplicates/cycles/limits, and
successfully allocate both destination arrays before moving or publishing
either entry.  Deletion locates both entries before moving either array.

### Required private invariant checker

In DEBUGGING builds verify:

- every list is sorted;
- no list contains duplicates;
- every outgoing entry has one reciprocal incoming entry;
- every referenced vertex is live;
- summed in- and out-degrees both equal `live_edges`; and
- no valid entry has label ID zero.

### Required tests

Loops, different-label parallel edges, duplicate tuples, first/middle/last
insertion and deletion, list growth, allocation failure injection, rejected
cycle rollback, vertex deletion with incident edges, and compact/wide
equivalence.

## Packet 07: eager adjacency queries

### Objective

Implement only the eager query surface over completed Packet 06 storage.

### Methods

`edges`, `edges_between`, `out_edges`, `in_edges`, `out_neighbors`,
`in_neighbors`, `out_degree`, `in_degree`, `edge_count`, `source_vertices`,
`sink_vertices`, and `loop_vertices`.

### Fixed results

- Edge tuples expose the normalized public label.
- Neighbor arrays repeat an ID once per differently labeled edge.
- Whole-edge order is `(from ID,to ID,label ID)`.
- Per-list order follows packed `(neighbor,label ID)` order.
- Unknown required vertex IDs throw.

### Forbidden scope

No lazy iterators, callbacks, or context-sensitive returns.

## Packet 08: paths, cycles, and reachability

### Objective

Implement iterative native DFS/BFS operations only.

### Methods

`has_path`, `path`, `shortest_path`, `cycle`, `shortest_cycle`, `descendants`,
`strict_descendants`, `ancestors`, `strict_ancestors`, `dfs_preorder`,
`dfs_postorder`, `dfs_reverse_postorder`, and `delete_paths`.

### Fixed algorithm choices

- `path` and ordinary `cycle`: iterative DFS.
- shortest operations: BFS with predecessor arrays.
- traversals: explicit native frames, never C recursion.
- `delete_paths`: follow the documented OTP-style repeated path removal and
  remove all differently labeled edges for each adjacent pair on the selected
  path; return the number of tuples removed.

### Required tests

Deep graphs, loops, parallel labels, multiple equal-length paths,
disconnected graphs, strict/start-inclusive reachability, reverse traversal,
and callback-free exception cleanup.

## Packet 09: components and ordering

### Objective

Implement whole-graph structural algorithms.

### Fixed algorithm choices

- Weak components: traversal over both directions.
- Strong components: iterative two-pass Kosaraju for the first implementation.
- Topological sort: Kahn's algorithm using a temporary in-degree array and a
  minimum-ID ready queue, so the documented result is deterministic.
- Components and vertices within them are emitted in ascending minimum-ID
  order; sort only the final small indexing structures needed to guarantee
  this contract.

### Methods

Weak, strong, and cyclic strong components; topological sort;
`reachability_roots`; `is_acyclic`; `is_tree`; `is_arborescence`; and
`arborescence_root`.

### Required tests

Exhaustive small graphs, loops, parallel labels, empty/singleton behavior,
multiple valid topological orders, and reference-model differential tests.

## Packet 10: transformations

### Objective

Implement induced subgraphs and condensation.

### Induced subgraph contract

- Input is an array reference of live vertex IDs.
- Duplicate input IDs are ignored after validation.
- Unknown IDs throw before construction.
- Result preserves original IDs, names, graph options, label IDs, and every
  edge whose endpoints are selected.
- `next_vertex_id` equals the source graph's value, preserving non-reuse.
- Result is mutable even when the source graph is frozen.

### Condensation contract

Return:

```perl
{
    graph        => $dag,
    components   => \@members_by_condensed_id_minus_one,
    component_of => \%condensed_id_by_original_id,
}
```

Assign condensed vertex IDs in ascending minimum-original-ID component order.
Condensed vertices are anonymous.  Preserve every distinct label connecting
two components and deduplicate identical resulting tuples.  The result is
acyclic, mutable, and uses the source label registry IDs unchanged.

## Packet 11: standalone freeze semantics

### Objective

Implement logical immutability without implementing ithread sharing.

### Required behavior

- `freeze` is idempotent, returns the receiver, and marks the complete logical
  graph immutable.
- `is_frozen` reports that state.
- Every operation which can change topology, names, labels, or options throws
  `XPERL.GRAPH.FROZEN` before mutation after freeze.
- `clone` deep-copies the graph and preserves frozen state.
- `mutable_copy` deep-copies the graph and always returns a mutable graph.
- Read operations perform no lazy writes to a frozen store.
- Standalone builds retain class-wide `CLONE_SKIP`.

### Required tests

Exercise every mutation family after freeze, repeated freeze, clone and
mutable-copy independence, destruction, allocation failure, and read-only
invariant checks.  A threaded standalone test verifies only that `CLONE_SKIP`
remains in effect.

### Forbidden scope

No `MGf_DUP`, `svt_dup`, thread-safe reference counting, shared allocator,
generator integration, or Perl-core edit.

## Packet 12: randomized, memory, and performance hardening

### Objective

Harden the completed eager implementation without changing public behavior.

### Required work

- Long randomized differential sequences against the reference model.
- Allocation-failure rollback tests at each prepare/commit allocation.
- ASan/LSan with `PERL_DESTRUCT_LEVEL=2` in a valid environment.
- Threaded and non-threaded DEBUGGING builds, while retaining `CLONE_SKIP`.
- Windows and 32-bit smoke requests.
- Compact/wide behavioral equivalence.
- Benchmarks for construction, sorted insertion by degree, memory per edge,
  queries, and each algorithm group.

### Stop condition

Do not change representation or API merely because a benchmark is slower than
expected.  Report measurements and propose a separate reviewed optimization.

## Packet 13: standalone Perl-wrapped cursor

This packet begins only after the eager standalone baseline and benchmark
report exist.

Implement one ordinary XS cursor for `vertex_iterator`.  Wrap it in a Perl
closure without making the cursor itself callable.  The cursor owns explicit
native state and exposes `next`; add `next_batch($count)` if the packet's
measurements show material per-item boundary overhead.  Specify completion,
failure, mutation invalidation, early destruction, retained graph lifetime,
and closure copies sharing one cursor.  This ID-only cursor captures topology
generation, not naming generation.

Benchmark complete consumption and early exit against `vertex_ids`.  Retain
graph `CLONE_SKIP`; the native cursor class also defines its own permanent
`CLONE_SKIP`.  Cursors and their wrappers are interpreter-local.

Do not create a callable XSUB, use `CvXSUBANY`, edit Perl core, or design a
core iterator API.

## Packet 14: import into XPerl and generator integration

### Prerequisites

- Packets 00 through 13 complete in the standalone repository.
- The standalone tree is reviewed as one importable revision.
- The target XPerl generator and `XError` contracts are available.

### Required work

- Choose and document a permanent move or a one-way snapshot import.  Do not
  leave two writable authoritative copies.
- Import the distribution as `dist/XGraph` without redesigning its C storage
  or public graph API.
- Bind the private error factory to the real `XError` contract.
- Add a thin Perl generator adapter over the Packet 13 XS cursor.  Keep the
  closure adapter usable independently.
- Add shipping files to top-level `MANIFEST` and run `make manisort`.
- Add maintainer metadata.
- Add an appropriate `pod/perldelta.pod` entry.
- Register the distribution with the core build.
- Retain `CLONE_SKIP`; thread sharing belongs only to Packet 15.
- Run focused load, error, cursor, and generator tests.

### Stop conditions

Stop if import requires a new Perl-core C API, if the generator adapter cannot
be written in Perl around the ordinary cursor, or if `XError` requires changing
an already fixed public graph condition.

## Packet 15: frozen-store ithread sharing

This packet implements the already-decided thread design after XGraph is in the
XPerl tree.  It is not a design gate.

### Fixed ownership work

- First record the target XPerl shared-allocation API, portable atomic or mutex
  facility, and nearby `MGf_DUP`/`svt_dup` examples.  This is a focused audit
  inside Packet 15; none of it is delegated back to standalone development.
- Replace `CLONE_SKIP` with extension magic carrying `MGf_DUP` and a reviewed
  `svt_dup` hook.
- Back all potentially shared `xg_store` allocations with Perl's
  shared-allocation facility through the existing private helpers.
- Replace the plain store reference count with the audited portable atomic
  implementation, or with Perl's mutex abstraction if the focused audit finds
  no suitable atomic primitive.
- Keep every `SV *`, AV, and HV in the interpreter-local `xg_graph` handle.
- Duplicate the four Perl containers into the child with the supported clone
  parameter/SV-duplication APIs.  Never retain a parent-interpreter `SV *`.
- For a frozen graph, allocate a child handle, attach the child's four
  containers, retain the same immutable store, and preserve both generation
  values.
- For a mutable graph, allocate an unavailable child handle with no store
  reference.  Every method except destruction throws
  `XPERL.GRAPH.THREAD_CLONE_REQUIRES_FROZEN`.
- Do not freeze the parent, deep-copy a mutable store, implement copy-on-write,
  or share an XS cursor.
- Keep the cursor class's `CLONE_SKIP`.  A child creates its own cursor over
  its frozen graph handle.
- On partial duplication failure, undo every acquired reference, clear the
  magic pointer, and leave destruction idempotent.

### Required tests

- several children reading one frozen store concurrently;
- parent and children destroyed in every order;
- child metadata mutation attempts proving AV/HV ownership is local;
- every child method rejecting an inherited mutable graph;
- generation preservation;
- child-local cursor creation and concurrent reads;
- forced duplication/allocation failure at every acquisition point;
- repeated construction, cloning, and destruction under a threaded DEBUGGING
  build; and
- ASan/LSan or the applicable leak tooling with `PERL_DESTRUCT_LEVEL=2`.

### Stop conditions

Stop if the supported extension-magic APIs cannot attach child-interpreter
containers without retaining parent SVs, if shared allocation cannot be paired
across destruction paths, or if passing tests would require sharing mutable
state.  Do not solve such a problem by changing Perl core opportunistically.

## Packet 16: final core integration and release validation

Complete POD and Changes for the imported module.  Run focused distribution
tests, thread tests, porting tests, and the broad harness.  Record unavailable
Windows, 32-bit, sanitizer, or other platform coverage.  Confirm that the
standalone/import ownership decision from Packet 14 has left one authoritative
source and that no generated or manifest file is stale.

There is no Gate I and no callable-XSUB experiment in this plan.  A future
proposal must revise the plan explicitly before adding either.

## Handoff template

Use this structure when assigning a packet:

```text
Implement XGraph Packet NN.

For Packets 00 through 13, work in the workspace XGraph repository and read:
    ../perl/planning/xgraph.md
    ../perl/planning/xgraph-implementation-packets.md

For Packets 14 through 16, work in the workspace Perl repository and read:
    planning/xgraph.md
    planning/xgraph-implementation-packets.md

The public behavior in the canonical xgraph.md named above is fixed. Do not
implement later packets. Do not make Perl-core changes unless this is Packet
14 through 16 and the packet explicitly requires them. Read the repository
AGENTS.md and applicable skills before editing. Preserve unrelated worktree
changes.

Complete every required result and focused validation in Packet NN. If a
global or packet stop condition occurs, stop and report evidence rather than
choosing a new API or representation.
```

For XS, ownership, algorithms, and debugging packets, run GPT-5.6 Luna with
high or xhigh reasoning.  Review each completed packet before assigning the
next one.
