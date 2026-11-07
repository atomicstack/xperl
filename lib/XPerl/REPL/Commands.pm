package XPerl::REPL::Commands;

use v5.36;
use feature qw(class try);
no warnings qw(experimental::class experimental::try);

use XPerl::REPL::Complete ();

our $VERSION = '0.01';

# name => [usage after the name, one-line description]
my %COMMANDS = (
    help    => ['[cmd]',                     'list commands and keys, or describe one command'],
    quit    => ['',                          'exit the repl'],
    vars    => ['',                          'list persisted lexical variables'],
    package => ['[name]',                    'show or set the current package'],
    edit    => ['',                          'edit the last input in $VISUAL or $EDITOR, then run it'],
    history => ['[n]',                       'show the last n inputs (default 20)'],
    render  => ['[legacy|annotated|json]',   'show or set how errors and warnings are rendered'],
    out     => ['[dumper|json|plain]',       'show or set how results are printed'],
    prompt       => ['[format]',             'show or set the prompt format'],
    continuation => ['[format]',             'show or set the continuation prompt format'],
    stack   => ['',                          'show the last error in full'],
    reset   => ['',                          'forget lexicals, package and pragmas'],
);
my %ALIASES = (q => 'quit');

# commands whose argument is the rest of the line as typed: trailing
# spaces are part of a prompt
my %VERBATIM = map { $_ => 1 } qw(prompt continuation);

my @KEYS = (
    ['tab',                             'complete'],
    ['up / down',                       'history, matching the typed prefix'],
    ['ctrl-r',                          'search history backwards'],
    ['ctrl-a / ctrl-e',                 'start / end of line'],
    ['ctrl-b / ctrl-f / alt-b / alt-f', 'back / forward a character or word'],
    ['ctrl-k / ctrl-u / ctrl-w / alt-d', 'kill to end / to start / word back / word forward'],
    ['ctrl-l',                          'clear the screen'],
    ['ctrl-c',                          'discard the input, or interrupt it while it runs'],
    ['ctrl-d',                          'quit on an empty line, else delete a character'],
    ['ctrl-z',                          'suspend the shell (fg resumes it)'],
    ['ctrl-x ctrl-e',                   'edit the input in $VISUAL or $EDITOR'],
    ['alt-enter / ctrl-j',              'submit the input even if it looks unfinished'],
);

sub _label ($name) {
    my $label = ":$name";
    $label .= ", :$_" for sort grep { $ALIASES{$_} eq $name } keys %ALIASES;
    $label .= " $COMMANDS{$name}[0]" if length $COMMANDS{$name}[0];
    return $label;
}

class XPerl::REPL::Commands {
    field $repl :param :reader;

    ADJUST {
        builtin::weaken($repl);    # the session owns us
    }

    method names { return sort keys %COMMANDS }

    method describe($name) { return $COMMANDS{$name}[1] }

    method help_text {
        my @names = $self->names;
        my $width = 0;
        for my $len ((map { length _label($_) } @names), (map { length $_->[0] } @KEYS)) {
            $width = $len if $len > $width;
        }
        my $text = "commands:\n";
        $text .= sprintf "  %-*s  %s\n", $width, _label($_), $COMMANDS{$_}[1] for @names;
        $text .= "\nkeys:\n";
        $text .= sprintf "  %-*s  %s\n", $width, @$_ for @KEYS;
        $text .= "\ncompletion listings are coloured by kind, with the theme roles\n";
        my @roles = map { "complete.$_" } @XPerl::REPL::Complete::KINDS;
        while (my @line = splice @roles, 0, 4) {
            $text .= '  ' . join(' ', @line) . "\n";
        }
        return $text;
    }

