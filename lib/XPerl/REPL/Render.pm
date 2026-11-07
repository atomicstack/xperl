package XPerl::REPL::Render;

use v5.36;
use feature qw(class try);
no warnings qw(experimental::class experimental::try);

use Cpanel::JSON::XS ();
use Data::Dumper ();
use Term::ANSIColor ();

our $VERSION = '0.01';

my @NAMES16 = qw(
    black red green yellow blue magenta cyan white
    bright_black bright_red bright_green bright_yellow
    bright_blue bright_magenta bright_cyan bright_white
);

# the standard xterm values of the 16 ANSI colours
my @RGB16 = (
    [0, 0, 0],       [205, 0, 0],     [0, 205, 0],     [205, 205, 0],
    [0, 0, 238],     [205, 0, 205],   [0, 205, 205],   [229, 229, 229],
    [127, 127, 127], [255, 0, 0],     [0, 255, 0],     [255, 255, 0],
    [92, 92, 255],   [255, 0, 255],   [0, 255, 255],   [255, 255, 255],
);

my @CUBE = (0, 95, 135, 175, 215, 255);

my %DEFAULT_THEME = (
    prompt       => 'bold',
    continuation => 'bold',
    result       => 'green',
    error        => 'red',
    warning      => 'yellow',
    hint         => 'cyan',
    muted        => 'bright_black',
    # completion listings, by candidate kind
    'complete.command' => 'bold',
    'complete.scalar'  => 'green',
    'complete.array'   => 'bright_green',
    'complete.hash'    => 'magenta',
    'complete.key'     => 'yellow',
    'complete.package' => 'cyan',
    'complete.sub'     => 'bright_blue',
    'complete.method'  => 'bright_blue',
    'complete.keyword' => 'bright_black',
    'complete.builtin' => 'bright_black',
    'complete.hint'    => 'bright_black',
);

my %DEFAULT_SPECS = (prompt => '%n> ', continuation => '... ');

my %OUT_MODES    = map { $_ => 1 } qw(dumper json plain);
my %RENDER_MODES = map { $_ => 1 } qw(legacy annotated json);

my $JSON = Cpanel::JSON::XS->new->canonical->pretty
    ->allow_blessed->convert_blessed->allow_nonref;

sub _distance ($p, $q) {
    return ($p->[0] - $q->[0])**2 + ($p->[1] - $q->[1])**2 + ($p->[2] - $q->[2])**2;
}

sub _index_rgb ($i) {
    return $RGB16[$i] if $i < 16;
    if ($i >= 232) {
        my $v = 8 + 10 * ($i - 232);
        return [$v, $v, $v];
    }
    $i -= 16;
    return [ $CUBE[int($i / 36)], $CUBE[int($i / 6) % 6], $CUBE[$i % 6] ];
}

# nearest xterm 256-colour index: the 6x6x6 cube or the 24-step grey ramp
sub nearest_256 ($red, $green, $blue) {
    my @want = ($red, $green, $blue);
    my @level = map {
        my $c = $_;
        my ($best) = sort { abs($CUBE[$a] - $c) <=> abs($CUBE[$b] - $c) } 0 .. 5;
        $best;
    } @want;
    my $cube = 16 + 36 * $level[0] + 6 * $level[1] + $level[2];
    my $avg = ($red + $green + $blue) / 3;
    my $step = $avg <= 8 ? 0 : $avg >= 238 ? 23 : int(($avg - 8) / 10 + 0.5);
    my $grey = 232 + $step;
    return _distance(_index_rgb($grey), \@want) < _distance(_index_rgb($cube), \@want)
        ? $grey : $cube;
}

# nearest of the 16 ANSI colours, as a Term::ANSIColor name
sub nearest_16 ($red, $green, $blue) {
    my @want = ($red, $green, $blue);
    my ($best) = sort { _distance($RGB16[$a], \@want) <=> _distance($RGB16[$b], \@want) } 0 .. 15;
    return $NAMES16[$best];
}

