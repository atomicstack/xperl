# Plan: `XGraph`, a compact XS directed-graph module

## Status and intent

This is the current design and implementation plan for `XGraph`.  It replaces
earlier assumptions that vertices are identified by names, that labels hold
arbitrary Perl data, or that edges need independent IDs.  It is not a final
release commitment, but its normative version-one choices are fixed for
implementation unless this plan is explicitly revised.

`XGraph` is intended to be a first-party XPerl module.  The `X` prefix marks
it as part of the bundled XPerl family and avoids claiming compatibility with
the established CPAN `Graph` namespace.  `XGraph::Directed` can remain
available as a future alias or family member if undirected graphs are added.
CPAN or PAUSE distribution is not a design requirement.

The semantic baseline is the public graph and algorithm surface of the
Erlang/OTP 29 `graph` module.  XGraph deliberately uses a mutable Perl object,
compact integer topology, optional vertex names, registered relationship
labels, and XS implementations rather than copying Erlang's representation or
calling conventions.

Development begins in the workspace's standalone sibling repository,
`../XGraph`.  That repository already contains the initial h2xs-style project
skeleton.  The reviewed distribution moves or is imported one-way into
`dist/XGraph` only when XPerl generator and `XError` integration is ready.
Frozen-store ithread sharing is implemented after that import, not during
standalone development.

## Goals

1. Cover the useful directed-graph operations exposed by Erlang/OTP 29
   `graph`, with deliberately Perlish names and return shapes.
2. Keep graph topology entirely in compact native integer storage.
3. Give every vertex a stable graph-assigned numeric ID, with an optional
   unique Perl-side name.
4. Represent an edge as the unique value `(from ID, to ID, label ID)`, without
   a second edge-identity namespace.
5. Treat edge labels as registered, low-cardinality relationship types rather
   than arbitrary per-edge data.
6. Implement storage, traversal, and algorithms in XS.  Where laziness is
   useful, expose ordinary XS cursor objects which Perl closures or generators
   can wrap.
7. Specify limits, mutation behavior, ordering, error behavior, ownership,
   ithread behavior, and iterator invalidation explicitly.
8. Keep the implementation independent of non-core C and C++ libraries.

## Non-goals for the first release

- undirected, weighted, hypergraph, or graph-rendering APIs;
- arbitrary application payloads stored on vertices or edges;
- reference-valued vertex names or edge labels;
- an independent graph-assigned edge ID;
- compatibility with every method in CPAN `Graph`;
- persistent or memory-mapped graph files;
- a high-churn, indefinitely maintained graph database;
- weighted shortest paths, network flow, PageRank, coloring, or other
  algorithms outside the OTP 29 baseline;
- exposing native pointers, slots, or packed adjacency words as public API;
- dumping the native representation as a serialization format; or
- adding a resumable C-stack facility merely to implement iteration.

## Normative version-one decisions

The following choices are fixed for the first implementation.  An implementing
agent must not reopen them without an explicit plan revision.

1. The shipping module is `XGraph`; version one is directed-only.
2. Compact 24/8 adjacency is the shipping representation.  Wide 32/32 is a
   compile-time test configuration, not a run-time graph option.
3. Vertex ID `0` is invalid; IDs `1..0xFFFFFF` are monotonic and never reused.
4. An omitted or `undef` vertex name means anonymous.  The empty string is a
   valid named vertex and is distinct from anonymity.
5. All defined non-reference name and label inputs are fetched for magic at
   most once inside XGraph after call entry, rejected if they become
   references, and stringified once before mutation.
   Version one rejects blessed references even if they overload stringification.
6. Normalized strings use the same equality and byte/UTF-8 behavior as ordinary
   Perl HV keys.  Do not add Unicode normalization, case folding, locale rules,
   or numeric comparison.
7. Adding an already used vertex name throws
   `XPERL.GRAPH.DUPLICATE_VERTEX_NAME`; it does not return the old vertex.
8. `rename_vertex($id, $name_or_undef)` is supported.  It retains the ID,
   atomically changes or removes the name mapping, and throws on collision.
9. Exact duplicate edge insertion throws `XPERL.GRAPH.EDGE_EXISTS`.
10. Version one has no vertex-handle or edge-handle classes.  Canonical native
    APIs take vertex IDs.  Name convenience methods resolve names and then call
    the same ID implementation.
11. Algorithm and enumeration results contain vertex IDs.  An edge exposed to
    Perl is `[FROM_ID, TO_ID, LABEL]`, where `LABEL` is `undef`, `""`, or the
    registered string, never the private label ID.
12. Public collection results are array references.  Version-one completion
    does not depend on generators, iterators, or a new core C API.
13. Lazy iterator methods are a post-baseline optimization.  They use a Perl
    closure or generator around an ordinary XS cursor.  The cursor may return
    batches to amortize Perl/XS transitions.  XGraph does not create callable
    XSUB CVs and does not require a new Perl-core iterator API.
14. A graph is mutable until `freeze` is called.  Freezing is irreversible,
    idempotent, and prohibits every operation which would change topology,
    names, labels, or graph options.
