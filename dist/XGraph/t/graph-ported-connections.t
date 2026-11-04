use strict;
use warnings;

# Provenance: ported from Graph 0.9735 (7d3f3ea), t/58_connections.t.
# CPAN Graph's directed source/sink cases are retained; undirected-only
# classifications and its scalar-context stringification are omitted.

use Test::More;
use XGraph;

sub named_ids {
    my ($id, @names) = @_;
    return [sort { $a <=> $b } map $id->{$_}, @names];
}

my $g = XGraph->new;
my %id;
$id{$_} = $g->add_vertex($_) for 1 .. 6;
$g->add_edge_by_names(1, 1);
$g->add_edge_by_names(1, 2);
$g->add_edge_by_names(1, 3);
$g->add_edge_by_names(2, 4);
$g->add_edge_by_names(5, 4);

is_deeply($g->source_vertices, named_ids(\%id, 5, 6),
          'source vertices have no incoming relationship');
is_deeply($g->sink_vertices, named_ids(\%id, 3, 4, 6),
          'sink vertices have no outgoing relationship');
is_deeply($g->loop_vertices, named_ids(\%id, 1),
          'loop vertices are reported independently of source/sink status');

my $p = XGraph->new;
my %p;
$p{$_} = $p->add_vertex($_) for qw(a b c d e f g h i j k l);
sub add_path {
    my ($graph, @names) = @_;
    $graph->add_edge_by_names($names[$_], $names[$_ + 1])
        for 0 .. $#names - 1;
}
add_path($p, qw(a b d));
add_path($p, qw(b e));
add_path($p, qw(a c f f));
add_path($p, qw(g h));
add_path($p, qw(i i));
add_path($p, qw(k k l));

is_deeply($p->source_vertices, named_ids(\%p, qw(a g j)),
          'path scenario sources exclude looped vertices');
is_deeply($p->sink_vertices, named_ids(\%p, qw(d e h j l)),
          'path scenario sinks include the isolated vertex');
is_deeply($p->loop_vertices, named_ids(\%p, qw(f i k)),
          'path scenario finds every self-loop');

done_testing;
