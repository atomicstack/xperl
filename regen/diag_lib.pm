# Helpers shared by diagnostic inventory and bulk migration tools.

package Diag::Migration;
use strict;
use warnings;
use Scalar::Util qw(refaddr);

sub read_source {
    my ($file) = @_;
    open my $fh, '<', $file or die "Can't open $file: $!\n";
    local $/;
    return <$fh>;
}

sub severity_name {
    my ( $conf, $value ) = @_;
    return unless defined $value && !ref($value);
    my $aliases = $conf->{severities};
    return $value if exists $aliases->{$value};
    my ($name) = grep { $aliases->{$_} eq $value } keys %$aliases;
    return $name;
}

sub check_identity {
    my ( $entry, $type, $codes, $numbers ) = @_;
    die "$type entry is not a hash\n" unless ref($entry) eq 'HASH';
    my ( $code, $number ) = @{$entry}{qw(code number)};
    die "$type has no valid code\n"
      unless defined $code && $code =~ /\A[A-Z][A-Z0-9_]*\z/;
    die "duplicate $type code $code\n" if $codes->{$code}++;
    die "$type $code has no numeric identity\n"
      unless defined $number && $number =~ /\A[0-9]+\z/;
    die "duplicate $type number $number\n" if $numbers->{$number}++;
}

sub diagnostic_enum_name {
    my ( $code, $suffix ) = @_;
    return 'perl_diag_' . lc($code) . '_' . lc($suffix);
}

sub macro_name {
    my ($diag) = @_;
    return $diag->{macro} if exists $diag->{macro};
    return 'PERL_' . macro_family($diag) . '_' . $diag->{code};
}

sub macro_family {
    my ( $diag, $api ) = @_;
    $api ||= $diag->{emit}{api} || 'DIE';
    return 'ADD_COMPILE_ERR' if $api =~ /^(?:YYERROR|DEFER_ERROR)/;
    return 'FORMAT'          if $api eq 'RENDER';
    return 'APPEND'          if $api eq 'APPEND_EXCEPTION';
    return 'CHECK_TAINT'     if $api eq 'TAINT';
    return 'THROW'           if $api eq 'FATAL_WARNER';
    if ( $api =~ /^WARN/ || is_warning_emitter($api) ) {
        return 'DEPRECATE'
          if $diag->{severity} =~ /^(?:D|DEPRECATION)$/
          || grep { /^WARN_DEPRECATED(?:_|$)/ } @{ $diag->{warning_categories} || [] };
        return 'WARN';
    }
    return 'PANIC' if $diag->{severity} =~ /^(?:P|INTERNAL_ERROR)$/;
    return 'THROW';
}

sub alias_macro_name {
    my ( $diag, $api ) = @_;
    return $diag->{macro_aliases}{$api}
      if exists $diag->{macro_aliases} && exists $diag->{macro_aliases}{$api};
    my $family    = macro_family( $diag, $api );
    my %qualifier = (
        DIE             => 'DIE',
        DIE_SV          => 'DIE_SV',
        DIE_NOCONTEXT   => 'NO_CONTEXT',
        CROAK           => 'CURRENT',
        CROAK_NOCONTEXT => 'NO_CONTEXT',
        CROAK_CONTEXT   => 'WITH_CONTEXT',
        CROAK_CALLER    => 'AT_CALLER',
        NOPERL_DIE      => 'BEFORE_INIT',
        WARN            => 'PLAIN',
        WARN_SV         => 'SV',
        WARNER          => 'UNCHECKED',
        CK_WARNER       => 'IF_ENABLED',
        CK_WARNER_D     => 'DEFAULT_ENABLED',
    );
    my $suffix = $family eq macro_family($diag) ? '_' . ( $qualifier{$api} || $api ) : '';
    return "PERL_${family}_$diag->{code}$suffix";
}

sub variant_api {
    my ( $diag, $variant ) = @_;
    return $variant->{emit}{api} if exists $variant->{emit} && exists $variant->{emit}{api};
    return $diag->{emit}{api} || 'DIE';
}

sub variant_macro_name {
    my ( $diag, $code, $variant ) = @_;
    return $variant->{macro} if exists $variant->{macro};
    return 'PERL_' . macro_family( $diag, variant_api( $diag, $variant ) ) . '_' . $code;
}

# Wildcards have two accepted spellings but one stored representation.
sub normalize_template_wildcards {
    my ($node) = @_;
    return $node unless ref($node) eq 'HASH';
    die "template branch has both any and * fallbacks\n"
      if exists $node->{any} && exists $node->{'*'};
    return { map { ( $_ eq 'any' ? '*' : $_ ) => normalize_template_wildcards( $node->{$_} ) } keys %$node };
}

sub normalize_diagnostic_schema {
    my ($diag) = @_;
    return unless exists $diag->{message};

    my $message = delete $diag->{message};
    die "message must be a hash\n" unless ref($message) eq 'HASH';
    die "message contains an unknown field\n"
      if grep { !/\A(?:templates|args|selectors|dynamic)\z/ } keys %$message;
    $diag->{message_template} = delete $message->{templates}
      if exists $message->{templates};
    for my $language ( keys %{ $diag->{message_template} || {} } ) {
        $diag->{message_template}{$language} = normalize_template_wildcards( $diag->{message_template}{$language} );
    }
    $diag->{params} = delete $message->{args}
      if exists $message->{args};
    $diag->{dynamic} = delete $message->{dynamic}
      if exists $message->{dynamic};

    if ( exists $message->{selectors} ) {
        my $selectors = delete $message->{selectors};
        die "message selectors must be an array\n"
          unless ref($selectors) eq 'ARRAY';
        my ( @names, @definitions );
        my %seen;
        for my $selector (@$selectors) {
            die "message selector must be a hash\n"
              unless ref($selector) eq 'HASH';
            die "message selector has an unknown field\n"
              if grep { !/\A(?:name|source|values|unsorted|assert_unknown|plural|wide)\z/ } keys %$selector;
            my $name = $selector->{name};
            die "message selector has no name\n"
              unless defined $name && !ref($name);
            die "duplicate message selector $name\n" if $seen{$name}++;
            push @names, $name;
            my $source = $selector->{source} || $name;
            my ($arg) = grep { $_->{name} eq $source } @{ $diag->{params} || [] };
            die "message selector $name has no message argument\n"
              unless $arg;
            my $definition = {
                name   => $name,
                source => $source,
                values => exists( $selector->{values} ) ? $selector->{values} : $arg->{selector_values},
            };
            $definition->{plural} = $selector->{plural} if exists $selector->{plural};
            $definition->{wide}   = $selector->{wide}   if exists $selector->{wide};
            die "plural selector $name defines its own values\n"
              if exists $selector->{plural} && defined $definition->{values};
            $definition->{unsorted} =
              exists( $selector->{unsorted} ) ? $selector->{unsorted} : $arg->{selector_unsorted}
              if exists( $selector->{unsorted} ) || exists( $arg->{selector_unsorted} );
            $definition->{assert_unknown} = $selector->{assert_unknown}
              if exists $selector->{assert_unknown};
            push @definitions, $definition;
        }
        $diag->{message_selectors}    = \@names;
        $diag->{selector_definitions} = \@definitions;
    }

    my %seen_selectors = map { $_ => 1 } @{ $diag->{message_selectors} || [] };
    for my $arg ( @{ $diag->{params} || [] } ) {
        next unless exists $arg->{selector_values};
        next if $seen_selectors{ $arg->{name} };
        push @{ $diag->{message_selectors} ||= [] }, $arg->{name};
        my $definition = {
            name   => $arg->{name},
            source => $arg->{name},
            values => $arg->{selector_values},
        };
        $definition->{unsorted}       = $arg->{selector_unsorted} if exists $arg->{selector_unsorted};
        $definition->{assert_unknown} = $arg->{selector_assert_unknown}
          if exists $arg->{selector_assert_unknown};
        push @{ $diag->{selector_definitions} ||= [] }, $definition;
        $seen_selectors{ $arg->{name} } = 1;
    }

    if ( $diag->{operation_words} ) {
        require './regen/diag_words.pm';
        Diag::Words::normalize_selectors($diag);
    }

    my $emit = $diag->{emit};
    die "emit must be a hash\n" unless ref($emit) eq 'HASH';
    $emit->{params}        = delete $emit->{args} if exists $emit->{args};
    $diag->{parser_action} = delete $emit->{parser_action}
      if exists $emit->{parser_action};
    $diag->{warning_categories} = delete $emit->{warning_categories}
      if exists $emit->{warning_categories};
    if ( exists $emit->{aliases} ) {
        my $aliases = delete $emit->{aliases};
        die "emit aliases must be an array\n" unless ref($aliases) eq 'ARRAY';
        my ( @apis, %macro_aliases );
        for my $alias (@$aliases) {
            die "emit alias must be a hash\n" unless ref($alias) eq 'HASH';
            die "emit alias has an unknown field\n"
              if grep { !/\A(?:api|macro)\z/ } keys %$alias;
            my $api = $alias->{api};
            die "emit alias has no API\n" unless defined $api && !ref($api);
            push @apis, $api;
            $macro_aliases{$api} = $alias->{macro} if exists $alias->{macro};
        }
        $emit->{aliases}       = \@apis;
        $diag->{macro_aliases} = \%macro_aliases if %macro_aliases;
    }

    for my $variant ( values %{ $diag->{variants} || {} } ) {
        next unless ref($variant) eq 'HASH' && ref( $variant->{emit} ) eq 'HASH';
        $variant->{parser_action} = delete $variant->{emit}{parser_action}
          if exists $variant->{emit}{parser_action};
    }
}

