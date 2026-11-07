package XPerl::REPL::Complete;

use v5.36;
no strict 'refs';    # stash walks

use mro ();

our $VERSION = '0.01';

# keywords and builtin function names. regenerate from the top of the
# source tree after building perl with:
#   { perl -ne 'print "$1\n" if $in && /^[+-](\w+)/; $in = 1 if /^__END__/' regen/keywords.pl
#     ./perl -Ilib -e 'no strict "refs"; print "$_\n" for grep { defined &{"builtin::$_"} } keys %builtin::'
#   } | grep -vxE 'import|unimport' | sort -u
our @KEYWORDS = qw(
    __CLASS__ __DATA__ __END__ __FILE__ __LINE__ __NAMESPACE__ __PACKAGE__
    __SUB__ abs accept ADJUST alarm all and any as atan2 AUTOLOAD BEGIN bind
    binmode bless blessed break caller cardinal_plural_form catch ceil chdir
    CHECK chmod chomp chop chown chr chroot class class_object_from_hash
    class_object_to_hash close closedir cmp connect continue cos
    created_as_number created_as_string crypt dbmclose dbmopen default defer
    defined DefinedVal delete DESTROY die dispatch do dump each else elsif
    END endgrent endhostent endnetent endprotoent endpwent endservent eof eq
    equ eval evalbytes exec exists exit exp export_lexically false FALSE fc
    fcntl field fileno finally Float FloatStr flock floor for foreach fork
    format formline ge gen get_diagnostic_data getc getgrent getgrgid
    getgrnam gethostbyaddr gethostbyname gethostent getlogin getnetbyaddr
    getnetbyname getnetent getpeername getpgrp getppid getpriority
    getprotobyname getprotobynumber getprotoent getpwent getpwnam getpwuid
    getservbyname getservbyport getservent getsockname getsockopt given glob
    gmtime goto grep gt hex if implements index indexed inf INIT int Int
    IntStr ioctl is_bool is_class_object is_tainted is_weak isa join
    jumphash_integer jumphash_string keys kill last lc lcfirst le length
    link listen load_module local localtime lock log lstat lt m map method
    mkdir msgctl msgget msgrcv msgsnd my namespace nan ne neu next no not
    Num NumEq NumStr ObjectVal oct on open opendir or ord
    ordinal_plural_form our pack package package_implements pipe pop pos
    print printf prototype push q qq qr quotemeta qw qx rand rand_bytes read
    readdir readline readlink readpipe recv redo ref refaddr reftype RefVal
    rename require reset return reverse rewinddir rindex rmdir role s say
    scalar ScalarVal seek seekdir select semctl semget semop send setgrent
    sethostent setnetent setpgrp setpriority setprotoent setpwent setservent
    setsockopt shift shmctl shmget shmread shmwrite shutdown sin siphash
    siphash_1_3 siphash_2_4 sleep socket socketpair sort splice split
    sprintf sqrt srand stat state Strict stringify study sub substr symlink
    syscall sysopen sysread sysseek system syswrite tell telldir tie tied
    time times tr trim true TRUE truncate try uc ucfirst umask undef
    UNITCHECK unless unlink unpack unshift untie until unweaken use utime
    values vec wait waitpid wantarray warn weaken when while write x xor y
    yield
);

# candidates are [word, kind] pairs; kinds name the source for colouring
# listings: command scalar array hash key package sub method keyword builtin
our @KINDS = qw(command scalar array hash key package sub method keyword builtin hint);
my %SIGIL_KIND = ('$' => 'scalar', '@' => 'array', '%' => 'hash');

# the first of each word
sub _uniq (@pairs) {
    my %seen;
    return grep { !$seen{ $_->[0] }++ } @pairs;
}

# (\@words, $start, \@kinds) from pairs
sub _result ($pairs, $start) {
    return ([ map { $_->[0] } @$pairs ], $start, [ map { $_->[1] } @$pairs ]);
}

# the stash of package $pkg ('' is main), or undef when there is none.
# walked level by level: \%{"Foo::"} would create the package.
sub _stash ($pkg) {
    my $stash = \%main::;
    for my $part (grep { length } split /::/, $pkg) {
        my $glob = $stash->{"${part}::"} or return undef;
        $stash = *{$glob}{HASH} or return undef;
    }
    return $stash;
}

# names in a stash ("Foo::" style), without the noise of file entries,
# nested-stash self references and punctuation variables
sub _stash_names ($pkg) {
    my $stash = _stash($pkg) or return;
    return grep { !/\A(?:_<|::)/ && /\A\w/ } keys %$stash;
}

sub _qualify ($pkg, $name) { return $pkg eq '' ? "main::$name" : "${pkg}::$name" }

