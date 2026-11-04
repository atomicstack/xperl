use strict;
use warnings;

# Provenance: ported from the larger directed cases in Graph 0.9735
# (7d3f3ea), t/59_dfs.t and t/60_bfs.t.  XGraph has no traversal object or
# BFS iterator, so this checks its eager DFS orders, shortest-path BFS result,
# and topological-order invariants instead.

use Test::More;
use XGraph;

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d e f g h i j k);
for my $edge (
    [qw(a b)], [qw(b c)], [qw(c d)], [qw(d e)],
    [qw(b f)], [qw(f g)], [qw(c h)], [qw(h i)],
    [qw(j k)],
) {
    $g->add_edge_by_ids($id{$edge->[0]}, $id{$edge->[1]});
}

is_deeply($g->dfs_preorder($id{a}),
          [map $id{$_}, qw(a b c d e h i f g)],
          'DFS preorder follows the complete directed branch');
is_deeply($g->dfs_postorder($id{a}),
          [map $id{$_}, qw(e d i h c g f b a)],
          'DFS postorder closes descendants before parents');
is_deeply($g->dfs_reverse_postorder($id{a}),
          [map $id{$_}, qw(a b f g c h i d e)],
          'reverse postorder is the reverse DFS finish order');

is_deeply($g->shortest_path($id{a}, $id{g}),
          [map $id{$_}, qw(a b f g)],
          'shortest_path follows the shortest BFS route');
is_deeply($g->shortest_path($id{a}, $id{i}),
          [map $id{$_}, qw(a b c h i)],
          'shortest_path handles a second branch');
ok(!defined $g->shortest_path($id{a}, $id{k}),
   'a disconnected root is not reachable');

my $order = $g->topological_sort;
my %position;
$position{$order->[$_]} = $_ for 0 .. $#$order;
is(scalar @$order, $g->vertex_count,
   'topological sort includes every vertex in this DAG');
for my $edge (@{ $g->edges }) {
    ok($position{$edge->[0]} < $position{$edge->[1]},
       'topological order respects each edge in the larger DAG');
}

my $cycle_error = eval { $g->add_edge_by_ids($id{i}, $id{c}); 1 };
ok($cycle_error, 'the unrestricted graph accepts a cycle');
ok(!$g->is_acyclic, 'the added back-edge makes the graph cyclic');
ok(!defined $g->topological_sort, 'a cyclic graph has no topological order');

done_testing;
