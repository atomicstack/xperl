#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use XPerl::REPL::Evaluator;

# t/test.pl has no is_deeply; compare canonical Dumper text instead.
use Data::Dumper ();
sub is_deeply {
    my ($got, $expected, $name) = @_;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Useqq    = 1;
    local $Data::Dumper::Indent   = 1;
    local $Data::Dumper::Terse    = 1;
    @_ = (Data::Dumper::Dumper($got), Data::Dumper::Dumper($expected), $name);
    goto &is;
}

# "1 = = 2" is used as the genuine syntax error throughout t/repl: the
# plan's "1 +* 2" parses as "1 + *2" (a glob) and compiles.

my $ev = XPerl::REPL::Evaluator->new;
my $r = $ev->evaluate('1 + 1', 1);
is($r->kind, 'ok', 'simple expression ok');
is_deeply($r->values, [2], 'value in list context');
is($r->input_number, 1, 'input number recorded');

$r = $ev->evaluate('(1, 2, 3)', 2);
is_deeply($r->values, [1, 2, 3], 'list context always');

$r = $ev->evaluate('die "boom\n"', 3);
is($r->kind, 'runtime_error');
isa_ok($r->exception, 'XPerl::Exception');
like($r->exception->render, qr/^boom$/m, 'runtime exception retained');

$r = $ev->evaluate('1 = = 2', 4);
is($r->kind, 'compile_error');
isa_ok($r->exception, 'XPerl::Exception');

$r = $ev->evaluate('die { code => 7 }', 5);
is($r->kind, 'runtime_error');
is($r->exception, undef, 'non-exception die has no exception object');
is($r->value->{code}, 7, 'compat value carries the reference');

