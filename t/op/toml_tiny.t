use strict;
use warnings;
use Test::More;
use TOML::Tiny;

my $config = TOML::Tiny->new(strict => 1)->decode(<<'TOML');
schema = 1
issued = 2026-11-06T12:00:00Z

[install]
prefix = "/opt/xperl"

[agents.claude]
command = "/opt/bin/claude-wrapper"
attempts = 2
TOML

is($config->{schema}, 1, 'integer value is parsed');
is($config->{issued}, '2026-11-06T12:00:00Z',
   'date-time remains a string by default');
is($config->{install}{prefix}, '/opt/xperl', 'table is parsed');
is($config->{agents}{claude}{attempts}, 2, 'nested table is parsed');
ok(!exists $INC{'DateTime/Format/ISO8601.pm'},
   'parsing does not load DateTime::Format::ISO8601');
ok(!exists $INC{'DateTime/Format/RFC3339.pm'},
   'parsing does not load DateTime::Format::RFC3339');

my $error = eval { TOML::Tiny->new(strict => 1)->decode("broken = [1,,2]\n"); 1 };
ok(!$error, 'invalid TOML is rejected');
like($@, qr/line|unexpected|expected/i, 'invalid TOML reports an error');

done_testing();
