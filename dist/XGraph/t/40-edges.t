use strict;
use warnings;

use Test::More tests => 17;
use XGraph;

my $graph = XGraph->new;
my $a = $graph->add_vertex('a');
my $b = $graph->add_vertex('b');
ok($graph->add_edge_by_ids($a, $b, 'calls'), 'add edge by IDs');
ok($graph->has_edge_by_ids($a, $b, 'calls'), 'find edge by IDs');
ok($graph->has_edge_by_names('a', 'b', 'calls'), 'find edge by names');
is($graph->edge_count, 1, 'edge count');

my $duplicate = eval { $graph->add_edge_by_ids($a, $b, 'calls'); 1 };
ok(!$duplicate, 'duplicate tuple is rejected');
like($@, qr/EDGE_EXISTS/, 'duplicate edge error');

ok($graph->add_edge_by_ids($a, $b, 'reads'), 'parallel label is allowed');
is($graph->edge_count, 2, 'parallel label increments count');
is_deeply($graph->edges_between($a, $b),
          [[$a, $b, 'calls'], [$a, $b, 'reads']], 'edges_between');
ok($graph->delete_edge_by_names('a', 'b', 'calls'), 'delete by names');
ok(!$graph->has_edge_by_ids($a, $b, 'calls'), 'deleted edge is absent');
ok(!$graph->delete_edge_by_ids($a, $b, 'calls'), 'missing deletion is false');
is($graph->edge_count, 1, 'edge count after deletion');

my $unknown = eval { $graph->add_edge_by_names('missing', 'b'); 1 };
ok(!$unknown, 'unknown named endpoint is rejected');
like($@, qr/UNKNOWN_VERTEX/, 'unknown endpoint error');

my $bad = eval { $graph->add_edge_by_ids({}, $b); 1 };
ok(!$bad, 'reference endpoint is rejected');
like($@, qr/INVALID_VERTEX_ID/, 'invalid endpoint error');
