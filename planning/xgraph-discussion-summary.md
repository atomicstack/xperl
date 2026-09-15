# XGraph discussion summary

## Status

This is a concise record of the current XGraph design discussion.  The
implementation-oriented plan is `planning/xgraph.md`; broader rationale is in
`planning/xperl-graph-module-recommendations.md`.

No source code has been implemented or changed as part of this planning work.

## Purpose

`XGraph` is intended to be a bundled, XS-backed directed graph library for
XPerl.  Erlang/OTP 29 `graph` supplies useful algorithmic coverage and prior
art, but XGraph will use a mutable Perl API and an independently designed
compact native representation.

The likely first-release surface includes construction, adjacency, paths,
cycles, traversal, reachability, weak and strong components, condensation,
topological sorting, subgraphs, and tree/arborescence operations.

## Current data model

### Vertices

- Every vertex has a graph-assigned numeric ID.
- ID `0` is invalid.
- IDs are monotonic and are not reused after deletion.
- A vertex may have one optional unique name.
- An anonymous vertex has no name; XGraph does not generate one.
- Names are strings or stringified non-reference scalars.
- References are rejected as names in version one.
- Names and IDs require unambiguous lookup APIs.

Perl-side naming state is expected to use:

```text
HV  name -> vertex ID
HV  vertex ID -> name
```

Anonymous vertices occupy neither map.

### Labels

Edge labels are registered, graph-local relationship types rather than
arbitrary edge payloads.

```text
0        invalid
1        undef
2        empty string
3..255   registered non-empty strings
```

Omitting a label is equivalent to passing `undef`; it is not equivalent to an
empty string.  Defined non-reference values are stringified once.  References
are rejected.

Loose mode automatically registers labels.  Strict mode requires string
labels to be declared before use, which helps detect misspelled relationship
types.

The graph maintains:

```text
HV  label -> label ID
AV  label ID -> label
```

Label IDs are initially private implementation details.

### Edges

Edges have no independent graph-assigned ID.  An edge is the unique value:

```text
(from vertex ID, to vertex ID, label ID)
```

Parallel edges between the same vertices require different labels.  Changing
an endpoint or label removes one edge and adds another.

XGraph will not initially store arbitrary application data on vertices or
edges.  Applications can maintain their own mappings from stable vertex IDs
or edge tuples to domain objects.

## Native representation

Native topology should contain integers only.  Perl strings remain in the
small AV/HV boundary described above.

Each edge is stored in both directions:

```text
source.out:      (destination ID, label ID)
destination.in:  (source ID, label ID)
```

The preferred compact adjacency occurrence is one `uint32_t`:

```text
high 24 bits: neighboring vertex ID
low 8 bits:   label ID
```

This costs four bytes per adjacency occurrence and eight bytes per directed
edge.  Unsigned numeric order is lexicographic `(vertex ID, label ID)` order,
so sorted adjacency arrays support binary search and contiguous ranges for all
labels connecting one neighbor.

Adjacency arrays use separate 32-bit `count` and `capacity` fields.  This
avoids imposing a 65,535-degree limit merely to save four bytes per allocated
list header.

Insertion and deletion update both adjacency directions transactionally.
Both required allocations succeed before either side is published.

## Compact limits

The 24/8 representation provides:

```text
maximum valid vertex ID:       0xFFFFFF
lifetime vertex allocations:   16,777,215
valid label IDs:               255
registered non-empty labels:   253
adjacency-list lengths:         32-bit
```

The vertex limit is considered reasonable for an in-memory Perl graph.  It is
a lifetime allocation limit because IDs are not reused, but high vertex churn
is not a target workload.  XGraph is expected primarily to build, analyze,
and discard dependency, call, package, workflow, and similar graphs.

The label limit is consistent with labels being low-cardinality relationship
types.  Exhaustion must produce a structured error before mutation or integer
wraparound.

## Wide representation path

Logical vertex IDs, label IDs, and adjacency lengths remain `uint32_t`.
Algorithms access entries only through encoding and decoding helpers.

```text
compact mode: uint32_t entry with 24/8 packing
wide mode:    uint64_t entry with 32/32 packing
```

