#!./perl
BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}
use v5.36;
use feature 'class';
no warnings 'experimental::class';
no warnings 'experimental::builtin';
use Scalar::Util qw(refaddr);
use Config;
our ($initializations, @adjusted, @released);

class InheritedBase {
    field $foo = do { ++$main::initializations; 5 };
    field @array = (1);
    field %hash = (key => 2);
    field $secret :private = 7;
    ADJUST { push @main::adjusted, 'base' }
    method foo { $foo }
    method secret { $secret }
    method references { \$foo, \@array, \%hash }
    method TEARDOWN { push @main::released, "base:$foo" }
}
class InheritedChild :isa(InheritedBase) {
    field $foo :inherited :reader(child_foo) :writer(set_child_foo);
    field @array :inherited;
    field %hash :inherited;
    field $own = $foo + 10;
    field $sum = $foo + $own;
    ADJUST { push @main::adjusted, 'child' }
    method child_references { \$foo, \@array, \%hash }
    method own { $own }
    method sum { $sum }
    method mutate { ++$foo; push @array, 3; $hash{other} = 4 }
}
class InheritedGrandchild :isa(InheritedChild) {
    field $foo :inherited;
    field @array :inherited;
    field %hash :inherited;
    method grand_references { \$foo, \@array, \%hash }
    method increment { ++$foo }
}
$initializations = 0;
@adjusted = ();
my $object = InheritedGrandchild->new;
is($initializations, 1, 'original inherited field initializer runs once');
is(join(',', @adjusted), 'base,child', 'each declaring class adjustment runs once');
is($object->own, 15, 'inherited field is bound before own default');
is($object->sum, 20, 'later default sees inherited and initialized own fields');
my @base = $object->references;
my @child = $object->child_references;
my @grand = $object->grand_references;
for my $i (0 .. 2) {
    is(refaddr($child[$i]), refaddr($base[$i]), 'child alias shares original storage for sigil ' . substr('$@%', $i, 1));
    is(refaddr($grand[$i]), refaddr($base[$i]), 'grandchild alias shares original storage');
}
is($object->child_foo, 5, 'generated reader works on alias');
$object->set_child_foo(40);
is($object->foo, 40, 'generated alias writer updates original field');
is($object->increment, 41, 'grandchild alias mutates original field');
$object->mutate;
is($object->foo, 42, 'child scalar alias mutates original field');
is(join(',', @{$base[1]}), '1,3', 'array alias mutates original array');
is($base[2]{other}, 4, 'hash alias mutates original hash');
is($object->secret, 7, 'original methods access private fields on descendant object');

{
    package InheritedLegacyMiddle;
    our @ISA;
    BEGIN { @ISA = ('InheritedBase') }
}
class InheritedAcrossLegacy :isa(InheritedLegacyMiddle) {
    field $foo :inherited;
    field $bar = $foo + 1;
    field $baz = $foo + $bar;
    method values { $foo, $bar, $baz }
}
my $mixed = InheritedAcrossLegacy->new;
is(join(',', $mixed->values), '5,6,11', 'inherited pads are not overwritten by own initializer indices through legacy parent');

role InheritedRole {
    field $role_value = 13;
    field $role_secret :private = 14;
    method role_value { $role_value }
    method role_secret { $role_secret }
}
class InheritedRoleParent :implements(InheritedRole) { field $prefix = 1 }
class InheritedRoleChild :isa(InheritedRoleParent) {
    field $role_value :inherited;
    method increment_role { ++$role_value }
}
my $role = InheritedRoleChild->new;
is($role->increment_role, 14, 'alias resolves storage supplied by parent-composed role');
is($role->role_value, 14, 'parent role method sees same inherited storage');
is($role->role_secret, 14, 'private role field is accessible to its original methods');

my $fields = builtin::class_object_to_hash($object);
ok(eq_array([sort keys %$fields], ['$self', qw(InheritedBase InheritedChild)]),
    'field hash contains only original storage owners');
ok(eq_array([sort keys %{$fields->{InheritedBase}}], [sort qw($foo @array %hash $secret)]),
    'base owner bucket contains its original fields');
ok(eq_array([sort keys %{$fields->{InheritedChild}}], [sort qw($own $sum)]),
    'child owner bucket omits inherited aliases');
my $copy = builtin::class_object_from_hash($fields, 'InheritedGrandchild');
is($copy->increment, 43, 'restored aliases resolve original shared scalar field');
is($object->foo, 43, 'shallow restoration retains original field value sharing');
is($copy->secret, 7, 'restored private field remains available to original methods');

