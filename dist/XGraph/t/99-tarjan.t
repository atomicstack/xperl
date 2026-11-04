use strict;
use warnings;

use Test::More;
use XGraph;

sub compare_scc_algorithms {
    my ($graph, $description) = @_;
    is_deeply(
        $graph->strongly_connected_components_tarjan,
        $graph->strongly_connected_components,
        "$description: Tarjan and Kosaraju agree",
    );
    is_deeply(
        $graph->strongly_connected_components_pearce,
        $graph->strongly_connected_components,
        "$description: Pearce and Kosaraju agree",
    );
    is_deeply(
        $graph->strongly_connected_components_tarjan_zwick,
        $graph->strongly_connected_components,
        "$description: Tarjan-Zwick and Kosaraju agree",
    );
}

my $graph = XGraph->new;
$graph->add_vertex for 1 .. 8;

$graph->add_edge_by_ids(1, 2, 'a');
$graph->add_edge_by_ids(1, 2, 'b');
$graph->add_edge_by_ids(2, 3);
$graph->add_edge_by_ids(3, 1);
$graph->add_edge_by_ids(3, 4);
$graph->add_edge_by_ids(4, 5);
$graph->add_edge_by_ids(5, 4);
$graph->add_edge_by_ids(5, 6);
$graph->add_edge_by_ids(6, 6);
$graph->add_edge_by_ids(8, 7);

is_deeply(
    $graph->strongly_connected_components_tarjan,
    [[1, 2, 3], [4, 5], [6], [7], [8]],
    'Tarjan returns sorted SCCs and preserves singleton components',
);
is_deeply(
    $graph->strongly_connected_components_pearce,
    [[1, 2, 3], [4, 5], [6], [7], [8]],
    'Pearce returns sorted SCCs and preserves singleton components',
);
is_deeply(
    $graph->strongly_connected_components_tarjan_zwick,
    [[1, 2, 3], [4, 5], [6], [7], [8]],
    'Tarjan-Zwick returns sorted SCCs and preserves singleton components',
);
compare_scc_algorithms($graph, 'mixed cycles');

my $dag = XGraph->new;
$dag->add_vertex for 1 .. 6;
$dag->add_edge_by_ids(1, 2);
$dag->add_edge_by_ids(1, 3);
$dag->add_edge_by_ids(2, 4);
$dag->add_edge_by_ids(3, 4);
$dag->add_edge_by_ids(4, 5);
$dag->add_edge_by_ids(5, 6);
compare_scc_algorithms($dag, 'acyclic graph');

for my $seed (0 .. 19) {
    my $random = XGraph->new;
    $random->add_vertex for 1 .. 12;
    for my $from (1 .. 12) {
        for my $to (1 .. 12) {
            next if (($seed * 29 + $from * 17 + $to * 7) % 13) > 2;
            eval { $random->add_edge_by_ids($from, $to) };
        }
    }
    compare_scc_algorithms($random, "deterministic graph seed $seed");
}

done_testing;
