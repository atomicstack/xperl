package XPerl::REPL::Config;

use v5.36;
use feature 'defer';
no warnings 'experimental::defer';

use File::Spec ();
use Getopt::Long ();

our $VERSION = '0.01';

my %CHOICES = (
    color  => [qw(auto always never)],
    out    => [qw(dumper json plain)],
    render => [qw(legacy annotated json)],
);

# terminal programs known to handle 256 colours whatever TERM says
my %TERM_PROGRAM_256 = map { $_ => 1 } qw(iTerm.app WezTerm kitty ghostty Apple_Terminal);

sub usage {
    return <<'EOT';
usage: xperl-repl [-I dir]... [-M module]... [-e code]... [--rc file] [--no-rc]
                  [--color=auto|always|never] [--out dumper|json|plain]
                  [--render legacy|annotated|json] [--prompt format]
                  [--continuation format] [--version] [--help] [file]
EOT
}

sub version_text {
    require XPerl::REPL;
    return "xperl-repl $XPerl::REPL::VERSION (xperl ${^XPERL_VERSION}, perl $^V)\n";
}

# command-line options as a hash; dies with the usage text on a bad option.
# -I, -M and -e take a value like perl's: "-Ilib" and "-I lib" both work.
sub parse_argv ($argv) {
    my @args = @$argv;
    my %o = (
        inc => [], modules => [], code => [], rc => undef, no_rc => 0,
        color => 'auto', out => undef, render => undef, version => 0, help => 0,
        prompt => undef, continuation => undef,
    );
    my @problems;
    my $ok = do {
        local $SIG{__WARN__} = sub { push @problems, $_[0] };
        my $saved = Getopt::Long::Configure(qw(bundling no_ignore_case no_auto_abbrev));
        defer { Getopt::Long::Configure($saved) }
        Getopt::Long::GetOptionsFromArray(
            \@args,
            'I=s'      => $o{inc},
            'M=s'      => $o{modules},
            'e=s'      => $o{code},
            'rc=s'     => \$o{rc},
            'no-rc'    => \$o{no_rc},
            'color=s'  => \$o{color},
            'out=s'    => \$o{out},
            'render=s' => \$o{render},
            'prompt=s'       => \$o{prompt},
            'continuation=s' => \$o{continuation},
            'version'  => \$o{version},
            'help'     => \$o{help},
        );
    };
    for my $key (sort keys %CHOICES) {
        next unless defined $o{$key};
        push @problems, "unknown --$key value \"$o{$key}\"\n"
            unless grep { $_ eq $o{$key} } @{ $CHOICES{$key} };
    }
    push @problems, "only one file can be given\n" if @args > 1;
    die join('', map { lcfirst } @problems) . usage() if !$ok || @problems;
    $o{file} = $args[0];
    $o{$_} = $o{$_} ? 1 : 0 for qw(no_rc version help);
    return \%o;
}

sub _home_file ($env, $name) {
    return undef unless defined $env->{HOME};
    return File::Spec->catfile($env->{HOME}, '.xperl', $name);
}

sub rc_path ($env)      { return $env->{XPERL_REPL_RC}      // _home_file($env, 'replrc') }
sub history_path ($env) { return $env->{XPERL_REPL_HISTORY} // _home_file($env, 'repl_history') }

# colour level for the terminal: 0, 16, 256 or 'rgb'
sub color_level (%a) {
    my $env = $a{env} // {};
    my $option = $a{option} // 'auto';
    return 0 if $option eq 'never';
    my $level = _detect($env);
    return $level || 16 if $option eq 'always';
    return 0 if defined $env->{NO_COLOR} && length $env->{NO_COLOR};
    return 0 unless $a{is_tty};
    return $level;
}

sub _detect ($env) {
    my $colorterm = $env->{COLORTERM} // '';
    return 'rgb' if $colorterm eq 'truecolor' || $colorterm eq '24bit';
    my $term = $env->{TERM} // '';
    return 256 if $term =~ /256color/ || $TERM_PROGRAM_256{ $env->{TERM_PROGRAM} // '' };
    return 0 if $term eq '' || $term eq 'dumb';
    return 16;
}

1;

__END__

=head1 NAME

XPerl::REPL::Config - xperl-repl command line, file paths and colour detection

=head1 DESCRIPTION

Internal to C<XPerl::REPL>. Parses the C<xperl-repl> command line, finds
the rc file (C<~/.xperl/replrc>, or C<XPERL_REPL_RC>) and history file
(C<~/.xperl/repl_history>, or C<XPERL_REPL_HISTORY>), and decides how many
colours to use: none for C<--color=never>, C<NO_COLOR> or output that is
not a terminal; truecolor when C<COLORTERM> says so; 256 for a
C<256color> C<TERM> or a known terminal program; none for a C<dumb> or
unset C<TERM>; otherwise 16. C<--color=always> uses at least 16.

=cut
