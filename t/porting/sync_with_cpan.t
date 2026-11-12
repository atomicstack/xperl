#!./perl -w

BEGIN {
    push @INC, '.' if -f 'TestInit.pm';
    push @INC, '..' if -f '../TestInit.pm';
}
use TestInit qw(T);
use strict;
use warnings;
require './t/test.pl';
use Archive::Tar;
use Cwd qw(abs_path getcwd);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Config;

skip_all('These importer fixtures require a Unix shell and fork')
    if $^O eq 'MSWin32' || $^O eq 'VMS' || !$Config{d_fork};
find_git_or_skip('all');
plan('no_plan');

my $root = abs_path('.');
my $perl = abs_path($^X);
my $tmp = File::Spec->rel2abs(tempdir('sync-cpan-XXXXXX',
    DIR => -d '../tmp' ? '../tmp' : '.', CLEANUP => 1));
my $serial = 0;

sub write_file {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print $fh $text;
    close $fh or die "$path: $!";
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub command {
    my ($directory, @args) = @_;
    splice @args, 1, 0, "-I$directory/fakelib" if $args[0] eq $perl;
    my $log = "$tmp/command-" . ++$serial;
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        chdir $directory or die "$directory: $!";
        open STDOUT, '>', $log or die "$log: $!";
        open STDERR, '>&', \*STDOUT or die "dup stderr: $!";
        delete @ENV{qw(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR)};
        $ENV{PERL5LIB} = "$directory/fakelib:$root/lib";
        $ENV{PERL5OPT} = '';
        $ENV{TMPDIR} = "$directory/cache";
        $ENV{SYNC_TEST_ARCHIVES} = $tmp;
        exec @args;
        die "exec @args: $!";
    }
    waitpid $pid, 0;
    my $status = $?;
    return ($status, read_file($log));
}

sub git {
    my ($directory, @args) = @_;
    my ($status, $output) = command($directory, 'git', @args);
    die "git @args failed: $output" if $status;
    return $output;
}

sub commit_fixture {
    my ($directory) = @_;
    git($directory, 'add', '.');
    write_file("$directory/.git/message", "Importer fixture\n");
    git($directory, '-c', 'user.name=Importer test', '-c',
        'user.email=importer@example.invalid', '-c', 'commit.gpgsign=false',
        'commit', '-q', '-F', '.git/message');
}

sub fixture {
    my $directory = "$tmp/repo-" . ++$serial;
    make_path(map { "$directory/$_" }
        qw(cpan/Existing lib Porting regen win32 cache fakelib/HTTP
           fakelib/IO/Socket fakelib/Net));
    for my $file (qw(Porting/sync-with-cpan Porting/manisort Porting/manifest_lib.pl
                     Porting/pod_lib.pl
                     regen/lib_cleanup.pl regen/regen_lib.pl Makefile.SH
                     win32/Makefile win32/GNUmakefile lib/.gitignore)) {
        copy("$root/$file", "$directory/$file") or die "copy $file: $!";
    }
    symlink $perl, "$directory/perl" or die "symlink perl: $!";
    write_file("$directory/cpan/Existing/Existing.pm", "package Existing; 1;\n");
    write_file("$directory/cpan/.gitignore", "Makefile.PL\nppport.h\n");
    write_file("$directory/Porting/exec-bit.txt", "# No executable fixtures\n");
    write_file("$directory/Porting/Maintainers.pl", <<'MAINTAINERS');
package Maintainers;
our @IGNORABLE = qw(Changes Makefile.PL ppport.h META.json);
our %Modules = (
    'Existing' => {
        'DISTRIBUTION' => 'AUTHOR/Existing-1.0.tar.gz',
        'FILES'        => 'cpan/Existing',
    },
);
our %DistName = (Existing => 'Existing');
1;
MAINTAINERS
    write_file("$directory/MANIFEST",
        "cpan/Existing/Existing.pm\tExisting\n");
    write_file("$directory/Makefile", <<MAKEFILE);
.PHONY: manisort test-prep test-harness test-porting
manisort:
	\@echo manisort >> events
	\@"$perl" "$root/Porting/manisort" --quiet --output=MANIFEST MANIFEST
test-prep:
	\@echo test-prep >> events
	\@test ! -f fail-build
test-harness:
	\@echo test-harness >> events
test-porting:
	\@echo test-porting >> events
MAKEFILE
    write_file("$directory/config.sh",
        "dynamic_ext='Existing'\nstatic_ext='Static/Existing'\nusedl='define'\nusedevel='define'\n");
    write_file("$directory/Configure", <<'CONFIGURE');
#!/bin/sh
printf '%s\n' "$@" > configure.args
test -z "$(find cpan -name '*-OLD')" || exit 1
grep "'SYNCINFO'" Porting/Maintainers.pl > /dev/null || exit 1
echo configure >> events
CONFIGURE
    write_file("$directory/fakelib/IO/Socket/SSL.pm", "1;\n");
    write_file("$directory/fakelib/Net/SSLeay.pm", "1;\n");
    write_file("$directory/fakelib/HTTP/Tiny.pm", <<'HTTP');
package HTTP::Tiny;
use File::Copy qw(copy);
sub new { bless {}, shift }
sub mirror {
    my ($self, $url, $to) = @_;
    my ($archive) = $url =~ m{([^/]+)$};
    copy("$ENV{SYNC_TEST_ARCHIVES}/$archive", $to) or die "fixture download: $!";
    return {success => 1};
}
1;
HTTP
    git($directory, 'init', '-q');
    commit_fixture($directory);
    return $directory;
}