15. Frozen native graph stores are shared read-only between ithreads.  The
    Perl graph handle and its AV/HV metadata remain interpreter-local.  A
    mutable graph inherited by a child interpreter is unusable there and every
    method on it throws `XPERL.GRAPH.THREAD_CLONE_REQUIRES_FROZEN`.
16. The initial storage prototype may use class-wide `CLONE_SKIP`.  The
    dedicated ithread packet replaces it with the fixed frozen-store design
    before thread support is declared complete.
17. `XError` is a prerequisite for freezing public failures.  Until its minimum
    constructor and throw contract exists, XGraph code routes every error
    through one private error factory; tests must not parse message text.

These defaults intentionally make the first implementation narrower than the
eventual design.  They prevent an implementation agent from inventing handle,
iterator, thread-clone, serialization, or error contracts opportunistically.

## Public data model

### Vertices

Every vertex has an immutable, graph-assigned numeric ID.  ID `0` is invalid.
IDs increase monotonically and are not reused after deletion, so a stale ID
cannot silently identify a different vertex.

A vertex may also have a unique name.  A vertex created without a name is
anonymous; XGraph does not manufacture a name for it.  Anonymous vertices are
addressed by ID.  Handle objects are deferred beyond version one.

Name normalization is:

```text
argument omitted or undef  -> anonymous vertex
defined non-reference      -> stringify once and use the resulting string
reference                  -> structured error
```

Stringification occurs before native mutation.  XGraph retains the normalized
ordinary scalar, not the original magical or overloaded input.  Values such
as `12` and `"12"` consequently denote the same name.  Reference values are
rejected before Perl can turn them into unstable strings such as
`HASH(0x...)`.  A later opt-in extension may accept blessed references with
string overloading, but version one does not.

Names and IDs are distinct namespaces.  APIs must not guess whether a scalar
such as `12` means ID 12 or name `"12"`; version one uses separate ID and name
methods.

The current Perl-side maps are:

```text
HV  vertex name -> vertex ID
HV  vertex ID   -> vertex name
```

Only named vertices occupy these maps.  The forward HV naturally uses shared
hash keys.  The reverse HV may use unshared numeric keys to avoid interning ID
strings in `PL_strtab`.  Initial code should favor ordinary, obvious SV
ownership; sharing a name SV or HEK between maps is a later measured
optimization.

### Edge labels

Edge labels are registered graph-local relationship types.  They are not
arbitrary payloads.  XGraph maintains:

```text
HV  label string -> label ID
AV  label ID     -> label string
```

The reserved compact IDs are:

```text
0        invalid
1        undef
2        empty string
3..255   registered non-empty string labels
```

Normalization is:

```text
argument omitted or undef  -> label ID 1
defined non-reference      -> stringify once
resulting empty string      -> label ID 2
other string                -> existing or newly registered label ID
reference                   -> structured error
```

Thus these calls are equivalent:

```perl
$graph->add_edge($a, $b);
$graph->add_edge($a, $b, undef);
```

They are distinct from:

```perl
$graph->add_edge($a, $b, "");
```

Loose label mode registers an unknown string on first use.  Strict label mode
requires string labels to be declared in advance, catching mistakes such as
`"depend_on"` in place of `"depends_on"`.  The reserved `undef` and empty
labels should not require declaration.

Label IDs are initially an implementation detail.  A low-level ID API may be
considered only after the ordinary string API is stable.

### Edges

An edge has no independent identity.  It is the relationship value:

```text
(from vertex ID, to vertex ID, label ID)
```

Only one identical tuple may exist.  Parallel edges between the same ordered
vertices require different labels.  Changing an endpoint or label means
deleting one edge and adding another.

An edge can be described using endpoint IDs or endpoint names.  The public
call makes the addressing form unambiguous, and every name form resolves to
vertex IDs before touching topology.  Handle objects are deferred.

No `(from ID, to ID, label ID)` API is required in version one, although it is
a possible low-level extension.  The normal ID-oriented form still accepts a
label string:

```perl
$graph->add_edge_by_ids($from_id, $to_id, "depends_on");
```

### No attached payloads

XGraph does not initially store a separate arbitrary value on a vertex or
edge.  Applications that need domain objects or records can keep their own map
from stable vertex IDs or edge tuples to those values.  This keeps Perl values
at a small boundary and prevents the graph from becoming a general-purpose
object store.

## Normative baseline Perl API

The reference model and initial XS implementation use this spelling.  Changes
require an explicit plan revision rather than local implementation judgment:

```perl
my $graph = XGraph->new(
    acyclic      => 1,
    strict_labels => 1,
);

$graph->declare_labels(qw(depends_on contains));

my $parse_id = $graph->add_vertex("parse");
my $emit_id  = $graph->add_vertex("emit");
my $anon_id  = $graph->add_vertex;

$graph->add_edge_by_names("parse", "emit", "depends_on");
$graph->add_edge_by_ids($parse_id, $emit_id, "depends_on");
```

Do not make scalar versus list context select different addressing or result
semantics.

### Construction and labels

