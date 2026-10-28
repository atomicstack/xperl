use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::IT',
    VERSION_FROM => 'IT.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'IT$(OBJ_EXT)' => 'IT_data.inc' },
);