    # true when $line is a :command (known or not); false for Perl,
    # including "::name" which is main::name
    method dispatch($line) {
        my ($name, $args) = $line =~ /\A:([a-z]\w*)(.*)\z/s or return 0;
        $name = $ALIASES{$name} // $name;
        $args =~ s/\A\s+//;
        $args =~ s/\s+\z// unless $VERBATIM{$name};
        unless ($COMMANDS{$name}) {
            $self->_error("unknown command :$name, try :help");
            return 1;
        }
        my $method = "cmd_$name";
        try { $self->$method($args) }
        catch ($v, $e) { $self->_error($e->render =~ s/\n\z//r) }
        return 1;
    }

    # the user's $\ and $, do not apply to the repl's own output
    method _print(@text) { local ($\, $,); print { $repl->out } @text }

    method _error($text) {
        local ($\, $,);
        print { $repl->err } $repl->renderer->colorize(error => "$text\n");
    }

    method cmd_help($args) {
        return $self->_print($self->help_text) unless length $args;
        my $name = $args =~ s/\A://r;
        $name = $ALIASES{$name} // $name;
        return $self->_error("unknown command :$name, try :help") unless $COMMANDS{$name};
        $self->_print(sprintf "  %s  %s\n", _label($name), $COMMANDS{$name}[1]);
    }

    method cmd_quit($args) { $repl->quit }

    method cmd_vars($args) {
        my $env = $repl->evaluator->env;
        my $renderer = $repl->renderer;
        for my $name (sort keys %$env) {
            my $ref = $env->{$name};
            my $text = $renderer->dump_value($name =~ /\A\$/ ? $$ref : $ref);
            # one line: with Useqq, Dumper only puts newlines between tokens
            $text =~ s/([\[\{])\n\s*/$1/g;
            $text =~ s/\n\s*([\]\}])/$1/g;
            $text =~ s/,\n\s*/, /g;
            $text =~ s/\n\s*/ /g;
            $self->_print("$name = ", $text =~ s/\s*\z//r, "\n");
        }
    }

    method cmd_package($args) {
        return $self->_print($repl->evaluator->package, "\n") unless length $args;
        $repl->evaluator->set_package($args);
    }

    # from ":edit", the last input is edited and then run. from the
    # ctrl-x ctrl-e binding (buffer => ..., cursor => ...), the buffer is
    # edited and the result is handed back to the line editor to submit.
    method cmd_edit($args, %from) {
        return $self->_error(':edit needs a terminal') unless $repl->input->is_tty;
        my $binding = exists $from{buffer};
        my $text = $binding ? $from{buffer} : ($repl->history->[-1] // '');
        my $kept = $binding ? { buffer => $from{buffer}, cursor => $from{cursor} } : undef;

        require File::Temp;
        my $tmp = File::Temp->new(TEMPLATE => 'xperl-repl-XXXX', SUFFIX => '.pl', TMPDIR => 1);
        $text =~ s/\n*\z/\n/;
        utf8::encode($text) if utf8::is_utf8($text);
        { local ($\, $,); print {$tmp} $text; }
        close $tmp;

        my $editor = $ENV{VISUAL} // $ENV{EDITOR} // 'vi';
        system((split ' ', $editor), $tmp->filename);
        if ($? == -1) {
            $self->_error("could not run $editor: $!, input kept");
            return $kept;
        }
        if ($?) {
            my $status = $? & 127 ? 'signal ' . ($? & 127) : $? >> 8;
            $self->_error("editor exited with status $status, input kept");
            return $kept;
        }

        open my $fh, '<', $tmp->filename or do {
            $self->_error("cannot read back @{[ $tmp->filename ]}: $!, input kept");
            return $kept;
        };
        my $edited = do { local $/; <$fh> } // '';
        utf8::decode($edited) if $repl->input->characters;
        $edited =~ s/\n+\z//;
        return { submit => $edited, force => 0 } if $binding;
        $repl->step($edited, echo => 1) if length $edited;
        return;
    }

    method cmd_history($args) {
        return $self->_error('usage: :history [n]') unless $args =~ /\A\d*\z/;
        my $count = length $args ? $args : 20;
        my @history = @{ $repl->history };
        my @numbers = @{ $repl->history_numbers };
        my $first = @history > $count ? @history - $count : 0;
        for my $i ($first .. $#history) {
            my $text = $history[$i] =~ s/\n\z//r;
            $text =~ s/\n/\n    /g;
            $self->_print($numbers[$i], "> $text\n");
        }
    }

    method cmd_render($args) {
        return $self->_print($repl->renderer->render_mode, "\n") unless length $args;
        $repl->renderer->set_render_mode($args);
    }

    method cmd_out($args) {
        return $self->_print($repl->renderer->out_mode, "\n") unless length $args;
        $repl->renderer->set_out_mode($args);
    }

    method cmd_stack($args) {
        my $last = $repl->last_error or return $self->_print("no error yet\n");
        my $renderer = $repl->renderer;
        my $text = $last->exception
            ? $renderer->format_exception($last->exception, mode => 'annotated', full => 1)
            : $renderer->format_exception($last->value);
        local ($\, $,);
        print { $repl->err } $renderer->colorize(error => $text);
    }

    method cmd_reset($args) { $repl->evaluator->reset }

    method cmd_prompt($args)       { $self->_spec(prompt => $args) }
    method cmd_continuation($args) { $self->_spec(continuation => $args) }

    method _spec($which, $args) {
        return $repl->$which($args) if length $args;
        my $spec = $repl->$which;
        $self->_print(ref $spec ? 'CODE' : $spec, "\n");
    }
}

1;

__END__

=head1 NAME

XPerl::REPL::Commands - the xperl-repl :commands

=head1 DESCRIPTION

Internal to C<XPerl::REPL>. A line starting with C<:> and a letter is a
command; C<:help> lists them. Lines starting with C<::> are Perl.

=cut
