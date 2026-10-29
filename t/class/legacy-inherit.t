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
use builtin qw(reftype refaddr weaken blessed);

our (@dispatch, @constructors);

{
    package LegacyPoint;

    sub new {
        my ($class, %args) = @_;
        push @main::constructors, $class;
        return bless { x => $args{x}, y => $args{y} }, $class;
    }

    sub coords {
        my ($self) = @_;
        return @{$self}{qw(x y)};
    }

    sub kind { 'plain point' }

    sub describe {
        my ($self) = @_;
        push @main::dispatch,
            ['legacy', builtin::reftype($self), builtin::refaddr($self)];
        my ($x, $y) = $self->coords;
        my $kind = $self->kind;
        push @main::dispatch,
            ['legacy-return', builtin::reftype($self), builtin::refaddr($self)];
        return "Point($x, $y): $kind";
    }

    sub move {
        my ($self, $dx, $dy) = @_;
        $self->{x} += $dx;
        $self->{y} += $dy;
        return;
    }
}

{
    package SharedLegacyPoint;
    our @ISA = ('LegacyPoint');
    our $shared;

    sub new {
        my $class = shift;
        return $shared //= $class->SUPER::new(@_);
    }
}

my $compiled = eval q{
    class LegacyRGBPoint :legacy_isa(LegacyPoint) {
        field $legacy_self :legacy_self;
        field $red :param;
        field $green :param;
        field $blue :param;

        method kind {
            push @main::dispatch,
                ['native', builtin::reftype($self), builtin::refaddr($self)];
            return "rgb($red, $green, $blue)";
        }

        method legacy_object { $legacy_self }
    }
    class SharedRGBPoint :legacy_isa(SharedLegacyPoint) {
        field $legacy_self :legacy_self;
        field $tag :param;
        method kind { "shared $tag" }
    }
    1;
};

ok($compiled, 'class can declare a legacy superclass and legacy_self field');
unless ($compiled) {
    diag($@);
    done_testing;
    exit;
}

my $plain = LegacyPoint->new(x => 1, y => 2);
is($plain->describe, 'Point(1, 2): plain point', 'ordinary legacy object still works');
@constructors = ();
@dispatch = ();

my $point = LegacyRGBPoint->new(
    x => 10, y => 20, red => 200, green => 100, blue => 50,
);
is(reftype($point), 'OBJECT', 'constructor returns a native class instance');
is(join(',', @constructors), 'LegacyRGBPoint',
    'parent constructor receives the subclass and runs once');
ok($point isa LegacyPoint, 'native instance inherits from the legacy parent');
my $legacy = $point->legacy_object;
is(reftype($legacy), 'HASH', 'legacy_self retains the parent representation');
is(ref($legacy), 'LegacyRGBPoint', 'legacy object retains the subclass blessing');

@dispatch = ();
is($point->describe, 'Point(10, 20): rgb(200, 100, 50)',
    'inherited method calls the native override');
is(join(',', map { $_->[0] } @dispatch), 'legacy,native,legacy-return',
    'dispatch crosses into legacy code and back into native code');
is(join(',', map { $_->[1] } @dispatch), 'HASH,OBJECT,HASH',
    'each method receives its expected representation');
is($dispatch[0][2], refaddr($legacy), 'legacy method receives the stored reference');
is($dispatch[1][2], refaddr($point), 'override receives the original native instance');
is($dispatch[2][2], refaddr($legacy), 'legacy caller keeps its invocant after callback');

$point->move(3, -2);
is($point->describe, 'Point(13, 18): rgb(200, 100, 50)',
    'inherited method changes coordinates without changing native fields');

my $other = LegacyRGBPoint->new(
    x => 4, y => 5, red => 6, green => 7, blue => 8,
);
is($other->describe, 'Point(4, 5): rgb(6, 7, 8)',
    'another instance has independent native and legacy state');
is($point->describe, 'Point(13, 18): rgb(200, 100, 50)',
    'constructing another instance preserves the first association');

my $weak = $point;
weaken($weak);
my @warnings;
my $warning_exception;
{
    local $SIG{__WARN__} = sub { push @warnings, "$_[0]" };
    local $SIG{__EXCEPT__} = sub { $warning_exception = $_[0] };
    undef $point;
}
like(join("", @warnings), qr/Legacy references outlive/,
    'warns when a legacy reference outlives its native owner');
