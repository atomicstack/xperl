use strict;
use warnings;
use Test::More;
use Cpanel::JSON::XS;

{
    package Cpanel::JSON::XS::CompactHashGrow;
    our $owner;
    our $calls = 0;

    sub TO_JSON {
        my $hash = $owner;
        ++$calls;
        $hash->{a} = 'changed';
        delete $hash->{c};
        $hash->{c} = 'reinserted';
        $hash->{"added-$_"} = $_ for (1..1000);
        return { converted => 1 };
    }
}

my $owner = {
    a => 1,
    b => bless({}, 'Cpanel::JSON::XS::CompactHashGrow'),
    c => 3,
};
$Cpanel::JSON::XS::CompactHashGrow::owner = $owner;

my $json = Cpanel::JSON::XS->new->canonical->convert_blessed;
is($json->encode($owner), '{"a":1,"b":{"converted":1},"c":3}',
   'canonical encoding uses the original key and value snapshot');
is($Cpanel::JSON::XS::CompactHashGrow::calls, 1,
   'TO_JSON runs once');
is($owner->{a}, 'changed', 'TO_JSON changed an existing key');
is($owner->{c}, 'reinserted', 'TO_JSON deleted and reinserted a key');
is($owner->{'added-1000'}, 1000, 'TO_JSON grew the owner hash');
$Cpanel::JSON::XS::CompactHashGrow::owner = undef;
undef $owner;

my $ascii_json = Cpanel::JSON::XS->new->canonical->ascii;
is($ascii_json->encode({ "\x{1F600}" => 1, "\x{E000}" => 2 }),
   q|{"\ud83d\ude00":1,"\ue000":2}|,
   'canonical snapshot keeps UTF-16 key ordering');

{
    package Cpanel::JSON::XS::CompactHashCroak;
    our $owner;

    sub TO_JSON {
        my $hash = $owner;
        $hash->{"croak-grow-$_"} = $_ for (1..1000);
        die "TO_JSON stopped after growing owner\n";
    }
    package main;
}

my $croak_owner = {
    a => 1,
    b => bless({}, 'Cpanel::JSON::XS::CompactHashCroak'),
    c => 3,
};
$Cpanel::JSON::XS::CompactHashCroak::owner = $croak_owner;
my $ok = eval { $json->encode($croak_owner); 1 };
ok(!$ok, 'TO_JSON croaks during canonical encoding');
like($@, qr/TO_JSON stopped after growing owner/,
     'TO_JSON exception reaches caller');
$Cpanel::JSON::XS::CompactHashCroak::owner = undef;
undef $croak_owner;
is($json->encode({ after => 1 }), '{"after":1}',
   'encoder remains usable after snapshot cleanup on croak');

done_testing;
