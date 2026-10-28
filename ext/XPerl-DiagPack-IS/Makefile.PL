use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::IS',
    VERSION_FROM => 'IS.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'IS$(OBJ_EXT)' => 'IS_data.inc' },
);
