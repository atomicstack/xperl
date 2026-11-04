use strict;
use warnings;

# Provenance: ported from Graph 0.9735 (7d3f3ea), primarily t/59_dfs.t and
# t/60_bfs.t.  XGraph exposes eager DFS orders and shortest paths rather than
# Graph's traversal objects, so this file checks order where deterministic and
# otherwise checks the traversal invariants.

use Test::More;
use XGraph;

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d e f g h);

for my $edge ([qw(a b)], [qw(b c)], [qw(b d)], [qw(a e)], [qw(e f)],
              [qw(g h)]) {
    $g->add_edge_by_ids($id{$edge->[0]}, $id{$edge->[1]});
}

is_deeply($g->dfs_preorder($id{a}),
          [$id{a}, $id{b}, $id{c}, $id{d}, $id{e}, $id{f}],
          'preorder follows sorted outgoing adjacency');
is_deeply($g->dfs_postorder($id{a}),
          [$id{c}, $id{d}, $id{b}, $id{f}, $id{e}, $id{a}],
          'postorder emits each child before its parent');
is_deeply($g->dfs_reverse_postorder($id{a}),
          [$id{a}, $id{e}, $id{f}, $id{b}, $id{d}, $id{c}],
          'reverse postorder reverses the postorder result');

for my $method (qw(dfs_preorder dfs_postorder dfs_reverse_postorder)) {
    my $result = $g->$method($id{a});
    my %seen;
    $seen{$_}++ for @$result;
    is(scalar keys %seen, 6, "$method visits six reachable vertices");
    is_deeply([sort { $a <=> $b } keys %seen],
              [sort { $a <=> $b } map $id{$_}, qw(a b c d e f)],
              "$method visits exactly the reachable set");
    ok(!grep($_ > $id{f}, @$result), "$method does not cross to another root");
}

my $topological = $g->topological_sort;
is_deeply($topological,
          [$id{a}, $id{b}, $id{c}, $id{d},
           $id{e}, $id{f}, $id{g}, $id{h}],
          'topological sort is deterministic for this DAG');

my %position;
$position{$topological->[$_]} = $_ for 0 .. $#$topological;
for my $edge (@{ $g->edges }) {
    ok($position{$edge->[0]} < $position{$edge->[1]},
       'topological order respects every directed edge');
}

is_deeply($g->source_vertices, [$id{a}, $id{g}],
          'source vertices are the two roots');
is_deeply($g->sink_vertices, [$id{c}, $id{d}, $id{f}, $id{h}],
          'sink vertices have no outgoing edges');

done_testing;
