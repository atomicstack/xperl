use strict;
use warnings;
no warnings 'once';
use Test::More;

sub tap_info { print '# ', @_, "\n" }

plan tests => 3;

ok( eval { require IO::Socket::SSL },"loaded");

tap_info( sprintf( "openssl version compiled=0x%0x linked=0x%0x -- %s",
    Net::SSLeay::OPENSSL_VERSION_NUMBER(),
    Net::SSLeay::SSLeay(),
    Net::SSLeay::SSLeay_version(0)));

tap_info( sprintf( "Net::SSLeay version=%s", $Net::SSLeay::VERSION));
tap_info( sprintf( "parent %s version=%s", $_, $_->VERSION))
    for (@IO::Socket::SSL::ISA);

IO::Socket::SSL->import(':debug1');
is( $IO::Socket::SSL::DEBUG,1, "IO::Socket::SSL::DEBUG 1");
is( $Net::SSLeay::trace,1, "Net::SSLeay::trace 1");

