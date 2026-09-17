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

# :implements accepted on a class
{
    role Greetable {
        method greet { "hello" }
    }

    class Greeter :implements(Greetable) {
        field $name :param;
        method name { $name }
    }

    ok(1, ':implements on class compiles');
}

# :implements accepted on a role (role-composes-role)
{
    role Inner {
        method inner { "inner" }
    }

    role Outer :implements(Inner) {
        method outer { "outer" }
    }

    ok(1, ':implements on role compiles');
}

# :implements with multiple roles
{
    role R1 {
        method r1 { "r1" }
    }

    role R2 {
        method r2 { "r2" }
    }

    class Multi :implements(R1) :implements(R2) {
        field $x :param;
        method x { $x }
    }

    ok(1, 'multiple :implements on class compiles');
}

# :implements rejects non-role targets
{
    ok(!eval q{
        use strict;
        use feature 'class';
        no warnings 'experimental::class';

        class NotARole {
            field $x :param;
        }

        class Consumer :implements(NotARole) {
            field $y :param;
        }
        1;
    }, ':implements with a class (not role) fails');
    like($@, qr/:implements attribute requires a role/, 'correct error for :implements with non-role');
}

# :implements rejects non-existent packages
{
    ok(!eval q{
        use strict;
        use feature 'class';
        no warnings 'experimental::class';
        class Bad :implements(No::Such::Role::Anywhere) { }
        1;
    }, ':implements with non-existent package fails');
    ok($@, 'got an error for non-existent role');
}

# :implements rejects plain packages
package PlainPkg { sub dummy { 1 } }
{
    ok(!eval q{
        use strict;
        use feature 'class';
        no warnings 'experimental::class';
        class Consumer2 :implements(PlainPkg) { }
        1;
    }, ':implements with plain package fails');
    like($@, qr/:implements attribute requires a role/, 'correct error for :implements with plain package');
}

# :implements with comma-separated list
{
    role ListR1 {
        method lr1 { "lr1" }
    }

    role ListR2 {
        method lr2 { "lr2" }
    }

    role ListR3 {
        method lr3 { "lr3" }
    }

    class ListConsumer :implements(ListR1, ListR2, ListR3) {
        field $x :param;
    }

    my $obj = ListConsumer->new(x => 1);
    is($obj->lr1, 'lr1', ':implements list: first role method');
    is($obj->lr2, 'lr2', ':implements list: second role method');
    is($obj->lr3, 'lr3', ':implements list: third role method');
    ok($obj->DOES('ListR1'), ':implements list: DOES first role');
    ok($obj->DOES('ListR2'), ':implements list: DOES second role');
    ok($obj->DOES('ListR3'), ':implements list: DOES third role');
}

# :implements list with fields
{
    role LF1 {
        field $a :param;
        method a { $a }
    }

    role LF2 {
        field $b :param;
        method b { $b }
    }

    class LFConsumer :implements(LF1, LF2) {
        field $c :param;
        method c { $c }
    }

    my $obj = LFConsumer->new(a => 1, b => 2, c => 3);
    is($obj->a, 1, ':implements list with fields: first role field');
    is($obj->b, 2, ':implements list with fields: second role field');
    is($obj->c, 3, ':implements list with fields: class field');
}

# :implements list with whitespace variations
{
    role WS1 { method ws1 { "ws1" } }
    role WS2 { method ws2 { "ws2" } }

    class WSConsumer :implements( WS1 , WS2 ) {
        field $x :param;
    }

    my $obj = WSConsumer->new(x => 1);
    is($obj->ws1, 'ws1', ':implements list with whitespace: first role');
    is($obj->ws2, 'ws2', ':implements list with whitespace: second role');
}

done_testing;
