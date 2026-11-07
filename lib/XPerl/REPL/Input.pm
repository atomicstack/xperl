package XPerl::REPL::Input;

use v5.36;
use feature qw(class try);
no warnings qw(experimental::class experimental::try);

our $VERSION = '0.01';

# input sources for XPerl::REPL. each yields one physical line per
# next_line call, without its newline, and undef at end of input. List and
# Handle never touch a terminal and ignore the prompt they are given.

class XPerl::REPL::Input::List {
    field $lines :param;
    field $pos = 0;

    method next_line($prompt = undef) {
        return undef if $pos >= @$lines;
        return $lines->[ $pos++ ] =~ s/\r?\n\z//r;
    }

    method exhausted          { return $pos >= @$lines }
    method is_tty             { return 0 }
    method add_history($text) { return }
    method last_submit_forced { return 0 }
    method last_cancelled     { return 0 }
}

class XPerl::REPL::Input::Handle {
    field $fh :param;
    field $eof = 0;

    method next_line($prompt = undef) {
        return undef if $eof;
        local $/ = "\n";    # whatever the user's code set it to
        my $line = readline $fh;
        if (!defined $line) {
            $eof = 1;
            return undef;
        }
        return $line =~ s/\r?\n\z//r;
    }

    # true once a read has hit end of file; checking eof() up front would
    # block on a pipe or terminal.
    method exhausted          { return $eof }
    method is_tty             { return 0 }
    method add_history($text) { return }
    method last_submit_forced { return 0 }
    method last_cancelled     { return 0 }
}

# the terminal: lines come from Term::ReadLine::XPerl (or, where it was not
# built, Term::ReadLine's stub), which draws the prompt it is given.
# the history file is rewritten after every input, so it survives "exit"
# in user code and a killed process.
class XPerl::REPL::Input::Tty {
    field $repl         :param;
    field $in           :param = \*STDIN;
    field $out          :param = \*STDOUT;
    field $history_file :param = undef;
    field $term         :param :reader = undef;
    field $eof = 0;
    field $editor = 0;    # true when $term is Term::ReadLine::XPerl

    ADJUST {
        builtin::weaken($repl);    # the session owns us
        unless ($term) {
            if (eval { require Term::ReadLine::XPerl; 1 }) {
                $term = Term::ReadLine::XPerl->new('xperl-repl', $in, $out);
            }
            else {
                require Term::ReadLine;
                $term = Term::ReadLine->new('xperl-repl', $in, $out);
                $term->ornaments(0);    # the prompt is coloured already
                local ($\, $,);
                print { $repl->err } "line editing unavailable: Term::ReadLine::XPerl not built;"
                    . " history, completion and key bindings are off\n";
            }
        }
        $editor = $term->isa('Term::ReadLine::XPerl') ? 1 : 0;
        if ($editor) {
            my $session = $repl;
            builtin::weaken($session);
            my $attribs = $term->Attribs;
            $attribs->{completion_function} = sub ($buffer, $cursor) {
                require XPerl::REPL::Complete;
                # listing colours from the current theme, as the theme can
                # change between tabs
                my $renderer = $session->renderer;
                $attribs->{candidate_colors} = {
                    map {
                        my $sgr = XPerl::REPL::Render::sgr($renderer->theme->{"complete.$_"}, $renderer->color_level);
                        length $sgr ? ($_ => $sgr) : ();
                    } @XPerl::REPL::Complete::KINDS
                };
                return XPerl::REPL::Complete::complete($session, $buffer, $cursor);
            };
            $attribs->{key_bindings} = {
                "\x18\x05" => sub ($buffer, $cursor) {    # ctrl-x ctrl-e
                    return $session->commands->cmd_edit('', buffer => $buffer, cursor => $cursor);
                },
            };
            $term->ReadHistory($history_file)
                if defined $history_file && -f $history_file;
        }
    }

    method next_line($prompt = undef) {
        return undef if $eof;
        my $line;
        try { $line = $term->readline($prompt // '') }
        catch ($v, $e) {
            # a completion or key binding died; the editor has already
            # restored the terminal
            $repl->report_failure($v, $e);
            return '';
        }
        if (!defined $line) {
            $eof = 1;
            local ($\, $,);
            print {$out} "\n" unless $editor;    # the stub leaves the cursor after the prompt
            return undef;
        }
        # the edited text of ctrl-x ctrl-e may end in a newline
        return $line =~ s/\n+\z//r;
    }

    method exhausted { return $eof }
    method is_tty    { return 1 }

    # true when lines are characters: the input handle decodes UTF-8
    method characters {
        my $fh = $term->IN;
        return 0 unless defined $fh && defined fileno $fh;
        return scalar grep { /\A(?:utf8|encoding\(utf-?8)/i } PerlIO::get_layers($fh);
    }

    method add_history($text) {
        return unless $editor;
        $text =~ s/\n\z//;
        return unless length $text;
        $term->addhistory($text);
        $self->_write_history;
    }

    method _write_history {
        return unless defined $history_file;
        require File::Basename;
        require File::Path;
        my $dir = File::Basename::dirname($history_file);
        File::Path::make_path($dir, { mode => 0700 }) unless -d $dir;
        $term->WriteHistory($history_file);
    }

    method last_submit_forced { return $editor && $term->last_submit_forced ? 1 : 0 }
    method last_cancelled     { return $editor && $term->last_cancelled ? 1 : 0 }
}

1;

__END__

=head1 NAME

XPerl::REPL::Input - line sources for xperl-repl

=head1 DESCRIPTION

Internal to C<XPerl::REPL>. C<XPerl::REPL::Input::List> reads from an
array of lines, C<XPerl::REPL::Input::Handle> from a filehandle and
C<XPerl::REPL::Input::Tty> from the terminal through
C<Term::ReadLine::XPerl>. Each returns one line per C<next_line> call and
undef at end of input.

=cut
