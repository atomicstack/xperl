#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use feature 'class';
use Data::Dumper;
use Scalar::Util qw(refaddr);
use Config;
no warnings 'experimental::class';

class ObjectHashTest {
    field $scalar :param :reader;
    field @array;
    field %hash;
}

my $object = ObjectHashTest->new(scalar => 'value');
my $fields = builtin::class_object_to_hash($object);

is(ref($fields), 'HASH', 'to_hash returns a hash reference');
is($fields->{ObjectHashTest}{'$scalar'}, 'value', 'scalar field is represented directly');
is(ref($fields->{ObjectHashTest}{'@array'}), 'ARRAY', 'array field is represented by a reference');
is(ref($fields->{ObjectHashTest}{'%hash'}), 'HASH', 'hash field is represented by a reference');

$fields->{ObjectHashTest}{'@array'}[0] = 'shared';
$fields->{ObjectHashTest}{'%hash'}{key} = 'shared';
my $copy = builtin::class_object_from_hash($fields, 'ObjectHashTest');
my $copy_fields = builtin::class_object_to_hash($copy);
is($copy->scalar, 'value', 'from_hash restores scalar fields');
is($copy_fields->{ObjectHashTest}{'@array'}[0], 'shared', 'array field values are shared');
is($copy_fields->{ObjectHashTest}{'%hash'}{key}, 'shared', 'hash field values are shared');
is(refaddr($copy_fields->{ObjectHashTest}{'@array'}), refaddr($fields->{ObjectHashTest}{'@array'}),
   'array field referent is shared');
is(refaddr($copy_fields->{ObjectHashTest}{'%hash'}), refaddr($fields->{ObjectHashTest}{'%hash'}),
   'hash field referent is shared');

my $dump = Dumper($object);
like($dump, qr/builtin::class_object_from_hash/, 'XS Dumper handles class objects');
my $restored = eval "no strict 'vars'; $dump";
is($@, '', 'XS Dumper output evaluates');
is($restored->scalar, 'value', 'XS Dumper restores class fields');

{
    local $Data::Dumper::Useperl = 1;
    my $pure_dump = Dumper($object);
    like($pure_dump, qr/builtin::class_object_from_hash/, 'pure Perl Dumper handles class objects');
    my $pure_restored = eval "no strict 'vars'; $pure_dump";
    is($@, '', 'pure Perl Dumper output evaluates');
    is($pure_restored->scalar, 'value', 'pure Perl Dumper restores class fields');
}

role ObjectHashBaseRole {
    field $shared :reader :param;
}

role ObjectHashLeftRole :implements(ObjectHashBaseRole) {
    field $left :reader :param;
}

role ObjectHashRightRole :implements(ObjectHashBaseRole) {
    field $right :reader :param;
}

class ObjectHashRoleConsumer
        :implements(ObjectHashLeftRole)
        :implements(ObjectHashRightRole) {
    field $own :reader :param;
}

my $role_object = ObjectHashRoleConsumer->new(
    shared => 'shared',
    left   => 'left',
    right  => 'right',
    own    => 'own',
);
my $role_fields = builtin::class_object_to_hash($role_object);
ok(eq_hash($role_fields->{ObjectHashRoleConsumer}, {
    '$shared' => 'shared',
    '$left'   => 'left',
    '$right'  => 'right',
    '$own'    => 'own',
}), 'to_hash represents each field in a role diamond once');

my $role_copy = builtin::class_object_from_hash(
    $role_fields, 'ObjectHashRoleConsumer');
is($role_copy->shared, 'shared', 'from_hash restores the shared role field');
is($role_copy->left, 'left', 'from_hash restores the left role field');
is($role_copy->right, 'right', 'from_hash restores the right role field');
is($role_copy->own, 'own', 'from_hash restores the class field');