sub archive {
    my ($dist, $version, $xs) = @_;
    my $tar = Archive::Tar->new;
    my $prefix = "$dist-$version";
    my %files = (
        'lib/Sample/Codec.pm' => "package Sample::Codec; our \$VERSION = '$version'; 1;\n",
        'Makefile.PL' => "# Supplied build instructions\n",
        'ppport.h' => "/* Compatibility header */\n",
        'Lib/Makefile.PL' => "# Nested build instructions\n",
        't/basic.t' => "print qq(1..1\\nok 1\\n);\n",
        'Changes' => "$version\nInitial fixture release\n",
    );
    $files{'Codec.xs'} = "/* XS fixture */\n" if $xs;
    $tar->add_data("$prefix/$_", $files{$_}, {mode => 0755})
        for sort keys %files;
    my $path = "$tmp/$prefix.tar.gz";
    $tar->write($path, 1) or die "write $path";
    return $path;
}

sub import_archive {
    my ($directory, $path, @options) = @_;
    my (undef, undef, $file) = File::Spec->splitpath($path);
    return command($directory, $perl, "-I$root/lib", 'Porting/sync-with-cpan',
        'Sample::Codec', '--add', '--tarball', $path,
        '--distribution', "AUTHOR/$file", '--yes', '--no-commit', @options);
}

my $path = archive('Sample-Codec', 'v1.2.3', 1);
my $repo = fixture();
my $head = git($repo, 'rev-parse', 'HEAD');
my ($status, $output) = import_archive($repo, $path, '--no-test');
is($status, 0, 'add imports an unregistered distribution without --force')
    or diag($output);
my $metadata = read_file("$repo/Porting/Maintainers.pl");
like($metadata, qr/'Sample::Codec' =>/, 'registration uses the module name');
like($metadata, qr{AUTHOR/Sample-Codec-v1\.2\.3\.tar\.gz},
    'registration records the CPAN archive and semantic version');
like($metadata, qr{cpan/Sample-Codec}, 'registration records the distribution directory');
for my $file (qw(Makefile.PL ppport.h Lib/Makefile.PL)) {
    ok(-f "$repo/cpan/Sample-Codec/$file", "$file is preserved");
    like(git($repo, 'ls-files', '--', "cpan/Sample-Codec/$file"),
        qr/\Q$file\E/, "$file is staged despite cpan ignore rules");
}
ok(!-f "$repo/cpan/Sample-Codec/Changes", 'ordinary ignorable files are removed');
ok(!-x "$repo/cpan/Sample-Codec/t/basic.t", 'test execute bits are removed');
ok(!-x "$repo/cpan/Sample-Codec/Makefile.PL", 'new source execute bits are removed');
like(read_file("$repo/MANIFEST"), qr{cpan/Sample-Codec/Makefile\.PL\t},
    'build instructions are included in MANIFEST');
like(read_file("$repo/lib/.gitignore"), qr{^/Sample/$}m,
    'library ignore rules are regenerated');
like(read_file("$repo/configure.args"), qr/^-Ddynamic_ext=Existing Sample\/Codec$/m,
    'Configure retains existing dynamic selections and enables the new XS extension');
like(read_file("$repo/configure.args"), qr/^-Dusedevel$/m,
    'Configure retains permission to build a development release');
is(read_file("$repo/events"), "configure\nmanisort\n",
    '--no-test refreshes configuration without running tests');
is(git($repo, 'rev-parse', 'HEAD'), $head, '--no-commit leaves HEAD unchanged');

write_file("$repo/cpan/Sample-Codec/ppport.h", "partial import\n");
git($repo, 'add', 'cpan/Sample-Codec', 'MANIFEST', 'Porting/Maintainers.pl');
($status, $output) = import_archive($repo, $path, '--no-test');
is($status, 0, 'a staged partial addition can be reset and retried') or diag($output);
is(read_file("$repo/cpan/Sample-Codec/ppport.h"), "/* Compatibility header */\n",
    'retry replaces partial source files');
$metadata = read_file("$repo/Porting/Maintainers.pl");
is(scalar(() = $metadata =~ /'Sample::Codec' =>/g), 1,
    'retry creates exactly one registration');

