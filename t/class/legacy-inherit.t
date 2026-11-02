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

class LegacyRGBPoint :isa(LegacyPoint) {
    field $red :param;
    field $green :param;
    field $blue :param;
    sub new ($class, %args) {
        my %modern;
        for my $name (qw(red green blue)) {
            $modern{$name} = delete $args{$name} if exists $args{$name};
        }
        my $self = $class->SUPER::new(%args);
        return $self->CONSTRUCT(%modern);
    }
    method kind {
        push @main::dispatch,
            ['modern', builtin::reftype($self), builtin::refaddr($self)];
        return "rgb($red, $green, $blue)";
    }
}

my $plain = LegacyPoint->new(x => 1, y => 2);
is($plain->describe, 'Point(1, 2): plain point', 'ordinary legacy object works');
@constructors = ();
my $point = LegacyRGBPoint->new(x => 10, y => 20, red => 200, green => 100, blue => 50);
is(reftype($point), 'HASH', 'modern object retains ordinary parent referent');
is(join(',', @constructors), 'LegacyRGBPoint', 'parent constructor runs once with effective class');
ok($point isa LegacyPoint, 'modern instance inherits the legacy parent');
@dispatch = ();
is($point->describe, 'Point(10, 20): rgb(200, 100, 50)', 'legacy method calls modern override');
is(join(',', map { $_->[0] } @dispatch), 'legacy,modern,legacy-return', 'ordinary dispatch crosses method kinds');
is(join(',', map { $_->[1] } @dispatch), 'HASH,HASH,HASH', 'all methods receive the same reference kind');
ok(!(grep { $_->[2] != refaddr($point) } @dispatch), 'all calls retain reference identity');
$point->move(3, -2);
is($point->describe, 'Point(13, 18): rgb(200, 100, 50)', 'legacy payload mutates independently of fields');
my $other = LegacyRGBPoint->new(x => 4, y => 5, red => 6, green => 7, blue => 8);
is($other->describe, 'Point(4, 5): rgb(6, 7, 8)', 'instances have independent fields and payload');
is($point->describe, 'Point(13, 18): rgb(200, 100, 50)', 'second construction preserves first object');
my $alias = $point;
my $weak = $point;
weaken($weak);
undef $point;
ok(defined($weak), 'ordinary strong alias retains the object');
is($alias->kind, 'rgb(200, 100, 50)', 'ordinary alias retains fields and blessing');
undef $alias;
ok(!defined($weak), 'storage does not keep the public object alive');

class SharedRGBPoint :isa(SharedLegacyPoint) {
    field $tag :param :reader;
    sub new ($class, %args) {
        my $tag = delete $args{tag};
        return $class->SUPER::new(%args)->CONSTRUCT(tag => $tag);
    }
}
{
    my $first = SharedRGBPoint->new(x => 1, y => 2, tag => 'first');
    eval { SharedRGBPoint->new(x => 3, y => 4, tag => 'second') };
    like($@, qr/already constructed/, 'cached legacy referent cannot initialize modern fields twice');
    is($first->tag, 'first', 'failed repeated construction preserves existing fields');
    is(join(',', $first->coords), '1,2', 'cached ordinary payload is intact');
    undef $SharedLegacyPoint::shared;
}

class NativeGrandchild :isa(LegacyRGBPoint) {
    field $extra :param :reader;
    sub new ($class, %args) {
        my $extra = delete $args{extra};
        my %modern;
        for my $name (qw(red green blue)) { $modern{$name} = delete $args{$name} }
        my $self = $class->LegacyPoint::new(%args);
        return $self->CONSTRUCT(%modern, extra => $extra);
    }
}
my $grand = NativeGrandchild->new(x => 1, y => 2, red => 3, green => 4, blue => 5, extra => 6);
is($grand->describe, 'Point(1, 2): rgb(3, 4, 5)', 'modern descendant inherits legacy payload and modern fields');
is($grand->extra, 6, 'modern descendant has its own fields');

{
    package ArrayPoint;
    sub new { bless [42], shift }
    sub value { $_[0][0] }
    package ScalarPoint;
    sub new { my $value = 42; bless \$value, shift }
    sub value { ${$_[0]} }
    package CodePoint;
    sub new { bless sub { 42 }, shift }
    sub value { $_[0]->() }
}
class ArrayChild :isa(ArrayPoint) {
    sub new ($class) { $class->SUPER::new->CONSTRUCT }
}
class ScalarChild :isa(ScalarPoint) {
    sub new ($class) { $class->SUPER::new->CONSTRUCT }
}
class CodeChild :isa(CodePoint) {
    sub new ($class) { $class->SUPER::new->CONSTRUCT }
}
for my $class (qw(ArrayChild ScalarChild CodeChild)) {
    is($class->new->value, 42, "$class retains its ordinary referent behavior");
}

