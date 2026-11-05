#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc(qw(. ../lib));
}

use strict;
use warnings;
use builtin qw(jumphash_integer jumphash_string);
no warnings 'experimental::builtin';

is(jumphash_integer(123, 1), 0, 'one bucket');
is(jumphash_integer(123, 12), 11, 'integer reference vector');
is(jumphash_integer(121233, 8), 5, 'second integer reference vector');
is(jumphash_integer('18446744073709551615', 257), 248,
   'full unsigned 64-bit key range');
is(jumphash_string('abc', 14), 12, 'string reference vector');
is(jumphash_string("a\0b", 257), 98, 'embedded NUL in string key');
is(jumphash_string('foobar', 14), 0, 'second string reference vector');
is(builtin::jumphash_integer(123, 12), 11, 'fully qualified integer call');
is(builtin::jumphash_string('abc', 14), 12, 'fully qualified string call');
is(prototype(\&builtin::jumphash_integer), '@', 'integer prototype');
is(prototype(\&builtin::jumphash_string), '@', 'string prototype');

for my $key (0, 1, 123, '18446744073709551615') {
    for my $buckets (1, 2, 8, 256) {
        my $before = jumphash_integer($key, $buckets);
        my $after = jumphash_integer($key, $buckets + 1);
        ok($after == $before || $after == $buckets,
           'adding a bucket only remaps to the new bucket');
    }
}

for my $bad ('', '-1', '1.5', '1e3', '18446744073709551616', undef, []) {
    eval { jumphash_integer($bad, 8) };
    like($@, qr/Jump hash key/, 'invalid integer key is rejected');
}

for my $bad ('', '0', '-1', '1.5', '2147483648', undef, []) {
    eval { jumphash_integer(1, $bad) };
    like($@, qr/Jump hash bucket count/, 'invalid bucket count is rejected');
}

eval { jumphash_string("\x{100}", 8) };
like($@, qr/Wide character/, 'wide character is not a byte string');
eval { jumphash_string(undef, 8) };
like($@, qr/byte string/, 'undefined string key is rejected');
eval { jumphash_string([], 8) };
like($@, qr/byte string/, 'reference string key is rejected');
eval { jumphash_integer(1) };
like($@, qr/Usage:/, 'integer argument count is checked');
eval { jumphash_string('abc') };
like($@, qr/Usage:/, 'string argument count is checked');

done_testing();
