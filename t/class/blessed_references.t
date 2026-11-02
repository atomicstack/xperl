#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use feature 'class';
no warnings 'experimental::class';
use Scalar::Util qw(refaddr reftype weaken);

our @events;
class OrdinaryReference {
    field $value :param :reader;
    field @array;
    field %hash;
    method identity { $self }
    method aliases { \$value, \@array, \%hash }
    method DESTROY { push @main::events, "destroy:$value" }
    method TEARDOWN { push @main::events, "teardown:$value" }
    method rebless_inside {
        bless $self, 'OrdinaryAfter';
        $value++;
        push @array, 'kept';
        $hash{kept} = 1;
        return $value;
    }
}

{
    my $object = OrdinaryReference->new(value => 10);
    is(reftype($object), 'SCALAR', 'default object is an ordinary scalar reference');
    ok(!defined($$object), 'default referent is undef');
    is(refaddr($object->identity), refaddr($object), 'method sees public reference');
    my $same = $object->CONSTRUCT;
    is(refaddr($same), refaddr($object), 'repeated CONSTRUCT keeps identity');
    ok(!eval { $object->CONSTRUCT(value => 20); 1 }, 'repeated parameters are rejected');
    is($object->value, 10, 'repeated construction preserves fields');
    bless $object, 'OrdinaryReference';
    is($object->value, 10, 'same-class bless preserves fields');
}
is(join(',', @events), 'destroy:10,teardown:10', 'DESTROY precedes TEARDOWN');
@events = ();

for my $reference ({ payload => 42 }, [42], \my $payload) {
    bless $reference, 'OrdinaryReference';
    my $identity = refaddr($reference);
    my $object = $reference->CONSTRUCT(value => 21);
    is(refaddr($object), $identity, 'CONSTRUCT preserves an existing referent');
    is($object->value, 21, 'fields attach to an existing referent');
    my ($scalar, $array, $hash) = $object->aliases;
    is($object->rebless_inside, 22, 'active method keeps its field aliases after rebless');
    is($$scalar, 22, 'escaped scalar field survives storage release');
    is($array->[0], 'kept', 'escaped array field survives storage release');
    is($hash->{kept}, 1, 'escaped hash field survives storage release');
    is(ref($object), 'OrdinaryAfter', 'rebless changes the public blessing');
}
is(join(',', @events), 'teardown:21,teardown:21,teardown:21',
    'reblessing calls TEARDOWN once without DESTROY');
@events = ();

class OrdinaryEmpty {
    method TEARDOWN { push @main::events, 'empty' }
}
{
    my $object = OrdinaryEmpty->new;
    my $weak = $object;
    weaken($weak);
    undef $object;
    ok(!defined($weak), 'hidden storage does not retain the public object');
}
is(join(',', @events), 'empty', 'zero-field class participates in TEARDOWN');
@events = ();

{
    package OrdinaryLegacy;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub describe { $_[0]{legacy} }
}
class OrdinaryDerived :isa(OrdinaryLegacy) {
    field $modern :param :reader;
    sub new ($class, %args) {
        my $modern = delete $args{modern};
        my $self = $class->SUPER::new(%args);
        return $self->CONSTRUCT(modern => $modern);
    }
    method combined { $self->describe . ':' . $modern }
}
{
    my $object = OrdinaryDerived->new(legacy => 'old', modern => 'new');
    is(reftype($object), 'HASH', 'legacy constructor retains its hash referent');
    is($object->combined, 'old:new', 'modern and legacy methods share the public object');
    is($object->{legacy}, 'old', 'legacy payload is intact');
}

{
    package OrdinaryLegacyChild;
    our @ISA = ('OrdinaryReference');
}
{
    my $object = OrdinaryLegacyChild->new(value => 30);
    is(ref($object), 'OrdinaryLegacyChild', 'inherited constructor uses effective class');
    is($object->value, 30, 'legacy descendant has inherited modern fields');
}