sub canonical_diagnostic_schema {
    my ($diag) = @_;
    my %entry = %$diag;
    $entry{tags}         = [ sort @{ $entry{tags} } ]         if exists $entry{tags};
    $entry{source_files} = [ sort @{ $entry{source_files} } ] if exists $entry{source_files};
    my %message;
    $message{templates} = delete $entry{message_template}
      if exists $entry{message_template};
    my @args              = map  { +{%$_} } @{ $entry{params} || [] };
    my %arg_by_name       = map  { $_->{name} => $_ } @args;
    my %selector_by_name  = map  { $_->{name} => $_ } @{ $entry{selector_definitions} || [] };
    my $has_wide_selector = grep { $_->{wide} } @{ $entry{selector_definitions} || [] };
    my @selectors;

    for my $name ( @{ $entry{message_selectors} || [] } ) {
        my $definition = $selector_by_name{$name} || {};
        next if $definition->{operation_word};
        my $arg      = $arg_by_name{$name};
        my %selector = ( name => $name );
        my $source   = $definition->{source} || $name;
        $selector{source} = $source if $source ne $name;
        my $values =
            exists( $definition->{values} )           ? $definition->{values}
          : $arg && exists( $arg->{selector_values} ) ? $arg->{selector_values}
          :                                             undef;
        if (  !$has_wide_selector
            && $source eq $name
            && $arg
            && defined $values
            && !exists $definition->{plural}
            && !exists $definition->{wide} )
        {
            $arg->{selector_values}         = $values;
            $arg->{selector_unsorted}       = $definition->{unsorted} if exists $definition->{unsorted};
            $arg->{selector_assert_unknown} = $definition->{assert_unknown}
              if exists $definition->{assert_unknown};
            next;
        }
        if ( $has_wide_selector && $source eq $name && $arg ) {
            delete @{$arg}{qw(selector_values selector_unsorted selector_assert_unknown)};
        }
        $selector{values}         = $values                 if defined $values;
        $selector{plural}         = $definition->{plural}   if exists $definition->{plural};
        $selector{wide}           = $definition->{wide}     if exists $definition->{wide};
        $selector{unsorted}       = $definition->{unsorted} if exists $definition->{unsorted};
        $selector{assert_unknown} = $definition->{assert_unknown}
          if exists $definition->{assert_unknown};
        push @selectors, \%selector;
    }
    $message{args}      = \@args                 if exists $entry{params};
    $message{selectors} = \@selectors            if @selectors;
    $message{dynamic}   = delete $entry{dynamic} if exists $entry{dynamic};
    $entry{message}     = \%message              if %message;
    delete $entry{params};
    delete $entry{message_selectors};
    delete $entry{selector_definitions};

    my %emit = %{ $entry{emit} || {} };
    $emit{args}          = delete $emit{params} if exists $emit{params};
    $emit{parser_action} = delete $entry{parser_action}
      if exists $entry{parser_action};
    $emit{warning_categories} = delete $entry{warning_categories}
      if exists $entry{warning_categories};
    if ( exists $emit{aliases} ) {
        my @aliases = map {
            my %alias = (
                api   => $_,
                macro => alias_macro_name( $diag, $_ )
            );
            \%alias;
        } @{ $emit{aliases} };
        $emit{aliases} = \@aliases;
    }
    delete $entry{macro_aliases};
    $entry{emit} = \%emit;

    if ( exists $entry{variants} ) {
        $entry{variants} = {
            map { $_ => { %{ $entry{variants}{$_} } } }
              keys %{ $entry{variants} }
        };
    }
    for my $variant ( values %{ $entry{variants} || {} } ) {
        next unless ref($variant) eq 'HASH';
        my %variant_emit = %{ $variant->{emit} || {} };
        $variant_emit{parser_action} = delete $variant->{parser_action}
          if exists $variant->{parser_action};
        $variant->{emit} = \%variant_emit if %variant_emit;
    }

    return \%entry;
}

# Collect array leaves without replacing references shared through the catalog.
sub collect_selector_arrays {
    my ( $values, $unsorted, $arrays ) = @_;

    if ( ref($values) eq 'ARRAY' ) {
        die "selector values must be scalar strings\n" if grep { !defined($_) || ref($_) } @$values;
        my $id = refaddr($values);
        $arrays->{$id}{values} = $values;
        $arrays->{$id}{unsorted} ||= $unsorted;
    }
    elsif ( ref($values) eq 'HASH' ) {
        collect_selector_arrays( $values->{$_}, $unsorted, $arrays ) for sort keys %$values;
    }
    else {
        die "selector values must be an array or conditional hash\n";
    }
}

# A marked use protects the entire shared domain, including unmarked aliases.
# Sort other array leaves before assigning IDs or writing the normalized config.
sub normalize_selector_order {
    my ($diagnostics) = @_;

    my %arrays;
    for my $diag (@$diagnostics) {
        for my $param ( @{ $diag->{params} || [] } ) {
            die "parameter $param->{name} has an invalid selector_unsorted flag\n"
              if exists( $param->{selector_unsorted} )
              && (!defined( $param->{selector_unsorted} )
                || ref( $param->{selector_unsorted} )
                || $param->{selector_unsorted} !~ /\A[01]\z/ );
            die "parameter $param->{name} has an invalid selector_assert_unknown flag\n"
              if exists( $param->{selector_assert_unknown} )
              && (!defined( $param->{selector_assert_unknown} )
                || ref( $param->{selector_assert_unknown} )
                || $param->{selector_assert_unknown} !~ /\A[01]\z/ );
            die "parameter $param->{name} has selector_unsorted without selector_values\n"
              if exists( $param->{selector_unsorted} ) && !exists( $param->{selector_values} );
            die "parameter $param->{name} has selector_assert_unknown without selector_values\n"
              if exists( $param->{selector_assert_unknown} ) && !exists( $param->{selector_values} );
            collect_selector_arrays( $param->{selector_values}, $param->{selector_unsorted} || 0, \%arrays )
              if exists $param->{selector_values};
        }
        for my $selector ( @{ $diag->{selector_definitions} || [] } ) {
            die "selector $selector->{name} has an invalid unsorted flag\n"
              if exists( $selector->{unsorted} )
              && (!defined( $selector->{unsorted} )
                || ref( $selector->{unsorted} )
                || $selector->{unsorted} !~ /\A[01]\z/ );
            collect_selector_arrays( $selector->{values}, $selector->{unsorted} || 0, \%arrays )
              unless exists $selector->{plural};
        }
    }
    for my $array ( values %arrays ) {
        next if $array->{unsorted};
        @{ $array->{values} } = sort @{ $array->{values} };
    }
}

# Validate the shared vocabulary before checking individual tags. Tags record
# analysis metadata and do not select classes, templates, severity, or delivery.
sub validate_diagnostic_tag_metadata {
    my ($conf) = @_;
    return {} unless exists $conf->{diagnostic_tags};

    my $metadata = $conf->{diagnostic_tags};
    die "diagnostic tag metadata must be a hash\n"
      unless ref($metadata) eq 'HASH';

    die "diagnostic tag metadata has no valid review status\n"
      unless defined $metadata->{review_status}
      && !ref( $metadata->{review_status} )
      && $metadata->{review_status} =~ /\A(?:provisional|reviewed)\z/;

    my $definitions = $metadata->{definitions};
    die "diagnostic tag definitions must be a hash\n"
      unless ref($definitions) eq 'HASH';

    for my $tag ( sort keys %$definitions ) {
        die "invalid diagnostic tag name '$tag'\n"
          unless $tag =~ /\A[a-z][a-z0-9_]*:[a-z][a-z0-9_]*\z/;

        die "diagnostic tag '$tag' has no description\n"
          unless defined $definitions->{$tag}
          && !ref( $definitions->{$tag} )
          && length $definitions->{$tag};
    }

    return $definitions;
}

# Check each diagnostic against the shared vocabulary before preserving its
# tags in normalized catalog output.
sub validate_diagnostic_tags {
    my ( $diag, $definitions ) = @_;
    return unless exists $diag->{tags};

    my $code = $diag->{code};
    die "diagnostic $code tags must be an array\n"
      unless ref( $diag->{tags} ) eq 'ARRAY';

    my %seen;
    for my $tag ( @{ $diag->{tags} } ) {
        die "diagnostic $code has an invalid tag\n"
          unless defined $tag && !ref($tag);

        die "diagnostic $code has an unknown tag '$tag'\n"
          unless exists $definitions->{$tag};

        die "diagnostic $code repeats tag '$tag'\n" if $seen{$tag}++;
    }
}

# Derived references are catalog data too. Validate stored lists before sorting
# them, even when a caller only exports translations and does not rescan source.
sub validate_diagnostic_source_files {
    my ($diag) = @_;
    return unless exists $diag->{source_files};

    die "diagnostic $diag->{code} source_files must be an array\n"
      unless ref( $diag->{source_files} ) eq 'ARRAY';

    my %seen;
    for my $file ( @{ $diag->{source_files} } ) {
        die "diagnostic $diag->{code} has an invalid source filename\n"
          unless defined $file && !ref($file) && length($file) && $file !~ /[\0\r\n]/;

        die "diagnostic $diag->{code} repeats source file $file\n" if $seen{$file}++;
    }
}

# Search the catalog's own text without depending on a selected translation.
# Shared or cyclic description structures must not repeat work indefinitely.
sub contains_panic_word {
    my @values = @_;
    my %seen;

    while (@values) {
        my $value = pop @values;
        next unless defined $value;

        my $type = ref($value);
        if ( !$type ) {
            return 1 if $value =~ /(?:\A|[^[:alnum:]])panic(?:[^[:alnum:]]|\z)/i;
            next;
        }

        next if $seen{ refaddr($value) }++;
        push @values, values %$value if $type eq 'HASH';
        push @values, @$value        if $type eq 'ARRAY';
    }

    return 0;
}

# A stored value is an explicit decision. Leave negative autodetection absent
# so a later edit can be detected, and preserve an explicit zero unchanged.
sub normalize_diagnostic_panic {
    my ($diag) = @_;

    if ( exists $diag->{is_panic} ) {
        die "diagnostic $diag->{code} is_panic must be boolean\n"
          unless defined $diag->{is_panic}
          && !ref( $diag->{is_panic} )
          && $diag->{is_panic} =~ /\A[01]\z/;
        return;
    }

    $diag->{is_panic} = 1
      if contains_panic_word( $diag->{code}, macro_name($diag), $diag->{description}, $diag->{message_template}, );
}

# Render-only status follows the delivery API. Keep it separate from the
# subject class so formatting helpers can share the ordinary classification.
sub normalize_diagnostic_render {
    my ($diag) = @_;
    my $is_render = ( $diag->{emit}{api} || '' ) eq 'RENDER' ? 1 : 0;

    if ( exists $diag->{is_render} ) {
        die "diagnostic $diag->{code} is_render must be boolean\n"
          unless defined $diag->{is_render}
          && !ref( $diag->{is_render} )
          && $diag->{is_render} =~ /\A[01]\z/;

        die "diagnostic $diag->{code} is_render disagrees with its delivery API\n"
          if $diag->{is_render} != $is_render;
    }

    $diag->{is_render} = 1 if $is_render;
}

