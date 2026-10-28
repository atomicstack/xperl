use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::PT',
    VERSION_FROM => 'PT.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'PT$(OBJ_EXT)' => 'PT_data.inc' },
);
