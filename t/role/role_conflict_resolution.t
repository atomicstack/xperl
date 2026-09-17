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

# Consumer's explicit method resolves a conflict between two roles
{
    role RA1 { method render { "RA" } }
    role RB1 { method render { "RB" } }

    class Widget :implements(RA1) :implements(RB1) {
        method render { "Widget" }
    }

    my $w = Widget->new;
    is($w->render, "Widget", "consumer explicit method resolves conflict");
}

# Consumer resolves one conflict but not another - only unresolved is an error
{
    role RA2 { method m1 { 1 } method m2 { 2 } }
    role RB2 { method m1 { 3 } method m2 { 4 } }

    eval q{
        class C2 :implements(RA2) :implements(RB2) {
            method m1 { "resolved" }
        }
    };
    like($@, qr/Method 'm2' conflicts/, "unresolved conflict is reported");
    unlike($@, qr/m1/, "resolved conflict is not reported");
}

# Consumer resolves all conflicts - no error
{
    role RA3 { method x { 1 } method y { 2 } }
    role RB3 { method x { 3 } method y { 4 } }

    class C3 :implements(RA3) :implements(RB3) {
        method x { "X" }
        method y { "Y" }
    }

    my $c = C3->new;
    is($c->x, "X", "consumer's x resolves conflict");
    is($c->y, "Y", "consumer's y resolves conflict");
}

# Role-into-role conflict resolution
{
    role RA4 { method m { "A" } }
    role RB4 { method m { "B" } }

    role RC4 :implements(RA4) :implements(RB4) {
        method m { "C" }
    }

    class D4 :implements(RC4) { }
    is(D4->new->m, "C", "role resolves sub-role conflict");
}

# Consumer explicit method takes precedence over single role method
{
    role R5 { method foo { "role" } }

    class C5 :implements(R5) {
        method foo { "class" }
    }

    is(C5->new->foo, "class", "consumer method takes precedence over role");
}

# Diamond composition - no conflict
{
    role Base6 { method m { "base" } }
    role Left6 :implements(Base6) { }
    role Right6 :implements(Base6) { }

    class C6 :implements(Left6) :implements(Right6) { }
    is(C6->new->m, "base", "diamond composition - no conflict");
}

# Conflicts remain conflicts when they reach the consumer through
# intermediate roles.
{
    role Origin7a { method run { "a" } }
    role Via7a :implements(Origin7a) { }
    role Origin7b { method run { "b" } }
    role Via7b :implements(Origin7b) { }

    eval q{ class C7x :implements(Via7a) :implements(Via7b) { } };
    like($@, qr/Method 'run' conflicts between/,
        "transitive method conflict is reported");
}

# Batch error reporting - multiple errors reported at once
{
    role RA7 { method a { 1 } method b { 2 } method c { 3 } }
    role RB7 { method a { 4 } method b { 5 } method c { 6 } }

    eval q{
        class C7 :implements(RA7) :implements(RB7) {
            method a { "resolved" }
        }
    };
    like($@, qr/Role composition errors/, "batch error header present");
    like($@, qr/'b' conflicts/, "conflict for b reported");
    like($@, qr/'c' conflicts/, "conflict for c reported");
    unlike($@, qr/'a' conflicts/, "resolved conflict a not reported");
}

# Required method satisfied by consumer
{
    role R8 { method to_string; }

    class C8 :implements(R8) {
        method to_string { "C8" }
    }
    is(C8->new->to_string, "C8", "consumer satisfies required method");
}

# Required method unsatisfied - error
{
    role R9 { method required_m; }

    eval q{
        class C9 :implements(R9) { }
    };
    like($@, qr/required.*not provided/i, "unsatisfied required method is an error");
}

# Inherited method (from superclass) satisfies a Required slot
{
    role NeedsRender10 {
        method render;
    }

    class BaseRenderer10 {
        method render { "from base" }
    }

    class FancyRenderer10 :isa(BaseRenderer10) :implements(NeedsRender10) { }

    is(FancyRenderer10->new->render, "from base",
        "inherited method satisfies Required slot");
}

# Inherited method does NOT resolve a Conflicted slot
{
    role Talker11a { method speak { "A" } }
    role Talker11b { method speak { "B" } }

    class BaseSpeaker11 {
        method speak { "base" }
    }

    eval q{
        class ChildSpeaker11 :isa(BaseSpeaker11) :implements(Talker11a) :implements(Talker11b) { }
    };
    like($@, qr/conflict/i,
        "inherited method does NOT resolve Conflicted slot");
}

# Consumer's generated accessor does NOT resolve a method conflict
{
    role Source12a { method value { "A" } }
    role Source12b { method value { "B" } }

    eval q{
        class Consumer12 :implements(Source12a) :implements(Source12b) {
            field $value :param :reader;  # generated accessor, not an explicit resolution
        }
    };
    like($@, qr/conflict/i,
        "consumer generated accessor does NOT resolve method conflict");
}

done_testing;
