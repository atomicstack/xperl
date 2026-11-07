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


my @calls;
sub completer {
    my @ret = @_;
    return sub { push @calls, [@_]; return @ret };
}

my $t = ed();
$t->Attribs->{completion_function} = completer(['hello'], 0);
is(type($t, "he\t\r"), 'hello', 'one match replaces the word');

$t = ed();
$t->Attribs->{completion_function} = completer(['help', 'hello'], 0);
is(type($t, "he\t\r"), 'hel', 'several matches: first tab inserts the common prefix');

{
    my ($lfh, $lfile) = tempfile(UNLINK => 1);
    my $l = Term::ReadLine::XPerl->new('t', \*STDIN, $lfh);
    $l->_test_mode(80, 24);
    $l->Attribs->{completion_function} = completer(['help', 'hello'], 0);
    is(type($l, "he\t\t\r"), 'hel', 'second tab lists without changing the buffer');
    my $out = slurp($lfile);
    like($out, qr/\r\nhelp +hello\r\n/, 'the matches are listed in columns');
    like($out, qr/hello\r\n.*> hel/s, 'the prompt and buffer are redrawn after the list');
}

$t = ed();
$t->Attribs->{completion_function} = completer([], 0);
is(type($t, "he\t\r"), 'he', 'no match leaves the buffer unchanged');
like(slurp($outfile), qr/\a/, 'no match rings the bell');

@calls = ();
$t = ed();
$t->Attribs->{completion_function} = completer(['$alpha'], 4);
is(type($t, "say \$al\t\r"), 'say $alpha', 'completion of a word mid-line');
is_deeply($calls[0], ['say $al', 7], 'callback receives the buffer and cursor');

@calls = ();
$t = ed();
$t->Attribs->{completion_function} = completer(['foo'], 0);
is(type($t, "fo x\e[D\e[D\t\r"), 'foo x', 'completion before trailing text');
is_deeply($calls[0], ['fo x', 2], 'cursor is the completion point, not the end');

# wide characters on an IN handle without a :utf8 layer are sent as UTF-8
$t = ed();
$t->Attribs->{completion_function} = sub { return (["\x{3bb}x"], 0) };
is(type($t, "a\t\r"), "\xce\xbbx", 'a wide-character completion comes back as UTF-8 bytes');
ok(!$t->_raw_active, 'raw mode is off afterwards');

$t = ed();
$t->Attribs->{completion_function} = sub { return (["x"], "not a number") };
$t->_feed_keys("a\t");
ok(!eval { $t->readline('> '); 1 }, 'a non-numeric start dies');
like($@, qr/completion_function/, 'naming completion_function');
ok(!$t->_raw_active, 'raw mode is off afterwards');

$t = ed();
is(type($t, "a\tb\r"), 'ab', 'tab without a completion_function does nothing');

