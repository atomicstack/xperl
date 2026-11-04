use strict;
use warnings;

use Test::More tests => 11;
use XGraph;

my $graph = XGraph->new;
my @ids = map { $graph->add_vertex } 1 .. 4;
my $cursor = $graph->_vertex_cursor;
is($cursor->next, 1, 'cursor returns first vertex');
is_deeply($cursor->next_batch(2), [2, 3], 'cursor returns a batch');
is($cursor->next, 4, 'cursor resumes after a batch');
ok(!defined $cursor->next, 'cursor reports exhaustion');
ok(!defined $cursor->next_batch(2), 'exhausted batch is undef');

my $next = $graph->vertex_iterator;
is_deeply([map { $next->() } 1 .. 4], [1, 2, 3, 4],
          'Perl closure wraps cursor state');
ok(!defined $next->(), 'closure reports exhaustion');

my $invalid = $graph->_vertex_cursor;
$graph->add_vertex;
my $error = eval { $invalid->next; 1 };
ok(!$error, 'structural mutation invalidates cursor');
like($@, qr/ITERATOR_INVALIDATED/, 'cursor invalidation error');

my $frozen = XGraph->new;
$frozen->add_vertex;
$frozen->freeze;
my $frozen_cursor = $frozen->_vertex_cursor;
is($frozen_cursor->next, 1, 'frozen graph cursor');
ok(!defined $frozen_cursor->next, 'frozen cursor completes');
