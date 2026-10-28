#!/usr/bin/perl

# Regenerate the diagnostic catalog, POD, C tables, helpers, and macros.
# Run with the environment perl: perl regen/diag.pl
# Keep macro inputs separate from composed diagnostic parameters.  A formatter
# such as UTF8fARG consumes several inputs to produce one parameter value.

use strict;
use warnings;
use charnames ':full';
use Encode qw(encode);
use Digest::SHA qw(sha256_hex);
use Scalar::Util qw(refaddr);
use Text::Wrap ();

our ( $CONF, $META );

BEGIN { require './regen/regen_lib.pl'; }
require './regen/diag_lib.pm';
require './regen/diag_classes.pm';
require './regen/warnings_data.pm';
require './regen/diag_pod.pm';
require './regen/diag_words.pm';
require './regen/diag_plural.pm';

my $printf_formatter       = qr/[+#0 -]*(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|h|ll|l|j|z|t|L)?[diouxXcspfFeEgGaA]/;
my $printf_conversion      = qr/%(?:$printf_formatter)/;
my $printf_format_sequence = qr/(?:[^%]|%%|$printf_conversion)+/;
my %selector_by_parameter;

sub selector_for_parameter {
    my ($arg) = @_;
    my $selectors = $selector_by_parameter{ refaddr($arg) };
    return $selectors && $selectors->[0];
}

sub diagnostic_enum_name {
    return Diag::Migration::diagnostic_enum_name(@_);
}

sub diagnostic_index_name  { return diagnostic_enum_name( $_[0], 'idx' ) }
sub diagnostic_number_name { return diagnostic_enum_name( $_[0], 'number' ) }
sub template_text_name     { return 'perl_diag_template_text_' . $_[0] }
sub template_start_name    { return 'perl_diag_template_start_' . $_[0] . '_' . $_[1] }
sub template_end_name      { return 'perl_diag_template_end_' . $_[0] }
sub selector_domain_name   { return 'perl_diag_selector_domain_' . $_[0] . '_' . $_[1] }
sub selector_domain_id_name { return selector_domain_name( @_ ) . '_id' }

sub selector_value_symbol {
    my ( $domain, $value, $id ) = @_;
    my $suffix = $value =~ /\A[0-9]+\z/ ? 'digits_' . $value : lc $value;
    return selector_domain_name( $domain->{owner_number}, $domain->{owner_column} ) . '_' . $suffix . '_' . $id;
}

# Names used for fixed locals and helper calls in generated C code.
my %generated_c_names = (
    diagnostic_index   => 'diag_index',
    params             => 'params_av',
    message            => 'message_sv',
    category           => 'category',
    category_value     => 'category_value',
    context_ptr        => 'context_ptr',
    exception_slot     => 'exception_slot',
    exception_slot_ptr => 'exception_slot_ptr',
    parameter_hash     => '_diag_param_hv',
    param_label        => 'label',
    param_type         => 'value_type',
    param_value        => 'param_value',
);

my %generated_c_functions = (
    word_operation_from_name => 'Perl_diag_word_operation_from_name',
    setup_param              => 'Perl_diag_setup_param',
    format_template          => 'Perl_diag_format_template',
    append                   => 'Perl_diag_append',
    die                      => 'Perl_diag_die',
    die_sv                   => 'Perl_diag_die_sv',
    die_nocontext            => 'Perl_diag_die_nocontext',
    die_nocontext_sv         => 'Perl_diag_die_nocontext_sv',
    croak                    => 'Perl_diag_croak',
    croak_sv                 => 'Perl_diag_croak_sv',
    croak_nocontext          => 'Perl_diag_croak_nocontext',
    croak_nocontext_sv       => 'Perl_diag_croak_nocontext_sv',
    croak_caller             => 'Perl_diag_croak_caller',
    croak_caller_sv          => 'Perl_diag_croak_caller_sv',
    warn                     => 'Perl_diag_warn',
    warn_sv                  => 'Perl_diag_warn_sv',
    warn_nocontext           => 'Perl_diag_warn_nocontext',
    warn_nocontext_sv        => 'Perl_diag_warn_nocontext_sv',
    ck_warner                => 'Perl_diag_ck_warner',
    ck_warner_sv             => 'Perl_diag_ck_warner_sv',
    ck_warner_d              => 'Perl_diag_ck_warner_d',
    ck_warner_d_sv           => 'Perl_diag_ck_warner_d_sv',
    ck_warner_regex_sv       => 'Perl_diag_ck_warner_regex_sv',
    ck_warner_d_regex_sv     => 'Perl_diag_ck_warner_d_regex_sv',
    fatal_warner             => 'Perl_diag_fatal_warner',
    fatal_warner_sv          => 'Perl_diag_fatal_warner_sv',
    taint_warner_d_sv        => 'Perl_diag_taint_warner_d_sv',
    warner                   => 'Perl_diag_warner',
    warner_sv                => 'Perl_diag_warner_sv',
    warner_regex_sv          => 'Perl_diag_warner_regex_sv',
);

sub generated_c_name {
    my ($key) = @_;
    die "unknown generated C name '$key'\n" unless exists $generated_c_names{$key};
    return $generated_c_names{$key};
}

sub generated_c_function {
    my ($key) = @_;
    die "unknown generated C function '$key'\n" unless exists $generated_c_functions{$key};
    return $generated_c_functions{$key};
}

# C quoting and parameter inputs

# Quote literal bytes for inclusion in a C string.
sub c_quote {
    my ($text) = @_;
    $text =~ s/([\\"])/\\$1/g;
    $text =~ s/\n/\\n/g;
    $text =~ s/\r/\\r/g;
    $text =~ s/\t/\\t/g;
    $text =~ s/\x0b/\\v/g;
    $text =~ s/\x0c/\\f/g;
    $text =~ s/\x08/\\b/g;
    $text =~ s/\x07/\\a/g;
    return '"' . $text . '"';
}

# Encode catalog text as UTF-8 and escape non-ASCII bytes for portable C source.
sub c_quote_utf8 {
    my ($text) = @_;

    my $bytes  = encode( 'UTF-8', $text );
    my $quoted = c_quote($bytes);
    $quoted =~ s/([\x80-\xFF])/sprintf("\\%03o", ord($1))/ge;
    return $quoted;
}

# Return macro inputs for one composed diagnostic parameter.
sub parameter_inputs {
    my ($arg) = @_;
    return @{ $arg->{inputs} || [$arg] };
}

# Recognize writers that fill an SV instead of expanding a C argument list.
sub is_format_writer {
    return defined( $_[0] ) && $_[0] =~ /\A(?:sv_setpvf|sv_catpvf)\z/;
}

# Pass a format argument for plain parameters.  Parameters with a pass
# function keep their format coupled to that preprocessing step.
sub helper_uses_format_parameter {
    my ($arg) = @_;
    my $selector = selector_for_parameter($arg);
    return 0 if $selector && !$selector->{definition}{plural};
    return 0 if native_capture_kind($arg);
    return !defined( $arg->{pass} ) || $arg->{pass} eq '';
}

# Return the C scalar type required by a printf conversion or Perl format token.
# Pointer and compound formats are handled by their input-specific callers.
sub scalar_format_c_type {
    my ($format) = @_;

    my %types = (
        IVdf    => 'IV',
        I32df   => 'I32',
        UVuf    => 'UV',
        UVxf    => 'UV',
        UVXf    => 'UV',
        U32uf   => 'U32',
        U32xf   => 'U32',
        LINE_Tf => 'line_t',
        zd      => 'SSize_t',
        zu      => 'Size_t',
        td      => 'ptrdiff_t',
        jd      => 'PERL_INTMAX_T',
        ld      => 'long',
        li      => 'long',
        lu      => 'unsigned long',
        lx      => 'unsigned long',
        '#lx'   => 'unsigned long',
    );

    return $types{$format};
}

# Quote ordinary printf conversions, leaving Perl format tokens as C tokens.
sub parameter_printf_format {
    my ($arg) = @_;

    my $format = $arg->{format_str};
    my $prefix = '%' . ( $arg->{prefix} || '' );

    return c_quote( $prefix . $format )
      if $format =~ /\A$printf_formatter\z/;

    return c_quote($prefix) . ' ' . $format;
}

# Apply an argument-expansion macro, including its configured fallback value.
# SV writers take a destination separately and receive the input list directly.
sub parameter_pass_expression {
    my ( $arg, $inputs ) = @_;

    my $pass   = $arg->{pass};
    my @values = @$inputs;

    return join( ', ', @values ) if !$pass || is_format_writer($pass);

    push @values, $arg->{default} if defined $arg->{default};

    return $pass . '(' . join( ', ', @values ) . ')';
}

# Separate an SV writer's formatting inputs from its optional UTF-8 flag input.
# The returned indexes let each rendering context choose its own C input names.
sub parameter_writer_inputs {
    my ($arg) = @_;

    my ( @values, $utf8 );

    for my $i ( 0 .. $#{ $arg->{inputs} } ) {
        if ( defined( $arg->{utf8_input} )
            && $arg->{inputs}[$i]{name} eq $arg->{utf8_input} )
        {
            $utf8 = $i;
        }
        else {
            push @values, $i;
        }
    }

    return ( \@values, $utf8 );
}

# Classify Perl text format tokens independently of their input constraints.
# Shared helpers and inline capture apply different policies to these families.
sub text_format_family {
    my ($format) = @_;

    return 'sv'      if $format =~ /\ASVf(?:32|256|_QUOTEDPREFIX)?\z/;
    return 'utf8'    if $format =~ /\AUTF8f(?:_QUOTEDPREFIX)?\z/;
    return 'padname' if $format eq 'PNf';
    return 'pv'      if $format eq 'PVf_QUOTEDPREFIX';
    return 'hek'
      if $format =~ /\AHEKf(?:256|_QUOTEDPREFIX|256_QUOTEDPREFIX)?\z/;
    return 'hvname' if $format =~ /\A(?:HvNAMEf(?:_QUOTEDPREFIX|_DEFAULT)?|PERL_HvNAMEf_DEFAULT)\z/;

    return '';
}

# Numeric capture policies share these supported conversion spellings.
sub scalar_parameter_format_supported {
    my ( $type, $format ) = @_;

    my %formats = (
        char => qr/\Ac\z/,
        iv   => qr/\A(?:c|d|i|ld|li|zd|td|jd|IVdf|I32df|LINE_Tf)\z/,
        uv   => qr/\A(?:u|x|o|02x|02X|04X|#o|lu|lx|#lx|zu|UVuf|UVxf|UVXf|U32uf|U32xf|LINE_Tf)\z/,
        nv   => qr/\ANV(?:e|f|g)f\z/,
        ptr  => qr/\Ap\z/,
    );

    return exists( $formats{$type} ) && $format =~ $formats{$type};
}

# Describe one parameter's format and value expressions for either C context.
# Helper formals use normalized input names and a formal fallback parameter.
sub parameter_formatting {
    my ( $arg, $inputs, $options ) = @_;

    my $format = parameter_printf_format($arg);
    my $values = parameter_pass_expression( $arg, $inputs );

    return ( $format, $values ) unless $options->{shared_helper};

    my $pass  = $arg->{pass} || '';
    my $token = $arg->{format_str};

    if ( $pass eq 'UTF8fARG' || $pass eq 'SVfARG' || $pass eq 'PNfARG' ) {
        $format = c_quote('%') . ' ' . $token;
    }
    elsif ( $pass =~ /\A(?:HvNAMEfARG|PERL_HvNAMEfARG_DEFAULT)/ ) {
        $format = c_quote('%') . ' ' . $token;
        $values =
          $pass eq 'PERL_HvNAMEfARG_DEFAULT'
          ? "&$options->{default_argument}"
          : "HvNAMEfARG($inputs->[0])";
    }
    elsif ( $pass eq 'HvNAME_HEK' ) {
        $format = c_quote('%') . ' HEKf';
        $values = "HEKfARG(HvNAME_HEK($inputs->[0]))";
    }
    elsif ( $token =~ /\AHEKf/ ) {
        $values = $pass ? "HEKfARG($inputs->[0])" : $inputs->[0];
    }
    else {
        $values = join( ', ', @$inputs );
    }

    $format = $options->{format_var}
      if $options->{shared_helper} && defined $options->{format_var};

    return ( $format, $values );
}

# Describe an SV writer call and the optional input that marks its result UTF-8.
# Callers provide layout and terminators so helper hashes remain unchanged.
sub parameter_writer_expression {
    my ( $arg, $destination, $inputs, $format_var ) = @_;

    my ( $value_indexes, $utf8_index ) = parameter_writer_inputs($arg);
    my @values = map { $inputs->[$_] } @$value_indexes;
    my $call =
      $arg->{pass} . '(' . $destination . ', '
      . ( defined($format_var) ? $format_var : c_quote( $arg->{format_str} ) )
      . ', ' . join( ', ', @values ) . ')';
    my $utf8 = defined($utf8_index) ? $inputs->[$utf8_index] : undef;

    return ( $call, $utf8 );
}

# Catalog validation

# Validate one composed parameter and the inputs used to format its value.
sub validate_message_parameter {
    my ( $diag, $arg ) = @_;

    my $code = $diag->{code};

    die "diagnostic $code has an invalid argument\n"
      unless ref($arg) eq 'HASH'
      && defined $arg->{name}
      && $arg->{name} =~ /\A[A-Za-z_]\w*\z/
      && defined $arg->{type}
      && $arg->{type} =~ /\A(?:text|byte|iv|uv|nv|char|ptr|sv)\z/;

    die "diagnostic $code has an invalid selector_assert_unknown flag\n"
      if exists( $arg->{selector_assert_unknown} )
      && (!defined( $arg->{selector_assert_unknown} )
        || ref( $arg->{selector_assert_unknown} )
        || $arg->{selector_assert_unknown} !~ /\A[01]\z/ );

    die "diagnostic $code has selector_assert_unknown without selector_values\n"
      if exists( $arg->{selector_assert_unknown} )
      && !exists( $arg->{selector_values} );

    die "diagnostic $code has an invalid literal fragment\n"
      if $arg->{literal_fragment}
      && ( $arg->{type} ne 'text'
        || $arg->{pass}
        || $arg->{inputs}
        || $arg->{format_str}
        || !$diag->{compatibility} );

    die "diagnostic $code has an invalid formatter\n"
      if defined $arg->{format_str}
      && $arg->{format_str} !~ /\A(?:[A-Za-z_][A-Za-z0-9_]*|$printf_formatter)\z/
      && !( is_format_writer( $arg->{pass} ) && $arg->{format_str} =~ /\A$printf_format_sequence\z/ );

    die "diagnostic $code has an invalid pass function\n"
      if defined $arg->{pass}
      && $arg->{pass} !~ /\A(?:[A-Za-z_][A-Za-z0-9_]*|sv_setpvf|sv_catpvf)\z/;

    die "diagnostic $code has an invalid format prefix\n"
      if defined $arg->{prefix}
      && $arg->{prefix} !~ /\A[+#0 -]*\d*(?:\.\d+)?\z/;

    if ( exists $arg->{inputs} ) {

        die "diagnostic $code has invalid formatter inputs\n"
          unless ref( $arg->{inputs} ) eq 'ARRAY' && @{ $arg->{inputs} };
        for my $input ( @{ $arg->{inputs} } ) {

            die "diagnostic $code has an invalid formatter input\n"
              unless ref($input) eq 'HASH'
              && defined $input->{name}
              && $input->{name} =~ /\A[A-Za-z_]\w*\z/
              && defined $input->{type}
              && $input->{type} =~ /\A(?:text|byte|iv|uv|nv|char|ptr|sv)\z/;
        }
    }

    die "diagnostic $code formatted composition needs inputs\n"
      if is_format_writer( $arg->{pass} )
      && ( !exists( $arg->{inputs} ) || !@{ $arg->{inputs} } );

    if ( is_format_writer( $arg->{pass} ) ) {
        my $format = $arg->{format_str};
        my $needed = 0;
        while ( $format =~ /($printf_conversion|%%)/g ) {
            my $conversion = $1;
            next if $conversion eq '%%';
            $needed += ( $conversion =~ tr/*/*/ );
            $needed++;
        }

        die "diagnostic $code formatted composition has too few inputs\n"
          if $needed > @{ $arg->{inputs} };

        die "diagnostic $code formatted composition has unused inputs\n"
          if $needed < @{ $arg->{inputs} }
          && ( !defined( $arg->{utf8_input} )
            || @{ $arg->{inputs} } != $needed + 1
            || $arg->{inputs}[-1]{name} ne $arg->{utf8_input} );
    }

    die "diagnostic $code has an invalid UTF-8 input name\n"
      if exists $arg->{utf8_input}
      && !( grep { $_->{name} eq $arg->{utf8_input} && $_->{type} eq 'iv' } @{ $arg->{inputs} || [] } );
}

# Reject malformed definitions before any output file is opened.
sub validate_diagnostic {
    my ( $conf, $diag, $allow_missing_forms ) = @_;

    die "diagnostic entry is not a hash reference\n"
      unless ref($diag) eq 'HASH';

    Diag::Words::validate_bindings( $diag, undef, $allow_missing_forms );

    die "diagnostic has no emit hash\n"
      unless ref( $diag->{emit} ) eq 'HASH';

    die "diagnostic has no exception kind\n"
      unless defined $diag->{kind} && $diag->{kind} =~ /\A[A-Z][A-Z0-9_]*\z/;

    die "diagnostic has an obsolete flat schema field\n"
      if grep { exists $diag->{$_} }
      qw(id args call_args aliases exception emitter emitter_aliases delivery_params template format props);

    die "diagnostic emit.params is not an array\n"
      if exists $diag->{emit}{params}
      && ref( $diag->{emit}{params} ) ne 'ARRAY';

    die "diagnostic emit.aliases is not an array\n"
      if exists $diag->{emit}{aliases}
      && ref( $diag->{emit}{aliases} ) ne 'ARRAY';

    my $has_accumulation_category =
      grep { $_->{name} eq 'category' && $_->{type} eq 'uv' } @{ $diag->{emit}{params} || [] };

    die "diagnostic emit.accumulate_macro must name a warning macro\n"
      if exists $diag->{emit}{accumulate_macro}
      && (
          !defined $diag->{emit}{accumulate_macro}
        || ref( $diag->{emit}{accumulate_macro} )
        || $diag->{emit}{accumulate_macro} !~ /\APERL_APPEND_[A-Z0-9_]+\z/
        || !Diag::Migration::is_warning_emitter( $diag->{emit}{api} || 'DIE' )
        || (   !@{ $diag->{warning_categories} || [] }
            && !$has_accumulation_category )
        || $diag->{dynamic}
      );

    die "diagnostic macro belongs at the top level\n"
      if exists $diag->{emit}{macro};
    my $code = $diag->{code};

    die "diagnostic $code has no severity\n"
      unless Diag::Migration::severity_name( $conf, $diag->{severity} );

    die "diagnostic $code has no argument list\n"
      unless ref( $diag->{params} ) eq 'ARRAY';

    die "diagnostic $code has more than 255 message parameters\n"
      if @{ $diag->{params} } > 255;

    for my $flag (qw(has_following_hint is_hint)) {
        die "diagnostic $code has an invalid $flag flag\n"
          if exists $diag->{$flag}
          && $diag->{$flag} !~ /\A[01]\z/;
    }

    die "diagnostic $code has an invalid format macro\n"
      if defined $diag->{emit}{format_macro}
      && $diag->{emit}{format_macro} !~ /\APERL_(?:DIAG_)?FORMAT_[A-Z0-9_]+\z/;

    die "diagnostic $code has a format macro format without a format macro\n"
      if exists( $diag->{emit}{format_macro_format} )
      && !defined( $diag->{emit}{format_macro} );

    die "diagnostic $code has invalid static format chunks\n"
      if exists $diag->{emit}{format_macro_chunks}
      && ( $diag->{emit}{format_macro_chunks} !~ /\A[01]\z/
        || !defined $diag->{emit}{format_macro}
        || ( $diag->{emit}{api} || '' ) ne 'RENDER' );

    my $format_error = Diag::Migration::format_error($diag);

    die "diagnostic $code has $format_error\n" if $format_error;

    for my $arg ( @{ $diag->{params} } ) {
        validate_message_parameter( $diag, $arg );
    }

    for my $arg ( @{ $diag->{emit}{params} || [] } ) {

        die "diagnostic $code has an invalid call argument\n"
          unless ref($arg) eq 'HASH'
          && defined $arg->{name}
          && $arg->{name} =~ /\A[A-Za-z_]\w*\z/
          && defined $arg->{type}
          && $arg->{type} =~ /\A(?:text|byte|iv|uv|nv|char|ptr|sv)\z/;
    }
    my %params;

    for my $arg ( @{ $diag->{params} }, @{ $diag->{emit}{params} || [] } ) {
        for my $param ( parameter_inputs($arg) ) {

            die "diagnostic $code has duplicate parameter $param->{name}\n"
              if $params{ $param->{name} }++;
        }
    }
}

# Template and selector tables

# Analyze each diagnostic once after validation. Table writers borrow these
# results instead of rescanning every language for each generated case. Keep
# the analysis outside the catalog so translation imports cannot reuse stale
# data and the normalized configuration contains only its own schema.
sub build_template_analysis {
    my ($diagnostics) = @_;
    my %analysis;

    for my $diag (@$diagnostics) {
        my %cases =
          map { $_ => Diag::Migration::template_cases( $diag, $_ ) } keys %{ $diag->{message_template} || {} };
        $analysis{ $diag->{code} } = {
            cases      => \%cases,
            parameters => Diag::Migration::template_parameter_layout($diag),
        };
    }

    return \%analysis;
}

# Replace named placeholders with positional string conversions in parameter order.
sub positional_template {
    my ( $template, $argspec, $code ) = @_;

    if ( !@$argspec ) {
        $template =~ s/%%/%/g;
        return ( $template, 0 );
    }

    my %index     = map { $argspec->[$_]{name} => $_ + 1 } 0 .. $#$argspec;
    my $max_index = 0;

    # Copy literal spans as a whole rather than making a suffix copy and
    # several substring tests for each character in every translation.
    $template =~ s{%%|%\{([A-Za-z_]\w*)\}|%}{
        if (defined $1) {
            my $name = $1;
            die "diagnostic $code template references unknown output argument $name\n"
              unless $index{$name};
            $max_index = $index{$name} if $index{$name} > $max_index;
            '%' . $index{$name} . '$s';
        }
        else { '%%' }
    }ge;

    return ( $template, $max_index );
}

# Intern ordered semantic value lists in the generator.  Language rows borrow
# these definitions, while output naming remains unchanged for this refactor.
sub selector_value_definition {
    my ( $values, $value_sets, $diag, $column, $width ) = @_;
    my @values = @$values;
    my $key    = join( '', $width, map { length($_) . ':' . $_ } @values );

    return $value_sets->{$key} if exists $value_sets->{$key};

    my %ids;
    @ids{@values} = 1 .. @values;

    my $definition = {
        values       => \@values,
        ids          => \%ids,
        width        => $width,
        symbols      => {},
        owner_number => $diag->{number},
        owner_column => $column,
        domain_id    => 1 + scalar keys %$value_sets,
    };
    $definition->{symbols}{ $values[$_] } =
      selector_value_symbol( $definition, $values[$_], $_ + 1 )
      for 0 .. $#values;
    $value_sets->{$key} = $definition;

    return $definition;
}

sub render_only_selector_definition {
    my ( $values, $diag, $column, $width ) = @_;
    my @values = @$values;
    my %ids;
    @ids{@values} = 1 .. @values;
    return {
        values       => \@values,
        ids          => \%ids,
        width        => $width,
        symbols      => {},
        owner_number => $diag->{number},
        owner_column => $column,
        domain_id    => 0,
    };
}

# Build canonical producer domains; plural and word-selector IDs are local
# rendering details and do not enter the shared domain registry.
sub build_selector_layouts {
    my ($diagnostics) = @_;

    %selector_by_parameter = ();
    my ( %layouts, %value_sets );

    for my $diag ( sort { $a->{number} <=> $b->{number} } @$diagnostics ) {
        my @names = @{ $diag->{message_selectors} || [] };
        my ( @values, @ids );
        my $packed_layout = Diag::Migration::selector_packed_layout($diag);

        if (@names) {
            for my $column ( 0 .. $#names ) {
                my $width      = $packed_layout->{widths}[$column];
                my ($selector_definition) = grep { $_->{name} eq $names[$column] }
                  @{ $diag->{selector_definitions} || [] };
                my $render_only = $selector_definition
                  && ( $selector_definition->{plural} || $selector_definition->{operation_word} );
                my $definition = $render_only
                  ? render_only_selector_definition(
                    Diag::Migration::selector_column_values( $diag, $column ),
                    $diag, $column, $width )
                  : selector_value_definition(
                    Diag::Migration::selector_column_values( $diag, $column ),
                    \%value_sets, $diag, $column, $width );

                my $max_values = $width == 16 ? 65535 : 255;
                die "diagnostic $diag->{code} selector $names[$column] has more than $max_values values\n"
                  if @{ $definition->{values} } > $max_values;

                push @values,                                        $definition->{values};
                push @ids,                                           $definition->{ids};
                push @{ $layouts{ $diag->{code} }{domains} ||= [] }, $definition;
                my $selector = $diag->{selector_definitions}[$column];
                next if $selector->{operation_word};
                my $source = $selector->{source} || $selector->{name};
                my ($parameter) = grep { $_->{name} eq $source } @{ $diag->{params} };
                die "diagnostic $diag->{code} selector $selector->{name} has no source parameter\n"
                  unless $parameter;
                push @{ $selector_by_parameter{ refaddr($parameter) } ||= [] },
                  {
                    domain     => $definition,
                    column     => $column,
                    definition => $selector,
                    diagnostic => $diag,
                  };
            }
        }

        $layouts{ $diag->{code} } ||= {};
        $layouts{ $diag->{code} }{names}      = \@names;
        $layouts{ $diag->{code} }{values}     = \@values;
        $layouts{ $diag->{code} }{ids}        = \@ids;
        $layouts{ $diag->{code} }{packed}     = $packed_layout;
        $layouts{ $diag->{code} }{diagnostic} = $diag;
        $layouts{ $diag->{code} }{number}     = $diag->{number};
    }

    return \%layouts;
}

sub build_language_selector_layouts {
    my ( $diagnostics, $language, $selector_layouts, $word_data ) = @_;
    $word_data ||= Diag::Words::catalog();
    my %language_layouts;

    for my $diag (@$diagnostics) {
        my $base = $selector_layouts->{ $diag->{code} };
        my %layout = %$base;
        $layout{domains} = [ @{ $base->{domains} || [] } ];
        $layout{values}  = [ @{ $base->{values} || [] } ];
        $layout{ids}     = [ @{ $base->{ids} || [] } ];
        my $word_domains = Diag::Words::rule_selector_domains( $diag, $word_data, $language );

        for my $column ( 0 .. $#{ $layout{names} || [] } ) {
            my $definition = $diag->{selector_definitions}[$column] || {};
            next unless $definition->{plural} || $definition->{operation_word};
            my $values = $definition->{plural}
              ? Diag::Migration::selector_values_for( $diag, $column, [], $language )
              : $word_domains->{ $layout{names}[$column] } || [];
            my $local = render_only_selector_definition(
                $values, $diag, $column, $layout{packed}{widths}[$column] );
            $layout{domains}[$column] = $local;
            $layout{values}[$column]  = $local->{values};
            $layout{ids}[$column]     = $local->{ids};
        }
        $language_layouts{ $diag->{code} } = \%layout;
    }

    return \%language_layouts;
}

sub selector_domain_id_expression {
    my ( $arg, $selector ) = @_;
    $selector ||= selector_for_parameter($arg);
    $selector = $selector->[0] if ref($selector) eq 'ARRAY';
    return '0' unless $selector && !$selector->{definition}{plural};
    my $domain = $selector->{domain};
    return selector_domain_id_name( $domain->{owner_number}, $domain->{owner_column} );
}

sub selector_setup_arguments {
    my ( $arg, $inputs ) = @_;
    my $selector = selector_for_parameter($arg);
    $selector = $selector->[0] if ref($selector) eq 'ARRAY';
    $selector = undef if $selector && $selector->{definition}{plural};
    my $domain_id = selector_domain_id_expression( $arg, $selector );
    return [ $domain_id, $domain_id eq '0' ? 'perl_diag_selector_invalid' : $inputs->[0] ];
}

# Store simple numeric sources as native values. The generator prepares their
# decimal spelling separately for legacy positional formats.
sub native_capture_kind {
    my ($arg) = @_;

    return unless ( $arg->{type} || '' ) =~ /\A(?:iv|uv)\z/;
    return if grep { exists $arg->{$_} } qw(inputs pass prefix literal_fragment);
    return if defined $arg->{role} && $arg->{role} ne 'internal';

    # Padding, precision and nondecimal conversions need their formatted value.
    # Match signedness to the C conversion, even when the semantic type differs.
    my %kinds = (
        IVdf    => 'iv',
        I32df   => 'iv',
        UVuf    => 'uv',
        U32uf   => 'uv',
        d       => 'iv',
        i       => 'iv',
        u       => 'uv',
        ld      => 'iv',
        li      => 'iv',
        lu      => 'uv',
        zd      => 'iv',
        zu      => 'uv',
        td      => 'iv',
        LINE_Tf => 'uv',
    );
    return $kinds{ $arg->{format_str} || '' };
}

# Pack criterion values in selector order, reserving zero for a wildcard.
# The C literal spelling and byte order are part of the current output format.
sub selector_pattern_hex {
    my ( $diag, $criteria, $selector_ids ) = @_;

    my $key = '0';

    if (@$selector_ids) {
        my $layout     = Diag::Migration::selector_packed_layout($diag);
        my $byte_count = defined( $layout->{wide_column} ) ? 8 : scalar @$selector_ids;
        my @pattern    = (0) x $byte_count;

        for my $column ( 0 .. $#$selector_ids ) {
            my $value = $criteria->[$column];
            next if $value eq '*';

            my $id = $selector_ids->[$column]{$value};
            die "diagnostic $diag->{code} has unknown selector value '$value'\n"
              unless $id;
            my $shift = $layout->{shifts}[$column];
            if ( $layout->{widths}[$column] == 16 ) {
                $pattern[ $shift / 8 ] = $id & 0xff;
                $pattern[ $shift / 8 + 1 ] = $id >> 8;
            }
            else {
                $pattern[ $shift / 8 ] = $id;
            }
        }

        # @pattern is little endian tuples, we need to convert to big
        # endian hex.
        $key = '0x' . join( '', reverse map { sprintf '%02x', $_ } @pattern );
    }

    return $key;
}

# Wrap the shared packed-key spelling for generated C initializers.
sub selector_pattern_expression {
    return 'UINT64_C(' . selector_pattern_hex(@_) . ')';
}

# Pad key contents so complete UINT64_C() tokens align to their longest row.
sub align_selector_key_arguments {
    my ($rows) = @_;
    my $column_width = 0;
    for my $row (@$rows) {
        my ($key) = $row->[1] =~ /\AUINT64_C\((0x[0-9a-f]+|0)\)\z/;
        die "invalid generated selector key $row->[1]\n" unless defined $key;
        my $token_width = length("UINT64_C($key),");
        $column_width = $token_width if $token_width > $column_width;
    }
    for my $row (@$rows) {
        my ($key) = $row->[1] =~ /\AUINT64_C\((0x[0-9a-f]+|0)\)\z/;
        die "invalid generated selector key $row->[1]\n" unless defined $key;
        my $padding_width = $column_width - length("UINT64_C($key),");
        die "selector key column is too narrow\n" if $padding_width < 0;
        my $padding = ' ' x $padding_width;
        $row->[1] = "UINT64_C($padding$key)";
    }
}

# Compile plural names to selector IDs once. Runtime matching uses only
# integer category maps and exact counts, not the corresponding strings.
sub write_plural_selector_definition {
    my ( $out, $diag, $column, $domain, $registry, $language ) = @_;
    my $definition     = $diag->{selector_definitions}[$column];
    my $kind           = uc( $definition->{plural} );
    my @exact          = grep { /\A(?:0|[1-9][0-9]*)\z/ } @{ $domain->{values} };
    for my $n (@exact) {
        die "diagnostic $diag->{code} has an exact plural value beyond U64\n"
          if length($n) > 20 || length($n) == 20 && $n gt '18446744073709551615';
    }
    my $values = $domain->{values};
    my $key = join( '|', $language, $kind, @$values );
    return $registry->{plural_names}{$key} if exists $registry->{plural_names}{$key};

    my $suffix = $language . '_' . $diag->{number} . '_' . $column;
    my $name   = 'Perl_diag_plural_selector_' . $suffix;
    my $macro    = 'PERL_DIAG_PLURAL_SELECTOR_' . $suffix;
    my @branches = map { "(n) == UINT64_C($_) ? (IV)$domain->{ids}{$_} :" } @exact;
    push @branches, "(IV)PERL_DIAG_PLURAL_${kind}_$language(n)";
    print {$out} render_plural_rule_macro( $macro, join( ' ', @branches ) );
    print {$out} "PERL_STATIC_INLINE IV\n$name(pTHX_ U16 language, UV n)\n{\n",
      "    PERL_UNUSED_CONTEXT;\n    PERL_UNUSED_ARG(language);\n",
      "    return $macro(n);\n}\n\n";
    return $registry->{plural_names}{$key} = $name;
}

# Intern equal language-local selector arrays and descriptors within a catalog.
sub write_selector_definition {
    my ( $data_out, $diag, $selector_values, $selector_domains, $registry, $language ) = @_;

    my @selectors     = @{ $diag->{message_selectors} || [] };
    my $selector_data = 'NULL';

    if (@selectors) {
        my $parameter_layout = Diag::Migration::template_parameter_layout($diag);
        my $packed_layout    = Diag::Migration::selector_packed_layout($diag);
        my %definitions      = map { $_->{name} => $_ } @{ $diag->{selector_definitions} || [] };
        my @descriptor_rows;

        for my $selector_index ( 0 .. $#selectors ) {
            my $values     = $selector_values->[$selector_index];
            my $domain     = $selector_domains->[$selector_index];
            my $width      = $domain->{width};
            my $values_key = pack( 'N', $width ) . pack( 'N', scalar @$values ) . join '',
              map { pack( 'N/a*', $_ ) } @$values;
            my $values_data = $registry->{value_names}{$values_key};
            my $definition  = $definitions{ $selectors[$selector_index] };
            my $plural_data =
              $definition->{plural}
              ? write_plural_selector_definition( $data_out, $diag, $selector_index, $domain, $registry, $language )
              : 'NULL';

            if ( !defined $values_data ) {
                if (@$values) {
                    $values_data = 'perl_diag_selector_values_' . $language . '_' . $diag->{number} . '_' . $selector_index;
                    $registry->{value_names}{$values_key} = $values_data;
                    print {$data_out} "static const char * const $values_data\[\] = {\n";
                    print {$data_out} wrap_initializer_values( [ map { c_quote($_) } @$values ] );
                    print {$data_out} "};\n\n";
                }
                else {
                    $values_data = 'NULL';
                    $registry->{value_names}{$values_key} = $values_data;
                }
            }
            $registry->{domain_rows}{ $domain->{domain_id} } = [ $values_data, scalar @$values ]
              if $domain->{domain_id};

            push @descriptor_rows,
              [
                $selectors[$selector_index],
                $parameter_layout->{selector_indices}{ $selectors[$selector_index] },
                $domain->{domain_id}
                  ? selector_domain_id_name( $domain->{owner_number}, $domain->{owner_column} )
                  : '0',
                $values_data,
                scalar @$values,
                $domain->{width},
                $packed_layout->{shifts}[$selector_index],
                $definition->{plural} ? c_quote( $definition->{plural} ) : 'NULL',
                $definition->{assert_unknown} || 0,
                $definition->{operation_word} ? 1 : 0,
                $plural_data,
                $domain->{domain_id} ? 1 : 0
              ];
        }

        my $descriptor_key = join '', map {
            join '', map { pack( 'N/a*', $_ ) } @$_;
        } @descriptor_rows;
        $selector_data = $registry->{descriptor_names}{$descriptor_key};

        if ( !defined $selector_data ) {
            $selector_data = 'perl_diag_selectors_' . $language . '_' . $diag->{number};
            $registry->{descriptor_names}{$descriptor_key} = $selector_data;
            print {$data_out} "static const perl_diag_selector_t $selector_data\[\] = {\n";
            my @rows = map { [ c_quote( $_->[0] ), @$_[ 1 .. 11 ] ] } @descriptor_rows;
            print {$data_out} render_struct_rows( \@rows );
            print {$data_out} "};\n\n";
        }
    }
    return $selector_data;
}

# Share canonical domain definitions across language-local descriptors.
sub new_selector_definition_registry {
    my ($selector_layouts) = @_;

    my $max_domain_id = 0;
    for my $layout ( values %$selector_layouts ) {
        for my $domain ( @{ $layout->{domains} || [] } ) {
            $max_domain_id = $domain->{domain_id} if $domain->{domain_id} > $max_domain_id;
        }
    }
    return {
        value_names      => {},
        descriptor_names => {},
        domain_rows      => {},
        max_domain_id    => $max_domain_id,
        languages        => []
    };
}

sub write_selector_definitions {
    my ( $data_out, $diagnostics, $selector_layouts, $registry, $language ) = @_;
    my %definitions;

    for my $diag ( sort { $a->{number} <=> $b->{number} } @$diagnostics ) {
        $definitions{ $diag->{code} } =
          $diag->{dynamic}
          ? 'NULL'
          : write_selector_definition(
            $data_out, $diag,
            $selector_layouts->{ $diag->{code} }{values},
            $selector_layouts->{ $diag->{code} }{domains}, $registry, $language
          );
    }

    return \%definitions;
}

sub write_selector_domain_table {
    my ( $data_out, $registry ) = @_;
    print {$data_out} "static const perl_diag_selector_domain_t perl_diag_selector_domains[] = {\n";
    my @domain_rows = ( [ 'NULL', 0 ] );
    for my $domain_id ( 1 .. $registry->{max_domain_id} ) {
        push @domain_rows,
          exists $registry->{domain_rows}{$domain_id}
          ? $registry->{domain_rows}{$domain_id}
          : [ 'NULL', 0 ];
    }
    print {$data_out} render_struct_rows( \@domain_rows, { 0 => 'index 0 is invalid' } );
    print {$data_out} "};\n\n";
}

# Extend colliding hash prefixes until every distinct template has a unique name.
sub template_text_names {
    my ($hashes) = @_;

    my %lengths = map { $_ => 8 } keys %$hashes;
    while (1) {
        my %groups;
        for my $text ( keys %$hashes ) {
            push @{ $groups{ substr( $hashes->{$text}, 0, $lengths{$text} ) } }, $text;
        }

        my $extended = 0;
        for my $texts ( values %groups ) {
            next unless @$texts > 1;
            for my $text (@$texts) {
                die "distinct diagnostic templates have the same SHA-256 digest\n"
                  if $lengths{$text} == 64;
                ++$lengths{$text};
            }
            $extended = 1;
        }
        last unless $extended;
    }

    return { map { $_ => template_text_name( substr( $hashes->{$_}, 0, $lengths{$_} ) ) } keys %$hashes };
}

# Share positional template text across diagnostics, selector cases and languages.
# Hash the UTF-8 bytes, independent of the Perl string's internal representation.
sub write_template_texts {
    my ( $data_out, $diagnostics, $template_analysis, $words, $only_language ) = @_;

    my %hashes;
    for my $diag (@$diagnostics) {
        next if $diag->{dynamic};
        my $analysis = $template_analysis->{ $diag->{code} };
        my @languages = defined($only_language)
          ? ($only_language)
          : keys %{ $diag->{message_template} || {} };
        for my $language (@languages) {
            for my $case ( @{ $analysis->{cases}{$language} } ) {
                my ( $params ) = Diag::Migration::template_case_parameter_layout(
                    $diag, $case->{template} );
                my ($text) = positional_template( $case->{template}, $params, $diag->{code} );
                $hashes{$text} = sha256_hex( encode( 'UTF-8', $text ) ) unless exists $hashes{$text};
            }
        }
    }

    my @word_languages = defined($only_language)
      ? ($words->{languages}{$only_language})
      : values %{ $words->{languages} || {} };
    for my $language ( grep { defined } @word_languages ) {
        for my $value ( @{ $language->{values} } ) {
            next unless defined $value->{text};
            $hashes{ $value->{text} } = sha256_hex( encode( 'UTF-8', $value->{text} ) );
        }
    }

    my $names     = template_text_names( \%hashes );
    my %sort_keys = map { $_ => lc $_ } keys %$names;
    my @rows;
    for my $text ( sort { $sort_keys{$a} cmp $sort_keys{$b} || $a cmp $b } keys %$names ) {
        push @rows, [ "static const char $names->{$text}\[\]", c_quote_utf8($text) ];
    }
    print {$data_out} render_constant_definitions( \@rows );
    print {$data_out} "\n";
    return $names;
}

# Compile positional templates and packed selector criteria in their existing match order.
sub language_case_rows {
    my ( $diag, $cases, $selector_ids, $template_names, $projection_spans,
        $projection_prefix ) = @_;

    my ( @case_rows, $case_index );
    $case_index = 0;

    for my $case ( Diag::Migration::ordered_selector_cases( $diag, $cases ) ) {
        my $pattern  = selector_pattern_expression( $diag, $case->{selectors}, $selector_ids );
        my $template = $case->{template};
        my ( $params, $source_indices ) = Diag::Migration::template_case_parameter_layout(
            $diag, $template );
        my ( $positional, $arg_count ) =
          positional_template( $template, $params, $diag->{code} );
        my $name = $template_names->{$positional};
        die "diagnostic $diag->{code} has an unregistered template\n" unless defined $name;
        my $key = $projection_prefix . $case_index++;
        my $span = $projection_spans->{$key};
        die "diagnostic $diag->{code} has no parameter projection\n" unless $span;
        push @case_rows,
          [ diagnostic_number_name( $diag->{code} ), $pattern, $name,
            $arg_count, $span->{offset} ];
    }
    return @case_rows;
}

# Assign stable IDs to equal metadata rows.
sub intern_metadata_pair {
    my ( $pair_ids, $pairs, $values, $description ) = @_;
    my $key = join '', map { pack( 'N/a*', $_ ) } @$values;
    my $id  = $pair_ids->{$key};

    if ( !defined $id ) {
        $id = scalar @$pairs;
        die "too many unique $description definitions\n"
          if $id > 0xFFFF;
        $pair_ids->{$key} = $id;
        push @$pairs, [@$values];
    }

    return $id;
}

# Assign stable parameter-pair IDs and collect each diagnostic's ordered list.
sub collect_parameter_metadata {
    my ( $diag_table, $template_analysis ) = @_;

    my ( %pair_ids, @pairs, @lists );
    push @pairs, undef;

    for my $diag ( sort { $a->{number} <=> $b->{number} } @$diag_table ) {
        my $layout = $template_analysis->{ $diag->{code} }{parameters};
        my @ids;
        for my $param ( @{ $layout->{captured_params} } ) {
            my ( $name, $type ) = @{$param}{qw(name type)};
            die "diagnostic $diag->{code} parameter $name has no type\n"
              unless defined $type;

            push @ids, intern_metadata_pair( \%pair_ids, \@pairs, [ $name, $type ], 'diagnostic parameter' );
        }

        die "diagnostic $diag->{code} has too many parameters\n"
          if @ids > 0xFF;
        push @lists, { diagnostic => $diag, ids => \@ids };
    }

    return ( \@pairs, \@lists );
}

# Find the first existing contiguous span equal to an ID sequence.
sub find_metadata_id_span {
    my ( $stream, $ids ) = @_;

    return 0 unless @$ids;
    my $last_offset = scalar(@$stream) - scalar(@$ids);
    return unless $last_offset >= 1;

    for my $offset ( 1 .. $last_offset ) {
        my $matches = 1;
        for my $index ( 0 .. $#$ids ) {
            my $stream_index = $offset + $index;
            die "invalid diagnostic metadata ID span lookup\n"
              if $stream_index > $#$stream
              || !defined $stream->[$stream_index]
              || !defined $ids->[$index];

            if ( $stream->[$stream_index] != $ids->[$index] ) {
                $matches = 0;
                last;
            }
        }
        return $offset if $matches;
    }

    return;
}

# Pack longer ID sequences first so shorter sequences can reuse their spans.
sub pack_metadata_id_sequences {
    my ($lists) = @_;

    my @stream = (0);
    my %spans;
    for my $list ( sort { @{ $b->{ids} } <=> @{ $a->{ids} } || $a->{diagnostic}{number} <=> $b->{diagnostic}{number} }
        @$lists )
    {
        my $ids    = $list->{ids};
        my $offset = find_metadata_id_span( \@stream, $ids );
        if ( !defined $offset && @$ids ) {
            $offset = scalar @stream;
            die "diagnostic metadata ID table exceeds U32 offsets\n"
              if $offset > 0xFFFFFFFF || @$ids > 0xFFFFFFFF - $offset;
            push @stream, @$ids;
        }
        $offset = 0 unless @$ids;
        $spans{ $list->{diagnostic}{code} } = {
            offset => $offset,
            count  => scalar @$ids,
        };
    }

    return ( \@stream, \%spans );
}

# Pack raw inputs and per-diagnostic input-range lists without adding runtime
# indirection. IDs are used only while generating the two direct row streams.
sub collect_input_metadata {
    my ( $diag_table, $template_analysis ) = @_;

    my ( %input_pair_ids, @input_pairs, @input_lists, %parameter_input_keys );
    push @input_pairs, undef;
    my @ordered_diags = sort { $a->{number} <=> $b->{number} } @$diag_table;

    for my $diag (@ordered_diags) {
        my $layout = $template_analysis->{ $diag->{code} }{parameters};
        for my $parameter_index ( 0 .. $#{ $layout->{captured_params} } ) {
            my $param  = $layout->{captured_params}[$parameter_index];
            my @inputs = parameter_inputs($param);
            die "diagnostic $diag->{code} parameter $param->{name} has too many raw C inputs\n"
              if @inputs > 0xFF;

            my @ids = map {
                die "diagnostic $diag->{code} parameter $param->{name} input has no type\n"
                  unless defined $_->{type};
                intern_metadata_pair( \%input_pair_ids, \@input_pairs, [ $_->{name}, $_->{type} ], 'raw C input' );
            } @inputs;
            my $key = "$diag->{number}:$parameter_index";
            push @{ $parameter_input_keys{ $diag->{number} } ||= [] }, $key;
            push @input_lists,
              {
                diagnostic => {
                    code   => $key,
                    number => $diag->{number} * 256 + $parameter_index,
                },
                ids => \@ids,
              };
        }
    }

    my ( $input_ids, $input_spans ) = pack_metadata_id_sequences( \@input_lists );
    my @input_metadata = (undef);
    push @input_metadata, $input_pairs[$_] for @$input_ids[ 1 .. $#$input_ids ];

    my ( %range_pair_ids, @range_pairs, @range_lists );
    push @range_pairs, undef;
    for my $diag (@ordered_diags) {
        my @range_ids;
        for my $key ( @{ $parameter_input_keys{ $diag->{number} } || [] } ) {
            my $span = $input_spans->{$key};
            my $id   = intern_metadata_pair(
                \%range_pair_ids, \@range_pairs,
                [ $span->{offset}, $span->{count} ],
                'diagnostic input range'
            );
            push @range_ids, $id;
        }
        push @range_lists, { diagnostic => $diag, ids => \@range_ids };
    }

    my ( $range_ids, $range_spans ) = pack_metadata_id_sequences( \@range_lists );
    my @input_ranges = (undef);
    push @input_ranges, $range_pairs[$_] for @$range_ids[ 1 .. $#$range_ids ];
    return ( \@input_metadata, \@input_ranges, $range_spans );
}

# Keep explicit parents and inherited capabilities beside the catalog metadata.
# Runtime class creation must not infer ancestry from package name spelling.
sub write_class_registry {
    my ( $out, $class_model ) = @_;

    print {$out} "static const struct {\n"
      . "    const char *name;\n"
      . "    const char *parent;\n"
      . "    bool leaf_only;\n"
      . "    U16 warning_category_plus_one; /* 0: no category; WARN_ALL + 1 is valid. */\n"
      . "} perl_diag_class_registry[] = {\n";

    my @rows = map {
        [
            c_quote( $_->[0] ), defined $_->[1] ? c_quote( $_->[1] ) : 'NULL',
            $_->[2] ? 'TRUE' : 'FALSE', defined $_->[3] ? $_->[3] . ' + 1' : 0
        ]
    } @{ Diag::Classes::runtime_registry_rows($class_model) };
    print {$out} render_struct_rows( \@rows );
    print {$out} "};\n\n";
}

# Emit shared name/type pairs, packed parameter lists and diagnostic metadata.
sub write_metadata_table {
    my ( $data_out, $diag_table, $diag_index, $template_analysis, $class_model ) = @_;

    my ( $param_pairs,    $param_lists )       = collect_parameter_metadata( $diag_table, $template_analysis );
    my ( $param_ids,      $diagnostic_params ) = pack_metadata_id_sequences($param_lists);
    my ( $input_metadata, $input_ranges, $diagnostic_input_offsets ) =
      collect_input_metadata( $diag_table, $template_analysis );
    print {$data_out} "static const perl_diag_param_metadata_t perl_diag_param_metadata[] = {\n";
    my @param_rows = (
        [ 'NULL', 'NULL' ],
        map {
            [ map { c_quote($_) } @$_ ]
        } @$param_pairs[ 1 .. $#$param_pairs ]
    );
    print {$data_out} render_struct_rows( \@param_rows, { 0 => 'index 0 means no parameter metadata' } );
    print {$data_out} "};\n\n";

    print {$data_out} "static const U16 perl_diag_param_ids[] = {\n"
      . "    /* index 0 means no parameter metadata */\n"
      . "       0,\n";
    print {$data_out} wrap_initializer_values( [ map { sprintf '%4u', $_ } @$param_ids[ 1 .. $#$param_ids ] ] );
    print {$data_out} "};\n\n";

    print {$data_out} "static const perl_diag_input_metadata_t perl_diag_input_metadata[] = {\n";
    my @input_rows = (
        [ 'NULL', 'NULL' ],
        map {
            [ map { c_quote($_) } @$_ ]
        } @$input_metadata[ 1 .. $#$input_metadata ]
    );
    print {$data_out} render_struct_rows( \@input_rows, { 0 => 'index 0 means no raw C input metadata' } );
    print {$data_out} "};\n\n";

    print {$data_out} "static const perl_diag_param_input_range_t perl_diag_param_input_ranges[] = {\n";
    my @input_range_rows = ( [ 0, 0 ], @$input_ranges[ 1 .. $#$input_ranges ] );
    print {$data_out} render_struct_rows( \@input_range_rows, { 0 => 'index 0 means no parameter input metadata' } );
    print {$data_out} "};\n\n";

    print {$data_out} "static const perl_diag_metadata_t perl_diag_metadata[] = {\n";
    my @metadata_rows = ( [ 'NULL', 0, 'NULL', 'NULL', 'FALSE', 0, 0, 0, 'FALSE', 'FALSE',
        'NULL', 'NULL', 'NULL', 'NULL', 'NULL', 'NULL', 'FALSE', 'FALSE' ] );

    for my $i ( 0 .. $#$diag_table ) {
        my $diag   = $diag_table->[$i];
        my $params = $diagnostic_params->{ $diag->{code} };
        my $classification = $class_model->{by_code}{ $diag->{code} };
        my $dynamic_category =
          $classification->{category_policy} =~ /\Aruntime category;/ ? 'TRUE' : 'FALSE';
        push @metadata_rows,
          [
            c_quote( $diag->{code} ),
            $diag->{number},
            c_quote( $diag->{kind} ),
            c_quote( $diag->{severity} ),
            $diag->{counts_as_error} ? 'TRUE' : 'FALSE',
            $params->{offset},
            $params->{count},
            $diagnostic_input_offsets->{ $diag->{code} }{offset},
            $diag->{has_following_hint} ? 'TRUE' : 'FALSE',
            $diag->{is_hint}            ? 'TRUE' : 'FALSE',
            c_quote( $classification->{proposed_class} ),
            c_quote( $classification->{allowed_class} ),
            c_quote( $classification->{category_policy} ),
            c_quote( $classification->{role} ),
            c_quote( $classification->{grouping_role} ),
            c_quote( $classification->{review_status} ),
            $classification->{leaf_only} eq 'yes' ? 'TRUE' : 'FALSE',
            $dynamic_category
          ];
    }

    print {$data_out} render_struct_rows(
        \@metadata_rows,
        { 0 => 'index 0 means no catalog entry' }
    );

    print {$data_out} "};\n\n";
}

# Wrap flat initializer lists without altering their value order or padding.
sub wrap_initializer_values {
    my ($values) = @_;

    return '' unless @$values;
    local $Text::Wrap::columns  = 100;
    local $Text::Wrap::unexpand = 0;
    my $text = Text::Wrap::wrap( '    ', '    ', join( ', ', @$values ) );
    $text =~ s/[ \t]+$//mg;
    return $text . ",\n";
}

# Classify a column as numeric only when all its nonempty cells are numbers.
sub numeric_columns {
    my ($rows) = @_;

    return [] unless @$rows;
    my @numeric = (1) x @{ $rows->[0] };
    my @seen    = (0) x @numeric;
    for my $row (@$rows) {
        die "inconsistent generated column count\n" unless @$row == @numeric;
        for my $column ( 0 .. $#$row ) {
            next unless length $row->[$column];
            $seen[$column]    = 1;
            $numeric[$column] = 0 unless $row->[$column] =~ /\A-?(?:[0-9]+|0[xX][0-9a-fA-F]+),?\z/;
        }
    }
    return [ map { $numeric[$_] && $seen[$_] } 0 .. $#numeric ];
}

# Format prepared C tokens to the longest rendered cell in each column.
# Numeric columns align right; text columns align left. Inter-column spacing
# and a single pre-brace space keep rows compact as catalogs change.
sub format_column_rows {
    my ( $rows, $options ) = @_;

    $options ||= {};
    my $numeric = numeric_columns($rows);
    my @widths  = (0) x @$numeric;
    for my $row (@$rows) {
        my @included    = grep { !$options->{omit_empty} || length( $row->[$_] ) } 0 .. $#$row;
        my $last_column = $included[-1];
        for my $column (@included) {
            next if $options->{omit_empty} && $column == $last_column && !$numeric->[$column];
            $widths[$column] = length( $row->[$column] )
              if length( $row->[$column] ) > $widths[$column];
        }
    }
    my $prefix    = defined( $options->{prefix} ) ? $options->{prefix} : '    ';
    my $suffix    = $options->{suffix}    || '';
    my $separator = $options->{separator} || '';
    my $text      = '';
    for my $index ( 0 .. $#$rows ) {
        my $row = $rows->[$index];
        my @columns;
        my @included    = grep { !$options->{omit_empty} || length( $row->[$_] ) } 0 .. $#$row;
        my $last_column = $included[-1];
        for my $column (@included) {
            my $value = $row->[$column];
            if ( $options->{unpad_last} && $column == $#$row ) {
                push @columns, $value;
                next;
            }
            my $width = $widths[$column];
            if ( $column == $last_column ) {
                if ( length $suffix ) {
                    push @columns, $numeric->[$column]
                      ? sprintf( '%*s ',  $width, $value )
                      : sprintf( '%-*s ', $width, $value );
                }
                else {
                    push @columns, $numeric->[$column] ? sprintf( '%*s', $width, $value ) : $value;
                }
                next;
            }
            $width += $numeric->[$column] ? 2 : 1;
            push @columns, $numeric->[$column]
              ? sprintf( '%*s  ', $width - 2, $value )
              : sprintf( '%-*s',  $width,     $value );
        }
        my $comments = $options->{comments};
        my $comment  = $comments && exists $comments->{$index} ? " /* $comments->{$index} */" : '';
        if ( $index == 0 && length($comment) ) {
            $text .= "    /* $comments->{$index} */\n";
            $comment = '';
        }
        my $line = $prefix . join( $separator, @columns ) . $suffix . $comment;
        $line =~ s/ +\z//;
        $text .= "$line\n";
    }
    return $text;
}

# Align declaration assignments without padding the literal before its semicolon.
sub render_constant_definitions {
    my ($rows) = @_;

    return format_column_rows( $rows, { prefix => '', separator => '= ', suffix => ';', unpad_last => 1 } );
}

# Keep commas attached to initializer cells while their rows are aligned.
sub render_struct_rows {
    my ( $rows, $comments ) = @_;

    my @tokens = map {
        my $row = $_;
        [ map { $row->[$_] . ( $_ < $#$row ? ',' : '' ) } 0 .. $#$row ]
    } @$rows;
    return format_column_rows( \@tokens, { prefix => '    { ', suffix => '},', comments => $comments } );
}

# Align explicit enum assignments while retaining implicit increments.
sub render_enum_rows {
    my ($rows) = @_;

    my @tokens = map {
        my ( $name, $value ) = @$_;
        [ $name . ( length($value) ? '' : ',' ), length($value) ? "$value," : '' ]
    } @$rows;
    return format_column_rows( \@tokens, { separator => '= ', omit_empty => 1 } );
}

# Emit already-resolved word values and packed identity maps for one language.
# Equal text shares the ordinary text pool. Equal maps and contained spans use
# the same packing routine as parameter metadata, independently per language.
sub write_word_tables {
    my ( $out, $language, $model, $diagnostics, $text_names ) = @_;
    my $data = $model->{languages}{$language};
    return {} unless $data && keys %{ $data->{bindings} };
    my $values_name = "perl_diag_word_values_$language";
    my $map_name    = "perl_diag_word_map_$language";
    my @values = map { [ defined $_->{text} ? $text_names->{ $_->{text} } : 'NULL', 'UINT64_C(0x' . $_->{key} . ')' ] }
      @{ $data->{values} };
    print {$out} "static const perl_diag_word_value_t $values_name\[\] = {\n",
      render_struct_rows(
        \@values,
        { 0 => 'unavailable translation', 1 => 'preserve the supplied display value' }
      ),
      "};\n\n";
    my @lists;

    for my $diag (@$diagnostics) {
        my $bindings = $data->{bindings}{ $diag->{code} } || [];
        for my $index ( 0 .. $#$bindings ) {
            push @lists,
              {
                diagnostic => { code => "$diag->{code}_$index", number => $diag->{number} * 256 + $index },
                ids        => $bindings->[$index]{map},
              };
        }
    }
    my ( $stream, $spans ) = pack_metadata_id_sequences( \@lists );
    print {$out} "static const U16 $map_name\[\] = {\n",
      wrap_initializer_values( [ map { sprintf '%4d', $_ } @$stream ] ), "};\n\n";
    my ( %result, %interned );
    for my $diag (@$diagnostics) {
        my $bindings = $data->{bindings}{ $diag->{code} } || [];
        next unless @$bindings;
        my @rows;
        for my $index ( 0 .. $#$bindings ) {
            my $binding = $bindings->[$index];
            my $span    = $spans->{"$diag->{code}_$index"};
            push @rows,
              [
                @{$binding}{qw(source target numeric assert_unknown)}, $span->{count},
                "$map_name + $span->{offset}",                         $values_name,
                'UINT64_C(0x' . $binding->{mask} . ')'
              ];
        }
        my $signature = join '', map {
            join '',
              map { pack 'N/a*', $_ }
              @$_
        } @rows;
        my $name = $interned{$signature};
        unless ( defined $name ) {
            $name = "perl_diag_word_bindings_${language}_$diag->{number}";
            $interned{$signature} = $name;
            print {$out} "static const perl_diag_word_binding_t $name\[\] = {\n",
              render_struct_rows( \@rows ), "};\n\n";
        }
        $result{ $diag->{code} } = [ scalar @$bindings, $name ];
    }
    return \%result;
}

# Emit selector definitions and positional templates for one language.
sub write_language_tables {
    my ( $data_out, $diag_table, $diag_index, $language, $selector_layouts,
        $selector_definitions, $template_names, $template_analysis, $schema_registry )
      = @_;

    my ( @case_rows, @offset_rows );
    my %template_rows;
    my @projection_lists;
    my $projection_case_index = 0;
    for my $diag ( sort { $a->{number} <=> $b->{number} } @$diag_table ) {
        my $cases = $diag->{dynamic} ? [] : $template_analysis->{ $diag->{code} }{cases}{$language} || [];
        my $diag_case_index = 0;
        for my $case ( Diag::Migration::ordered_selector_cases( $diag, $cases ) ) {
            my ( undef, $source_indices ) = Diag::Migration::template_case_parameter_layout(
                $diag, $case->{template} );
            my $key = $diag->{code} . ':' . $diag_case_index++;
            push @projection_lists, {
                diagnostic => { code => $key,
                    number => $projection_case_index },
                ids => $source_indices,
            };
            $projection_case_index++;
        }
    }
    my ( $projection_stream, $projection_spans ) =
      pack_metadata_id_sequences( \@projection_lists );
    print {$data_out} "static const U8 perl_diag_template_argument_indices_$language\[\] = {\n"
      . "    /* offset 0 means no display arguments */\n"
      . "    0,\n"
      . wrap_initializer_values( [ map { sprintf '%3u', $_ } @$projection_stream[ 1 .. $#$projection_stream ] ] )
      . "};\n\n";
    my ( $previous_start, $previous_count );
    my $end_offset = template_end_name($language);

    for my $diag ( sort { $a->{number} <=> $b->{number} } @$diag_table ) {
        my $analysis = $template_analysis->{ $diag->{code} };
        my $cases =
          $diag->{dynamic}
          ? []
          : $analysis->{cases}{$language} || [];
        my @selectors = @{ $diag->{message_selectors} || [] };
        die "diagnostic $diag->{code} has more than seven selectors\n"
          if @selectors > 7;
        my $first_case    = 'perl_diag_template_no_template';
        my $selector_data = @$cases ? $selector_definitions->{ $diag->{code} } : 'NULL';
        my $layout        = $selector_layouts->{ $diag->{code} };
        my $selector_ids  = @$cases ? $layout->{ids} : [];

        if (@$cases) {
            $first_case = template_start_name( $language, $diag->{number} );
            my $assignment =
                !defined($previous_start) ? '1'
              : $previous_count == 1      ? ''
              :                             "$previous_start + $previous_count";
            push @offset_rows, [ $first_case, $assignment ];
            ( $previous_start, $previous_count ) = ( $first_case, scalar @$cases );
        }

        my $parameter_layout = $analysis->{parameters};
        my $projection_prefix = $diag->{code} . ':';
        my @diag_rows = language_case_rows(
            $diag, $cases, $selector_ids, $template_names,
            $projection_spans, $projection_prefix );
        push @case_rows, @diag_rows;
        $template_rows{ $diag->{code} } = [
            scalar(@selectors),
            $parameter_layout->{stored_count},
            $diag->{operation_words} ? 'perl_diag_word_group_' . $diag->{number} : 'perl_diag_word_group_none',
            $first_case, $selector_data
        ];
    }

    my $end_assignment =
        !defined($previous_start) ? '1'
      : $previous_count == 1      ? ''
      :                             "$previous_start + $previous_count";
    push @offset_rows, [ $end_offset, $end_assignment ];
    print {$data_out} "enum {\n", render_enum_rows( \@offset_rows ), "};\n\n";

    print {$data_out}
      "/* A plain 0 key means no selectors. In hexadecimal keys, zero\n",
      " * selector fields are wildcards; a wide field is tested as a whole.\n",
      " */\n";
    print {$data_out} "static const perl_diag_template_case_t perl_diag_template_cases_$language\[\] = {\n";

    my @rows = ( [ 0, 'UINT64_C(0)', 'NULL', 0, 0 ], @case_rows, [ 0, 'UINT64_C(0)', 'NULL', 0, 0 ] );
    align_selector_key_arguments( \@rows );
    print {$data_out} render_struct_rows(
        \@rows,
        { 0 => 'offset 0 means no template', $#rows => "terminates the last diagnostic's rows" }
    );

    print {$data_out} "};\n\n";

    print {$data_out} "static const perl_diag_template_t perl_diag_templates_$language\[\] = {\n";
    my @supplied = grep { @{ $template_analysis->{ $_->{code} }{cases}{$language} || [] }
                            && !$_->{dynamic} } sort { $a->{number} <=> $b->{number} } @$diag_table;
    my @template_rows = (
        [ 0, 0, 'perl_diag_word_group_none', 'perl_diag_template_no_template', 'NULL' ],
        map { $template_rows{ $_->{code} } } @supplied
    );
    print {$data_out} render_struct_rows(
        \@template_rows,
        { 0 => 'index 0 means no catalog entry' }
    );

    print {$data_out} "};\n\n";

    write_pack_schema_data( $data_out, \@supplied, $template_analysis, $schema_registry );
    my @schema_pointers = ( 'NULL', map { '&perl_diagpack_schema_' . $_->{number} } @supplied );
    print {$data_out} "static const perl_diagpack_schema_t * const perl_diagpack_schemas_$language\[\] = {\n",
      "    /* local schema row zero is unused */\n",
      wrap_initializer_values( \@schema_pointers ), "};\n\n";
}

# Rule bodies are C expressions over one local unsigned integer. Reject
# unknown categories and tokens before passing the expressions to the compiler.
sub validate_plural_expression {
    my ( $name, $expression ) = @_;
    die "invalid plural rule name '$name'\n"
      unless $name =~ /\A(?:cardinal|ordinal)_[A-Za-z0-9_]+\z/;
    die "invalid plural expression for $name\n"
      unless defined $expression && !ref($expression) && length $expression;

    my %category   = map { $_ => 1 } qw(zero one two few many other);
    my @categories = $expression =~ /"([^"]*)"/g;
    my $operators  = $expression;
    $operators =~ s/"[^"]*"//g;
    die "invalid plural expression for $name\n"
      unless @categories && !grep { !$category{$_} } @categories;
    die "invalid plural expression for $name\n"
      if $operators =~ /[^n0-9\s()?:<>=!&|%+*\/~-]/
      || grep { $_ ne 'n' } $operators =~ /([A-Za-z_][A-Za-z0-9_]*)/g;
}

# Declare only the grammatical categories returned by this expression.
# Diagnostic-specific exact counts and wildcard cases do not belong here.
sub validate_plural_rule {
    my ( $name, $rule ) = @_;
    die "invalid plural rule definition for $name\n"
      unless ref($rule) eq 'HASH'
      && ref( $rule->{forms} ) eq 'ARRAY'
      && !grep { $_ ne 'forms' && $_ ne 'expression' } keys %$rule;
    validate_plural_expression( $name, $rule->{expression} );
    my %used = map { $_ => 1 } $rule->{expression} =~ /"([^"]*)"/g;
    my %declared;
    for my $form ( @{ $rule->{forms} } ) {
        die "invalid plural form declaration for $name\n"
          unless defined($form) && !ref($form) && $used{$form} && !$declared{$form}++;
    }
    die "plural forms do not match expression for $name\n"
      unless keys(%declared) == keys(%used);
}

# Resolve a language's explicit rule reference, keeping cardinal and ordinal
# registries distinct even when two expressions happen to be identical.
sub language_plural_rule {
    my ( $configuration, $rules, $language, $kind ) = @_;
    my $entry = $configuration->{$language};
    my $rule  = ref($entry) eq 'HASH' ? $entry->{ lc($kind) } : undef;
    die "language $language has no $kind plural rule in language configuration\n"
      unless defined $rule && !ref($rule);
    die "language $language references unknown $kind plural rule '$rule'\n"
      unless exists $rules->{$rule};
    die "language $language uses the wrong plural rule kind '$rule'\n"
      unless index( $rule, lc($kind) . '_' ) == 0;
    return $rule;
}

# Reuse the ordinary macro renderer, splitting ternary branches for readability.
sub render_plural_rule_macro {
    my ( $name, $expression ) = @_;
    local $Text::Wrap::columns = 100;
    local $Text::Wrap::huge    = 'overflow';
    $expression = join "\n", map { Text::Wrap::wrap( '', '', $_ ) } split /(?<=:) /, $expression;
    $expression =~ s/\n/ \\\n    /g;
    return render_macro_definition( $name, 'n', "($expression)" );
}

# Validate the rule registry and emit only the requested languages' rules,
# aliases and dispatch. The fixed C entry points pass local UV/U16 values.
sub write_plural_macros {
    my ( $out, $languages, $configuration, $rules ) = @_;
    die "catalog has no language configuration\n" unless ref($configuration) eq 'HASH';
    die "catalog has no plural rule registry\n"   unless ref($rules) eq 'HASH';

    my %emitted_languages = map { $_ => 1 } @$languages;
    my %required_rules;
    for my $kind (qw(CARDINAL ORDINAL)) {
        for my $language (@$languages) {
            $required_rules{ language_plural_rule( $configuration, $rules, $language, $kind ) } = 1;
        }
    }

    print {$out} "/* Integer rules reference CLDR 48. Macro arguments must be local variables. */\n";
    for my $rule ( sort keys %$rules ) {
        validate_plural_rule( $rule, $rules->{$rule} );
        next unless $required_rules{$rule};
        my $expression = $rules->{$rule}{expression};
        $expression =~ s/"(zero|one|two|few|many|other)"/'perl_diag_selector_plural_' . $1/ge;
        print {$out} render_plural_rule_macro( 'PERL_DIAG_PLURAL_' . uc($rule), $expression );
    }

    for my $kind (qw(CARDINAL ORDINAL)) {
        language_plural_rule( $configuration, $rules, $_, $kind ) for @$languages;
        for my $language ( sort keys %$configuration ) {
            die "invalid configured language '$language'\n"
              unless $language =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
            my $rule = language_plural_rule( $configuration, $rules, $language, $kind );
            next unless $emitted_languages{$language};
            print {$out} render_macro_definition( "PERL_DIAG_PLURAL_${kind}_$language",
                'n', 'PERL_DIAG_PLURAL_' . uc($rule) . '(n)' );
        }

        my @branches = map {
            my $language = $languages->[$_];
            "(language) == perl_diag_lang_$language ? PERL_DIAG_PLURAL_${kind}_$language(n) :"
        } 0 .. $#$languages;
        my $expression = '( ' . join( " \\\n      ", @branches, 'perl_diag_selector_invalid )' );
        print {$out} render_macro_definition( "PERL_DIAG_PLURAL_$kind", 'language, n', $expression );
    }
}

# Discover languages from their actual templates, as the runtime tables do.
sub catalog_languages {
    my ($diagnostics) = @_;
    my %languages;
    for my $diag (@$diagnostics) {
        $languages{$_} = 1 for keys %{ $diag->{message_template} || {} };
    }
    return sort keys %languages;
}

# Shared by core and XS catalog writers; core passes the global language ID,
# while a standalone pack uses its local ID 1.
sub render_pack_catalog_definition {
    my ( $language, $language_id, $catalog_name ) = @_;
    return "static const perl_diagpack_catalog $catalog_name = {\n"
      . "    " . c_quote($language) . ", $language_id,\n"
      . "    perl_diag_template_cases_$language, C_ARRAY_LENGTH(perl_diag_template_cases_$language),\n"
      . "    perl_diag_template_argument_indices_$language, C_ARRAY_LENGTH(perl_diag_template_argument_indices_$language),\n"
      . "    perl_diag_templates_$language, C_ARRAY_LENGTH(perl_diag_templates_$language),\n"
      . "    perl_diagpack_schemas_$language, perl_diagpack_param_schema_table, C_ARRAY_LENGTH(perl_diagpack_param_schema_table),\n"
      . "    perl_diagpack_operation_names, C_ARRAY_LENGTH(perl_diagpack_operation_names),\n"
      . "    perl_diag_word_groups_$language, C_ARRAY_LENGTH(perl_diag_word_groups_$language)\n"
      . "};\n";
}

# Record opcode meanings so registration can check a pack's native IDs.
sub write_pack_operation_names {
    my ( $out, $names ) = @_;
    print {$out} "static const char * const perl_diagpack_operation_names\[\] = {\n",
      wrap_initializer_values( [ map { c_quote($_) } @$names ] ), "};\n\n";
}

# Share parameter pairs and packed lists across this output's row schemas.
sub write_pack_schema_data {
    my ( $out, $diag_table, $template_analysis, $registry ) = @_;
    return if $registry->{written}++;
    my ( $pairs, $lists ) = collect_parameter_metadata( $diag_table, $template_analysis );
    my ( $ids,   $spans ) = pack_metadata_id_sequences($lists);
    my @pair_rows = ( [ 'NULL', 'NULL' ], map { [ c_quote( $_->[0] ), c_quote( $_->[1] ) ] } @$pairs[ 1 .. $#$pairs ] );
    print {$out} "static const perl_diagpack_param_schema_t perl_diagpack_param_schema_table\[\] = {\n",
      render_struct_rows( \@pair_rows ), "};\n\n";
    print {$out} "static const U16 perl_diagpack_param_schema_ids\[\] = {\n    0,\n",
      wrap_initializer_values( [ map { sprintf '%4u', $_ } @$ids[ 1 .. $#$ids ] ] ), "};\n\n";
    for my $diag ( sort { $a->{number} <=> $b->{number} } @$diag_table ) {
        my $span = $spans->{ $diag->{code} };
        print {$out} "static const perl_diagpack_schema_t perl_diagpack_schema_$diag->{number} = {\n",
          "    $diag->{number}, ", c_quote( $diag->{code} ), ",\n",
          "    perl_diagpack_param_schema_ids + $span->{offset}, $span->{count}\n};\n\n";
    }
}

# Shared descriptor and plural-callback writer for built-in and XS engines.
sub render_pack_engine_definition {
    my ( $language, $catalog_name, $engine_name, $function_prefix ) = @_;
    my $id = lc $language;
    return "\nstatic U8\n${function_prefix}_${id}_cardinal(pTHX_ UV n)\n{\n"
      . "    PERL_UNUSED_CONTEXT;\n    PERL_UNUSED_ARG(n);\n"
      . "    return (U8)PERL_DIAG_PLURAL_CARDINAL_$id(n);\n}\n"
      . "\nstatic U8\n${function_prefix}_${id}_ordinal(pTHX_ UV n)\n{\n"
      . "    PERL_UNUSED_CONTEXT;\n    PERL_UNUSED_ARG(n);\n"
      . "    return (U8)PERL_DIAG_PLURAL_ORDINAL_$id(n);\n}\n"
      . "\nstatic const perl_diagpack_engine $engine_name = {\n"
      . "    PERL_DIAGPACK_ABI, sizeof(perl_diagpack_engine), " . c_quote($id) . ",\n"
      . "    &$catalog_name, Perl_diagpack_render_catalog,\n"
      . "    ${function_prefix}_${id}_cardinal, ${function_prefix}_${id}_ordinal\n"
      . "};\n";
}

# Render the metadata and language tables used by the runtime renderer.
sub render_data {
    my ( $diagnostics, $diag_table, $diag_index, $selector_layouts, $language_config, $plural_rules, $class_model ) =
      @_;

    my $template_analysis = build_template_analysis($diagnostics);
    my $word_catalog      = Diag::Words::catalog();
    my $word_operations   = Diag::Words::operation_names();
    my $text              = '';
    open my $data_out, '>', \$text or die "Cannot buffer diagnostic tables: $!\n";
    print {$data_out} 'STATIC_ASSERT_DECL(OP_max + 2 == ', scalar(@$word_operations) + 1,
      "); /* compiled operation-map bound */\n\n";

    # Optional catalogs are emitted only into their XS distributions.
    my @languages = ('en');
    my @language_ids =
      ( [ 'perl_diag_lang_none', 0 ], map { [ 'perl_diag_lang_' . $languages[$_], $_ + 1 ] } 0 .. $#languages );
    print {$data_out} "enum {\n", render_enum_rows( \@language_ids ), "};\n\n";
    my @word_diagnostics = grep { $_->{operation_words} } sort { $a->{number} <=> $b->{number} } @$diag_table;
    die "diagnostic word groups exceed U16 indexes\n" if @word_diagnostics > 65535;
    my @word_group_ids =
      ( [ 'perl_diag_word_group_none', 0 ], map { [ 'perl_diag_word_group_' . $_->{number}, '' ] } @word_diagnostics );
    print {$data_out} "enum {\n", render_enum_rows( \@word_group_ids ), "};\n\n";
    write_plural_macros( $data_out, \@languages, $language_config, $plural_rules );
    write_class_registry( $data_out, $class_model );
    write_metadata_table( $data_out, $diag_table, $diag_index, $template_analysis, $class_model );
    print {$data_out} "enum {\n", render_enum_rows( [ [ 'perl_diag_template_no_template', 0 ] ] ), "};\n\n";

    my %selector_layouts_by_language =
      map { $_ => build_language_selector_layouts( $diagnostics, $_, $selector_layouts, $word_catalog ) } @languages;
    my $compiled_words = Diag::Words::compile( $diagnostics, $word_catalog, \%selector_layouts_by_language );
    write_pack_operation_names( $data_out, $word_operations );
    my $schema_registry = {};
    write_pack_schema_data( $data_out, $diag_table, $template_analysis, $schema_registry );
    my $template_names    = write_template_texts( $data_out, $diagnostics, $template_analysis, $compiled_words, 'en' );
    my $selector_registry = new_selector_definition_registry($selector_layouts);

    for my $language (@languages) {
        my $language_layouts = $selector_layouts_by_language{$language};
        my $selector_definitions =
          write_selector_definitions( $data_out, $diagnostics, $language_layouts, $selector_registry, $language );
        my $word_bindings = write_word_tables( $data_out, $language, $compiled_words, $diag_table, $template_names );
        my @groups = ( [ 0, 'NULL' ], map { $word_bindings->{ $_->{code} } || [ 0, 'NULL' ] } @word_diagnostics );
        print {$data_out} "static const perl_diag_word_group_t perl_diag_word_groups_$language\[\] = {\n",
          render_struct_rows( \@groups, { 0 => 'no word bindings' } ), "};\n\n";
        write_language_tables(
            $data_out,             $diag_table,     $diag_index,        $language, $language_layouts,
            $selector_definitions, $template_names, $template_analysis, $schema_registry
        );
    }

    for my $language (@languages) {
        print {$data_out}
          render_pack_catalog_definition( $language, "perl_diag_lang_$language",
            "perl_diagpack_builtin_catalog_$language" ),
          render_pack_engine_definition(
            $language,
            "perl_diagpack_builtin_catalog_$language",
            "perl_diagpack_builtin_engine_$language",
            "Perl_diagpack_builtin"
          ),
          "\n";
    }
    write_selector_domain_table( $data_out, $selector_registry );

    print {$data_out} "static const perl_diagpack_engine * const perl_diagpack_builtin_engines[] = {\n";
    for my $language (@languages) {
        print {$data_out} "    &perl_diagpack_builtin_engine_$language,\n";
    }
    print {$data_out} "    NULL, /* terminates the language table */\n";
    print {$data_out} "};\n\n";

    close $data_out or die "Cannot close diagnostic tables buffer: $!\n";

    return $text;
}

# Shared C helpers

# Check the supported formatter, input count, and input types for one shared-helper parameter.
sub helper_parameter_eligible {
    my ($arg) = @_;

    return 0 if $arg->{literal_fragment};

    my $type        = $arg->{type}       || '';
    my $format      = $arg->{format_str} || '';
    my $pass        = $arg->{pass}       || '';
    my @inputs      = parameter_inputs($arg);
    my $input_count = @inputs;

    my $family = text_format_family($format);

    if ( $type ne 'text' ) {
        return
             scalar_parameter_format_supported( $type, $format )
          && !$pass
          && $input_count == 1;
    }

    if ( is_format_writer($pass) ) {
        return exists $arg->{inputs};
    }

    if ( $family eq 'sv' ) {
        return $pass eq 'SVfARG' && !exists $arg->{inputs};
    }

    if ( $family eq 'utf8' ) {
        my @input_types = map { $_->{type} || '' } @inputs;
        return $pass eq 'UTF8fARG' && join( ',', @input_types ) eq 'iv,uv,text';
    }

    if ( $family eq 'padname' ) {
        return $pass eq 'PNfARG' && !exists $arg->{inputs};
    }

    if ( $family eq 'hek' ) {
        return ( !$pass || $pass eq 'HEKfARG' || $pass eq 'HvNAME_HEK' )
          && $input_count == 1;
    }

    if ( $family eq 'hvname' ) {
        return 0 unless $input_count == 1;

        return $pass eq 'PERL_HvNAMEfARG_DEFAULT' && exists( $arg->{default} )
          if $format eq 'PERL_HvNAMEf_DEFAULT';

        return $pass eq 'HvNAMEfARG' && !exists $arg->{default};
    }

    my %input_counts = (
        s                => 1,
        '.*s'            => 2,
        '*.*s'           => 3,
        '.1s'            => 1,
        PVf_QUOTEDPREFIX => 1
    );

    return
         exists( $input_counts{$format} )
      && !$pass
      && $input_count == $input_counts{$format};
}

# Check whether a definition and its delivery inputs can use a shared C helper.
sub diag_helper_eligible {
    my ( $diag, $warning_categories ) = @_;

    my $api = $diag->{emit}{api} || '';

    return
      unless $api =~
/\A(?:CROAK|CROAK_NOCONTEXT|CROAK_CONTEXT|DIE|DIE_NOCONTEXT|WARN|WARN_CONTEXT|WARN_NOCONTEXT|WARNER|CK_WARNER|CK_WARNER_D|FATAL_WARNER|TAINT|APPEND_EXCEPTION|APPEND_WARNING)\z/;
    return
         if $diag->{dynamic}
      || $diag->{emit}{warn_once}
      || $diag->{emit}{regex_location};
    my @emit_params = @{ $diag->{emit}{params} || [] };

    if ( $api eq 'APPEND_EXCEPTION' || $api eq 'APPEND_WARNING' ) {
        return unless @emit_params >= 1
          && $emit_params[0]{name} eq 'exception_slot'
          && $emit_params[0]{type} eq 'ptr';
        return if $api eq 'APPEND_EXCEPTION' && @emit_params != 1;
        my @category_params = @emit_params > 1
          ? @emit_params[ 1 .. $#emit_params ]
          : ();
        return if @category_params > 1
          || ( @category_params
            && ( $category_params[0]{name} ne 'category'
              || $category_params[0]{type} ne 'uv' ) );
        my @categories = @{ $diag->{warning_categories} || [] };
        return
          if @categories > 4
          || grep { !$warning_categories->{$_} } @categories;
        return if $api eq 'APPEND_WARNING' && !@categories && !@category_params;
    }
    elsif (@emit_params) {
        return
             unless $api =~ /\A(?:WARNER|CK_WARNER|CK_WARNER_D|FATAL_WARNER)\z/
          && @emit_params == 1
          && $emit_params[0]{name} eq 'category'
          && $emit_params[0]{type} eq 'uv';
    }
    return
      if grep { Diag::Migration::variant_api( $diag, $_ ) ne $api } values %{ $diag->{variants} || {} };

    if ( $api =~ /\A(?:WARNER|CK_WARNER|CK_WARNER_D|FATAL_WARNER)\z/ ) {
        my @categories = @{ $diag->{warning_categories} || [] };
        return unless ( @categories && @categories <= 4 ) || @emit_params;
        return if grep { !$warning_categories->{$_} } @categories;
    }

    return if grep { !helper_parameter_eligible($_) } @{ $diag->{params} };

    return 1;
}

# Select the C input type expected by a parameter formatter.
sub helper_input_c_type {
    my ( $input, $arg, $input_index ) = @_;
    my $selector = selector_for_parameter($arg);
    return 'IV' if $selector && !$selector->{definition}{plural};

    my $format = $input_index == 2 && ( $arg->{pass} || '' ) eq 'UTF8fARG' ? '' : $arg->{format_str}
      || '';

    return 'int'             if $input_index == 0 && ( $arg->{pass} || '' ) eq 'UTF8fARG';
    return 'UV'              if $input_index == 1 && ( $arg->{pass} || '' ) eq 'UTF8fARG';
    return 'SV *'            if ( $arg->{pass} || '' ) eq 'SVfARG';
    return 'const PADNAME *' if ( $arg->{pass} || '' ) eq 'PNfARG';
    return 'HV *'
      if ( $arg->{pass} || '' ) eq 'HvNAME_HEK'
      || ( $arg->{pass} || '' ) =~ /\A(?:HvNAMEfARG|PERL_HvNAMEfARG_DEFAULT)/;
    return 'const HEK *'  if $format =~ /\AHEKf/;
    return 'NV'           if $input->{type} eq 'nv';
    return 'SV *'         if $input->{type} eq 'sv';
    return 'const void *' if $format eq 'p';
    my $scalar_type = scalar_format_c_type($format);
    return $scalar_type   if defined $scalar_type;
    return 'const char *' if $input->{type} eq 'text';
    return 'U32'          if $input->{type} eq 'uv';
    return 'int';
}

# Name helper inputs by formatter when a composed parameter has several inputs.
# A single input needs no suffix because its parameter position identifies it.
sub helper_input_name {
    my ( $arg_index, $arg, $input_index ) = @_;

    my @inputs = parameter_inputs($arg);
    my $name  = 'ma_arg' . $arg_index;

    return $name if @inputs == 1;

    if ( ( $arg->{pass} || '' ) eq 'UTF8fARG' ) {
        my @suffixes = qw(utf8_flag len pv);
        return $name . '_' . $suffixes[$input_index];
    }

    my $formatter = $arg->{pass} || 'sv_setpvf';
    $formatter =~ s/[^A-Za-z0-9_]/_/g;

    return $name . '_' . $formatter . '_' . ( $input_index + 1 );
}

# Build normalized C arguments so helpers can be shared across diagnostic definitions.
sub helper_signature {
    my ($diag) = @_;

    my $api = $diag->{emit}{api};
    ( my $api_family = $api ) =~ s/_CONTEXT\z//;
    my @formal;
    push @formal, 'SV **' . generated_c_name('exception_slot')
      if $api eq 'APPEND_EXCEPTION' || $api eq 'APPEND_WARNING';

    for my $i ( 0 .. $#{ $diag->{params} } ) {
        my $arg    = $diag->{params}[$i];
        my $n      = $i + 1;
        my @inputs = parameter_inputs($arg);
        push @formal, 'const char *ma_fmt' . $n
          if helper_uses_format_parameter($arg);
        for my $j ( 0 .. $#inputs ) {
            my $name = helper_input_name( $i + 1, $arg, $j );
            my $type = helper_input_c_type( $inputs[$j], $arg, $j );
            push @formal, $type . ( $type =~ /\*\z/ ? '' : ' ' ) . $name;
        }
        push @formal, 'const char *ma_default' . $n if exists $arg->{default};
    }
    push @formal, 'U32 ' . generated_c_name('category')
      if $api_family =~ /\A(?:WARNER|CK_WARNER|CK_WARNER_D|FATAL_WARNER)\z/;
    push @formal, 'U32 ' . generated_c_name('category')
      if ( $api eq 'APPEND_EXCEPTION' || $api eq 'APPEND_WARNING' )
      && ( @{ $diag->{warning_categories} || [] }
        || grep { $_->{name} eq 'category' } @{ $diag->{emit}{params} || [] } );

    return join( ",\n    ", 'UV ' . generated_c_name('diagnostic_index'), @formal );
}

# Format one composed parameter into the shared carrier arrays, preserving UTF-8 flags.
sub write_helper_parameter {
    my ( $fh, $arg, $i, $parameter_layout ) = @_;

    my $n                       = $i + 1;
    my @inputs                  = map { helper_input_name( $n, $arg, $_ ) }
      0 .. scalar( parameter_inputs($arg) ) - 1;
    my $format_var = helper_uses_format_parameter($arg) ? 'ma_fmt' . $n : undef;
    my $default_argument = 'scratch_default_arg' . $n;
    my $format                  = $arg->{format_str};
    my $pass                    = $arg->{pass} || '';
    my $formatted_into_template = 0;
    my ( $template_format, $template_values );
    my $diagnostic_index = $parameter_layout->{diagnostic_indices}{ $arg->{name} };
    my $params         = generated_c_name('params');
    my $setup_param    = generated_c_function('setup_param');
    my $diag_index     = generated_c_name('diagnostic_index');

    my $selector = selector_for_parameter($arg);
    if ( $selector && !$selector->{definition}{plural} ) {
        my $domain = $selector->{domain};
        my $domain_id = selector_domain_id_name( $domain->{owner_number}, $domain->{owner_column} );
        my $selector_id = $inputs[0];
        my $selector_value = $selector_id;
        my $setup_call = "$setup_param(aTHX_ $params, $diag_index, $diagnostic_index,\n"
          . "        $domain_id, $selector_value)";
        print {$fh} "    $setup_call;\n";
        return;
    }

    if (my $native_kind = native_capture_kind($arg)) {
        my $parameter_value = "tmpl_arg$n";
        my $setter = $native_kind eq 'uv' ? 'sv_setuv' : 'sv_setiv';
        print {$fh} "    SV * const $parameter_value = $setup_param(aTHX_ $params, $diag_index, $diagnostic_index,\n"
          . "        0, perl_diag_selector_invalid);\n"
          . "    $setter($parameter_value, $inputs[0]);\n";
        return;
    }

    if ( is_format_writer($pass) ) {
        my $parameter_value = "tmpl_arg$n";
        my ( $writer_call, $utf8_input ) = parameter_writer_expression( $arg, $parameter_value, \@inputs, $format_var );

        print {$fh} "    SV * const $parameter_value = $setup_param(aTHX_ $params, $diag_index, $diagnostic_index,\n"
          . "        0, perl_diag_selector_invalid);\n"
          . "    $writer_call;\n";

        print {$fh} "    if ($utf8_input) SvUTF8_on($parameter_value);\n"
          if defined $utf8_input;
        $formatted_into_template = 1;
    }
    else {
        ( $template_format, $template_values ) =
          parameter_formatting( $arg, \@inputs,
            {
                shared_helper   => 1,
                default         => "ma_default$n",
                default_argument => $default_argument,
                format_var      => $format_var
            } );
    }

    unless ($formatted_into_template) {
        my $parameter_value = "tmpl_arg$n";
        print {$fh} "    SV * const $parameter_value = $setup_param(aTHX_ $params, $diag_index, $diagnostic_index,\n"
          . "        0, perl_diag_selector_invalid);\n"
          . "    sv_setpvf($parameter_value, $template_format, $template_values);\n";
    }
}

# Emit the helper disposition after its parameters and optional message are ready.
sub write_helper_delivery {
    my ( $fh, $diag, $params, $message ) = @_;

    my $api = $diag->{emit}{api};
    my $category_name = generated_c_name('category');
    my $exception_slot = generated_c_name('exception_slot');
    my $diag_index = generated_c_name('diagnostic_index');
    my $append = generated_c_function('append');

    if ( my $delivery = ordinary_delivery_definition( $api, 1 ) ) {
        my $function = $delivery->{sv_function};
        my $context  = $delivery->{context};

        print {$fh} "    $function($context" . "$diag_index, $params, $message);\n";
        print {$fh} "    NORETURN_FUNCTION_END;\n" if $delivery->{noreturn};
    }
    elsif ( $api eq 'TAINT' ) {
        print {$fh} "    if (PL_unsafe || TAINT_WARN_get) {\n"
          . "        " . generated_c_function('taint_warner_d_sv') . "(aTHX_ $diag_index, $params, packWARN(WARN_TAINT), $message);\n"
          . "    }\n"
          . "    else {\n"
          . "        " . generated_c_function('croak_sv') . "(aTHX_ $diag_index, $params, $message);\n"
          . "    }\n";
    }
    elsif ( $api eq 'APPEND_EXCEPTION' || $api eq 'APPEND_WARNING' ) {
        my $dynamic_category = grep { $_->{name} eq 'category' }
          @{ $diag->{emit}{params} || [] };
        my $category = $dynamic_category
          ? $category_name
          : @{ $diag->{warning_categories} || [] } ? $category_name : '0';
        print {$fh}
          "    $append(aTHX_ $exception_slot, $message, $diag_index, $params, $category);\n";
    }
    else {
        my $function = warning_delivery_sv_function($api);
        print {$fh} "    $function(aTHX_ $diag_index, $params, $category_name, $message);\n";
    }
}

# Assemble a normalized shared helper body before assigning its deduplicated name.
sub render_diag_helper {
    my ($diag) = @_;

    my $out = '';
    open my $fh, '>', \$out or die "Cannot buffer diagnostic helper: $!\n";
    my $api              = $diag->{emit}{api};
    my $parameter_layout = Diag::Migration::template_parameter_layout($diag);
    my $signature        = helper_signature($diag);
    my $no_context       = $api =~ /_NOCONTEXT\z/;
    my $return_type      = 'void';
    my $inline =
      $api =~ /\A(?:CROAK(?:_NOCONTEXT|_CONTEXT)?|DIE(?:_NOCONTEXT)?)\z/
      ? 'PERL_STATIC_INLINE_NO_RET'
      : 'PERL_STATIC_INLINE';
    my $noreturn =
      $api =~ /\A(?:CROAK(?:_NOCONTEXT|_CONTEXT)?|DIE(?:_NOCONTEXT)?)\z/
      ? ' __attribute__noreturn__'
      : '';
    my $context = $no_context ? '' : 'pTHX_ ';
    my $diag_index = generated_c_name('diagnostic_index');
    my $params_name = generated_c_name('params');

    $_ and $_ .= " " for $noreturn, $inline;

    print {$fh} "${noreturn}${inline}${return_type}\nDIAG_HELPER_NAME(${context}$signature)\n{\n";

    for my $i ( 0 .. $#{ $diag->{params} } ) {
        my $arg = $diag->{params}[$i];
        next unless ( $arg->{pass} || '' ) eq 'PERL_HvNAMEfARG_DEFAULT';
        my $input = helper_input_name( $i + 1, $arg, 0 );
        print {$fh} "    const perl_hvname_default scratch_default_arg" . ( $i + 1 )
          . " = { $input, ma_default" . ( $i + 1 ) . " };\n";
    }

    print {$fh} "    dTHX;\n" if $no_context;

    if ( $api eq 'APPEND_WARNING'
        && !grep { $_->{name} eq 'category' }
        @{ $diag->{emit}{params} || [] } )
    {
        my @categories = @{ $diag->{warning_categories} };
        my $category   = packed_warning_categories( \@categories );
        print {$fh} "    if (!Perl_ckwarn(aTHX_ $category))\n        return;\n";
    }

    if ( $parameter_layout->{has_param_values} ) {
        print {$fh} "    AV *$params_name = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));\n";
    }
    print {$fh} "\n"
      if $parameter_layout->{has_param_values};

    for my $i ( 0 .. $#{ $diag->{params} } ) {
        print {$fh} "\n" if $i;
        write_helper_parameter( $fh, $diag->{params}[$i], $i, $parameter_layout );
    }

    my $params        = $parameter_layout->{has_param_values} ? $params_name : 'NULL';
    write_helper_delivery( $fh, $diag, $params, 'NULL' );

    print {$fh} "}\n\n";
    close $fh or die "Cannot close diagnostic helper buffer: $!\n";
    $out =~ s/\n{3,}/\n\n/g;
    return $out;
}

# Collect eligible helper definitions without rendering or assigning names.
sub collect_helper_candidates {
    my ( $diagnostics, $warning_categories ) = @_;

    my @candidates;

    for my $diag (@$diagnostics) {
        my @aliases = @{ $diag->{emit}{aliases} || [] };
        next if @aliases && keys %{ $diag->{variants} || {} };
        my @helper_specs =
          map { [ $_, undef ] } ( $diag->{emit}{api}, @aliases );
        if ( my $macro = $diag->{emit}{accumulate_macro} ) {
            my @append_params = ( { name => 'exception_slot', type => 'ptr' } );
            push @append_params,
              { name => 'category', type => 'uv' }
              if grep { $_->{name} eq 'category' }
              @{ $diag->{emit}{params} || [] };
            my $candidate = {
                %$diag,
                emit => {
                    %{ $diag->{emit} },
                    api     => 'APPEND_WARNING',
                    params  => \@append_params,
                    aliases => [],
                },
            };
            push @helper_specs, [ 'APPEND_WARNING', $candidate, $macro ];
        }
        for my $spec (@helper_specs) {
            my ( $api, $candidate, $macro ) = @$spec;
            $candidate ||= { %$diag, emit => { %{ $diag->{emit} }, api => $api, aliases => [] }, };
            if ( !diag_helper_eligible( $candidate, $warning_categories ) ) {
                die "diagnostic $diag->{code} cannot generate its append-warning helper\n"
                  if $macro;
                next;
            }
            push @candidates,
              {
                diagnostic => $diag,
                api        => $api,
                definition => $candidate,
              };
        }
    }

    @candidates = sort { $a->{diagnostic}{number} <=> $b->{diagnostic}{number} || $a->{api} cmp $b->{api} } @candidates;

    return \@candidates;
}

# Register one rendered body and return its shared helper name.
sub register_helper_candidate {
    my ( $candidate, $helpers, $body_names, $name_keys ) = @_;

    my $definition   = $candidate->{definition};
    my $body         = render_diag_helper($definition);
    my $api          = $candidate->{api};
    my $diag         = $candidate->{diagnostic};
    my $parameter_layout = Diag::Migration::template_parameter_layout($definition);
    my $input_arg_count    = scalar @{ $definition->{params} };
    my $dedupe_key   = $body;
    my $helper_name  = $body_names->{$dedupe_key};

    if ( !defined $helper_name ) {
        $helper_name = 'Perl_throw_' . lc($api)
          . "_${input_arg_count}_$diag->{number}";
        my $existing_key = $name_keys->{$helper_name};
        die "diagnostic $diag->{code} needs multiple helpers named $helper_name\n"
          if defined($existing_key) && $existing_key ne $dedupe_key;

        ( my $named_body = $body ) =~ s/\bDIAG_HELPER_NAME\b/$helper_name/;
        $body_names->{$dedupe_key} = $helper_name;
        $name_keys->{$helper_name} = $dedupe_key;
        $helpers->{$helper_name}   = $named_body;
    }

    return $helper_name;
}

# Render eligible helper bodies once, then map diagnostics and APIs to them.
sub build_helpers {
    my ( $diagnostics, $warning_categories ) = @_;

    my $candidates = collect_helper_candidates( $diagnostics, $warning_categories );
    my ( %diag_helper, %body_names, %name_keys, %helpers );

    for my $candidate (@$candidates) {
        my $diag = $candidate->{diagnostic};
        my $api  = $candidate->{api};
        my $name = register_helper_candidate( $candidate, \%helpers, \%body_names, \%name_keys, );
        $diag_helper{"$diag->{code}\0$api"} = $name;
    }

    return { bodies => \%helpers, by_diagnostic => \%diag_helper };
}

# Dynamic operation names cross into numeric identity once, before capture.
# Rendering and matching can then use the same direct maps as numeric callers.
sub render_word_identity_helper {
    my $function = generated_c_function('word_operation_from_name');
    my $body     = <<'C';
/* Unknown names keep their supplied display text through identity zero. */
PERL_STATIC_INLINE UV
__WORD_OPERATION_FROM_NAME__(const char *name, STRLEN length)
{
    if (!name)
        return perl_diag_word_operation_none;
    for (UV index = 0; index < OP_max; index++) {
        if (strlen(PL_op_name[index]) == length
            && memEQ(name, PL_op_name[index], length))
            return PERL_DIAG_WORD_OPERATION(index);
    }
    return length == sizeof("do_block") - 1
        && memEQs(name, length, "do_block")
        ? perl_diag_word_operation_do_block : perl_diag_word_operation_none;
}

C
    $body =~ s/__WORD_OPERATION_FROM_NAME__/$function/g;
    return $body;
}

# Return shared C helpers in the stable output order.
sub render_helpers {
    my ($registry) = @_;

    return render_word_identity_helper()
      . join( '', map { $registry->{bodies}{$_} } sort keys %{ $registry->{bodies} } );
}

# Macro formats and capture

# Compile the English template into C format tokens and ordered value specifications.
sub compile_macro_format {
    my ( $diag, $emitter ) = @_;

    my $code    = $diag->{code};
    my @argspec = @{ $diag->{params} };
    my @value_args;
    my $format_expr;
    my $english_cases = Diag::Migration::template_cases( $diag, 'en' );
    my $format        = $english_cases->[0]{template};
    my %seen_any_case;
    for my $case (@$english_cases) {
        $seen_any_case{$1}++ while $case->{template} =~ /%\{([A-Za-z_]\w*)\}/g;
    }
    my %selector_inputs = map {
        my $definition = $_;
        ( $definition->{source} || $definition->{name} ) => 1
    } @{ $diag->{selector_definitions} || [] };
    $selector_inputs{$_} = 1 for @{ $diag->{message_selectors} || [] };
    my @pieces;
    while ( $format =~ /\G((?:%%|[^%])*?)(?:%\{([A-Za-z_]\w*)\}|\z)/gcs ) {
        my ( $text, $name ) = ( $1, $2 );
        my ($arg) =
          defined($name) ? grep { $_->{name} eq $name } @argspec : ();
        die "diagnostic $code references unknown argument $name\n"
          if defined($name) && !$arg;
        my $literal = $arg && $arg->{literal_fragment};
        $text =~ s/%%/%/g if $emitter eq 'YYERROR' && !@argspec;
        if ( length $text ) {
            $text .= '%' if defined($name) && !$literal;
            push @pieces, c_quote($text);
        }
        elsif ( defined($name) && !$literal ) {
            push @pieces, '"%"';
        }
        last unless defined $name;
        if ($literal) {
            push @pieces, $arg->{name};
            next;
        }
        push @value_args, $arg;
        my $formatter = $arg->{format_str} || 's';

        # printf conversion letters are part of the format string;
        # symbolic Perl format fragments (SVf, UVxf, ...) are C tokens.
        if ( $formatter =~ /\A$printf_formatter\z/ ) {
            push @pieces, '"' . $formatter . '"';
        }
        else {
            push @pieces, c_quote( $arg->{prefix} )
              if defined $arg->{prefix};
            push @pieces, $formatter;
        }
    }
    die "diagnostic $code has unused format argument\n"
      if grep {
             !$seen_any_case{ $_->{name} }
          && !$selector_inputs{ $_->{name} }
          && !$_->{internal}
          && !exists( $_->{selector_values} )
      } @argspec;
    $format_expr = @pieces ? join( ' ', @pieces ) : '""';
    return ( $format_expr, \@value_args );
}

# Emit literal pieces for allocation-free writers that supply their own values.
# The complete English template remains the source of grammar and punctuation.
sub write_format_macro_chunks {
    my ( $out, $diag ) = @_;

    my @parts = Diag::Migration::format_macro_chunks($diag);
    for my $index ( 0 .. $#parts ) {
        print {$out} "#define $diag->{emit}{format_macro}_TEXT_$index " . c_quote_utf8( $parts[$index] ) . "\n";
    }
    print {$out} "\n";
}

# Prepare macro inputs, formatted values, and optional public format definitions.
# Input arrays name raw C arguments.  ordered_parameters contains composed
# message parameters in template order.  The remaining fields are C source
# expressions, including comma-prefixed value and delivery argument lists.
sub prepare_macro_format {
    my ( $out, $diag ) = @_;

    my $code    = $diag->{code};
    my $emitter = $diag->{emit}{api} || 'DIE';
    my @argspec = @{ $diag->{params} };
    my ( $format_expr, $ordered_parameters ) = compile_macro_format( $diag, $emitter );
    my @ordered_parameters = @$ordered_parameters;
    my @message_inputs     = map {
        map { $_->{name} }
          parameter_inputs($_)
    } @argspec;
    my @delivery_inputs = map { $_->{name} } @{ $diag->{emit}{params} || [] };

    if ( $emitter eq 'APPEND_EXCEPTION' ) {
        die "diagnostic $code needs one exception_slot delivery parameter\n"
          unless @delivery_inputs == 1
          && $diag->{emit}{params}[0]{name} eq 'exception_slot'
          && $diag->{emit}{params}[0]{type} eq 'ptr';
    }
    my $macro_parameters = join( ', ',
        $emitter eq 'APPEND_EXCEPTION'
        ? ( @delivery_inputs, @message_inputs )
        : ( @message_inputs, @delivery_inputs ) );
    my @value_expressions = map {
        my @inputs = map { $_->{name} } parameter_inputs($_);
        parameter_pass_expression( $_, \@inputs )
    } @ordered_parameters;
    my $value_expressions    = @value_expressions ? ', ' . join( ', ', @value_expressions ) : '';
    my $delivery_expressions = @delivery_inputs   ? ', ' . join( ', ', @delivery_inputs )   : '';
    my $format_expression    = $format_expr;
    $format_expression = "ASSERT_IS_LITERAL($format_expression)"
      if grep { $_->{literal_fragment} } @argspec;

    if ( $diag->{emit}{interpreter_suffix} ) {
        $format_expression .= ' pTHX__FORMAT';
        $value_expressions .= ' pTHX__VALUE';
    }

    if ( defined $diag->{emit}{format_macro} ) {
        my $format_macro_format =
          defined $diag->{emit}{format_macro_format}
          ? c_quote( $diag->{emit}{format_macro_format} )
          : $format_expression;
        print {$out} "#define $diag->{emit}{format_macro} $format_macro_format\n\n";
        write_format_macro_chunks( $out, $diag )
          if $diag->{emit}{format_macro_chunks};
        $format_expression = $diag->{emit}{format_macro};
    }

    return {
        macro_parameters     => $macro_parameters,
        message_inputs       => \@message_inputs,
        delivery_inputs      => \@delivery_inputs,
        ordered_parameters   => \@ordered_parameters,
        format_expression    => $format_expression,
        value_expressions    => $value_expressions,
        delivery_expressions => $delivery_expressions,
    };
}

# Identify parameter formats that cannot use the inline structured capture path.
sub parameter_requires_legacy_format {
    my ($arg) = @_;

    return 1 if $arg->{literal_fragment};

    my $format = $arg->{format_str} || '';
    my $type   = $arg->{type};
    my $pass   = $arg->{pass} || '';
    my $family = text_format_family($format);

    if ($pass) {
        return 1 unless $type eq 'text';

        if ( is_format_writer($pass) ) {
            return !( $arg->{inputs} && @{ $arg->{inputs} } );
        }

        if ( $family eq 'utf8' && $pass eq 'UTF8fARG' ) {
            return 1 if !$arg->{inputs} || $arg->{default};
            my @types = map { $_->{type} } @{ $arg->{inputs} };

            return join( ',', @types ) ne 'iv,uv,text';
        }

        return 1 if $arg->{inputs} || $arg->{default};

        return 0 if $family eq 'sv'      && $pass eq 'SVfARG';
        return 0 if $family eq 'padname' && $pass eq 'PNfARG';
        return 0
          if $family eq 'hek'
          && $format ne 'HEKf256_QUOTEDPREFIX'
          && $pass eq 'HEKfARG';
        return 0 if $format eq 'HEKf' && $pass eq 'HvNAME_HEK';

        return 1;
    }

    return 0 if scalar_parameter_format_supported( $type, $format );
    return 1 unless $type eq 'text';
    return 0 if $format =~ /\A(?:s|\.\*s|\*s|\*\.\*s|\.1s)\z/;

    if ( $family eq 'pv'
        || ( $family eq 'hek' && $format ne 'HEKf256_QUOTEDPREFIX' ) )
    {
        return !!( $arg->{inputs} || $arg->{default} );
    }

    return 1;
}

# Choose capture and delivery modes before constructing the macro body.
# The returned flags describe the selected path.  The AV fields are C source
# expressions naming the generated parameter and formatting carriers.
sub plan_parameter_capture {
    my ( $diag, $emitter ) = @_;

    my $code           = $diag->{code};
    my @argspec        = @{ $diag->{params} };
    my $parser_capture = $emitter =~ /\AYYERROR(?:_PVN?)?\z/
      && !grep { !defined( $_->{format_str} ) || $_->{literal_fragment} } @argspec;
    my $simple_capture = ( !@argspec && !$diag->{emit}{interpreter_suffix} && !$diag->{emit}{expression} )
      || ( @argspec
        && !$diag->{emit}{interpreter_suffix}
        && !$diag->{emit}{expression}
        && !grep { parameter_requires_legacy_format($_) } @argspec );
    my $regex_template_capture = $simple_capture
      && $diag->{emit}{regex_location_template};
    my $checked_capture =
         $simple_capture
      && $emitter =~ /\ACK_WARNER(?:_D)?(?:_CONTEXT)?\z/
      && !$diag->{emit}{regex_location}
      && !$diag->{emit}{warn_once};
    my $runtime_capture = $simple_capture
      && ( $emitter =~
/\A(?:CROAK(?:_NOCONTEXT|_CONTEXT|_CALLER)?|DIE(?:_NOCONTEXT)?|TAINT|WARN(?:_CONTEXT|_NOCONTEXT)?|WARNER(?:_CONTEXT)?|DEFER_ERROR)\z/
      )
      && !$diag->{emit}{regex_location}
      && !$diag->{emit}{warn_once};
    my $regex_warning_capture =
         $simple_capture
      && $emitter =~ /\A(?:CK_WARNER(?:_D)?(?:_CONTEXT)?|WARNER_CONTEXT)\z/
      && $diag->{emit}{regex_location};
    $runtime_capture ||= $regex_template_capture;
    $runtime_capture = 1 if $emitter eq 'APPEND_EXCEPTION';
    $runtime_capture ||= $checked_capture;
    $runtime_capture ||= $regex_warning_capture;
    my $positional_args    = \@argspec;
    my $parameter_layout   = Diag::Migration::template_parameter_layout($diag);
    my $positional_capture = ( $runtime_capture || $parser_capture )
      && !grep { !defined( $_->{format_str} ) || $_->{literal_fragment} || $_->{format_str} eq 'VCATPVFN_FV_GF' }
      @$positional_args;
    my $direct_empty_croak = !@argspec
      && $emitter =~ /\ACROAK(?:_CONTEXT)?\z/;

    if ( @{ $diag->{message_selectors} || [] } ) {
        die "diagnostic $code has message selectors but cannot use positional capture\n"
          unless $positional_capture;
        $runtime_capture = 1;
    }
    my $parameter_av_expression = $parameter_layout->{has_param_values}
      ? generated_c_name('params')
      : 'NULL';
    return {
        parser                   => $parser_capture,
        runtime                  => $runtime_capture,
        checked                  => $checked_capture,
        positional               => $positional_capture,
        direct_empty_croak       => $direct_empty_croak,
        parameter_av_expression  => $parameter_av_expression,
    };
}

# Classify formatter inputs and choose a message variable that cannot shadow an input.
sub capture_input_layout {
    my ($diag) = @_;

    my $code        = $diag->{code};
    my @argspec     = @{ $diag->{params} };
    my @input_specs = map { parameter_inputs($_) } @argspec;
    my %sv_inputs   = map { $_->{name} => 1 }
      grep { ( $_->{pass} || '' ) eq 'SVfARG' } @argspec;
    my %hek_inputs = map { $_->{name} => 1 }
      grep {
             ( $_->{format_str} || '' ) =~ /\AHEKf(?:256|_QUOTEDPREFIX)?\z/
          && ( !$_->{pass} || $_->{pass} eq 'HEKfARG' )
      } @argspec;
    my %hvname_hek_inputs = map { $_->{name} => 1 }
      grep { ( $_->{pass} || '' ) eq 'HvNAME_HEK' } @argspec;
    my %utf8_length_inputs = map { $_->{inputs}[1]{name} => 1 }
      grep { ( $_->{pass} || '' ) eq 'UTF8fARG' } @argspec;
    my %input_formats = map { $_->{name} => $_->{format_str} }
      grep { !$_->{inputs} } @argspec;
    my %seen_input;
    die "diagnostic $code repeats a formatter input\n"
      if grep { $seen_input{ $_->{name} }++ } @input_specs;
    my $template_message_var = generated_c_name('message');

    return {
        inputs           => \@input_specs,
        message_variable => $template_message_var,
        kinds            => {
            sv          => \%sv_inputs,
            hek         => \%hek_inputs,
            hvname_hek  => \%hvname_hek_inputs,
            utf8_length => \%utf8_length_inputs,
            format      => \%input_formats
        },
    };
}

# Give generated C locals distinct namespaces for macro inputs, template
# values, and temporary state so names derived from one cannot collide with
# names derived from another.
sub captured_input_local {
    return 'in_' . $_[0];
}

sub template_value_local {
    return 'tmpl_' . $_[0];
}

sub temporary_local {
    return 'scratch_' . $_[0];
}

sub macro_argument_local {
    return 'ma_' . $_[0];
}

# Declare each macro input once with the C type required by its formatter.
sub captured_input_declaration {
    my ( $input, $kinds ) = @_;

    my $name        = $input->{name};
    my $selector = selector_for_parameter($input);
    return 'IV const ' . captured_input_local($name) . " = $name;"
      if $selector && !$selector->{definition}{plural};
    my $format      = $kinds->{format}{$name} || '';
    my $scalar_type = scalar_format_c_type($format);
    my ( $type, $cast );

    if ( $kinds->{sv}{$name} ) {
        $type = $cast = 'SV *';
    }
    elsif ( $kinds->{hvname_hek}{$name} ) {
        $type = $cast = 'HV *';
    }
    elsif ( $kinds->{hek}{$name} ) {
        $type = $cast = 'const HEK *';
    }
    elsif ( $input->{type} eq 'nv' ) {
        $type = 'NV';
    }
    elsif ( $kinds->{utf8_length}{$name} ) {
        $type = 'UV';
    }
    elsif ( $input->{type} eq 'sv' ) {
        $type = 'SV *';
    }
    elsif ( $format eq 'p' ) {
        $type = 'void *';
    }
    elsif ( $format eq 'PNf' ) {
        $type = 'const PADNAME *';
    }
    elsif ( defined $scalar_type ) {
        $type = $scalar_type;
    }
    else {
        my %input_types = ( text => 'const char *', uv => 'U32' );
        $type = $input_types{ $input->{type} } || 'int';
    }

    # Cast pointer inputs at the macro boundary.  Scalar inputs retain the
    # conversion performed by their local C declaration.
    if ( !defined $cast ) {
        $cast = 'void *'          if $format eq 'p';
        $cast = 'const PADNAME *' if !defined($cast) && $format eq 'PNf';
        $cast = 'const char *'    if !defined($cast) && $input->{type} eq 'text';
    }
    my $value = defined($cast) ? "($cast)($name)" : "($name)";
    return "$type const " . captured_input_local($name) . " = $value;";
}

# Convert one captured argument to the SV value stored in the diagnostic.
sub captured_parameter_value {
    my ( $arg, $input_kinds, $text_input ) = @_;

    my $name   = $arg->{name};
    my $pass   = $arg->{pass}       || '';
    my $format = $arg->{format_str} || '';

    my $selector = selector_for_parameter($arg);
    if ( $selector && !$selector->{definition}{plural} ) {
        return 'newSViv(' . captured_input_local($name) . ')';
    }

    return template_value_local($name) if is_format_writer($pass);
    return "newSVpvf(\"%c\", " . captured_input_local($name) . ")"
      if $arg->{type} eq 'char';
    return temporary_local($name . '_copy')
      if $pass eq 'SVfARG' || $pass eq 'UTF8fARG';
    return "newSVpvf(\"%\" HEKf, HEKfARG(HvNAME_HEK("
      . captured_input_local($name) . ")))"
      if $input_kinds->{hvname_hek}{$name};
    return 'newSVhek(' . captured_input_local($name) . ')'
      if $input_kinds->{hek}{$name};
    return 'newSVsv(' . captured_input_local($name) . ')'
      if $arg->{type} eq 'sv';
    return 'newSViv(' . captured_input_local($name) . ')'
      if $arg->{type} eq 'iv';
    return 'newSVuv(' . captured_input_local($name) . ')'
      if $arg->{type} eq 'uv';
    return 'newSVnv(' . captured_input_local($name) . ')'
      if $arg->{type} eq 'nv';
    return 'newSVuv(PTR2UV(' . captured_input_local($name) . '))'
      if $arg->{type} eq 'ptr';
    return 'newSVpvf("%.*s", '
      . captured_input_local($arg->{inputs}[0]{name}) . ', '
      . captured_input_local($text_input) . ')'
      if $format eq '.*s';
    return 'newSVpvf("%.*s", '
      . captured_input_local($arg->{inputs}[1]{name}) . ', '
      . captured_input_local($text_input) . ')'
      if $format eq '*.*s';
    return 'newSVpvf("%.1s", ' . captured_input_local($text_input) . ')'
      if $format eq '.1s';
    return 'newSVpvf("%" PNf, PNfARG('
      . captured_input_local($name) . '))' if $pass eq 'PNfARG';

    return 'newSVpv(' . captured_input_local($text_input) . ', 0)';
}

# Render the extra copy and UTF-8 flag operations for a composed argument.
sub captured_parameter_preparation {
    my ($arg) = @_;

    my @body;
    my $name = $arg->{name};
    my $pass = $arg->{pass} || '';

    if ( $pass eq 'SVfARG' ) {
        push @body, 'SV * const ' . temporary_local($name . '_copy')
          . ' = sv_2mortal(newSVsv(' . captured_input_local($name) . '));';
    }

    if ( $pass eq 'UTF8fARG' ) {
        my ( $utf8, $length, $text ) =
          map { captured_input_local($_->{name}) } @{ $arg->{inputs} };
        my $copy = temporary_local($name . '_copy');
        push @body, "SV * const $copy = sv_2mortal($text ? newSVpvn($text, (STRLEN)$length) : newSV(0));";
        push @body, "if ($utf8 && $text) SvUTF8_on($copy);";
    }

    return @body;
}

# Render one composed parameter, retaining formatter inputs and UTF-8 handling.
sub render_captured_parameter {
    my ( $arg, $catalog_metadata, $parameter_layout, $positional_capture,
        $input_kinds, $utf8_flag ) = @_;

    my @body;
    my $name       = $arg->{name};
    my $pass       = $arg->{pass} || '';
    my $text_input = $arg->{inputs} ? $arg->{inputs}[-1]{name} : $name;
    my $params_name = generated_c_name('params');

    push @body, captured_parameter_preparation($arg);

    my $selector = selector_for_parameter($arg);
    my $value = captured_parameter_value( $arg, $input_kinds, $text_input );

    if ( ( $arg->{pass} || '' ) eq 'PNfARG' ) {
        push @body, "SvUTF8_on($value);";
    }
    if ($positional_capture) {
        my $diagnostic_index = $parameter_layout->{diagnostic_indices}{$name};
        my $setup = generated_c_function('setup_param') . "(aTHX_ $params_name"
          . ", $catalog_metadata, "
          . "$diagnostic_index, "
          . join( ', ', @{ selector_setup_arguments( $arg,
                [ map { captured_input_local($_->{name}) } parameter_inputs($arg) ] ) } )
          . ')';
        my @inputs =
          map { captured_input_local($_->{name}) } parameter_inputs($arg);
        @inputs = map { temporary_local($_->{name} . '_copy') }
          parameter_inputs($arg)
          if ( $arg->{pass} || '' ) eq 'SVfARG';
        if ( ( $arg->{pass} || '' ) eq 'UTF8fARG' ) {
            my $text = captured_input_local($arg->{inputs}[-1]{name});
            $inputs[-1] = "($text ? SvPVX("
              . temporary_local($name . '_copy') . ') : NULL)';
        }
        my $parameter_value = template_value_local($name);
        if ( $selector && !$selector->{definition}{plural} ) {
            push @body, "$setup;";
        }
        elsif ( my $native_kind = native_capture_kind($arg) ) {
            my $setter = $native_kind eq 'uv' ? 'sv_setuv' : 'sv_setiv';
            push @body,
              "SV * const $parameter_value = $setup;",
              "$setter($parameter_value, " . captured_input_local($name) . ");";
        }
        elsif ( is_format_writer( $arg->{pass} ) ) {
            my ( $format, $values ) = parameter_formatting( $arg, \@inputs, {} );
            my @writer_inputs =
              map { captured_input_local($_->{name}) } parameter_inputs($arg);
            my ( $writer_call, $utf8_input ) = parameter_writer_expression( $arg, $parameter_value, \@writer_inputs );

            push @body,
              "SV * const $parameter_value = $setup;",
              "$writer_call;";

            push @body, "if ($utf8_input) SvUTF8_on($parameter_value);"
              if defined $utf8_input;
        }
        else {
            my ( $format, $values ) = parameter_formatting( $arg, \@inputs, {} );
            push @body,
              "",
              "SV * const $parameter_value = $setup;",
              "sv_setpvf($parameter_value, $format, $values);";
            push @body, "if ($utf8_flag & SVf_UTF8) SvUTF8_on($parameter_value);"
              if defined $utf8_flag && $arg->{type} eq 'text';
        }
    }
    else {
        if ( is_format_writer( $arg->{pass} ) ) {
            push @body, "SV * const $value = newSV(0);";
            my @writer_inputs =
              map { captured_input_local($_->{name}) } parameter_inputs($arg);
            my ( $writer_call, $utf8_input ) = parameter_writer_expression( $arg, $value, \@writer_inputs );

            push @body, "$writer_call;";
            push @body, "if ($utf8_input) SvUTF8_on($value);"
              if defined $utf8_input;
        }
        my $selector_args = selector_setup_arguments( $arg,
            [ map { captured_input_local($_->{name}) } parameter_inputs($arg) ] );
        push @body,
          'PERL_DIAG_PUSH_PARAM(' . $params_name . ', '
          . join( ', ', c_quote($name), c_quote( $arg->{type} ), $value,
                  $selector_args->[0] ) . ');';
    }
    return @body;
}

# Build declarations and composed parameter values before adding delivery logic.
sub render_capture_setup {
    my ( $diag, $capture, $layout ) = @_;

    my $emitter              = $diag->{emit}{api} || 'DIE';
    my $catalog_metadata     = diagnostic_enum_name( $diag->{code}, 'IDX' );
    my @argspec              = @{ $diag->{params} };
    my @delivery_params      = map { $_->{name} } @{ $diag->{emit}{params} || [] };
    my @input_specs          = @{ $layout->{inputs} };
    my $template_message_var = $layout->{message_variable};
    my $parameter_layout     = Diag::Migration::template_parameter_layout($diag);
    my $params_name          = generated_c_name('params');
    my $category_value_name  = generated_c_name('category_value');
    my $context_ptr_name     = generated_c_name('context_ptr');
    my $exception_slot_ptr_name = generated_c_name('exception_slot_ptr');
    my $parameter_av_expression = $parameter_layout->{has_param_values}
      ? $params_name
      : 'NULL';
    my ( $checked_capture, $positional_capture, $direct_empty_croak ) =
      @{$capture}{qw(checked positional direct_empty_croak)};

    my @body;
    push @body, 'dTHX;'
      if $emitter =~ /_NOCONTEXT\z/;

    if ($checked_capture) {
        my @categories = @{ $diag->{warning_categories} || [] };
        my $category;
        if (@categories) {
            $category = packed_warning_categories( \@categories );
        }
        else {
            push @body, 'U32 const ' . $category_value_name
              . " = ($delivery_params[0]);";
            $category = $category_value_name;
        }
        my $check = $emitter =~ /\ACK_WARNER_D/ ? 'Perl_ckwarn_d' : 'Perl_ckwarn';
        push @body, "if ($check(aTHX_ $category)) {";
    }

    if ( $emitter eq 'CROAK_CONTEXT' && @delivery_params ) {
        push @body, 'PerlInterpreter * const ' . $context_ptr_name
          . " = ($delivery_params[0]);";
        push @body, "dTHXa($context_ptr_name);";
    }

    if ( $emitter eq 'APPEND_EXCEPTION' ) {
        push @body, 'SV ** const ' . $exception_slot_ptr_name
          . " = (SV **)($delivery_params[0]);";
    }

    my $input_kinds = $layout->{kinds};
    push @body, captured_input_declaration( $_, $input_kinds ) for @input_specs;
    push @body, 'AV * const ' . $params_name
      . ' = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));'
      if $parameter_layout->{has_param_values};

    push @body, ''
      if $parameter_layout->{has_param_values};

    my ($utf8_flag) = map { $_->{name} eq 'flags' ? $_->{name} : () }
      @{ $diag->{emit}{params} || [] };
    if (defined $utf8_flag
        && grep { $_->{type} eq 'text' } @argspec)
    {
        $utf8_flag = temporary_local('utf8_flags');
        push @body, 'U32 const ' . $utf8_flag . ' = (flags);';
    }

    for my $i ( 0 .. $#argspec ) {
        push @body, '' if $i;
        my $arg = $argspec[$i];
        push @body, render_captured_parameter( $arg, $catalog_metadata,
            $parameter_layout, $positional_capture, $input_kinds, $utf8_flag );
    }

    if ( $positional_capture && !$direct_empty_croak
        && $emitter !~ /\A(?:YYERROR(?:_PV|_PVN)?|DEFER_ERROR)\z/ )
    {
        push @body, '' if @body;
        my $parser_needs_message = $emitter =~
          /\A(?:YYERROR(?:_PV|_PVN)?|DEFER_ERROR)\z/;
        if ($parser_needs_message) {
            push @body,
              "SV * const $template_message_var = "
              . generated_c_function('format_template') . "(aTHX_ $catalog_metadata, NULL, $parameter_av_expression);";
        }
        else {
            push @body, "SV * const $template_message_var = NULL;";
        }
    }

    return @body;
}

# Render the inline capture body and retain parameter setup for its delivery aliases.
# call is the complete C expression.  fatal and warning hold statement lists
# that aliases reuse, with matching printf values and the message SV name.
sub render_inline_capture {
    my ( $diag, $format, $capture, $warning_categories ) = @_;

    my $emitter    = $diag->{emit}{api} || 'DIE';
    my @value_args = @{ $format->{ordered_parameters} };
    my $cformat    = $format->{format_expression};

    my ( $runtime_capture, $checked_capture, $positional_capture, $direct_empty_croak ) =
      @{$capture}{qw(runtime checked positional direct_empty_croak)};

    my (
        @fatal_alias_setup, $fatal_alias_values, @warning_alias_setup, $warning_alias_values,
        $message_format,    $message_values,     $template_message_var
    );
    my $layout = capture_input_layout($diag);
    $template_message_var = $layout->{message_variable};
    my @body = render_capture_setup( $diag, $capture, $layout );

    my @capture_values = map {
        my @inputs = map { captured_input_local($_->{name}) } parameter_inputs($_);
        @inputs = map { temporary_local($_->{name} . '_copy') }
          parameter_inputs($_)
          if ( $_->{pass} || '' ) eq 'SVfARG';
        if ( ( $_->{pass} || '' ) eq 'UTF8fARG' ) {
            my $text = captured_input_local($_->{inputs}[-1]{name});
            $inputs[-1] = "($text ? SvPVX("
              . temporary_local($_->{name} . '_copy') . ') : NULL)';
        }
        $_->{pass}
          ? $_->{pass} . '(' . join( ', ', @inputs ) . ')'
          : join( ', ', @inputs )
    } @value_args;
    my $capture_values = @capture_values ? ', ' . join( ', ', @capture_values ) : '';
    $message_format = $positional_capture ? '"%" SVf' : $cformat;
    $message_values =
      $positional_capture
      ? ", SVfARG($template_message_var)"
      : $capture_values;

    if ( $emitter eq 'CROAK' ) {
        @fatal_alias_setup  = @body;
        $fatal_alias_values = $message_values;
    }

    if (   $runtime_capture
        && $emitter =~ /WARN/
        && @{ $diag->{warning_categories} || [] } )
    {
        @warning_alias_setup = @body;
        shift @warning_alias_setup if $checked_capture;
        $warning_alias_values = $message_values;
    }

    my $capture_call = captured_delivery_call(
        $diag, $capture,
        {
            variable        => $template_message_var,
            format          => $message_format,
            values          => $message_values,
            original_format => $cformat,
            original_values => $capture_values
        },
        $warning_categories
    );
    push @body, $capture_call . ';';
    push @body, '}' if $checked_capture;
    @body = indent_warning_guard( \@body ) if $checked_capture;

    my $call = $direct_empty_croak ? $capture_call : render_macro_block( \@body );

    return {
        call             => $call,
        fatal            => \@fatal_alias_setup,
        warning          => \@warning_alias_setup,
        fatal_values     => $fatal_alias_values,
        warning_values   => $warning_alias_values,
        message_format   => $message_format,
        message_variable => $template_message_var,
    };
}

# Ordinary delivery APIs differ in their function name and interpreter context.
# Context-free croak helpers already acquire a context before reaching delivery.
sub ordinary_delivery_definition {
    my ( $api, $shared_helper ) = @_;

    my %definitions = (
        DIE             => [ generated_c_function('die'),             'aTHX_ ', 1, generated_c_function('die_sv') ],
        DIE_NOCONTEXT   => [ generated_c_function('die_nocontext'),   '',       1, generated_c_function('die_nocontext_sv') ],
        CROAK           => [ generated_c_function('croak'),           'aTHX_ ', 1, generated_c_function('croak_sv') ],
        CROAK_CONTEXT   => [ generated_c_function('croak'),           'aTHX_ ', 1, generated_c_function('croak_sv') ],
        CROAK_NOCONTEXT => [ generated_c_function('croak_nocontext'), '',       1, generated_c_function('croak_nocontext_sv') ],
        CROAK_CALLER    => [ generated_c_function('croak_caller'),    '',       1, generated_c_function('croak_caller_sv') ],
        WARN            => [ generated_c_function('warn'),            'aTHX_ ', 0, generated_c_function('warn_sv') ],
        WARN_CONTEXT    => [ generated_c_function('warn'),            'aTHX_ ', 0, generated_c_function('warn_sv') ],
        WARN_NOCONTEXT  => [ generated_c_function('warn_nocontext'),  '',       0, generated_c_function('warn_nocontext_sv') ],
    );
    my $definition = $definitions{$api};

    return unless $definition;

    my ( $function, $context, $noreturn, $sv_function ) = @$definition;

    if ( $shared_helper && $api =~ /\ACROAK(?:_NOCONTEXT|_CONTEXT)?\z/ ) {
        $function = generated_c_function('croak');
        $sv_function = generated_c_function('croak_sv');
        $context  = 'aTHX_ ';
    }

    return {
        function => $function,
        sv_function => $sv_function,
        context  => $context,
        noreturn => $noreturn
    };
}

# Build the category expression once for every warning delivery context.
sub packed_warning_categories {
    my ($categories) = @_;

    return '0' unless @$categories;

    return 'packWARN' . ( @$categories == 1 ? '' : scalar @$categories ) . '(' . join( ', ', @$categories ) . ')';
}

# Resolve categorized warning APIs, including their explicit-context aliases.
sub warning_delivery_function {
    my ($api) = @_;

    return generated_c_function('ck_warner_d')  if $api =~ /\ACK_WARNER_D/;
    return generated_c_function('ck_warner')    if $api =~ /\ACK_WARNER/;
    return generated_c_function('fatal_warner') if $api =~ /\AFATAL_WARNER/;

    return generated_c_function('warner');
}

# Resolve the SV-taking equivalent for categorized warning delivery.
sub warning_delivery_sv_function {
    my ($api) = @_;

    return generated_c_function('ck_warner_d_sv') if $api =~ /\ACK_WARNER_D/;
    return generated_c_function('ck_warner_sv')   if $api =~ /\ACK_WARNER/;
    return generated_c_function('fatal_warner_sv') if $api =~ /\AFATAL_WARNER/;

    return generated_c_function('warner_sv');
}

# Keep macro continuation lines and body indentation consistent across emitters.
sub render_macro_definition {
    my ( $name, $parameters, $expression, $prefixed_parameters ) = @_;

    my @parameters = map { s/\A\s+|\s+\z//gr } split /,/, $parameters;
    my %to_prefix = map { $_ => 1 } @{ $prefixed_parameters || [] };
    my %renamed = map { $_ => macro_argument_local($_) }
      grep { length && $to_prefix{$_} } @parameters;
    if (%renamed) {
        my @parts = split /("(?:\\.|[^"\\])*")/, $expression, -1;
        for my $i ( 0 .. $#parts ) {
            next if $parts[$i] =~ /\A"/;
            for my $parameter ( sort { length($b) <=> length($a) } keys %renamed ) {
                $parts[$i] =~ s/(?<![A-Za-z0-9_])\Q$parameter\E(?![A-Za-z0-9_])/$renamed{$parameter}/g;
            }
        }
        $expression = join '', @parts;
    }
    $parameters = join ', ', map { length ? ( $renamed{$_} || $_ ) : $_ } @parameters;

    return "#define $name($parameters) \\\n    $expression\n\n";
}

# Statements already contain their terminators and any nested indentation.
sub render_macro_block {
    my ($statements) = @_;
    my @folded_statements;

    for my $statement (@$statements) {
        next if $statement =~ /\A\s*\z/
          && @folded_statements
          && $folded_statements[-1] =~ /\A\s*\z/;
        push @folded_statements, $statement;
    }
    $statements = \@folded_statements;

    return "STMT_START { \\\n        " . join( " \\\n        ", @$statements ) . " \\\n    } STMT_END";
}

# Keep warning guards at their enclosing indentation, indenting their contents.
sub indent_warning_guard {
    my ($statements) = @_;
    my $category_value = generated_c_name('category_value');
    my $category_value_re = quotemeta($category_value);

    return map {
        /\A(?:if \(Perl_ckwarn|U32 const $category_value_re)|\A\}\z/
          ? $_
          : "    $_"
    } @$statements;
}

# Diagnostic delivery

# Add configured parser recovery or abort control after a diagnostic call.
sub parser_action_call {
    my ( $action, $call ) = @_;
    return $call
      if !defined($action) || $action eq 'collect' || $action eq 'caller';
    my $control = $action eq 'recover' ? 'YYERROR' : 'yyquit()';
    return render_macro_block( [ "$call;", "$control;" ] );
}

# Select warning or fatal taint delivery while retaining diagnostic metadata.
sub taint_call {
    my ( $diag, $values, $params_ref, $message_sv ) = @_;
    $params_ref ||= 'NULL';
    my $metadata = diagnostic_enum_name( $diag->{code}, 'IDX' );
    my ( $warning, $fatal );

    if ($message_sv) {
        $warning =
          generated_c_function('taint_warner_d_sv') . "(aTHX_ $metadata, $params_ref, packWARN(WARN_TAINT), $message_sv)";
        $fatal = generated_c_function('croak_sv') . "(aTHX_ $metadata, $params_ref, $message_sv)";
    }
    else {
        $warning = generated_c_function('ck_warner_d') . "(aTHX_ $metadata, $params_ref, packWARN(WARN_TAINT), $values)";
        $fatal   = generated_c_function('croak') . "(aTHX_ $metadata, $params_ref, $values)";
    }

    return render_macro_block( [ 'if (PL_unsafe || TAINT_WARN_get)', "    $warning;", 'else', "    $fatal;", ] );
}

# Build warning delivery from named formatting, category, and location options.
sub warning_call {
    my ( $diag, $options ) = @_;

    my ( $emitter, $format, $values, $params_ref, $category_override, $message_sv, $warning_categories )
      = @{$options}{
        qw(api format values params category message warning_categories)
      };
    $params_ref ||= 'NULL';
    my @categories = @{ $diag->{warning_categories} || [] };
    my @delivery   = grep { ( $_->{role} || '' ) ne 'regex_location' } @{ $diag->{emit}{params} || [] };
    my @locations  = grep { ( $_->{role} || '' ) eq 'regex_location' } @{ $diag->{emit}{params} || [] };
    die "diagnostic $diag->{code} renders its regex location without a location argument\n"
      if $diag->{emit}{regex_location_template} && !$diag->{emit}{regex_location};
    die "diagnostic $diag->{code} needs one regex location parameter\n"
      if $diag->{emit}{regex_location}
      && ( @locations != 1 || $locations[0]{type} ne 'ptr' );
    die "diagnostic $diag->{code} needs static categories or one runtime category\n"
      unless ( @categories && @categories <= 4 && !@delivery )
      || ( !@categories && @delivery == 1 && $delivery[0]{type} eq 'uv' );
    die "diagnostic $diag->{code} has an unknown warning category\n"
      if grep { !$warning_categories->{$_} } @categories;
    my $category = $category_override
      || (
        @categories
        ? packed_warning_categories( \@categories )
        : $delivery[0]{name}
      );

    if ( $diag->{emit}{regex_location}
        && !$diag->{emit}{regex_location_template} ) {
        $format .= ' REPORT_LOCATION';
        $values .= ", REPORT_LOCATION_ARGS($locations[0]{name})";
    }
    my $api      = warning_delivery_function($emitter);
    my $metadata = diagnostic_enum_name( $diag->{code}, 'IDX' );
    my $call;
    if ($diag->{emit}{regex_location}
        && !$diag->{emit}{regex_location_template}
        && $api =~ /\APerl_diag_(?:ck_)?warner(?:_d)?\z/) {
        my $location = $locations[0]{name};
        my $regex_api = $emitter =~ /\ACK_WARNER_D/
          ? generated_c_function('ck_warner_d_regex_sv')
          : $api eq generated_c_function('ck_warner')
          ? generated_c_function('ck_warner_regex_sv')
          : generated_c_function('warner_regex_sv');
        my $regex_message = $message_sv || 'NULL';
        $call = "$regex_api(aTHX_ $metadata, $params_ref, $category, $regex_message, UTF, "
          . "PERL_REPORT_LOCATION_BEFORE_LENGTH($location), sI, "
          . "PERL_REPORT_LOCATION_AFTER_LENGTH($location), "
          . "PERL_REPORT_LOCATION_AFTER_START($location))";
    }
    elsif ($message_sv) {
        my $function = $api eq generated_c_function('ck_warner_d')
          ? generated_c_function('ck_warner_d_sv')
          : $api eq generated_c_function('ck_warner')
          ? generated_c_function('ck_warner_sv')
          : $api . '_sv';
        $call = "$function(aTHX_ $metadata, $params_ref, $category, $message_sv)";
    }
    else {
        $call = "$api(aTHX_ $metadata, $params_ref, $category, $format$values)";
    }
    $call = "WARN_HELPER_($locations[0]{name}, $category, $call)"
      if $diag->{emit}{regex_location};

    if ( $diag->{emit}{warn_once} ) {
        my $once = $diag->{emit}{warn_once};
        die "diagnostic $diag->{code} has invalid warn-once state\n"
          unless $diag->{emit}{regex_location}
          && $warning_categories->{$once}
          && grep { $_ eq $once } @categories;
        $call = render_macro_block( [ "if (!RExC_warned_$once) {", "    RExC_warned_$once = 1;", "    $call;", '}', ] );
    }
    return $call;
}

# Select the disposition of a captured diagnostic without constructing its parameters.
sub captured_delivery_call {
    my ( $diag, $capture, $message, $warning_categories ) = @_;

    my $emitter          = $diag->{emit}{api} || 'DIE';
    my $catalog_metadata = diagnostic_enum_name( $diag->{code}, 'IDX' );
    my @delivery_params  = map { $_->{name} } @{ $diag->{emit}{params} || [] };
    my ( $parser_capture, $checked_capture, $positional_capture, $direct_empty_croak,
        $parameter_av_expression )
      = @{$capture}{
        qw(parser checked positional direct_empty_croak
          parameter_av_expression)
      };
    my ( $template_message_var, $message_format, $message_values, $cformat, $capture_values ) =
      @{$message}{qw(variable format values original_format original_values)};
    my $context_ptr_name = generated_c_name('context_ptr');
    my $exception_slot_ptr_name = generated_c_name('exception_slot_ptr');
    my $capture_call;

    if ($parser_capture) {
        my $flags = @delivery_params ? $delivery_params[0] : '0';
        $capture_call = parser_action_call( $diag->{parser_action},
            $positional_capture
            ? "Perl_yyerror_diag_pvn_params(aTHX_ $catalog_metadata, "
              . "NULL, 0, $flags, "
              . "$parameter_av_expression)"
            : "Perl_yyerror_diag_params(aTHX_ $catalog_metadata, "
              . "form($cformat$capture_values), $flags, $parameter_av_expression)" );
    }
    elsif ( $emitter eq 'DEFER_ERROR' ) {
        $capture_call = "Perl_defer_error_diag_params(aTHX_ "
          . (
              $positional_capture
            ? '&PL_sv_undef'
            : "mess($cformat$capture_values)"
          )
          . ", "
          . "$catalog_metadata, $parameter_av_expression, 0)";
    }
    elsif ( $emitter eq 'DIE' ) {
        my $delivery = ordinary_delivery_definition( $emitter, 0 );
        my ( $function, $context ) = @{$delivery}{qw(function context)};
        $capture_call =
          $positional_capture
          ? "${function}_sv($context$catalog_metadata, $parameter_av_expression, $template_message_var)"
          : "$function($context$catalog_metadata, $parameter_av_expression, $message_format$message_values)";
    }
    elsif ( $emitter eq 'DIE_NOCONTEXT' ) {
        my $delivery = ordinary_delivery_definition( $emitter, 0 );
        my ( $function, $context ) = @{$delivery}{qw(function context)};
        $capture_call =
          $positional_capture
          ? "${function}_sv($context$catalog_metadata, $parameter_av_expression, $template_message_var)"
          : "$function($context$catalog_metadata, $parameter_av_expression, $message_format$message_values)";
    }
    elsif ( $emitter eq 'CROAK_NOCONTEXT' ) {
        my $delivery = ordinary_delivery_definition( $emitter, 0 );
        my ( $function, $context ) = @{$delivery}{qw(function context)};
        $capture_call =
          $positional_capture
          ? "${function}_sv($context$catalog_metadata, $parameter_av_expression, $template_message_var)"
          : "$function($context$catalog_metadata, $parameter_av_expression, $message_format$message_values)";
    }
    elsif ( $emitter eq 'CROAK_CALLER' ) {
        my $delivery = ordinary_delivery_definition( $emitter, 0 );
        my ( $function, $context ) = @{$delivery}{qw(function context)};
        $capture_call =
          $positional_capture
          ? "${function}_sv($context$catalog_metadata, $parameter_av_expression, $template_message_var)"
          : "$function($context$catalog_metadata, $parameter_av_expression, $message_format$message_values)";
    }
    elsif ( $emitter eq 'CROAK_CONTEXT' ) {
        my $context = @delivery_params
          ? "$context_ptr_name, "
          : 'aTHX_ ';
        $capture_call =
            $direct_empty_croak ? generated_c_function('croak_sv') . "($context$catalog_metadata, NULL, NULL)"
          : $positional_capture
          ? generated_c_function('croak_sv') . "($context$catalog_metadata, $parameter_av_expression, $template_message_var)"
          : generated_c_function('croak') . "($context$catalog_metadata, " . "$parameter_av_expression, $message_format$message_values)";
    }
    elsif ( $emitter eq 'CROAK' ) {
        $capture_call =
            $direct_empty_croak ? generated_c_function('croak_sv') . "(aTHX_ $catalog_metadata, NULL, NULL)"
          : $positional_capture
          ? generated_c_function('croak_sv') . "(aTHX_ $catalog_metadata, $parameter_av_expression, $template_message_var)"
          : generated_c_function('croak') . "(aTHX_ $catalog_metadata, " . "$parameter_av_expression, $message_format$message_values)";
    }
    elsif ( $emitter eq 'APPEND_EXCEPTION' ) {
        my @categories = @{ $diag->{warning_categories} || [] };
        my $category =
          @categories
          ? packed_warning_categories( \@categories )
          : '0';
        $capture_call =
            generated_c_function('append') . "(aTHX_ $exception_slot_ptr_name, "
          . ( $positional_capture ? $template_message_var : '&PL_sv_undef' )
          . ", $catalog_metadata, $parameter_av_expression, $category)";
    }
    elsif ( $emitter eq 'WARN_NOCONTEXT' ) {
        my $delivery = ordinary_delivery_definition( $emitter, 0 );
        my ( $function, $context ) = @{$delivery}{qw(function context)};
        $capture_call =
          $positional_capture
          ? "${function}_sv($context$catalog_metadata, $parameter_av_expression, $template_message_var)"
          : "$function($context$catalog_metadata, $parameter_av_expression, $message_format$message_values)";
    }
    elsif ( $emitter eq 'WARN' || $emitter eq 'WARN_CONTEXT' ) {
        $capture_call =
          $positional_capture
          ? generated_c_function('warn_sv') . "(aTHX_ $catalog_metadata, $parameter_av_expression, $template_message_var)"
          : generated_c_function('warn') . "(aTHX_ $catalog_metadata, " . "$parameter_av_expression, $message_format$message_values)";
    }
    elsif ( $emitter eq 'TAINT' ) {
        $capture_call = taint_call(
            $diag, "$message_format$message_values",
            $parameter_av_expression,
            $positional_capture ? $template_message_var : undef
        );
    }
    else {
        $capture_call = warning_call(
            $diag,
            {
                api      => $emitter,
                format   => $message_format,
                values   => $message_values,
                params   => $parameter_av_expression,
                category => $checked_capture && !@{ $diag->{warning_categories} || [] }
                  ? generated_c_name('category_value')
                : undef,
                message => $positional_capture ? $template_message_var
                : undef,
                warning_categories => $warning_categories
            }
        );
    }
    return $capture_call;
}

# Select the legacy delivery call for definitions that cannot use a shared helper.
sub uncaptured_delivery_call {
    my ( $diag, $format, $warning_categories ) = @_;

    my $emitter          = $diag->{emit}{api} || 'DIE';
    my $catalog_metadata = diagnostic_enum_name( $diag->{code}, 'IDX' );
    my ( $cformat, $values, $call_values ) =
      @{$format}{qw(format_expression value_expressions delivery_expressions)};
    my @delivery_params = @{ $format->{delivery_inputs} };
    my $delivery        = ordinary_delivery_definition( $emitter, 0 );

    if ( $delivery && $emitter ne 'CROAK_CONTEXT' ) {
        my ( $function, $context ) = @{$delivery}{qw(function context)};
        return "$function($context$catalog_metadata, NULL, $cformat$values)";
    }

    if ( $emitter eq 'NOPERL_DIE' ) {
        return "Perl_noperl_die($cformat$values)";
    }

    if ( $emitter eq 'CROAK_CONTEXT' ) {
        my $context = @delivery_params ? "$delivery_params[0], " : 'aTHX_ ';
        return generated_c_function('croak') . "($context$catalog_metadata, NULL, $cformat$values)";
    }

    if ( $emitter eq 'APPEND_EXCEPTION' ) {
        return generated_c_function('append') . "(aTHX_ (SV **)($delivery_params[0]), &PL_sv_undef, $catalog_metadata, NULL, 0)";
    }

    if ( Diag::Migration::is_warning_emitter($emitter) ) {
        return warning_call(
            $diag,
            {
                api                => $emitter,
                format             => $cformat,
                values             => $values,
                warning_categories => $warning_categories,
            }
        );
    }
    return taint_call( $diag, "$cformat$values" ) if $emitter eq 'TAINT';

    if ( $emitter eq 'DEFER_ERROR' ) {
        return "Perl_defer_error_diag_params(aTHX_ mess($cformat$values), "
          . "$catalog_metadata, NULL, NULL, 0)";
    }

    if ( $emitter eq 'YYERROR' ) {
        my $message = @{ $format->{message_inputs} } ? "form($cformat$values)" : $cformat;
        return "Perl_yyerror_diag(aTHX_ $catalog_metadata, $message, 0)";
    }

    if ( $emitter eq 'YYERROR_PV' ) {
        return "Perl_yyerror_diag(aTHX_ $catalog_metadata, form($cformat$values)$call_values)";
    }
    return "yyerror_pvn(form($cformat$values), strlen(form($cformat$values))$call_values)";
}

# Emit delivery aliases using the same captured parameters as the primary macro.
sub write_delivery_aliases {
    my ( $out, $diag, $format, $capture, $setup, $warning_categories ) = @_;

    my $code             = $diag->{code};
    my $macro            = Diag::Migration::macro_name($diag);
    my $catalog_metadata = diagnostic_enum_name( $code, 'IDX' );
    my ( $params, $cformat, $values ) =
      @{$format}{qw(macro_parameters format_expression value_expressions)};
    my @args            = @{ $format->{message_inputs} };
    my @delivery_params = @{ $format->{delivery_inputs} };
    my ( $positional_capture, $parameter_av_expression ) =
      @{$capture}{qw(positional parameter_av_expression)};
    my @fatal_alias_setup   = @{ $setup->{fatal} };
    my @warning_alias_setup = @{ $setup->{warning} };
    my ( $fatal_alias_values, $warning_alias_values, $message_format, $template_message_var ) = @{$setup}{
        qw(fatal_values warning_values
          message_format message_variable)
    };

    for my $alias ( @{ $diag->{emit}{aliases} || [] } ) {
        die "diagnostic $code has an invalid alias $alias\n"
          unless $alias =~
/\A(?:DIE(?:_NOCONTEXT)?|CROAK(?:_NOCONTEXT|_CONTEXT|_CALLER)?|NOPERL_DIE|WARN(?:_CONTEXT|_NOCONTEXT)?|YYERROR(?:_PV|_PVN)?)\z/
          || Diag::Migration::is_warning_emitter($alias);
        my $alias_macro = Diag::Migration::alias_macro_name( $diag, $alias );
        if ( @fatal_alias_setup && $alias =~ /\A(?:DIE|CROAK_CONTEXT)\z/ ) {
            my @alias_body = @fatal_alias_setup;
            push @alias_body,
              $positional_capture
              ? (
                $alias eq 'DIE'
                ? generated_c_function('die_sv') . "(aTHX_ $catalog_metadata, $parameter_av_expression, $template_message_var);"
                : generated_c_function('croak_sv') . "(aTHX_ $catalog_metadata, $parameter_av_expression, $template_message_var);"
              )
              : (
                $alias eq 'DIE'
                ? generated_c_function('die') . "(aTHX_ $catalog_metadata, $parameter_av_expression, $message_format$fatal_alias_values);"
                : generated_c_function('croak') . "(aTHX_ $catalog_metadata, $parameter_av_expression, $message_format$fatal_alias_values);"
              );
            print {$out} render_macro_definition( $alias_macro, $params, render_macro_block( \@alias_body ), \@args );
            next;
        }
        if (   @warning_alias_setup
            && $alias =~ /\A(?:WARNER|FATAL_WARNER|CK_WARNER(?:_D)?)\z/ )
        {
            my @alias_body = @warning_alias_setup;
            my $checked    = $alias =~ /\ACK_WARNER/;
            if ($checked) {
                my @categories = @{ $diag->{warning_categories} };
                my $category   = packed_warning_categories( \@categories );
                my $check      = $alias eq 'CK_WARNER_D' ? 'Perl_ckwarn_d' : 'Perl_ckwarn';
                unshift @alias_body, "if ($check(aTHX_ $category)) {";
            }
            push @alias_body,
              warning_call(
                $diag,
                {
                    api      => $alias,
                    format   => $message_format,
                    values   => $warning_alias_values,
                    params   => $parameter_av_expression,
                    category => undef,
                    message  => $positional_capture ? $template_message_var
                    : undef,
                    warning_categories => $warning_categories
                }
              ) . ';';
            push @alias_body, '}' if $checked;
            @alias_body = indent_warning_guard( \@alias_body ) if $checked;

            print {$out} render_macro_definition( $alias_macro, $params, render_macro_block( \@alias_body ), \@args );
            next;
        }
        my $delivery = ordinary_delivery_definition( $alias, 0 );
        my $alias_call;

        if ( $delivery && $alias ne 'CROAK' ) {
            my ( $function, $context ) = @{$delivery}{qw(function context)};
            $alias_call = "$function($context$catalog_metadata, NULL, $cformat$values)";
        }
        elsif ( $alias eq 'NOPERL_DIE' ) {
            $alias_call = "Perl_noperl_die($cformat$values)";
        }
        elsif ( Diag::Migration::is_warning_emitter($alias) ) {
            $alias_call = warning_call(
                $diag,
                {
                    api                => $alias,
                    format             => $cformat,
                    values             => $values,
                    warning_categories => $warning_categories,
                }
            );
        }
        else {
            $alias_call = $macro . '(' . join( ', ', @args, @delivery_params ) . ')';
        }

        print {$out} render_macro_definition( $alias_macro, $params, $alias_call, \@args );
    }
}

# Generated macro interfaces

# Bind diagnostic metadata and names to a shared helper call.
sub render_helper_macro {
    my ( $diag, $macro, $helper, $api ) = @_;

    my @message_macro_parameters = map {
        map { $_->{name} }
          parameter_inputs($_)
    } @{ $diag->{params} };
    my @emit_macro_parameters =
      map { $_->{name} } @{ $diag->{emit}{params} || [] };
    my @macro_parameters =
      $api eq 'APPEND_EXCEPTION' || $api eq 'APPEND_WARNING'
      ? ( @emit_macro_parameters, @message_macro_parameters )
      : ( @message_macro_parameters, @emit_macro_parameters );
    my $no_context  = $api =~ /_NOCONTEXT\z/;
    my @helper_args = (
        $no_context
        ? diagnostic_enum_name( $diag->{code}, 'IDX' )
        : 'aTHX_ ' . diagnostic_enum_name( $diag->{code}, 'IDX' )
    );

    if ( $api eq 'APPEND_EXCEPTION' || $api eq 'APPEND_WARNING' ) {
        push @helper_args, '(SV **)(' . $diag->{emit}{params}[0]{name} . ')';
    }

    for my $arg ( @{ $diag->{params} } ) {
        if ( helper_uses_format_parameter($arg) ) {
            push @helper_args, parameter_printf_format($arg);
        }

        my $input_index = 0;
        my @arg_inputs  = map {
            my $name   = $_->{name};
            my $c_type = helper_input_c_type( $_, $arg, $input_index++ );
                $c_type eq 'SV *'         ? "(SV *)($name)"
              : $c_type eq 'const char *' ? "(const char *)($name)"
              : $name
        } parameter_inputs($arg);
        push @helper_args, @arg_inputs;
        push @helper_args, $arg->{default} if exists $arg->{default};
    }

    if ( ( $api eq 'APPEND_EXCEPTION' || $api eq 'APPEND_WARNING' )
        && grep { $_->{name} eq 'category' } @{ $diag->{emit}{params} || [] } )
    {
        push @helper_args, generated_c_name('category');
    }
    elsif ( ( $api eq 'APPEND_EXCEPTION' || $api eq 'APPEND_WARNING' )
        && @{ $diag->{warning_categories} || [] } ) {
        my @categories = @{ $diag->{warning_categories} };
        push @helper_args, packed_warning_categories( \@categories );
    }
    elsif ( $api =~ /\A(?:WARNER|CK_WARNER|CK_WARNER_D|FATAL_WARNER)\z/ ) {
        if ( @{ $diag->{emit}{params} || [] } ) {
            push @helper_args, map { $_->{name} } @{ $diag->{emit}{params} };
        }
        else {
            my @categories = @{ $diag->{warning_categories} };
            push @helper_args, packed_warning_categories( \@categories );
        }
    }

    my $expression = "$helper( \\\n" . '        ' . join( ", \\\n        ", @helper_args ) . " \\\n" . "    )";

    return render_macro_definition( $macro, join( ', ', @macro_parameters ), $expression,
        \@message_macro_parameters );
}

# Write shared helper calls when every delivery alias has a registered helper.
sub write_shared_helper_macros {
    my ( $out, $diag, $diag_helper ) = @_;

    my $code    = $diag->{code};
    my $emitter = $diag->{emit}{api} || 'DIE';
    my $macro   = Diag::Migration::macro_name($diag);
    my @aliases = @{ $diag->{emit}{aliases} || [] };
    my $helper  = $diag_helper->{"$code\0$emitter"};

    if ( $helper && !grep { !defined $diag_helper->{"$code\0$_"} } @aliases ) {
        print {$out} render_helper_macro( $diag, $macro, $helper, $emitter );
        for my $alias (@aliases) {
            my $alias_macro = Diag::Migration::alias_macro_name( $diag, $alias );
            print {$out} render_helper_macro( $diag, $alias_macro, $diag_helper->{"$code\0$alias"}, $alias );
        }
        if ( my $append_macro = $diag->{emit}{accumulate_macro} ) {
            my $append_helper = $diag_helper->{"$code\0APPEND_WARNING"};
            die "diagnostic $code has no generated append-warning helper\n"
              unless $append_helper;
            my $append_diag = {
                %$diag,
                emit => {
                    %{ $diag->{emit} },
                    api     => 'APPEND_WARNING',
                    params  => [
                        { name => 'exception_slot', type => 'ptr' },
                        ( grep { $_->{name} eq 'category' }
                              @{ $diag->{emit}{params} || [] }
                            ? ( { name => 'category', type => 'uv' } )
                            : () ),
                    ],
                    aliases => [],
                },
            };
            print {$out} render_helper_macro( $append_diag, $append_macro, $append_helper, 'APPEND_WARNING' );
        }
        return 1;
    }
    return 0;
}

# Emit opaque message adapters and their explicitly supported delivery aliases.
sub write_dynamic_macros {
    my ( $out, $diag, $warning_categories ) = @_;

    my $code             = $diag->{code};
    my $emitter          = $diag->{emit}{api} || 'DIE';
    my $macro            = Diag::Migration::macro_name($diag);
    my $catalog_metadata = diagnostic_enum_name( $code, 'IDX' );
    my @dynamic_args     = map { $_->{name} } @{ $diag->{params} };
    my @dynamic_call_args =
      map { $_->{name} } @{ $diag->{emit}{params} || [] };
    my $dynamic_values = join( ', ', @dynamic_args, @dynamic_call_args );
    die "diagnostic $code needs one format parameter for warning compatibility\n"
      if $diag->{dynamic} eq 'format'
      && Diag::Migration::is_warning_emitter($emitter)
      && ( @dynamic_args != 1
        || $diag->{params}[0]{type} ne 'text'
        || @dynamic_call_args );
    die "diagnostic $code uses an unsupported dynamic format delivery\n"
      if $diag->{dynamic} eq 'format'
      && $emitter ne 'TAINT'
      && $emitter ne 'CROAK_NOCONTEXT'
      && !Diag::Migration::is_warning_emitter($emitter);
    my $dynamic_call;

    if ( $diag->{dynamic} eq 'format' ) {
        if ( $emitter eq 'TAINT' ) {
            $dynamic_call = taint_call( $diag, $dynamic_values );
        }
        elsif ( Diag::Migration::is_warning_emitter($emitter) ) {
            $dynamic_call = warning_call(
                $diag,
                {
                    api                => $emitter,
                    format             => $dynamic_values,
                    values             => ', 0',
                    warning_categories => $warning_categories,
                }
            );
        }
        else {
            $dynamic_call = generated_c_function('croak_nocontext') . "($catalog_metadata, NULL, $dynamic_values)";
        }
    }
    elsif ( $diag->{dynamic} eq 'sv' ) {
        $dynamic_call = "croak_sv($dynamic_values)";
    }
    else {
        my $function = $emitter eq 'YYERROR'
          || $emitter eq 'YYERROR_PV' ? 'Perl_yyerror_diag' : 'Perl_yyerror_diag_pvn';
        my @delivery = $emitter eq 'YYERROR' ? ('0') : @dynamic_call_args;
        $dynamic_call = $function . '(aTHX_ ' . join( ', ', $catalog_metadata, @dynamic_args, @delivery ) . ')';
    }

    my $dynamic_params = join( ', ', @dynamic_args, @dynamic_call_args );

    print {$out}
      render_macro_definition( $macro, $dynamic_params,
        parser_action_call( $diag->{parser_action}, $dynamic_call ), \@dynamic_args );

    for my $alias ( @{ $diag->{emit}{aliases} || [] } ) {
        my $alias_macro = Diag::Migration::alias_macro_name( $diag, $alias );
        if (   $diag->{dynamic} eq 'sv'
            && $alias =~ /\A(?:DIE_SV|WARN_SV)\z/ )
        {
            print {$out} render_macro_definition( $alias_macro, $dynamic_params,
                lc($alias) . "($dynamic_values)", \@dynamic_args );
            next;
        }
        die "diagnostic $code has an unsupported dynamic alias\n"
          unless $diag->{dynamic} eq 'format'
          && Diag::Migration::is_warning_emitter($alias);
        my $alias_call = warning_call(
            $diag,
            {
                api                => $alias,
                format             => $dynamic_values,
                values             => ', 0',
                warning_categories => $warning_categories,
            }
        );

        print {$out} render_macro_definition( $alias_macro, $dynamic_params, $alias_call,
            \@dynamic_args );
    }
    return;
}

# Emit a diagnostic macro and its delivery aliases from one validated definition.
sub write_diagnostic_macros {
    my ( $out, $diag, $diag_helper, $warning_categories ) = @_;

    my $code    = $diag->{code};
    my $emitter = $diag->{emit}{api} || 'DIE';

    # Render-only catalog entries have no producer or exception record.
    if ( $emitter eq 'RENDER' ) {
        die "render-only diagnostic $code cannot have delivery aliases or variants\n"
          if @{ $diag->{emit}{aliases} || [] } || keys %{ $diag->{variants} || {} };
        if ( defined $diag->{emit}{format_macro} ) {
            die "render-only format macro $code cannot select template cases\n"
              if @{ $diag->{selector_definitions} || [] };
            prepare_macro_format( $out, $diag );
        }
        my $macro = Diag::Migration::macro_name($diag);
        print {$out} "#define $macro(language, values) " . "\\\n";
        print {$out} "    Perl_diag_render_format(aTHX_ ", diagnostic_enum_name( $code, 'IDX' ), ", (values), (language))\n\n";
        return;
    }
    die "diagnostic $code has an unknown emitter $emitter\n"
      unless $emitter =~ /\ADIE(?:_NOCONTEXT)?\z/
      || $emitter =~ /\ACROAK(?:_NOCONTEXT|_CONTEXT|_CALLER)?\z/
      || $emitter eq 'NOPERL_DIE'
      || $emitter eq 'APPEND_EXCEPTION'
      || $emitter eq 'DEFER_ERROR'
      || $emitter =~ /\AWARN(?:_CONTEXT|_NOCONTEXT)?\z/
      || $emitter eq 'TAINT'
      || Diag::Migration::is_warning_emitter($emitter)
      || $emitter =~ /\AYYERROR(?:_PV|_PVN)?\z/;
    my $macro = Diag::Migration::macro_name($diag);

    if ( $diag->{dynamic} ) {
        write_dynamic_macros( $out, $diag, $warning_categories );
        return;
    }
    my $format = prepare_macro_format( $out, $diag );
    return if write_shared_helper_macros( $out, $diag, $diag_helper );
    my $call = uncaptured_delivery_call( $diag, $format, $warning_categories );

    my $capture = plan_parameter_capture( $diag, $emitter );
    my $setup   = { fatal => [], warning => [] };

    if ( $capture->{parser} || $capture->{runtime} ) {
        $setup = render_inline_capture( $diag, $format, $capture, $warning_categories );
        $call  = $setup->{call};
    }

    my $params = $format->{macro_parameters};

    print {$out} render_macro_definition( $macro, $params,
        parser_action_call( $diag->{parser_action}, $call ), $format->{message_inputs} );

    write_delivery_aliases( $out, $diag, $format, $capture, $setup, $warning_categories );
}

# Bind configured fixed values while preserving the remaining macro inputs.
sub write_variant_macros {
    my ( $out, $diag ) = @_;

    for my $code ( sort keys %{ $diag->{variants} || {} } ) {
        my $variant = $diag->{variants}{$code};
        my ( @params, @message_params, @values );
        for my $param ( @{ $diag->{params} } ) {
            if ( exists $variant->{values}{ $param->{name} } ) {
                my $value = $variant->{values}{ $param->{name} }{en};
                my $selector = selector_for_parameter($param);
                if ( $selector && !$selector->{definition}{plural} ) {
                    my $symbol = $selector->{domain}{symbols}{$value};
                    die "diagnostic $diag->{code} variant $code has unknown selector value $value\n"
                      unless $symbol;
                    push @values, $symbol;
                }
                else {
                    push @values, c_quote($value);
                }
            }
            else {
                my @inputs =
                  map { $_->{name} } @{ $param->{inputs} || [$param] };
                push @params, @inputs;
                push @message_params, @inputs;
                push @values, @inputs;
            }
        }
        my @delivery = map { $_->{name} } @{ $diag->{emit}{params} || [] };
        push @params, @delivery;
        push @values, @delivery;
        my $api = Diag::Migration::variant_api( $diag, $variant );
        my $target =
          $api eq ( $diag->{emit}{api} || 'DIE' )
          ? Diag::Migration::macro_name($diag)
          : Diag::Migration::alias_macro_name( $diag, $api );
        my $macro = Diag::Migration::variant_macro_name( $diag, $code, $variant );
        my $call  = $target . '(' . join( ', ', @values ) . ')';
        print {$out} render_macro_definition(
            $macro,
            join( ', ', @params ),
            parser_action_call( $variant->{parser_action}, $call ),
            \@message_params
        );
    }
}

# Emit the shared wildcard/category IDs and one typed enum per ordered domain.
sub write_selector_domain_enums {
    my ( $out, $selector_layouts ) = @_;
    my %domains;
    for my $layout ( values %$selector_layouts ) {
        for my $column ( 0 .. $#{ $layout->{domains} || [] } ) {
            my $domain = $layout->{domains}[$column];
            next unless $domain->{domain_id};
            my $definition = $layout->{diagnostic}{selector_definitions}[$column] || {};
            next if $definition->{plural} || $definition->{operation_word};
            $domains{ $domain->{domain_id} } = $domain;
        }
    }

    my $category_id   = 0;
    my @category_rows = (
        [ 'perl_diag_selector_invalid',  -1 ],
        [ 'perl_diag_selector_wildcard', 0 ],
        map { [ 'perl_diag_selector_plural_' . $_, ++$category_id ] } qw(zero one two few many other)
    );
    print {$out} "\nenum perl_diag_selector_common_value {\n",
      render_enum_rows( \@category_rows ), "};\n\n";

    for my $domain_id ( sort { $a <=> $b } keys %domains ) {
        my $domain = $domains{$domain_id};
        my @rows   = map {
            my $value    = $domain->{values}[$_];
            my $position = $_ + 1;
            my $assignment =
              $position <= 6 && $value eq (qw(zero one two few many other))[ $position - 1 ]
              ? 'perl_diag_selector_plural_' . $value
              : $domain->{ids}{$value};
            [ $domain->{symbols}{$value}, $assignment ]
        } 0 .. $#{ $domain->{values} };
        my $tag  = selector_domain_name( $domain->{owner_number}, $domain->{owner_column} ) . '_values';
        my $type = selector_domain_name( $domain->{owner_number}, $domain->{owner_column} ) . '_t';
        print {$out} "typedef enum $tag {\n",
          render_enum_rows( \@rows ),
          "} $type;\n\n";
    }

    my @domain_rows = ( [ 'perl_diag_selector_domain_none_id', 0 ] );
    push @domain_rows, map { [ selector_domain_id_name( $domains{$_}{owner_number}, $domains{$_}{owner_column} ), $_ ] }
      sort { $a <=> $b } keys %domains;
    print {$out} "enum perl_diag_selector_domain_id {\n",
      render_enum_rows( \@domain_rows ), "};\n\n";

    for my $domain_id ( sort { $a <=> $b } keys %domains ) {
        my $domain = $domains{$domain_id};
        my $suffix = $domain->{owner_number} . '_' . $domain->{owner_column};
        print {$out} render_macro_definition( "PERL_DIAG_SELECTOR_ENCODE_$suffix", 'value', '(value)' );
    }
    for
      my $code ( sort { $selector_layouts->{$a}{number} <=> $selector_layouts->{$b}{number} } keys %$selector_layouts )
    {
        my $layout = $selector_layouts->{$code};
        next unless @{ $layout->{names} || [] };
        my %definitions = map { $_->{name} => $_ } @{ $layout->{diagnostic}{selector_definitions} || [] };
        my ( @parameters, @parts );
        for my $column ( 0 .. $#{ $layout->{names} } ) {
            my $name   = $layout->{names}[$column];
            my $domain = $layout->{domains}[$column];
            next if $definitions{$name}{plural} || $definitions{$name}{operation_word};
            my $suffix = $domain->{owner_number} . '_' . $domain->{owner_column};
            unless ( $definitions{$name}{plural} ) {
                my $param_name = uc($name);
                $param_name =~ s/[^A-Z0-9_]/_/g;
                print {$out} render_macro_definition(
                    "PERL_DIAG_SELECTOR_FROM_${code}_${param_name}",
                    'value',
                    "Perl_diag_selector_from_cstr(aTHX_ "
                      . selector_domain_id_name( $domain->{owner_number}, $domain->{owner_column} )
                      . ', (value))',
                    ['value']
                );
            }
            next if $definitions{$name}{plural} || $definitions{$name}{operation_word};
            push @parameters, $name;
            push @parts,
              "((U64)PERL_DIAG_SELECTOR_ENCODE_$suffix($name) << " . $layout->{packed}{shifts}[$column] . ')';
        }
        my $expression = @parts ? '( ' . join( ' | ', @parts ) . ' )' : 'UINT64_C(0)';
        print {$out} render_macro_definition(
            'PERL_DIAG_SELECTOR_KEY_' . $code,
            join( ', ', @parameters ),
            $expression, \@parameters
        );
    }
}

# Render indexes, diagnostic macros, aliases, and fixed-value variants.
sub render_header {
    my ( $diagnostics, $diag_table, $diag_index, $registry, $warning_categories, $selector_layouts ) = @_;

    my $text = '';
    open my $out, '>', \$text or die "Cannot buffer diagnostic header: $!\n";

    my $params_name    = generated_c_name('params');
    my $param_label    = generated_c_name('param_label');
    my $param_type     = generated_c_name('param_type');
    my $param_value    = generated_c_name('param_value');
    my $parameter_hash = generated_c_name('parameter_hash');

    my $header = <<'HEADER';
#ifndef PERL_DIAG_H
#define PERL_DIAG_H 1

/* Generated macros preserve delivery and parser control semantics. */

#define PERL_DIAG_PUSH_PARAM(__PARAMS_NAME__, __PARAM_LABEL__, __PARAM_TYPE__, __PARAM_VALUE__, __SELECTOR_DOMAIN__) \
    STMT_START { \
        HV * const __PARAMETER_HASH__ = newHV(); \
        (void)hv_stores(__PARAMETER_HASH__, "name", newSVpvs(__PARAM_LABEL__)); \
        (void)hv_stores(__PARAMETER_HASH__, "type", newSVpvs(__PARAM_TYPE__)); \
        (void)hv_stores(__PARAMETER_HASH__, "value", (__PARAM_VALUE__)); \
        if (__SELECTOR_DOMAIN__) { \
            (void)hv_stores(__PARAMETER_HASH__, "selector_domain", newSVuv(__SELECTOR_DOMAIN__)); \
        } \
        av_push((__PARAMS_NAME__), newRV_noinc(MUTABLE_SV(__PARAMETER_HASH__))); \
    } STMT_END

HEADER

    $header =~ s/__PARAMS_NAME__/$params_name/g;
    $header =~ s/__PARAM_LABEL__/$param_label/g;
    $header =~ s/__PARAM_TYPE__/$param_type/g;
    $header =~ s/__PARAM_VALUE__/$param_value/g;
    $header =~ s/__PARAMETER_HASH__/$parameter_hash/g;
    print {$out} $header;

    print {$out} "/* Operation identity is separate from grammatical selector IDs. */\n",
      "enum perl_diag_word_operation {\n",
      "    perl_diag_word_operation_none = 0,\n",
      "    perl_diag_word_operation_do_block = OP_max + 1\n",
      "};\n",
      "enum { perl_diag_word_value_outside_domain = 0xffff };\n",
      "#define PERL_DIAG_WORD_OPERATION(type) ((UV)(type) + 1)\n\n";

    # Extension builds share the same one-based metadata indexes. Implicit
    # enum values avoid renumbering every declaration after an insertion.
    my @index_rows =
      ( [ 'perl_diag_index_none', 0 ], map { [ diagnostic_index_name( $_->{code} ), '' ] } @$diag_table );
    print {$out} "enum perl_diag_index {\n",
      render_enum_rows( \@index_rows ), "};\n";

    # Catalog numbers are stable identities, independent of metadata indexes.
    my @number_rows =
      ( [ 'perl_diag_number_none', 0 ], map { [ diagnostic_number_name( $_->{code} ), $_->{number} ] } @$diag_table );
    print {$out} "\nenum perl_diag_number {\n",
      render_enum_rows( \@number_rows ), "};\n";

    write_selector_domain_enums( $out, $selector_layouts );

    print {$out} "\n#if defined(PERL_CORE) || defined(PERL_EXT_RE_BUILD)\n";
    print {$out} "#define PERL_DIAG_METADATA_COUNT " . scalar(@$diagnostics) . "\n";
    print {$out} "\n#endif\n\n";

    for my $diag (@$diagnostics) {
        write_diagnostic_macros( $out, $diag, $registry->{by_diagnostic}, $warning_categories );
    }

    for my $diag (@$diagnostics) {
        write_variant_macros( $out, $diag );
    }

    print {$out} "#endif /* PERL_DIAG_H */\n";
    close $out or die "Cannot close diagnostic header buffer: $!\n";

    return $text;
}

# Catalog output and regeneration

# Parse the standalone dump mode without loading the translation driver.
# Other options remain untouched unless the caller selected this mode.
sub template_dump_option {
    my ($arguments) = @_;
    return unless grep { /\A--dump-templates(?:=|\z)/ } @$arguments;

    require Getopt::Long;
    my $parser = Getopt::Long::Parser->new( config => [qw(pass_through no_auto_abbrev no_ignore_case)] );
    my $path;
    $parser->getoptionsfromarray( $arguments, 'dump-templates=s' => \$path )
      or die "Usage: perl regen/diag.pl --dump-templates=FILE\n";
    die "--dump-templates cannot be combined with other options\n" if @$arguments;
    die "--dump-templates requires a nonempty filename without NUL or line breaks\n"
      unless defined $path && length $path && $path !~ /[\0\r\n]/;

    return $path;
}

sub language_pack_option {
    my ($arguments) = @_;
    my @selected;
    for (my $index = 0; $index < @$arguments;) {
        if ($arguments->[$index] =~ /\A--generate-pack=(.*)\z/) {
            push @selected, $1;
            splice @$arguments, $index, 1;
        }
        else {
            $index++;
        }
    }
    die "--generate-pack may be specified only once\n" if @selected > 1;
    return unless @selected;
    die "--generate-pack requires a lowercase language code or 'all'\n"
      unless $selected[0] =~ /\A[a-z][a-z0-9_]*\z/;
    return $selected[0];
}

# Keep each UTF-8 template on one physical TSV row. Escape literal backslashes
# in the same pass so newly produced escapes are never processed again.
sub template_dump_field {
    my ($value) = @_;
    my %escapes = ( "\\" => "\\\\", "\t" => '\t', "\n" => '\n', "\r" => '\r' );
    $value =~ s{([\\\x00-\x1f\x7f])}
      {exists $escapes{$1} ? $escapes{$1} : sprintf '\\x{%02x}', ord($1)}ge;
    return $value;
}

# Export defined cases in the same language, diagnostic and match order as
# the compiled tables. Wildcards remain cases, rather than expanding into
# their Cartesian product. Missing translations are not copied from English.
sub write_template_dump {
    my ( $diagnostics, $path ) = @_;
    my $layouts   = build_selector_layouts($diagnostics);
    my $analysis  = build_template_analysis($diagnostics);
    my $word_data = Diag::Words::catalog();
    my @languages = ( 'en', grep { $_ ne 'en' } catalog_languages($diagnostics) );
    my $text      = "# language_id\tnumber_hex\tselector_hex\ttemplate\n";
    $text .= sprintf "# language 0x%x=%s\n", $_, $languages[$_] for 0 .. $#languages;

    for my $language_id ( 0 .. $#languages ) {
        my $language         = $languages[$language_id];
        my $language_hex     = sprintf '0x%x', $language_id;
        my $language_layouts = build_language_selector_layouts( $diagnostics, $language, $layouts, $word_data );
        for my $diag (@$diagnostics) {
            next if $diag->{dynamic};
            my $entry  = $analysis->{ $diag->{code} };
            my $cases  = $entry->{cases}{$language} || [];
            my $ids    = $language_layouts->{ $diag->{code} }{ids};

            for my $case ( Diag::Migration::ordered_selector_cases( $diag, $cases ) ) {
                my $key = selector_pattern_hex( $diag, $case->{selectors}, $ids );
                $key = '0x0' if $key eq '0';
                my ($params) = Diag::Migration::template_case_parameter_layout(
                    $diag, $case->{template} );
                my ($template) = positional_template( $case->{template}, $params, $diag->{code} );
                my $number     = sprintf '0x%x', $diag->{number};
                $text .= join( "\t", $language_hex, $number, $key, template_dump_field($template) ) . "\n";
            }
        }
    }

    write_plain_output( $path, $text, 1 );
}

# Prepare every output before opening files.  Rendering performs the remaining
# formatter, selector, and delivery checks without publishing a partial result.
sub prepare_generation {
    my ( $conf, $meta, $diagnostics, $diag_table, $diag_index,
        $warning_categories ) = @_;

    my $pod_file = $conf->{pod_file};
    die "diag_conf.pl has no pod_file\n" unless defined $pod_file;

    my $class_model = Diag::Classes::build_model(
        $diagnostics, $conf->{diagnostic_classes},
        Perl::Regen::Warnings::tree(), Diag::Migration::read_source('warnings.h')
    );
    my $selector_layouts = build_selector_layouts($diagnostics);
    my $helpers          = build_helpers( $diagnostics, $warning_categories );
    my $catalog          = Diag::Migration::render_catalog($conf);
    my $documentation    = Diag::Documentation::render( $conf->{documentation} );
    my $data             = render_data( $diagnostics, $diag_table, $diag_index,
        $selector_layouts, $conf->{languages}, $conf->{plural_rules}, $class_model );
    my $header           = render_header( $diagnostics, $diag_table, $diag_index,
        $helpers, $warning_categories, $selector_layouts );
    my $plural           = Diag::Plural::render();

    return {
        catalog            => $catalog,
        documentation_path => $pod_file,
        documentation      => $documentation,
        data               => $data,
        helpers            => render_helpers($helpers),
        header             => $header,
        plural             => $plural,
    };
}

# Publish a validated plain-text output without generated-file markers.
sub write_plain_output {
    my ( $path, $text, $utf8 ) = @_;

    if ($utf8) {
        utf8::upgrade($text);
        require Encode;
        $text = Encode::encode( 'UTF-8', $text,
            Encode::FB_CROAK() | Encode::LEAVE_SRC() );
    }

    my $out = open_new( $path, '>' );
    print {$out} $text;
    close_and_rename($out);
}

# Generated C outputs share their provenance and read-only footer conventions.
sub write_generated_output {
    my ( $path, $text, $sources, $from ) = @_;

    my $out = open_new( $path, '>', { by => 'regen/diag.pl',
        from => $from || 'diag_conf.pl and diag_op_conf.pl' } );
    print {$out} $text;
    read_only_bottom_close_and_rename( $out, $sources || [qw(diag_conf.pl diag_op_conf.pl regen/opcodes)] );
}

# Write a readable translation worksheet for one requested language.
sub write_translation_table {
    my ( $diagnostics, $language ) = @_;
    require JSON::PP;

    my @entries = map {
        +{
            %$_,
            translated => $_->{translated} ? JSON::PP::true() : JSON::PP::false(),
        }
    } @{ Diag::Migration::translation_table_rows( $diagnostics, $language ) };

    my $document = {
        instructions => [
            'Edit only each entry translation field.',
            'Entries with translated false contain the English source as a fallback.',
            'Keep %{name} argument placeholders and selector values unchanged.',
            'Merge edits with LOAD_TRANS_TABLE=perldiag_trans_' . $language
              . '.json perl -I. regen/diag.pl from the Perl source root.',
        ],
        source_language => 'en',
        target_language => $language,
        entries         => \@entries,
    };
    my $text = JSON::PP->new->canonical->pretty->utf8->encode($document);
    my $path = "perldiag_trans_$language.json";
    write_plain_output( $path, $text );
    print "Wrote $path\n";
}

# Load a translator worksheet and merge its edited rows into the catalog.
sub load_translation_table {
    my ( $conf, $diagnostics, $path, $provenance_path ) = @_;
    require JSON::PP;

    open my $input, '<:raw', $path
      or die "Cannot open translation worksheet $path: $!\n";
    local $/;
    my $document = JSON::PP->new->utf8->decode(<$input>);
    close $input or die "Cannot close translation worksheet $path: $!\n";

    if ( $document->{vocabulary_version} ) {
        require './regen/diag_translate.pm';
        require './regen/diag_word_translate.pm';
        my $count = Diag::Translation::Words::import_document( $conf, $diagnostics, $document,
            $provenance_path || 'regen/diag_translation_provenance.json' );
        print "Applied $count operation vocabulary updates from $path\n";
        return 1;
    }
    my $count = Diag::Migration::apply_translation_table( $diagnostics, $document );
    require './regen/diag_translate.pm';
    my $recorded = Diag::Translation::record_import( $conf, $diagnostics, $document,
        $provenance_path || 'regen/diag_translation_provenance.json' );
    print "Applied $count translation updates from $path\n";
    print "Recorded source provenance for $recorded diagnostics\n" if $recorded;
    return 0;
}

# Refresh shared word domains from the opcode inventory. Numeric identity
# comes from source order, independently of these readable sorted domains.
sub populate_operation_domains {
    my ($meta) = @_;
    my @comma_names;
    for my $line ( split /\n/, Diag::Migration::read_source('regen/opcodes') ) {
        next if $line =~ /\A(?:\s*#|\s*\z)/;
        my ( $name, undef, $check ) = split /\t+/, $line;
        next unless defined $check;
        push @comma_names, $name
          if $check eq 'ck_fun' || $check eq 'ck_grep' || $check eq 'ck_split';
    }
    @{ $meta->{missing_comma_word_operations} } = sort @comma_names;
    my $operations = Diag::Words::source_words();
    @{ $meta->{operation_word_opcodes} } = sort grep { $_ ne 'do_block' } keys %$operations;
    @{ $meta->{operation_word_all} }     = sort keys %$operations;
    delete @{$meta}{
        qw(compile_callee_operation_name
          not_enough_arguments_operation_name
          too_many_arguments_operation_name
          missing_comma_function_name
          format_operation_name)
    };
}

# Keep repair provenance beside its destination so the final rename is atomic.
# Generated catalog files are published individually; provenance is published
# only after that set has been written successfully.
sub stage_repair_provenance {
    my ($path) = @_;
    my $staged = "$path.repair-stage.$$";
    require './regen/diag_translate.pm';
    Diag::Translation::write_json( $staged, Diag::Translation::read_provenance($path) );
    return $staged;
}

sub publish_repair_provenance {
    my ( $staged, $path ) = @_;
    rename $staged, $path or die "Cannot publish repair provenance $path: $!\n";
}

# Validate the complete catalog before publishing any derived files.
sub main {
    my $pack_language = language_pack_option(\@ARGV);
    my $review_options;
    if ( grep { /^--review-diagnostics(?:=|$)/ } @ARGV ) {
        require './regen/diag_review.pm';
        $review_options = Diag::Review::options( \@ARGV );
    }
    my $template_dump = template_dump_option( \@ARGV );
    my $translation_options;
    if (@ARGV) {
        require './regen/diag_translate.pm';
        $translation_options = Diag::Translation::options( \@ARGV );
    }

    my $translation_language = $ENV{MAKE_TRANS_TABLE};
    my $translation_file     = $ENV{LOAD_TRANS_TABLE};
    die "diagnostic review cannot be combined with translation environment variables\n"
      if $review_options && ( defined $translation_language || defined $translation_file );
    die "--generate-pack cannot be combined with other options or translation environment variables\n"
      if defined($pack_language)
      && (@ARGV || defined($translation_language) || defined($translation_file));
    die "--dump-templates cannot be combined with MAKE_TRANS_TABLE or LOAD_TRANS_TABLE\n"
      if defined $template_dump && ( defined $translation_language || defined $translation_file );
    die "MAKE_TRANS_TABLE must be a language code such as en or de\n"
      if defined($translation_language)
      && $translation_language !~ /\A[A-Za-z][A-Za-z0-9_-]*\z/;
    die "LOAD_TRANS_TABLE must name a JSON translation worksheet\n"
      if defined($translation_file)
      && ( !length($translation_file) || $translation_file =~ /[\0\r\n]/ );
    die "translation mode cannot be combined with MAKE_TRANS_TABLE or LOAD_TRANS_TABLE\n"
      if $translation_options && ( defined $translation_language || defined $translation_file );

    do './diag_conf.pl';
    my $conf = $CONF;
    my $meta = $META;
    die "diag_conf.pl did not define a hash reference\n"
      unless ref($conf) eq 'HASH';
    die "diag_conf.pl did not define a metadata hash reference\n"
      unless ref($meta) eq 'HASH';
    populate_operation_domains($meta);
    Diag::Words::catalog();
    my $diagnostics = Diag::Migration::diagnostics($conf);
    my $word_catalog_changed =
      defined $translation_file
      ? load_translation_table( $conf, $diagnostics, $translation_file,
        $translation_options && $translation_options->{provenance_file} )
      : 0;
    my %warning_categories =
      map { $_ => 1 } Diag::Migration::read_source('warnings.h') =~ /^#define\s+(WARN_\w+)\s+\d+/mg;

    for my $diag (@$diagnostics) {
        validate_diagnostic( $conf, $diag,
            $translation_options && ( $translation_options->{vocabulary} || $translation_options->{mode} eq 'audit' ) );
    }
    @$diagnostics = sort { $a->{number} <=> $b->{number} } @$diagnostics;

    if ($review_options) {
        Diag::Review::run( $conf, $diagnostics, $review_options );
        return;
    }

    if ( defined $template_dump ) {
        write_template_dump( $diagnostics, $template_dump );
        return;
    }

    my $repair_runs;
    my $staged_repair_provenance;
    if ($translation_options) {
        $repair_runs = Diag::Translation::run( $conf, $diagnostics, $translation_options );
        return
             unless $translation_options->{mode} eq 'repair'
          && !$translation_options->{dry_run}
          && !$translation_options->{no_import};
        if ( grep { !$_->{complete} } @$repair_runs ) {
            print "Repair is incomplete; saved work is retained. Resume to finish before automatic import.\n";
            return;
        }
        print "Importing completed repairs and regenerating the catalog\n";
        $staged_repair_provenance = stage_repair_provenance( $translation_options->{provenance_file} );
        for my $run (@$repair_runs) {
            $word_catalog_changed =
              load_translation_table( $conf, $diagnostics, $run->{output}, $staged_repair_provenance )
              || $word_catalog_changed;
        }
        validate_diagnostic( $conf, $_ ) for @$diagnostics;
    }

    Diag::Migration::update_diagnostic_source_files($diagnostics);

    my @diag_table = sort { $a->{code} cmp $b->{code} } @$diagnostics;
    die "too many diagnostics for the generated U16 table index\n"
      if @diag_table > 0xFFFF;
    my %diag_index;
    @diag_index{ map { $_->{code} } @diag_table } = 1 .. @diag_table;

    if ( defined $pack_language ) {
        my @pack_languages =
          $pack_language eq 'all'
          ? sort keys %{ $conf->{languages} }
          : ($pack_language);
        die "unknown language pack '$pack_language'\n"
          if grep { !exists $conf->{languages}{$_} } @pack_languages;
        my $selector_layouts = build_selector_layouts($diagnostics);
        require './regen/diag_pack.pm';
        Diag::Pack::generate( \@pack_languages, $diagnostics, \@diag_table, $selector_layouts,
            $conf->{languages}, $conf->{plural_rules}, '.' );
        return;
    }

    my $prepared = prepare_generation( $conf, $meta, $diagnostics, \@diag_table, \%diag_index, \%warning_categories );

    my $word_catalog_text = $word_catalog_changed ? Diag::Words::render_catalog( Diag::Words::catalog() ) : undef;

    # Normalize the catalog first so generated-file digests describe it.
    write_plain_output( 'diag_op_conf.pl',               $word_catalog_text,         1 ) if defined $word_catalog_text;
    write_plain_output( 'diag_conf.pl',                  $prepared->{catalog},       1 );
    write_plain_output( $prepared->{documentation_path}, $prepared->{documentation}, 1 );
    write_generated_output( 'perldiag_data.inc',    $prepared->{data} );
    write_generated_output( 'perldiag_helpers.inc', $prepared->{helpers} );
    write_generated_output( 'perldiag.h',           $prepared->{header} );
    write_generated_output( 'perldiag_plural.inc', $prepared->{plural},
        [qw(lib/unicore/cldr/plural.pl regen/diag_plural.pm)],
        'lib/unicore/cldr/plural.pl' );
    publish_repair_provenance( $staged_repair_provenance, $translation_options->{provenance_file} )
      if defined $staged_repair_provenance;
    write_translation_table( $diagnostics, $translation_language )
      if defined $translation_language;

    if ($repair_runs) {
        print "Repair results imported and catalog regenerated. Rebuild Perl to use the translations.\n";
        Diag::Translation::cleanup_repairs($repair_runs) if $translation_options->{cleanup};
    }
}

main() unless caller;
1;
