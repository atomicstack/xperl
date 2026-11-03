#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc(qw(. ../lib));
}

use strict;
use warnings;
use builtin qw(siphash siphash_1_3 siphash_2_4);
no warnings 'experimental::builtin';

my $key = pack 'H*', '000102030405060708090a0b0c0d0e0f';

is(unpack('H*', siphash_2_4('')), '310e0edd47db6f72',
   'SipHash-2-4 empty vector');
is(unpack('H*', siphash_1_3('')), 'dcc40f055801acab',
   'SipHash-1-3 empty vector');
is(unpack('H*', siphash_2_4("\0")), 'fd67dc93c539f874',
   'SipHash-2-4 one-byte vector');
is(unpack('H*', siphash_1_3("\0")), '93ca577df39bf4c9',
   'SipHash-1-3 one-byte vector');

for my $message ('', "\0", "abcdefghijklmno", "a\0b" x 7) {
    is(siphash(2, 4, $message), siphash_2_4($message),
       'configurable rounds match SipHash-2-4');
    is(siphash(1, 3, $message, $key), siphash_1_3($message, $key),
       'configurable rounds match SipHash-1-3');
}

is(siphash_2_4('abc', $key), siphash_2_4('abc'),
   'explicit canonical key matches the default');
is(siphash(0, 0, ''), siphash(0, 0, '', $key),
   'zero rounds are accepted');
isnt(siphash_2_4('abc', "\0" x 16), siphash_2_4('abc'),
     'an explicit key changes the hash');

for my $bad ('', '1.5', '-1', '1e1', '18446744073709551616', undef, []) {
    eval { siphash($bad, 4, 'abc') };
    like($@, qr/SipHash round count/, 'invalid compression count is rejected');
    eval { siphash(2, $bad, 'abc') };
    like($@, qr/SipHash round count/, 'invalid finalization count is rejected');
}

for my $bad ('', 'short', 'x' x 17, undef, []) {
    eval { siphash_2_4('abc', $bad) };
    like($@, qr/SipHash seed must be exactly 16 bytes/,
         'invalid key is rejected');
}

eval { siphash_2_4("\x{100}") };
like($@, qr/Wide character/, 'wide-character input is rejected');

eval { siphash_2_4() };
like($@, qr/Usage:/, 'missing input is rejected');

done_testing();
