#!./perl

BEGIN {
    @INC = -f './TestInit.pm' ? ('.') : ('..');
}
use TestInit qw(T);
use strict;
use warnings;
use charnames ':full';
use Scalar::Util qw(refaddr);
require './t/test.pl';
require './regen/diag_lib.pm';
require './regen/diag_pod.pm';

plan('no_plan');
my $formats = Diag::Migration::format_macros();
ok( $formats->{UTF8f_QUOTEDPREFIX}, 'UTF8 formats come from perl.h' );
ok( $formats->{UVXf},               'integer formats come from the configuration header' );
my $constants = Diag::Migration::format_constants();
ok( exists $constants->{PL_no_sock_func}, 'shared formats come from their perl.h initializers' );
my $socket = Diag::Migration::parse_format( Diag::Migration::resolve_format( 'aTHX_ PL_no_sock_func', $constants ),
    ['name'], $formats );
is(
    $socket->{message_template}{en},
    'Unsupported socket function "%{arg1}" called',
    'socket constants resolve to a named message'
);
is( join( '|', @{ $socket->{values} } ), 'name', 'resolving a constant preserves its argument' );
my $hash_element = Diag::Migration::parse_format( Diag::Migration::resolve_format( 'aTHX_ PL_no_helem_sv', $constants ),
    ['SVfARG(key)'], $formats );
is( $hash_element->{params}[0]{format_str},    'SVf', 'constant initializers retain Perl format fragments' );
is( join( '|', @{ $hash_element->{values} } ), 'key', 'constant initializers retain SV inputs' );
is( Diag::Migration::resolve_format( 'runtime_format', $constants ),
    'runtime_format', 'unknown runtime formats are not assigned a constant message' );

my $mixed = Diag::Migration::parse_format( '"%s: %" UTF8f " %d %" SVf',
    [ 'prefix', 'UTF8fARG(UTF, end - start, start)', 'column', 'SVfARG(sv)' ], $formats );
ok( $mixed, 'mixed standard and symbolic formats parse' );
is( $mixed->{message_template}{en}, '%{arg1}: %{arg2} %{arg3} %{arg4}', 'substitutions keep format order' );
is(
    join( '|', @{ $mixed->{values} } ),
    'prefix|UTF|end - start|start|column|sv',
    'UTF8 triples and SV wrapper inputs keep argument order'
);
is( join( '|', map { $_->{type} } @{ $mixed->{params} } ), 'text|text|iv|text', 'symbolic string types stay text' );
is( join( '|', map { $_->{type} } @{ $mixed->{params}[1]{inputs} } ),
    'iv|uv|text', 'UTF8 inputs describe encoding, length and text' );

my $precision = Diag::Migration::parse_format( '"%*.*s %% %td"', [ 'width', 'length', 'buffer', 'offset' ], $formats );
ok( $precision, 'dynamic width and precision parse' );
is( $precision->{params}[0]{format_str}, '*.*s', 'width and precision stay in the formatter' );
is( join( '|', @{ $precision->{values} } ),
    'width|length|buffer|offset', 'width and precision inputs precede their value' );
is( $precision->{message_template}{en}, '%{arg1} %% %{arg2}', 'escaped percent consumes no value' );

my $hex = Diag::Migration::parse_format( '"U+%04" UVXf " %#" UVxf', [ 'first', 'second' ], $formats );
is( $hex->{params}[0]{prefix},            '04', 'symbolic hex width and padding are retained' );
is( $hex->{params}[1]{prefix},            '#',  'alternate form is retained' );
is( $hex->{params}[0]{type},              'uv', 'hex argument is unsigned' );
is( Diag::Migration::type_for('IVdf'),    'iv', 'signed integer fragment is not a float' );
is( Diag::Migration::type_for('LINE_Tf'), 'iv', 'line-number fragment is not a float' );

my $escaped_source = <<'C';
"line\n\"quoted\"\\end"
C
my $escaped = Diag::Migration::parse_format( $escaped_source, [], $formats );
is( $escaped->{message_template}{en}, "line\n\"quoted\"\\end", 'C escapes are decoded once for regeneration' );
ok( !Diag::Migration::parse_format( 'fmt',     ['value'],          $formats ), 'dynamic formats are deferred' );
ok( !Diag::Migration::parse_format( '"%s %d"', ['one'],            $formats ), 'missing values are rejected' );
ok( !Diag::Migration::parse_format( '"%s"',    [ 'one', 'extra' ], $formats ), 'extra values are rejected' );
ok( !Diag::Migration::parse_format( '"%" NOT_A_FORMAT', ['one'],   $formats ), 'unknown fragments are rejected' );
ok( !Diag::Migration::parse_format( '"%" UTF8f',        ['UTF8fARG(UTF, len)'], $formats ),
    'incomplete UTF8 triples are rejected' );
ok( !Diag::Migration::parse_format( '"%" UTF8f', ['format(UTF, len, pv)'], $formats ),
    'unrecognized UTF8 packing is deferred' );

my $continued = Diag::Migration::parse_format( <<'C', [], $formats );
"first\n\
second\n"
C
is( $continued->{message_template}{en},
    "first\nsecond\n", 'physical line continuations add no text and lose no message' );
my @empty = Diag::Migration::split_args('  ');
is( scalar @empty, 0, 'empty macro argument lists contain no arguments' );
my $context =
  Diag::Migration::parse_format( '"Bad SV %" UVxf " %s" pTHX__FORMAT', [ 'PTR2UV(sv)', 'kind pTHX__VALUE' ], $formats );
ok( $context->{emit}{interpreter_suffix}, 'conditional interpreter context is catalog metadata' );
is( $context->{message_template}{en}, 'Bad SV %{arg1} %{arg2}', 'interpreter suffix does not hide the message' );
is( join( '|', @{ $context->{values} } ),
    'PTR2UV(sv)|kind', 'conditional interpreter context leaves fixed message inputs' );
my $zero_context = Diag::Migration::parse_format( '"Bad interpreter" pTHX__FORMAT pTHX__VALUE', [], $formats );
ok( $zero_context->{emit}{interpreter_suffix}, 'zero-argument messages retain conditional interpreter context' );
ok( !Diag::Migration::parse_format( '"Bad interpreter" pTHX__FORMAT', [], $formats ),
    'an unpaired interpreter format suffix is rejected' );
my $local = Diag::Migration::local_format_constants(<<'C');
/* static const char ignored[] = "comment"; */
static const char message[] = "Bad %" UVxf;
const char *dynamic = select_message();
C
ok( exists $local->{message}, 'fixed local character arrays can own known formats' );
ok(
    !exists $local->{ignored} && !exists $local->{dynamic},
    'comments and runtime pointers are not fixed format constants'
);

is(
    Diag::Migration::format_error( { message_template => { en => 'hook %.*s' }, params => [] } ),
    'unmanaged printf conversion',
    'named formats reject raw printf substitutions'
);
is(
    Diag::Migration::format_error( { template => 'hook %.*s', params => [] } ),
    'obsolete template field',
    'the old printf template schema is rejected'
);
ok(
    !Diag::Migration::format_error(
        {
            message_template => { en => 'hook %{text} %%' },
            params           => [ { name => 'text', type => 'text' }, ]
        }
    ),
    'named formats allow placeholders and literal percent signs'
);
ok( !Diag::Migration::format_error( { message_template => { en => 'bare %%{literal}' }, params => [] } ),
    'escaped percent cannot introduce a placeholder' );
is(
    Diag::Migration::format_error( { message_template => { fr => 'texte' }, params => [] } ),
    'missing English message template',
    'English is required for generation'
);
is(
    Diag::Migration::format_error( { message_template => { en => '%{missing}' }, params => [] } ),
    'unknown message parameter in en',
    'unknown placeholders are rejected'
);
my $translated = {
    message_template => { en => '%{first} %{second}', fr => '%{second} %{first}' },
    params           => [ { name => 'first', type => 'text' }, { name => 'second', type => 'text' } ]
};
ok( !Diag::Migration::format_error($translated), 'translations may reorder the same parameters' );
$translated->{message_template}{fr} = '%{first}';
ok( !Diag::Migration::format_error($translated), 'translations may omit message parameters' );

my @calls = Diag::Migration::calls( <<'C', qr/PERL_DIAG_LEGACY_croak/ );
/* PERL_DIAG_LEGACY_croak("comment"); */
const char *example = "PERL_DIAG_LEGACY_croak(\"string\")";
=for apidoc example
 PERL_DIAG_LEGACY_croak("documentation");
=cut
PERL_DIAG_LEGACY_croak(
    "%s %d", lookup("a,b", values[2]), 3);
C
is( scalar @calls,   1, 'comments, string contents and POD examples are excluded' );
is( $calls[0]{line}, 6, 'multiline calls retain their source line' );
is(
    join( '|', @{ $calls[0]{args} } ),
    '"%s %d"|lookup("a,b", values[2])|3',
    'nested calls and quoted commas stay intact'
);

my @raw = Diag::Migration::calls( <<'C', qr/croak/ );
#define EXAMPLE(value) \
    croak("unmanaged %s", value)
C
is( scalar @raw,   1, 'unmanaged emitters inside macro bodies are visible' );
is( $raw[0]{line}, 2, 'unmanaged macro emitters retain their source line' );

our ( $CONF, $META );
do './diag_conf.pl';
my $conf        = $CONF;
my $diagnostics = Diag::Migration::diagnostics($conf);

{
    my @checks = (
        [ 'ERROR_CALL_BINDING_ARITY_SUBROUTINE_COUNT_MISMATCH',        'fr', qr/re\N{U+E7}u/,                                         4 ],
        [ 'ERROR_UNICODE_CODE_POINT_REGEXP_LIMIT_EXCEEDED',        'fr', qr/r\N{U+E9}guli/,                                       1 ],
        [ 'WARNING_REGEXP_MODIFIER_INLINE_GLOBAL_OR_ONCE_IGNORED',          'es', qr/expresi\N{U+F3}n/,                                    2 ],
        [ 'WARNING_REGEXP_MODIFIER_INLINE_CONTINUE_IGNORED', 'es', qr/expresi\N{U+F3}n/,                                    2 ],
        [ 'NOTE_HINT_STACK_UNWIND_DEFERRED',            'fr', qr/D\N{U+E9}roulement de la pile diff\N{U+E9}r\N{U+E9}/, 1 ],
        [ 'NOTE_HINT_STACK_UNWIND_DEFERRED',            'de', qr/zur\N{U+FC}ckgestellt/,                               1 ],
    );

    for my $check (@checks) {
        my ( $code, $language, $expected, $count ) = @$check;
        my ($diag) = grep { $_->{code} eq $code } @$diagnostics;
        my $cases = Diag::Migration::template_cases( $diag, $language );
        is( scalar @$cases, $count, "$code $language retains every template case" );
        for my $case (@$cases) {
            like( $case->{template}, $expected, "$code $language contains the intended accent" );
            unlike(
                $case->{template},
                qr/\N{U+C3}[\N{U+80}-\N{U+BF}]/,
                "$code $language does not contain the repaired double encoding"
            );
        }
    }
}

is( Diag::Migration::severity_name( $conf, 'P' ),
    'INTERNAL_ERROR', 'the established P classification has a long alias' );
is( Diag::Migration::severity_name( $conf, 'X' ),
    'UNTRAPPABLE_ERROR', 'the established X classification has a long alias' );
is( Diag::Migration::severity_name( $conf, 'A' ), 'ALIEN_ERROR', 'the established A classification has a long alias' );
ok( !defined Diag::Migration::severity_name( $conf, 'UNKNOWN' ), 'unknown severity names are rejected' );
my ($division) = grep { $_->{code} eq 'ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO' } @$diagnostics;
my $nested_fixture = sub {
    my (%change) = @_;
    return {
        severities      => $conf->{severities},
        exception_kinds => $conf->{exception_kinds},
        diagnostic_tags => $conf->{diagnostic_tags},
        diagnostics     => {
            FATAL_ERROR => {
                CORE_RUNTIME => {
                    ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO => { %$division, %change },
                }
            },
        }
    };
};

# Selector ordering normalization.
my $sorted_values      = [ 'zulu', 'alpha', 'beta' ];
my $preserved_values   = [ 'zulu', 'alpha' ];
my $conditional_values = { first => [ 'zulu', 'beta' ], second => [ 'gamma', 'alpha' ] };
my $ordering_fixture   = [
    {
        params => [
            { name => 'sorted',      selector_values => $sorted_values },
            { name => 'alias',       selector_values => $preserved_values },
            { name => 'preserved',   selector_values => $preserved_values, selector_unsorted => 1 },
            { name => 'conditional', selector_values => $conditional_values },
        ]
    }
];
Diag::Migration::normalize_selector_order($ordering_fixture);
is( join( ' ', @$sorted_values ),    'alpha beta zulu', 'unmarked selector values sort during normalization' );
is( join( ' ', @$preserved_values ), 'zulu alpha',      'marked selector values retain their order' );
is(
    refaddr( $ordering_fixture->[0]{params}[1]{selector_values} ),
    refaddr($preserved_values),
    'an unmarked alias retains the protected shared array'
);
is( join( ' ', @{ $conditional_values->{first} } ),  'beta zulu',   'conditional selector leaves are sorted' );
is( join( ' ', @{ $conditional_values->{second} } ), 'alpha gamma', 'every conditional branch is sorted' );

my $explicit_order = {
    message => {
        templates => { en => { '*' => 'example' } },
        args      => [ { name => 'source', type => 'text', format_str => 's' } ],
        selectors => [
            {
                name     => 'selection',
                source   => 'source',
                values   => [ 'zulu', 'alpha' ],
                unsorted => 1
            }
        ],
    },
    emit => { api => 'CROAK' },
};
Diag::Migration::normalize_diagnostic_schema($explicit_order);
Diag::Migration::normalize_selector_order( [$explicit_order] );
my $canonical_order = Diag::Migration::canonical_diagnostic_schema($explicit_order);
is( $canonical_order->{message}{selectors}[0]{unsorted}, 1, 'explicit unsorted flags survive normalization' );
is( join( ' ', @{ $canonical_order->{message}{selectors}[0]{values} } ),
    'zulu alpha', 'explicit selector definitions retain their configured order' );
my $argument_order = {
    message => {
        templates => { en => { '*' => 'example' } },
        args      => [
            {
                name              => 'selection',
                type              => 'text',
                format_str        => 's',
                selector_values   => [ 'zulu', 'alpha' ],
                selector_unsorted => 1
            }
        ]
    },
    emit => { api => 'CROAK' },
};
Diag::Migration::normalize_diagnostic_schema($argument_order);
my $canonical_argument = Diag::Migration::canonical_diagnostic_schema($argument_order);
is( $canonical_argument->{message}{args}[0]{selector_unsorted},
    1, 'argument ordering flags survive conversion through selector definitions' );
my $invalid_order;
eval {
    Diag::Migration::normalize_selector_order(
        [
            {
                params => [ { name => 'bad', selector_values => ['alpha'], selector_unsorted => 'yes' } ]
            }
        ]
    );
    1;
} or $invalid_order = $@;
like( $invalid_order, qr/invalid selector_unsorted flag/, 'invalid selector ordering flags are rejected' );