ok(!blessed($legacy), 'surviving legacy referent is unblessed');
my ($warning_diagnostic) = grep {
    $_->code eq 'WARNING_MISC_OBJECT_LEGACY_REFERENCE_SURVIVES'
} @{ $warning_exception->contents };
ok($warning_diagnostic && $warning_diagnostic->isa('XPerl::Diagnostic::Warning::Misc'),
    'escaped reference warning uses the structured misc warning class');
is(join(',', @{$warning_diagnostic->warning_categories}), 'WARN_MISC',
    'escaped reference warning retains its warning category');
ok(!defined($weak), 'magic backlink does not keep the native instance alive');
is(reftype($legacy), 'HASH', 'legacy reference can outlive the native instance');

my $first = SharedRGBPoint->new(x => 1, y => 2, tag => 'first');
my $duplicate = eval {
    SharedRGBPoint->new(x => 3, y => 4, tag => 'second');
};
my $duplicate_error = $@;
ok(!$duplicate && length($duplicate_error),
    'a legacy referent cannot back two live native instances');
my ($duplicate_diagnostic) = grep {
    $_->code eq 'ERROR_OBJECT_LEGACY_ALREADY_ATTACHED'
} @{ $duplicate_error->contents };
ok($duplicate_diagnostic && $duplicate_diagnostic->isa('XPerl::Diagnostic::Error::Object::Legacy'),
    'duplicate association has a typed legacy-object diagnostic');
is($first->describe, 'Point(1, 2): shared first',
    'rejected association preserves the original backlink and fields');

undef $SharedLegacyPoint::shared;
undef $first;
undef $legacy;
undef $other;

our (@destroyed, $resurrected);
{
    package DestructiblePoint;
    our @ISA = ('LegacyPoint');
    sub DESTROY {
        push @main::destroyed, 'legacy:' . builtin::reftype($_[0]);
    }
}
{
    package ArrayPoint;
    sub new { my $class = shift; bless [@_], $class }
    sub first { $_[0][0] }
}
{
    package ScalarPoint;
    sub new { my $class = shift; my $value = 42; bless \$value, $class }
    sub value { ${$_[0]} }
}
{
    package CodePoint;
    sub new { my $class = shift; my $value = 42; bless sub { $value }, $class }
    sub value { $_[0]->() }
}

my $more = eval q{
    class InheritedDestroy :legacy_isa(DestructiblePoint) {
        field $legacy :legacy_self;
    }
    class NativeDestroy :legacy_isa(DestructiblePoint) {
        field $legacy :legacy_self;
        method DESTROY { push @main::destroyed, 'native:' . builtin::reftype($self) }
    }
    class ChainedDestroy :legacy_isa(DestructiblePoint) {
        field $legacy :legacy_self;
        method DESTROY {
            push @main::destroyed, 'native:' . builtin::reftype($self);
            $self->SUPER::DESTROY;
        }
    }
    class ResurrectPoint :legacy_isa(DestructiblePoint) {
        field $legacy :legacy_self;
        method DESTROY { $main::resurrected = $self unless $main::resurrected }
        method legacy_object { $legacy }
    }
    class ArrayChild :legacy_isa(ArrayPoint) { field $legacy :legacy_self; }
    class ScalarChild :legacy_isa(ScalarPoint) { field $legacy :legacy_self; }
    class CodeChild :legacy_isa(CodePoint) { field $legacy :legacy_self; }
    class NativeGrandchild :isa(LegacyRGBPoint) {
        field $extra :param;
        method extra { $extra }
    }
    class RebindPoint :legacy_isa(LegacyPoint) {
        field $legacy :legacy_self;
        method replace { $legacy = {} }
    }
    1;
};
ok($more, 'additional legacy subclasses compile') or diag($@);
if($more) {
    for my $case (
        ['InheritedDestroy', 'legacy:HASH'],
        ['NativeDestroy', 'native:OBJECT'],
        ['ChainedDestroy', 'native:OBJECT,legacy:HASH'],
    ) {
        @destroyed = ();
        { my $obj = $case->[0]->new(x => 1, y => 2); }
        is(join(',', @destroyed), $case->[1], "$case->[0] destroys exactly once");
    }
    is(ArrayChild->new(word => 'value')->first, 'word', 'blessed array parent');
    is(ScalarChild->new->value, 42, 'blessed scalar parent');
    is(CodeChild->new->value, 42, 'blessed code parent');
    my $grand = NativeGrandchild->new(x => 1, y => 2,
        red => 3, green => 4, blue => 5, extra => 6);
    is($grand->describe, 'Point(1, 2): rgb(3, 4, 5)', 'native subclass inherits association');
    is($grand->extra, 6, 'native subclass has its own fields');
    my $rebind = RebindPoint->new(x => 1, y => 2);
    eval { $rebind->replace };
    like($@, qr/read.only/, 'legacy association cannot be replaced');
    { my $obj = ResurrectPoint->new(x => 7, y => 8); }
    ok($resurrected, 'native destructor can resurrect its object');
    is(join(',', $resurrected->coords), '7,8', 'resurrection preserves association');
    ok(blessed($resurrected->legacy_object), 'resurrection preserves legacy blessing');
    # Prevent another resurrection while releasing the saved object.
    my $saved = $resurrected;
    $resurrected = 1;
    undef $saved;
    undef $resurrected;
}


