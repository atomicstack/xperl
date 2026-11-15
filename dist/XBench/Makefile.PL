use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'XBench',
    VERSION_FROM     => 'lib/XBench.pm',
    ABSTRACT_FROM    => 'lib/XBench.pm',
    AUTHOR           => 'Yves Orton',
    LICENSE          => 'perl',
    MIN_PERL_VERSION => '5.041',
    PREREQ_PM        => {
        'Config'                     => 0,
        'XStats'                     => '0.01',
        'XPerl::Diagnostic::Catalog' => '0.01',
        'Time::HiRes'                => 0,
        'Scalar::Util'               => 0,
        'POSIX'                      => 0,
        'JSON::PP'                   => 0,
        'Getopt::Long'               => 0,
    },
    PM => {
        'lib/XBench.pm'        => '$(INST_LIB)/XBench.pm',
        'lib/XBench/Result.pm' => '$(INST_LIB)/XBench/Result.pm',
    },
    EXE_FILES => ['bin/xbench'],
);
