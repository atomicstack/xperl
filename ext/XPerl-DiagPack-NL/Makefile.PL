use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::NL',
    VERSION_FROM => 'NL.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'NL$(OBJ_EXT)' => 'NL_data.inc' },
);