sub diagnostics {
    my ($conf) = @_;
    my $tag_definitions = validate_diagnostic_tag_metadata($conf);
    my $aliases = $conf->{severities};
    die "catalog has no severity aliases\n" unless ref($aliases) eq 'HASH';
    my %letters;
    for my $name ( sort keys %$aliases ) {
        die "invalid severity alias $name\n"
          unless $name =~ /\A[A-Z][A-Z0-9_]+\z/
          && defined $aliases->{$name}
          && $aliases->{$name} =~ /\A[WDSFPXA]\z/;
        die "duplicate severity letter $aliases->{$name}\n" if $letters{ $aliases->{$name} }++;
    }
    die "severity aliases must cover W, D, S, F, P, X and A\n" unless keys(%letters) == 7;
    my $common = $conf->{common} || {};
    die "catalog common definitions must be a hash\n"
      unless ref($common) eq 'HASH';
    for my $name ( sort keys %$common ) {
        my $values = $common->{$name};
        die "common selector values $name has an invalid name\n"
          unless $name =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        die "common selector values $name must be a non-empty array\n"
          unless ref($values) eq 'ARRAY' && @$values;
        my %seen;
        for my $value (@$values) {
            die "common selector values $name has an invalid value\n"
              unless defined $value
              && !ref($value)
              && $value =~ /\A[A-Za-z][A-Za-z0-9_]*\z/
              && $value ne '*';
            die "common selector values $name has a duplicate value $value\n"
              if $seen{$value}++;
        }
    }
    die "catalog has no exception kind registry\n" unless ref( $conf->{exception_kinds} ) eq 'ARRAY';
    my ( %kinds, %kind_numbers );
    check_identity( $_, 'exception kind', \%kinds, \%kind_numbers ) for @{ $conf->{exception_kinds} };
    my $groups = $conf->{diagnostics};
    die "catalog diagnostics must be a severity/kind/code hash\n" unless ref($groups) eq 'HASH';
    my ( @diagnostics, %seen_severity, %codes, %numbers );
    die "catalog retired_numbers is not an array\n"
      if exists $conf->{retired_numbers} && ref( $conf->{retired_numbers} ) ne 'ARRAY';
    my %retired;

    for my $number ( @{ $conf->{retired_numbers} || [] } ) {
        die "invalid retired diagnostic number\n"
          unless defined $number && !ref($number) && $number =~ /\A[0-9]+\z/;
        die "duplicate retired diagnostic number $number\n" if $retired{$number}++;
    }
    my %macros = ( PERL_DIAG_H => 'header guard' );
    for my $severity ( sort keys %$groups ) {
        my $name = severity_name( $conf, $severity );
        die "unknown severity key $severity\n" unless defined $name;
        die "duplicate severity group $name\n" if $seen_severity{$name}++;
        die "diagnostics/$severity is not a hash\n" unless ref( $groups->{$severity} ) eq 'HASH';
        for my $kind ( sort keys %{ $groups->{$severity} } ) {
            my $kinds = $groups->{$severity}{$kind};
            die "diagnostics/$severity/$kind is not a valid kind hash\n"
              unless $kind =~ /\A[A-Z][A-Z0-9_]*\z/ && ref($kinds) eq 'HASH';
            die "diagnostics/$severity/$kind names an unregistered kind\n" unless $kinds{$kind};
            for my $code ( sort keys %$kinds ) {
                my $diag = $kinds->{$code};
                my $path = "diagnostics/$severity/$kind/$code";
                die "$path is not a diagnostic hash\n" unless ref($diag) eq 'HASH';
                normalize_diagnostic_schema($diag);
                die "$path has a mismatched severity\n"
                  unless ( severity_name( $conf, $diag->{severity} ) || '' ) eq $name;
                die "$path has a mismatched kind\n"
                  unless defined $diag->{kind} && $diag->{kind} eq $kind;
                die "$path has a mismatched code\n"
                  unless defined $diag->{code} && $diag->{code} eq $code;
                check_identity( $diag, 'diagnostic', \%codes, \%numbers );
                validate_diagnostic_tags( $diag, $tag_definitions );
                validate_diagnostic_source_files($diag);
                die "$path reuses retired diagnostic number $diag->{number}\n"
                  if $retired{ $diag->{number} };
                die "$path has no emit hash\n" unless ref( $diag->{emit} ) eq 'HASH';
                normalize_diagnostic_panic($diag);
                normalize_diagnostic_render($diag);
                my $parser_api = ( $diag->{emit}{api} || '' ) =~ /\A(?:YYERROR(?:_PV|_PVN)?|DEFER_ERROR)\z/;
                die "$path counts_as_error must be boolean\n"
                  if exists $diag->{counts_as_error}
                  && ( ref( $diag->{counts_as_error} )
                    || $diag->{counts_as_error} !~ /\A[01]\z/ );
                $diag->{counts_as_error} =
                  exists $diag->{counts_as_error} ? 0 + $diag->{counts_as_error}
                  : (
                         $parser_api
                      || ( $diag->{emit}{api} || '' ) eq 'FATAL_WARNER'
                      || ( $diag->{severity} eq 'FATAL_ERROR'
                        && ( $diag->{emit}{api} || 'DIE' ) ne 'APPEND_EXCEPTION' )
                  ) ? 1
                  : 0;

                if ($parser_api) {
                    die "$path needs a parser_action\n"
                      unless defined $diag->{parser_action};
                    die "$path has an invalid parser_action\n"
                      if ref( $diag->{parser_action} )
                      || $diag->{parser_action} !~ /\A(?:collect|recover|abort|caller)\z/;
                    die "$path reserves caller action for dynamic text\n"
                      if $diag->{parser_action} eq 'caller'
                      && ( $diag->{dynamic} || '' ) ne 'text';
                }
                else {
                    die "$path has parser_action without parser delivery\n"
                      if exists $diag->{parser_action};
                }
                die "$path emit.aliases is not an array\n"
                  if exists $diag->{emit}{aliases} && ref( $diag->{emit}{aliases} ) ne 'ARRAY';
                die "$path macro_aliases is not a hash\n"
                  if exists $diag->{macro_aliases} && ref( $diag->{macro_aliases} ) ne 'HASH';
                my %aliases = map { $_ => 1 } @{ $diag->{emit}{aliases} || [] };
                die "$path names an undeclared delivery alias\n"
                  if grep { !$aliases{$_} } keys %{ $diag->{macro_aliases} || {} };
                my @names =
                  ( macro_name($diag), map { alias_macro_name( $diag, $_ ) } @{ $diag->{emit}{aliases} || [] } );
                push @names, $diag->{emit}{accumulate_macro}
                  if $diag->{emit}{accumulate_macro};
                push @names, $diag->{emit}{format_macro} if exists $diag->{emit}{format_macro};

                for my $macro (@names) {
                    die "$path has an invalid macro name\n"
                      unless defined $macro && $macro =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
                    die "duplicate diagnostic macro $macro in $path and $macros{$macro}\n"
                      if exists $macros{$macro};
                    $macros{$macro} = $path;
                }
                push @diagnostics, $diag;
            }
        }
    }
    for my $diag (@diagnostics) {
        next unless exists $diag->{variants};
        my $path = "diagnostic $diag->{code} variants";
        die "$path is not a hash\n" unless ref( $diag->{variants} ) eq 'HASH';
        die "$path needs a fixed message definition\n" if $diag->{dynamic};
        die "$path needs a message parameter list\n" unless ref( $diag->{params} ) eq 'ARRAY';
        my %params = map { $_->{name} => $_ } @{ $diag->{params} };
        my %apis   = map { $_ => 1 } ( $diag->{emit}{api} || 'DIE', @{ $diag->{emit}{aliases} || [] } );
        for my $code ( sort keys %{ $diag->{variants} } ) {
            my $variant = $diag->{variants}{$code};
            my $entry   = "$path/$code";
            die "$entry has an invalid code\n" unless $code =~ /\A[A-Z][A-Z0-9_]*\z/;
            die "duplicate diagnostic code $code\n" if $codes{$code}++;
            die "$entry is not a hash\n" unless ref($variant) eq 'HASH';
            die "$entry has an unknown field\n" if grep { !/\A(?:macro|values|parser_action|emit)\z/ } keys %$variant;
            die "$entry emit must contain only an API\n"
              if exists $variant->{emit}
              && ( ref( $variant->{emit} ) ne 'HASH'
                || grep { $_ ne 'api' } keys %{ $variant->{emit} } );
            my $api = variant_api( $diag, $variant );
            die "$entry names an undeclared delivery API\n"
              unless defined $api && !ref($api) && $apis{$api};

            if ( exists $variant->{parser_action} ) {
                die "$entry has parser_action without parser delivery\n"
                  unless $api =~ /\AYYERROR(?:_PV|_PVN)?\z/;
                die "$entry has an invalid parser_action\n"
                  unless defined $variant->{parser_action}
                  && !ref( $variant->{parser_action} )
                  && $variant->{parser_action} =~ /\A(?:collect|recover|abort)\z/;
                die "$entry needs a collecting parent for parser control\n"
                  unless $diag->{parser_action} eq 'collect';
            }
            my $macro = variant_macro_name( $diag, $code, $variant );
            die "$entry has an invalid macro name\n"
              unless defined $macro && $macro =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
            die "duplicate diagnostic macro $macro in $entry and $macros{$macro}\n"
              if exists $macros{$macro};
            $macros{$macro} = $entry;
            die "$entry has no fixed parameter values or parser action\n"
              unless ref( $variant->{values} ) eq 'HASH'
              && ( keys %{ $variant->{values} } || exists $variant->{parser_action} );
            for my $name ( sort keys %{ $variant->{values} } ) {
                my $param = $params{$name} or die "$entry binds an unknown message parameter $name\n";
                die "$entry can only bind simple text parameters\n"
                  unless ( $param->{type} || '' ) eq 'text'
                  && ( $param->{format_str} || '' ) eq 's'
                  && !grep { exists $param->{$_} } qw(inputs pass prefix literal_fragment);
                my $translations = $variant->{values}{$name};
                die "$entry parameter $name needs an English value\n"
                  unless ref($translations) eq 'HASH' && exists $translations->{en};
                for my $language ( sort keys %$translations ) {
                    my $value = $translations->{$language};
                    die "$entry has an invalid fixed value for $name/$language\n"
                      unless $language =~ /\A[A-Za-z][A-Za-z0-9_-]*\z/
                      && defined $value
                      && !ref($value)
                      && $value !~ /\0/;
                }
            }
        }
    }
    normalize_selector_order(\@diagnostics);
    return \@diagnostics;
}

sub render_catalog {
    my ($conf) = @_;
    require Data::Dumper;
    my $common = $conf->{common} || {};
    my %sorted = ( %$conf, diagnostics => {} );
    $sorted{retired_numbers} = [ sort { $a <=> $b } @{ $conf->{retired_numbers} } ]
      if exists $conf->{retired_numbers};
    for my $diag ( @{ diagnostics($conf) } ) {
        my $severity = severity_name( $conf, $diag->{severity} );
        my $entry    = canonical_diagnostic_schema($diag);
        if ( exists $diag->{variants} ) {
            $entry->{variants} = {
                map {
                    my $variant      = $diag->{variants}{$_};
                    my %copy         = %$variant;
                    my %variant_emit = %{ $copy{emit} || {} };
                    $variant_emit{parser_action} = delete $copy{parser_action}
                      if exists $copy{parser_action};
                    $copy{emit} = \%variant_emit if %variant_emit;
                    $_ => { %copy, macro => variant_macro_name( $diag, $_, $variant ) }
                } keys %{ $diag->{variants} }
            };
        }
        $sorted{diagnostics}{$severity}{ $diag->{kind} }{ $diag->{code} } =
          { %$entry, severity => $severity, macro => macro_name($diag) };
    }
    _upgrade_catalog_text( \%sorted );
    my $source = read_source('diag_conf.pl');
    require Encode;
    $source = Encode::decode( 'UTF-8', $source, Encode::FB_CROAK() | Encode::LEAVE_SRC() );
    my ($preamble) = $source =~ /\A(.*?)^\$META\s/ms;
    my @pod = ( $preamble || '' ) =~ /(^=(?:pod|head\d)\b.*?^=cut[^\n]*\n)/gms;
    my $dumper =
      Data::Dumper->new( [ $common, \%sorted ], [qw(META CONF)] )->Indent(1)->Sortkeys( \&catalog_key_order )->Useqq(1);
    $dumper->Useutf8(1) if $dumper->can('Useutf8');
    my $dump = _readable_catalog_dump( join '', $dumper->Dump );
    my $text =
        "# Declarative diagnostic and documentation catalog.\n"
      . "# Run perl regen/diag.pl after editing this file.\n"
      . "# Regeneration normalizes the data below and preserves this POD.\n\n"
      . "use utf8;\n\n"
      . join( "\n", @pod )
      . ( @pod ? "\n" : '' )
      . $dump;
    return $text;
}

# Both catalogs normalize older Dumper escape spellings before making printable
# Unicode readable. Controls and literal backslashes keep their escaped meaning.
sub _readable_catalog_dump {
    my ($dump) = @_;
    $dump =~ s{(?<!\\)((?:\\\\)*)\\(?:x\{([0-9a-fA-F]+)\}|N\{U\+([0-9a-fA-F]+)\}|([0-7]{1,3}))}
        {(defined($2) || defined($3))
            ? $1 . _unicode_name_escape(hex(defined($2) ? $2 : $3))
            : $1 . sprintf("\\x{%02x}", oct($4))}gex;
    return _literal_catalog_unicode_escapes($dump);
}

