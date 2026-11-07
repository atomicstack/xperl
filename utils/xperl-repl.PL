#!/usr/local/bin/perl

use Config;
use File::Basename qw(&basename &dirname);
use Cwd;

# List explicitly here the variables you want Configure to
# generate.  Metaconfig only looks for shell variables, so you
# have to mention them as if they were shell variables, not
# %Config entries.  Thus you write
#  $startperl
# to ensure Configure will look for $Config{startperl}.

# This forces PL files to create target in same directory as PL file.
# This is so that make depend always knows where to find PL derivatives.
my $origdir = cwd;
chdir dirname($0);
my $file = basename($0, '.PL');
$file .= '.com' if $^O eq 'VMS';

open OUT, '>', $file or die "Can't create $file: $!";

print "Extracting $file (with variable substitutions)\n";

# In this section, perl variables will be expanded during extraction.
# You can use $Config{...} to use Configure variables.

print OUT <<"!GROK!THIS!";
$Config{startperl}
    eval 'exec $Config{perlpath} -S \$0 \${1+"\$@"}'
	if 0; # ^ Run only under a shell
!GROK!THIS!

# In the following, perl variables are not expanded during extraction.

print OUT <<'!NO!SUBS!';

use XPerl::REPL;
exit XPerl::REPL->main(\@ARGV);

__END__

=head1 NAME

xperl-repl - an interactive xperl shell

=head1 SYNOPSIS

    xperl-repl [-I dir]... [-M module]... [-e code]... [--rc file]
               [--no-rc] [--color=auto|always|never]
               [--out dumper|json|plain]
               [--render legacy|annotated|json] [--prompt format]
               [--continuation format] [--version] [--help] [file]

=head1 DESCRIPTION

B<xperl-repl> reads Perl from the terminal, runs each input and prints
its result, keeping lexical variables, the current package and pragmas
from one input to the next. Type C<:help> at the prompt for its commands
and keys.

The options, commands, key bindings, rc file and limits are described in
L<XPerl::REPL>.

=cut
!NO!SUBS!

close OUT or die "Can't close $file: $!";
chmod 0755, $file or die "Can't reset permissions for $file: $!\n";
exec("$Config{'eunicefix'} $file") if $Config{'eunicefix'} ne ':';
chdir $origdir;
