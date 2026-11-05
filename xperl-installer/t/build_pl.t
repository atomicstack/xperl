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

Example::Built 1.00 E/EX/EXAMPLE/Example-Built-1.00.tar.gz
Example::Failing 1.00 E/EX/EXAMPLE/Example-Failing-1.00.tar.gz
INDEX
gzip \$index => File::Spec->catfile($modules, '02packages.details.txt.gz')
    or die $GzipError;

for my $name (qw(Built Failing)) {
    my $dist = "Example-$name-1.00";
    my $tar = Archive::Tar->new;
    my $build_pl = <<'BUILD_PL';
use strict;
use warnings;
my ($flag, $prefix) = @ARGV;
die "missing install base\n" unless $flag eq '--install_base' && $prefix;
open my $out, '>', 'Build' or die $!;
print {$out} <<'BUILD';
use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Spec;
use Test::Harness;
use Config;
my ($command, $prefix) = ($ARGV[0] // 'build', '__PREFIX__');
if ($command eq 'test') {
    $ENV{PERL5LIB} = join($Config{path_sep}, 'lib', $ENV{PERL5LIB} // '');
    runtests('t/basic.t');
}
elsif ($command eq 'install') {
    my $target = File::Spec->catdir($prefix, qw(lib perl5 Example));
    make_path($target);
    copy('lib/Example/__MODULE__.pm',
         File::Spec->catfile($target, '__MODULE__.pm')) or die $!;
}
elsif ($command ne 'build') { die "unknown command $command\n" }
BUILD
close $out or die $!;
open my $in, '<', 'Build' or die $!;
my $body = do { local $/; <$in> };
close $in;
$body =~ s/__PREFIX__/$prefix/g;
open $out, '>', 'Build' or die $!;
print {$out} $body;
close $out or die $!;
BUILD_PL
    $build_pl =~ s/__MODULE__/$name/g;
    $tar->add_data("$dist/Build.PL", $build_pl);
    my $module = "package Example::$name;\nour \$VERSION = '1.00';\n1;\n";
    $tar->add_data("$dist/lib/Example/$name.pm", $module);
    my $test = $name eq 'Built'
        ? "use Test::More tests => 1; use Example::Built; pass('works');\n"
        : "use Test::More tests => 1; fail('blocks install');\n";
    $tar->add_data("$dist/t/basic.t", $test);
    my $meta = {
        'meta-spec' => { version => 2 },
        name => "Example-$name", version => '1.00',
        abstract => 'Local Build.PL installer test', author => ['XPerl'],
        generated_by => 'XPerl installer test', release_status => 'stable',
        license => ['perl_5'], dynamic_config => JSON::PP::false,
        prereqs => {},
    };
    $tar->add_data("$dist/META.json", JSON::PP->new->encode($meta));
    $tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
}

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, 'Example::Built' or die $!;
my $output = do { local $/; <$pipe> };
ok(close $pipe, 'Build.PL installation completed');
my $result = eval { JSON::PP->new->decode($output) };
ok($result && $result->{status} eq 'installed', 'installation succeeded');
my $receipt_path = $result->{receipts}[0];
open my $receipt_file, '<', $receipt_path or die $!;
my $receipt = JSON::PP->new->decode(do { local $/; <$receipt_file> });
is($receipt->{build_system}, 'Build.PL', 'receipt identifies build system');
is_deeply([map { $_->{name} } @{$receipt->{phases}}],
          [qw(configure build test install)], 'all Build.PL phases ran');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Built.pm)),
   'module installed into the selected prefix');

open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, 'Example::Failing' or die $!;
my $failure = do { local $/; <$pipe> };
ok(!close $pipe, 'failed Build.PL tests stop installation');
ok(!-f File::Spec->catfile($prefix, qw(lib perl5 Example Failing.pm)),
   'failed module is not installed');

done_testing();
