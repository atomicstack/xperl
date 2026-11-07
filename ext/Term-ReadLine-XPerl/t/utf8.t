#!./perl -w

BEGIN {
    require Config;
    if ($Config::Config{extensions} !~ m{\bTerm/ReadLine/XPerl\b}) {
        print "1..0 # skip: Term::ReadLine::XPerl was not built\n";
        exit 0;
    }
}

# no "use utf8": the literals below are UTF-8 byte strings, which is what
# readline returns when IN has no :utf8 layer
use strict;
use Test::More;
use File::Temp qw(tempfile);
use Term::ReadLine::XPerl;

sub ed {
    my ($cols, $in) = @_;
    my ($fh, $file) = tempfile(UNLINK => 1);
    my $t = Term::ReadLine::XPerl->new('t', $in // \*STDIN, $fh);
    $t->_test_mode($cols // 80, 24);
    return ($t, $file);
}

sub type {
    my ($keys, $prompt, $cols) = @_;
    my ($t, $file) = ed($cols);
    $t->_feed_keys($keys);
    my $line = $t->readline($prompt // '> ');
    return wantarray ? ($line, slurp($file)) : $line;
}

sub slurp {
    open my $fh, '<', $_[0] or die "$_[0]: $!";
    local $/;
    return scalar <$fh>;
}

is(type("λx\x7f\r"), 'λ', 'backspace after an ASCII character');
is(type("λ\x7f\r"), '', 'backspace deletes a whole two-byte character');
is(type("😀\x7f\r"), '', 'backspace deletes a whole four-byte character');
is(type("日本\e[D語\r"), '日語本', 'left moves over a whole wide character');
is(type("日a\x01\e[CX\r"), '日Xa', 'right moves past a whole wide character');
is(type("aλb\x01\e[C\e[3~\r"), 'ab', 'delete removes a whole character');
is(type("λμ ν\x17\r"), 'λμ ', 'ctrl-w with non-ASCII words');
is(type("λμ ν\x01\edX\r"), 'X ν', 'alt-d treats non-ASCII letters as word characters');
is(type("e\xcc\x81\x7f\r"), 'e', 'backspace removes a combining mark on its own');

{
    my (undef, $out) = type("日a\x01\e[C\r");
    like($out, qr/\r\e\[4C/, 'the cursor after a wide character is two columns on');
    (undef, $out) = type("e\xcc\x81x\e[D\r");
    like($out, qr/\r\e\[3C/, 'a combining mark takes no column');
    (undef, $out) = type("😀\x01\e[C\r");
    like($out, qr/\r\e\[4C/, 'an emoji takes two columns');
}

{
    # 5 columns: "> 日" fills four, so 本 cannot fit and wraps whole
    my ($line, $out) = type("日本\x01\r", '> ', 5);
    is($line, '日本', 'wide characters at the right margin');
    like($out, qr/> 日本\e\[1A\r\e\[2C/, 'a wide character that does not fit moves to the next row');
}

{
    # 5 columns: "> abc" fills the row; the combining mark stays on it
    my ($line, $out) = type("abc\xcc\x81\r", '> ', 5);
    is($line, "abc\xcc\x81", 'combining mark at the right margin');
    like($out, qr/> abc\xcc\x81\r\n\r\r\n\z/, 'a combining mark does not wrap to the next row');
}

{
    my ($line, $out) = type("ab\x01X\r", "\e[1m>\e[0m ");
    is($line, 'Xab', 'coloured prompt');
    like($out, qr/\e\[1m>\e\[0m ab\r\e\[2C/, 'SGR escapes in the prompt take no columns');
    unlike($out, qr/\e\[10C/, 'the escape bytes are not counted');
}

# fresh-line prompt: query the cursor column and start on a new row if
# the previous output left the cursor mid-line
{
    my ($t, $file) = ed();
    $t->Attribs->{test_cursor_query} = 1;
    $t->_feed_keys("\e[5;9R" . "ok\r");
    is($t->readline('> '), 'ok', 'cursor report is consumed, not inserted');
    like(slurp($file), qr/\A\e\[6n\r\n\r\e\[J> /, 'column 9: a newline comes before the prompt');

    ($t, $file) = ed();
    $t->Attribs->{test_cursor_query} = 1;
    $t->_feed_keys("\e[5;1R" . "ok\r");
    is($t->readline('> '), 'ok', 'column 1');
    like(slurp($file), qr/\A\e\[6n\r\e\[J> /, 'column 1: no newline before the prompt');

    ($t, $file) = ed();
    $t->Attribs->{test_cursor_query} = 1;
    $t->_feed_keys("ok\r");
    is($t->readline('> '), 'ok', 'typed-ahead keys without a report are kept');
    like(slurp($file), qr/\A\e\[6n\r\e\[J> /, 'no report: no newline');

    ($t, $file) = ed();
    $t->_feed_keys("ok\r");
    $t->readline('> ');
    unlike(slurp($file), qr/\e\[6n/, 'test mode does not query unless asked');

    # a terminal that never answers is asked only once
    ($t, $file) = ed();
    $t->Attribs->{test_cursor_query} = 1;
    is($t->readline('> '), undef, 'no reply and no keys');
    $t->_feed_keys("ok\r");
    is($t->readline('> '), 'ok', 'the next readline works');
    my $queries = () = slurp($file) =~ /\e\[6n/g;
    is($queries, 1, 'an unanswered query is not repeated');

    # a reply keeps the query on
    ($t, $file) = ed();
    $t->Attribs->{test_cursor_query} = 1;
    $t->_feed_keys("\e[5;1Ra\r\e[5;1Rb\r");
    $t->readline('> ') for 1, 2;
    $queries = () = slurp($file) =~ /\e\[6n/g;
    is($queries, 2, 'an answered query is repeated next time');
}

# a :utf8 IN handle gets characters back, and callbacks see characters
{
    my ($ifh, $ifile) = tempfile(UNLINK => 1);
    close $ifh;
    open my $in, '<:encoding(UTF-8)', $ifile or die;
    my ($t) = ed(80, $in);
    $t->_feed_keys("λa\r");
    my $line = $t->readline('> ');
    is(length $line, 2, 'readline decodes when IN has a :utf8 layer');
    is($line, "\x{3bb}a", 'to the expected characters');

    my @args;
    $t->Attribs->{completion_function} = sub {
        @args = @_;
        return (["\x{3bb}\x{3bc}"], 0);
    };
    $t->_feed_keys("λ\t\r");
    is($t->readline("\x{3bb}> "), "\x{3bb}\x{3bc}", 'completion with characters');
    is_deeply(\@args, ["\x{3bb}", 1], 'callback gets a character buffer and offset');

    $t->Attribs->{key_bindings} = {
        "\x18" => sub { @args = @_; return { buffer => "\x{3bd}\x{3be}", cursor => 1 } },
    };
    $t->_feed_keys("μλ\x02\x18X\r");
    is($t->readline('> '), "\x{3bd}X\x{3be}", 'binding edit with a character cursor');
    is_deeply(\@args, ["\x{3bc}\x{3bb}", 1], 'binding gets a character buffer and offset');

    $t->addhistory("\x{3c0}");
    is_deeply([$t->GetHistory], ["\x{3c0}"], 'history entries come back as characters');
}

done_testing();