sub _literal_catalog_unicode_escapes {
    my ($text) = @_;
    require charnames;
    $text =~ s{(?<!\\)((?:\\\\)*)\\N\{([^{}]+)\}}
        {$1 . _catalog_printable_unicode(charnames::vianame($2), $2)}ge;
    return $text;
}

my $catalog_default_ignorable_re =
  eval 'qr/\A\p{Default_Ignorable_Code_Point}\z/';
my @catalog_default_ignorable_ranges = (
    [0x00AD, 0x00AD], [0x034F, 0x034F], [0x061C, 0x061C], [0x115F, 0x1160],
    [0x17B4, 0x17B5], [0x180B, 0x180F], [0x200B, 0x200F], [0x202A, 0x202E],
    [0x2060, 0x206F], [0x3164, 0x3164], [0xFE00, 0xFE0F], [0xFEFF, 0xFEFF],
    [0xFFA0, 0xFFA0], [0xFFF0, 0xFFF8], [0x1BCA0, 0x1BCA3],
    [0x1D173, 0x1D17A], [0xE0000, 0xE0FFF],
);

sub _catalog_printable_unicode {
    my ($code_point, $name) = @_;
    return sprintf('\\N{%s}', $name)
      unless defined($code_point) && $code_point >= 0x80
          && $code_point <= 0x10FFFF
          && !($code_point >= 0xD800 && $code_point <= 0xDFFF);
    my $char = chr($code_point);
    utf8::upgrade($char);
    return sprintf('\\N{%s}', $name)
      unless $char =~ /\A[\p{L}\p{M}\p{N}\p{P}\p{S}]\z/;
    if ($catalog_default_ignorable_re) {
        return sprintf('\\N{%s}', $name)
          if $char =~ $catalog_default_ignorable_re;
    }
    else {
        for my $range (@catalog_default_ignorable_ranges) {
            return sprintf('\\N{%s}', $name)
              if $code_point >= $range->[0] && $code_point <= $range->[1];
        }
    }
    return $char;
}

sub _unicode_name_escape {
    my ($code_point) = @_;
    return sprintf( '\\N{U+%X}', $code_point ) if $code_point > 0x10FFFF;
    require charnames;
    my $name = charnames::viacode($code_point);
    return defined($name) ? "\\N{$name}" : sprintf( '\\N{U+%X}', $code_point );
}

sub _upgrade_catalog_text {
    my ($value) = @_;
    if ( ref($value) eq 'HASH' ) {
        for my $key ( keys %$value ) {
            $value->{$key} = _upgrade_catalog_text( $value->{$key} );
        }
    }
    elsif ( ref($value) eq 'ARRAY' ) {
        for my $index ( 0 .. $#$value ) {
            $value->[$index] = _upgrade_catalog_text( $value->[$index] );
        }
    }
    elsif ( !ref($value) && defined($value) && $value =~ /[^\x00-\x7f]/ ) {
        utf8::upgrade($value);
    }
    return $value;
}

sub write_catalog {
    my ($conf) = @_;
    my $text = render_catalog($conf);
    require Encode;
    my $bytes = Encode::encode( 'UTF-8', $text,
      Encode::FB_CROAK() | Encode::LEAVE_SRC() );
    open my $out, '>:raw', 'diag_conf.pl' or die "Can't write diag_conf.pl: $!\n";
    print {$out} $bytes;
    close $out or die "Can't close diag_conf.pl: $!\n";
}

sub catalog_key_order {
    my ($hash) = @_;
    my @order =
      exists $hash->{kind} && exists $hash->{code}
      ? qw(number severity kind code macro source_files tags is_panic is_render message operation_words counts_as_error variants compatibility translation_review emit)
      : exists $hash->{values} ? qw(macro values emit)
      : exists $hash->{api}
      ? qw(api args parser_action warning_categories aliases accumulate_macro format_macro format_macro_format format_macro_chunks interpreter_suffix regex_location regex_location_template warn_once)
      : exists $hash->{templates}
      || exists $hash->{args} || exists $hash->{selectors} ? qw(templates args selectors dynamic)
      : exists $hash->{name}
      && ( exists $hash->{values} || exists $hash->{domain} ) ? qw(name source values domain unsorted wide)
      : exists $hash->{api} && exists $hash->{macro} ? qw(api macro)
      : exists $hash->{name} && exists $hash->{type}
      ? qw(name type format_str prefix pass inputs utf8_input literal_fragment role selector_values selector_unsorted selector_assert_unknown internal)
      : ();
    my %rank;
    @rank{@order} = 0 .. $#order;
    return [
        sort {
            ( exists $rank{$a} ? $rank{$a} : scalar @order ) <=> ( exists $rank{$b} ? $rank{$b} : scalar @order )
              || $a cmp $b
        } keys %$hash
    ];
}

sub source_files {
    my ($options) = @_;
    $options ||= {};
    my $manifest = read_source('MANIFEST');
    return grep {
             ( /\.(?:c|cpp|h|xs|y)\z/
            || ( $options->{include_includes} && /\.inc\z/ ) )
          && !/\Aperldiag(?:\.h|_data\.inc|_helpers\.inc|_plural\.inc)\z/
          && (!m!\A(?:ext|dist|cpan|lib|t|os2/OS2)/!
            || m!\Aext/DynaLoader/!
            || ( $options->{include_extensions} && m{\A(?:ext/(?!re/)|os2/OS2/)} ) )
    } map { ( split ' ', $_ )[0] } split /\n/, $manifest;
}

# Map public diagnostic spellings to their catalog owner, including aliases
# and fixed variants. Numeric table offsets are deliberately not recognized.
sub diagnostic_reference_symbols {
    my ($diagnostics) = @_;
    my ( %symbols, %codes );

    for my $diag (@$diagnostics) {
        my $code = $diag->{code};
        $codes{$code} = $code;
        my @names = ( macro_name($diag), map { alias_macro_name( $diag, $_ ) } @{ $diag->{emit}{aliases} || [] } );
        for my $field (qw(accumulate_macro format_macro)) {
            push @names, $diag->{emit}{$field} if defined $diag->{emit}{$field};
        }
        if ( $diag->{emit}{format_macro_chunks} ) {
            my @parts = format_macro_chunks($diag);
            push @names, map { "$diag->{emit}{format_macro}_TEXT_$_" } 0 .. $#parts;
        }
        push @names, map { variant_macro_name( $diag, $_, $diag->{variants}{$_} ) }
          keys %{ $diag->{variants} || {} };
        push @names, map { diagnostic_enum_name( $code, $_ ) } qw(idx number);
        $symbols{$_} = $code for @names;
    }

    return ( \%symbols, \%codes );
}

# Allocation-free writers use these literal pieces as separate macros. Keep
# their numbering shared by the generator and the source-reference inventory.
sub format_macro_chunks {
    my ($diag) = @_;
    die "diagnostic $diag->{code} cannot override a chunked static format\n"
      if defined $diag->{emit}{format_macro_format};

    my $template = $diag->{message_template}{en};
    die "diagnostic $diag->{code} needs one English template for literal chunks\n"
      if ref($template);

    my @parts;
    while ( $template =~ /\G((?:%%|[^%])*?)(?:%\{([A-Za-z_]\w*)\}|\z)/gcs ) {
        push @parts, $1;
        last unless defined $2;
    }
    s/%%/%/g for @parts;
    return @parts;
}

# Retain reference lines for review tools. Source offsets advance monotonically
# so line lookup does not repeatedly count from the beginning of a large file.
sub diagnostic_source_references {
    my ($diagnostics) = @_;
    my ( $symbols, $codes ) = diagnostic_reference_symbols($diagnostics);
    my %references;

    for my $file ( source_files( { include_extensions => 1, include_includes => 1 } ) ) {
        next if $file =~ m{\Aext/XPerl-DiagPack-[^/]+/};
        my $source = mask_noncode( read_source($file) );
        my ( $line, $offset ) = ( 1, 0 );
        # Escaped newlines belong to C literals. Without /s, a continued
        # string can leave the scanner inside a quote for the following code.
        while ( $source =~ /"((?:\\.|[^"\\])*)"|'(?:\\.|[^'\\])*'|\b([A-Za-z_]\w*)\b/gs ) {
            my $start = $-[0];
            my $code  = defined $1 ? $codes->{$1} : $symbols->{ $2 || '' };
            next unless defined $code;
            my $between = substr( $source, $offset, $start - $offset );
            $line += $between =~ tr/\n//;
            $offset = $start;
            $references{$code}{$file}{$line} = 1;
        }
    }

    return \%references;
}

# Catalog lists omit line numbers to avoid churn. References include emitters,
# forwarding APIs, test fixtures and framework comparisons, not just producers.
sub update_diagnostic_source_files {
    my ($diagnostics) = @_;
    my $references = diagnostic_source_references($diagnostics);

    for my $diag (@$diagnostics) {
        $diag->{source_files} = [ sort keys %{ $references->{ $diag->{code} } || {} } ];
    }
}

sub mask_noncode {
    my ($source) = @_;
    $source =~ s{
        ("(?:\\.|[^"\\])*" | '(?:\\.|[^'\\])*')
        | /\*.*?\*/ | //[^\n]*
    }{defined($1) ? $1 : $& =~ s/[^\n]/ /gr}gsex;

    # POD is documentation even when it contains C examples.
    $source =~ s{^=\w.*?^=cut[^\n]*}{ $& =~ s/[^\n]/ /gr }gmse;
    return $source;
}

sub split_args {
    my ($body) = @_;
    return () unless $body =~ /\S/;
    my @args;
    my $start = 0;
    my $depth = 0;
    while ( $body =~ /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[()\[\]{},])/gs ) {
        my $token = $1;
        ++$depth if $token =~ /^[([{]$/;
        --$depth if $token =~ /^[)\]}]$/;
        if ( $token eq ',' && !$depth ) {
            push @args, substr( $body, $start, $-[0] - $start );
            $start = $+[0];
        }
    }
    push @args, substr( $body, $start );
    for (@args) { s/^\s+|\s+$//g }
    return @args;
}

sub call_end {
    my ( $source, $open ) = @_;
    pos($source) = $open + 1;
    my $depth = 1;
    while ( $source =~ /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[()])/gs ) {
        ++$depth     if $1 eq '(';
        --$depth     if $1 eq ')';
        return $+[0] if !$depth;
    }
    return;
}

