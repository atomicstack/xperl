use strict;
use warnings;

use Config;
use Scalar::Util qw(blessed);
use Test::More;

plan skip_all => 'Perl was built without ithreads'
    unless $Config{useithreads};

require threads;
use XGraph;

my $graph = XGraph->new;
$graph->add_vertex('thread-local');
my $cursor = $graph->_vertex_cursor;
my $thread = threads->create(sub {
    my ($g, $c) = @_;
    # CLONE_SKIP leaves unblessed references to undefined scalars.
    return (!blessed($g) && ref($g) eq 'SCALAR' && !defined($$g)
        && !blessed($c) && ref($c) eq 'SCALAR' && !defined($$c)) ? 1 : 0;
}, $graph, $cursor);
is($thread->join, 1, 'standalone objects retain class-wide CLONE_SKIP');

done_testing;