for my $case (
    ['Missing', ':isa(InheritedBase)', 'field $absent :inherited;', qr/No ancestor declares/],
    ['Private', ':isa(InheritedBase)', 'field $secret :inherited;', qr/private and cannot/],
    ['RolePrivate', ':isa(InheritedRoleParent)', 'field $role_secret :inherited;', qr/private and cannot/],
    ['Initializer', ':isa(InheritedBase)', 'field $foo :inherited = 1;', qr/with :inherited/],
    ['ParamAfter', ':isa(InheritedBase)', 'field $foo :inherited :param;', qr/with :inherited/],
    ['ParamBefore', ':isa(InheritedBase)', 'field $foo :param :inherited;', qr/with :inherited/],
    ['PrivateAfter', ':isa(InheritedBase)', 'field $foo :inherited :private;', qr/with :private/],
    ['PrivateBefore', ':isa(InheritedBase)', 'field $foo :private :inherited;', qr/with :inherited/],
    ['Repeated', ':isa(InheritedBase)', 'field $foo :inherited :inherited;', qr/with :inherited/],
    ['Value', ':isa(InheritedBase)', 'field $foo :inherited(x);', qr/with :inherited/],
    ['PrivateValue', '', 'field $foo :private(x);', qr/with :private/],
) {
    eval "class InheritedBad$case->[0] $case->[1] { $case->[2] }";
    like($@, $case->[3], "$case->[0] inherited declaration is rejected");
}
eval q{ role InheritedBadRole { field $foo :inherited } };
like($@, qr/with :inherited/, 'roles cannot declare inherited class storage');
eval q{ class InheritedNotImplicit :isa(InheritedBase) { method unbound { $foo } } };
like($@, qr/Global symbol|not accessible/, 'ancestor field is not implicitly in lexical scope');

class InheritedShadow :isa(InheritedBase) {
    field $foo = 9;
    method shadow_foo { $foo }
}
my $shadow = InheritedShadow->new;
is($shadow->foo, 5, 'parent method keeps its original same-named field');
is($shadow->shadow_foo, 9, 'child owns a distinct same-named field');
eval q{ class InheritedShadowGrand :isa(InheritedShadow) { field $foo :inherited } };
like($@, qr/ambiguous ancestor declarations/, 'inherited name is ambiguous across parent and grandparent originals');

class InheritedOtherBase { field $foo = 99 }
{
    package InheritedAmbiguousLegacy;
    our @ISA;
    BEGIN { @ISA = ('InheritedBase', 'InheritedOtherBase') }
}
eval q{ class InheritedAmbiguous :isa(InheritedAmbiguousLegacy) { field $foo :inherited } };
like($@, qr/ambiguous ancestor declarations/, 'multiple distinct ancestor declarations are diagnosed');

@InheritedLegacyMiddle::ISA = ('InheritedOtherBase');
is(join(',', $mixed->values), '5,6,11', 'existing object retains sealed inherited storage after legacy ISA mutation');
eval { InheritedAcrossLegacy->new };
like($@, qr/Storage owner.*absent/, 'new construction rejects missing sealed alias owner after ISA mutation');
@InheritedLegacyMiddle::ISA = ('InheritedBase');

class InheritedParamBase { field $argument :param :reader }
class InheritedParamChild :isa(InheritedParamBase) {
    field $argument :inherited;
    method parameter_alias { $argument }
}
class InheritedParamGrand :isa(InheritedParamChild) {
    field $argument :inherited;
    method parameter_grand { $argument }
}
my $parameter = InheritedParamGrand->CONSTRUCT(argument => 23);
is($parameter->argument, 23, 'original parameter initializes inherited field once');
is($parameter->parameter_alias, 23, 'child alias reads original parameter');
is($parameter->parameter_grand, 23, 'grandchild alias reads original parameter');
is(Scalar::Util::reftype($parameter), 'SCALAR', 'class-name CONSTRUCT keeps ordinary scalar representation');

class InheritedDiamondLeft :isa(InheritedBase) { field $foo :inherited }
class InheritedDiamondRight :isa(InheritedBase) { field $foo :inherited }
{
    package InheritedDiamondLegacy;
    our @ISA;
    BEGIN { @ISA = ('InheritedDiamondLeft', 'InheritedDiamondRight') }
}
class InheritedDiamond :isa(InheritedDiamondLegacy) {
    field $foo :inherited;
    field $extra = 2;
    method diamond_value { $foo + $extra }
}
my $diamond = InheritedDiamond->new;
is($diamond->diamond_value, 7, 'diamond aliases deduplicate the same original field declaration');
my $diamond_fields = builtin::class_object_to_hash($diamond);
is(scalar(grep { $_ eq '$foo' } keys %{$diamond_fields->{InheritedBase}}), 1,
    'diamond aliases serialize the original field once under its owner');
ok(!exists($diamond_fields->{InheritedDiamondLeft}) && !exists($diamond_fields->{InheritedDiamondRight}),
    'alias-only diamond branches have no buckets');

SKIP: {
    skip('threads unavailable', 2) unless $Config{useithreads};
    require threads;
    my $values = threads->create(sub {
        my $value = $object->increment;
        eval q{ class InheritedThreadChild :isa(InheritedGrandchild) {
            field $foo :inherited;
            method next_value { ++$foo }
        } };
        die $@ if $@;
        my $new = InheritedThreadChild->new;
        return [$value, $new->next_value];
    })->join;
    is(join(',', @$values), '44,6', 'threads clone aliases and can seal new inherited subclasses');
    is($object->foo, 43, 'thread alias mutations preserve original interpreter fields');
}

@released = ();
undef $fields;
undef $copy;
undef $object;
is(join(',', @released), 'base:43,base:43', 'lifecycle delegates once per public object despite inherited aliases');
is(${$base[0]}, 43, 'escaped alias retains original field after object release');

done_testing();
