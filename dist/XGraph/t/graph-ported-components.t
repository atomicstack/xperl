use strict;
use warnings;

# Provenance: ported from Graph 0.9735 (7d3f3ea), primarily t/61_connected.t,
# t/63_scc.t, and the reachability cases in t/84_all_cessors.t.  Component
# arrays are canonicalized because Graph did not promise the same outer order;
# XGraph's deterministic ordering is checked separately where useful.

use Test::More;
use XGraph;

sub component_signature {
    my ($components) = @_;
    return join ';',
        map { join ',', @$_ }
        sort { $a->[0] <=> $b->[0] }
        map { [ sort { $a <=> $b } @$_ ] } @$components;
}

sub named_component_signature {
    my ($id, @components) = @_;
    return component_signature([
        map { [ map $id->{$_}, @$_ ] } @components
    ]);
}

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for qw(a b c d e f g);

$g->add_edge_by_ids($id{a}, $id{b});
$g->add_edge_by_ids($id{b}, $id{a});
$g->add_edge_by_ids($id{b}, $id{c});
$g->add_edge_by_ids($id{d}, $id{e});
$g->add_edge_by_ids($id{e}, $id{d});
$g->add_edge_by_ids($id{f}, $id{f});

is(component_signature($g->weakly_connected_components),
   named_component_signature(\%id, [qw(a b c)], [qw(d e)], [qw(f)], [qw(g)]),
   'weak components are not directed');
is(component_signature($g->strongly_connected_components),
   named_component_signature(\%id, [qw(a b)], [qw(c)], [qw(d e)], [qw(f)],
                             [qw(g)]),
   'strong components distinguish one-way reachability');
is(component_signature($g->cyclic_strongly_connected_components),
   named_component_signature(\%id, [qw(a b)], [qw(d e)], [qw(f)]),
   'cyclic strong components include loops and multi-vertex SCCs');
is_deeply($g->reachability_roots,
          [$id{a}, $id{d}, $id{f}, $id{g}],
          'one smallest root is returned for each source SCC');

my $all = $g->strongly_connected_components;
my %member;
$member{$_}++ for map @$_, @$all;
is_deeply([sort { $a <=> $b } keys %member],
          [sort { $a <=> $b } values %id],
          'strong components partition the live vertices');
is_deeply([sort { $a <=> $b } values %member], [(1) x 7],
          'each vertex occurs in exactly one strong component');

# This is the Sedgewick graph used by Graph/t/63_scc.t.  It provides a larger
# directed SCC case without depending on CPAN Graph's condensation object.
my $s = XGraph->new;
my %n;
$n{$_} = $s->add_vertex("$_") for 0 .. 12;
my @edges = (
    [0, 1], [0, 5], [0, 6], [2, 0], [2, 3], [3, 2], [3, 5],
    [4, 2], [4, 3], [4, 11], [5, 4], [6, 4], [6, 9], [7, 6],
    [7, 8], [8, 7], [8, 9], [9, 10], [9, 11], [10, 12], [11, 12],
    [12, 9],
);
$s->add_edge_by_ids($n{$_->[0]}, $n{$_->[1]}) for @edges;

is(component_signature($s->strongly_connected_components),
   named_component_signature(\%n, [qw(0 2 3 4 5 6)], [qw(1)], [qw(7 8)],
                             [qw(9 10 11 12)]),
   'the larger SCC example has the expected four components');
is(component_signature($s->cyclic_strongly_connected_components),
   named_component_signature(\%n, [qw(0 2 3 4 5 6)], [qw(7 8)],
                             [qw(9 10 11 12)]),
   'the larger example excludes its acyclic singleton');

done_testing;
