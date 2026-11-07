#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use v5.36;
use XPerl::REPL;
use XPerl::REPL::Input;

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

sub session (@lines) {
    open my $o, '>', \my $out;
    open my $e, '>', \my $err;
    my $repl = XPerl::REPL->new(input => XPerl::REPL::Input::List->new(lines => \@lines), out => $o, err => $e);
    my $status = $repl->run;
    close $o; close $e;
    return ($out // '', $err // '', $status, $repl);
}

my ($out, $err, $st) = session('1 + 1', 'my $x = 3', '$x * 2');
is($out, "2\n3\n6\n", 'results printed, lexicals persist, no prompts on non-tty');
is($err, '', 'no errors');
is($st, 0, 'exit 0 at EOF');

($out, $err) = session('if (1) {', '  42', '}');
is($out, "42\n", 'continuation lines joined');

# the assignment prints its value too, like any other input
($out) = session('my $h = <<EOT', 'hello', 'EOT', '$h');
is($out, qq{"hello\\n"\n"hello\\n"\n}, 'heredoc terminator recognised (joined text ends in newline)');

($out) = session('my $s = 1 + \\', '2', '$s');
is($out, "3\n3\n", 'backslash continuation');

($out, $err) = session('1 = = 2', '7');
like($err, qr/^compile error: syntax error at input 1 line 1/, 'compile error rendered on err');
is($out, "7\n", 'session continues after error, input number advances');

($out, $err) = session('if (1) {', '1;');
like($err, qr/^compile error: Missing right curly .* at input 1 line 2/, 'incomplete input at EOF is submitted as an error');

($out, $err) = session('1 +');
is($err, "compile error: syntax error at input 1 line 1, at EOF\n", 'the generated tail is shown as the input');

# a compile-time warning: only the warning is printed for it, and the
# compile error after it starts with the error
($out, $err) = session('1 2');
my @lines = split /\n/, $err;
is(scalar(grep { /^compile error: / } @lines), 1, 'one compile error line');
is(scalar(grep { /Number found where operator expected/ } @lines), 1, 'the warning once');
like($err, qr/^Number found where operator expected .* at input 1 line 1, near "1 2"\n/, 'the warning first, without the #line directive');
like($err, qr/^compile error: syntax error at input 1 line 1, near "1 2"$/m, 'then the syntax error');
unlike($err, qr/#line/, 'no generated #line text anywhere');

($out, $err) = session(':render json', '1 2');
my ($warning) = $err =~ /\A(\{.*?^\})\n/ms;
like($warning, qr/"code" : "WARNING_SYNTAX_OPERATOR_EXPECTED"/, 'json: the warning');
unlike($warning, qr/ERROR_SYNTAX_INVALID/, 'json: without the error');
like($warning, qr/"severity" : "WARNING"/, 'json: as a warning');

($out, $err) = session('my $u; my $s = "a" . $u', '1');
like($err, qr/^Use of uninitialized value \$u in concatenation \(\.\) or string at input 1 line 1\.$/m, 'a runtime warning is rendered as it was');

($out, $err) = session('1 +;', '5');
like($err, qr/^compile error: syntax error at input 1 line 1, at EOF/, "an operator before ';' is an error at once");
is($out, "5\n", 'not a continuation');

($out, $err) = session('die "boom\n"', '8');
like($err, qr/^error: boom/, 'runtime error');

($out, $err) = session('warn "careful\n"; print "p\n"; 5');
like($out, qr/^p\n5\n/, 'user print then result');
like($err, qr/^careful/, 'warning rendered on err, immediately');

($out, $err) = session('local $SIG{ALRM} = sub { kill INT => $$ }; alarm 1; sleep 5; 1', '"next"');
like($err, qr/^interrupted/, 'SIGINT during execution renders interrupted');
is($out, qq{"next"\n}, 'and the loop continues');

# failures outside the evaluator do not end the session
($out, $err) = session(
    'package TH { sub TIEHASH { bless {} } sub FETCH { die "fetch failed\n" } sub FIRSTKEY { "a" } sub NEXTKEY { undef } }',
    'tie my %th, "TH"; \\%th',
    '5',
);
like($err, qr/^error: fetch failed/m, 'a value that dies while it is rendered is reported');
like($out, qr/^5\n\z/m, 'and the next input runs');

($out, $err) = session(
    ':out plain',
    'package SI { use overload q{""} => sub { kill INT => $$; sleep 2; "x" } }',
    'bless {}, "SI"',
    '6',
);
like($err, qr/^interrupted/m, 'SIGINT while a result is rendered interrupts that input');
like($out, qr/^6\n\z/m, 'and the next input runs');

# the user's $/, $\ and $, do not reach the repl's own reads and prints
{
    open my $in, '<', \"\$/ = undef; 1\n2 + 2\n3\n";
    open my $o, '>', \my $hout;
    open my $e, '>', \my $herr;
    my $repl = XPerl::REPL->new(input => XPerl::REPL::Input::Handle->new(fh => $in), out => $o, err => $e);
    $repl->run;
    is($hout, "1\n4\n3\n", '$/ = undef does not change how input lines are read');
    $/ = "\n";
}
($out, $err) = session('$\ = "X"; $, = "-"; 1', '(2, 3)', ':out plain', '4', 'die "d\n"', ':history 1');
unlike($out, qr/X|-/, '$\ and $, do not appear in results or command output');
unlike($err, qr/X|-\z/, 'nor in errors');
$\ = undef; $, = undef;

($out, $err) = session('', '   ', '1');
is($out, "1\n", 'blank lines are skipped');

my (undef, undef, undef, $repl) = session('my $q = 1');
is($repl->input_number, 1);
is_deeply($repl->history, ["my \$q = 1\n"], 'history keeps submitted inputs');

(undef, undef, undef, $repl) = session('1', '1 = = 2', '2');
is($repl->last_error->input_number, 2, 'last_error is the last failed input');

open my $fh, '<', \"1\n2\n"; my $h = XPerl::REPL::Input::Handle->new(fh => $fh);
ok(!$h->is_tty, 'handle source is not a tty');
is($h->next_line('> '), '1'); is($h->next_line('> '), '2'); is($h->next_line('> '), undef); ok($h->exhausted);

{
  open my $o, '>', \my $echoed;
  my $e = XPerl::REPL->new(input => XPerl::REPL::Input::List->new(lines => []), out => $o, err => \*STDERR);
  $e->step('3 + 4', echo => 1);
  is($echoed, "1> 3 + 4\n7\n", 'echo prints prompt and text first');
  $e->out('json');
  is($e->renderer->out_mode, 'json', 'out($mode) sets the result mode');
  $e->render('annotated');
  is($e->renderer->render_mode, 'annotated', 'render($mode) sets the error mode');
  $e->theme(error => 'magenta');
  is($e->renderer->theme->{error}, 'magenta', 'theme(%roles) sets colours');
}

my $ro = XPerl::REPL->new(input => XPerl::REPL::Input::List->new(lines => []), out => \*STDOUT, err => \*STDERR);
is($main::REPL, $ro, '$main::REPL set for rc files');
done_testing;
