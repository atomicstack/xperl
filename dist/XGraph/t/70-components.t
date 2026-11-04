use strict;
use warnings;

use Test::More tests => 13;
use XGraph;

my $graph = XGraph->new;
my @id = map { $graph->add_vertex } 1 .. 6;
my ($a, $b, $c, $d, $e, $f) = @id;
$graph->add_edge_by_ids($a, $b);
$graph->add_edge_by_ids($b, $a);
$graph->add_edge_by_ids($b, $c);
$graph->add_edge_by_ids($c, $d);
$graph->add_edge_by_ids($d, $c);
$graph->add_edge_by_ids($e, $f);

is_deeply($graph->strongly_connected_components,
          [[$a, $b], [$c, $d], [$e], [$f]], 'strong components');
is_deeply($graph->cyclic_strongly_connected_components,
          [[$a, $b], [$c, $d]], 'cyclic strong components');
is_deeply($graph->weakly_connected_components,
          [[$a, $b, $c, $d], [$e, $f]], 'weak components');
is_deeply($graph->source_vertices, [$e], 'source vertices');
is_deeply($graph->sink_vertices, [$f], 'sink vertices');
is_deeply($graph->loop_vertices, [], 'loop vertices');

my $dag = XGraph->new(acyclic => 1);
my $x = $dag->add_vertex;
my $y = $dag->add_vertex;
my $z = $dag->add_vertex;
$dag->add_edge_by_ids($x, $y);
$dag->add_edge_by_ids($y, $z);
ok($dag->is_acyclic, 'acyclic option accepts DAG');
my $error = eval { $dag->add_edge_by_ids($z, $x); 1 };
ok(!$error, 'acyclic option rejects cycle');
like($@, qr/CYCLE_REJECTED/, 'cycle rejection error');
is_deeply($dag->edges, [[$x, $y, undef], [$y, $z, undef]],
          'cycle rejection does not mutate');
is_deeply($dag->topological_sort, [$x, $y, $z], 'DAG topological order');

my $empty = XGraph->new;
is_deeply($empty->topological_sort, [], 'empty topological sort');
ok($empty->is_acyclic, 'empty graph is acyclic');
