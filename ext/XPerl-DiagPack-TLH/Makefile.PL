use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::TLH',
    VERSION_FROM => 'TLH.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'TLH$(OBJ_EXT)' => 'TLH_data.inc' },
);
