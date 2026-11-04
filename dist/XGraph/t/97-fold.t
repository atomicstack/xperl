use strict;
use warnings;

use Test::More;
use XGraph;

sub named_reducer {
    my ($vertex, $acc, $context) = @_;
    $context->{calls}++;
    push @$acc, [
        $vertex->id,
        $vertex->name,
        $vertex->has_metadata ? $vertex->metadata : 'absent',
    ];
    return $acc;
}

my $graph = XGraph->new;
my $a = $graph->add_vertex('a');
my $b = $graph->add_vertex;
my $c = $graph->add_vertex('c');

my $payload = { role => 'source', values => [1, 2] };
is($graph->set_vertex_metadata($a, $payload), $graph,
   'setting metadata returns the graph');
ok($graph->has_vertex_metadata($a), 'metadata presence is tracked');
is_deeply($graph->vertex_metadata($a), $payload,
          'arbitrary metadata is returned unchanged');
ok(!$graph->has_vertex_metadata($b), 'metadata is optional');
is($graph->set_vertex_metadata($b, undef), $graph,
   'undef metadata can be stored');
ok($graph->has_vertex_metadata($b), 'undef metadata remains present');
ok(!defined $graph->vertex_metadata($b), 'stored undef is returned as undef');

my $view = $graph->vertex($a);
is($view->graph, $graph, 'vertex view retains its graph');
is($view->id, $a, 'vertex view exposes its numeric identity');
is($view->name, 'a', 'vertex view exposes its name');
is_deeply($view->metadata, $payload, 'vertex view exposes metadata');
$view->set_metadata({ role => 'updated' });
is($graph->vertex_metadata($a)->{role}, 'updated',
   'vertex view can update metadata');
ok($view->delete_metadata, 'vertex view can delete metadata');
ok(!$view->has_metadata, 'deleted metadata is absent');

$graph->set_vertex_metadata($a, $payload);
my $context = { calls => 0 };
my $rows = $graph->fold_vertices([], \&named_reducer, $context);
is($context->{calls}, 3, 'named reducer receives the explicit context');
is_deeply($rows, [
    [$a, 'a', $payload],
    [$b, undef, undef],
    [$c, 'c', 'absent'],
], 'fold visits vertex views in ID order');

my $sum = $graph->fold_vertices(0, sub {
    my ($vertex, $acc, $unused_context) = @_;
    return $acc + $vertex->id;
});
is($sum, $a + $b + $c, 'closure reducer works without explicit context');

my $clone = $graph->clone;
is_deeply($clone->vertex_metadata($a), $payload,
          'clone copies vertex metadata');
ok($graph->freeze, 'graph can be frozen with metadata');
my $frozen_error = eval { $graph->set_vertex_metadata($a, 1); 1 };
ok(!$frozen_error, 'frozen metadata is immutable through the graph');
like($@, qr/FROZEN/, 'frozen metadata mutation reports the standard error');

ok($clone->delete_vertex_by_id($a), 'deleting a vertex succeeds');
my $deleted_metadata_error = eval { $clone->vertex_metadata($a); 1 };
ok(!$deleted_metadata_error, 'deleted vertex metadata cannot be read');
like($@, qr/UNKNOWN_VERTEX/, 'deleted metadata reports an unknown vertex');

my $mutation_error = eval {
    $clone->fold_vertices([], sub {
        my ($vertex, $acc) = @_;
        $clone->add_vertex('invalidates-fold');
        return $acc;
    });
    1;
};
ok(!$mutation_error, 'structural mutation invalidates a fold cursor');
like($@, qr/ITERATOR_INVALIDATED/, 'fold reports cursor invalidation');

done_testing;
