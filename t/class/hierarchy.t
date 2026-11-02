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
our @order;

class UnionBase {
    field $base_value = do { push @main::order, 'init-base'; 1 };
    ADJUST { push @main::order, 'adjust-base' }
    method base { $base_value }
    method base_identity { $self }
}
class UnionLeft :isa(UnionBase) {
    field $left_value = do { push @main::order, 'init-left'; 2 };
    ADJUST { push @main::order, 'adjust-left' }
    method left { $left_value }
    method left_identity { $self }
    method via_super { $self->SUPER::base }
}
class UnionRight :isa(UnionBase) {
    field $right_value = do { push @main::order, 'init-right'; 3 };
    ADJUST { push @main::order, 'adjust-right' }
    method right { $right_value }
    method increment_right { ++$right_value }
    method right_identity { $self }
}
{
    package UnionLegacyDiamond;
    our @ISA = ('UnionLeft', 'UnionRight');
}
class UnionTop :isa(UnionLegacyDiamond) {
    field $top_value = do { push @main::order, 'init-top'; 4 };
    ADJUST {
        push @main::order, 'adjust-top';
        die 'ancestor fields unavailable' unless $self->base == 1 && $self->right == 3;
    }
    method top { $top_value }
    method top_identity { $self }
}
@order = ();
my $object = UnionTop->new;
is(join(',', @order),
    'init-base,init-left,init-right,init-top,adjust-base,adjust-left,adjust-right,adjust-top',
    'diamond initializes each declaring class once before running adjustments');
is(join(',', $object->base, $object->left, $object->right, $object->top), '1,2,3,4',
    'each declaring class contributes its fields across the hierarchy');
is($object->via_super, 1, 'SUPER uses declaring ancestor part');
for my $name (qw(base_identity left_identity right_identity top_identity)) {
    is(refaddr($object->$name), refaddr($object), "$name sees the same public reference");
}
my $right = UnionRight->can('right');
is($right->($object), 3, 'direct method CV resolves its declaring class part');
is($object->increment_right, 4, 'second branch fields are mutable');
is($object->left, 2, 'mutating one branch does not alter another');

class UnionUnrelated { field $same = 99; method unrelated { $same } }
my $unrelated = UnionUnrelated->can('unrelated');
ok(!eval { $unrelated->($object); 1 }, 'direct CV cannot access an absent declaring class');
like($@, qr/Cannot invoke a method/, 'absent class part is diagnosed');

class UnionAcrossLegacy :isa(UnionLegacyDiamond) {
    field $value :param :reader;
}
my $mixed = UnionAcrossLegacy->new(value => 'mixed');
is(join(',', $mixed->base, $mixed->left, $mixed->right, $mixed->value), '1,2,3,mixed',
    'modern child of legacy multiple parents owns complete ancestor union');

