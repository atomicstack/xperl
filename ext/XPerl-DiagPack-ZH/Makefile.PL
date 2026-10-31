use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::ZH',
    VERSION_FROM => 'ZH.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'ZH$(OBJ_EXT)' => 'ZH_data.inc' },
);