| Method | Return | Baseline semantics |
| --- | --- | --- |
| `new(acyclic => BOOL, strict_labels => BOOL)` | graph | Both options default false; unknown options throw. |
| `freeze` | receiver | Irreversibly make the complete logical graph immutable; idempotent. |
| `is_frozen` | boolean | True only after `freeze`; never changes back to false. |
| `clone` | graph | Deep independent clone preserving IDs, names, label IDs, tuples, and frozen state. |
| `mutable_copy` | graph | Deep independent mutable copy preserving IDs, names, label IDs, and tuples. |
| `declare_label($label)` | receiver | String label only; declaring an existing label is a no-op. |
| `declare_labels(@labels)` | receiver | Atomic: validate and reserve capacity before registering any. |
| `labels` | array reference | Public labels in label-ID order, including `undef` then `""`. |
| `label_count` | integer | Count of valid label values, including the two reserved labels. |

### Vertices

| Method | Return | Baseline semantics |
| --- | --- | --- |
| `add_vertex()` | vertex ID | Create an anonymous vertex. |
| `add_vertex($name)` | vertex ID | `undef` is anonymous; duplicate normalized name throws. |
| `has_vertex_id($id)` | boolean | Invalid or deleted IDs return false. |
| `vertex_id_by_name($name)` | ID or `undef` | Missing name is ordinary absence; references throw. |
| `vertex_name_by_id($id)` | string or `undef` | `undef` means anonymous; unknown ID throws. |
| `rename_vertex($id, $name_or_undef)` | true | Atomic rename/removal; unknown ID or collision throws. |
| `delete_vertex_by_id($id)` | boolean | False if absent; deletes all incident edges. |
| `delete_vertex_by_name($name)` | boolean | False if absent; otherwise delegates by ID. |
| `vertex_ids` | array reference | Live IDs in ascending numeric order. |
| `vertex_count` | integer | Number of live vertices. |

### Edges and adjacency

Every label argument below is optional and defaults to `undef`.  Every edge
returned to Perl is `[FROM_ID, TO_ID, LABEL]`.

| Method | Return | Baseline semantics |
| --- | --- | --- |
| `add_edge_by_ids($from,$to,$label?)` | true | Unknown endpoint, unknown strict label, duplicate tuple, or rejected cycle throws. |
| `add_edge_by_names($from,$to,$label?)` | true | Resolve both names, then use the ID operation. |
| `has_edge_by_ids($from,$to,$label?)` | boolean | False for absent tuple; malformed IDs throw. |
| `has_edge_by_names($from,$to,$label?)` | boolean | False if either name or tuple is absent. |
| `delete_edge_by_ids($from,$to,$label?)` | boolean | False for absent tuple. |
| `delete_edge_by_names($from,$to,$label?)` | boolean | False if either name or tuple is absent. |
| `edges` | array reference | All edge tuples in ascending `(from,to,label-ID)` order. |
| `edges_between($from,$to)` | array reference | ID endpoints; tuples in label-ID order. |
| `out_edges($id)`, `in_edges($id)` | array reference | Unknown vertex throws. |
| `out_neighbors($id)`, `in_neighbors($id)` | array reference | IDs; one occurrence per edge, so differently labeled parallel edges repeat the neighbor. |
| `out_degree($id)`, `in_degree($id)` | integer | Counts edge tuples, including loops and parallel labels. |
| `edge_count` | integer | Number of live edge tuples. |

### Algorithms and transformations

All vertex inputs and results in the baseline algorithm layer are IDs.  Name
convenience wrappers can be added later in Perl without duplicating XS
algorithms.

| Method group | Required baseline result |
| --- | --- |
| `has_path`, `path`, `shortest_path` | Boolean or ID-array path; absent path is `undef` for the path methods. |
| `cycle`, `shortest_cycle` | Closed ID-array cycle; absent cycle is `undef`. |
| `descendants`, `strict_descendants`, `ancestors`, `strict_ancestors` | ID array references. |
| `dfs_preorder`, `dfs_postorder`, `dfs_reverse_postorder` | ID array references. |
| `weakly_connected_components`, `strongly_connected_components`, `cyclic_strongly_connected_components` | Array references of ID-array components. |
| `topological_sort` | ID array reference, or `undef` if cyclic. |
| `source_vertices`, `sink_vertices`, `loop_vertices`, `reachability_roots` | ID array references. |
| `is_acyclic`, `is_tree`, `is_arborescence` | Canonical booleans. |
| `arborescence_root` | Vertex ID or `undef`. |
| `delete_paths` | Integer number of edge tuples removed. |
| `induced_subgraph` | New mutable graph preserving selected vertex IDs, names, labels, and included tuples. |
| `condensation` | Hash reference `{ graph, components, component_of }`; the new graph is mutable, `components` is indexed by condensed vertex ID minus one, and `component_of` maps every original ID to its condensed ID. |

Except where a mathematical result defines an order, whole-result order is
the ascending order naturally induced by IDs and sorted adjacency.  Tests may
rely on the orders stated above, but not on AV/HV iteration order.

## Native representation

### Baseline object and vertex layout

The initial XS object is an opaque blessed scalar referent with extension
magic.  The magic pointer owns one `xg_graph` allocation.  Do not expose a
blessed hash whose internal keys callers can mutate.

The baseline native shapes are conceptually split into an interpreter-local
handle and a native store:

```c
typedef struct {
    xg_adj_list *in;
    xg_adj_list *out;
    U8           live;
} xg_vertex;

typedef struct xg_store {
    xg_vertex *vertices;       /* indexed directly by vertex ID */
    U32        vertex_capacity;
    U32        next_vertex_id;
    U32        live_vertices;
    U64        live_edges;
    U64        topology_generation;
    U64        naming_generation;

    /* abstracted lifetime state; made thread-safe in the XPerl thread packet */
    xg_store_refcount_t store_refcount;
    U8         acyclic;
    U8         strict_labels;
    U8         frozen;
} xg_store;

typedef struct {
    xg_store  *store;
    AV        *labels_by_id;
    HV        *label_ids_by_name;
    HV        *vertex_names_by_id;
    HV        *vertex_ids_by_name;
    U8         unavailable_thread_clone;
} xg_graph;
```

Field spelling may follow local C style, but ownership and division of state
must not change without review.  `vertices[0]` remains permanently invalid.
Growing the vertex array zero-initializes new records.  A deleted record is a
tombstone with `live == 0` and null adjacency pointers.

The interpreter-local graph handle owns one reference to each AV/HV and one
reference to the native store.  The store contains no `SV *`.  All store
allocation and release goes through one private helper family.  The standalone
implementation may back those helpers with ordinary allocation and a plain
reference count while it retains `CLONE_SKIP`.  The post-import XPerl ithread
packet changes them to Perl's shared-allocation facility and a portable atomic
reference count, or the existing Perl mutex abstraction if its focused audit
finds no suitable atomic primitive.

The magic free hook first detaches its handle pointer, releases the store, and
then decrements the four Perl containers.  The last store reference frees all
native adjacency and vertex storage.  Cleanup must tolerate partial
construction and repeated attempts.

The ordinary `clone` and `mutable_copy` methods deep-copy native arrays and the
four Perl containers.  `clone` preserves frozen state.  `mutable_copy` always
returns a private mutable store.  These methods are separate from ithread
cloning.  The initial storage prototype declares `CLONE_SKIP`; the dedicated
ithread packet later replaces it with the frozen sharing design below.

### Boundary invariant

The principal ownership rule is:

> Perl strings and values live in a small number of AV/HV structures at the
> graph boundary; native topology contains compact integers only.

The Perl-facing structures are approximately:

```text
AV  labels_by_id
HV  label_ids_by_name
HV  vertex_names_by_id
HV  vertex_ids_by_name
```

The native graph owns vertex state, incoming and outgoing adjacency arrays,
counts, generation numbers, and the next vertex ID.  There is no edge-ID map,
edge record array, or edge-ID counter.

All magical name and label inputs must be fetched and normalized before the
native mutation guard is entered.  The AV/HV structures own their SVs through
normal Perl refcount rules; native vertex and adjacency records contain no
borrowed `SV *` fields.

### Compact adjacency entries

The preferred compact entry is:

```text
31                    8 7             0
+----------------------+---------------+
|    vertex ID: 24     | label ID: 8   |
+----------------------+---------------+
```

Packing and unpacking use unsigned arithmetic:

```c
packed    = (vertex_id << 8) | label_id;
vertex_id = packed >> 8;
label_id  = packed & UINT32_C(0xff);
```

The label occupies the low bits, so unsigned numeric ordering is exactly
lexicographic `(vertex ID, label ID)` ordering.  This is true for integer
comparison, not raw bytewise `memcmp` on little-endian systems.

Each directed edge occurs twice:

```text
source.out:      (destination ID, label ID)
destination.in:  (source ID, label ID)
```

The relationship storage is therefore four bytes in each direction, or eight
bytes per directed edge.

### Adjacency lists

Use 32-bit length and capacity fields independently of the packed entry:

```c
struct xg_adj_list {
    uint32_t capacity;
    uint32_t count;
    xg_adj_entry_t entries[];
};
```

This avoids an otherwise unnecessary degree limit of 65,535 while adding only
four bytes to each allocated list header.  Empty lists need no allocation.
Capacity growth and allocation multiplication must be overflow-checked.

Keep each list sorted by packed entry.  This provides:

```text
exact edge lookup:             O(log degree)
all labels for one neighbor:   one contiguous range
iteration:                     contiguous and cache-friendly
insertion/deletion:            O(degree) packed-word movement
```

Insertion and deletion cost should be benchmarked on realistic degree
distributions before adding a hash or tree index.

### Compact limits

Compact mode has explicit limits:

```text
valid vertex IDs:              1 .. 0xFFFFFF
lifetime vertex allocations:   16,777,215
valid label IDs:               1 .. 255
registered non-empty strings:  253
adjacency count/capacity:       32-bit
```

The vertex limit is a lifetime allocation limit because IDs are not reused.
XGraph is aimed primarily at graphs which are constructed, queried, and then
discarded, rather than indefinitely churning graph databases.  Sixteen
million vertices would already require substantial native memory before edge
storage and algorithm workspaces, so the limit is considered reasonable for
the intended initial scope.

Exhaustion must throw a specific structured error before counters wrap or
mutation begins.  The packed value `UINT32_MAX` is valid for vertex
`0xFFFFFF` and label `0xFF`, so it must not be used as an internal sentinel.

