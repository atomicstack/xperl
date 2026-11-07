package XPerl::REPL::Evaluator;

use v5.36;

# compile user source in a scope that sees none of this file's lexicals:
# this sub is defined before any "my" or "our" below, so the string eval
# cannot see evaluator internals or class fields. the generated prologue
# compiles under this file's v5.36 hints; user code gets its own.
sub _compile { eval $_[0] }

use B ();
use feature qw(class try);
no warnings qw(experimental::class experimental::try);

our $VERSION = '0.01';

class XPerl::REPL::Interrupted {}

class XPerl::REPL::Result {
    field $kind         :param :reader;
    field $values       :param :reader = [];
    field $exception    :param :reader = undef;
    field $value        :param :reader = undef;
    field $input_number :param :reader;
}

class XPerl::REPL::Evaluator {
    # the generated prologue reads saved lexicals from here. it is
    # localised to this evaluator's %env around compile and run, so several
    # evaluators can coexist.
    our %ENV;

    # compiled into the first input and the first input after reset.
    our $PRELUDE = "use v5.36; use feature ':all'; use builtin ':all'; use strict; use warnings;\n";

    # a compile failure carrying any of these diagnostic codes means the
    # input is unfinished and more lines may complete it. all are tagged
    # condition:unterminated_unbalanced in diag_conf.pl, but that tag also
    # covers genuine errors, so the list is explicit. ERROR_SYNTAX_INVALID
    # is handled in is_incomplete: it only counts at end of input.
    our @INCOMPLETE_CODES = qw(
        ERROR_SYNTAX_DELIMITER_UNCLOSED_STRUCTURE
        ERROR_SYNTAX_QUOTED_STRING_TERMINATOR_MISSING
        ERROR_SYNTAX_QUOTED_STRING_REGEXP_UNTERMINATED
        ERROR_SYNTAX_QUOTED_STRING_SUBSTITUTION_PATTERN_UNTERMINATED
        ERROR_SYNTAX_QUOTED_STRING_SUBSTITUTION_REPLACEMENT_UNTERMINATED
        ERROR_SYNTAX_QUOTED_STRING_TRANSLITERATION_SEARCH_UNTERMINATED
        ERROR_SYNTAX_QUOTED_STRING_TRANSLITERATION_REPLACEMENT_UNTERMINATED
        ERROR_SYNTAX_QUOTED_STRING_ANGLE_UNTERMINATED
        ERROR_SYNTAX_QUOTED_STRING_ANGLE_GLOB_UNTERMINATED
        ERROR_SYNTAX_QUOTED_STRING_HEREDOC_QUOTED_DELIMITER_UNTERMINATED
    );
    my %INCOMPLETE = map { $_ => 1 } @INCOMPLETE_CODES;

    # declared first in the block holding the user's code, so a pad name
    # whose scope ends with this one's was declared at the top level
    our $SCOPE_MARK = '$XPerl_REPL_top_level';

    # the file name of the generated tail; see build_source
    our $TAIL_FILE = 'xperl-repl-end';

    # the evaluator compiling right now; the generated BEGIN blocks reach
    # it through _restore_hints and _save_hints.
    our $CURRENT;

    field %env;
    field $package = 'main';
    field $hints;             # undef (prelude next) or [$^H, \%^H, ${^WARNING_BITS}]
    field $pending;           # [$hints, $package] saved by the compile in progress

    method env     { return \%env }
    method package { return $package }
    method hints   { return $hints }

    # the name is interpolated into generated source, so only accept a
    # plain package name.
    method set_package($name) {
        die "invalid package name \"$name\"\n" unless $name =~ /\A\w+(?:::\w+)*\z/;
        $package = $name;
    }

    method reset {
        %env = ();
        $package = 'main';
        $hints = undef;
    }

    method _set_pending($h, $pkg) { $pending = [ $h, $pkg ] }

    # called at BEGIN time inside the user's do block: install the saved
    # hints into the scope being compiled, as an import method would.
    sub _restore_hints {
        my ($h, $hh, $wb) = @{ $CURRENT->hints };
        %^H = %$hh;
        ${^WARNING_BITS} = $wb;
        $^H = $h;
        return;
    }

