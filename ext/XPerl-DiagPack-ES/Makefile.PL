use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::ES',
    VERSION_FROM => 'ES.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'ES$(OBJ_EXT)' => 'ES_data.inc' },
);