like($ev->build_source('say 1', 9), qr/^#line 1 "xperl-repl input 9"$/m, 'line directive names the input');
like($ev->build_source('say 1', 9), qr/do \{/, 'user code wrapped in do block');

my $ev2 = XPerl::REPL::Evaluator->new;
$ev2->evaluate('my $x = 5; my @a = (1,2); my %h = (k => "v"); our $o = 1', 1);
is_deeply([sort keys %{ $ev2->env }], ['$x', '%h', '@a'], 'my vars captured, our skipped');
is_deeply($ev2->evaluate('$x + 1', 2)->values, [6], 'scalar persists');
$ev2->evaluate('$x++; push @a, 3; $h{j} = 1', 3);
is_deeply($ev2->evaluate('[$x, \@a, [sort keys %h]]', 4)->values, [[6, [1,2,3], ['j','k']]], 'mutations persist via aliasing');
is_deeply($ev2->evaluate('my $x = "re"; $x', 5)->values, ['re'], 'redeclaration allowed');
is(${ $ev2->env->{'$x'} }, 're', 'latest declaration wins');
my $rr = $ev2->evaluate('my $y = 10; die "later\n"', 6);
is($rr->kind, 'runtime_error');
is(${ $ev2->env->{'$y'} }, 10, 'captures kept when the input dies');
$ev2->evaluate('my sub lf { 1 } 1', 7);
ok(!exists $ev2->env->{'&lf'}, 'lexical subs not persisted');
$ev2->reset;
is_deeply($ev2->env, {}, 'reset clears env');
is($ev2->evaluate('$x', 8)->kind, 'compile_error', 'after reset $x is undeclared under strict');

my $ev3 = XPerl::REPL::Evaluator->new;
is($ev3->package, 'main', 'default package');
$ev3->evaluate('package Foo; sub hi { "hi" }', 1);
is($ev3->package, 'Foo', 'package statement persists');
is_deeply($ev3->evaluate('__PACKAGE__', 2)->values, ['Foo']);
is_deeply($ev3->evaluate('hi()', 3)->values, ['hi'], 'sub defined in Foo callable');
$ev3->evaluate('package Bar { 1 }', 4);
is($ev3->package, 'Foo', 'block-form package does not leak');
$ev3->set_package('main');
is_deeply($ev3->evaluate('__PACKAGE__', 5)->values, ['main']);

is($ev3->evaluate('$undeclared = 1', 6)->kind, 'compile_error', 'strict on by default');
$ev3->evaluate('no strict "vars"; $undeclared = 1', 7);
is_deeply($ev3->evaluate('$undeclared', 8)->values, [1], 'no strict persists');
{ open my $sink, '>', \my $buf; my $old = select $sink;
  is_deeply($ev3->evaluate('say "x"; 1', 9)->values, [1], 'say available from prelude');
  select $old; is($buf, "x\n", 'say wrote to the selected handle'); }
# builtin ':all' imports lexically, so it does not ride along with the hints
is_deeply($ev3->evaluate('true ? "t" : "f"', 9)->values, ['t'], 'builtins available on later inputs');
$ev3->evaluate('no feature "say"', 10);
{ local $SIG{__WARN__} = sub {}; is($ev3->evaluate('say 1', 11)->kind, 'compile_error', 'feature toggle persists'); }
my @w; { local $SIG{__WARN__} = sub { push @w, "$_[0]" }; $ev3->evaluate('my $u; my $s = "a" . $u', 12); }
is(scalar @w, 1, 'warnings on by default');
@w = (); { local $SIG{__WARN__} = sub { push @w, "$_[0]" }; $ev3->evaluate('no warnings; 1', 13); $ev3->evaluate('my $u2; my $s2 = "a" . $u2', 14); }
is(scalar @w, 0, 'no warnings persists');
$ev3->evaluate('my $bad = ; package Nope;', 15);
is($ev3->package, 'main', 'a failed compile does not change the package');
$ev3->reset;
is($ev3->package, 'main', 'reset restores package');
{ local $SIG{__WARN__} = sub {}; is($ev3->evaluate('$undeclared', 15)->kind, 'compile_error', 'reset restores strict'); }

# only top-level declarations persist
my $ev5 = XPerl::REPL::Evaluator->new;
$ev5->evaluate('my $x = 5', 1);
$ev5->evaluate('{ my $x = 10 } 1', 2);
is_deeply($ev5->evaluate('$x', 3)->values, [5], 'a my in an inner block does not replace the saved one');
$ev5->evaluate('for my $i (1 .. 3) { } 1', 4);
ok(!exists $ev5->env->{'$i'}, 'a foreach loop variable is not captured');
$ev5->evaluate('my @m = map { my $y = $_ * 2; $y } 1 .. 2', 5);
ok(!exists $ev5->env->{'$y'}, 'a my inside a map block is not captured');
is_deeply($ev5->evaluate('"@m"', 6)->values, ['2 4'], 'the top-level my next to it is');
$ev5->evaluate('my $q = "lex"', 7);
$ev5->evaluate('our $q = "pkg"', 8);
ok(!exists $ev5->env->{'$q'}, 'an our redeclaration drops the saved my');
is_deeply($ev5->evaluate('our $q; $q', 9)->values, ['pkg'], 'and the package variable is seen');
{ local $SIG{__WARN__} = sub {}; $ev5->evaluate('our $r = "pkg"; my $r = "lex"', 10); }
is_deeply($ev5->evaluate('$r', 11)->values, ['lex'], 'a my after an our in one input is captured');
$ev5->evaluate('my $x = 6; { my $x = 7 }', 12);
is_deeply($ev5->evaluate('$x', 13)->values, [6], 'a top-level redeclaration still wins');
$ev5->evaluate('if ((my $c = 3) > 1) { 1 }', 14);
ok(!exists $ev5->env->{'$c'}, 'a my in an if condition belongs to the if');
is_deeply([sort keys %{ $ev5->env }], ['$r', '$x', '@m'], 'nothing generated is captured');

# SIGINT while compiling (BEGIN, use) aborts the input, not the process
my $ev4 = XPerl::REPL::Evaluator->new;
is($ev4->evaluate('BEGIN { kill INT => $$; sleep 1 } 1', 1)->kind, 'interrupted', 'interrupt during compile');
is_deeply($ev4->evaluate('2', 2)->values, [2], 'and the next input runs');
done_testing;
