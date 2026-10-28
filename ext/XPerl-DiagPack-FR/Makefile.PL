use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::FR',
    VERSION_FROM => 'FR.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'FR$(OBJ_EXT)' => 'FR_data.inc' },
);