    # called at BEGIN time as the last statement of the user's do block.
    # the values are only promoted once the whole input has compiled, so a
    # failed compile never changes package or hints.
    sub _save_hints ($h, $hh, $wb, $pkg) {
        $CURRENT->_set_pending([ $h, { %$hh }, $wb ], $pkg);
        return;
    }

    # every "my" and "our" scalar/array/hash in $cv's pad, in pad
    # (declaration) order, as [name, ref, is_our, scope_end]. lexical subs
    # ("&name") and "state" variables are skipped. scope_end is the
    # COP_SEQ_RANGE_HIGH of the name: names declared in the same block end
    # with it. refs must be taken before $cv runs: the pad SVs are cleared
    # when the call returns, but a ref taken beforehand keeps the value.
    sub _pad_entries ($cv) {
        my ($names, $values) = map { [ $_->ARRAY ] }
            B::svref_2object($cv)->PADLIST->ARRAY;
        my @entries;
        for my $i (0 .. $#$names) {
            my $pn = $names->[$i];
            next unless $pn->can('PV');
            my $name = $pn->PV;
            next unless defined $name && $name =~ /^[\$\@%]\w+\z/;
            next if $pn->FLAGS & B::PADNAMEf_STATE();
            my $is_our = ref($pn->OURSTASH) ne 'B::SPECIAL';
            push @entries, [ $name, $is_our ? undef : $values->[$i]->object_2svref,
                             $is_our, $pn->COP_SEQ_RANGE_HIGH ];
        }
        return @entries;
    }

    # the "my" variables of $cv's pad as name => ref; the latest wins
    method capture_lexicals($cv) {
        my %new;
        $new{ $_->[0] } = $_->[1] for grep { !$_->[2] } _pad_entries($cv);
        return \%new;
    }

