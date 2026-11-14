use strict;
use warnings;
use Config;
use ExtUtils::MakeMaker;

my ($core) = map { /^CORE=(.*)$/ ? $1 : () } @ARGV;
@ARGV = grep { !/^CORE=/ } @ARGV;
die "pass CORE=/absolute/path/to/matching/perl/source\n"
    unless defined $core && -f "$core/perl.h";

WriteMakefile(
    NAME => 'HashOptionsCompat',
    VERSION_FROM => 'HashOptionsCompat.pm',
    PM => { 'HashOptionsCompat.pm' => '$(INST_LIB)/HashOptionsCompat.pm' },
    PERL_SRC => $core,
    INC => "-I$core",
    OPTIMIZE => $Config{optimize},
    XS => { 'HashOptionsCompat.xs' => 'HashOptionsCompat.c' },
    OBJECT => '$(O_FILES)',
);