my $selector_diag = {
    message_selectors => [ 'count_error', 'expected_bound' ],
    params            => [
        {
            name            => 'count_error',
            type            => 'text',
            format_str      => 's',
            selector_values => [ 'too_few', 'too_many' ],
        },
        {
            name            => 'expected_bound',
            type            => 'text',
            format_str      => 's',
            selector_values => {
                too_few  => [ 'exact', 'minimum' ],
                too_many => [ 'exact', 'maximum' ],
            },
        },
        { name => 'count',  type => 'uv',   format_str => 'UVuf' },
        { name => 'detail', type => 'text', format_str => 's' },
    ],
    message_template => {
        en => {
            too_few => {
                exact   => 'Too few arguments (%{detail}; expected %{count})',
                minimum => 'Too few arguments (expected at least %{count})',
            },
            too_many => {
                exact   => 'Too many arguments (expected %{count})',
                maximum => 'Too many arguments (expected at most %{count})',
            },
        },
    },
};
my $no_selector_error;
my $selector_error = Diag::Migration::format_error($selector_diag);
is( $selector_error, $no_selector_error, 'selector templates cover each case and allow branch-specific parameters' );
is( scalar @{ Diag::Migration::template_cases( $selector_diag, 'en' ) },
    4, 'nested selector templates flatten to four generated cases' );

my ($assigned_reference) =
  grep { $_->{code} eq 'ERROR_MUTATION_REFERENCE_ALIASING_REFERENT_TYPE_MISMATCH' } @$diagnostics;
is(
    refaddr( $assigned_reference->{selector_definitions}[0]{values} ),
    refaddr( $conf->{common}{reftype_name} ),
    'assigned-reference selectors use the shared reference-type list'
);
is(
    join( ' ', @{ $conf->{common}{reftype_name} } ),
    'UNKNOWN ARRAY HASH CODE REF SCALAR GLOB REGEXP OBJECT LVALUE IO FORMAT VSTRING INVLIST',
    'the common reference-type list covers every Perl reftype name'
);
my $opcode_header      = Diag::Migration::read_source('opcode.h');
my %native_reftype_ids = $opcode_header =~ /^#define SVrt_([A-Z]+)\s+(0x[0-9a-fA-F]+)/gm;
my $reftype_values     = $conf->{common}{reftype_name};
my @reftype_mismatches;

for my $index ( 0 .. $#$reftype_values ) {
    my $name = $reftype_values->[$index];
    next if $name eq 'UNKNOWN';
    push @reftype_mismatches, $name
      unless exists( $native_reftype_ids{$name} )
      && hex( $native_reftype_ids{$name} ) + 1 == $index + 1;
}
is( scalar @reftype_mismatches, 0,         'reference-type selector IDs are one greater than SVrt constants' );
is( $reftype_values->[0],       'UNKNOWN', 'UNKNOWN has selector ID one while zero remains wildcard' );
my ($lexical_export_reference) = grep { $_->{code} eq 'ERROR_LEXICAL_EXPORT_REFERENCE_TYPE_MISMATCH' } @$diagnostics;
is(
    refaddr( $assigned_reference->{selector_definitions}[0]{values} ),
    refaddr( $lexical_export_reference->{selector_definitions}[0]{values} ),
    'reference-type diagnostics share the generator selector values'
);
is(
    join( ' ', sort keys %{ $lexical_export_reference->{message_template}{en} } ),
    '* ARRAY INVLIST IO OBJECT UNKNOWN',
    'English lexical-export wording selects the article for every reftype'
);
is( join( ' ', sort keys %{ $lexical_export_reference->{message_template}{fr} } ),
    '*', 'French lexical-export wording uses one template for every reftype' );
is( join( ' ', map { $_->{name} } @{ Diag::Migration::template_parameter_union($lexical_export_reference) } ),
    'reference_type', 'lexical-export reftype is both rendered and selected' );

is(
    join( ' ', sort keys %{ $assigned_reference->{message_template}{en} } ),
    '* ARRAY INVLIST IO OBJECT UNKNOWN',
    'English specifies the reference types that take the article “an”'
);
is( join( ' ', sort keys %{ $assigned_reference->{message_template}{fr} } ),
    '*', 'French uses one parameterized template without vowel-conformance cases' );
is( join( ' ', map { $_->{name} } @{ Diag::Migration::template_parameter_union($assigned_reference) } ),
    'reference_type', 'the reference type is both a rendered argument and a selector input' );
is( $assigned_reference->{number}, 1172, 'the shared assigned-reference diagnostic keeps its canonical number' );
is( join( ' ', @{ $assigned_reference->{emit}{aliases} } ), 'DIE', 'the shared diagnostic retains DIE delivery' );
is(
    $assigned_reference->{macro_aliases}{DIE},
    'PERL_THROW_ERROR_MUTATION_REFERENCE_ALIASING_REFERENT_TYPE_MISMATCH_DIE',
    'the DIE alias has an explicit generated macro name'
);
is( $assigned_reference->{variants}{ERROR_MUTATION_REFERENCE_ALIASING_SCALAR_REQUIRED}{values}{reference_type}{en},
    'SCALAR', 'the scalar-reference macro specializes the shared type parameter' );
is( $assigned_reference->{variants}{ERROR_MUTATION_REFERENCE_ALIASING_SCALAR_REQUIRED}{emit}{api},
    'DIE', 'the scalar-reference specialization preserves DIE delivery' );
ok( !( grep { $_->{number} == 1007 || $_->{number} == 1470 || $_->{number} == 2037 } @$diagnostics ),
    'merged assigned-reference diagnostic numbers are no longer active' );
my %retired_numbers = map { $_ => 1 } @{ $conf->{retired_numbers} };
ok( $retired_numbers{1092}, 'unreachable scalar-provider result-count number is retired' );
ok( !( grep { $_->{number} == 1092 } @$diagnostics ),
    'scalar calls do not generate a provider result-count diagnostic' );
ok( $retired_numbers{$_}, "merged method-lookup number $_ is retired" ) for ( 2050, 2051, 2052 );
my ($method_lookup) = grep { $_->{number} == 1772 } @$diagnostics;
is( $method_lookup->{macro_aliases}{DIE},
    'PERL_THROW_ERROR_OBJECT_METHOD_LOOKUP_NOT_FOUND_DIE',
    'shared method lookup retains a DIE delivery alias' );
my ($method_package_lookup) = grep { $_->{number} == 1773 } @$diagnostics;
is( $method_package_lookup->{macro_aliases}{DIE},
    'PERL_THROW_ERROR_OBJECT_METHOD_LOOKUP_PACKAGE_NOT_FOUND_DIE',
    'shared missing-package lookup retains a DIE delivery alias' );
ok( $retired_numbers{1587}, 'unreachable required-field-attribute-value number is retired' );
ok( !( grep { $_->{number} == 1587 } @$diagnostics ),
    'unreachable required-field-attribute-value diagnostic is not generated' );
ok( $retired_numbers{$_}, "removed assigned-reference number $_ is retired" ) for ( 1007, 1470, 2037 );
my ($declared_refs) = grep { $_->{code} eq 'ERROR_SYNTAX_DECLARATION_VARIABLE_REFERENCE_FEATURE_DISABLED' } @$diagnostics;
is( $declared_refs->{number}, 1307, 'duplicate declared-reference feature errors keep number 1307' );
is(
    $declared_refs->{macro_aliases}{CROAK},
    'PERL_THROW_DECLARED_REFS_FEATURE_DISABLED',
    'the parser retains its declared-reference feature macro as a delivery alias'
);
ok(
    !( grep { $_->{code} eq 'DECLARED_REFS_FEATURE_DISABLED' } @$diagnostics ),
    'the duplicate declared-reference diagnostic is no longer active'
);
ok( $retired_numbers{1655}, 'the duplicate declared-reference number is retired' );
ok( $retired_numbers{$_},   "removed typed-reference number $_ is retired" ) for ( 1004, 1005, 2040, 2044 );

my $source_selector_diag = {
    message_selectors    => ['selector_kind'],
    selector_definitions => [
        {
            name   => 'selector_kind',
            source => 'kind_input',
            values => [ 'alpha', 'beta' ],
        },
    ],
    params => [
        { name => 'kind_input', type => 'text', format_str => 's' },
        { name => 'display',    type => 'text', format_str => 's' },
    ],
    message_template => {
        en => {
            alpha => 'Value: %{display}',
            '*'   => 'Value: %{display}',
        },
    },
};
my $source_selector_layout = Diag::Migration::template_parameter_layout($source_selector_diag);
is( join( ' ', map { $_->{name} } @{ $source_selector_layout->{canonical_params} } ),
    'kind_input display', 'capture parameters retain declared source order' );
is( $source_selector_layout->{selector_indices}{selector_kind},
    0, 'selector lookup uses the canonical source index' );
is( $source_selector_layout->{canonical_indices}{display}, 1,
    'display parameters retain their canonical source index' );
my ($source_display_params) = Diag::Migration::template_case_parameter_layout(
    $source_selector_diag, 'Value: %{display}' );
is( join( ' ', map { $_->{name} } @$source_display_params ),
    'display', 'each translated case selects only its declared display parameters' );
is( $source_selector_layout->{stored_count}, 2, 'selector sources remain in stored diagnostic parameters' );

my $semantic_selector_diag = {
    message_selectors => ['reference_type'],
    params            => [
        {
            name       => 'reference_type',
            type       => 'text',
            format_str => 's',
        },
    ],
    common           => $conf->{common},
    message_template => {
        en => {
            SCALAR => 'Scalar reference',
            '*'    => 'Other reference',
        },
        fr => {
            SCALAR => 'Référence scalaire',
            ARRAY  => 'Référence de tableau',
            HASH   => 'Référence de hachage',
            CODE   => 'Référence de code',
            '*'    => 'Autre référence',
        },
    },
};
$semantic_selector_diag->{params}[0]{selector_values} =
  $conf->{common}{reftype_name};
Diag::Migration::normalize_diagnostic_schema($semantic_selector_diag);
is( scalar Diag::Migration::format_error($semantic_selector_diag),
    undef, 'semantic selector values are shared across language templates' );
is( scalar @{ Diag::Migration::template_cases( $semantic_selector_diag, 'en' ) },
    2, 'a language can use a wildcard for values handled explicitly elsewhere' );

my $selector_order_diag = {
    code              => 'SELECTOR_ORDER_TEST',
    message_selectors => [ 'first', 'second' ],
    params            => [
        { name => 'first',  selector_values => [ 'a', 'b' ] },
        { name => 'second', selector_values => [ 'b', 'c' ] },
    ],
};
my @selector_output_order = Diag::Migration::ordered_selector_cases(
    $selector_order_diag,
    [
        { selectors => [ '*', 'b' ], template => 'wildcard first' },
        { selectors => [ 'b', '*' ], template => 'b fallback' },
        { selectors => [ 'a', '*' ], template => 'a fallback' },
        { selectors => [ 'a', 'b' ], template => 'exact overlap' },
        { selectors => [ 'a', 'c' ], template => 'specific' },
        { selectors => [ '*', '*' ], template => 'default' },
    ]
);
is(
    join( ' | ', map { $_->{template} } @selector_output_order ),
    'exact overlap | specific | a fallback | b fallback | wildcard first | default',
    'selector output orders exact and specific cases before ordered fallbacks'
);

my %diagnostic_by_code = map { $_->{code} => $_ } @$diagnostics;
my $filehandle_diag    = $diagnostic_by_code{WARNING_IO_OPERATION_ON_CLOSED_OR_UNOPENED_HANDLE};
is(
    join( ' ', map { $_->{name} } @{ Diag::Migration::template_parameter_union($filehandle_diag) } ),
    'handle_type operation handle_name',
    'filehandle template parameters include values displayed by any language'
);
my $executable_diag = $diagnostic_by_code{ERROR_SYSTEM_PROCESS_EXECUTABLE_LOOKUP_FAILED};
is( join( ' ', map { $_->{name} } @{ Diag::Migration::template_parameter_union($executable_diag) } ),
    'target', 'executable lookup templates use only their rendered parameter' );

sub generated_namespace_violations {
    my ($source) = @_;
    my @violations;

    while ( $source =~ /^\s*#\s*define\s+([A-Za-z_]\w*)/gm ) {
        push @violations, "macro:$1" unless $1 =~ /^PERL_/;
    }
    while ( $source =~ /\benum(?:\s+\w+)?\s*\{([^}]*)\}\s*;/sg ) {
        my $members = $1;
        $members =~ s{/\*.*?\*/}{}gs;
        for my $member ( split /,/, $members ) {
            my ($name) = $member =~ /^\s*([A-Za-z_]\w*)/;
            push @violations, "enum:$name" if defined($name) && $name !~ /^perl_/;
        }
    }
    while ( $source =~ /^[ \t]*static[ \t]+const\b([^\n]*)/gm ) {
        my $declaration = $1;
        my ($name) = $declaration =~ /\b([A-Za-z_]\w*)[ \t]*(?:\[|=|;)/;
        next unless defined $name;
        push @violations, "data:$name" unless $name =~ /^perl_/;
    }
    while ( $source =~ /\btypedef\b.*?\}\s*([A-Za-z_]\w*)\s*;/sg ) {
        push @violations, "type:$1" unless $1 =~ /^perl_/;
    }
    while ( $source =~ /^\s*(?:static\s+)?(?:inline\s+)?(?:[A-Za-z_]\w*\s+|\*\s*)+([A-Za-z_]\w*)\s*\([^;{}]*\)\s*\n?\s*\{/gm ) {
        push @violations, "function:$1" unless $1 =~ /^Perl_/;
    }
    return @violations;
}

is(
    join( ',', generated_namespace_violations(
            join "\n", map { Diag::Migration::read_source($_) }
              qw(perldiag.h perldiag_helpers.inc perldiag_data.inc perldiag_plural.inc)
        )
    ),
    '', 'generated diagnostic definitions follow the Perl C namespace policy'
);
my $diagnostic_type_source = Diag::Migration::read_source('pp_ctl.c');
my $diagnostic_match_source = Diag::Migration::read_source('diag_template_match.h');
my $operator_header = Diag::Migration::read_source('op.h');
my $optimizer_source = Diag::Migration::read_source('peep.c');
my @diagnostic_types = $diagnostic_type_source =~ /typedef\s+struct\s*\{.*?\}\s*(\w+)\s*;/sg;
ok( @diagnostic_types && !grep( { $_ !~ /^perl_diag_/ } @diagnostic_types ),
    'handwritten diagnostic catalog types use the perl_ namespace' );
like(
    $operator_header,
    qr/#define PERL_DIAG_OP_DESC_WARNING_EXPERIMENTAL_ARGS_ARRAY_WITH_SIGNATURES_EXPLICIT_USE\(o\) OP_DESC\(o\)/,
    'signature-warning display data has a diagnostic-specific semantic wrapper'
);
like(
    $optimizer_source,
    qr/PERL_WARN_WARNING_EXPERIMENTAL_ARGS_ARRAY_WITH_SIGNATURES_EXPLICIT_USE\([\s\S]*?PERL_DIAG_OP_DESC_WARNING_EXPERIMENTAL_ARGS_ARRAY_WITH_SIGNATURES_EXPLICIT_USE\(parent\)\)/,
    'the audited signature-warning producer uses its display wrapper'
);
sub op_desc_wrapper_definition {
    my ( $path, $line ) = @_;
    return 0 unless $path =~ m{(?:^|/)op\.h\z};
    return 1 if $line =~ /^\s*#\s*define\s+OP_DESC\s*\(/;
    return $line =~ /^\s*#\s*define\s+(?:PERL_DIAG_(?:PL_)?OP_DESC_[A-Z0-9_]+|PERL_(?:ENCODE_TEXT_WARNING|B_API|XS_API_TEST)_OP_DESC)\s*\([^)]*\)\s*OP_DESC\s*\(/;
}
sub pl_op_desc_wrapper_definition {
    my ( $path, $line ) = @_;
    return 0 unless $path =~ m{(?:^|/)op\.h\z};
    return 1 if $line =~ /^\s*\#\s*define\s+(?:
        PERL_OP_DESC_CORE_TABLE|PERL_OP_DESC_CUSTOM_EXTENSION_TABLE|
        PERL_(?:DIAG|PANIC)_PL_OP_DESC_[A-Z0-9_]+|
        PERL_(?:DEBUG_CONTEXT_OLD_OP_DESC|OP_DESC_LOOKUP_NAME_ALIAS)|
        PERL_TAINT_PL_OP_DESC_[A-Z0-9_]+
    )\b[^\n]*\bPL_op_desc\s*\[/x;
    return 0;
}
ok( op_desc_wrapper_definition( 'op.h', '#define OP_DESC(o) OP_DESC_IMPL(o)' ),
    'the OP_DESC primitive definition is an explicit maintenance exception' );
