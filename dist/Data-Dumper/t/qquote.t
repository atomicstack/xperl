#!./perl -w
# t/qquote.t - Test qquote()

use strict;
use warnings;

use Test::More tests => 25;
use Data::Dumper;

{
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning = $_[0] };

    my $str = Data::Dumper::qquote("");
    is($str,   q{""}, q{qquote("") returned ""});
    is($warning, "",  q{qquote("") did not warn});
}

{
    my $bytes = "\xE9";
    my $chars = "\N{U+E9}";

    is(Data::Dumper::qquote($bytes), '"\\x{e9}"',
       'byte strings use a hexadecimal byte escape');
    is(Data::Dumper::qquote($chars), '"\\x{e9}"',
       'UTF-8 strings keep the traditional hexadecimal escape by default');
    is(Data::Dumper::qquote($chars, 0, 0, 1), '"\\N{U+E9}"',
       'PreserveUnicode uses a Unicode code point escape');
    is(Data::Dumper::qquote($chars, 0, 0, 'name'),
       '"\\N{LATIN SMALL LETTER E WITH ACUTE}"',
       'PreserveUnicode name uses a Unicode character name escape');

    my $roundtrip_bytes = eval Data::Dumper::qquote($bytes);
    my $roundtrip_chars = eval Data::Dumper::qquote($chars);

    is($roundtrip_bytes, $bytes, 'byte string value round trips');
    ok(!utf8::is_utf8($roundtrip_bytes), 'byte string remains unflagged');
    is($roundtrip_chars, $chars, 'character string value round trips');
    ok(!utf8::is_utf8($roundtrip_chars),
       'traditional hexadecimal escape does not preserve the UTF-8 flag');
    ok(utf8::is_utf8(eval Data::Dumper::qquote($chars, 0, 0, 1)),
       'PreserveUnicode retains the UTF-8 flag');
}

{
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning = $_[0] };

    my $str = Data::Dumper::qquote();
    is($str,   q{""}, q{qquote() returned ""});
    is($warning, "",  q{qquote() did not warn});
}

{
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning = $_[0] };

    my $str = Data::Dumper::qquote(undef);
    is($str,   q{""}, q{qquote(undef) returned ""});
    is($warning, "",  q{qquote(undef) did not warn});
}

{
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning = $_[0] };

    my $str = Data::Dumper::qquote("simple");
    is($str,   q{"simple"}, q{qquote("simple") returned "simple"});
    is($warning, "",        q{qquote("simple") did not warn});
}

{
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning = $_[0] };

    my $str = Data::Dumper::qquote(q{check 'single' quote});
    is($str,   q{"check 'single' quote"}, q{qquote('single') returned correctly});
    is($warning, "", q{qquote('single') did not warn});
}

{
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning = $_[0] };

    my $str = Data::Dumper::qquote(q{check "double" quote});
    is($str,     q{"check \"double\" quote"}, q{qquote("double") returned correctly});
    is($warning, "", 'qquote(undef) did not warn');
}

{
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning = $_[0] };

    my $str = Data::Dumper::qquote(qq{check \a quote});
    is($str,     q{"check \a quote"}, q{qquote("\a") returned correctly});
    is($warning, "", 'qquote(undef) did not warn');
}

SKIP: {
    skip "ASCII-centric test", 2, unless ord "A" == 65;
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning = $_[0] };

    my $str = Data::Dumper::qquote(qq{check \cg quote});
    is($str,     q{"check \a quote"}, q{qquote("\cg") returned correctly});
    is($warning, "", 'qquote(undef) did not warn');
}
