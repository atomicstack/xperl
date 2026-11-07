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


my $t = ed();
my @args;
$t->Attribs->{key_bindings} = {
    "\x18\x05" => sub { @args = @_; return { buffer => 'edited', cursor => 6 } },
};
is(type($t, "a\x18\x05\r"), 'edited', 'binding returning buffer and cursor replaces the line');
is_deeply(\@args, ['a', 1], 'binding receives buffer and cursor');
ok(!$t->last_submit_forced, 'plain enter is not forced');

$t = ed();
$t->Attribs->{key_bindings} = {
    "\x18\x05" => sub { return { buffer => 'abc', cursor => 1 } },
};
is(type($t, "\x18\x05X\r"), 'aXbc', 'the returned cursor is used');

$t = ed();
$t->Attribs->{key_bindings} = {
    "\x18\x05" => sub { return { submit => 'done', force => 1 } },
};
is(type($t, "zz\x18\x05"), 'done', 'binding can submit');
ok($t->last_submit_forced, 'with force');

$t = ed();
$t->Attribs->{key_bindings} = {
    "\x18\x05" => sub { return { submit => 'soft', force => 0 } },
};
is(type($t, "\x18\x05"), 'soft', 'binding can submit without force');
ok(!$t->last_submit_forced, 'force => 0 is not forced');

$t = ed();
$t->Attribs->{key_bindings} = { "\x18\x05" => sub { return } };
is(type($t, "ab\x18\x05c\r"), 'abc', 'binding returning undef changes nothing');

$t = ed();
$t->Attribs->{key_bindings} = { "\ex" => sub { return { submit => 'meta' } } };
is(type($t, "\ex"), 'meta', 'escape-prefixed (meta) byte sequences can be bound');

$t = ed();
$t->Attribs->{key_bindings} = { 'C-x' => sub { return { submit => 'named' } } };
is(type($t, "C-x"), 'named', 'keys are byte sequences: C-x is three literal bytes');
$t = ed();
$t->Attribs->{key_bindings} = { 'C-x' => sub { return { submit => 'named' } } };
is(type($t, "\x18\r"), '', 'and is not ctrl-x');

$t = ed();
$t->Attribs->{key_bindings} = { "\x18\x05" => sub { return [ edit => 'spec', 4 ] } };
$t->_feed_keys("\x18\x05");
ok(!eval { $t->readline('> '); 1 }, 'array ref results are not accepted');
like($@, qr/key binding/, 'they die naming the key binding');
ok(!$t->_raw_active, 'raw mode is off after the bad result');

# wide characters on an IN handle without a :utf8 layer are sent as UTF-8
$t = ed();
$t->Attribs->{key_bindings} = { "\x18" => sub { return { submit => "\x{3bb}" } } };
is(type($t, "\x18"), "\xce\xbb", 'a submitted wide character comes back as UTF-8 bytes');
ok(!$t->_raw_active, 'raw mode is off');
$t = ed();
$t->Attribs->{key_bindings} = { "\x18" => sub { return { buffer => "\x{3bb}\x{3bc}", cursor => 1 } } };
is(type($t, "\x18X\r"), "\xce\xbbX\xce\xbc", 'an edit with wide characters keeps a character cursor');
ok(!$t->_raw_active, 'raw mode is off');

{
    package My::FalseError;
    use overload 'bool' => sub { 0 }, '""' => sub { 'false error' }, fallback => 1;
    sub new { bless {}, $_[0] }
}
$t = ed();
$t->Attribs->{key_bindings} = { "\x18" => sub { die My::FalseError->new } };
$t->_feed_keys("\x18");
ok(!eval { $t->readline('> '); 1 }, 'an exception object that is false still propagates');
is(ref $@, 'My::FalseError', 'unchanged');
ok(!$t->_raw_active, 'raw mode is off');

$t = ed();
$t->Attribs->{key_bindings} = { "\x18\x05" => sub { return { buffer => 'b' } } };
is(type($t, "\x18q\r"), 'q', 'a partial binding prefix falls back to normal keys');
is(type($t, "\x18\x05\r"), 'b', 'and the binding still works afterwards');

$t = ed();
$t->Attribs->{key_bindings} = { "\x18\x05" => sub { return { buffer => 'b' } } };
is(type($t, "x\e[D\x18\e[CY\r"), 'xY', 'an escape sequence after a partial prefix is still parsed');

$t = ed();
is(type($t, "abc\e\r"), 'abc', 'alt-enter submits');
ok($t->last_submit_forced, 'alt-enter is forced');
$t = ed();
is(type($t, "abc\n"), 'abc', 'ctrl-j submits');
ok($t->last_submit_forced, 'ctrl-j is forced');
$t = ed();
is(type($t, "abc\r"), 'abc', 'enter submits');
ok(!$t->last_submit_forced, 'enter is not forced');

$t = ed();
my $raw_in_cb;
$t->Attribs->{key_bindings} = {
    "\x18\x05" => sub { $raw_in_cb = $t->_raw_active; die "oops\n" },
};
$t->_feed_keys("a\x18\x05");
ok(!eval { $t->readline('> '); 1 }, 'a dying binding propagates out of readline');
is($@, "oops\n", 'with its exception');
ok(!$raw_in_cb, 'bindings run outside raw mode');
ok(!$t->_raw_active, 'raw mode is off after the exception');
$t->_feed_keys("again\r");
is($t->readline('> '), 'again', 'the editor works after a dying binding');

{
    package My::Error;
    sub new { bless { msg => $_[1] }, $_[0] }
}
$t = ed();
$t->Attribs->{key_bindings} = { "\x18\x05" => sub { die My::Error->new('obj') } };
$t->_feed_keys("\x18\x05");
eval { $t->readline('> ') };
is(ref $@, 'My::Error', 'exception objects propagate unchanged');

$t = ed();
$t->Attribs->{key_bindings} = { "\x18\x05" => sub { return 42 } };
$t->_feed_keys("\x18\x05");
ok(!eval { $t->readline('> '); 1 }, 'a malformed binding result dies');
like($@, qr/key binding/, 'naming the key binding');

done_testing();