our $saved;
our $resurrect = 1;
class OrdinaryResurrection {
    field $value = 7;
    method DESTROY {
        push @main::events, 'resurrect-destroy';
        $main::saved = $self if $main::resurrect-- > 0;
    }
    method TEARDOWN { push @main::events, "resurrect-teardown:$value" }
}
@events = ();
{ my $object = OrdinaryResurrection->new }
is(join(',', @events), 'resurrect-destroy', 'DESTROY resurrection defers TEARDOWN');
undef $saved;
is(join(',', @events), 'resurrect-destroy,resurrect-destroy,resurrect-teardown:7',
    'final destruction runs TEARDOWN once');

our $fail = 1;
class OrdinaryRetry {
    field $value :param :reader;
    ADJUST { die "initialization failed\n" if $main::fail }
}
my $reference = bless { payload => 9 }, 'OrdinaryRetry';
ok(!eval { $reference->CONSTRUCT(value => 1); 1 }, 'failed initialization propagates');
is($reference->{payload}, 9, 'failed initialization preserves ordinary payload');
$fail = 0;
is(refaddr($reference->CONSTRUCT(value => 2)), refaddr($reference), 'retry preserves identity');
is($reference->value, 2, 'retry initializes fresh fields');

{
    package OrdinaryNamedTeardown;
    sub TEARDOWN { push @main::events, 'legacy teardown' }
}
@events = ();
{ my $legacy = bless {}, 'OrdinaryNamedTeardown' }
is(scalar(@events), 0, 'legacy TEARDOWN name alone has no lifecycle effect');

@events = ();
class TeardownParent {
    field $base = 'base';
    method TEARDOWN { push @main::events, $base }
}
class TeardownChild :isa(TeardownParent) {
    field $child = 'child';
    method TEARDOWN {
        push @main::events, $child;
        $self->SUPER::TEARDOWN;
    }
}
{ my $object = TeardownChild->new }
is(join(',', @events), 'child,base', 'TEARDOWN uses normal lookup and explicit parent delegation');

class ThrowingTeardown {
    field $value = 9;
    method value { $value }
    method TEARDOWN { die "teardown failed:$value\n" }
}
{
    my $object = ThrowingTeardown->new;
    ok(!eval { bless $object, 'AfterThrow'; 1 }, 'explicit rebless propagates TEARDOWN exception');
    like($@, qr/teardown failed:9/, 'rebless retains hook exception');
    is(ref($object), 'ThrowingTeardown', 'failed rebless retains old blessing');
    ok(!eval { $object->value; 1 }, 'failed teardown releases state and later field methods fail cleanly');
    like($@, qr/without initialized class storage/, 'missing storage has clear diagnostic');
    bless $object, 'AfterThrow';
    is(ref($object), 'AfterThrow', 'later rebless does not repeat TEARDOWN');
}
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, "$_[0]" };
    { my $object = ThrowingTeardown->new }
    like(join('', @warnings), qr/teardown failed:9/, 'destruction reports TEARDOWN exceptions through cleanup warnings');
}

our $teardown_saved;
@events = ();
class TeardownResurrection {
    field $value = 17;
    sub DESTROY { push @main::events, 'destroy' }
    method TEARDOWN {
        push @main::events, "teardown:$value";
        $main::teardown_saved = $self;
    }
    method value { $value }
}
{ my $object = TeardownResurrection->new }
ok($teardown_saved, 'TEARDOWN may resurrect the public reference');
is(join(',', @events), 'destroy,teardown:17', 'resurrecting TEARDOWN runs once');
ok(!eval { $teardown_saved->value; 1 }, 'resurrected reference has released modern state');
undef $teardown_saved;
is(join(',', @events), 'destroy,teardown:17,destroy', 'later destruction follows ordinary DESTROY without TEARDOWN');

class RecursiveTeardown {
    field $value = 18;
    method TEARDOWN {
        bless $self, 'RecursiveTeardown';
        push @main::events, "same:$value";
        bless $self, 'NestedAfter';
    }
}
@events = ();
{
    my $object = RecursiveTeardown->new;
    ok(!eval { bless $object, 'OuterAfter'; 1 }, 'recursive different-class rebless is rejected');
    like($@, qr/during TEARDOWN/, 'recursive rebless has clear diagnostic');
    is(join(',', @events), 'same:18', 'recursive same-class bless preserves active state');
    bless $object, 'OuterAfter';
}