### Representation abstraction and wide mode

Do not scatter shifts, masks, entry widths, or limits through algorithms.
Use logical ID types and one adjacency abstraction:

```c
typedef uint32_t xg_vertex_id_t;
typedef uint32_t xg_label_id_t;
typedef uint32_t xg_degree_t;
```

Compact storage uses a `uint32_t` entry containing 24/8 bits.  A wide build can
use a `uint64_t` entry containing 32/32 bits.  In both cases labels occupy the
low bits and unsigned integer order remains `(vertex,label)` order.

All code must use helpers for:

- encoding an adjacency entry;
- extracting vertex and label IDs;
- checking representation limits;
- calculating neighbor ranges; and
- allocating with `sizeof(xg_adj_entry_t)`.

No algorithm should shift or mask an entry directly.  Build and test both
representations during development even if compact mode is the only initial
shipping configuration.  Make representation a compile-time choice first;
per-graph automatic promotion would add branches, conversion failure paths,
and peak-memory costs without a demonstrated requirement.

Native packing is never a serialized or XS-visible ABI.

### Transactional mutation

An edge insertion must update both outgoing and incoming lists atomically:

1. fetch and normalize all magical Perl arguments;
2. resolve endpoints and labels;
3. validate vertices, tuple uniqueness, acyclicity, and limits;
4. locate both insertion positions;
5. allocate or grow both lists before publishing either change;
6. insert both packed entries; and
7. update counts and the structural generation.

Deletion similarly locates both occurrences before modifying either list.
Debug builds should provide an invariant checker proving that every outgoing
entry has exactly one matching incoming entry and that every list is sorted
and duplicate-free.

Vertex deletion removes its name mapping and every incoming and outgoing
tuple, but does not make its ID reusable.

## Algorithms

Algorithms operate on numeric IDs and packed adjacency entries.  All deep
traversals use explicit native stacks or queues rather than C recursion.

- DFS: arbitrary path, cycle, preorder, postorder, reverse postorder, and
  acyclicity checks.
- BFS: shortest unweighted path and shortest cycle.
- SCCs: iterative Tarjan or two-pass Kosaraju, chosen for auditability and
  measured cost.
- Weak components: traversal over incoming and outgoing adjacency.
- Topological sort: Kahn's algorithm or a documented traversal equivalent.
- Condensation: compute SCC membership, create component vertices, and
  deduplicate resulting edge tuples.
- Tree and arborescence predicates: explicit degree, edge-count, and
  reachability rules.
- Enforced-acyclic insertion: reject loops, then search from proposed target
  to proposed source before committing.

Document time and temporary memory in terms of live vertices `V` and edges
`E`.  Do not sort complete results merely to make an unspecified order look
stable; sorted adjacency already supplies deterministic local order by IDs.

### Fixed mathematical edge cases

- `has_path($a,$b)`, `path`, and `shortest_path` require at least one edge.
  When `$a == $b`, they succeed only if a loop or longer cycle returns to the
  start.
- Every returned non-cycle path is `[START,...,END]`.  Every returned cycle is
  closed as `[V,...,V]`; a self-loop is `[V,V]` for both cycle methods.
- `descendants` and `ancestors` use paths of length zero or more and therefore
  include valid starting vertices.  Their `strict_` forms require a path of
  length one or more; a start can still appear when a cycle reaches it again.
- Weak and strong component results partition all live vertices exactly once.
  A cyclic strong component has more than one vertex or is a singleton with a
  self-loop.
- `reachability_roots` returns the smallest vertex ID from each source SCC of
  the condensation graph, ordered by ID.  This is a deterministic minimal set
  from which all vertices are reachable.
- The empty graph is acyclic, but is neither a tree nor an arborescence and has
  no arborescence root.
- A singleton graph with no loop is both a tree and an arborescence; its sole
  vertex is the arborescence root.
- `is_tree` treats directed edges as undirected but counts every labeled edge.
  It requires a non-empty weakly connected graph, no loop, and exactly `V-1`
  edge tuples.  Differently labeled parallel edges therefore prevent tree
  status.
- An arborescence requires one in-degree-zero root, in-degree one for every
  other vertex, exactly `V-1` edge tuples, and reachability of every vertex
  from the root.  Loops and labeled parallel edges consequently fail.
- `topological_sort` returns `[]` for an empty graph and `undef` for every
  cyclic graph, including a self-loop.  When several vertices are available,
  choose the smallest ID first.

## Eager results and Perl-wrapped XS cursors

### Policy

Do not make every result lazy.  Materialized results are natural for paths,
cycles, component partitions, topological order, condensation, and predicates
which inherently compute a complete answer.

Lazy interfaces are candidates for:

- vertices;
- edges;
- incoming and outgoing edges;
- neighbors; and
- DFS or BFS traversal where the caller may stop early.

Prefer explicit eager and lazy names over context-dependent returns:

```perl
my $vertices = $graph->vertices;          # array reference
my $iterator = $graph->vertex_iterator;   # Perl callable
```

Bulk eager methods remain important.  A one-value cursor crosses the Perl/XS
boundary once per item, while a batching cursor can amortize that cost.

### Fixed division of responsibility