our $restored_destroyed = 0;
class ObjectHashLifetime {
    field $value :param;
    method DESTROY { ++$main::restored_destroyed }
}
{
    my $restored = builtin::class_object_from_hash({ObjectHashLifetime => {'$value' => 1}}, 'ObjectHashLifetime');
}
is($restored_destroyed, 1, 'restored object is released at end of scope');
{
    my $referent = {};
    my $weak = $referent;
    Scalar::Util::weaken($weak);
    {
        my $object = ObjectHashLifetime->new(value => $referent);
        builtin::class_object_to_hash($object);
    }
    undef $referent;
    ok(!defined($weak), 'discarded field hash releases its field references');
}

is(builtin::is_class_object($object), 1, 'storage predicate recognizes a modern instance');
ok(!builtin::is_class_object(bless({}, 'PlainObjectHash')), 'storage predicate rejects ordinary legacy object');
ok(!builtin::is_class_object('ObjectHashTest'), 'storage predicate rejects class name');

for my $useperl (0, 1) {
    local $Data::Dumper::Useperl = $useperl;
    local $Data::Dumper::Purity = 1;
    for my $kind (qw(SCALAR ARRAY HASH)) {
        my $shared = { value => 42 };
        my $payload = $kind eq 'HASH' ? { shared => $shared }
                    : $kind eq 'ARRAY' ? [$shared] : \my $scalar;
        $$payload = $shared if $kind eq 'SCALAR';
        my $object = bless $payload, 'ObjectHashTest';
        $object->CONSTRUCT(scalar => $shared);
        $shared->{owner} = $object;
        our $VAR1;
        local $VAR1;
        my $dump = Dumper($object);
        eval $dump;
        is($@, '', "Dumper Useperl=$useperl $kind payload graph evaluates");
        my $restored = $VAR1;
        is(Scalar::Util::reftype($restored), $kind eq 'SCALAR' ? 'REF' : $kind, "Dumper preserves $kind payload kind");
        is($restored->scalar->{value}, 42, 'Dumper preserves field data');
        my $restored_shared = $kind eq 'HASH' ? $restored->{shared}
                            : $kind eq 'ARRAY' ? $restored->[0] : $$restored;
        is(refaddr($restored_shared), refaddr($restored->scalar),
            'Dumper preserves references shared between payload and fields');
        is(refaddr($restored_shared->{owner}), refaddr($restored),
            'Dumper preserves a cycle through fields to public object');
        delete $shared->{owner};
        delete $restored_shared->{owner};
    }
}

for my $payload ({ payload => 9 }, [9], \my $scalar) {
    my $before = refaddr($payload);
    eval { builtin::class_object_from_hash({
        ObjectHashTest => {'$scalar' => 1, '@array' => 'wrong', '%hash' => {}},
    }, 'ObjectHashTest', $payload) };
    like($@, qr/must be a reference/, 'invalid restored field is rejected');
    ok(!Scalar::Util::blessed($payload), 'failed restoration leaves caller payload unblessed');
    is(refaddr($payload), $before, 'failed restoration preserves payload identity');
    ok(!builtin::is_class_object($payload), 'failed restoration leaves no modern storage');
}

{
    my $legacy = bless {}, 'PlainObjectHash';
    my @die;
    local $SIG{__DIE__} = sub { push @die, "$_[0]" };
    local $Data::Dumper::Useperl = 1;
    Dumper($legacy);
    is(scalar @die, 0, 'pure Perl Dumper detects storage without invoking die hooks');
}

SKIP: {
    skip('Storable unavailable', 4) unless eval { require Storable; 1 };
    eval { Storable::dclone($object) };
    like($@, qr/Modern class storage requires an explicit STORABLE_freeze hook/,
        'Storable rejects implicit serialization that would discard modern fields');
    my $legacy = Storable::dclone(bless({ payload => 12 }, 'PlainObjectHash'));
    is($legacy->{payload}, 12, 'ordinary legacy Storable serialization is unaffected');
    class ObjectHashStorable {
        field $value :param :reader;
        method STORABLE_freeze($cloning) { "$value" }
        sub STORABLE_thaw ($self, $cloning, $serialized) {
            $self->CONSTRUCT(value => $serialized);
        }
    }
    my $source = ObjectHashStorable->new(value => 27);
    my $restored = Storable::dclone($source);
    is($restored->value, 27, 'explicit Storable hooks can restore modern fields');
    is(Scalar::Util::reftype($restored), 'SCALAR', 'Storable hooks retain ordinary referent representation');
}

