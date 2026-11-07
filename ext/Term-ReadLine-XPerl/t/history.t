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

sub term {
    open my $in, '<', \'' or die;
    Term::ReadLine::XPerl->new('t', $in);
}

my @entries = ('print 1', "if (1) {\n  2\n}", 'say "a\\\\nb\\\\"');

my $t = term();
$t->addhistory($_) for @entries;
is_deeply([$t->GetHistory], \@entries, 'GetHistory returns entries in order');

my ($fh, $file) = tempfile(UNLINK => 1);
close $fh;
ok($t->WriteHistory($file), 'WriteHistory returns true');
{
    open my $r, '<', $file or die;
    my @lines = <$r>;
    is(scalar @lines, 3, 'one line per entry in the history file');
    is($lines[1], "if (1) {\\n  2\\n}\n", 'embedded newlines are escaped');
    is($lines[2], "say \"a\\\\\\\\nb\\\\\\\\\"\n", 'backslashes are escaped');
}

my $t2 = term();
ok($t2->ReadHistory($file), 'ReadHistory returns true');
is_deeply([$t2->GetHistory], \@entries, 'history file round-trips');

ok(!$t2->ReadHistory("$file.does-not-exist"), 'ReadHistory of a missing file is false');
ok(!$t2->WriteHistory("$file.no/such/dir"), 'WriteHistory to a bad path is false');

my $t3 = term();
$t3->Attribs->{history_max} = 2;
$t3->addhistory($_) for qw(a b c);
is_deeply([$t3->GetHistory], [qw(b c)], 'history_max keeps the newest entries');

my $t4 = term();
$t4->addhistory($_) for qw(x x y x x);
is_deeply([$t4->GetHistory], [qw(x y x)], 'a repeat of the previous entry is not added');

my $t5 = term();
$t5->addhistory($_) for qw(1 2 3 4);
$t5->Attribs->{history_max} = 3;
is_deeply([$t5->GetHistory], [qw(2 3 4)], 'lowering history_max trims old entries');

# WriteHistory replaces the file whole: it writes a new file beside it and
# renames it over the old one, so a write cut short never leaves half a
# history behind
{
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $h = "$dir/hist";
    my $t6 = term();
    $t6->addhistory('old');
    ok($t6->WriteHistory($h), 'first write');
    SKIP: {
        skip 'no hard links', 2 unless link $h, "$dir/link";
        $t6->addhistory('new');
        ok($t6->WriteHistory($h), 'second write');
        open my $l, '<', "$dir/link" or die;
        is(do { local $/; <$l> }, "old\n", 'the old file was replaced, not rewritten in place');
    }
    opendir my $dh, $dir or die;
    is_deeply([sort grep { !/\A\./ } readdir $dh], [qw(hist link)], 'no temporary file is left');
    is((stat $h)[2] & 07777, 0600, 'the new file has mode 0600');
}

done_testing();
