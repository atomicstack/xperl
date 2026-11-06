use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;
use XPerl::Installer::Build;

my $root = tempdir(CLEANUP => 1,
                   DIR => $ENV{XPERL_TEST_TMPDIR} // File::Spec->tmpdir);
my $builder = XPerl::Installer::Build->new(
    prefix => File::Spec->catdir($root, 'prefix'),
    workdir => File::Spec->catdir($root, 'work'));
my @names = qw(PERL5_CPAN_IS_RUNNING PERL5_CPANPLUS_IS_RUNNING
               PERL5_CPANM_IS_RUNNING PERL5_CPAN_IS_EXECUTING
               PERL PERL_MM_USE_DEFAULT
               NONINTERACTIVE_TESTING PERL_USE_UNSAFE_INC
               AUTOMATED_TESTING NO_COLOR);
my $code = 'print JSON::PP->new->encode({map { $_ => $ENV{$_} } @ARGV})';

{
    my $checkout = File::Spec->catdir($root, 'checkout-lib');
    my $site = File::Spec->catdir($builder->{prefix}, 'lib', 'perl5');
    make_path($checkout, $site);
    local @INC = ($checkout, @INC);
    local $ENV{PERL5LIB};
    my $log = File::Spec->catfile($root, 'include.log');
    is($builder->_run($root, $log, $^X, '-MJSON::PP', '-e',
                     'print JSON::PP->new->encode(\@INC)'),
       0, 'child library path probe succeeds');
    open my $input, '<', $log or die $!;
    my $include = JSON::PP->new->decode(do { local $/; <$input> });
    ok(scalar(grep { $_ eq $site } @$include),
       'child searches the selected installation prefix');
    ok(!scalar(grep { $_ eq $checkout } @$include),
       'child does not inherit the installer process library path');

    local $ENV{PERL5LIB} = $checkout;
    my $explicit_log = File::Spec->catfile($root, 'explicit-include.log');
    is($builder->_run($root, $explicit_log, $^X, '-MJSON::PP', '-e',
                     'print JSON::PP->new->encode(\@INC)'),
       0, 'explicit caller library path probe succeeds');
    open my $explicit, '<', $explicit_log or die $!;
    my $explicit_include = JSON::PP->new->decode(do { local $/; <$explicit> });
    ok(scalar(grep { $_ eq $checkout } @$explicit_include),
       'child preserves an explicit caller PERL5LIB');
}

{
    local %ENV = %ENV;
    delete @ENV{@names};
    for my $phase (qw(configure build test install)) {
        my $log = File::Spec->catfile($root, "$phase.log");
        is($builder->_run($root, $log,
            { phase => $phase, unsafe_inc => 0 },
            $^X, '-MJSON::PP', '-e', $code, @names),
           0, "$phase command succeeds");
        open my $input, '<', $log or die $!;
        my $values = JSON::PP->new->decode(do { local $/; <$input> });
        is($values->{PERL_USE_UNSAFE_INC}, 0,
           "$phase follows distribution unsafe-inc setting");
        is($values->{PERL}, abs_path($^X),
           "$phase uses the running XPerl interpreter");
        is($values->{PERL_MM_USE_DEFAULT},
           $phase eq 'install' ? undef : 1,
           "$phase uses the expected MakeMaker default setting");
        is($values->{NONINTERACTIVE_TESTING},
           $phase eq 'test' ? 1 : undef,
           "$phase uses the expected noninteractive test setting");
        for my $name (qw(PERL5_CPAN_IS_RUNNING PERL5_CPANPLUS_IS_RUNNING
                         PERL5_CPANM_IS_RUNNING)) {
            like($values->{$name}, qr/\A\d+\z/,
                 "$phase sets $name") if $phase eq 'configure';
            is($values->{$name}, undef,
               "$phase leaves $name unset") if $phase ne 'configure';
        }
        is($values->{AUTOMATED_TESTING}, undef,
           "$phase does not claim smoke testing");
        is($values->{PERL5_CPAN_IS_EXECUTING}, undef,
           "$phase does not claim to execute Makefile.PL");
        is($values->{NO_COLOR}, undef,
           "$phase preserves the caller's color environment");
    }
    ok(!exists $ENV{PERL_MM_USE_DEFAULT},
       'phase settings do not escape into the installer process');
}

{
    my $makefile = File::Spec->catfile($root, 'Makefile.PL');
    open my $output, '>', $makefile or die $!;
    print {$output} "print \$ENV{PERL5_CPAN_IS_EXECUTING}, qq{\\n};\n";
    close $output or die $!;
    my $log = File::Spec->catfile($root, 'makefile.log');
    is($builder->_run($root, $log, { phase => 'configure' },
                     $^X, 'Makefile.PL'), 0,
       'Makefile.PL configuration command succeeds');
    open my $input, '<', $log or die $!;
    chomp(my $executing = <$input>);
    is($executing, $makefile,
       'Makefile.PL receives the CPAN executing marker');
}

{
    local $ENV{PERL_USE_UNSAFE_INC} = 0;
    local $ENV{NO_COLOR} = 1;
    my $log = File::Spec->catfile($root, 'override.log');
    is($builder->_run($root, $log,
        { phase => 'test', unsafe_inc => 1 },
        $^X, '-MJSON::PP', '-e', $code, @names),
       0, 'caller override command succeeds');
    open my $input, '<', $log or die $!;
    my $values = JSON::PP->new->decode(do { local $/; <$input> });
    is($values->{PERL_USE_UNSAFE_INC}, 0,
       'caller unsafe-inc override takes precedence');
    is($values->{NO_COLOR}, 1, 'caller color setting is preserved');
}

{
    local %ENV = %ENV;
    delete $ENV{PERL_USE_UNSAFE_INC};
    my $log = File::Spec->catfile($root, 'default.log');
    is($builder->_run($root, $log,
        { phase => 'test' }, $^X, '-MJSON::PP', '-e', $code, @names),
       0, 'legacy distribution command succeeds');
    open my $input, '<', $log or die $!;
    my $values = JSON::PP->new->decode(do { local $/; <$input> });
    is($values->{PERL_USE_UNSAFE_INC}, 1,
       'legacy distribution receives cpanm unsafe-inc default');
}

done_testing();
