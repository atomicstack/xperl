package XPerl::REPL;

use v5.36;
use feature qw(class try defer);
no warnings qw(experimental::class experimental::try experimental::defer);

use IO::Handle ();
use XPerl::REPL::Commands;
use XPerl::REPL::Evaluator;
use XPerl::REPL::Render;

our $VERSION = '0.01';

# a line that is a :command rather than Perl ("::foo()" is Perl)
my $COMMAND = qr/\A:[a-z]/;

class XPerl::REPL {
    field $input       :param :reader = undef;
    field $out         :param;
    field $err         :param :reader;
    field $color_level :param = 0;
    field $evaluator   :param :reader = undef;
    field $renderer    :param :reader = undef;
    field $commands    :reader;
    field @history;
    field @history_numbers;   # the input number of each @history entry
    field @pushback;          # lines read ahead that still need handling
    field $input_number = 0;
    field $last_error;
    field $quit = 0;

    ADJUST {
        $evaluator //= XPerl::REPL::Evaluator->new;
        $renderer  //= XPerl::REPL::Render->new(
            out => $out, err => $err, color_level => $color_level,
        );
        $renderer->set_session($self);
        $commands = XPerl::REPL::Commands->new(repl => $self);
        # keep user prints, warnings and results in order
        $out->autoflush(1);
        $err->autoflush(1);
        no warnings 'once';
        $main::REPL = $self;
    }

    method history         { return [@history] }
    method history_numbers { return [@history_numbers] }
    method input_number { return $input_number }
    method last_error   { return $last_error }
    method quit         { $quit = 1 }

    # the input source; a terminal input needs the session to exist first
    method set_input($source) { $input = $source }

    # the output handle, or with an argument the result mode (rc files:
    # $REPL->out('json'))
    method out(@mode) {
        return $out unless @mode;
        $renderer->set_out_mode($mode[0]);
    }

    method render($mode)   { $renderer->set_render_mode($mode) }
    method theme(%roles)   { $renderer->set_theme(%roles) }

    # the prompt and continuation prompt: a format string or a code ref
    # (see "prompts" below); without an argument, the current one
    method prompt(@spec) {
        return $renderer->prompt_spec unless @spec;
        $renderer->set_prompt_spec($spec[0]);
    }

    method continuation(@spec) {
        return $renderer->continuation_spec unless @spec;
        $renderer->set_continuation_spec($spec[0]);
    }

    method run {
        my $going = 1;
        while ($going) {
            $going = $self->guard(sub {
                my $text = $self->read_input;
                return defined $text ? $self->step($text) : 0;
            });
        }
        return 0;
    }

    # run $code, reporting what it dies with instead of letting it end the
    # session; returns $code's value, or true after a failure. SIGINT
    # outside the evaluator's own handler (reading, rendering) interrupts
    # $code, not the process. run and main's startup inputs use it.
    method guard($code) {
        local $SIG{INT} = sub { die XPerl::REPL::Interrupted->new };
        my $ok;
        try { $ok = $code->() }
        catch ($v, $e) {
            $self->report_failure($v, $e);
            $ok = 1;
        }
        return $ok;
    }

    # an exception from outside the evaluator: a render that died, a
    # completion callback, an interrupt between inputs
    method report_failure($v, $e) {
        my $interrupted = builtin::blessed($v) && $v isa XPerl::REPL::Interrupted;
        my $result = XPerl::REPL::Result->new(
            kind => $interrupted ? 'interrupted' : 'runtime_error',
            exception => $interrupted ? undef : $e,
            input_number => $input_number,
        );
        try { $renderer->print_error($result) }
        catch ($v2, $e2) {
            local ($\, $,);
            print {$err} 'error: ', $e->render('legacy') =~ s/\n?\z/\n/r;
        }
    }

    # one logical input: physical lines joined while they end in "\".
    # undef at end of input. continuation of incomplete Perl is step's job.
    method read_input {
        return shift(@pushback) . "\n" if @pushback;
        my $prompt = $renderer->prompt($input_number + 1);
        my $text;
        while (defined(my $line = $input->next_line($prompt))) {
            if ($input->last_cancelled) {    # ctrl-c: drop what was typed
                undef $text;
                $prompt = $renderer->prompt($input_number + 1);
                next;
            }
            if ($line =~ s/\\\z//) {
                $text .= "$line\n";
                $prompt = $renderer->continuation_prompt($input_number + 1);
                next;
            }
            return ($text // '') . "$line\n";
        }
        return defined $text ? $text : undef;
    }

    # handle one input; false once the session should end. options: echo
    # (print the prompt and text first), whole (incomplete input is an
    # error, not a reason to read more lines), quiet (startup input: no
    # result printed, nothing added to the history), label (an unnumbered
    # input, such as "rc file": its name in messages instead of "input N")
    method step($text, %opt) {
        $text =~ s/\n\z//;
        if ($opt{echo}) {
            local ($\, $,);
            print {$out} $renderer->prompt($input_number + 1), $text, "\n";
        }
        return 1 if $text =~ /\A\s*\z/;

        # a :command goes into the line editor's history (so up-arrow
        # finds it) but not :history, which lists inputs
        if ($text =~ $COMMAND) {
            $input->add_history($text) unless $opt{quiet};
            return !$quit if $commands->dispatch($text);
        }

        my $label = $opt{label};
        my $n = defined $label ? $input_number : ++$input_number;
        my $result = $self->_evaluate($text, $n, $label);
        # incomplete: ask for more lines and retry under the same number.
        # end of input, a forced submit or a :command line submits as is.
        while ($result->kind eq 'incomplete' && !$opt{whole} && !$input->last_submit_forced) {
            my $line = $input->next_line($renderer->continuation_prompt($n));
            last unless defined $line;
            if ($input->last_cancelled) {    # ctrl-c: drop the input
                $input_number-- unless defined $label;
                return !$quit;
            }
            if ($line =~ $COMMAND) {
                push @pushback, $line;
                last;
            }
            $text .= "\n$line";
            $result = $self->_evaluate($text, $n, $label);
        }
        unless ($opt{quiet}) {
            push @history, "$text\n";
            push @history_numbers, $n;
            $input->add_history($text);
        }

        if ($result->kind eq 'ok') {
            $renderer->print_result($result) unless $opt{quiet};
        }
        else {
            $renderer->print_error($result);
            $last_error = $result unless $result->kind eq 'interrupted';
        }
        return !$quit;
    }

    # user output goes to $out as it happens; warnings render immediately
    method _evaluate($text, $n, $label = undef) {
        my $old = select $out;
        defer { select $old }
        local $SIG{__WARN__} = sub ($msg) {
            $renderer->print_warning(${^CUR_ERROR_OBJ} // $msg, $msg);
        };
        return $evaluator->evaluate("$text\n", $n, $label);
    }
}


# the xperl-repl program: XPerl::REPL->main(\@ARGV) returns the exit status
sub main ($class, $argv) {
    require XPerl::REPL::Config;
    require XPerl::REPL::Input;
    my $o;
    try { $o = XPerl::REPL::Config::parse_argv($argv) }
    catch ($v, $e) {
        print STDERR ref $v ? $e->render : $v;
        return 2;
    }
    if ($o->{help}) {
        print STDOUT XPerl::REPL::Config::usage();
        return 0;
    }
    if ($o->{version}) {
        print STDOUT XPerl::REPL::Config::version_text();
        return 0;
    }
    unshift @INC, @{ $o->{inc} };

    # in a UTF-8 locale the terminal, pipes and -e code are characters
    my $utf8 = _utf8_locale();
    if ($utf8) {
        binmode $_, ':encoding(UTF-8)' for \*STDIN, \*STDOUT, \*STDERR;
        utf8::decode($_) for @{ $o->{code} };
    }

    my $is_tty = -t STDIN && -t STDOUT;
    my $repl = $class->new(
        out => \*STDOUT,
        err => \*STDERR,
        color_level => XPerl::REPL::Config::color_level(
            option => $o->{color}, env => \%ENV, is_tty => $is_tty,
        ),
    );
    $repl->set_input($is_tty
        ? XPerl::REPL::Input::Tty->new(
            repl => $repl, in => \*STDIN, out => \*STDOUT,
            history_file => XPerl::REPL::Config::history_path(\%ENV),
          )
        : XPerl::REPL::Input::Handle->new(fh => \*STDIN));

    unless ($o->{no_rc}) {
        my $rc = $o->{rc} // XPerl::REPL::Config::rc_path(\%ENV);
        if (defined $rc && (defined $o->{rc} || -e $rc)) {
            my $text = _slurp($rc, $utf8);
            # the session is $REPL, declared on the rc file's first line
            if (defined $text) { $repl->guard(sub { $repl->step("our \$REPL; $text", whole => 1, quiet => 1, label => 'rc file') }) }
            else { print STDERR $repl->renderer->colorize(error => "cannot read rc file $rc: $!\n") }
        }
    }
    # the command line wins over the rc file
    $repl->out($o->{out})       if defined $o->{out};
    $repl->render($o->{render}) if defined $o->{render};
    $repl->prompt($o->{prompt})             if defined $o->{prompt};
    $repl->continuation($o->{continuation}) if defined $o->{continuation};

    for my $module (@{ $o->{modules} }) {
        # as perl's -M: -MFoo=a,b is "use Foo split(/,/, 'a,b')", -M-Foo is "no Foo"
        my ($no, $name, $list) = $module =~ /\A(-?)([^=]*)(?:=(.*))?\z/s;
        my $code = ($no ? 'no' : 'use') . " $name";
        $code .= ' qw(' . join(' ', split /,/, $list) . ')' if defined $list;
        $repl->guard(sub { $repl->step("$code;\n", whole => 1, quiet => 1, label => "-M $module") });
    }
    for my $code (@{ $o->{code} }) {
        return 0 unless $repl->guard(sub { $repl->step("$code\n", echo => $is_tty, whole => 1) });    # :quit
    }
    if (defined $o->{file}) {
        my $text = _slurp($o->{file}, $utf8);
        # as perl does, the program ends at an __END__ or __DATA__ line
        $text =~ s/^__(?:END|DATA)__\b.*//ms if defined $text;
        if (defined $text) { $repl->guard(sub { $repl->step($text, whole => 1) }) or return 0 }
        else {
            print STDERR $repl->renderer->colorize(error => "cannot read $o->{file}: $!\n");
            return 2;
        }
    }
    return $repl->run;
}

# true when the locale's character set is UTF-8: the CODESET of LC_CTYPE,
# or else the first of LC_ALL, LC_CTYPE and LANG that is set
sub _utf8_locale {
    my $codeset = eval {
        require POSIX;
        require I18N::Langinfo;
        POSIX::setlocale(POSIX::LC_CTYPE(), '');
        I18N::Langinfo::langinfo(I18N::Langinfo::CODESET());
    };
    return $codeset =~ /\Autf-?8\z/i ? 1 : 0 if defined $codeset && length $codeset;
    my ($name) = grep { defined && length } @ENV{qw(LC_ALL LC_CTYPE LANG)};
    return defined $name && $name =~ /utf-?8/i ? 1 : 0;
}

# a file's text; decoded from UTF-8 when $utf8 (a UTF-8 locale), so a
# file reads as what was typed would
sub _slurp ($file, $utf8 = 0) {
    open my $fh, $utf8 ? '<:encoding(UTF-8)' : '<', $file or return undef;
    local $/;
    return scalar(<$fh>) // '';
}

1;

__END__

=head1 NAME

XPerl::REPL - the xperl interactive shell

=head1 SYNOPSIS

    $ xperl-repl
    1> my @n = (3, 1, 2)
    (3, 1, 2)
    2> sort { $a <=> $b } @n
    (1, 2, 3)
    3> :quit

    $ xperl-repl -MList::Util=sum -e 'sum(1 .. 10)' < /dev/null
    55

    # from Perl
    use XPerl::REPL;
    use XPerl::REPL::Input;

    my $repl = XPerl::REPL->new(out => \*STDOUT, err => \*STDERR);
    $repl->set_input(XPerl::REPL::Input::Handle->new(fh => \*STDIN));
    exit $repl->run;

=head1 DESCRIPTION

C<XPerl::REPL> is the engine of F<xperl-repl>, the interactive shell
bundled with xperl.  It reads Perl one input at a time, evaluates it with
the C<-E> feature surface plus C<strict> and C<warnings>, and prints the
result.  Lexical variables, the current package and compile-time hints
(C<strict>, C<warnings>, features) persist from one input to the next.
It uses only modules from the core distribution.

An input that the parser reports as unfinished (an open block, string,
heredoc, or an expression ending in an operator) is continued with the
C<... > prompt.  A line ending in C<\> always continues.  At end of input,
or when a C<:command> line is typed during a continuation, the pending
input is submitted as it is.

Results print with C<Data::Dumper>, except that a result is a number or
a string by how it was created: numbers print bare (C<3.5>, not
C<"3.5">) and strings always quoted (C<"42">).  Errors and warnings print
as rendered C<XPerl::Exception>s, errors prefixed C<compile error:> or
C<error:>, and warnings as they happen, in order with the input's own output.
C<SIGINT> (ctrl-c) while an input runs aborts that input and prints
C<interrupted>; the session goes on.

On a terminal, input is read with L<Term::ReadLine::XPerl>, which gives
history, completion and the key bindings below.  Where that extension was
not built, F<xperl-repl> falls back to L<Term::ReadLine>'s stub and says
so once.  When standard input or output is not a terminal, lines are read
from standard input with no prompts and no editing, so
C<< xperl-repl < script.pl >> prints one result per input.

=head2 Characters

When the locale's character set is UTF-8 (its C<CODESET>, or else the
first of C<LC_ALL>, C<LC_CTYPE> and C<LANG> that is set), F<xperl-repl>
puts an C<:encoding(UTF-8)> layer on standard input, output and error
and decodes C<-e> code, the rc file and a script file.  What you type or
load is then characters, as under C<use utf8>: C<length "\x{3bb}">
written with the Greek letter is 1, and printing it gives no "Wide
character" warning.  The history file holds UTF-8.  In any other locale
input, files and output are bytes.