# package variables with $sigil, subs (no sigil) and package names under
# the stash that $word names: "Foo::B" walks %Foo:: for names starting "B"
sub _from_stash ($sigil, $word, $current) {
    my ($pkg, $part) = $word =~ /\A(?:(.*)::)?(\w*)\z/ or return;
    my $root = $pkg // ($sigil eq '' ? '' : $current);
    $root = '' if $root eq 'main' && !defined $pkg;
    my @found;
    for my $name (sort grep { index($_, $part) == 0 } _stash_names($root)) {
        if ($name =~ /\A(\w+)::\z/) {
            next unless $sigil eq '' && $1 ne 'main';
            my $package = defined $pkg ? "${pkg}::$1" : $1;
            # a package name typed in full descends into it
            push @found, [ $package eq $word ? "${package}::" : $package, 'package' ];
            next;
        }
        my $full = _qualify($root, $name);
        my $shown = defined $pkg ? "${pkg}::$name" : $name;
        if ($sigil eq '') {
            push @found, [ $shown, 'sub' ] if defined &{$full};
        }
        elsif ($sigil eq '$') {
            push @found, [ "\$$shown", 'scalar' ] if defined ${*{$full}{SCALAR}};
        }
        elsif ($sigil eq '@') {
            push @found, [ "\@$shown", 'array' ] if *{$full}{ARRAY};
        }
        else {
            push @found, [ "%$shown", 'hash' ] if *{$full}{HASH};
        }
    }
    return @found;
}

# lexicals matching a sigil and prefix. after "$", arrays and hashes keep
# the typed sigil: $a for $a[0], $h for $h{k}. the kind is what the
# variable is: $a offered for @a is an array.
sub _from_lexicals ($repl, $sigil, $part) {
    my @found;
    for my $name (sort keys %{ $repl->evaluator->env }) {
        my ($s, $bare) = $name =~ /\A(.)(.*)\z/s;
        next unless index($bare, $part) == 0;
        if    ($sigil eq $s)  { push @found, [ $name, $SIGIL_KIND{$s} ] }
        elsif ($sigil eq '$') { push @found, [ "\$$bare", $SIGIL_KIND{$s} ] }
    }
    return sort { $a->[0] cmp $b->[0] } @found;
}

sub _methods ($class, $part) {
    return unless length $class;
    my @found;
    for my $c (@{ mro::get_linear_isa($class) }) {
        push @found, grep { index($_, $part) == 0 && defined &{"${c}::$_"} } _stash_names($c);
    }
    my %seen;
    return sort grep { !$seen{$_}++ } @found;
}

# a package variable's container, by stash walk so nothing is autovivified:
# HASH, ARRAY or SCALAR slot of the glob that $name (maybe qualified) names
sub _package_var ($slot, $name, $current) {
    $name = _qualify($current, $name) unless $name =~ /::/;
    my ($pkg, $leaf) = $name =~ /\A(.*)::(\w+)\z/ or return;
    my $stash = _stash($pkg) or return;
    my $glob = $stash->{$leaf};
    return unless ref \$glob eq 'GLOB';
    return *{$glob}{$slot};
}

# one subscript in a chain: optional arrow, then {bareword}, {'literal'},
# {"literal"} or [digits]
my $SUBSCRIPT = qr/(->)?(?:\{(?:(\w+)|'((?:[^'\\]|\\.)*)'|"((?:[^"\\\$\@]|\\.)*)")\}|\[(\d+)\])/;