{
    my $obj = LegacyRGBPoint->new(x => 11, y => 12, red => 1, green => 2, blue => 3);
    my $method = 'describe';
    is($obj->$method, 'Point(11, 12): rgb(1, 2, 3)', 'dynamic legacy method name');
    my $cv = $obj->can('describe');
    is($obj->$cv, 'Point(11, 12): rgb(1, 2, 3)', 'legacy method CV invocant');
    my $native_cv = $obj->can('kind');
    is($native_cv->($obj->legacy_object), 'rgb(1, 2, 3)', 'direct native CV accepts associated legacy reference');
    my $fields = builtin::class_object_to_hash($obj);
    eval { builtin::class_object_from_hash($fields, 'LegacyRGBPoint') };
    like($@, qr/already belongs/, 'restoration rejects a second live owner');
    is($obj->describe, 'Point(11, 12): rgb(1, 2, 3)', 'failed restoration leaves original association intact');
    undef $fields;
}
{
    my $before = @constructors;
    my $restored = builtin::class_object_from_hash({
        '$legacy_self' => bless({x => 21, y => 22}, 'LegacyRGBPoint'),
        '$red' => 7, '$green' => 8, '$blue' => 9,
    }, 'LegacyRGBPoint');
    is(scalar @constructors, $before, 'restoration does not call parent constructor');
    is($restored->describe, 'Point(21, 22): rgb(7, 8, 9)', 'restoration establishes reverse dispatch');
}

for my $case (
    ['MissingLegacyField', ':legacy_isa(LegacyPoint)', '', qr/requires a :legacy_self field/],
    ['ArrayLegacyField', ':legacy_isa(LegacyPoint)', 'field @legacy :legacy_self;', qr/requires one scalar/],
    ['DuplicateLegacyField', ':legacy_isa(LegacyPoint)', 'field $a :legacy_self; field $b :legacy_self;', qr/already has/],
    ['RepeatedLegacyAttribute', ':legacy_isa(LegacyPoint)', 'field $a :legacy_self :legacy_self;', qr/already has/],
    ['InheritedLegacyField', ':isa(LegacyRGBPoint)', 'field $different_name :legacy_self;', qr/already has/],
    ['GrandchildLegacyField', ':isa(NativeGrandchild)', 'field $different_name :legacy_self;', qr/already has/],
    ['ParameterLegacyField', ':legacy_isa(LegacyPoint)', 'field $a :legacy_self :param;', qr/requires one scalar/],
    ['InitializedLegacyField', ':legacy_isa(LegacyPoint)', 'field $a :legacy_self = {};', qr/requires one scalar/],
    ['NoLegacyParent', '', 'field $a :legacy_self;', qr/requires one scalar/],
) {
    eval "class $case->[0] $case->[1] { $case->[2] }";
    like($@, $case->[3], "$case->[0] rejected");
}


