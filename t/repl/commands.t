#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use XPerl::REPL;
use XPerl::REPL::Input;

sub session (@lines) {
    open my $o, '>', \my $out;
    open my $e, '>', \my $err;
    my $repl = XPerl::REPL->new(input => XPerl::REPL::Input::List->new(lines => \@lines), out => $o, err => $e);
    my $status = $repl->run;
    close $o; close $e;
    return ($out // '', $err // '', $status, $repl);
}

my ($out, $err) = session(':help');
like($out, qr/^commands:\n/m, 'help header'); like($out, qr/^  :quit, :q\s+exit the repl/m); like($out, qr/^keys:\n/m, 'key table present');
like($out, qr/^completion listings are coloured by kind, with the theme roles\n  complete\.command complete\.scalar .*complete\.hint$/ms, 'help names the completion colour roles');
like($out, qr/^  :render \[legacy\|annotated\|json\]\s+\S/m, 'arguments shown');
($out, $err) = session(':help out');
like($out, qr/^  :out \[dumper\|json\|plain\]\s+show or set how results are printed$/m, 'help for one command');
($out, $err) = session(':help nope');
like($err, qr/^unknown command :nope, try :help/, 'help for an unknown command');
($out, $err) = session(':nope');
like($err, qr/^unknown command :nope, try :help/);
($out) = session('::main_sub()', 'sub main_sub { 9 } ::main_sub()');
like($out, qr/9\n$/, 'leading :: is perl, not a command');
my (undef, undef, $st, $repl) = session('1', ':quit', '2');
is($st, 0); is($repl->input_number, 1, ':quit stops the loop before 2');
(undef, undef, $st) = session(':q'); is($st, 0, ':q alias');
($out) = session('my $x = 1; my @a = (1,2)', ':vars');
like($out, qr/^\$x = 1$/m); like($out, qr/^\@a = \[1, 2\]$/m, 'vars one line each');
($out) = session('my %h = (k => [1])', ':vars');
like($out, qr/^%h = \{k => \[1\]\}$/m, 'nested hash on one line');
($out) = session(':out plain', 'my @a = (1)', ':vars');
like($out, qr/^\@a = \[1\]$/m, 'vars always use the dumper');
($out) = session(':package'); like($out, qr/^main$/m);
($out) = session(':package Foo', '__PACKAGE__'); like($out, qr/^"Foo"$/m);
($out, $err) = session(':package 1;die'); like($err, qr/^invalid package name "1;die"/, 'bad package name refused');
($out) = session('1', '2', ':history 1'); like($out, qr/^2> 2$/m, 'history shows input number and text');
unlike($out, qr/^1> 1$/m, 'history n limits the count');
{
    # :history shows each input's own number, not its place in the list
    open my $o, '>', \my $hout;
    my $repl = XPerl::REPL->new(input => XPerl::REPL::Input::List->new(lines => []), out => $o, err => $o);
    $repl->step('5', quiet => 1);
    $repl->step('6');
    $repl->step(':history');
    like($hout, qr/^2> 6$/m, ':history numbers by input number');
}
($out) = session('if (1) {', '3', '}', ':history');
like($out, qr/^1> if \(1\) \{\n    3\n    \}$/m, 'continuation lines indented');
($out) = session(':render'); like($out, qr/^legacy$/m);
($out, $err) = session(':render json', '1 = = 2'); like($err, qr/"schema"/, 'render json applied');
($out, $err) = session(':render bogus'); like($err, qr/unknown render mode "bogus"/);
($out) = session(':out'); like($out, qr/^dumper$/m);
($out) = session(':out json', '[1]'); like($out, qr/^\[\n/, 'out json applied');
($out, $err) = session('if (1) {', ':stack'); # forced error via EOF submit of incomplete input
like($err, qr/ERROR_SYNTAX|syntax error/, 'stack renders the last error in full');
($out, $err) = session(':stack'); like($out, qr/^no error yet$/m);
($out, $err) = session('my $x = 1', ':reset', '$x');
like($err, qr/Global symbol "\$x"/, 'reset clears lexicals');
($out, $err) = session(':edit'); like($err, qr/:edit needs a terminal/);

my $cmds = XPerl::REPL::Commands->new(repl => $repl);
is_deeply([$cmds->names], [qw(continuation edit help history out package prompt quit render reset stack vars)], 'twelve commands, sorted');
ok(!$cmds->dispatch('1 + 1'), 'perl is not a command');
ok(!$cmds->dispatch('::foo()'), ':: is not a command');
like($cmds->describe('stack'), qr/last error/, 'describe');
done_testing;

sub is_deeply ($got, $expected, $name) { is(join(' ', @$got), join(' ', @$expected), $name) }
