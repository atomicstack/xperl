#!./perl

BEGIN {
    @INC = -f './TestInit.pm' ? ('.') : ('..');
}
use TestInit qw(T);
use strict;
use warnings;
use utf8;
require './t/test.pl';
require './regen/diag_lib.pm';
require './regen/diag_words.pm';
require './regen/diag_translate.pm';
require Storable;

plan('no_plan');
my $catalog = Diag::Words::catalog();
my $provenance = Diag::Translation::read_provenance('regen/diag_translation_provenance.json');
my %required_forms;
{
    our ( $CONF, $META );
    do './diag_conf.pl' or die $@ || $!;
    for my $diag ( @{ Diag::Migration::diagnostics($CONF) } ) {
        for my $binding ( values %{ $diag->{operation_words} || {} } ) {
            for my $language ( keys %{ $binding->{rules} } ) {
                my $form = $catalog->{languages}{$language}{rules}{ $binding->{rules}{$language} }{form};
                $required_forms{$language}{$_}{$form} = 1 for @{ $binding->{operations} };
            }
        }
    }
}

# This checks data coverage and technical spellings, not linguistic quality.
# Coverage alone does not establish review. Reviewed words need provenance
# from the review workflow, which is distinct from native linguistic review.
{
    my $source     = Diag::Words::source_words();
    my @operations = sort grep { Diag::Words::operation_class( $catalog, $source, $_ ) eq 'description' } keys %$source;
    for my $language ( sort keys %{ $catalog->{languages} } ) {
        my $profile = $catalog->{languages}{$language};
        is(
            join( ',', sort keys %{ $profile->{words} } ),
            join( ',', @operations ),
            "$language covers the shared descriptive operation domain"
        );
        my ( @missing, @symbols, @status );
        for my $operation (@operations) {
            my $word = $profile->{words}{$operation};
            next unless $word;
            push @status, $operation if $language ne 'en'
              && ( $word->{status} || '' ) eq 'reviewed'
              && ( $provenance->{words}{$language}{$operation}{workflow} || '' ) ne 'review';
            my %needed = ( $profile->{base_form} => 1, %{ $required_forms{$language}{$operation} || {} } );
            push @missing, "$operation/$_" for grep { !defined $word->{forms}{$_} } sort keys %needed;
            for my $form ( sort keys %{ $word->{forms} } ) {
                my $text = $word->{forms}{$form};
                next unless defined $text;
                while ( $source->{$operation} =~ /\(([!%&*+\-.\/:<=>?^|~]+)\)/g ) {
                    my $symbol = $1;

                    # Check the complete operator token without requiring
                    # English parentheses around translated descriptions.
                    my $operator_char = qr/[!%&*+\-.\/:<=>?^|~]/;
                    $symbol = '~.'
                      if $operation eq 'scomplement'
                      && $symbol eq '~'
                      && $text =~ /(?<!$operator_char)~\.(?!$operator_char)/;
                    push @symbols, "$operation/$form/$symbol"
                      unless $text =~ /(?<!$operator_char)\Q$symbol\E(?!$operator_char)/;
                }
            }
        }
        is( join( ',', @missing ), '', "$language supplies every form requested by its actual sentence roles" );
        is( join( ',', @symbols ), '', "$language preserves operator symbols in every form" );
        is( join( ',', @status ),  '', "$language reviewed words have explicit review provenance" );
    }
    is(
        $catalog->{languages}{de}{words}{aelemfast_lex}{forms}{dative},
        'einem lexikalischen Arrayelement mit konstantem Index',
        'German stores the whole agreeing phrase'
    );
    is(
        $catalog->{languages}{is}{words}{add}{forms}{dative},
        'samlagningu (+)',
        'Icelandic stores a distinct case form'
    );
    is(
        $catalog->{languages}{it}{words}{add}{forms}{indefinite},
        'un’addizione (+)',
        'Italian article elision is part of the stored phrase'
    );
    ok(
        !exists $catalog->{languages}{is}{words}{concat}{tags}{gender},
        'mixed-gender alternatives do not acquire a single invented gender'
    );
}