{
    package OverloadedPoint;
    our @ISA = ('LegacyPoint');
    use overload '""' => sub { $_[0]->describe }, fallback => 1;
}
class ModernOverloaded :isa(OverloadedPoint) {
    sub new ($class, %args) { $class->SUPER::new(%args)->CONSTRUCT }
    method kind { 'overloaded' }
}
my $overloaded = ModernOverloaded->new(x => 3, y => 4);
is("$overloaded", 'Point(3, 4): overloaded', 'inherited overload calls modern override');

{
    package StrictPoint;
    sub new {
        my ($class, %args) = @_;
        die 'unexpected modern argument' if exists $args{colour};
        bless \%args, $class;
    }
    sub describe { $_[0]{x} . ':' . $_[0]->colour }
    our $AUTOLOAD;
    sub AUTOLOAD { $_[0]{x} . ':autoload' }
    sub DESTROY { }
}
class ModernStrict :isa(StrictPoint) {
    field $colour :param :reader;
    sub new ($class, %args) {
        my $colour = delete $args{colour};
        return $class->SUPER::new(%args)->CONSTRUCT(colour => $colour);
    }
}
my $strict = ModernStrict->new(x => 5, colour => 'green');
is($strict->describe, '5:green', 'custom constructor separates legacy and field parameters');
is($strict->missing, '5:autoload', 'legacy AUTOLOAD receives ordinary referent');

role LegacyLabelRole {
    field $tag :param :reader;
}
class RoleLegacyPoint :isa(LegacyPoint) :implements(LegacyLabelRole) {
    field $name :param;
    sub new ($class, %args) {
        my %modern;
        for my $key (qw(tag name)) { $modern{$key} = delete $args{$key} }
        return $class->SUPER::new(%args)->CONSTRUCT(%modern);
    }
    method kind { "$name:" . $self->tag }
    method label($suffix) { "$name:$suffix" }
}
my $role = RoleLegacyPoint->new(x => 1, y => 2, name => 'point', tag => 'role');
is($role->describe, 'Point(1, 2): point:role', 'role fields retain composition offsets');
ok($role->implements('LegacyLabelRole'), 'legacy subclass composes role');
my $label = $role->can('label');
is($label->($role, 'direct'), 'point:direct', 'signatured method accepts direct public invocant');
my $describe = $role->can('describe');
is($role->$describe, 'Point(1, 2): point:role', 'legacy method CV uses ordinary invocant');
{
    no warnings 'once';
    *LegacyPoint::xs_reftype = \&builtin::reftype;
}
is($role->xs_reftype, 'HASH', 'legacy XSUB method sees ordinary referent');
is(LegacyPoint::xs_reftype($role), 'HASH', 'ordinary XSUB call sees same referent');

SKIP: {
    skip('XS::APItest unavailable', 3) unless eval { require XS::APItest; 1 };
    my @result = XS::APItest::call_method('describe', XS::APItest::G_SCALAR(), $strict);
    is($result[0], '5:green', 'C call_method uses ordinary dispatch');
    {
        no warnings 'once';
        *LegacyPoint::xs_self = \&XS::APItest::return_first_arg;
    }
    my $result = $role->xs_self;
    is(refaddr($result), refaddr($role), 'XSUB may return original argument SV');
    is($result->tag, 'role', 'returned argument retains modern fields');
}

{
    package TiedLegacyValue;
    sub TIESCALAR { bless [42], shift }
    sub FETCH { $_[0][0] }
    sub STORE { $_[0][0] = $_[1] }
    package MagicalScalarParent;
    sub new { my $class = shift; tie my $value, 'TiedLegacyValue'; bless \$value, $class }
    sub value { ${$_[0]} }
}
class MagicalScalarChild :isa(MagicalScalarParent) {
    field $extra = 11;
    sub new ($class) { $class->SUPER::new->CONSTRUCT }
    method sum { $self->value + $extra }
}
my $magical = MagicalScalarChild->new;
is($magical->value, 42, 'existing scalar get magic survives storage attachment');
$$magical = 73;
is($magical->sum, 84, 'existing scalar set magic and modern fields coexist');

eval q{ class RemovedBlessedSelf :isa(LegacyPoint) { field $value :blessed_self; } };
like($@, qr/Unrecognised field attribute|Unrecognized field attribute/, ':blessed_self has been removed');

my $calls = @constructors;
my $default = LegacyRGBPoint->CONSTRUCT(red => 1, green => 2, blue => 3);
is(scalar @constructors, $calls, 'CONSTRUCT does not invoke legacy parent constructor');
is(reftype($default), 'SCALAR', 'class-name CONSTRUCT has default scalar referent');

done_testing;
