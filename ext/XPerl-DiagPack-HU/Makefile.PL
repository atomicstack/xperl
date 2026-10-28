use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::HU',
    VERSION_FROM => 'HU.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'HU$(OBJ_EXT)' => 'HU_data.inc' },
);
