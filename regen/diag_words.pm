# Operation vocabulary shared by diagnostic validation and translation tools.

package Diag::Words;
use strict;
use warnings;

# Load and validate once. Fixtures can supply their own data to every operation.
my $catalog;

sub catalog {
    return $catalog if $catalog;
    my $path = './diag_op_conf.pl';
    my $data = do $path;
    die "Cannot load $path: " . ( $@ || $! || 'file did not return a hash' ) . "\n"
      unless ref($data) eq 'HASH';
    validate($data);
    return $catalog = $data;
}

# Reference descriptions do not prove that an opcode can reach a diagnostic.
# Each binding retains its separately audited operation domain.
sub source_words {
    my %words = ( do_block => 'do block' );
    for my $line ( split /\n/, Diag::Migration::read_source('regen/opcodes') ) {
        next if $line =~ /\A(?:\s*#|\s*\z)/;
        my ( $name, $description ) = split /\t+/, $line;
        $words{$name} = $description;
    }
    return \%words;
}

sub valid_name {
    return defined $_[0] && !ref( $_[0] ) && $_[0] =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
}

sub valid_text {
    return defined $_[0] && !ref( $_[0] ) && length( $_[0] ) && $_[0] !~ /[\x00-\x1f\x7f]/;
}

# Internal spellings such as prtf still denote literal keyword names.
sub literal_operation {
    my ( $data, $source, $name ) = @_;
    return $source->{$name} eq $name || grep { $_ eq $name } @{ $data->{literal_operations} };
}

# Custom-op descriptions come from the extension, even when its identity is
# known. They must not be replaced with the core's generic description.
sub operation_class {
    my ( $data, $source, $name ) = @_;
    return 'opaque' unless defined $name && exists $source->{$name};
    return 'opaque' if grep { $_ eq $name } @{ $data->{opaque_operations} || [] };
    return literal_operation( $data, $source, $name ) ? 'keyword' : 'description';
}

# Reject typos instead of silently ignoring a form, tag or rule field.
sub check_fields {
    my ( $value, $where, @fields ) = @_;
    die "$where must be a hash\n" unless ref($value) eq 'HASH';
    my %allowed = map { $_ => 1 } @fields;
    die "$where has unknown field $_\n" for grep { !$allowed{$_} } sort keys %$value;
}

# Return a membership set without changing the declared order in the config.
sub name_set {
    my ( $values, $where, $allow_empty ) = @_;
    die "$where must be " . ( $allow_empty ? 'an array' : 'a nonempty array' ) . "\n"
      unless ref($values) eq 'ARRAY' && ( $allow_empty || @$values );
    my %seen;
    for my $value (@$values) {
        die "$where has an invalid name\n" unless valid_name($value);
        die "$where has duplicate name $value\n" if $seen{$value}++;
    }
    return \%seen;
}

# A rule requests one form and maps declared word tags to named outputs.
# This initial contract has no conditional branches or executable expressions.
sub validate_rule {
    my ( $profile, $name, $forms, $where ) = @_;
    die "$where has an invalid rule name\n" unless valid_name($name);
    my $rule = $profile->{rules}{$name};
    check_fields( $rule, $where, qw(form select) );
    die "$where requests an undeclared form\n"
      unless valid_name( $rule->{form} ) && $forms->{ $rule->{form} };
    die "$where select must be a hash\n" unless ref( $rule->{select} ) eq 'HASH';

    for my $output ( sort keys %{ $rule->{select} } ) {
        die "$where has an invalid selector output\n" unless valid_name($output);
        my $selection       = $rule->{select}{$output};
        my $selection_where = "$where output $output";
        check_fields( $selection, $selection_where, qw(tag fallback) );
        my $tag = $selection->{tag};
        die "$selection_where reads an undeclared tag\n"
          unless valid_name($tag) && exists $profile->{tags}{$tag};
        my %values   = map { $_ => 1 } @{ $profile->{tags}{$tag} };
        my $fallback = $selection->{fallback};
        die "$selection_where has an invalid fallback\n"
          unless defined $fallback && !ref($fallback) && ( $fallback eq '*' || $values{$fallback} );
    }
}

# Words may omit forms that none of their actual diagnostic rules requires.
# English's base form is checked against the canonical opcode descriptions.
sub validate_word {
    my ( $data, $language, $operation, $forms, $source ) = @_;
    my $where = "operation word $language/$operation";
    die "$where is not a known operation\n" unless exists $source->{$operation};
    die "$where is a literal keyword, not a description\n" if literal_operation( $data, $source, $operation );
    die "$where is opaque, not a fixed description\n"      if operation_class( $data, $source, $operation ) eq 'opaque';
    my $profile = $data->{languages}{$language};
    my $word    = $profile->{words}{$operation};
    check_fields( $word, $where, qw(forms tags status description) );
    die "$where description must be valid English source guidance\n"
      if exists $word->{description} && ( $language ne 'en' || !valid_text( $word->{description} ) );
    die "$where needs word forms\n" unless ref( $word->{forms} ) eq 'HASH' && keys %{ $word->{forms} };

    for my $form ( sort keys %{ $word->{forms} } ) {
        die "$where has undeclared form $form\n"   unless $forms->{$form};
        die "$where form $form has invalid text\n" unless valid_text( $word->{forms}{$form} );
    }
    my $base = $profile->{base_form};
    die "$where has stale English text in form $base\n"
      if $language eq 'en' && ( !defined $word->{forms}{$base} || $word->{forms}{$base} ne $source->{$operation} );
    die "$where has an invalid status\n"
      if exists $word->{status}
      && ( !defined $word->{status} || ref( $word->{status} ) || $word->{status} !~ /\A(?:draft|reviewed)\z/ );
    return                             unless exists $word->{tags};
    die "$where tags must be a hash\n" unless ref( $word->{tags} ) eq 'HASH';

    for my $tag ( sort keys %{ $word->{tags} } ) {
        die "$where has undeclared tag $tag\n" unless exists $profile->{tags}{$tag};
        my %values = map { $_ => 1 } @{ $profile->{tags}{$tag} };
        my $value  = $word->{tags}{$tag};
        die "$where tag $tag has an undeclared value\n"
          unless defined $value && !ref($value) && $values{$value};
    }
}

# Language declarations are independent: one language's cases or genders do
# not become required forms or tag values in another language.
sub validate_profile {
    my ( $data, $language, $source ) = @_;
    die "invalid operation vocabulary language $language\n" unless $language =~ /\A[A-Za-z][A-Za-z0-9_-]*\z/;
    my $where   = "operation vocabulary $language";
    my $profile = $data->{languages}{$language};
    check_fields( $profile, $where, qw(base_form forms tags rules words) );
    my $forms = name_set( $profile->{forms}, "$where forms" );
    die "$where needs a declared base_form\n"
      unless valid_name( $profile->{base_form} ) && $forms->{ $profile->{base_form} };
    for my $field (qw(tags rules words)) {
        die "$where $field must be a hash\n" unless ref( $profile->{$field} ) eq 'HASH';
    }
    for my $tag ( sort keys %{ $profile->{tags} } ) {
        die "$where has an invalid tag name\n" unless valid_name($tag);
        name_set( $profile->{tags}{$tag}, "$where tag $tag" );
    }
    validate_rule( $profile, $_, $forms, "$where rule $_" ) for sort keys %{ $profile->{rules} };
    validate_word( $data, $language, $_, $forms, $source )  for sort keys %{ $profile->{words} };
}

# Validate the data contract without requiring complete non-English coverage.
# A partially translated language can be structurally valid and still need work.
sub validate {
    my ($data) = @_;
    check_fields( $data, 'operation vocabulary', qw(version literal_operations opaque_operations languages) );
    die "unsupported operation vocabulary version\n"
      unless defined $data->{version} && !ref( $data->{version} ) && $data->{version} eq '2';
    die "operation vocabulary needs language definitions\n" unless ref( $data->{languages} ) eq 'HASH';
    die "operation vocabulary needs English\n"              unless exists $data->{languages}{en};
    my $source   = source_words();
    my $literals = name_set( $data->{literal_operations}, 'literal operation aliases', 1 );
    die "unknown literal operation alias $_\n" for grep { !exists $source->{$_} } sort keys %$literals;
    my $opaque = name_set( $data->{opaque_operations} || [], 'opaque operations', 1 );

    for my $name ( sort keys %$opaque ) {
        die "unknown opaque operation $name\n" unless exists $source->{$name};
        die "operation $name is both literal and opaque\n" if literal_operation( $data, $source, $name );
    }
    validate_profile( $data, $_, $source ) for sort keys %{ $data->{languages} };

    for my $operation ( sort keys %$source ) {
        next unless operation_class( $data, $source, $operation ) eq 'description';
        die "operation vocabulary is missing English word $operation\n"
          unless exists $data->{languages}{en}{words}{$operation};
    }
    return 1;
}

# Tag lookup never borrows another language's grammar. A missing tag follows
# the rule's explicit fallback; missing text is reported separately below.
sub rule_selectors {
    my ( $rule, $word ) = @_;
    my %selectors;
    for my $output ( sort keys %{ $rule->{select} } ) {
        my $selection = $rule->{select}{$output};
        my $value     = $word && $word->{tags} ? $word->{tags}{ $selection->{tag} } : undef;
        $selectors{$output} = defined $value ? $value : $selection->{fallback};
    }
    return \%selectors;
}

# Pure Perl reference implementation used to compile the lookup tables.
# Missing text makes this attempt unavailable. The caller owns whole-message
# language fallback. Literal and opaque text is preserved without inferred tags.
sub resolve_word {
    my ( $data, $language, $operation, $rule_name, $original, $source ) = @_;
    my $profile = $data->{languages}{$language};
    return { status => 'unknown_language' } unless $profile;
    my $rule = $profile->{rules}{$rule_name};
    die "operation vocabulary $language has no rule $rule_name\n" unless $rule;
    my $result = { form => $rule->{form}, selectors => rule_selectors( $rule, undef ) };
    $source ||= source_words();
    if ( operation_class( $data, $source, $operation ) eq 'opaque' ) {
        return { %$result, status => 'unknown_operation' } unless defined $original;
        die "opaque operation text must be a string\n" if ref($original);
        return { %$result, status => 'opaque', text => $original };
    }
    if ( literal_operation( $data, $source, $operation ) ) {
        die "literal operation text must be a string\n" if ref($original);
        return { %$result, status => 'literal', text => defined $original ? $original : $source->{$operation} };
    }
    my $word = $profile->{words}{$operation};
    return { %$result, status => 'missing_word' } unless $word;
    return { %$result, status => 'missing_form' } unless exists $word->{forms}{ $rule->{form} };
    return {
        %$result,
        status    => 'resolved',
        text      => $word->{forms}{ $rule->{form} },
        selectors => rule_selectors( $rule, $word ),
        ( exists $word->{status} ? ( review_status => $word->{status} ) : () ),
    };
}

# Identity sources are retained internal inputs, not grammatical selectors.
# A binding maps each rule output to its own diagnostic selector dimension.
sub validate_bindings {
    my ( $diag, $data, $allow_missing_forms ) = @_;
    return unless exists $diag->{operation_words};
    $data ||= catalog();
    my $bindings = $diag->{operation_words};
    die "diagnostic $diag->{code} operation_words must be a hash\n" unless ref($bindings) eq 'HASH';
    my %params    = map { $_->{name} => $_ } @{ $diag->{params} || [] };
    my %displayed = map { $_->{name} => 1 } @{ Diag::Migration::template_parameter_union($diag) };
    my %derived   = map { $_->{name} => 1 }
      grep { $_->{operation_word} } @{ $diag->{selector_definitions} || [] };
    my %producer_selectors = map { $_ => 1 }
      grep { !$derived{$_} } @{ $diag->{message_selectors} || [] };
    my $source = source_words();
    my %selector_owners;

    for my $name ( sort keys %$bindings ) {
        my $where = "diagnostic $diag->{code} operation word $name";
        die "$where is not a displayed parameter\n" unless $displayed{$name};
        die "$where is not a text parameter\n"      unless $params{$name}{type} eq 'text';
        my $binding = $bindings->{$name};
        check_fields( $binding, $where, qw(source operations rules selectors assert_unknown) );
        die "$where assert_unknown must be 0 or 1\n"
          if exists $binding->{assert_unknown}
          && (!defined $binding->{assert_unknown}
            || ref( $binding->{assert_unknown} )
            || $binding->{assert_unknown} !~ /\A[01]\z/ );
        my $identity = $binding->{source};
        die "$where has no retained identity source\n"
          unless valid_name($identity)
          && $params{$identity}
          && $params{$identity}{internal}
          && defined $params{$identity}{type}
          && $params{$identity}{type} =~ /\A(?:text|uv)\z/;
        my $operations = name_set( $binding->{operations}, "$where operations" );
        die "$where has unknown operation $_\n" for grep { !exists $source->{$_} } sort keys %$operations;
        die "$where rules must be a hash\n"     unless ref( $binding->{rules} ) eq 'HASH';
        die "$where needs an English rule\n"    unless exists $binding->{rules}{en};
        die "$where selectors must be a hash\n" unless ref( $binding->{selectors} ) eq 'HASH';

        for my $output ( sort keys %{ $binding->{selectors} } ) {
            my $selector = $binding->{selectors}{$output};
            die "$where has an invalid selector mapping\n" unless valid_name($output) && valid_name($selector);
            die "$where output $selector conflicts with a producer selector\n" if $producer_selectors{$selector};
            die "$where shares selector $selector with $selector_owners{$selector}\n"
              if exists $selector_owners{$selector};
            $selector_owners{$selector} = $name;
        }
        my %used_outputs;
        for my $language ( sort keys %{ $binding->{rules} } ) {
            my $profile = $data->{languages}{$language};
            die "$where has unknown language $language\n" unless $profile;
            my $rule_name = $binding->{rules}{$language};
            die "$where language $language has no rule\n"
              unless valid_name($rule_name) && exists $profile->{rules}{$rule_name};
            my $rule = $profile->{rules}{$rule_name};
            for my $output ( sort keys %{ $rule->{select} } ) {
                die "$where language $language rule $rule_name has unmapped output $output\n"
                  unless exists $binding->{selectors}{$output};
                $used_outputs{$output} = 1;
            }
            for my $operation ( sort keys %$operations ) {
                next unless operation_class( $data, $source, $operation ) eq 'description';
                my $word = $profile->{words}{$operation};
                die "$where language $language operation $operation rule $rule_name needs form $rule->{form}\n"
                  if !$allow_missing_forms && $word && !exists $word->{forms}{ $rule->{form} };
            }
        }
        die "$where has unused selector output $_\n"
          for grep { !$used_outputs{$_} } sort keys %{ $binding->{selectors} };
    }
    return 1;
}

# Return independent grammatical domains. Later table generation will merge
# these with explicit template cases, then assign packed-key fields and IDs.
sub binding_selector_domains {
    my ( $diag, $data ) = @_;
    $data ||= catalog();
    validate_bindings( $diag, $data );
    return rule_selector_domains( $diag, $data );
}

# Schema normalization needs these domains before template validation can run.
# Full binding validation follows after the derived dimensions exist.
sub rule_selector_domains {
    my ( $diag, $data, $only_language ) = @_;
    my %domains;
    for my $binding ( values %{ $diag->{operation_words} || {} } ) {
        my @languages = defined($only_language) ? ($only_language) : sort keys %{ $binding->{rules} };
        for my $language (@languages) {
            next unless defined $binding->{rules}{$language};
            my $profile = $data->{languages}{$language};
            die "diagnostic $diag->{code} has unknown word language $language\n" unless $profile;
            my $rule = $profile->{rules}{ $binding->{rules}{$language} };
            die "diagnostic $diag->{code} has unknown word rule in $language\n" unless $rule;
            for my $output ( sort keys %{ $rule->{select} } ) {
                my $selector  = $binding->{selectors}{$output};
                my $selection = $rule->{select}{$output};
                $domains{$selector}{$_} = 1 for @{ $profile->{tags}{ $selection->{tag} } };
            }
        }
    }
    return { map { $_ => [ sort keys %{ $domains{$_} } ] } sort keys %domains };
}

# Grammatical dimensions belong to the existing selector layout. They have
# retained identity sources, but no extra parameter or producer-supplied value.
sub normalize_selectors {
    my ( $diag, $data ) = @_;
    my $domains = rule_selector_domains( $diag, $data || catalog() );
    my %seen    = map { $_ => 1 } @{ $diag->{message_selectors} || [] };
    for my $word ( sort keys %{ $diag->{operation_words} } ) {
        my $binding = $diag->{operation_words}{$word};
        for my $output ( sort keys %{ $binding->{selectors} } ) {
            my $name = $binding->{selectors}{$output};
            die "diagnostic $diag->{code} word selector $name conflicts with another selector\n" if $seen{$name}++;
            die "diagnostic $diag->{code} has unused word selector $name\n" unless $domains->{$name};
            my $english   = ( $data || catalog() )->{languages}{en}{rules}{ $binding->{rules}{en} };
            my $selection = $english->{select}{$output};
            push @{ $diag->{message_selectors} ||= [] }, $name;
            push @{ $diag->{selector_definitions} ||= [] },
              {
                name           => $name,
                source         => $binding->{source},
                values         => $domains->{$name},
                operation_word => $word,
                word_zero      => !$selection || $selection->{fallback} eq '*' ? 1 : 0,
                ( @{ $domains->{$name} } > 255 ? ( wide => 1 ) : () ),
              };
        }
    }
}

# Keep numeric identities in opcode order. Zero is unknown, and the synthetic
# do-block identity follows the actual opcode table. C emits OP_* + 1 symbols.
sub operation_names {
    my @names;
    for my $line ( split /\n/, Diag::Migration::read_source('regen/opcodes') ) {
        next if $line =~ /\A(?:\s*#|\s*\z)/;
        push @names, ( split /\t+/, $line )[0];
    }
    return [ @names, 'do_block' ];
}

# Assemble bytes rather than shifting Perl integers. Regeneration must produce
# the same U64 keys when its host Perl has only 32-bit integers.
sub set_key_field {
    my ( $bytes, $packed, $column, $value ) = @_;
    my $width = $packed->{widths}[$column];
    substr( $$bytes, $packed->{shifts}[$column] / 8, $width / 8 ) =
      $width == 16 ? pack( 'v', $value ) : pack( 'C', $value );
}

# Bind rule outputs to the existing diagnostic fields. The same packing is
# used for translated words and the explicit literal/unknown fallback.
sub compile_word_outputs {
    my ( $diag, $binding, $outputs, $columns, $packed, $selector_layout ) = @_;
    my $key = "\0" x 8;
    for my $output ( sort keys %$outputs ) {
        my $dimension = $binding->{selectors}{$output};
        my $column    = $columns->{$dimension};
        my $value     = $outputs->{$output};
        next if $value eq '*';
        my $domain = Diag::Migration::selector_column_values( $diag, $column );
        my $ids = $selector_layout
          ? $selector_layout->{ids}[$column]
          : { map { $domain->[$_] => $_ + 1 } 0 .. $#$domain };
        die "diagnostic $diag->{code} word selector $dimension has unknown value $value\n" unless $ids->{$value};
        set_key_field( \$key, $packed, $column, $ids->{$value} );
    }
    return unpack( 'H16', scalar reverse $key );
}

# A NULL phrase preserves the original text while still applying rule outputs.
sub intern_word_value {
    my ( $language, $values, $interned, $text, $key ) = @_;
    my $signature = $key . ':' . ( defined $text ? $text : '' );
    unless ( exists $interned->{$signature} ) {
        die "operation vocabulary $language exceeds U16 value IDs\n" if @$values >= 65535;
        $interned->{$signature} = scalar @$values;
        push @$values, { text => $text, key => $key };
    }
    return $interned->{$signature};
}

# Compile each language independently. Map entries 0 and 1 mean unavailable
# and pass-through respectively. All other entries intern a complete phrase
# and its already-packed grammatical outputs. No runtime grammar is needed.
sub compile {
    my ( $diagnostics, $data, $selector_layouts_by_language ) = @_;
    $data ||= catalog();
    my $names  = operation_names();
    my $source = source_words();
    die "operation vocabulary exceeds U16 identity-map bounds\n" if @$names + 1 > 65535;
    my %identities       = map { $names->[$_] => $_ + 1 } 0 .. $#$names;
    my %needed_languages = map { $_           => 1 } keys %{ $data->{languages} };
    for my $diag (@$diagnostics) {
        $needed_languages{$_} = 1 for keys %{ $diag->{message_template} || {} };
        validate_bindings( $diag, $data ) if $diag->{operation_words};
    }
    my %languages;
    my @compile_languages = $selector_layouts_by_language
      ? sort keys %$selector_layouts_by_language
      : sort keys %needed_languages;
    for my $language (@compile_languages) {
        my @values   = ( { text => undef, key => '0' x 16 }, { text => undef, key => '0' x 16 } );
        my %interned = ( ( '0' x 16 ) . ':' => 1 );
        my %bindings;
        my %resolved_words;
        for my $diag ( sort { $a->{number} <=> $b->{number} } @$diagnostics ) {
            next unless $diag->{operation_words};
            my $layout    = Diag::Migration::template_parameter_layout($diag);
            my $packed    = Diag::Migration::selector_packed_layout($diag);
            my $language_layouts = $selector_layouts_by_language
              ? $selector_layouts_by_language->{$language}
              : undef;
            my $selector_layout = $language_layouts
              ? $language_layouts->{ $diag->{code} }
              : undef;
            my @selectors = @{ $diag->{message_selectors} || [] };
            my %columns   = map { $selectors[$_] => $_ } 0 .. $#selectors;
            for my $name (
                sort { $layout->{canonical_indices}{$a} <=> $layout->{canonical_indices}{$b} }
                keys %{ $diag->{operation_words} }
              )
            {
                my $binding     = $diag->{operation_words}{$name};
                my $rule        = $binding->{rules}{$language};
                my $fallback_id = 0;
                if ( defined $rule ) {
                    my $outputs = rule_selectors( $data->{languages}{$language}{rules}{$rule}, undef );
                    my $key     = compile_word_outputs( $diag, $binding, $outputs, \%columns, $packed,
                        $selector_layout );
                    $fallback_id = intern_word_value( $language, \@values, \%interned, undef, $key );
                }

                # Reserve the last U16 value for audited-domain assertions.
                # Entry zero always retains the release-build fallback.
                my @map = ( $binding->{assert_unknown} ? 65535 : $fallback_id ) x ( @$names + 1 );
                $map[0] = $fallback_id;
                my $mask = "\0" x 8;
                for my $dimension ( values %{ $binding->{selectors} } ) {
                    my $column = $columns{$dimension};
                    die "diagnostic $diag->{code} has no word selector $dimension\n" unless defined $column;
                    set_key_field( \$mask, $packed, $column, $packed->{widths}[$column] == 16 ? 65535 : 255 );
                }
                for my $operation ( @{ $binding->{operations} } ) {
                    my $resolved;
                    if ( defined $rule ) {
                        my $cache_key = "$rule:$operation";
                        $resolved = $resolved_words{$cache_key} ||=
                          resolve_word( $data, $language, $operation, $rule, undef, $source );
                    }
                    my $identity = $identities{$operation};
                    die "unknown operation identity $operation\n" unless $identity;
                    if ( !$resolved || $resolved->{status} =~ /\Amissing_/ ) {
                        $map[$identity] = 0;
                        next;
                    }
                    $map[$identity] = $fallback_id;
                    next unless $resolved->{status} eq 'resolved';
                    my $key = compile_word_outputs( $diag, $binding, $resolved->{selectors}, \%columns, $packed,
                        $selector_layout );
                    $map[$identity] = intern_word_value( $language, \@values, \%interned, $resolved->{text}, $key );
                }
                push @{ $bindings{ $diag->{code} } },
                  {
                    assert_unknown => $binding->{assert_unknown} ? 1 : 0,
                    map            => \@map,
                    mask           => unpack( 'H16', scalar reverse $mask ),
                    source         => $layout->{diagnostic_indices}{ $binding->{source} },
                    target         => $layout->{canonical_indices}{$name},
                    numeric => ( grep { $_->{name} eq $binding->{source} && $_->{type} eq 'uv' } @{ $diag->{params} } )
                    ? 1
                    : 0,
                  };
            }
        }
        $languages{$language} = { values => \@values, bindings => \%bindings };
    }
    return { operations => $names, languages => \%languages };
}

# Translation packets share one dictionary across independent operation roles.
# Missing translations remain explicit alongside the runtime binding contract.
sub context {
    my ( $diag, $language, $data ) = @_;
    return unless exists $diag->{operation_words};
    $data ||= catalog();
    validate_bindings( $diag, $data, 1 );
    my $source = source_words();
    my ( @parameters, %words, %rules, %english_rules );
    my $target = $data->{languages}{$language};
    for my $name ( sort keys %{ $diag->{operation_words} } ) {
        my $binding   = $diag->{operation_words}{$name};
        my $rule_name = $binding->{rules}{$language};
        $rules{$rule_name} = $target->{rules}{$rule_name} if defined $rule_name;
        my $english_rule = $binding->{rules}{en};
        $english_rules{$english_rule} = $data->{languages}{en}{rules}{$english_rule};
        for my $operation ( @{ $binding->{operations} } ) {
            next if exists $words{$operation};
            $words{$operation} = {
                operation      => $operation,
                english        => $source->{$operation},
                english_word   => $data->{languages}{en}{words}{$operation},
                classification => operation_class( $data, $source, $operation ),
                translation    => $target ? $target->{words}{$operation} : undef,
            };
        }
        my %rule_names = ( en => $english_rule );
        $rule_names{$language} = $rule_name if defined $rule_name;
        push @parameters, { parameter => $name, %$binding, rules => \%rule_names };
    }
    return {
        parameters           => \@parameters,
        words                => \%words,
        rules                => \%rules,
        english_rules        => \%english_rules,
        profile              => $target ? { map { $_ => $target->{$_} } qw(base_form forms tags) } : undef,
        runtime_substitution => 1,
    };
}

# Share the dependency shape across sentence and vocabulary provenance.
# Review status and unused forms are not upstream rendering dependencies.
sub word_dependencies {
    my ( $word, $forms ) = @_;
    return unless $word;
    return {
        forms => { map { $_ => $word->{forms}{$_} } sort keys %$forms },
        tags  => $word->{tags} || {},
        exists $word->{description} ? ( description => $word->{description} ) : (),
    };
}

# Fingerprints track the forms and rules a diagnostic actually uses. A profile
# may declare extra forms for other sentences without invalidating this one.
sub dependencies {
    my ( $diag, $language, $data ) = @_;
    $data ||= catalog();
    my $context = context( $diag, $language, $data ) or return;
    my %forms;
    for my $parameter ( @{ $context->{parameters} } ) {
        for my $lc ( 'en', $language ) {
            my $rule_name = $parameter->{rules}{$lc};
            next unless defined $rule_name;
            $forms{$lc}{ $data->{languages}{$lc}{rules}{$rule_name}{form} } = 1;
        }
    }
    for my $word ( values %{ $context->{words} } ) {
        for my $pair ( [ en => 'english_word' ], [ $language => 'translation' ] ) {
            my ( $lc, $field ) = @$pair;
            my $entry = $word->{$field} or next;
            $word->{$field} = word_dependencies( $entry, $forms{$lc} || {} );
        }
    }
    if ( $context->{profile} ) {
        my %tags = map { $_->{tag} => 1 }
          map { values %{ $_->{select} } } values %{ $context->{rules} };
        $context->{profile} = {
            forms => [ sort keys %{ $forms{$language} || {} } ],
            tags  => { map { $_ => $context->{profile}{tags}{$_} } sort keys %tags },
        };
    }
    return $context;
}

# Report missing runtime dependencies independently of sentence coverage.
# Draft status is linguistic review information, not a missing translation.
sub coverage {
    my ( $diag, $language, $data ) = @_;
    $data ||= catalog();
    my $source = source_words();
    my ( %needed, %drafts, @missing_words, @missing_forms, @missing_rules );
    for my $parameter ( sort keys %{ $diag->{operation_words} || {} } ) {
        my $binding   = $diag->{operation_words}{$parameter};
        my $profile   = $data->{languages}{$language};
        my $rule_name = $binding->{rules}{$language};
        my $rule      = $profile && defined $rule_name ? $profile->{rules}{$rule_name} : undef;
        push @missing_rules, { parameter => $parameter, rule => $rule_name } unless $rule;
        for my $operation ( @{ $binding->{operations} } ) {
            next unless operation_class( $data, $source, $operation ) eq 'description';
            $needed{$operation} = 1;
            my $word = $profile ? $profile->{words}{$operation} : undef;
            if ( !$word ) {
                push @missing_words, $operation unless grep { $_ eq $operation } @missing_words;
                next;
            }
            $drafts{$operation} = 1 unless ( $word->{status} || 'draft' ) eq 'reviewed';
            push @missing_forms, { parameter => $parameter, operation => $operation, form => $rule->{form} }
              if $rule && !exists $word->{forms}{ $rule->{form} };
        }
    }
    return {
        required_words   => scalar keys %needed,
        missing_words    => [ sort @missing_words ],
        missing_forms    => \@missing_forms,
        missing_rules    => \@missing_rules,
        unreviewed_words => [ sort keys %drafts ],
        complete         => @missing_words || @missing_forms || @missing_rules ? 0 : 1,
    };
}

# Preserve config documentation while writing deterministic, executable Perl.
# This writer is used only for imports; ordinary regeneration leaves it alone.
sub render_catalog {
    my ($data) = @_;
    require Data::Dumper;
    require Encode;
    my $source = Encode::decode( 'UTF-8', Diag::Migration::read_source('diag_op_conf.pl'), Encode::FB_CROAK() );
    my ($preamble) = $source =~ /\A(.*?)^\+\{/ms;
    die "Missing operation vocabulary preamble\n" unless defined $preamble;
    Diag::Migration::_upgrade_catalog_text($data);
    my $dumper = Data::Dumper->new( [$data] )->Terse(1)->Indent(1)->Sortkeys(1)->Useqq(1)->Deepcopy(1);
    $dumper->Useutf8(1) if $dumper->can('Useutf8');
    return $preamble . '+' . Diag::Migration::_readable_catalog_dump( $dumper->Dump );
}

1;
