use 5.036003;
use ExtUtils::MakeMaker;

my $define = $ENV{XGRAPH_WIDE} ? '-DXGRAPH_WIDE' : '';
WriteMakefile(
    NAME              => 'XGraph',
    VERSION_FROM      => 'lib/XGraph.pm',
    PREREQ_PM         => {},
    ABSTRACT_FROM     => 'lib/XGraph.pm',
    PM                => {
        'lib/XGraph.pm'       => '$(INST_LIBDIR)/XGraph.pm',
        'lib/XGraph/IO/DOT.pm' => '$(INST_LIBDIR)/XGraph/IO/DOT.pm',
    },
    AUTHOR            => 'Yves Orton',
    LICENSE           => 'perl',
    LIBS              => [''],
    DEFINE            => $define,
    INC               => '-I.',
    OBJECT            => '$(O_FILES)',
);