{
    package FieldReblesser;
    sub DESTROY { bless $_[0]{owner}, 'FieldAfter' if $_[0]{owner} }
}
class FieldRelease {
    field $held :param;
    method TEARDOWN { push @main::events, 'field-release' }
}
@events = ();
{
    my $held = bless {}, 'FieldReblesser';
    my $object = FieldRelease->new(held => $held);
    $held->{owner} = $object;
    weaken($held->{owner});
    undef $held;
    bless $object, 'OuterAfter';
    is(ref($object), 'OuterAfter', 'field destructor may rebless owner during storage release');
    is(join(',', @events), 'field-release', 'field destruction does not repeat TEARDOWN');
}

class UnrelatedLayout {
    field $other = 99;
    method other { $other }
}
{
    package MutableLegacyClass;
    our @ISA = ('OrdinaryReference');
}
{
    my $object = MutableLegacyClass->new(value => 8);
    @MutableLegacyClass::ISA = ('UnrelatedLayout');
    ok(!eval { $object->other; 1 }, 'changed legacy ISA cannot bind unrelated field layout');
    @MutableLegacyClass::ISA = ('OrdinaryReference');
    is($object->value, 8, 'original layout remains intact after rejected method');
}

class UnblessDuringMethod {
    field $value = 11;
    method keep_field {
        XS::APItest::sv_unbless($self);
        ++$value;
    }
    method unbless_classname {
        XS::APItest::sv_unbless($self);
        __CLASS__;
    }
    method rebless_classname {
        bless $self, 'ClassnameLegacy';
        __CLASS__;
    }
}
SKIP: {
    skip('XS::APItest unavailable', 8) unless eval { require XS::APItest; 1 };
    @events = ();
    my $object = OrdinaryReference->new(value => 19);
    XS::APItest::sv_unbless($object);
    is(ref($object), 'SCALAR', 'lifecycle unbless preserves ordinary referent');
    is(join(',', @events), 'teardown:19', 'unbless calls TEARDOWN without DESTROY');
    XS::APItest::sv_unbless($object);
    is(join(',', @events), 'teardown:19', 'repeated unbless is a no-op');
    my $legacy = bless {}, 'OrdinaryNamedTeardown';
    XS::APItest::sv_unbless($legacy);
    is(ref($legacy), 'HASH', 'legacy unbless preserves payload kind');
    is(join(',', @events), 'teardown:19', 'legacy unbless does not invent TEARDOWN behavior');
    is(UnblessDuringMethod->new->keep_field, 12, 'active method retains field alias after unbless');
    eval { UnblessDuringMethod->new->unbless_classname };
    like($@, qr/without initialized class storage/, '__CLASS__ after unbless fails cleanly');
    is(UnblessDuringMethod->new->rebless_classname, 'ClassnameLegacy',
        '__CLASS__ after rebless reflects the effective legacy package');
}

our $initializing_self;
class ReblessInDefault {
    field $first = do {
        bless $main::initializing_self, 'AfterInitializer';
        1;
    };
    field $second = 2;
}
$initializing_self = bless {}, 'ReblessInDefault';
ok(!eval { $initializing_self->CONSTRUCT; 1 }, 'reblessing during a field default fails cleanly');
like($@, qr/released during field initialization/, 'released initializer storage is diagnosed');
undef $initializing_self;

class LayoutBase { field $x = 1; method x { $x } }
class LayoutOther { field $y = 2; method y { $y } }
{
    package LegacyMultipleLayouts;
    our @ISA = ('LayoutBase', 'LayoutOther');
    package LegacyBetweenLayouts;
    our @ISA = ('LayoutBase');
}
class LayoutAcrossLegacy :isa(LegacyBetweenLayouts) { field $z = 3 }
{
    my $multiple = LegacyMultipleLayouts->new;
    is($multiple->x, 1, 'legacy multiple inheritance includes first modern part');
    is($multiple->y, 2, 'legacy multiple inheritance includes second modern part');
    my $across = LayoutAcrossLegacy->new;
    is($across->x, 1, 'modern inheritance through legacy package retains ancestor part');
    is(ref($across), 'LayoutAcrossLegacy', 'mixed modern and legacy chain preserves effective class');
}