# Syntax examples are Perl spellings. Extension-owned prose is a third class,
# separate from both literal syntax and the core's translatable descriptions.
{
    my $source = Diag::Words::source_words();
    for my $operation (qw(dofile entereval entertry entertrycatch)) {
        my $word = Diag::Words::resolve_word( $catalog, 'fr', $operation, 'operation' );
        is( $word->{status}, 'literal',             "$operation is literal syntax" );
        is( $word->{text},   $source->{$operation}, "$operation preserves its complete syntax example" );
    }
    is( Diag::Words::operation_class( $catalog, $source, 'schop' ),
        'description', 'scalar chop retains the descriptive qualifier' );
    my $word = Diag::Words::resolve_word( $catalog, 'fr', 'custom', 'operation', 'extension-owned description' );
    is( $word->{status}, 'opaque',                      'known custom identity remains extension-owned' );
    is( $word->{text},   'extension-owned description', 'custom description is not replaced by generic core prose' );
    is( Diag::Words::resolve_word( $catalog, 'fr', 'custom', 'operation' )->{status},
        'unknown_operation', 'custom identity without its original text is unavailable' );
}

# These profiles test the data contract. They do not register new languages
# or claim that synthetic Welsh strings are reviewed diagnostic translations.
sub fixture {
    my $data = Storable::dclone($catalog);
    $data->{languages}{ru} = {
        base_form => 'nominative',
        forms     => [qw(nominative genitive instrumental)],
        tags      => { gender => [qw(masculine feminine neuter)] },
        rules     => {
            subject      => { form => 'nominative', select => { gender => { tag => 'gender', fallback => '*' } } },
            of_operation => { form => 'genitive',   select => {} },
        },
        words => {
            add    => { forms => { nominative => 'сложение', genitive => 'сложения' }, tags => { gender => 'neuter' } },
            concat => { forms => { nominative => 'конкатенация' }, tags => { gender => 'feminine' } },
        },
    };
    $data->{languages}{cy} = {
        base_form => 'default',
        forms     => [qw(default soft_mutation)],
        tags      => { initial_class => [qw(changes unchanged)] },
        rules     => {
            mutated => {
                form   => 'soft_mutation',
                select => { initial => { tag => 'initial_class', fallback => '*' } },
            },
        },
        words => {
            add => {
                forms => { default       => 'cy:add:base', soft_mutation => 'cy:add:soft' },
                tags  => { initial_class => 'changes' }
            },
        },
    };
    return $data;
}

# The identity domain remains separate from both displayed text and rule outputs.
sub diagnostic {
    return {
        number => 65000,
        code   => 'WORD_CONTRACT_FIXTURE',
        params => [
            { name => 'word',     type => 'text', format_str => 's' },
            { name => 'identity', type => 'text', format_str => 's', internal => 1 },
        ],
        message_template => { en => '%{word}' },
        operation_words  => {
            word => {
                source     => 'identity',
                operations => [qw(add concat)],
                rules      => { en     => 'operation',   ru => 'subject', cy => 'mutated', nl => 'gender' },
                selectors  => { gender => 'word_gender', initial => 'word_initial' },
            },
        },
    };
}

# Storable exposes canonical ordering as a package variable. Keep that setting
# local to snapshots so test comparisons do not depend on hash iteration order.
sub snapshot {
    no warnings 'once';
    local $Storable::canonical = 1;
    return Storable::freeze( $_[0] );
}

my $data = fixture();
ok( Diag::Words::validate($data), 'different language declarations validate independently' );

# Exercise generated data before involving C. Derived dimensions share the
# ordinary key layout, while identity remains a retained parameter.
{
    my $diag = diagnostic();
    push @{ $diag->{operation_words}{word}{operations} }, qw(prtf custom multiconcat);
    Diag::Words::normalize_selectors( $diag, $data );
    ok( Diag::Words::validate_bindings( $diag, $data ), 'derived selector dimensions validate as word outputs' );
    my $before = snapshot($diag);
    my $model  = Diag::Words::compile( [$diag], $data );
    is( snapshot($diag), $before, 'compiling lookups does not mutate diagnostic definitions' );
    my %ids     = map { $model->{operations}[$_] => $_ + 1 } 0 .. $#{ $model->{operations} };
    my $ru      = $model->{languages}{ru};
    my $binding = $ru->{bindings}{WORD_CONTRACT_FIXTURE}[0];
    my $word    = $ru->{values}[ $binding->{map}[ $ids{add} ] ];
    is( $word->{text},    'сложение',         'opcode map selects the requested Russian phrase directly' );
    is( $word->{key},     '0000000000000004', 'gender compiles to its ordinary packed selector ID' );
    is( $binding->{mask}, '000000000000ffff', 'binding clears both of its independent grammatical fields' );
    is( $binding->{map}[ $ids{prtf} ],   1,   'literal identity maps to pass-through' );
    is( $binding->{map}[ $ids{custom} ], 1,   'custom identity maps to pass-through' );
    is( $binding->{map}[0],              1,   'unknown identity preserves the original phrase' );
    is( $model->{languages}{cy}{bindings}{WORD_CONTRACT_FIXTURE}[0]{map}[ $ids{concat} ],
        0, 'missing translated word compiles to unavailable, not English text' );
    my $en = $model->{languages}{en}{bindings}{WORD_CONTRACT_FIXTURE}[0];
    is( $en->{map}[ $ids{concat} ], $en->{map}[ $ids{multiconcat} ], 'equal resolved values share one record' );
    {
        my $bounded = Storable::dclone($diag);
        $bounded->{operation_words}{word}{assert_unknown} = 1;
        my $compiled = Diag::Words::compile( [$bounded], $data );
        my $guard    = $compiled->{languages}{ru}{bindings}{WORD_CONTRACT_FIXTURE}[0];
        is( $guard->{assert_unknown},     1,     'bounded word retains its debug guard' );
        is( $guard->{map}[ $ids{shift} ], 65535, 'outside-domain identity uses the reserved guard value' );
        is( $guard->{map}[ $ids{prtf} ],  1,     'allowed literal passes the domain guard' );
        is( $guard->{map}[0],             1,     'bounded word keeps a release fallback for unknown identities' );
        is( $compiled->{languages}{cy}{bindings}{WORD_CONTRACT_FIXTURE}[0]{map}[ $ids{concat} ],
            0, 'missing translation is distinct from an outside-domain identity' );
    }
    my $canonical = Diag::Migration::canonical_diagnostic_schema($diag);
    ok( !exists $canonical->{message}{selectors}, 'generated grammatical dimensions are not duplicated in config' );
    {
        no warnings 'redefine';
        local *Diag::Words::catalog = sub { $data };
        Diag::Migration::normalize_diagnostic_schema($canonical);
    }
    is(
        join( ',', @{ $canonical->{message_selectors} } ),
        join( ',', @{ $diag->{message_selectors} } ),
        'reload reconstructs the same derived selector order'
    );
    is(
        snapshot( $canonical->{selector_definitions} ),
        snapshot( $diag->{selector_definitions} ),
        'reload reconstructs the same derived domains and identity sources'
    );
    $diag->{selector_definitions}[0]{wide} = 1;
    my $wide         = Diag::Words::compile( [$diag], $data )->{languages}{ru};
    my $wide_binding = $wide->{bindings}{WORD_CONTRACT_FIXTURE}[0];
    is( $wide->{values}[ $wide_binding->{map}[ $ids{add} ] ]{key},
        '0004000000000000', 'wide grammatical field uses the reserved high two octets' );
    is( $wide_binding->{mask}, 'ffff0000000000ff', 'wide field is masked as one U16 alongside the narrow field' );
}

