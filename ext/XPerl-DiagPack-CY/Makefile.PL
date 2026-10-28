use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::CY',
    VERSION_FROM => 'CY.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'CY$(OBJ_EXT)' => 'CY_data.inc' },
);
