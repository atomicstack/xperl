use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::FA',
    VERSION_FROM => 'FA.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'FA$(OBJ_EXT)' => 'FA_data.inc' },
);