XPerl `gen`/`yield` suspends a Perl optree and continuation.  It cannot suspend
an arbitrary C call stack inside an XSUB.  XGraph does not need C-stack
suspension.  Traversal state is an explicit ordinary XS cursor object, and a
small Perl closure or generator supplies the callable interface.

The cursor may retain:

```text
strong graph reference
captured structural generation
iterator kind and current position
native DFS stack or BFS queue
visited bitmap
lifecycle flags
```

The XS cursor exposes ordinary methods such as `next` and `next_batch($count)`.
The Perl adapter owns completion and generator protocol behavior.  Returning a
batch is required for enumerations where measurements show that one XS call per
item is material.  Complete algorithms remain eager rather than disguising a
whole-graph computation behind a cursor.

Do not create callable XSUB CVs, store XGraph state in `CvXSUBANY`, expose
private core iterator helpers, or propose a Perl-core iterator C API for
XGraph.  A future project may revisit that decision only after a separate plan
revision.  It is not an XGraph implementation gate.

### Mutation and iterator lifetime

An XS cursor strongly retains its graph handle and captures its structural
generation.  Structural mutation invalidates the cursor.  Its next `next` or
`next_batch` call throws a structured error rather than reading moved native
storage.  The Perl adapter records the corresponding failed state.

The first `vertex_iterator` cursor captures topology generation only.  Renames
and newly declared unused labels do not invalidate an ID enumeration.  A later
cursor which materializes names or labels must state whether it also captures
naming generation before that cursor is added.

The adapter and cursor are interpreter-local and are not cloned into a new
ithread.  Each thread creates its own cursor over a frozen shared store.  A
cursor over a frozen graph never sees structural invalidation.

## Error behavior

XGraph uses the planned `XError` contract.  Version-one conditions map as
follows:

| Code | Required condition |
| --- | --- |
| `XPERL.GRAPH.INVALID_ARGUMENT` | Wrong arity, unknown option, wrong container shape, or input outside a method's documented domain. |
| `XPERL.GRAPH.INVALID_VERTEX_ID` | A required ID is a reference, non-integral, zero, negative, or above the representation maximum. |
| `XPERL.GRAPH.UNKNOWN_VERTEX` | A well-formed ID required to name a live endpoint is absent or deleted, or an add-by-name endpoint is unknown. |
| `XPERL.GRAPH.DUPLICATE_VERTEX_NAME` | Add or rename would reuse an existing normalized name. |
| `XPERL.GRAPH.INVALID_LABEL` | A label is a reference or otherwise cannot be normalized as specified. |
| `XPERL.GRAPH.UNKNOWN_LABEL` | Strict mode receives an undeclared non-empty string label. |
| `XPERL.GRAPH.LABEL_LIMIT` | Registering another label would exceed the representation limit. |
| `XPERL.GRAPH.VERTEX_ID_EXHAUSTED` | Allocating another vertex would exceed the representation limit. |
| `XPERL.GRAPH.EDGE_EXISTS` | Exact `(from,to,label)` tuple already exists. |
| `XPERL.GRAPH.CYCLE_REJECTED` | An acyclic graph insertion would create a loop or other cycle. |
| `XPERL.GRAPH.FROZEN` | An operation attempts to mutate a frozen graph. |
| `XPERL.GRAPH.THREAD_CLONE_REQUIRES_FROZEN` | A child interpreter attempts to use a graph which was mutable when inherited. |
| `XPERL.GRAPH.ALLOCATION_FAILED` | Checked native allocation cannot be satisfied, where Perl has not already thrown its ordinary allocation exception. |
| `XPERL.GRAPH.ITERATOR_INVALIDATED` | Approved future iterator observes incompatible graph generation. |

Predicate and deletion methods return false for a well-formed but absent ID,
name, or edge tuple where their API table says absence is ordinary.  Operations
which require a live vertex throw `UNKNOWN_VERTEX`.  Malformed IDs always throw
`INVALID_VERTEX_ID`; they are not treated as absence.  No code may infer a
condition by parsing a message.

## Ownership, freezing, threads, and cloning

The interpreter-local graph handle has one clear owner.  `DESTROY` is
idempotent and tolerates partially constructed handles.  It detaches native
records before releasing the store or decrementing any SV which can run magic,
`DESTROY`, or reenter XGraph.

`freeze` completes only after every pending mutation is committed.  It then
marks the store immutable with release semantics.  There is no `thaw` and no
copy-on-write mutation.  After freeze, all public mutation methods fail with
`XPERL.GRAPH.FROZEN`, including rename, deletion, label declaration, and graph
option changes.  Read methods must not write lazy caches, counters, or other
state into the shared store.

The initial prototype may use `CLONE_SKIP`, but thread support replaces it
with extension magic carrying `MGf_DUP` and a reviewed `svt_dup` hook.  That
hook has exactly two semantic cases:

1. For a frozen source, allocate a new interpreter-local handle, attach the
   AV/HV values cloned for the child interpreter, point at the same immutable
   native store, and retain the store with its thread-safe reference count.
2. For a mutable source, create no usable native-store reference in the child.
   Mark the child handle unavailable.  Every method except destruction throws
   `XPERL.GRAPH.THREAD_CLONE_REQUIRES_FROZEN`.  Do not freeze the parent, copy
   the mutable store, or allow child access to it implicitly.