=head1 OPTIONS

    xperl-repl [-I dir]... [-M module]... [-e code]... [--rc file]
               [--no-rc] [--color=auto|always|never]
               [--out dumper|json|plain]
               [--render legacy|annotated|json] [--prompt format]
               [--continuation format] [--version] [--help] [file]

=over 4

=item -I dir

Add C<dir> to the front of C<@INC>.  May be repeated.

=item -M module

Run C<use module> in the session, so its exports are available at the
prompt.  As with F<perl>, C<-MFoo=a,b> imports C<a> and C<b>, and
C<-M-Foo> runs C<no Foo>.  May be repeated.  It is not numbered as an
input: an error in it names it as C<-M Foo>.

=item -e code

Evaluate C<code> as an input, in order, before the prompt appears; on a
terminal it is echoed with its prompt.  Each C<-e> is one whole input: an
unfinished one is an error, not continued.  May be repeated.

=item file

Evaluate the contents of C<file> as one input before the prompt appears.

=item --rc file, --no-rc

Read the rc file from C<file> instead of the default, or not at all.

=item --color=auto|always|never

Colour the prompt, errors and warnings.  C<auto> (the default) colours
only when standard input and output are terminals and C<NO_COLOR> is not
set, and picks 16, 256 or 24-bit colour from C<COLORTERM>, C<TERM> and
C<TERM_PROGRAM>.  C<always> colours even when C<NO_COLOR> is set.

