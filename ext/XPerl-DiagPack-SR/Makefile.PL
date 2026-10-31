use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'XPerl::DiagPack::SR',
    VERSION_FROM => 'SR.pm',
    INC          => '-I../..',
    PREREQ_PM    => {},
    depend       => { 'SR$(OBJ_EXT)' => 'SR_data.inc' },
);
