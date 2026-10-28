use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::UK',
    VERSION_FROM => 'UK.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'UK$(OBJ_EXT)' => 'UK_data.inc' },
);