=item --out dumper|json|plain

How results are printed, as with the C<:out> command.

=item --render legacy|annotated|json

How errors and warnings are printed, as with the C<:render> command.

=item --prompt format, --continuation format

The prompt and the continuation prompt, as with the C<:prompt> and
C<:continuation> commands; see L</PROMPTS>.

=item --version, --help

Print the version or the usage and exit.

=back

The command-line options C<--out>, C<--render>, C<--prompt> and
C<--continuation> are applied after the rc file, so they win over it.

=head1 COMMANDS

A line starting with C<:> and a letter is a command; C<:help> lists them
with the key bindings.  A line starting with C<::> is Perl (C<::foo()> is
C<main::foo()>).

=over 4

=item :help [cmd]

List the commands and keys, or describe one command.

=item :quit, :q

Leave the shell.  ctrl-d on an empty line does the same.

=item :vars

List the persisted lexical variables, each with a one-line dump of its
value.

=item :package [name]

Show the current package, or switch to C<name>.

=item :edit

Open the last input in C<$VISUAL>, else C<$EDITOR>, else F<vi>, and run
what is saved.  If the editor exits with a non-zero status, nothing is
run.  Only on a terminal.

=item :history [n]

Show the last C<n> inputs (default 20) with their input numbers.

=item :render [legacy|annotated|json]

