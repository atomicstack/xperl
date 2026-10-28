#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use Scalar::Util qw(refaddr);
require JSON::PP;

# Keep every node alive independently while constructing and dismantling deep
# fixtures, so the test measures serialization rather than recursive teardown.
sub diagnostic {
    my ($number) = @_;
    return XPerl::Diagnostic->_new(
        {
            code     => 'ERROR_USER_TEXT',
            number   => 2438,
            kind     => 'USER_RUNTIME',
            severity => 'FATAL_ERROR',
            params   => [ { name => 'text', type => 'text', value => "level$number" } ],
            location => { file => 'nested-serialization.t', line => $number },
        }
    );
}

my $depth = 4096;
my @chain = map { diagnostic($_) } 0 .. $depth;
$chain[$_]->append( $chain[ $_ + 1 ] ) for 0 .. $depth - 1;
my $json    = $chain[0]->as_json;
my $records = () = $json =~ /"schema":"xperl\.diagnostic\.v2"/g;
is( $records, $depth + 1, 'JSON preserves every diagnostic in a deep valid tree' );
like( $json, qr/"value":"level4096"/, 'JSON retains the deepest diagnostic data' );
my $leaves = () = $json =~ /"contents":\[\]/g;
is( $leaves, 1, 'only the final diagnostic is a leaf in the serialized chain' );
my $closing = ']}' x ( $depth + 1 );
ok( length($json) >= length($closing) && substr( $json, -length($closing) ) eq $closing,
    'JSON closes every nested frame without truncation' );

my $dumper = $chain[0]->render_as_dumper;
$records = () = $dumper =~ /"schema" => "xperl\.diagnostic\.v2"/g;
is( $records, $depth + 1, 'Dumper preserves every diagnostic in a deep valid tree' );
like( $dumper, qr/"value" => "level4096"/, 'Dumper retains the deepest diagnostic data' );
$_->{contents} = [] for @chain;

my $root   = diagnostic(10);
my $left   = diagnostic(11);
my $right  = diagnostic(12);
my $shared = diagnostic(13);
$root->append($left);
$root->append($right);
$left->append($shared);
$right->append($shared);
my $record = JSON::PP->new->decode( $root->as_json );
is( $record->{contents}[0]{contents}[0]{location}{line}, 13, 'shared diagnostic is serialized in its first branch' );
is( $record->{contents}[1]{contents}[0]{location}{line},
    13, 'shared diagnostic is serialized again in its second branch' );
ok( refaddr( $left->contents->[0] ) == refaddr($shared) && refaddr( $right->contents->[0] ) == refaddr($shared),
    'serialization preserves the shared diagnostic identity in the source tree' );

# Invalid private hash edits must terminate without imposing a depth limit on
# valid trees. Only the back edge is replaced by null (undef in Dumper).
my $cycle = diagnostic(20);
$cycle->{contents} = [$cycle];
$record = JSON::PP->new->decode( $cycle->as_json );
is( scalar @{ $record->{contents} }, 1, 'a direct cycle retains its child position' );
ok( !defined $record->{contents}[0], 'a direct ancestor edge serializes as null' );
my $cycle_dump = eval '(' . $cycle->render_as_dumper . ')';
is( $@, '', 'Dumper cycle output is valid Perl data' );
ok( !defined $cycle_dump->{contents}[0], 'Dumper represents the cycle edge as undef' );
$cycle->{contents} = [];

my $legacy_cycle = diagnostic(21);
$legacy_cycle->{contents} = [$legacy_cycle];
my $legacy_cycle_text = eval { $legacy_cycle->render_as_legacy('en') };
is( $@, '', 'legacy rendering contains a direct raw-hash cycle' );
like( $legacy_cycle_text, qr/level21/, 'legacy rendering retains a cyclic node own message' );
my $legacy_cycle_exception = XPerl::Exception->_new();
$legacy_cycle_exception->append($legacy_cycle);
my $annotated_cycle_text = eval { $legacy_cycle_exception->render_as_annotated('en') };
is( $@, '', 'annotated rendering contains a direct raw-hash cycle' );
like( $annotated_cycle_text, qr/level21/, 'annotated rendering retains a cyclic node own message' );

my $render_context = { preserved => 1 };
$legacy_cycle->render_as_legacy('en', $render_context);
is( scalar keys %$render_context, 1,
    'standalone legacy rendering restores the caller context after a cycle' );
is( $render_context->{preserved}, 1,
    'standalone legacy rendering preserves caller data' );
my $annotated_again = $legacy_cycle_exception->render_as_annotated('en');
like( $annotated_again, qr/level21/,
    'annotated rendering works again after a completed cycle traversal' );
$legacy_cycle->{contents} = [];

my $unwind_diagnostic = diagnostic(22);
my $unwind_context = { preserved => 2 };
$unwind_diagnostic->{params}[0]{value} =
    bless {}, 'XPerlNestedSerialization::DieOnString';
eval { $unwind_diagnostic->render_as_legacy('en', $unwind_context) };
like( $@, qr/render callback died/, 'a rendering callback can unwind the renderer' );
is( scalar keys %$unwind_context, 1,
    'unwinding removes the active ancestor marker from the caller context' );
$unwind_diagnostic->{params}[0]{value} = 'level22';
like( $unwind_diagnostic->render_as_legacy('en', $unwind_context), qr/level22/,
    'rendering remains usable after callback unwind' );

