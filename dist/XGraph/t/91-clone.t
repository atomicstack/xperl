use strict;
use warnings;

use Test::More tests => 12;
use XGraph;

my $graph = XGraph->new;
my $a = $graph->add_vertex('a');
my $b = $graph->add_vertex('b');
$graph->add_edge_by_ids($a, $b, 'edge');

my $clone = $graph->clone;
is_deeply($clone->vertex_ids, $graph->vertex_ids, 'clone copies vertices');
is_deeply($clone->edges, $graph->edges, 'clone copies edges');
ok(!$clone->is_frozen, 'mutable clone remains mutable');
$clone->add_vertex('clone-only');
ok(!defined $graph->vertex_id_by_name('clone-only'),
   'clone mutation does not affect source');

$graph->freeze;
my $frozen = $graph->clone;
ok($frozen->is_frozen, 'clone preserves frozen state');
my $mutable = $graph->mutable_copy;
ok(!$mutable->is_frozen, 'mutable_copy clears frozen state');
$mutable->add_vertex('mutable-copy');
ok(defined $mutable->vertex_id_by_name('mutable-copy'),
   'mutable copy accepts mutation');
is($graph->vertex_count, 2, 'source is unchanged');

is_deeply($frozen->labels, $graph->labels, 'frozen clone copies labels');
is($frozen->vertex_id_by_name('a'), $a, 'frozen clone preserves names');
is($mutable->vertex_id_by_name('a'), $a, 'mutable copy preserves IDs');
ok($mutable->has_edge_by_ids($a, $b, 'edge'),
   'mutable copy preserves edge tuples');
