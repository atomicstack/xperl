use strict;
use warnings;

use Test::More;
use XGraph;
use lib 't/lib';
use XGraph::Reference;

my ($xs, $ref) = (XGraph->new, XGraph::Reference->new);
my @labels = (undef, '', 'left', 'right');
my $seed = 0x5eed1234;
sub rnd { $seed = (1103515245 * $seed + 12345) & 0x7fffffff; $seed }
sub live_ids { @{ $xs->vertex_ids } }
sub check_invariants {
    my @vertices = @{ $xs->vertex_ids };
    my @edges = @{ $xs->edges };
    my ($out_total, $in_total) = (0, 0);
    $out_total += $xs->out_degree($_) for @vertices;
    $in_total += $xs->in_degree($_) for @vertices;
    is($out_total, $xs->edge_count, 'out-degree total matches edge count');
    is($in_total, $xs->edge_count, 'in-degree total matches edge count');
    for my $edge (@edges) {
        ok($xs->has_edge_by_ids(@$edge), 'every listed edge is queryable');
    }
    my @partition = sort { $a <=> $b } map @$_, @{ $xs->weakly_connected_components };
    is_deeply(\@partition, \@vertices, 'weak components partition live vertices');
    my $topological = $xs->topological_sort;
    if (defined $topological) {
        my %position;
        @position{@$topological} = 0 .. $#$topological;
        ok((grep { $position{$_->[0]} >= $position{$_->[1]} } @edges) == 0,
           'topological order respects every edge');
    }
}

for my $step (1 .. 250) {
    my @ids = live_ids;
    my $choice = rnd() % 100;
    if ($choice < 18 || @ids < 2) {
        my $name = rnd() % 3 ? "v$step" : undef;
        my ($xo, $ro);
        my $xe = eval { $xo = $xs->add_vertex($name); 1 };
        my $re = eval { $ro = $ref->add_vertex($name); 1 };
        ok($xe == $re, "step $step vertex result agrees");
        is($xo, $ro, "step $step vertex id agrees") if $xe;
    }
    elsif ($choice < 72) {
        @ids = live_ids;
        my ($from, $to) = ($ids[rnd() % @ids], $ids[rnd() % @ids]);
        my $label = $labels[rnd() % @labels];
        my ($xe, $re);
        my $xo = eval { $xs->add_edge_by_ids($from, $to, $label); 1 };
        $xe = $@;
        my $ro = eval { $ref->add_edge_by_ids($from, $to, $label); 1 };
        $re = $@;
        ok(!!$xo == !!$ro, "step $step edge result agrees");
    }
    elsif ($choice < 88) {
        @ids = live_ids;
        my $id = $ids[rnd() % @ids];
        my $xo = eval { $xs->delete_vertex_by_id($id); 1 };
        my $ro = eval { $ref->delete_vertex_by_id($id); 1 };
        is(!!$xo, !!$ro, "step $step vertex deletion agrees");
    }
    else {
        my @edges = @{ $xs->edges };
        if (@edges) {
            my $edge = $edges[rnd() % @edges];
            my ($xo, $ro);
            my $xe = eval { $xo = $xs->delete_edge_by_ids(@$edge); 1 };
            my $re = eval { $ro = $ref->delete_edge_by_ids(@$edge); 1 };
            ok($xe == $re, "step $step edge deletion result agrees");
            is($xo, $ro, "step $step edge deletion value agrees") if $xe;
        }
    }
    is_deeply($xs->vertex_ids, $ref->vertex_ids, "step $step vertices");
    is_deeply($xs->edges, $ref->edges, "step $step edges");
    is($xs->vertex_count, $ref->vertex_count, "step $step vertex count");
    is($xs->edge_count, $ref->edge_count, "step $step edge count");
    check_invariants();
}

done_testing;