{
    my $copy = fixture();
    $copy->{languages}{ru}{rules}{subject}{select}{gender}{fallback} = 'masculine';
    my $diag = diagnostic();
    $diag->{message_template}{zz} = '%{word}';
    Diag::Words::normalize_selectors( $diag, $copy );
    my $model    = Diag::Words::compile( [$diag], $copy );
    my $ru       = $model->{languages}{ru};
    my $fallback = $ru->{bindings}{WORD_CONTRACT_FIXTURE}[0]{map}[0];
    ok( $fallback > 1,                           'explicit fallback category gets a resolved pass-through record' );
    ok( !defined $ru->{values}[$fallback]{text}, 'explicit fallback preserves the supplied phrase' );
    is( $ru->{values}[$fallback]{key}, '0000000000000003', 'explicit fallback category is precomputed' );
    is( $model->{languages}{zz}{bindings}{WORD_CONTRACT_FIXTURE}[0]{map}[0],
        0, 'language without a vocabulary rule cannot silently borrow another rule' );
    $diag->{message_template}{en} = { map { $_ => '%{word}' } qw(common feminine masculine neuter) };
    eval { Diag::Migration::validate_template_coverage( $diag, Diag::Migration::template_cases( $diag, 'en' ) ); 1 };
    like( $@, qr/no template for selector combination/, 'coverage includes the reachable zero-valued word fields' );
    $diag->{message_template}{en}{'*'} = '%{word}';
    ok(
        eval { Diag::Migration::validate_template_coverage( $diag, Diag::Migration::template_cases( $diag, 'en' ) ); 1 }
        ,
        'English wildcard covers literal and unknown word outputs'
    );
}

{
    my $diag = diagnostic();
    push @{ $diag->{params} },
      { name => 'context', type => 'text', format_str => 's' },
      { name => 'context_identity', type => 'text', format_str => 's', internal => 1 };
    $diag->{message_template}{en}                = '%{word} %{context}';
    $diag->{operation_words}{context}            = Storable::dclone( $diag->{operation_words}{word} );
    $diag->{operation_words}{context}{source}    = 'context_identity';
    $diag->{operation_words}{context}{selectors} = { gender => 'context_gender', initial => 'context_initial' };
    Diag::Words::normalize_selectors( $diag, $data );
    my $model = Diag::Words::compile( [$diag], $data );
    my %ids   = map { $model->{operations}[$_] => $_ + 1 } 0 .. $#{ $model->{operations} };
    my $ru    = $model->{languages}{ru};
    my ( $word, $context ) = @{ $ru->{bindings}{WORD_CONTRACT_FIXTURE} };
    is( $word->{mask},    '00000000ffff0000', 'first displayed word owns its own grammatical fields' );
    is( $context->{mask}, '000000000000ffff', 'second word does not clear the first word fields' );
    is( $ru->{values}[ $word->{map}[ $ids{add} ] ]{key},
        '0000000000040000', 'first word gets its independently positioned category' );
    is( $ru->{values}[ $context->{map}[ $ids{add} ] ]{key},
        '0000000000000004', 'second word gets the same category in another field' );
}
my $diagnostic = diagnostic();
ok( Diag::Words::validate_bindings( $diagnostic, $data ), 'rules bind retained identity and independent outputs' );
my $before = snapshot($data);
my $ru     = Diag::Words::resolve_word( $data, 'ru', 'add', 'subject' );
is( $ru->{text},              'сложение', 'Russian rule selects the nominative word' );
is( $ru->{selectors}{gender}, 'neuter',   'Russian rule independently selects gender' );
is( $ru->{status},            'resolved', 'available word form resolves' );
is( Diag::Words::resolve_word( $data, 'ru', 'add', 'of_operation' )->{text},
    'сложения', 'another rule selects another form of the same operation' );
my $cy = Diag::Words::resolve_word( $data, 'cy', 'add', 'mutated' );
is( $cy->{text},               'cy:add:soft', 'Welsh fixture selects its language-local mutation form' );
is( $cy->{selectors}{initial}, 'changes',     'Welsh uses a different selector dimension' );
is( Diag::Words::resolve_word( $data, 'en', 'add', 'operation' )->{text},
    'addition (+)', 'English needs no grammatical selector or gender tag' );
is( scalar keys %{ Diag::Words::resolve_word( $data, 'en', 'add', 'operation' )->{selectors} },
    0, 'English rule emits no artificial grammatical category' );

my $after = snapshot($data);
ok( $before eq $after, 'resolving several languages does not modify vocabulary data' );
my $domains = Diag::Words::binding_selector_domains( $diagnostic, $data );
is(
    join( ',', @{ $domains->{word_gender} } ),
    'common,feminine,masculine,neuter',
    'grammatical domain is the union of language rule values'
);
is( join( ',', @{ $domains->{word_initial} } ), 'changes,unchanged', 'a different property retains its own domain' );
ok(
    !grep( /nominative|genitive|soft_mutation/, map { @$_ } values %$domains ),
    'requested forms do not become grammatical selector values'
);

{
    my $diag = diagnostic();
    push @{ $diag->{params} },
      { name => 'context', type => 'text', format_str => 's' },
      { name => 'context_identity', type => 'text', format_str => 's', internal => 1 };
    $diag->{message_template}{en}     = '%{word} %{context}';
    $diag->{operation_words}{context} = Storable::dclone( $diag->{operation_words}{word} );
    my $binding = $diag->{operation_words}{context};
    $binding->{source}    = 'context_identity';
    $binding->{selectors} = { gender => 'context_gender', initial => 'context_initial' };
    my $domains = Diag::Words::binding_selector_domains( $diag, $data );
    is( scalar keys %$domains, 4, 'two words retain independent grammatical selector dimensions' );
    is(
        join( ',', @{ $domains->{context_gender} } ),
        join( ',', @{ $domains->{word_gender} } ),
        'equivalent dimensions share values without conflating the words'
    );
}

my $literal = Diag::Words::resolve_word( $data, 'ru', 'prtf', 'subject' );
is( $literal->{text},              'printf',  'literal keyword alias stays literal' );
is( $literal->{status},            'literal', 'literal text has a distinct resolution status' );
is( $literal->{selectors}{gender}, '*',       'literal keyword does not acquire an invented gender' );
my $opaque = Diag::Words::resolve_word( $data, 'ru', 'extension_operation', 'subject', 'extension prose' );
is( $opaque->{text},   'extension prose', 'opaque extension text is preserved' );
is( $opaque->{status}, 'opaque',          'opaque text is distinguishable from translated vocabulary' );
is( Diag::Words::resolve_word( $data, 'ru', 'extension_operation', 'subject' )->{status},
    'unknown_operation', 'unknown identity without supplied text stays unavailable' );
is( Diag::Words::resolve_word( $data, 'ru', 'multiply', 'subject' )->{status},
    'missing_word', 'missing translation is not silently replaced with English' );
is( Diag::Words::resolve_word( $data, 'ru', 'concat', 'of_operation' )->{status},
    'missing_form', 'missing requested form is explicit' );
is( Diag::Words::resolve_word( $data, 'not_registered', 'add', 'subject' )->{status},
    'unknown_language', 'unknown language is reported without English fallback' );
{
    local $data->{languages}{ru}{words}{add}{tags} = {};
    is( Diag::Words::resolve_word( $data, 'ru', 'add', 'subject' )->{selectors}{gender},
        '*', 'missing tag uses the declared rule fallback' );
}

# Declaring a form does not require it on every word. Actual rule use does.
{
    my $copy = fixture();
    $copy->{languages}{ru}{words}{add}{forms} = { genitive => 'сложения' };
    ok( Diag::Words::validate($copy), 'unused base form need not be present on a partial translated word' );
    my $diag = diagnostic();
    $diag->{operation_words}{word}{rules}{ru} = 'of_operation';
    $diag->{operation_words}{word}{operations} = ['add'];
    ok( Diag::Words::validate_bindings( $diag, $copy ), 'application validates only the form its rule requests' );
    $diag->{operation_words}{word}{rules}{ru} = 'subject';
    eval { Diag::Words::validate_bindings( $diag, $copy ); 1 };
    like(
        $@,
        qr/WORD_CONTRACT_FIXTURE.*word.*language ru operation add rule subject needs form nominative/,
        'missing required form error identifies diagnostic, parameter, language, operation and rule'
    );
}
{
    my $diag = diagnostic();
    $diag->{operation_words}{word}{rules}{ru} = 'of_operation';
    eval { Diag::Words::validate_bindings( $diag, $data ); 1 };
    like( $@, qr/language ru operation concat.*needs form genitive/, 'all bound operations are checked' );
}

# Each malformed fixture is isolated so one failure cannot mask another check.
my @invalid_profiles = (
    [ 'undeclared base form', sub { $_[0]{languages}{ru}{base_form} = 'unknown' }, qr/ru needs a declared base_form/ ],
    [ 'duplicate form', sub { push @{ $_[0]{languages}{ru}{forms} }, 'nominative' }, qr/duplicate name nominative/ ],
    [
        'undeclared word form',
        sub { $_[0]{languages}{ru}{words}{add}{forms}{unknown} = 'text' },
        qr/ru\/add has undeclared form unknown/
    ],
    [
        'undeclared word tag',
        sub { $_[0]{languages}{ru}{words}{add}{tags}{unknown} = 'value' },
        qr/ru\/add has undeclared tag unknown/
    ],
    [
        'undeclared tag value',
        sub { $_[0]{languages}{ru}{words}{add}{tags}{gender} = 'unknown' },
        qr/tag gender has an undeclared value/
    ],
    [
        'undeclared rule form',
        sub { $_[0]{languages}{ru}{rules}{subject}{form} = 'unknown' },
        qr/rule subject requests an undeclared form/
    ],
    [
        'undeclared rule tag',
        sub { $_[0]{languages}{ru}{rules}{subject}{select}{gender}{tag} = 'unknown' },
        qr/output gender reads an undeclared tag/
    ],
    [
        'invalid fallback',
        sub { $_[0]{languages}{ru}{rules}{subject}{select}{gender}{fallback} = 'unknown' },
        qr/output gender has an invalid fallback/
    ],
    [
        'unsupported conditional rule',
        sub { $_[0]{languages}{ru}{rules}{subject}{cases} = [] },
        qr/unknown field cases/
    ],
    [
        'unknown opcode',
        sub { $_[0]{languages}{ru}{words}{unknown_operation} = { forms => { nominative => 'text' } } },
        qr/not a known operation/
    ],
    [
        'translated literal alias',
        sub { $_[0]{languages}{ru}{words}{prtf} = { forms => { nominative => 'text' } } },
        qr/literal keyword, not a description/
    ],
    [ 'invalid status', sub { $_[0]{languages}{ru}{words}{add}{status} = 'unknown' }, qr/invalid status/ ],
    [
        'fixed custom description',
        sub { $_[0]{languages}{ru}{words}{custom} = { forms => { nominative => 'fixed description' } } },
        qr/opaque, not a fixed description/
    ],
    [ 'unknown opaque identity', sub { push @{ $_[0]{opaque_operations} }, 'unknown' }, qr/unknown opaque operation/ ],
    [ 'overlapping classification', sub { push @{ $_[0]{opaque_operations} }, 'prtf' }, qr/both literal and opaque/ ],
    [ 'wrong data version',         sub { $_[0]{version} = 1 }, qr/unsupported operation vocabulary version/ ],
);
for my $case (@invalid_profiles) {
    my ( $label, $change, $expected ) = @$case;
    my $copy = fixture();
    $change->($copy);
    eval { Diag::Words::validate($copy); 1 };
    like( $@, $expected, "reject $label" );
}
my @invalid_bindings = (
    [
        'missing retained source',
        sub { $_[0]{operation_words}{word}{source} = 'missing' },
        qr/no retained identity source/
    ],
    [
        'invalid bound flag',
        sub { $_[0]{operation_words}{word}{assert_unknown} = 2 },
        qr/assert_unknown must be 0 or 1/
    ],
    [ 'noninternal identity', sub { $_[0]{params}[1]{internal} = 0 }, qr/no retained identity source/ ],
    [
        'unknown operation',
        sub { $_[0]{operation_words}{word}{operations} = ['unknown'] },
        qr/unknown operation unknown/
    ],
    [
        'unknown language',
        sub { $_[0]{operation_words}{word}{rules}{unknown} = 'subject' },
        qr/unknown language unknown/
    ],
    [ 'unknown rule',    sub { $_[0]{operation_words}{word}{rules}{ru} = 'unknown' },    qr/language ru has no rule/ ],
    [ 'unmapped output', sub { delete $_[0]{operation_words}{word}{selectors}{gender} }, qr/unmapped output gender/ ],
    [
        'unused output',
        sub { $_[0]{operation_words}{word}{selectors}{unused} = 'word_unused' },
        qr/unused selector output unused/
    ],
    [
        'shared selector',
        sub { $_[0]{operation_words}{word}{selectors}{initial} = 'word_gender' },
        qr/shares selector word_gender/
    ],
    [ 'old global form field', sub { $_[0]{operation_words}{word}{form} = 'default' }, qr/unknown field form/ ],
    [
        'producer selector collision',
        sub {
            $_[0]{message_selectors} = ['word_gender'];
            $_[0]{selector_definitions} =
              [ { name => 'word_gender', source => 'identity', values => [qw(add concat)] } ];
        },
        qr/output word_gender conflicts with a producer selector/,
    ],
);
for my $case (@invalid_bindings) {
    my ( $label, $change, $expected ) = @$case;
    my $copy = diagnostic();
    $change->($copy);
    eval { Diag::Words::validate_bindings( $copy, $data ); 1 };
    like( $@, $expected, "reject $label" );
}

