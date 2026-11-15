use Test::More;

use YAML::XS ();

my $libyaml_version = YAML::XS::LibYAML::libyaml_version();
note "libyaml version = $libyaml_version";
cmp_ok($libyaml_version, '=~', qr{^\d+\.\d+(?:\.\d+)$}, "libyaml_version ($libyaml_version)");

done_testing;
