package Term::ReadLine::XPerl;

use strict;
use warnings;
use IO::Handle ();
use Scalar::Util ();

our $VERSION = '0.01';

require XSLoader;
XSLoader::load();

sub _fd {
    my ($fh) = @_;
    my $fd = defined $fh ? fileno($fh) : undef;
    return defined $fd && $fd >= 0 ? $fd : -1;
}

sub new {
    my ($class, $appname, $in, $out) = @_;
    $in  //= \*STDIN;
    $out //= \*STDOUT;
    my $self = bless {
        appname => $appname,
        IN      => $in,
        OUT     => $out,
        attribs => {
            completion_function => undef,
            candidate_colors    => {},
            display_only_kinds  => ['hint'],
            key_bindings        => {},
            history_max         => 1000,
            multiline           => 1,
        },
        test_mode => 0,
    }, $class;
    $self->{c} = Term::ReadLine::XPerl::C->new(_fd($in), _fd($out));
    return $self;
}

sub ReadLine { 'Term::ReadLine::XPerl' }
sub IN       { $_[0]{IN} }
sub OUT      { $_[0]{OUT} }
sub MinLine  { undef }
sub Attribs  { $_[0]{attribs} }

sub Features {
    return {
        addhistory   => 1,
        readHistory  => 1,
        writeHistory => 1,
        getHistory   => 1,
        attribs      => 1,
        autohistory  => 0,
        completion   => 1,
        key_bindings => 1,
        multiline    => 1,
        ornaments    => 0,
    };
}

sub last_submit_forced { $_[0]{forced} ? 1 : 0 }
sub last_cancelled     { $_[0]{cancelled} ? 1 : 0 }

