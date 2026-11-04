use strict;
use warnings;

use Test::More tests => 8;
use XGraph;

my $graph = XGraph->new(acyclic => 1, strict_labels => 1);
ok($graph, 'accepted the documented constructor options');
is($graph->vertex_count, 0, 'new graph has no vertices');
is_deeply($graph->labels, [undef, ''], 'reserved labels are exposed');
is($graph->label_count, 2, 'reserved labels count');

my $error = eval { XGraph->new(unknown => 1); 1 };
ok(!$error, 'unknown constructor option is rejected');
like($@, qr/XPERL\.GRAPH\.INVALID_ARGUMENT/, 'structured option error');

my $id = $graph->add_vertex;
is($id, 1, 'IDs start at one');
ok(!defined $graph->vertex_name_by_id($id), 'anonymous vertex has no name');