$t = ed();
$t->Attribs->{completion_function} = sub { die "boom\n" };
$t->_feed_keys("x\t\r");
ok(!eval { $t->readline('> '); 1 }, 'a dying completion_function propagates');
is($@, "boom\n", 'with its exception');
ok(!$t->_raw_active, 'raw mode is restored before the exception propagates');
{
    my ($dfh, $dfile) = tempfile(UNLINK => 1);
    my $d = Term::ReadLine::XPerl->new('t', \*STDIN, $dfh);
    $d->_test_mode(80, 24);
    $d->Attribs->{completion_function} = sub { die "boom\n" };
    $d->_feed_keys("x\t");
    eval { $d->readline('> ') };
    like(slurp($dfile), qr/> x\r\e\[3C\r\n\z/, 'the error is not printed on the input row');
}

$t = ed();
my $raw_in_cb;
$t->Attribs->{completion_function} = sub { $raw_in_cb = $t->_raw_active; return (['xy'], 0) };
is(type($t, "x\t\r"), 'xy', 'completion runs');
ok($raw_in_cb, 'completion callbacks run in raw mode');

# listings coloured by kind: completion_function's optional third value
# names each word's kind, candidate_colors maps kinds to SGR prefixes
sub listing {
    my (%attr) = @_;
    my ($lfh, $lfile) = tempfile(UNLINK => 1);
    my $l = Term::ReadLine::XPerl->new('t', \*STDIN, $lfh);
    $l->_test_mode(80, 24);
    %{ $l->Attribs } = (%{ $l->Attribs }, %attr);
    my $line = type($l, "\t\t\r");
    return ($line, slurp($lfile));
}
my %colors = (package => "\e[36m", key => "\e[33m");
my ($line, $listed) = listing(
    completion_function => completer(['alpha', 'beta'], 0, ['package', 'key']),
    candidate_colors    => \%colors,
);
like($listed, qr/\e\[36malpha\e\[0m/, 'a listed word in its kind colour');
like($listed, qr/\e\[33mbeta\e\[0m/, 'each word by its own kind');
like($listed, qr/\e\[36malpha\e\[0m {2}\e\[33mbeta/, 'columns padded by the visible width');
is($line, '', 'the returned line has no escapes');
($line, $listed) = listing(
    completion_function => completer(['alpha', 'beta'], 0, ['package', 'other']),
    candidate_colors    => \%colors,
);
like($listed, qr/\e\[36malpha\e\[0m {2}beta\r\n/, 'a kind with no colour is plain');
($line, $listed) = listing(completion_function => completer(['alpha', 'beta'], 0, ['package', 'key']));
unlike($listed, qr/\e\[3[36]m/, 'no candidate_colors: a plain listing');
($line, $listed) = listing(
    completion_function => completer(['alpha', 'beta'], 0),
    candidate_colors    => \%colors,
);
like($listed, qr/\r\nalpha +beta\r\n/, 'two return values: a plain listing');
($line, $listed) = listing(
    completion_function => completer(['alpha', 'beta'], 0, ['package']),
    candidate_colors    => \%colors,
);
like($listed, qr/\r\nalpha +beta\r\n/, 'kinds of the wrong length are ignored');
$t = ed();
$t->Attribs->{completion_function} = completer(['alphabet'], 0, ['package']);
$t->Attribs->{candidate_colors} = \%colors;
is(type($t, "al\t\r"), 'alphabet', 'a single match is inserted without colour');

# display-only candidates (kinds in display_only_kinds, default hint) are
# listed, never inserted; when there are any they are listed on the first tab
sub hinted {
    my ($keys, @ret) = @_;
    my ($hfh, $hfile) = tempfile(UNLINK => 1);
    my $h = Term::ReadLine::XPerl->new('t', \*STDIN, $hfh);
    $h->_test_mode(80, 24);
    $h->Attribs->{completion_function} = completer(@ret);
    my $line = type($h, $keys);
    return ($line, slurp($hfile), $h);
}
my $out;
is_deeply(Term::ReadLine::XPerl->new('t', \*STDIN, $outfh)->Attribs->{display_only_kinds}, ['hint'],
          'display_only_kinds defaults to hint');
($line, $out) = hinted("\$a[\t\r", ['0..1'], 3, ['hint']);
is($line, '$a[', 'a hint alone is not inserted');
like($out, qr/\r\n0\.\.1\r\n/, 'it is listed on the first tab');
unlike($out, qr/\a/, 'without the bell');
($line, $out) = hinted("\t\r", ['foo', '0..1'], 0, ['sub', 'hint']);
is($line, 'foo', 'with one insertable candidate, that one is inserted');
like($out, qr/\r\nfoo +0\.\.1\r\n/, 'and both are listed');
($line, $out) = hinted("\t\r", ['help', 'hello', '0..1'], 0, ['sub', 'sub', 'hint']);
is($line, 'hel', 'with several, their common prefix is inserted');
like($out, qr/\r\nhelp +hello +0\.\.1\r\n/, 'and all are listed');
{
    my ($hfh, $hfile) = tempfile(UNLINK => 1);
    my $h = Term::ReadLine::XPerl->new('t', \*STDIN, $hfh);
    $h->_test_mode(80, 24);
    $h->Attribs->{completion_function} = completer(['0..1'], 0, ['hint']);
    $h->Attribs->{display_only_kinds} = [];
    is(type($h, "\t\r"), '0..1', 'a kind not in display_only_kinds is inserted');
}
($line, $out) = hinted("x\t\r", ['0..1'], 1, ['hint', 'extra']);
is($line, 'x0..1', 'kinds of the wrong length: no hints');

done_testing();