sub _test_mode {
    my ($self, $cols, $rows) = @_;
    $self->{test_mode} = 1;
    $self->{c}->set_test_mode($cols // 80, $rows // 24);
    return;
}

sub _feed_keys  { $_[0]{c}->feed($_[1]); return }
sub _raw_active { $_[0]{c}->raw_active ? 1 : 0 }
sub _signals_trapped { $_[0]{c}->signals_trapped }
sub _suspends { $_[0]{c}->suspends }

sub _sync_history_max {
    my ($self) = @_;
    my $max = $self->{attribs}{history_max};
    $self->{c}->history_set_max(defined $max ? $max : 1000);
}

sub _key_name {
    my ($k) = @_;
    $k =~ s/([^\x21-\x7e])/sprintf '\\x%02x', ord $1/ge;
    return "'$k'";
}

sub _offset {
    my ($what, $n, $len) = @_;
    die "$what returned a non-numeric offset\n"
        unless defined $n && !ref $n && Scalar::Util::looks_like_number($n);
    $n = int $n;
    return $n < 0 ? 0 : $n > $len ? $len : $n;
}

# The C editor works on bytes.  Everything handed back to it is converted
# here, inside the callback the XS runs under G_EVAL, so a bad value dies
# into that eval and the editor unwinds and restores the terminal.
sub readline {
    my ($self, $prompt, $preload) = @_;
    $self->{forced} = $self->{cancelled} = 0;
    my $in = $self->{IN};
    unless ($self->{test_mode} || -t $in) {
        # no terminal: read through PerlIO so in-memory handles, pipes,
        # files and any layers on IN all behave as perl's own readline
        local $/ = "\n";
        my $line = CORE::readline($in);
        return undef unless defined $line;
        chomp $line;
        return $line;
    }
    my $attr = $self->{attribs};
    my $utf8 = _is_utf8_handle($in);
    # with a :utf8 IN handle the caller and its callbacks see characters
    # and character offsets; otherwise bytes, except that a string holding
    # wide characters is sent as UTF-8
    my $wide = sub { $utf8 || utf8::is_utf8($_[0]) };
    my $enc  = sub {
        my $s = defined $_[0] ? "$_[0]" : '';
        utf8::encode($s) if $wide->($s);
        $s;
    };
    my $dec = sub { my $s = $_[0]; utf8::decode($s) if $utf8 && defined $s; $s };
    my $c2b = sub { $wide->($_[0]) ? length $enc->(substr $_[0], 0, $_[1]) : $_[1] };
    my $b2c = sub { $utf8 ? length $dec->(substr $_[0], 0, $_[1]) : $_[1] };

    my $complete;
    if (my $cf = $attr->{completion_function}) {
        $complete = sub {
            my ($buf, $cursor) = @_;
            my $text = $dec->($buf);
            my $at   = $b2c->($buf, $cursor);
            my ($words, $start, $kinds) = $cf->($text, $at);
            return unless ref $words eq 'ARRAY';
            $start = _offset('completion_function', $start // 0, $at);
            # each word with its kind's colour for listings ('' for plain)
            # and whether its kind is display-only
            undef $kinds unless ref $kinds eq 'ARRAY' && @$kinds == @$words;
            my $colors = ref $attr->{candidate_colors} eq 'HASH' ? $attr->{candidate_colors} : {};
            my $only = $attr->{display_only_kinds};
            my %display = map { $_ => 1 } ref $only eq 'ARRAY' ? @$only : ();
            my @triples;
            for my $i (0 .. $#$words) {
                my $kind  = $kinds ? $kinds->[$i] : undef;
                my $color = defined $kind ? $colors->{$kind} : undef;
                push @triples, $enc->($words->[$i]), defined $color ? $enc->($color) : '',
                    defined $kind && $display{$kind} ? 1 : 0;
            }
            return ($c2b->($text, $start), @triples);
        };
    }

    my $kb = $attr->{key_bindings};
    my ($dispatch, @seqs);
    if (ref $kb eq 'HASH' && %$kb) {
        @seqs = grep { length } keys %$kb;
        $dispatch = sub {
            my ($seq, $buf, $cursor) = @_;
            my ($r) = $kb->{$seq}->($dec->($buf), $b2c->($buf, $cursor));
            return () unless defined $r;
            my $what = 'key binding ' . _key_name($seq);
            die "$what returned an unsupported value\n" unless ref $r eq 'HASH';
            return ('submit', $enc->($r->{submit}), $r->{force} ? 1 : 0)
                if exists $r->{submit};
            die "$what returned an unsupported value\n"
                unless exists $r->{buffer};
            my $text = defined $r->{buffer} ? "$r->{buffer}" : '';
            my $at   = _offset($what, $r->{cursor} // length $text, length $text);
            return ('edit', $enc->($text), $c2b->($text, $at));
        };
    }

    $self->_sync_history_max;
    my $out = $self->{OUT};
    IO::Handle::flush($out) if defined $out && defined fileno($out);
    my $c = $self->{c};
    $c->set_cursor_query($attr->{test_cursor_query} ? 1 : 0)
        if $self->{test_mode};
    my $line = $c->readline($enc->($prompt), $enc->($preload), $complete,
                            $dispatch, \@seqs, $attr->{multiline} // 1);
    $self->{forced}    = $c->last_submit_forced;
    $self->{cancelled} = $c->last_cancelled;
    return $dec->($line);
}

sub _is_utf8_handle {
    my ($fh) = @_;
    return 0 unless defined $fh && defined fileno($fh);
    return scalar grep { /\A(?:utf8|encoding\(utf-?8)/i }
        PerlIO::get_layers($fh);
}

sub addhistory {
    my ($self, $text) = @_;
    $self->_sync_history_max;
    return unless defined $text;
    # history is UTF-8 bytes when IN is a UTF-8 handle, as GetHistory
    # decodes it then; a wide string is UTF-8 in any case
    if (_is_utf8_handle($self->{IN}) || utf8::is_utf8($text)) {
        $text = "$text";
        utf8::encode($text);
    }
    $self->{c}->history_add($text);
    return;
}

sub GetHistory {
    my ($self) = @_;
    $self->_sync_history_max;
    my @h = $self->{c}->history_list;
    if (_is_utf8_handle($self->{IN})) {
        utf8::decode($_) for @h;
    }
    return @h;
}

sub ReadHistory {
    my ($self, $file) = @_;
    $self->_sync_history_max;
    return $self->{c}->history_load($file) ? 1 : 0;
}

sub WriteHistory {
    my ($self, $file) = @_;
    $self->_sync_history_max;
    return $self->{c}->history_save($file) ? 1 : 0;
}

sub DESTROY {
    my ($self) = @_;
    delete $self->{c};
}

1;
__END__

=head1 NAME

Term::ReadLine::XPerl - the line editor bundled with xperl

=head1 SYNOPSIS

    use Term::ReadLine::XPerl;

    my $term = Term::ReadLine::XPerl->new('myapp', \*STDIN, \*STDOUT);
    $term->ReadHistory("$ENV{HOME}/.myapp_history");
    while (defined(my $line = $term->readline('> '))) {
        $term->addhistory($line) if length $line;
        ...
    }
    $term->WriteHistory("$ENV{HOME}/.myapp_history");

=head1 DESCRIPTION

C<Term::ReadLine::XPerl> is a small line editor written in C and bundled
with the xperl core.  It provides the L<Term::ReadLine> method set without
any external library: no readline, libedit, ncurses or terminfo.  It
drives the terminal with C<termios> and a VT100 escape subset, so it is
available on Unix-like systems only.

When the input handle is not a terminal, C<readline> reads one line
through the handle's own PerlIO layers, with no prompt, no echo and no
editing.  This is what pipes, files and in-memory handles get.

=head1 METHODS

=over 4

=item new($appname, $in = \*STDIN, $out = \*STDOUT)

Creates an editor reading from C<$in> and drawing on C<$out>.

=item ReadLine

Returns C<'Term::ReadLine::XPerl'>.

=item readline($prompt, $preload = '')

Reads one line and returns it without its newline, or C<undef> at end of
input.  C<readline> never adds to the history by itself; call
C<addhistory>.

=item addhistory($text)

Appends C<$text> to the history unless it repeats the newest entry.  Once
the history holds C<history_max> entries the oldest is dropped.

=item GetHistory

Returns the history entries, oldest first.

=item ReadHistory($file)

=item WriteHistory($file)

Load the history from, or save it to, C<$file>, returning true on
success.  The file holds one entry per line; a newline inside an entry is
written as C<\n> and a backslash as C<\\>.  C<WriteHistory> creates the
file with mode 0600.  It writes a new file beside C<$file> and renames it
over the old one, so an interrupted write leaves the old history whole.

=item Features

Returns a hash ref describing the supported features: C<addhistory>,
C<readHistory>, C<writeHistory>, C<getHistory>, C<attribs>, C<completion>,
C<key_bindings> and C<multiline> are true; C<autohistory> and C<ornaments>
are false.

=item Attribs

Returns the hash ref of settings, read at each call that needs them:

=over 4

=item completion_function

A code ref called when tab is pressed, as C<< $cb->($buffer, $cursor) >>,
where C<$cursor> is the offset of the cursor in C<$buffer>.  It returns
C<(\@words, $start)>: the candidate replacements and the offset where the
word being completed starts.  One candidate replaces the text from
C<$start> to the cursor.  With several, the first tab inserts their
longest common prefix and a second tab lists them in columns below the
line, then redraws it.  With none, the terminal bell rings.  A non-numeric
C<$start> makes C<readline> die.  The callback runs with the terminal in
raw mode.

It may return a third value, C<\@kinds>: one name per word (any string,
such as C<package> or C<key>), which C<candidate_colors> maps to
colours for the listing and C<display_only_kinds> can mark as shown but
never inserted.  Kinds of a different length from the words are
ignored.

=item candidate_colors

A hash ref mapping a kind from C<completion_function> to the escape
sequence that starts its colour, such as C<"\e[36m">.  A listed word
whose kind has an entry is written in that colour followed by
C<"\e[0m">; other words are plain.  The colours do not count towards
column widths, and inserted text is never coloured.

=item display_only_kinds

An array ref of kinds whose words are shown but never inserted, by
default C<['hint']>: a hint such as an index range.  When the candidates
include any, the first tab inserts what the other candidates agree on
(the one candidate, or their longest common prefix) and lists every
word, hints included; with only hints the line is left as it is.

=item key_bindings

A hash ref mapping key sequences to code refs.  A key is the byte sequence
the terminal sends, such as C<"\x18\x05"> for ctrl-x ctrl-e or C<"\ex"> for
alt-x.  When the input matches a key, the editor moves to a fresh row,
restores the terminal from raw mode and calls C<< $cb->($buffer, $cursor) >>.  The callback returns one of:

=over 4

=item C<undef> (or an empty list)

Nothing changes; the line is redrawn.

=item C<< { buffer => $text, cursor => $offset } >>

Replace the line and continue editing.  C<cursor> defaults to the end.

=item C<< { submit => $text, force => $bool } >>

Return C<$text> from C<readline>, with C<last_submit_forced> set to
C<$force>.

=back

Any other value, or a non-numeric C<cursor>, makes C<readline> die.

If the callback dies, the exception propagates out of C<readline> with
the terminal already restored, as it does for C<completion_function>.

=item multiline

When true (the default), newlines in the buffer, from a recalled history
entry or a key binding, are drawn as new rows indented by the prompt
width.  When false they are drawn as C<^J>.

=item history_max

The maximum number of history entries, default 1000.

=back

=item IN

=item OUT

The input and output handles.

=item MinLine

Returns C<undef>; history is never added automatically.

=item last_cancelled

True when the last C<readline> was ended by ctrl-c.

=item last_submit_forced

True when the line returned by the last C<readline> was submitted with
alt-enter, ctrl-j or a key binding that asked for it.

=back

=head1 EDITING KEYS

On a terminal C<readline> puts the terminal in raw mode for the duration
of the call and restores it on every return path, and from an C<atexit>
handler.  While it is raw, C<SIGTERM>, C<SIGHUP>, C<SIGQUIT> and
C<SIGALRM> are trapped if they have no handler (neither a C<%SIG> entry
nor C<IGNORE>): the trap restores the terminal and then lets the signal
end the process as it would have.  C<_signals_trapped> returns how many
are trapped at the moment, for tests.  The keys follow readline/bash
conventions:

=over 4

=item enter

Submit the line.

=item ctrl-a, home

Move to the start of the line.

=item ctrl-e, end

Move to the end of the line.

=item ctrl-b, left

Move back one character.

=item ctrl-f, right

Move forward one character.

=item alt-b

Move back to the start of a word.

=item alt-f

Move forward to the end of a word.

=item backspace, ctrl-h

Delete the character before the cursor.

=item delete

Delete the character under the cursor.

=item ctrl-d

Delete the character under the cursor; on an empty line, end of input (readline returns undef).

=item ctrl-k

Kill to the end of the line.

=item ctrl-u

Kill to the start of the line.

=item ctrl-w

Kill the whitespace-delimited word before the cursor.

=item alt-d

Kill to the end of the word after the cursor.

=item ctrl-l

Clear the screen and redraw.

=item ctrl-z

Suspend the process (C<SIGTSTP>) with the terminal restored, as the
terminal itself would outside raw mode; on resume the line is redrawn
on a fresh row.  In test mode C<_suspends> counts the presses instead.

=item ctrl-c

Discard the line: readline returns an empty string and last_cancelled is true.

=item up, down

Walk the history.  Only entries that start with the text typed before
the first up are visited; down past the newest entry brings that text
back.

=item ctrl-r

Incremental reverse history search.  Typed characters extend the search
text, ctrl-r finds an older match and backspace shortens the text.
Enter accepts the match and submits it, ctrl-g or ctrl-c returns to the
original line, and any other key accepts the match and then acts on it.

=item tab

Complete, through C<completion_function>.

=item alt-enter, ctrl-j

Submit the line with C<last_submit_forced> set, for callers that would
otherwise ask for more input.

=back

A word, for alt-b, alt-f and alt-d, is a run of C<\w> characters (ASCII
letters, digits and underscore, plus any non-ASCII character), as in GNU
readline: alt-f skips non-word characters and then word characters, so
with the cursor at the start of C<one two>, alt-f stops after C<one> and
a following alt-d kills C< two>.  ctrl-w instead kills back to the
previous whitespace, so it removes C<$foo-E<gt>bar> as one unit.

=head1 CHARACTERS AND DISPLAY

The editor works on UTF-8.  Cursor motion and deletion move by whole
code points, and the display width of each character comes from a small
built-in table: East Asian wide and fullwidth characters and emoji take
two columns, combining marks none.  Escape sequences in the prompt, such
as the SGR colour codes C<"\e[1m"> and C<"\e[0m">, take no columns, so a
coloured prompt lines up.

C<readline> returns a byte string, unless the C<IN> handle has a
C<:utf8> or C<:encoding(UTF-8)> layer: then it returns characters,
C<GetHistory> returns characters, and C<completion_function> and
C<key_bindings> callbacks receive characters with character offsets.
Without such a layer they work on bytes, but a word, buffer or submitted
text that contains wide characters is sent to the terminal as UTF-8.

On a terminal, C<readline> first asks for the cursor position.  If earlier
output left the cursor in the middle of a line, the prompt starts on a
new one.

=head1 TESTING

C<_test_mode($cols = 80, $rows = 24)> makes the editor behave as a
terminal of that size without touching C<termios>, and C<_feed_keys($bytes)>
queues raw key bytes for it to read.  Once the queue is empty,
C<readline> returns C<undef> as at end of input.  The drawing escapes
are written to C<OUT>, so a test can inspect them.  With
C<< Attribs->{test_cursor_query} >> true, test mode also sends the cursor
position query and reads the reply from the queue.  C<_raw_active>
reports whether the editor is in raw mode.  These are for tests only.

=head1 SEE ALSO

L<Term::ReadLine>, L<XPerl::REPL>, which uses this editor for
F<xperl-repl>.

=cut
