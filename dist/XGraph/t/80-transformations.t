use strict;
use warnings;

use Test::More tests => 15;
use XGraph;

my $graph = XGraph->new;
my @id = map { $graph->add_vertex("v$_") } 1 .. 5;
my ($a, $b, $c, $d, $e) = @id;
$graph->add_edge_by_ids($a, $b, 'ab');
$graph->add_edge_by_ids($b, $a, 'ba');
$graph->add_edge_by_ids($b, $c, 'bc');
$graph->add_edge_by_ids($d, $e, 'de');

my $subgraph = $graph->induced_subgraph([$a, $b, $b]);
is_deeply($subgraph->vertex_ids, [$a, $b], 'induced vertices preserve IDs');
is_deeply($subgraph->edges, [[$a, $b, 'ab'], [$b, $a, 'ba']],
          'induced edges');
is($subgraph->vertex_name_by_id($a), 'v1', 'induced names');
ok(!$subgraph->is_frozen, 'induced result is mutable');
$subgraph->add_vertex('only-subgraph');
ok(!defined $graph->vertex_id_by_name('only-subgraph'),
   'induced result is independent');

my $condensation = $graph->condensation;
is_deeply($condensation->{components}, [[$a, $b], [$c], [$d], [$e]],
          'condensation components');
is_deeply($condensation->{component_of},
          [undef, 1, 1, 2, 3, 4], 'component mapping');
my $dag = $condensation->{graph};
is_deeply($dag->vertex_ids, [1, 2, 3, 4], 'condensed IDs');
is_deeply($dag->edges, [[1, 2, 'bc'], [3, 4, 'de']],
          'condensed edges');
ok($dag->is_acyclic, 'condensation is acyclic');
ok(!$dag->is_frozen, 'condensation is mutable');
$dag->add_vertex;
is($dag->vertex_count, 5, 'condensation can be mutated');

is_deeply($graph->reachability_roots, [$a, $d], 'reachability roots');
my $frozen = $graph->clone;
$frozen->freeze;
my $frozen_subgraph = $frozen->induced_subgraph([$a]);
ok(!$frozen_subgraph->is_frozen, 'derived graph from frozen source is mutable');
is_deeply($frozen_subgraph->vertex_ids, [$a], 'frozen induced vertex');