`CLONE_SKIP` is class-wide and therefore cannot implement the final policy by
itself.  The duplication hook uses the clone parameter and supported SV
duplication facilities to attach the child's AV/HV values.  It never retains a
parent-interpreter `SV *`.  If any step fails, it releases the store reference,
frees the partial handle, and leaves no magic pointer which destruction could
free twice.

The ordinary `clone` method deep-copies logical state.  A frozen clone remains
frozen.  `mutable_copy` is the explicit way to obtain an independent mutable
graph.  Neither operation shares a store.

Perl closures, generators, and XS cursors are interpreter-local.  The native
cursor class keeps its own class-wide `CLONE_SKIP` permanently and has no
duplication hook.  An inherited wrapper therefore has no usable cursor in the
child.  Code in a child thread creates a new cursor over its cloned handle to
the frozen store.  Thread behavior must be demonstrated in a threaded
DEBUGGING build.  The graph class's `CLONE_SKIP` remains acceptable only before
the dedicated thread packet is complete.

Serialization should describe public vertices, names, labels, and edge tuples
under a versioned schema.  Never serialize native pointers, capacities, packed
words, tombstones, or representation mode as authoritative data.

## Testing strategy

### Contract tests

Cover:

- named and anonymous vertices;
- uniqueness, lookup, rename, deletion, and non-reuse of vertex IDs;
- numeric/string name canonicalization, bytes, UTF-8, empty names, magic, and
  rejected references;
- reserved `undef` and empty labels and their distinct edge tuples;
- loose registration, strict declaration, duplicate declarations, label
  exhaustion, magic, and rejected references;
- duplicate edge tuples and parallel differently labeled edges;
- loops and incoming/outgoing degree accounting;
- rejected cyclic insertion with no partial mutation;
- vertex-ID exhaustion with no counter wrap;
- freeze idempotence and rejection of every mutation after freeze;
- exact lookup and all-label neighbor ranges;
- all path, cycle, component, tree, subgraph, and condensation edge cases;
- eager and lazy result agreement; and
- documented unspecified versus deterministic ordering.

### Native invariants and property tests

Build a small pure-Perl reference model for tests.  Generate random operation
sequences and compare public state after each operation.  Assert:

- adjacency lists are sorted and duplicate-free;
- every outgoing entry has one matching incoming entry;
- degree totals equal the live edge count in both directions;
- every path follows live edge tuples;
- components partition live vertices;
- topological order respects every edge;
- condensation is acyclic; and
- clone mutations do not affect the source.

Run the same behavioral suite against compact 24/8 and wide 32/32 builds.
Exercise boundary IDs and labels without allocating a sixteen-million-vertex
graph by exposing test-only checked encoding helpers.

### Cursor and thread tests

Test:

- empty, singleton, partially consumed, completed, and failed iterators;
- early destruction and workspace cleanup;
- Perl adapter copies sharing one cursor where documented;
- graph destruction while an iterator retains it;
- mutation invalidation before and during traversal;
- exceptions while materializing names or results;
- scalar, list, and void calling contexts;
- compatibility with `next_val`, `running`, `completed`, `failed`, and
  `exhausted` in the Perl adapter;
- single-item and batched cursor agreement;
- frozen-store reads from several ithreads;
- parent destruction while child handles retain the store;
- child destruction before and after parent destruction;
- child AV/HV metadata belonging to the child interpreter;
- mutable inherited handles rejecting all use without touching the parent's
  store; and
- partial duplication failure without leaks or double destruction.

### Memory and platform tests

Run focused tests under normal, DEBUGGING, threaded, non-threaded, ASan, and
LSan configurations.  Use `PERL_DESTRUCT_LEVEL=2` for valid leak-sensitive
runs.  Cover allocation failure, magical inputs, callback exceptions,
destruction during unwind, graph/iterator cycles, and global destruction.

Obtain Windows and 32-bit smoke coverage.  Use explicit unsigned types and
overflow checks; do not assume alignment, byte order, ASCII, or `sizeof(long)`.

## Benchmark plan

Benchmarks justify XS and the compact constraints; they do not define
correctness.  Compare compact and wide builds, the pure-Perl reference model,
and CPAN `Graph` only where semantics align.

Measure:

- construction of sparse DAGs, cyclic graphs, and dense/hub-heavy graphs;
- bytes per live vertex and edge;
- name and label lookup and registration;
- sorted-list insertion/deletion across realistic degree distributions;
- edge membership, neighbor-range scans, and degree queries;
- BFS, DFS, reachability, SCCs, weak components, and topological sort;
- eager bulk returns versus Perl-wrapped one-value and batched XS cursors;
- early-stopped traversal, where laziness should win;
- deep graph cloning, mutable copies, and frozen-store thread sharing; and
- peak memory for algorithm workspaces.

Record Perl revision, compiler, optimization, threading, representation mode,
graph generator, `V`, `E`, degree distribution, label cardinality, and peak
resident memory.  Do not publish one blended score.

## Implementation phases

### Phase 0: prerequisite audit