{
    package OverloadedPoint;
    our @ISA = ('LegacyPoint');
    use overload '""' => sub { $_[0]->describe }, fallback => 1;
}
{
    package StrictPoint;
    sub new {
        my ($class, %args) = @_;
        die 'unexpected native argument' if exists $args{colour};
        bless \%args, $class;
    }
    sub describe { my ($self) = @_; "$self->{x}:" . $self->colour }
    our $AUTOLOAD;
    sub AUTOLOAD { my ($self) = @_; "$self->{x}:autoload" }
    sub DESTROY { }
}
{
    package FailingPoint;
    sub new { die "parent constructor failed\n" }
}
{
    package InvalidPoint;
    sub new { {} }
}
my $last = eval q{
    class NativeOverloaded :legacy_isa(OverloadedPoint) {
        field $legacy :legacy_self;
        method kind { 'overloaded' }
    }
    class NativeStrict :legacy_isa(StrictPoint) {
        field $legacy :legacy_self;
        field $colour :param;
        method colour { $colour }
    }
    class NativeFailing :legacy_isa(FailingPoint) { field $legacy :legacy_self; }
    class NativeInvalid :legacy_isa(InvalidPoint) { field $legacy :legacy_self; }
    class FailingAdjust :legacy_isa(DestructiblePoint) {
        field $legacy :legacy_self;
        ADJUST { die "adjust failed\n" }
    }
    1;
};
ok($last, 'failure and overload fixtures compile') or diag($@);
if($last) {
    my $obj = NativeOverloaded->new(x => 3, y => 4);
    is("$obj", 'Point(3, 4): overloaded', 'inherited overload receives legacy self and calls native override');
    my $strict = NativeStrict->new(x => 5, colour => 'green');
    is($strict->describe, '5:green', 'native parameters are not passed to strict parent constructor');
    is($strict->missing, '5:autoload', 'legacy AUTOLOAD receives the legacy self');
    eval { NativeFailing->new };
    like($@, qr/parent constructor failed/, 'parent constructor failure propagates');
    eval { NativeInvalid->new };
    like($@, qr/blessed non.native reference/, 'unblessed parent result rejected');
    @destroyed = ();
    eval { FailingAdjust->new(x => 1, y => 2) };
    like($@, qr/adjust failed/, 'adjust failure propagates');
    is(join(',', @destroyed), 'legacy:HASH', 'failed adjustment releases legacy object exactly once');
    SKIP: {
        skip('XS::APItest unavailable', 1) unless eval { require XS::APItest; 1 };
        my @result = XS::APItest::call_method('describe', XS::APItest::G_SCALAR(), $strict);
        is($result[0], '5:green', 'C call_method performs legacy dispatch');
    }
}


{
    no warnings 'once';
    *LegacyPoint::xs_reftype = \&builtin::reftype;
}
my $signatures = eval q{
    class SignaturePoint :legacy_isa(LegacyPoint) {
        field $legacy :legacy_self;
        field $name :param;
        method label($suffix) { "$name:$suffix" }
        method legacy_object { $legacy }
    }
    1;
};
ok($signatures, 'signatured method fixture compiles') or diag($@);
if($signatures) {
    my $obj = SignaturePoint->new(x => 1, y => 2, name => 'point');
    is($obj->xs_reftype, 'HASH', 'legacy XS method receives the legacy reference');
    is($obj->legacy_object->label('arrow'), 'point:arrow', 'signatured method via legacy invocant');
    my $method = $obj->can('label');
    is($method->($obj->legacy_object, 'direct'), 'point:direct', 'direct signatured native CV maps legacy invocant');
    is(LegacyPoint::xs_reftype($obj), 'OBJECT', 'ordinary function calls preserve native arguments');
}


my $roles = eval q{
    role LegacyLabelRole {
        field $tag :param;
        method tag { $tag }
    }
    class RoleLegacyPoint :legacy_isa(LegacyPoint) :implements(LegacyLabelRole) {
        field $legacy :legacy_self;
        field $name :param;
        method kind { "$name:" . $self->tag }
    }
    1;
};
ok($roles, 'legacy subclass can compose a role') or diag($@);
if($roles) {
    my $obj = RoleLegacyPoint->new(x => 1, y => 2, tag => 'role', name => 'point');
    is($obj->describe, 'Point(1, 2): point:role', 'role fields preserve legacy field indexing');
    ok($obj->implements('LegacyLabelRole'), 'role query works on legacy subclass');
}

{
    @destroyed = ();
    {
        my $restored = builtin::class_object_from_hash({
            '$legacy' => bless({x => 1, y => 2}, 'InheritedDestroy'),
        }, 'InheritedDestroy');
        is(join(',', $restored->coords), '1,2', 'restored legacy state is usable');
    }
    is(join(',', @destroyed), 'legacy:HASH', 'restored object releases its legacy self');
}

