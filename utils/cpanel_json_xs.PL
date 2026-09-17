#!/usr/local/bin/perl

use Config;
use File::Basename qw(basename dirname);
use Cwd qw(cwd);
use File::Spec;

my $origdir = cwd;
chdir dirname($0);
my $file = basename($0, '.PL');
$file .= '.com' if $^O eq 'VMS';

open my $out, '>', $file or die "Can't create $file: $!";

print {$out} <<"!GROK!THIS!";
$Config{startperl}
    eval 'exec $Config{perlpath} -S \\$0 \\${1+"\\$@"}'
        if 0; # ^ Run only under a shell
!GROK!THIS!

my $script = File::Spec->catfile(
    File::Spec->catdir(File::Spec->updir, qw[cpan Cpanel-JSON-XS bin]),
    'cpanel_json_xs',
);

open my $in, '<', $script or die "$0: cannot find '$script': $!\n";
print {$out} <$in>;
close $in or die "Can't close $script: $!";
close $out or die "Can't close $file: $!";

chmod 0755, $file or die "Can't reset permissions for $file: $!\n";
exec "$Config{eunicefix} $file" if $Config{eunicefix} ne ':';
chdir $origdir;

# ex: set ro:
