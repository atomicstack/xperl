#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use Config;
use XPerl::DiagPack qw(all);
require B;

my $early_diagnostic = bless {
    code     => 'ERROR_SYNTAX_INVALID',
    number   => 1,
    kind     => 'CORE_COMPILE',
    severity => 'FATAL_ERROR',
    params   => [],
    location => { file => 'early.pl', line => 2 },
  },
  'XPerl::Diagnostic';
my $early_exception = bless {
    contents => [$early_diagnostic],
    origin   => undef,
  },
  'XPerl::Exception';
is(
    runperl(
            prog => 'print join q[|], (XPerl::Diagnostic->can(q[code]) && '
          . 'XPerl::Exception->can(q[render]) ? 1 : 0), (exists '
          . '$INC{q[XPerl/Diagnostic.pm]} || exists '
          . '$INC{q[XPerl/Exception.pm]} ? 1 : 0)'
    ),
    '1|0',
    'both classes work without loading their Perl files'
);

require XPerl::Diagnostic;
require XPerl::Exception;
require overload;
require JSON::PP;

require builtin;

# Synthetic cases use packed keys for compact table tests. Build their source
# records explicitly so rendering reads current parameter values.
sub legacy_selector_fixture {
    my ($fields) = @_;
    no warnings 'experimental::builtin';
    my $data = builtin::get_diagnostic_data( $fields->{number} );
    return XPerl::Diagnostic->_new($fields) unless $data;

    my %params = map { $_->{name} => $_ } @{ $fields->{params} || [] };
    my $narrow = 0;
    for my $selector ( @{ $data->{selectors} || [] } ) {
        my $width = $selector->{value_width} || 8;
        my $shift = $width == 16 ? 48     : 8 * $narrow++;
        my $mask  = $width == 16 ? 0xffff : 0xff;
        my $id    = ( $fields->{selector_key} >> $shift ) & $mask;
        next if $selector->{plural_kind};
        my $source = $selector->{source};
        my ($parameter) = grep { $_->{name} eq $source } @{ $data->{parameters} || [] };
        next unless $parameter;

        if ( exists $params{$source} ) {
            my $current = $params{$source}{value};
            my $index   = 0;
            for my $value ( @{ $selector->{values} || [] } ) {
                if ( defined($current) && "$current" eq $value ) {
                    $params{$source}{value} = $index + 1;
                    last;
                }
                $index++;
            }
            next;
        }
        next unless $id;
        $params{$source} = {
            name  => $source,
            type  => $parameter->{type},
            value => $id,
        };
    }

    my %ordered = map { $_->{name} => 1 } @{ $data->{parameters} || [] };
    my @records = map { $params{ $_->{name} } ? $params{ $_->{name} } : () } @{ $data->{parameters} || [] };
    push @records, map { $params{$_} } grep { !exists $ordered{$_} } keys %params;
    $fields->{params} = \@records;
    return XPerl::Diagnostic->_new($fields);
}

sub is_diagnostic_text {
    my ( $diagnostic, $expected, $description ) = @_;
    my $location = $diagnostic->location;

    if ( defined $location->{file} && defined $location->{line} ) {
        $expected .= " at $location->{file} line $location->{line}.";
    }

    is( $diagnostic->text, $expected, $description );
}

sub diagnostic_metadata {
    my ($diagnostic) = @_;
    no warnings 'experimental::builtin';
    return builtin::get_diagnostic_data( $diagnostic->number );
}

sub selector_native_id {
    my ( $diagnostic, $source, $semantic_value ) = @_;
    return selector_native_id_for_code( $diagnostic->code, $source, $semantic_value );
}

sub selector_native_id_for_code {
    my ( $code, $source, $semantic_value ) = @_;
    no warnings 'experimental::builtin';
    my $data = builtin::get_diagnostic_data($code);
    my ($selector) = grep { $_->{source} eq $source } @{ $data->{selectors} || [] };
    return undef unless $selector;
    my $index = 0;
    for my $value ( @{ $selector->{values} || [] } ) {
        return $index + 1 if $value eq $semantic_value;
        $index++;
    }
    return undef;
}

sub is_captured_parameter_schema {
    my ( $diagnostic, $description ) = @_;
    my $data = diagnostic_metadata($diagnostic);
    is( join( ',', map { $_->{name} } @{ $diagnostic->params } ),
        join( ',', map { $_->{name} } @{ $data->{parameters} || [] } ), $description );
}

my @coercion_cases = (
    [
        'ERROR_NUMERIC_CONVERSION_INTEGER_COERCION_FORBIDDEN', 'bit_or', 'bitwise or (|)',
        'Can\'t coerce GLOB to integer in bitwise or (|)',
        sub { no warnings 'numeric'; $_[0] |= 0 },
        'integer coercion'
    ],
    [
        'ERROR_NUMERIC_CONVERSION_NUMBER_COERCION_FORBIDDEN', 'add', 'addition (+)',
        'Can\'t coerce GLOB to number in addition (+)',
        sub { no warnings 'numeric'; $_[0] += 0 },
        'number coercion'
    ],
    [
        'ERROR_TYPE_STRING_SCALAR_COERCION_UNSUPPORTED', 'multiconcat', 'concatenation (.) or string',
        'Can\'t coerce GLOB to string in concatenation (.) or string',
        sub { $_[0] .= '' },
        'string coercion'
    ],
);

for my $case (@coercion_cases) {
    my ( $code, $operation, $description, $english, $trigger, $label ) = @$case;
    my $exception;
    {
        local $SIG{__EXCEPT__} = sub { $exception = $_[0] };
        eval { $trigger->(*STDERR) };
        $exception ||= $@;
    }
    isa_ok( $exception, 'XPerl::Exception', "$label throws a structured exception" );
    my $diagnostic = $exception->contents->[0];
    is( $diagnostic->code, $code, "$label keeps its diagnostic identity" );
    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $params{arg3_operation}, 1 + B::opnumber($operation),
        "$label retains its numeric operation identity" );
    ok( !defined $diagnostic->selector_key, "$label identity does not occupy a selector field" );
    is( $params{arg3}, $description,
        "$label retains the displayed OP_DESC parameter" );
    is_diagnostic_text( $diagnostic, $english,
        "$label keeps a complete English descriptive message" );
}

SKIP: {
    skip 'requires XS::APItest', 12
      unless eval { require XS::APItest; 1 };

    for my $case (
        [ 'bizarre', 'ERROR_INTERNAL_SCALAR_COPY_SOURCE_NOT_SCALAR_IN_OPERATION', 'Bizarre copy of ARRAY in subroutine entry' ],
        [ 'copy_to', 'ERROR_INTERNAL_SCALAR_COPY_TARGET_TYPE_UNSUPPORTED_IN_OPERATION', 'Cannot copy to ARRAY in subroutine entry' ],
      )
    {
        my ( $fixture, $code, $english ) = @$case;
        my $exception;
        {
            local $SIG{__EXCEPT__} = sub { $exception = $_[0] };
            eval { XS::APItest::test_sv_setsv_failure($fixture) };
            $exception ||= $@;
        }
        isa_ok( $exception, 'XPerl::Exception', "$fixture copy failure is structured" );
        my $diagnostic = $exception->contents->[0];
        is( $diagnostic->code, $code, "$fixture keeps its diagnostic identity" );
        my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
        is( $params{arg3_operation}, 1 + B::opnumber('entersub'),
            "$fixture retains its numeric operation identity" );
        ok( !defined $diagnostic->selector_key, "$fixture identity does not occupy a selector field" );
        is( $params{arg3}, 'subroutine entry',
            "$fixture retains its displayed OP_DESC parameter" );
        is_diagnostic_text( $diagnostic, $english,
            "$fixture keeps a complete English descriptive message" );
    }
}

for my $case (
    [
        undef => q{sub XPerl::lv_undef :lvalue { undef } XPerl::lv_undef = 1;},
        'Can\'t return undef from lvalue subroutine',
        "Impossible de renvoyer undef depuis une sous-routine lvalue"
    ],
    [
        temporary =>
q{sub XPerl::lv_temporary :lvalue { index "abc", 0 } XPerl::lv_temporary = 1;},
        'Can\'t return a temporary from lvalue subroutine',
"Impossible de renvoyer une valeur temporaire depuis une sous-routine lvalue"
    ],
    [
        readonly =>
          q{sub XPerl::lv_readonly :lvalue { 1 } XPerl::lv_readonly = 1;},
        'Can\'t return a readonly value from lvalue subroutine',
"Impossible de renvoyer une valeur en lecture seule depuis une sous-routine lvalue"
    ],
  )
{
    my ( $kind, $source, $expected_en, $expected_fr ) = @$case;
    eval $source;
    my $exception  = $@;
    my $diagnostic = $exception->contents->[0];

    is( $diagnostic->code, 'ERROR_MUTATION_LVALUE_RETURN_VALUE_NOT_MODIFIABLE',
        "lvalue $kind return uses its catalogued diagnostic" );
    is_captured_parameter_schema( $diagnostic,
        "lvalue $kind retains its declared semantic parameter set" );
    ok( $diagnostic->selector_key, "lvalue $kind return retains its selector" );
    is_diagnostic_text( $diagnostic, $expected_en,
        "lvalue $kind return selects its English template" );
    like(
        $exception->render_as_legacy('fr'),
        qr/^\Q$expected_fr\E \N{U+E0} /,
        "lvalue $kind return selects its French template"
    );
}

{
    use utf8;
    eval q{ my $zero = 0; 1 / $zero };
    my $exception = $@;
    my $arabic    = $exception->render_as_legacy('ar');
    like( $arabic, qr/^قسمة غير مسموح بها على صفر/, 'Arabic renders a complete exception from the catalog' );
    ok( utf8::is_utf8($arabic), 'Arabic rendering retains decoded Unicode characters' );
    like(
        $exception->render_as_legacy('en'),
        qr/^Illegal division by zero/,
        'Arabic rendering leaves the English rendering intact'
    );

    eval q{ my ($x, $y); $x + $y = 1 };
    my $operation_error = $@;
    my $original        = $operation_error->contents->[0]->params->[0]{value};
    like( $operation_error->render_as_legacy('ar'), qr/الجمع/,
        'Arabic rendering uses the shared addition description' );
    is( $operation_error->contents->[0]->params->[0]{value},
        $original, 'Arabic word substitution preserves the canonical parameter' );
}


{
    use utf8;
    eval q{ 1 = 2 };
    my $error    = $@;
    my $original = $error->contents->[0]->params->[0]{value};
    like( $error->render_as_legacy('fi'), qr/vakioalkiota/,
        'Finnish modification targets use the partitive word form' );
    like( $error->render_as_legacy('fi'),
        qr/skalaarisijoitus/, 'Finnish assignment context uses its nominative operation label' );
    is( $error->contents->[0]->params->[0]{value},
        $original, 'Finnish inflection preserves the canonical parameter value' );

    eval q{ use feature 'refaliasing'; no warnings 'experimental::refaliasing'; (\do{}) = 42 };
    like( $@->render_as_legacy('fi'), qr/do-lohkoon/, 'Finnish reference targets use the illative word form' );

    my @warnings;
    {
        local $SIG{__EXCEPT__} = sub { push @warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        my $ok = eval q{ use warnings; my ($a, $b) = (q[a], q[b]); $a . $b; 1 };
    }
    my ($void) = grep { $_->contents->[0]->code eq 'WARNING_VOID_USELESS_EXPRESSION_PV' } @warnings;
    ok( $void, 'the void-expression producer supplies the Finnish role fixture' );
    if ($void) {
        my $text = $void->render_as_legacy('fi');
        like( $text, qr/merkkijonojen ketjutus/, 'Finnish void messages use the separate semantic word form' );
        unlike( $text, qr/tai merkkijono/, 'Finnish void concatenation omits the ordinary string alternative' );
    }
    else {
        fail('Finnish void word fixture');
        fail('Finnish void meaning fixture');
    }
}

{
    use utf8;
    eval q{ 1 = 2 };
    my $error    = $@;
    my $original = $error->contents->[0]->params->[0]{value};
    like(
        $error->render_as_legacy('hu'),
        qr/Nem módosítható skaláris értékadás során: konstans elem/,
        'Hungarian modification wording uses article-free operation phrases'
    );
    is( $error->contents->[0]->params->[0]{value},
        $original, 'Hungarian word substitution preserves the canonical parameter' );

    eval q{ my $x = q[x]; length($x) = 1 };
    like( $@->render_as_legacy('hu'), qr/length/, 'Hungarian operation wording preserves literal builtin names' );

    my @warnings;
    {
        local $SIG{__EXCEPT__} = sub { push @warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        my $ok = eval q{ use warnings; my ($a, $b) = (q[a], q[b]); $a . $b; 1 };
    }
    my ($void) = grep { $_->contents->[0]->code eq 'WARNING_VOID_USELESS_EXPRESSION_PV' } @warnings;
    ok( $void, 'the void-expression producer supplies the Hungarian role fixture' );
    if ($void) {
        my $text = $void->render_as_legacy('hu');
        like( $text, qr/karakterláncok összefűzése/, 'Hungarian void messages use the separate semantic word form' );
        unlike( $text, qr/vagy karakterlánc/, 'Hungarian void concatenation omits the ordinary string alternative' );
    }
    else {
        fail('Hungarian void word fixture');
        fail('Hungarian void meaning fixture');
    }
}

{
    use utf8;
    eval q{ 1 = 2 };
    my $error    = $@;
    my $original = $error->contents->[0]->params->[0]{value};
    like(
        $error->render_as_legacy('tr'),
        qr/skaler atama bağlamında sabit öğe değiştirilemez/,
        'Turkish modification wording uses the operation description and context'
    );
    is( $error->contents->[0]->params->[0]{value},
        $original, 'Turkish word substitution preserves the canonical parameter' );

    eval q{ my $x = q[x]; length($x) = 1 };
    like( $@->render_as_legacy('tr'), qr/length/, 'Turkish operation wording preserves literal builtin names' );

    for my $case ( [ 1, 'ARRAY' ], [ 5, 'alt yordam' ], ) {
        my ( $key, $label ) = @$case;
        my $diagnostic = legacy_selector_fixture(
            {
                code         => 'ERROR_TYPE_UNINITIALIZED_REFERENCE_VALUE_REQUIRED',
                number       => 1755,
                kind         => 'CORE_RUNTIME',
                severity     => 'FATAL_ERROR',
                params       => [],
                selector_key => $key,
                location     => {},
            }
        );
        like(
            $diagnostic->render_as_legacy('tr'),
            qr/\Q$label\E başvurusu/,
            'Turkish undefined references render from retained selector data'
        );
    }

    my @warnings;
    {
        local $SIG{__EXCEPT__} = sub { push @warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        my $ok = eval q{ use warnings; my ($a, $b) = (q[a], q[b]); $a . $b; 1 };
    }
    my ($void) = grep { $_->contents->[0]->code eq 'WARNING_VOID_USELESS_EXPRESSION_PV' } @warnings;
    ok( $void, 'the void-expression producer supplies the Turkish role fixture' );
    if ($void) {
        my $text = $void->render_as_legacy('tr');
        like( $text, qr/dizge birleştirme/, 'Turkish void messages use the separate semantic word form' );
        unlike( $text, qr/veya dizge/, 'Turkish void concatenation omits the ordinary string alternative' );
    }
    else {
        fail('Turkish void word fixture');
        fail('Turkish void meaning fixture');
    }
}

{
    use utf8;
    eval q{ 1 = 2 };
    my $error    = $@;
    my $original = $error->contents->[0]->params->[0]{value};
    my $text     = $error->render_as_legacy('he');
    like( $text, qr/פריט קבוע/,   'Hebrew modification wording uses the translated operation phrase' );
    like( $text, qr/השמה סקלרית/, 'Hebrew modification wording retains its assignment context' );
    ok( utf8::is_utf8($text), 'Hebrew rendering retains decoded Unicode characters' );
    is( $error->contents->[0]->params->[0]{value},
        $original, 'Hebrew word substitution preserves the canonical parameter' );

    eval q{ my $x = q[x]; length($x) = 1 };
    like( $@->render_as_legacy('he'), qr/length/, 'Hebrew operation wording preserves literal builtin names' );

    for my $case ( [ 1, 'לקריאה בלבד' ], [ 2, 'זמני' ], [ 3, 'undef' ], ) {
        my ( $key, $label ) = @$case;
        my $diagnostic = legacy_selector_fixture(
            {
                code         => 'ERROR_MUTATION_LVALUE_RETURN_VALUE_NOT_MODIFIABLE',
                number       => 1193,
                kind         => 'CORE_RUNTIME',
                severity     => 'FATAL_ERROR',
                params       => [],
                selector_key => $key,
                location     => {},
            }
        );
        like( $diagnostic->render_as_legacy('he'),
            qr/\Q$label\E/, 'Hebrew lvalue returns render from retained selector data' );
    }

    for my $case ( [ 1, "'^'", 'אחרי הנקודתיים' ], [ 8, 'נקודה־פסיק', 'במקום נקודתיים' ], ) {
        my ( $key, $detail, $position ) = @$case;
        my $diagnostic = legacy_selector_fixture(
            {
                code         => 'WARNING_REGEXP_CHAR_CLASS_POSIX_SYNTAX_SUSPICIOUS',
                number       => 2604,
                kind         => 'CORE_RUNTIME',
                severity     => 'WARNING',
                params       => [],
                selector_key => $key,
                location     => {},
            }
        );
        like(
            $diagnostic->render_as_legacy('he'),
            qr/\Q$detail\E.*\Q$position\E/,
            'Hebrew POSIX warnings translate the retained reason selector'
        );
    }

    for my $case (
        [ 0x01010101, 'filehandle', 'close', qr/close\(\).*ידית קובץ סגורה.*HANDLE/ ],
        [ 0x02020202, 'socket',     'print', qr/print על שקע תקשורת שלא נפתח/ ],
      )
    {
        my ( $key, $type, $operation, $expected ) = @$case;
        my $diagnostic = legacy_selector_fixture(
            {
                code     => 'WARNING_IO_OPERATION_ON_CLOSED_OR_UNOPENED_HANDLE',
                number   => 2325,
                kind     => 'CORE_RUNTIME',
                severity => 'WARNING',
                params   => [
                    { name => 'handle_type', type => 'text', value => $type },
                    { name => 'operation',   type => 'text', value => $operation },
                    { name => 'handle_name', type => 'text', value => 'HANDLE' },
                ],
                selector_key => $key,
                location     => {},
            }
        );
        like( $diagnostic->render_as_legacy('he'),
            $expected, 'Hebrew IO warnings retain handle state, type, name and call form' );
    }

    my @warnings;
    {
        local $SIG{__EXCEPT__} = sub { push @warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        my $ok = eval q{ use warnings; my ($a, $b) = (q[a], q[b]); $a . $b; 1 };
    }
    my ($void) = grep { $_->contents->[0]->code eq 'WARNING_VOID_USELESS_EXPRESSION_PV' } @warnings;
    ok( $void, 'the void-expression producer supplies the Hebrew role fixture' );
    if ($void) {
        my $text = $void->render_as_legacy('he');
        like( $text, qr/שרשור מחרוזות/, 'Hebrew void messages use the separate semantic word form' );
        unlike( $text, qr/או מחרוזת/, 'Hebrew void concatenation omits the ordinary string alternative' );
    }
    else {
        fail('Hebrew void word fixture');
        fail('Hebrew void meaning fixture');
    }
}

my @invalid_symbol_cases = (
    [ array => 1, 'Bad symbol for array', 'Symbole incorrect pour un tableau' ],
    [
        dirhandle => 2,
        'Bad symbol for dirhandle',
        "Symbole incorrect pour un handle de r\N{U+E9}pertoire"
    ],
    [
        filehandle => 3,
        'Bad symbol for filehandle',
        'Symbole incorrect pour un handle de fichier'
    ],
    [ hash => 4, 'Bad symbol for hash', 'Symbole incorrect pour un hachage' ],
    [
        scalar => 5,
        'Bad symbol for scalar', 'Symbole incorrect pour un scalaire'
    ],
);

for my $case (@invalid_symbol_cases) {
    my ( $symbol_kind, $selector_key, $expected_en, $expected_fr ) = @$case;
    my $diagnostic = legacy_selector_fixture(
        {
            code         => 'ERROR_SYMBOL_TABLE_SLOT_SYMBOL_INVALID',
            number       => 1189,
            kind         => 'CORE_RUNTIME',
            severity     => 'FATAL_ERROR',
            params       => [],
            selector_key => $selector_key,
            location     => {},
        }
    );
    my $exception = XPerl::Exception->_new();
    $exception->append($diagnostic);

    is_captured_parameter_schema( $diagnostic,
        "invalid $symbol_kind symbol retains its semantic selector source" );
    like( $exception->render_as_legacy('en'),
        qr/^\Q$expected_en\E/,
        "invalid $symbol_kind symbol selects the English template" );
    like( $exception->render_as_legacy('fr'),
        qr/^\Q$expected_fr\E/,
        "invalid $symbol_kind symbol selects the French template" );
}

{
    my $leaf = XPerl::Diagnostic::Note->_new(
        {
            code     => 'ERROR_USER_TEXT',
            number   => 2438,
            kind     => 'USER_RUNTIME',
            severity => 'NOTE',
            params   => [],
        }
    );
    ok( !exists $leaf->{contents}, 'a new leaf has no children storage' );
    is( $leaf->contents_count, 0, 'a leaf without children storage has count zero' );
    is( scalar @{$leaf->contents}, 0, 'a leaf without children storage returns an empty list' );
    ok( !exists $leaf->{contents}, 'reading children does not allocate storage' );
    my $empty = XPerl::Diagnostic->_new(
        { code => 'ERROR_USER_TEXT', params => [], contents => [] } );
    ok( !exists $empty->{contents}, 'an explicit empty child list needs no storage' );
    $empty->append($leaf);
    ok( $empty->{contents}[0] == $leaf, 'first append creates storage and retains child identity' );
    my $without_children = $empty->derive([]);
    ok( !exists $without_children->{contents}, 'derive with no children omits storage' );
    is( $empty->contents_count, 1, 'derive leaves the original child list intact' );
    my $parent = XPerl::Diagnostic->_new(
        {
            code     => 'ERROR_USER_TEXT',
            number   => 2438,
            kind     => 'USER_RUNTIME',
            severity => 'FATAL_ERROR',
            params   => [],
        }
    );
    {
        package XPerlTest::DerivedLeafNote;
        our @ISA = ('XPerl::Diagnostic::Note::Hint');
    }
    my $derived_leaf = XPerlTest::DerivedLeafNote->_new(
        { code => 'ERROR_USER_TEXT', params => [], contents => [] } );
    ok( !eval { $derived_leaf->append($parent); 1 },
        'a Perl subclass cannot bypass a registered inherited leaf capability' );
    like( $@, qr/cannot contain children/,
        'inherited leaf rejection reports the same collector rule' );
    ok( !eval {
        XPerl::Diagnostic->_new(
            { code => 'ERROR_USER_TEXT', params => [], contents => [42] } );
        1;
    }, 'diagnostic construction rejects non-diagnostic children' );
    ok( !eval {
        XPerl::Diagnostic::Note->_new(
            { code => 'ERROR_USER_TEXT', params => [], contents => [$parent] } );
        1;
    }, 'Note constructors cannot bypass the leaf-only restriction' );
    ok( $leaf->isa('XPerl::Diagnostic') && $leaf->isa('XPerl::DiagGroup'),
        'diagnostic subclasses share the DiagGroup base' );
    is( $leaf->contents_count, 0,
        'new diagnostics start with an empty canonical child list' );
    ok( !$leaf->has_errors, 'neutral Note leaves do not count as errors' );
    ok( $parent->has_errors, 'a diagnostic counts its own error severity' );
    ok( $parent->append($leaf) == $leaf,
        'DiagGroup append returns the appended diagnostic' );
    my $derived = $parent->derive( [$leaf] );
    ok( $derived != $parent && $derived->isa(ref $parent),
        'derive returns a distinct diagnostic of the same class' );
    is( $derived->code, $parent->code,
        'derive preserves the diagnostic identity metadata' );
    ok( $derived->contents->[0] == $leaf,
        'derive preserves replacement child identity' );
    is( $parent->contents_count, 1,
        'derive leaves the original diagnostic tree unchanged' );
    ok( !eval { $parent->derive( [$parent] ); 1 },
        'derive rejects cyclic child trees' );
    ok( !eval { $leaf->derive( [$parent] ); 1 },
        'derive cannot bypass Note leaf restrictions' );
    ok( $parent->contents->[0] == $leaf,
        'children returns the immediate child by identity' );
    is( $parent->contents_count, 1, 'child_count counts immediate children' );
    ok( $parent->contains($parent) && $parent->contains($leaf),
        'contains includes its root and descendants' );
    ok( !$leaf->contains($parent),
        'contains does not match a node outside the subtree' );
    my $nested_json = JSON::PP->new->decode( $parent->as_json );
    is( $nested_json->{schema}, 'xperl.diagnostic.v2',
        'nested diagnostics use the versioned diagnostic schema' );
    is( $nested_json->{contents}[0]{code}, 'ERROR_USER_TEXT',
        'diagnostic JSON nests its immediate child' );
    is( scalar @{ $nested_json->{contents}[0]{contents} }, 0,
        'diagnostic JSON emits an empty child list for leaves' );

    my $render_parent = XPerl::Diagnostic->_new(
        {
            code     => 'ERROR_USER_TEXT',
            number   => 2438,
            kind     => 'USER_RUNTIME',
            severity => 'FATAL_ERROR',
            params   => [ { name => 'text', type => 'text', value => 'parent' } ],
        }
    );
    my $render_child = XPerl::Diagnostic->_new(
        {
            code     => 'ERROR_USER_TEXT',
            number   => 2438,
            kind     => 'USER_RUNTIME',
            severity => 'FATAL_ERROR',
            params   => [ { name => 'text', type => 'text', value => 'child' } ],
        }
    );
    $render_parent->append($render_child);
    like( $render_parent->render_as_legacy('en'), qr/^parent\n  child$/,
        'legacy diagnostic rendering nests child text' );
    my $render_exception = XPerl::Exception->_new();
    $render_exception->append($render_parent);
    like( $render_exception->render_as_modern('en'),
        qr/parent\n  #2438 FATAL_ERROR\.USER_RUNTIME\.ERROR_USER_TEXT\n  child/,
        'annotated diagnostic rendering nests child text' );
    ok( !eval { $leaf->append($parent); 1 },
        'Note subclasses reject containment' );
    ok( !eval { $parent->append($parent); 1 },
        'a diagnostic cannot directly contain itself' );
    my $other = XPerl::Diagnostic->_new(
        {
            code     => 'ERROR_USER_TEXT',
            number   => 2438,
            kind     => 'USER_RUNTIME',
            severity => 'FATAL_ERROR',
            params   => [],
        }
    );
    $parent->append($other);
    ok( !eval { $other->append($parent); 1 },
        'a diagnostic cannot be appended below one of its descendants' );

    my $exception = XPerl::Exception->_new();
    $exception->append($parent);
    ok( $exception->contents->[0] == $parent,
        'Exception and Diagnostic use the shared child API' );
    my $cycle_candidate = XPerl::Diagnostic->_new(
        { code => 'ERROR_USER_TEXT', params => [], contents => [] } );
    $cycle_candidate->{contents} = [$exception];
    ok( !eval { $exception->append($cycle_candidate); 1 },
        'legacy Exception append rejects a diagnostic subtree containing itself' );
    like( $@, qr/would create a cycle/,
        'legacy Exception append reports the containment cycle' );
    is( $exception->contents_count, 1,
        'a rejected legacy append leaves the collector unchanged' );
    ok( $exception->contains($leaf) && $exception->has_errors,
        'Exception queries include descendants and its own disposition' );
    ok( $exception->contents->[0] == $parent,
        'the common contents accessor returns immediate diagnostic references' );
    my $nested_exception_json = JSON::PP->new->decode( $exception->as_json );
    is( $nested_exception_json->{contents}[0]{contents}[1]{code},
        'ERROR_USER_TEXT', 'exception JSON keeps nested children under their root' );
    my @nested_envelopes = map { JSON::PP->new->decode($_) }
      grep { length } split /\n/, $exception->render('JSON');
    is( $nested_envelopes[0]{schema}, 'xperl.diagnostic-group.v2',
        'delivery envelopes use the nested versioned schema' );
    is( $nested_envelopes[0]{contents}[0]{contents}[1]{code},
        'ERROR_USER_TEXT', 'delivery envelope keeps nested children under their root' );

    my $container = XPerl::Diagnostic->_new(
        { code => 'ERROR_USER_TEXT', params => [], severity => 'NOTE' } );
    my $nested_error = XPerl::Diagnostic->_new(
        { code => 'ERROR_USER_TEXT', params => [], severity => 'FATAL_ERROR' } );
    $container->append($nested_error);
    my $nested_exception = XPerl::Exception->_new();
    $nested_exception->append($container);
    is( $nested_exception->severity, 'FATAL_ERROR',
        'exception severity includes nested fatal children' );
    ok( $nested_exception->has_errors,
        'exception disposition includes nested fatal children' );
}

for my $case (
    [
        filehandle => q{print foo, 1;},
        'No comma allowed after filehandle',
"Aucune virgule n'est autoris\N{U+E9}e apr\N{U+E8}s un handle de fichier"
    ],
    [
        subroutine => q{sort foo, 1..2;},
        'No comma allowed after subroutine name',
"Aucune virgule n'est autoris\N{U+E9}e apr\N{U+E8}s un nom de sous-routine"
    ],
  )
{
    my ( $target_kind, $source, $expected_en, $expected_fr ) = @$case;
    eval $source;
    my $exception  = $@;
    my $diagnostic = $exception->contents->[0];

    is( $diagnostic->code, 'ERROR_SYNTAX_CALL_COMMA_AFTER_INDIRECT_NAME',
        "trailing comma after $target_kind uses its catalogued diagnostic" );
    is_captured_parameter_schema( $diagnostic,
        "trailing comma $target_kind retains its declared semantic parameter set" );
    ok( $diagnostic->selector_key,
        "trailing comma $target_kind retains its selector" );
    like( $exception->render_as_legacy('en'),
        qr/^\Q$expected_en\E/,
        "trailing comma $target_kind selects the English template" );
    like(
        $exception->render_as_legacy('fr'),
        qr/^\Q$expected_fr\E \N{U+E0} /,
        "trailing comma $target_kind selects the French template"
    );
}

for my $case (
    [
        malloc_options => 1,
'"-T" is on the #! line, it must also be used on the command line with $ENV{PERL_MALLOC_OPT}',
"\"-T\" figure dans la ligne #!, il doit aussi \N{U+00EA}tre utilis\N{U+00E9} sur la ligne de commande avec \$ENV{PERL_MALLOC_OPT}"
    ],
    [
        other => 2,
        '"-T" is on the #! line, it must also be used on the command line',
"\"-T\" figure dans la ligne #!, il doit aussi \N{U+00EA}tre utilis\N{U+00E9} sur la ligne de commande"
    ],
  )
{
    my ( $switch_source, $selector_key, $expected_en, $expected_fr ) = @$case;
    my $diagnostic = legacy_selector_fixture(
        {
            code     => 'ERROR_RUN_OPTION_STARTUP_SWITCH_REQUIRED',
            number   => 1824,
            kind     => 'CORE_RUNTIME',
            severity => 'FATAL_ERROR',
            params   => [ { name => 'switch', type => 'char', value => 'T' } ],
            selector_key => $selector_key,
            location     => {},
        }
    );
    my $exception = XPerl::Exception->_new();
    $exception->append($diagnostic);

    is( $diagnostic->params->[0]{value},
        'T', "shebang switch retains its displayed value for $switch_source" );
    is_captured_parameter_schema( $diagnostic,
        "shebang source selector is retained for $switch_source" );
    like( $exception->render_as_legacy('en'),
        qr/^\Q$expected_en\E/,
        "shebang source selects the English template for $switch_source" );
    like( $exception->render_as_legacy('fr'),
        qr/^\Q$expected_fr\E/,
        "shebang source selects the French template for $switch_source" );
}

for my $case (
    [
        ERROR_SECURITY_PRIVILEGE_SETUID_INPUT_FORBIDDEN => 1211,
        'No -T allowed while running setuid',
        'No program input from stdin allowed while running setuid',
"L'option -T n'est pas autoris\N{U+00E9}e lors de l'ex\N{U+00E9}cution avec setuid",
"L'entr\N{U+00E9}e du programme depuis stdin n'est pas autoris\N{U+00E9}e lors de l'ex\N{U+00E9}cution avec setuid",
    ],
    [
        ERROR_SECURITY_PRIVILEGE_SETGID_INPUT_FORBIDDEN => 1487,
        'No -T allowed while running setgid',
        'No program input from stdin allowed while running setgid',
"L'option -T n'est pas autoris\N{U+00E9}e lors de l'ex\N{U+00E9}cution avec setgid",
"L'entr\N{U+00E9}e du programme depuis stdin n'est pas autoris\N{U+00E9}e lors de l'ex\N{U+00E9}cution avec setgid",
    ],
    [
        ERROR_SECURITY_PRIVILEGE_FDSCRIPT_INPUT_FORBIDDEN => 1488,
        'No -T allowed with (suid) fdscript',
        'No program input from stdin allowed with (suid) fdscript',
        "L'option -T n'est pas autoris\N{U+00E9}e avec fdscript (suid)",
"L'entr\N{U+00E9}e du programme depuis stdin n'est pas autoris\N{U+00E9}e avec fdscript (suid)",
    ],
  )
{
    my ( $code, $number, $en_switch, $en_stdin, $fr_switch, $fr_stdin ) =
      @$case;

    for my $input_case (
        [ command_line_switch => 1, 'T',  $en_switch, $fr_switch ],
        [ stdin               => 2, "\0", $en_stdin,  $fr_stdin ],
      )
    {
        my ( $input_kind, $selector_key, $switch, $expected_en, $expected_fr )
          = @$input_case;
        my $diagnostic = legacy_selector_fixture(
            {
                code     => $code,
                number   => $number,
                kind     => 'CORE_RUNTIME',
                severity => 'FATAL_ERROR',
                params   =>
                  [ { name => 'switch', type => 'char', value => $switch } ],
                selector_key => $selector_key,
                location     => {},
            }
        );
        my $exception = XPerl::Exception->_new();
        $exception->append($diagnostic);

        like( $exception->render_as_legacy('en'),
            qr/^\Q$expected_en\E/,
            "$code selects the English $input_kind template" );
        like( $exception->render_as_legacy('fr'),
            qr/^\Q$expected_fr\E/,
            "$code selects the French $input_kind template" );
    }
}

is( $early_exception->kind, 'CORE_COMPILE',
    'a core-shaped exception uses the built-in class methods' );
is( $early_exception->contents->[0]->code,
    'ERROR_SYNTAX_INVALID',
    'a core-shaped diagnostic uses the built-in class methods' );

eval q{ &CORE::keys(1) };
my $hash_or_array_error = $@;
is(
    $hash_or_array_error->contents->[0]->code,
    'ERROR_CALL_BINDING_TYPE_HASH_REFERENCE_REQUIRED',
    'CORE::keys uses the catalogued hash-or-array requirement'
);
my %hash_or_array_params =
  map { $_->{name} => $_->{value} }
  @{ $hash_or_array_error->contents->[0]->params };
is( $hash_or_array_params{argument_number},
    '1', 'the builtin diagnostic retains its argument number' );
is( $hash_or_array_params{operation_description},
    'keys', 'the builtin diagnostic retains its operation description' );
ok(
    exists $hash_or_array_params{accepted_reference_types}
      && $hash_or_array_error->contents->[0]->selector_key,
'the accepted reference set is retained as a semantic selector parameter'
);
like(
    $hash_or_array_error->render_as_legacy('en'),
    qr/\AType of arg 1 to &CORE::keys must be hash or array reference at /,
    'the hash-or-array selector keeps the complete English message'
);
like(
    $hash_or_array_error->render_as_legacy('fr'),
    qr/Le type de l'argument 1 de &CORE::keys doit .*hachage ou de tableau/,
    'the same diagnostic selects the complete French template at render time'
);

eval q{ &CORE::dbmclose([]) };
my $hash_only_error = $@;
is(
    $hash_only_error->contents->[0]->code,
    'ERROR_CALL_BINDING_TYPE_HASH_REFERENCE_REQUIRED',
    'CORE::dbmclose uses the same diagnostic for its hash-only requirement'
);
isnt(
    $hash_only_error->contents->[0]->selector_key,
    $hash_or_array_error->contents->[0]->selector_key,
    'the hash-only and hash-or-array requirements have distinct selector values'
);
like(
    $hash_only_error->render_as_legacy('en'),
    qr/\AType of arg 1 to &CORE::dbmclose must be hash reference at /,
    'the hash-only selector keeps the complete English message'
);

eval q{my %h; () = keys $h{foo=>};};
my $forbidden_scalar_error       = $@;
my @forbidden_scalar_diagnostics = @{ $forbidden_scalar_error->contents };
is(
    join( '|', map { $_->code } @forbidden_scalar_diagnostics ),
    'ERROR_CALL_BINDING_TYPE_SCALAR_CONTAINER_ACCESS_FORBIDDEN|ERROR_CALL_BINDING_TYPE_EXPRESSION_TYPE_MISMATCH',
    'the scalar experiment and its type error remain separate diagnostics'
);
my %forbidden_scalar_params =
  map { $_->{name} => $_->{value} }
  @{ $forbidden_scalar_diagnostics[0]->params };
my %invalid_argument_type_params =
  map { $_->{name} => $_->{value} }
  @{ $forbidden_scalar_diagnostics[1]->params };
is( $invalid_argument_type_params{actual}, 'hash element',
    'type diagnostic retains the existing actual-description fallback' );
is( $invalid_argument_type_params{actual_operation}, 1 + B::opnumber('helem'),
    'type diagnostic retains the helem word identity outside its selector' );
is( $forbidden_scalar_params{feature},
    'keys', 'the scalar experiment records the operation as data' );
like(
    $forbidden_scalar_error->render_as_legacy('en'),
    qr/Experimental keys on scalar is now forbidden.*Type of arg 1 to keys/s,
    'the scalar experiment retains its English wording and diagnostic order'
);
like(
    $forbidden_scalar_error->render_as_legacy('fr'),
    qr/fonctionnalit.*hachage ou un tableau.*\N{U+00E9}l\N{U+00E9}ment de table de hachage/s,
    'the scalar experiment and exact type description render in French'
);

eval q{\pos = 42;};
my $scalar_refassign_error = $@;
my ($scalar_refassign_diagnostic) =
  grep { $_->code eq 'ERROR_MUTATION_REFERENCE_ALIASING_SCALAR_TARGET_NOT_SUPPORTED' }
  @{ $scalar_refassign_error->contents };
my %scalar_refassign_params =
  map { $_->{name} => $_->{value} }
  @{ $scalar_refassign_diagnostic->params };
is( $scalar_refassign_params{target}, 'match position',
    'scalar reference-assignment error retains its OP_DESC fallback' );
is( $scalar_refassign_params{target_operation}, 1 + B::opnumber('pos'),
    'scalar reference-assignment retains the pos word identity' );
like( $scalar_refassign_diagnostic->render_as_legacy('en'),
    qr/Can't modify reference to match position in scalar assignment/,
    'scalar reference-assignment error keeps its English text' );

eval q{(\pos) = 42;};
my $list_refassign_error = $@;
my ($list_refassign_diagnostic) =
  grep { $_->code eq 'ERROR_MUTATION_REFERENCE_ALIASING_TARGET_NOT_SUPPORTED' }
  @{ $list_refassign_error->contents };
my %list_refassign_params =
  map { $_->{name} => $_->{value} }
  @{ $list_refassign_diagnostic->params };
is( $list_refassign_params{target}, 'match position',
    'list reference-assignment error retains its target description' );
is( $list_refassign_params{context}, 'list assignment',
    'list reference-assignment error retains its context description' );
is( $list_refassign_params{context_operation}, 1 + B::opnumber('aassign'),
    'list reference-assignment retains the context word identity' );
is( $list_refassign_params{target_operation}, 1 + B::opnumber('pos'),
    'list reference-assignment retains the pos target identity' );
like( $list_refassign_diagnostic->render_as_legacy('en'),
    qr/Can't modify reference to match position in list assignment/,
    'list reference-assignment error keeps its English text' );

eval q{(\do{}) = 42;};
my $block_refassign_error = $@;
my ($block_refassign_diagnostic) =
  grep { $_->code eq 'ERROR_MUTATION_REFERENCE_ALIASING_TARGET_NOT_SUPPORTED' }
  @{ $block_refassign_error->contents };
my %block_refassign_params =
  map { $_->{name} => $_->{value} }
  @{ $block_refassign_diagnostic->params };
is( $block_refassign_params{target}, 'do block',
    'do-block reference-assignment keeps its display fallback' );
is( $block_refassign_params{context_operation}, 1 + B::opnumber('aassign'),
    'do-block reference-assignment retains list-assignment identity' );
like( $block_refassign_diagnostic->render_as_legacy('en'),
    qr/Can't modify reference to do block in list assignment/,
    'do-block reference-assignment keeps its English text' );

my $non_lvalue_call_error;
{
    use feature 'refaliasing';
    no warnings 'experimental::refaliasing';
    our ( $xperl_nonlv_a, $xperl_nonlv_b );
    sub xperl_non_lvalue_sub () { $xperl_nonlv_a, $xperl_nonlv_b }
    eval q{xperl_non_lvalue_sub = (2, 3);};
    $non_lvalue_call_error = $@;
}
my ($non_lvalue_call_diagnostic) =
  grep { $_->code eq 'ERROR_MUTATION_LVALUE_CALL_NON_LVALUE_SUBROUTINE_IN_CONTEXT' }
  @{ $non_lvalue_call_error->contents };
my %non_lvalue_call_params =
  map { $_->{name} => $_->{value} }
  @{ $non_lvalue_call_diagnostic->params };
is( $non_lvalue_call_params{subroutine}, 'main::xperl_non_lvalue_sub',
    'non-lvalue call keeps its literal callee name' );
is( $non_lvalue_call_params{context}, 'scalar assignment',
    'non-lvalue call keeps its OP_DESC context fallback' );
is( $non_lvalue_call_params{context_operation}, 1 + B::opnumber('sassign'),
    'non-lvalue call retains the scalar-assignment word identity' );
like( $non_lvalue_call_diagnostic->render_as_legacy('en'),
    qr/Can't modify non-lvalue subroutine call of &main::xperl_non_lvalue_sub in scalar assignment/,
    'non-lvalue call keeps its English text with a literal callee wildcard' );

my $cannot_modify_metadata;
{
    no warnings 'experimental::builtin';
    $cannot_modify_metadata = builtin::get_diagnostic_data(1419);
}
require B;
is( scalar @{ $cannot_modify_metadata->{selectors} }, 0,
    'operation identities do not consume grammatical selector fields' );

eval q{1 += 2;};
my $cannot_modify_context_error = $@;
my ($cannot_modify_context_diagnostic) =
  grep { $_->code eq 'ERROR_MUTATION_LVALUE_TARGET_NOT_MODIFIABLE' }
  @{ $cannot_modify_context_error->contents };
my %cannot_modify_context_params =
  map { $_->{name} => $_->{value} }
  @{ $cannot_modify_context_diagnostic->params };
is( $cannot_modify_context_params{target}, 'constant item',
    'in-context modification retains the target OP_DESC fallback' );
is( $cannot_modify_context_params{context}, 'addition (+)',
    'in-context modification retains the context OP_DESC fallback' );
is( $cannot_modify_context_params{target_operation}, 1 + B::opnumber('const'),
    'in-context modification retains the constant operation identity' );
is( $cannot_modify_context_params{context_operation}, 1 + B::opnumber('add'),
    'in-context modification retains the addition operation identity' );
like( $cannot_modify_context_diagnostic->render_as_legacy('en'),
    qr/\ACan't modify constant item in addition \(\+\) at \(eval \d+\) line 1\.\z/,
    'in-context modification keeps its complete English message' );

eval q{local 1;};
my $cannot_modify_local_error = $@;
my ($cannot_modify_local_diagnostic) =
  grep { $_->code eq 'ERROR_MUTATION_LVALUE_TARGET_NOT_MODIFIABLE' }
  @{ $cannot_modify_local_error->contents };
my %cannot_modify_local_params =
  map { $_->{name} => $_->{value} }
  @{ $cannot_modify_local_diagnostic->params };
is( $cannot_modify_local_params{context}, 'local',
    'local remains a literal context parameter' );
is( $cannot_modify_local_params{target_operation}, 1 + B::opnumber('const'),
    'local retains the descriptive target identity' );
is( $cannot_modify_local_params{context_operation}, 0,
    'literal local context needs no operation lookup' );
like( $cannot_modify_local_diagnostic->render_as_legacy('en'),
    qr/\ACan't modify constant item in local at \(eval \d+\) line 1\.\z/,
    'local keeps its legacy English message' );

for my $case (
    [ 'lock 1', 'lock', 'constant item' ],
    [ 'chop 1', 'chop', 'constant item' ],
    [ 'chomp 1', 'chomp', 'constant item' ],
    [ 'undef 1', 'undef operator', 'constant item' ],
    [ 'read STDIN, 1, 1', 'read', 'constant item' ],
    [ 'substr(1,0,1) = "a"', 'substr', 'constant item' ],
    [ 'vec(1,0,1) = 1', 'vec', 'constant item' ],
    [ '(keys %h) = 1', 'list assignment', 'keys' ],
    [ 'chop(tr/a/b/r)', 'chop', 'transliteration (tr///)' ],
    [ 'pos @a', 'match position', 'array dereference' ],
    [ 'do {1} = 2', 'scalar assignment', 'do block' ],
) {
    my ( $source, $context, $target ) = @$case;
    eval "sub { our (\@a, %h); $source }";
    my $exception = $@;
    my ($diagnostic) = grep {
        $_->code eq 'ERROR_MUTATION_LVALUE_TARGET_NOT_MODIFIABLE'
    } @{ $exception->contents };
    ok( $diagnostic, "$source reports the modification target failure" );
    next unless $diagnostic;
    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $params{target}, $target, "$source preserves its target description" );
    is( $params{context}, $context, "$source preserves its modifying context" );
    like( $diagnostic->render_as_legacy('en'),
        qr/\ACan't modify \Q$target\E in \Q$context\E at /,
        "$source keeps its English diagnostic" );
    if ( $source eq 'lock 1' ) {
        is( $params{context_operation}, 1 + B::opnumber('lock'),
            'the literal lock name retains its operation identity' );
        ok( !defined $diagnostic->selector_key,
            'a literal function name needs no grammatical selector value' );
    }
}

eval 'my $$foo : bar = 1';
my $cannot_declare_error = $@;
my ($cannot_declare_diagnostic) =
  grep { $_->code eq 'ERROR_SYNTAX_DECLARATION_TARGET_NOT_DECLARABLE' }
  @{ $cannot_declare_error->contents };
my %cannot_declare_params =
  map { $_->{name} => $_->{value} }
  @{ $cannot_declare_diagnostic->params };
is( $cannot_declare_params{target}, 'scalar dereference',
    'declaration diagnostic retains the expression-description fallback' );
is( $cannot_declare_params{target_operation}, 1 + B::opnumber('rv2sv'),
    'declaration diagnostic retains the rv2sv word identity' );
like( $cannot_declare_diagnostic->render_as_legacy('en'),
    qr/Can't declare scalar dereference in "my"/,
    'declaration diagnostic keeps its English message' );

eval 'my(do{})';
my $cannot_declare_block_error = $@;
my ($cannot_declare_block_diagnostic) =
  grep { $_->code eq 'ERROR_SYNTAX_DECLARATION_TARGET_NOT_DECLARABLE' }
  @{ $cannot_declare_block_error->contents };
my %cannot_declare_block_params =
  map { $_->{name} => $_->{value} }
  @{ $cannot_declare_block_diagnostic->params };
is( $cannot_declare_block_params{target}, 'do block',
    'declaration diagnostic retains its fixed do-block display' );
ok( $cannot_declare_block_params{target_operation}
    && !defined $cannot_declare_block_diagnostic->selector_key,
    'declaration diagnostic retains synthetic do-block identity outside its selector' );
like( $cannot_declare_block_diagnostic->render_as_legacy('en'),
    qr/Can't declare do block in "my"/,
    'declaration diagnostic keeps the complete do-block message' );

my $useless_localization_warning;
{
    local $SIG{__EXCEPT__} = sub { $useless_localization_warning = $_[0] };
    local $SIG{__WARN__} = sub { };
    eval q{use warnings 'syntax'; my $x; local($x += 1);};
}
my ($useless_localization_diagnostic) =
  grep { $_->code eq 'WARNING_SYNTAX_LOCALIZATION_NO_EFFECT' }
  @{ $useless_localization_warning->contents };
my %useless_localization_params =
  map { $_->{name} => $_->{value} }
  @{ $useless_localization_diagnostic->params };
is( $useless_localization_params{arg1}, 'addition (+)',
    'localization warning retains its OP_DESC fallback' );
is( $useless_localization_params{arg1_operation}, 1 + B::opnumber('add'),
    'localization warning retains the numeric add word identity' );
like( $useless_localization_diagnostic->render_as_legacy('en'),
    qr/Useless localization of addition \(\+\)/,
    'localization warning preserves its complete English text' );
like( $useless_localization_diagnostic->render_as_legacy('fr'),
    qr/Localisation inutile : addition \(\+\)/,
    'localization warning has a complete French add case' );

my $false_but_defined_warning;
{
    local $SIG{__EXCEPT__} = sub { $false_but_defined_warning = $_[0] };
    local $SIG{__WARN__} = sub { };
    eval q{
        use warnings 'misc';
        my @values = ('value');
        if (my $value = each @values) { }
    };
}
my ($false_but_defined_diagnostic) =
  grep { $_->code eq 'WARNING_MISC_TRUTH_TEST_MAY_DISCARD_DEFINED_VALUE' }
  @{ $false_but_defined_warning->contents };
isa_ok( $false_but_defined_diagnostic, 'XPerl::Diagnostic',
    'the array each warning is structured' );
ok( $false_but_defined_diagnostic->isa('XPerl::Diagnostic::Warning::Misc'),
    'the each warning instantiates its controlling misc class' );
is( join('|', @{ $false_but_defined_diagnostic->warning_categories }), 'WARN_MISC',
    'the misc class preserves the original warning category' );
my %false_but_defined_params =
  map { $_->{name} => $_->{value} }
  @{ $false_but_defined_diagnostic->params };
is( $false_but_defined_diagnostic->selector_key, 1,
    'the array each warning selects the aeach case' );
ok( !exists $false_but_defined_diagnostic->{selector_key},
    'the compatibility selector key is not cached in the diagnostic' );
is( JSON::PP->new->decode( $false_but_defined_diagnostic->as_json )
        ->{selector_key},
    1, 'diagnostic JSON derives the compatibility selector key from its parameters' );
ok( !exists $false_but_defined_diagnostic->{selector_key},
    'serializing a diagnostic does not cache the compatibility selector key' );
is( $false_but_defined_params{operation}, 'each on array',
    'the array each warning retains its displayed operation' );
is_diagnostic_text(
    $false_but_defined_diagnostic,
    'Value returned by each on array can be "0" and still be defined; test with defined()',
    'the array each warning has a complete English template'
);

eval q{use strict 'subs'; XPerlExceptionBareword;};
my $strict_subs_bareword_error = $@;
my $strict_subs_bareword_diagnostic =
  $strict_subs_bareword_error->contents->[0];
ok( $strict_subs_bareword_diagnostic->isa(
        'XPerl::Diagnostic::Error::Strict::Subs' ),
    'strict-subs diagnostics instantiate their semantic class' );
is(
    $strict_subs_bareword_diagnostic->code,
    'ERROR_STRICT_SUBS_BAREWORD_FORBIDDEN',
    'strict subs records a catalogued bareword diagnostic'
);
my %strict_subs_bareword_params =
  map { $_->{name} => $_->{value} }
  @{ $strict_subs_bareword_diagnostic->params };
is( $strict_subs_bareword_params{word},
    'XPerlExceptionBareword',
    'strict subs stores the bareword as a parameter' );
is_diagnostic_text(
    $strict_subs_bareword_diagnostic,
    'Bareword "XPerlExceptionBareword" not allowed while "strict subs" in use',
    'strict subs retains its complete English message'
);
{
    my $location = $strict_subs_bareword_diagnostic->location;
    is(
        $strict_subs_bareword_error->render_as_legacy('pt'),
        qq{A palavra sem aspas "XPerlExceptionBareword" n\x{e3}o \x{e9} permitida com "strict subs" em uso}
          . " em $location->{file}, linha $location->{line}.\n",
        'strict subs renders its Portuguese message and location'
    );
}

eval q{
    open XPerlExceptionHandle, ">&", STDOUT;
    no feature "bareword_filehandles";
    print XPerlExceptionHandle;
};
my $bareword_filehandle_error      = $@;
my $bareword_filehandle_diagnostic = $bareword_filehandle_error->contents->[0];
is(
    $bareword_filehandle_diagnostic->code,
    'ERROR_IO_HANDLE_BAREWORD_NAME_FORBIDDEN',
    'disabled bareword filehandles record a catalogued diagnostic'
);
my %bareword_filehandle_params =
  map { $_->{name} => $_->{value} }
  @{ $bareword_filehandle_diagnostic->params };
is( $bareword_filehandle_params{filehandle},
    'XPerlExceptionHandle',
    'the bareword filehandle is stored as a parameter' );
is_diagnostic_text(
    $bareword_filehandle_diagnostic,
    'Bareword filehandle "XPerlExceptionHandle" not allowed under '
      . "'no feature \"bareword_filehandles\"'",
    'disabled bareword filehandles retain their complete English message'
);

my @builtin_reference_requirements = (
    [
        q{&CORE::read(*STDIN, 1, 1)},
        'scalar_reference',
        2,
        'read',
        qr/\AType of arg 2 to &CORE::read must be scalar reference at /,
        qr/argument 2.*&CORE::read.*scalaire/,
    ],
    [
        q{&CORE::lock(1)},
        'reference_with_code',
        1,
        'lock',
qr/\AType of arg 1 to &CORE::lock must be reference to one of \[\$\@%&\*\] at /,
        qr/argument 1.*&CORE::lock.*\[\$\@%&\*\]/,
    ],
    [
        q{&CORE::tie(1, "Foo")},
        'reference_without_code',
        1,
        'tie',
qr/\AType of arg 1 to &CORE::tie must be reference to one of \[\$\@%\*\] at /,
        qr/argument 1.*&CORE::tie.*\[\$\@%\*\]/,
    ],
);

for my $case (@builtin_reference_requirements) {
    my ( $source, $selector, $argument_number, $operation, $english, $french )
      = @$case;

    eval $source;
    my $error      = $@;
    my $diagnostic = $error->contents->[0];
    is(
        $diagnostic->code,
        'ERROR_CALL_BINDING_TYPE_REFERENCE_TYPE_UNSUPPORTED',
        "$operation uses the typed reference requirement"
    );

    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $params{argument_number},
        "$argument_number", "$operation keeps its argument number" );
    is( $params{operation_name}, $operation, "$operation keeps its name" );
    ok(
        exists $params{accepted_reference_types} && $diagnostic->selector_key,
        "$operation retains the accepted reference set as a selector parameter"
    );
    like( $error->render_as_legacy('en'),
        $english, "$operation renders its complete English requirement" );
    like( $error->render_as_legacy('fr'),
        $french, "$operation renders its complete French requirement" );
}

my @invalid_argument_type_cases = (
    [
        array_ref => q{sub proto_array (\@) {}; proto_array(1);},
        'array_ref',
        qr/Type of arg 1 to main::proto_array must be array/,
        qr/argument 1.*proto_array.*tableau/,
        '',
    ],
    [
        hash_ref => q{sub proto_hash (\%) {}; proto_hash(1);},
        'hash_ref',
        qr/Type of arg 1 to main::proto_hash must be hash/,
        qr/argument 1.*proto_hash.*hachage/,
        '',
    ],
    [
        filehandle => q{open(<STDIN>, q[<], q[file]);},
        'filehandle',
        qr/Type of arg 1 to open must be HANDLE/,
        qr/argument 1.*open.*HANDLE/,
        '',
    ],
    [
        hash_or_array_ref =>
          q{our $scalar_for_values; values $scalar_for_values;},
        'hash_or_array_ref',
        qr/Type of arg 1 to values must be hash or array/,
        qr/argument 1.*values.*hachage ou un tableau/,
        '',
    ],
    [
        block_or_sub => q{sub proto_block (&) {}; proto_block(1);},
        'block_or_sub',
        qr/Type of arg 1 to main::proto_block must be block or sub \{\}/,
        qr/argument 1.*proto_block.*bloc ou sub \{\}/,
        '',
    ],
    [
        sub => q{sub proto_sub ($&) {}; proto_sub(1,2);},
        'sub',
        qr/Type of arg 2 to main::proto_sub must be sub \{\}/,
        qr/argument 2.*proto_sub.*sub \{\}/,
        '',
    ],
    [
        sigil_set =>
q{sub proto_sigil_set (\[$@]) {}; our %sigil_hash; proto_sigil_set(%sigil_hash);},
        'sigil_set',
        qr/Type of arg 1 to main::proto_sigil_set must be one of \[\$\@\]/,
        qr/argument 1.*proto_sigil_set.*types suivants.*\[\$\@\]/,
        '[$@]',
    ],
    [
        symbol =>
q{sub proto_symbol (\*) {}; our $symbol_scalar; proto_symbol($symbol_scalar);},
        'symbol',
        qr/Type of arg 1 to main::proto_symbol must be symbol/,
        qr/argument 1.*proto_symbol.*symbole/,
        '',
    ],
    [
        subroutine => q{sub proto_subroutine (\&) {}; proto_subroutine(1);},
        'subroutine',
        qr/Type of arg 1 to main::proto_subroutine must be subroutine/,
        qr/argument 1.*proto_subroutine.*sous-routine/,
        '',
    ],
    [
        scalar => q{sub proto_scalar (\$) {}; proto_scalar(1);},
        'scalar',
        qr/Type of arg 1 to main::proto_scalar must be scalar/,
        qr/argument 1.*proto_scalar.*scalaire/,
        '',
    ],
);

for my $case (@invalid_argument_type_cases) {
    my ( $name, $source, $expected_kind, $english, $french, $expected_sigils )
      = @$case;
    eval $source;
    my $exception = $@;
    my ($diagnostic) =
      grep { $_->code eq 'ERROR_CALL_BINDING_TYPE_EXPRESSION_TYPE_MISMATCH' } @{ $exception->contents };
    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };

    is( $params{expected_kind}, selector_native_id( $diagnostic, 'expected_kind', $expected_kind ),
        "$name keeps its semantic selector value" );
    ok( $diagnostic->selector_key,
        "$name selects a complete diagnostic template" );
    is( $params{sigils}, $expected_sigils,
        "$name stores only the accepted sigil syntax when present" );
    ok( !exists $params{expected},
        "$name does not store the former English requirement fragment" );
    like( $diagnostic->render_as_legacy('en'),
        $english, "$name preserves its English requirement" );
    like( $diagnostic->render_as_legacy('fr'),
        $french, "$name renders its complete French requirement" );
}

my @overload_resolution_failures = (
    [
        q{
            package XPerlException::UnresolvedOverload;
            use overload '+' => 'missing_overload_method';
            package main;
            my $object = bless {}, 'XPerlException::UnresolvedOverload';
            $object + 1;
        },
        'method_not_found',
        'missing_overload_method',
        qr/Can't resolve method "missing_overload_method" overloading "\+"/,
        qr/Impossible de r.*solver la m.*thode "missing_overload_method"/,
    ],
    [
        q{
            {
                package XPerlException::OverloadParent;
                use overload '+' => 'missing_overload_method';
            }
            {
                package XPerlException::OverloadChild;
                our @ISA = ('XPerlException::OverloadParent');
            }
            XPerlException::OverloadChild->can('(+');
            my $object = bless {}, 'XPerlException::OverloadChild';
            $object + 1;
        },
        'stub_found',
        '???',
        qr/Stub found while resolving method "\?\?\?" overloading "\+"/,
        qr/m.*thode factice "\?\?\?".*r.*solution de la surcharge/,
    ],
);

for my $case (@overload_resolution_failures) {
    my ( $source, $failure, $method_name, $english, $french ) = @$case;

    eval $source;
    my $error      = $@;
    my $diagnostic = $error->contents->[0];
    is( $diagnostic->code, 'ERROR_OVERLOAD_METHOD_RESOLUTION_FAILED',
        "$failure uses the overload-conflict diagnostic" );

    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $params{method_name}, $method_name,
        "$failure keeps the method-name value" );
    is( $params{operator}, '+', "$failure keeps the overloaded operator" );
    ok(
        exists $params{resolution_failure} && $diagnostic->selector_key,
        "$failure retains the failure mode as a selector parameter"
    );
    like( $error->render_as_legacy('en'),
        $english, "$failure renders its complete English template" );
    like( $error->render_as_legacy('fr'),
        $french, "$failure renders its complete French template" );
}

{

    package XPerlException::OverloadLeft;
    use overload q/""/ => sub { 'left' }, fallback => 0;

    package XPerlException::OverloadRight;
    use overload q/""/ => sub { 'right' }, fallback => 0;
}

my @missing_overload_cases = (
    [
        sub { my $left = bless {}, 'XPerlException::OverloadLeft'; ~$left },
        'XPerlException::OverloadLeft',
        '',
qr/Operation "~": no method found, argument in overloaded package XPerlException::OverloadLeft/,
    ],
    [
        sub { my $left = bless {}, 'XPerlException::OverloadLeft'; $left | 'x' }
        ,
        'XPerlException::OverloadLeft',
        '',
qr/Operation "\|": no method found,\n\tleft argument in overloaded package XPerlException::OverloadLeft,\n\tright argument has no overloaded magic/,
    ],
    [
        sub {
            my $right = bless {}, 'XPerlException::OverloadRight';
            'x' | $right;
        },
        '',
        'XPerlException::OverloadRight',
qr/Operation "\|": no method found,\n\tleft argument has no overloaded magic,\n\tright argument in overloaded package XPerlException::OverloadRight/,
    ],
    [
        sub {
            my $left  = bless {}, 'XPerlException::OverloadLeft';
            my $right = bless {}, 'XPerlException::OverloadRight';
            $left | $right;
        },
        'XPerlException::OverloadLeft',
        'XPerlException::OverloadRight',
qr/Operation "\|": no method found,\n\tleft argument in overloaded package XPerlException::OverloadLeft,\n\tright argument in overloaded package XPerlException::OverloadRight/,
    ],
);

for my $case (@missing_overload_cases) {
    my ( $run, $left_package, $right_package, $expected ) = @$case;
    eval { $run->() };

    my $diagnostic = $@->contents->[0];
    my %params     = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $diagnostic->code, 'ERROR_OVERLOAD_OPERATION_METHOD_NOT_FOUND',
        'missing-method failure keeps its diagnostic identity' );
    ok( $diagnostic->selector_key,
        'missing-method failure records its semantic selector key' );
    is( $params{left_package}, $left_package,
        'missing-method failure records the left operand package when present'
    );
    is( $params{right_package}, $right_package,
        'missing-method failure records the right operand package when present'
    );
    like( $diagnostic->render_as_legacy('en'),
        $expected,
        'missing-method failure preserves the complete English wording' );
}

my @inc_hook_contexts = (
    [
        bless( {}, 'XPerlException::NoINCMethod' ),
        'object_hook',
        qr/in object hook in \@INC/,
        qr/dans un hook d'objet de \@INC/,
    ],
    [
        [ bless( {}, 'XPerlException::NoINCMethod' ) ],
        'array_object_hook',
        qr/in object in ARRAY hook in \@INC/,
        qr/dans un objet d'un hook ARRAY de \@INC/,
    ],
);

for my $case (@inc_hook_contexts) {
    my ( $inc_entry, $hook_context, $english, $french ) = @$case;
    local @INC = ($inc_entry);
    eval q{ require XPerlException::MissingINCMethod; 1 };
    my $error      = $@;
    my $diagnostic = $error->contents->[0];
    is( $diagnostic->code, 'ERROR_LOAD_HOOK_INC_METHODS_NOT_FOUND',
        "$hook_context uses the missing-hook diagnostic" );

    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    like(
        $params{package},
        qr/XPerlException::NoINCMethod/,
        "$hook_context keeps the package name"
    );
    ok(
        exists $params{hook_context} && $diagnostic->selector_key,
        "$hook_context is retained as a selector parameter"
    );
    like( $error->render_as_legacy('en'),
        $english, "$hook_context renders its complete English template" );
    like( $error->render_as_legacy('fr'),
        $french, "$hook_context renders its complete French template" );
}

{

    package XPerlException::DyingINCHook;
    our $AUTOLOAD;
    sub AUTOLOAD { die "INC hook failed\n" }
    sub DESTROY  { }
}

my @inc_hook_failures = (
    [ bless( {}, 'XPerlException::DyingINCHook' ), 'INC', 'method', ],
    [ sub { die "sub hook failed\n" },             'INC', 'sub', ],
);

for my $case (@inc_hook_failures) {
    my ( $inc_entry, $hook, $invocation_kind ) = @$case;
    local @INC = ($inc_entry);
    eval q{ require XPerlException::DyingHookTarget; 1 };
    my $error       = $@;
    my @diagnostics = @{ $error->contents };
    is( join( ',', map { $_->code } @diagnostics ),
        'ERROR_USER_TEXT,ERROR_LOAD_HOOK_INC_DIED',
        "$invocation_kind hook failure stays before the INC diagnostic" );

    my $diagnostic = $diagnostics[-1];
    my %params     = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $params{hook}, $hook, "$invocation_kind hook name is retained" );
    ok(
        exists $params{invocation_kind} && $diagnostic->selector_key,
        "$invocation_kind is retained as a selector parameter"
    );
    like(
        $error->render_as_legacy('en'),
        qr/\Q$hook\E \Q$invocation_kind\E hook died/,
        "$invocation_kind failure renders in English"
    );
    like(
        $error->render_as_legacy('fr'),
        $invocation_kind eq 'method'
        ? qr/Le hook de m.*thode \Q$hook\E a .*chou/
        : qr/Le hook sub \Q$hook\E a .*chou/,
        "$invocation_kind failure renders in French"
    );
}

my $fields = {
    code     => 'ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO',
    number   => 1001,
    kind     => 'CORE_RUNTIME',
    severity => 'FATAL_ERROR',
    params   => [],
    location => { file => 'runtime.pl', line => 12 },
};
my $first = XPerl::Diagnostic->_new($fields);
push @{ $fields->{params} }, { name => 'changed' };
$fields->{location}{line} = 99;
is( $first->code, 'ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO',
    'diagnostic identity is stored separately' );
is( scalar @{ $first->params }, 0,  'constructor owns its parameter list' );
is( $first->location->{line},   12, 'constructor owns its location' );
ok( !exists $first->{text}, 'diagnostics do not store preformatted text' );
ok( !exists $first->{selector_key},
    'diagnostics without selectors do not store a selector key' );
ok( !exists $first->{render_args},
    'diagnostics use parameter values as their render arguments' );

for my $case (
    [
        'ERROR_IO_LAYER_BYTE_OPERATION_ON_UTF8_HANDLE', 1183, 'sysread',
        "sysread() isn't allowed on :utf8 handles", qr/sysread\(\)/
    ],
    [
        'WARNING_SYNTAX_CONTROL_TRANSFER_PRECEDENCE', 2128, 'goto',
        'Possible precedence issue with control flow operator (goto)', qr/goto/,
        undef
    ],
    [
        'WARNING_IO_DIRECTORY_OPERATION_ON_FILEHANDLE', 2223, 'readdir',
        'readdir() attempted on handle DIR opened with open()', qr/readdir\(\)/,
        'DIR'
    ],
    [
        'WARNING_IO_DIRECTORY_OPERATION_ON_INVALID_HANDLE', 2224, 'closedir',
        'closedir() attempted on invalid dirhandle DIR', qr/closedir\(\)/,
        'DIR'
    ],
  )
{
    my ( $code, $number, $operation, $expected_en, $expected_fr, $arg2 ) = @$case;
    my @params = ( { name => 'arg1', type => 'text', value => $operation } );
    push @params, { name => 'arg2', type => 'text', value => $arg2 }
      if defined $arg2;
    my $diagnostic = XPerl::Diagnostic->_new(
        {
            code     => $code,
            number   => $number,
            kind     => 'CORE_RUNTIME',
            severity => $code eq 'ERROR_IO_LAYER_BYTE_OPERATION_ON_UTF8_HANDLE' ? 'FATAL_ERROR' : 'WARNING',
            params   => \@params,
            location => {},
        }
    );

    ok( !$diagnostic->selector_key,
        "$code renders the operation without a redundant selector" );
    is( $diagnostic->render_as_legacy('en'), $expected_en,
        "$code preserves its English wording" );
    like( $diagnostic->render_as_legacy('fr'), $expected_fr,
        "$code preserves the literal operation name in French" );
}

my $warning_fields = {
    code               => 'TWO_CATEGORIES',
    severity           => 'WARNING',
    warning_categories => [ 'WARN_NUMERIC', 'WARN_UNINITIALIZED' ],
    params             => [],
    location           => {},
};
my $two_category_warning = XPerl::Diagnostic->_new($warning_fields);
$warning_fields->{warning_categories}[0] = 'changed';
is(
    join( '|', @{ $two_category_warning->warning_categories } ),
    'WARN_NUMERIC|WARN_UNINITIALIZED',
    'constructor owns the warning category names'
);
my $returned_categories = $two_category_warning->warning_categories;
$returned_categories->[0] = 'changed';
is(
    join( '|', @{ $two_category_warning->warning_categories } ),
    'WARN_NUMERIC|WARN_UNINITIALIZED',
    'warning category access does not expose the stored array'
);
is(
    join(
        '|',
        @{ JSON::PP->new->decode( $two_category_warning->as_json )
              ->{warning_categories}
        }
    ),
    'WARN_NUMERIC|WARN_UNINITIALIZED',
    'warning JSON keeps multiple category names in order'
);

my $exception = XPerl::Exception->_new();
is( scalar @{ $exception->contents }, 0, 'a new exception has no messages' );
for my $class (qw(XPerl::DiagGroup XPerl::Diagnostic XPerl::Exception)) {
    ok( $class->can('contents') && $class->can('contents_count'),
        "$class provides the common contents interface" );
    ok( !$class->can('children') && !$class->can('child_count')
            && !$class->can('messages') && !$class->can('_append_message'),
        "$class has no obsolete collection aliases" );
}
ok( exists $exception->{contents} && !exists $exception->{messages},
    'an exception uses contents storage' );
ok( !$exception->{thrown}, 'a new exception has not been thrown' );

ok( $exception, 'an exception is true independently of its rendered text' );

{
    my $warnings = XPerl::Exception->_new();
    for my $spec (
        [ 'CONTEXT',        'CONTEXT' ],
        [ 'SEVERE_WARNING', 'USER_RUNTIME' ],
        [ 'WARNING',        'CORE_COMPILE' ],
      )
    {
        $warnings->append(
            XPerl::Diagnostic->_new(
                {
                    code     => 'PRIMARY_CLASSIFICATION',
                    severity => $spec->[0],
                    kind     => $spec->[1],
                    params   => [],
                }
            )
        );
    }

    is( $warnings->severity, 'SEVERE_WARNING',
        'a severe warning is the first warning despite surrounding diagnostics' );
    is( $warnings->kind, 'USER_RUNTIME',
        'exception kind comes from the severe warning' );

    $warnings->append($first);
    is( $warnings->severity, 'FATAL_ERROR',
        'a later error takes priority over a severe warning' );
    is( $warnings->kind, 'CORE_RUNTIME',
        'exception kind follows the later error' );
}

$exception->append($first);
is( $exception->kind, 'CORE_RUNTIME',
    'the exception kind comes from its first diagnostic' );
my $context = XPerl::Diagnostic->_new(
    {
        code     => 'RETHROWN_AT',
        number   => 5,
        severity => 'CONTEXT',
        params   => [ { name => 'divisor', type => 'iv', value => '0' } ],
        location => { file => 'callback.pl', line => 8 },
    }
);
$exception->_record_throw(
    { file => 'runtime.pl', line => 12, reason => 'initial' } );
$exception->_record_throw(
    {
        file   => 'callback.pl',
        line   => 8,
        reason => 'rethrow'
    },
    $context
);
my $outer_context = XPerl::Diagnostic->_new(
    {
        code     => 'RETHROWN_AT',
        number   => 5,
        severity => 'CONTEXT',
        params   => [],
        location => { file => 'outer.pl', line => 3 },
    }
);
$exception->_record_throw(
    {
        file   => 'outer.pl',
        line   => 3,
        reason => 'rethrow'
    },
    $outer_context
);
is( scalar @{ $exception->contents },
    3, 'one exception holds multiple diagnostics' );
ok(
    $exception->contents->[0] == $first
      && $exception->contents->[1] == $context
      && $exception->contents->[2] == $outer_context,
    'message order and identity are preserved'
);
is( $exception->origin->{file},
    'runtime.pl', 'rethrows do not replace the origin' );
eval { $exception->_record_throw( { reason => 'rethrow' } ) };
like(
    $@,
    qr/Explicit rethrow needs a diagnostic/,
    'an explicit rethrow requires a diagnostic'
);
my $messages = $exception->contents;
push @$messages, $early_diagnostic;
is( scalar @{ $exception->contents },
    3, 'message access does not expose the array' );
my $origin = $exception->origin;
$origin->{file} = 'changed.pl';
is( $exception->origin->{file},
    'runtime.pl', 'origin access does not expose the record' );

my $warning_exception = XPerl::Exception->_new();
$warning_exception->append(
    XPerl::Diagnostic->_new(
        {
            code     => 'USER_WARNING_TEXT',
            number   => 4,
            kind     => 'USER_RUNTIME',
            severity => 'WARNING',
            params   => [],
            location => { file => 'warning.pl', line => 2 },
        }
    )
);
my $warning_rethrow = XPerl::Diagnostic->_new(
    {
        code     => 'RETHROWN_AT',
        number   => 5,
        severity => 'CONTEXT',
        params   => [],
        location => { file => 'hook.pl', line => 7 },
    }
);
$warning_exception->_record_throw(
    {
        file   => 'hook.pl',
        line   => 7,
        reason => 'rethrow'
    },
    $warning_rethrow
);
is( $warning_exception->origin->{file},
    'hook.pl', 'the first throw of a warning object sets the throw origin' );
is( $warning_exception->origin->{message_index},
    1, 'the first throw links its rethrow diagnostic' );
is( $warning_exception->contents->[0]->location->{file},
    'warning.pl', 'the original warning location remains separate' );

eval { die $exception };
is(
    overload::StrVal($@),
    overload::StrVal($exception),
    'current die and eval preserve reference identity'
);

is(
    $first->render_as_legacy('en'),
    'Illegal division by zero at runtime.pl line 12.',
    'diagnostic rendering looks up its catalog template'
);
is(
    $first->render_as_legacy('fr'),
    "Division par z\N{U+E9}ro ill\N{U+E9}gale \N{U+E0} runtime.pl ligne 12.",
    'zero-argument translated templates preserve accented characters'
);
is(
    $first->render_as_legacy('nl'),
    'Delen door nul is niet toegestaan in runtime.pl op regel 12.',
    'rendering discovers the Dutch catalog generated from the config'
);
ok(
    utf8::is_utf8( $first->render_as_legacy('fr') ),
    'zero-argument translated templates remain UTF-8 strings'
);

my $byte_parent = XPerl::Diagnostic->_new(
    {
        code     => 'ERROR_USER_TEXT',
        number   => 2438,
        kind     => 'USER_RUNTIME',
        severity => 'NOTE',
        params   => [
            {
                name  => 'text',
                type  => 'text',
                value => pack( 'C*', 112, 97, 114, 101, 110, 116 ),
            },
        ],
        location => {},
    }
);
my $utf8_child = XPerl::Diagnostic->_new(
    {
        code     => 'WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED',
        number   => 2260,
        kind     => 'CORE_RUNTIME',
        severity => 'WARNING',
        params   => [
            { name => 'arg1', type => 'text', value => "caf\x{e9}" },
        ],
        location => {},
    }
);
$byte_parent->append($utf8_child);
my $byte_parent_rendered = $byte_parent->render_as_legacy('fr');
ok( !utf8::is_utf8( $byte_parent->params->[0]{value} ),
    'the parent starts with a byte string' );
ok( utf8::is_utf8($byte_parent_rendered),
    'a UTF-8 child makes the nested rendering UTF-8' );
like( $byte_parent_rendered, qr/caf\N{U+00E9}/,
    'nested French rendering preserves UTF-8 child text' );

my $localized_diagnostic = XPerl::Diagnostic->_new(
    {
        code     => 'WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED',
        number   => 2260,
        kind     => 'CORE_RUNTIME',
        severity => 'WARNING',
        params   =>
          [ { name => 'arg1', type => 'text', value => 'array slice' }, ],
        location => { file => 'modern.pl', line => 12 },
    }
);
my $localized_exception = XPerl::Exception->_new();
$localized_exception->append($localized_diagnostic);
is(
    $localized_exception->render_as_modern('en'),
'#2260 WARNING.CORE_RUNTIME.WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED modern.pl:12'
      . "\nMultidimensional syntax array slice not supported at modern.pl line 12.\n",
    'modern exception rendering prefixes English with diagnostic metadata'
);
is(
    $localized_exception->render_as_modern('fr'),
'#2260 WARNING.CORE_RUNTIME.WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED modern.pl:12'
      . "\nLa syntaxe multidimensionnelle array slice n\'est pas prise en charge \N{U+E0} modern.pl ligne 12.\n",
    'modern exception rendering prefixes French with diagnostic metadata'
);
is(
    $localized_exception->render_as_modern('nl'),
'#2260 WARNING.CORE_RUNTIME.WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED modern.pl:12'
      . "\nMeerdimensionale syntaxis array slice wordt niet ondersteund in modern.pl op regel 12.\n",
    'modern exception rendering prefixes Dutch with diagnostic metadata'
);

eval q{ use strict; $xperl_french = 1; };
my $french_compile_error = $@->render_as_legacy('fr');
ok( utf8::is_utf8($french_compile_error),
    'localized diagnostic rendering keeps its UTF-8 flag' );
like( $french_compile_error, qr/n\N{U+00E9}cessite/,
    'localized diagnostic rendering preserves accented characters' );

ok(
    !exists $localized_diagnostic->{template}
      && !exists $localized_diagnostic->{text},
    'catalog template and rendered text are absent from the diagnostic object'
);
my $second_localized_diagnostic = XPerl::Diagnostic->_new(
    {
        code     => 'WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED',
        number   => 2260,
        kind     => 'CORE_RUNTIME',
        severity => 'WARNING',
        params   =>
          [ { name => 'arg1', type => 'text', value => 'hash slice' }, ],
        location => {},
    }
);
$localized_exception->append($second_localized_diagnostic);
like(
    $localized_exception->render_as_modern('en'),
    qr/array slice.*hash slice/s,
    'modern exception rendering includes every diagnostic in order'
);
like(
    $localized_exception->render_as_modern('fr'),
    qr/array slice.*hash slice/s,
    'modern rendering localizes the whole exception'
);

is(
    $localized_diagnostic->render_as_legacy(
        'en', { exception => $localized_exception, index => 0 }
    ),
    'Multidimensional syntax array slice not supported',
    'a supplied render context lets the diagnostic defer its location'
);

{

    package XPerlTest::RenderAppend;
    use overload '""' => sub {
        my ($self) = @_;
        if ( !$self->{did_append}++ ) {
            push @{ $self->{exception}{contents} }, $self->{next};
        }
        return $self->{value};
      },
      fallback => 1;
}

my $appended_diagnostic = XPerl::Diagnostic->_new(
    {
        code     => 'WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED',
        number   => 2260,
        kind     => 'CORE_RUNTIME',
        severity => 'WARNING',
        params   =>
          [ { name => 'arg1', type => 'text', value => 'hash slice' }, ],
        location => { file => 'append.pl', line => 14 },
    }
);
my $appending_value = bless {
    value => 'array slice',
    next  => $appended_diagnostic,
  },
  'XPerlTest::RenderAppend';
my $appending_diagnostic = XPerl::Diagnostic->_new(
    {
        code     => 'WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED',
        number   => 2260,
        kind     => 'CORE_RUNTIME',
        severity => 'WARNING',
        params   =>
          [ { name => 'arg1', type => 'text', value => $appending_value }, ],
        location => { file => 'append.pl', line => 13 },
    }
);
my $appending_exception = XPerl::Exception->_new();
$appending_value->{exception} = $appending_exception;
$appending_exception->append($appending_diagnostic);
like(
    $appending_exception->render_as_modern('en'),
    qr/array slice.*hash slice/s,
    'modern rendering observes diagnostics appended during rendering'
);
$appending_value->{did_append} = 0;
like(
    $appending_exception->render_as_legacy('en'),
    qr/array slice.*hash slice/s,
    'legacy rendering observes diagnostics appended during rendering'
);

{

    package XPerlTest::RenderReplace;
    use overload '""' => sub {
        my ($self) = @_;
        $self->{exception}{contents} = [ $self->{replacement} ]
          unless $self->{did_replace}++;
        return 'array slice';
      },
      fallback => 1;
}

my $replacement_diagnostic = XPerl::Diagnostic->_new(
    {
        code     => 'WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED',
        number   => 2260,
        kind     => 'CORE_RUNTIME',
        severity => 'WARNING',
        params   =>
          [ { name => 'arg1', type => 'text', value => 'hash slice' }, ],
        location => { file => 'replace.pl', line => 24 },
    }
);
my $replacing_value = bless { replacement => $replacement_diagnostic, },
  'XPerlTest::RenderReplace';
my $replacing_diagnostic = XPerl::Diagnostic->_new(
    {
        code     => 'WARNING_SYNTAX_MULTIDIMENSIONAL_SUBSCRIPT_UNSUPPORTED',
        number   => 2260,
        kind     => 'CORE_RUNTIME',
        severity => 'WARNING',
        params   =>
          [ { name => 'arg1', type => 'text', value => $replacing_value }, ],
        location => { file => 'replace.pl', line => 23 },
    }
);
my $replacing_exception = XPerl::Exception->_new();
$replacing_value->{exception} = $replacing_exception;
$replacing_exception->append($replacing_diagnostic);
my $replacement_rendering = $replacing_exception->render_as_modern('en');
like(
    $replacement_rendering,
    qr/array slice/,
    'rendering keeps the current diagnostic alive while its array is replaced'
);
unlike( $replacement_rendering, qr/hash slice/,
    'rendering observes truncation after the current diagnostic' );

{
    package XPerlTest::ChildArrayReplace;
    use overload '""' => sub {
        my ($self) = @_;
        if ( !$self->{did_replace}++ ) {
            $self->{parent}{contents} = [ $self->{replacement} ];
        }
        return $self->{value};
      },
      fallback => 1;
}

my $replacement_child = XPerl::Diagnostic->_new(
    {
        code     => 'ERROR_USER_TEXT',
        number   => 2438,
        kind     => 'USER_RUNTIME',
        severity => 'FATAL_ERROR',
        params   => [ { name => 'text', type => 'text', value => 'replacement' } ],
        location => {},
    }
);
my $replacing_child_value;
$replacing_child_value = bless {
    value       => 'first child',
    replacement => $replacement_child,
  }, 'XPerlTest::ChildArrayReplace';
my $first_nested_child = XPerl::Diagnostic->_new(
    {
        code     => 'ERROR_USER_TEXT',
        number   => 2438,
        kind     => 'USER_RUNTIME',
        severity => 'FATAL_ERROR',
        params   => [ { name => 'text', type => 'text', value => $replacing_child_value } ],
        location => {},
    }
);
my $second_nested_child = XPerl::Diagnostic->_new(
    {
        code     => 'ERROR_USER_TEXT',
        number   => 2438,
        kind     => 'USER_RUNTIME',
        severity => 'FATAL_ERROR',
        params   => [ { name => 'text', type => 'text', value => 'second child' } ],
        location => {},
    }
);
my $mutating_parent = XPerl::Diagnostic->_new(
    {
        code     => 'ERROR_USER_TEXT',
        number   => 2438,
        kind     => 'USER_RUNTIME',
        severity => 'FATAL_ERROR',
        params   => [ { name => 'text', type => 'text', value => 'parent' } ],
        location => {},
    }
);
$replacing_child_value->{parent} = $mutating_parent;
$mutating_parent->append($first_nested_child);
$mutating_parent->append($second_nested_child);
my $mutating_nested_render = $mutating_parent->render_as_legacy('en');
like( $mutating_nested_render, qr/first child/,
    'nested rendering keeps the current child alive during overload mutation' );
unlike( $mutating_nested_render, qr/second child|replacement/,
    'nested rendering re-fetches the replaced child array' );
$mutating_parent->{contents} = [];
$replacing_child_value->{parent} = undef;

$replacing_exception->{contents} = [$replacing_diagnostic];
$replacing_value->{did_replace}  = 0;
$replacement_rendering           = $replacing_exception->render_as_legacy('en');
like(
    $replacement_rendering,
    qr/array slice/,
'legacy rendering keeps the current diagnostic alive while its array is replaced'
);
unlike( $replacement_rendering, qr/hash slice/,
    'legacy rendering observes truncation after the current diagnostic' );

my $saved_error = $@ = 'saved error';
my $dump        = $exception->render('Dumper');
like(
    $dump,
    qr/"schema" => "xperl\.diagnostic-group\.v2".*?ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO/s,
    'Dumper rendering includes the structured exception and diagnostics'
);
is( $@, $saved_error, 'Dumper rendering preserves the active error value' );
like(
    $exception->render('legacy'),
    qr/Illegal division by zero/,
    'Dumper rendering does not change template-rendered diagnostic output'
);

my $diagnostic_json = JSON::PP->new->decode( $first->as_json );
is( $diagnostic_json->{schema},
    'xperl.diagnostic.v2',
    'standalone diagnostic JSON has a versioned schema' );
is( $diagnostic_json->{code},
    'ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO', 'diagnostic JSON uses the symbolic code' );

my $serializer_cycle = XPerl::Diagnostic->_new(
    {
        code => 'ERROR_USER_TEXT', number => 2438, kind => 'USER_RUNTIME',
        severity => 'FATAL_ERROR', params => [], location => {},
    }
);
$serializer_cycle->{contents} = [$serializer_cycle];
my $cycle_json = JSON::PP->new->decode( $serializer_cycle->as_json );
ok( !defined $cycle_json->{contents}[0],
    'JSON serialization emits null at an ancestor cycle edge' );
$serializer_cycle->{contents} = [];

my $wide_selector_key = 0xffff << 48;
my $wide_key_diagnostic = XPerl::Diagnostic->_new(
    {
        code         => 'ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO',
        number       => 1001,
        kind         => 'CORE_RUNTIME',
        severity     => 'FATAL_ERROR',
        selector_key => $wide_selector_key,
        params       => [],
        location     => {},
    }
);
is( $wide_key_diagnostic->selector_key, $wide_selector_key,
    'diagnostic objects retain the complete U64 selector key' );
my $wide_key_json = JSON::PP->new->decode( $wide_key_diagnostic->as_json );
is( $wide_key_json->{selector_key}, $wide_selector_key,
    'diagnostic JSON round trips a key with the top U16 field set' );
my $wide_key_literal = eval $wide_key_diagnostic->render_as_dumper;
is( $@, '', 'wide selector key Dumper output is a valid Perl literal' );
is( $wide_key_literal->{selector_key}, $wide_selector_key,
    'diagnostic Dumper output round trips the top U16 selector field' );

is( scalar @{ $diagnostic_json->{params} },
    0, 'diagnostic JSON carries the typed parameters' );
ok( !exists $diagnostic_json->{text},
    'diagnostic JSON omits a rendered text field' );
is( $diagnostic_json->{location}{file},
    'runtime.pl', 'diagnostic JSON includes the source location' );
ok(
    !exists $diagnostic_json->{location}{column},
    'diagnostic JSON has no column field'
);
ok(
    !exists $diagnostic_json->{warning_categories},
    'diagnostic JSON omits absent warning categories'
);
my $undefined_categories = XPerl::Diagnostic->_new(
    {
        code               => 'UNCATEGORIZED',
        warning_categories => undef,
        params             => [],
        location           => {},
    }
);
ok(
    !exists JSON::PP->new->decode( $undefined_categories->as_json )
      ->{warning_categories},
    'diagnostic JSON omits explicitly undefined warning categories'
);
my $exception_json    = $exception->as_json;
my $decoded_exception = JSON::PP->new->decode($exception_json);
is( $decoded_exception->{schema},
    'xperl.exception.v2', 'exception JSON has its own versioned schema' );
is( $decoded_exception->{contents}[1]{code},
    'RETHROWN_AT', 'exception JSON keeps diagnostic order' );
is(
    $exception->render('json'),
    $exception->render('JSONL'),
    'JSON and JSONL use the same line-oriented shape'
);
$exception->{private_marker} = 'not in the schema';
$first->{private_marker}     = 'not in the schema';
is( $exception->as_json, $exception_json,
    'JSON output does not expose private object fields' );

my $escaped_diagnostic = XPerl::Diagnostic->_new(
    {
        code   => 'ESCAPED_TEXT',
        params => [
            {
                name  => 'fragment',
                type  => 'text',
                value => "\"\\\n\0\x{100}\x{1f642}",
            }
        ],
        location => {},
    }
);
is(
    JSON::PP->new->decode( $escaped_diagnostic->as_json )->{params}[0]{value},
    "\"\\\n\0\x{100}\x{1f642}",
    'JSON preserves quotes, backslashes, controls and Unicode'
);
like( $escaped_diagnostic->as_json,
    qr/\\u0100/,
    'JSON escapes non-ASCII text without a JSON module in the renderer' );
like( $escaped_diagnostic->as_json,
    qr/\\uD83D\\uDE42/,
    'JSON uses a surrogate pair for supplementary code points' );

{
    my $json = $escaped_diagnostic->render_as_json;
    is(
        $json,
        $escaped_diagnostic->as_json,
        'diagnostic JSON renderer uses the defined schema'
    );
    my $literal = $escaped_diagnostic->render_as_dumper;
    unlike( $literal, qr/\n/,
        'diagnostic Dumper rendering occupies one physical line' );
    my $decoded = eval $literal;
    is( $@, '', 'diagnostic Dumper rendering is a valid Perl literal' );
    is(
        $decoded->{params}[0]{value},
        $escaped_diagnostic->params->[0]{value},
        'Dumper literals round trip controls and supplementary Unicode'
    );

    my $interpolation = XPerl::Diagnostic->_new(
        {
            code   => 'ESCAPED_TEXT',
            params => [
                {
                    name  => 'text',
                    type  => 'text',
                    value => q{$secret @array \" \u1234}
                }
            ],
            location => {},
        }
    );
    my $copy = eval $interpolation->render_as_dumper;
    is( $@, '', 'Dumper literals escape Perl interpolation characters' );
    is(
        $copy->{params}[0]{value},
        $interpolation->params->[0]{value},
        'Dumper literals preserve dollar signs, arrays and literal escapes'
    );

    my $records = $exception->render('fr:legacy:JSON');
    my @lines   = grep length, split /\n/, $records;
    my @decoded = map { JSON::PP::decode_json($_) } @lines;
    is(
        join( '', map { $_->{message} } @decoded ),
        $exception->render_as_legacy('fr'),
        'JSON records contain the requested translated human messages'
    );
    is( $decoded[0]{type}, 'FATAL_ERROR',
        'record type comes from its primary diagnostic' );
    unlike( $records, qr/private_marker/,
        'records omit private object fields' );
    is( $exception->render('fr:legacy:JSONL'),
        $records, 'JSONL is an alias for JSON' );

    my @dumped = grep length, split /\n/,
      $exception->render('fr:legacy:Dumper');
    my @copies = map { eval $_ } @dumped;
    is( $@, '', 'Dumper group records are valid Perl literals' );
    is(
        JSON::PP->new->canonical->encode( \@copies ),
        JSON::PP->new->canonical->encode( \@decoded ),
        'Dumper and JSON share the same public record fields'
    );
}

{
    my $output = runperl(
        prog => q{
            BEGIN {
                ${^DIAG_RENDER} = q[en:legacy:JSON];
                $SIG{__DIE__} = sub { print STDERR q[HOOK:], $_[0] };
            }
            my $e = XPerl::Exception->_new();
            for my $spec ([q[ERROR_USER_TEXT], 2438, q[FATAL_ERROR], qq[first\n]],
                          [q[WARNING_USER_TEXT], 2439, q[WARNING], qq[middle\n]],
                          [q[ERROR_USER_TEXT], 2438, q[FATAL_ERROR], qq[last\n]]) {
                $e->append(XPerl::Diagnostic->_new({
                    code => $spec->[0], number => $spec->[1], severity => $spec->[2],
                    kind => q[USER_RUNTIME], params => [{name => q[text], type => q[text],
                    value => $spec->[3]}], location => {},
                }));
            }
            die $e;
        },
        stderr => 1,
    );
    my @lines = grep length, split /\n/, $output;
    is( scalar @lines,
        5,
        'JSON delivery finishes each error before the next warning or error' );
    like( $lines[0], qr/^HOOK:/, 'die hook runs before its group output' );
    my @records = map { s/^HOOK://; JSON::PP::decode_json($_) } @lines;
    is(
        $records[0]{message},
        "first (Stack unwind deferred)\n",
        'die hook receives the serialized human message with its deferred hint'
    );
    is( $records[1]{message},
        "first\n", 'automatic output retains the original human message' );
    is( $records[2]{type}, 'WARNING',
        'warning record stays between the error groups' );
    is( $records[3]{message},
        "last\n", 'final die hook receives the final serialized group' );
    is( $records[4]{message},
        "last\n",
        'final group is printed once without an aggregate duplicate' );
}

{
    my $warning = runperl(
        prog => q{
            BEGIN {
                ${^DIAG_RENDER} = q[en:legacy:Dumper];
                $SIG{__WARN__} = sub { print $_[0] };
            }
            warn q[quoted ] . chr(34) . qq[ \nline\n];
            print exists $INC{q[Data/Dumper.pm]} ? q[module loaded] : q[native writer];
        },
    );
    my ( $line, $implementation ) = split /\n/, $warning;
    my $record = eval $line;
    is( $@, '', 'warning hook receives a complete Dumper record' );
    is( $record->{type}, 'WARNING',
        'warning envelope has its primary severity' );
    is(
        $record->{message},
        "quoted \" \nline\n",
        'warning envelope retains its human text'
    );
    is(
        $implementation,
        'native writer',
        'Dumper output does not load Data::Dumper'
    );
}

{
    use warnings FATAL => 'uninitialized';
    my $value;
    eval { my $joined = $value . 'suffix' };
    my $record = JSON::PP::decode_json( $@->render('en:legacy:JSON') );
    is( $record->{type}, 'FATAL_ERROR',
        'fatal warning group records its error disposition' );
    ok( $record->{contents}[0]{fatal},
        'fatalized warning metadata records its disposition' );
    is( $record->{contents}[0]{code}, 'ERROR_FATALIZED_WARNING_WRAPPER',
        'fatal JSON exposes the promotion wrapper' );
    is( $record->{contents}[0]{number}, 2719,
        'the promotion wrapper uses its stable catalog number' );
    is( $record->{contents}[0]{kind}, 'CORE_RUNTIME',
        'the promotion wrapper carries catalogued runtime metadata' );
    is( $record->{contents}[0]{promotion_reason}, 'fatal warning category',
        'fatal JSON records the promotion reason' );
    is( $record->{contents}[0]{contents}[0]{code}, 'WARNING_UNINITIALIZED_VALUE_WITH_OPERATION',
        'fatal JSON preserves the original warning as a child' );
}

{
    my $hint = XPerl::Diagnostic->_new(
        {
            code     => 'NOTE_HINT_STACK_UNWIND_DEFERRED',
            number   => 2522,
            kind     => 'CORE_RUNTIME',
            severity => 'WARNING',
            params   => [],
            location => {},
        }
    );
    like(
        $hint->render_as_legacy('fr'),
        qr/D\N{U+E9}roulement de la pile diff\N{U+E9}r\N{U+E9}/,
        'French deferred-unwind rendering preserves decoded accents'
    );
    like( $hint->render_as_legacy('de'),
        qr/zur\N{U+FC}ckgestellt/,
        'German deferred-unwind rendering preserves its decoded umlaut' );
}

my $implicit_json = do {
    local $ENV{PERL_DIAG_RENDER} = 'JSON';
    runperl( prog => 'eval { die q[hello] }; print $@' );
};
is(
    JSON::PP->new->decode($implicit_json)->{contents}[0]{code},
    'ERROR_USER_TEXT',
    'the environment selects implicit JSON rendering'
);

my $implicit_dump = do {
    local $ENV{PERL_DIAG_RENDER} = 'Dumper';
    runperl(
            prog => 'require XPerl::Exception; my $e = XPerl::Exception->_new; '
          . '$e->append(XPerl::Diagnostic->_new({code => q[ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO], '
          . 'number => 1001, kind => q[CORE_RUNTIME], severity => q[FATAL_ERROR], '
          . 'params => [], location => {}})); print $e' );
};
like(
    $implicit_dump,
    qr/"schema" => "xperl\.diagnostic-group\.v2".*?CORE_RUNTIME/s,
    'environment selects implicit Dumper rendering'
);
unlike( $implicit_dump, qr/^legacy$/, 'Dumper mode does not show legacy text' );
my $implicit_legacy = do {
    local $ENV{PERL_DIAG_RENDER} = 'legacy';
    runperl(
            prog => 'require XPerl::Exception; my $e = XPerl::Exception->_new; '
          . '$e->append(XPerl::Diagnostic->_new({code => q[ERROR_USER_TEXT], '
          . 'number => 2438, kind => q[USER_RUNTIME], severity => q[FATAL_ERROR], '
          . 'params => [{name => q[text], type => q[text], value => q[legacy]}], '
          . 'location => {}})); '
          . '$ENV{PERL_DIAG_RENDER} = q[Dumper]; print $e' );
};
is( $implicit_legacy, 'legacy', 'render mode is fixed when the class loads' );

my $default_user_error =
  runperl( prog => 'eval { die q[hello] }; print join(q[|], ref($@), '
      . '$@->contents->[0]->code, $@->contents->[0]->params->[0]{value}), '
      . 'chr(10)' );
is(
    $default_user_error,
    "XPerl::Exception|ERROR_USER_TEXT|hello\n",
    'plain die creates a user error without loading the exception module'
);

for my $compile_failure (
    [ strict_vars => q{use strict; $missing = 1;} ],
    [ syntax      => q{my $value = ;} ],
    [ begin       => q{BEGIN { die "compile failure\n" }} ],
    [ unitcheck   => q{UNITCHECK { die "unitcheck failure\n" }} ],
  )
{
    my ( $name, $source ) = @$compile_failure;
    eval $source;
    my $caught    = $@;
    my $canonical = ${^ERROR_OBJ};
    is( ref($canonical), 'XPerl::Exception',
        "$name compile failure publishes the canonical exception" );
    is(
        defined($canonical) ? overload::StrVal($canonical) : '<undef>',
        overload::StrVal($caught),
        "$name compile failure exposes the same object through both variables"
    );
}

{
    eval q{use strict; $outer_missing = 1;};
    my $outer_exception = ${^ERROR_OBJ};
    is( ref($outer_exception), 'XPerl::Exception',
        'the outer compile failure has a canonical exception' );
    {
        local $@;
        eval q{my $inner_value = ;};
        is(
            defined( ${^ERROR_OBJ} )
            ? overload::StrVal( ${^ERROR_OBJ} )
            : '<undef>',
            overload::StrVal($@),
            'a localized compile failure publishes its own exception'
        );
    }
    is(
        defined( ${^ERROR_OBJ} ) ? overload::StrVal( ${^ERROR_OBJ} )
        : '<undef>',
        defined($outer_exception) ? overload::StrVal($outer_exception)
        : '<missing outer>',
        'leaving localized $@ restores the outer compile exception'
    );
    eval '1';
    ok( !defined ${^ERROR_OBJ},
        'successful string eval clears the caught compile exception' );
}

{
    my $replacement = [];
    local $SIG{__DIE__} = sub { die $replacement };
    eval q{use strict; $hook_missing = 1;};
    my $caught    = $@;
    my $canonical = ${^ERROR_OBJ};
    is(
        overload::StrVal($caught),
        overload::StrVal($replacement),
        'a compile-error hook preserves its replacement reference in $@'
    );
    is( ref($canonical), 'XPerl::Exception',
        'a compile-error hook publishes its replacement exception' );
}

my $thrown_object = [];
eval { die $thrown_object };
is( ref($@), 'ARRAY',
    'the caught value of a reference exception is the reference' );
is( ref( ${^ERROR_OBJ} ),
    'XPerl::Exception',
    'the canonical error variable contains the structured exception' );
is( ${^ERROR_OBJ}->contents->[0]->code,
    'ERROR_USER_REFERENCE',
    'die with a reference records a user exception object diagnostic' );
is(
    overload::StrVal($@),
    overload::StrVal($thrown_object),
    'the compatibility value preserves the thrown reference identity'
);
is(
    overload::StrVal( ${^ERROR_OBJ}->contents->[0]->params->[0]{value} ),
    overload::StrVal($thrown_object),
    'the structured diagnostic retains the original thrown reference'
);

ok( ${^ERROR_OBJ}->{thrown},
    'the structured exception records that it was thrown' );

my $explicitly_rethrown = ${^ERROR_OBJ};
eval { die $explicitly_rethrown };
is( ref($@), 'ARRAY',
    'the compatibility value remains the reference held by its diagnostic' );
is(
    overload::StrVal($@),
    overload::StrVal($thrown_object),
    'rethrowing the structured exception preserves the diagnostic reference'
);
is( ref( ${^ERROR_OBJ} ),
    'XPerl::Exception',
    'explicit rethrow keeps the structured exception canonical' );
is(
    overload::StrVal( ${^ERROR_OBJ} ),
    overload::StrVal($explicitly_rethrown),
    'explicit rethrow preserves the structured exception identity'
);
is( ${^ERROR_OBJ}->contents->[-1]->code,
    'ERROR_PROPAGATION_RETHROW_CONTEXT', 'explicit rethrow appends its propagation diagnostic' );
ok( ${^ERROR_OBJ}->{thrown}, 'explicit rethrow keeps the thrown state set' );

eval { die "scalar exception for explicit rethrow\n" };
my $scalar_exception = ${^ERROR_OBJ};
eval { die $scalar_exception };
is(
    overload::StrVal( ${^ERROR_OBJ} ),
    overload::StrVal($scalar_exception),
    'explicitly rethrowing a scalar exception keeps its canonical object'
);
is(
    ${^ERROR_OBJ}->contents->[0]->params->[0]{value},
    "scalar exception for explicit rethrow\n",
    'explicit scalar rethrow preserves its original diagnostic'
);
is( ${^ERROR_OBJ}->contents->[-1]->code,
    'ERROR_PROPAGATION_RETHROW_CONTEXT', 'explicit scalar rethrow appends propagation context' );

my $nested_thrown_object = bless {}, 'XPerlTest::NestedThrownObject';
my $nested_reference_exception;
eval {
    eval { die $nested_thrown_object };
    $nested_reference_exception = ${^ERROR_OBJ};
    die $@;
};
is(
    ref($@),
    'XPerlTest::NestedThrownObject',
    'die $@ after a nested eval preserves a reference exception value'
);
is(
    overload::StrVal($@),
    overload::StrVal($nested_thrown_object),
    'die $@ after a nested eval preserves reference identity'
);
is( ref( ${^ERROR_OBJ} ),
    'XPerl::Exception', 'die $@ wraps the reference in a canonical exception' );
isnt(
    overload::StrVal( ${^ERROR_OBJ} ),
    overload::StrVal($nested_reference_exception),
    'die $@ creates a new canonical exception from the reference value'
);
is( ${^ERROR_OBJ}->contents->[0]->code,
    'ERROR_USER_REFERENCE',
    'the new exception records the compatibility reference as its value' );
is(
    overload::StrVal( ${^ERROR_OBJ}->contents->[0]->params->[0]{value} ),
    overload::StrVal($nested_thrown_object),
    'the new diagnostic retains the original thrown reference'
);

for my $case ( [ hash => {} ], [ code => sub { 1 } ] ) {
    my ( $kind, $reference ) = @$case;
    eval { die $reference };
    is( ref($@), uc($kind),
        "die with an unblessed $kind reference preserves its type" );
    is(
        overload::StrVal($@),
        overload::StrVal($reference),
        "die with an unblessed $kind reference preserves its identity"
    );
    is( ${^ERROR_OBJ}->contents->[0]->code, 'ERROR_USER_REFERENCE',
        "die with an unblessed $kind reference records a structured diagnostic"
    );
    is(
        overload::StrVal( ${^ERROR_OBJ}->contents->[0]->params->[0]{value} ),
        overload::StrVal($reference),
        "the $kind diagnostic retains the original reference"
    );
}

my $regex_reference = qr{x};
eval { die $regex_reference };
is( ref($@), 'Regexp', 'die with a regex reference preserves its type in $@' );
is(
    overload::StrVal($@),
    overload::StrVal($regex_reference),
    'die with a regex reference preserves its identity in $@'
);
is( ${^ERROR_OBJ}->contents->[0]->code,
    'ERROR_USER_REFERENCE',
    'die with a regex reference records a structured diagnostic' );
is(
    overload::StrVal( ${^ERROR_OBJ}->contents->[0]->params->[0]{value} ),
    overload::StrVal($regex_reference),
    'the structured diagnostic retains the regex reference'
);

eval { die "string exception\n" };
is( ref($@), 'XPerl::Exception',
    'a string exception appears as an XPerl::Exception in $@' );
is(
    overload::StrVal($@),
    overload::StrVal( ${^ERROR_OBJ} ),
    '$@ and the canonical variable expose the same string exception'
);

my $reference_exception    = ${^ERROR_OBJ};
my $reference_compat_value = $@;
{
    local $@;
    eval { die "inner exception\n" };
    is( ref($@), 'XPerl::Exception',
        'a string exception still appears as an XPerl::Exception' );
    is( ref( ${^ERROR_OBJ} ),
        'XPerl::Exception',
        'the canonical variable tracks the inner exception' );
}
is(
    overload::StrVal( ${^ERROR_OBJ} ),
    overload::StrVal($reference_exception),
    'localizing $@ restores the matching canonical exception'
);
is(
    overload::StrVal($@),
    overload::StrVal($reference_compat_value),
    'localizing $@ restores the compatibility value from the outer scope'
);

my $localized_reference = bless {}, 'XPerlTest::LocalizedReference';
eval { die $localized_reference };
my $localized_reference_exception = ${^ERROR_OBJ};
{
    local $@ = 'temporary localized value';
    ok( !defined ${^ERROR_OBJ},
        'assigning localized $@ clears the canonical exception in scope' );
    eval { die "inner localized exception\n" };
}
is(
    ref($@),
    'XPerlTest::LocalizedReference',
    'localizing $@ restores an outer reference exception value'
);
is(
    overload::StrVal( ${^ERROR_OBJ} ),
    overload::StrVal($localized_reference_exception),
    'localizing $@ restores the canonical outer reference exception'
);

eval { die "append mutation\n" };
$@ .= ' changed';
ok( !defined ${^ERROR_OBJ}, 'mutating $@ clears the canonical exception' );
eval { die "substitution mutation\n" };
$@ =~ s/substitution/changed/;
ok( !defined ${^ERROR_OBJ},
    'substituting in $@ clears the canonical exception' );
eval { die "undef mutation\n" };
undef $@;
ok( !defined ${^ERROR_OBJ}, 'undefining $@ clears the canonical exception' );

our ( $destroy_eval_error, $destroy_eval_exception );
{

    package XPerlTestDestroyEval;

    sub DESTROY {
        eval { die "exception from DESTROY\n" };
        $main::destroy_eval_error     = $@;
        $main::destroy_eval_exception = ${^ERROR_OBJ};
    }
}
{
    my $object = bless {}, 'XPerlTestDestroyEval';
}
is( ref($destroy_eval_error),
    'XPerl::Exception', 'eval in DESTROY catches a structured exception' );
is(
    overload::StrVal($destroy_eval_error),
    overload::StrVal($destroy_eval_exception),
    'eval in DESTROY keeps $@ and the canonical exception synchronized'
);

my $default_core_error =
  runperl( prog => 'my $divisor = 0; eval { my $result = 1 / $divisor }; print '
      . 'join(q[|], ref($@), $@->contents->[0]->code), chr(10)' );
is(
    $default_core_error,
    "XPerl::Exception|ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO\n",
    'catalogued runtime errors are objects by default'
);

my $user_error_hook =
  runperl( prog => 'local $SIG{__DIE__} = sub { print join(q[|], ref($_[0]), '
      . '${^CUR_ERROR_OBJ}->contents->[0]->code), chr(10) }; eval { die q[hello] }; '
      . 'print ref($@), chr(10)' );
is(
    $user_error_hook,
    "|ERROR_USER_TEXT\nXPerl::Exception\n",
    'the die hook receives text while eval retains the exception object'
);

my ( $die_hook_current_exception, $die_hook_current_after );
{
    local $SIG{__DIE__} = sub {
        $die_hook_current_exception = ${^CUR_ERROR_OBJ};
    };
    eval { die "current die hook exception\n" };
    $die_hook_current_after = ${^CUR_ERROR_OBJ};
}
is( ref($die_hook_current_exception),
    'XPerl::Exception',
    '__DIE__ can inspect the canonical exception in its dynamic scope' );
is( $die_hook_current_exception->contents->[0]->code,
    'ERROR_USER_TEXT', '__DIE__ sees the exception currently being handled' );
ok( !defined($die_hook_current_after),
    'the current exception variable is restored after __DIE__' );

my ( $warn_hook_current_exception, $warn_hook_current_after );
{
    local $SIG{__WARN__} = sub {
        $warn_hook_current_exception = ${^CUR_ERROR_OBJ};
    };
    warn "current warn hook exception\n";
    $warn_hook_current_after = ${^CUR_ERROR_OBJ};
}
is( ref($warn_hook_current_exception),
    'XPerl::Exception',
    '__WARN__ can inspect the canonical exception in its dynamic scope' );
is( $warn_hook_current_exception->contents->[0]->code,
    'WARNING_USER_TEXT', '__WARN__ sees the warning currently being handled' );
ok( !defined($warn_hook_current_after),
    'the current exception variable is restored after __WARN__' );

{
    package XPerlTestHookContext;
    sub die_trigger { die "caller and eval state in die hook\n" }
    sub warn_trigger { warn "caller and eval state in warn hook\n" }
}
my @hook_context_states;
{
    local $SIG{__DIE__} = sub {
        push @hook_context_states,
          [ 'DIE', $^S, ( caller(1) )[3] ];
    };
    local $SIG{__WARN__} = sub {
        push @hook_context_states,
          [ 'WARN', $^S, ( caller(1) )[3] ];
    };
    eval { XPerlTestHookContext::die_trigger() };
    eval { XPerlTestHookContext::warn_trigger() };
}
is(
    join( '|', map { join( ',', @$_ ) } @hook_context_states ),
    'DIE,1,XPerlTestHookContext::die_trigger'
      . '|WARN,1,XPerlTestHookContext::warn_trigger',
    'warning and die hooks preserve caller context and eval state'
);
ok( !$^S, 'hook delivery restores the eval state after the eval returns' );

my (
    @die_hook_exception_codes, $warn_during_die_exception,
    $warn_during_die_text,     $die_during_warning_hook
);
{
    local $SIG{__EXCEPT__} = sub {
        push @die_hook_exception_codes, $_[0]->contents->[0]->code;
    };
    local $SIG{__DIE__}  = sub { warn "warning from die hook\n" };
    local $SIG{__WARN__} = sub {
        $warn_during_die_exception = ${^CUR_ERROR_OBJ};
        $warn_during_die_text      = $_[0];
    };
    eval { die "original failure\n" };
    $die_during_warning_hook = $@;
}
is( $warn_during_die_exception->contents->[0]->code,
    'ERROR_USER_TEXT', '__WARN__ in __DIE__ sees the active exception' );
is(
    $warn_during_die_text,
    "warning from die hook\n",
    'warn in __DIE__ calls __WARN__ directly with its legacy value'
);
is( join( ',', @die_hook_exception_codes ),
    'ERROR_USER_TEXT', 'warn in __DIE__ does not create another exception episode' );
is( $die_during_warning_hook->contents->[0]->code,
    'ERROR_USER_TEXT',
    'a handled warning does not replace the active fatal exception' );

my (
    $warning_handler_context,     $warning_handler_original,
    $warning_handler_replacement, $die_hook_calls_for_warning_handler
);
{
    local $SIG{__DIE__} = sub {
        $die_hook_calls_for_warning_handler++;
        warn "warning before handler failure\n";
    };
    local $SIG{__WARN__} = sub {
        $warning_handler_context = ${^CUR_ERROR_OBJ};
        $warning_handler_original =
          $warning_handler_context->contents->[0]->params->[0]{value};
        die "warning handler failure\n";
    };
    eval { die "original fatal error\n" };
    $warning_handler_replacement = $@;
}
is(
    $warning_handler_original,
    "original fatal error\n",
    '__WARN__ retains the active fatal object while running inside __DIE__'
);
is(
    $warning_handler_replacement->contents->[0]->params->[0]{value},
    "warning handler failure\n",
    'a dying __WARN__ replaces the active fatal while inside __DIE__'
);
is( $die_hook_calls_for_warning_handler,
    1, 'a replacement from __WARN__ does not recursively call __DIE__' );

my ( @warning_hook_failure_codes, $warning_hook_failure_exception,
    $warning_hook_failure_die_arg );
{
    local $SIG{__EXCEPT__} = sub {
        push @warning_hook_failure_codes, $_[0]->contents->[0]->code;
    };
    local $SIG{__WARN__} = sub { die @_ };
    local $SIG{__DIE__}  = sub { $warning_hook_failure_die_arg = $_[0] };
    eval { warn "warning replaced by hook failure\n" };
    $warning_hook_failure_exception = $@;
}
is( join( ',', @warning_hook_failure_codes ),
    'WARNING_USER_TEXT',
    '__EXCEPT__ runs once before the warning hook replacement' );
is(
    $warning_hook_failure_exception->contents->[0]->params->[0]{value},
    "warning replaced by hook failure\n",
    'a dying __WARN__ turns its warning into a caught fatal exception'
);
is(
    $warning_hook_failure_die_arg,
    "warning replaced by hook failure\n",
    '__DIE__ receives the replacement from a dying __WARN__'
);

{
    my @caught_warning_values;
    my @caught_warning_exceptions;
    local $@ = "reused error\n";
    local $SIG{__EXCEPT__} = sub {
        push @caught_warning_exceptions, $_[0];
    };
    local $SIG{__WARN__} = sub {
        push @caught_warning_values, $_[0];
    };

    warn;
    warn "";

    is( scalar @caught_warning_values,
        2, 'each empty warning reusing $@ calls __WARN__ once' );
    like(
        $_,
        qr/^reused error\n\t\.\.\.caught at /,
        'the warning hook receives the reused error and catch context'
    ) for @caught_warning_values;
    is( $@, "reused error\n", 'warning delivery preserves the caught value' );

    for my $exception (@caught_warning_exceptions) {
        is( scalar @{ $exception->contents },
            1, 'a caught warning is one complete diagnostic' );
        is( $exception->contents->[0]->code,
            'WARNING_PROPAGATION_CAUGHT_EXCEPTION_REPORTED_AS_WARNING', 'the caught warning has its own catalog entry' );
        is(
            $exception->contents->[0]->params->[0]{value},
            "reused error\n",
            'the reused error is a diagnostic parameter'
        );
    }
}

my $die_object_hook_value;
my $die_object_hook_exception;
my $die_object_hook_arg_count;
{
    local $SIG{__EXCEPT__} = sub { $die_object_hook_exception = $_[0] };
    local $SIG{__DIE__}    = sub {
        $die_object_hook_arg_count = scalar @_;
        $die_object_hook_value     = shift;
    };
    eval { die $thrown_object };
}
is(
    overload::StrVal($die_object_hook_value),
    overload::StrVal($thrown_object),
    'the die hook receives the reference compatibility value'
);
is( ref($die_object_hook_exception),
    'XPerl::Exception',
    'the exception hook receives the structured exception' );
is( $die_object_hook_arg_count, 1,
    'the die hook keeps its historical one-argument signature' );

my $user_warning_hook =
  runperl(
    prog => 'local $SIG{__EXCEPT__} = sub { my $e = $_[0]; print join(q[|], '
      . 'ref($e), $e->contents->[0]->code), chr(10) }; '
      . 'local $SIG{__WARN__} = sub { print scalar @_, chr(10) }; '
      . 'warn q[hello]' );
is(
    $user_warning_hook,
    "XPerl::Exception|WARNING_USER_TEXT\n1\n",
    'the exception hook receives a user warning object'
);

my ( @promoted_warnings, @promoted_errors );
my $promoted_warning_exception;
{
    local $SIG{__EXCEPT__} = sub {
        $_[0]->contents->[0]{severity} = 'FATAL_ERROR';
    };
    local $SIG{__WARN__} = sub { push @promoted_warnings, $_[0] };
    local $SIG{__DIE__}  = sub { push @promoted_errors,   $_[0] };
    eval { warn "promoted warning\n" };
    $promoted_warning_exception = $@;
}
is( ref($promoted_warning_exception),
    'XPerl::Exception', 'an exception hook can promote a warning to an error' );
is( $promoted_warning_exception->severity,
    'FATAL_ERROR', 'a promoted warning remains an error' );
is( scalar @promoted_warnings,
    0, 'a warning promoted to an error skips the warning hook' );
is( scalar @promoted_errors,
    1, 'a warning promoted to an error reaches the die hook' );

my ( @downgraded_warnings, @downgraded_errors );
my $downgraded_error_exception;
{
    local $SIG{__EXCEPT__} = sub {
        $_[0]->contents->[0]{severity} = 'WARNING';
    };
    local $SIG{__WARN__} = sub { push @downgraded_warnings, $_[0] };
    local $SIG{__DIE__}  = sub { push @downgraded_errors,   $_[0] };
    eval { die "error stays fatal\n" };
    $downgraded_error_exception = $@;
}
is( $downgraded_error_exception->severity,
    'FATAL_ERROR', 'an exception hook cannot downgrade an error' );
is( scalar @downgraded_warnings,
    0, 'an error changed to warning is not sent to the warning hook' );
is( scalar @downgraded_errors,
    1, 'an error changed to warning still reaches the die hook' );

my $nested_hook_output = runperl(
    prog => q{
        my (@except, @warn);
        local $SIG{__EXCEPT__}= sub {
            push @except, $_[0]->contents->[0]->code;
            warn qq[nested warning\n];
        };
        local $SIG{__WARN__}= sub { push @warn, $_[0] };
        warn qq[outer warning\n];
        print scalar(@except), q[|], scalar(@warn), q[|], $warn[0];
    },
    stderr => 1
);
like(
    $nested_hook_output,
    qr/nested warning\n/,
    'a warning raised by the exception hook is emitted without recursion'
);
like(
    $nested_hook_output,
    qr/1\|1\|outer warning\n/,
    'only the original warning is delivered through the warning hook'
);

my ( @outer_exception_hooks, @inner_exception_hooks );
{
    local $SIG{__EXCEPT__} = sub {
        push @outer_exception_hooks, $_[0]->contents->[0]->params->[0]{value};
    };
    {
        local $SIG{__EXCEPT__} = sub {
            push @inner_exception_hooks,
              $_[0]->contents->[0]->params->[0]{value};
        };
        eval { die "inner localized exception hook\n" };
    }
    eval { die "restored outer exception hook\n" };
}
is(
    join( '|', @inner_exception_hooks ),
    "inner localized exception hook\n",
    'localized __EXCEPT__ uses the inner handler'
);
is(
    join( '|', @outer_exception_hooks ),
    "restored outer exception hook\n",
    'localized __EXCEPT__ restores the outer handler'
);

my $throwing_exception_hook_calls = 0;
my $throwing_exception_hook_error;
{
    local $SIG{__EXCEPT__} = sub {
        $throwing_exception_hook_calls++;
        die "exception hook failure\n";
    };
    eval { die "original exception\n" };
    $throwing_exception_hook_error = $@;
}
is( $throwing_exception_hook_calls,
    1, '__EXCEPT__ does not recursively invoke itself when it throws' );
is(
    $throwing_exception_hook_error->contents->[0]->params->[0]{value},
    "exception hook failure\n",
    'an exception thrown by __EXCEPT__ replaces the handled exception'
);

my $warning_hook_recursion = runperl(
    prog => 'my $calls= 0; local $SIG{__WARN__}= sub { ++$calls; '
      . 'print q{handled: }, $_[0]; warn q{nested warning}, chr(10) '
      . 'if $calls == 1 }; warn q{outer warning}, chr(10); '
      . 'print q{calls=}, $calls, chr(10)',
    stderr => 1
);
like(
    $warning_hook_recursion,
    qr/nested warning/,
    'a warning raised by __WARN__ reaches the default output path'
);
like(
    $warning_hook_recursion,
    qr/handled: outer warning/,
    '__WARN__ still receives the warning being handled'
);
unlike(
    $warning_hook_recursion,
    qr/handled: nested warning/,
    'a warning raised by __WARN__ does not recursively call the hook'
);
like( $warning_hook_recursion, qr/calls=1/,
    'the warning hook runs once when it raises another warning' );

my $die_hook_exception;
{
    local $SIG{__DIE__} = sub { die "die hook failure\n" };
    eval { die "original failure\n" };
    $die_hook_exception = $@;
}
is(
    $die_hook_exception->contents->[0]->params->[0]{value},
    "die hook failure\n",
    'an exception thrown by __DIE__ replaces the exception being handled'
);

my @runtime_warnings;
{
    local $SIG{__EXCEPT__} = sub { push @runtime_warnings, $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval "warn q[first];\nwarn q[second];\n";
}
is( scalar @runtime_warnings,
    2, 'separate runtime warnings create separate diagnostics' );
is(
    join( ',', map { $_->contents->[0]->location->{line} } @runtime_warnings ),
    '1,2',
    'each runtime warning keeps its own source line'
);
is(
    $runtime_warnings[0]->contents->[0]->location->{file},
    $runtime_warnings[1]->contents->[0]->location->{file},
    'runtime warnings from one eval keep their shared source file'
);

eval "my \$value = 1;\nqr/[a-/;\n";
is(
    $@->contents->[0]->code,
    'ERROR_REGEXP_CHAR_CLASS_UNTERMINATED',
    'an unmatched opening bracket has a specific diagnostic code'
);
is( $@->contents->[0]->location->{line},
    2, 'a regex diagnostic keeps the line containing its pattern' );

my @unmatched_open_paren_cases = (
    {
        pattern => '(',
        before  => '(',
        after   => '',
    },
    {
        pattern => '(abc',
        before  => '(',
        after   => 'abc',
    },
    {
        pattern => '(?[( [a] ])',
        before  => '(?[( [a] ',
        after   => '])',
    },
);

for my $case (@unmatched_open_paren_cases) {
    my ( $pattern, $before, $after ) = @{$case}{qw(pattern before after)};
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    my $params     = $diagnostic->params;
    is( $diagnostic->code, 'ERROR_REGEXP_GROUP_OPEN_PAREN_UNMATCHED',
        "regex pattern '$pattern' has a specific diagnostic code" );
    is( join( ',', map { $_->{name} } @$params ),
        'before,after',
        "regex pattern '$pattern' records its location parameters" );
    is(
        join( "\0", map { $_->{value} } @$params ),
        join( "\0", $before, $after ),
        "regex pattern '$pattern' keeps the source slices around the marker"
    );
}

my @unmatched_open_bracket_cases = (
    {
        pattern => '[abc',
        before  => '[',
        after   => 'abc',
    },
    {
        pattern => '[' . chr(92),
        before  => '[' . chr(92),
        after   => '',
    },
);

for my $case (@unmatched_open_bracket_cases) {
    my ( $pattern, $before, $after ) = @{$case}{qw(pattern before after)};
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    my $params     = $diagnostic->params;
    is(
        $diagnostic->code,
        'ERROR_REGEXP_CHAR_CLASS_UNTERMINATED',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    is( join( ',', map { $_->{name} } @$params ),
        'before,after',
        "regex pattern '$pattern' records its location parameters" );
    is(
        join( "\0", map { $_->{value} } @$params ),
        join( "\0", $before, $after ),
        "regex pattern '$pattern' keeps the source slices around the marker"
    );
}

my $unmatched_close_paren_pattern = ')';
eval { qr/$unmatched_close_paren_pattern/ };
my $unmatched_close_paren = $@->contents->[0];
is( $unmatched_close_paren->code,
    'ERROR_REGEXP_GROUP_CLOSE_PAREN_UNMATCHED',
    'an unmatched closing parenthesis has a specific code' );
is(
    join( '|', map { $_->{name} } @{ $unmatched_close_paren->params } ),
    'before|after',
    'the unmatched closing parenthesis records its pattern slices'
);
is( join( "\0", map { $_->{value} } @{ $unmatched_close_paren->params } ),
    ")\0", 'the closing parenthesis remains before the location marker' );

my @extended_charclass_failures = (
    {
        pattern => q{(?[(?^:a) ])},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_INTERPOLATED_SET_REQUIRED',
        message => 'Expecting interpolated extended charclass',
        params  => [ [ before => q{(?[(?^:a)} ], [ after => q{ ])} ], ],
    },
    {
        pattern => q{(?[\cK ( \t ) ])},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_OPEN_PAREN_UNEXPECTED',
        message => q{Unexpected '(' with no preceding operator},
        params  => [ [ before => q{(?[\cK (} ], [ after => q{ \t ) ])} ], ],
    },
    {
        pattern => q{(?[\cK + ) ])},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_CLOSE_PAREN_UNMATCHED',
        message => q{Unexpected ')'},
        params  => [ [ before => q{(?[\cK + )} ], [ after => q{ ])} ], ],
    },
    {
        pattern => q{(?[ + \t ])},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_BINARY_OPERATOR_UNEXPECTED',
        message => q{Unexpected binary operator '+' with no preceding operand},
        params  => [
            [ operator => '+' ],
            [ before   => q{(?[ +} ],
            [ after    => q{ \t ])} ],
        ],
    },
    {
        pattern => q{(?[a])},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_CHARACTER_UNEXPECTED',
        message => 'Unexpected character',
        params  => [ [ before => q{(?[a} ], [ after => q{])} ], ],
    },
    {
        pattern => q{(?[\cK \t ])},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_OPERATOR_MISSING',
        message => 'Operand with no preceding operator',
        params  => [ [ before => q{(?[\cK \t} ], [ after => q{ ])} ], ],
    },
    {
        pattern => q{(?[ [ \t ]},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_UNTERMINATED',
        message => 'Syntax error in (?[...])',
        params  => [ [ before => q{(?[ [ \t ]} ], [ after => '' ], ],
    },
    {
        pattern => q{(?[[[::]]])},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_CLOSE_BRACKET_UNEXPECTED',
        message => q{Unexpected ']' with no following ')' in (?[...},
        params  => [ [ before => q{(?[[[::]]} ], [ after => q{])} ], ],
    },
    {
        pattern => q{(?[\cK + ])},
        code    => 'ERROR_REGEXP_CHAR_CLASS_EXTENDED_EXPRESSION_INCOMPLETE',
        message => q{Incomplete expression within '(?[ ])'},
        params  => [ [ before => q{(?[\cK + } ], [ after => q{])} ], ],
    },
);

for my $case (@extended_charclass_failures) {
    eval { qr/$case->{pattern}/ };

    my $diagnostic      = $@->contents->[0];
    my $params          = $diagnostic->params;
    my @expected_params = @{ $case->{params} };

    is( $diagnostic->code, $case->{code},
        "regex pattern '$case->{pattern}' has a specific diagnostic code" );
    is(
        join( ',', map { $_->{name} } @$params ),
        join( ',', map { $_->[0] } @expected_params ),
        "regex pattern '$case->{pattern}' records its semantic parameters"
    );
    is(
        join( "\0", map { $_->{value} } @$params ),
        join( "\0", map { $_->[1] } @expected_params ),
        "regex pattern '$case->{pattern}' retains its marker slices"
    );

    my $rendered =
        $case->{message}
      . " in regex; marked by <-- HERE in m/"
      . $expected_params[-2][1]
      . " <-- HERE "
      . $expected_params[-1][1] . "/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$rendered\E at /,
        "regex pattern '$case->{pattern}' preserves its legacy message"
    );
}

my @regex_quantifier_failures = (
    {
        pattern => q{a{01}},
        code    => 'ERROR_REGEXP_QUANTIFIER_INTEGER_INVALID',
        message => 'Invalid quantifier in {,}',
        params  => [ [ before => q[a{01] ], [ after => q[}] ], ],
    },
    {
        pattern => q{a{999999999999999999}},
        code    => 'ERROR_REGEXP_LIMIT_QUANTIFIER_COUNT_EXCEEDED',
        message => 'Quantifier in {,} bigger than %{limit}',
        params  => [
            [ limit  => '__numeric__' ],
            [ before => q[a{999999999999999999] ],
            [ after  => q[}] ],
        ],
    },
    {
        pattern => q{a**},
        code    => 'ERROR_REGEXP_QUANTIFIER_NESTED',
        message => 'Nested quantifiers',
        params  => [ [ before => q{a**} ], [ after => q{} ], ],
    },
    {
        pattern => q{*a},
        code    => 'ERROR_REGEXP_QUANTIFIER_TARGET_MISSING',
        message => 'Quantifier follows nothing',
        params  => [ [ before => q{*} ], [ after => q{a} ], ],
    },
);

for my $case (@regex_quantifier_failures) {
    eval { qr/$case->{pattern}/ };

    my $diagnostic      = $@->contents->[0];
    my $params          = $diagnostic->params;
    my @expected_params = @{ $case->{params} };

    is( $diagnostic->code, $case->{code},
        "regex pattern '$case->{pattern}' has a specific diagnostic code" );
    is(
        join( ',', map { $_->{name} } @$params ),
        join( ',', map { $_->[0] } @expected_params ),
        "regex pattern '$case->{pattern}' records its parameters"
    );
    my @expected_values;
    for my $i ( 0 .. $#expected_params ) {
        my $expected_value = $expected_params[$i][1];
        if ( $expected_value eq '__numeric__' ) {
            is( $params->[$i]{type},
                'iv', 'the quantifier limit is recorded as an integer' );
            like( $params->[$i]{value},
                qr/\A\d+\z/, 'the quantifier limit remains numeric data' );
            push @expected_values, $params->[$i]{value};
        }
        else {
            push @expected_values, $expected_value;
        }
    }
    is(
        join( "\0", map { $_->{value} } @$params ),
        join( "\0", @expected_values ),
        "regex pattern '$case->{pattern}' retains its quantifier data"
    );

    my $message = $case->{message};
    if ( $message =~ /%\{limit\}/ ) {
        $message =~ s/%\{limit\}/$params->[0]{value}/;
    }

    my $rendered =
        $message
      . " in regex; marked by <-- HERE in m/"
      . $params->[-2]{value}
      . " <-- HERE "
      . $params->[-1]{value} . "/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$rendered\E at /,
        "regex pattern '$case->{pattern}' preserves its legacy message"
    );
}

my $nested_paren_diagnostic;
{
    local ${^RE_COMPILE_RECURSION_LIMIT} = 2;
    my $pattern = '((a))';
    eval { qr/$pattern/ };
    $nested_paren_diagnostic = $@->contents->[0];
}
is(
    $nested_paren_diagnostic->code,
    'ERROR_REGEXP_LIMIT_COMPILE_NESTING_EXCEEDED',
    'exceeding the regex nesting limit has a specific diagnostic code'
);
is(
    join( "\0", map { $_->{value} } @{ $nested_paren_diagnostic->params } ),
    "((\0a))",
    'the nesting limit diagnostic retains its pattern marker slices'
);
like(
    $nested_paren_diagnostic->render_as_legacy('en'),
qr/\AToo many nested open parens in regex; marked by <-- HERE in m\/\(\( <-- HERE a\)\)\/ at /,
    'the nesting limit diagnostic preserves its legacy message'
);

my @unterminated_verb_cases = (
    [ '(*FOO', 'named_verb', 'construct', 'Unterminated verb pattern' ],
    [
        '(*foo',     'generic_construct',
        'construct', "Unterminated '(*...' construct"
    ],
    [
        '(*FOO:bar', 'named_verb',
        'argument',  'Unterminated verb pattern argument'
    ],
    [
        '(*foo:bar', 'generic_construct',
        'argument',  "Unterminated '(*...' argument"
    ],
);

for my $case (@unterminated_verb_cases) {
    my ( $pattern, $verb_kind, $verb_part, $expected ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is(
        $diagnostic->code,
        'ERROR_REGEXP_VERB_CONSTRUCT_UNTERMINATED',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    ok( $diagnostic->selector_key,
        "regex pattern '$pattern' stores its verb syntax selector key" );
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E in regex; marked by <-- HERE in m\//,
        "regex pattern '$pattern' selects the matching message template"
    );
}

my @verb_opener_spacing_cases = (
    [ '( *FOO)', "In '(*VERB...)', the '(' and '*' must be adjacent" ],
    [ '( *foo)', "In '(*...)', the '(' and '*' must be adjacent" ],
);

for my $case (@verb_opener_spacing_cases) {
    my ( $pattern, $expected ) = @$case;
    eval { qr/$pattern/x };

    my $diagnostic = $@->contents->[0];
    is(
        $diagnostic->code,
        'ERROR_REGEXP_VERB_OPENER_NOT_ADJACENT',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    ok( $diagnostic->selector_key,
        "regex pattern '$pattern' stores its verb form selector key" );
    is(
        join( "\0", map { $_->{value} } grep { !$_->{selector_domain} } @{ $diagnostic->params } ),
        "( *\0" . substr( $pattern, 3 ),
        "regex pattern '$pattern' retains the marker source slices"
    );
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E in regex; marked by <-- HERE in m\//,
        "regex pattern '$pattern' selects the matching message template"
    );
}

my @verb_fail_cases = (
    {
        pattern => '(*sr)',
        code    => 'ERROR_REGEXP_VERB_COLON_MISSING',
        message => "'(*sr' requires a terminating ':'",
        params => [ [ verb => 'sr' ], [ before => '(*sr' ], [ after => ')' ], ],
    },
    {
        pattern  => '(*FOO)',
        code     => 'ERROR_REGEXP_VERB_NAME_UNKNOWN',
        selector => 'named_verb',
        message  => "Unknown verb pattern 'FOO'",
        params   =>
          [ [ verb => 'FOO' ], [ before => '(*FOO)' ], [ after => '' ], ],
    },
    {
        pattern  => '(*foo)',
        code     => 'ERROR_REGEXP_VERB_NAME_UNKNOWN',
        selector => 'generic_construct',
        message  => "Unknown '(*...)' construct 'foo'",
        params   =>
          [ [ verb => 'foo' ], [ before => '(*foo)' ], [ after => '' ], ],
    },
    {
        pattern => '(*MARK)',
        code    => 'ERROR_REGEXP_VERB_ARGUMENT_MISSING',
        message => "Verb pattern 'MARK' has a mandatory argument",
        params  =>
          [ [ verb => 'MARK' ], [ before => '(*MARK' ], [ after => ')' ], ],
    },
);

for my $case (@verb_fail_cases) {
    eval { qr/$case->{pattern}/ };

    my $diagnostic = $@->contents->[0];
    my $params     = $diagnostic->params;

    is( $diagnostic->code, $case->{code},
        "regex pattern '$case->{pattern}' has a specific diagnostic code" );

    if ( defined $case->{selector} ) {
        ok( $diagnostic->selector_key,
            "regex pattern '$case->{pattern}' stores its verb selector" );
    }

    my %expected_values = map { $_->[0] => $_->[1] } @{ $case->{params} };
    my $metadata = diagnostic_metadata($diagnostic);
    if ( defined $case->{selector} ) {
        my ($selector) = grep {
            grep { $_ eq $case->{selector} } @{ $_->{values} || [] }
        } @{ $metadata->{selectors} || [] };
        $expected_values{ $selector->{source} } =
          selector_native_id( $diagnostic, $selector->{source}, $case->{selector} );
    }
    is(
        join( "\0", map { $_->{value} } @$params ),
        join( "\0", map { $expected_values{ $_->{name} } }
              @{ $metadata->{parameters} || [] } ),
        "regex pattern '$case->{pattern}' retains its verb and marker data"
    );

    my $rendered =
        $case->{message}
      . ' in regex; marked by <-- HERE in m/'
      . $case->{params}[-2][1]
      . ' <-- HERE '
      . $case->{params}[-1][1] . '/';

    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$rendered\E at /,
        "regex pattern '$case->{pattern}' preserves its legacy message"
    );
}

my @wildcard_modifier_exception_cases = (
    [ '\\p{gc=:(?a)L:}',  'a' ],
    [ '\\p{nv=:(?g)10:}', 'g' ],
    [ '\\p{gc=:(?-m)L:}', '-m' ],
);

for my $case (@wildcard_modifier_exception_cases) {
    my ( $pattern, $modifier ) = @$case;
    {
        no warnings 'experimental::uniprop_wildcards';
        eval { qr/$pattern/ };
    }

    my $diagnostic = $@->contents->[0];
    my $params     = $diagnostic->params;

    is(
        $diagnostic->code,
        'ERROR_REGEXP_MODIFIER_PROPERTY_WILDCARD_FORBIDDEN',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    is( $params->[0]{name},
        'modifier',
        "regex pattern '$pattern' stores the semantic modifier parameter" );
    is( $params->[0]{value},
        $modifier, "regex pattern '$pattern' composes the displayed modifier" );
    like(
        $diagnostic->render_as_legacy('en'),
qr/\A\QUse of modifier '$modifier' is not allowed in Unicode property wildcard subpatterns\E in regex; marked by <-- HERE in m\//,
        "regex pattern '$pattern' preserves its legacy message and marker"
    );
}

my @regex_restricted_operation_cases = (
    [
        '\\p{nv=/a*/}',
        'ERROR_REGEXP_QUANTIFIER_UNBOUNDED_EMPTY_WILDCARD_FORBIDDEN',
"Use of quantifier '*' is not allowed in Unicode property wildcard subpatterns",
        'a*',
        '',
        1,
    ],
    [
        '\\p{nv=/\\G/}',
        'ERROR_REGEXP_ESCAPE_GLOBAL_POSITION_IN_WILDCARD_FORBIDDEN',
        "Use of '\\G' is not allowed in Unicode property wildcard subpatterns",
        '\\G',
        '\\G',
        '',
        1,
    ],
    [
        '\\p{gc=:\\pS:}',
        'ERROR_REGEXP_ESCAPE_PROPERTY_WILDCARD_NESTING_FORBIDDEN',
        "Use of '\\pS' is not allowed in Unicode property wildcard subpatterns",
        'p',
        'S',
        '\\pS',
        '',
        1,
    ],
    [
        '(?=a\\K)',
        'ERROR_REGEXP_GROUP_LOOKAROUND_MATCH_START_RESET_FORBIDDEN',
        '\\K not permitted in lookahead/lookbehind',
        '(?=a\\K', ')', undef,
    ],
    [
        '\\C',
        'ERROR_REGEXP_ESCAPE_C_ESCAPE_UNSUPPORTED',
        '\\C no longer supported',
        '\\', 'C', undef,
    ],
);

for my $case (@regex_restricted_operation_cases) {
    my ( $pattern, $code, $message, @expected_params ) = @$case;
    if ( pop @expected_params ) {
        no warnings 'experimental::uniprop_wildcards';
        eval { qr/$pattern/ };
    }
    else {
        eval { qr/$pattern/ };
    }

    my $diagnostic = $@->contents->[0];
    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } grep { !$_->{selector_domain} } @{ $diagnostic->params } ),
        join( "\0", @expected_params ),
        "regex pattern '$pattern' retains its marker source slices"
    );
    my ( $before, $after ) = @expected_params[ -2, -1 ];
    my $expected =
      "$message in regex; marked by <-- HERE in m/$before <-- HERE $after/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy wording"
    );
}

my @unrecognized_sequence_cases =
  ( [ '(?;x)', '?;' ], [ '(?PX<n>foo|bar|baz)', '?PX' ], [ '(??x)', '??x' ], );

for my $case (@unrecognized_sequence_cases) {
    my ( $pattern, $sequence ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    my $params     = $diagnostic->params;

    is(
        $diagnostic->code,
        'ERROR_REGEXP_GROUP_SEQUENCE_UNKNOWN',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    is( $params->[0]{name},
        'sequence',
        "regex pattern '$pattern' stores the sequence as one parameter" );
    is( $params->[0]{value},
        $sequence, "regex pattern '$pattern' retains the rejected sequence" );
    like(
        $diagnostic->render_as_legacy('en'),
qr/\A\QSequence ($sequence...) not recognized in regex; marked by <-- HERE in m/,
        "regex pattern '$pattern' preserves its legacy message and marker"
    );
}

my @unterminated_sequence_cases = ( [ '\\k', '\\k' ], [ '\\k<', '\\k<' ], );

for my $case (@unterminated_sequence_cases) {
    my ( $pattern, $sequence ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    my $params     = $diagnostic->params;

    is(
        $diagnostic->code,
        'ERROR_REGEXP_GROUP_BACKREFERENCE_DELIMITER_UNTERMINATED',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    is( $params->[0]{name},
        'sequence',
        "regex pattern '$pattern' records its unterminated sequence" );
    is( $params->[0]{value},
        $sequence, "regex pattern '$pattern' records the sequence bytes" );
    like(
        $diagnostic->render_as_legacy('en'),
qr/\A\QSequence $sequence... not terminated in regex; marked by <-- HERE in m/,
        "regex pattern '$pattern' preserves its legacy wording"
    );
}

my @unescaped_left_brace_cases = (
    [ '\\q{',   0, '\\q{', '' ],
    [ '\\w{',   1, '\\w{', '' ],
    [ ':{4,a}', 1, ':{',   '4,a}' ],
);

for my $case (@unescaped_left_brace_cases) {
    my ( $pattern, $strict, $before, $after ) = @$case;

    if ($strict) {
        no warnings 'experimental';
        use re 'strict';
        eval { qr/$pattern/ };
    }
    else {
        eval { qr/$pattern/ };
    }

    my $diagnostic = $@->contents->[0];
    my $params     = $diagnostic->params;

    is( $diagnostic->code, 'ERROR_REGEXP_ESCAPE_LITERAL_OPEN_BRACE_FORBIDDEN',
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } @$params ),
        join( "\0", $before, $after ),
        "regex pattern '$pattern' retains its location parameters"
    );
    like(
        $diagnostic->render_as_legacy('en'),
qr/\A\QUnescaped left brace in regex is illegal here in regex; marked by <-- HERE in m/,
        "regex pattern '$pattern' preserves its legacy wording"
    );
}

my @invalid_unicode_property_cases = (
    [ '\\p', 'ERROR_REGEXP_ESCAPE_PROPERTY_NAME_MISSING', 'p', '\\p', '', 'Empty \\p' ],
    [
        '\\P!',
        'ERROR_REGEXP_ESCAPE_PROPERTY_SHORT_NAME_INVALID',
        'P',
        '\\P!',
        '',
"Character following \\P must be '{' or a single-character Unicode property name"
    ],
);

for my $case (@invalid_unicode_property_cases) {
    my ( $pattern, $code, $escape, $before, $after, $message ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    my $params     = $diagnostic->params;

    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } @$params ),
        join( "\0", $escape, $before, $after ),
        "regex pattern '$pattern' retains the escape and location parameters"
    );
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$message\E in regex; marked by <-- HERE in m\//,
        "regex pattern '$pattern' preserves its legacy wording"
    );
}

my $qmark_opener_pattern = '( ?a)';
eval { qr/$qmark_opener_pattern/x };
my $qmark_opener_diagnostic = $@->contents->[0];
is(
    $qmark_opener_diagnostic->code,
    'ERROR_REGEXP_GROUP_QUESTION_OPENER_NOT_ADJACENT',
    'whitespace before a question-mark group opener has a specific code'
);
is(
    join( "\0", map { $_->{value} } @{ $qmark_opener_diagnostic->params } ),
    "( ?\0a)",
    'the question-mark group diagnostic retains its marker source slices'
);
like(
    $qmark_opener_diagnostic->render_as_legacy('en'),
qr/\AIn '\(\?\.\.\.\)', the '\(' and '\?' must be adjacent in regex; marked by <-- HERE in m\//,
    'the question-mark group diagnostic preserves its legacy message'
);

my @unterminated_p_named_cases = (
    [ '(?P<', 'Sequence (?P<... not terminated', '(?P<' ],
    [ '(?P>', 'Sequence (?P>... not terminated', '(?P>' ],
);

for my $case (@unterminated_p_named_cases) {
    my ( $pattern, $expected, $before ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is(
        $diagnostic->code,
        'ERROR_REGEXP_GROUP_NAME_P_PREFIX_UNTERMINATED',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    ok( $diagnostic->selector_key,
        "regex pattern '$pattern' stores its named-sequence selector key" );
    is( join( "\0", map { $_->{value} } grep { !$_->{selector_domain} } @{ $diagnostic->params } ),
        "$before\0",
        "regex pattern '$pattern' retains the marker source slices" );
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E in regex; marked by <-- HERE in m\//,
        "regex pattern '$pattern' selects the matching message template"
    );
}

for my $pattern ( '(?i', '(?a-x' ) {
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is(
        $diagnostic->code,
        'ERROR_REGEXP_MODIFIER_INLINE_UNTERMINATED',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    is( join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        "$pattern\0",
        "regex pattern '$pattern' retains its end-of-pattern marker" );
    my $expected =
"Sequence (?... not terminated in regex; marked by <-- HERE in m/$pattern <-- HERE /";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy message"
    );
}

my $unterminated_named_recursion_pattern = '(?&foo';
eval { qr/$unterminated_named_recursion_pattern/ };
my $unterminated_named_recursion = $@->contents->[0];
is(
    $unterminated_named_recursion->code,
    'ERROR_REGEXP_GROUP_SUBROUTINE_NAMED_CALL_UNTERMINATED',
    'an unterminated named recursion has a specific diagnostic code'
);
is(
    join(
        "\0", map { $_->{value} } @{ $unterminated_named_recursion->params }
    ),
    "(?&foo\0",
    'the named recursion diagnostic retains its end-of-pattern marker'
);
like(
    $unterminated_named_recursion->render_as_legacy('en'),
qr/\ASequence \(\?&\.\.\. not terminated in regex; marked by <-- HERE in m\//,
    'the named recursion diagnostic preserves its legacy message'
);

my @unterminated_named_group_cases =
  ( [ '(?<foo', '<', '(?<foo' ], [ q{(?'foo}, q{'}, q{(?'foo} ], );

for my $case (@unterminated_named_group_cases) {
    my ( $pattern, $opener, $before ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is(
        $diagnostic->code,
        'ERROR_REGEXP_GROUP_NAME_DELIMITER_UNTERMINATED',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        "$opener\0$before\0",
        "regex pattern '$pattern' records its opener and marker slices"
    );
    my $expected =
"Sequence (?${opener}... not terminated in regex; marked by <-- HERE in m/$before <-- HERE /";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy message"
    );
}

my @unterminated_named_condition_cases = (
    [ '(?(<foo)x|y)',  '<',  '(?(<foo',  ')x|y)' ],
    [ q{(?('foo)x|y)}, q{'}, q{(?('foo}, ')x|y)' ],
);

for my $case (@unterminated_named_condition_cases) {
    my ( $pattern, $opener, $before, $after ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is(
        $diagnostic->code,
        'ERROR_REGEXP_CONDITIONAL_NAME_UNTERMINATED',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        "$opener\0$before\0$after",
        "regex pattern '$pattern' records its opener and marker slices"
    );
    my $expected =
"Sequence (?(${opener}... not terminated in regex; marked by <-- HERE in m/$before <-- HERE $after/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy message"
    );
}

my @unterminated_lookaround_cases = (
    [ '(?=',  '?=',  '(?=' ],
    [ '(?!',  '?!',  '(?!' ],
    [ '(?<=', '?<=', '(?<=' ],
    [ '(?<!', '?<!', '(?<!' ],
);

for my $case (@unterminated_lookaround_cases) {
    my ( $pattern, $lookaround, $before ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is(
        $diagnostic->code,
        'ERROR_REGEXP_GROUP_LOOKAROUND_UNTERMINATED',
        "regex pattern '$pattern' has a specific diagnostic code"
    );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        "$lookaround\0$before\0",
        "regex pattern '$pattern' records its lookaround and marker slices"
    );
    my $expected =
"Sequence ($lookaround... not terminated in regex; marked by <-- HERE in m/$before <-- HERE /";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy message"
    );
}

my @named_group_regex_failures = (
    [
        '(?<1abc>x)', 'ERROR_REGEXP_GROUP_NAME_INITIAL_CHARACTER_INVALID',
        '(?<1',       'abc>x)'
    ],
    [ '\\k<foo>', 'ERROR_REGEXP_GROUP_NAME_TARGET_MISSING', '\\k<foo', '>' ],
);

for my $case (@named_group_regex_failures) {
    my ( $pattern, $code, $before, $after ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        join( "\0", $before, $after ),
        "regex pattern '$pattern' retains the marker source slices"
    );
}

my $noncontinuation       = chr(0x24B7);
my $bad_identifier_source = "my \$a${noncontinuation}b;";
eval $bad_identifier_source;
my $bad_identifier = $@->contents->[0];
is(
    $bad_identifier->code,
    'ERROR_SYNTAX_IDENTIFIER_CHARACTER_INVALID',
    'an invalid identifier character has a structured diagnostic'
);
my %bad_identifier_params =
  map { $_->{name} => $_->{value} } @{ $bad_identifier->params };
is( $bad_identifier_params{codepoint},
    '24B7', 'an invalid identifier records its code point' );
is( $bad_identifier_params{identifier_before},
    "a${noncontinuation}",
    'an invalid identifier records its prefix and offending character' );
is( $bad_identifier_params{identifier_after},
    'b', 'an invalid identifier records the remaining identifier text' );

my $bad_group_name = "(?<a${noncontinuation}b>x)";
eval { qr/$bad_group_name/ };
my $bad_group_name_diagnostic = $@->contents->[0];
is(
    $bad_group_name_diagnostic->code,
    'ERROR_REGEXP_GROUP_NAME_IDENTIFIER_INVALID',
    'an invalid regex group name retains its diagnostic identity'
);
my %bad_group_name_params =
  map { $_->{name} => $_->{value} } @{ $bad_group_name_diagnostic->params };
is( $bad_group_name_params{codepoint},
    '24B7', 'an invalid regex group name records its code point' );
is( $bad_group_name_params{identifier_before},
    "a${noncontinuation}",
    'an invalid regex group name records its prefix and bad character' );
is( $bad_group_name_params{identifier_after},
    'b', 'an invalid regex group name records the remaining identifier text' );
is( $bad_group_name_params{before},
    '(?<a',
    'an invalid regex group name retains the pattern location before it' );
is( $bad_group_name_params{after},
    "${noncontinuation}b>x)",
    'an invalid regex group name retains the pattern location after it' );

eval '$01';
is( $@->contents->[0]->code, 'ERROR_SYNTAX_IDENTIFIER_NUMERIC_NAME_LEADING_ZERO',
'a multi-digit numeric variable with a leading zero has a structured diagnostic'
);

my @numeric_group_reference_failures = (
    [
        '(?999999999999999999999999)', 'ERROR_REGEXP_GROUP_REFERENCE_NUMBER_INVALID',
        '(?999999999999999999999999',  ')'
    ],
    [ '(?-1)',  'ERROR_REGEXP_GROUP_REFERENCE_TARGET_MISSING', '(?-1)',  '' ],
    [ '(?2)',   'ERROR_REGEXP_GROUP_REFERENCE_TARGET_MISSING', '(?2)',   '' ],
    [ '(x)\\2', 'ERROR_REGEXP_GROUP_REFERENCE_TARGET_MISSING', '(x)\\2', '' ],
    [ '\\87',   'ERROR_REGEXP_GROUP_REFERENCE_TARGET_MISSING', '\\87',   '' ],
    [ '\\g{2}', 'ERROR_REGEXP_GROUP_REFERENCE_TARGET_MISSING', '\\g{2}', '' ],
);

for my $case (@numeric_group_reference_failures) {
    my ( $pattern, $code, $before, $after ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        join( "\0", $before, $after ),
        "regex pattern '$pattern' retains the exact marker slices"
    );
    my $summary =
      $code eq 'ERROR_REGEXP_GROUP_REFERENCE_NUMBER_INVALID'
      ? 'Invalid reference to group'
      : 'Reference to nonexistent group';
    my $expected =
      "$summary in regex; marked by <-- HERE in m/$before <-- HERE $after/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy message"
    );
}

my @backreference_parse_failures = (
    [
        '\\g', 'ERROR_REGEXP_GROUP_BACKREFERENCE_UNTERMINATED',
        '\\g', '', 'Unterminated \\g... pattern'
    ],
    [
        '\\g{1', 'ERROR_REGEXP_GROUP_BACKREFERENCE_BRACED_UNTERMINATED',
        '\\g{1', '', 'Unterminated \\g{...} pattern'
    ],
    [
        '\\g{1x}', 'ERROR_REGEXP_GROUP_BACKREFERENCE_DELIMITER_UNTERMINATED',
        '\\g{1',   'x}', 'Sequence \\g{... not terminated'
    ],
    [
        '\\g{0}', 'ERROR_REGEXP_GROUP_BACKREFERENCE_GROUP_ZERO_FORBIDDEN', '\\g{', '0}',
        'Reference to invalid group 0'
    ],
    [
        '\\g{-1}', 'ERROR_REGEXP_GROUP_BACKREFERENCE_RELATIVE_TARGET_UNAVAILABLE',
        '\\g{-',   '1}', 'Reference to nonexistent or unclosed group'
    ],
);

for my $case (@backreference_parse_failures) {
    my ( $pattern, $code, $before, $after, $summary ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    my @expected_params =
      $code eq 'ERROR_REGEXP_GROUP_BACKREFERENCE_DELIMITER_UNTERMINATED'
      ? ( '\\g{', $before, $after )
      : ( $before, $after );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        join( "\0", @expected_params ),
        "regex pattern '$pattern' retains its diagnostic parameters"
    );
    my $expected =
      "$summary in regex; marked by <-- HERE in m/$before <-- HERE $after/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy wording"
    );
}

my @named_character_escape_failures = (
    [
        '\\N {SPACE}', 'ERROR_REGEXP_ESCAPE_CHARACTER_NAME_BRACES_NOT_ADJACENT',
        '\\N',         ' {SPACE}', 'Missing braces on \\N{}',
        0,             1,
    ],
    [
        '\\N{_}', 'ERROR_REGEXP_ESCAPE_CHARACTER_NAME_EMPTY_SEQUENCE_FORBIDDEN', '\\N{_}', '',
        'Zero length \\N{}',
        1, 0,
    ],
    [
        '\\N{U+Z}', 'ERROR_REGEXP_ESCAPE_CHARACTER_NAME_HEX_SEQUENCE_INVALID',
        '\\N{U+Z',  '}', 'Invalid hexadecimal number in \\N{U+...}',
        0,          0,
    ],
    [
        '[\\N]', 'ERROR_REGEXP_CHAR_CLASS_N_ESCAPE_NAME_REQUIRED',
        '[\\N',  ']',
        '\\N in a character class must be a named character: \\N{...}',
        0, 0,
    ],
    [
        '[\\N{U+0061.0301}-z]',
        'ERROR_REGEXP_CHAR_CLASS_N_ESCAPE_NOT_SINGLE_CHARACTER',
        '[\\N{U+0061.0301',
        '}-z]',
        '\\N{} here is restricted to one character',
        1,
        0,
    ],
);

for my $case (@named_character_escape_failures) {
    my ( $pattern, $code, $before, $after, $summary, $strict, $extended ) =
      @$case;

    if ($strict) {
        no warnings 'experimental';
        use re 'strict';
        if ($extended) {
            eval { qr/$pattern/x };
        }
        else {
            eval { qr/$pattern/ };
        }
    }
    elsif ($extended) {
        eval { qr/$pattern/x };
    }
    else {
        eval { qr/$pattern/ };
    }

    my $diagnostic = $@->contents->[0];
    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        join( "\0", $before, $after ),
        "regex pattern '$pattern' retains its marker source slices"
    );
    my $expected =
      "$summary in regex; marked by <-- HERE in m/$before <-- HERE $after/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy wording"
    );
}

my @conditional_pattern_failures = (
    [
        '(?(1?)a|b)', 'ERROR_REGEXP_CONDITIONAL_TEST_SYNTAX_INVALID',
        '(?(1?', ')a|b)', 'Switch condition not recognized',
    ],
    [
        '(?(DEFINE)a|b)', 'ERROR_REGEXP_CONDITIONAL_DEFINE_ALTERNATION_FORBIDDEN',
        '(?(DEFINE)a|',   'b)', '(?(DEFINE)....) does not allow branches',
    ],
    [
        '(?(1)a|b|c)', 'ERROR_REGEXP_CONDITIONAL_BRANCH_COUNT_EXCEEDED',
        '(?(1)a|b|', 'c)', 'Switch (?(condition)... contains too many branches',
    ],
    [
        '(?(x)a|b)', 'ERROR_REGEXP_CONDITIONAL_TEST_UNKNOWN', '(?(x', ')a|b)',
        'Unknown switch condition (?(...))',
    ],
    [
        '(?(1)a', 'ERROR_REGEXP_CONDITIONAL_UNTERMINATED',
        '(?(1)a', '', 'Switch (?(condition)... not terminated',
    ],
    [
        '(?(2147483648)a|b)', 'ERROR_REGEXP_CONDITIONAL_TEST_SYNTAX_INVALID',
        '(?(',                '2147483648)a|b)',
        'Switch condition not recognized',
    ],
    [
        '(?(999999999999999999999999999999999999999999999999999999)a|b)',
        'ERROR_REGEXP_CONDITIONAL_TEST_SYNTAX_INVALID',
        '(?(',
        '999999999999999999999999999999999999999999999999999999)a|b)',
        'Switch condition not recognized',
    ],
    [
        '(?', 'ERROR_REGEXP_GROUP_CONSTRUCT_INCOMPLETE',
        '(?', '', 'Sequence (? incomplete',
    ],
);

for my $case (@conditional_pattern_failures) {
    my ( $pattern, $code, $before, $after, $summary ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        join( "\0", $before, $after ),
        "regex pattern '$pattern' retains its marker source slices"
    );
    my $expected =
      "$summary in regex; marked by <-- HERE in m/$before <-- HERE $after/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy wording"
    );
}

my @regex_modifier_failures = (
    [
        '(?aaa)', 'ERROR_REGEXP_MODIFIER_INLINE_ASCII_LIMIT_EXCEEDED', 'a',
        'Regexp modifier "a" may appear a maximum of twice',
        '(?aaa', ')',
    ],
    [
        '(?uu)', 'ERROR_REGEXP_MODIFIER_INLINE_REPEATED',
        'u',     'Regexp modifier "u" may not appear twice',
        '(?uu',  ')',
    ],
    [
        '(?ua)', 'ERROR_REGEXP_MODIFIER_INLINE_CHARSET_CONFLICT',
        'u',     'a', 'Regexp modifiers "u" and "a" are mutually exclusive',
        '(?ua',  ')',
    ],
    [
        '(?-u)', 'ERROR_REGEXP_MODIFIER_INLINE_NEGATION_FORBIDDEN',
        'u',     'Regexp modifier "u" may not appear after the "-"',
        '(?-u',  ')',
    ],
);

for my $case (@regex_modifier_failures) {
    my ( $pattern, $code, @expected_params ) = @$case;
    my $after   = pop @expected_params;
    my $before  = pop @expected_params;
    my $summary = pop @expected_params;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        join( "\0", @expected_params, $before, $after ),
        "regex pattern '$pattern' records modifier and marker parameters"
    );
    my $expected =
      "$summary in regex; marked by <-- HERE in m/$before <-- HERE $after/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy message"
    );
}

my @regex_braced_escape_failures = (
    [ '\\N{U+', 'ERROR_REGEXP_ESCAPE_CLOSE_BRACE_MISSING', 'N', '\\N{',  'U+' ],
    [ '\\b{g',  'ERROR_REGEXP_ESCAPE_CLOSE_BRACE_MISSING', 'b', '\\b{',  'g' ],
    [ '\\p{L',  'ERROR_REGEXP_ESCAPE_CLOSE_BRACE_MISSING', 'p', '\\p{',  'L' ],
    [ '\\b{}',  'ERROR_REGEXP_ESCAPE_BRACED_CONTENT_MISSING',           'b', '\\b{}', '' ],
    [ '\\p{}',  'ERROR_REGEXP_ESCAPE_BRACED_CONTENT_MISSING',           'p', '\\p{',  '}' ],
);

for my $case (@regex_braced_escape_failures) {
    my ( $pattern, $code, $escape, $before, $after ) = @$case;
    eval { qr/$pattern/ };

    my $diagnostic = $@->contents->[0];
    is( $diagnostic->code, $code,
        "regex pattern '$pattern' has a specific diagnostic code" );
    is(
        join( "\0", map { $_->{value} } @{ $diagnostic->params } ),
        join( "\0", $escape, $before, $after ),
        "regex pattern '$pattern' records the escape and marker slices"
    );
    my $escaped_name = '\\' . $escape . '{}';
    my $summary =
      $code eq 'ERROR_REGEXP_ESCAPE_BRACED_CONTENT_MISSING'
      ? "Empty $escaped_name"
      : "Missing right brace on $escaped_name";
    my $expected =
      "$summary in regex; marked by <-- HERE in m/$before <-- HERE $after/";
    like(
        $diagnostic->render_as_legacy('en'),
        qr/\A\Q$expected\E at /,
        "regex pattern '$pattern' preserves its legacy message"
    );
}

eval q{my $x = ;};
is( ref($@), 'XPerl::Exception', 'a compile failure carries an exception' );
ok(
    !scalar(
        grep {
            my $location = $_->location;
                 !defined $location->{file}
              || !length $location->{file}
              || !defined $location->{line}
              || $location->{line} < 1
        } @{ $@->contents }
    ),
    'each diagnostic in a compile exception records its source file and line'
);
is( $@->contents->[0]->code,
    'ERROR_SYNTAX_INVALID', 'a generated parser macro records its catalog code' );
is( $@->contents->[0]->number,
    1164, 'the parser diagnostic retains its catalog number' );
ok(
    !exists $@->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);
ok(
    !exists $@->contents->[0]->{text},
    'diagnostics do not store rendered text'
);
ok( utf8::is_utf8( $@->contents->[0]->text ),
    'an ASCII zero-argument template formats to a UTF-8 string' );
is( $@->contents->[0]->kind,
    'CORE_COMPILE', 'the parser diagnostic retains its catalog kind' );
ok(
    !exists $@->contents->[0]->location->{column},
    'compile diagnostics do not expose partial column data'
);
is( scalar @{ $@->contents->[0]->params },
    0, 'the cataloged syntax error has no redundant message parameter' );
is_diagnostic_text( $@->contents->[0],
    'syntax error', 'the diagnostic renders its catalog template' );
like(
    $@->render_as_modern('en'),
qr/#1164 FATAL_ERROR\.CORE_COMPILE\.ERROR_SYNTAX_INVALID \(eval \d+\):1\nSyntax error at \(eval \d+\) line 1, at EOF/,
    'modern exception rendering prefixes the diagnostic location'
);

eval 'package XPerlVersionError 01;';
my ($version_error) = grep { $_->code eq 'ERROR_SYNTAX_VERSION_INVALID_DECLARATION' } @{ $@->contents };
is( $version_error->code,
    'ERROR_SYNTAX_VERSION_INVALID_DECLARATION', 'a strict package version uses a structured diagnostic' );
is_captured_parameter_schema( $version_error,
    'the version diagnostic retains its declared selector source' );
ok( $version_error->selector_key,
'the version diagnostic stores its stable reason identifier as a selector key'
);
ok(
    !exists $version_error->{template},
    'diagnostics do not store catalog templates'
);

eval "use strict 'vars';\n\$xperl_compile_first;\n\$xperl_compile_second;\n";
my @compile_locations = map { $_->location } @{ $@->contents };
is( join( ',', map { $_->{line} } @compile_locations ),
    '2,3',
    'each accumulated parser diagnostic keeps the line where it was emitted' );
is(
    $compile_locations[0]{file},
    $compile_locations[1]{file},
    'accumulated parser diagnostics keep their shared source file'
);
like(
    $@->render('legacy'),
    qr/^Global symbol "\$xperl_compile_first" requires explicit package name/,
    'the exception retains the first accumulated diagnostic'
);
my $legacy_compile_error = $@->render('legacy');
like(
    $legacy_compile_error,
    qr/\$xperl_compile_first.* at \Q$compile_locations[0]{file}\E line 2\./s,
    'the first accumulated parser diagnostic renders its file and line'
);
like(
    $legacy_compile_error,
    qr/\$xperl_compile_second.* at \Q$compile_locations[1]{file}\E line 3\./s,
    'the second accumulated parser diagnostic renders its file and line'
);

eval q{use strict 'vars'; $xperl_first_independent_failure;};
my $first_compile_exception = $@;
eval q{package XPerlIndependentCompile 01;};
my $second_compile_exception = $@;
is(
    $first_compile_exception->contents->[0]->code,
    'ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME',
    'the first eval retains its own compile exception'
);
is( $second_compile_exception->contents->[0]->code,
    'ERROR_SYNTAX_VERSION_INVALID_DECLARATION', 'the next eval starts with its own compile diagnostics' );
ok(
    !scalar(
        grep { $_->code eq 'ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME' }
          @{ $second_compile_exception->contents }
    ),
    'a caught compile exception is not carried into the next eval'
);

eval q{for my a1b $i (1) {}};
is( $@->contents->[0]->code,
    'ERROR_SYNTAX_DECLARATION_VARIABLE_TYPE_PACKAGE_NOT_FOUND', 'unknown class names use their catalogued diagnostic' );
is( $@->contents->[0]->params->[0]{name},
    'name', 'the unknown class diagnostic names its parameter' );
is( $@->contents->[0]->params->[0]{value},
    'a1b', 'the unknown class diagnostic retains the class name' );
like(
    $@->contents->[0]->text,
    qr/^No such class a1b(?:\s|$)/,
    'the unknown class diagnostic preserves its text'
);

eval q{my $XPerl::name;};
is(
    $@->contents->[0]->code,
    'ERROR_SYNTAX_DECLARATION_LEXICAL_NAME_QUALIFIED',
    'lexical package names use a catalogued diagnostic'
);
my %lexical_package_params =
  map { $_->{name} => $_->{value} } @{ $@->contents->[0]->params };
is( join( ',', sort keys %lexical_package_params ),
    join( ',', sort map { $_->{name} } @{ diagnostic_metadata($@->contents->[0])->{parameters} } ),
    'lexical package diagnostics retain all declared parameter values' );
is( $lexical_package_params{name},
    '$XPerl::name',
    'lexical package diagnostics retain the full variable name' );
ok( $@->contents->[0]->selector_key,
    'lexical package diagnostics retain their selector key' );
is(
    index(
        $@->contents->[0]->text,
        '"my" variable $XPerl::name can\'t be in a package'
    ),
    0,
    'lexical package diagnostics preserve the English wording'
);

for my $case (
    [
        variable => q{our $Foo::bar;},
        '$Foo::bar',
        'No package name allowed for variable $Foo::bar in "our"',
"Aucun nom de paquet n'est autoris\N{U+E9} pour la variable \$Foo::bar dans \"our\""
    ],
    [
        subroutine => q{our sub Foo::bar;},
        '&Foo::bar',
        'No package name allowed for subroutine &Foo::bar in "our"',
"Aucun nom de paquet n'est autoris\N{U+E9} pour la sous-routine &Foo::bar dans \"our\""
    ],
  )
{
    my ( $kind, $source, $name, $expected_en, $expected_fr ) = @$case;
    eval $source;
    my $exception  = $@;
    my $diagnostic = $exception->contents->[0];

    is( $diagnostic->code,
        'ERROR_SYNTAX_DECLARATION_OUR_NAME_QUALIFIED', "qualified our $kind uses its diagnostic" );
    is_captured_parameter_schema( $diagnostic,
        "qualified our $kind retains its declared semantic parameter set" );
    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $params{name}, $name, "qualified our $kind retains its complete name" );
    ok( $diagnostic->selector_key,
        "qualified our $kind stores the semantic selector" );
    is_diagnostic_text( $diagnostic, $expected_en,
        "qualified our $kind selects the English template" );
    like(
        $exception->render_as_legacy('fr'),
        qr/^\Q$expected_fr\E(?: \N{U+E0} |$)/,
        "qualified our $kind selects the French template"
    );
}

my $structured_constant_overload = do {
    local $ENV{PERL_DIAG_RENDER} = 'Dumper';
    runperl(
        prog => q{
BEGIN {
    require XPerl::Exception;
    require XPerl::Diagnostic;
    require overload;
    my $exception = XPerl::Exception->_new();
    $exception->append(XPerl::Diagnostic->_new({
        code => q{INNER_CONSTANT_EXCEPTION},
        number => 1,
        kind => q{CORE_RUNTIME},
        severity => q{FATAL_ERROR},
        params => [],
        location => {},
    }));
    $exception->{error_count} = 1;
    overload::constant(q{integer}, sub { die $exception });
}
my $constant = 1;
},
        stderr => 1,
    );
};
like(
    $structured_constant_overload,
qr/"code" => "INNER_CONSTANT_EXCEPTION"[\s\S]*?"code" => "ERROR_PROPAGATION_EVAL_CONTEXT"/,
'constant overload propagation retains the structured diagnostic and context'
);
unlike(
    $structured_constant_overload,
    qr/"code" => "ERROR_PROPAGATION_EVAL_ERROR_TEXT"/,
    'structured constant overload errors are not flattened into text'
);

eval q{
    use overload;
    BEGIN { overload::constant integer => sub {} }
    1
};
is( $@->contents->[0]->code,
    'ERROR_OVERLOAD_CONSTANT_CONVERSION_FAILED',
    'undefined constant handlers use a catalogued diagnostic' );
my $undefined_handler_diagnostic = $@->contents->[0];
my @undefined_handler_records = @{ $undefined_handler_diagnostic->{params} };
my %undefined_handler_params =
  map { $_->{name} => $_->{value} } @undefined_handler_records;
is( $undefined_handler_params{constant},
    '1',
    'undefined constant handler diagnostics retain the constant spelling' );
is( $undefined_handler_params{overload_type},
    'integer',
    'undefined constant handler diagnostics retain the overload type' );
ok(
    exists $undefined_handler_params{reason}
      && $undefined_handler_diagnostic->selector_key,
    'the overload reason is retained with its compatibility selector key'
);
is(
    join( '|', map { $_->{name} . ':' . $_->{type} } @undefined_handler_records ),
    join( '|', map { $_->{name} . ':' . $_->{type} }
          @{ diagnostic_metadata($undefined_handler_diagnostic)->{parameters} } ),
    'overload capture retains every parameter name and declared type'
);
my ($undefined_reason) = grep { $_->{name} eq 'reason' }
  @undefined_handler_records;
my $native_reason = $undefined_reason->{value};
ok( $undefined_reason->{selector_domain},
    'the captured enum value retains its semantic domain' );
my $undefined_json = JSON::PP->new->decode(
    $undefined_handler_diagnostic->as_json );
my ($json_reason) = grep { $_->{name} eq 'reason' }
  @{ $undefined_json->{params} };
is( $json_reason->{selector_domain},
    'ERROR_OVERLOAD_CONSTANT_CONVERSION_FAILED.reason',
    'JSON derives a diagnostic-scoped enum locator from the current native ID' );
is( $json_reason->{value}, "$undefined_reason->{value}",
    'JSON preserves the native enum ID as its quoted decimal value' );
my $undefined_dump = eval $undefined_handler_diagnostic->render_as_dumper;
is( $@, '', 'Dumper output with enum metadata is valid Perl data' );
my ($dump_reason) = grep { $_->{name} eq 'reason' }
  @{ $undefined_dump->{params} };
is( $dump_reason->{selector_domain}, $json_reason->{selector_domain},
    'Dumper carries the same enum locator as JSON' );
my $text_reason = sprintf '%d', $undefined_reason->{value};
$undefined_reason->{value} = $text_reason;
my $edited_json = JSON::PP->new->decode(
    $undefined_handler_diagnostic->as_json );
my ($edited_reason) = grep { $_->{name} eq 'reason' }
  @{ $edited_json->{params} };
ok( !exists $edited_reason->{selector_domain},
    'JSON does not attach the old enum domain after the value becomes text' );
is( $edited_reason->{value}, $text_reason,
    'JSON serializes the edited current text value' );
$undefined_reason->{value} = $native_reason;
my $invalid_reason_id = 999999;
$undefined_reason->{value} = $invalid_reason_id;
my $invalid_id_json = JSON::PP->new->decode(
    $undefined_handler_diagnostic->as_json );
my ($invalid_id_reason) = grep { $_->{name} eq 'reason' }
  @{ $invalid_id_json->{params} };
is( $invalid_id_reason->{selector_domain},
    'ERROR_OVERLOAD_CONSTANT_CONVERSION_FAILED.reason',
    'JSON retains enum-domain metadata for an out-of-range native ID' );
is( $invalid_id_reason->{value}, "$invalid_reason_id",
    'JSON preserves an out-of-range native ID as a quoted decimal value' );
$undefined_reason->{value} = $native_reason;
is(
    index(
        $undefined_handler_diagnostic->text,
        'Constant(1): Call to &{$^H{integer}} did not return a defined value'
    ),
    0,
    'undefined constant handler errors preserve the English wording'
);

eval q{
    use overload;
    BEGIN { overload::constant integer => sub {}; undef *^H }
    1
};
is( $@->contents->[0]->code,
    'ERROR_OVERLOAD_CONSTANT_CONVERSION_FAILED',
    'constant overload failures use a catalogued diagnostic' );
my %missing_overload_params =
  map { $_->{name} => $_->{value} } @{ $@->contents->[0]->params };
is( $missing_overload_params{constant},
    '1', 'missing overload diagnostics retain the constant spelling' );
is( $missing_overload_params{overload_type},
    'integer', 'missing overload diagnostics retain the overload type' );
ok(
    exists $missing_overload_params{reason} && $@->contents->[0]->selector_key,
    'the missing overload reason is captured with its compatibility selector key'
);
is( index( $@->contents->[0]->text, 'Constant(1) unknown' ),
    0, 'constant overload diagnostics preserve the English wording' );

my $too_large_hex = 'F' x 40;
my $maximum_hex   = $Config{ivsize} > 4 ? '7FFFFFFFFFFFFFFF' : '7FFFFFFF';
eval qq{no warnings 'portable'; "\\N{U+$too_large_hex}"};
is( $@->contents->[0]->code,
    'ERROR_UNICODE_CODE_POINT_HEX_ESCAPE_OVERFLOW',
    'oversized code points use their catalogued diagnostic' );
is( $@->contents->[0]->params->[0]{value},
    $too_large_hex,
    'the code point diagnostic retains its hexadecimal digits' );
is( $@->contents->[0]->params->[1]{value},
    $maximum_hex, 'the code point diagnostic retains its maximum value' );
like(
    $@->contents->[0]->text,
qr/^Use of code point 0x\Q$too_large_hex\E is not allowed; the permissible max is 0x\Q$maximum_hex\E/,
    'the code point diagnostic preserves the assembled text'
);

my $runtime_too_large;
{
    no warnings 'portable';
    $runtime_too_large = hex($maximum_hex) + 1;
    eval { my $runtime_character = chr($runtime_too_large) };
}
is( $@->contents->[0]->code,
    'ERROR_UNICODE_CODE_POINT_ENCODING_LIMIT_EXCEEDED',
    'runtime code point conversion uses its catalogued diagnostic' );
is(
    $@->contents->[0]->params->[0]{value},
    sprintf( '%X', $runtime_too_large ),
    'the runtime code point diagnostic retains its hexadecimal digits'
);
is( $@->contents->[0]->params->[1]{value},
    $maximum_hex, 'the runtime diagnostic retains its permissible maximum' );
is_diagnostic_text(
    $@->contents->[0],
    "Use of code point 0x"
      . sprintf( '%X', $runtime_too_large )
      . " is not allowed; the permissible max is 0x$maximum_hex",
    'the runtime diagnostic preserves its legacy wording'
);

my $regex_too_large =
  $Config{ivsize} > 4
  ? '1_0000_0000_0000_0000'
  : '1_0000_0000';
eval qq{no warnings 'portable'; qr/\\N{U+$regex_too_large}/};
is( $@->contents->[0]->code,
    'ERROR_UNICODE_CODE_POINT_REGEXP_LIMIT_EXCEEDED',
    'oversized regex code points use their catalogued diagnostic' );
is( $@->contents->[0]->params->[0]{value},
    $regex_too_large, 'regex diagnostics preserve the input digits' );
is( $@->contents->[0]->params->[1]{value},
    $maximum_hex, 'regex diagnostics retain their permissible maximum' );
like(
    $@->contents->[0]->text,
qr/Use of code point 0x\Q$regex_too_large\E is not allowed; the permissible max is 0x\Q$maximum_hex\E in regex; marked by <-- HERE in m\/\\N\{U\+\Q$regex_too_large\E <-- HERE }\//,
    'regex code point errors preserve their marked pattern'
);

eval 'sub xperl_invalid_separator ($) : plugh + XYZZY ;';
is( $@->contents->[0]->code,
    'ERROR_SYNTAX_DECLARATION_ATTRIBUTE_LIST_SUFFIX_INVALID',
    'attribute list errors retain their catalog identity' );
my %attribute_list_params =
  map { $_->{name} => $_->{value} } @{ $@->contents->[0]->params };
is( $attribute_list_params{separator},
    '+', 'attribute list errors retain the offending separator character' );
ok(
    exists $attribute_list_params{reason} && $@->contents->[0]->selector_key,
    'the attribute-list reason is retained as a selector parameter'
);

eval q{use charnames qw(:full); "\N{DefinitelyNotAUnicodeName}"};
is( $@->contents->[0]->code,
    'ERROR_UNICODE_CHARACTER_NAME_UNKNOWN',
    'character name failures retain their catalog identity' );
is( $@->contents->[0]->params->[0]{name},
    'name', 'unknown character names have a named diagnostic parameter' );
is( $@->contents->[0]->params->[0]{value},
    'DefinitelyNotAUnicodeName', 'unknown character names retain their value' );
is_diagnostic_text(
    $@->contents->[0],
    "Unknown charname 'DefinitelyNotAUnicodeName'",
    'unknown character names retain their legacy message'
);
is( $@->contents->[0]->location->{parser_context},
    'within_string', 'string charname failures retain parser context' );
like(
    $@->contents->[0]->as_json,
    qr/"parser_context":"within_string"/,
    'diagnostic JSON retains parser context'
);
my $standalone_unknown_charname = $@->contents->[0];
ok(
    !defined $standalone_unknown_charname->context_follows_index,
    'standalone charname diagnostics have no context follow-up'
);
ok(
    !exists JSON::PP->new->decode( $standalone_unknown_charname->as_json )
      ->{context_follows_index},
    'diagnostic JSON omits an absent context relationship'
);
unlike(
    $standalone_unknown_charname->render_as_legacy('en'),
    qr/context unavailable/,
    'standalone charname rendering does not expect a context diagnostic'
);

my $light_charname = XPerl::Diagnostic->_new(
    {
        code                  => 'ERROR_UNICODE_CHARACTER_NAME_UNKNOWN',
        number                => 2503,
        kind                  => 'CORE_COMPILE',
        severity              => 'FATAL_ERROR',
        light                 => 1,
        context_follows_index => 1,
        params   => [ { name => 'name', type => 'text', value => 'BadName' } ],
        location => { file => 'test.pl', line => 4 }
    }
);
is( $light_charname->context_follows_index,
    1, 'light diagnostics can refer to their tail by exception index' );
is(
    JSON::PP->new->decode( $light_charname->as_json )->{context_follows_index},
    1,
    'diagnostic JSON records the exception-local tail index'
);
like(
    $light_charname->render_as_legacy('en'),
    qr/context unavailable/,
    'a linked diagnostic rendered outside its exception reports missing context'
);

my $charname_location = XPerl::Diagnostic->_new(
    {
        code     => 'ERROR_UNICODE_CHARACTER_NAME_FAILURE_AT_PATTERN',
        number   => 2508,
        kind     => 'CORE_COMPILE',
        severity => 'FATAL_ERROR',
        params   => [
            { name => 'before', type => 'text', value => 'prefix' },
            { name => 'after',  type => 'text', value => 'suffix' }
        ],
        location => { file => 'test.pl', line => 4 }
    }
);
my $contextual_charname = XPerl::Exception->_new();
$contextual_charname->append($light_charname);
$contextual_charname->append($charname_location);
my $contextual_charname_text = $contextual_charname->render_as_modern('en');
like(
    $contextual_charname_text,
    qr/^# FATAL_ERROR\.CORE_COMPILE\nUnknown charname 'BadName'/m,
    'modern rendering lets the location diagnostic own the group identity'
);
like(
    $contextual_charname_text,
    qr/^#2508 FATAL_ERROR\.CORE_COMPILE\.ERROR_UNICODE_CHARACTER_NAME_FAILURE_AT_PATTERN/m,
    'modern rendering retains the identity on the location diagnostic'
);

{

    package XPerlTest::RenderTruncateContext;
    use overload '""' => sub {
        my ($self) = @_;
        $self->{exception}{contents} = [ $self->{detail} ]
          unless $self->{did_truncate}++;
        return 'BadName';
      },
      fallback => 1;
}

my $truncating_context_value    = bless {}, 'XPerlTest::RenderTruncateContext';
my $truncating_light_diagnostic = XPerl::Diagnostic->_new(
    {
        code                  => 'ERROR_UNICODE_CHARACTER_NAME_UNKNOWN',
        number                => 2503,
        kind                  => 'CORE_COMPILE',
        severity              => 'FATAL_ERROR',
        light                 => 1,
        context_follows_index => 1,
        params                => [
            {
                name  => 'name',
                type  => 'text',
                value => $truncating_context_value
            }
        ],
        location => { file => 'test.pl', line => 4 }
    }
);
$truncating_context_value->{detail} = $truncating_light_diagnostic;
my $truncating_tail_diagnostic = XPerl::Diagnostic->_new(
    {
        code     => 'ERROR_UNICODE_CHARACTER_NAME_FAILURE_AT_PATTERN',
        number   => 2508,
        kind     => 'CORE_COMPILE',
        severity => 'FATAL_ERROR',
        params   => [
            { name => 'before', type => 'text', value => 'prefix' },
            { name => 'after',  type => 'text', value => 'suffix' }
        ],
        location => { file => 'test.pl', line => 4 }
    }
);
my $truncating_context_exception = XPerl::Exception->_new();
$truncating_context_value->{exception} = $truncating_context_exception;
$truncating_context_exception->append($truncating_light_diagnostic);
$truncating_context_exception->append($truncating_tail_diagnostic);
my $truncated_context_text =
  $truncating_context_exception->render_as_modern('en');
like(
    $truncated_context_text,
    qr/^#2503 FATAL_ERROR\.CORE_COMPILE\.ERROR_UNICODE_CHARACTER_NAME_UNKNOWN test\.pl:4/m,
    'modern rendering keeps light diagnostic identity if its tail is removed'
);
like(
    $truncated_context_text,
    qr/context unavailable/,
    'modern rendering reports that the removed tail context is unavailable'
);
$truncating_context_exception->{contents} =
  [ $truncating_light_diagnostic, $truncating_tail_diagnostic ];
$truncating_context_value->{did_truncate} = 0;
my $truncated_context_legacy =
  $truncating_context_exception->render_as_legacy('en');
like(
    $truncated_context_legacy,
    qr/context unavailable/,
    'legacy rendering reports a tail removed during stringification'
);

eval q{
    package XPerlExceptionCname { sub translator { pop } }
    BEGIN { $^H{charnames} = \&XPerlExceptionCname::translator }
    "\N{TOO  MANY SPACES}"
};
is( $@->contents->[0]->code,
    'ERROR_UNICODE_CHARACTER_NAME_REPEATED_SPACE',
    'custom charname validation failures retain their catalog identity' );
is( $@->contents->[0]->location->{parser_context},
    'within_string', 'custom charname failures retain parser context' );

eval q{qr/\N{DefinitelyNotAUnicodeName}/};
is(
    join( ',', map { $_->code } @{ $@->contents } ),
    'ERROR_UNICODE_CHARACTER_NAME_UNKNOWN,ERROR_COMPILATION_EXECUTION_ABORTED',
    'regex charname errors abort parsing after recording the diagnostic'
);
is( $@->contents->[-1]->params->[1]{value},
    1, 'compile-abort summary retains the exact parser error count' );
is( $@->contents->[0]->params->[0]{value},
    'DefinitelyNotAUnicodeName', 'regex charname errors retain the name' );
like(
    "$@",
    qr/Unknown charname 'DefinitelyNotAUnicodeName'.*within pattern/s,
    'regex charname errors retain their pattern context'
);

eval q{qr'\N{DefinitelyNotAUnicodeName}'};
is(
    join( ',', map { $_->code } @{ $@->contents } ),
    'ERROR_UNICODE_CHARACTER_NAME_FAILURE_AT_PATTERN',
    'regex compiler charname failures use the pattern-location root'
);
is( $@->contents->[0]->contents->[0]->code,
    'ERROR_UNICODE_CHARACTER_NAME_UNKNOWN', 'the pattern-location diagnostic owns the charname error' );
like(
    $@->render_as_legacy('en'),
    qr/^Unknown charname 'DefinitelyNotAUnicodeName'.*in regex/s,
    'legacy rendering retains the regex pattern context'
);
my $regex_charname_text = $@->render_as_modern('en');
like(
    $regex_charname_text,
    qr/^  #2503 FATAL_ERROR\.CORE_COMPILE\.ERROR_UNICODE_CHARACTER_NAME_UNKNOWN\n  Unknown charname/m,
    'modern rendering keeps the charname error under its context root'
);
like(
    $regex_charname_text,
    qr/^#2508 FATAL_ERROR\.CORE_COMPILE\.ERROR_UNICODE_CHARACTER_NAME_FAILURE_AT_PATTERN/m,
    'modern rendering gives the pattern-location diagnostic the group identity'
);

eval q{qr'\p{NoSuchPropertyNameForTest}'};
is( $@->contents->[0]->code,
    'ERROR_UNICODE_PROPERTY_CONTEXT_INVALID_DEFINITION_AT_PATTERN',
    'regex property failures use the pattern-location root' );
ok( $@->contents->[0]->contents_count,
    'the pattern-location root owns the property diagnostic' );
like( $@->render_as_legacy('en'), qr/NoSuchPropertyNameForTest.*in regex/s,
    'legacy rendering retains the regex property context' );

eval q!"\c{"!;
is( $@->contents->[0]->code,
    'ERROR_SYNTAX_ESCAPE_CONTROL_OPEN_BRACE_PRINTABLE_RESULT',
    'control escape errors retain their catalog identity' );
is( $@->contents->[0]->params->[0]{name},
    'control', 'control escape errors retain the control character argument' );
is( $@->contents->[0]->params->[0]{type},
    'char', 'control escape errors type the control character argument' );

eval q!qr/\c{/!;
is( $@->contents->[0]->code,
    'ERROR_REGEXP_ESCAPE_CONTROL_CHARACTER_INVALID',
    'regex control escape errors use their contextual diagnostic' );
is( scalar @{ $@->contents },
    1, 'regex control escape errors are reported only once' );
like(
    $@->contents->[0]->text,
    qr/marked by <-- HERE in m\//,
    'regex control escape errors retain the pattern marker'
);

eval q{
    no warnings 'experimental::builtin';
    use builtin qw(export_lexically);
    BEGIN {
        my @wrong_type;
        export_lexically '$expected_scalar' => \@wrong_type;
    }
};
is(
    $@->contents->[0]->code,
    'ERROR_LEXICAL_EXPORT_REFERENCE_TYPE_MISMATCH',
    'lexical export type mismatch keeps its diagnostic identity'
);
is( $@->contents->[0]->params->[0]{name},
    'reference_type', 'lexical export type is a semantic parameter' );
is( $@->contents->[0]->params->[0]{value},
    selector_native_id( $@->contents->[0], 'reference_type', 'SCALAR' ),
    'lexical export type retains the native reference-type ID' );
ok( $@->contents->[0]->selector_key,
    'lexical export type also selects the appropriate article' );
like(
    $@->render_as_legacy('en'),
    qr/^Expected a SCALAR reference in export_lexically/,
    'English lexical export wording uses the type parameter'
);
like(
    $@->render_as_legacy('fr'),
    qr/type SCALAR/,
    'French lexical export wording uses the type parameter'
);
ok(
    !exists $@->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);

eval q{use strict; $x = 1;};
is(
    $@->contents->[0]->code,
    'ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME',
    'strict variable errors have their own diagnostic identity'
);
ok(
    $@->contents->[0]->isa('XPerl::Diagnostic::Error::Strict::Vars'),
    'a strict-vars producer marks the shared diagnostic as Strict::Vars'
);
ok(
    !exists $@->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);
is( scalar @{ $@->contents->[0]->params },
    1, 'the variable name is recorded as one semantic argument' );
is( $@->contents->[0]->params->[0]{name},
    'var_name', 'the combined argument is named var_name' );
is( $@->contents->[0]->params->[0]{value},
    '$x', 'the combined argument contains the sigil and variable name' );
like(
    $@->render('legacy'),
    qr/^Global symbol "\$x" requires explicit package name /,
    'the strict variable error retains its previous wording'
);

my $not_imported_warning =
  runperl( prog => 'use strict; use warnings; '
      . 'local $SIG{__EXCEPT__} = sub { my $d = $_[0]->contents->[0]; '
      . 'print join(q[|], $d->code, $d->params->[0]{name}, '
      . '$d->params->[0]{value}), chr(10) '
      . 'if $d->code eq q[WARNING_MISC_VARIABLE_NOT_IMPORTED] }; '
      . 'local $SIG{__WARN__} = sub { }; '
      . 'eval q{ package XPerl::Exception::NotImportedTest; '
      . 'use strict q[vars]; { no strict; $xperl_test_name = 1; } '
      . '$xperl_test_name = 1; };' );
is(
    $not_imported_warning,
    "WARNING_MISC_VARIABLE_NOT_IMPORTED|var_name|\$xperl_test_name\n",
    'the unimported variable warning records its full name as one argument'
);

eval q{my $^A;};
is( $@->contents->[0]->code,
    'ERROR_SYNTAX_DECLARATION_SPECIAL_CONTROL_NAME_FORBIDDEN',
    'global control variables use their catalogued diagnostic' );
my $global_control_diagnostic = $@->contents->[0];
ok( $global_control_diagnostic->selector_key,
    'the declaration context is stored as a selector key' );
is(
    join( ',', map { $_->{name} } @{ $global_control_diagnostic->params } ),
    'var_name,context',
    'the context displayed in Italian is stored as a diagnostic parameter'
);
is( $global_control_diagnostic->params->[0]{name},
    'var_name', 'global control variables use one semantic name parameter' );
is( $global_control_diagnostic->params->[0]{value},
    '$^A', 'the semantic name includes its sigil and control spelling' );
is( $global_control_diagnostic->params->[1]{value},
    selector_native_id( $global_control_diagnostic, 'context', 'my' ),
    'the declaration context retains its native selector ID' );
like(
    $@->render_as_legacy('en'),
    qr/^Can't use global \$\^A in "my"/,
    'English rendering selects the declaration-context template'
);
like(
    $@->render_as_legacy('fr'),
    qr/^Impossible d'utiliser la variable globale \$\^A dans "my"/,
    'French rendering selects the declaration-context template'
);

eval q{qr/a/q};
is( ref($@), 'XPerl::Exception',
    'a parameterized parser failure carries an exception' );
is( $@->contents->[0]->code,
    'ERROR_REGEXP_MODIFIER_LITERAL_UNKNOWN',
    'the parameterized diagnostic has its catalog code' );
my $modifier_params = $@->contents->[0]->params;
is( scalar @$modifier_params,    1, 'the parser records one formatter input' );
is( $modifier_params->[0]{name}, 'modifier', 'the parameter keeps its name' );
is( $modifier_params->[0]{type}, 'text',     'the parameter keeps its type' );
is( $modifier_params->[0]{value},
    'q', 'the parser copies the formatter input value' );

eval q{qr/[a-/};
is(
    $@->contents->[0]->code,
    'ERROR_REGEXP_CHAR_CLASS_UNTERMINATED',
    'an unmatched bracket keeps its catalog code'
);
my $regex_params = $@->contents->[0]->params;
is( join( '|', map { $_->{name} } @$regex_params ),
    'before|after', 'the regex failure records its named pattern slices' );
is( $regex_params->[1]{value},
    'a-', 'the pattern slice is copied before unwinding' );
eval "qr/[\x{100}-/";
my $utf8_fragment = $@->contents->[0]->params->[1]{value};
is( $utf8_fragment, "\x{100}-", 'the UTF-8 fragment retains its value' );
ok( utf8::is_utf8($utf8_fragment),
    'the UTF-8 fragment retains its encoding flag' );

eval 'my $x = "\x{";';
is( ref($@), 'XPerl::Exception',
    'a backslash escape parser failure carries an exception' );
is(
    $@->contents->[0]->code,
    'ERROR_SYNTAX_ESCAPE_HEX_CLOSE_BRACE_MISSING',
    'the hex escape failure keeps its specific diagnostic code'
);

eval q!my $x = "\o{}";!;
is( ref($@), 'XPerl::Exception', 'an empty octal escape carries an exception' );
is( $@->contents->[0]->code,
    'ERROR_SYNTAX_ESCAPE_OCTAL_DIGITS_MISSING',
    'the octal escape failure keeps its specific diagnostic code' );

my $zero = 0;
eval { my $quotient = 1 / $zero };
is( ref($@), 'XPerl::Exception',
    'a catalogued runtime failure carries an exception' );
is( $@->kind, 'CORE_RUNTIME', 'the runtime exception keeps its kind' );
is( $@->contents->[0]->code,
    'ERROR_NUMERIC_DOMAIN_DIVISION_BY_ZERO', 'the runtime diagnostic keeps its catalog code' );
is( $@->contents->[0]->number,
    1001, 'the runtime diagnostic keeps its catalog number' );
ok(
    !exists $@->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);
like(
    $@->render('legacy'),
    qr/^Illegal division by zero at /,
    'the runtime exception retains its compatibility text'
);

my $log_zero = 0;
eval { my $unused = log($log_zero) };
my $log_domain_error = $@;
is( $log_domain_error->contents->[0]->code,
    'ERROR_NUMERIC_DOMAIN_LOG_SQRT_ARGUMENT_INVALID', 'log domain failure uses a catalog diagnostic' );
my %log_domain_params =
  map { $_->{name} => $_ } @{ $log_domain_error->contents->[0]->params };
is( $log_domain_params{operation}{value},
    selector_native_id( $log_domain_error->contents->[0], 'operation', 'log' ),
    'log domain failure retains the native operation ID' );
is( $log_domain_params{value}{type},
    'nv', 'log domain failure retains the numeric input type' );
is( $log_domain_params{value}{value},
    '0', 'log domain failure records the numeric input' );
like(
    $log_domain_error->render_as_legacy('en'),
    qr/^Can't take log of 0 at /,
    'log domain failure keeps its compatibility wording'
);

my $negative_sqrt = -1;
eval { my $unused = sqrt($negative_sqrt) };
my $sqrt_domain_error = $@;
is( $sqrt_domain_error->contents->[0]->code,
    'ERROR_NUMERIC_DOMAIN_LOG_SQRT_ARGUMENT_INVALID', 'sqrt domain failure uses a catalog diagnostic' );
my %sqrt_domain_params =
  map { $_->{name} => $_ } @{ $sqrt_domain_error->contents->[0]->params };
is( $sqrt_domain_params{operation}{value},
    selector_native_id( $sqrt_domain_error->contents->[0], 'operation', 'sqrt' ),
    'sqrt domain failure retains the native operation ID' );
is( $sqrt_domain_params{value}{value},
    '-1', 'sqrt domain failure records the negative input' );
isnt(
    $log_domain_error->contents->[0]->selector_key,
    $sqrt_domain_error->contents->[0]->selector_key,
    'log and sqrt domain failures select distinct templates'
);
like(
    $sqrt_domain_error->render_as_legacy('en'),
    qr/^Can't take sqrt of -1 at /,
    'sqrt domain failure keeps its compatibility wording'
);

eval { &CORE::length( 'a', 'b' ) };
is( ref($@), 'XPerl::Exception', 'a parameterized runtime failure carries an exception' );
is(
    $@->contents->[0]->code,
    'ERROR_CALL_BINDING_ARITY_INVALID_ARGUMENT_COUNT',
    'the parameterized runtime failure keeps its catalog code'
);
my $count_params = $@->contents->[0]->params;
is( join( '|', map { join( ':', @$_{qw(name type value)} ) } @$count_params ),
    'argument_count_relation:text:2|function:text:length',
    'the runtime diagnostic stores the callee and native relation selector' );
ok( !exists $@->contents->[0]->{template}, 'diagnostics do not store catalog templates' );
like(
    $@->render('legacy'),
    qr/^Too many arguments for length at /,
    'parameter capture preserves the rendered runtime message'
);

my $too_many_key = $@->contents->[0]->selector_key;
eval { &CORE::substr() };
is(
    $@->contents->[0]->code,
    'ERROR_CALL_BINDING_ARITY_INVALID_ARGUMENT_COUNT',
    'too few runtime arguments use the shared arity diagnostic'
);
isnt( $@->contents->[0]->selector_key, $too_many_key, 'runtime arity distinguishes shortage from excess' );
like(
    $@->render_as_legacy('en'),
    qr/^Not enough arguments for substr at /,
    'runtime shortage preserves English wording'
);

for my $language (qw(ru uk)) {
    unlike(
        $@->render_as_legacy($language),
        qr/Not enough|Too many/,
        "$language translates the argument-count relation"
    );
}

eval { kill 'NOT_A_SIGNAL', $$ };
is( ref($@), 'XPerl::Exception',
    'an SV formatted failure carries an exception' );
is( $@->contents->[0]->code,
    'ERROR_SYSTEM_SIGNAL_KILL_SIGNAL_NAME_UNKNOWN',
    'the SV formatted failure keeps its catalog code' );
my $signal_params = $@->contents->[0]->params;
is(
    join( '|', map { join( ':', @$_{qw(name type value)} ) } @$signal_params ),
    'arg1:text:NOT_A_SIGNAL',
    'the SV formatter contributes an owned parameter value'
);
like(
    $@->render('legacy'),
    qr/^Unrecognized signal name "NOT_A_SIGNAL" at /,
    'SV parameter capture preserves the rendered runtime message'
);

{
    use feature 'signatures';
    no warnings 'experimental::signatures';
    sub xperl_one_arg ($argument) { }
    eval { xperl_one_arg( 1, 2 ) };
    is( ref($@), 'XPerl::Exception',
        'a caller-context failure carries an exception' );
    is( $@->contents->[0]->code,
        'ERROR_CALL_BINDING_ARITY_SUBROUTINE_COUNT_MISMATCH',
        'caller-context delivery keeps its catalog identity' );
    like(
        "$@",
        qr/Too many arguments for subroutine/,
        'the two selector values select the too-many exact message'
    );

    eval { xperl_one_arg() };
    like(
        "$@",
        qr/Too few arguments for subroutine/,
        'the first selector value selects the too-few message'
    );

    sub xperl_optional_arg ( $required, $optional = undef ) { }
    eval { xperl_optional_arg() };
    like(
        "$@",
        qr/Too few arguments.*expected at least/,
        'the second selector value selects the minimum-bound message'
    );
    eval { xperl_optional_arg( 1, 2, 3 ) };
    like(
        "$@",
        qr/Too many arguments.*at most/,
        'the second selector value selects the maximum-bound message'
    );
}

eval {
    eval { die "rethrow me\n" };
    die;
};
my $rethrow = $@;
is( ref($rethrow), 'XPerl::Exception',
    'bare die preserves the structured exception' );
like(
    $rethrow->render('legacy'),
    qr/^rethrow me\n\t\.\.\.propagated at .* line \d+\.\n$/,
    'bare die appends the legacy propagation location'
);
is( $rethrow->contents->[0]->params->[0]{value},
    "rethrow me\n", 'propagation leaves the original diagnostic unchanged' );
my $propagation = $rethrow->contents->[-1];
is( $propagation->code, 'ERROR_PROPAGATION_RETHROW_CONTEXT',
    'bare die appends a rethrow-context diagnostic' );
ok( !exists $propagation->{template},
    'diagnostics do not store catalog templates' );
is(
    join( '|',
        map { join( ':', @$_{qw(name type)} ) } @{ $propagation->params } ),
    'file:text|line:uv',
    'the propagation diagnostic keeps the file and line as typed parameters'
);

my $aggregate_warning;
{
    use warnings 'syntax';
    local $SIG{__EXCEPT__} = sub { $aggregate_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval 'my @items; length(@items);';
}
is( $aggregate_warning->contents->[0]->code,
    'WARNING_SYNTAX_LENGTH_NAMED_AGGREGATE_COERCION',
    'length on an aggregate keeps its diagnostic identity' );
my %aggregate_params = map { $_->{name} => $_->{value} }
  @{ $aggregate_warning->contents->[0]->params };
ok(
    exists $aggregate_params{aggregate_kind}
      && $aggregate_warning->contents->[0]->selector_key,
    'length warnings retain the aggregate kind as a selector parameter'
);
ok(
    !exists $aggregate_warning->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);

my $escape_digit_warning;
{
    use warnings 'digit';
    local $SIG{__EXCEPT__} = sub { $escape_digit_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval q{ use warnings 'digit'; my $value = "\o{1238}"; };
}
is( $escape_digit_warning->contents->[0]->code,
    'WARNING_SYNTAX_DIGIT_ESCAPE_TERMINATED_EARLY',
    'an alien octal digit is reported as a structured warning' );
my %escape_digit_params = map { $_->{name} => $_->{value} }
  @{ $escape_digit_warning->contents->[0]->params };
ok(
    exists $escape_digit_params{radix}
      && $escape_digit_warning->contents->[0]->selector_key,
    'the alien digit warning retains the radix selector parameter'
);
is( $escape_digit_params{character},
    "'8'", 'the alien digit warning records the displayed character' );
is( $escape_digit_params{escape},
    '\\o', 'the alien digit warning records the escape form' );
is( $escape_digit_params{resolved},
    '\\o{123}', 'the alien digit warning records the resolved escape' );
ok(
    !exists $escape_digit_warning->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);

my $unbraced_escape_digit_warning;
{
    use warnings 'digit';
    local $SIG{__EXCEPT__} = sub { $unbraced_escape_digit_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval q{ use warnings 'digit'; my $value = "\178"; };
}
is( $unbraced_escape_digit_warning->contents->[0]->code,
    'WARNING_SYNTAX_DIGIT_ESCAPE_TERMINATED_EARLY',
    'an unbraced alien octal digit uses the structured escape warning' );
my %unbraced_escape_params = map { $_->{name} => $_->{value} }
  @{ $unbraced_escape_digit_warning->contents->[0]->params };
is( $unbraced_escape_params{character},
    "'8'", 'the unbraced warning keeps the offending character' );
is( $unbraced_escape_params{escape},
    '\\0', 'the unbraced warning records the escape form' );
is( $unbraced_escape_params{resolved},
    '\\0178', 'the unbraced warning records the resolved escape' );
is( $unbraced_escape_digit_warning->contents->[0]->location->{parser_context},
    'within_string', 'the unbraced warning retains its string context' );

my $shadowed_lexical_warning;
{
    local $SIG{__EXCEPT__} = sub { $shadowed_lexical_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval q{ use warnings 'shadow'; my $x; my $x; };
}
is( $shadowed_lexical_warning->contents->[0]->code,
    'WARNING_SHADOW_DECLARATION_MASKS_EARLIER_BINDING',
    'a shadowed lexical name uses its structured warning' );
my %shadowed_params = map { $_->{name} => $_->{value} }
  @{ $shadowed_lexical_warning->contents->[0]->params };
is( $shadowed_params{prior_name},
    '$x', 'the PNf formatter stores the lexical name' );
ok(
    utf8::is_utf8( $shadowed_params{prior_name} ),
    'the PNf formatter marks the lexical name as UTF-8'
);
ok(
    exists $shadowed_params{entity_kind}
      && exists $shadowed_params{declaration_extent}
      && $shadowed_lexical_warning->contents->[0]->selector_key,
'entity kind and declaration extent select the template without display params'
);
is_diagnostic_text(
    $shadowed_lexical_warning->contents->[0],
    '"my" variable $x masks earlier declaration in same scope',
    'the PNf formatter preserves the warning text'
);
like(
    $shadowed_lexical_warning->render_as_legacy('fr'),
qr/La d.*claration "my" de la variable \$x masque une d.*claration ant.*rieure dans la m.*me port.*e/,
    'the shadow warning selects its complete French template'
);

my $unavailable_lexical_warning;
{
    local $SIG{__EXCEPT__} = sub { $unavailable_lexical_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval q{
        use warnings 'closure';
        sub { my $x; sub f { $x } }->();
    };
}
my $unavailable_diagnostic = $unavailable_lexical_warning->contents->[0];
is( $unavailable_diagnostic->code,
    'WARNING_CLOSURE_LEXICAL_CAPTURE_UNAVAILABLE',
    'an unavailable lexical uses its structured warning' );
my %unavailable_params =
  map { $_->{name} => $_->{value} } @{ $unavailable_diagnostic->params };
is( $unavailable_params{name},
    '$x', 'the unavailable lexical name remains display data' );
ok(
    exists $unavailable_params{entity_kind}
      && $unavailable_diagnostic->selector_key,
    'the lexical kind stays available as semantic selector data'
);
is_diagnostic_text(
    $unavailable_diagnostic,
    'Variable "$x" is not available',
    'the unavailable variable keeps the legacy English wording'
);
like(
    $unavailable_lexical_warning->render_as_legacy('fr'),
    qr/Variable "\$x" n'est pas disponible/,
    'the unavailable variable selects its complete French template'
);

my $not_shared_lexical_warning;
{
    local $SIG{__EXCEPT__} = sub { $not_shared_lexical_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval q{
        use warnings 'closure';
        sub x { my $x; sub y { $x } }
    };
}
my $not_shared_diagnostic = $not_shared_lexical_warning->contents->[0];
is( $not_shared_diagnostic->code,
    'WARNING_CLOSURE_LEXICAL_CAPTURE_WILL_NOT_STAY_SHARED', 'an unshared lexical uses its structured warning' );
my %not_shared_params =
  map { $_->{name} => $_->{value} } @{ $not_shared_diagnostic->params };
is( $not_shared_params{lexical_name},
    '$x', 'the unshared lexical name remains composed display data' );
ok(
      exists $not_shared_params{entity_kind}
      && $not_shared_diagnostic->selector_key,
    'the lexical kind stays available as semantic selector data'
);
is_diagnostic_text(
    $not_shared_diagnostic,
    'Variable "$x" will not stay shared',
    'the unshared variable keeps the legacy English wording'
);
like(
    $not_shared_lexical_warning->render_as_legacy('fr'),
    qr/La variable "\$x" ne restera pas partag.*e/,
    'the unshared variable selects its complete French template'
);

sub capture_void_warning {
    my ($source) = @_;
    my $program = q{
        use XPerl::DiagPack qw(all);
        BEGIN {
            $SIG{__EXCEPT__} = sub {
                my $diagnostic = $_[0]->contents->[0];
                my $params = join q[,], map {
                    $_->{name} . q[=] . $_->{value}
                } @{ $diagnostic->params };
                print join q[|], $diagnostic->code,
                  defined($diagnostic->selector_key) ? 1 : 0,
                  $params,
                  $diagnostic->render_as_legacy(q[en]),
                  $diagnostic->render_as_legacy(q[fr]);
                print qq[\n];
            };
            $SIG{__WARN__} = sub { };
        }
        use warnings qw(void);
    };

    return runperl( prog => $program . $source );
}

for my $case (
    [
        variable => 'our $value; $value;',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'variable',
        'Useless use of a variable in void context',
        qr{^Utilisation inutile d'une variable en contexte void},
        0,
    ],
    [
        constant => '42;',
        'WARNING_VOID_USELESS_EXPRESSION_SV',
        'constant',
        'Useless use of a constant (42) in void context',
        qr{^Utilisation inutile d'une constante \(42\) en contexte void},
        1,
    ],
    [
        constant_undef => 'use constant U => undef; U;',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'constant_undef',
        'Useless use of a constant (undef) in void context',
        qr{^Utilisation inutile de la constante undef en contexte void},
        0,
    ],
    [
        anonymous_array => '[];',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'anonymous_array',
        'Useless use of an anonymous array ([]) in void context',
        qr{^Utilisation inutile d'un tableau anonyme \(\[\]\) en contexte void},
        0,
    ],
    [
        anonymous_hash => '+{};',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'anonymous_hash',
        'Useless use of an anonymous hash ({}) in void context',
        qr{^Utilisation inutile d'un hachage anonyme \(\{\}\) en contexte void},
        0,
    ],
    [
        negative_pattern_binding => '$_ !~ /x/;',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'negative_pattern_binding',
        'Useless use of a negative pattern binding (!~) in void context',
qr{^Utilisation inutile d'une liaison de motif n.gative \(!~\) en contexte void},
        0,
    ],
    [
        non_destructive_substitution => 's/x/y/r;',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'non_destructive_substitution',
        'Useless use of non-destructive substitution (s///r) in void context',
qr{^Utilisation inutile d'une substitution non destructive \(s///r\) en contexte void},
        0,
    ],
    [
        non_destructive_transliteration => 'tr/x/y/r;',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'non_destructive_transliteration',
'Useless use of non-destructive transliteration (tr///r) in void context',
qr{^Utilisation inutile d'une translitt.ration non destructive \(tr///r\) en contexte void},
        0,
    ],
    [
        op_description => 'time + 2;',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'add',
        'Useless use of addition (+) in void context',
        qr{^Utilisation inutile en contexte void : une addition \(\+\)},
        1,
    ],
    [
        literal_keyword => 'sort { $a <=> $b } (1,2);',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'sort',
        'Useless use of sort in void context',
        qr{^Utilisation inutile en contexte void : sort},
        1,
    ],
    [
        keyword_override => 'time;',
        'WARNING_VOID_USELESS_EXPRESSION_PV',
        'time',
        'Useless use of time in void context',
        qr{^Utilisation inutile de la fonction time en contexte void},
        1,
    ],
  )
{
    my ( $kind, $source, $expected_code, $expected_selector, $expected_en,
        $expected_fr, $has_detail )
      = @$case;
    my $output = capture_void_warning($source);
    chomp $output;
    my ( $code, $has_selector, $param_text, $english, $french ) =
      split /\|/, $output, 5;

    is( $code, $expected_code,
        "void-context $kind uses its structured diagnostic" );
    is( $has_selector, 1, "void-context $kind retains its selector key" );
    my %params = map { split /=/, $_, 2 } split /,/, $param_text;
    my $is_word = $expected_selector eq 'add' || $expected_selector eq 'sort';
    is( $params{op_name}, $is_word ? -1
        : selector_native_id_for_code( $expected_code, 'op_name', $expected_selector ),
        "void-context $kind retains only its semantic selecting value" );
    if ($is_word || $expected_selector eq 'time') {
        is( $params{operation_identity}, 1 + B::opnumber($expected_selector),
            "void-context $kind keeps numeric identity for its word" );
    }

    like( $english, qr/^\Q$expected_en\E/,
        "void-context $kind keeps its English wording" );
    like( $french, $expected_fr,
        "void-context $kind selects its complete French template" );

    is( defined( $params{arg1} ) && length( $params{arg1} ) ? 1 : 0,
        $has_detail, "void-context $kind stores only a real display detail" );
    ok( exists $params{op_name},
        "void-context $kind retains its selector as a parameter" );
    is( $params{arg1}, '42', 'the constant value remains diagnostic data' )
      if $kind eq 'constant';
    is( $params{arg1}, 'addition (+)',
        'the OP_DESC remains available as diagnostic data' )
      if $kind eq 'op_description';
    is( $params{arg1}, 'sort',
        'the literal keyword remains available as display data' )
      if $kind eq 'literal_keyword';
    is( $params{arg1}, 'time',
        'the overridden keyword remains available as display data' )
      if $kind eq 'keyword_override';
}

my $escape_warning_then_error;
{
    local $SIG{__EXCEPT__} = sub { $escape_warning_then_error = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval q{
        use warnings 'digit';
        my $value = "\o{1238}\o";
    };
}
is(
    join( '|', map { $_->code } @{ $escape_warning_then_error->contents } ),
    'WARNING_SYNTAX_DIGIT_ESCAPE_TERMINATED_EARLY|ERROR_SYNTAX_ESCAPE_OCTAL_BRACES_REQUIRED',
    'backslash diagnostics retain source order before a parser flush'
);

my $regex_escape_warning_text;
my $regex_escape_exception;
{
    use warnings 'digit';
    local $SIG{__WARN__} = sub { $regex_escape_warning_text .= $_[0] };
    eval q! qr/\o{123z}\c{/ !;
    $regex_escape_exception = $@;
}
is(
    join( '|', map { $_->code } @{ $regex_escape_exception->contents } ),
    'WARNING_SYNTAX_DIGIT_ESCAPE_TERMINATED_EARLY|ERROR_REGEXP_ESCAPE_CONTROL_CHARACTER_INVALID',
    'the regex exception retains warning and error diagnostics in order'
);
like(
    $regex_escape_warning_text,
    qr/Non-octal character .* terminates/,
    'the regex digit warning is delivered to the legacy warning hook'
);
my ($regex_escape_warning) = grep { $_->code eq 'WARNING_SYNTAX_DIGIT_ESCAPE_TERMINATED_EARLY' }
  @{ $regex_escape_exception->contents };
ok( $regex_escape_warning,
    'the regex exception retains the structured digit warning' );
my %regex_escape_warning_params =
  map { $_->{name} => $_->{value} } @{ $regex_escape_warning->params };
is( $regex_escape_warning_params{resolved},
    '\o{123}', 'the regex escape warning retains its resolved value' );
my %regex_escape_error_params = map { $_->{name} => $_->{value} }
  @{ $regex_escape_exception->contents->[1]->params };
is( $regex_escape_error_params{before},
    '\o{123z}\c{', 'the regex error retains its own pattern prefix' );
is( $regex_escape_error_params{after},
    '', 'the regex error retains its own pattern suffix' );

my @invalid_printf_warnings;
{
    use warnings 'printf';
    local $SIG{__EXCEPT__} = sub { push @invalid_printf_warnings, $_[0] };
    local $SIG{__WARN__}   = sub { };

    my $printf_output;
    open my $printf_fh, '>', \$printf_output or die $!;
    printf {$printf_fh} "%y";
    my $unused = sprintf "%";
    $unused = sprintf( "%+2L" . chr(3) );
}

is( scalar @invalid_printf_warnings,
    3, 'invalid printf formats raise three structured warnings' );
my @invalid_printf_diagnostics =
  map { $_->contents->[0] } @invalid_printf_warnings;
is(
    join( '|', map { $_->code } @invalid_printf_diagnostics ),
'WARNING_SYNTAX_PRINTF_CONVERSION_INVALID|WARNING_SYNTAX_PRINTF_CONVERSION_INVALID|WARNING_SYNTAX_PRINTF_CONVERSION_INVALID',
    'printf warnings keep their catalog identity'
);
my @invalid_printf_params = map {
    +{ map { $_->{name} => $_->{value} } @{ $_->params } }
} @invalid_printf_diagnostics;
is( $invalid_printf_params[0]{operation},
    'printf', 'printf records its operation name as a parameter' );
is( $invalid_printf_params[0]{conversion},
    '%y', 'printf records the malformed conversion as data' );
is( $invalid_printf_params[1]{operation},
    'sprintf', 'sprintf records its operation name as a parameter' );
is( $invalid_printf_params[1]{conversion},
    '', 'an incomplete format has no conversion text parameter' );
is( $invalid_printf_params[2]{conversion},
    '%+2L\\003',
    'nonprintable conversion bytes retain their escaped representation' );
ok(
    (
        grep { $_->{name} eq 'conversion_state' }
        @{ $invalid_printf_diagnostics[0]->params }
    ),
    'conversion state remains available as canonical selector data'
);
ok(
    $invalid_printf_diagnostics[0]->selector_key
      && $invalid_printf_diagnostics[1]->selector_key
      && $invalid_printf_diagnostics[0]->selector_key !=
      $invalid_printf_diagnostics[1]->selector_key,
    'conversion and end-of-format warnings use different selector keys'
);
like(
    $invalid_printf_warnings[0]->render_as_legacy('en'),
    qr/\AInvalid conversion in printf: "%y"/,
    'structured printf warning keeps its legacy rendering'
);
like(
    $invalid_printf_warnings[1]->render_as_legacy('en'),
    qr/\AInvalid conversion in sprintf: end of string/,
    'structured end-of-format warning keeps its legacy rendering'
);
{
    my $location            = $invalid_printf_warnings[2]->contents->[0]->location;
    my $expected            = $invalid_printf_warnings[2]->render_as_legacy('en');
    my $english_location    = " at $location->{file} line $location->{line}";
    my $portuguese_location = " em $location->{file}, linha $location->{line}";
    $expected =~ s/\AInvalid conversion in/Convers\x{e3}o inv\x{e1}lida em/;
    $expected =~ s/\Q$english_location\E/$portuguese_location/;
    is( $invalid_printf_warnings[2]->render_as_legacy('pt'),
        $expected, 'printf renders its Portuguese message and location' );
}

for my $regex_case (
    [ 'outside a character class', '\\178',   '\\178',  '' ],
    [ 'inside a character class',  '[\\178]', '[\\178', ']' ],
  )
{
    my ( $description, $pattern, $before, $after ) = @$regex_case;
    my ( $exception, $warning_text );
    {
        use warnings 'regexp';
        local $SIG{__EXCEPT__} = sub { $exception = $_[0] };
        local $SIG{__WARN__}   = sub { $warning_text .= $_[0] };
        eval "use warnings 'regexp'; qr/$pattern/";
    }

    my ($warning) = grep { $_->code eq 'WARNING_REGEXP_ESCAPE_DIGIT_OUTSIDE_RADIX' }
      @{ $exception->contents };
    ok( $warning, "$description records a structured octal warning" );

    my %params = map { $_->{name} => $_->{value} } @{ $warning->params };
    ok(
        exists $params{radix} && $warning->selector_key,
        "$description retains radix as a selector parameter"
    );
    is( $params{character}, "'8'", "$description records the offending digit" );
    is( $params{escape},    '\\0', "$description records the octal escape" );
    is( $params{resolved}, '\\0178',
        "$description records the resolved escape" );
    is( $warning->{pattern_context}{before},
        $before, "$description records the pattern prefix" );
    is( $warning->{pattern_context}{after},
        $after, "$description records the pattern suffix" );
    like(
        $warning_text,
qr/Non-octal character .* terminates .* Resolved as .* in regex; marked by <-- HERE/,
        "$description preserves the legacy warning and location"
    );
}

my $aggregate_hash_warning;
{
    use warnings 'syntax';
    local $SIG{__EXCEPT__} = sub { $aggregate_hash_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval 'my %items; length(%items);';
}
my %aggregate_hash_params = map { $_->{name} => $_->{value} }
  @{ $aggregate_hash_warning->contents->[0]->params };
ok( exists $aggregate_hash_params{aggregate_kind},
    'length records the aggregate kind' );
is( $aggregate_hash_params{aggregate_name},
    '%items', 'length records the displayed hash name' );
like(
    $aggregate_hash_warning->render_as_legacy('en'),
    qr/scalar\(keys %items\)/,
    'length selects the hash-specific explanation'
);
ok( !exists $aggregate_hash_warning->contents->[0]->{template},
    'diagnostics do not store catalog templates' );

my @missing_method_warnings;
{
    use warnings 'missing_import';
    local $SIG{__EXCEPT__} = sub { push @missing_method_warnings, $_[0] };
    local $SIG{__WARN__}   = sub { };
    Local::MissingImport->import('bar');
    Local::MissingImport->import( 'bar', 'guff' );
}
is( scalar @missing_method_warnings,
    2, 'missing import warnings cover complete and truncated argument lists' );
ok(
    $missing_method_warnings[0]->contents->[0]->selector_key,
    'a missing import warning stores its argument-list selector'
);
ok( !exists $missing_method_warnings[0]->contents->[0]->{template},
    'diagnostics do not store catalog templates' );
isnt(
    $missing_method_warnings[0]->contents->[0]->selector_key,
    $missing_method_warnings[1]->contents->[0]->selector_key,
    'complete and truncated argument lists use distinct selector keys'
);
ok( !exists $missing_method_warnings[1]->contents->[0]->{template},
    'diagnostics do not store catalog templates' );

SKIP: {
    skip 'requires a debugging build', 7
      unless $Config{ccflags} =~ /(?:^|\s)-DDEBUGGING(?:\s|$)/;
    skip 'requires XS::APItest', 6
      unless eval { require XS::APItest; 1 };

    my @shared_string_warnings;
    my @shared_string_warning_lines;
    {
        use warnings 'internal';
        local $SIG{__EXCEPT__} = sub { push @shared_string_warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        push @shared_string_warning_lines, __LINE__ + 1;
        XS::APItest::Hash::test_unsharepvn_nonexistent( 'bytes', 0 );
        push @shared_string_warning_lines, __LINE__ + 1;
        XS::APItest::Hash::test_unsharepvn_nonexistent( 'utf8', 1 );
    }
    is( scalar @shared_string_warnings,
        2, 'unsharing absent shared strings warns for byte and UTF-8 input' );
    ok(
        $shared_string_warnings[0]->contents->[0]->selector_key,
        'a byte string warning records its UTF-8 selector'
    );
    ok( !exists $shared_string_warnings[0]->contents->[0]->{template},
        'diagnostics do not store catalog templates' );
    isnt(
        $shared_string_warnings[0]->contents->[0]->selector_key,
        $shared_string_warnings[1]->contents->[0]->selector_key,
        'byte and UTF-8 warnings use distinct marker selectors'
    );
    ok( !exists $shared_string_warnings[1]->contents->[0]->{template},
        'diagnostics do not store catalog templates' );
    is(
        join( '|', map { $_->contents->[0]->code } @shared_string_warnings ),
'WARNING_SEVERE_INTERNAL_SHARED_STRING_FREE_NOT_FOUND|WARNING_SEVERE_INTERNAL_SHARED_STRING_FREE_NOT_FOUND',
        'both shared string warnings retain their diagnostic identity'
    );
    is(
        join( ',',
            map { $_->contents->[0]->location->{line} }
              @shared_string_warnings ),
        join( ',', @shared_string_warning_lines ),
        'warnings from an XS call record their Perl call-site lines'
    );
}

SKIP: {
    skip 'requires XS::APItest and Encode', 99
      unless eval { require XS::APItest; require Encode; 1 };

    my $utf8_sequence = chr 0x80;
    utf8::encode($utf8_sequence);
    substr( $utf8_sequence, 1, 1 ) = ' ';

    my @utf8_warnings;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub { push @utf8_warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        XS::APItest::utf8::bytes_cmp_utf8( 'a', $utf8_sequence );
    }

    is( scalar @utf8_warnings,
        1, 'a non-continuation byte emits one structured warning' );

    my $utf8_warning = $utf8_warnings[0];
    my %utf8_params  = map { $_->{name} => $_->{value} }
      @{ $utf8_warning->contents->[0]->params };
    is( $utf8_warning->contents->[0]->code,
        'WARNING_UTF8_TWO_BYTE_SEQUENCE_CONTINUATION_INVALID',
        'a non-continuation warning retains its diagnostic identity' );
    is(
        $utf8_params{bytes},
        sprintf( '\\x%02x\\x%02x',
            ord( substr( $utf8_sequence, 0, 1 ) ),
            ord( substr( $utf8_sequence, 1, 1 ) ) ),
        'the non-continuation warning stores escaped bytes as data'
    );
    is(
        $utf8_params{unexpected_byte},
        sprintf( '%02x', ord( substr( $utf8_sequence, 1, 1 ) ) ),
        'the non-continuation warning stores the unexpected byte as hex'
    );
    is(
        $utf8_params{start_byte},
        sprintf( '%02x', ord( substr( $utf8_sequence, 0, 1 ) ) ),
        'the non-continuation warning stores the start byte as hex'
    );

    my $expected_text = sprintf(
        'Malformed UTF-8 character: %s (unexpected non-continuation byte '
          . '0x%s, immediately after start byte 0x%s; need 2 bytes, got 1)',
        $utf8_params{bytes},
        $utf8_params{unexpected_byte},
        $utf8_params{start_byte}
    );

    is( $utf8_warning->contents->[0]->selector_key,
        2,
        'a non-continuation warning retains only the operation-context selector' );
    if ( ( $utf8_warning->contents->[0]->selector_key & 0xff ) == 2 ) {
        $expected_text .= ' in ' . $utf8_params{operation};
    }
    ok(
        !exists $utf8_warning->contents->[0]->{template},
        'diagnostics do not store catalog templates'
    );
    is_diagnostic_text( $utf8_warning->contents->[0],
        $expected_text,
        'the non-continuation warning preserves its English text' );
    like(
        $utf8_warning->contents->[0]->render_as_legacy('fr'),
        qr/UTF-8 mal form.*dans une entr.*e de sous-programme/,
        'the French entersub template contains the complete malformed message'
    );

    my $malformed_utf8_warning;
    my $malformed_utf8_warning_line;
    {
        local $SIG{__EXCEPT__} = sub { $malformed_utf8_warning = $_[0] };
        local $SIG{__WARN__}   = sub { };
        my $malformed_utf8 = "\xC2";
        Encode::_utf8_on($malformed_utf8);
        $malformed_utf8_warning_line = __LINE__ + 1;
        XS::APItest::test_utf8_length( $malformed_utf8, 0, 1 );
    }

    my $malformed_utf8_diagnostic = $malformed_utf8_warning->contents->[0];
    is( $malformed_utf8_diagnostic->code,
        'WARNING_UTF8_TRUNCATED_SEQUENCE_IN_OPERATION',
        'an incomplete UTF-8 sequence keeps its operation warning identity' );
    ok( !defined $malformed_utf8_diagnostic->selector_key,
        'an incomplete UTF-8 warning keeps word identity outside the selector key' );
    is(
        join( '|',
            map { $_->{name} . ':' . $_->{value} }
              @{ $malformed_utf8_diagnostic->params } ),
        'operation_identity:' . (1 + B::opnumber('entersub')) . '|operation:subroutine entry',
        'the incomplete UTF-8 warning stores display and identity separately'
    );
    is( join( ',', @{ $malformed_utf8_diagnostic->warning_categories } ),
        'WARN_UTF8', 'the incomplete UTF-8 warning keeps its category' );
    is_diagnostic_text(
        $malformed_utf8_diagnostic,
'Malformed UTF-8 character (unexpected end of string) in subroutine entry',
        'the operation template contains the complete malformed UTF-8 message'
    );
    like(
        $malformed_utf8_diagnostic->render_as_legacy('fr'),
        qr/UTF-8 mal form.*dans une entr.*e de sous-programme/,
        'the French entersub template contains the complete malformed UTF-8 message'
    );
    is( $malformed_utf8_diagnostic->location->{line},
        $malformed_utf8_warning_line,
        'the incomplete UTF-8 warning retains its Perl call-site line' );

    my @short_sequence_warnings;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub {
            push @short_sequence_warnings, $_[0];
        };
        local $SIG{__WARN__} = sub { };
        XS::APItest::utf8::test_utf8n_to_uvchr_error( "\xF3", 1, 0 );
    }

    is( scalar @short_sequence_warnings,
        1, 'a short UTF-8 sequence emits one structured warning' );
    my $short_sequence_diagnostic = $short_sequence_warnings[0]->contents->[0];
    my %short_sequence_params =
      map { $_->{name} => $_->{value} } @{ $short_sequence_diagnostic->params };
    is( $short_sequence_diagnostic->code,
        'WARNING_UTF8_SEQUENCE_TOO_SHORT',
        'a short-sequence warning retains its diagnostic identity' );
    is( $short_sequence_params{bytes},
        '\\xf3', 'a short-sequence warning stores its byte dump as data' );
    is( $short_sequence_params{available_bytes},
        1, 'a short-sequence warning records available bytes' );
    is( $short_sequence_params{expected_bytes},
        4, 'a short-sequence warning records required bytes' );
    is(
        $short_sequence_params{operation},
        'subroutine entry',
        'a short-sequence warning records its operation description'
    );
    is( $short_sequence_params{operation_identity},
        1 + B::opnumber('entersub'), 'a short-sequence warning retains numeric operation identity' );
    ok(
        $short_sequence_diagnostic->selector_key,
        'a short-sequence warning records selector state'
    );
    is( join( ',', @{ $short_sequence_diagnostic->warning_categories } ),
        'WARN_UTF8', 'a short-sequence warning keeps its warning category' );
    like(
        $short_sequence_warnings[0]->render_as_legacy('en'),
        qr/Malformed UTF-8 character: .*too short; 1 byte available, need 4/,
        'a short-sequence warning renders its structured byte counts'
    );
    like(
        $short_sequence_diagnostic->render_as_legacy('fr'),
        qr/Caract\N{U+00E8}re UTF-8 mal form\N{U+00E9} : .*1 octet disponible, il en faut 4.*dans une entr\N{U+00E9}e de sous-programme/,
        'French uses the exact entersub template without an English description'
    );

    my @two_byte_warnings;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub { push @two_byte_warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        XS::APItest::utf8::test_utf8n_to_uvchr_error( "\xF3\xA0", 2, 0 );
    }
    my $two_byte_diagnostic = $two_byte_warnings[0]->contents->[0];
    my %two_byte_params =
      map { $_->{name} => $_->{value} } @{ $two_byte_diagnostic->params };
    is( $two_byte_params{available_bytes}, 2,
        'a two-byte short sequence retains its source count' );
    like( $two_byte_diagnostic->render_as_legacy('en'),
        qr/2 bytes available, need 4/,
        'English uses the plural case for two available bytes' );
    like( $two_byte_diagnostic->render_as_legacy('fr'),
        qr/2 octets disponibles, il en faut 4/,
        'French resolves its own plural rule for two available bytes' );

    my @continuation_warnings;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub { push @continuation_warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        XS::APItest::utf8::test_utf8n_to_uvchr_error( "\x80", 1, 0 );
    }

    is( scalar @continuation_warnings,
        1, 'an unexpected continuation emits one structured warning' );
    my $continuation_diagnostic = $continuation_warnings[0]->contents->[0];
    my %continuation_params =
      map { $_->{name} => $_->{value} } @{ $continuation_diagnostic->params };
    is(
        $continuation_diagnostic->code,
        'WARNING_UTF8_CONTINUATION_WITHOUT_START',
        'an unexpected continuation retains its diagnostic identity'
    );
    is( $continuation_params{bytes},
        '\\x80', 'an unexpected continuation stores its escaped byte as data' );
    is( $continuation_params{byte},
        '80', 'an unexpected continuation stores the byte value as hex' );
    is(
        $continuation_params{operation},
        'subroutine entry',
        'an unexpected continuation stores its operation description'
    );
    ok( $continuation_diagnostic->selector_key,
        'an unexpected continuation records selector state' );
    is( join( ',', @{ $continuation_diagnostic->warning_categories } ),
        'WARN_UTF8', 'an unexpected continuation keeps its warning category' );
    like(
        $continuation_warnings[0]->render_as_legacy('en'),
qr/Malformed UTF-8 character: .*unexpected continuation byte 0x80, with no preceding start byte/,
        'an unexpected continuation renders the complete warning'
    );

    my @immediate_non_continuation_warnings;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub {
            push @immediate_non_continuation_warnings, $_[0];
        };
        local $SIG{__WARN__} = sub { };
        XS::APItest::utf8::test_utf8n_to_uvchr_error(
            pack( 'C*', 0xE2, 0x41, 0x42 ),
            3, 0 );
    }

    my $immediate_non_continuation_diagnostic =
      $immediate_non_continuation_warnings[0]->contents->[0];
    my %immediate_non_continuation_params =
      map { $_->{name} => $_->{value} }
      @{ $immediate_non_continuation_diagnostic->params };
    is( $immediate_non_continuation_params{available_bytes},
        1, 'an immediate non-continuation retains the one-byte valid prefix' );
    like(
        $immediate_non_continuation_warnings[0]->render_as_legacy('en'),
        qr/immediately after start byte 0xe2; required sequence length 3 bytes; valid prefix length 1/,
        'an immediate non-continuation uses neutral length labels'
    );

    my @non_continuation_warnings;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub {
            push @non_continuation_warnings, $_[0];
        };
        local $SIG{__WARN__} = sub { };
        XS::APItest::utf8::test_utf8n_to_uvchr_error(
            pack( 'C*', 0xE2, 0x82, 0x41 ),
            3, 0 );
    }

    is( scalar @non_continuation_warnings,
        1, 'a later non-continuation emits one structured warning' );
    my $non_continuation_diagnostic =
      $non_continuation_warnings[0]->contents->[0];
    my %non_continuation_params =
      map { $_->{name} => $_->{value} }
      @{ $non_continuation_diagnostic->params };
    is(
        $non_continuation_diagnostic->code,
        'WARNING_UTF8_SEQUENCE_CONTINUATION_INVALID',
        'a later non-continuation keeps its diagnostic identity'
    );
    is( $non_continuation_params{bytes},
        '\\xe2\\x82\\x41',
        'a later non-continuation stores the bounded byte dump' );
    is( $non_continuation_params{unexpected_byte},
        '41', 'a later non-continuation stores the invalid byte value' );
    is( $non_continuation_params{start_byte},
        'e2', 'a later non-continuation stores the sequence start byte' );
    is( $non_continuation_params{expected_bytes},
        3, 'a later non-continuation records the required sequence length' );
    is( $non_continuation_params{available_bytes},
        2, 'a later non-continuation records the valid prefix length' );
    is(
        $non_continuation_params{operation},
        'subroutine entry',
        'a later non-continuation records its operation description'
    );
    ok(
        $non_continuation_diagnostic->selector_key,
        'a later non-continuation records selector state'
    );
    is( join( ',', @{ $non_continuation_diagnostic->warning_categories } ),
        'WARN_UTF8', 'a later non-continuation keeps its warning category' );
    like(
        $non_continuation_warnings[0]->render_as_legacy('en'),
qr/unexpected non-continuation byte 0x41; after a valid prefix of length 2 starting with byte 0xe2; required sequence length 3 bytes; valid prefix length 2/,
        'a later non-continuation renders its sequence position and lengths'
    );
    like(
        $non_continuation_warnings[0]->render_as_legacy('es'),
        qr/ en una entrada de subprograma/,
        'a later non-continuation keeps the Spanish operation connector'
    );
    like(
        $non_continuation_warnings[0]->render_as_legacy('fr'),
        qr/ dans une entr.*e de sous-programme/,
        'a later non-continuation keeps the French operation connector'
    );
    like(
        $non_continuation_warnings[0]->render_as_legacy('pt'),
        qr/ em uma entrada de subprograma/,
        'a later non-continuation keeps the Portuguese operation connector'
    );

    require './charset_tools.pl';

    my $is_ascii = ord('A') == 65;
    my $overlong_bytes =
      main::I8_to_native( $is_ascii ? "\xc0\x80" : "\xc0\xa0" );
    my @overlong_warnings;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub { push @overlong_warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        XS::APItest::utf8::test_utf8n_to_uvchr_error( $overlong_bytes,
            length($overlong_bytes), 0 );
    }

    is( scalar @overlong_warnings,
        1, 'a decodable overlong sequence emits one structured warning' );
    my $overlong_diagnostic = $overlong_warnings[0]->contents->[0];
    my %overlong_params =
      map { $_->{name} => $_->{value} } @{ $overlong_diagnostic->params };
    is(
        $overlong_diagnostic->code,
        'WARNING_UTF8_OVERLONG_VALUE',
        'a decodable overlong sequence keeps its diagnostic identity'
    );
    is(
        $overlong_params{operation},
        'subroutine entry',
        'a decodable overlong records its operation'
    );
    is( $overlong_params{bytes}, '\xc0\x80',
        'a decodable overlong stores its original bytes' )
      if $is_ascii;
    is( $overlong_params{canonical_bytes},
        '\x00', 'a decodable overlong stores its canonical encoding' );
    is(
        $overlong_params{codepoint},
        $is_ascii ? 'U+00' : '0x00',
        'a decodable overlong stores its code point separately'
    );
    is( join( ',', @{ $overlong_diagnostic->warning_categories } ),
        'WARN_UTF8', 'a decodable overlong keeps its warning category' );
    like(
        $overlong_warnings[0]->render_as_legacy('en'),
        qr/overlong; instead use \\x00 to represent U\+00/,
        'a decodable overlong renders its canonical bytes and code point'
    );
    like(
        $overlong_warnings[0]->render_as_legacy('fr'),
        qr/ dans une entr.*e de sous-programme/,
        'a decodable overlong keeps the French operation connector'
    );

    my $short_overlong_bytes =
      substr( main::I8_to_native( $is_ascii ? "\xe0\x80\x80" : "\xe0\xa0\xa0" ),
        0, 2 );
    my @short_overlong_warnings;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub { push @short_overlong_warnings, $_[0] };
        local $SIG{__WARN__}   = sub { };
        XS::APItest::utf8::test_utf8n_to_uvchr_error( $short_overlong_bytes,
            length($short_overlong_bytes), 0 );
    }

    my ($short_overlong_diagnostic) = map { @{ $_->contents } }
      grep { $_->contents->[0]->code eq 'WARNING_UTF8_OVERLONG_PREFIX' }
      @short_overlong_warnings;
    ok( $short_overlong_diagnostic,
        'an undecodable overlong prefix emits a structured warning' );
    my %short_overlong_params =
      map { $_->{name} => $_->{value} } @{ $short_overlong_diagnostic->params };
    is( $short_overlong_diagnostic->code,
        'WARNING_UTF8_OVERLONG_PREFIX',
        'an undecodable overlong prefix keeps its diagnostic identity' );
    is(
        $short_overlong_params{operation},
        'subroutine entry',
        'an undecodable overlong records its operation'
    );
    is( $short_overlong_params{prefix},
        '\xe0\x80',
        'an undecodable overlong stores the bytes that establish its prefix' )
      if $is_ascii;
    ok( !exists $short_overlong_params{codepoint},
        'an undecodable overlong does not invent a code point' );
    is( join( ',', @{ $short_overlong_diagnostic->warning_categories } ),
        'WARN_UTF8', 'an undecodable overlong keeps its warning category' );
    like(
        $short_overlong_diagnostic->render_as_legacy('en'),
        qr/sequence that starts with "\\xe0\\x80" is overlong/,
        'an undecodable overlong renders its byte prefix'
    ) if $is_ascii;
    like(
        $short_overlong_diagnostic->render_as_legacy('fr'),
        qr/ dans une entr.*e de sous-programme/,
        'an undecodable overlong keeps the French operation connector'
    );

    # These are UTF8_WARN_PERL_EXTENDED and UTF8_WARN_SUPER from utf8.h.
    my $warn_perl_extended = 0x0100;
    my $warn_super         = 0x0400;

    for my $case (
        [
            'super code point', pack( 'C*', 0xF4, 0x90, 0x80, 0x80 ),
            $warn_super,        'WARNING_UTF8_NON_UNICODE_CODEPOINT_ABOVE_UNICODE_MAX',
            '110000',           qr/Code point 0x110000 is not Unicode/,
        ],
        [
            'Perl-extended code point',
            XS::APItest::utf8::test_uvchr_to_utf8_flags( 0x80000000, 0 ),
            $warn_perl_extended,
            'WARNING_UTF8_NON_UNICODE_PERL_EXTENDED_CODEPOINT',
            '80000000',
            qr/Code point 0x80000000 is not Unicode/,
        ],
      )
    {
        my ( $description, $bytes, $flags, $code, $codepoint, $rendered ) =
          @$case;
        my @warnings;
        {
            use warnings 'non_unicode';
            use warnings 'portable';
            local $SIG{__EXCEPT__} = sub { push @warnings, $_[0] };
            local $SIG{__WARN__}   = sub { };
            XS::APItest::utf8::test_utf8n_to_uvchr_error( $bytes,
                length($bytes), $flags );
        }

        is( scalar @warnings, 1, "$description emits one structured warning" );
        my $diagnostic = $warnings[0]->contents->[0];
        is( $diagnostic->code, $code,
            "$description keeps its diagnostic identity" );
        my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
        is( $params{arg1}, $codepoint, "$description records its code point" );
        is(
            $params{operation},
            'subroutine entry',
            "$description records its operation"
        );
        is( join( ',', @{ $diagnostic->warning_categories } ),
            'WARN_NON_UNICODE', "$description keeps its warning category" );
        like( $warnings[0]->render_as_legacy('en'),
            $rendered, "$description renders the complete warning" );
    }

    for my $case (
        [
            'Perl-extended',     pack( 'C*', 0xFE ),
            $warn_perl_extended, 'WARNING_UTF8_NON_UNICODE_PERL_EXTENDED_SEQUENCE_PREFIX',
        ],
        [
            'non-Unicode', pack( 'C*', 0xF4, 0xBF ),
            $warn_super,   'WARNING_UTF8_NON_UNICODE_ABOVE_UNICODE_SEQUENCE_PREFIX',
        ],
      )
    {
        my ( $description, $bytes, $flags, $code ) = @$case;
        my @warnings;
        {
            use warnings 'non_unicode';
            use warnings 'portable';
            local $SIG{__EXCEPT__} = sub { push @warnings, $_[0] };
            local $SIG{__WARN__}   = sub { };
            XS::APItest::utf8::test_utf8n_to_uvchr_error( $bytes,
                length($bytes), $flags );
        }

        my ($diagnostic) = map { @{ $_->contents } }
          grep {
            my $exception = $_;
            grep { $_->code eq $code } @{ $exception->contents }
          } @warnings;
        ok( $diagnostic, "$description prefix emits a structured warning" );
        my %params =
          $diagnostic
          ? map { $_->{name} => $_->{value} } @{ $diagnostic->params }
          : ();
        is(
            $params{prefix},
            $description eq 'Perl-extended' ? '\\xfe' : '\\xf4\\xbf',
            "$description prefix is retained as data"
        );
        ok( !exists $params{arg1},
            "$description prefix does not invent a code point" );
        is(
            join(
                ',', $diagnostic ? @{ $diagnostic->warning_categories } : ()
            ),
            'WARN_NON_UNICODE',
            "$description prefix keeps its category"
        );
        like(
            $diagnostic ? $diagnostic->render_as_legacy('en') : '',
            $description eq 'Perl-extended'
            ? qr/sequence that starts with "\\xfe" is a Perl extension/
            : qr/sequence that starts with "\\xf4\\xbf" is for a non-Unicode code point/,
            "$description prefix renders its complete warning"
        );
    }

    my @surrogate_and_nonchar_inputs = (
        [
            'UTF-16 surrogate code point', pack( 'C*', 0xED, 0xA0, 0x80 ),
            0x40,                          'WARNING_UTF8_SURROGATE_SURROGATE_DECODED',
        ],
        [
            'UTF-16 surrogate prefix', pack( 'C*', 0xED, 0xA0 ),
            0x40,                      'WARNING_UTF8_SEQUENCE_TOO_SHORT',
        ],
        [
            'Unicode noncharacter', pack( 'C*', 0xEF, 0xB7, 0x90 ),
            0x1000,                 'WARNING_UTF8_NONCHAR_NONCHARACTER_DECODED',
        ],
    );
    my @surrogate_and_nonchar_warnings;
    {
        use warnings 'surrogate';
        use warnings 'nonchar';
        local $SIG{__EXCEPT__} = sub {
            push @surrogate_and_nonchar_warnings, $_[0];
        };
        local $SIG{__WARN__} = sub { };

        for my $case (@surrogate_and_nonchar_inputs) {
            my ( undef, $bytes, $flags ) = @$case;
            XS::APItest::utf8::test_utf8n_to_uvchr_error( $bytes,
                length($bytes), $flags );
        }
    }

    is( scalar @surrogate_and_nonchar_warnings,
        4, 'surrogate and noncharacter decoding emits four diagnostics' );

    my @surrogate_and_nonchar_cases = (
        [
            'UTF-16 surrogate code point',
            'WARNING_UTF8_SURROGATE_SURROGATE_DECODED',
            'arg1',
            'D800',
            'WARN_SURROGATE',
            qr/UTF-16 surrogate U\+D800 in subroutine entry/,
        ],
        [
            'UTF-16 surrogate prefix length',
            'WARNING_UTF8_SEQUENCE_TOO_SHORT',
            'bytes',
            '\\xed\\xa0',
            'WARN_UTF8',
qr/Malformed UTF-8 character: .*too short; 2 bytes available, need 3/,
        ],
        [
            'UTF-16 surrogate prefix',
            'WARNING_UTF8_SURROGATE_SURROGATE_SEQUENCE_PREFIX',
            'prefix',
            '\\xed\\xa0',
            'WARN_SURROGATE',
            qr/sequence that starts with "\\xed\\xa0" is for a surrogate/,
        ],
        [
            'Unicode noncharacter',
            'WARNING_UTF8_NONCHAR_NONCHARACTER_DECODED',
            'arg1',
            'FDD0',
            'WARN_NONCHAR',
            qr/Unicode non-character U\+FDD0 is not recommended/,
        ],
    );

    for my $i ( 0 .. $#surrogate_and_nonchar_cases ) {
        my ( $description, $expected_code, $param_name,
            $expected_value, $expected_category, $rendered )
          = @{ $surrogate_and_nonchar_cases[$i] };
        my $diagnostic = $surrogate_and_nonchar_warnings[$i]->contents->[0];
        my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
        is( $diagnostic->code, $expected_code,
            "$description keeps its specific diagnostic identity" );
        is( $params{$param_name}, $expected_value,
            "$description retains the code point or byte prefix" );
        is( join( ',', @{ $diagnostic->warning_categories } ),
            $expected_category, "$description retains its warning category" );
        like( $surrogate_and_nonchar_warnings[$i]->render_as_legacy('en'),
            $rendered, "$description renders its complete warning" );
    }
}

SKIP: {
    skip 'the packed UTF-8 sequence is ASCII-specific', 5
      unless ord('A') == 65;

    my @pack_exceptions;
    {
        use warnings 'utf8';
        no warnings 'experimental::smartmatch';
        local $SIG{__EXCEPT__} = sub { push @pack_exceptions, $_[0] };
        local $SIG{__WARN__}   = sub { };
        eval {
            for ( 0 .. 30 ) {
                my $packed = 0 ~~ pack 'UXc', exp;
            }
        };
    }

    my ($decoder_warning) =
      grep { $_->contents->[0]->code eq 'WARNING_UTF8_SEQUENCE_CONTINUATION_INVALID' }
      @pack_exceptions;
    ok( $decoder_warning,
        'pack delivers its malformed UTF-8 warning as a structured diagnostic'
    );

    my %params =
      $decoder_warning
      ? map { $_->{name} => $_->{value} }
      @{ $decoder_warning->contents->[0]->params }
      : ();
    is( $params{operation}, 'pack',
        'the pack warning records its operation as structured data' );
    is( $params{bytes}, '\xc2\x00',
        'the pack warning retains the malformed bytes' );
    is(
        join( ',',
            $decoder_warning
            ? @{ $decoder_warning->contents->[0]->warning_categories }
            : () ),
        'WARN_UTF8',
        'the pack warning retains its UTF-8 warning category'
    );
    like(
        $decoder_warning ? $decoder_warning->render_as_legacy('en') : '',
        qr/required sequence length 2 bytes; valid prefix length 1\) in pack/,
        'the pack warning renders the full UTF-8 diagnostic'
    );
}

my %strict_refs_templates = (
    symbol =>
      'Can\'t use string ("%1$s") as a symbol ref while "strict refs" in use',
    scalar =>
      'Can\'t use string ("%1$s") as a SCALAR ref while "strict refs" in use',
    array =>
      'Can\'t use string ("%1$s") as an ARRAY ref while "strict refs" in use',
    hash =>
      'Can\'t use string ("%1$s") as a HASH ref while "strict refs" in use',
);
for my $case (
    [ symbol => '*{$name};' ],
    [ scalar => '$$name;' ],
    [ array  => '@{$name};' ],
    [ hash   => '%{$name};' ],
  )
{
    my ( $reference_kind, $expression ) = @$case;
    eval "use strict 'refs'; my \$name = 'symbolic'; $expression";
    is( $@->contents->[0]->params->[0]{value},
        'symbolic', "strict refs stores the $reference_kind string value" );
    my $expected_text = $strict_refs_templates{$reference_kind};
    $expected_text =~ s/%1\$s/symbolic/;
    is_diagnostic_text( $@->contents->[0], $expected_text,
        "strict refs preserves the $reference_kind rendered text" );
    ok( $@->contents->[0]->selector_key,
        "strict refs stores selectors for the $reference_kind case" );
    ok(
        !exists $@->contents->[0]->{template},
        'diagnostics do not store catalog templates'
    );
}

eval q{ use strict 'refs'; my $name = 'x' x 40; $$name; };
ok( $@->contents->[0]->selector_key,
    'strict refs selects the truncated value case' );
is_diagnostic_text(
    $@->contents->[0],
    'Can\'t use string ("'
      . ( 'x' x 32 )
      . '"...) as a SCALAR ref while "strict refs" in use',
    'strict refs selects the complete truncated scalar message'
);

eval q{ use strict 'refs'; my $name = 'x' x 32; $$name; };
ok( $@->contents->[0]->selector_key,
    'strict refs selects the complete value case at the display limit' );
is_diagnostic_text(
    $@->contents->[0],
    'Can\'t use string ("'
      . ( 'x' x 32 )
      . '") as a SCALAR ref while "strict refs" in use',
    'strict refs does not add an ellipsis at the display limit'
);

eval q{ use strict 'refs'; my $name = "a\0b"; $$name; };
is( $@->contents->[0]->params->[0]{value},
    "a\0b", 'strict refs preserves an embedded NUL in its argument' );
is_diagnostic_text(
    $@->contents->[0],
    "Can't use string (\"a\0b\") as a SCALAR ref while \"strict refs\" in use",
    'the generated formatter preserves an embedded NUL in the message'
);

my $byte_name = "\xE9";
{
    our $strict_refs_byte_name;
    local $strict_refs_byte_name = $byte_name;
    eval q{ use strict 'refs'; $$strict_refs_byte_name; };
}
is( utf8::is_utf8( $@->contents->[0]->params->[0]{value} ),
    '', 'strict refs keeps a byte argument as a byte string' );
is( unpack( 'H*', $@->contents->[0]->params->[0]{value} ),
    'e9', 'strict refs preserves the byte argument value' );
is_diagnostic_text(
    $@->contents->[0],
    "Can't use string (\"\xE9\") as a SCALAR ref while \"strict refs\" in use",
    'the generated formatter preserves the byte argument in its message'
);

eval q{ use strict 'refs'; my $name = 'NoSuchSub'; &$name; };
is(
    $@->contents->[0]->code,
    'ERROR_STRICT_REFS_SUBROUTINE_STRING_REFERENCE_FORBIDDEN',
    'a symbolic subroutine call under strict refs keeps its diagnostic'
);
is( $@->contents->[0]->params->[0]{value},
    'NoSuchSub',
    'the strict refs subroutine formatter stores the string value' );
is_diagnostic_text(
    $@->contents->[0],
'Can\'t use string ("NoSuchSub") as a subroutine ref while "strict refs" in use',
    'the strict refs subroutine formatter preserves its rendered text'
);

eval q{ use strict 'refs'; my $name = 'x' x 40; &$name; };
ok( $@->contents->[0]->selector_key,
    'strict refs subroutine errors select the truncated value case' );
is_diagnostic_text(
    $@->contents->[0],
    'Can\'t use string ("'
      . ( 'x' x 32 )
      . '"...) as a subroutine ref while "strict refs" in use',
    'strict refs selects the complete truncated subroutine message'
);

{

    package XPerlTest::ExistingTiePackage;
}

package main;
eval q{ my %hash; tie %hash, 'XPerlTest::ExistingTiePackage'; };
is( $@->contents->[0]->code,
    'ERROR_OBJECT_METHOD_LOOKUP_NOT_FOUND',
    'a missing tie method keeps its structured diagnostic' );
my %missing_tie_params =
  map { $_->{name} => $_->{value} } @{ $@->contents->[0]->params };
is( $missing_tie_params{arg1},
    '"TIEHASH"', 'the quoted method formatter stores the method name' );
is(
    $missing_tie_params{arg2},
    '"XPerlTest::ExistingTiePackage"',
    'the normalized package formatter stores the package name'
);
is_diagnostic_text(
    $@->contents->[0],
'Can\'t locate object method "TIEHASH" via package "XPerlTest::ExistingTiePackage"',
    'the normalized method and package formatters preserve the error text'
);

for my $case (
    [ 'XPerlTest::MissingTieConstructorPackage',
      'ERROR_OBJECT_METHOD_LOOKUP_PACKAGE_NOT_FOUND' ],
    [ {}, 'ERROR_OBJECT_METHOD_LOOKUP_NOT_FOUND' ],
) {
    eval { my %hash; tie %hash, $case->[0]; };
    my $exception = $@;
    my $diagnostic = $exception->contents->[0];
    is( $diagnostic->code, $case->[1],
        'tie constructor lookup uses the shared diagnostic' );
    is( $diagnostic->params->[0]{value}, '"TIEHASH"',
        'normalized C-string method keeps its quoted value' );
    like( $exception->render_as_legacy('en'),
        qr/Can't locate object method "TIEHASH" via package/,
        'the shared DIE alias preserves the tie failure text' );
}

my $utf8_method = "\N{U+E9}";
my $object      = bless {}, 'XPerlTest::MissingMethodPackage';
eval { $object->$utf8_method() };
is( $@->contents->[0]->code,
    'ERROR_OBJECT_METHOD_LOOKUP_NOT_FOUND',
    'a missing UTF-8 method keeps its structured diagnostic' );
my $utf8_method_param = $@->contents->[0]->params->[0]{value};
is(
    $utf8_method_param,
    '"' . $utf8_method . '"',
    'the UTF-8 method formatter stores the method name'
);
ok( utf8::is_utf8($utf8_method_param),
    'the UTF-8 method formatter preserves the UTF-8 flag' );
like( $@->contents->[0]->text,
    qr/\Q"$utf8_method"\E/,
    'the UTF-8 method formatter preserves the quoted method name' );

{
    no warnings 'experimental::class';
    use feature 'class';
    BEGIN { push @XPerlTestClassWithIsa::ISA, 'XPerlTestParent' }
    eval q{ class XPerlTestClassWithIsa {} };
}
is( $@->contents->[0]->code,
    'ERROR_OBJECT_DEFINITION_CLASS_EXISTING_ISA_FORBIDDEN',
    'a class with a non-empty ISA keeps its structured diagnostic' );
my $class_params = $@->contents->[0]->params;
is( $class_params->[0]{value},
    'XPerlTestClassWithIsa', 'the stash-name formatter stores the class name' );
is_diagnostic_text(
    $@->contents->[0],
'Cannot create class XPerlTestClassWithIsa as it already has a non-empty @ISA',
    'the stash-name formatter preserves the error text'
);

{
    no warnings 'experimental::class';
    use feature 'class';

    class XPerlExceptionRequiredParameterClass {
        field $required_class_parameter : param;
    }

    role XPerlExceptionRequiredParameterRole {
        field $required_role_parameter : param;
    }

    class XPerlExceptionRequiredParameterRoleConsumer
      : implements(XPerlExceptionRequiredParameterRole) { }

    class XPerlExceptionUnknownParametersClass { }
}

for my $case (
    [ { unexpected => 1 }, 1 ],
    [ { unexpected => 1, extra => 2 }, 2 ],
) {
    my ( $arguments, $expected_count ) = @$case;
    eval { XPerlExceptionUnknownParametersClass->new(%$arguments) };
    my $diagnostic = $@->contents->[0];
    my %params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $diagnostic->code,
        'ERROR_OBJECT_CONSTRUCTOR_UNKNOWN_PARAMETERS',
        'unknown constructor parameters keep their diagnostic identity' );
    is( $params{param_count}, $expected_count,
        'unknown constructor parameter count is retained as data' );
}

for ( 1 .. 2 ) {
    my $class_call_line = __LINE__ + 1;
    eval { XPerlExceptionRequiredParameterClass->new() };
    my $error      = $@;
    my $diagnostic = $error->contents->[0];
    my %params     = map { $_->{name} => $_->{value} } @{ $diagnostic->params };

    is(
        $diagnostic->code,
        'ERROR_OBJECT_CONSTRUCTOR_REQUIRED_PARAMETER_MISSING',
        'a missing class parameter has its own diagnostic identity'
    );
    is( $params{parameter}, 'required_class_parameter',
        'a missing class parameter is retained as data' );
    is(
        $params{class_name},
        '"XPerlExceptionRequiredParameterClass"',
        'the class name keeps its historical quoted form'
    );
    is( $diagnostic->location->{line},
        $class_call_line,
        'the missing class parameter points to the constructor call' );
    is_diagnostic_text(
        $diagnostic,
q{Required parameter 'required_class_parameter' is missing for "XPerlExceptionRequiredParameterClass" constructor},
        'the catalog template preserves the class constructor wording'
    );
}

for ( 1 .. 2 ) {
    my $role_call_line = __LINE__ + 1;
    eval { XPerlExceptionRequiredParameterRoleConsumer->new() };
    my $error      = $@;
    my $diagnostic = $error->contents->[0];
    my %params     = map { $_->{name} => $_->{value} } @{ $diagnostic->params };

    is(
        $diagnostic->code,
        'ERROR_OBJECT_CONSTRUCTOR_REQUIRED_PARAMETER_MISSING',
        'a missing role parameter has its own diagnostic identity'
    );
    is( $params{parameter}, 'required_role_parameter',
        'a missing role parameter is retained as data' );
    is(
        $params{class_name},
        '"XPerlExceptionRequiredParameterRole"',
        'the role name keeps its historical quoted form'
    );
    is( $diagnostic->location->{line},
        $role_call_line,
        'the missing role parameter points to the constructor call' );
    is_diagnostic_text(
        $diagnostic,
q{Required parameter 'required_role_parameter' is missing for "XPerlExceptionRequiredParameterRole" constructor},
        'the catalog template preserves the role constructor wording'
    );
}

for my $case (
    [
        array => sub {
            my @array;
            my $reference = \@array;
            my $lvalue    = sub : lvalue { @{$reference} };
            eval { $lvalue->() = 3 };
            $@;
        },
        'Can\'t return array to lvalue scalar context',
    ],
    [
        hash => sub {
            my %hash;
            my $reference = \%hash;
            my $lvalue    = sub : lvalue { %{$reference} };
            eval { $lvalue->() = 3 };
            $@;
        },
        'Can\'t return hash to lvalue scalar context',
    ],
  )
{
    my ( $aggregate_kind, $get_exception, $template ) = @$case;
    my $exception;
    {
        local $SIG{__WARN__} = sub { };
        $exception = $get_exception->();
    }
    is( $exception->contents->[0]->code, 'ERROR_MUTATION_LVALUE_RETURN_AGGREGATE_IN_SCALAR_CONTEXT',
        "an lvalue sub returning an $aggregate_kind uses the generic diagnostic"
    );
    ok( $exception->contents->[0]->selector_key,
        "the $aggregate_kind return error records its semantic selector" );
    like( $exception->render_as_legacy('en'),
        qr/\Q$aggregate_kind\E/,
        "the $aggregate_kind return error selects its message" );
    ok(
        !exists $exception->contents->[0]->{template},
        'diagnostics do not store catalog templates'
    );
}

my $captured_warning;
{
    local $SIG{__EXCEPT__} = sub { $captured_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $unset;
    my $joined = $unset . 'suffix';
}
is( ref($captured_warning), 'XPerl::Exception',
    'a warning hook receives the catalogued object' );
is( $captured_warning->contents->[0]->code,
    'WARNING_UNINITIALIZED_VALUE_WITH_OPERATION',
    'the warning diagnostic retains its catalog code' );
is( $captured_warning->contents->[0]->severity,
    'WARNING', 'the warning keeps its severity' );
my $uninitialized_params = $captured_warning->contents->[0]->params;
is(
    join( '|',
        map { $_->{name} . ':' . $_->{value} } @$uninitialized_params ),
    'operation_identity:' . ( 1 + B::opnumber('multiconcat') )
      . '|name_state_selector:1|name:$unset|operation:concatenation (.) or string',
    'the uninitialized warning stores its displayed name and operation'
);
like(
    $captured_warning->contents->[0]->render_as_legacy('en'),
    qr/\AUse of uninitialized value \$unset in concatenation \(\.\) or string at /,
    'the descriptive multiconcat case preserves its complete English output'
);
ok(
    !exists $captured_warning->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);
is( join( '|', @{ $captured_warning->contents->[0]->warning_categories } ),
    'WARN_UNINITIALIZED', 'the warning keeps its symbolic category' );
is(
    join(
        '|',
        @{ JSON::PP->new->decode( $captured_warning->contents->[0]->as_json )
              ->{warning_categories}
        }
    ),
    'WARN_UNINITIALIZED',
    'warning JSON includes its symbolic categories'
);

my $join_uninit_warning;
{
    use warnings 'uninitialized';
    local $SIG{__EXCEPT__} = sub { $join_uninit_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $unset;
    my $joined = join '', $unset;
}
is(
    join( '|', map { $_->{name} . ':' . $_->{value} }
          @{ $join_uninit_warning->contents->[0]->params } ),
    'operation_identity:' . ( 1 + B::opnumber('join') )
      . '|name_state_selector:1|name:$unset|operation:join or string',
    'folded join retains its displayed operation description'
);
like(
    $join_uninit_warning->render('en:legacy'),
    qr/\AUse of uninitialized value \$unset in join or string at /,
    'the complete English join case preserves its existing output'
);
like(
    $join_uninit_warning->render('fr:legacy'),
    qr/\AUtilisation d'une valeur non initialis\x{E9}e \$unset dans join ou cha\x{EE}ne interpol\x{E9}e \N{LATIN SMALL LETTER A WITH GRAVE} /,
    'folded join selects a complete French operation template'
);

my $sprintf_uninit_warning;
{
    use warnings 'uninitialized';
    local $SIG{__EXCEPT__} = sub { $sprintf_uninit_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $unset;
    my $formatted = sprintf '%s', $unset;
}
my ($sprintf_operation) = grep { $_->{name} eq 'operation' }
  @{ $sprintf_uninit_warning->contents->[0]->params };
is(
    $sprintf_operation->{value}, 'sprintf',
    'fake multiconcat retains the sprintf operation identity'
);
like(
    $sprintf_uninit_warning->render('fr:legacy'),
    qr/\AUtilisation d'une valeur non initialis\x{E9}e \$unset dans sprintf \N{LATIN SMALL LETTER A WITH GRAVE} /,
    'fake multiconcat selects the French sprintf template'
);

my $sort_uninit_warning;
{
    use warnings 'uninitialized';
    local $SIG{__EXCEPT__} = sub { $sort_uninit_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my @sorted = sort { my $unset; $unset } ( 1, 2 );
}
my ($sort_operation) = grep { $_->{name} eq 'operation' }
  @{ $sort_uninit_warning->contents->[0]->params };
is(
    $sort_operation->{value}, 'sort',
    'sort without an active op retains the sort operation identity'
);
like(
    $sort_uninit_warning->render('fr:legacy'),
    qr/\AUtilisation d'une valeur non initialis\x{E9}e dans sort \N{LATIN SMALL LETTER A WITH GRAVE} /,
    'sort without an active op selects its French template'
);

my $array_element_uninit_warning;
{
    use warnings 'uninitialized';
    local $SIG{__EXCEPT__} = sub { $array_element_uninit_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $index;
    my @array = (1);
    my $value = $array[$index];
}
my ($array_element_operation) = grep { $_->{name} eq 'operation_identity' }
  @{ $array_element_uninit_warning->contents->[0]->params };
is(
    $array_element_operation->{value},
    1 + B::opnumber('aelem'),
    'multideref records numeric identity for its inner array element operation'
);

my $hash_exists_uninit_warning;
{
    use warnings 'uninitialized';
    local $SIG{__EXCEPT__} = sub { $hash_exists_uninit_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $key;
    my %hash = ( x => 1 );
    my $exists = exists $hash{$key};
}
my ($hash_exists_operation) = grep { $_->{name} eq 'operation_identity' }
  @{ $hash_exists_uninit_warning->contents->[0]->params };
is(
    $hash_exists_operation->{value},
    1 + B::opnumber('exists'),
    'multideref retains numeric identity for the exists operation override'
);

my $posix_warning_exception;
{
    local $SIG{__EXCEPT__} = sub { $posix_warning_exception = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $pattern = '[[:dgit]]';
    my $regex   = qr/$pattern/;
}
is( $posix_warning_exception->contents->[0]->code,
    'WARNING_REGEXP_CHAR_CLASS_POSIX_SYNTAX_SUSPICIOUS',
    'a malformed POSIX-class warning uses its semantic diagnostic' );
ok(
    $posix_warning_exception->contents->[0]->selector_key,
    'the POSIX-class reason is retained as a selector'
);
is( scalar @{ $posix_warning_exception->contents->[0]->params },
    scalar @{ diagnostic_metadata($posix_warning_exception->contents->[0])->{parameters} },
    'the POSIX-class reason remains in the canonical parameter record' );

my @posix_outside_class_cases = (
    [
        'recognized',
        '[:alpha:]',
        'POSIX syntax [: :] belongs inside character classes',
"La syntaxe POSIX [: :] doit se trouver dans une classe de caract\N{U+E8}res",
    ],
    [
        'unimplemented',
        '[=foo=]',
"POSIX syntax [= =] belongs inside character classes (but this one isn't implemented)",
"La syntaxe POSIX [= =] doit se trouver dans une classe de caract\N{U+E8}res (mais celle-ci n'est pas impl\N{U+E9}ment\N{U+E9}e)",
    ],
    [
        'invalid',
        '[:no_such_class:]',
"POSIX syntax [: :] belongs inside character classes (but this one isn't fully valid)",
"La syntaxe POSIX [: :] doit se trouver dans une classe de caract\N{U+E8}res (mais celle-ci n'est pas enti\N{U+E9}rement valide)",
    ],
);

for my $case (@posix_outside_class_cases) {
    my ( $status, $pattern, $expected_en, $expected_fr ) = @$case;
    my $exception;
    {
        use warnings 'regexp';
        local $SIG{__EXCEPT__} = sub { $exception = $_[0] };
        local $SIG{__WARN__}   = sub { };
        my $regex = qr/$pattern/;
    }

    my ($diagnostic) =
      $exception
      ? grep { $_->code eq 'WARNING_REGEXP_CHAR_CLASS_POSIX_OUTER_BRACKETS_MISSING' }
      @{ $exception->contents }
      : ();
    ok( $diagnostic, "POSIX outside-class warning records $status status" );
    my $location_marker = ' in regex; marked by <-- HERE';
    my $rendered_en = $diagnostic ? $diagnostic->render_as_legacy('en') : '';
    my $rendered_fr = $diagnostic ? $diagnostic->render_as_legacy('fr') : '';
    my $en_location = index( $rendered_en, $location_marker );
    my $fr_location =
      index( $rendered_fr, " dans l'expression r\N{U+E9}guli\N{U+E8}re" );
    is(
        $en_location >= 0 ? substr( $rendered_en, 0, $en_location ) : undef,
        $expected_en,
        "POSIX outside-class $status template renders in English"
    );
    is(
        $fr_location >= 0 ? substr( $rendered_fr, 0, $fr_location ) : undef,
        $expected_fr,
        "POSIX outside-class $status template renders in French"
    );
    ok( $en_location >= 0 && $fr_location >= 0,
        "POSIX outside-class $status retains its regex location" );
    my %diagnostic_params =
      $diagnostic
      ? map { $_->{name} => $_->{value} } @{ $diagnostic->params }
      : ();
    is(
        $diagnostic
        ? join( '|', map { $_->{name} } @{ $diagnostic->params } )
        : undef,
        'arg1|arg2|class_status',
        "POSIX outside-class $status retains its selector input"
    );
    is( $diagnostic_params{class_status},
        selector_native_id( $diagnostic, 'class_status', $status ),
        "POSIX outside-class $status records its native selector ID" );
}

my @stat_warning_exceptions;
{
    local $SIG{__EXCEPT__} = sub { push @stat_warning_exceptions, $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval q{
        use warnings 'syntax';
        our @stat_foo;
        @stat_foo = ('stat.t');
        stat @stat_foo;
        my @stat_bar = @stat_foo;
        stat @stat_bar;
        my $stat_ref = \@stat_foo;
        stat @$stat_ref;
        1;
    };
}
my @stat_diagnostics = map { @{ $_->contents } } @stat_warning_exceptions;

is(
    join( '|', map { $_->code } @stat_diagnostics ),
    'WARNING_SYNTAX_FILE_TEST_ARRAY_COERCION_WITH_ELEMENT_HINT|WARNING_SYNTAX_FILE_TEST_ARRAY_COERCION_WITH_ELEMENT_HINT|WARNING_SYNTAX_FILE_TEST_ARRAY_COERCION_WITHOUT_ELEMENT_HINT',
    'stat array warnings use their distinct diagnostic identities'
);
my @stat_params;
for my $diagnostic (@stat_diagnostics) {
    push @stat_params,
      { map { $_->{name} => $_->{value} } @{ $diagnostic->params } };
}
is( join( '|', map { $_->{name} // '' } @{ $stat_diagnostics[0]->params } ),
    'name', 'the stat suggestion keeps only its semantic display parameter' );
is( $stat_params[0]{name},
    '$stat_foo[0]', 'the stat suggestion retains the first element name' );
is( $stat_params[1]{name},
    '$stat_bar[0]', 'the second stat suggestion retains its element name' );
is( scalar @{ $stat_diagnostics[2]->params },
    0, 'an unavailable stat suggestion has no message parameters' );
is_diagnostic_text(
    $stat_diagnostics[0],
'Array passed to stat will be coerced to a scalar (did you want stat $stat_foo[0]?)',
    'the stat suggestion preserves the complete English warning'
);
is_diagnostic_text(
    $stat_diagnostics[2],
    'Array passed to stat will be coerced to a scalar',
    'the generic stat warning preserves the historical English wording'
);
like(
    $stat_diagnostics[0]->render_as_legacy('fr'),
qr/^Array passed to stat will be coerced to a scalar \(vouliez-vous appeler stat \$stat_foo\[0\] \?\)/,
    'the stat suggestion preserves the historical French hint rendering'
);

my $readonly_io_exception;
{
    use warnings 'layer';
    local $SIG{__EXCEPT__} = sub { $readonly_io_exception = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $readonly_io_scalar = \43;
    ok( !defined open( my $readonly_fh, '>', $readonly_io_scalar ),
        'opening a readonly scalar for output fails' );
}
my $readonly_io_diagnostic = $readonly_io_exception->contents->[0];
is( $readonly_io_diagnostic->code,
    'WARNING_IO_LAYER_SCALAR_READONLY_FOR_WRITE',
    'the readonly PerlIO warning keeps its identity' );
is( scalar @{ $readonly_io_diagnostic->params },
    0, 'the readonly PerlIO warning has no message-fragment parameters' );
is_diagnostic_text(
    $readonly_io_diagnostic,
    'Modification of a read-only value attempted',
    'the readonly PerlIO warning preserves its full wording'
);

my $readonly_value_exception;
{
    my $readonly_value = 42;
    Internals::SvREADONLY( $readonly_value, 1 );
    eval { $readonly_value++ };
    $readonly_value_exception = $@;
}
my $readonly_value_diagnostic = $readonly_value_exception->contents->[0];
is(
    $readonly_value_diagnostic->code,
    'ERROR_MUTATION_READ_ONLY_VALUE_MODIFICATION',
    'modifying a readonly value has a structured diagnostic'
);
is( scalar @{ $readonly_value_diagnostic->params },
    0, 'the readonly modification error has no message-fragment parameters' );
is_diagnostic_text(
    $readonly_value_diagnostic,
    'Modification of a read-only value attempted',
    'the readonly modification error preserves its full wording'
);

my $unnamed_warning;
{
    local $SIG{__EXCEPT__} = sub { $unnamed_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $value = undef() + 0;
}
ok( $unnamed_warning->contents->[0]->selector_key,
    'an uninitialized warning without a variable name stores its selector' );
ok(
    !exists $unnamed_warning->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);

my $filehandle_warning;
{
    use warnings 'closed';
    local $SIG{__EXCEPT__} = sub { $filehandle_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    open my $fh, '>', \my $sink or die $!;
    close $fh;
    print {$fh} 'x';
}
is( $filehandle_warning->contents->[0]->code,
    'WARNING_IO_OPERATION_ON_CLOSED_OR_UNOPENED_HANDLE',
    'a closed filehandle warning keeps its diagnostic identity' );
ok( $filehandle_warning->contents->[0]->isa(
        'XPerl::Diagnostic::Warning::IO' ),
    'runtime warning categories preserve the reviewed IO subject class' );
is( join('|', @{ $filehandle_warning->contents->[0]->warning_categories }), 'WARN_CLOSED',
    'the IO subject class preserves the runtime closed warning category' );
ok( $filehandle_warning->contents->[0]->isa(
        'XPerl::Diagnostic::Warning::IO' ),
    'runtime IO warning category retains its registered family' );
is( ref( $filehandle_warning->contents->[0] ),
    'XPerl::Diagnostic::Warning::IO::Closed',
    'closed handle warning uses its specific runtime control class' );
is(
    join( '|',
        map { $_->{name} . ':' . $_->{value} }
          @{ $filehandle_warning->contents->[0]->params } ),
    'handle_state:1|handle_type:1|handle_name_state:1|operation_form:1'
      . '|operation:print|handle_name:$fh',
    'a filehandle warning records its state and operation values'
);
ok(
    !exists $filehandle_warning->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);

my $filetest_warning;
{
    use warnings 'closed';
    local $SIG{__EXCEPT__} = sub { $filetest_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    open my $fh, '>', \my $sink or die $!;
    close $fh;
    my $exists = -e $fh;
}
is(
    join( '|',
        map { $_->{name} . ':' . $_->{value} }
          @{ $filetest_warning->contents->[0]->params } ),
    'handle_state:1|handle_type:1|handle_name_state:1|operation_form:2'
      . '|operation:-e|handle_name:$fh',
    'a filehandle warning identifies file test syntax semantically'
);
ok(
    !exists $filetest_warning->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);

my @dirhandle_warnings;
{
    use warnings 'io';
    local $SIG{__EXCEPT__} = sub { push @dirhandle_warnings, $_[0] };
    local $SIG{__WARN__}   = sub { };
    opendir my $dh, '.' or die $!;
    print {$dh} 'x';
}
my ($dirhandle_hint) =
  grep { $_->contents->[0]->code eq 'WARNING_IO_DIRHANDLE_USED_AS_FILEHANDLE_SUGGESTION' }
  @dirhandle_warnings;
ok( $dirhandle_hint,
    'using a directory handle as a filehandle emits the structured hint' );
is(
    join( '|',
        map { $_->{name} . ':' . $_->{value} }
          @{ $dirhandle_hint->contents->[0]->params } ),
    'handle_name_state:1|operation:print|operation_form:1|handle_name:$dh',
    'a dirhandle hint records semantic name state and operation values'
);
ok(
    !exists $dirhandle_hint->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);

my $numeric_warning;
{
    local $SIG{__EXCEPT__} = sub { $numeric_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $bad = 'bad';
    my $sum = $bad + 0;
}
is( ref($numeric_warning), 'XPerl::Exception',
    'the exception hook receives a parameterized warning' );
is(
    $numeric_warning->contents->[0]->code,
    'WARNING_NUMERIC_VALUE_NONNUMERIC_IN_OPERATION',
    'the parameterized warning keeps its catalog code'
);
is(
    join( '|',
        map { join( ':', @$_{qw(name type value)} ) }
          @{ $numeric_warning->contents->[0]->params } ),
    'arg2_operation:uv:' . (1 + B::opnumber('add'))
      . '|arg1:text:bad|arg2:text:addition (+)',
    'the warning records its named formatter values'
);
like(
    $numeric_warning->render('fr:legacy'),
    qr/\AL'argument "bad" n'est pas num\x{E9}rique dans une addition \(\+\) \N{LATIN SMALL LETTER A WITH GRAVE} /,
    'the addition selector renders a complete French message'
);
like(
    $numeric_warning->render('en:legacy'),
    qr/\AArgument "bad" isn\'t numeric in addition \(\+\) at /,
    'the complete English case preserves its existing output'
);
ok(
    !exists $numeric_warning->contents->[0]->{template},
    'diagnostics do not store catalog templates'
);

{
    use warnings FATAL => 'numeric';
    my $bad = 'bad';
    eval { my $sum = $bad + 0 };
    is( ref($@), 'XPerl::Exception',
        'a fatalized parameterized warning uses the exception transport' );
    my $wrapper = $@->contents->[0];
    ok( $wrapper->isa('XPerl::Diagnostic::Error::FatalizedWarning'),
        'a fatalized warning uses its semantic wrapper class' );
    is( ( map { $_->{value} } grep { $_->{name} eq 'arg1' }
          @{ $wrapper->contents->[0]->params } )[0],
        'bad', 'fatalization keeps the warning parameter' );
}

my $wide_warning;
{
    local $SIG{__EXCEPT__} = sub { $wide_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    open my $fh, '>', \my $bytes or die $!;
    binmode $fh, ':raw';
    print {$fh} "\x{100}";
}
is( ref($wide_warning), 'XPerl::Exception',
    'the exception hook receives a checked warning' );
is( $wide_warning->contents->[0]->code,
    'WARNING_UTF8_WIDE_CHARACTER_IN_BYTE_OPERATION',
    'the checked warning keeps its catalog code' );
ok(
    $wide_warning->contents->[0]->selector_key,
    'the checked warning stores its operation selector'
);
like(
    $wide_warning->contents->[0]->text,
qr/\AWide character in print at (?:t\/)?op\/xperl_exception\.t line \d+\.\z/,
    'the standalone diagnostic includes its source location'
);
my $suppressed_wide_warnings = 0;
{
    no warnings 'utf8';
    local $SIG{__WARN__} = sub { $suppressed_wide_warnings++ };
    open my $fh, '>', \my $bytes or die $!;
    binmode $fh, ':raw';
    print {$fh} "\x{100}";
}
is( $suppressed_wide_warnings, 0,
    'a disabled checked warning remains suppressed' );

SKIP: {
    skip 'requires Socket and local socketpair support', 6
      unless eval { require Socket; 1 };

    my ( $wide_send, $peer );
    skip 'local socketpair is unavailable', 6
      unless socketpair( $wide_send, $peer, Socket::PF_UNIX(),
        Socket::SOCK_STREAM(), 0 );

    eval { send( $wide_send, "\x{100}", 0 ) };
    my $wide_send_error = $@;
    isa_ok( $wide_send_error, 'XPerl::Exception',
        'wide send reports a structured fatal diagnostic' );
    my $diagnostic = $wide_send_error->contents->[0];
    is( $diagnostic->code, 'ERROR_UNICODE_WIDE_CHARACTER_BYTE_CONVERSION_FAILED_IN_OPERATION',
        'wide send keeps its diagnostic identity' );
    my %send_params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $send_params{arg1_operation}, 1 + B::opnumber('send'),
        'wide send retains its numeric operation identity' );
    is( join( '|', map { $_->{name} . ':' . $_->{value} } @{ $diagnostic->params } ),
        'arg1_operation:' . (1 + B::opnumber('send')) . '|arg1:send',
        'wide send retains display and identity' );
    is_diagnostic_text( $diagnostic, 'Wide character in send',
        'wide send preserves its English message' );
    like( $diagnostic->render_as_legacy('fr'), qr/Caract.*send/,
        'wide send selects the complete French operation template' );
}

for my $case (
    [
        chr(0xD800),
        'WARNING_UTF8_SURROGATE_CASE_MAPPING_RETURNS_SURROGATE_UNCHANGED',
        'Operation "uc" returns its argument for UTF-16 surrogate U+D800',
        qr/"uc" renvoie son argument pour le substitut UTF-16 U\+D800/,
        'the surrogate warning'
    ],
    [
        chr(0x110000),
        'WARNING_UTF8_NON_UNICODE_CASE_MAPPING_RETURNS_SUPER_UNCHANGED',
        'Operation "uc" returns its argument for non-Unicode code point 0x110000',
        qr/"uc" renvoie son argument pour le point de code non Unicode 0x110000/,
        'the non-Unicode warning'
    ],
) {
    my ( $input, $code, $english, $french, $label ) = @$case;
    my $warning;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub { $warning = $_[0] };
        local $SIG{__WARN__}   = sub { };
        my $upper = uc $input;
    }
    my $diagnostic = $warning->contents->[0];
    is( $diagnostic->code, $code, "$label retains its diagnostic identity" );
    my %word_values = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $word_values{arg1_operation}, 1 + B::opnumber('uc'),
        "$label retains numeric uc identity" );
    is_diagnostic_text( $diagnostic, $english,
        "$label preserves its English message" );
    like( $diagnostic->render_as_legacy('fr'), $french,
        "$label selects the complete French uc template" );
}

for my $case (
    [
        0xD800,
        'WARNING_UTF8_SURROGATE_CASE_MAPPING_RETURNS_SURROGATE_UNCHANGED',
        'Operation "subroutine entry" returns its argument for UTF-16 surrogate U+D800',
    ],
    [
        0x110000,
        'WARNING_UTF8_NON_UNICODE_CASE_MAPPING_RETURNS_SUPER_UNCHANGED',
        'Operation "subroutine entry" returns its argument for non-Unicode code point 0x110000',
    ],
) {
    my ( $codepoint, $code, $english ) = @$case;
    my $warning;
    {
        use warnings 'utf8';
        local $SIG{__EXCEPT__} = sub { $warning = $_[0] };
        local $SIG{__WARN__}   = sub { };
        XS::APItest::test_toUPPER_uvchr($codepoint);
    }
    my $diagnostic = $warning->contents->[0];
    is( $diagnostic->code, $code,
        "$code reports the descriptive XSUB caller operation" );
    my %word_values = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
    is( $word_values{arg1_operation}, 1 + B::opnumber('entersub'),
        "$code retains numeric subroutine-entry identity" );
    is_diagnostic_text( $diagnostic, $english,
        "$code uses its complete descriptive English template" );
}

SKIP: {
    skip 'requires POSIX locale support', 9
      unless eval { require POSIX; POSIX->import('locale_h'); 1 };

    my $old_ctype = POSIX::setlocale(&POSIX::LC_CTYPE);
    skip 'cannot select the C character locale', 9
      unless defined $old_ctype && POSIX::setlocale(&POSIX::LC_CTYPE, 'C');

    my @locale_diagnostics;
    {
        use locale;
        use warnings 'locale';
        local $SIG{__EXCEPT__} = sub {
            push @locale_diagnostics, $_[0]->contents->[0];
        };
        local $SIG{__WARN__} = sub { };
        my $wide_character = uc "\x{103}";
        my $case_mapping    = uc "\x{FB00}";
    }
    POSIX::setlocale( &POSIX::LC_CTYPE, $old_ctype );

    is( scalar @locale_diagnostics, 2,
        'non-UTF-8 locale case mapping emits both structured warnings' );
    my ( $wide_locale, $mapping_locale ) = @locale_diagnostics;
    is( $wide_locale->code, 'WARNING_LOCALE_WIDE_CHARACTER_UNDER_BYTE_CTYPE',
        'wide-character locale warning keeps its diagnostic identity' );
    my %locale_params = map { $_->{name} => $_->{value} } @{ $wide_locale->params };
    is( $locale_params{arg2_operation}, 1 + B::opnumber('uc'),
        'wide-character locale warning retains its numeric uc identity' );
    is_diagnostic_text(
        $wide_locale,
        'Wide character (U+103) in uc under a non-UTF-8 locale',
        'wide-character locale warning preserves its English message'
    );
    like( $wide_locale->render_as_legacy('fr'), qr/U\+103.*dans uc/,
        'wide-character locale warning uses the complete French uc message' );
    is( $mapping_locale->code, 'WARNING_LOCALE_CASE_MAPPING_CROSSES_BYTE_BOUNDARY',
        'locale case-mapping warning keeps its diagnostic identity' );
    my %mapping_params = map { $_->{name} => $_->{value} } @{ $mapping_locale->params };
    is( $mapping_params{arg1_operation}, 1 + B::opnumber('uc'),
        'locale case-mapping warning retains its numeric uc identity' );
    like( $mapping_locale->text, qr/Can't do uc\("\\x\{FB00\}"\)/,
        'locale case-mapping warning preserves its English text' );
    like( $mapping_locale->render_as_legacy('fr'),
        qr/Impossible d'appliquer uc\("\\x\{FB00\}"\)/,
        'locale case-mapping warning uses the complete French uc message' );
}

my $wrapped_warning;
{
    local $SIG{__EXCEPT__} = sub { $wrapped_warning = $_[0] };
    local $SIG{__WARN__}   = sub { };
    my $wide_bytes = "\x{100}" x 16;
    my $value      = unpack( 's', $wide_bytes );
}
is( ref($wrapped_warning), 'XPerl::Exception',
    'the exception hook receives a runtime-category warning' );
is( $wrapped_warning->contents->[0]->code,
    'WARNING_PACK_UNPACK_BYTE_FORMAT_CHARACTER_WRAPPED',
    'the runtime-category warning keeps its catalog code' );
is(
    join( '|',
        map { $_->{value} } @{ $wrapped_warning->contents->[0]->params } ),
    's|unpack',
    'the runtime-category warning captures both formatter values'
);

is( ref( $wrapped_warning->contents->[0] ),
    'XPerl::Diagnostic::Warning::Unpack',
    'unpack wrapping uses its runtime warning-control class' );
{
    my $pack_warning;
    local $SIG{__EXCEPT__} = sub { $pack_warning = $_[0] };
    local $SIG{__WARN__} = sub { };
    my $wide_value = "\x{100}";
    my $value = pack 'u', $wide_value;
    is( ref( $pack_warning->contents->[0] ),
        'XPerl::Diagnostic::Warning::Pack',
        'pack wrapping uses its runtime warning-control class' );
}

my $once_warning = do {
    local $ENV{PERL_DIAG_RENDER} = 'Dumper';
    runperl(
        switches => ['-w'],
        prog     => 'BEGIN { $SIG{__EXCEPT__} = sub { my $w = $_[0]; print '
          . '$w->contents->[0]->code, chr(10); print join(q[|], map { '
          . '$_->{value} } @{$w->contents->[0]->params}), chr(10) }; '
          . '$SIG{__WARN__} = sub {}; } $typo = ' . '1;'
    );
};
like(
    $once_warning,
    qr/^WARNING_ONCE_PACKAGE_NAME_USED_ONCE\nmain\|typo\n\z/,
    'a hash-key warning retains its owned package and symbol names'
);

my $missing_semicolon_warning = runperl(
    stderr => 1,
    prog   => <<'PERL',
BEGIN {
    $SIG{__EXCEPT__} = sub {
        for my $diagnostic ( @{ $_[0]->contents } ) {
            next unless $diagnostic->code eq q{WARNING_SYNTAX_SEMICOLON_PREVIOUS_LINE_SEMICOLON_MAY_BE_MISSING};
            print join( q{|}, $diagnostic->code,
                scalar @{ $diagnostic->params },
                join( q{,}, @{ $diagnostic->warning_categories } ),
                $diagnostic->render_as_legacy(q{en}) ), qq{\n};
        }
    };
    $SIG{__WARN__} = sub {};
}
use warnings q{semicolon};
1
foo;
PERL
);
like(
    $missing_semicolon_warning,
qr/WARNING_SYNTAX_SEMICOLON_PREVIOUS_LINE_SEMICOLON_MAY_BE_MISSING\|0\|WARN_SEMICOLON\|Semicolon seems to be missing at -e line \d+\./,
'the missing-semicolon warning is catalogued without an English message parameter'
);

my @hash_assignment_warnings;
{
    use warnings 'misc';
    local $SIG{__EXCEPT__} = sub { push @hash_assignment_warnings, $_[0] };
    local $SIG{__WARN__}   = sub { };
    my %hash;
    %hash = ( 1 .. 3 );
    %hash = ( {} );
}
is( scalar @hash_assignment_warnings,
    2, 'odd hash assignments produce two structured warnings' );
is(
    join( '|', map { $_->contents->[0]->code } @hash_assignment_warnings ),
    'WARNING_MISC_HASH_ASSIGNMENT_ODD_ELEMENT_COUNT'
      . '|WARNING_MISC_HASH_ASSIGNMENT_AGGREGATE_REFERENCE_IN_ODD_LIST',
    'odd hash assignment conditions have distinct diagnostic identities'
);
is(
    join( '|',
        map { scalar @{ $_->contents->[0]->params } }
          @hash_assignment_warnings ),
    '0|0',
    'hash assignment warnings do not store message fragments'
);
is(
    join( '|',
        map { join( ',', @{ $_->contents->[0]->warning_categories } ) }
          @hash_assignment_warnings ),
    'WARN_MISC|WARN_MISC',
    'hash assignment warnings keep their category'
);
is_diagnostic_text(
    $hash_assignment_warnings[0]->contents->[0],
    'Odd number of elements in hash assignment',
    'odd hash assignment warning keeps its complete English text'
);
is_diagnostic_text(
    $hash_assignment_warnings[1]->contents->[0],
    'Reference found where even-sized list expected',
    'reference hash assignment warning keeps its complete English text'
);

{
    use warnings FATAL => 'uninitialized';
    my $unset;
    my ($seen_wrapper, $seen_warning, $nested_warning, $deep_warning,
        $cycle_warning, $shared_warning);
    local $SIG{__EXCEPT__} = sub {
        $seen_wrapper = $_[0]->contents->[0];
        $seen_warning = $seen_wrapper->contents->[0];
        $nested_warning = XPerl::Diagnostic->_new(
            {
                code => 'WARNING_UNINITIALIZED_VALUE_WITH_OPERATION', number => 2250,
                kind => 'CORE_RUNTIME', severity => 'WARNING',
                params => [], location => {},
            }
        );
        $nested_warning->{_fatal_warning} = 1;
        push @{ $seen_warning->{contents} }, $nested_warning;
        $deep_warning = XPerl::Diagnostic->_new(
            {
                code => 'WARNING_UNINITIALIZED_VALUE_WITH_OPERATION', number => 2250,
                kind => 'CORE_RUNTIME', severity => 'WARNING',
                params => [], location => {},
            }
        );
        $deep_warning->{_fatal_warning} = 1;
        my $deep_context = $deep_warning;
        for (1 .. 160) {
            $deep_context = XPerl::Diagnostic->_new(
                {
                    code => 'ERROR_USER_TEXT', number => 2438,
                    kind => 'USER_RUNTIME', severity => 'NOTE',
                    params => [], location => {}, contents => [$deep_context],
                }
            );
        }
        push @{ $seen_warning->{contents} }, $deep_context;
        $cycle_warning = XPerl::Diagnostic->_new(
            {
                code => 'WARNING_UNINITIALIZED_VALUE_WITH_OPERATION', number => 2250,
                kind => 'CORE_RUNTIME', severity => 'WARNING',
                params => [], location => {},
            }
        );
        $cycle_warning->{_fatal_warning} = 1;
        $cycle_warning->{contents} = [$cycle_warning];
        push @{ $seen_warning->{contents} }, $cycle_warning;
        $shared_warning = XPerl::Diagnostic->_new(
            {
                code => 'WARNING_UNINITIALIZED_VALUE_WITH_OPERATION', number => 2250,
                kind => 'CORE_RUNTIME', severity => 'WARNING',
                params => [], location => {},
            }
        );
        $shared_warning->{_fatal_warning} = 1;
        my $shared_context = XPerl::Diagnostic->_new(
            {
                code => 'ERROR_USER_TEXT', number => 2438,
                kind => 'USER_RUNTIME', severity => 'NOTE',
                params => [], location => {},
                contents => [$shared_warning, $shared_warning],
            }
        );
        push @{ $seen_warning->{contents} }, $shared_context;
    };
    eval { my $joined = $unset . 'suffix' };
    is( ref($@), 'XPerl::Exception',
        'fatal warnings use the same exception transport' );
    is( $@->contents->[0]->code,
        'ERROR_FATALIZED_WARNING_WRAPPER', 'fatal warning exception retains its wrapper' );
    is( $@->contents->[0]->contents->[0]->code,
        'WARNING_UNINITIALIZED_VALUE_WITH_OPERATION',
        'fatalization keeps the warning diagnostic identity' );
    ok( $seen_wrapper->isa('XPerl::Diagnostic::Error::FatalizedWarning'),
        '__EXCEPT__ sees the fatalized structure on entry' );
    is( overload::StrVal($seen_warning),
        overload::StrVal($@->contents->[0]->contents->[0]),
        'the wrapper child preserves the original warning reference' );
    ok( $@->contents->[0]->contents->[0]->contents->[0]
            ->isa('XPerl::Diagnostic::Error::FatalizedWarning'),
        'fatalization wraps warning descendants added by __EXCEPT__' );
    my $deep_node = $seen_wrapper->contents->[0]->contents->[1];
    $deep_node = $deep_node->contents->[0] for 1 .. 160;
    ok( $deep_node->isa('XPerl::Diagnostic::Error::FatalizedWarning'),
        'fatalization keeps warning descendants beyond 128 levels' );
    ok( $seen_wrapper->contents->[0]->contents->[2]
            ->isa('XPerl::Diagnostic::Error::FatalizedWarning'),
        'fatalization traverses a warning with a raw ancestor cycle' );
    my $shared_children =
        $seen_wrapper->contents->[0]->contents->[3]->contents;
    ok( $shared_children->[0]
            ->isa('XPerl::Diagnostic::Error::FatalizedWarning')
            && $shared_children->[1]
            ->isa('XPerl::Diagnostic::Error::FatalizedWarning'),
        'fatalization wraps shared warning occurrences in both branches' );
    is( overload::StrVal($shared_children->[0]->contents->[0]),
        overload::StrVal($shared_children->[1]->contents->[0]),
        'shared fatal-warning wrappers retain one warning identity' );
}

like(
    runperl(
        prog => "use warnings FATAL => q(all);\nuse strict;\n\$foo;\nmyfunc 1,2,3\n",
        stderr => 1,
    ),
    qr/Number found where operator expected \(Do you need to predeclare "myfunc"\?\) at .* line 4, near "myfunc 1"/,
    'fatalized compile warnings retain parser context and location'
);

SKIP: {
    skip 'requires XS::APItest', 3
      unless eval { require XS::APItest; 1 };

    {
        package XPerlTest::FatalCleanupWarning;
        sub DESTROY {
            use warnings FATAL => 'uninitialized';
            my $unset;
            my $ignored = "$unset";
        }
    }

    my ($cleanup_warning, $cleanup_exception);
    local $SIG{__WARN__} = sub { $cleanup_warning .= $_[0] };
    local $SIG{__EXCEPT__} = sub { $cleanup_exception = $_[0] };
    XS::APItest::call_sv(
        sub {
            my $cleanup = bless {}, 'XPerlTest::FatalCleanupWarning';
            die "primary failure\n";
        },
        XS::APItest::G_VOID() | XS::APItest::G_EVAL()
            | XS::APItest::G_KEEPERR(),
    );
    like( $cleanup_warning, qr/\(in cleanup\)/,
        'G_KEEPERR reports a fatal-category warning as cleanup output' );
    ok( !$cleanup_exception
            || $cleanup_exception->contents->[0]->code ne 'ERROR_FATALIZED_WARNING_WRAPPER',
        'G_KEEPERR does not wrap cleanup warnings as fatal errors' );

    is( join( '|', @{ XS::APItest::test_diag_adopt_rollback() } ),
        '3|3|2|1|1|1|0|1',
        'rollback subtracts nested errors, retains shared errors, and preserves collector severity' );
}

my $compile_dump = do {
    local $ENV{PERL_DIAG_RENDER} = 'Dumper';
    runperl( prog => 'eval q{my $x = ;}; print ref($@), qq[\n], $@' );
};

my $operator_warning_exception;
{
    local $SIG{__EXCEPT__} = sub { $operator_warning_exception = $_[0] };
    local $SIG{__WARN__}   = sub { };
    eval '0${';
}
my $operator_warning_messages = $operator_warning_exception->contents;
is( $operator_warning_messages->[0]->code,
    'WARNING_SYNTAX_OPERATOR_EXPECTED',
    'operator warnings append a structured primary diagnostic' );
ok( !( grep { $_->code eq 'NOTE_HINT_OPERATOR_EXPECTED_MISSING_OPERATOR' }
      @$operator_warning_messages ),
    'operator hints are not independent top-level diagnostics' );
ok( $operator_warning_messages->[0]->selector_key,
    'operator warnings record the token kind in the selector key' );
my $operator_hint = $operator_warning_messages->[0]->contents->[0];
is( $operator_warning_messages->[0]->contents_count, 1,
    'the primary owns one missing-operator hint' );
is(
    $operator_hint->code,
    'NOTE_HINT_OPERATOR_EXPECTED_MISSING_OPERATOR',
    'the primary owns its missing-operator hint'
);
is( $operator_hint->params->[0]{value},
    '${', 'the operator hint retains the source text' );
ok(
    $operator_warning_messages->[0]{has_following_hint},
    'the primary diagnostic records its following hint'
);
ok(
    $operator_hint->{is_hint},
    'the hint diagnostic identifies itself as a hint'
);
is( join( ',', @{ $operator_warning_messages->[0]->warning_categories } ),
    'WARN_SYNTAX', 'the primary diagnostic retains its warning category' );
is( $operator_hint->warning_categories, undef,
    'the hint uses its parent warning policy' );
is( $operator_hint->severity, 'NOTE', 'the operator hint has NOTE severity' );
like(
    $operator_warning_exception->render_as_modern('en'),
qr{\n\x20\x20An operator may be missing before "\$\{"\.},
    'modern rendering groups an operator hint under its primary diagnostic'
);
like(
    $operator_warning_exception->render_as_legacy('en'),
qr/Scalar found where operator expected \(Missing operator before "\$\{"\?\) at .* near "0\$\{"\n/,
    'legacy rendering appends a contextual hint to its primary diagnostic'
);
like(
    $operator_hint->render_as_legacy('en'),
    qr/An operator may be missing before "\$\{"\. at .* line 1\./,
    'an operator hint remains complete when rendered by itself'
);

my $german_operator_warning =
  $operator_warning_exception->render_as_legacy('de');
like(
    $german_operator_warning,
    qr/\(M\N{U+F6}glicherweise fehlt vor "\$\{" ein Operator\)/,
    'a grouped legacy operator hint uses the requested language'
);
ok(
    utf8::is_utf8($german_operator_warning),
    'grouped localized hints preserve the UTF-8 flag'
);

my $predeclare_warning = XPerl::Exception->_new();
$predeclare_warning->append( $operator_warning_messages->[0] );
my $predeclare_hint = XPerl::Diagnostic->_new(
    {
        code     => 'NOTE_HINT_OPERATOR_EXPECTED_PREDECLARE',
        number   => 2513,
        kind     => 'CORE_COMPILE',
        severity => 'NOTE',
        params   => [ { name => 'name', type => 'text', value => 'foo' } ],
        location => $operator_warning_messages->[0]->location,
    }
);
$predeclare_hint->{is_hint} = 1;
$predeclare_warning->append($predeclare_hint);
like(
    $predeclare_warning->render_as_legacy('de'),
    qr/\(M\N{U+F6}glicherweise m\N{U+FC}ssen Sie "foo" vorher deklarieren\)/,
    'a grouped predeclaration hint uses the requested language'
);

my $nested_eval_with_pending_warning = runperl(
    prog => 'use warnings; qq[\\q]; BEGIN { eval q{1}; '
      . 'eval q{my $inner = ;}; '
      . 'print qq[inner=], ref($@), qq[:], $@->contents->[0]->code, qq[\n]; } '
      . 'print qq[outer ok\n];',
    stderr => 1
);
like(
    $nested_eval_with_pending_warning,
    qr/inner=XPerl::Exception:ERROR_SYNTAX_INVALID/,
    'a nested eval keeps its compile error separate from outer diagnostics'
);
like(
    $nested_eval_with_pending_warning,
    qr/Unrecognized escape \\q passed through/,
    'the outer parser warning survives nested eval compilation'
);
like( $nested_eval_with_pending_warning,
    qr/outer ok/,
    'the outer program continues after a nested eval compile failure' );

my $nested_require_with_pending_warning = runperl(
    prog => 'use warnings; qq[\\q]; BEGIN { require strict; } '
      . 'print qq[outer ok\n];',
    stderr => 1
);
like(
    $nested_require_with_pending_warning,
    qr/Unrecognized escape \\q passed through/,
    'the outer parser warning survives nested require compilation'
);
like( $nested_require_with_pending_warning,
    qr/outer ok/,
    'the outer program continues after nested require compilation' );

my $use_with_pending_warning = runperl(
    prog   => 'use warnings; qq[\\q]; use strict; print qq[outer ok\n];',
    stderr => 1
);
like(
    $use_with_pending_warning,
    qr/Unrecognized escape \\q passed through/,
    'a lexical use can start its temporary parser with pending diagnostics'
);
like( $use_with_pending_warning, qr/outer ok/,
    'the outer program continues after the temporary use parser' );

like(
    $compile_dump,
    qr/^XPerl::Exception\n\{.*?"code" => "ERROR_SYNTAX_INVALID"/s,
    'Dumper mode shows a real catalogued compile error'
);

my $top_level_compile_dump = do {
    local $ENV{PERL_DIAG_RENDER} = 'Dumper';
    runperl( prog => 'use strict; $x = 1;', stderr => 1 );
};
like(
    $top_level_compile_dump,
    qr/^\{.*?"code" => "ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME"/s,
    'Dumper mode renders top-level compile errors'
);

my $multiple_compile_dump = do {
    local $ENV{PERL_DIAG_RENDER} = 'Dumper';
    runperl(
        prog   => 'use strict; $x=$foo+0; $y=$x+1;',
        stderr => 1
    );
};
like(
    $multiple_compile_dump,
    qr/^\{.*?"code" => "ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME"/s,
    'Dumper mode renders multiple top-level compile errors'
);
my @multiple_compile_diagnostics = $multiple_compile_dump =~
  /"code" => "ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME"/g;
is( scalar @multiple_compile_diagnostics,
    4, 'Dumper mode preserves every top-level compile diagnostic' );

my $top_level_compile_json = do {
    local $ENV{PERL_DIAG_RENDER} = 'JSON';
    runperl( prog => 'use strict; $x = 1;', stderr => 1 );
};
like(
    $top_level_compile_json,
    qr/"code":"ERROR_COMPILATION_EXECUTION_ABORTED"/,
    'the compile exception includes its terminal diagnostic'
);
unlike( $top_level_compile_json, qr/LEGACY_TEXT/,
    'the compile exception does not duplicate its diagnostics as text' );

{
    my $episode = XPerl::Exception->_new();
    for my $value ( "first warning\n", "second warning\n" ) {
        $episode->append(
            XPerl::Diagnostic->_new(
                {
                    code     => 'WARNING_USER_TEXT',
                    number   => 0,
                    kind     => 'USER',
                    severity => 'WARNING',
                    params   =>
                      [ { name => 'message', type => 'sv', value => $value } ],
                }
            )
        );
    }

    $episode->append(
        XPerl::Diagnostic->_new(
            {
                code     => 'ERROR_USER_TEXT',
                number   => 0,
                kind     => 'USER',
                severity => 'FATAL_ERROR',
                params   => [
                    {
                        name  => 'message',
                        type  => 'sv',
                        value => "original error\n"
                    }
                ],
            }
        )
    );

    my ( @warnings, $die_calls, $except_calls, $caught );
    {
        local $SIG{__EXCEPT__} = sub { $except_calls++ };
        local $SIG{__WARN__}   = sub {
            push @warnings, $_[0];
            die "warning replacement\n" if @warnings == 1;
        };
        local $SIG{__DIE__} = sub { $die_calls++ };
        eval { die $episode };
        $caught = ${^ERROR_OBJ};
    }

    is( scalar @warnings, 2, 'delivery continues after a warning hook dies' );
    is( $die_calls, 2, 'each independent error group visits the die hook' );
    is( $except_calls, 1,
        'legacy replacements do not revisit the exception hook' );
    is(
        overload::StrVal($caught),
        overload::StrVal($episode),
        'warning promotion keeps the canonical exception identity'
    );
    is(
        $caught->contents->[0]->params->[0]{value},
        "warning replacement\n",
        'the replacement fatal is retained until the final unwind'
    );

    my $journal = $caught->{_delivery};
    my $inspection = JSON::PP::decode_json( $caught->as_json );
    ok( !exists $inspection->{delivery} && !exists $inspection->{_delivery},
        'exception JSON omits the private delivery journal' );
    is( $journal->[-1]{kind}, 'unwind', 'the unwind record is last' );
    is( $journal->[0]{status},
        'replaced', 'private journal identifies a replaced warning' );
    is(
        $journal->[0]{original}[0]{params}[0]{value},
        "first warning\n",
        'private journal retains the original warning for debugging'
    );

    {
        local $SIG{__DIE__} = sub { $die_calls++ };
        eval { die $caught };
    }
    is( $die_calls, 4,
        'a later rethrow calls the die hook for each error group again' );
}

{
    my ( @except_has_delivery, @legacy_has_delivery, @exceptions );
    {
        local $SIG{__EXCEPT__} = sub {
            push @except_has_delivery, exists $_[0]{_delivery} ? 1 : 0;
            push @exceptions, $_[0];
        };
        local $SIG{__WARN__} = local $SIG{__DIE__} = sub {
            push @legacy_has_delivery,
                ref ${^CUR_ERROR_OBJ}->{_delivery} eq 'ARRAY' ? 1 : 0;
        };
        warn "journal warning\n";
        eval { die "journal error\n" };
    }
    is( join(',', @except_has_delivery), '0,0',
        'fresh exceptions have no delivery journal during __EXCEPT__' );
    is( join(',', @legacy_has_delivery), '1,1',
        'warning and die hooks see the attached delivery journal' );
    ok( @{$exceptions[0]{_delivery}} && @{$exceptions[1]{_delivery}},
        'warning and error journals retain delivery records afterward' );
    ok( !exists $exceptions[0]->contents->[0]{contents},
        'a core-produced warning leaf has no children storage' );
    ok( !exists $exceptions[1]->contents->[0]{contents},
        'a core-produced error leaf has no children storage' );
}

my $buffered_hook_output = runperl(
    prog => q{
        local $SIG{__WARN__}= sub {
            print STDERR qq[begin\n];
            eval { die qq[inner\n] };
            print STDERR q[caught:], $@;
            warn qq[replacement\n];
            print STDERR qq[end\n];
        };
        warn qq[outer\n];
    },
    stderr => 1,
);
is(
    $buffered_hook_output,
    "begin\ncaught:inner\nend\nreplacement\n",
    'explicit prints stay immediate and nested eval catches independently'
);

{
    my $episode = XPerl::Exception->_new();
    for my $item (
        [ 'ERROR_USER_TEXT',   'FATAL_ERROR', "original error\n" ],
        [ 'WARNING_USER_TEXT', 'WARNING',     "following warning\n" ]
      )
    {
        $episode->append(
            XPerl::Diagnostic->_new(
                {
                    code     => $item->[0],
                    number   => 0,
                    kind     => 'USER',
                    severity => $item->[1],
                    params   =>
                      [ { name => 'text', type => 'sv', value => $item->[2] } ],
                }
            )
        );
    }

    my $warning_context;
    {
        local $SIG{__DIE__}  = sub { die "replacement error\n" };
        local $SIG{__WARN__} = sub {
            $warning_context =
              ${^CUR_ERROR_OBJ}->contents->[0]->params->[0]{value};
        };
        eval { die $episode };
    }
    is(
        $warning_context,
        "replacement error\n",
        'later warning hooks see the fatal replacement in the canonical object'
    );
}

{
    local $ENV{PERL_DIAG_RENDER};
    is( runperl( prog => 'print ${^DIAG_RENDER}' ),
        'auto:legacy', 'the default rendering control is auto:legacy' );
    local $ENV{PERL_DIAG_RENDER} = 'fr:annotated';
    is( runperl( prog => 'BEGIN { print ${^DIAG_RENDER} }' ),
        'fr:annotated', 'the environment initializes rendering before BEGIN' );
}

{
    local ${^DIAG_RENDER} = 'en:legacy';
    my $english = "$localized_exception";
    is(
        $english,
        $localized_exception->render_as_legacy('en'),
        'the explicit language controls implicit legacy rendering'
    );
    {
        local ${^DIAG_RENDER} = 'fr:annotated';
        is(
            "$localized_exception",
            $localized_exception->render_as_modern('fr'),
            'a localized setting changes rendering of an existing exception'
        );
    }
    is( "$localized_exception", $english,
        'local restores the rendering setting' );
    local ${^DIAG_RENDER}   = 'auto:legacy';
    local $ENV{LC_ALL}      = '';
    local $ENV{LC_MESSAGES} = 'nl_NL.UTF-8';
    local $ENV{LANG}        = 'de_DE.UTF-8';
    is(
        "$localized_exception",
        $localized_exception->render_as_legacy('nl'),
        'automatic language uses LC_MESSAGES before LANG'
    );
    local $ENV{LC_ALL} = 'fr_FR.UTF-8';
    is(
        "$localized_exception",
        $localized_exception->render_as_legacy('fr'),
        'LC_ALL overrides the automatic message language'
    );
    $ENV{LC_ALL} = 'C';
    is( "$localized_exception", $english, 'the C locale renders in English' );
    ${^DIAG_RENDER} = 'de';
    is(
        "$localized_exception",
        $localized_exception->render_as_legacy('de'),
        'a bare language setting selects its legacy rendering'
    );
    is(
        $localized_exception->render('de'),
        $localized_exception->render('de:legacy'),
        'explicit rendering accepts a bare language setting'
    );
    $ENV{LC_ALL} = 'fr_FR.UTF-8';
    ${^DIAG_RENDER} = 'auto';
    is(
        "$localized_exception",
        $localized_exception->render_as_legacy('fr'),
        'bare auto selects the automatic language in legacy style'
    );
    ${^DIAG_RENDER} = 'zz:legacy';
    is( "$localized_exception", $english,
        'unavailable languages fall back to English' );
    ${^DIAG_RENDER} = 'JSON';
    is(
        "$localized_exception",
        $localized_exception->render('en:legacy:JSON'),
        'bare JSON defaults to English legacy message content'
    );
    ${^DIAG_RENDER} = 'JSONL';
    my @records = map { JSON::PP::decode_json($_) } grep length, split /\n/,
      "$localized_exception";
    is(
        scalar @records,
        scalar @{ $localized_exception->contents },
        'JSONL writes one independent record per ungrouped diagnostic'
    );
    is( $records[0]{schema},
        'xperl.diagnostic-group.v2', 'JSONL records identify their schema' );
    is(
        $records[0]{contents}[0]{code},
        $localized_exception->contents->[0]->code,
        'JSONL retains structured diagnostic identity'
    );
    is(
        $localized_exception->render('fr:annotated'),
        $localized_exception->render_as_modern('fr'),
        'explicit render accepts the same settings'
    );
    is(
        $localized_exception->render_as_annotated('fr'),
        $localized_exception->render_as_modern('fr'),
        'annotated names the existing metadata format'
    );
}

{
    my @groups = map { JSON::PP::decode_json($_) }
      grep length, split /\n/, $predeclare_warning->render('JSONL');
    is( scalar @groups,
        1, 'JSONL keeps an attached hint with its primary diagnostic' );
    is( scalar @{ $groups[0]{contents} },
        2, 'the JSONL hint group retains both diagnostics' );
    @groups = map { JSON::PP::decode_json($_) }
      grep length, split /\n/, $contextual_charname->render('JSONL');
    is( scalar @groups,
        1, 'JSONL groups light diagnostics with their following context' );
}

{
    local ${^DIAG_RENDER} = $localized_exception;
    is(
        "$localized_exception",
        $localized_exception->render_as_legacy('en'),
        'reference-valued settings do not recursively stringify themselves'
    );
    is(
        $localized_exception->render($localized_exception),
        $localized_exception->render_as_legacy('en'),
        'explicit rendering also rejects reference-valued settings safely'
    );
}

my $ordered_groups = runperl(
    prog => q{
        local ${^DIAG_RENDER}= q[en:legacy];
        my $e= XPerl::Exception->_new();
        for my $item ([q[ERROR_USER_TEXT],q[FATAL_ERROR],qq[E1\n]],
                      [q[WARNING_USER_TEXT],q[WARNING],qq[W1\n]],
                      [q[ERROR_USER_TEXT],q[FATAL_ERROR],qq[E2\n]],
                      [q[WARNING_USER_TEXT],q[WARNING],qq[W2\n]]) {
            $e->append(XPerl::Diagnostic->_new({
                code=>$item->[0], number=>($item->[0] eq q[ERROR_USER_TEXT] ? 2438 : 2439), kind=>q[USER_RUNTIME], severity=>$item->[1],
                params=>[{name=>q[text],type=>q[text],value=>$item->[2]}],
            }));
        }
        local $SIG{__DIE__}= sub { print STDERR q[D:], $_[0] };
        local $SIG{__WARN__}= sub { print STDERR q[W:], $_[0] };
        die $e;
    },
    stderr => 1,
);
is(
    $ordered_groups,
"D:E1 (Stack unwind deferred)\nE1\nW:W1\nD:E2 (Stack unwind deferred)\nE2\nW:W2\n",
'each group is emitted before the next legacy hook and final unwind does not repeat it'
);

{
    my $e = XPerl::Exception->_new();
    for my $text ( "first error\n", "removed error\n" ) {
        $e->append(
            XPerl::Diagnostic->_new(
                {
                    code     => 'ERROR_USER_TEXT',
                    number   => 2438,
                    kind     => 'USER_RUNTIME',
                    severity => 'FATAL_ERROR',
                    params   =>
                      [ { name => 'text', type => 'text', value => $text } ],
                }
            )
        );
    }

    my ( @die_args, $caught );
    {
        local $SIG{__DIE__} = sub {
            my $active_exception = ${^CUR_ERROR_OBJ};
            push @die_args, $_[0];
            $active_exception->{contents} = [ $active_exception->{contents}[0] ]
              if @die_args == 1;
        };
        eval { die $e };
        $caught = ${^ERROR_OBJ};
    }

    is( scalar @die_args,
        1, 'truncating diagnostics in a die hook prevents later callbacks' );
    is( join( ',', map { $_->code } @{ $caught->contents } ),
        'ERROR_USER_TEXT', 'delivery keeps the output group after list truncation' );
    is(
        $caught->contents->[0]->params->[0]{value},
        "first error\n",
        'delivery does not resurrect diagnostics removed by a hook'
    );
}

{
    my $e = XPerl::Exception->_new();
    for my $text ( "first error\n", "queued error\n" ) {
        $e->append(
            XPerl::Diagnostic->_new(
                {
                    code     => 'ERROR_USER_TEXT',
                    number   => 2438,
                    kind     => 'USER_RUNTIME',
                    severity => 'FATAL_ERROR',
                    params   => [ { name => 'text', type => 'text', value => $text } ],
                }
            )
        );
    }

    my @seen;
    {
        local $SIG{__DIE__} = sub {
            my $active = ${^CUR_ERROR_OBJ};
            push @seen, $_[0];
            if (@seen == 1) {
                $active->{contents}[1] = XPerl::Diagnostic->_new(
                    {
                        code     => 'ERROR_USER_TEXT',
                        number   => 2438,
                        kind     => 'USER_RUNTIME',
                        severity => 'FATAL_ERROR',
                        params   => [
                            { name => 'text', type => 'text', value => "appended error\n" }
                        ],
                    }
                );
                push @{ $active->{contents} }, XPerl::Diagnostic->_new(
                    {
                        code     => 'ERROR_USER_TEXT',
                        number   => 2438,
                        kind     => 'USER_RUNTIME',
                        severity => 'FATAL_ERROR',
                        params   => [
                            { name => 'text', type => 'text', value => "late error\n" }
                        ],
                    }
                );
            }
        };
        eval { die $e };
    }

    is( scalar @seen, 3,
        'hook additions become a finite appended action batch and removed queued groups are skipped' );
    like( $seen[1], qr/appended error/, 'the hook replacement is delivered' );
    like( $seen[2], qr/late error/, 'the hook addition is delivered after it' );
}

{
    my $e = XPerl::Exception->_new();
    for my $text ( "first error\n", "queued error\n" ) {
        $e->append(
            XPerl::Diagnostic->_new(
                {
                    code     => 'ERROR_USER_TEXT',
                    number   => 2438,
                    kind     => 'USER_RUNTIME',
                    severity => 'FATAL_ERROR',
                    params   => [ { name => 'text', type => 'text', value => $text } ],
                }
            )
        );
    }

    my @seen;
    {
        local $SIG{__DIE__} = sub {
            push @seen, $_[0];
            if ( @seen == 1 ) {
                $e->contents->[1]->append(
                    XPerl::Diagnostic->_new(
                        {
                            code     => 'ERROR_USER_TEXT',
                            number   => 2438,
                            kind     => 'USER_RUNTIME',
                            severity => 'FATAL_ERROR',
                            params   => [
                                { name => 'text', type => 'text', value => "nested child\n" }
                            ],
                        }
                    )
                );
            }
        };
        eval { die $e };
    }

    is( scalar @seen, 2,
        'a queued group still delivers after its children change in a prior hook' );
    like( $seen[1], qr/queued error.*nested child/s,
        'the queued group renders its live nested child changes' );
}

{
    my $e = XPerl::Exception->_new();
    for my $text ( "first error\n", "last error\n" ) {
        $e->append(
            XPerl::Diagnostic->_new(
                {
                    code     => 'ERROR_USER_TEXT',
                    number   => 2438,
                    kind     => 'USER_RUNTIME',
                    severity => 'FATAL_ERROR',
                    params   =>
                      [ { name => 'text', type => 'text', value => $text } ],
                }
            )
        );
    }
    my @args;
    {
        local ${^DIAG_RENDER} = 'en:legacy';
        local $SIG{__DIE__} = sub { push @args, $_[0] };
        eval { die $e };
    }
    is( scalar @args, 2,
        'independent runtime error diagnostics each visit the die hook' );
    like(
        $args[0],
        qr/Stack unwind deferred/,
        'a nonfinal error carries the deferred unwind hint'
    );
    is( $args[1], "last error\n",
        'the final error has no deferred unwind hint' );
}

{
    my ( $calls, $value );
    local $SIG{__DIE__} = sub { $calls++; $value = $_[0] };
    eval q[use strict; $x=$y+$z;];
    is( $calls, 1, 'one compilation error batch produces one die hook call' );
    is( ref($value), '', 'the compiler die hook receives rendered text' );
    like(
        $value,
        qr/Global symbol "\$x".*Global symbol "\$y".*Global symbol "\$z"/s,
        'the compiler hook text retains all errors and their order'
    );
}

{
    my $e = XPerl::Exception->_new();
    $e->append(
        XPerl::Diagnostic->_new(
            {
                code     => 'ERROR_USER_TEXT',
                number   => 2438,
                kind     => 'USER_RUNTIME',
                severity => 'FATAL_ERROR',
                params   =>
                  [ { name => 'text', type => 'text', value => "first\n" } ],
            }
        )
    );
    my $light = XPerl::Diagnostic->_new(
        { %$light_charname, context_follows_index => 2 } );
    $e->append($light);
    $e->append($charname_location);
    $e->append(
        XPerl::Diagnostic->_new(
            {
                code     => 'WARNING_USER_TEXT',
                number   => 2439,
                kind     => 'USER_RUNTIME',
                severity => 'WARNING',
                params   => [
                    {
                        name  => 'text',
                        type  => 'text',
                        value => "last warning\n"
                    }
                ],
            }
        )
    );
    my @args;
    {
        local ${^DIAG_RENDER} = 'en:legacy';
        local $SIG{__DIE__}   = sub { push @args, $_[0] };
        local $SIG{__WARN__}  = sub { };
        eval { die $e };
    }
    is( scalar @args, 2, 'a light run and its tail produce one die hook call' );
    like(
        $args[1],
        qr/BadName.*marked by <-- HERE/s,
        'the hook receives light diagnostics with the regex tail context'
    );
    unlike(
        $args[1],
        qr/context unavailable/,
        'group-local links resolve during hook rendering'
    );
    unlike(
        $e->render_as_legacy('en'),
        qr/context unavailable/,
        'canonical links remain valid after group-local rendering'
    );
}

{
    my $call_line = __LINE__ + 1;
    eval { goto; };
    my $diagnostic = $@->contents->[0];

    is( $diagnostic->code, 'ERROR_CONTROL_FLOW_GOTO_LABEL_REQUIRED',
        'an argless goto has its own diagnostic identity' );
    is( scalar @{ $diagnostic->params },
        0, 'an argless goto has no sentence-fragment parameters' );
    is( $diagnostic->location->{line},
        $call_line, 'an argless goto points to the goto statement' );
    is_diagnostic_text(
        $diagnostic,
        'goto must have label',
        'the catalog template preserves the historical wording'
    );
}

{
    my $diagnostic = bless {
        code => 'WARNING_UNTIE_INNER_REFERENCES_REMAIN', number => 2217,
        kind => 'CORE_RUNTIME', severity => 'WARNING', selector_key => 0,
        params => [{ name => 'arg1', type => 'uv', value => '0' }],
    }, 'XPerl::Diagnostic';

    like($diagnostic->render_as_legacy('en'), qr/0 inner references still exist/,
        'English resolves zero as other at render time');
    like($diagnostic->render_as_legacy('fr'), qr/sans r\x{e9}f\x{e9}rence interne/,
        'a French exact zero case wins over its one category');
    $diagnostic->{params}[0]{value} = '1';
    like($diagnostic->render_as_legacy('en'), qr/1 inner reference still exists/,
        'English inflects both noun and verb for a single reference');
    like($diagnostic->render_as_legacy('fr'), qr/1 r\x{e9}f\x{e9}rence interne existe encore/,
        'French still selects its grammatical category for non-exact counts');
    $diagnostic->{params}[0]{value} = '2';
    like($diagnostic->render_as_legacy('en'), qr/2 inner references still exist/,
        'rerendering reads the current count instead of a saved category');
    like($diagnostic->render_as_legacy('unsupported'), qr/2 inner references still exist/,
        'an unsupported language uses English plural selection');

    my @icelandic_plural_boundaries = (
        [ '1', "reynt a\x{f0} aftengja me\x{f0}an 1 innri tilv\x{ed}sun er enn til" ],
        [ '11', "reynt a\x{f0} aftengja me\x{f0}an 11 innri tilv\x{ed}sanir eru enn til" ],
        [ '21', "reynt a\x{f0} aftengja me\x{f0}an 21 innri tilv\x{ed}sun er enn til" ],
        [ '101', "reynt a\x{f0} aftengja me\x{f0}an 101 innri tilv\x{ed}sun er enn til" ],
        [ '111', "reynt a\x{f0} aftengja me\x{f0}an 111 innri tilv\x{ed}sanir eru enn til" ],
        [ '18446744073709551601',
          "reynt a\x{f0} aftengja me\x{f0}an 18446744073709551601 innri tilv\x{ed}sun er enn til" ],
        [ '18446744073709551611',
          "reynt a\x{f0} aftengja me\x{f0}an 18446744073709551611 innri tilv\x{ed}sanir eru enn til" ],
    );
    for my $case (@icelandic_plural_boundaries) {
        $diagnostic->{params}[0]{value} = $case->[0];
        is( $diagnostic->render_as_legacy('is'), $case->[1],
            "Icelandic cardinal selection preserves the exact count $case->[0]" );
    }
}

{
    package PluralUntie;
    sub TIESCALAR { bless {}, shift }
    sub FETCH { 0 }
}
{
    my $diagnostic;
    local $SIG{__WARN__} = sub { $diagnostic = ${^CUR_ERROR_OBJ}->contents->[0] };
    tie my $value, 'PluralUntie';
    my $retained = tied $value;
    untie $value;
    is($diagnostic->code, 'WARNING_UNTIE_INNER_REFERENCES_REMAIN',
        'the real untie warning uses the plural-aware catalog entry');
    is($diagnostic->params->[0]{value}, '1', 'the emitted diagnostic retains its original numeric count');
    is($diagnostic->selector_key, 0, 'the emitter does not freeze a language-specific plural category');
}

{
    local $ENV{PERL_DIAG_RENDER} = 'fr:legacy';
    my $array_base = runperl(
        prog   => q{use warnings q(syntax); $[ < 5;},
        stderr => 1,
    );
    like( $array_base, qr/\$\[ utilis.*une comparaison num.*rique strictement inf.*rieur \(<\)/,
        'the French array-base warning resolves its complete operation phrase' );
    unlike( $array_base, qr/numeric lt \(<\)/,
        'the French array-base warning does not append English OP_DESC' );
    my $array_base_fallback = runperl(
        prog   => q{use warnings q(syntax); $[ <= 5;},
        stderr => 1,
    );
    like( $array_base_fallback, qr/\$\[ utilis.*une comparaison num.*rique inf.*rieur ou .*gal \(<=\)/,
        'the shared French sentence resolves another comparison phrase' );

    my $negation = runperl(
        prog   => q{use warnings q(precedence); my $x = !$a == 1;},
        stderr => 1,
    );
    like( $negation, qr/Probl.*priorit.*entre ! et une .*galit.*num.*rique \(==\)/,
        'the French negation warning resolves its operation phrase' );
    unlike( $negation, qr/numeric eq \(==\)/,
        'the French negation warning does not append English OP_DESC' );
    my $negation_fallback = runperl(
        prog   => q{use warnings q(precedence); my $x = !$a lt $b;},
        stderr => 1,
    );
    like( $negation_fallback, qr/entre ! et une comparaison de cha.*nes strictement inf.*rieur \(lt\)/,
        'the shared French negation sentence resolves another operation phrase' );
    local $ENV{PERL_DIAG_RENDER} = 'en:legacy';
    my $english = runperl(
        prog   => q{use warnings q(precedence); my $x = !$a == 1;},
        stderr => 1,
    );
    like( $english, qr/Possible precedence problem between ! and numeric eq \(==\)/,
        'complete English precedence templates preserve their existing output' );
}

{
    local $ENV{PERL_DIAG_RENDER} = 'fr:legacy';
    my $not_enough = runperl( prog => q{join();}, stderr => 1 );
    like( $not_enough, qr/Pas assez d'arguments pour join ou cha.*ne/,
        'the French join arity error localizes its operation description' );
    unlike( $not_enough, qr/join or string/,
        'the French join arity error does not append English OP_DESC' );

    my $too_many = runperl( prog => q{defined(1,2);}, stderr => 1 );
    like( $too_many, qr/Trop d'arguments pour un op.*rateur defined/,
        'the French defined arity error localizes its operation description' );
    unlike( $too_many, qr/defined operator/,
        'the French defined arity error does not append English OP_DESC' );

    my $callee = runperl( prog => q{sub sample ($); sample();}, stderr => 1 );
    like( $callee, qr/Pas assez d'arguments pour main::sample/,
        'a user-defined callee keeps its literal name in the wildcard' );
}

{
    use feature 'signatures';

    sub xperl_signature_call_target { }

    my @cases = (
        [ aelem    => '$_[0]',                         'array element' ],
        [ akeys    => 'keys @_',                       'keys on array' ],
        [ avalues  => 'values @_',                     'values on array' ],
        [ aeach    => 'each @_',                       'each on array' ],
        [ entersub => 'xperl_signature_call_target(q(a), @_, q(z))',
          'subroutine entry' ],
        [ shift    => 'shift @_',                      'shift' ],
    );

    for my $case (@cases) {
        my ( $operation, $body, $description ) = @$case;
        my @diagnostics;
        {
            local $SIG{__EXCEPT__} = sub {
                push @diagnostics, @{ $_[0]->contents };
            };
            local $SIG{__WARN__} = sub { };
            use warnings 'experimental::args_array_with_signatures';
            my $source = "sub (\$x) { $body }";
            eval $source;
            is( $@, '', "$operation signature warning compiles" );
        }

        is( scalar @diagnostics, 1,
            "$operation emits one structured signature warning" );
        my $diagnostic = $diagnostics[0];
        is( $diagnostic->code, 'WARNING_EXPERIMENTAL_ARGS_ARRAY_WITH_SIGNATURES_EXPLICIT_USE',
            "$operation retains its diagnostic identity" );
        my %word_params = map { $_->{name} => $_->{value} } @{ $diagnostic->params };
        is( $word_params{arg1}, $description,
            "$operation keeps its OP_DESC fallback parameter" );
        is( $word_params{arg1_operation}, 1 + B::opnumber($operation),
            "$operation retains its numeric word identity" );

        my $expected = "Use of \@_ in $description with signatured subroutine is experimental";
        is_diagnostic_text( $diagnostic, $expected,
            "$operation selects its complete English template" );
        if ( $operation eq 'aelem' ) {
            like(
                $diagnostic->render_as_legacy('fr'),
                qr/^L'utilisation de \@_ dans un \N{LATIN SMALL LETTER E WITH ACUTE}l\N{LATIN SMALL LETTER E WITH ACUTE}ment de tableau/,
                'array-element warning selects its complete French template'
            );
            unlike( $diagnostic->render_as_legacy('fr'), qr/array element/,
                'French array-element warning does not append English OP_DESC' );
        }
    }
}

{
    my $bitwise_error;
    {
        local $SIG{__EXCEPT__} = sub { $bitwise_error = $_[0] };
        my $wide = "\x{100}";
        eval { my $ignored = $wide | 'x'; 1 };
        $bitwise_error ||= $@;
    }
    my ($bitwise_diagnostic) = grep { $_->code eq 'ERROR_UNICODE_WIDE_CHARACTER_BITWISE_STRING_NOT_BYTES' }
      @{ $bitwise_error->contents };
    is( $bitwise_diagnostic->params->[0]{value}, 'bitwise or (|)',
        'wide bitwise strings retain their operation display' );
    is( $bitwise_diagnostic->selector_key, 2,
        'wide bitwise strings select the exact bitwise-or case' );
    is_diagnostic_text(
        $bitwise_diagnostic,
        'Use of strings with code points over 0xFF as arguments to bitwise or (|) operator is not allowed',
        'wide bitwise strings use a complete English description'
    );
}

{
    eval q{no ops qw(add); my $value = 1 + 2;};
    my $mask_error = $@;
    my ($mask_diagnostic) = grep { $_->code eq 'ERROR_SECURITY_OPERATION_MASK_TRAP' }
      @{ $mask_error->contents };
    is( $mask_diagnostic->params->[0]{value}, 'addition (+)',
        'operation-mask errors retain their operation display' );
    my %mask_params = map { $_->{name} => $_->{value} } @{ $mask_diagnostic->params };
    is( $mask_params{arg1_operation}, 1 + B::opnumber('add'),
        'operation-mask errors retain the numeric opcode word identity' );
    is_diagnostic_text( $mask_diagnostic,
        "'addition (+)' trapped by operation mask",
        'operation-mask errors use a complete English description' );
}

{
    my $scalarized_diagnostic;
    {
        local $SIG{__WARN__} = sub {
            $scalarized_diagnostic = ${^CUR_ERROR_OBJ}->contents->[0];
        };
        eval q{my @array = (q{x}); my $matched = @array =~ /x/;};
    }
    is( $scalarized_diagnostic->code, 'WARNING_MISC_AGGREGATE_BINDING_SCALARIZED_NAMED',
        'array pattern matching uses the structured scalarization warning' );
    is( $scalarized_diagnostic->selector_key, 1,
        'array pattern matching selects the exact match case' );
    is_diagnostic_text( $scalarized_diagnostic,
        'Applying pattern match (m//) to @array will act on scalar(@array)',
        'array pattern matching uses a complete English description' );
}

{
    for my $case (
        [ 0x103, '', '%ENV is aliased to another variable while running with -T switch',
            "%ENV est un alias d'une autre variable pendant l'exécution avec l'option -T" ],
        [ 0x203, 'custom_target', '%ENV is aliased to custom_target while running with -T switch',
            "%ENV est un alias de custom_target pendant l'exécution avec l'option -T" ],
    ) {
        my ( $selector_key, $target, $english, $french ) = @$case;
        utf8::decode($french);
        my $diagnostic = legacy_selector_fixture({
            number => 1804,
            code => 'ERROR_TAINT_ENVIRONMENT_HASH_ALIAS_FORBIDDEN',
            kind => 'CORE_RUNTIME', severity => 'FATAL_ERROR',
            selector_key => $selector_key,
            params => [ { name => 'operation', type => 'text', value => $target },
                { name => 'taint_context', type => 'text', value => 'taint_mode' } ],
            location => {},
        });
        is( $diagnostic->render_as_legacy('en'), $english,
            'ENV alias targets preserve English output' );
        is( $diagnostic->render_as_legacy('fr'), $french,
            'ENV alias targets translate generic text and preserve custom names' );
    }
}

{
    my @process_name_warnings;
    local $SIG{__WARN__} = sub { push @process_name_warnings, $_[0] };
    local $0;
    $0 = "\x{100}";
    like( $process_name_warnings[0], qr/Wide character in \$0/,
        'wide process-name warning identifies the literal Perl variable' );
}

for my $case (
    [ 1673, 'WARNING_INTERNAL_MEMORY_COW_READONLY_PROTECTION_FAILED', 0 ],
    [ 1674, 'WARNING_INTERNAL_MEMORY_COW_READWRITE_PROTECTION_FAILED', 1 ],
) {
    my $diagnostic = bless {
        number => $case->[0], code => $case->[1],
        params => [
            { name => 'arg2', type => 'ptr', value => '0x1234' },
            { name => 'arg3', type => 'uv', value => '64' },
            { name => 'arg4', type => 'iv', value => '5' },
        ],
        location => {},
    }, 'XPerl::Diagnostic';
    for my $language (qw(en de es fr is it nl pt)) {
        my $text = $diagnostic->render_as_legacy($language);
        is( $text =~ /mprotect RW/ ? 1 : 0, $case->[2],
            "$language COW protection label matches the requested permissions" );
    }
}

fresh_perl_is( q{
    use warnings;
    BEGIN {
        $SIG{__EXCEPT__} = sub { print "EXCEPT\n" };
        $SIG{__WARN__} = sub { print "WARN\n" };
    }
    my $value = pack 'u', "\x{100}";
    print "ok\n";
}, "EXCEPT\nWARN\nok\n", {},
    'constant-folded accumulated warning is deferred to execution' );

fresh_perl_is( q{
    BEGIN { $SIG{__EXCEPT__} = sub { print "HOOK\n" } }
    eval { my $value = 1 / 0 };
    print "caught\n";
}, "HOOK\ncaught\n", {},
    'exception hook does not observe speculative constant-fold failure' );

fresh_perl_like( q{
    use warnings;
    my $value = pack 'u', "\x{100}";
    print "ok\n";
}, qr/Character\(s\).*wrapped in pack.*\nok/s, {},
    'constant-folded pack warning does not abort compilation' );

done_testing();