{
    package LegacyTeardownParent;
    sub TEARDOWN { push @main::events, 'inherited legacy hook' }
    package LegacyAutoTeardown;
    our $AUTOLOAD;
    sub AUTOLOAD { push @main::events, 'autoload hook' }
    sub DESTROY { }
}
class InheritedLegacyTeardown :isa(LegacyTeardownParent) { }
class NoAutoloadTeardown :isa(LegacyAutoTeardown) { }
@events = ();
{ my $object = InheritedLegacyTeardown->new }
is(join(',', @events), 'inherited legacy hook', 'modern state enables inherited ordinary TEARDOWN sub');
@events = ();
{ my $object = NoAutoloadTeardown->new }
is(scalar(@events), 0, 'TEARDOWN lookup has no AUTOLOAD fallback');

our $reentrant;
class ReentrantConstruction {
    ADJUST { $self->CONSTRUCT if $main::reentrant }
}
$reentrant = 1;
ok(!eval { ReentrantConstruction->new; 1 }, 'reentrant CONSTRUCT from ADJUST fails');
like($@, qr/being initialized or released/, 'reentrant construction has clear diagnostic');
$reentrant = 0;
ok(ReentrantConstruction->new, 'later construction remains possible after failure');

class ConstructInTeardown {
    method TEARDOWN { $self->CONSTRUCT }
}
{
    my $object = ConstructInTeardown->new;
    ok(!eval { bless $object, 'AfterConstructInTeardown'; 1 }, 'TEARDOWN cannot reconstruct active storage');
    like($@, qr/being initialized or released/, 'release construction has clear diagnostic');
    bless $object, 'AfterConstructInTeardown';
}

class OrderedRelease {
    field $name :param;
    field $first :param = undef;
    field $second :param = undef;
    method DESTROY { push @main::events, "destroy:$name" }
    method TEARDOWN { push @main::events, "teardown:$name" }
}
{
    package OrderedPayload;
    sub DESTROY { push @main::events, 'payload' }
}
@events = ();
{
    my $object = bless { payload => bless({}, 'OrderedPayload') }, 'OrderedRelease';
    $object->CONSTRUCT(name => 'root',
        first => OrderedRelease->new(name => 'left',
            first => OrderedRelease->new(name => 'left-leaf')),
        second => OrderedRelease->new(name => 'right',
            second => OrderedRelease->new(name => 'right-leaf')));
    undef $object;
}
is(join(',', @events), join(',',
    'destroy:root', 'teardown:root',
    'destroy:right', 'teardown:right',
    'destroy:right-leaf', 'teardown:right-leaf',
    'destroy:left', 'teardown:left',
    'destroy:left-leaf', 'teardown:left-leaf', 'payload'),
    'final release walks fields depth-first in reverse order before ordinary payload');

class DeepReleaseChain {
    field $next :param = undef;
}
{
    my $head;
    $head = DeepReleaseChain->new(next => $head) for 1 .. 10000;
    undef $head;
    pass('deep acyclic class chain is released');
}

class OrdinaryGlobAlias {
    field $stored = 3;
    method stored { $stored }
}
{
    my $object = OrdinaryGlobAlias->new;
    our $ordinary_glob_alias;
    local *ordinary_glob_alias;
    *ordinary_glob_alias = $object;
    $ordinary_glob_alias = 99;
    is($$object, 99, 'ordinary scalar object can alias a glob scalar slot');
    is($object->stored, 3, 'glob alias mutation preserves modern field storage');
    is(refaddr(\$ordinary_glob_alias), refaddr($object), 'glob assignment preserves scalar referent identity');
}
{
    my $object = bless [], 'OrdinaryGlobAlias';
    is(ref($object), 'OrdinaryGlobAlias', 'ordinary bless can target a modern package');
    $object->CONSTRUCT;
    bless $object, 'main';
    is(ref($object), 'main', 'ordinary modern object can be reblessed into a legacy package');
}

done_testing();