Audit the existing `../XGraph` repository and its h2xs-style skeleton.  Confirm
extension build requirements, the private error-factory seam, relevant XS
ownership examples, and validation commands against the supported Perl
configurations.  Record Perl-core integration requirements without importing
the module yet.  The public semantics are already fixed above; Phase 0 records
missing prerequisites rather than revisiting them.

Exit condition: Packet 00 in `planning/xgraph-implementation-packets.md` is
complete and no prerequisite ambiguity remains.

### Phase 1: executable reference model

Implement the contract in pure Perl under a private test namespace.  Build
contract, exhaustive small-graph, randomized, and invariant tests before XS.
The reference model is behavioral evidence, not the shipping implementation.

Exit condition: all proposed operations and edge cases have executable tests.

### Phase 2: native storage

Implement graph ownership, name/label boundary maps, vertex allocation,
compact and wide adjacency accessors, sorted lists, transactional edge
mutation, deletion, clone, destruction, and invariant checking.

Exit condition: storage tests pass under DEBUGGING, non-threaded, and sanitizer
builds, with compact/wide equivalence.  A threaded build verifies the temporary
`CLONE_SKIP` behavior before the dedicated thread phase.

### Phase 3: eager algorithms

Implement adjacency queries, DFS/BFS paths and cycles, reachability, acyclic
insertion, components, topological sort, roots, tree/arborescence operations,
subgraphs, and condensation entirely in XS.

Exit condition: differential and property tests pass for randomized graphs.

### Phase 4: standalone freeze semantics

Implement the interpreter-local handle/native-store split, `freeze`,
`is_frozen`, and `mutable_copy`.  Retain `CLONE_SKIP`.  Do not implement magic
duplication, shared allocation, cross-process shared memory, or memory-mapped
persistence in the standalone repository.

Exit condition: freeze and copy tests establish immutability and ownership;
thread tests continue to establish only the declared `CLONE_SKIP` behavior.

### Phase 5: standalone eager baseline

Finish standalone module POD, Changes, examples, broad tests, platform smoke
coverage, and benchmark methodology.  Keep public errors behind the private
factory so the later core import can bind them to `XError` without changing
call sites.

Exit condition: the standalone eager distribution is a tested release
candidate and no Perl-core source change is required to build or use it.

### Phase 6: standalone cursor adapter

Implement one ordinary XS cursor and a thin Perl closure wrapper.  Add a
generator adapter only when running on a Perl which supplies the required
generator facility.  Add `next_batch` if measurements show material per-item
boundary cost.  Validate completion, failure, invalidation, destruction, and
interpreter-local semantics.  Do not create callable XSUB CVs.

Exit condition: evidence identifies which operations benefit from laziness and
the adapter contract requires no new Perl-core C API.

### Phase 7: import into Perl core

Import the reviewed standalone distribution into `dist/XGraph`.  Add core
build registration, `MANIFEST`, maintainer metadata, release notes, the real
`XError` binding, and generator integration tests against the target XPerl.
Retain `CLONE_SKIP` during the import.  Treat the import as a snapshot or
permanent move chosen explicitly before the packet begins; do not leave two
writable authoritative copies.

Exit condition: the imported distribution builds in core and its focused
error, cursor, and generator tests pass.

### Phase 8: XPerl ithread support

Replace `CLONE_SKIP` with the specified magic duplication hook, shared store
allocation, thread-safe store lifetime, frozen-store sharing, and unavailable
child handles for inherited mutable graphs.

Exit condition: focused threaded DEBUGGING, destruction, failure-injection,
and leak tests establish the fixed ownership design.

### Phase 9: final core validation

Complete integration documentation and run focused, porting, and broad core
tests.  Record unavailable platform and sanitizer coverage.

Exit condition: the imported distribution meets its release requirements and
has no remaining standalone/core semantic difference.

## Deferred features and gated decisions

These items are outside the baseline implementation.  An implementation agent
must stop at the named gate rather than select a design:

1. **Vertex and edge handle objects:** deferred until ID/name APIs have real
   use.  Do not create handle classes in version one.
2. **Reference or overloaded-object names and labels:** deferred.  Version one
   rejects every reference.
3. **Run-time wide graphs or automatic promotion:** deferred.  Wide mode is a
   compile-time equivalence configuration only.
4. **Lazy cursor adapters:** begin only after eager API benchmarks and the
   cursor packet are approved.  They remain Perl wrappers over ordinary XS
   cursor objects.
5. **Callable XSUB or core iterator C API:** not part of the XGraph plan.  It
   requires an explicit future plan revision rather than an implementation
   experiment.
6. **Cross-process shared memory:** deferred.  Frozen ithread sharing uses the
   ordinary process address space, not `mmap` or a persistent shared segment.
7. **Binary serialization:** deferred.  Any future format serializes public
   logical state, not native packed arrays.
8. **Storage or algorithm substitutions:** an SCC implementation, growth
   factor, or search helper may change only when tests remain identical and a
   benchmark or auditability argument is recorded.

The executable work breakdown is in
`planning/xgraph-implementation-packets.md`.  Each packet defines prerequisites,
allowed scope, required results, validation, and conditions which require the
agent to stop and report rather than improvise.