commit_fixture($repo);
write_file("$repo/cpan/Sample-Codec/ppport.h", "local change\n");
($status, $output) = import_archive($repo, $path, '--no-test');
ok($status, 'add rejects an already committed distribution');
like($output, qr/already bundled; omit --add/, 'rejection explains how to update');
is(read_file("$repo/cpan/Sample-Codec/ppport.h"), "local change\n",
    'rejection happens before resetting the source tree');
($status, $output) = command($repo, $perl, "-I$root/lib", 'Porting/sync-with-cpan',
    'Sample::Other', '--add', '--tarball', $path,
    '--distribution', 'AUTHOR/Sample-Codec-v1.2.3.tar.gz', '--yes', '--no-test');
ok($status, 'add rejects another module from an already bundled distribution');
like($output, qr/already bundled/, 'duplicate distribution is diagnosed');

my $update = archive('Sample-Codec', 'v1.2.4', 1);
($status, $output) = command($repo, $perl, "-I$root/lib", 'Porting/sync-with-cpan',
    'Sample::Codec', '--tarball', $update, '--yes', '--no-test', '--no-commit');
is($status, 0, 'ordinary update works after an addition') or diag($output);
like(read_file("$repo/Porting/Maintainers.pl"), qr/Sample-Codec-v1\.2\.4/,
    'ordinary update advances the registered archive');
ok(-f "$repo/cpan/Sample-Codec/Makefile.PL", 'ordinary update retains the supplied makefile');

$repo = fixture();
write_file("$repo/fail-build", "fail\n");
$head = git($repo, 'rev-parse', 'HEAD');
($status, $output) = import_archive($repo, $path, '--commit');
ok($status, 'a build failure stops the addition');
is(git($repo, 'rev-parse', 'HEAD'), $head, 'build failure leaves HEAD unchanged');
unlink "$repo/fail-build" or die $!;
write_file("$repo/events", '');
($status, $output) = import_archive($repo, $path);
is($status, 0, 'failed build can be retried') or diag($output);
is(read_file("$repo/events"),
    "configure\nmanisort\ntest-prep\ntest-harness\ntest-porting\n",
    'successful addition runs the build and both test stages');

$repo = fixture();
write_file("$repo/config.sh",
    "dynamic_ext=''\nstatic_ext='Existing'\nusedl='undef'\n");
($status, $output) = import_archive($repo, $path, '--no-test');
is($status, 0, 'addition supports a static-only configuration') or diag($output);
like(read_file("$repo/configure.args"), qr/^-Dstatic_ext=Existing Sample\/Codec$/m,
    'new XS extension joins the existing static selection');

$repo = fixture();
my $pure = archive('Sample-Pure', '1.0', 0);
($status, $output) = import_archive($repo, $pure, '--no-test');
is($status, 0, 'addition supports a pure Perl distribution') or diag($output);
unlike(read_file("$repo/configure.args"), qr/^-D(?:dynamic_ext|static_ext)=/m,
    'pure Perl addition does not alter XS extension selections');

$repo = fixture();
write_file("$repo/cache/02packages.details.txt",
    "Sample::Codec v1.2.3 A/AU/AUTHOR/Sample-Codec-v1.2.3.tar.gz\n");
($status, $output) = command($repo, $perl, "-I$root/lib", 'Porting/sync-with-cpan',
    'Sample::Codec', '--add', '--yes', '--no-test', '--no-commit');
is($status, 0, 'module lookup resolves and downloads the archive from the package index')
    or diag($output);
like(read_file("$repo/Porting/Maintainers.pl"),
    qr{AUTHOR/Sample-Codec-v1\.2\.3\.tar\.gz}, 'package index supplies the author and archive');

write_file("$repo/events", '');
($status, $output) = command($repo, $perl, "-I$root/lib", 'Porting/sync-with-cpan',
    'Sample-Codec', '--add', '--version', 'v1.2.4', '--yes', '--no-test', '--no-commit');
is($status, 0, 'distribution lookup supports selecting another release') or diag($output);
like(read_file("$repo/Porting/Maintainers.pl"), qr{Sample-Codec-v1\.2\.4\.tar\.gz},
    'selected archive version is registered');

$repo = fixture();
($status, $output) = command($repo, $perl, "-I$root/lib", 'Porting/sync-with-cpan',
    'Sample::Codec', '--add', '--tarball', $path, '--yes', '--no-test');
ok($status, 'offline addition requires a CPAN distribution identity');
like($output, qr/requires --distribution AUTHOR\/ARCHIVE/,
    'missing identity has an actionable diagnostic');

($status, $output) = import_archive($repo, $path, '--type', 'dist', '--no-test');
ok($status, 'add rejects unsupported target directories');
like($output, qr/--add imports into cpan/, 'unsupported target is diagnosed');
