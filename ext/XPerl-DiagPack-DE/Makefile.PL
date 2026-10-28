use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::DE',
    VERSION_FROM => 'DE.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'DE$(OBJ_EXT)' => 'DE_data.inc' },
);
