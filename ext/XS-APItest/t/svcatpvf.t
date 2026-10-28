use strict;
use warnings;

use FindBin;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
use Test::More tests => 7;

use XS::APItest;

my @cases = (
    [field     => '%2$d'],
    [precision => '%.*2$d'],
    [vector    => '%2$vd'],
    [width     => '%*2$d'],
);

for my $case (@cases) {
    my ($what, $format) = @$case;
    my $got = eval { test_sv_catpvf($format); 1 };
    my $exn = $got ? undef : $@;
    like($exn, qr/\b\QCannot yet reorder sv_vcatpvfn() arguments from va_list\E\b/,
         "explicit $what index forbidden in va_list arguments");
}

{
    local $ENV{PERL_DIAG_RENDER} = 'fr:legacy';
    my $test_dir = File::Spec->rel2abs($FindBin::Bin);
    my $root_dir = File::Spec->catdir( $test_dir, '..', '..' );
    my $ext_dir  = File::Spec->catdir( $test_dir, '..' );
    my $stderr   = gensym;
    my $pid      = open3(
        my $stdin,
        my $stdout,
        $stderr,
        $^X,
        '-I' . File::Spec->catdir( $ext_dir,  'blib', 'lib' ),
        '-I' . File::Spec->catdir( $ext_dir,  'blib', 'arch' ),
        '-I' . File::Spec->catdir( $root_dir, 'lib' ),
        '-e',
        q{use warnings; use XS::APItest; XS::APItest::test_sv_catpvf_no_active_op(q{%s});},
    );
    close $stdin;
    local $/;
    <$stdout>;
    my $warning = <$stderr>;
    close $stdout;
    close $stderr;
    waitpid $pid, 0;
    like(
        $warning,
        qr/^Argument manquant dans sv_vcatpvfn\(\)/,
        'formatter preserves the no-active-op function name in the French sentence'
    );
}

# these actually test newSVpvf() but it is the same underlying logic.
is(test_HvNAMEf(bless {}, "Whatever::You::Like"),
    "class='Whatever::You::Like'");
is(test_HvNAMEf_QUOTEDPREFIX(bless {}, "x" x 1000),
    'class="xxxxxxxxxxxxxxxxxxxxxxxxxx'.
    'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'.
    'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"..."xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'.
    'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'.
    'xxxxxxxxxxxxxxxxxxxxx"');
