use strict;
use warnings;

use Test::More tests => 22;
use XGraph;

my $graph = XGraph->new;
my $a = $graph->add_vertex('a');
my $b = $graph->add_vertex;
my $empty = $graph->add_vertex('');
is_deeply($graph->vertex_ids, [$a, $b, $empty], 'IDs are ordered');
is($graph->vertex_id_by_name('a'), $a, 'name lookup');
is($graph->vertex_id_by_name(0 + 0), undef, 'missing name is ordinary absence');
is($graph->vertex_name_by_id($empty), '', 'empty name is distinct');
ok(!$graph->has_vertex_id(99), 'unknown ID is absent');
ok(!$graph->has_vertex_id(0), 'zero ID is ordinary absence');
ok(!$graph->has_vertex_id(-1), 'negative ID is ordinary absence');
ok(!$graph->has_vertex_id({}), 'reference ID is ordinary absence');

my $duplicate = eval { $graph->add_vertex('a'); 1 };
ok(!$duplicate, 'duplicate name is rejected');
like($@, qr/DUPLICATE_VERTEX_NAME/, 'duplicate name error');

is($graph->rename_vertex($b, 'b'), $graph, 'rename returns receiver');
is($graph->vertex_id_by_name('b'), $b, 'renamed vertex is indexed');
is($graph->rename_vertex($b, undef), $graph, 'rename can remove a name');
ok(!defined $graph->vertex_id_by_name('b'), 'removed name is absent');

ok($graph->delete_vertex_by_name('a'), 'delete by name');
ok(!$graph->has_vertex_id($a), 'deleted vertex is absent');
is($graph->add_vertex('new'), 4, 'deleted IDs are not reused');
is($graph->delete_vertex_by_id(99), 0, 'deleting an absent ID returns false');
my $numeric_name = $graph->add_vertex(42);
is($graph->vertex_name_by_id($numeric_name), '42', 'numeric names are stringified');
is($graph->vertex_id_by_name('42'), $numeric_name,
   'stringified numeric name is indexed');

my $reference_error = eval { $graph->add_vertex({}); 1 };
ok(!$reference_error, 'reference name is rejected');
like($@, qr/INVALID_ARGUMENT/, 'reference name error');
