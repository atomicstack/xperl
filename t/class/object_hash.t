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
no warnings 'experimental::class';

class ObjectHashTest {
    field $scalar :param :reader;
    field @array;
    field %hash;
}

my $object = ObjectHashTest->new(scalar => 'value');
my $fields = builtin::class_object_to_hash($object);

is(ref($fields), 'HASH', 'to_hash returns a hash reference');
is($fields->{'$scalar'}, 'value', 'scalar field is represented directly');
is(ref($fields->{'@array'}), 'ARRAY', 'array field is represented by a reference');
is(ref($fields->{'%hash'}), 'HASH', 'hash field is represented by a reference');

$fields->{'@array'}[0] = 'shared';
$fields->{'%hash'}{key} = 'shared';
my $copy = builtin::class_object_from_hash($fields, 'ObjectHashTest');
my $copy_fields = builtin::class_object_to_hash($copy);
is($copy->scalar, 'value', 'from_hash restores scalar fields');
is($copy_fields->{'@array'}[0], 'shared', 'array field values are shared');
is($copy_fields->{'%hash'}{key}, 'shared', 'hash field values are shared');
is(refaddr($copy_fields->{'@array'}), refaddr($fields->{'@array'}),
   'array field referent is shared');
is(refaddr($copy_fields->{'%hash'}), refaddr($fields->{'%hash'}),
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
ok(eq_hash($role_fields, {
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
    my $restored = builtin::class_object_from_hash({'$value' => 1}, 'ObjectHashLifetime');
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
        '$scalar' => 1, '@array' => 'wrong', '%hash' => {},
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
    eval { builtin::class_object_from_hash($invalid, 'ObjectHashAggregateChild') };
    like($@, qr/has the wrong reference type/, 'role aggregate restoration validates referent type before inherited aliases bind');
}

done_testing();