    # true when a compile exception says the input is unfinished. the
    # parser context of a diagnostic is the "parser_context" key of the
    # hashref returned by $diag->location (the same name as the
    # location.parser_context JSON field); "eof" means the parser ran out
    # of input, as for "1 +" or "my @a = (1,". perl says that too of an
    # error at any ";" in string source ("1 +;"), so it only counts when
    # the error is in the generated tail.
    method is_incomplete($exception) {
        return 0 unless builtin::blessed($exception) && $exception isa XPerl::Exception;
        my @pending = @{ $exception->contents };
        while (my $diag = shift @pending) {
            my $code = $diag->code // '';
            return 1 if $INCOMPLETE{$code};
            my $where = $diag->location // {};
            return 1 if $code eq 'ERROR_SYNTAX_INVALID'
                && ($where->{parser_context} // '') eq 'eof'
                && ($where->{file} // '') =~ /\A\Q$TAIL_FILE\E-\S+\z/;
            unshift @pending, @{ $diag->contents };
        }
        return 0;
    }

    # $label names the input in messages: "input $n" unless given
    method build_source($text, $n, $label = undef) {
        $label = defined $label ? $label =~ tr/"\n//dr : "input $n";
        # the tail's file name is unquoted, so it is escaped instead
        my $tail = $TAIL_FILE . '-' . ($label =~ s/([%\s"])/sprintf '%%%02X', ord $1/ger);
        my $prologue = join '', map {
            "\\my $_ = \$XPerl::REPL::Evaluator::ENV{'$_'};\n"
        } sort keys %env;
        # the generated tail sits on one line numbered as the user's last
        # line, so errors found at end of input (an unclosed block) point
        # into the input rather than past it. it is in a file of its own,
        # $TAIL_FILE, so is_incomplete can tell an error at the tail's ";"
        # (the input ran out) from one at a ";" the user typed: perl
        # reports both "at EOF". the name is unquoted, because a quote here
        # would close an unterminated string in the input.
        my $last = 1 + (($text =~ s/\n\z//r) =~ tr/\n//);
        return join '',
            "package main;\n",
            "sub {\n",
            "use feature 'refaliasing';\n",
            "no warnings 'experimental::refaliasing', 'shadow';\n",
            $prologue,
            # builtin imports are lexical, so they are not part of the saved
            # hints: import them again for every input.
            "use builtin ':all';\n",
            "package $package;\n",
            "do {\n",
            # its scope is the user's top level: see evaluate
            "my $SCOPE_MARK;\n",
            defined $hints
                ? "BEGIN { XPerl::REPL::Evaluator::_restore_hints() }\n"
                : $PRELUDE,
            "#line 1 \"xperl-repl $label\"\n",
            $text, "\n",
            "#line $last $tail\n",
            "; BEGIN { XPerl::REPL::Evaluator::_save_hints(\$^H, \\%^H, \${^WARNING_BITS}, __PACKAGE__) } } }";
    }

    method evaluate($text, $n, $label = undef) {
        # __END__, __DATA__, ^D and ^Z end perl source wherever a statement
        # can start. they would end the string eval before the generated
        # closing braces, so the input would look incomplete forever.
        if ($text =~ /(?:^|[;{}])\s*(__(?:END|DATA)__\b|[\cD\cZ])/m) {
            my $token = $1 eq "\cD" ? '^D' : $1 eq "\cZ" ? '^Z' : $1;
            my $error = do { local $@; eval { die "$token is not allowed in repl input\n" }; $@ };
            return XPerl::REPL::Result->new(
                kind => 'compile_error', exception => $error, input_number => $n,
            );
        }

        my $source = $self->build_source($text, $n, $label);
        local %XPerl::REPL::Evaluator::ENV = %env;
        # compiling runs user code too (BEGIN, use). an interrupt there
        # reaches $@ only as text inside BEGIN-failed diagnostics, so the
        # handler records it instead.
        my $interrupted = 0;
        local $SIG{INT} = sub { $interrupted = 1; die XPerl::REPL::Interrupted->new };
        my ($cv, $error);
        $pending = undef;
        {
            local $@;
            local $CURRENT = $self;
            $cv = XPerl::REPL::Evaluator::_compile($source);
            $error = $@ unless $cv;
        }
        return XPerl::REPL::Result->new(kind => 'interrupted', input_number => $n)
            if !$cv && $interrupted;
        return XPerl::REPL::Result->new(
            kind => $self->is_incomplete($error) ? 'incomplete' : 'compile_error',
            exception => $error, input_number => $n,
        ) unless $cv;
        ($hints, $package) = @$pending if $pending;

        # keep the top-level declarations: those whose scope ends with the
        # scope mark's. names declared in inner blocks, loops and conditions,
        # and the prologue's aliases (outside the block), are left alone. in
        # declaration order, so the latest wins; an "our" ends the "my".
        # captures are kept even if the input then dies.
        my @entries = _pad_entries($cv);
        my ($top) = map { $_->[3] } grep { $_->[0] eq $SCOPE_MARK } @entries;
        for my $entry (@entries) {
            my ($name, $ref, $is_our, $scope_end) = @$entry;
            next if $name eq $SCOPE_MARK || $scope_end != $top;
            if ($is_our) { delete $env{$name} }
            else         { $env{$name} = $ref }
        }

        my @values;
        try {
            @values = $cv->();
        }
        catch ($v, $e) {
            # observed 2026-11-07: catch ($v, $e) always sets $e to the
            # canonical XPerl::Exception, even for "die { code => 7 }" or a
            # blessed non-exception ref. $v is the original reference for a
            # ref die and the XPerl::Exception itself for a string die. so
            # classify on $v: a non-exception reference is reported through
            # value with exception undef, everything else through $e.
            return XPerl::REPL::Result->new(kind => 'interrupted', input_number => $n)
                if builtin::blessed($v) && $v isa XPerl::REPL::Interrupted;
            return XPerl::REPL::Result->new(
                kind => 'runtime_error', value => $v, input_number => $n,
            ) if ref $v && !(builtin::blessed($v) && $v isa XPerl::Exception);
            return XPerl::REPL::Result->new(
                kind => 'runtime_error', exception => $e, input_number => $n,
            );
        }
        return XPerl::REPL::Result->new(
            kind => 'ok', values => \@values, input_number => $n,
        );
    }
}

1;

__END__

=head1 NAME

XPerl::REPL::Evaluator - compile and run one xperl-repl input

=head1 DESCRIPTION

Internal to C<XPerl::REPL>. Each input is compiled once as an anonymous
sub, run in list context, and reported as an C<XPerl::REPL::Result>.

=cut
