#!perl

BEGIN {
    chdir 't' if -d 't';
    require '../../../t/test.pl';
    set_up_inc('../../../lib');
}

use strict;
use warnings;
use XS::APItest;

sub packed_key {
    my ($hex) = @_;
    return unpack( 'Q>', pack( 'H*', $hex ) );
}

my @wide_keys = (
    [ 255,   packed_key('00ff000000000001'), 'any_wide_n1' ],
    [ 256,   packed_key('0100000000000001'), 'wide_256_n1' ],
    [ 257,   packed_key('0101000000000001'), 'wide_257_n1' ],
    [ 511,   packed_key('01ff000000000001'), 'wide_511_n1' ],
    [ 512,   packed_key('0200000000000001'), 'wide_512_n1' ],
    [ 65535, packed_key('ffff000000000001'), 'wide_65535_n1' ],
);

for my $fixture ( 0 .. 2 ) {
    for my $case (@wide_keys) {
        is( XS::APItest::diag_template_match_fixture( $fixture, $case->[1], 0 ),
            $case->[2], "wide selector metadata position $fixture matches ID $case->[0]" );
    }
}

is( XS::APItest::diag_template_match_fixture( 0, packed_key('0100000000000002'), 0 ),
    'wide_256_n2', 'full packed key distinguishes narrow values beside a wide field' );
is( XS::APItest::diag_template_match_fixture( 0, packed_key('0101000000000001'), 0 ),
    'wide_257_n1', 'exact U16 value 0x0100 does not match 0x0101' );
is( XS::APItest::diag_template_match_fixture( 0, packed_key('0100000000000000'), 0 ),
    'wide_256_any_narrow', 'zero narrow field matches a whole-field wildcard' );
is( XS::APItest::diag_template_match_fixture( 0, packed_key('0100000000000001'), 0x02 ),
    undef, 'an invalid selector column rejects otherwise matching cases' );

is( XS::APItest::diag_template_match_fixture( 3, packed_key('ffff000000000001'), 0 ),
    'wide_65535_n1', 'six narrow selectors fit beside the U16 field without aliasing it' );
is( XS::APItest::diag_template_match_fixture( 3, packed_key('0000010000000000'), 0 ),
    'n6_only', 'the sixth narrow selector occupies the last byte beside the U16 field' );
is( XS::APItest::diag_template_match_fixture( 4, packed_key('0001000000000000'), 0 ),
    'n7_only', 'seven narrow selectors use all seven U8 positions' );
is( XS::APItest::diag_template_match_fixture( 4, 1, 0 ),
    'n1_only', 'the first narrow selector remains the least significant byte' );

my $last_value = XS::APItest::diag_selector_fixture( 'wide_65535', 65535 );
is( $last_value->[0], 65535,        'the largest U16 domain ID converts without overflow' );
is( $last_value->[1], 'wide_65535', 'the final U16 domain ID converts back to its name' );
is( XS::APItest::diag_selector_fixture( 'wide_00256', 256 )->[0], 256, 'ID 256 converts through the generated domain' );
is( XS::APItest::diag_selector_fixture( 'unknown', 65536 )->[0], -1, 'unknown text and out-of-range IDs are rejected' );
is( XS::APItest::diag_selector_fixture( '*', 0 )->[0],           0,  'selector wildcard zero round trips' );

my $large_key  = packed_key('ffff000000000001');
my $diagnostic = bless {
    code         => 'WIDE_SELECTOR_FIXTURE',
    number       => 990001,
    kind         => 'CORE_RUNTIME',
    severity     => 'WARNING',
    selector_key => $large_key,
    params       => [],
    location     => { file => 'diag-template-match.t', line => 1 },
  },
  'XPerl::Diagnostic';
my $json = $diagnostic->as_json;
like( $json, qr/"selector_key":18446462598732840961/, 'JSON emits a wide packed selector key without truncation' );
require JSON::PP;
my $decoded = JSON::PP::decode_json($json);
is( "$decoded->{selector_key}", '18446462598732840961', 'the serialized U64 selector key round trips through JSON' );

done_testing();
