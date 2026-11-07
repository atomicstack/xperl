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

use_ok('Term::ReadLine::XPerl');

# in-memory handles have no file descriptor: reads go through PerlIO
{
    open my $in, '<', \"first\nsecond\n" or die;
    open my $out, '>', \my $buf or die;
    my $t = Term::ReadLine::XPerl->new('t', $in, $out);
    is($t->ReadLine, 'Term::ReadLine::XPerl', 'ReadLine names the backend');
    is($t->readline('> '), 'first', 'non-tty: reads a line, no prompt echo');
    is($t->readline('> '), 'second', 'non-tty: second line');
    is($t->readline('> '), undef, 'non-tty: undef at EOF');
    is($buf // '', '', 'nothing written to out when not a tty');
    is($t->IN, $in, 'IN returns the input handle');
    is($t->OUT, $out, 'OUT returns the output handle');
    is($t->MinLine, undef, 'MinLine is undef');
    is_deeply([$t->GetHistory], [], 'non-tty readline does not add history');
}

{
    open my $in, '<', \"x\n" or die;
    my $t = Term::ReadLine::XPerl->new('t', $in);
    my $f = $t->Features;
    ok($f->{completion}, 'feature: completion');
    ok(!$f->{autohistory}, 'feature: no autohistory');
    ok($f->{$_}, "feature: $_")
        for qw(addhistory readHistory writeHistory getHistory attribs
               key_bindings multiline);
    ok(!$f->{ornaments}, 'feature: no ornaments');
    my $a = $t->Attribs;
    is(ref $a, 'HASH', 'Attribs is a hash ref');
    is($a->{history_max}, 1000, 'history_max defaults to 1000');
    is($a->{multiline}, 1, 'multiline defaults to 1');
    ok(exists $a->{$_}, "attrib $_ exists")
        for qw(completion_function key_bindings);
    ok(!$t->last_submit_forced, 'last_submit_forced starts false');
    is($t->Attribs, $a, 'Attribs returns the same hash each time');
}

# real files and pipes
{
    my ($fh, $file) = tempfile(UNLINK => 1);
    print $fh "one\ntwo\nlast-no-newline";
    close $fh;
    open my $in, '<', $file or die;
    my $t = Term::ReadLine::XPerl->new('t', $in);
    is($t->readline(''), 'one', 'file: first line');
    is($t->readline(''), 'two', 'file: second line');
    is($t->readline(''), 'last-no-newline', 'file: final line without newline');
    is($t->readline(''), undef, 'file: undef at EOF');
}

SKIP: {
    skip 'no pipe open', 3 unless $^O ne 'MSWin32';
    open my $in, '-|', $^X, '-e', 'print "p1\np2\n"' or skip "pipe: $!", 3;
    my $t = Term::ReadLine::XPerl->new('t', $in);
    is($t->readline(''), 'p1', 'pipe: first line');
    is($t->readline(''), 'p2', 'pipe: second line');
    is($t->readline(''), undef, 'pipe: undef at EOF');
}

done_testing();
