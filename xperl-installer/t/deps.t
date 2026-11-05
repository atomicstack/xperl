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
use XPerl::Installer::Deps;

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

Example::Dependency 1.00 E/EX/EXAMPLE/Example-Dependency-1.00.tar.gz
Example::Application 1.00 E/EX/EXAMPLE/Example-Application-1.00.tar.gz
INDEX
gzip \$index => File::Spec->catfile($modules, '02packages.details.txt.gz')
    or die $GzipError;

for my $name (qw(Dependency Application)) {
    my $root_name = "Example-$name-1.00";
    my $tar = Archive::Tar->new;
    $tar->add_data("$root_name/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::$name', VERSION => '1.00');\n");
    my $body = $name eq 'Dependency'
        ? "package Example::Dependency;\nour \$VERSION = '1.00';\nsub value { 42 }\n1;\n"
        : "package Example::Application;\nour \$VERSION = '1.00';\nuse Example::Dependency;\nsub value { Example::Dependency::value() }\n1;\n";
    $tar->add_data("$root_name/lib/Example/$name.pm", $body);
    $tar->add_data("$root_name/t/basic.t",
        "use Test::More tests => 1; use Example::$name; is(Example::${name}::value(), 42);\n");
    my $meta = {
        'meta-spec' => { version => 2 },
        name => "Example-$name", version => '1.00',
        abstract => 'Local installer test', author => ['XPerl'],
        generated_by => 'XPerl installer test', release_status => 'stable',
        license => ['perl_5'], dynamic_config => JSON::PP::false,
        prereqs => $name eq 'Application'
            ? { runtime => { requires => { 'Example::Dependency' => '1.00' } } }
            : {},
    };
    $tar->add_data("$root_name/META.json", JSON::PP->new->encode($meta));
    $tar->write(File::Spec->catfile($releases, "$root_name.tar.gz"), 1);
}

my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, 'Example::Application' or die $!;
my $output = do { local $/; <$pipe> };
ok(close $pipe, 'application installation completed');
my $result = eval { JSON::PP->new->decode($output) };
ok($result && $result->{status} eq 'installed', 'dependency run succeeded');
my @modules;
for my $path (@{$result->{receipts}}) {
    open my $input, '<', $path or die $!;
    my $receipt = JSON::PP->new->decode(do { local $/; <$input> });
    push @modules, $receipt->{module};
}
is_deeply(\@modules, ['Example::Dependency', 'Example::Application'],
          'required dependency installed first');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Application.pm)),
   'application installed into selected prefix');

my $old_archive = File::Spec->catfile($root, 'old-meta.tar.gz');
my $old_tar = Archive::Tar->new;
$old_tar->add_data('Old-Meta-0.03/META.yml', <<'META');
--- #YAML:1.0
name: Old-Meta
version: 0.03
abstract: ~
author: []
license: unknown
requires:
    Test::More: 0
meta-spec:
    version: 1.4
META
$old_tar->write($old_archive, 1);
my $old_meta = XPerl::Installer::Deps::_metadata($old_archive);
is($old_meta->name, 'Old-Meta', 'old metadata with no abstract is accepted');
is($old_meta->effective_prereqs->merged_requirements(
       [qw(configure build test runtime)], ['requires'])
       ->requirements_for_module('Test::More'),
   '0', 'old metadata still provides its requirements');

done_testing();