{
    my @unexpected;
    local $SIG{__WARN__} = sub { push @unexpected, "$_[0]" };
    my $invoke = sub {
        my $obj = LegacyRGBPoint->new(x => 1, y => 2, red => 3, green => 4, blue => 5);
        return [$obj->describe];
    };
    is($invoke->()->[0], 'Point(1, 2): rgb(3, 4, 5)', 'legacy call in a return expression');
    is(scalar @unexpected, 0, 'method argument temporaries do not look like escaped references');
}


for my $case (
    ['ERROR_OBJECT_COMPOSITION_INHERITANCE_LEGACY_SUPERCLASS_REQUIRED', 'Composition::Inheritance'],
    ['ERROR_OBJECT_FIELD_ATTRIBUTE_LEGACY_SELF_INVALID', 'Field::Attribute'],
    ['ERROR_OBJECT_FIELD_ATTRIBUTE_LEGACY_SELF_ALREADY_ASSIGNED', 'Field::Attribute'],
    ['ERROR_OBJECT_DEFINITION_LEGACY_SELF_REQUIRED', 'Definition'],
    ['ERROR_OBJECT_LEGACY_REFERENCE_INVALID', 'Legacy'],
    ['ERROR_OBJECT_LEGACY_ALREADY_ATTACHED', 'Legacy'],
    ['ERROR_OBJECT_METHOD_CALL_LEGACY_SELF_UNAVAILABLE', 'MethodCall'],
) {
    my $schema = builtin::get_diagnostic_data($case->[0]);
    is($schema->{class}, "XPerl::Diagnostic::Error::Object::$case->[1]",
        "$case->[0] has its semantic exception class");
    ok($schema->{counts_as_error}, "$case->[0] counts as an error");
}

SKIP: {
    skip('XS::APItest unavailable', 2) unless eval { require XS::APItest; 1 };
    {
        no warnings 'once';
        *LegacyPoint::xs_self = \&XS::APItest::return_first_arg;
    }
    my $obj = LegacyRGBPoint->new(x => 1, y => 2, red => 3, green => 4, blue => 5);
    my $result = $obj->xs_self;
    is(refaddr($result), refaddr($obj->legacy_object), 'XS method may return its argument SV');
    is($result->kind, 'rgb(3, 4, 5)', 'returned XS argument retains its association');
    undef $result;
}

my $renamed = eval q{
    class NamedLegacyStorage :legacy_isa(LegacyPoint) {
        field $coordinates_storage :legacy_self;
        method kind { 'named storage' }
        method legacy_object { $coordinates_storage }
    }
    class ShadowLegacyStorage :isa(NamedLegacyStorage) {
        field $coordinates_storage :param;
        method own_storage { $coordinates_storage }
    }
    class InheritedNamedStorage :isa(ShadowLegacyStorage) { }
    1;
};
ok($renamed, 'legacy self may use a different lexical field name') or diag($@);
if($renamed) {
    my $obj = InheritedNamedStorage->new(x => 8, y => 9, coordinates_storage => 'ordinary field');
    is($obj->describe, 'Point(8, 9): named storage', 'inherited association follows its field slot');
    is($obj->own_storage, 'ordinary field', 'same-named ordinary field remains distinct');
    is(reftype($obj->legacy_object), 'HASH', 'base accessor reads the original legacy slot');
    eval q{ class RenamedDuplicateStorage :isa(InheritedNamedStorage) {
        field $renamed_again :legacy_self;
    } };
    like($@, qr/already has/, 'renaming cannot introduce a second inherited legacy self');
}

{
    my $obj = LegacyRGBPoint->new(x => 1, y => 2, red => 3, green => 4, blue => 5);
    my $escaped = $obj->legacy_object;
    my $weak = $obj;
    weaken($weak);
    my $error;
    {
        use warnings FATAL => 'misc';
        eval { undef $obj };
        $error = $@;
    }
    like($error, qr/Legacy references outlive/, 'escaped-reference warning can be fatalized');
    ok(!defined($weak), 'fatal warning finishes native destruction');
    ok(!blessed($escaped), 'fatal warning leaves the legacy referent unblessed');
}

done_testing;
