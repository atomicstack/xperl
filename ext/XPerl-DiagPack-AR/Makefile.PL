use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::AR',
    VERSION_FROM => 'AR.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'AR$(OBJ_EXT)' => 'AR_data.inc' },
);
