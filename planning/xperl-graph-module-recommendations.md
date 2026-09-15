# XPerl graph module recommendations

## Purpose and relationship to the implementation plan

This document records the design rationale for a bundled high-performance
XPerl graph library.  The working name is `XGraph`.  Detailed implementation
phases, tests, limits, and unresolved API questions live in
`planning/xgraph.md`; that document is authoritative when this rationale is
less specific.

The central recommendation is:

> Use Erlang/OTP 29 `graph` as the algorithmic and conceptual baseline, but
> build a deliberately compact mutable graph for Perl whose native topology
> contains only integer IDs.

The design should borrow mature graph vocabulary and behavior without copying
Erlang source or importing assumptions which do not fit Perl and XS.

## Why Erlang remains useful prior art

Erlang's new `graph` module combines construction and the algorithms formerly
split across `digraph` and `digraph_utils`.  Its useful surface includes:

- directed labeled edges;
- optional acyclic enforcement;
- paths and cycles;
- reachability and traversal order;
- weak and strong components;
- condensation;
- topological sorting;
- source, sink, loop, and root queries;
- induced subgraphs; and
- tree and arborescence predicates.

XGraph should cover that coherent surface before adding unrelated algorithms
such as Dijkstra, A*, flow, matching, PageRank, or coloring.

The identity model is deliberately not identical to either Erlang library:

| Topic | OTP 29 `graph` | Older `digraph` | Current XGraph direction |
| --- | --- | --- | --- |
| mutation | immutable value | mutable ETS object | mutable Perl object |
| vertex identity | caller term or generated integer | caller/generated term | graph-assigned numeric ID |
| vertex annotation | arbitrary label | arbitrary label | optional unique string name |
| anonymous vertex | generated ID, empty label | generated ID, empty label | generated ID, no name |
| edge identity | `(from,to,label)` | independent edge term | `(from ID,to ID,label ID)` |
| edge annotation | label is also identity | arbitrary label | registered relationship label |
| independent edge ID | no | yes | no |

XGraph is therefore not a compatibility wrapper.  It is an XPerl graph design
informed by Erlang's coverage and long experience.

## Core recommendations

### Mutable by default

Use a conventional mutable object:

```perl
my $graph = XGraph->new(acyclic => 1);
my $a = $graph->add_vertex("a");
my $b = $graph->add_vertex("b");
$graph->add_edge_by_ids($a, $b, "depends_on");
```

Persistent data structures would dominate the initial implementation and
impose an unfamiliar update style.  An explicit deep `clone` supplies
branchable state when needed.

### Develop standalone before core import

Build the storage engine, eager algorithms, freeze semantics, reference model,
and ordinary XS cursors in the workspace's existing `../XGraph` distribution
repository.  Keep errors behind one private factory and avoid private
Perl-core APIs.  Import the reviewed distribution into `dist/XGraph` only when
the XPerl `XError` and generator adapters are ready for integration.

The import must establish one authoritative source.  It may be a permanent
move or a documented one-way snapshot, but development must not continue in
two independent writable copies.

### Numeric vertex identity, optional names

Every vertex receives a monotonically increasing numeric ID.  Zero is invalid
and deleted IDs are not reused.  Stable non-reuse is more valuable for the
intended build-and-analyze workloads than optimizing for long-running vertex
churn.

A unique optional name is a Perl-side alias, not the vertex's native identity.
An anonymous vertex has no name; do not synthesize one.  This keeps anonymous
vertices out of the name HVs and makes the distinction observable and honest.

Names accept strings or values which can be stringified without being
references.  Stringify once at the boundary and retain the normalized string.
Reject all references in version one, including blessed references.  Later
support for explicitly string-overloaded objects can be considered without
retaining the original object.

Use explicit lookup forms so an integer-looking name cannot be confused with
an ID.

### Registered relationship labels

An edge label is a low-cardinality relationship type such as `depends_on`,
`contains`, or `calls`.  It is not general per-edge storage.

Maintain a forward HV and reverse AV.  Reserve:

```text
0        invalid
1        undef
2        empty string
3..255   registered strings in compact mode
```

Omission and explicit `undef` are equivalent.  The empty string remains a
real, distinct label.  Accept stringifiable non-reference scalars; reject
references before ordinary reference stringification occurs.

Loose mode automatically interns an unknown label.  Strict mode requires
string labels to be declared first.  Strict mode is valuable for schema-like
graphs because it detects misspelled relationship types.

Do not add a separate public label-ID API until ordinary use demonstrates a
need.  Label IDs primarily exist to make native topology compact.

### Edges are values, not entities

Represent an edge solely as:

```text
(from vertex ID, to vertex ID, label ID)
```

The tuple is unique.  Differently labeled parallel edges are allowed; exact
duplicates are not.  Relabeling or changing an endpoint removes one edge and
adds another.

