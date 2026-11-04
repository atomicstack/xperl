# Tests ported from CPAN `Graph`

These files are deliberately separate from XGraph's native test suite.  They
are mathematical compatibility checks derived from the locally downloaded
CPAN `Graph` distribution, version 0.9735, repository commit `7d3f3ea`.

Each `graph-ported-*.t` file names the source test files which motivated it and
contains a provenance comment at the top.  The tests use XGraph's API and
assert graph properties rather than CPAN `Graph`'s object stringification,
scalar-context conventions, or exact method names.

The current port consists of thirteen files and 1,497 assertions.  In addition
to the focused vertex, adjacency, path, cycle, component, subgraph, and
traversal cases, it includes larger traversal scenarios, copy/clone
independence, structural edge cases, all-cessor behavior, and an independent
reachability and shortest-distance matrix checked against XGraph.

The port keeps directed simple-graph cases where the two libraries describe
the same mathematical operation.  It adapts the cases as follows:

- CPAN `Graph` vertex names become XGraph's stable numeric IDs after explicit
  name-to-ID lookup.
- XGraph's array-reference result shapes are compared directly or normalized
  to sets where the source test did not specify an order.
- XGraph edge labels are omitted unless a source case has a direct labelled
  relationship equivalent.  XGraph's labelled parallel-edge behavior is
  tested separately by the native suite.
- XGraph's directed-only model omits undirected, hyperedge, weighted-edge,
  attribute, reference-vertex, and multivertex cases.
- XGraph's explicit path semantics are used.  In particular, a zero-length
  path from a vertex to itself is not a cycle, while a cycle must be closed.

The source coverage is intentionally recorded here rather than hidden in a
single generated test file:

- `graph-ported-adjacency.t` — `t/16_edges.t`, `t/39_edges_at.t`,
  `t/40_edges_from.t`, `t/41_edges_to.t`, `t/56_neighbourhood.t`, and
  `t/57_degree.t`.
- `graph-ported-all-cessors.t` — `t/84_all_cessors.t`.
- `graph-ported-components.t` — `t/61_connected.t`, `t/63_scc.t`, and the
  directed part of `t/84_all_cessors.t`.
- `graph-ported-connections.t` — the directed source, sink, and loop cases
  from `t/58_connections.t`.
- `graph-ported-copy.t` — the directed portions of `t/67_copy.t`.
- `graph-ported-cycles.t` — `t/45_add_cycle.t` and cycle cases from
  `t/59_dfs.t`.
- `graph-ported-paths.t` — `t/42_add_path.t` and directed portions of
  `t/72_transitive.t`.
- `graph-ported-structural.t` — `t/16_edges.t`, `t/26_multiedged.t`, and
  `t/66_simple.t`.
- `graph-ported-subgraph.t` — directed vertex-induced cases from
  `t/85_subgraph.t`.
- `graph-ported-transitive-matrix.t` — directed transitive cases from
  `t/72_transitive.t` and the larger SCC graph in `t/63_scc.t`.
- `graph-ported-traversals.t` — `t/59_dfs.t` and `t/60_bfs.t`.
- `graph-ported-traversal-scenarios.t` — larger directed cases from
  `t/59_dfs.t` and `t/60_bfs.t`.
- `graph-ported-vertices.t` — `t/10_has_vertices.t`, `t/11_vertices.t`,
  `t/12_has_vertex.t`, and `t/14_delete_vertex.t`.

No port is copied into the existing XGraph tests.  A failure in one of these
files therefore identifies either a mathematical regression or an explicit
semantic difference which needs review.
