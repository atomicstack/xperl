use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::FI',
    VERSION_FROM => 'FI.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'FI$(OBJ_EXT)' => 'FI_data.inc' },
);