Show or set how errors and warnings are rendered: C<legacy> is Perl's
usual one-line message (with a hint to use C<:stack> when there is more),
C<annotated> shows the structured diagnostic with its source context, and
C<json> the exception as JSON.

=item :out [dumper|json|plain]

Show or set how results are printed: C<dumper> (the default) with
C<Data::Dumper>, C<json> as pretty JSON, C<plain> as Perl would
stringify them.

=item :stack

Show the last error in full: every propagation group, annotated.

=item :reset

Forget all lexicals, return to package C<main> and the startup pragmas.

=item :prompt [format]

Show the prompt, or set it to C<format>: the rest of the line as typed,
trailing spaces included.  A prompt set from Perl as a code reference
shows as C<CODE>.  See L</PROMPTS>.

=item :continuation [format]

Show or set the continuation prompt, as C<:prompt> does.

=back

=head1 PROMPTS

The prompt is C<%n> followed by C<< > >> and the continuation prompt is
C<...>, both followed by a space and bold on a colour terminal.  Either
can be set with C<:prompt> and C<:continuation>, C<--prompt> and
C<--continuation>, or in the rc file:

    $REPL->prompt('%{muted}%t%{/} %p %n> ');
    $REPL->continuation('%{muted}...%{/} ');
    $REPL->prompt(sub ($repl) { $repl->evaluator->package . '> ' });

