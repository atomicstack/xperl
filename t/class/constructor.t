#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use feature 'class';
no warnings 'experimental::class';
use Scalar::Util qw(refaddr);

our @construction;
class DefaultConstructor {
    field $x :param :reader;
    field $y :param :reader = 20;
    ADJUST { push @main::construction, "adjust:$x,$y" }
}
is(refaddr(DefaultConstructor->can('new')), refaddr(DefaultConstructor->can('CONSTRUCT')),
    'default new and CONSTRUCT are the same CV');
my $default = DefaultConstructor->new(x => 10);
is($default->y, 20, 'default new retains field defaults');
is(DefaultConstructor->CONSTRUCT(x => 30)->x, 30, 'CONSTRUCT accepts named parameters directly');
is(join(';', @construction), 'adjust:10,20;adjust:30,20', 'both paths run ADJUST');
eval { DefaultConstructor->CONSTRUCT() };
like($@, qr/Required parameter 'x' is missing/, 'CONSTRUCT enforces required parameters');
eval { DefaultConstructor->CONSTRUCT(x => 1, surprise => 2) };
like($@, qr/Unrecognized parameters/, 'CONSTRUCT rejects unused parameters');

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, "$_[0]" };
    eval q{
        class SignatureConstructor {
            field $x :param :reader;
            field $y :param :reader;
            ADJUST { push @main::construction, 'signature-adjust' }
            sub new ($class, $x, $y = 42) {
                push @main::construction, 'signature-new';
                my $self = $class->CONSTRUCT(x => $x, y => $y);
                push @main::construction, 'signature-after';
                return $self;
            }
        }
        1;
    } or die $@;
}
is(join('', @warnings), '', 'declaring sub new does not redefine generated code');
@construction = ();
my $signed = SignatureConstructor->new(7);
is($signed->x, 7, 'custom constructor binds positional arguments');
is($signed->y, 42, 'custom constructor applies signature defaults');
is(join(';', @construction), 'signature-new;signature-adjust;signature-after',
    'custom constructor controls work around generated initialization');
isnt(refaddr(SignatureConstructor->can('new')), refaddr(SignatureConstructor->can('CONSTRUCT')),
    'custom new and generated CONSTRUCT are distinct CVs');
eval { SignatureConstructor->new() };
like($@, qr/Too few arguments/, 'custom constructor keeps signature arity checks');
is(SignatureConstructor->CONSTRUCT(x => 3, y => 4)->y, 4, 'CONSTRUCT bypasses the custom signature');

class FactoryConstructor {
    field $required :param;
    ADJUST { die 'must not initialize' }
    sub new ($class, $value) { return [$class, $value] }
}
my $factory = FactoryConstructor->new('result');
is(ref($factory), 'ARRAY', 'custom new need not allocate a native instance');
is($factory->[1], 'result', 'custom new controls its return value');

class ParentConstructor {
    field $x :param :reader;
    sub new ($class, $x, @rest) { return $class->CONSTRUCT(x => $x, @rest) }
}
class ChildConstructor :isa(ParentConstructor) {
    field $y :param :reader;
    sub new ($class, $x, $y) { return $class->SUPER::new($x, y => $y) }
}
my $child = ChildConstructor->new(5, 6);
is(ref($child), 'ChildConstructor', 'delegating parent sub resolves the requested class CONSTRUCT');
is($child->x, 5, 'delegated construction initializes inherited fields');
is($child->y, 6, 'delegated construction initializes child fields');
class PreparingParent {
    field $x :param :reader;
    sub new ($class, $x) {
        push @main::construction, 'parent-prepare';
        return [x => $x * 2];
    }
}
class PreparingChild :isa(PreparingParent) {
    field $y :param :reader;
    ADJUST { push @main::construction, 'child-adjust' }
    sub new ($class, $x, $y, $increment) {
        my $params = $class->SUPER::new($x);
        my $self = $class->CONSTRUCT(@$params, y => $y);
        $self->initialize($increment);
        return $self;
    }
    method initialize ($increment) {
        push @main::construction, 'child-initialize';
        $y += $increment;
    }
}
@construction = ();
my $prepared = PreparingChild->new(2, 3, 4);
is($prepared->x, 4, 'parent sub can prepare arguments before the child calls CONSTRUCT');
is($prepared->y, 7, 'constructor passes transient arguments directly to initialization');
is(join(';', @construction), 'parent-prepare;child-adjust;child-initialize',
    'ordinary sub controls parent processing and post-allocation initialization');

class DefaultChildConstructor :isa(ParentConstructor) {
    field $y :param :reader;
    BEGIN { __PACKAGE__->can('new') }
}
is(refaddr(DefaultChildConstructor->can('new')), refaddr(DefaultChildConstructor->can('CONSTRUCT')),
    'a class without local new gets its own alias even after an inherited lookup');
is(DefaultChildConstructor->new(x => 8, y => 9)->y, 9, 'child default alias accepts key/value pairs');

class AliasConstructor :isa(ParentConstructor) {
    BEGIN { *new = \&ParentConstructor::new }
}
is(AliasConstructor->new(11)->x, 11, 'an explicitly aliased constructor is preserved');

{
    class UnitConstructor;
    field $value :param :reader;
    sub new ($class, $value) { return $class->CONSTRUCT(value => $value) }
}
is(UnitConstructor->new(12)->value, 12, 'unit class syntax permits a signed constructor');

{
    use utf8;
    class Cönstructor {
        field $value :param :reader;
    }
    is(Cönstructor->new(value => 13)->value, 13, 'Unicode class name gets a working alias');
    is(refaddr(Cönstructor->can('new')), refaddr(Cönstructor->can('CONSTRUCT')),
        'Unicode class constructor alias shares its CV');
}

class AliasingConstructor {
    field $value :param :reader;
    sub new {
        my $class = shift;
        $_[0]++;
        return $class->CONSTRUCT(value => $_[0]);
    }
}
my $argument = 14;
is(AliasingConstructor->new($argument)->value, 15, 'unsigned constructor can forward an argument');
is($argument, 15, 'unsigned constructor retains normal argument aliases');

{
    package LegacyConstructorParent;
    sub new { my ($class, %args) = @_; return bless \%args, $class }
    sub legacy_value { $_[0]{value} }
}
class LegacySignatureConstructor :isa(LegacyConstructorParent) {
    field $legacy :blessed_self :param;
    field $extra :param :reader;
    sub new ($class, $value, $extra) {
        my $parent = $class->SUPER::new(value => $value);
        return $class->CONSTRUCT(legacy => $parent, extra => $extra);
    }
}
my $legacy = LegacySignatureConstructor->new(16, 17);
is($legacy->legacy_value, 16, 'custom signature feeds the legacy parent construction path');
is($legacy->extra, 17, 'custom signature feeds native parameters in a legacy subclass');

is(ref($default->CONSTRUCT(x => 18)), 'DefaultConstructor',
    'generated CONSTRUCT can be invoked on an existing instance');
is($default->x, 10, 'instance invocation does not change the original object');

my $broken = eval q{ class BrokenConstructor { field $x :unknown_attribute; } 1; };
ok(!$broken, 'invalid class definition fails');
ok(!BrokenConstructor->can('CONSTRUCT'), 'failed definition removes the generated CONSTRUCT');
ok(!BrokenConstructor->can('new'), 'failed definition leaves no default alias');

done_testing;
