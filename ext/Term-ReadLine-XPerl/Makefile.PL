use ExtUtils::MakeMaker;
use Config;

WriteMakefile(
    NAME         => 'Term::ReadLine::XPerl',
    VERSION_FROM => 'lib/Term/ReadLine/XPerl.pm',
    OBJECT       => 'xrl$(OBJ_EXT) XPerl$(OBJ_EXT)',
    # the cursor-position query waits with poll(2) where Configure found
    # it, else select(2)
    DEFINE       => join(' ',
        ($Config{i_termios} ? '-DXRL_HAVE_TERMIOS' : ()),
        ($Config{i_poll} && $Config{d_poll} ? '-DXRL_HAVE_POLL' : ()),
        ($Config{i_sysselct} ? '-DXRL_HAVE_SYS_SELECT' : ()),
    ),
);
