use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::EN',
    VERSION_FROM => 'EN.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'EN$(OBJ_EXT)' => 'EN_data.inc' },
);