role UnionPaddingRole { field $padding = 1000; method padding { $padding } }
role UnionSharedRole {
    field $shared = 0;
    method shared { $shared }
    method increment_shared { ++$shared }
    my method private_increment { ++$shared }
    method through_private { $self->&private_increment }
    method closure { sub { ++$shared } }
    method anonymous { method { ++$shared } }
    method identity { $self }
}
role UnionOtherRole {
    field $other_shared = 0;
    method shared { $other_shared }
    method increment_shared { ++$other_shared }
    my method private_increment { ++$other_shared }
    method through_private { $self->&private_increment }
    method closure { sub { ++$other_shared } }
    method anonymous { method { ++$other_shared } }
    method identity { $self }
}
class UnionRolePrefix { field $prefix = 10; method prefix { $prefix } }
class UnionRoleLeft :isa(UnionRolePrefix) :implements(UnionSharedRole) {
    field $left = 11;
    method left { $left }
}
class UnionRoleRight :implements(UnionPaddingRole, UnionOtherRole) {
    field $right = 12;
    method right { $right }
}
class UnionRoleAbsent :isa(UnionRolePrefix) :implements(UnionSharedRole) { }
{
    package UnionRoleLegacy;
    our @ISA = ('UnionRoleLeft', 'UnionRoleRight');
}
my $roles = UnionRoleLegacy->new;
my $left_shared = UnionRoleLeft->can('shared');
my $right_shared = UnionRoleRight->can('shared');
is($left_shared->($roles), 0, 'first role contribution owns its field');
is($right_shared->($roles), 0, 'second role contribution owns its distinct field');
is(UnionRoleLeft->can('increment_shared')->($roles), 1, 'first composed CV maps its consumer');
is($right_shared->($roles), 0, 'first consumer mutation preserves second role field');
is(UnionRoleRight->can('through_private')->($roles), 1, 'private lexical method inherits second consumer context');
is(UnionRoleLeft->can('through_private')->($roles), 2, 'private lexical method resolves first consumer context');
my $closure = UnionRoleRight->can('closure')->($roles);
is($closure->(), 2, 'ordinary escaped closure retains second consumer field alias');
my $anonymous = UnionRoleLeft->can('anonymous')->($roles);
is($anonymous->($roles), 3, 'escaped anonymous method retains composing class identity');
is($left_shared->($roles), 3, 'anonymous method changes first consumer role field');
is($right_shared->($roles), 2, 'anonymous method leaves other role consumer unchanged');
my $absent = UnionRoleAbsent->can('shared');
ok(!eval { $absent->($roles); 1 }, 'composed CV from absent consumer is rejected despite shared role');
my $absent_identity = UnionRoleAbsent->can('identity');
ok(!eval { $absent_identity->($roles); 1 }, 'fieldless composed CV preserves consumer identity');
is(UnionRoleRight->can('padding')->($roles), 1000, 'preceding role field offsets are preserved');
is($roles->prefix, 10, 'preceding superclass fields are preserved');

class UnionParameterA { field $one :param(duplicate); method one { $one } }
class UnionParameterB { field $two :param(duplicate); method two { $two } }
our $invalid_destroyed = 0;
{
    package UnionParameterLegacy;
    our @ISA = ('UnionParameterA', 'UnionParameterB');
    sub DESTROY { ++$main::invalid_destroyed }
}
eval { UnionParameterLegacy->new(duplicate => 1) };
like($@, qr/already in use/, 'duplicate constructor parameter across class parts is rejected before initialization');
is($invalid_destroyed, 0, 'invalid layout does not bless a partial new object or call DESTROY');

class UnionConflictA { field $collision = 1 }
class UnionConflictB { field $collision = 2 }
{
    package UnionConflictLegacy;
    our @ISA = ('UnionConflictA', 'UnionConflictB');
    package UnionDuplicateRoleLegacy;
    our @ISA = ('UnionRoleLeft', 'UnionRoleAbsent');
}
eval { UnionConflictLegacy->new };
like($@, qr/Field.*collision|field.*collision/, 'distinct field declarations in mixed union must have unique names');
eval { UnionDuplicateRoleLegacy->new };
like($@, qr/Field.*shared|field.*shared/, 'independent class consumers cannot introduce duplicate role fields');
eval q{ class UnionShadowRejected :isa(UnionConflictA) { field $collision = 3 } };
like($@, qr/Field.*collision|field.*collision/, 'direct superclass field shadowing is rejected');

SKIP: {
    skip('threads unavailable', 2) unless $Config{useithreads};
    require threads;
    my $values = threads->create(sub {
        return [$object->base, $object->left, $object->right, $object->top,
            UnionRoleLeft->can('shared')->($roles), UnionRoleRight->can('shared')->($roles)];
    })->join;
    is(join(',', @$values), '1,2,4,4,3,2', 'thread cloning preserves class and role consumer layout identities');
    is($object->right, 4, 'cloned storage leaves original object intact');
}

done_testing();