A format string is literal text with these escapes:

    %n               the number the next input gets
    %p               the current package
    %t               the local time, as HH:MM:SS
    %d               the last component of the current directory
    %%               a percent sign
    %{role}...%{/}   the text in the colour of a theme role

Any other C<%> is literal.  A C<%{role}> colour runs to C<%{/}>, the
next C<%{role}> or the end of the prompt; roles do not nest.  A format
without a C<%{role}> is drawn in the C<prompt> (or C<continuation>)
colour; one with a C<%{role}> only in the colours it names.

A code reference is called with the session each time the prompt is
drawn, and what it returns is the prompt, as is: it can colour parts
with C<< $repl->renderer->colorize($role, $text) >>.  Each time it dies
the default prompt is drawn instead; the error is printed, as
C<prompt callback failed: ...>, only the first time, or again after the
prompt is set.

Prompts are drawn only when standard input is a terminal.

=head1 KEYS

On a terminal, line editing follows readline and bash:

    tab                  complete
    up / down            history, matching the typed prefix
    ctrl-r               search history backwards
    ctrl-a / ctrl-e      start / end of line
    ctrl-b / ctrl-f      back / forward a character
    alt-b / alt-f        back / forward a word
    ctrl-k / ctrl-u      kill to end / to start of line
    ctrl-w / alt-d       kill a word back / forward
    ctrl-l               clear the screen
    ctrl-c               discard the input, or interrupt it while it runs
    ctrl-d               quit on an empty line, else delete a character
    ctrl-z               suspend the shell (fg resumes it)
    ctrl-x ctrl-e        edit the input in $VISUAL or $EDITOR, then run it
    alt-enter / ctrl-j   submit the input even if it looks unfinished

ctrl-c while typing a continuation line discards the whole pending
input, not just that line.  If C<$EDITOR> fails, ctrl-x ctrl-e keeps the
line as it was.