my $copy = diagnostic();
$copy->{params}[1]{type} = 'uv';
ok( Diag::Words::validate_bindings( $copy, $data ), 'identity source permits a retained numeric representation' );

{
    our ( $CONF, $META );
    do './diag_conf.pl' or die $@ || $!;
    my ($diag) = grep { $_->{number} == 1419 } @{ Diag::Migration::diagnostics($CONF) };
    my $layout = Diag::Migration::template_parameter_layout($diag);
    for my $column ( 0, 1 ) {
        my $role    = $column ? 'context' : 'target';
        my $binding = $diag->{operation_words}{$role};
        ok(
            $binding->{operations} == $META->{ 'lvalue_word_' . $role },
            "$role word domain reloads from shared metadata"
        );
        ok( !@{ $diag->{message_selectors} || [] },                     "$role identity consumes no selector field" );
        ok( exists $layout->{diagnostic_indices}{ $binding->{source} }, "$role identity is retained" );
        ok( exists $layout->{canonical_indices}{ $binding->{source} }, "$role identity has a canonical source index" );
        ok( exists $layout->{canonical_indices}{$role}, "$role target has a canonical source index" );
    }
    my ($display_params) = Diag::Migration::template_case_parameter_layout(
        $diag, Diag::Migration::template_cases( $diag, 'en' )->[0]{template} );
    is( scalar @$display_params, 2, 'each lvalue case keeps its two display parameters' );
    is( $layout->{stored_count},              4, 'schema migration reuses the four existing retained parameters' );
    ok( Diag::Words::validate_bindings($diag), 'reloaded shipped bindings satisfy the complete contract' );

    # Check that the activated pilot binds the intended grammatical roles.
    my $roles = Storable::dclone($diag);
    for my $language ( sort keys %{ $catalog->{languages} } ) {
        my $target_rule =
            $language eq 'zh'                                                                ? 'default'
          : $language eq 'fi'                                                                ? 'operation_object'
          : $language eq 'he' || $language eq 'hu' || $language eq 'tr'                      ? 'operation'
          : $language eq 'ar' || $language eq 'en' || $language eq 'cy' || $language eq 'fa' ? 'operation'
          : $language eq 'de'                                                                ? 'accusative'
          : $language eq 'is'                                                                ? 'dative'
          : $language eq 'ru' || $language eq 'uk' || $language eq 'sr'                        ? 'accusative'
          :                                                               'indefinite';
        my $context_rule =
            $language eq 'fi'                      ? 'operation'
          : $language eq 'cy'                      ? 'soft_mutation'
          : $language eq 'ru'                      ? 'prepositional'
          : $language eq 'uk' || $language eq 'sr' ? 'locative'
          : $language eq 'de' || $language eq 'is' ? 'dative'
          :                                          $target_rule;
        is( $roles->{operation_words}{target}{rules}{$language},  $target_rule,  "$language binds the target role" );
        is( $roles->{operation_words}{context}{rules}{$language}, $context_rule, "$language binds the context role" );
        ok( Diag::Words::validate_bindings( $roles, $catalog ), "$language forms cover both lvalue roles" );
        my @unavailable;
        for my $role (qw(target context)) {
            my $binding = $roles->{operation_words}{$role};
            for my $operation ( @{ $binding->{operations} } ) {
                my $word = Diag::Words::resolve_word( $catalog, $language, $operation, $binding->{rules}{$language} );
                push @unavailable, "$role/$operation" unless $word->{status} eq 'resolved';
            }
        }
        is( join( ',', @unavailable ), '', "$language resolves every audited target/context phrase" );
    }
}

