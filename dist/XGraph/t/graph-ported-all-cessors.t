use strict;
use warnings;

# Provenance: ported from Graph 0.9735 (7d3f3ea), t/84_all_cessors.t.
# Graph's all_successors/all_predecessors/all_neighbors methods are expressed
# through XGraph's directed reachability and incoming/outgoing neighbour APIs.
# Radius-specific methods are omitted because XGraph has no radius API.

use Test::More;
use XGraph;

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d e f g);
for my $edge ([qw(a b)], [qw(a c)], [qw(b d)], [qw(b e)],
              [qw(c f)], [qw(c g)]) {
    $g->add_edge_by_ids($id{$edge->[0]}, $id{$edge->[1]});
}

sub ids { [map $id{$_}, @_ ] }

is_deeply($g->strict_descendants($id{a}), ids(qw(b c d e f g)),
          'all successors of a');
is_deeply($g->strict_descendants($id{b}), ids(qw(d e)),
          'all successors of b');
is_deeply($g->strict_descendants($id{c}), ids(qw(f g)),
          'all successors of c');
is_deeply($g->strict_descendants($id{d}), [],
          'a leaf has no successors');

is_deeply($g->strict_ancestors($id{a}), [],
          'the source has no predecessors');
is_deeply($g->strict_ancestors($id{b}), ids(qw(a)),
          'all predecessors of b');
is_deeply($g->strict_ancestors($id{d}), ids(qw(a b)),
          'all predecessors of d');
is_deeply($g->strict_ancestors($id{g}), ids(qw(a c)),
          'all predecessors of g');

is_deeply($g->descendants($id{a}), ids(qw(a b c d e f g)),
          'reachable includes the source');
is_deeply($g->ancestors($id{d}), ids(qw(a b d)),
          'reverse reachability includes the target');

sub unique_sorted {
    my %seen;
    $seen{$_}++ for map @$_, @_;
    return [sort { $a <=> $b } keys %seen];
}

is_deeply(unique_sorted($g->out_neighbors($id{a}), $g->in_neighbors($id{a})),
          ids(qw(b c)),
          'all neighbours of a combine both directions');
is_deeply(unique_sorted($g->out_neighbors($id{b}), $g->in_neighbors($id{b})),
          ids(qw(a d e)),
          'all neighbours of b combine predecessors and successors');
is_deeply(unique_sorted($g->out_neighbors($id{d}), $g->in_neighbors($id{d})),
          ids(qw(b)),
          'all neighbours of a leaf contain its predecessor');

my $cycle = XGraph->new;
my ($x, $y) = map { $cycle->add_vertex($_) } qw(x y);
$cycle->add_edge_by_ids($x, $x);
$cycle->add_edge_by_ids($x, $y);
$cycle->add_edge_by_ids($y, $x);
is_deeply($cycle->strict_descendants($x), [$x, $y],
          'successors include the start when a cycle returns to it');
is_deeply($cycle->strict_ancestors($x), [$x, $y],
          'predecessors include the start when a cycle returns to it');
is_deeply($cycle->out_neighbors($x), [$x, $y],
          'a loop appears once in outgoing neighbours');
is_deeply($cycle->in_neighbors($x), [$x, $y],
          'a loop appears once in incoming neighbours');

done_testing;
