#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use feature 'class';
no warnings 'experimental::class';
use Data::Dumper;
use Scalar::Util qw(refaddr);

our @toasted;
class SnapshotNode {
    field $value :param;
    field @list;
    field %map;
    method value { $value }
    method refs { \$value, \@list, \%map }
    method link($peer) { push @list, $peer; $map{peer} = $peer }
    method clear { @list = (); %map = () }
    method toast { push @main::toasted, $value; $self }
}

my $live = SnapshotNode->new(value => 17);
my $view = builtin::class_object_to_hash($live);
is(refaddr($view->{'$self'}), refaddr($live), 'snapshot contains the actual public object');
ok(builtin::is_class_object($view->{'$self'}), 'live self retains modern storage magic');
is(refaddr(builtin::class_object_from_hash($view)), refaddr($live), 'one-argument restoration is idempotent on a live view');
$view->{SnapshotNode}{'$value'} = 99;
is(builtin::class_object_from_hash($view)->value, 99, 'live field entries share original field scalars');
for my $bad ({}, {'$self' => undef}, {'$self' => []}) {
    eval { builtin::class_object_from_hash($bad) };
    like($@, qr/snapshot \$self must be a blessed reference/, 'invalid snapshot self has an accurate diagnostic');
}
my $ordinary = bless {}, 'SnapshotNode';
my $hydrated = builtin::class_object_from_hash({
    '$self' => $ordinary,
    SnapshotNode => {'$value' => 23, '@list' => [], '%map' => {}},
});
is(refaddr($hydrated), refaddr($ordinary), 'hydration attaches to the supplied blessed referent');
is($hydrated->value, 23, 'hydration attaches original owner fields');

our ($initializing_error, $teardown_error, $release_error, $release_view);
class SnapshotBusy {
    field $value = 1;
    ADJUST {
        eval { builtin::class_object_from_hash(builtin::class_object_to_hash($self)) };
        $main::initializing_error = $@;
    }
    method TEARDOWN {
        eval { builtin::class_object_from_hash(builtin::class_object_to_hash($self)) };
        $main::teardown_error = $@;
    }
}
{
    my $busy = SnapshotBusy->new;
    like($initializing_error, qr/storage is being initialized or released/, 'hydration rejects initialization in progress');
}
like($teardown_error, qr/storage is being initialized or released/, 'hydration rejects TEARDOWN in progress');

package SnapshotReleaseProbe {
    sub DESTROY {
        eval { builtin::class_object_from_hash($main::release_view) };
        $main::release_error = $@;
    }
}
class SnapshotRelease {
    field $held = bless {}, 'SnapshotReleaseProbe';
}
{
    require XS::APItest;
    my $releasing = SnapshotRelease->new;
    $release_view = builtin::class_object_to_hash($releasing);
    delete $release_view->{SnapshotRelease};
    XS::APItest::sv_unbless($releasing);
    like($release_error, qr/storage is being initialized or released/, 'hydration rejects detached storage during field destruction');
    undef $release_view;
}

class SnapshotOriginal { field $old = 'original'; method old { $old } }
class SnapshotReplacement { field $new = 'replacement' }
package SnapshotLegacy { our @ISA = ('SnapshotOriginal') }
{
    my $legacy = SnapshotLegacy->new;
    my $snapshot = builtin::class_object_to_hash($legacy);
    local @SnapshotLegacy::ISA = ('SnapshotReplacement');
    is(refaddr(builtin::class_object_from_hash($snapshot)), refaddr($legacy),
        'idempotent hydration validates the stored layout after legacy ancestry changes');
    is(SnapshotOriginal->can('old')->($legacy), 'original', 'existing original field remains available');
}

