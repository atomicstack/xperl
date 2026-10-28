package Diag::Plural;

use strict;
use warnings;
use utf8;
use File::Spec;

my @categories = qw(zero one two few many other);
my %category = map { $_ => 1 } @categories;
my %operand = map { $_ => 1 } qw(n i v w f t c e);
my $max_literal = '4294967295';
my $max_rule_id = 65535;

our $CLDR_DATA;

sub load_data {
    my ($path) = @_;
    $path ||= 'lib/unicore/cldr/plural.pl';
    $path = File::Spec->rel2abs($path);
    local $CLDR_DATA;
    my $loaded = do $path;
    my $error = $@ || $!;
    die "Cannot load CLDR plural data from $path: $error\n"
        unless $loaded;
    _validate_data($CLDR_DATA);
    return $CLDR_DATA;
}

sub compile {
    my ($data) = @_;
    $data = load_data() unless defined $data;
    _validate_data($data);

    my (%definitions, %rule_signature);
    for my $kind (qw(cardinal ordinal)) {
        my $type = $data->{$kind};
        for my $source_id (sort keys %{$type->{rules}}) {
            my $source = $type->{rules}{$source_id};
            my %conditions;
            for my $name (@categories[0 .. $#categories - 1]) {
                next unless exists $source->{$name};
                my $text = $source->{$name}{condition};
                die "$kind rule $source_id has an empty $name condition\n"
                    unless length $text;
                my $condition = _fold(_parse_condition($text));
                next if $condition->{type} eq 'constant'
                    && !$condition->{value};
                $conditions{$name} = $condition;
            }
            die "$kind rule $source_id has a condition for other\n"
                if length $source->{other}{condition};
            my $signature = _rule_signature(\%conditions);
            $definitions{$signature} ||= { conditions => \%conditions };
            $rule_signature{$kind}{$source_id} = $signature;
        }
    }

    my $other_signature = _rule_signature({});
    $definitions{$other_signature} ||= { conditions => {} };

    my %rule_ids;
    my @signatures = sort keys %definitions;
    die "Too many compiled CLDR plural rules\n"
        if @signatures > $max_rule_id;
    for my $index (0 .. $#signatures) {
        $rule_ids{$signatures[$index]} = $index + 1;
    }

    my %cardinal_locale_signature;
    for my $locale (sort keys %{$data->{cardinal}{locales}}) {
        my $source_id = $data->{cardinal}{locales}{$locale};
        $cardinal_locale_signature{$locale}
            = $rule_signature{cardinal}{$source_id};
    }

    my $plural_parents = $data->{plural_parents};
    my %rows = %cardinal_locale_signature;
    for my $kind (qw(cardinal ordinal)) {
        for my $locale (sort keys %{$plural_parents->{$kind}}) {
            die "$kind plural parent $locale has a direct rule\n"
                if exists $data->{$kind}{locales}{$locale};
            die "$kind plural parent target $plural_parents->{$kind}{$locale} has no explicit rule\n"
                unless exists $data->{$kind}{locales}
                    {$plural_parents->{$kind}{$locale}};
        }
    }

    my %cardinal_parents = %{$plural_parents->{cardinal}};
    for my $locale (sort keys %cardinal_parents) {
        die "Cardinal plural parent locale collision for $locale\n"
            if exists $rows{$locale};
        my $target = $cardinal_parents{$locale};
        my $source_id = $data->{cardinal}{locales}{$target};
        die "Cardinal plural parent target $target has no rule row\n"
            unless defined $source_id;
        $rows{$locale} = $rule_signature{cardinal}{$source_id};
    }
    for my $locale (sort keys %{$plural_parents->{ordinal}}) {
        next if exists $rows{$locale};
        my $fallback = _stripped_locale_rule($locale, \%cardinal_locale_signature);
        die "Ordinal plural parent $locale has no cardinal fallback\n"
            unless defined $fallback;
        $rows{$locale} = $fallback;
    }

    my %known = map { $_ => 1 } keys %rows;
    die "Ordinal locale has no cardinal locale row\n"
        if grep { !$known{$_} } keys %{$data->{ordinal}{locales}};

    my %ordinal_signature = map {
        my $locale = $_;
        my $source_id = $data->{ordinal}{locales}{$locale};
        $locale => $rule_signature{ordinal}{$source_id};
    } keys %{$data->{ordinal}{locales}};
    my %ordinal_parents = %{$plural_parents->{ordinal}};

    my @locales;
    for my $locale (sort { _ascii_sort_key($a) cmp _ascii_sort_key($b) } keys %rows) {
        my $ordinal_target = $ordinal_parents{$locale};
        if (!defined $ordinal_target) {
            $ordinal_target = _stripped_locale_rule(
                $locale, \%ordinal_signature,
            );
        }
        my $ordinal_sig = defined $ordinal_target
            ? $ordinal_signature{$ordinal_target}
            : $other_signature;
        die "No ordinal rule for known locale $locale\n"
            unless defined $ordinal_sig;
        push @locales, {
            name => lc($locale),
            cardinal => $rule_ids{$rows{$locale}},
            ordinal => $rule_ids{$ordinal_sig},
        };
    }

    my %seen_name;
    for my $locale (@locales) {
        die "Locale names collide after case folding: $locale->{name}\n"
            if $seen_name{$locale->{name}}++;
        for my $kind (qw(cardinal ordinal)) {
            die "No compiled $kind rule for locale $locale->{name}\n"
                unless defined $locale->{$kind}
                    && $locale->{$kind} > 0
                    && $locale->{$kind} <= $max_rule_id;
        }
    }

    my @rules = map {
        {
            id => $rule_ids{$_},
            signature => $_,
            conditions => $definitions{$_}{conditions},
        }
    } @signatures;

    return {
        version => $data->{version}{cldr},
        categories => [@categories],
        default_other => $rule_ids{$other_signature},
        rules => \@rules,
        locales => \@locales,
    };
}

sub render {
    my ($model) = @_;
    $model ||= compile(load_data());
    _validate_model($model);

    my $output = <<'C';
typedef struct perl_diag_plural_locale {
    const char *name;
    U16 cardinal;
    U16 ordinal;
} perl_diag_plural_locale;

static const perl_diag_plural_locale perl_diag_plural_locales[] = {
C
    for my $locale (@{$model->{locales}}) {
        $output .= sprintf "    { \"%s\", %uU, %uU },\n",
            $locale->{name}, $locale->{cardinal}, $locale->{ordinal};
    }
    $output .= <<'C';
};

static U8
Perl_diag_plural_evaluate(U16 rule, UV n)
{
    switch (rule) {
C
    for my $rule (@{$model->{rules}}) {
        $output .= sprintf "      case %uU:\n", $rule->{id};
        my $unconditional = 0;
        for my $name (@categories[0 .. $#categories - 1]) {
            next unless exists $rule->{conditions}{$name};
            my $condition = $rule->{conditions}{$name};
            if ($condition->{type} eq 'constant' && $condition->{value}) {
                $output .= "        return perl_diag_selector_plural_$name;\n";
                $unconditional = 1;
                last;
            }
            $output .= "        if (" . _render_condition($condition) . ")\n"
                . "            return perl_diag_selector_plural_$name;\n";
        }
        $output .= "        return perl_diag_selector_plural_other;\n"
            unless $unconditional;
    }
    $output .= <<'C';
    }
    return 0;
}
C
    return $output;
}

sub parse_condition {
    return _fold(_parse_condition($_[0]));
}

sub render_condition {
    return _render_condition($_[0]);
}

sub _validate_data {
    my ($data) = @_;
    die "Invalid CLDR plural table\n" unless ref($data) eq 'HASH';
    die "Missing CLDR plural version metadata\n"
        unless ref($data->{version}) eq 'HASH'
            && defined $data->{version}{cldr}
            && $data->{version}{cldr} =~ /\A\d+\z/
            && defined $data->{version}{package}
            && defined $data->{version}{unicode};
    die "Invalid CLDR plural categories\n"
        unless ref($data->{categories}) eq 'ARRAY'
            && join(',', @{$data->{categories}}) eq join(',', @categories);
    for my $kind (qw(cardinal ordinal)) {
        my $type = $data->{$kind};
        die "Missing $kind rule data\n"
            unless ref($type) eq 'HASH'
                && ref($type->{locales}) eq 'HASH'
                && ref($type->{rules}) eq 'HASH'
                && keys %{$type->{locales}}
                && keys %{$type->{rules}};
        for my $locale (keys %{$type->{locales}}) {
            die "Invalid $kind locale id '$locale'\n"
                unless $locale =~ /\A[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z/;
            my $id = $type->{locales}{$locale};
            die "Unknown $kind rule '$id' for locale $locale\n"
                unless defined $id && !ref($id) && exists $type->{rules}{$id};
        }
        for my $id (keys %{$type->{rules}}) {
            my $rules = $type->{rules}{$id};
            die "Invalid $kind rule set '$id'\n" unless ref($rules) eq 'HASH';
            die "$kind rule set '$id' has no other category\n"
                unless exists $rules->{other}
                    && ref($rules->{other}) eq 'HASH'
                    && defined $rules->{other}{condition}
                    && !ref($rules->{other}{condition});
            for my $name (keys %$rules) {
                die "Unknown category '$name' in $kind rule '$id'\n"
                    unless $category{$name};
                die "Invalid condition for $kind rule '$id' category '$name'\n"
                    unless ref($rules->{$name}) eq 'HASH'
                        && defined $rules->{$name}{condition}
                        && !ref($rules->{$name}{condition});
            }
        }
    }
    my $parents = $data->{plural_parents};
    die "Missing plural parent metadata\n"
        unless ref($parents) eq 'HASH'
            && ref($parents->{cardinal}) eq 'HASH'
            && ref($parents->{ordinal}) eq 'HASH';
    for my $kind (qw(cardinal ordinal)) {
        for my $locale (keys %{$parents->{$kind}}) {
            my $target = $parents->{$kind}{$locale};
            die "Invalid $kind plural parent mapping for '$locale'\n"
                unless $locale =~ /\A[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z/
                    && defined $target && !ref($target)
                    && $target =~ /\A[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z/;
        }
    }
}

sub _validate_model {
    my ($model) = @_;
    die "Invalid compiled CLDR plural model\n"
        unless ref($model) eq 'HASH'
            && ref($model->{rules}) eq 'ARRAY'
            && ref($model->{locales}) eq 'ARRAY'
            && defined $model->{default_other};
}

sub _parse_condition {
    my ($text) = @_;
    die "Plural condition must be a non-empty string\n"
        unless defined $text && !ref($text) && length $text;
    my $parser = { tokens => _tokenize($text), index => 0 };
    my $tree = _parse_or($parser);
    die "Unexpected token in plural condition '$text'\n"
        if $parser->{index} < @{$parser->{tokens}};
    return $tree;
}

sub _tokenize {
    my ($text) = @_;
    my @tokens;
    pos($text) = 0;
    while (pos($text) < length($text)) {
        if ($text =~ /\G\s+/gc) {
            next;
        }
        my ($kind, $value);
        if ($text =~ /\G(!=|\.\.|[=%,])/gc) {
            ($kind, $value) = ('symbol', $1);
        }
        elsif ($text =~ /\G([0-9]+)/gc) {
            ($kind, $value) = ('number', _parse_uint($1));
        }
        elsif ($text =~ /\G([A-Za-z]+)/gc) {
            ($kind, $value) = ('word', $1);
        }
        else {
            my $offset = pos($text);
            die "Invalid token in plural condition near '"
                . substr($text, $offset, 16) . "'\n";
        }
        push @tokens, [$kind, $value];
    }
    return \@tokens;
}

sub _parse_uint {
    my ($text) = @_;
    $text =~ s/\A0+(?=\d)//;
    die "Plural rule literal exceeds 32-bit unsigned range: $text\n"
        if length($text) > length($max_literal)
            || length($text) == length($max_literal) && $text gt $max_literal;
    return 0 + $text;
}

sub _parse_or {
    my ($parser) = @_;
    my @children = (_parse_and($parser));
    while (_take_word($parser, 'or')) {
        push @children, _parse_and($parser);
    }
    return @children == 1 ? $children[0] : { type => 'or', children => \@children };
}

sub _parse_and {
    my ($parser) = @_;
    my @children = (_parse_relation($parser));
    while (_take_word($parser, 'and')) {
        push @children, _parse_relation($parser);
    }
    return @children == 1 ? $children[0] : { type => 'and', children => \@children };
}

sub _parse_relation {
    my ($parser) = @_;
    my ($operand_kind, $operand_name) = _take_token($parser);
    die "Expected a CLDR operand\n"
        unless defined $operand_kind && $operand_kind eq 'word'
            && $operand{$operand_name};
    my $modulus;
    if (_take_symbol($parser, '%')) {
        my ($kind, $text) = _take_token($parser);
        die "Expected a positive modulo value\n"
            unless defined $kind && $kind eq 'number' && $text > 0;
        $modulus = $text;
    }
    my ($operator_kind, $operator) = _take_token($parser);
    die "Expected '=' or '!=' in plural condition\n"
        unless defined $operator_kind && $operator_kind eq 'symbol'
            && ($operator eq '=' || $operator eq '!=');

    my @values;
    while (1) {
        my ($kind, $low) = _take_token($parser);
        die "Expected an unsigned plural rule value\n"
            unless defined $kind && $kind eq 'number';
        my $high = $low;
        if (_take_symbol($parser, '..')) {
            my ($high_kind, $high_value) = _take_token($parser);
            die "Expected an unsigned plural range end\n"
                unless defined $high_kind && $high_kind eq 'number';
            die "Descending plural rule range\n" if $high_value < $low;
            $high = $high_value;
        }
        push @values, [$low, $high];
        last unless _take_symbol($parser, ',');
    }
    return {
        type => 'relation',
        operand => $operand_name,
        modulus => $modulus,
        operator => $operator,
        values => \@values,
    };
}

sub _take_word {
    my ($parser, $word) = @_;
    my $token = $parser->{tokens}[$parser->{index}];
    return 0 unless $token && $token->[0] eq 'word' && $token->[1] eq $word;
    $parser->{index}++;
    return 1;
}

sub _take_symbol {
    my ($parser, $symbol) = @_;
    my $token = $parser->{tokens}[$parser->{index}];
    return 0 unless $token && $token->[0] eq 'symbol' && $token->[1] eq $symbol;
    $parser->{index}++;
    return 1;
}

sub _take_token {
    my ($parser) = @_;
    return if $parser->{index} >= @{$parser->{tokens}};
    return @{$parser->{tokens}[$parser->{index}++]};
}

sub _fold {
    my ($node) = @_;
    return $node if $node->{type} eq 'constant';
    if ($node->{type} eq 'relation') {
        return _fold_relation($node);
    }
    die "Unknown plural expression node '$node->{type}'\n"
        unless $node->{type} eq 'and' || $node->{type} eq 'or';
    my @children = map { _fold($_) } @{$node->{children}};
    return _fold_boolean($node->{type}, @children);
}

sub _fold_relation {
    my ($node) = @_;
    my $values = _normalize_intervals($node->{values});
    my $variable = $node->{operand} eq 'n' || $node->{operand} eq 'i';
    my $modulus = $node->{modulus};
    if (!$variable || defined($modulus) && $modulus == 1) {
        my $value = 0;
        $value %= $modulus if defined $modulus;
        my $matched = _contains($values, $value);
        return { type => 'constant', value => $node->{operator} eq '=' ? !!$matched : !$matched };
    }
    if (defined $modulus) {
        my $maximum = $modulus - 1;
        $values = _intersect_intervals($values, 0, $maximum);
    }
    my $matched = @$values ? 1 : 0;
    if (!$matched) {
        return { type => 'constant', value => $node->{operator} eq '!=' ? 1 : 0 };
    }
    if (defined($modulus) && @$values == 1
            && $values->[0][0] == 0
            && $values->[0][1] == $modulus - 1) {
        return { type => 'constant', value => $node->{operator} eq '=' ? 1 : 0 };
    }
    return {
        type => 'relation',
        operand => 'n',
        modulus => $modulus,
        operator => $node->{operator},
        values => $values,
    };
}

sub _normalize_intervals {
    my ($input) = @_;
    my @sorted = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @$input;
    my @merged;
    for my $interval (@sorted) {
        my ($low, $high) = @$interval;
        if (@merged) {
            my $last = $merged[-1];
            if ($low <= $last->[1]
                    || $last->[1] < 4294967295 && $low == $last->[1] + 1) {
                $last->[1] = $high if $high > $last->[1];
                next;
            }
        }
        push @merged, [$low, $high];
    }
    return \@merged;
}

sub _intersect_intervals {
    my ($intervals, $minimum, $maximum) = @_;
    my @result;
    for my $interval (@$intervals) {
        next if $interval->[0] > $maximum || $interval->[1] < $minimum;
        push @result, [
            $interval->[0] < $minimum ? $minimum : $interval->[0],
            $interval->[1] > $maximum ? $maximum : $interval->[1],
        ];
    }
    return _normalize_intervals(\@result);
}

sub _contains {
    my ($intervals, $value) = @_;
    for my $interval (@$intervals) {
        return 1 if $value >= $interval->[0] && $value <= $interval->[1];
    }
    return 0;
}

sub _fold_boolean {
    my ($type, @children) = @_;
    my $is_and = $type eq 'and';
    my (%seen, @flat);
    for my $child (@children) {
        if ($child->{type} eq 'constant') {
            return { type => 'constant', value => 0 }
                if $is_and && !$child->{value};
            return { type => 'constant', value => 1 }
                if !$is_and && $child->{value};
            next;
        }
        my @parts = $child->{type} eq $type
            ? @{$child->{children}} : ($child);
        for my $part (@parts) {
            my $key = _node_key($part);
            push @flat, $part unless $seen{$key}++;
        }
    }
    return { type => 'constant', value => $is_and ? 1 : 0 } unless @flat;
    return $flat[0] if @flat == 1;
    @flat = sort { _node_key($a) cmp _node_key($b) } @flat;
    return { type => $type, children => \@flat };
}

sub _node_key {
    my ($node) = @_;
    return $node->{value} ? 'T' : 'F' if $node->{type} eq 'constant';
    if ($node->{type} eq 'relation') {
        my $modulus = defined $node->{modulus} ? $node->{modulus} : '-';
        my $values = join ',', map {
            $_->[0] == $_->[1] ? $_->[0] : $_->[0] . '..' . $_->[1]
        } @{$node->{values}};
        return join ':', 'R', $node->{operand}, $modulus, $node->{operator}, $values;
    }
    return $node->{type} . '[' . join(',', map { _node_key($_) } @{$node->{children}}) . ']';
}

sub _rule_signature {
    my ($conditions) = @_;
    return join "\x1e", map {
        exists $conditions->{$_} ? $_ . ':' . _node_key($conditions->{$_}) : $_ . ':-'
    } @categories[0 .. $#categories - 1];
}

sub _stripped_locale_rule {
    my ($locale, $rules) = @_;
    while (defined $locale) {
        return $locale if exists $rules->{$locale};
        $locale =~ s/-[^-]+\z// or return;
    }
    return;
}

sub _ascii_sort_key {
    my ($text) = @_;
    $text = lc $text;
    return pack 'C*', map { utf8::native_to_unicode(ord $_) } split //, $text;
}

sub _render_condition {
    my ($node) = @_;
    return $node->{value} ? '1' : '0' if $node->{type} eq 'constant';
    if ($node->{type} eq 'and' || $node->{type} eq 'or') {
        my $operator = $node->{type} eq 'and' ? ' && ' : ' || ';
        return '(' . join($operator, map { _render_condition($_) } @{$node->{children}}) . ')';
    }
    die "Cannot render unknown plural expression node '$node->{type}'\n"
        unless $node->{type} eq 'relation';
    my $left = 'n';
    $left .= ' % ' . $node->{modulus} . 'U' if defined $node->{modulus};
    my @matches = map { _render_interval($left, $_->[0], $_->[1]) } @{$node->{values}};
    my $membership = @matches == 1 ? $matches[0] : '(' . join(' || ', @matches) . ')';
    if ($node->{operator} eq '=') {
        return $membership;
    }
    if (@{$node->{values}} == 1 && $node->{values}[0][0] == $node->{values}[0][1]) {
        return '(' . $left . ' != ' . $node->{values}[0][0] . 'U)';
    }
    return '!(' . $membership . ')';
}

sub _render_interval {
    my ($left, $low, $high) = @_;
    return '(' . $left . ' == ' . $low . 'U)' if $low == $high;
    return '(' . $left . ' <= ' . $high . 'U)' if $low == 0;
    return '(' . $left . ' >= ' . $low . 'U && '
        . $left . ' <= ' . $high . 'U)';
}

1;