role ObjectHashAggregateRole {
    field @role_array;
    field %role_hash;
}
class ObjectHashAggregateParent :implements(ObjectHashAggregateRole) { }
class ObjectHashAggregateChild :isa(ObjectHashAggregateParent) {
    field @role_array :inherited;
    field %role_hash :inherited;
}
for my $invalid (
    { '@role_array' => {}, '%role_hash' => {} },
    { '@role_array' => [], '%role_hash' => [] },
) {
    eval { builtin::class_object_from_hash({ObjectHashAggregateParent => $invalid}, 'ObjectHashAggregateChild') };
    like($@, qr/has the wrong reference type/, 'role aggregate restoration validates referent type before inherited aliases bind');
}

class BucketParent {
    field $value :param(parent_value) :reader(parent_value);
    field @items = ('parent');
    field %items = (key => 'parent');
    method parent_items { \@items, \%items }
}
class BucketChild :isa(BucketParent) {
    field $value :param(child_value) :reader(child_value);
    field @items = ('child');
    field %items = (key => 'child');
    method child_items { \@items, \%items }
}
my $shadow = BucketChild->new(parent_value => 'parent', child_value => 'child');
my $shadow_fields = builtin::class_object_to_hash($shadow);
ok(eq_array([sort keys %$shadow_fields], ['$self', qw(BucketChild BucketParent)]),
    'same-named declarations are separated by their original storage owner');
is($shadow_fields->{BucketParent}{'$value'}, 'parent', 'parent scalar value has its owner bucket');
is($shadow_fields->{BucketChild}{'$value'}, 'child', 'child scalar value has its distinct owner bucket');
is($shadow_fields->{BucketParent}{'@items'}[0], 'parent', 'parent array value has its owner bucket');
is($shadow_fields->{BucketChild}{'@items'}[0], 'child', 'child array value has its owner bucket');
is($shadow_fields->{BucketParent}{'%items'}{key}, 'parent', 'parent hash value has its owner bucket');
is($shadow_fields->{BucketChild}{'%items'}{key}, 'child', 'child hash value has its owner bucket');
my $shadow_copy = builtin::class_object_from_hash($shadow_fields, 'BucketChild');
is($shadow_copy->parent_value, 'parent', 'restoration preserves parent same-named scalar');
is($shadow_copy->child_value, 'child', 'restoration preserves child same-named scalar');
my @parent_items = $shadow_copy->parent_items;
my @child_items = $shadow_copy->child_items;
is($parent_items[0][0], 'parent', 'restoration preserves parent array');
is($child_items[0][0], 'child', 'restoration preserves child array');
is($parent_items[1]{key}, 'parent', 'restoration preserves parent hash');
is($child_items[1]{key}, 'child', 'restoration preserves child hash');

for my $useperl (0, 1) {
    local $Data::Dumper::Useperl = $useperl;
    local $Data::Dumper::Purity = 1;
    my $parent = { label => 'parent' };
    my $child = { label => 'child' };
    my $graph = bless { parent => $parent, child => $child }, 'BucketChild';
    $graph->CONSTRUCT(parent_value => $parent, child_value => $child);
    $parent->{owner} = $child->{owner} = $graph;
    our $VAR1;
    local $VAR1;
    my $dump = Dumper($graph);
    like($dump, qr/\$VAR1.*BucketParent/s,
        "Useperl=$useperl purity paths qualify parent owner");
    like($dump, qr/\$VAR1.*BucketChild/s,
        "Useperl=$useperl purity paths qualify child owner");
    eval $dump;
    is($@, '', "Useperl=$useperl shadowed-owner graph evaluates");
    is($VAR1->parent_value->{label}, 'parent', 'parent graph field survives reconstruction');
    is($VAR1->child_value->{label}, 'child', 'child graph field survives reconstruction');
    is(refaddr($VAR1->{parent}), refaddr($VAR1->parent_value), 'payload shares original parent field reference');
    is(refaddr($VAR1->{child}), refaddr($VAR1->child_value), 'payload shares original child field reference');
    is(refaddr($VAR1->parent_value->{owner}), refaddr($VAR1), 'parent field cycle points to reconstructed public object');
    is(refaddr($VAR1->child_value->{owner}), refaddr($VAR1), 'child field cycle points to same reconstructed object');
    delete $parent->{owner};
    delete $child->{owner};
    delete $VAR1->parent_value->{owner};
    delete $VAR1->child_value->{owner};
}