There is no demonstrated requirement for an identity which survives changing
the relationship itself.  Omitting edge IDs removes counters, maps,
serialization rules, exhaustion rules, and bidirectional tuple/ID indexes.

Applications which need domain records can map stable vertex IDs and edge
tuples to their own objects.  XGraph should not store arbitrary application
payloads initially.

## Native representation recommendation

### Keep Perl values at the boundary

The likely boundary is:

```text
AV  label ID -> label
HV  label -> label ID
HV  vertex ID -> name
HV  name -> vertex ID
```

The native topology contains only IDs, counts, offsets or pointers, generation
numbers, and packed adjacency entries.  It contains no borrowed name or label
SVs.

This division provides ordinary Perl ownership for strings while keeping the
hot graph representation dense.  Magical inputs are normalized before native
mutation, so exceptions cannot leave half-published topology.

### Store incoming and outgoing adjacency

Maintaining both directions is justified by the public API and structural
algorithms.  Reconstructing incoming relationships by scanning the graph would
make ordinary operations unnecessarily expensive.

For an edge `(A,B,L)`, store:

```text
A.out: (B,L)
B.in:  (A,L)
```

All mutation must be transactional because the edge is represented twice.
Allocate both sides before modifying either and provide a debug invariant
checker for reciprocal entries.

### Prefer compact 24/8 adjacency words

Compact mode stores one adjacency occurrence as:

```text
high 24 bits: neighboring vertex ID
low 8 bits:   label ID
```

That yields four bytes per occurrence and eight bytes per directed edge.  It
also makes unsigned numeric order exactly `(vertex,label)` order.  Sorted
arrays can therefore use direct binary search, and every differently labeled
edge for one neighbor occupies a contiguous range.

Use two 32-bit header fields for count and capacity.  Adjacency length does not
need to inherit an unrelated 16-bit limit from entry packing.

Sorted vectors make exact lookup `O(log degree)` and insertion/deletion
`O(degree)`.  For ordinary sparse graphs, moving compact words may outperform
more elaborate structures through lower allocation and cache costs.  Measure
real degree distributions before adding indexes.

### Accept the compact limits deliberately

Compact mode permits:

```text
16,777,215 lifetime vertex IDs
255 valid label values, including undef and empty
253 registered non-empty string labels
32-bit incoming and outgoing list lengths
```

Sixteen million vertices is a reasonable ceiling for an in-memory Perl graph:
native vertex records, algorithm workspaces, adjacency, and optional Perl
names are likely to impose practical memory limits first.  Non-reuse makes it
a lifetime allocation bound, but XGraph is not initially aimed at
indefinitely churning graph databases.

The label ceiling is consistent with labels being relationship types.  It is
not suitable for assigning a unique textual annotation to every edge, which
is intentionally outside the model.

Both exhaustion conditions must be documented and reported before wraparound.

### Preserve a wide implementation path

Algorithms must not know how entries are packed.  Logical vertex and label IDs
remain `uint32_t`; accessors encode/decode either:

```text
compact: uint32_t containing 24/8 bits
wide:    uint64_t containing 32/32 bits
```

Both keep the label in the low bits and retain the same numeric ordering.
Counts remain 32-bit in either mode.

Build both forms during development.  This checks that helpers, rather than
hard-coded masks or sizes, define the representation.  Begin with a
compile-time choice; automatic graph-wide or per-list promotion adds
complexity which has no demonstrated user requirement.

## Result and iterator recommendations

### Retain eager bulk operations

XS can construct an entire result with one Perl/XS transition.  Complete
answers such as paths, cycles, component partitions, condensation, and
topological order should normally be materialized.

Enumeration and traversal can benefit from laziness when a caller may stop
early.  Offer explicit methods rather than changing meaning with context:

```perl
my $all = $graph->vertices;
my $it  = $graph->vertex_iterator;
```

Candidate iterators include vertices, edges, adjacency, neighbors, DFS, and
BFS.  Benchmarks should include both complete consumption and early exit.

### Wrap ordinary XS cursors in Perl

XPerl generators suspend a Perl continuation at `yield`; they do not suspend
an arbitrary C stack.  XGraph should represent traversal as an explicit native
state machine in an ordinary XS cursor object.  A small Perl closure or
generator wraps the cursor and calls `next` or `next_batch` as required.

A state object may retain:

- the graph;
- the graph generation it expects;
- current vertex and adjacency position;
- a DFS stack or BFS queue;
- a visited bitmap; and
- lifecycle flags.

Structural graph mutation invalidates a live cursor.  Its next native call
throws a structured error, and the Perl adapter records the corresponding
failed state.  Batch reads should be measured before treating one Perl/XS
transition per item as a problem.

