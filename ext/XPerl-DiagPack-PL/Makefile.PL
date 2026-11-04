use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::PL',
    VERSION_FROM => 'PL.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'PL$(OBJ_EXT)' => 'PL_data.inc' },
);
