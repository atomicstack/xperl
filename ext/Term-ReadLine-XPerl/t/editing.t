#!./perl -w

BEGIN {
    require Config;
    if ($Config::Config{extensions} !~ m{\bTerm/ReadLine/XPerl\b}) {
        print "1..0 # skip: Term::ReadLine::XPerl was not built\n";
        exit 0;
    }
}

use strict;
use Test::More;
use File::Temp qw(tempfile);
use Term::ReadLine::XPerl;

my ($outfh, $outfile) = tempfile(UNLINK => 1);

sub ed {
    my $t = Term::ReadLine::XPerl->new('t', \*STDIN, $outfh);
    $t->_test_mode(80, 24);
    return $t;
}

sub type {
    my ($t, $keys) = @_;
    $t->_feed_keys($keys);
    return $t->readline('> ');
}

sub slurp {
    open my $fh, '<', $_[0] or die "$_[0]: $!";
    local $/;
    return scalar <$fh>;
}

is(type(ed(), "abc\r"), 'abc', 'typed text is returned on enter');
is(type(ed(), "abc\x01X\r"), 'Xabc', 'ctrl-a then insert');
is(type(ed(), "abc\x01\x05X\r"), 'abcX', 'ctrl-e');
is(type(ed(), "abc\e[H\e[FX\r"), 'abcX', 'home and end keys');
is(type(ed(), "abc\x7f\r"), 'ab', 'backspace');
is(type(ed(), "abc\x08\r"), 'ab', 'ctrl-h');
is(type(ed(), "abc\e[D\e[D\e[3~\r"), 'ac', 'left left delete');
is(type(ed(), "abc\x02\x02\x06X\r"), 'abXc', 'ctrl-b ctrl-b ctrl-f');
is(type(ed(), "abc\e[D\e[CX\r"), 'abcX', 'left right');
is(type(ed(), "one two three\x17\r"), 'one two ', 'ctrl-w kills the previous whitespace-delimited word');
is(type(ed(), "one two\x01\x0b\r"), '', 'ctrl-k from start');
is(type(ed(), "one two\x01\ef\x0b\r"), 'one', 'ctrl-k from the middle');
is(type(ed(), "junk\x15new\r"), 'new', 'ctrl-u');
is(type(ed(), "ab cd\e[D\x15\r"), 'd', 'ctrl-u kills only to the left of the cursor');

# word motion follows readline: a word is a run of \w characters
is(type(ed(), "one two\x01\ef\edX\r"), 'oneX', 'alt-f moves past "one", alt-d kills " two"');
is(type(ed(), "foo-bar baz\ebX\r"), 'foo-bar Xbaz', 'alt-b moves to the start of the word');
is(type(ed(), "foo-bar baz\eb\ebX\r"), 'foo-Xbar baz', 'alt-b skips punctuation between words');
is(type(ed(), "foo.bar\x01\edX\r"), 'X.bar', 'alt-d at a word start kills that word only');
is(type(ed(), "a b\x01\ef\efX\r"), 'a bX', 'alt-f twice reaches the end');

my $t = ed();
$t->_feed_keys("abc\x03");
is($t->readline('> '), '', 'ctrl-c returns empty');
ok($t->last_cancelled, 'ctrl-c sets last_cancelled');
$t->_feed_keys("x\r");
is($t->readline('> '), 'x', 'next readline after ctrl-c works');
ok(!$t->last_cancelled, 'last_cancelled is reset by the next readline');

$t = ed();
$t->_feed_keys("\x04");
is($t->readline('> '), undef, 'ctrl-d on empty is EOF');
$t = ed();
$t->_feed_keys("ab\x04\r");
is($t->readline('> '), 'ab', 'ctrl-d on non-empty is no-op at end');
is(type(ed(), "abc\x01\x04\r"), 'bc', 'ctrl-d deletes the character under the cursor');

is(type(ed(), "\r"), '', 'empty enter returns empty string');
is(type(ed(), "a\x0cb\r"), 'ab', 'ctrl-l redraws and keeps the buffer');
is(type(ed(), "a\e[1;5Cb\x07\x00\r"), 'ab', 'unknown keys and sequences are ignored');

$t = ed();
$t->_feed_keys("X\r");
is($t->readline('> ', 'seed'), 'seedX', 'preload');

$t = ed();
$t->_feed_keys("abc");
is($t->readline('> '), undef, 'queue exhausted in test mode is EOF');

$t = ed();
$t->_feed_keys("one\rtwo\r");
is($t->readline('> '), 'one', 'fed keys beyond the submit stay queued');
is($t->readline('> '), 'two', 'and feed the next readline');

like(slurp($outfile), qr/> abc/, 'prompt and text echoed to out');

# the visible line wraps at the test terminal width
{
    my ($wfh, $wfile) = tempfile(UNLINK => 1);
    my $w = Term::ReadLine::XPerl->new('t', \*STDIN, $wfh);
    $w->_test_mode(10, 5);
    $w->_feed_keys("0123456789abcdef\x01\r");
    is($w->readline('> '), '0123456789abcdef', 'a line longer than the terminal');
    like(slurp($wfile), qr/\e\[1A/, 'cursor moved up across the wrapped row');
}

ok(!$t->_raw_active, 'raw mode is off after readline returns');

# ctrl-z suspends the process (SIGTSTP) with the terminal restored, then
# picks up the line again; test mode counts it instead of stopping
{
    my $z = ed();
    my $before = -s $outfile;
    is(type($z, "ab\x1ac\r"), 'abc', 'ctrl-z keeps the line');
    is($z->_suspends, 1, 'and suspends once');
    like(substr(slurp($outfile), $before), qr/> ab[^\n]*\r\n.*> abc/s, 'the line is redrawn on a fresh row after it');
    ok(!$z->_raw_active, 'raw mode is off afterwards');
}

done_testing();
