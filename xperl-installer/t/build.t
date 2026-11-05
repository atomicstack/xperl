use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;
use XPerl::Installer::Build;
use XPerl::Installer::Fetch;

my $root = tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $prefix = File::Spec->catdir($root, 'prefix');
my $modules = File::Spec->catdir($mirror, 'modules');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path($modules, $releases);

my $index = <<'INDEX';
File: 02packages.details.txt

Example::Tiny 1.00 E/EX/EXAMPLE/Example-Tiny-1.00.tar.gz
Example::Broken 1.00 E/EX/EXAMPLE/Example-Broken-1.00.tar.gz
INDEX
gzip \$index => File::Spec->catfile($modules, '02packages.details.txt.gz')
    or die $GzipError;

my $tar = Archive::Tar->new;
$tar->add_data('Example-Tiny-1.00/Makefile.PL', <<'MAKEFILE');
use ExtUtils::MakeMaker;
WriteMakefile(NAME => 'Example::Tiny', VERSION => '1.00');
MAKEFILE
$tar->add_data('Example-Tiny-1.00/lib/Example/Tiny.pm', <<'MODULE');
package Example::Tiny;
our $VERSION = '1.00';
sub answer { 42 }
1;
MODULE
$tar->add_data('Example-Tiny-1.00/t/basic.t', <<'TEST');
use Test::More tests => 1;
use Example::Tiny;
is(Example::Tiny::answer(), 42, 'module works');
TEST
$tar->write(File::Spec->catfile($releases, 'Example-Tiny-1.00.tar.gz'), 1);

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, 'Example::Tiny' or die $!;
my $output = do { local $/; <$pipe> };
ok(close $pipe, 'installer completed');
my $result = eval { JSON::PP->new->decode($output) };
ok($result && $result->{status} eq 'installed', 'receipt reports installation');
my $receipt_path = $result->{receipts}[0];
open my $receipt_file, '<', $receipt_path or die $!;
my $receipt = JSON::PP->new->decode(do { local $/; <$receipt_file> });
is_deeply([map { $_->{name} } @{$receipt->{phases}}],
          [qw(configure build test install)], 'all build phases ran');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Tiny.pm)),
   'module installed into the selected prefix');
ok(-f $receipt_path, 'receipt written');

my $broken = Archive::Tar->new;
$broken->add_data('Example-Broken-1.00/Makefile.PL', <<'MAKEFILE');
use ExtUtils::MakeMaker;
WriteMakefile(NAME => 'Example::Broken', VERSION => '1.00');
MAKEFILE
$broken->add_data('Example-Broken-1.00/lib/Example/Broken.pm', <<'MODULE');
package Example::Broken;
our $VERSION = '1.00';
1;
MODULE
$broken->add_data('Example-Broken-1.00/t/basic.t', <<'TEST');
use Test::More tests => 1;
fail('test failure blocks installation');
TEST
$broken->write(File::Spec->catfile($releases, 'Example-Broken-1.00.tar.gz'), 1);
my $fetcher = XPerl::Installer::Fetch->new(mirror => $mirror, cache => $cache);
my $bad_release = $fetcher->fetch('Example::Broken');
my $bad_prefix = File::Spec->catdir($root, 'bad-prefix');
my $builder = XPerl::Installer::Build->new(prefix => $bad_prefix,
    workdir => File::Spec->catdir($root, 'bad-work'));
eval { $builder->install($bad_release) };
like($@, qr/test failed/, 'failed tests stop the installation');
ok(!-f File::Spec->catfile($bad_prefix, qw(lib perl5 Example Broken.pm)),
   'failed distribution is not installed');

done_testing();
