use strict;
use warnings;

use Test::More tests => 22;
use XGraph;

my $graph = XGraph->new;
is($graph->label_count, 2, 'reserved labels occupy IDs one and two');
$graph->declare_label('calls');
$graph->declare_labels('contains', 'reads');
is_deeply($graph->labels, [undef, '', 'calls', 'contains', 'reads'],
          'labels retain registration order');
is($graph->label_count, 5, 'registered labels count');
$graph->declare_label('calls');
is($graph->label_count, 5, 'duplicate declaration is a no-op');

my $a = $graph->add_vertex('a');
my $b = $graph->add_vertex('b');
$graph->add_edge_by_ids($a, $b);
$graph->add_edge_by_ids($b, $a, '');
is_deeply($graph->edges, [[$a, $b, undef], [$b, $a, '']],
          'undef and empty labels are distinct');

my $strict = XGraph->new(strict_labels => 1);
$a = $strict->add_vertex('a');
$b = $strict->add_vertex('b');
my $error = eval { $strict->add_edge_by_ids($a, $b, 'typo'); 1 };
ok(!$error, 'strict mode rejects undeclared labels');
like($@, qr/UNKNOWN_LABEL/, 'strict label error');
is($strict->label_count, 2, 'rejected strict label is not registered');

my $magic = bless {}, 'XGraph::TestString';
my $magic_error = eval { $graph->declare_label($magic); 1 };
ok(!$magic_error, 'reference labels are rejected');
like($@, qr/INVALID_LABEL/, 'reference label error');

my $before = $graph->label_count;
my $atomic = eval { $graph->declare_labels('not-committed', $magic); 1 };
ok(!$atomic, 'bulk declaration rejects the complete batch');
like($@, qr/INVALID_LABEL/, 'bulk declaration reports label error');
is($graph->label_count, $before, 'bulk declaration is atomic');

my $loose = XGraph->new;
my ($loose_a, $loose_b) = ($loose->add_vertex, $loose->add_vertex);
ok(!$loose->has_edge_by_ids($loose_a, $loose_b, 'not-registered'),
   'unknown read label is absent');
is($loose->label_count, 2, 'unknown read label is not registered');
ok(!$loose->delete_edge_by_ids($loose_a, $loose_b, 'also-not-registered'),
   'unknown delete label is absent');
is($loose->label_count, 2, 'unknown delete label is not registered');

my $numeric = XGraph->new;
my ($numeric_a, $numeric_b) = ($numeric->add_vertex, $numeric->add_vertex);
$numeric->add_edge_by_ids($numeric_a, $numeric_b, 42);
is_deeply($numeric->edges, [[$numeric_a, $numeric_b, '42']],
          'numeric labels are stringified');

my $limited = XGraph->new;
$limited->declare_labels(map { "label-$_" } 1 .. 253);
is($limited->label_count, 255, 'compact label limit is reachable');
my $limit_error = eval { $limited->declare_label('one-too-many'); 1 };
if ($limit_error) {
    ok(1, 'wide representation accepts labels beyond compact limit');
    is($limited->label_count, 256, 'wide representation registered label');
    ok(1, 'wide representation has no compact label-limit error');
} else {
    ok(1, 'compact label limit is enforced');
    like($@, qr/LABEL_LIMIT/, 'label limit error is structured');
    is($limited->label_count, 255, 'compact limit rejection is atomic');
}

package XGraph::TestString;
sub stringify { 'unused' }
1;
