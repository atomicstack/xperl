use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;
use XPerl::Installer::Registry;

my $root = tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $dist = File::Spec->catdir($root, qw(distributions Example-Tiny));
my $patch_dir = File::Spec->catdir($dist, 'patches');
make_path($patch_dir);
my $patch_path = File::Spec->catfile($patch_dir, 'fix.patch');
my $patch_text = "--- a/test\n+++ b/test\n";
open my $patch, '>:raw', $patch_path or die $!;
print {$patch} $patch_text;
close $patch or die $!;
my $patch_sha = sha256_hex($patch_text);
my $source_sha = 'a' x 64;
my $index = {
    schema => 1,
    distribution => 'Example-Tiny',
    releases => [{
        version => '1.00',
        cpan_path => 'E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz',
        source_sha256 => $source_sha,
        patch_sets => [{
            id => 'fix',
            xperl => {
                min_inclusive => "$^V",
                max_exclusive => 'v99.0.0',
            },
            patches => [{
                path => 'patches/fix.patch',
                sha256 => $patch_sha,
            }],
            recipes => [],
        }],
    }],
};
open my $index_file, '>', File::Spec->catfile($dist, 'index.json')
    or die $!;
print {$index_file} JSON::PP->new->canonical->encode($index);
close $index_file or die $!;

my $release = {
    distribution => 'Example-Tiny',
    distribution_version => '1.00',
    cpan_path => 'E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz',
    sha256 => $source_sha,
};
my $registry = XPerl::Installer::Registry->new(path => $root);
my $selection = $registry->patches_for($release);
is($selection->{patch_set}, 'fix', 'selects the matching patch set');
is($selection->{patches}[0]{sha256}, $patch_sha,
   'checks and reports the patch digest');
eval { $registry->patches_for({ %$release, sha256 => 'b' x 64 }) };
like($@, qr/source digest mismatch/, 'rejects a different source archive');
open $patch, '>>', $patch_path or die $!;
print {$patch} "tampered\n";
close $patch or die $!;
eval { $registry->patches_for($release) };
like($@, qr/patch digest mismatch/, 'rejects a modified patch');

done_testing();
