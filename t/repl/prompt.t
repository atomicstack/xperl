#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use Cwd ();
use File::Basename ();
use XPerl::REPL;
use XPerl::REPL::Input;

# a session in package Foo whose next input is number 5; its output and
# errors are in the returned scalars
sub session (%args) {
    open my $o, '>', \my $out;
    open my $e, '>', \my $err;
    my $repl = XPerl::REPL->new(
        input => XPerl::REPL::Input::List->new(lines => []), out => $o, err => $e, %args,
    );
    $repl->step("$_\n") for 1, 2, 3, 'package Foo; 4';
    clear($o, \$out);
    return ($repl, \$out, \$err, $o, $e);
}

# empty an in-memory handle and its scalar
sub clear ($fh, $buf) { $$buf = ''; seek $fh, 0, 0 }

my ($repl, $out, $err, $ofh, $efh) = session();
my $r = $repl->renderer;
is($repl->prompt, '%n> ', 'default prompt spec');
is($repl->continuation, '... ', 'default continuation spec');
is($r->prompt(3), '3> ', 'default prompt');
is($r->continuation_prompt, '... ', 'default continuation prompt');

$repl->prompt('%p:%n> ');
is($repl->prompt, '%p:%n> ', 'reader returns the spec');
is($r->prompt(5), 'Foo:5> ', '%p and %n');
$repl->prompt('100%% %q> ');
is($r->prompt(5), '100% %q> ', '%% is a percent sign, an unknown escape is literal');
$repl->prompt('%t');
like($r->prompt(5), qr/\A\d\d:\d\d:\d\d\z/, '%t is the local time');
$repl->prompt('%d');
is($r->prompt(5), File::Basename::basename(Cwd::getcwd()), '%d is the directory basename');
$repl->prompt('%{nope}x%{/}');
is($r->prompt(5), '%{nope}x%{/}', 'an unknown colour role is literal, and so is its close');
$repl->prompt('%{/}> ');
is($r->prompt(5), '%{/}> ', 'a close with no role open is literal');

$repl->continuation('~~ ');
is($r->continuation_prompt, '~~ ', 'continuation spec');
$repl->continuation('%n| ');
is($r->continuation_prompt(7), '7| ', 'continuation %n is the input being continued');

$repl->prompt(sub ($s) { '[' . ($s->input_number + 1) . ']' });
is($r->prompt(5), '[5]', 'coderef called with the session');
ok(ref $repl->prompt eq 'CODE', 'as the code ref');
eval { $repl->prompt([]) };
like($@, qr/^prompt must be a format string or a code reference/, 'other refs are refused');

$repl->prompt(sub { die "boom\n" });
is($r->prompt(5), '5> ', 'a dying coderef falls back to the default prompt');
like($$err, qr/^prompt callback failed: boom$/m, 'and reports the error');
clear($efh, $err);
is($r->prompt(5), '5> ', 'still the default on the next draw');
is($$err, '', 'reported once, not on every draw');
$repl->prompt(sub { die "again\n" });
$r->prompt(5);
like($$err, qr/^prompt callback failed: again$/m, 'a new coderef is reported again');

# colours
my ($c) = session(color_level => 16);
my $cr = $c->renderer;
is($cr->prompt(3), "\e[1m3> \e[0m", 'default prompt bold at 16 colours');
is($cr->continuation_prompt, "\e[1m... \e[0m", 'continuation bold too');
$c->prompt('%p> ');
is($cr->prompt(5), "\e[1mFoo> \e[0m", 'a format without colour escapes gets the prompt colour');
$c->prompt('%{error}%n%{/}> ');
is($cr->prompt(5), "\e[31m5\e[0m> ", 'colour escapes, no outer wrapping');
$repl->prompt('%{error}%n%{/}> ');
is($r->prompt(5), '5> ', 'colour escapes at level 0');
$c->prompt('a%{/}> ');
is($cr->prompt(5), "a%{/}> ", 'a stray close emits no reset and no outer colour');
$c->prompt('%{result}a%{hint}b');
is($cr->prompt(5), "\e[32ma\e[0m\e[36mb\e[0m", 'a role runs to the next role or the end');
$c->prompt(sub ($s) { '[' . ($s->input_number + 1) . ']' });
is($cr->prompt(5), '[5]', 'coderef output is used verbatim');
$c->prompt(sub ($s) { $s->renderer->colorize(error => 'x') });
is($cr->prompt(5), "\e[31mx\e[0m", 'a coderef can colour with the theme');

# commands
($repl, $out, $err, $ofh, $efh) = session();
$repl->step(":prompt\n");
is($$out, "%n> \n", ':prompt shows the spec');
clear($ofh, $out);
$repl->step(":prompt %p> \n");
is($repl->prompt, '%p> ', ':prompt FORMAT keeps the trailing space');
$repl->step(":prompt\n");
like($$out, qr/^%p> $/m, 'and shows it');
clear($ofh, $out);
$repl->step(":continuation ~~ \n");
$repl->step(":continuation\n");
like($$out, qr/^~~ $/m, ':continuation FORMAT, then shown');
clear($ofh, $out);
$repl->prompt(sub { 'x' });
$repl->step(":prompt\n");
is($$out, "CODE\n", 'a coderef shows as CODE');
clear($ofh, $out);
$repl->step(":help\n");
like($$out, qr/^  :prompt \[format\]\s+\S/m, ':help lists :prompt');
like($$out, qr/^  :continuation \[format\]\s+\S/m, 'and :continuation');
clear($ofh, $out);
$repl->step(":package\n");
is($$out, "Foo\n", 'other commands still trim their arguments');

done_testing;