sub _name_param ($name) {
    my $esc;
    try { $esc = Term::ANSIColor::color($name) }
    catch ($v, $e) { die "unknown colour \"$name\"\n" }
    return $esc =~ s/\A\e\[//r =~ s/m\z//r;
}

# escape sequence for a colour spec at a terminal colour level (0, 16,
# 256 or 'rgb'). a spec is space-separated tokens, each an ANSI attribute
# name ("bold", "red", "bright_black"), a 0-255 index, or "#rrggbb";
# indexes and rgb values are mapped down to what the level supports.
sub sgr ($spec, $level) {
    return '' if !$level || !defined $spec || $spec eq '';
    my $rgb = $level eq 'rgb';
    my @params;
    for my $tok (split ' ', $spec) {
        if ($tok =~ /\A#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})\z/i) {
            my @c = map { hex } $1, $2, $3;
            push @params, $rgb           ? '38;2;' . join(';', @c)
                        : $level >= 256  ? '38;5;' . nearest_256(@c)
                        :                  _name_param(nearest_16(@c));
        }
        elsif ($tok =~ /\A\d+\z/) {
            die "unknown colour \"$tok\"\n" if $tok > 255;
            push @params, $rgb || $level >= 256 ? "38;5;$tok"
                        : $tok < 16             ? _name_param($NAMES16[$tok])
                        :                         _name_param(nearest_16(@{ _index_rgb($tok) }));
        }
        else {
            push @params, _name_param($tok);
        }
    }
    return "\e[" . join(';', @params) . 'm';
}

# a delivery-group record whose diagnostics are all the compilation-
# aborted summary
sub _only_aborted ($record) {
    my @codes = map { $_->{code} // '' } @{ $record->{contents} // [] };
    return @codes && !grep { $_ ne 'ERROR_COMPILATION_EXECUTION_ABORTED' } @codes;
}

# the generated source's file names read "input N", and its #line
# directive, which perl can quote as "near" text, is dropped
sub _tidy ($text) {
    # the generated tail's file: xperl-repl-end- and the escaped label
    $text =~ s{\bxperl-repl-end-(\S+)}{ $1 =~ s/%([0-9A-F]{2})/chr hex $1/ger }ge;
    # the input's own file: "xperl-repl input 7", "xperl-repl rc file",
    # "xperl-repl -M Foo"
    $text =~ s/\bxperl-repl (?=input \d|rc file\b|-M )//g;
    $text =~ s/#line \d+ "(?:input \d+|rc file|-M [^"\n]*)"\n//g;
    return $text;
}

# a group record or diagnostic list made only of warnings
sub _all_warnings (@codes) {
    return @codes && !grep { !/\AWARNING_/ } @codes;
}
sub _record_codes ($record) { return map { $_->{code} // '' } @{ $record->{contents} // [] } }

# _tidy applied to every string in decoded JSON data (file names in
# locations and parameters)
sub _tidy_data ($d) {
    return [ map { _tidy_data($_) } @$d ] if ref $d eq 'ARRAY';
    return { map { $_ => _tidy_data($d->{$_}) } keys %$d } if ref $d eq 'HASH';
    return defined $d && !ref $d && $d =~ /xperl-repl/ ? _tidy($d) : $d;
}

# print as the repl's own output: the user's $\ and $, do not apply
sub _emit ($fh, @text) {
    local ($\, $,);
    print {$fh} @text;
}

sub _string ($v) { return defined $v ? "$v" : undef }

# a copy of $v that Cpanel::JSON::XS can encode: class objects become
# their field hashes; code refs, globs and other non-data references
# become their string form and set $$lossy.
sub _jsonable ($v, $lossy, $seen) {
    return $v unless ref $v;
    my $id = builtin::refaddr($v);
    if ($seen->{$id}) {
        $$lossy = 1;
        return "$v";
    }
    local $seen->{$id} = 1;
    if (builtin::is_class_object($v)) {
        my $h = builtin::class_object_to_hash($v);
        delete $h->{'$self'};
        return _jsonable($h, $lossy, $seen);
    }
    return $v if builtin::blessed($v);     # TO_JSON or null via the encoder
    my $type = builtin::reftype($v);
    return [ map { _jsonable($_, $lossy, $seen) } @$v ] if $type eq 'ARRAY';
    return { map { $_ => _jsonable($v->{$_}, $lossy, $seen) } keys %$v } if $type eq 'HASH';
    return $v if $type eq 'SCALAR' && !ref $$v && defined $$v && $$v =~ /\A[01]\z/;   # JSON booleans
    $$lossy = 1;
    return "$v";
}

class XPerl::REPL::Render {
    field $out         :param;
    field $err         :param;
    field $color_level :param :reader = 0;
    field $theme       :param :reader = {};
    field $out_mode    :reader = 'dumper';
    field $render_mode :reader = 'legacy';
    field $session;
    field %specs = %DEFAULT_SPECS;
    field %failed;    # roles whose code ref spec died and was reported

    ADJUST {
        $theme = { %DEFAULT_THEME, %$theme };
    }

    method set_out_mode($m) {
        die "unknown output mode \"$m\"\n" unless $OUT_MODES{$m};
        $out_mode = $m;
    }

    method set_render_mode($m) {
        die "unknown render mode \"$m\"\n" unless $RENDER_MODES{$m};
        $render_mode = $m;
    }

    method set_theme(%roles) {
        sgr($_, 'rgb') for grep { defined } values %roles;   # dies on a bad spec
        $theme->{$_} = $roles{$_} for keys %roles;
    }

    method colorize($role, $text) {
        my $start = sgr($theme->{$role}, $color_level);
        return $start eq '' ? $text : "$start$text\e[0m";
    }

    # prompts: a spec is a format string or a code ref, see set_prompt_spec
    method prompt($n)                  { return $self->_draw(prompt => $n) }
    method continuation_prompt($n = undef) { return $self->_draw(continuation => $n) }

    method prompt_spec       { return $specs{prompt} }
    method continuation_spec { return $specs{continuation} }
    method set_prompt_spec($spec)       { $self->_set_spec(prompt => $spec) }
    method set_continuation_spec($spec) { $self->_set_spec(continuation => $spec) }

    # the session whose package and input number prompts show, and which a
    # code ref spec is called with
    method set_session($s) {
        $session = $s;
        builtin::weaken($session);    # the session owns us
    }

    method _set_spec($role, $spec) {
        die "$role must be a format string or a code reference\n"
            unless defined $spec && (!ref $spec || ref $spec eq 'CODE');
        $specs{$role} = $spec;
        delete $failed{$role};
    }

    # $n is the input number %n shows; without one, the session's next
    method _draw($role, $n) {
        $n //= $session ? $session->input_number + 1 : '';
        my $spec = $specs{$role};
        if (ref $spec) {
            my $text;
            try { $text = $spec->($session) // '' }
            catch ($v, $e) {
                # once per spec: a broken callback would otherwise
                # repeat its error before every input
                _emit $err, $self->colorize(error =>
                    $self->format_exception($e, prefix => 'prompt callback failed: '))
                    unless $failed{$role}++;
                $spec = $DEFAULT_SPECS{$role};
            }
            return $text if defined $text;
        }
        my $text = $self->_expand($spec, $n);
        return $spec =~ /%\{/ ? $text : $self->colorize($role, $text);
    }

    # a format string's text: %n %p %t %d %% and %{role}...%{/} colours.
    # anything else, unknown escapes and roles included, is literal.
    method _expand($format, $n) {
        my %value = (
            n   => sub { $n },
            p   => sub { $session ? $session->evaluator->package : 'main' },
            t   => sub { require POSIX; POSIX::strftime('%H:%M:%S', localtime) },
            d   => sub {
                require Cwd;
                my $dir = Cwd::getcwd() // '';
                return $dir =~ m{([^/]+)/*\z} ? $1 : $dir;
            },
            '%' => sub { '%' },
        );
        my ($text, $part, $role) = ('', '');
        my $flush = sub {
            $text .= defined $role ? $self->colorize($role, $part) : $part;
            $part = '';
        };
        while ($format =~ /\G(?:%\{(\w+)\}|(%\{\/\})|%([nptd%])|(%|[^%]+))/gc) {
            if    (defined $1 && exists $theme->{$1}) { $flush->(); $role = $1 }
            elsif (defined $1) { $part .= "%{$1}" }
            elsif (defined $2 && defined $role) { $flush->(); undef $role }
            elsif (defined $2) { $part .= $2 }
            elsif (defined $3) { $part .= $value{$3}->() }
            else               { $part .= $4 }
        }
        $flush->();
        return $text;
    }

    # one value through Data::Dumper with the repl settings
    method dump_value($v) {
        local $Data::Dumper::Terse     = 1;
        local $Data::Dumper::Indent    = 1;
        local $Data::Dumper::Sortkeys  = 1;
        local $Data::Dumper::Useqq     = 1;
        local $Data::Dumper::Deparse   = 1;
        local $Data::Dumper::Quotekeys = 0;
        return Data::Dumper::Dumper($v);
    }

    # a result value for the dumper layout, number or string by how it was
    # created rather than by Dumper's look at its digits: a number prints
    # bare (Dumper quotes floats, "3.5"), a string always quoted (Dumper
    # leaves "42" bare), Useqq style. undef, booleans and references print
    # as Dumper has them.
    method _dump_top($v) {
        no warnings 'experimental::builtin';
        if (defined $v && !ref $v && !builtin::is_bool($v)) {
            return "$v\n" if builtin::created_as_number($v);
            return Data::Dumper::qquote("$v") . "\n" if builtin::created_as_string($v);
        }
        return $self->dump_value($v);
    }

    # results as text ending in a newline, or '' for an empty list. dumper
    # layout: one value as is; several in parentheses, on one line when all
    # are plain scalars, else one per line.
    method format_values(@values) {
        return '' unless @values;
        if ($out_mode eq 'plain') {
            return join("\n", map { $_ // '' } @values) . "\n";
        }
        if ($out_mode eq 'json') {
            my $lossy = 0;
            my $data = _jsonable(@values == 1 ? $values[0] : \@values, \$lossy, {});
            my $text;
            try { $text = $JSON->encode($data) }
            catch ($v, $e) {
                $lossy = 1;
                $text = $JSON->encode(@values == 1 ? _string($values[0]) : [ map { _string($_) } @values ]);
            }
            $self->print_warning("result is not representable as json, printed as strings\n")
                if $lossy;
            return $text;
        }
        return $self->_dump_top($values[0]) if @values == 1;
        my @dumped = map { $self->_dump_top($_) =~ s/\n\z//r } @values;
        return '(' . join(', ', @dumped) . ")\n" unless grep { ref } @values;
        return "(\n" . join(",\n", @dumped) . "\n)\n";
    }

    # an exception (XPerl::Exception), a value thrown with die, or a plain
    # warning string, rendered under the render mode as text ending in a
    # newline. options: mode (overrides render_mode), full (legacy: every
    # message group instead of the first), prefix (prepended, text modes).
    method format_exception($x, %opt) {
        my $prefix = $opt{prefix} // '';
        my $is_exception = builtin::blessed($x) && $x isa XPerl::Exception;
        my $text;
        if (!$is_exception) {
            $text = ref $x ? $self->dump_value($x) : ($x // '');   # a die value is always dumped
        }
        else {
            my $mode = $opt{mode} // $render_mode;
            if ($mode eq 'json') {
                return $JSON->encode(_tidy_data(Cpanel::JSON::XS::decode_json($x->as_json)));
            }
            if ($mode eq 'annotated') {
                $text = $x->render_as_annotated('auto');
            }
            else {
                # one JSON record per logical message group; its "message"
                # is that group's legacy text.
                my @records = map { Cpanel::JSON::XS::decode_json($_) }
                    grep { length } split /\n/, $x->render('auto:legacy:JSON');
                # compile-time warnings in an error were printed as warnings
                # already; the headline is the first error
                unless ($opt{full}) {
                    my @errors = grep { !_all_warnings(_record_codes($_)) } @records;
                    @records = @errors if @errors;
                }
                my @groups = map { $_->{message} } @records;
                @groups = ("$x") unless @groups;
                # perl's "Execution of ... aborted" group adds nothing to
                # the first message, so it does not count as more to see
                my $more = grep { !_only_aborted($_) } @records[ 1 .. $#records ];
                if ($opt{full} || @groups == 1) {
                    $text = join '', @groups;
                }
                else {
                    $text = ($groups[0] =~ s/\n\z//r)
                        . ($more ? " (:stack for $more more)" : '') . "\n";
                }
            }
            $text = _tidy($text);
        }
        $text .= "\n" unless $text =~ /\n\z/;
        return $prefix . $text;
    }

    method print_result($result) {
        my $text = $self->format_values(@{ $result->values });
        return unless length $text;
        # colour the text, not its trailing newline
        my ($body, $nl) = $text =~ /\A(.*?)(\n?)\z/s;
        _emit $out, $self->colorize(result => $body), $nl;
    }

    method print_error($result) {
        my $kind = $result->kind;
        if ($kind eq 'interrupted') {
            _emit $err, $self->colorize(muted => 'interrupted'), "\n";
            return;
        }
        my $prefix = $kind eq 'runtime_error' ? 'error: ' : 'compile error: ';
        my $x = $result->exception // $result->value;
        _emit $err, $self->colorize(error => $self->format_exception($x, prefix => $prefix));
    }

    # $x is a warning: an XPerl::Exception (${^CUR_ERROR_OBJ}) or text.
    # at compile time perl delivers a warning with its whole in-progress
    # exception, errors included; only its WARNING_ diagnostics are shown
    # then, or $message when it has none.
    method print_warning($x, $message = undef) {
        if (builtin::blessed($x) && $x isa XPerl::Exception
            && !_all_warnings(map { $_->code // '' } @{ $x->contents })) {
            my $text = $self->_warnings_of($x);
            return _emit $err, $self->colorize(warning => $text) if defined $text;
            $x = $message // "$x";
        }
        # every group: a warning has no :stack to point at
        _emit $err, $self->colorize(warning => $self->format_exception($x, full => 1));
    }

    # the warning part of an exception that also holds errors, as text, or
    # undef when there is none
    method _warnings_of($x) {
        if ($render_mode eq 'json') {
            my $doc = _tidy_data(Cpanel::JSON::XS::decode_json($x->as_json));
            my @warnings = grep { ($_->{code} // '') =~ /\AWARNING_/ } @{ $doc->{contents} };
            return undef unless @warnings;
            # kind and severity are derived from the contents
            @$doc{qw(contents kind severity)} = (\@warnings, $warnings[0]{kind}, 'WARNING');
            return $JSON->encode($doc);
        }
        # legacy groups, also for annotated mode: the annotated renderer
        # works on the whole exception only
        my @groups = map { $_->{message} }
            grep { grep { /\AWARNING_/ } _record_codes($_) }
            map { Cpanel::JSON::XS::decode_json($_) }
            grep { length } split /\n/, $x->render('auto:legacy:JSON');
        return undef unless @groups;
        my $text = _tidy(join '', @groups);
        $text .= "\n" unless $text =~ /\n\z/;
        return $text;
    }
}

1;

__END__

=head1 NAME

XPerl::REPL::Render - format xperl-repl results, errors and colours

=head1 DESCRIPTION

Internal to C<XPerl::REPL>. Turns result lists into C<Data::Dumper>, JSON
or plain text, renders C<XPerl::Exception> objects in the C<legacy>,
C<annotated> or C<json> style, and maps colour specs (ANSI names, 0-255
indexes, C<#rrggbb>) to what the terminal supports.  It also draws the
prompts from their format strings or code references.

=cut
