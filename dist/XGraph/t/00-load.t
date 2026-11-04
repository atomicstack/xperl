use strict;
use warnings;

use Test::More tests => 3;

BEGIN { use_ok('XGraph') }

my $graph = XGraph->new;
ok($graph, 'constructor returns an object');
can_ok($graph, qw(add_vertex add_edge_by_ids vertex_ids edges freeze));
