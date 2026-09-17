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

# --- Setup: roles and classes for testing ---

role Drawable {
    method draw { "draw" }
}

role Printable {
    method print_out { "print" }
}

role Composing :implements(Drawable) {
    method extra { "extra" }
}

class Widget :implements(Drawable) {
    field $name :param :reader;
}

class FancyWidget :isa(Widget) :implements(Printable) {
}

class Unrelated {
    field $x :param;
}

# --- Nominal ->implements method tests ---

# Basic: class composing role
{
    my $w = Widget->new(name => "test");
    ok($w->implements('Drawable'), 'Widget instance ->implements(Drawable)');
    ok(!$w->implements('Printable'), 'Widget instance does not ->implements(Printable)');
}

# Inheritance: subclass inherits role composition
{
    my $fw = FancyWidget->new(name => "fancy");
    ok($fw->implements('Drawable'), 'FancyWidget inherits Drawable via Widget');
    ok($fw->implements('Printable'), 'FancyWidget directly does Printable');
}

# Transitive: role composes role
{
    class TransWidget :implements(Composing) {
        field $id :param;
    }
    my $tw = TransWidget->new(id => 1);
    ok($tw->implements('Composing'), 'TransWidget directly does Composing');
    ok($tw->implements('Drawable'), 'TransWidget transitively does Drawable (via Composing)');
}

# Class name (not instance)
{
    ok(Widget->implements('Drawable'), 'Widget class ->implements(Drawable)');
    ok(!Widget->implements('Printable'), 'Widget class does not ->implements(Printable)');
}

# Unrelated class does not compose role
{
    my $u = Unrelated->new(x => 1);
    ok(!$u->implements('Drawable'), 'Unrelated class does not do Drawable');
}

# Non-existent role returns false
{
    my $w = Widget->new(name => "test");
    ok(!$w->implements('No::Such::Role'), '->implements with non-existent role returns false');
}

# ->implements is nominal; DOES delegates to it for class objects
{
    my $w = Widget->new(name => "test");
    ok($w->implements('Drawable'), '->implements returns true for composed role');
    ok($w->DOES('Drawable'), '->DOES returns true for composed role');
}

# --- Infix `implements` operator tests ---

# Basic infix
{
    my $w = Widget->new(name => "test");
    ok($w implements Drawable, 'infix: $w implements Drawable');
    ok(!($w implements Printable), 'infix: $w does not implement Printable');
}

# Infix with inheritance
{
    my $fw = FancyWidget->new(name => "fancy");
    ok($fw implements Drawable, 'infix: FancyWidget implements Drawable (inherited)');
    ok($fw implements Printable, 'infix: FancyWidget implements Printable (direct)');
}

# Infix transitive
{
    class TransWidget2 :implements(Composing) {
        field $id :param;
    }
    my $tw = TransWidget2->new(id => 1);
    ok($tw implements Composing, 'infix: TransWidget2 implements Composing');
    ok($tw implements Drawable, 'infix: TransWidget2 implements Drawable (transitive)');
}

# Infix with class name (as string on LHS)
{
    ok('Widget' implements Drawable, 'infix: Widget class implements Drawable');
    ok(!('Widget' implements Printable), 'infix: Widget class does not implement Printable');
}

# Infix in conditional
{
    my $w = Widget->new(name => "test");
    my $result = $w implements Drawable ? "yes" : "no";
    is($result, "yes", 'infix implements works in ternary');
}

# --- DOES delegation tests ---

# Basic: class composes role -- DOES delegates to implements
{
    my $w = Widget->new(name => "test");
    ok($w->DOES('Drawable'), 'DOES: Widget fulfills Drawable contract');
}

# A consuming class may replace a role-provided default method
role Renderable {
    method render { "base render" }
}

class Canvas :implements(Renderable) {
    field $id :param;
}

class FancyCanvas :isa(Canvas) {
    method render { "fancy render" }
}

{
    my $c = Canvas->new(id => 1);
    ok($c->DOES('Renderable'), 'DOES: Canvas fulfills Renderable (no override)');
    ok($c->implements('Renderable'), 'implements: Canvas nominally implements Renderable');

    my $fc = FancyCanvas->new(id => 2);
    ok($fc->DOES('Renderable'), 'DOES: FancyCanvas implements Renderable despite overriding render');
    ok($fc->implements('Renderable'), 'implements: FancyCanvas still nominally implements Renderable');
}

# Class itself overrides a role-provided default method
role Greetable2 {
    method greet { "hello" }
}

class Greeter2 :implements(Greetable2) {
    field $name :param;
    method greet { "hi from $name" }
}

{
    my $g = Greeter2->new(name => "world");
    ok($g->DOES('Greetable2'), 'DOES: Greeter2 implements Greetable2 with its own greet');
    ok($g->implements('Greetable2'), 'implements: Greeter2 still nominally implements Greetable2');
}

# Required method satisfied -- DOES true
role Describable {
    method describe;
}

class Item :implements(Describable) {
    field $label :param;
    method describe { "item: $label" }
}

{
    my $item = Item->new(label => "test");
    ok($item->DOES('Describable'), 'DOES: Item satisfies Describable required method');
    ok($item->implements('Describable'), 'implements: Item nominally implements Describable');
}

# Subclasses retain nominal role membership when overriding a role method.
role Contract {
    method fulfill { "fulfilled" }
    method verify;
}

class Worker :implements(Contract) {
    field $id :param;
    method verify { 1 }
}

class OverrideWorker :isa(Worker) {
    method fulfill { "overridden" }
}

{
    my $w = Worker->new(id => 1);
    ok($w->implements('Contract'), 'implements/DOES agree: Worker implements Contract');
    ok($w->DOES('Contract'), 'implements/DOES agree: Worker DOES Contract');

    my $ow = OverrideWorker->new(id => 2);
    ok($ow->implements('Contract'), 'OverrideWorker implements Contract nominally');
    ok($ow->DOES('Contract'), 'OverrideWorker DOES Contract via implements');
}

# A non-class package can opt into the DOES delegation protocol explicitly
{
    package ExternalImplementation;
    sub new { bless {}, shift }
    sub implements { $_[1] eq 'ExternalRole' }

    package main;
    my $external = ExternalImplementation->new;
    ok($external->DOES('ExternalRole'),
       'DOES delegates to an explicitly supplied implements method');
    ok($external->DOES('ExternalImplementation'),
       'ordinary DOES fallback remains available when implements is false');
}

done_testing;