Tab completes C<:commands>, lexical variables (C<$a[> and C<$h{> find
C<@a> and C<%h>), package variables, subs and package names, methods
after C<< -> >> on a class name or a lexical holding an object, hash
keys and array indexes from live data (C<$h{>, C<< $r->{ >>, C<$a[>
and chains such as C<< $r->{a}[0]{ >> or C<$h{b}[>), then Perl's
keywords and builtin functions.  A second tab lists several matches.
After an array subscript, tab shows the array's index range above the
prompt as a hint, such as C<0..1> for two elements or C<3..11> after
C<$a[3> for twelve, and leaves the line as it is.  Keys and indexes
are only read, never computed: a walk stops at a tied value, a variable
subscript or a method call.  Listing a hash's keys resets its C<each>
iterator, so completing on a hash that a loop is walking with C<each>
starts that walk over.

=head1 FILES

=over 4

=item F<~/.xperl/replrc>

The rc file, or the file named by C<XPERL_REPL_RC>.  It is Perl,
evaluated quietly before C<-M>, C<-e> and the prompt, in the same session,
so its lexicals, imports and pragmas are visible at the prompt.  The
session object is available as C<$REPL>:

    $REPL->out('json');                  # as :out json
    $REPL->render('annotated');          # as :render annotated
    $REPL->theme(error => '#ff5f5f', prompt => 'bold green');
    use List::Util qw(sum max);

Theme roles are C<prompt>, C<continuation>, C<result>, C<error>,
C<warning>, C<hint> and C<muted>; a value is a space-separated list of
L<Term::ANSIColor> attribute names, colour numbers (0 to 255) and
C<#rrggbb> colours, reduced to what the terminal supports.  By default
results are green, errors red, warnings yellow and prompts bold.

When a second tab lists several completions, each is coloured by its
kind, with these roles and defaults:

    complete.command   bold           complete.package   cyan
    complete.scalar    green          complete.sub       bright_blue
    complete.array     bright_green   complete.method    bright_blue
    complete.hash      magenta        complete.keyword   bright_black
    complete.key       yellow         complete.builtin   bright_black
    complete.hint      bright_black

An array or hash offered as C<$name> (for C<$name[> or C<$name{>) is
coloured as an array or hash.

Errors in the rc file are printed, naming it as C<rc file>, and do not
stop startup; it is not numbered as an input.

=item F<~/.xperl/repl_history>

The history file, or the file named by C<XPERL_REPL_HISTORY>.  It is
loaded at startup and rewritten after every input, so it survives
C<exit> and a killed session; with two sessions open the last one to
write wins.  It is created with mode 0600 (its directory with 0700).

=back

=head1 PERSISTENCE

Each input is compiled as the body of a sub, in list context, with the
lexicals of earlier inputs aliased in.  After it runs, its top-level
C<my> variables are saved, even if the input died after declaring them;
variables declared in an inner block, a loop or a condition are not.
The package at the end of an input becomes the package of the next, and
so do C<strict>, C<warnings> and feature settings changed with C<use> or
C<no>.  An C<our> declaration is not saved: under C<strict>, declare it
again (or use the full name) in a later input.  A top-level C<our> also
ends a saved C<my> of the same name.

=head1 LIMITATIONS

=over 4

=item *

Lexical subs (C<my sub>) do not persist between inputs.  C<local> is
undone at the end of the input that ran it, and C<state> variables belong
to one input.

=item *

A named sub cannot see the saved lexicals of earlier inputs: each input is
compiled as an anonymous sub, and a named sub is created once, when that
input compiles, before the saved variables are aliased in.  So after
C<my $n = 42>, C<sub getn { $n }> warns that C<$n> is not available and
returns C<undef>.  Use a closure instead:

    my $getn = sub { $n };
    $getn->()

=item *

C<exit> in an input exits the shell with that status.

=item *

An unclosed anonymous hash (C<my $h = {>) is reported as a syntax error
rather than continued; end the line with C<\>, or submit with alt-enter
or ctrl-j, to continue it.  Each line of a continued input recompiles the
whole input, so C<use> and C<BEGIN> on its earlier lines run once per
line.

=item *

A syntax error at end of input that follows an earlier genuine error
(C<1 = = 2; foo(>) still reads as unfinished until the input is finished
or forced.

=item *

C<__END__>, C<__DATA__>, ctrl-d and ctrl-z characters are rejected
wherever a statement can start, including inside a string on the same
line as code, and an C<__END__> line inside a heredoc body.

=item *

While the editor waits for a key, C<%SIG> handlers run only when the next
key arrives.  A C<SIGTERM>, C<SIGHUP>, C<SIGQUIT> or C<SIGALRM> with no
handler still ends the process, after the editor restores the terminal.
Perl's safe signals mean a blocking system call or XS function cannot be
interrupted with ctrl-c.

=item *

A terminal that does not answer the cursor position query within
100 ms turns off, for the rest of the session, the check that starts the
prompt on a fresh line after output that did not end in a newline.

=back

=head1 METHODS

For embedding the engine; F<xperl-repl> is a thin wrapper round C<main>.

=over 4

=item XPerl::REPL->new(out => $fh, err => $fh, %opt)

A session writing results to C<out> and errors to C<err>.  Options:
C<input> (an input source), C<color_level> (0, 16, 256 or C<'rgb'>),
C<evaluator> and C<renderer>.

=item set_input($source)

Set the input source: C<XPerl::REPL::Input::List> (lines from an array),
C<XPerl::REPL::Input::Handle> (a filehandle) or
C<XPerl::REPL::Input::Tty> (the terminal, which needs the session, so it
is set after C<new>).

=item run

Read and evaluate inputs until the end of input or C<:quit>; returns 0.

=item step($text, %opt)

Evaluate one input as if typed.  With C<< echo => 1 >> the prompt and
text are printed first, with C<< whole => 1 >> an unfinished input is an
error rather than continued, and with C<< quiet => 1 >> its result is not
printed and it does not go into the history.

=item XPerl::REPL->main(\@ARGV)

Run F<xperl-repl> with the given arguments and return the exit status.

=item out($mode), render($mode), theme(%roles)

Set the result mode, the error mode and colours, as in the rc file.

=item prompt($spec), continuation($spec)

Set the prompt or the continuation prompt to a format string or a code
reference (see L</PROMPTS>); without an argument, return it.

=back

=head1 SEE ALSO

L<Term::ReadLine::XPerl>, L<XPerl::Exception>

=cut