sub calls {
    my ( $source, $names ) = @_;
    my $masked = mask_noncode($source);
    my @calls;
    while ( $masked =~ /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b($names)\s*\(/gs ) {
        next unless defined $1;
        my ( $name, $start, $open ) = ( $1, $-[0], $+[0] - 1 );
        my $end = call_end( $masked, $open );
        next unless defined $end;
        my $body = substr( $masked, $open + 1, $end - $open - 2 );
        $body =~ s/\\\n//g;
        push @calls,
          {
            name  => $name,
            start => $start,
            end   => $end,
            line  => 1 + ( substr( $source, 0, $start ) =~ tr/\n// ),
            args  => [ split_args($body) ]
          };
        pos($masked) = $end;
    }
    return @calls;
}

sub emitter_names {
    return
qr/(?:Perl_|S_)?(?:croak(?:_nocontext|_sv|_caller)?|die(?:_nocontext|_sv)?|warn(?:_nocontext|_sv)?|(?:ck_)?warner(?:_d|_nocontext)?|fatal_warner|noperl_die|yyerror(?:_pv|_pvn)?|v(?:croak|warn|warner|fatal_warner))|DIE|PERL_DIAG_LEGACY_\w+|PERL_DIAG_DYNAMIC_YYERROR(?:_PV|_PVN)?/;
}

sub api_boundary {
    my ( $file, $call, $source ) = @_;
    my @lines  = split /\n/, $source;
    my $line   = $lines[ $call->{line} - 1 ];
    my $before = substr( $source, 0, $call->{start} );
    $before =~ s/.*\n//s;

    # A corrupt static diagnostic-pack descriptor has no usable pack catalog
    # with which to report its own failure. Keep this emergency path bounded
    # to the single helper and fixed message used for that case.
    if ( $file eq 'pp_ctl.c'
        && $call->{name} eq 'Perl_croak'
        && @{ $call->{args} } == 2
        && $call->{args}[0] =~ /\AaTHX_\s+"invalid diagnostic language pack catalog: %s"\z/
        && $call->{args}[1] eq 'reason' )
    {
        my $prefix = mask_noncode( substr( $source, 0, $call->{start} ) );
        $prefix =~ s/.*^\}//ms;
        return 1
          if $prefix =~ /(?:^|\n)\s*static\s+void\s+Perl_diagpack_invalid_catalog\(pTHX_\s+const char\s*\*\s*reason\)\s*\n\{\s*$/;
    }

    return 1 if $before =~ /^\s*#\s*define\s+\z/;
    return 1
      if $file eq 'util.h'
      && $call->{name} eq 'Perl_croak_nocontext'
      && @{ $call->{args} } == 1
      && $call->{args}[0] eq '__VA_ARGS__'
      && $line =~ /^\s*#\s*define\s+croak\(/;
    return 1
      if $file eq 'util.h'
      && $call->{name} eq 'Perl_die_nocontext'
      && @{ $call->{args} } == 1
      && $call->{args}[0] eq '__VA_ARGS__'
      && $line =~ /^\s*#\s*define\s+die\(/;
    return 1
      if ( $file eq 'util.c' || $file eq 'proto.h' )
      && $call->{name} =~ /^Perl_croak(?:_nocontext)?$/
      && $call->{args}[0] =~ /\A(?:pTHX_\s+)?const char \*pat\z/;
    return 1
      if ( $file eq 'pp_hot.c' || $file eq 'perlio.c' || $file eq 'proto.h' )
      && $call->{name} =~ /^Perl_(?:croak_caller|noperl_die)$/
      && $call->{args}[0] =~ /\Aconst char\s*\*\s*pat\z/;

    if ( $call->{name} =~
        /^Perl_((?:ck_)?warner(?:_d|_nocontext)?|(?:warn|die)(?:_nocontext|_sv)?|croak_sv|fatal_warner)$/ )
    {
        my $backend = $1;
        return 1
          if ( $file eq 'util.c' || $file eq 'proto.h' )
          && $call->{args}[0] =~ /\A(?:pTHX_\s+)?(?:U32\s+err|const char\s*\*\s*pat|SV\s*\*\s*baseex)\z/;
        return 1
          if $file eq 'embed.h'
          && $line =~ /^\s*#\s*define\s+\Q$backend\E\(/
          && join( ',', @{ $call->{args} } ) =~ /\AaTHX_\s+(?:(?:a,)?__VA_ARGS__|a)\z/;
    }
    if ( $call->{name} =~ /^Perl_(yyerror(?:_pv|_pvn)?|v(?:croak|warn|warner|fatal_warner))$/ ) {
        my $backend = $1;
        return 1
          if ( $file eq 'proto.h'
            || ( $backend =~ /^yyerror/ ? $file eq 'toke.c' : $file eq 'util.c' ) )
          && $call->{args}[0] =~
          /\ApTHX_\s+(?:const char\s*\*\s*(?:const\s+)?(?:pat|s)|U32\s+err(?:\s+(?:UNUSED|__attribute__unused__))?)\z/;
        my $count =
            $backend =~ /warner/ || $backend eq 'yyerror_pvn' ? 3
          : $backend eq 'yyerror'                             ? 1
          :                                                     2;
        my $forward = 'aTHX_ ' . join( ',', ( 'a', 'b', 'c' )[ 0 .. $count - 1 ] );
        return 1
          if $file eq 'embed.h'
          && $line =~ /^\s*#\s*define\s+\Q$backend\E\(/
          && join( ',', @{ $call->{args} } ) eq $forward;
    }

    # These public API implementations forward an external format and va_list.
    # Restrict the boundary by file, enclosing function, and exact inputs.
    if ( ( $file eq 'util.c' || $file eq 'pp_hot.c' )
        && $call->{name} =~ /\Av(?:croak|warn|warner|fatal_warner)\z/ )
    {
        my $prefix = mask_noncode( substr( $source, 0, $call->{start} ) );
        $prefix =~ s/.*^\}//ms;
        my ($owner) = $prefix =~ /^Perl_(\w+)\([^\n]*\)\n\{/m;
        my $inputs  = join( ',', @{ $call->{args} } );
        return 1
          if defined $owner
          && $call->{name} eq 'vcroak'
          && $inputs eq 'pat,&args'
          && ( ( $file eq 'util.c' && $owner =~ /\A(?:croak|die)(?:_nocontext)?\z/ )
            || ( $file eq 'pp_hot.c' && $owner eq 'croak_caller' ) );
        return 1
          if $file eq 'util.c'
          && defined $owner
          && (
            ( $call->{name} eq 'vwarn' && $inputs eq 'pat,&args' && $owner =~ /\Awarn(?:_nocontext)?\z/ )
            || (   $call->{name} eq 'vwarner'
                && $inputs eq 'err,pat,&args'
                && $owner =~ /\A(?:warner(?:_nocontext)?|ck_warner(?:_d)?)\z/ )
            || (
                $owner eq 'vwarner'
                && (   ( $call->{name} eq 'vwarn' && $inputs eq 'pat,args' )
                    || ( $call->{name} eq 'vfatal_warner' && $inputs eq 'err,pat,args' ) )
            )
            || (   $owner eq 'fatal_warner'
                && $call->{name} eq 'vfatal_warner'
                && $inputs eq 'err,pat,&args' )
          );
    }
    return 0;
}

sub decode_literal {
    my ($literal) = @_;
    my %escape = (
        n    => "\n",
        r    => "\r",
        t    => "\t",
        a    => "\a",
        b    => "\b",
        f    => "\f",
        v    => chr(11),
        '\\' => '\\',
        '"'  => '"',
        "'"  => "'",
        '?'  => '?'
    );
    my $invalid;
    $literal =~ s/\\(.)/exists $escape{$1} ? $escape{$1} : do { $invalid = 1; '' }/gse;
    return if $invalid;
    return $literal;
}

sub format_macros {

    # perl.h and the configuration header define Perl's format fragments.
    my %macros;
    for my $file ( 'perl.h', 'config_h.SH' ) {
        my $source = read_source($file);
        while ( $source =~ /^\s*#\s*define\s+(\w+f(?:\d+|_QUOTEDPREFIX|_DEFAULT)?)\s+/gm ) {
            $macros{$1} = 1;
        }
    }
    return \%macros;
}

sub format_constants {
    my $source = mask_noncode( read_source('perl.h') );
    my %constants;
    while ( $source =~ /\bEXTCONST\s+char\s+(PL_\w+)\[\][^;{]*?\bINIT\s*\(/g ) {
        my ( $name, $open ) = ( $1, $+[0] - 1 );
        my $end = call_end( $source, $open );
        next unless defined $end;
        $constants{$name} = substr( $source, $open + 1, $end - $open - 2 );
        pos($source) = $end;
    }
    return \%constants;
}

sub resolve_format {
    my ( $expression, $constants ) = @_;
    $expression =~ s/^\s*aTHX_\s*//;
    return exists $constants->{$expression} ? $constants->{$expression} : $expression;
}

sub type_for {
    my ($formatter) = @_;
    return 'text' if $formatter =~ /^(?:SV|HEK|HvNAME|UTF8|PN|PV)f/;
    return 'uv'   if $formatter =~ /^(?:UV|U32)/;
    return 'nv'   if $formatter =~ /^NV/;
    return 'iv'   if $formatter =~ /^(?:IV|LINE_T)/;
    return 'uv'   if $formatter =~ /[ouxX]$/;
    return 'nv'   if $formatter =~ /[fFeEgGaA]$/;
    return 'iv'   if $formatter =~ /[di]$/;
    return 'char' if $formatter =~ /c$/;
    return 'ptr'  if $formatter =~ /p$/;
    return 'text';
}

sub parse_format {
    my ( $expr, $values, $macros ) = @_;
    $expr =~ s/\\\n//g;
    my $interpreter_suffix;
    if ( $expr =~ s/\s+pTHX__FORMAT(\s+pTHX__VALUE)?\s*\z// ) {
        $interpreter_suffix = 1;
        my $value_in_format = defined $1;
        $values = [@$values];
        return
          unless $value_in_format
          || ( @$values && $values->[-1] =~ s/\s+pTHX__VALUE\s*\z// );
    }
    my $format = '';
    pos($expr) = 0;
    while ( $expr =~ /\G\s*(?:"((?:\\.|[^"\\])*)"|([A-Za-z_]\w*))\s*/gc ) {
        if ( defined $1 ) {
            my $literal = decode_literal($1);
            return unless defined $literal;
            $format .= $literal;
        }
        else {
            return unless $macros->{$2};
            $format .= "\x01$2\x02";
        }
    }
    return unless defined( pos($expr) ) && pos($expr) == length($expr);
    my ( $result, @spec, @call_values );
    $result = '';
    my $value_index = 0;
    pos($format) = 0;
    while ( pos($format) < length($format) ) {
        if ( $format =~ /\G([^%\x01]+)/gc ) { $result .= $1;   next }
        if ( $format =~ /\G%%/gc )          { $result .= '%%'; next }
        return
          unless $format =~
          /\G%([+#0 -]*(?:\*|\d+)?(?:\.(?:\*|\d+))?)(?:(hh|h|ll|l|j|z|t|L)?([diouxXcspfFeEgGaA])|\x01(\w+)\x02)/gc;
        my ( $prefix, $length, $letter, $symbol ) = ( $1, $2, $3, $4 );
        my $formatter = defined($symbol) ? $symbol : $prefix . ( $length || '' ) . $letter;
        my $name      = 'arg' . ( 1 + @spec );
        my $spec      = { name => $name, type => type_for($formatter), format_str => $formatter };
        $spec->{prefix} = $prefix if defined($symbol) && length($prefix);
        my $value = $values->[ $value_index++ ];
        return unless defined $value;

        if ( defined($symbol) && $symbol =~ /^UTF8f/ ) {
            return unless $value =~ /^UTF8fARG\((.*)\)$/s;
            my @inputs = split_args($1);
            return unless @inputs == 3;
            $spec->{pass}   = 'UTF8fARG';
            $spec->{inputs} = [
                { name => "${name}_utf8",   type => 'iv' },
                { name => "${name}_length", type => 'uv' },
                { name => "${name}_text",   type => 'text' },
            ];
            push @call_values, @inputs;
        }
        elsif ( !defined($symbol) && $prefix =~ /\*/ ) {
            my $stars  = $prefix =~ tr/*//;
            my @inputs = ($value);
            for ( 1 .. $stars ) {
                return unless defined $values->[$value_index];
                push @inputs, $values->[ $value_index++ ];
            }
            $spec->{inputs} = [
                ( map { { name => "${name}_size$_", type => 'iv' } } 1 .. $stars ),
                { name => "${name}_value", type => $spec->{type} },
            ];
            push @call_values, @inputs;
        }
        else {
            if ( defined($symbol) && $value =~ /^(SVfARG|HEKfARG|HvNAMEfARG|PNfARG)\((.*)\)$/s ) {
                my ( $pass, $inner ) = ( $1, $2 );
                my @inner = split_args($inner);
                return unless @inner == 1;
                $spec->{pass} = $pass;
                $value = $inner[0];
            }
            push @call_values, $value;
        }
        push @spec, $spec;
        $result .= "%{$name}";
    }
    return unless $value_index == @$values;
    return {
        message_template => { en => $result },
        params           => \@spec,
        values           => \@call_values,
        emit             => { ( $interpreter_suffix ? ( interpreter_suffix => 1 ) : () ) }
    };
}

sub signature {
    my ($diag) = @_;
    return unless ref( $diag->{message_template} ) eq 'HASH' && defined $diag->{message_template}{en};
    my @delivery = grep { ( $_->{role} || '' ) ne 'regex_location' } @{ $diag->{emit}{params} || [] };
    return
      if @delivery
      && !( is_warning_emitter( $diag->{emit}{api} ) && @delivery == 1 && $delivery[0]{type} eq 'uv' );
    my $format = $diag->{message_template}{en};
    my %indices;
    my @spec = @{ $diag->{params} };
    for my $i ( 0 .. $#spec ) { $indices{ $spec[$i]{name} } = $i }
    $format =~ s/%%|%\{(\w+)\}/defined($1) ? '%{' . $indices{$1} . '}' : '%%'/ge;
    return join "\0", uc( $diag->{emit}{api} || 'DIE' ),
      join( ',', @{ $diag->{warning_categories} || [] } ),
      ( @delivery ? 'runtime-category' : '' ), ( $diag->{emit}{regex_location} || '' ),
      ( $diag->{emit}{warn_once} || '' ), $format, map {
        join ':', $_->{format_str} || 's', $_->{prefix} || '', $_->{pass} || '',
          $_->{type}, ( $_->{literal_fragment} || '' ), ( $_->{utf8_input} || '' ),
          map { $_->{type} }
          @{ $_->{inputs} || [] }
      } @spec, ( $diag->{emit}{interpreter_suffix} ? { format_str => 'pTHX__FORMAT', type => 'ptr' } : () );
}

sub local_format_constants {
    my ($source) = @_;
    my %constants;
    my $masked = mask_noncode($source);
    while (
        $masked =~ /\b(?:static\s+)?const\s+char\s+(\w+)\s*\[\s*\]\s*=\s*((?:"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|\s)+);/g )
    {
        $constants{$1} = $2;
    }
    return \%constants;
}

sub is_warning_emitter {
    return defined( $_[0] )
      && $_[0] =~ /\A(?:FATAL_WARNER|CK_WARNER(?:_D)?(?:_CONTEXT)?|WARNER(?:_(?:CONTEXT|NOCONTEXT))?)\z/;
}

sub warning_categories {
    my ($expression) = @_;
    return unless $expression =~ /\ApackWARN([234]?)\(\s*(WARN_\w+(?:\s*,\s*WARN_\w+)*)\s*\)\z/;
    my ( $count, $list ) = ( $1 || 1, $2 );
    my @categories = split /\s*,\s*/, $list;
    return unless @categories == $count;
    return \@categories;
}

sub format_error {
    my ($diag) = @_;
    return 'obsolete template field'
      if exists $diag->{template} || exists $diag->{format};
    return 'dynamic boundary has a fixed message template'
      if $diag->{dynamic} && exists $diag->{message_template};
    return if $diag->{dynamic};
    my $templates = $diag->{message_template};
    return 'missing English message template'
      unless ref($templates) eq 'HASH' && exists $templates->{en};
    for my $param ( @{ $diag->{params} } ) {
        my $type   = $param->{type}       || '';
        my $format = $param->{format_str} || '';
        my %compatible_types;

        if (   $format =~ /\A(?:SVf|UTF8f|HEKf|HvNAMEf|PNf|PVf)/
            || $format =~ /\A(?:s|\.\*s|\*s|\*\.\*s|\.1s|%)/ )
        {
            %compatible_types = ( text => 1 );
        }
        elsif ( $format eq 'c' ) {
            %compatible_types = ( char => 1, iv => 1 );
        }
        elsif ( $format =~ /\A(?:d|i|ld|li|zd|td|jd|IVdf|I32df)\z/ ) {
            %compatible_types = ( iv => 1 );
        }
        elsif ( $format eq 'LINE_Tf' ) {
            %compatible_types = ( iv => 1, uv => 1 );
        }
        elsif ( $format =~ /\A(?:u|x|o|02x|02X|#o|lu|lx|#lx|zu|UVuf|UVxf|UVXf|U32uf|U32xf)\z/ ) {
            %compatible_types = ( uv => 1 );
        }
        elsif ($format =~ /\ANV(?:e|f|g)f\z/
            || $format eq 'VCATPVFN_FV_GF' )
        {
            %compatible_types = ( nv => 1 );
        }
        elsif ( $format eq 'p' ) {
            %compatible_types = ( ptr => 1 );
        }

        return "parameter $param->{name} uses formatter $format with incompatible type $type"
          if %compatible_types && !$compatible_types{$type};
    }
    return 'message_selectors must be an array'
      if exists $diag->{message_selectors}
      && ref( $diag->{message_selectors} ) ne 'ARRAY';
    my %all_params = map { $_->{name} => 1 } @{ $diag->{params} };
    return 'duplicate message parameter'
      if keys(%all_params) != @{ $diag->{params} };
    my %selector_values;
    my %selector_definitions = map { $_->{name} => $_ } @{ $diag->{selector_definitions} || [] };
    my @selectors            = @{ $diag->{message_selectors} || [] };
    for my $name (@selectors) {
        return 'invalid message selector name'
          unless defined $name
          && !ref($name)
          && $name =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        return 'duplicate message selector'
          if exists $selector_values{$name};
        my $definition = $selector_definitions{$name} || {};
        my $source     = $definition->{source}        || $name;
        return "message selector $name has an invalid wide flag"
          if exists( $definition->{wide} )
          && (!defined( $definition->{wide} )
            || ref( $definition->{wide} )
            || $definition->{wide} ne '1' );
        return "wide selector $name cannot be plural"
          if $definition->{wide} && exists $definition->{plural};
        return "message selector $name has no source parameter"
          unless $all_params{$source};
        my ($param) = grep { $_->{name} eq $source } @{ $diag->{params} };

        if ( $definition->{operation_word} ) {
            $selector_values{$name} = 1;
            next;
        }
        if ( exists $definition->{plural} ) {
            return "message selector $name has invalid plural kind"
              unless defined $definition->{plural}
              && !ref( $definition->{plural} )
              && $definition->{plural} =~ /\A(?:cardinal|ordinal)\z/;
            return "plural selector $name must use a simple unsigned integer parameter"
              unless $param->{type} eq 'uv'
              && ( $param->{format_str} || '' ) eq 'UVuf'
              && !grep { exists $param->{$_} } qw(inputs pass prefix literal_fragment role);
            $selector_values{$name} = 1;
            next;
        }
        return "message selector $name must be a simple text parameter"
          unless ( $param->{type} || '' ) eq 'text'
          && ( $param->{format_str} || '' ) eq 's'
          && !grep { exists $param->{$_} } qw(inputs pass prefix literal_fragment role);
        $selector_values{$name} = 1;
    }
    my @wide_selectors = grep { $selector_definitions{$_}{wide} } @selectors;
    return 'a diagnostic can have at most one wide selector' if @wide_selectors > 1;
    return 'a diagnostic can have at most seven selectors'   if @selectors > 7;
    return 'a wide selector requires at most six narrow selectors'
      if @wide_selectors && @selectors - @wide_selectors > 6;
    for my $column ( 0 .. $#selectors ) {
        my $definition = $selector_definitions{ $selectors[$column] } || {};
        next if exists $definition->{plural};
        my $limit  = $definition->{wide} ? 65535 : 255;
        my $values = selector_column_values( $diag, $column );
        return "selector $selectors[$column] has more than $limit values"
          if @$values > $limit;
    }
    for my $param ( @{ $diag->{params} } ) {
        return "parameter $param->{name} has selector_values but is not a selector"
          if exists $param->{selector_values}
          && !grep {
            my $definition = $selector_definitions{$_} || {};
            ( $definition->{source} || $_ ) eq $param->{name}
          } @selectors;
    }
    my %params = map { $_->{name} => 1 }
      grep { !$_->{internal} } @{ $diag->{params} };
    my ( %used_in_any_language, %used_by_language );
    for my $language ( sort keys %$templates ) {
        my $cases = eval { template_cases( $diag, $language ) };
        return "invalid message template for $language: $@" if $@;
        return "invalid message template for $language"
          unless @$cases || $language ne 'en';
        if ( $language eq 'en' ) {
            my $covered = eval { validate_template_coverage( $diag, $cases ); 1 };
            return "invalid message template for $language: $@" unless $covered;
        }
        my %used_params;
        for my $case (@$cases) {
            my $template = $case->{template};
            my %seen;
            $template =~ s{%%|%\{([A-Za-z_]\w*)\}}{defined($1) ? do { $seen{$1}++; '' } : ''}ge;
            return 'unmanaged printf conversion' if $template =~ /%/;
            return "unknown message parameter in $language" if grep { !$params{$_} } keys %seen;
            $used_params{$_} = 1 for keys %seen;
        }
        $used_in_any_language{$_}    = 1 for keys %used_params;
        $used_by_language{$language} = \%used_params;
    }
    return;
}

# Return the legacy flattened display parameter order used by old flat APIs.
# Capture generation must use template_parameter_layout instead.
# Callers compiling the catalog can supply its already flattened cases.
sub template_parameter_union {
    my ( $diag, $cases_by_language ) = @_;
    my %used;

    for my $language ( sort keys %{ $diag->{message_template} || {} } ) {
        my $cases =
            $cases_by_language
          ? $cases_by_language->{$language}
          : template_cases( $diag, $language );
        for my $case (@$cases) {
            my $template = $case->{template};
            $template =~ s{%%|%\{([A-Za-z_]\w*)\}}
                {defined($1) ? do { $used{$1} = 1; '' } : ''}ge;
        }
    }

    return [ grep { $used{ $_->{name} } && !$_->{internal} } @{ $diag->{params} || [] } ];
}

# Capture arguments in their declared order.  Translation templates are
# projected onto this canonical list separately, one case at a time.
sub template_parameter_layout {
    my ($diag) = @_;
    my @selectors = @{ $diag->{message_selectors} || [] };
    my ( %canonical_indices, %selector_indices );
    my %selector_definitions = map { $_->{name} => $_ } @{ $diag->{selector_definitions} || [] };

    my @captured_params = @{ $diag->{params} || [] };
    die "diagnostic $diag->{code} has more than 255 declared parameters\n"
      if @captured_params > 255;
    @canonical_indices{ map { $_->{name} } @captured_params } = 0 .. $#captured_params;

    for my $name (@selectors) {
        my $source = $selector_definitions{$name}{source} || $name;
        die "selector $name has no stored parameter $source\n"
          unless exists $canonical_indices{$source};
        $selector_indices{$name} = $canonical_indices{$source};
    }

    return {
        canonical_params   => \@captured_params,
        captured_params    => \@captured_params,
        canonical_indices  => \%canonical_indices,
        diagnostic_indices => \%canonical_indices,
        selector_indices   => \%selector_indices,
        has_param_values   => scalar @captured_params,
        stored_count       => scalar @captured_params,
    };
}

# Return the dense display arguments and their canonical source indices for
# one translated case.  Sorting by source index makes equivalent placeholder
# sets share both a positional format and a projection map.
sub template_case_parameter_layout {
    my ( $diag, $template ) = @_;
    my %canonical = map { $_->{name} => $_ } @{ $diag->{params} || [] };
    my %used;
    $template =~ s{%%|%\{([A-Za-z_]\w*)\}}{
        if (defined $1) {
            die "diagnostic $diag->{code} template references unknown parameter $1\n"
              unless exists $canonical{$1};
            $used{$1} = 1;
        }
        ''
    }ge;
    my @parameters = grep { $used{ $_->{name} } } @{ $diag->{params} || [] };
    my @indices = map { $_ } 0 .. $#{ $diag->{params} || [] };
    my %indices = map { $diag->{params}[$_]{name} => $_ } @indices;
    return ( \@parameters, [ map { $indices{ $_->{name} } } @parameters ] );
}

# Flatten and check template branches without expanding the selector product.
# Parameter discovery and output generation call this repeatedly. Coverage is
# checked separately during schema validation, before any output is published.
sub template_cases {
    my ( $diag, $language ) = @_;
    my $template  = normalize_template_wildcards( $diag->{message_template}{$language} );
    my @selectors = @{ $diag->{message_selectors} || [] };
    return [] unless defined $template;
    if ( !@selectors ) {
        die "template must be a string\n" if ref($template);
        return [ { selectors => [], template => $template } ];
    }

    my @cases;
    my $walk;
    $walk = sub {
        my ( $node, $depth, $path ) = @_;
        if ( !ref($node) ) {
            die "template leaf must be a string\n" unless defined $node;
            my @path = ( @$path, ('*') x ( @selectors - @$path ) );
            push @cases, { selectors => \@path, template => $node };
            return;
        }
        die "template branch must be a hash\n" unless ref($node) eq 'HASH';
        die "template branch extends beyond selector list\n"
          if $depth >= @selectors;
        my %allowed = map { $_ => 1 } @{ selector_values_for( $diag, $depth, $path ) };
        for my $key ( sort keys %$node ) {
            die "unknown selector value '$key' at depth $depth\n"
              unless $key eq '*' || $allowed{$key};
            $walk->( $node->{$key}, $depth + 1, [ @$path, $key ] );
        }
    };
    $walk->( $template, 0, [] );

    return \@cases;
}

# English must cover the complete selector domain. Other languages may leave
# cases untranslated and use the English fallback. Keep this exhaustive check
# out of template and parameter discovery, which do not select a template.
sub validate_template_coverage {
    my ( $diag, $cases ) = @_;
    my $combinations = selector_combinations($diag);

    # Coverage needs any match, not the winning template. Broad wildcard
    # cases cover most combinations without searching all exact cases first.
    my $ordered_cases = [ reverse ordered_selector_cases( $diag, $cases ) ];
    for my $combination (@$combinations) {
        my $best = _matching_template_case( $diag, $cases, $combination, $ordered_cases );
        die "no template for selector combination\n" unless $best;
    }
    return;
}

# Select the most specific template that matches one selector combination.
sub _matching_template_case {
    my ( $diag, $cases, $combination, $ordered_cases ) = @_;

    $ordered_cases ||= [ ordered_selector_cases( $diag, $cases ) ];
    for my $case (@$ordered_cases) {
        my $matches = 1;
        for my $i ( 0 .. $#$combination ) {
            my $selector = $case->{selectors}[$i];
            if ( !defined $selector ) {
                $matches = 0;
                last;
            }
            next if $selector eq '*';
            if ( $selector ne $combination->[$i] ) {
                $matches = 0;
                last;
            }
        }
        return $case if $matches;
    }

    return;
}

# Build translator-friendly rows, using English where the requested language
# has no template for a diagnostic.
sub translation_table_rows {
    my ( $diagnostics, $language ) = @_;
    my @rows;

    for my $diag ( sort { $a->{number} <=> $b->{number} } @$diagnostics ) {
        my $templates = $diag->{message_template} || {};
        next unless exists $templates->{en};

        my $english_cases = template_cases( $diag, 'en' );
        my $language_cases =
          $language eq 'en' ? $english_cases
          : !exists $templates->{$language} ? []
          : template_cases( $diag, $language );
        my $english_ordered_cases =
          [ ordered_selector_cases( $diag, $english_cases ) ];
        my $language_ordered_cases = $language eq 'en'
          ? $english_ordered_cases
          : [ ordered_selector_cases( $diag, $language_cases ) ];
        my $selectors     = $diag->{message_selectors} || [];
        my $combinations  = selector_combinations($diag);

        for my $combination (@$combinations) {
            my $source_case = _matching_template_case( $diag, $english_cases,
                $combination, $english_ordered_cases );
            my $target_case = _matching_template_case( $diag, $language_cases,
                $combination, $language_ordered_cases );
            my $translated  = $language eq 'en' || defined $target_case;
            my $selected    = $translated ? $target_case : $source_case;
            my %row = (
                number      => 0 + $diag->{number},
                code        => $diag->{code},
                source      => $source_case->{template},
                translation => $selected->{template},
                language    => $translated ? $language : 'en',
                translated  => $translated ? 1 : 0,
            );
            $row{selectors} = {
                map { $selectors->[$_] => $combination->[$_] }
                  0 .. $#$selectors
            } if @$selectors;
            push @rows, \%row;
        }
    }

    return \@rows;
}

# Preserve an existing wildcard template while adding a more specific case.
sub _template_default_tree {
    my ( $template, $levels ) = @_;

    for ( 1 .. $levels ) {
        $template = { '*' => $template };
    }

    return $template;
}

# Install one translated leaf without discarding broader existing cases.
sub _set_translation_case {
    my ( $template_ref, $selectors, $values, $depth, $translation ) = @_;

    if ( !defined $$template_ref ) {
        $$template_ref = {};
    }
    elsif ( !ref($$template_ref) ) {
        $$template_ref = _template_default_tree( $$template_ref, scalar(@$selectors) - $depth );
    }
    $$template_ref ||= {};
    die "translation selector branch must be a hash\n"
      unless ref($$template_ref) eq 'HASH';

    my $selector_value = $values->[$depth];
    $selector_value = '*' if $selector_value eq 'any';
    if ( $depth == $#$selectors ) {
        if ( $selector_value eq '*' && ref( $$template_ref->{$selector_value} ) eq 'HASH' ) {
            my $branch = $$template_ref->{$selector_value};
            return 0
              if defined( $branch->{'*'} )
              && !ref( $branch->{'*'} )
              && $branch->{'*'} eq $translation;
            $branch->{'*'} = $translation;
            return 1;
        }
        return 0
          if defined( $$template_ref->{$selector_value} )
          && !ref( $$template_ref->{$selector_value} )
          && $$template_ref->{$selector_value} eq $translation;
        $$template_ref->{$selector_value} = $translation;
        return 1;
    }

    my $child     = $$template_ref->{$selector_value};
    my $child_ref = \$child;
    my $changed   = _set_translation_case( $child_ref, $selectors, $values, $depth + 1, $translation );
    $$template_ref->{$selector_value} = $child;

    return $changed;
}

# Check translated coverage locally without expanding domains in model prompts.
sub translation_is_complete {
    my ( $diag, $language ) = @_;
    my $cases = template_cases( $diag, $language );
    return 0 unless @$cases;
    my $ordered_cases = [ ordered_selector_cases( $diag, $cases ) ];
    for my $combination ( @{ selector_combinations($diag) } ) {
        return 0 unless _matching_template_case( $diag, $cases, $combination,
            $ordered_cases );
    }
    return 1;
}

# Install complete language-specific case sets after validating every update.
# Unlike worksheet rows, these cases need not follow the English selector tree.
sub apply_translation_sets {
    my ( $diagnostics, $document ) = @_;
    require JSON::PP;
    my $json     = JSON::PP->new->canonical;
    my $language = $document->{target_language};
    die "translation sets have an invalid target language\n"
      unless defined $language
      && !ref($language)
      && $language =~ /\A[A-Za-z][A-Za-z0-9_-]*\z/
      && $language ne 'en';
    die "translation sets must be an array\n"
      unless ref( $document->{template_sets} ) eq 'ARRAY';

    my %by_code = map { $_->{code} => $_ } @$diagnostics;
    my ( %seen, @updates );
    for my $entry ( @{ $document->{template_sets} } ) {
        die "invalid translation set\n" unless ref($entry) eq 'HASH';
        my $code = $entry->{code};
        die "invalid translation set code\n" unless defined $code && !ref($code);
        my $diag = $by_code{$code} or die "unknown translation diagnostic $code\n";
        die "duplicate translation set $code\n" if $seen{$code}++;
        die "translation number does not match $code\n"
          unless defined $entry->{number}
          && !ref( $entry->{number} )
          && $entry->{number} =~ /\A[0-9]+\z/
          && $entry->{number} == $diag->{number};
        die "English source changed for $code\n"
          unless $json->encode( $entry->{source_cases} ) eq $json->encode( template_cases( $diag, 'en' ) );
        die "translation cases must be a nonempty array for $code\n"
          unless ref( $entry->{cases} ) eq 'ARRAY' && @{ $entry->{cases} };

        my @selectors = @{ $diag->{message_selectors} || [] };
        my ( $tree, %patterns );
        for my $case ( @{ $entry->{cases} } ) {
            die "invalid translation case for $code\n"
              unless ref($case) eq 'HASH'
              && ref( $case->{selectors} ) eq 'ARRAY'
              && !grep { !defined($_) || ref($_) } @{ $case->{selectors} };
            die "invalid translation selector count for $code: expected "
              . scalar(@selectors) . ", got " . scalar( @{ $case->{selectors} } ) . "\n"
              unless @{ $case->{selectors} } == @selectors;
            die "invalid translation text for $code\n"
              unless defined $case->{template} && !ref( $case->{template} );
            my @pattern = map { $_ eq 'any' ? '*' : $_ } @{ $case->{selectors} };
            my $key     = $json->encode( \@pattern );
            die "duplicate translation selector case for $code\n" if $patterns{$key}++;
            if (@selectors) {
                _set_translation_case( \$tree, \@selectors, \@pattern, 0, $case->{template} );
            }
            else {
                $tree = $case->{template};
            }
        }

        my %candidate = ( %$diag, message_template => { %{ $diag->{message_template} }, $language => $tree } );
        my $error     = format_error( \%candidate );
        die "invalid translation for $code: $error\n" if defined $error;
        push @updates, [ $diag, $tree ];
    }

    $_->[0]{message_template}{$language} = $_->[1] for @updates;
    return scalar @updates;
}

# Apply edited worksheet rows to the matching diagnostic language templates.
sub apply_translation_table {
    my ( $diagnostics, $document ) = @_;

    die "translation worksheet must be a hash\n"
      unless ref($document) eq 'HASH';
    return apply_translation_sets( $diagnostics, $document )
      if exists $document->{template_sets};
    my $language = $document->{target_language};
    die "translation worksheet has an invalid target language\n"
      unless defined $language
      && !ref($language)
      && $language =~ /\A[A-Za-z][A-Za-z0-9_-]*\z/
      && $language ne 'en';
    die "translation worksheet entries must be an array\n"
      unless ref( $document->{entries} ) eq 'ARRAY';

    my %by_code = map { $_->{code} => $_ } @$diagnostics;
    my ( @updates, %seen, %legacy_rows );
    for my $entry ( @{ $document->{entries} } ) {
        die "translation worksheet entry must be a hash\n"
          unless ref($entry) eq 'HASH';
        my ( $code, $number, $source, $translation ) =
          @{$entry}{qw(code number source translation)};
        die "translation worksheet entry has invalid identity or text\n"
          unless defined $code
          && !ref($code)
          && defined $number
          && !ref($number)
          && $number =~ /\A[0-9]+\z/
          && defined $source
          && !ref($source)
          && defined $translation
          && !ref($translation);
        my $diag = $by_code{$code}
          or die "translation worksheet refers to unknown diagnostic $code\n";
        die "translation worksheet number does not match $code\n"
          unless $diag->{number} == $number;

        my @selectors     = @{ $diag->{message_selectors} || [] };
        my $english_cases = template_cases( $diag, 'en' );
        my @source_cases  = grep { $_->{template} eq $source } @$english_cases;
        die "translation worksheet source does not match $code\n"
          unless @source_cases;

        my @patterns;
        if ( exists $entry->{selectors} ) {
            my $selector_values = $entry->{selectors};
            die "translation worksheet selectors must be a hash\n"
              unless ref($selector_values) eq 'HASH';
            die "translation worksheet selector list does not match $code\n"
              unless keys(%$selector_values) == @selectors
              && !grep { !exists $selector_values->{$_} } @selectors;
            my @values = map { $selector_values->{$_} } @selectors;
            die "translation worksheet has an invalid selector value for $code\n"
              if grep { !defined($_) || ref($_) } @values;
            my $english_case = _matching_template_case( $diag, $english_cases, \@values );
            die "translation worksheet source does not match selector case for $code\n"
              unless $english_case && $english_case->{template} eq $source;
            push @patterns, \@values;
        }
        else {
            my $row_identity = join "\x1E", $code, $source;
            if ( exists $legacy_rows{$row_identity} ) {
                die "conflicting duplicate translation worksheet row for $code\n"
                  if $legacy_rows{$row_identity} ne $translation;
                next;
            }
            $legacy_rows{$row_identity} = $translation;
            @patterns = map { $_->{selectors} } @source_cases;
        }

        for my $pattern (@patterns) {
            my $identity = join "\x1E", $code, @$pattern;
            die "duplicate translation worksheet row for $code\n"
              if $seen{$identity}++;
            push @updates, [ $diag, \@selectors, $pattern, $translation ];
        }
    }

    my $applied = 0;
    for my $update (@updates) {
        my ( $diag, $selectors, $pattern, $translation ) = @$update;
        if ( !@$selectors ) {
            next
              if defined( $diag->{message_template}{$language} )
              && !ref( $diag->{message_template}{$language} )
              && $diag->{message_template}{$language} eq $translation;
            $diag->{message_template}{$language} = $translation;
            $applied++;
            next;
        }
        my $template_ref = \$diag->{message_template}{$language};
        $applied += _set_translation_case( $template_ref, $selectors, $pattern, 0, $translation );
    }

    return $applied;
}

# Build a plural domain without expanding selector products. Passing a
# language limits exact numbers to that language's template branches.
sub plural_exact_values {
    my ( $diag, $depth, $language ) = @_;
    my %values;
    my $walk;
    $walk = sub {
        my ( $node, $level ) = @_;
        return unless ref($node) eq 'HASH';
        if ( $level == $depth ) {
            $values{$_} = 1 for grep { /\A(?:0|[1-9][0-9]*)\z/ } keys %$node;
            return;
        }
        $walk->( $_, $level + 1 ) for values %$node;
    };
    my $templates = $diag->{message_template} || {};
    $walk->( $templates->{$_}, 0 ) for defined($language) ? ($language) : keys %$templates;
    return [ sort { length($a) <=> length($b) || $a cmp $b } keys %values ];
}

sub plural_selector_values {
    my ( $diag, $depth, $language ) = @_;
    return [ qw(zero one two few many other), @{ plural_exact_values( $diag, $depth, $language ) } ];
}

sub selector_values_for {
    my ( $diag, $depth, $path, $language ) = @_;
    my $name = $diag->{message_selectors}[$depth];
    my ($definition) = grep { $_->{name} eq $name } @{ $diag->{selector_definitions} || [] };
    return plural_selector_values( $diag, $depth, $language ) if $definition && $definition->{plural};
    my ($param) = grep { $_->{name} eq $name } @{ $diag->{params} || [] };
    my $values =
        $definition && $definition->{values}
      ? $definition->{values}
      : $param && $param->{selector_values};
    for my $previous (@$path) {
        return $values if ref($values) eq 'ARRAY';
        die "selector $name needs values for '$previous'\n"
          unless ref($values) eq 'HASH';
        if ( $previous eq '*' ) {
            my %seen;
            my @all = map { @$_ }
              grep { ref($_) eq 'ARRAY' } @{$values}{ sort keys %$values };
            $values = [ grep { !$seen{$_}++ } @all ];
            next;
        }
        $values =
          exists $values->{$previous}
          ? $values->{$previous}
          : $values->{'*'};
        die "selector $name has no values for '$previous'\n"
          unless defined $values;
    }
    die "selector $name needs an array of allowed values\n"
      unless ref($values) eq 'ARRAY' && @$values;
    my %seen;
    for my $value (@$values) {
        die "selector $name has an invalid value\n"
          unless defined $value
          && !ref($value)
          && $value =~ /\A(?:[A-Za-z][A-Za-z0-9_]*|0|[1-9][0-9]*)\z/
          && $value ne '*'
          && $value ne 'any';
        die "selector $name has a duplicate value\n" if $seen{$value}++;
    }
    return $values;
}

# Independent columns do not need the Cartesian product merely to assign IDs.
# Conditional domains visit only the prefixes needed to collect their values.
sub selector_column_values {
    my ( $diag, $column ) = @_;
    my $name         = $diag->{message_selectors}[$column];
    my ($definition) = grep { $_->{name} eq $name } @{ $diag->{selector_definitions} || [] };
    my ($param)      = grep { $_->{name} eq $name } @{ $diag->{params}               || [] };
    my $values       = $definition ? $definition->{values} : $param && $param->{selector_values};
    return selector_values_for( $diag, $column, [] )
      if $definition && $definition->{plural} || ref($values) eq 'ARRAY';

    my ( %seen, @values );
    my $walk;
    $walk = sub {
        my ( $depth, $path ) = @_;
        if ( $depth == $column ) {
            push @values, grep { !$seen{$_}++ } @{ selector_values_for( $diag, $column, $path ) };
            return;
        }
        $walk->( $depth + 1, [ @$path, $_ ] ) for @{ selector_values_for( $diag, $depth, $path ) };
    };
    $walk->( 0, [] );
    return \@values;
}

sub selector_combinations {
    my ($diag)      = @_;
    my @selectors   = @{ $diag->{message_selectors} || [] };
    my %definitions = map { $_->{name} => $_ } @{ $diag->{selector_definitions} || [] };
    my @combinations;
    my $walk;
    $walk = sub {
        my ( $depth, $path ) = @_;
        if ( $depth == @selectors ) {
            push @combinations, [@$path];
            return;
        }
        my $definition = $definitions{ $selectors[$depth] } || {};
        my @values     = @{ selector_values_for( $diag, $depth, $path ) };
        unshift @values, '*' if $definition->{word_zero};
        for my $value (@values) {
            $walk->( $depth + 1, [ @$path, $value ] );
        }
    };
    $walk->( 0, [] );
    return \@combinations;
}

# Order template cases by specificity, then by their packed selector key.
# Selector value order remains defined by each selector domain; this only
# orders the criteria that refer to those values.
my %selector_value_ids_by_diag;

# Map selector columns to the fixed packed-key layout. A wide field occupies
# the top two octets regardless of where it appears in configuration order.
sub selector_packed_layout {
    my ($diag)      = @_;
    my @names       = @{ $diag->{message_selectors} || [] };
    my %definitions = map  { $_->{name} => $_ } @{ $diag->{selector_definitions} || [] };
    my @wide        = grep { $definitions{ $names[$_] }{wide} } 0 .. $#names;

    die "diagnostic $diag->{code} has more than one wide selector\n" if @wide > 1;
    die "diagnostic $diag->{code} has more than seven selectors\n"   if @names > 7;
    die "diagnostic $diag->{code} has more than six narrow selectors with a wide selector\n"
      if @wide && @names - @wide > 6;

    my ( @shifts, @widths );
    my $narrow_index = 0;
    for my $column ( 0 .. $#names ) {
        if ( @wide && $column == $wide[0] ) {
            $shifts[$column] = 48;
            $widths[$column] = 16;
        }
        else {
            $shifts[$column] = 8 * $narrow_index++;
            $widths[$column] = 8;
        }
    }

    return { shifts => \@shifts, widths => \@widths, wide_column => $wide[0] };
}

sub ordered_selector_cases {
    my ( $diag, $cases ) = @_;
    my $diag_key = refaddr($diag);

    # Translation import may add exact numbers without replacing this object.
    # Its plural domain must be rebuilt when those branches change.
    my $has_plural         = grep { $_->{plural} } @{ $diag->{selector_definitions} || [] };
    my $selector_value_ids = $has_plural ? undef : $selector_value_ids_by_diag{$diag_key};

    if ( !$selector_value_ids ) {
        my @ids_by_column;

        for my $column ( 0 .. $#{ $diag->{message_selectors} || [] } ) {
            my @values = @{ selector_column_values( $diag, $column ) };
            my %ids;
            @ids{@values} = 1 .. @values;
            push @ids_by_column, \%ids;
        }

        $selector_value_ids = \@ids_by_column;
        $selector_value_ids_by_diag{$diag_key} = $selector_value_ids unless $has_plural;
    }

    my $packed_layout = selector_packed_layout($diag);
    my @packed_order =
      sort { $packed_layout->{shifts}[$b] <=> $packed_layout->{shifts}[$a] } 0 .. $#$selector_value_ids;

    my @indexed = map {
        my $case = $cases->[$_];
        my @key;
        for my $column ( 0 .. $#$selector_value_ids ) {
            my $value = $case->{selectors}[$column];
            push @key, !defined($value) || $value eq '*'
              ? 0
              : $selector_value_ids->[$column]{$value};
            die "diagnostic $diag->{code} has no selector key for value '$value'\n"
              if defined($value) && $value ne '*' && !defined( $key[-1] );
        }
        [ $case, scalar( grep { $_ } @key ), \@key ]
    } 0 .. $#$cases;

    return map { $_->[0] }
      sort {
             $b->[1] <=> $a->[1]
          || _compare_selector_keys( $a->[2], $b->[2], \@packed_order )
          || $a->[0]{template} cmp $b->[0]{template}
      } @indexed;
}

# Compare packed selector keys from the most significant octet to the least.
sub _compare_selector_keys {
    my ( $left, $right, $packed_order ) = @_;

    for my $index (@$packed_order) {
        my ( $a, $b ) = ( $left->[$index], $right->[$index] );
        next if $a == $b;
        return $a <=> $b;
    }

    return 0;
}

1;