class BucketEmpty { }
class BucketAliasOnly :isa(ObjectHashTest) { field $scalar :inherited }
my $empty_fields = builtin::class_object_to_hash(BucketEmpty->new);
ok(eq_array([keys %$empty_fields], ['$self']), 'fieldless snapshot contains only its live self');
is(ref(builtin::class_object_from_hash({}, 'BucketEmpty')), 'BucketEmpty', 'fieldless restoration needs no owner bucket');
my $alias_fields = builtin::class_object_to_hash(BucketAliasOnly->new(scalar => 11));
ok(!exists($alias_fields->{BucketAliasOnly}) && exists($alias_fields->{ObjectHashTest}),
    'alias-only descendant has no bucket of copied fields');

for my $bad (undef, [], 1) {
    my $payload = { payload => 29 };
    eval { builtin::class_object_from_hash({ObjectHashTest => $bad}, 'ObjectHashTest', $payload) };
    like($@, qr/Class field bucket ObjectHashTest must be a hash reference/, 'malformed owner bucket is diagnosed');
    ok(!Scalar::Util::blessed($payload) && $payload->{payload} == 29,
        'malformed owner bucket leaves caller payload unchanged and unblessed');
}
for my $bad ({}, { '$scalar' => 1, '@array' => [], '%hash' => {} },
        { BucketChild => { '$value' => 1, '@items' => [], '%items' => {} } }) {
    my $payload = {};
    eval { builtin::class_object_from_hash($bad, 'BucketChild', $payload) };
    like($@, qr/Class field bucket BucketParent must be a hash reference/, 'missing original owner bucket is diagnosed');
    ok(!Scalar::Util::blessed($payload), 'missing owner does not bless caller payload');
}

role BucketRole {
    field $role = 'default';
    field @role;
    field %role;
    method set_role($value) { $role = $value; @role = ($value); %role = (key => $value) }
    method role_value { $role }
    method anonymous_role { method { $role } }
    my method private_role { $role }
    method lexical_role { \&private_role }
    method invoke_role($callback) { $callback->($self) }
    method closure_role { sub { $role } }
    method factory_role { sub { method { $role } } }
}
class BucketPrefix { field $prefix = 7 }
class BucketRoleLeft :isa(BucketPrefix) :implements(BucketRole) { }
class BucketRoleRight :implements(BucketRole) { }
{
    package BucketLegacy;
    our @ISA = ('BucketRoleLeft', 'BucketRoleRight');
}
my $role_union = BucketLegacy->new;
BucketRoleLeft->can('set_role')->($role_union, 'left');
BucketRoleRight->can('set_role')->($role_union, 'right');
my $left_anon = BucketRoleLeft->can('anonymous_role')->($role_union);
my $right_anon = BucketRoleRight->can('anonymous_role')->($role_union);
is($left_anon->($role_union), 'left', 'escaped anonymous role method retains first consumer identity');
is($right_anon->($role_union), 'right', 'escaped anonymous role method retains second consumer identity');
my $left_lexical = BucketRoleLeft->can('lexical_role')->($role_union);
my $right_lexical = BucketRoleRight->can('lexical_role')->($role_union);
is($left_lexical->($role_union), 'left', 'escaped lexical method keeps first role consumer');
is($right_lexical->($role_union), 'right', 'escaped lexical method keeps second role consumer');
is(BucketRoleRight->can('invoke_role')->($role_union, $left_lexical), 'left',
    'captured lexical context wins over another active role consumer');
