use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::HE',
    VERSION_FROM => 'HE.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'HE$(OBJ_EXT)' => 'HE_data.inc' },
);