Do not create callable XSUB CVs, store state in `CvXSUBANY`, or add a Perl-core
iterator C API for XGraph.  That is not an implementation gate.  It would
require an explicit future plan revision.

## Freeze and ithread recommendation

Keep a per-interpreter graph handle separate from a native topology store.
`freeze` makes the complete logical graph permanently immutable.  A later
`mutable_copy` is the explicit route back to independently mutable state.

Standalone development retains `CLONE_SKIP`.  After import into XPerl, frozen
handles in child interpreters share the same immutable native store with a
thread-safe lifetime count.  Perl AV/HV name and label metadata is cloned into
each interpreter.  A graph which was mutable when inherited has no usable
store in the child and throws `XPERL.GRAPH.THREAD_CLONE_REQUIRES_FROZEN` on
use.  Do not freeze or deep-copy it implicitly.

This sharing uses ordinary address-space sharing between OS threads.  Explicit
`mmap`, cross-process shared memory, and persistent graph files are separate
deferred features.  The native cursor class retains its own `CLONE_SKIP`, so
cursors and their Perl wrappers remain interpreter-local.  Each child creates
its own cursor over the frozen store.

## API principles

- Use separate ID and name methods; handle objects are deferred from version
  one.  Do not guess identity mode from scalar form.
- Avoid scalar/list-context changes in meaning.
- Use IDs as the natural result for anonymous vertices.
- Define whether result representation is fixed or caller-selectable.
- Keep unspecified global ordering unspecified, even though sorted native
  adjacency gives deterministic local order.
- Treat a missing query result differently from malformed input or an unknown
  mutation endpoint.
- Use structured XPerl error codes rather than message parsing.
- Keep compact representation details out of serialization and public ABI.

Candidate error conditions include invalid selectors, unknown vertices,
duplicate names, unknown strict-mode labels, label exhaustion, vertex-ID
exhaustion, duplicate edge tuples, rejected cycles, and invalidated iterators.

## Algorithm scope

The initial coherent surface should include:

- vertex and edge construction, deletion, membership, and counts;
- incoming/outgoing adjacency, neighbors, and degrees;
- source, sink, and loop vertices;
- arbitrary and shortest unweighted paths and cycles;
- reachability and reverse reachability;
- DFS traversal orders;
- weak, strong, and cyclic strong components;
- condensation and induced subgraphs;
- topological sorting and reachability roots;
- acyclicity, tree, and arborescence operations; and
- explicit clone.

Weighted algorithms should be deferred.  Without arbitrary edge payloads, a
future weighted layer needs a separate weight map, callback, or specialized
module rather than pretending every relationship label is a weight.

## Validation recommendations

Use a pure-Perl behavioral model and randomized differential tests.  Translate
or compare Erlang tests only where semantics genuinely align; XGraph's vertex
names and edge handling deliberately differ.

Test compact and wide encodings against the same contract.  Verify reciprocal
adjacency, sort order, tuple uniqueness, degree totals, path validity,
component partitions, topological results, clone independence, and rollback
after every rejected mutation.

Give special attention to:

- UTF-8 and byte names/labels;
- numeric stringification and magical scalars;
- rejection of references;
- `undef` versus empty edge labels;
- strict and loose registration;
- all representation boundaries;
- exception-safe dual-list mutation;
- cursor early destruction, batching, and invalidation;
- frozen-store retention and interpreter-local cursor ownership;
- frozen ithread sharing and mutable-child rejection after XPerl import;
- destructor reentrancy and global destruction; and
- ASan/LSan runs with `PERL_DESTRUCT_LEVEL=2`.

Benchmark time and memory separately.  Important comparisons include compact
versus wide entries, sorted-vector insertion at different degrees, complete
eager enumeration versus one-value and batched cursor adapters, early
traversal exit, and peak workspace memory for whole-graph algorithms.

## Recommended next step

Execute the bounded work in `planning/xgraph-implementation-packets.md`,
starting with the prerequisite audit and pure-Perl reference model.  The
canonical plan has fixed duplicate insertion, selectors, rename behavior,
result representation, compact-mode policy, and the eager version-one scope;
implementation packets must not reopen them.

The representation is promising precisely because it is simple.  Preserve
that simplicity by requiring evidence and a separate approved packet before
adding edge IDs, arbitrary payloads, hash indexes for adjacency, automatic
wide promotion, handles, or additional lazy cursor families.

## References

- Erlang/OTP 29 `graph`: <https://www.erlang.org/doc/apps/stdlib/graph.html>
- Erlang `digraph`: <https://www.erlang.org/doc/apps/stdlib/digraph.html>
- Erlang `digraph_utils`:
  <https://www.erlang.org/doc/apps/stdlib/digraph_utils.html>
- XPerl generator and iterator behavior: `pod/perlgenerator.pod`
