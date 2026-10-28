#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;

sub encoded_layers {
    my ( $text, $layers ) = @_;
    utf8::encode($text) for 1 .. $layers;
    return $text;
}

for my $text ( '', 'plain ASCII', "a\0b", "\N{U+E9}", "\N{U+100}",
    "\N{U+1F642}", "a\0\N{U+E9}\N{U+100}" )
{
    for my $layers ( 0 .. 4 ) {
        for my $force ( 0, 1 ) {
            my $value    = encoded_layers( $text, $layers );
            my $returned = utf8::repeat_decode( $value, $force );
            my $label    = "layers=$layers force=$force";

            is( $value,    $text, "decodes the argument ($label)" );
            is( $returned, $text, "returns the decoded string ($label)" );
            ok( utf8::valid($value),   "result has a valid representation ($label)" );
            ok( utf8::is_utf8($value), "force sets the UTF-8 flag ($label)" ) if $force;
        }
    }
}

{
    my $value  = encoded_layers( "\N{U+E9}", 3 );
    my $shared = $value;
    utf8::repeat_decode( $value, 1 );
    is( $value,  "\N{U+E9}",                      'decodes a shared string' );
    is( $shared, encoded_layers( "\N{U+E9}", 3 ), 'leaves the other buffer owner unchanged' );
}

{
    my $invalid = encoded_layers( "\N{U+E9}", 1 );
    chop $invalid;
    my $value = $invalid;
    utf8::repeat_decode($value);
    is( $value, $invalid, 'invalid UTF-8 stops decoding without changing the bytes' );
    ok( !utf8::is_utf8($value), 'invalid bytes stay unflagged without force' );

    my $expected = $invalid;
    utf8::upgrade($expected);
    utf8::repeat_decode( $value, 1 );
    is( $value, $expected, 'force upgrades undecodable native bytes' );
    ok( utf8::is_utf8($value), 'force flags undecodable bytes as UTF-8' );
}

{
    my $value = "\N{U+E9}";
    utf8::repeat_decode($value);
    is( $value, "\N{U+E9}", 'already decoded native-range text retains its characters' );
    ok( !utf8::is_utf8($value), 'native-range text ends in bytes without force' );

    $value = 12345;
    is( utf8::repeat_decode($value), '12345', 'numeric input is stringified' );
}

{

    package RepeatDecodeTie;
    sub TIESCALAR { bless { value => $_[1], fetches => 0, stores => 0 }, $_[0] }
    sub FETCH     { $_[0]{fetches}++; $_[0]{value} }
    sub STORE     { $_[0]{stores}++;  $_[0]{value} = $_[1] }
}

{
    tie my $value, 'RepeatDecodeTie', encoded_layers( "\N{U+E9}", 3 );
    my $state    = tied $value;
    my $returned = utf8::repeat_decode( $value, 1 );
    is( $state->{fetches}, 1, 'tied input is fetched once, including return-value consumption' );
    is( $state->{stores},  1, 'tied result is stored once' );
    is( $state->{value},   "\N{U+E9}", 'STORE receives the fully decoded value' );
    ok( utf8::is_utf8( $state->{value} ), 'STORE receives the requested UTF-8 representation' );
    is( $returned,         "\N{U+E9}", 'tied input returns a plain decoded value' );
    is( $state->{fetches}, 1,          'reading the returned value does not FETCH again' );
}

{

    package RepeatDecodeObject;
    use overload '""' => sub { $_[0]{calls}++; $_[0]{value} }, fallback => 1;
}

{
    my $object = bless { calls => 0, value => encoded_layers( "\N{U+E9}", 3 ) },
      'RepeatDecodeObject';
    my $value = $object;
    is( utf8::repeat_decode( $value, 1 ), "\N{U+E9}", 'overloaded input returns decoded text' );
    is( $object->{calls},                 1,          'overloaded input is stringified once' );
    is( ref($value), '',         'stringification replaces the argument reference' );
    is( $value,      "\N{U+E9}", 'overloaded argument is changed in place' );
}

{
    my $value = encoded_layers( "\N{U+E9}", 2 );
    utf8::decode($value);
    my $old_length = length($value);
    utf8::repeat_decode( $value, 1 );
    is( length($value), 1, 'decoding invalidates cached character lengths' );
}

for my $call ( sub { utf8::repeat_decode() }, sub { utf8::repeat_decode( 'x', 0, 0 ) } ) {
    eval { $call->() };
    like( $@, qr/Usage: utf8::repeat_decode/, 'wrong argument counts report usage' );
}

{
    eval { utf8::repeat_decode('read-only') };
    like( $@, qr/Modification of a read-only value/, 'read-only arguments are rejected' );
}

done_testing();
