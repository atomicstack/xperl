use strict;
use warnings;

use Test::More;
use XGraph;

my $g = XGraph->new;
my ($a, $b, $c, $d, $e) = map { $g->add_vertex($_) } qw(a b c d e);

$g->add_edge_by_ids($a, $b);
$g->add_edge_by_ids($a, $b, 'alternate');
$g->add_edge_by_ids($c, $a);
$g->add_edge_by_ids($a, $a);
$g->add_edge_by_ids($d, $c);

is_deeply($g->undirected_neighbors($a), [$a, $b, $c],
          'undirected neighbors combine both directions and deduplicate');
is_deeply($g->undirected_neighbors($b), [$a],
          'an incoming-only relationship is visible');
is_deeply($g->undirected_neighbors($c), [$a, $d],
          'an outgoing-only relationship is visible');
is_deeply($g->undirected_neighbors($d), [$c],
          'the reverse endpoint sees the same adjacency');
is_deeply($g->undirected_neighbors($e), [],
          'an isolated vertex has no undirected neighbors');

ok($g->has_path($a, $b), 'directed path remains available');
ok(!$g->has_path($b, $a), 'undirected neighbors do not create reverse paths');
is($g->edge_count, 5, 'undirected interpretation does not alter edge count');
is($g->out_degree($a), 3, 'out degree remains directed and label-sensitive');
is($g->in_degree($a), 2, 'in degree remains directed and label-sensitive');

my $tree = XGraph->new;
my ($x, $y, $z) = map { $tree->add_vertex } 1 .. 3;
$tree->add_edge_by_ids($x, $y);
$tree->add_edge_by_ids($z, $y);
ok($tree->is_tree, 'a one-way chain is a tree under undirected connectivity');
ok(!$tree->has_path($y, $x), 'tree recognition does not make paths undirected');

my $reciprocal = XGraph->new;
my ($r, $s) = map { $reciprocal->add_vertex } 1 .. 2;
$reciprocal->add_edge_by_ids($r, $s);
$reciprocal->add_edge_by_ids($s, $r);
ok(!$reciprocal->is_tree,
   'reciprocal directed edges are two relationships, not one tree edge');

done_testing;