my $ancestor   = diagnostic(30);
my $descendant = diagnostic(31);
$ancestor->append($descendant);
$descendant->{contents} = [$ancestor];
$record = JSON::PP->new->decode( $ancestor->as_json );
is( $record->{contents}[0]{location}{line}, 31, 'an indirect cycle retains the real descendant' );
ok( !defined $record->{contents}[0]{contents}[0], 'only the indirect back edge becomes null' );
my $indirect_legacy = eval { $ancestor->render_as_legacy('en') };
is( $@, '', 'legacy rendering contains an indirect raw-hash cycle' );
like( $indirect_legacy, qr/level30.*level31/s,
    'legacy rendering keeps both nodes and omits only the active back edge' );
my $ancestor_exception = XPerl::Exception->_new();
$ancestor_exception->append($ancestor);
my $indirect_annotated = eval { $ancestor_exception->render_as_annotated('en') };
is( $@, '', 'annotated rendering contains an indirect raw-hash cycle' );
like( $indirect_annotated, qr/level30.*level31/s,
    'annotated rendering keeps both nodes and omits only the active back edge' );
$descendant->{contents} = [];

# A cycle in one branch must not suppress a subsequent, valid occurrence.
$root->{contents}  = [ $cycle, $shared ];
$cycle->{contents} = [$cycle];
$record            = JSON::PP->new->decode( $root->as_json );
ok( !defined $record->{contents}[0]{contents}[0], 'a cyclic branch is bounded' );
is( $record->{contents}[1]{location}{line}, 13, 'the following valid branch is preserved' );
$cycle->{contents} = [];

my $render_root = diagnostic(60);
my $render_left = diagnostic(61);
my $render_right = diagnostic(62);
my $render_shared = diagnostic(63);
$render_root->append($render_left);
$render_root->append($render_right);
$render_left->append($render_shared);
$render_right->append($render_shared);
my $render_dag = $render_root->render_as_legacy('en');
my $shared_text_count = () = $render_dag =~ /level63/g;
is( $shared_text_count, 2, 'human rendering visits shared descendants in both branches' );

{

    package XPerlNestedSerialization::ReplaceChildren;

    sub TIESCALAR {
        my ( $class, $parent, $replacement ) = @_;
        return bless { parent => $parent, replacement => $replacement }, $class;
    }

    sub FETCH {
        my ($self) = @_;
        my $parent = delete $self->{parent};
        $parent->{contents} = $self->{replacement} if defined $parent;
        return 0;
    }

    package XPerlNestedSerialization::ReplaceChildrenOnString;
    use overload '""' => sub {
        my ($self) = @_;
        my $parent = delete $self->{parent};
        $parent->{contents} = $self->{replacement} if defined $parent;
        return $self->{text};
    }, fallback => 1;

    package XPerlNestedSerialization::DieOnString;
    use overload '""' => sub { die "render callback died\n" }, fallback => 1;
}

my $shrinking = diagnostic(40);
my $current   = diagnostic(41);
$shrinking->append($current);
$shrinking->append( diagnostic(42) );
tie $current->{is_hint}, 'XPerlNestedSerialization::ReplaceChildren', $shrinking, [];
$record = JSON::PP->new->decode( $shrinking->as_json );
is( $record->{contents}[0]{location}{line}, 41, 'a callback cannot destroy the diagnostic currently being serialized' );
ok( !defined $record->{contents}[1], 'a truncated child position serializes as null' );
is( $shrinking->contents_count, 0, 'serialization does not autovivify truncated child slots' );
untie $current->{is_hint};

$shrinking->{contents} = [$current];
tie $current->{is_hint}, 'XPerlNestedSerialization::ReplaceChildren', $shrinking, [];
my $post_callback_text = $shrinking->render_as_legacy('en');
like( $post_callback_text, qr/level41/,
    'human rendering retains the current child while a callback replaces its array' );
is( $shrinking->contents_count, 0,
    'human rendering leaves the callback replacement intact' );
untie $current->{is_hint};

$shrinking->{contents} = [$current];
my $annotated_callback_value = bless {
    parent => $shrinking, replacement => [], text => 'level41',
}, 'XPerlNestedSerialization::ReplaceChildrenOnString';
$current->{params}[0]{value} = $annotated_callback_value;
my $shrinking_exception = XPerl::Exception->_new();
$shrinking_exception->append($shrinking);
my $annotated_callback_text = $shrinking_exception->render_as_annotated('en');
like( $annotated_callback_text, qr/level41/,
    'annotated rendering retains the current child while a callback replaces its array' );
is( $shrinking->contents_count, 0,
    'annotated rendering leaves the callback replacement intact' );

$shrinking->{contents} = [$current];
$current->{params}[0]{value} = 'level41';
my $post_unwind_text = $shrinking->render_as_legacy('en');
like( $post_unwind_text, qr/level41/,
    'legacy rendering works after callback unwind restores the context' );
is( $shrinking->contents_count, 1, 'post-callback rendering preserves the restored child list' );
$annotated_callback_text = $shrinking_exception->render_as_annotated('en');
like( $annotated_callback_text, qr/level41/,
    'annotated rendering works after callback unwind restores the context' );
$shrinking->{contents} = [];

my $replacing = diagnostic(50);
$current = diagnostic(51);
$replacing->append($current);
$replacing->append( diagnostic(52) );
my @replacement = map { diagnostic($_) } 53 .. 55;
tie $current->{is_hint}, 'XPerlNestedSerialization::ReplaceChildren', $replacing, \@replacement;
$record = JSON::PP->new->decode( $replacing->as_json );
is( $record->{contents}[0]{location}{line},
    51, 'the current child keeps its identity when its parent array is replaced' );
is( $record->{contents}[1]{location}{line}, 54, 'the next child is looked up in the replacement array' );
is( scalar @{ $record->{contents} }, 2, 'a callback cannot extend serialization beyond the original child range' );
is( $replacing->contents_count,         3, 'the replacement source array keeps its actual size' );
untie $current->{is_hint};

done_testing;
