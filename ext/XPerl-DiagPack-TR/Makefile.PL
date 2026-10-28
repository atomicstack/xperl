use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::TR',
    VERSION_FROM => 'TR.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'TR$(OBJ_EXT)' => 'TR_data.inc' },
);
