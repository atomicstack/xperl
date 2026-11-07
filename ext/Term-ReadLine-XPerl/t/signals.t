#!./perl -w

BEGIN {
    require Config;
    if ($Config::Config{extensions} !~ m{\bTerm/ReadLine/XPerl\b}) {
        print "1..0 # skip: Term::ReadLine::XPerl was not built\n";
        exit 0;
    }
    if (!$Config::Config{i_termios} || !$Config::Config{d_fork}) {
        print "1..0 # skip: no termios or no fork\n";
        exit 0;
    }
}

use strict;
use Test::More;
use File::Temp qw(tempfile);
use POSIX ();
use Term::ReadLine::XPerl;

my ($outfh) = tempfile(UNLINK => 1);

sub ed {
    my $t = Term::ReadLine::XPerl->new(q(t), \*STDIN, $outfh);
    $t->_test_mode(80, 24);
    return $t;
}

# while the editor holds the terminal in raw mode, a fatal signal left at
# its default action would end the process with the terminal still raw:
# the editor traps those signals for that time only
# signals still at their default action here (one may be ignored)
my $default = grep { !defined $SIG{$_} || $SIG{$_} eq 'DEFAULT' } qw(TERM HUP QUIT ALRM);
my @during;
my $t = ed();
$t->Attribs->{completion_function} = sub {
    push @during, $t->_signals_trapped;
    return ([], 0);
};
$t->_feed_keys("a\t\r");
is($t->readline(q(> )), 'a', 'readline with a completion');
is_deeply(\@during, [$default], 'TERM, HUP, QUIT and ALRM are trapped while raw');
is($t->_signals_trapped, 0, 'and released afterwards');

{
    local $SIG{ALRM} = sub { };
    @during = ();
    $t->_feed_keys("a\t\r");
    $t->readline(q(> ));
    is_deeply(\@during, [$default - 1], 'a signal with a perl handler is left alone');
}

@during = ();
my $b = ed();
$b->Attribs->{key_bindings} = {
    "\x18" => sub { push @during, $b->_signals_trapped; return { buffer => 'x' } },
};
$b->_feed_keys("\x18\r");
is($b->readline(q(> )), 'x', 'readline with a binding');
is_deeply(\@during, [0], 'not trapped while a binding runs out of raw mode');
is($b->_signals_trapped, 0, 'and none left over');

# the trap restores the terminal and then dies of the signal as before
for my $sig (qw(TERM ALRM)) {
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        my $c = ed();
        $c->Attribs->{completion_function} = sub {
            $sig eq 'ALRM' ? alarm 1 : kill $sig => $$;
            sleep 3;
            print STDERR "survived\n";
            return ([], 0);
        };
        $c->_feed_keys("a\t\r");
        $c->readline(q(> ));
        POSIX::_exit(0);
    }
    waitpid $pid, 0;
    is($? & 127, POSIX->can("SIG$sig")->(), "SIG$sig still ends the process");
}

done_testing;