is(BucketRoleLeft->can('invoke_role')->($role_union, $right_lexical), 'right',
    'captured lexical context remains independent after alternate invocation');
my $left_closure = BucketRoleLeft->can('closure_role')->($role_union);
my $right_closure = BucketRoleRight->can('closure_role')->($role_union);
is($left_closure->(), 'left', 'escaped ordinary closure keeps first role field alias');
is($right_closure->(), 'right', 'escaped ordinary closure keeps second role field alias');
my $left_factory = BucketRoleLeft->can('factory_role')->($role_union);
my $right_factory = BucketRoleRight->can('factory_role')->($role_union);
my $left_nested = $left_factory->();
my $right_nested = $right_factory->();
is($left_nested->($role_union), 'left', 'nested anonymous method preserves first lexical consumer');
is($right_nested->($role_union), 'right', 'nested anonymous method preserves second lexical consumer');
SKIP: {
    skip('threads unavailable', 1) unless $Config{useithreads};
    require threads;
    my $values = threads->create(sub {
        return [$left_anon->($role_union), $right_anon->($role_union),
            $left_lexical->($role_union), $right_lexical->($role_union),
            $left_factory->()->($role_union), $right_factory->()->($role_union)];
    })->join;
    is(join(',', @$values), 'left,right,left,right,left,right', 'thread cloning retains independent escaped role contexts');
}
my $role_union_fields = builtin::class_object_to_hash($role_union);
for my $case (['BucketRoleLeft', 'left'], ['BucketRoleRight', 'right']) {
    my ($owner, $value) = @$case;
    is($role_union_fields->{$owner}{'$role'}, $value, "$owner owns composed scalar role field");
    is($role_union_fields->{$owner}{'@role'}[0], $value, "$owner role array uses its runtime class shift");
    is($role_union_fields->{$owner}{'%role'}{key}, $value, "$owner role hash uses its runtime class shift");
}
ok(!exists($role_union_fields->{BucketRole}) && !exists($role_union_fields->{BucketLegacy}),
    'role and conventional package names do not become storage buckets');
my $role_union_copy = builtin::class_object_from_hash($role_union_fields, 'BucketLegacy');
is(BucketRoleLeft->can('role_value')->($role_union_copy), 'left', 'legacy multiple-parent restoration preserves first role consumer');
is(BucketRoleRight->can('role_value')->($role_union_copy), 'right', 'legacy multiple-parent restoration preserves second role consumer');

{
    use feature qw(dispatch_on indirect);
    use dispatch::Predicates;
    my $parent_match = 0;
    dispatch ($shadow) {
        on (BucketParent { '$value' => 'parent', ... }) { $parent_match = 1 }
        on (_) { }
    };
    is($parent_match, 1, 'parent object pattern selects original parent storage on shadowing child');
    my $child_match = 0;
    dispatch ($shadow) {
        on (BucketChild { '$value' => 'child', ... }) { $child_match = 1 }
        on (_) { }
    };
    is($child_match, 1, 'child object pattern selects its own same-named field');
    my $alias = BucketAliasOnly->new(scalar => 11);
    my $alias_match = 0;
    dispatch ($alias) {
        on (BucketAliasOnly { '$scalar' => 11 }) { $alias_match = 1 }
        on (_) { }
    };
    is($alias_match, 1, 'alias-only class pattern projects the original aliased slot');
    my $legacy = bless { payload => 'ordinary' }, 'BucketLegacy';
    $legacy->CONSTRUCT;
    my $legacy_match = 0;
    dispatch ($legacy) {
        on (BucketLegacy { payload => 'ordinary' }) { $legacy_match = 1 }
        on (_) { }
    };
    is($legacy_match, 1, 'conventional object pattern uses payload despite attached modern fields');
}

done_testing();
