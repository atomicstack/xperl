#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    skip_all('Term::ReadLine::XPerl was not built')
        unless eval { require Term::ReadLine::XPerl; 1 };
}

use v5.36;
use XPerl::REPL;
use XPerl::REPL::Input;
use File::Spec;

my $screen_file = tempfile();
my $history_file = tempfile();
my $editor = File::Spec->rel2abs(tempfile());    # run via \$EDITOR
my $seen = tempfile();

sub slurp ($file) {
    open my $fh, '<', $file or return '';
    local $/;
    return scalar <$fh>;
}

sub write_file ($file, $text, $mode = 0644) {
    open my $fh, '>', $file or die "$file: $!";
    print {$fh} $text;
    close $fh;
    chmod $mode, $file;
}

# a session reading keys from the editor's test feed; the editor draws on
# $screen_file, results and errors land in $out and $err
sub tty_session ($keys, %opt) {
    open my $o, '>', \my $out;
    open my $e, '>', \my $err;
    open my $screen, '>', $screen_file or die "$screen_file: $!";
    my $term = Term::ReadLine::XPerl->new('xperl-repl-test', \*STDIN, $screen);
    $term->_test_mode(80, 24);
    $term->_feed_keys($keys);
    my $repl = XPerl::REPL->new(out => $o, err => $e, color_level => $opt{color_level} // 0);
    $repl->prompt($opt{prompt}) if defined $opt{prompt};
    my $input = XPerl::REPL::Input::Tty->new(
        repl => $repl, term => $term, history_file => $opt{history_file},
    );
    $repl->set_input($input);
    my $status = $repl->run;
    close $screen;
    return ($out // '', $err // '', $status, slurp($screen_file), $term);
}

my ($out, $err, $status, $screen) = tty_session("1 + 1\r");
is($out, "2\n", 'a line typed into the editor is evaluated');
is($err, '', 'no errors');
is($status, 0, 'end of keys ends the session with 0');
like($screen, qr/1> 1 \+ 1/, 'the editor drew the prompt and the line');

($out, $err, $status, $screen) = tty_session("1 + 1\r", prompt => '%{prompt}%n%{/}> ', color_level => 16);
is($out, "\e[32m2\e[0m\n", 'a coloured custom prompt still returns the typed line');
like($screen, qr/\e\[1m1\e\[0m> 1 \+ 1/, 'and is drawn as rendered');

($out, $err, $status, $screen) = tty_session("if (1) {\r42\r}\r");
is($out, "42\n", 'continuation lines are read through the editor');
like($screen, qr/\.\.\. 42/, 'with the continuation prompt');

($out, $err) = tty_session("if (1) {\e\r7\r");
like($err, qr/^compile error: /, 'alt-enter submits incomplete input as is');
is($out, "7\n", 'and the session goes on');

($out, $err) = tty_session("if (1) {\r\x03" . "5\r");
is($out, "5\n", 'ctrl-c during continuation discards the pending input');
is($err, '', 'without an error');

($out, $err) = tty_session("1 + \\\r\x03" . "6\r");
is($out, "6\n", 'ctrl-c after a backslash continuation discards it too');

{
    local $ENV{EDITOR} = $editor;
    delete local $ENV{VISUAL};
    write_file($editor, qq{#!/bin/sh\ncat "\$1" > '$seen'\nprintf 'my \$e = 9\\n' > "\$1"\n}, 0755);

    ($out, $err) = tty_session(":edit\r\$e\r");
    is($out, "1> my \$e = 9\n9\n9\n", ':edit runs the edited text as the next input, echoed');
    is($err, '', 'no errors from :edit');

    ($out, $err) = tty_session("7\r:edit\r");
    is(slurp($seen), "7\n", ':edit starts from the last input');

    ($out, $err) = tty_session("abc\x18\x05\$e\r");
    is($out, "9\n9\n", 'ctrl-x ctrl-e submits the edited text');
    is(slurp($seen), "abc\n", 'starting from the current buffer');

    local $ENV{EDITOR} = 'false';
    ($out, $err) = tty_session(":edit\r");
    like($err, qr/editor exited with status 1, input kept/, 'a failing editor is reported');
    ($out, $err) = tty_session("7\x18\x05\r");
    like($err, qr/editor exited with status 1, input kept/, 'from the binding too');
    is($out, "7\n", 'and the buffer is kept');

    local $ENV{VISUAL} = $editor;
    ($out, $err) = tty_session(":edit\r");
    is($out, "1> my \$e = 9\n9\n", '$VISUAL wins over $EDITOR');
}

unlink $history_file;
tty_session("my \$h1 = 1\rif (1) {\r2\r}\r", history_file => $history_file);
{
    open my $screen, '>', $screen_file or die;
    my $term = Term::ReadLine::XPerl->new('xperl-repl-test', \*STDIN, $screen);
    $term->_test_mode(80, 24);
    open my $o, '>', \my $o_text;
    my $repl = XPerl::REPL->new(out => $o, err => $o);
    my $input = XPerl::REPL::Input::Tty->new(
        repl => $repl, term => $term, history_file => $history_file,
    );
    is(join('|', $term->GetHistory), "my \$h1 = 1|if (1) {\n2\n}",
       'history file round trip, one entry per input');
}

# with a UTF-8 input handle lines are characters, and so is the history
{
    unlink $history_file;
    open my $in, '<&', \*STDIN or die "dup STDIN: $!";
    binmode $in, ':encoding(UTF-8)';
    open my $o, '>', \my $out;
    open my $screen, '>', $screen_file or die;
    my $term = Term::ReadLine::XPerl->new('xperl-repl-test', $in, $screen);
    $term->_test_mode(80, 24);
    $term->_feed_keys("length \"\xce\xbb\xc3\xa9\"\r");
    my $repl = XPerl::REPL->new(out => $o, err => $o);
    $repl->set_input(XPerl::REPL::Input::Tty->new(repl => $repl, term => $term, history_file => $history_file));
    $repl->run;
    is($out, "2\n", 'a UTF-8 input handle gives characters');

    # what an editor saves is UTF-8 too
    write_file($editor, qq{#!/bin/sh\nprintf 'length "\\316\\273"\\n' > "\$1"\n}, 0755);
    local $ENV{EDITOR} = $editor;
    delete local $ENV{VISUAL};
    for my $keys ("\x18\x05", ":edit\r") {
        open my $o2, '>:utf8', \my $out2;
        my $t2 = Term::ReadLine::XPerl->new('xperl-repl-test', $in, $screen);
        $t2->_test_mode(80, 24);
        $t2->_feed_keys($keys);
        my $r2 = XPerl::REPL->new(out => $o2, err => $o2);
        $r2->set_input(XPerl::REPL::Input::Tty->new(repl => $r2, term => $t2));
        $r2->run;
        like($out2, qr/^1\n\z/m, 'edited text is decoded: ' . ($keys =~ /edit/ ? ':edit' : 'ctrl-x ctrl-e'));
    }
    open my $hf, '<:raw', $history_file or die;
    is(scalar <$hf>, "length \"\xce\xbb\xc3\xa9\"\n", 'the history file holds UTF-8');
    my $again = Term::ReadLine::XPerl->new('xperl-repl-test', $in, $screen);
    $again->_test_mode(80, 24);
    $again->ReadHistory($history_file);
    is(join('|', $again->GetHistory), "length \"\x{3bb}\x{e9}\"", 'and reads back as characters');
    my $cafe = "caf\xe9";    # one byte per character, not UTF-8 flagged
    $again->addhistory($cafe);
    $again->WriteHistory($history_file);
    open $hf, '<:raw', $history_file or die;
    my @raw = <$hf>;
    is($raw[-1], "caf\xc3\xa9\n", 'a character string without the UTF-8 flag is encoded too');
    is(($again->GetHistory)[-1], "caf\x{e9}", 'and round-trips');
}

{
    my (undef, undef, undef, undef, $term) = tty_session(":out json\r1\r");
    is(join('|', $term->GetHistory), ':out json|1', ':commands go into the editor history');
}

{
    my (undef, undef, undef, $listed) = tty_session("my \$xqa = 1; my \$xqb = 2\r\$xq\t\t\x03", color_level => 16);
    like($listed, qr/\e\[32m\$xqa\e\[0m +\e\[32m\$xqb\e\[0m/, 'completion listings are coloured by kind');
    (undef, undef, undef, $listed) = tty_session("my \$xqa = 1; my \$xqb = 2\r\$xq\t\t\x03");
    like($listed, qr/\$xqa +\$xqb\r\n/, 'listed');
    unlike($listed, qr/\e\[3\dm/, 'and plain without colour');
}

{
    my ($o, undef, undef, $listed) = tty_session("my \@a = (5, 6)\r\$a[\t1]\r");
    is($o, "(5, 6)\n6\n", 'an index range is not inserted: the line stays \$a[ and the typed index is used');
    like($listed, qr/\r\n0\.\.1\r\n/, 'the range is listed above the prompt');
}

($out, $err) = tty_session(":he\t\r");
like($out, qr/^commands:/, 'tab completes a :command');

($out, $err) = tty_session("my \$long_name = 4\r\$long_n\t + 1\r");
is($out, "4\n5\n", 'tab completes a lexical');

# a completion or key binding that dies does not end the session
{
    open my $o, '>', \my $out;
    open my $e, '>', \my $err;
    open my $screen, '>', $screen_file or die;
    my $term = Term::ReadLine::XPerl->new('xperl-repl-test', \*STDIN, $screen);
    $term->_test_mode(80, 24);
    $term->_feed_keys("1\t\r2\r");
    my $repl = XPerl::REPL->new(out => $o, err => $e);
    $repl->set_input(XPerl::REPL::Input::Tty->new(repl => $repl, term => $term));
    $term->Attribs->{completion_function} = sub { die "completion broke\n" };
    is($repl->run, 0, 'a dying completion does not end the session');
    like($err // '', qr/^error: completion broke/m, 'it is reported');
    is($out, "2\n", 'and the next line is read');
}

# without the editor: Term::ReadLine's stub, with a notice
my $prog = <<'EOP';
unshift @INC, sub { die "blocked\n" if $_[1] eq 'Term/ReadLine/XPerl.pm'; return };
require XPerl::REPL; require XPerl::REPL::Input;
my $r = XPerl::REPL->new(out => \*STDOUT, err => \*STDERR);
$r->set_input(XPerl::REPL::Input::Tty->new(repl => $r, in => \*STDIN, out => \*STDOUT));
exit $r->run;
EOP
my $progfile = tempfile();
write_file($progfile, $prog);
my $got = runperl(progfile => $progfile, stdin => "1 + 2\n", stderr => 1);
like($got, qr/line editing unavailable: Term::ReadLine::XPerl not built; history, completion and key bindings are off/,
     'a notice when the editor is missing');
like($got, qr/1> 3$/m, 'the stub reads lines and shows the prompt');

done_testing();