sub _hash_key_text ($key, $quote) {
    if ($quote eq '"') {
        $key =~ s/([\\"\$\@])/\\$1/g;
        return qq{"$key"};
    }
    return $key if $quote eq '' && $key =~ /\A[A-Za-z_]\w*\z/;
    $key =~ s/([\\'])/\\$1/g;
    return "'$key'";
}

# keys for "$name{KEY", "$name->{KEY" and chains like "$r->{a}[0]{KEY",
# and indexes for "$name[N" and chains like "$h{b}[N": only walks the live
# data (no tied containers, no overloaded derefs, no method or function
# calls). undef unless the text is a subscript.
sub _hash_keys ($repl, $before) {
    $before =~ /(?<![\$\@%\w:])\$(?<name>\w+(?:::\w+)*)(?<chain>(?:$SUBSCRIPT)*)(?<arrow>->)?(?:\{(?<typed>'(?:[^'\\]|\\.)*|"(?:[^"\\\$\@]|\\.)*|\w*)|\[(?<index>\d*))\z/
        or return;
    my ($name, $chain, $arrow) = @+{qw(name chain arrow)};
    my $open = defined $+{index} ? '[' : '{';
    my $typed = $+{index} // $+{typed};
    my $start = length($before) - length $typed;
    my @steps;
    while ($chain =~ /\G$SUBSCRIPT/gc) {
        push @steps, [ $1, defined $5 ? ('[', $5) : ('{', $2 // $3 // $4) ];
        $steps[-1][2] =~ s/\\(.)/$1/gs if defined $3 || defined $4;
    }
    push @steps, [ $arrow, $open, undef ];

    # the base: $h{ is %h, $a[ is @a, $s->{ and $s->[ are $s
    my $first = $steps[0];
    my $sigil = $first->[0] ? '$' : $first->[1] eq '{' ? '%' : '@';
    my $data;
    if ($name !~ /::/ && (my $ref = $repl->evaluator->env->{"$sigil$name"})) {
        $data = $ref;
    }
    else {
        $data = _package_var({ '$' => 'SCALAR', '%' => 'HASH', '@' => 'ARRAY' }->{$sigil},
                             $name, $repl->evaluator->package);
    }
    return [] unless $data;
    # a tied scalar, as the base or an element, would run its FETCH
    if ($sigil eq '$') {
        return [] if tied $$data;
        $data = $$data;
    }

    no overloading;
    for my $i (0 .. $#steps) {
        my (undef, $kind, $sub) = @{ $steps[$i] };
        my $type = builtin::reftype($data) // '';
        if ($kind eq '{') {
            return [] unless $type eq 'HASH' && !tied %$data;
            last if $i == $#steps;
            return [] unless exists $data->{$sub} && !tied $data->{$sub};
            $data = $data->{$sub};
        }
        else {
            return [] unless $type eq 'ARRAY' && !tied @$data;
            last if $i == $#steps;
            return [] unless $sub <= $#$data && !tied $data->[$sub];
            $data = $data->[$sub];
        }
    }

    # an array: one hint, listed and not inserted, the range of its
    # indexes ("0..$#array") from the index typed so far
    if ($open eq '[') {
        my ($from, $last) = (length $typed ? 0 + $typed : 0, $#$data);
        return [], $start if $from > $last;
        return [ $from == $last ? "$last" : "$from..$last" ], $start, 'hint';
    }
    my ($quote, $part) = $typed =~ /\A(['"]?)(.*)\z/s;
    $part =~ s/\\(.)/$1/gs if length $quote;
    return [ map { _hash_key_text($_, $quote) } sort grep { index($_, $part) == 0 } keys %$data ], $start;
}

# (\@candidates, $start, \@kinds) for the word ending at $cursor in $buffer. each
# candidate replaces substr($buffer, $start, $cursor - $start).
sub complete ($repl, $buffer, $cursor) {
    my $before = substr $buffer, 0, $cursor;

    if (my ($keys, $start, $kind) = _hash_keys($repl, $before)) {
        return _result([ map { [ $_, $kind // 'key' ] } @$keys ], $start // $cursor);
    }
    # a subscript the walk cannot follow ($h{$k}{, $h{ a }{,
    # $obj->meth->{, $h{$k}[): no keys or indexes, and not keywords either
    return ([], $cursor, []) if $before =~ /(?:[\]\}]|->|\$\w+)(?:\{\s*['"]?\w*|\[\s*\d*)\z/;

    if ($before =~ /\A:(\w*)\z/) {
        my $part = $1;
        return _result([ map { [ ":$_", 'command' ] } grep { index($_, $part) == 0 } $repl->commands->names ], 0);
    }

    if ($before =~ /(?:(\$\w+)|(\w+(?:::\w+)*))->(\w*)\z/) {
        my ($var, $class, $part) = ($1, $2, $3);
        if (defined $var) {
            my $ref = $repl->evaluator->env->{$var};
            $class = $ref && builtin::blessed($$ref) ? builtin::blessed($$ref) : '';
        }
        return _result([ map { [ $_, 'method' ] } _methods($class, $part) ], $cursor - length $part);
    }

    if ($before =~ /([\$\@%])((?:\w+::)*\w*)\z/) {
        my ($sigil, $word) = ($1, $2);
        my $start = $cursor - length($word) - 1;
        my @found = $word =~ /::/ ? () : _from_lexicals($repl, $sigil, $word);
        push @found, _from_stash($sigil, $word, $repl->evaluator->package);
        return _result([ _uniq(@found) ], $start);
    }

    if ($before =~ /((?:\w+::)+\w*|\w+)\z/) {
        my $word = $1;
        my $start = $cursor - length $word;
        my @found = _from_stash('', $word, $repl->evaluator->package);
        push @found, map { [ $_, defined &{"builtin::$_"} ? 'builtin' : 'keyword' ] }
            sort grep { index($_, $word) == 0 } @KEYWORDS unless $word =~ /::/;
        return _result([ _uniq(@found) ], $start);
    }

    return ([], $cursor, []);
}

1;

__END__

=head1 NAME

XPerl::REPL::Complete - tab-completion candidates for xperl-repl

=head1 DESCRIPTION

Internal to C<XPerl::REPL>. C<complete($repl, $buffer, $cursor)> returns
the candidate words for the word before the cursor and the offset where
that word starts, and each word's kind (C<command>, C<scalar>, C<array>,
C<hash>, C<key>, C<package>, C<sub>, C<method>, C<keyword> or
C<builtin>), which colours listings, or C<hint> for an array's index
range, which the editor lists but does not insert. Sources, in order: hash keys and array
index ranges from live data (C<$h{>, C<< $r->{a}{ >>, C<$h{b}[>), C<:commands>, lexicals, package
variables, subs and package names, methods after C<< -> >>, and keywords
and builtin functions.

=cut
