#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use Scalar::Util ();
use XPerl::REPL::Render;

my $r = XPerl::REPL::Render->new(out => \*STDOUT, err => \*STDERR);
is($r->format_values(42), "42\n", 'scalar without VAR prefix');
is($r->format_values(), '', 'empty list prints nothing');
is($r->format_values(undef), "undef\n", 'undef');
is($r->format_values("a\tb"), qq{"a\\tb"\n}, 'Useqq strings');
like($r->format_values({ b => 1, a => [1,2] }), qr/^\{\n\s+a => \[\n/, 'nested, sorted, Indent=1');
is($r->format_values(1, 2), "(1, 2)\n", 'list of plain scalars in parens on one line');
# top-level values created as numbers print bare, not quoted as Dumper
# quotes floats; strings, booleans, undef and references are unchanged
is($r->format_values(2**32), "4294967296\n", 'a float-valued integer is bare');
is($r->format_values(3.5), "3.5\n", 'a float is bare');
is($r->format_values(2**64), "1.84467440737096e+19\n", 'a large float is bare');
is($r->format_values(-0.25), "-0.25\n", 'a negative float is bare');
is($r->format_values(1e100), "1e+100\n", 'an exponent float is bare');
is($r->format_values(42), "42\n", 'an integer is bare as before');
is($r->format_values("42"), qq{"42"\n}, 'a string is quoted, however short');
is($r->format_values("42" + 0), "42\n", 'a number made from a string is bare');
is($r->format_values(42 . ""), qq{"42"\n}, 'a string made from a number is quoted');
is($r->format_values("abc"), qq{"abc"\n}, 'a plain string');
is($r->format_values("a\tb\x{263a}"), qq{"a\\tb\\x{263a}"\n}, 'with Useqq escapes');
{
  my $n = 7; my $used = "$n";
  is($r->format_values($n), "7\n", 'a number used as a string is still a number');
  my $s = "7"; my $sum = $s + 1;
  is($r->format_values($s), qq{"7"\n}, 'a string used as a number is still a string');
  # a dualvar has a string part, so created_as_string is true: its string
  # is quoted, as Dumper prints it too
  is($r->format_values(Scalar::Util::dualvar(5, "five")), qq{"five"\n}, 'a dualvar prints its string, quoted');
}
is($r->format_values(42, "42"), qq{(42, "42")\n}, 'list: number bare, string quoted');
is($r->format_values("4294967296"), qq{"4294967296"\n}, 'and so does a long one');
is($r->format_values(!!1), "!!1\n", 'true stays !!1');
is($r->format_values(!!0), "!!0\n", 'false stays !!0');
is($r->format_values(undef), "undef\n", 'undef stays undef');
is($r->format_values([3.5]), "[\n  \"3.5\"\n]\n", 'numbers inside references are left to Dumper');
is($r->format_values(2**32, "x"), qq{(4294967296, "x")\n}, 'each element of a list');
is($r->format_values(3.5, [1]), "(\n3.5,\n[\n  1\n]\n)\n", 'each element of a list with references');
like($r->format_values(1, 2), qr/^\(\n?1,\s*2\n?\)\n$/s, 'list of plain scalars in parens');
like($r->format_values(1, [2]), qr/^\(\n1,\n\[/m, 'list with a ref: one per line');
is($r->format_values(1, [2]), "(\n1,\n[\n  2\n]\n)\n", 'list with a ref: exact layout');
{ use feature 'class'; no warnings 'experimental::class'; class RPoint { field $x :param; field $y :param; }
  like($r->format_values(RPoint->new(x => 1, y => 2)), qr/RPoint/, 'class object dumped');
  like($r->format_values(RPoint->new(x => 1, y => 2)), qr/x.*1/s, 'class object shows fields');
  $r->set_out_mode('json');
  like($r->format_values(RPoint->new(x => 1, y => 2)), qr/"RPoint" : \{\n\s+"\$x" : 1,/, 'json class object via class_object_to_hash');
  $r->set_out_mode('dumper'); }
is($r->out_mode, 'dumper', 'out mode reader');
$r->set_out_mode('json');
is($r->format_values({ b => 1, a => 2 }), qq[{\n   "a" : 2,\n   "b" : 1\n}\n], 'json canonical pretty');
is($r->format_values(1, 2), qq{[\n   1,\n   2\n]\n}, 'json list as array');
{
  open my $werr, '>', \my $warned;
  my $w = XPerl::REPL::Render->new(out => \*STDOUT, err => $werr);
  $w->set_out_mode('json');
  like($w->format_values(sub {}), qr/CODE\(0x/, 'code ref falls back to stringification');
  like($warned, qr/^result is not representable as json, printed as strings$/m, 'with a warning on err');
}
$r->set_out_mode('plain');
is($r->format_values("a", undef, 3), "a\n\n3\n", 'plain joins with newlines');
eval { $r->set_out_mode('nope') }; like($@, qr/unknown output mode "nope"/);
eval { $r->set_render_mode('nope') }; like($@, qr/unknown render mode "nope"/);
is($r->render_mode, 'legacy', 'render mode default');

is(XPerl::REPL::Render::sgr('red', 16), "\e[31m");
is(XPerl::REPL::Render::sgr('bold red', 16), "\e[1;31m");
is(XPerl::REPL::Render::sgr(208, 256), "\e[38;5;208m");
is(XPerl::REPL::Render::sgr('#ff5f5f', 'rgb'), "\e[38;2;255;95;95m");
is(XPerl::REPL::Render::sgr('#ff5f5f', 256), "\e[38;5;203m", 'rgb downgraded to 256');
is(XPerl::REPL::Render::sgr('#ff5f5f', 16), "\e[91m", 'rgb downgraded to bright red');
is(XPerl::REPL::Render::sgr('#ff5f5f', 0), '', 'no colour');
is(XPerl::REPL::Render::sgr(9, 16), "\e[91m", 'low index at 16 colours');
is(XPerl::REPL::Render::nearest_256(128, 128, 128), 244, 'grey ramp');
is(XPerl::REPL::Render::nearest_16(0, 0, 0), 'black');
is($r->colorize('error', 'x'), 'x', 'identity at level 0');
my $c = XPerl::REPL::Render->new(out => \*STDOUT, err => \*STDERR, color_level => 16);
is($c->colorize('error', 'x'), "\e[31mx\e[0m", 'default error theme is red');
is($c->colorize('result', 'x'), "\e[32mx\e[0m", 'default result theme is green');
is($c->prompt(3), "\e[1m3> \e[0m", 'prompt bold by default');
$c->set_theme(error => '#ff5f5f');
is($c->colorize('error', 'x'), "\e[91mx\e[0m", 'user theme, downgraded to the level');
is($c->theme->{warning}, 'yellow', 'set_theme keeps other roles');
is($c->theme->{'complete.scalar'}, 'green', 'completion kinds have theme roles');
is($c->colorize('complete.key', 'x'), "\e[33mx\e[0m", 'keys are yellow by default');
is($c->colorize('complete.sub', 'x'), "\e[94mx\e[0m", 'subs are bright blue by default');
is($c->colorize('complete.method', 'x'), "\e[94mx\e[0m", 'and so are methods');
is($c->colorize('complete.hint', 'x'), "\e[90mx\e[0m", 'hints are muted');
$c->set_theme('complete.key' => 'red');
is($c->colorize('complete.key', 'x'), "\e[31mx\e[0m", 'a completion role is themable');
is($r->prompt(3), '3> ');
is($r->continuation_prompt, '... ');

use XPerl::REPL::Evaluator;
my $ev = XPerl::REPL::Evaluator->new;
my $bad = $ev->evaluate('1 = = 2', 7);
my $txt = $r->format_exception($bad->exception, prefix => 'compile error: ');
like($txt, qr/^compile error: syntax error at input 7 line 1/, 'legacy, input N substituted');
unlike($txt, qr/\(eval \d+\)/, 'no (eval N) leaks');
is($txt, qq{compile error: syntax error at input 7 line 1, near "= ="\n}, 'execution-aborted group is not counted for :stack');
like($r->format_exception($bad->exception, full => 1), qr/^Execution of input 7 aborted/m, 'but full still shows it');
like($r->format_exception($bad->exception, mode => 'json'), qr/"schema"\s*:\s*"xperl\.exception\.v2"/, 'json mode');
like($r->format_exception($bad->exception, mode => 'annotated'), qr/ERROR_SYNTAX_INVALID|syntax error/i, 'annotated mode renders');
like($r->format_exception($bad->exception, mode => 'annotated'), qr/ at input 7 line 1/, 'annotated substitutes input N');
{
    # perl quotes the first line as "near" text, with the #line directive
    local $SIG{__WARN__} = sub {};
    my $near = $ev->evaluate('1 2', 12);
    my $all = $r->format_exception($near->exception, full => 1);
    like($all, qr/near "1 2"\n/, 'near text without the #line directive');
    unlike($all, qr/#line/, 'no #line anywhere');
    unlike($r->format_exception($near->exception, mode => 'annotated'), qr/#line/, 'nor annotated');
}
{
    my $json = $r->format_exception($ev->evaluate('1 +', 14)->exception, mode => 'json');
    like($json, qr/"file" : "input 14"/, 'json mode shows the input label as the file');
    unlike($json, qr/xperl-repl/, 'json mode has no generated file names');
}
my $multi = $ev->evaluate('if (1) {', 8);
like($r->format_exception($multi->exception), qr/\(:stack for 1 more\)/, 'extra groups summarised');
unlike($r->format_exception($multi->exception, full => 1), qr/:stack for/, 'full shows all');
my $die = $ev->evaluate('die { code => 7 }', 9);
like($r->format_exception($die->value, prefix => 'error: '), qr/^error: \{\n\s+code => 7/, 'non-exception die dumped');
is($r->format_exception("plain\n"), "plain\n", 'a plain string passes through');

{
  open my $o, '>', \my $out; open my $e, '>', \my $err;
  my $p = XPerl::REPL::Render->new(out => $o, err => $e);
  $p->print_result($ev->evaluate('6 * 7', 10));
  $p->print_error($bad);
  $p->print_error($ev->evaluate('die "boom\n"', 11));
  $p->print_error(XPerl::REPL::Result->new(kind => 'interrupted', input_number => 12));
  $p->print_warning("careful\n");
  is($out, "42\n", 'print_result writes to out');
  like($err, qr/^compile error: syntax error at input 7 line 1/, 'compile error prefix');
  like($err, qr/^error: boom$/m, 'runtime error prefix');
  like($err, qr/^interrupted$/m, 'interrupted');
  like($err, qr/^careful$/m, 'warning on err');
}

# results are green by default in every output mode; only the text is
# coloured, the trailing newline is not
for my $mode (qw(dumper json plain)) {
  open my $o, '>', \my $out;
  my $p = XPerl::REPL::Render->new(out => $o, err => \*STDERR, color_level => 16);
  $p->set_out_mode($mode);
  $p->print_result($ev->evaluate('6 * 7', 13));
  is($out, "\e[32m42\e[0m\n", "$mode result is green");
}
{
  open my $o, '>', \my $out;
  my $p = XPerl::REPL::Render->new(out => $o, err => \*STDERR, color_level => 16);
  $p->print_result($ev->evaluate('[1]', 14));
  is($out, "\e[32m[\n  1\n]\e[0m\n", 'multi-line result coloured as one block, newline outside');
  $p->set_theme(result => '');
  $out = ''; seek $o, 0, 0;
  $p->print_result($ev->evaluate('42', 15));
  is($out, "42\n", 'empty result spec is uncoloured');
}
{
  open my $o, '>', \my $out;
  my $p = XPerl::REPL::Render->new(out => $o, err => \*STDERR);
  $p->print_result($ev->evaluate('42', 16));
  is($out, "42\n", 'no colour at level 0');
}
done_testing;
