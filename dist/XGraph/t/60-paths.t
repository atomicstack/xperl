use strict;
use warnings;

use Test::More tests => 29;
use XGraph;

my $graph = XGraph->new;
my @id = map { $graph->add_vertex } 1 .. 5;
my ($a, $b, $c, $d, $e) = @id;
$graph->add_edge_by_ids($a, $b);
$graph->add_edge_by_ids($b, $c);
$graph->add_edge_by_ids($a, $d);
$graph->add_edge_by_ids($d, $c);
$graph->add_edge_by_ids($c, $e);

ok($graph->has_path($a, $e), 'path exists');
ok(!$graph->has_path($e, $a), 'reverse path is absent');
is_deeply($graph->path($a, $e), [$a, $b, $c, $e], 'path result');
is_deeply($graph->shortest_path($a, $e), [$a, $b, $c, $e],
          'shortest path result');
ok(!defined $graph->path($e, $a), 'missing path is undef');

is_deeply($graph->descendants($a), [$a, $b, $c, $d, $e], 'descendants');
is_deeply($graph->strict_descendants($a), [$b, $c, $d, $e],
          'strict descendants');
is_deeply($graph->ancestors($c), [$a, $b, $c, $d], 'ancestors');
is_deeply($graph->strict_ancestors($c), [$a, $b, $d], 'strict ancestors');

is_deeply($graph->dfs_preorder($a), [$a, $b, $c, $e, $d], 'DFS preorder');
is_deeply($graph->dfs_postorder($a), [$e, $c, $b, $d, $a], 'DFS postorder');
is_deeply($graph->dfs_reverse_postorder($a), [$a, $d, $b, $c, $e],
          'reverse postorder');
is_deeply($graph->topological_sort, [$a, $b, $d, $c, $e],
          'topological sort uses minimum available ID');
ok($graph->is_acyclic, 'DAG is acyclic');
ok(!$graph->cycle, 'DAG has no cycle');
ok(!defined $graph->shortest_cycle, 'DAG has no shortest cycle');

$graph->add_edge_by_ids($e, $a, 'return');
ok(!$graph->is_acyclic, 'cycle is detected');
is_deeply($graph->cycle, [$a, $b, $c, $e, $a], 'cycle result');
is_deeply($graph->shortest_cycle, [$a, $b, $c, $e, $a],
          'shortest cycle result');
is_deeply($graph->path($a, $a), [$a, $b, $c, $e, $a],
          'path to self finds a cycle');
is_deeply($graph->strict_descendants($a), [$a, $b, $c, $d, $e],
          'strict descendants include start through a cycle');
is_deeply($graph->strict_ancestors($a), [$a, $b, $c, $d, $e],
          'strict ancestors include start through a cycle');

my $dead_end = XGraph->new;
my ($dead_a, $dead_b, $dead_c) = map { $dead_end->add_vertex } 1 .. 3;
$dead_end->add_edge_by_ids($dead_a, $dead_b);
$dead_end->add_edge_by_ids($dead_b, $dead_c);
$dead_end->add_edge_by_ids($dead_c, $dead_b);
ok(!defined $dead_end->path($dead_a, $dead_a),
   'self-path search terminates when a downstream cycle excludes the start');

my $tree = XGraph->new;
my $root = $tree->add_vertex;
my $leaf = $tree->add_vertex;
$tree->add_edge_by_ids($root, $leaf);
ok($tree->is_tree, 'two-vertex tree');
ok($tree->is_arborescence, 'two-vertex arborescence');
is($tree->arborescence_root, $root, 'arborescence root');

my $paths = XGraph->new;
my $p = $paths->add_vertex;
my $q = $paths->add_vertex;
my $r = $paths->add_vertex;
$paths->add_edge_by_ids($p, $q, 'one');
$paths->add_edge_by_ids($p, $q, 'two');
$paths->add_edge_by_ids($q, $r, 'three');
is($paths->delete_paths($p, $r), 3, 'delete_paths removes all labels');
is($paths->edge_count, 0, 'delete_paths removes the selected paths');
is($paths->delete_paths($p, $r), 0, 'delete_paths reports no remaining path');
