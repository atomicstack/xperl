#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
}

use v5.42;
use feature 'class';
no warnings 'experimental::class';

role BaseWithReaderAndParam {
    field $base :reader :param = -1;
}

class C::BaseWithReaderAndParam :implements(BaseWithReaderAndParam) {}

role ExtendedBaseWithReaderAndParam :implements(BaseWithReaderAndParam) {}

class C::E::BaseWithReaderAndParam :implements(ExtendedBaseWithReaderAndParam) {}

ok(BaseWithReaderAndParam->can('base'), '... does BaseWithReaderAndParam::base exist');
ok(C::BaseWithReaderAndParam->can('base'), '... does C::BaseWithReaderAndParam::base exist');
ok(ExtendedBaseWithReaderAndParam->can('base'), '... does ExtendedBaseWithReaderAndParam::base exist');
ok(C::E::BaseWithReaderAndParam->can('base'), '... does C::E::BaseWithReaderAndParam::base exist');

my $c = C::BaseWithReaderAndParam->new( base => 20 );
isa_ok($c, 'C::BaseWithReaderAndParam');
ok($c->DOES('BaseWithReaderAndParam'), '... does BaseWithReaderAndParam');
is($c->base, 20, '... got the expected values');

my $ce = C::E::BaseWithReaderAndParam->new( base => 20 );
isa_ok($ce, 'C::E::BaseWithReaderAndParam');
ok($ce->DOES('ExtendedBaseWithReaderAndParam'), '... does ExtendedBaseWithReaderAndParam');
ok($ce->DOES('BaseWithReaderAndParam'), '... does BaseWithReaderAndParam');
is($ce->base, 20, '... got the expected values');

{
    my $initialized = 0;
    my $adjusted = 0;

    role DiamondFieldBase {
        field $shared :reader = ++$initialized;
        ADJUST { ++$adjusted }
    }

    role DiamondFieldLeft :implements(DiamondFieldBase) {
        field $left :reader :param;
    }

    role DiamondFieldRight :implements(DiamondFieldBase) {
        field $right :reader :param;
    }

    class DiamondFieldParent {
        field $parent :reader :param;
    }

    class DiamondFieldConsumer :isa(DiamondFieldParent)
            :implements(DiamondFieldLeft)
            :implements(DiamondFieldRight) {
        field $own :reader :param;
    }

    my $diamond = DiamondFieldConsumer->new(
        parent => 'parent',
        left   => 'left',
        right  => 'right',
        own    => 'own',
    );

    is($initialized, 1, 'diamond initializes a shared field once');
    is($adjusted, 1, 'diamond adjusts a shared field once');
    is($diamond->parent, 'parent', 'superclass field has the right offset');
    is($diamond->shared, 1, 'shared role field has the right offset');
    is($diamond->left, 'left', 'left role field has the right offset');
    is($diamond->right, 'right', 'right role field has the right offset');
    is($diamond->own, 'own', 'class field has the right offset');
}

done_testing;
