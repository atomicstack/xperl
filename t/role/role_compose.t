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

# Basic method composition
{
    role Greetable {
        method greet { "hello" }
    }

    class Greeter :implements(Greetable) {
        field $name :param;
        method name { $name }
    }

    my $g = Greeter->new(name => "World");
    is($g->greet, 'hello', 'composed method works');
    is($g->name,  'World', 'class own method works');
    ok(Greeter->can('greet'), 'class can() sees composed method');
}

# Multiple methods from one role
{
    role Positioned {
        method x { 10 }
        method y { 20 }
        method pos { $self->x . "," . $self->y }
    }

    class Sprite :implements(Positioned) {
        field $name :param;
        method name { $name }
    }

    my $s = Sprite->new(name => "player");
    is($s->x,    10,      'first composed method');
    is($s->y,    20,      'second composed method');
    is($s->pos,  '10,20', 'composed method calling other composed methods');
    is($s->name, 'player', 'class own method');
}

# Multiple roles composed into one class
{
    role CanFly {
        method fly { "flying" }
    }

    role CanSwim {
        method swim { "swimming" }
    }

    class Duck :implements(CanFly) :implements(CanSwim) {
        field $name :param;
        method name { $name }
    }

    my $d = Duck->new(name => "Donald");
    is($d->fly,  'flying',   'method from first role');
    is($d->swim, 'swimming', 'method from second role');
    is($d->name, 'Donald',   'class own method');
}

# Method conflict detection
{
    ok(!eval q{
        use strict;
        use feature 'class';
        no warnings 'experimental::class';

        role Conflict1 { method clash { "c1" } }
        role Conflict2 { method clash { "c2" } }

        class Conflicted :implements(Conflict1) :implements(Conflict2) {
            field $x :param;
        }
        1;
    }, 'method conflict croaks');
    like($@, qr/Method 'clash' conflicts between/, 'conflict error message');
}

# Diamond deduplication - same role via two paths
{
    role SharedRole {
        method shared { "shared" }
    }

    role LeftPath :implements(SharedRole) {
        method left { "left" }
    }

    role RightPath :implements(SharedRole) {
        method right { "right" }
    }

    class DiamondClass :implements(LeftPath) :implements(RightPath) {
        field $x :param;
    }

    my $d = DiamondClass->new(x => 1);
    is($d->shared, 'shared', 'diamond: shared method works');
    is($d->left,   'left',   'diamond: left path method works');
    is($d->right,  'right',  'diamond: right path method works');
}

# Non-conflicting methods with same name from same origin (diamond)
# should not conflict
{
    role Origin {
        method m { "origin" }
    }

    role Via1 :implements(Origin) {
        method v1 { "v1" }
    }

    role Via2 :implements(Origin) {
        method v2 { "v2" }
    }

    class DiamondOK :implements(Via1) :implements(Via2) {
        field $x :param;
    }

    my $d = DiamondOK->new(x => 1);
    is($d->m,  'origin', 'diamond: method from shared origin is not a conflict');
    is($d->v1, 'v1',     'diamond: unique method from first path');
    is($d->v2, 'v2',     'diamond: unique method from second path');
}

# Transitive method composition (role composes role)
{
    role Base1 {
        method base { "base" }
    }

    role Middle :implements(Base1) {
        method middle { "middle" }
    }

    class Consumer :implements(Middle) {
        field $x :param;
    }

    my $c = Consumer->new(x => 1);
    is($c->base,   'base',   'transitively composed method');
    is($c->middle, 'middle', 'directly composed method');
}

# ADJUST block composition
{
    my @order;

    role WithAdjust1 {
        ADJUST {
            push @order, "adjust1";
        }
    }

    role WithAdjust2 {
        ADJUST {
            push @order, "adjust2";
        }
    }

    class AdjustConsumer :implements(WithAdjust1) :implements(WithAdjust2) {
        ADJUST {
            push @order, "class_adjust";
        }
    }

    @order = ();
    my $obj = AdjustConsumer->new();
    is(join(" ", @order), "class_adjust adjust1 adjust2",
        'ADJUST blocks: class first, then roles in composition order');
}

# ADJUST block with field mutation
{
    role Initializable {
        field $initialized :reader = 0;
        ADJUST { $initialized = 1 }
    }

    class Widget :implements(Initializable) {
        field $label :param;
        method label { $label }
    }

    my $w = Widget->new(label => "btn");
    is($w->initialized, 1,     'role ADJUST mutated field');
    is($w->label,       'btn', 'class field unaffected');
}

# A shared ADJUST block runs once when composed through a diamond.
{
    my $adjusted = 0;

    role AdjustBase {
        ADJUST { ++$adjusted }
    }
    role AdjustLeft :implements(AdjustBase) { }
    role AdjustRight :implements(AdjustBase) { }
    class AdjustDiamond :implements(AdjustLeft) :implements(AdjustRight) { }

    AdjustDiamond->new;
    is($adjusted, 1, 'diamond: shared ADJUST block runs once');
}

# Role composing into role, then into class
{
    role Loggable {
        method log { "logged" }
    }

    role Auditable :implements(Loggable) {
        method audit { "audited: " . $self->log }
    }

    class Service :implements(Auditable) {
        field $name :param;
        method name { $name }
    }

    my $s = Service->new(name => "svc");
    is($s->log,   'logged',          'transitive role method');
    is($s->audit, 'audited: logged', 'intermediate role method calling transitive');
    is($s->name,  'svc',             'class own method');
}

done_testing;