for my $useperl (0, 1) {
    local $Data::Dumper::Useperl = $useperl;
    our ($external, $VAR1);
    local $external = $live;
    {
        local $VAR1;
        my $named = Data::Dumper->new([$live])->Seen({external => $live})->Dump;
        unlike($named, qr/class_object_from_hash/, 'preloaded Seen object keeps its external name');
        eval $named;
        is($@, '', 'preloaded Seen output evaluates against the supplied reference');
        is(refaddr($VAR1), refaddr($external), 'preloaded Seen preserves authoritative external identity');
    }

    my $left = bless {}, 'SnapshotNode';
    my $right = bless {}, 'SnapshotNode';
    $left->CONSTRUCT(value => 'left');
    $right->CONSTRUCT(value => 'right');
    $left->link($right);
    $right->link($left);
    $left->{peer} = $right;
    $right->{peer} = $left;
    my ($scalar, $array, $hash) = $left->refs;
    my $holder = $left;
    my $root = [$left, $left, $right, $scalar, $array, $hash, \$holder];
    local $VAR1;
    my $dump = Data::Dumper->new([$root])->Purity(1)->Sortkeys(1)->Dump;
    eval $dump;
    is($@, '', "Useperl=$useperl graph with nested wrappers evaluates");
    is(refaddr($VAR1->[0]), refaddr($VAR1->[1]), 'whole-object aliases target the ordinary referent');
    is(refaddr($VAR1->[0]{peer}), refaddr($VAR1->[2]), 'payload shares the nested object');
    is(refaddr($VAR1->[2]{peer}), refaddr($VAR1->[0]), 'payload cycle crosses reconstructed objects');
    my ($s, $a, $h) = $VAR1->[0]->refs;
    is(refaddr($s), refaddr($VAR1->[3]), 'scalar field alias survives final conversion');
    is(refaddr($a), refaddr($VAR1->[4]), 'array field alias survives final conversion');
    is(refaddr($h), refaddr($VAR1->[5]), 'hash field alias survives final conversion');
    is(refaddr($a->[0]), refaddr($VAR1->[2]), 'field graph shares the same nested object as payload');
    is(refaddr(${$VAR1->[6]}), refaddr($VAR1->[0]), 'reference to an object holder retains identity');
    ${$VAR1->[3]} = 'changed';
    is($VAR1->[0]->value, 'changed', 'mutation through serialized scalar alias changes the installed field');
    my $reconstructed = $VAR1;

    our ($first, $again, $field);
    local ($first, $again, $field);
    my $roots = Data::Dumper->new([$left, $left, $scalar], [qw(first again field)])->Purity(1)->Dump;
    eval $roots;
    is($@, '', 'whole-call conversion follows fixups across multiple roots');
    is(refaddr($first), refaddr($again), 'shared object roots resolve to one referent');
    my ($first_field) = $first->refs;
    is(refaddr($first_field), refaddr($field), 'field alias in later root uses the installed field');

    my $cache = Data::Dumper->new([[$live]])->Purity(1);
    eval $cache->Dump;
    is($@, '', 'first cached dump reconstructs nested object');
    my $cache_object = $VAR1->[0];
    my ($live_scalar) = $live->refs;
    eval $cache->Values([$live_scalar])->Dump;
    is($@, '', 'later cached dump does not retain disposed wrapper paths');
    my ($cache_field) = $cache_object->refs;
    is(refaddr($VAR1), refaddr($cache_field), 'cached name resolves to the installed scalar field');
    $$VAR1 = 'cache mutation';
    is($live->value, 99, 'cached dump leaves source object unchanged');
    is($$VAR1, 'cache mutation', 'cached field alias remains writable');

    @toasted = ();
    my $plain = SnapshotNode->new(value => 'toast');
    eval Data::Dumper->new([$plain])->Toaster('toast')->Dump;
    is($@, '', 'normal Toaster runs after modern storage attachment');
    is(join(',', @toasted), 'toast', 'normal Toaster sees restored field state');
    @toasted = ();
    my $terse = Data::Dumper->new([$plain])->Terse(1)->Toaster('toast')->Dump;
    my $terse_object = eval $terse;
    is($@, '', 'simple Terse expression evaluates');
    is($terse_object->value, 'toast', 'Terse inline restoration preserves fields');
    is(join(',', @toasted), 'toast', 'Terse Toaster also runs after attachment');
    like($terse, qr/^builtin::class_object_from_hash\(/, 'Terse emits compact inline restoration');

    my @cleanup = ($left, $right, $reconstructed->[0], $reconstructed->[2], $first, $first->{peer});
    for my $object (@cleanup) {
        $object->clear;
        delete $object->{peer};
    }
}

done_testing();