# Retain semantic expected-type selection while removing descriptor products.
{
    our ( $CONF, $META );
    do './diag_conf.pl' or die $@ || $!;
    for my $diag ( @{ Diag::Migration::diagnostics($CONF) } ) {
        next
          unless $diag->{number} =~
/^(?:1209|1223|1533|1534|1538|1540|1541|2236|2369|2245|2249|1186|1195|1404|1405|1406|1417|1420|1423|1424|1425|2122|2166|2127|2146|2165)$/;
        my $expected = $diag->{number} == 1417 ? 10 : 1;
        ok( Diag::Words::validate_bindings($diag), "$diag->{number} has valid word bindings" );
        my $grammar_cases = 1;
        for my $definition ( @{ $diag->{selector_definitions} || [] } ) {
            $grammar_cases *= 1 + @{ $definition->{values} } if $definition->{operation_word};
        }
        for my $language ( sort keys %{ $catalog->{languages} } ) {
            my $count = scalar @{ Diag::Migration::template_cases( $diag, $language ) };
            cmp_ok( $count, '>=', 1, "$diag->{number}/$language has sentence coverage" );
            cmp_ok(
                $count, '<=',
                $expected * $grammar_cases,
                "$diag->{number}/$language expands semantic and grammatical cases only"
            );
        }
        my @selectors = map { $_->{name} }
          grep { !$_->{operation_word} } @{ $diag->{selector_definitions} || [] };
        is(
            join( ',', @selectors ),
            $expected == 10 ? 'expected_kind' : '',
            "$diag->{number} keeps word identities outside selector fields"
        );
    }
}

# Byte-count, position and operation-context cases remain independent of words.
{
    our ( $CONF, $META );
    do './diag_conf.pl' or die $@ || $!;
    my %wanted = map { $_ => 1 } ( 2309, 2311, 2314, 2315, 2316, 2357, 2358, 2618 .. 2629 );
    for my $diag ( @{ Diag::Migration::diagnostics($CONF) } ) {
        next unless $wanted{ $diag->{number} };
        ok( Diag::Words::validate_bindings($diag), "$diag->{number} has valid UTF-8 word bindings" );
        ok( !grep( { $_ eq 'operation_name' } @{ $diag->{message_selectors} || [] } ),
            "$diag->{number} removes its descriptor selector" );
        for my $language ( sort keys %{ $catalog->{languages} } ) {
            cmp_ok( scalar @{ Diag::Migration::template_cases( $diag, $language ) },
                '<=', 8, "$diag->{number}/$language keeps only byte/context sentence cases" );
        }
    }
}

# The remaining large families separate semantic cases from word identity.
{
    our ( $CONF, $META );
    do './diag_conf.pl' or die $@ || $!;
    for my $diag ( @{ Diag::Migration::diagnostics($CONF) } ) {
        next unless $diag->{number} =~ /^(?:2072|2119|2250)$/;
        ok( Diag::Words::validate_bindings($diag), "$diag->{number} has valid semantic/word bindings" );
        my $is_void = $diag->{number} != 2250;
        is(
            join( ',', @{ $diag->{message_selectors} } ),
            $is_void ? 'op_name' : 'name_state',
            "$diag->{number} retains only its semantic selector"
        );
        if ($is_void) {
            is(
                join( ',', @{ $diag->{selector_definitions}[0]{values} } ),
'anonymous_array,anonymous_hash,constant,constant_undef,literal,negative_pattern_binding,non_destructive_substitution,non_destructive_transliteration,time,variable',
                "$diag->{number} retains semantic cases and the explicit keyword override"
            );
            is( $diag->{operation_words}{arg1}{rules}{en},
                'void_expression', "$diag->{number} preserves its English contextual word form" );
        }
        for my $language ( sort keys %{ $catalog->{languages} } ) {
            cmp_ok(
                scalar @{ Diag::Migration::template_cases( $diag, $language ) },
                '<=',
                $is_void ? 10 : 2,
                "$diag->{number}/$language has no descriptor expansion"
            );
        }
    }
}
