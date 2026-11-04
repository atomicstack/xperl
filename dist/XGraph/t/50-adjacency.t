use strict;
use warnings;

use Test::More tests => 16;
use XGraph;

my $graph = XGraph->new;
my $a = $graph->add_vertex('a');
my $b = $graph->add_vertex('b');
my $c = $graph->add_vertex('c');
$graph->add_edge_by_ids($a, $c, 'z');
$graph->add_edge_by_ids($a, $b, 'b');
$graph->add_edge_by_ids($a, $b, 'a');
$graph->add_edge_by_ids($c, $a, 'back');

is($graph->out_degree($a), 3, 'out degree counts edge tuples');
is($graph->in_degree($b), 2, 'in degree counts labels');
is($graph->out_degree($b), 0, 'empty out degree');
is_deeply($graph->out_neighbors($a), [$b, $b, $c],
          'neighbors follow packed ordering');
is_deeply($graph->in_neighbors($b), [$a, $a], 'incoming neighbors');
is_deeply($graph->out_edges($a),
          [[$a, $b, 'b'], [$a, $b, 'a'], [$a, $c, 'z']],
          'outgoing edges are sorted');
is_deeply($graph->in_edges($a), [[$c, $a, 'back']], 'incoming edges');
is_deeply($graph->edges,
          [[$a, $b, 'b'], [$a, $b, 'a'], [$a, $c, 'z'], [$c, $a, 'back']],
          'whole-edge order');

ok($graph->delete_vertex_by_id($b), 'vertex deletion');
is($graph->edge_count, 2, 'incident edges are deleted');
is($graph->out_degree($a), 1, 'out degree after vertex deletion');
is($graph->in_degree($a), 1, 'in degree after vertex deletion');
is_deeply($graph->edges, [[$a, $c, 'z'], [$c, $a, 'back']],
          'reciprocal adjacency remains consistent');

$graph->add_edge_by_ids($a, $a, 'loop');
is($graph->edge_count, 3, 'loops are allowed in a general graph');
is_deeply($graph->out_neighbors($a), [$a, $c], 'loop ordering');
is($graph->in_degree($a), 2, 'loop contributes to both degrees');