Both place the label in the low bits and preserve `(vertex,label)` numeric
ordering.  Development should build and test both modes so no algorithm
depends directly on shifts, masks, limits, or entry size.  Compact versus wide
should initially be a compile-time choice rather than automatic per-graph
promotion.

The packing is private and must not become a serialization format or public
XS ABI.

## Eager results and iteration

XGraph aims to implement graph work in XS.  Complete results such as paths,
cycles, components, condensation, and topological ordering should normally be
materialized by one XS call.

Lazy iterators may be useful for vertices, edges, adjacency, neighbors, DFS,
and BFS, especially when callers stop early.  Eager and lazy APIs should be
explicit rather than selected by Perl context.

XPerl `gen`/`yield` suspends Perl execution and cannot suspend an arbitrary C
call stack.  XGraph therefore should not try to implement lazy XS traversal by
yielding from the middle of an XSUB.

Instead, an ordinary XS cursor holds the explicit native pull state machine.
A small Perl closure or generator wraps the cursor and calls `next` or
`next_batch`.  The cursor can retain the graph, captured generation, current
position, DFS/BFS workspace, visited bitmap, and completion state.

Structural graph mutation invalidates a cursor.  Its next call throws a
structured error and the Perl adapter records failure.  Batching should be
used when measurements show material per-item Perl/XS transition cost.

XGraph will not create callable XSUB CVs, store iterator state in
`CvXSUBANY`, or request a new Perl-core iterator C API.  Revisiting that choice
requires an explicit future plan revision.

## Freezing and ithreads

The graph uses an interpreter-local handle pointing to a native topology
store.  `freeze` irreversibly makes the complete logical graph immutable.
`clone` preserves frozen state, while `mutable_copy` makes an independent
mutable graph.

Standalone development retains `CLONE_SKIP`.  After the module moves into the
XPerl tree, a frozen graph cloned into an ithread receives a new
interpreter-local handle and cloned AV/HV metadata while sharing the immutable
native store.  The store has thread-safe lifetime management and no `SV *`
fields.  A mutable inherited graph is unavailable in the child and throws a
specific freeze-before-thread error on use.  The native cursor class keeps
`CLONE_SKIP`; cursors remain interpreter-local.

This is ordinary read-only sharing between threads, not explicit
cross-process shared memory or a persistent memory-mapped graph format.

## Development location

Storage, eager algorithms, freeze semantics, tests, and ordinary XS cursors
will be developed in the workspace's existing `../XGraph` distribution
repository.  The reviewed distribution moves or is imported one-way into
`dist/XGraph` when XPerl `XError` and generator integration are ready.  There
must be only one writable authoritative source after import.

## Relationship to Erlang

Erlang/OTP 29 `graph` gives vertices identifiers plus separate arbitrary
labels, while an edge is uniquely identified by `{From,To,Label}` and has no
independent edge ID.

Older Erlang `digraph` gives both vertices and edges independent IDs, with
labels as ancillary information.

XGraph deliberately differs from both:

- vertices always receive graph-assigned numeric IDs;
- vertex names are optional unique string aliases, not arbitrary annotations;
- edges use unique `(from,to,label)` values and have no IDs;
- labels are registered relationship types; and
- topology is mutable compact native storage.

## Version-one decisions now fixed

- Empty string is a valid vertex name; `undef` means anonymous.
- Vertex names can be atomically changed or removed without changing IDs.
- Duplicate vertex names and exact duplicate edge tuples throw structured
  errors.
- Version one exposes separate ID and name methods and no handle classes.
- Algorithms and enumeration return vertex IDs; public edge values are
  `[from ID,to ID,label]`.
- Ordinary Perl HV key semantics define normalized string equality.
- Version one returns eager array references and does not depend on iterators.
- Compact mode ships first; wide mode is a compile-time equivalence test.
- Standalone development retains `CLONE_SKIP`; frozen-store ithread sharing is
  implemented only after import into XPerl.
- Lazy APIs use Perl wrappers over ordinary XS cursors.  There is no callable
  XSUB or Perl-core iterator API packet.

## Next step

Follow `planning/xgraph-implementation-packets.md`, beginning with the
prerequisite audit and private pure-Perl reference model.  Review each bounded
packet before assigning the next.  Standalone work must retain `CLONE_SKIP`,
and the later XPerl import and thread packets must follow their fixed scope.
