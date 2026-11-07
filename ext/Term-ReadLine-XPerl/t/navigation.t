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
    my $t = Term::ReadLine::XPerl->new(q(t), \*STDIN, $outfh);
    $t->_test_mode(80, 24);
    return $t;
}

sub type {
    my ($t, $keys) = @_;
    $t->_feed_keys($keys);
    return $t->readline(q(> ));
}

sub slurp {
    open my $fh, q(<), $_[0] or die "$_[0]: $!";
    local $/;
    return scalar <$fh>;
}


sub hist {
    my $t = ed();
    $t->addhistory($_) for qw(alpha beta alps);
    return $t;
}

is(type(hist(), "\e[A\r"), 'alps', 'up recalls the newest entry');
is(type(hist(), "\e[A\e[A\e[A\r"), 'alpha', 'up up up walks back');
is(type(hist(), "\e[A\e[A\e[A\e[A\r"), 'alpha', 'up stops at the oldest entry');
is(type(hist(), "al\e[A\r"), 'alps', 'prefix-aware up');
is(type(hist(), "al\e[A\e[A\r"), 'alpha', 'prefix-aware up skips non-matching entries');
is(type(hist(), "al\e[A\e[A\e[B\r"), 'alps', 'down walks forward');
is(type(hist(), "al\e[A\e[B\r"), 'al', 'down past the newest restores the typed text');
is(type(hist(), "\e[AX\e[A\r"), 'alpsX', 'editing a recalled entry starts a new prefix');
is(type(hist(), "\eOA\r"), 'alps', 'application-mode up arrow');
is(type(hist(), "zz\e[A\r"), 'zz', 'no match leaves the buffer alone');

is(type(hist(), "\x12bet\r"), 'beta', 'ctrl-r finds and enter accepts');
is(type(hist(), "\x12a\r"), 'alps', 'ctrl-r finds the newest match');
is(type(hist(), "\x12a\x12\r"), 'beta', 'ctrl-r again finds an older match');
is(type(hist(), "\x12a\x12\x12\r"), 'alpha', 'and again');
is(type(hist(), "\x12bet\x07x\r"), 'x', 'ctrl-g cancels to the original buffer');
is(type(hist(), "orig\x12bet\x03\r"), 'orig', 'ctrl-c cancels the search, not the line');
is(type(hist(), "\x12betx\x7f\r"), 'beta', 'backspace shortens the search text');
is(type(hist(), "\x12bet\x05X\r"), 'betaX', 'another key accepts the match and edits it');
like(slurp($outfile), qr/\(reverse-i-search\)'bet': beta/, 'search prompt is drawn');

my $t = ed();
my $ml = "if (1) {\n  1\n}";
$t->addhistory($ml);
is(type($t, "\e[A\r"), $ml, 'a multi-line entry is recalled verbatim');

{
    my ($mfh, $mfile) = tempfile(UNLINK => 1);
    my $m = Term::ReadLine::XPerl->new('t', \*STDIN, $mfh);
    $m->_test_mode(80, 24);
    $m->addhistory("ab\ncd");
    $m->_feed_keys("\e[A\x01X\r");
    is($m->readline('> '), "Xab\ncd", 'editing within a multi-line buffer');
    my $out = slurp($mfile);
    like($out, qr/> ab\r\n  cd/, 'continuation rows are indented by the prompt width');
    like($out, qr/\e\[1A\r\e\[2C/, 'cursor moves up to the first row');

    my ($sfh, $sfile) = tempfile(UNLINK => 1);
    my $s = Term::ReadLine::XPerl->new('t', \*STDIN, $sfh);
    $s->_test_mode(80, 24);
    $s->Attribs->{multiline} = 0;
    $s->addhistory("ab\ncd");
    $s->_feed_keys("\e[A\r");
    is($s->readline('> '), "ab\ncd", 'multiline off still returns the buffer');
    like(slurp($sfile), qr/> ab\^Jcd/, 'multiline off draws newlines as ^J');
}

done_testing();
