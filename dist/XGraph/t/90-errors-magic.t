use strict;
use warnings;

use Test::More tests => 10;
use XGraph;

my $graph = XGraph->new;
my $id = $graph->add_vertex('a');
$graph->freeze;
ok($graph->is_frozen, 'freeze marks graph immutable');
is($graph->freeze, $graph, 'freeze is idempotent and returns receiver');

for my $action (
    sub { $graph->add_vertex('b') },
    sub { $graph->rename_vertex($id, 'b') },
    sub { $graph->declare_label('x') },
    sub { $graph->delete_vertex_by_id($id) },
) {
    my $ok = eval { $action->(); 1 };
    ok(!$ok, 'mutation is rejected after freeze');
    like($@, qr/FROZEN/, 'frozen error is structured');
}
