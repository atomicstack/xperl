use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Archive::Tar;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use Test::More;

my $root = abs_path(tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir));
my $mirror = File::Spec->catdir($root, 'mirror');
my $cache = File::Spec->catdir($root, 'cache');
my $prefix = File::Spec->catdir($root, 'prefix');
my $modules = File::Spec->catdir($mirror, 'modules');
my $releases = File::Spec->catdir($mirror, qw(authors id E EX EXAMPLE));
make_path($modules, $releases);

my $index = <<'INDEX';
File: 02packages.details.txt

Example::Fixable 1.00 E/EX/EXAMPLE/Example-Fixable-1.00.tar.gz
Example::Unfixable 1.00 E/EX/EXAMPLE/Example-Unfixable-1.00.tar.gz
Example::Slow 1.00 E/EX/EXAMPLE/Example-Slow-1.00.tar.gz
INDEX
gzip \$index => File::Spec->catfile($modules, '02packages.details.txt.gz')
    or die $GzipError;

for my $name (qw(Fixable Unfixable Slow)) {
    my $dist = "Example-$name-1.00";
    my $tar = Archive::Tar->new;
    $tar->add_data("$dist/Makefile.PL",
        "use ExtUtils::MakeMaker;\nWriteMakefile(NAME => 'Example::$name', VERSION => '1.00');\n");
    $tar->add_data("$dist/lib/Example/$name.pm",
        "package Example::$name;\nour \$VERSION = '1.00';\nsub value { 0 }\n1;\n");
    $tar->add_data("$dist/t/basic.t",
        "use Test::More tests => 1; use Example::$name; is(Example::${name}::value(), 42);\n");
    $tar->write(File::Spec->catfile($releases, "$dist.tar.gz"), 1);
}

my $agent = File::Spec->catfile($root, 'repair-agent');
open my $agent_file, '>', $agent or die $!;
print {$agent_file} "#!$^X\n";
print {$agent_file} <<'AGENT';
use strict;
use warnings;
use JSON::PP;
use File::Spec;
my $request_path = shift @ARGV;
open my $request_file, '<', $request_path or die $!;
my $request = JSON::PP->new->decode(do { local $/; <$request_file> });
open my $marker, '>', $ENV{XPERL_REPAIR_MARKER} or die $!;
print {$marker} JSON::PP->new->encode($request);
close $marker or die $!;
exit 0 if $request->{module} eq 'Example::Unfixable';
if ($request->{module} eq 'Example::Slow') { sleep 3; exit 0 }
my $module = File::Spec->catfile($request->{source},
                                qw(lib Example Fixable.pm));
open my $source, '<', $module or die $!;
my $body = do { local $/; <$source> };
close $source or die $!;
$body =~ s/sub value \{ 0 \}/sub value { 42 }/
    or die "expected source not found\n";
open my $output, '>', $module or die $!;
print {$output} $body;
close $output or die $!;
my $added = File::Spec->catfile($request->{source},
                                qw(lib Example Added.pm));
open my $extra, '>', $added or die $!;
print {$extra} "package Example::Added;\n1;\n";
close $extra or die $!;
AGENT
close $agent_file or die $!;
chmod 0755, $agent or die $!;

local $ENV{XPERL_REPAIR_MARKER} = File::Spec->catfile($root, 'request.json');
my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'xperl');
open my $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, '--repair-command', $agent,
    '--repair-attempts', '1', 'Example::Fixable' or die $!;
my $output = do { local $/; <$pipe> };
ok(close $pipe, 'repair completed');
my $result = eval { JSON::PP->new->decode($output) };
ok($result && $result->{status} eq 'installed', 'repaired module installed');
my $receipt_path = $result->{receipts}[0];
open my $receipt_file, '<', $receipt_path or die $!;
my $receipt = JSON::PP->new->decode(do { local $/; <$receipt_file> });
is_deeply([map { $_->{name} } @{$receipt->{phases}}],
          [qw(configure build test repair configure build test proposal-check install)],
          'installer reran all checks after repair');
my $proposal = $receipt->{proposal};
ok($proposal && -f $proposal->{path}, 'reviewable patch was written');
open my $patch_file, '<:raw', $proposal->{path} or die $!;
my $patch = do { local $/; <$patch_file> };
is(sha256_hex($patch), $proposal->{sha256}, 'receipt records patch digest');
like($patch, qr/\+sub value \{ 42 \}/, 'patch contains source repair');
like($patch, qr/^\+\+\+ b\/lib\/Example\/Added\.pm$/m,
     'patch contains agent-added source file');
unlike($patch, qr/^\+\+\+ b\/(?:Makefile|blib\/)/m,
       'patch excludes generated build products');
open my $request_file, '<', $ENV{XPERL_REPAIR_MARKER} or die $!;
my $request = JSON::PP->new->decode(do { local $/; <$request_file> });
is($request->{failed_phase}, 'test', 'agent received failed phase');
ok(-f $request->{failed_log}, 'agent received persistent test log');
ok(-f File::Spec->catfile($prefix, qw(lib perl5 Example Fixable.pm)),
   'repaired module installed in prefix');

open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, '--repair-command', $agent,
    '--repair-attempts', '1', 'Example::Unfixable' or die $!;
my $failure = do { local $/; <$pipe> };
ok(!close $pipe, 'repair stops after configured attempt limit');
ok(!-f File::Spec->catfile($prefix, qw(lib perl5 Example Unfixable.pm)),
   'unrepaired module was not installed');

open $pipe, '-|', $^X, $script, 'install', '--mirror', $mirror,
    '--cache', $cache, '--prefix', $prefix, '--repair-command', $agent,
    '--repair-attempts', '1', '--repair-timeout', '1', 'Example::Slow'
    or die $!;
my $timeout = do { local $/; <$pipe> };
ok(!close $pipe, 'slow repair command times out');
ok(!-f File::Spec->catfile($prefix, qw(lib perl5 Example Slow.pm)),
   'timed-out repair did not install module');

done_testing();