ok( op_desc_wrapper_definition(
        'op.h', '#define PERL_DIAG_OP_DESC_SAMPLE(o) OP_DESC(o)' ),
    'a named semantic wrapper definition is an explicit maintenance exception' );
ok( !op_desc_wrapper_definition( 'op.c', 'OP_DESC(o)' ),
    'a direct OP_DESC source call is not a wrapper definition' );
ok( !op_desc_wrapper_definition(
        'op.h', '#define PERL_OP_DESC_ALIAS(o) OP_DESC(o)' ),
    'an alias without the OP_DESC role name is not an audited wrapper' );
ok( pl_op_desc_wrapper_definition(
        'op.h', '#define PERL_DIAG_PL_OP_DESC_SAMPLE(type) PL_op_desc[type]' ),
    'a named PL_op_desc role wrapper is an explicit maintenance exception' );
ok( !pl_op_desc_wrapper_definition(
        'op.c', 'PERL_WARN_SAMPLE(PL_op_desc[type])' ),
    'a direct PL_op_desc message use is not a wrapper definition' );
my @unwrapped_op_desc;
my @unwrapped_pl_op_desc;
require File::Find;
my $op_desc_source_root = -f 'op.h' ? '.' : '..';
File::Find::find(
    {
        no_chdir  => 1,
        preprocess => sub {
            grep { !m{(?:^|/)(?:\.git|blib|tmp)\z} } @_;
        },
        wanted => sub {
            return unless -f $_ && /\.(?:c|h|xs)\z/;
            open my $fh, '<', $_ or die "Can't read $_: $!\n";
            my $line_number = 0;
            my $in_c_comment = 0;
            while ( my $line = <$fh> ) {
                $line_number++;
                next unless $line =~ /(?<![A-Z0-9_])OP_DESC\s*\(/;
                next if op_desc_wrapper_definition( $_, $line );
                push @unwrapped_op_desc, "$_:$line_number";
            }
            close $fh or die "Can't close $_: $!\n";
            open $fh, '<', $_ or die "Can't read $_: $!\n";
            $line_number = 0;
            while ( my $line = <$fh> ) {
                $line_number++;
                my $code = $line;
                if ($in_c_comment) {
                    if ( $code =~ s{.*?\*/}{} ) {
                        $in_c_comment = 0;
                    }
                    else {
                        next;
                    }
                }
                $code =~ s{/\*.*?\*/}{}g;
                if ( $code =~ s{/\*.*\z}{}s ) {
                    $in_c_comment = 1;
                }
                $code =~ s{//.*\z}{};
                next unless $code =~ /\bPL_op_desc\s*\[/;
                next if pl_op_desc_wrapper_definition( $_, $code );
                next if $_ =~ m{(?:^|/)opcode\.h\z}
                    && $code =~ /^\s*EXTCONST\s+char\s*\*\s*const\s+PL_op_desc\s*\[\]\s+INIT\s*\(/;
                push @unwrapped_pl_op_desc, "$_:$line_number";
            }
            close $fh or die "Can't close $_: $!\n";
        },
    },
    $op_desc_source_root
);
diag( 'unwrapped OP_DESC uses: ' . join( ', ', @unwrapped_op_desc ) )
  if @unwrapped_op_desc;
is( join( ',', @unwrapped_op_desc ), '',
    'source uses OP_DESC only through the primitive and semantic wrappers' );
diag( 'unwrapped PL_op_desc uses: ' . join( ', ', @unwrapped_pl_op_desc ) )
  if @unwrapped_pl_op_desc;
is( join( ',', @unwrapped_pl_op_desc ), '',
    'source uses PL_op_desc only through named semantic wrappers' );
my $builtin_diagnostic_source = Diag::Migration::read_source('builtin.c');
like( $builtin_diagnostic_source, qr/^XS\(Perl_builtin_get_diagnostic_data\);/m,
    'diagnostic-data builtin wrapper follows the Perl function namespace' );
like( $builtin_diagnostic_source, qr/^XS\(Perl_builtin_plural_form\);/m,
    'plural builtin wrapper follows the Perl function namespace' );
unlike( $builtin_diagnostic_source, qr/^XS\(XS_builtin_(?:get_diagnostic_data|plural_form)\)/m,
    'diagnostic builtin wrappers have no XS_ namespace exceptions' );
my $embed_fnc_source = Diag::Migration::read_source('embed.fnc');
my $embed_header_source = Diag::Migration::read_source('embed.h');
my @new_long_name_functions = qw(
  cardinal_plural_form defer_error_diag defer_error_diag_params
  defer_error_diag_params_context do_warn get_deprecated_property_reason
  grok_bslash_c_diag grok_bslash_c_with_reason grok_bslash_o_diag
  grok_bslash_x_diag load_charnames ordinal_plural_form
  prescan_version_reason repeat_decode_utf8 xperl_exception_render_legacy
  yyerror_diag yyerror_diag_params yyerror_diag_pvn yyerror_diag_pvn_params
);
my %embed_flags;
while ( $embed_fnc_source =~ /^([A-Za-z]+)\s*\|[^|]+\|\s*([A-Za-z_]\w*)/gm ) {
    $embed_flags{$2} = $1;
}
ok( !grep( { !defined($embed_flags{$_}) || $embed_flags{$_} !~ /o/ } @new_long_name_functions ),
    'branch-added embedded function APIs suppress their short-name aliases' );
my $new_short_name_pattern = join '|', map { quotemeta($_) } @new_long_name_functions;
unlike( $embed_header_source, qr/^\s*#\s*define (?:$new_short_name_pattern)\b/m,
    'branch-added embedded APIs have no generated short-name aliases' );
is(
    join( ',', sort { $a cmp $b } generated_namespace_violations(<<'C')),
#define BAD_DIAG_MACRO 1
enum { BAD_DIAG_ENUM };
static const int BAD_DIAG_TABLE[] = { 0 };
typedef struct { int member; } bad_diag_type;
static void BAD_diag_helper(void) { }
C
    'data:BAD_DIAG_TABLE,enum:BAD_DIAG_ENUM,function:BAD_diag_helper,macro:BAD_DIAG_MACRO,type:bad_diag_type',
    'namespace validation classifies injected bad macros, enums, data, types and functions'
);
my $exception_source = Diag::Migration::read_source('xperl_exception.inc');
like( $exception_source, qr/^static SV \*\nPerl_xperl_render_exception_legacy\(/m,
    'branch-added exception helpers use the Perl function namespace' );
unlike( $exception_source, qr/\b(?:S_xperl_|S_boot_core_XPerl|XS_XPerl_)/,
    'new exception helper and XSUB implementations have no S_ or XS_ name aliases' );
like( $exception_source, qr/^XS\(Perl_XPerl_Diagnostic_new\);/m,
    'hand-written exception XSUB wrappers use the Perl function namespace' );

my $generated_header        = Diag::Migration::read_source('perldiag.h');
my $selector_generated_data = Diag::Migration::read_source('perldiag_data.inc');
my $french_pack_data = Diag::Migration::read_source('ext/XPerl-DiagPack-FR/FR_data.inc');
my $generated_helpers       = Diag::Migration::read_source('perldiag_helpers.inc');
my $generated_catalog       = join "\n", $generated_header, $selector_generated_data, $generated_helpers;
like(
    $generated_header,
    qr/enum perl_diag_selector_common_value\s*\{[\s\S]*?perl_diag_selector_invalid\s*=\s*-1,[\s\S]*?perl_diag_selector_wildcard\s*=\s*0,[\s\S]*?perl_diag_selector_plural_zero\s*=\s*1,[\s\S]*?perl_diag_selector_plural_other\s*=\s*6,/,
    'wildcard, invalid, and standard plural category IDs are distinct'
);
like(
    $generated_header,
    qr/perl_diag_selector_domain_1172_0_unknown_1\s*=\s*1,[\s\S]*?perl_diag_selector_domain_1172_0_array_2\s*=\s*2,[\s\S]*?perl_diag_selector_domain_1172_0_t;/,
    'reference-type domain values equal their packed byte IDs'
);
unlike(
    $generated_header,
    qr/perl_diag_selector_domain_2217_0_(?:zero_1|digits_0_7)/,
    'derived plural values do not enter the producer selector enums'
);
like(
    $french_pack_data,
    qr/#define PERL_DIAG_PLURAL_SELECTOR_fr_2217_0\(n\) \\\n\s*\(\(n\) == UINT64_C\(0\) \? \(IV\)7 :[\s\S]*?static const char \* const perl_diag_selector_values_fr_2217_0\[\] = \{\n\s*"zero",[\s\S]*?"0",\n\};/,
    'French plural zero and exact numeric zero retain distinct language-local IDs'
);
my $shared_domain_refs = () = $selector_generated_data =~ /perl_diag_selector_domain_2311_0_id/g;
ok( $shared_domain_refs > 1, 'identical ordered selector domains reuse the same internal domain ID' );
like(
    $generated_header,
    qr/#define PERL_DIAG_SELECTOR_ENCODE_1172_0\(value\) \\\n\s*\(value\)[\s\S]*?#define PERL_DIAG_SELECTOR_KEY_ERROR_MUTATION_REFERENCE_ALIASING_REFERENT_TYPE_MISMATCH\(ma_reference_type\) \\\n\s*\( \(\(U64\)PERL_DIAG_SELECTOR_ENCODE_1172_0\(ma_reference_type\) << 0\) \)/,
    'selector encoders preserve constant IDs and key macros evaluate each input once'
);
like(
    $generated_header,
    qr/#define PERL_DIAG_SELECTOR_FROM_ERROR_STRICT_REFS_STRING_REFERENCE_FORBIDDEN_REFERENCE_KIND\(ma_value\) \\\n\s*Perl_diag_selector_from_cstr\(aTHX_ perl_diag_selector_domain_2425_0_id, \(ma_value\)\)/,
    'dynamic selector strings have a diagnostic-specific conversion boundary'
);
my $native_selector_capture = generated_macro_body(
    $generated_header, 'PERL_THROW_ERROR_MUTATION_REFERENCE_ALIASING_REFERENT_TYPE_MISMATCH' );
$native_selector_capture =~ s/\\\n\s*/ /g;
like(
    $native_selector_capture,
    qr{
        IV \s+ const \s+ in_reference_type \s*=\s* ma_reference_type;
        [\s\S]*?
        Perl_diag_setup_param\([^;]*selector_domain_1172_0_id,\s*in_reference_type
    }x,
    'producer capture retains the native integer selector ID'
);
like(
    $diagnostic_match_source,
    qr/Perl_diag_selector_value_id[\s\S]*?if \(length == 1 && value\[0\] == '\*'\)[\s\S]*?return 0;[\s\S]*?return -1;/,
    'selector value lookup separates wildcard, known, and invalid values'
);
like(
    $diagnostic_type_source,
    qr/Perl_diag_selector_from_sv[\s\S]*?SvGETMAGIC\(value\);[\s\S]*?SvPV_nomg\(value, length\)[\s\S]*?Perl_diag_selector_from_pvn/,
    'dynamic selector conversion fetches scalar magic once before lookup'
);
like(
    $diagnostic_type_source . $diagnostic_match_source,
    qr/invalid_selector_mask\s*\|=\s*\(U8\)\(1U << column\)[\s\S]*?invalid_selector_mask & \(U8\)\(1U << selector_index\)/,
    'invalid plural inputs cannot be mistaken for wildcard or category-zero selectors'
);
unlike( $generated_catalog, qr/(?<![A-Za-z0-9_])DIAG_[A-Z0-9_]+/, 'generated diagnostic constants use PERL_DIAG names' );
unlike( $generated_catalog, qr/\bS_diag_[A-Za-z0-9_]+/, 'generated diagnostic data has no S_diag aliases' );
unlike( $generated_catalog, qr/\bdiag_[a-z][A-Za-z0-9_]*_t\b/, 'generated diagnostic types use perl_diag names' );
my $generated_embed = Diag::Migration::read_source('embed.h');
unlike(
    $generated_embed,
    qr/^\s*#\s*(?:define|undef)\s+(?:diag_[a-z]|S_diag_|DIAG_)/m,
    'embed.h has no generated diagnostic short aliases or legacy constants'
);
my %generated_template_text =
  $selector_generated_data =~ /^static const char (perl_diag_template_text_[0-9a-f]+)\[\]\s+= "((?:\\.|[^"\\])*)";$/gm;
like(
    $generated_header,
    qr/#define PERL_THROW_DECLARED_REFS_FEATURE_DISABLED\(\)(?:(?!#define ).)*?perl_diag_error_syntax_declaration_variable_reference_feature_disabled_idx/s,
    'the parser macro uses the canonical declared-reference diagnostic'
);
my @selector_value_bodies =
  $selector_generated_data =~ /^static const char \* const perl_diag_selector_values_[a-z]+_[0-9_]+\[\]\s+= \{\n(.*?)^\};$/gms;
ok( @selector_value_bodies, 'selector value tables are present' );
ok(
    !grep( { /diag_selector_/ } @selector_value_bodies ),
    'selector value tables contain configured strings directly'
);
my @selector_descriptor_bodies =
  $selector_generated_data =~ /^static const perl_diag_selector_t perl_diag_selectors_[a-z]+_\d+\[\]\s+= \{\n(.*?)^\};$/gms;
my %selector_value_bodies      = map { $_ => 1 } @selector_value_bodies;
my %selector_descriptor_bodies = map { $_ => 1 } @selector_descriptor_bodies;
my @selector_descriptor_uses =
  $selector_generated_data =~ m{
      \{ \s+ \d+, \s+ \d+, \s+ perl_diag_word_group_\w+,
      \s+ perl_diag_template_\w+, \s+ (perl_diag_selectors_[a-z]+_\d+) \s+ \},
  }gx;
is(
    scalar @selector_value_bodies,
    scalar keys %selector_value_bodies,
    'equivalent selector value arrays are emitted only once'
);
is(
    scalar @selector_descriptor_bodies,
    scalar keys %selector_descriptor_bodies,
    'equivalent selector descriptions are emitted only once'
);
ok( @selector_descriptor_uses > @selector_descriptor_bodies, 'diagnostics reuse shared selector descriptions' );
like(
    $selector_generated_data,
    qr/perl_diag_selectors_(?:en|fr)_\d+|perl_diag_selector_values_(?:en|fr)_\d+_\d+/,
    'language-specific selector arrays use language-qualified names'
);

for my $code (qw(WARNING_IO_OPERATION_ON_CLOSED_OR_UNOPENED_HANDLE ERROR_SYSTEM_PROCESS_EXECUTABLE_LOOKUP_FAILED)) {
    my $lower_code = lc $code;
    my @rows;
    while ( $selector_generated_data =~
        /^\s*\{\s*perl_diag_\Q$lower_code\E_number,\s+UINT64_C\([^)]*\),\s+(perl_diag_template_text_[0-9a-f]+),\s+(\d+),\s+\d+\s+\},/mg )
    {
        my ( $name, $count ) = ( $1, $2 );
        die "unknown generated template $name" unless exists $generated_template_text{$name};
        push @rows, [ $generated_template_text{$name}, $count ];
    }
    my $invalid_row = grep {
        my ( $template, $count ) = @$_;
        my $required_count = 0;
        for my $position ( $template =~ /%(\d+)\$s/g ) {
            $required_count = $position if $position > $required_count;
        }
        $count != $required_count;
    } @rows;
    ok( @rows && !$invalid_row, "$code templates use output parameter positions" );
}

my $incomplete_selector_diag = {
    %$selector_diag,
    message_template => {
        en => {
            too_few => {
                exact => 'Too few arguments (expected %{count})',
            },
            too_many => {
                exact   => 'Too many arguments (%{detail}; expected %{count})',
                maximum => 'Too many arguments (expected at most %{count})',
            },
        },
    },
};
like(
    Diag::Migration::format_error($incomplete_selector_diag),
    qr/no template for selector combination/,
    'selector templates reject a missing valid combination'
);
my $partial_translation_diag = {
    %$selector_diag,
    message_template => {
        en => {
            too_few => {
                exact => 'Too few arguments (expected %{count})',
                '*'   => 'Too few arguments',
            },
            too_many => {
                exact   => 'Too many arguments (%{detail}; expected %{count})',
                maximum => 'Too many arguments (expected at most %{count})',
            },
        },
        fr => {
            too_few => {
                exact => 'Pas assez d’arguments (attendu %{count})',
            },
        },
    },
};
ok(
    !Diag::Migration::format_error($partial_translation_diag),
    'a translation may omit selector cases supplied by the English fallback'
);
my $translation_import_diag = {
    %$source_selector_diag,
    code   => 'TRANSLATION_IMPORT_TEST',
    number => 9000,
};
my $translation_import_count = Diag::Migration::apply_translation_table(
    [$translation_import_diag],
    {
        target_language => 'nl',
        entries         => [
            {
                code        => 'TRANSLATION_IMPORT_TEST',
                number      => 9000,
                source      => 'Value: %{display}',
                translation => 'Waarde: %{display}',
            },
            {
                code        => 'TRANSLATION_IMPORT_TEST',
                number      => 9000,
                source      => 'Value: %{display}',
                translation => 'Waarde: %{display}',
            },
        ],
    },
);
is( $translation_import_count, 2, 'selectorless worksheets merge one translation across matching selector cases' );
is(
    $translation_import_diag->{message_template}{nl}{alpha},
    'Waarde: %{display}',
    'translation import preserves a matching specific case'
);
is(
    $translation_import_diag->{message_template}{nl}{'*'},
    'Waarde: %{display}',
    'translation import preserves a matching wildcard case'
);
my $selector_translation_diag =
  { %$translation_import_diag, message_template => { en => { alpha => 'Alpha', '*' => 'Other' } }, };
is(
    Diag::Migration::apply_translation_table(
        [$selector_translation_diag],
        {
            target_language => 'nl',
            entries         => [
                {
                    code        => 'TRANSLATION_IMPORT_TEST',
                    number      => 9000,
                    source      => 'Other',
                    selectors   => { selector_kind => 'beta' },
                    translation => 'Overig',
                },
            ],
        },
    ),
    1,
    'selector-aware worksheets update only their selected case'
);
is( $selector_translation_diag->{message_template}{nl}{beta},
    'Overig', 'selector-aware worksheet case is merged into the right branch' );
my $fallback_selector_diag = {
    %$selector_diag,
    message_template => {
        en => {
            too_few => {
                '*' => 'Too few arguments (expected %{count})',
            },
            too_many => {
                exact   => 'Too many arguments (%{detail}; expected %{count})',
                maximum => 'Too many arguments (expected at most %{count})',
            },
        },
    },
};
my $fallback_selector_error = Diag::Migration::format_error($fallback_selector_diag);
is( $fallback_selector_error, $no_selector_error, 'selector templates allow a wildcard fallback at one level' );
my $ambiguous_selector_diag = {
    message_selectors => [ 'first', 'second' ],
    params            => [
        {
            name            => 'first',
            type            => 'text',
            format_str      => 's',
            selector_values => [ 'x', 'y' ],
        },
        {
            name            => 'second',
            type            => 'text',
            format_str      => 's',
            selector_values => { x => [ 'm', 'n' ], y => [ 'm', 'n' ] },
        },
        { name => 'count', type => 'uv', format_str => 'UVuf' },
    ],
    message_template => {
        en => {
            x   => { '*' => 'X %{count}' },
            '*' => {
                m   => 'M %{count}',
                '*' => 'Default %{count}',
            },
        },
    },
};
is( scalar Diag::Migration::format_error($ambiguous_selector_diag),
    undef, 'selector templates accept equal-specificity cases with deterministic precedence' );
is(
    Diag::Migration::_matching_template_case(
        $ambiguous_selector_diag,
        Diag::Migration::template_cases( $ambiguous_selector_diag, 'en' ),
        [ 'x', 'm' ],
    )->{template},
    'X %{count}',
    'declared selector-column order chooses the first equal-specificity fallback'
);

my @overlapping_selector_cases = (
    { selectors => [ '*', 'b' ], template => 'wildcard in first column' },
    { selectors => [ 'a', '*' ], template => 'wildcard in second column' },
    { selectors => [ 'a', 'b' ], template => 'exact match' },
);
for my $order ( [ 0, 1, 2 ], [ 1, 0, 2 ], [ 2, 0, 1 ], [ 2, 1, 0 ], ) {
    my @cases = @overlapping_selector_cases[@$order];
    is( Diag::Migration::_matching_template_case( $selector_order_diag, \@cases, [ 'a', 'b' ] )->{template},
        'exact match', 'an exact selector case wins regardless of source row order' );
}
my @equal_specificity_cases = @overlapping_selector_cases[ 0, 1 ];
is(
    Diag::Migration::_matching_template_case( $selector_order_diag, \@equal_specificity_cases, [ 'a', 'b' ] )->{template},
    'wildcard in second column',
    'equal-specificity ties use selector tuple order with wildcards last'
);

my $overlapping_selector_diag = {
    code              => 'SELECTOR_PRECEDENCE_TEST',
    number            => 9001,
    message_selectors => [ 'first', 'second' ],
    params            => [
        {
            name            => 'first',
            type            => 'text',
            format_str      => 's',
            selector_values => ['a'],
        },
        {
            name            => 'second',
            type            => 'text',
            format_str      => 's',
            selector_values => ['b'],
        },
    ],
    message_template => {
        en => {
            '*' => { b => 'Wildcard in first column' },
            a   => {
                '*' => 'Wildcard in second column',
                b   => 'Exact match',
            },
        },
    },
};
is( scalar Diag::Migration::format_error($overlapping_selector_diag),
    undef, 'the selector validator accepts overlapping fallback cases' );
my $precedence_translation_rows = Diag::Migration::translation_table_rows( [$overlapping_selector_diag], 'fr' );
is( $precedence_translation_rows->[0]{source},
    'Exact match', 'translation export resolves through the same exact-case precedence' );
is(
    Diag::Migration::apply_translation_table(
        [$overlapping_selector_diag],
        {
            target_language => 'fr',
            template_sets   => [
                {
                    code         => 'SELECTOR_PRECEDENCE_TEST',
                    number       => 9001,
                    source_cases => Diag::Migration::template_cases( $overlapping_selector_diag, 'en' ),
                    cases        => [
                        {
                            selectors => [ 'a', 'b' ],
                            template  => 'Correspondance exacte',
                        },
                    ],
                },
            ],
        },
    ),
    1,
    'translation-set import accepts a language-specific exact selector case'
);
is(
    $overlapping_selector_diag->{message_template}{fr}{a}{b},
    'Correspondance exacte',
    'translation-set import updates the exact selector leaf'
);

my ($negation_precedence) = grep {
    $_->{code} eq 'WARNING_SYNTAX_PRECEDENCE_UNPARENTHESIZED_NEGATION_WITH_OPERATOR'
} @$diagnostics;
my %negation_translation_fixture = %$negation_precedence;
# Use a synthetic ordinary selector to test language-owned exact overrides.
# The real diagnostic resolves its operation through the shared vocabulary.
delete $negation_translation_fixture{operation_words};
$negation_translation_fixture{message_selectors} = ['comparison'];
$negation_translation_fixture{selector_definitions} =
  [ { name => 'comparison', source => 'arg1', values => [qw(eq ne)] }, ];

$negation_translation_fixture{message_template} =
  { map { $_ => $negation_precedence->{message_template}{$_} } qw(en fr) };

my $negation_french_fallback =
  "Probl\N{LATIN SMALL LETTER E WITH GRAVE}me de priorit\N{LATIN SMALL LETTER E WITH ACUTE} possible entre ! et %{arg1}";
is(
    Diag::Migration::apply_translation_table(
        [ \%negation_translation_fixture ],
        {
            target_language => 'fr',
            template_sets   => [
                {
                    code         => 'WARNING_SYNTAX_PRECEDENCE_UNPARENTHESIZED_NEGATION_WITH_OPERATOR',
                    number       => 2127,
                    source_cases => Diag::Migration::template_cases(
                        \%negation_translation_fixture, 'en'
                    ),
                    cases => [
                        {
                            selectors => ['*'],
                            template  => $negation_french_fallback,
                        },
                        {
                            selectors => ['eq'],
                            template  => "Cas fran\N{LATIN SMALL LETTER C WITH CEDILLA}ais : %{arg1}",
                        },
                    ],
                },
            ],
        },
    ),
    1,
    'a controlled French negation translation imports an exact comparison case'
);
my $negation_french_cases = Diag::Migration::template_cases(
    \%negation_translation_fixture, 'fr'
);
is(
    Diag::Migration::_matching_template_case(
        \%negation_translation_fixture, $negation_french_cases, ['eq']
    )->{template},
    "Cas fran\N{LATIN SMALL LETTER C WITH CEDILLA}ais : %{arg1}",
    'a French exact comparison case takes precedence over its wildcard'
);
is(
    Diag::Migration::_matching_template_case(
        \%negation_translation_fixture, $negation_french_cases, ['ne']
    )->{template},
    $negation_french_fallback,
    'the French wildcard remains the fallback for other comparisons'
);

for my $field (qw(severity kind code)) {
    my $fixture = $nested_fixture->( $field => 'WRONG' );
    eval { Diag::Migration::diagnostics($fixture) };
    like(
        $@,
        qr{
    diagnostics/FATAL_ERROR/CORE_RUNTIME/ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO\x20has\x20a\x20
    mismatched\x20$field
}x,
        "hierarchy validation rejects a mismatched $field"
    );
}
my $short_severity = $nested_fixture->( severity => 'F' );
$short_severity->{diagnostics}{F} =
  delete $short_severity->{diagnostics}{FATAL_ERROR};
is(
    Diag::Migration::render_catalog($short_severity),
    Diag::Migration::render_catalog( $nested_fixture->() ),
    'short severity keys and fields normalize to matching long names'
);
my $duplicate_severity = $nested_fixture->();
$duplicate_severity->{diagnostics}{F} = {};
eval { Diag::Migration::diagnostics($duplicate_severity) };
like( $@, qr/duplicate severity group FATAL_ERROR/, 'alias spellings cannot create duplicate severity groups' );
my $duplicate_code = $nested_fixture->();
$duplicate_code->{diagnostics}{FATAL_ERROR}{CORE_COMPILE}{ $division->{code} } =
  { %$division, kind => 'CORE_COMPILE', number => 9999 };
eval { Diag::Migration::diagnostics($duplicate_code) };
like( $@, qr/duplicate diagnostic code ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO/, 'diagnostic codes are unique across different kinds' );
my $duplicate_number = $nested_fixture->();
$duplicate_number->{diagnostics}{WARNING}{CORE_COMPILE}{CORE_TEST_COLLISION} = {
    %$division,
    severity => 'WARNING',
    kind     => 'CORE_COMPILE',
    code     => 'CORE_TEST_COLLISION'
};
eval { Diag::Migration::diagnostics($duplicate_number) };
like( $@, qr/duplicate diagnostic number 1001/, 'diagnostic numbers are unique across severities and kinds' );
my $retired_number = $nested_fixture->();
$retired_number->{retired_numbers} = [ $division->{number} ];
eval { Diag::Migration::diagnostics($retired_number) };
like( $@, qr/reuses retired diagnostic number 1001/, 'a consolidated diagnostic number cannot be reused' );
$retired_number->{retired_numbers} = [ 9998, 9998 ];
eval { Diag::Migration::diagnostics($retired_number) };
like( $@, qr/duplicate retired diagnostic number 9998/, 'retired numbers must be unique' );
$retired_number->{retired_numbers} = ['invalid'];
eval { Diag::Migration::diagnostics($retired_number) };
like( $@, qr/invalid retired diagnostic number/, 'retired identities must be numeric' );
$retired_number->{retired_numbers} = {};
eval { Diag::Migration::diagnostics($retired_number) };
like( $@, qr/retired_numbers is not an array/, 'retired identities have one declared representation' );
$retired_number->{retired_numbers} = [ 9999, 9998 ];
like(
    Diag::Migration::render_catalog($retired_number),
    qr/"retired_numbers" => \[\s*9998,\s*9999\s*\]/,
    'normalization sorts retired identities numerically'
);

for my $field (qw(code number)) {
    my $fixture = $nested_fixture->();
    my $first   = $conf->{exception_kinds}[0];
    $fixture->{exception_kinds} = [
        $first,
        {
            %$first,
            (
                $field eq 'code'
                ? ( number => 9999 )
                : ( code => 'CORE_TEST_KIND' )
            )
        }
    ];
    eval { Diag::Migration::diagnostics($fixture) };
    like( $@, qr/duplicate exception kind $field/, "exception kind $field identities are unique" );
}
my $unknown_kind = $nested_fixture->();
$unknown_kind->{exception_kinds} = [];
eval { Diag::Migration::diagnostics($unknown_kind) };
like( $@, qr/names an unregistered kind/, 'diagnostics must refer to a registered exception kind' );
my $implicit_macro = $nested_fixture->();
my $implicit_entry = $implicit_macro->{diagnostics}{FATAL_ERROR}{CORE_RUNTIME}{ $division->{code} };
$implicit_entry->{emit} = { %{ $division->{emit} } };
delete $implicit_entry->{macro};
is( Diag::Migration::macro_name($implicit_entry),
    'PERL_THROW_ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO', 'omitted macro names use the operation family' );
like(
    Diag::Migration::render_catalog($implicit_macro),
    qr/"macro" => "PERL_THROW_ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO"/,
    'normalization writes the generated macro name into the config'
);
$implicit_entry->{macro} = 'CUSTOM_DivisionError';
is( Diag::Migration::macro_name($implicit_entry), 'CUSTOM_DivisionError', 'an explicit macro name is used faithfully' );
like(
    Diag::Migration::render_catalog($implicit_macro),
    qr/"macro" => "CUSTOM_DivisionError"/,
    'normalization preserves an explicit macro name'
);
my $named_alias = $nested_fixture->();
my $alias_entry =
  $named_alias->{diagnostics}{FATAL_ERROR}{CORE_RUNTIME}{ $division->{code} };
$alias_entry->{emit} =
  { %{ $division->{emit} }, api => 'CROAK', aliases => ['DIE'] };
$alias_entry->{macro_aliases} = { DIE => 'PERL_THROW_DIVISION_RETURN' };
is( Diag::Migration::alias_macro_name( $alias_entry, 'DIE' ),
    'PERL_THROW_DIVISION_RETURN', 'explicit secondary names preserve distinct calling contracts' );
like(
    Diag::Migration::render_catalog($named_alias),
    qr/\{\s*"api"\s*=>\s*"DIE",\s*"macro"\s*=>\s*"PERL_THROW_DIVISION_RETURN"\s*\}/s,
    'normalization records the secondary name'
);
$alias_entry->{macro_aliases}{WARN} = 'PERL_WARN_DIVISION';
eval { Diag::Migration::diagnostics($named_alias) };
like( $@, qr/undeclared delivery alias/, 'names cannot introduce an undeclared delivery' );
delete $alias_entry->{macro_aliases}{WARN};
$alias_entry->{macro_aliases}{DIE} = $alias_entry->{macro};
eval { Diag::Migration::diagnostics($named_alias) };
like( $@, qr/duplicate diagnostic macro/, 'primary and secondary names cannot collide' );

for my $other (qw(primary alias format)) {
    my $fixture = $nested_fixture->();
    my $entry =
      $fixture->{diagnostics}{FATAL_ERROR}{CORE_RUNTIME}{ $division->{code} };
    $entry->{emit} = { %{ $division->{emit} } };
    my $macro = $other eq 'alias' ? 'PERL_WARN_CORE_TEST_MACRO' : 'COLLIDING_MACRO';
    $entry->{macro} = $macro;
    my $emit =
        $other eq 'primary' ? { api => 'WARN' }
      : $other eq 'alias'   ? { api => 'CROAK', aliases => ['WARN'] }
      :                       { api => 'WARN', format_macro => $macro };
    my $second = {
        %$division,
        number   => 9999,
        severity => 'WARNING',
        code     => 'CORE_TEST_MACRO',
        emit     => $emit,
    };
    delete $second->{macro};
    $second->{macro} = $macro if $other eq 'primary';
    $fixture->{diagnostics}{WARNING}{CORE_RUNTIME}{CORE_TEST_MACRO} = $second;
    eval { Diag::Migration::diagnostics($fixture) };
    like( $@, qr/duplicate diagnostic macro/, "macro names cannot collide with a $other macro" );
}
my @unordered = grep {
    my $diag     = Diag::Migration::canonical_diagnostic_schema($_);
    my @expected = grep { exists $diag->{$_} } qw(
      number severity kind code macro source_files tags is_panic is_render message operation_words counts_as_error variants
      compatibility translation_review emit class has_following_hint is_hint
    );
    join( '|', @{ Diag::Migration::catalog_key_order($diag) } ) ne join( '|', @expected )
} @$diagnostics;
is( scalar @unordered, 0, 'catalog definitions use the explicit definition field order' );
my ($syntax_error) = grep { $_->{code} eq 'ERROR_SYNTAX_INVALID' } @$diagnostics;
my $parser_fixture = sub {
    my %variants =
      map { $_ => { %{ $syntax_error->{variants}{$_} }, values => { %{ $syntax_error->{variants}{$_}{values} } } } }
      keys %{ $syntax_error->{variants} };
    return {
        severities      => $conf->{severities},
        exception_kinds => $conf->{exception_kinds},
        diagnostic_tags => $conf->{diagnostic_tags},
        diagnostics     => {
            FATAL_ERROR => {
                CORE_COMPILE => {
                    ERROR_SYNTAX_INVALID => {
                        %$syntax_error,
                        emit     => { %{ $syntax_error->{emit} } },
                        variants => \%variants
                    },
                }
            }
        },
    };
};
is( $syntax_error->{parser_action}, 'collect', 'shared syntax text can be collected without parser control' );
is( $syntax_error->{variants}{ERROR_SYNTAX_INVALID_RECOVER}{parser_action},
    'recover', 'grammar recovery has its own symbolic action' );
is( $syntax_error->{variants}{ERROR_SYNTAX_INVALID_ABORT}{parser_action},
    'abort', 'immediate parser abort has its own symbolic action' );
ok(
    eval { Diag::Migration::diagnostics( $parser_fixture->() ); 1 },
    'action-only variants can share one parser message'
);
for my $case (
    [ 'a missing action',                  sub { delete $_[0]{parser_action} }, qr/needs a parser_action/ ],
    [ 'an invalid action',                 sub { $_[0]{parser_action} = 'flush' },  qr/invalid parser_action/ ],
    [ 'caller control on a fixed message', sub { $_[0]{parser_action} = 'caller' }, qr/reserves caller action/ ],
    [
        'a controlled variant with a noncollecting parent',
        sub { $_[0]{parser_action} = 'abort' },
        qr/needs a collecting parent/
    ],
  )
{
    my ( $label, $change, $expected ) = @$case;
    my $fixture = $parser_fixture->();
    $change->( $fixture->{diagnostics}{FATAL_ERROR}{CORE_COMPILE}{ERROR_SYNTAX_INVALID} );
    eval { Diag::Migration::diagnostics($fixture) };
    like( $@, $expected, "parser definitions reject $label" );
}
my $nonparser_action = $nested_fixture->( parser_action => 'abort' );
eval { Diag::Migration::diagnostics($nonparser_action) };
like( $@, qr/parser_action without parser delivery/, 'parser actions cannot be attached to runtime errors' );
my $variant_fixture = sub {
    my $fixture = $nested_fixture->();
    my $entry =
      $fixture->{diagnostics}{FATAL_ERROR}{CORE_RUNTIME}{ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO};
    $entry->{message_template} = { en => 'Error in %{operation}: %{detail}' };
    $entry->{params}           = [
        { name => 'operation', type => 'text', format_str => 's' },
        { name => 'detail',    type => 'text', format_str => 's' },
    ];
    $entry->{emit}     = { api => 'CROAK', aliases => ['DIE'] };
    $entry->{variants} = {
        TEST_FIXED_OPERATION => {
            values => { operation => { en => 'lookup', fr => 'recherche' } },
            emit   => { api       => 'DIE' },
        },
    };
    return ( $fixture, $entry, $entry->{variants}{TEST_FIXED_OPERATION} );
};
{
    my ( $fixture, $entry, $variant ) = $variant_fixture->();
    ok( eval { Diag::Migration::diagnostics($fixture); 1 },
        'a specialization binds fixed text and chooses a declared delivery' );
    is(
        Diag::Migration::variant_macro_name( $entry, 'TEST_FIXED_OPERATION', $variant ),
        'PERL_THROW_TEST_FIXED_OPERATION',
        'a specialization has its own symbolic macro'
    );
    like(
        Diag::Migration::render_catalog($fixture),
        qr/"macro" => "PERL_THROW_TEST_FIXED_OPERATION"/,
        'normalization records the specialization macro name'
    );
    like(
        Diag::Migration::render_catalog($fixture),
        qr/"fr" => "recherche"/,
        'fixed parameter translations remain visible in the catalog'
    );
    $variant->{macro} = 'CUSTOM_FixedOperation';
    is( Diag::Migration::variant_macro_name( $entry, 'TEST_FIXED_OPERATION', $variant ),
        'CUSTOM_FixedOperation', 'explicit specialization names are preserved' );
    delete $variant->{emit};
    is( Diag::Migration::variant_api( $entry, $variant ),
        'CROAK', 'omitted specialization delivery inherits the shared API' );
}
for my $case (
    [ 'an unknown parameter',     sub { $_[2]{values}{missing} = { en => 'fixed' } }, qr/unknown message parameter/ ],
    [ 'missing English text',     sub { delete $_[2]{values}{operation}{en} },        qr/needs an English value/ ],
    [ 'a non-string translation', sub { $_[2]{values}{operation}{fr} = [] }, qr/invalid fixed value/ ],
    [ 'a NUL in fixed text',      sub { $_[2]{values}{operation}{en} = "bad\0text" }, qr/invalid fixed value/ ],
    [ 'no fixed bindings',        sub { $_[2]{values}                = {} }, qr/no fixed parameter values/ ],
    [ 'an undeclared delivery',   sub { $_[2]{emit}{api} = 'CROAK_NOCONTEXT' }, qr/undeclared delivery API/ ],
    [ 'delivery overrides',       sub { $_[2]{emit}{params} = [] }, qr/emit must contain only an API/ ],
    [ 'a compound binding',       sub { $_[1]{params}[0]{inputs} = [] }, qr/only bind simple text/ ],
    [ 'a numeric binding',        sub { $_[1]{params}[0]{type} = 'iv' }, qr/only bind simple text/ ],
    [ 'a misspelled field',       sub { $_[2]{value} = {} }, qr/unknown field/ ],
    [
        'a parser action on runtime delivery',
        sub { $_[2]{parser_action} = 'recover' },
        qr/parser_action without parser delivery/
    ],
    [ 'a primary macro collision', sub { $_[2]{macro} = $_[1]{macro} }, qr/duplicate diagnostic macro/ ],
    [
        'an alias macro collision',
        sub { $_[2]{macro} = Diag::Migration::alias_macro_name( $_[1], 'DIE' ) },
        qr/duplicate diagnostic macro/
    ],
    [
        'a code collision',
        sub {
            $_[1]{variants}{ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO} =
              delete $_[1]{variants}{TEST_FIXED_OPERATION};
        },
        qr/duplicate diagnostic code/
    ],
    [
        'a dynamic definition',
        sub { $_[1]{dynamic} = 'sv' },
        qr/needs a fixed message definition/
    ],
  )
{
    my ( $label, $change, $expected ) = @$case;
    my @fixture = $variant_fixture->();
    $change->(@fixture);
    eval { Diag::Migration::diagnostics( $fixture[0] ) };
    like( $@, $expected, "specializations reject $label" );
}
my @old_schema = grep {
         exists $_->{id}
      || exists $_->{args}
      || exists $_->{call_args}
      || exists $_->{aliases}
      || exists $_->{exception}
      || exists $_->{emitter}
      || exists $_->{delivery_params}
      || exists $_->{emitter_aliases}
      || exists $_->{props}
      || exists $_->{format}
      || exists $_->{template}
} @$diagnostics;
is( scalar @old_schema, 0, 'the catalog uses named templates and grouped delivery details' );
my $rendered_catalog = Diag::Migration::render_catalog($conf);
my $catalog_source = Diag::Migration::read_source('diag_conf.pl');
require Encode;
$catalog_source = Encode::decode( 'UTF-8', $catalog_source,
    Encode::FB_CROAK() | Encode::LEAVE_SRC() );
is( $rendered_catalog, $catalog_source,
    'regeneration preserves the schema POD and canonical catalog text' );
like( $rendered_catalog, qr/^use utf8;$/m,
    'the normalized catalog enables UTF-8 source literals' );
like( $rendered_catalog, qr/[^\x00-\x7f]/,
    'printable Unicode is stored directly in the catalog source' );
my $round_trip = eval Diag::Migration::render_catalog($conf);
ok( $round_trip && !$@, 'the normalized catalog remains executable Perl with POD' );
is(
    Diag::Migration::render_catalog($round_trip),
    Diag::Migration::render_catalog($conf),
    'canonical serialization is idempotent'
);
my @fixed = grep { !$_->{dynamic} } @$diagnostics;
is( scalar( grep { !exists $_->{message_template}{en} } @fixed ),
    0, 'every fixed diagnostic has an English named message template' );
my $pod = Diag::Migration::read_source('pod/perldiag.pod');
is( Diag::Documentation::render( $conf->{documentation} ),
    $pod, 'declarative documentation reproduces perldiag.pod byte for byte' );
is( Diag::Documentation::render( Diag::Documentation::import_pod($pod) ),
    $pod, 'importing the complete POD preserves its bytes' );
my $sample_pod = <<'POD';
=head1 NAME

example

=over 4

=item First %s
continued heading

=item Second %s

(F) One shared explanation.

=over 4

=item Nested detail

An example, not a diagnostic heading.

=back

=item Last

See the first entry.

=back

=cut
POD
my $docs = Diag::Documentation::import_pod($sample_pod);
is( scalar @{ $docs->{entries} },              2, 'nested lists do not create diagnostic entries' );
is( scalar @{ $docs->{entries}[0]{headings} }, 2, 'adjacent headings share an explanation' );
like( $docs->{entries}[0]{headings}[0], qr/continued heading/, 'multiline headings retain their continuation' );
is( Diag::Documentation::render($docs),
    $sample_pod, 'shared explanations, nested lists and multiline headings round trip' );
$docs->{entries}[1]{text} = "(F) A changed explanation.\n\n";
like(
    Diag::Documentation::render($docs),
    qr/A changed explanation/,
    'changing catalog data changes the generated documentation'
);
push @{ $docs->{entries} }, $docs->{entries}[0];
eval { Diag::Documentation::render($docs) };
like( $@, qr/duplicate documentation code/, 'the documentation renderer rejects duplicate identities' );
eval { Diag::Documentation::import_pod("=over 4\n\n=item broken\n\ntext\n") };
like( $@, qr/unbalanced or missing diagnostic POD list/, 'the importer rejects an unclosed diagnostic list' );
my $utf8 = Diag::Migration::parse_format(
    '"%" UTF8f', ['UTF8fARG(source_utf8, source_length, source_text)'], $formats
);
$utf8->{emit}{api} = 'CROAK';
my $reuse = Diag::Migration::parse_format( '"%" UTF8f', ['UTF8fARG(utf8, len, pv)'], $formats );
$reuse->{emit}{api} = 'CROAK';
is(
    Diag::Migration::signature($reuse),
    Diag::Migration::signature($utf8),
    'reuse ignores argument names while retaining formatter and input types'
);
$reuse->{params}[0]{format_str} = 'UTF8f_QUOTEDPREFIX';
ok(
    Diag::Migration::signature($reuse) ne Diag::Migration::signature($utf8),
    'quoted-prefix formatter is a distinct diagnostic signature'
);

my $header         = Diag::Migration::read_source('perldiag.h');
my $helpers        = Diag::Migration::read_source('perldiag_helpers.inc');
my ($inplace_edit) = grep { $_->{code} eq 'ERROR_IO_INPLACE_EDIT_PATH_CONTEXT_INVALID' } @$diagnostics;
is(
    join( ',', @{ $inplace_edit->{params}[1]{selector_values} } ),
    'cwd_changed,work_file_missing',
    'in-place edit failures select messages by semantic reason'
);
my $doio = Diag::Migration::read_source('doio.c');
like(
    $doio,
    qr/PERL_THROW_ERROR_IO_INPLACE_EDIT_PATH_CONTEXT_INVALID\(\s*orig_pv,\s*perl_diag_selector_domain_1181_0_cwd_changed_1\)/s,
    'in-place edit directory changes pass a symbolic selector value'
);
like(
    $doio,
    qr/PERL_THROW_ERROR_IO_INPLACE_EDIT_PATH_CONTEXT_INVALID\(\s*orig_pv,\s*perl_diag_selector_domain_1181_0_work_file_missing_2\)/s,
    'in-place edit work-file failures pass a symbolic selector value'
);
my ($undefined_reference) = grep { $_->{code} eq 'ERROR_TYPE_UNINITIALIZED_REFERENCE_VALUE_REQUIRED' } @$diagnostics;
is(
    join( ',', @{ $undefined_reference->{params}[0]{selector_values} } ),
    'array,filehandle,hash,scalar,subroutine,symbol',
    'undefined reference messages select complete text by reference kind'
);
my $pp     = Diag::Migration::read_source('pp.c');
my $pp_hot = Diag::Migration::read_source('pp_hot.c');
unlike(
    "$pp\n$pp_hot",
    qr/PERL_THROW_ERROR_TYPE_UNINITIALIZED_REFERENCE_VALUE_REQUIRED(?:_DIE|_NO_CONTEXT)?\(\s*"(?:a |an )/,
    'undefined reference callers pass semantic kinds instead of article fragments'
);

for my $code (qw( ERROR_TYPE_REFERENCE_REFERENT_TYPE_MISMATCH ERROR_MUTATION_REFERENCE_ALIASING_REFERENT_TYPE_MISMATCH )) {
    my ($diag) = grep { $_->{code} eq $code } @$diagnostics;
    ok( @{ $diag->{params}[0]{selector_values} } > 1, "$code selects complete messages by semantic reference kind" );
}
my ($not_reference)      = grep { $_->{code} eq 'ERROR_TYPE_REFERENCE_REFERENT_TYPE_MISMATCH' } @$diagnostics;
my ($not_glob_reference) = grep { $_->{code} eq 'ERROR_TYPE_REFERENCE_GLOB_OR_IO_REQUIRED' } @$diagnostics;
is(
    join( ',', @{ $not_reference->{params}[0]{selector_values} } ),
    join( ',', @{ $META->{reftype_name} } ),
    'typed-reference failures use the shared Perl reference-type domain'
);
is(
    join( ' ', sort keys %{ $not_reference->{message_template}{en} } ),
    '* ARRAY INVLIST IO OBJECT UNKNOWN',
    'the English reference message selects only its vowel-conformance cases'
);
is( join( ' ', sort keys %{ $not_reference->{message_template}{fr} } ),
    '*', 'the French reference message uses one parameterized template' );
for my $check (
    [ ERROR_TYPE_REFERENCE_ARRAY_REQUIRED  => 'ARRAY',  'DIE' ],
    [ ERROR_TYPE_REFERENCE_EXPECTED_CODE   => 'CODE',   'DIE' ],
    [ ERROR_TYPE_REFERENCE_HASH_REQUIRED   => 'HASH',   'DIE' ],
    [ ERROR_TYPE_REFERENCE_SCALAR_REQUIRED => 'SCALAR', 'DIE' ],
  )
{
    my ( $code, $reference_type, $api ) = @$check;
    is( $not_reference->{variants}{$code}{values}{reference_type}{en},
        $reference_type, "$code specializes the shared reference diagnostic" );
    is( $not_reference->{variants}{$code}{emit}{api} || 'DIE', $api, "$code preserves its $api delivery" );
}
is( $not_glob_reference->{emit}{api}, 'DIE_NOCONTEXT', 'GLOB failures keep their no-context delivery' );
my ($wide_character_operation) = grep { $_->{code} eq 'WARNING_UTF8_WIDE_CHARACTER_IN_BYTE_OPERATION' } @$diagnostics;
is(
    join( ',', @{ $wide_character_operation->{params}[0]{selector_values} } ),
    'print,program_name,setenv,setenv_key_encoding,warn',
    'wide-character operation messages select complete localized wording'
);
like(
    $pp_hot,
    qr/PERL_THROW_ERROR_TYPE_REFERENCE_REFERENT_TYPE_MISMATCH\(\s*is_pp_rv2av\s*\?\s*perl_diag_selector_domain_1172_0_array_2\s*:\s*perl_diag_selector_domain_1172_0_hash_3/s,
    'not-reference callers pass symbolic Perl reference types'
);
unlike(
    $pp_hot,
    qr/PERL_THROW_ERROR_MUTATION_REFERENCE_ALIASING_REFERENT_TYPE_MISMATCH\(bad\)/,
    'assigned-reference callers do not pass assembled wording'
);
my $os2 = Diag::Migration::read_source('os2/os2.c');
like( $os2, qr/PERL_THROW_ERROR_SYSTEM_SYSCALL_FUNCTION_UNAVAILABLE\("fork"\)/, 'unimplemented-function callers pass the function name' );
my $mg = Diag::Migration::read_source('mg.c');
like( $mg, qr/PERL_THROW_ERROR_MUTATION_REFERENCE_ALIASING_REFERENT_TYPE_MISMATCH\(PERL_DIAG_SELECTOR_FROM_ERROR_MUTATION_REFERENCE_ALIASING_REFERENT_TYPE_MISMATCH_REFERENCE_TYPE\(bad\)\)/,
    'magic assignment converts its dynamic selector at the shared CROAK boundary' );
unlike(
    $mg,
    qr/PERL_WARN_WARNING_UTF8_WIDE_CHARACTER_IN_BYTE_OPERATION\("setenv key/,
    'wide-character warning callers pass an operation selector'
);
my ($strict_refs_bareword) = grep { $_->{code} eq 'ERROR_STRICT_REFS_BAREWORD_REFERENCE_FORBIDDEN' } @$diagnostics;
is( join( ',', @{ $strict_refs_bareword->{params}[1]{selector_values} } ),
    'array,hash,scalar', 'strict-reference barewords select complete text by reference kind' );
my $op = Diag::Migration::read_source('op.c');
unlike( $op, qr/reference_kind\s*=\s*"(?:a |an )/, 'strict-reference bareword callers do not pass article fragments' );
like(
    $header,
    qr/^#define PERL_FORMAT_ERROR_TAINT_DEPENDENCY_INSECURE "Insecure dependency in %s%s"$/m,
    'taint selector templates preserve the legacy dispatch format'
);
my @helper_names = $helpers =~ /^(Perl_(?:diag|throw)_\w+)\(/mg;
is(
    join( "\n", @helper_names ),
    join( "\n", sort @helper_names ),
    'generated helper definitions are sorted alphabetically by name'
);

sub generated_macro_body {
    my ( $header, $name ) = @_;
    my ($body) = $header =~ /^#define \Q$name\E[^\n]*\n(.*?)(?=^#define|\z)/ms;
    return $body;
}

sub macro_uses_catalog_entry {
    my ( $header, $name, $code ) = @_;
    my $body = generated_macro_body( $header, $name );
    my $lower_code = lc $code;
    return defined($body) && $body =~ /\bperl_diag_\Q$lower_code\E_idx\b/;
}

like(
    $helpers,
qr/Perl_throw_croak_[0-9]+_[0-9]+\(pTHX_ UV diag_index\)\n\{\n    Perl_diag_croak_sv\(aTHX_ diag_index, NULL, NULL\);/,
    'argumentless fatal helpers delegate template selection to the throw API'
);
like(
    $header,
    qr/^#define PERL_THROW_ERROR_UNICODE_UTF8_UNPACK_STRING_INVALID\(\) \\\n\s+Perl_throw_croak_[0-9]+_[0-9]+\(/m,
    'argumentless diagnostics reuse the shared fatal helper'
);
like(
    $helpers,
qr/Perl_throw_die_nocontext_[0-9]+_[0-9]+\(UV diag_index\)\n\{\n\s*dTHX;\n\s*Perl_diag_die_nocontext_sv\(diag_index, NULL, NULL\);/,
    'context-free DIE helpers retain their no-context API'
);
like(
    $helpers,
qr/Perl_throw_warn_nocontext_[0-9]+_[0-9]+\(UV diag_index,[\s\S]*?\n\s*Perl_diag_warn_nocontext_sv\(diag_index, params_av, NULL\);/,
    'context-free warning helpers retain their no-context API'
);
like(
    $header,
qr/^#define PERL_WARN_WARNING_INTERNAL_MEMORY_WINDOWS_FREE_TO_WRONG_POOL\(ma_arg1, ma_arg2\) \\\n\s*Perl_throw_warn_nocontext_[0-9]+_[0-9]+\(/m,
    'context-free warning macros call the shared helper'
);
my ($hek_helper) =
  generated_macro_body( $header, 'PERL_THROW_ERROR_OBJECT_METHOD_CALL_NAMED_NATIVE_INSTANCE_REQUIRED' ) =~
  /(Perl_throw_croak_[0-9]+_[0-9]+)/;
like(
    $header,
    qr/^#define PERL_THROW_ERROR_OBJECT_METHOD_CALL_NAMED_NATIVE_INSTANCE_REQUIRED\(ma_name\) \\\n\s*Perl_throw_croak_[0-9]+_[0-9]+\(/m,
    'expression-compatible HEK diagnostics call a shared helper'
);
like(
    $helpers,
    qr/\Q$hek_helper\E\(pTHX_[\s\S]*?HEKfARG\(ma_arg1\)\);/,
    'shared helpers preserve HEK conversion and quoted-prefix formatting'
);
like(
    generated_macro_body( $header, 'PERL_WARN_WARNING_ONCE_PACKAGE_NAME_USED_ONCE' ),
    qr/Perl_throw_warner_[0-9]+_[0-9]+\([\s\S]*?packWARN\(WARN_ONCE\)/,
    'the warning macro calls its warning helper with the configured category'
);
like(
    generated_macro_body( $header, 'PERL_THROW_WARNING_ONCE_PACKAGE_NAME_USED_ONCE' ),
    qr/Perl_throw_fatal_warner_[0-9]+_[0-9]+\([\s\S]*?packWARN\(WARN_ONCE\)/,
    'the fatal-warning alias calls its own emitter helper'
);
my ($runtime_category_helper) =
  generated_macro_body( $header, 'PERL_WARN_WARNING_IO_OPERATION_ON_CLOSED_OR_UNOPENED_HANDLE' ) =~
  /(Perl_throw_warner_[0-9]+_[0-9]+)/;
like(
    $helpers,
qr/\Q$runtime_category_helper\E\(pTHX_ UV diag_index,[\s\S]*?U32 category\)\n\{[\s\S]*?Perl_diag_warner_sv\(aTHX_ diag_index, params_av, category, NULL\);/,
    'shared warning helpers accept runtime categories as delivery arguments'
);
like(
    generated_macro_body( $header, 'PERL_WARN_WARNING_IO_OPERATION_ON_CLOSED_OR_UNOPENED_HANDLE' ),
    qr/\Q$runtime_category_helper\E\([\s\S]*?\n\s*category \\\n\s*\)/,
    'runtime warning category macros forward the category to their helper'
);
my ($precision_helper) =
  generated_macro_body( $header, 'PERL_WARN_WARNING_OVERFLOW_TIME_INPUT_OUT_OF_RANGE' ) =~ /(Perl_throw_ck_warner_[0-9]+_[0-9]+)/;
like(
    $helpers,
qr/\Q$precision_helper\E\(pTHX_ UV diag_index,[\s\S]*?Perl_diag_setup_param\(aTHX_ params_av, diag_index, 1,\s*0, perl_diag_selector_invalid\)[\s\S]*?sv_setpvf\(tmpl_arg2, ma_fmt2, ma_arg2\);/,
    'shared helpers preserve configured numeric format prefixes'
);
my ($hex_helper) =
  generated_macro_body( $header, 'PERL_THROW_ERROR_SYNTAX_QUOTED_STRING_TRANSLITERATION_RANGE_REVERSED_HEX_ESCAPE' ) =~
  /(Perl_throw_croak_[0-9]+_[0-9]+)/;
my ($other_hex_helper) =
  generated_macro_body( $header, 'PERL_THROW_ERROR_SYNTAX_QUOTED_STRING_TRANSLITERATION_RANGE_REVERSED_NAMED_ESCAPE' ) =~
  /(Perl_throw_croak_[0-9]+_[0-9]+)/;
like(
    $helpers,
qr/\Q$hex_helper\E\(pTHX_ UV diag_index,[\s\S]*?Perl_diag_setup_param\(aTHX_ params_av, diag_index, 0,\s*0, perl_diag_selector_invalid\)[\s\S]*?sv_setpvf\(tmpl_arg1, ma_fmt1, ma_arg1\);/,
    'shared helpers preserve zero-padded hexadecimal format prefixes'
);
is( $other_hex_helper, $hex_helper,                 'diagnostics with the same prefixed formatter reuse one helper' );
like( $hex_helper, qr/^Perl_throw_croak_\d+_\d+$/, 'helper names use input count and diagnostic number' );
like(
    generated_macro_body( $header, 'PERL_THROW_ERROR_SYNTAX_QUOTED_STRING_TRANSLITERATION_RANGE_REVERSED_HEX_ESCAPE' ),
    qr/"%04" UVXf, \\\n\s*ma_min/,
    'hex diagnostics pass their configured formatter as a helper argument'
);
like(
    generated_macro_body( $header, 'PERL_WARN_WARNING_OVERFLOW_TIME_INPUT_OUT_OF_RANGE' ),
    qr/"%\.0" NVff, \\\n\s*ma_arg2/,
    'numeric diagnostics pass their configured formatter as a helper argument'
);
like(
    generated_macro_body( $header, 'PERL_DEPRECATE_WARNING_DEPRECATED_DELIMITER_WILL_BE_PAIRED_UNPAIRED_DELIMITER_USED' ),
    qr/Perl_throw_ck_warner_d_1_2099\(/,
    'composed UTF8 inputs count as one conceptual input'
);
my ($default_helper) =
  generated_macro_body( $header, 'PERL_THROW_ERROR_OBJECT_COMPOSITION_NATIVE_ROLE_REQUIRED' ) =~
  /(Perl_throw_croak_[0-9]+_[0-9]+)/;
like(
    $helpers,
qr/\Q$default_helper\E\(pTHX_ UV diag_index,\n\s*HV \*ma_arg1,[\s\S]*?const char \*ma_default1\)[\s\S]*?const perl_hvname_default scratch_default_arg1 = \{ ma_arg1, ma_default1 \};[\s\S]*?PERL_HvNAMEf_DEFAULT, &scratch_default_arg1/,
    'shared helpers parameterize custom-format fallback values'
);
like(
    generated_macro_body( $header, 'PERL_THROW_ERROR_OBJECT_COMPOSITION_NATIVE_ROLE_REQUIRED' ),
    qr/\Q$default_helper\E\([\s\S]*?"\(unknown\)" \\\n\s*\)/,
    'custom-format helpers receive the configured fallback'
);
my ($hvname_helper) =
  generated_macro_body( $header, 'PERL_THROW_ERROR_OBJECT_CONSTRUCTOR_CLASS_INCOMPLETE' ) =~
  /(Perl_throw_croak_[0-9]+_[0-9]+)/;
my ($other_hvname_helper) =
  generated_macro_body( $header, 'PERL_THROW_ERROR_OBJECT_DEFINITION_CLASS_REOPEN_FORBIDDEN' ) =~ /(Perl_throw_croak_[0-9]+_[0-9]+)/;
like(
    $helpers,
    qr/\Q$hvname_helper\E\(pTHX_[\s\S]*?HvNAMEfARG\(ma_arg1\)\)/,
    'shared helpers preserve quoted HV-name formatting'
);
is( $other_hvname_helper, $hvname_helper, 'diagnostics with the same HV-name formatter reuse one helper' );
like(
    $header,
    qr/^#define PERL_APPEND_WARNING_SYNTAX_CONTROL_ESCAPE_PRINTABLE_RESULT\(exception_slot, ma_arg1, ma_arg2\) /m,
    'configured append macros remain available with helper-based producers'
);
like(
    generated_macro_body( $header, 'PERL_APPEND_WARNING_SYNTAX_CONTROL_ESCAPE_PRINTABLE_RESULT' ),
    qr/Perl_throw_append_warning_[0-9]+_[0-9]+\([\s\S]*?\(const char \*\)\(ma_arg2\)/,
    'text arguments are cast to the helper parameter type'
);
my ($taint_helper) =
  generated_macro_body( $header, 'PERL_CHECK_TAINT_ERROR_TAINT_DEPENDENCY_INSECURE' ) =~ /(Perl_throw_taint_[0-9]+_[0-9]+)/;
like(
    $helpers,
qr/\Q$taint_helper\E\(pTHX_ UV diag_index,[\s\S]*?if \(PL_unsafe \|\| TAINT_WARN_get\)[\s\S]*?Perl_diag_taint_warner_d_sv\(aTHX_ diag_index, params_av, packWARN\(WARN_TAINT\), NULL\);[\s\S]*?Perl_diag_croak_sv\(aTHX_ diag_index, params_av, NULL\);/,
    'taint helpers retain their warning-or-croak delivery policy'
);
my ($other_taint_helper) =
  generated_macro_body( $header, 'PERL_CHECK_TAINT_ERROR_TAINT_ENVIRONMENT_GLOB_ALIAS_FORBIDDEN' ) =~ /(Perl_throw_taint_[0-9]+_[0-9]+)/;
is( $other_taint_helper, $taint_helper, 'taint diagnostics with matching arguments reuse one helper' );
my ($append_helper) =
  generated_macro_body( $header, 'PERL_APPEND_ERROR_COMPILATION_FAILED' ) =~
  /(Perl_throw_append_exception_[0-9]+_[0-9]+)/;
my ($append_helper_body) = $helpers =~ /(^\Q$append_helper\E\([\s\S]*?^\})/m;
like(
    $helpers,
qr/\Q$append_helper\E\(pTHX_ UV diag_index,\n\s*SV \*\*exception_slot\)[\s\S]*?Perl_diag_append\(aTHX_ exception_slot, NULL, diag_index, NULL, 0\);/,
    'argumentless append helpers preserve the accumulator delivery'
);
unlike(
    $append_helper_body,
    qr/Perl_diag_format_template/,
    'append helpers do not render a template before storing diagnostic data'
);
my ($append_text_helper) =
  generated_macro_body( $header, 'PERL_APPEND_ERROR_LOAD_NOT_FOUND_IN_INC' ) =~
  /(Perl_throw_append_exception_[0-9]+_[0-9]+)/;
my ($other_append_text_helper) =
  generated_macro_body( $header, 'PERL_APPEND_ERROR_PHASE_CALL_QUEUE_ABORTED' ) =~
  /(Perl_throw_append_exception_[0-9]+_[0-9]+)/;
like(
    $helpers,
qr/\Q$append_text_helper\E\(pTHX_ UV diag_index,[\s\S]*?Perl_diag_append\(aTHX_ exception_slot, NULL, diag_index, params_av, 0\);/,
    'append helpers pass structured parameters into the accumulator'
);
is( $other_append_text_helper, $append_text_helper, 'append diagnostics with matching arguments reuse one helper' );
unlike( $header . $helpers, qr/template_args_av/, 'generated producers do not allocate template argument arrays' );
ok(
    $header !~ /PERL_DIAG_LEGACY_|PERL_DIAG_DYNAMIC_YYERROR|__VA_ARGS__/
    ,
    'the generated diagnostic interface has no legacy or variadic adapters'
);

for my $case (
    [ 'PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_DISPATCH_ON_OUTSIDE_DISPATCH',    'ERROR_SYNTAX_DISPATCH_ON_OUTSIDE_DISPATCH' ],
    [ 'PERL_PANIC_ERROR_INTERNAL_FORMAT_PRINTF_FREXP_EXPONENT_UNSET',                              'ERROR_INTERNAL_FORMAT_PRINTF_FREXP_EXPONENT_UNSET' ],
    [ 'PERL_THROW_WARNING_ONCE_PACKAGE_NAME_USED_ONCE',                            'WARNING_ONCE_PACKAGE_NAME_USED_ONCE' ],
    [ 'PERL_WARN_WARNING_REGEXP_QUANTIFIER_FIXED_COUNT_GREEDINESS_IGNORED',         'WARNING_REGEXP_QUANTIFIER_FIXED_COUNT_GREEDINESS_IGNORED' ],
    [ 'PERL_DEPRECATE_WARNING_DEPRECATED_COMPONENT_REMOVAL_SCHEDULED',       'WARNING_DEPRECATED_COMPONENT_REMOVAL_SCHEDULED' ],
    [ 'PERL_WARN_WARNING_LOCALE_WIDE_CHARACTER_UNDER_BYTE_CTYPE',          'WARNING_LOCALE_WIDE_CHARACTER_UNDER_BYTE_CTYPE' ],
    [ 'PERL_WARN_WARNING_INTERNAL_MEMORY_WINDOWS_FREE_TO_WRONG_POOL',                     'WARNING_INTERNAL_MEMORY_WINDOWS_FREE_TO_WRONG_POOL' ],
    [ 'PERL_WARN_WARNING_SEVERE_INTERNAL_SCALAR_FREE_OUTSIDE_ARENAS',                          'WARNING_SEVERE_INTERNAL_SCALAR_FREE_OUTSIDE_ARENAS' ],
    [ 'PERL_APPEND_COMPOSED_LOCALE_WARNING',                  'WARNING_LOCALE_CTYPE_CHARACTER_SEMANTICS_UNEXPECTED' ],
    [ 'PERL_WARN_WARNING_UTF8_NON_UNICODE_PERL_EXTENDED_CODEPOINT',                           'WARNING_UTF8_NON_UNICODE_PERL_EXTENDED_CODEPOINT' ],
    [ 'PERL_WARN_WARNING_UTF8_WIDE_CHARACTER_IN_BYTE_OPERATION',                'WARNING_UTF8_WIDE_CHARACTER_IN_BYTE_OPERATION' ],
    [ 'PERL_WARN_WARNING_OVERFLOW_TIME_INPUT_OUT_OF_RANGE',                    'WARNING_OVERFLOW_TIME_INPUT_OUT_OF_RANGE' ],
    [ 'PERL_THROW_ERROR_SYSTEM_SYSCALL_FUNCTION_UNAVAILABLE_DIE',                'ERROR_SYSTEM_SYSCALL_FUNCTION_UNAVAILABLE' ],
    [ 'PERL_THROW_ERROR_IO_SOCKET_OPERATION_UNAVAILABLE',               'ERROR_IO_SOCKET_OPERATION_UNAVAILABLE' ],
    [ 'PERL_THROW_ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH',                            'ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH' ],
    [ 'PERL_THROW_ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH_NO_CONTEXT',                 'ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH' ],
    [ 'PERL_THROW_ERROR_UNSUPPORTED_OPERATION_NOT_IMPLEMENTED_DIE',                       'ERROR_UNSUPPORTED_OPERATION_NOT_IMPLEMENTED' ],
    [ 'PERL_WARN_WARNING_OVERFLOW_INTEGER_LITERAL_RANGE_EXCEEDED_DEFAULT_ENABLED', 'WARNING_OVERFLOW_INTEGER_LITERAL_RANGE_EXCEEDED' ],
    [ 'PERL_THROW_ERROR_UNSUPPORTED_OPERATION_NOT_IMPLEMENTED_NO_CONTEXT',                'ERROR_UNSUPPORTED_OPERATION_NOT_IMPLEMENTED' ],
    [ 'PERL_PANIC_ERROR_INTERNAL_THREADS_API_FAILED_AT_LOCATION',       'ERROR_INTERNAL_THREADS_API_FAILED_AT_LOCATION' ],
    [ 'PERL_PANIC_ERROR_INTERNAL_THREADS_API_FAILED_WITH_RETURN_CODE',           'ERROR_INTERNAL_THREADS_API_FAILED_WITH_RETURN_CODE' ],
    [ 'PERL_PANIC_ERROR_INTERNAL_THREADS_CONDITION_API_FAILED_WITH_RETURN_CODE',        'ERROR_INTERNAL_THREADS_CONDITION_API_FAILED_WITH_RETURN_CODE' ],
    [ 'PERL_PANIC_ERROR_INTERNAL_THREADS_CONDITION_API_FAILED_WITH_STATUS',                'ERROR_INTERNAL_THREADS_CONDITION_API_FAILED_WITH_RETURN_CODE' ],
  )
{
    my ( $macro, $code ) = @$case;
    ok( macro_uses_catalog_entry( $header, $macro, $code ), "$macro passes its catalog index to generated code", );
}
my $locale_warning_macro = generated_macro_body( $header, 'PERL_APPEND_COMPOSED_LOCALE_WARNING' );
my ($locale_warning_helper) = $locale_warning_macro =~ /(Perl_throw_append_exception_[0-9]+_[0-9]+)/;
like(
    $locale_warning_macro,
    qr/Perl_throw_append_exception_[0-9]+_[0-9]+/,
    'locale character warning uses the generated append helper'
);
like(
    $helpers,
qr/\Q$locale_warning_helper\E\(pTHX_ UV diag_index,[\s\S]*?SV \*\*exception_slot,[\s\S]*?U32 category[\s\S]*?Perl_diag_append\(aTHX_ exception_slot, NULL, diag_index, params_av, category\);/,
    'locale character warning retains structured data and warning category'
);
like( $locale_warning_macro, qr/packWARN\(WARN_LOCALE\)/,
    'locale character warning appends with its warning category' );
my $unsupported_locale_macro = generated_macro_body( $header, 'PERL_APPEND_WARNING_LOCALE_CTYPE_LOCALE_UNSUPPORTED' );
like( $unsupported_locale_macro, qr/packWARN\(WARN_LOCALE\)/,
    'unsupported locale warning uses the same warning accumulator category' );
my $dispatch_body = generated_macro_body( $header, 'PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_DISPATCH_ON_OUTSIDE_DISPATCH' );
like(
    $dispatch_body,
    qr/Perl_yyerror_diag_pvn_params\(aTHX_ perl_diag_error_syntax_dispatch_on_outside_dispatch_idx,/,
    'dispatch parser errors retain the structured diagnostic parameters'
);
like( $dispatch_body, qr/\bYYERROR;/, 'dispatch parser errors still enter grammar recovery' );
like(
    generated_macro_body( $header, 'PERL_ADD_COMPILE_ERR_ERROR_REGEXP_MODIFIER_LITERAL_UNKNOWN' ),
    qr/sv_setpvf\(tmpl_modifier, "%\.\*s", in_length, in_modifier\)/,
    'parser diagnostic macros share per-parameter setup'
);
my $unknown_class_body = generated_macro_body( $header, 'PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_DECLARATION_VARIABLE_TYPE_PACKAGE_NOT_FOUND' );
like(
    $unknown_class_body,
    qr/UTF8fARG\(in_is_utf8, in_length/,
    'unknown class names retain their UTF-8 encoding and byte length'
);
like(
    $unknown_class_body,
qr/Perl_yyerror_diag_pvn_params\(aTHX_ perl_diag_error_syntax_declaration_variable_type_package_not_found_idx,[\s\S]*?params_av\)/,
    'typed parser templates still use parser error accumulation'
);
like(
    $header,
qr/^#define PERL_WARN_WARNING_UTF8_TWO_BYTE_SEQUENCE_CONTINUATION_INVALID\(ma_operation_identity, ma_bytes, ma_unexpected_byte, ma_start_byte, ma_context_selector, ma_operation\)/m,
    'UTF-8 warning inputs keep byte data separate from message wording'
);
my $syntax_error_body = generated_macro_body( $header, 'PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_INVALID' );
like(
    $syntax_error_body,
    qr/Perl_yyerror_diag_pvn_params\(aTHX_ perl_diag_error_syntax_invalid_idx, NULL, 0, 0, NULL\)/,
    'zero-argument catalogued parser errors defer rendering'
);
unlike(
    $syntax_error_body,
    qr/Perl_diag_format_template/,
    'zero-argument parser macros do not format an unused message'
);
my $unclassified_parser_body = generated_macro_body(
    $header, 'PERL_ADD_COMPILE_ERR_ERROR_COMPILATION_UNCLASSIFIED_PARSER_ERROR'
);
like(
    $unclassified_parser_body,
qr/sv_setpvf\(tmpl_message, "%" SVf, SVfARG\(scratch_message_copy\)\);[\s\S]*?Perl_yyerror_diag_pvn_params\(aTHX_ perl_diag_error_compilation_unclassified_parser_error_idx, NULL, 0, 0, params_av\)/,
    'unclassified parser diagnostics keep their caller-supplied message as data'
);
my $deferred_error_body = generated_macro_body(
    $header, 'PERL_ADD_COMPILE_ERR_ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME'
);
like(
    $deferred_error_body,
qr/Perl_defer_error_diag_params\(aTHX_ &PL_sv_undef, perl_diag_error_strict_vars_global_symbol_requires_explicit_package_name_idx, params_av, 0\)/,
    'deferred parser errors record structured data without rendering early'
);
unlike(
    $deferred_error_body,
    qr/Perl_diag_format_template/,
    'deferred parser macros leave text rendering to the consumer'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_INVALID_RECOVER\(\)\x20
    \\\n\s*STMT_START\x20\{\x20
    \\\n\s*PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_INVALID\(\);\x20\\\n\s*YYERROR;\x20
    \\\n\s*\}\x20STMT_END
/mx,
    'an action-only variant shares its message and enters recovery'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_INVALID_ABORT\(\)\x20
    \\\n\s*STMT_START\x20\{\x20
    \\\n\s*PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_INVALID\(\);\x20
    \\\n\s*yyquit\(\);\x20\\\n\s*\}\x20STMT_END
/mx,
    'an action-only variant shares its message and aborts'
);
like(
    generated_macro_body( $header, 'PERL_THROW_ERROR_CALL_BINDING_ARITY_ODD_SLURPY_HASH_ARGUMENT_COUNT' ),
    qr/Perl_diag_croak_caller_sv\(/,
    'signature errors retain caller-context delivery'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_THROW_ERROR_MEMORY_ALLOCATION_FAILED\(\)\x20
    \\\n\s*Perl_noperl_die\("Out\x20of\x20memory\x20in\x20perl:\?\?\?"\)
/mx,
    'context-free allocation failures use a complete catalog message'
);
like(
    $header,
    qr/^#define PERL_THROW_ERROR_USER_OPAQUE_SV_DELIVERY_DIE_SV\(ma_message\) \\\n\s*die_sv\(ma_message\)/m,
    'SV forwarding delivers the original SV to die_sv'
);
like(
    $header,
    qr/^#define PERL_WARN_SV\(ma_message\) \\\n\s*warn_sv\(ma_message\)/m,
    'SV warning forwarding retains warn_sv delivery'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_WARN_WARNING_EXPERIMENTAL_VLB_CAPTURING_LOOKBEHIND_USED[^\n]*\x20
    \\\n\s*STMT_START\x20\{[\s\S]*?if\x20
    \(!RExC_warned_WARN_EXPERIMENTAL__VLB\)\x20\{\x20
    \\\n\s*RExC_warned_WARN_EXPERIMENTAL__VLB\x20=\x201;
/mx,
    'experimental regex warnings retain their per-compilation once flag'
);
like(
    $header,
qr/^#define PERL_WARN_WARNING_REGEXP_QUANTIFIER_FIXED_COUNT_GREEDINESS_IGNORED\(ma_arg1, location\) \\\n\s*STMT_START.*?Perl_diag_ck_warner_regex_sv\(aTHX_ perl_diag_warning_regexp_quantifier_fixed_count_greediness_ignored_idx,[^\n]*REPORT_LOCATION/ms,
    'regex warnings retain suppression and source location reporting'
);
my ($regex_modifier_macro) = $header =~ /(^#define PERL_WARN_WARNING_REGEXP_MODIFIER_INLINE_GLOBAL_OR_ONCE_IGNORED\(.*?^    \} STMT_END)/ms;
my ($regex_continue_macro) = $header =~ /(^#define PERL_WARN_WARNING_REGEXP_MODIFIER_INLINE_CONTINUE_IGNORED\(.*?^    \} STMT_END)/ms;
like(
    $regex_modifier_macro,
    qr/SV \* const message_sv = NULL;[\s\S]*?WARN_HELPER_\(location, packWARN\(WARN_REGEXP\), Perl_diag_warner_sv/s,
    'regex selector templates defer rendering and retain warning location'
);
like(
    $regex_continue_macro,
    qr/SV \* const message_sv = NULL;[\s\S]*?WARN_HELPER_\(location, packWARN\(WARN_REGEXP\), Perl_diag_warner_sv/s,
    'regex continue selector templates defer rendering and retain warning location'
);
my $regex_signature = {
    %$reuse,
    warning_categories => ['WARN_REGEXP'],
    emit               => {
        api            => 'CK_WARNER_CONTEXT',
        regex_location => 1,
        params         => [ { name => 'location', type => 'ptr', role => 'regex_location' } ]
    },
};
my %other_location = (
    %$regex_signature,
    emit => {
        %{ $regex_signature->{emit} }, params => [ { name => 'end', type => 'ptr', role => 'regex_location' } ]
    }
);
is(
    Diag::Migration::signature($regex_signature),
    Diag::Migration::signature( \%other_location ),
    'regex warning reuse ignores the location parameter name'
);
$other_location{emit}{warn_once} = 'WARN_EXPERIMENTAL__VLB';
ok( Diag::Migration::signature($regex_signature) ne Diag::Migration::signature( \%other_location ),
    'regex warning reuse distinguishes per-compilation warning state' );
ok(
    $header !~ /^#define PERL_DIAG_LEGACY_(?:ck_warner(?:_d)?|warner)\(/m,
    'retired categorized warning adapters are not generated'
);
is( join( '|', @{ Diag::Migration::warning_categories('packWARN2(WARN_UTF8, WARN_PORTABLE)') } ),
    'WARN_UTF8|WARN_PORTABLE', 'packed warning categories retain order' );
ok(
    !Diag::Migration::warning_categories('packWARN2(WARN_UTF8)'),
    'packed warning categories must match their declared count'
);
ok( !Diag::Migration::warning_categories('packWARN(category)'),
    'runtime warning categories remain delivery arguments' );
my $warning = Diag::Migration::parse_format( '"Wide character in %s"', ['operation'], $formats );
$warning->{emit}{api} = 'CK_WARNER_D';
$warning->{warning_categories} = ['WARN_UTF8'];
my %other_warning = (
    %$warning,
    warning_categories => ['WARN_IO'],
    emit               => { %{ $warning->{emit} } }
);
ok(
    Diag::Migration::signature($warning) ne Diag::Migration::signature( \%other_warning ),
    'reuse distinguishes warning categories for identical message text'
);
$other_warning{warning_categories} = ['WARN_UTF8'];
$other_warning{emit}{api} = 'WARNER';
ok( Diag::Migration::signature($warning) ne Diag::Migration::signature( \%other_warning ),
    'reuse distinguishes checked and unconditional warning delivery' );
my ( $lock_params, $lock_call ) = $header =~ qr{
    ^\#define\x20PERL_PANIC_ERROR_INTERNAL_THREADS_LOCK_READ_COUNT_NEGATIVE\(([^\n]+)\)\x20\\\n
    \s*(Perl_throw_croak_[0-9]+_[0-9]+\([\s\S]*?\n\s*\))
}mx;
is(
    $lock_params,
    'ma_name, ma_file, ma_line, ma_thread, ma_mutex, ma_reliable, ma_readers, ma_xcounter, ma_rcounter',
    'named-format helper keeps the declared macro parameter order'
);
$lock_call =~ s/\\\n\s*/ /g;
like(
    $lock_call,
    qr{
        "%s", \s* \(const\s+char\s+\*\) \(ma_name\),
        \s* "%s", \s* \(const\s+char\s+\*\) \(ma_file\),
        \s* ma_line, \s* "%p", \s* ma_thread, \s* "%p", \s* ma_mutex,
        \s* "%s", \s* \(const\s+char\s+\*\) \(ma_reliable\),
        \s* ma_readers, \s* ma_xcounter, \s* ma_rcounter
    }sx,
    'named-format helper binds each declared value to its matching formal'
);
ok( $header !~ /^#define PERL_DIAG_LEGACY_croak(?:_nocontext)?\(/m, 'retired croak adapters are not generated' );
ok( $header !~ /^#define PERL_DIAG_LEGACY_DIE\(/m,                  'the retired DIE adapter is not generated' );
like(
    $header,
    qr/
    ^\#define\x20PERL_THROW_CWD_CWD_USAGE\(\)\x20
    \\\n\s*PERL_THROW_ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH\("Cwd::cwd\(\)"\)
/mx,
    'a usage specialization supplies its configured fixed signature'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_THROW_UMASK_NOT_IMPLEMENTED\(\)\x20
    \\\n\s*PERL_THROW_ERROR_UNSUPPORTED_OPERATION_NOT_IMPLEMENTED_DIE\("umask"\)
/mx,
    'an unavailable operation specialization keeps DIE delivery'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_THROW_FILE_COPY_SYSCOPY_USAGE\(\)\x20
    \\\n\s*PERL_THROW_ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH_NO_CONTEXT\("File::Copy::syscopy\(
    src,dst,flag=0\)"\)
/mx,
    'a platform usage specialization keeps context lookup'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_PANIC_MUTEX_INIT_ERROR_AT_LOCATION\(ma_error,\x20
    ma_file,\x20ma_line\)\x20
    \\\n\s*PERL_PANIC_ERROR_INTERNAL_THREADS_API_FAILED_AT_LOCATION\("MUTEX_INIT",\x20
    ma_error,\x20ma_file,\x20ma_line\)
/mx,
    'a thread specialization supplies its operation and forwards ' . 'runtime values'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_PANIC_COND_INIT_STATUS_ERROR\(ma_error\)\x20
    \\\n\s*PERL_PANIC_ERROR_INTERNAL_THREADS_CONDITION_API_FAILED_WITH_STATUS\("COND_INIT",\x20
    ma_error\)
/mx,
    'a condition specialization forwards its long runtime status'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_THROW_IOCTL_IS_NOT_IMPLEMENTED\(\)\x20
    \\\n\s*PERL_THROW_ERROR_UNSUPPORTED_OPERATION_NOT_IMPLEMENTED_DIE\("ioctl"\)
/mx,
    'a specialization binds its operation and delivery API'
);
like(
    $header,
    qr/
    ^\#define\x20PERL_THROW_ERROR_UNSUPPORTED_OPERATION_NOT_IMPLEMENTED\(ma_operation\)\x20
/mx,
    'the generic not-implemented diagnostic takes one operation value'
);
unlike(
    $header,
    qr/PERL_THROW_UNIMPLEMENTED_OPERATION|"copula"/,
    'not-implemented messages do not expose a grammatical fragment alias'
);
{
    my $file = tempfile();
    for my $case (
        [
            'PERL_THROW_ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH("Cwd::cwd()");',
            qr/not ok \d+.*fixed signature text/s,
            'the source guard rejects fixed text in a shared diagnostic call'
        ],
        [
            'PERL_THROW_ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH("Cwd::" "cwd()");',
            qr/not ok \d+.*fixed signature text/s,
            'the source guard rejects concatenated fixed text'
        ],
        [
            'PERL_THROW_ERROR_CALL_BINDING_ARITY_SIGNATURE_MISMATCH(runtime_signature); PERL_THROW_CWD_CWD_USAGE();',
            qr/^ok 1 /m,
            'the source guard accepts runtime values and configured message macros'
        ],
        [
            'PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_INVALID(); YYERROR;',
            qr/not ok \d+.*unmanaged YYERROR/s,
            'the source guard rejects separate grammar recovery'
        ],
        [
            '/* YYERROR; */ const char *text = "YYERROR;"; ' . 'PERL_ADD_COMPILE_ERR_ERROR_SYNTAX_INVALID_ABORT();',
            qr/^ok 1 /m,
            'the source guard ignores quoted and commented recovery examples'
        ],
      )
    {
        open my $out, '>', $file or die "Cannot write $file: $!";
        print {$out} $case->[0];
        close $out or die "Cannot close $file: $!";
        my $result = runperl(
            progfile => 't/porting/diag.t',
            args     => [$file],
            stderr   => 1
        );
        like( $result, $case->[1], $case->[2] );
    }
}

for my $case (
    [ 'PERL_THROW_ERROR_INTERNAL_SCALAR_TYPE_CLONE_SOURCE_UNKNOWN',           'ERROR_INTERNAL_SCALAR_TYPE_CLONE_SOURCE_UNKNOWN' ],
    [ 'PERL_PANIC_ERROR_INTERNAL_STACK_JUMP_SETJMP_RESULT_INVALID', 'ERROR_INTERNAL_STACK_JUMP_SETJMP_RESULT_INVALID' ],
    [ 'PERL_THROW_ERROR_USER_OPAQUE_LITERAL_FORMAT',  'ERROR_USER_OPAQUE_LITERAL_FORMAT' ],
  )
{
    my ( $macro, $code ) = @$case;
    ok( macro_uses_catalog_entry( $header, $macro, $code ), "$macro passes its catalog index to generated code", );
}

my $api_source = <<'C';
#define croak(...) Perl_croak_nocontext(__VA_ARGS__)
#define OTHER(...) Perl_croak_nocontext(__VA_ARGS__)
C
my @api_calls = Diag::Migration::calls( $api_source, qr/Perl_croak_nocontext/ );
ok( Diag::Migration::api_boundary( 'util.h', $api_calls[0], $api_source ),
    'the public croak interface is an API boundary' );
ok( !Diag::Migration::api_boundary( 'util.h', $api_calls[1], $api_source ),
    'an arbitrary forwarding macro is not an API boundary' );
ok(
    !Diag::Migration::api_boundary( 'other.h', $api_calls[0], $api_source ),
    'the API boundary is restricted to its declaration file'
);
my $recursive_api   = '#define croak(value) croak("unmanaged")';
my @recursive_calls = Diag::Migration::calls( $recursive_api, qr/croak/ );
ok( Diag::Migration::api_boundary( 'util.h', $recursive_calls[0], $recursive_api ),
    'a macro parameter declaration is not an emitter call' );
ok( !Diag::Migration::api_boundary( 'util.h', $recursive_calls[1], $recursive_api ),
    'a call sharing the macro declaration name is checked' );
my $warning_api = <<'C';
# define ck_warner(a,...) Perl_ck_warner(aTHX_ a,__VA_ARGS__)
# define OTHER(a,...) Perl_ck_warner(aTHX_ a,__VA_ARGS__)
Perl_ck_warner(pTHX_ U32 err, const char *pat, ...);
C
my @warning_calls = Diag::Migration::calls( $warning_api, qr/Perl_ck_warner/ );
ok( Diag::Migration::api_boundary( 'embed.h', $warning_calls[0], $warning_api ),
    'generated public warning forwarding is an API boundary' );
ok( !Diag::Migration::api_boundary( 'embed.h', $warning_calls[1], $warning_api ),
    'an arbitrary warning forwarding macro is a producer' );
ok(
    Diag::Migration::api_boundary( 'proto.h', $warning_calls[2], $warning_api ),
    'warning API declarations are excluded from producer inventory'
);
ok(
    !Diag::Migration::api_boundary( 'other.h', $warning_calls[2], $warning_api ),
    'warning declaration boundaries are restricted to their defining files'
);
my $die_api = '#define die(...) Perl_die_nocontext(__VA_ARGS__)';
my ($die_call) = Diag::Migration::calls( $die_api, qr/Perl_die_nocontext/ );
ok(
    Diag::Migration::api_boundary( 'util.h', $die_call, $die_api ),
    'the public lowercase die macro is an API boundary'
);
ok(
    !Diag::Migration::api_boundary( 'other.h', $die_call, $die_api ),
    'a lowercase die forwarding macro elsewhere is a producer'
);
my $forwarding = <<'C';
void
Perl_croak(const char *pat, ...)
{
    vcroak(pat, &args);
    vcroak("new unmanaged message", &args);
}

void
ordinary_function(const char *pat)
{
    vcroak(pat, &args);
}
C
my @forward_calls = Diag::Migration::calls( $forwarding, qr/vcroak/ );
ok(
    Diag::Migration::api_boundary( 'util.c', $forward_calls[0], $forwarding ),
    'the public croak implementation can forward its external va_list'
);
ok(
    !Diag::Migration::api_boundary( 'util.c', $forward_calls[1], $forwarding ),
    'a new literal inside a public emitter is an unmanaged producer'
);
ok(
    !Diag::Migration::api_boundary( 'util.c', $forward_calls[2], $forwarding ),
    'ordinary functions cannot bypass the guard with opaque forwarding'
);
ok(
    !Diag::Migration::api_boundary( 'other.c', $forward_calls[0], $forwarding ),
    'variadic forwarding boundaries are restricted to implementation files'
);

my $generated_data_path =
  -f 'perldiag_data.inc'
  ? 'perldiag_data.inc'
  : '../perldiag_data.inc';
my $generated_data = Diag::Migration::read_source($generated_data_path);
my ( $template_rows, @out_of_range_positions ) = (0);
while ( $generated_data =~ /^\s*\{\s*perl_diag_(\w+)_number,\s*UINT64_C\([^)]*\),\s*(perl_diag_template_text_[0-9a-f]+),\s*(\d+),\s*\d+\s*\},/gm )
{
    my ( $diagnostic_code, $name, $parameter_count ) = ( $1, $2, $3 );
    die "unknown generated template $name" unless exists $generated_template_text{$name};
    my $template = $generated_template_text{$name};
    $template_rows++;

    while ( $template =~ /(?<!%)%([1-9][0-9]*)\$/g ) {
        push @out_of_range_positions,
          "diagnostic $diagnostic_code uses argument $1 with only $parameter_count parameters"
          if $1 > $parameter_count;
    }
}

ok( $template_rows, 'generated diagnostic templates were checked' );
is( scalar @out_of_range_positions, 0, 'positional template references stay within the supported parameter count' );
diag( join "\n", @out_of_range_positions ) if @out_of_range_positions;

my $parser_api = <<'C';
# define yyerror_pv(a,b) Perl_yyerror_pv(aTHX_ a,b)
Perl_yyerror_pv(pTHX_ const char * const s, U32 flags);
C
my @parser_calls = Diag::Migration::calls( $parser_api, qr/Perl_yyerror_pv/ );
ok(
    Diag::Migration::api_boundary( 'embed.h', $parser_calls[0], $parser_api ),
    'the generated parser forwarding interface is a boundary'
);
ok( Diag::Migration::api_boundary( 'proto.h', $parser_calls[1], $parser_api ),
    'parser entry-point declarations are boundaries' );
ok( !Diag::Migration::api_boundary( 'other.c', $parser_calls[1], $parser_api ),
    'parser boundaries do not exempt arbitrary files' );

my $locale_macro_source = Diag::Migration::read_source('locale.c');
my ($locale_override_body) = $locale_macro_source =~
  /\#\s*define\s+OVERRIDE_AND_SAVEPV\([^\n]+\\\n\s*STMT_START\s*\{[^\n]+\\\n(.*?)^\s*\}\s*STMT_END/ms;
ok( defined($locale_override_body) && !( grep { /\S/ && !/\\\z/ } split /\n/, $locale_override_body ),
    'the locale override panic preserves every macro continuation' );
