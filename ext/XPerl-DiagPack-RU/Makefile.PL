use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::RU',
    VERSION_FROM => 'RU.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'RU$(OBJ_EXT)' => 'RU_data.inc' },
);
