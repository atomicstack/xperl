use strict;
use warnings;

BEGIN {
    chdir 't' if -d 't';

    package XPerlDiagPackTest;
    require './test.pl';
    $XPerlDiagPackTest::NO_ENDING = 1;
    XPerlDiagPackTest::set_up_inc('../lib');

    *main::ok           = \&XPerlDiagPackTest::ok;
    *main::is           = \&XPerlDiagPackTest::is;
    *main::isnt         = \&XPerlDiagPackTest::isnt;
    *main::like         = \&XPerlDiagPackTest::like;
    *main::unlike       = \&XPerlDiagPackTest::unlike;
    *main::skip         = \&XPerlDiagPackTest::skip;
    *main::plan         = \&XPerlDiagPackTest::plan;
    *main::done_testing = \&XPerlDiagPackTest::done_testing;
    *main::diag         = \&XPerlDiagPackTest::diag;
}

use Config;
use B ();
use builtin qw(cardinal_plural_form get_diagnostic_data ordinal_plural_form);
no warnings 'experimental::builtin';

my @languages              = qw(ar cy de en es fa fi fr he hu is it nl pt ru sr tr uk);
my $initial_render_default = ${^DIAG_RENDER};
my %packs;
my %load_default;
my %load_error;
my %selected      = map { $_ => 1 } $Config{extensions} =~ m{XPerl/DiagPack/([A-Z][A-Z0-9_]*)}g;
my %test_language = map { $_ => 1 } @languages;
$test_language{ lc $_ } = 1 for keys %selected;
my @test_languages = sort keys %test_language;

for my $language (@test_languages) {
    my $module = 'XPerl::DiagPack::' . uc $language;
    ( my $file = "$module.pm" ) =~ s{::}{/}g;
    unless ( eval { require $file; 1 } ) {
        $load_error{$language} = $@;
        next;
    }
    $packs{$language}        = $module;
    $load_default{$language} = ${^DIAG_RENDER};
}

plan( skip_all => 'no optional diagnostic language packs are installed' )
  unless keys %packs || grep { $selected{ uc $_ } } @test_languages;

for my $language (@test_languages) {
    next unless $selected{ uc $language };
    ok( $packs{$language}, "configured XPerl::DiagPack::" . uc($language) . ' is loadable' );
    diag( $load_error{$language} ) unless $packs{$language};
}

for my $language ( sort keys %packs ) {
    my $module = $packs{$language};
    is( $load_default{$language}, $initial_render_default, "loading $module does not change the selected language" );
    my $metadata = $module->metadata;
    is( $metadata->{language},    $language, "$module remains bound to its own language descriptor" );
    is( $metadata->{abi_version}, 5,         "$module reports the shared descriptor ABI" );
}

{
    my $selected = eval q{ use diagpack 'de'; 1 };
    ok( $selected, 'diagpack loads a language and installs a lexical hint' );
    is( ${^DIAG_RENDER}, $initial_render_default,
        'diagpack does not change the mutable rendering default' );
    ok( $INC{'XPerl/DiagPack/DE.pm'}, 'diagpack loaded the matching language module' );
}

{
    local $ENV{PERL_DIAG_RENDER} = 'de:legacy';
    is(
        XPerlDiagPackTest::runperl( prog => 'print exists $INC{q[XPerl/DiagPack/DE.pm]} ? q[loaded] : q[missing]' ),
        'loaded', 'startup loads the pack named by PERL_DIAG_RENDER'
    );
}

{
    local $ENV{LC_ALL} = 'C.UTF-8';
    local $ENV{PERL_DIAG_RENDER} = 'auto:legacy';
    is(
        XPerlDiagPackTest::runperl( prog => 'print exists $INC{q[XPerl/DiagPack/C.pm]} ? q[loaded] : q[english]' ),
        'english', 'C.UTF-8 startup uses built-in English without loading a C pack'
    );
}

{
    local $ENV{PERL_DIAG_RENDER} = 'en:legacy';
    is(
        XPerlDiagPackTest::runperl(
            prog => 'no warnings q[experimental::builtin]; '
              . 'use builtin qw(cardinal_plural_form ordinal_plural_form); '
              . 'print cardinal_plural_form(q[fr], 1), q[|], '
              . 'ordinal_plural_form(q[fr], 1), q[|], '
              . '(exists $INC{q[XPerl/DiagPack/FR.pm]} ? q[loaded] : q[none])'
        ),
        'one|one|none', 'plural helpers cover French without loading its pack'
    );
}

{
    local $ENV{LC_ALL} = 'C.UTF-8';
    local $ENV{PERL_DIAG_RENDER} = 'auto:legacy';
    is(
        XPerlDiagPackTest::runperl(
            prog => 'use XPerl::DiagPack; print exists $INC{q[XPerl/DiagPack/DE.pm]} ? q[loaded] : q[none]'
        ),
        'none', 'bare umbrella import does not load optional packs'
    );
    is(
        XPerlDiagPackTest::runperl(
            prog => 'BEGIN { unshift @INC, sub { '
              . 'die q[unexpected EN load] if $_[1] eq q[XPerl/DiagPack/EN.pm]; return } } '
              . 'use diagpack q[en]; print q[ok]'
        ),
        'ok', 'the English pragma works without loading the optional EN pack'
    );
}

{
    local $ENV{PERL_DIAG_RENDER} = 'zz:legacy';
    my $output = XPerlDiagPackTest::runperl( prog => 'print ${^DIAG_RENDER}', stderr => 1 );
    like( $output, qr/Warning: unable to load diagnostic language pack 'zz'/,
        'startup reports an unavailable requested pack' );
    like( $output, qr/zz:legacy/,
        'startup keeps the requested rendering setting after load failure' );
}

{
    local $ENV{PERL_DIAG_RENDER} = 'de:legacy';
    is(
        XPerlDiagPackTest::runperl(
            switches => ['-T'],
            prog => 'print exists $INC{q[XPerl/DiagPack/DE.pm]} ? q[loaded] : q[missing]'
        ),
        'missing', 'tainted startup does not load a non-English pack from the environment'
    );
}

{
    my $loaded = eval q{ use XPerl::DiagPack qw(all); 1 };
    ok( $loaded, 'the diagnostic-pack umbrella loads all installed languages' );
    is( ${^DIAG_RENDER}, $initial_render_default,
        'loading the diagnostic-pack umbrella does not select a language' );
}

my $plural_schema = get_diagnostic_data(2630);
my $dynamic_schema = get_diagnostic_data(1436);
is( $dynamic_schema->{parameter_layout}{stored_parameter_count},
    $dynamic_schema->{parameter_layout}{captured_parameter_count},
    'inspection retains parameter counts for diagnostics without an English row' );
my ($count_selector) = grep { $_->{name} eq 'count' } @{ $plural_schema->{selectors} };
ok( grep { $_ eq '1' } @{ $count_selector->{exact_numeric_values} },
    'inspection keeps exact-count cases declared by translated languages' );
my $foreign_exact_case = 0;
for my $language (qw(pt ru uk)) {
    for my $case ( @{ $plural_schema->{translations}{$language}{cases} || [] } ) {
        $foreign_exact_case ||= grep {
            $_->{selector} eq 'count' && $_->{value} eq '1'
        } @{ $case->{selector_criteria} };
    }
}
ok( $foreign_exact_case,
    'inspection decodes translated exact-count cases using each language domain' );

is( ${^DIAG_RENDER}, $initial_render_default, 'loading all available packs leaves the selected language unchanged' );

SKIP: {
    skip 'Serbian diagnostic pack is unavailable', 8 unless $packs{sr};

    my $runtime = eval q{
        use diagpack 'sr';
        my $zero = 0;
        eval { my $result = 1 / $zero };
        $@;
    };
    ok( $runtime && ref $runtime, 'a runtime error captures the Serbian pack lexically' );
    my $legacy = $runtime->render_as_legacy('sr');
    like( $legacy, qr/[\x{0400}-\x{04FF}]/, 'Serbian errors use Cyrillic' );
    {
        local ${^DIAG_RENDER} = 'en:legacy';
        is( $runtime->render, $legacy, 'implicit rendering retains the captured Serbian pack' );
        isnt( $legacy, $runtime->render_as_legacy('en'), 'Serbian rendering differs from English' );
    }
    require JSON::PP;
    my $record = JSON::PP->new->decode( $runtime->render('sr:legacy:JSON') );
    is( $record->{message}, $legacy, 'structured output retains the Serbian message' );
    ok( utf8::is_utf8($legacy), 'Serbian text retains decoded Unicode characters' );
    is( join(',', map { cardinal_plural_form('sr', $_) } (0, 1, 2, 11, 12, 21, 22)),
        'other,one,few,other,other,one,few', 'Serbian cardinal rules handle teen exceptions' );
    is( join(',', map { ordinal_plural_form('sr', $_) } (1, 2, 21)),
        'other,other,other', 'Serbian ordinal counts use other' );
}

SKIP: {
    skip 'Persian diagnostic pack is unavailable', 8 unless $packs{fa};

    {
        local $ENV{PERL_DIAG_RENDER} = 'fa:legacy';
        my $startup = XPerlDiagPackTest::runperl(
            switches => ['-CS'],
            prog     => q{
                my $zero = 0;
                eval { my $result = 1 / $zero };
                my $exception = $@;
                print exists $INC{q[XPerl/DiagPack/FA.pm]} ? qq[loaded\n] : qq[missing\n];
                print $exception;
            }
        );
        utf8::decode($startup) unless utf8::is_utf8($startup);
        like( $startup, qr/^loaded\n/,           'startup loads the Persian pack' );
        like( $startup, qr/[\x{0600}-\x{06FF}]/, 'startup renders a runtime error in Persian' );
    }

    my $runtime = eval q{
        use diagpack 'fa';
        my $zero = 0;
        eval { my $result = 1 / $zero };
        $@;
    };
    ok( $runtime && ref $runtime, 'a runtime error captures the Persian pack lexically' );
    {
        local ${^DIAG_RENDER} = 'en:legacy';
        is(
            $runtime->render,
            $runtime->render_as_legacy('fa'),
            'implicit rendering keeps Persian after the default changes to English'
        );
        isnt(
            $runtime->render,
            $runtime->render_as_legacy('en'),
            'an explicit English render overrides the captured Persian language'
        );
    }

    my $hook_warning;
    {
        local $SIG{__WARN__} = sub { $hook_warning = $_[0] };
        eval q{
            use diagpack 'fa';
            use warnings 'uninitialized';
            my $value;
            my $number = $value + 1;
        };
    }
    like( $hook_warning, qr/[\x{0600}-\x{06FF}]/, 'the warning hook receives the rendered Persian message' );

    require JSON::PP;
    my $legacy = $runtime->render_as_legacy('fa');
    my $record = JSON::PP->new->decode( $runtime->render('fa:legacy:JSON') );
    is( $record->{message}, $legacy,
        'the structured human message matches the Persian legacy text in logical Unicode order' );
    ok( utf8::is_utf8($legacy), 'Persian legacy text retains its decoded Unicode characters' );
}

SKIP: {
    skip 'German and French diagnostic packs are unavailable', 18
      unless $packs{de} && $packs{fr};

    my $schema   = get_diagnostic_data(1429);
    my $captured = eval q{
        use diagpack 'de';
        XPerl::Diagnostic->_new({
            code => $schema->{code},
            number => $schema->{number},
            kind => $schema->{kind},
            severity => $schema->{severity},
            params => [ { name => 'keyword', type => 'text', value => 'use' } ],
        });
    };
    ok( $captured, 'a diagnostic constructed in a lexical pack scope is captured' );
    local ${^DIAG_RENDER} = 'fr:legacy';
    is(
        $captured->render,
        $packs{de}->render($captured),
        'implicit rendering uses the captured engine after the default changes'
    );
    is(
        $captured->render_as_legacy('fr'),
        $packs{fr}->render($captured),
        'an explicit render language overrides the captured engine'
    );

    my $runtime = eval q{
        use diagpack 'de';
        my $zero = 0;
        eval { my $quotient = 1 / $zero };
        $@;
    };
    ok( $runtime && ref $runtime, 'a runtime error captures the lexical pack engine' );
    is(
        $runtime->render,
        $runtime->render_as_legacy('de'),
        'implicit exception rendering uses the runtime diagnostic capture'
    );
    is(
        $runtime->render('fr:legacy'),
        $runtime->render_as_legacy('fr'),
        'an explicit exception language overrides captured diagnostics'
    );
    isnt(
        $runtime->render,
        $runtime->render('fr:legacy'),
        'the scoped and explicitly overridden exception languages differ'
    );

    my $parser = eval q{
        use diagpack 'de';
        eval q{ my $broken = ; };
        $@;
    };
    ok( $parser && ref $parser, 'a parser error is captured in a lexical pack scope' );
    is(
        $parser->render,
        $parser->render_as_legacy('de'),
        'implicit parser exception rendering uses its captured engine'
    );

    my ( $outer, $inner, $restored );
    my $nested = eval q{
        use diagpack 'de';
        $outer = XPerl::Diagnostic->_new({
            code => $schema->{code}, number => $schema->{number},
            kind => $schema->{kind}, severity => $schema->{severity},
            params => [ { name => 'keyword', type => 'text', value => 'use' } ],
        });
        {
            use diagpack 'fr';
            $inner = XPerl::Diagnostic->_new({
                code => $schema->{code}, number => $schema->{number},
                kind => $schema->{kind}, severity => $schema->{severity},
                params => [ { name => 'keyword', type => 'text', value => 'use' } ],
            });
        }
        $restored = XPerl::Diagnostic->_new({
            code => $schema->{code}, number => $schema->{number},
            kind => $schema->{kind}, severity => $schema->{severity},
            params => [ { name => 'keyword', type => 'text', value => 'use' } ],
        });
        1;
    };
    ok( $nested, 'nested pragma scopes compile successfully' );
    is( $outer->render,    $packs{de}->render($outer),    'outer lexical pack selection is captured' );
    is( $inner->render,    $packs{fr}->render($inner),    'nested lexical pack selection is captured' );
    is( $restored->render, $packs{de}->render($restored), 'leaving a nested scope restores its parent selection' );

    my $tree         = $outer->derive( [ $inner, $restored ] );
    my $tree_text    = $tree->render;
    my $german_body  = $packs{de}->render($outer);
    my $french_body  = $packs{fr}->render($inner);
    my $german_count = () = $tree_text =~ /\Q$german_body\E/g;
    my $french_count = () = $tree_text =~ /\Q$french_body\E/g;
    is( $german_count, 2, 'the implicit tree retains both German record captures' );
    is( $french_count, 1, 'the implicit tree retains its French child capture' );
    my $explicit_tree  = $tree->render_as_legacy('fr');
    my $explicit_count = () = $explicit_tree =~ /\Q$french_body\E/g;
    is( $explicit_count, 3, 'explicit French applies to every record in the tree' );
    unlike( $explicit_tree, qr/\Q$german_body\E/, 'the explicit tree rendering contains no captured German wording' );

    my $hook_warning;
    {
        local $SIG{__WARN__} = sub { $hook_warning = $_[0] };
        eval q{
            use diagpack 'de';
            use warnings 'uninitialized';
            my $value;
            my $number = $value + 1;
        };
    }
    like( $hook_warning, qr/Verwendung|uninitialisiert/, 'the legacy warning hook receives the scoped German message' );
}

SKIP: {
    skip 'German diagnostic pack is unavailable', 2 unless $packs{de};
    skip 'XS::APItest is not built',              2 unless eval { require XS::APItest; 1 };
    my $schema   = get_diagnostic_data(1429);
    my $captured = eval q{
        use diagpack 'de';
        XPerl::Diagnostic->_new({
            code => $schema->{code}, number => $schema->{number},
            kind => $schema->{kind}, severity => $schema->{severity},
            params => [ { name => 'keyword', type => 'text', value => 'use' } ],
        });
    };
    my $original = $captured->render;
    XS::APItest::diagpack_test_override( 'de', 2 );
    is( $captured->render, $original, 'a captured descriptor survives replacement of its language registry entry' );
    is(
        $captured->render_as_legacy('de'),
        'registered English replacement',
        'an explicit language lookup uses the replacement engine'
    );
    XS::APItest::diagpack_test_restore('de');
}

{

    package DiagPackRenderFetch;
    our $fetches = 0;
    our $on_fetch;
    sub TIESCALAR { bless {}, shift }
    sub FETCH     { $fetches++; $on_fetch->() if $on_fetch; return "use" }
}

my $fetch_diagnostic = bless {
    code   => 'ERROR_SYNTAX_DECLARATION_USE_NO_IN_EXPRESSION',
    number => 1429,
    params => [ { name => 'keyword', type => 'text', value => undef } ],
  },
  'XPerl::Diagnostic';
tie $fetch_diagnostic->{params}[0]{value}, 'DiagPackRenderFetch';
$DiagPackRenderFetch::fetches = 0;
ok( defined $fetch_diagnostic->render_as_legacy('en'), 'core rendering accepts a tied semantic value' );
is( $DiagPackRenderFetch::fetches, 1, 'core rendering fetches each tied semantic value once' );
my ($fetch_language) = sort keys %packs;
$DiagPackRenderFetch::fetches = 0;
ok(
    defined $packs{$fetch_language}->render($fetch_diagnostic),
    "$fetch_language pack rendering accepts a tied semantic value"
);
is( $DiagPackRenderFetch::fetches, 1, "$fetch_language pack rendering snapshots a tied semantic value once" );
untie $fetch_diagnostic->{params}[0]{value};

for my $target ( 'core', $fetch_language ) {
    $fetch_diagnostic->{params} = [ { name => 'keyword', type => 'text', value => undef } ];
    tie $fetch_diagnostic->{params}[0]{value}, 'DiagPackRenderFetch';
    local $DiagPackRenderFetch::on_fetch = sub { $fetch_diagnostic->{params} = [] };
    my $rendered =
        $target eq 'core'
      ? $fetch_diagnostic->render_as_legacy('en')
      : $packs{$target}->render($fetch_diagnostic);
    ok( defined $rendered && length $rendered, "$target rendering survives FETCH replacing the source array" );
    is( scalar @{ $fetch_diagnostic->{params} }, 0, "$target FETCH replaced the source array" );
}

my $keyword         = pack 'U', 0xFC;
my $text_diagnostic = bless {
    code   => 'ERROR_SYNTAX_DECLARATION_USE_NO_IN_EXPRESSION',
    number => 1429,
    params => [ { name => 'keyword', type => 'text', value => $keyword } ],
  },
  'XPerl::Diagnostic';
my $stored_keyword     = $text_diagnostic->{params}[0]{value};
my $original_keyword   = "$stored_keyword";
my $original_utf8_flag = utf8::is_utf8($stored_keyword);

my $hooks = 0;
for my $language ( sort keys %packs ) {
    my $module = $packs{$language};
    my ( $rendered, $warned, $died );
    {
        local $SIG{__EXCEPT__} = sub { $hooks++ };
        local $SIG{__WARN__}   = sub { $warned++ };
        local $SIG{__DIE__}    = sub { $died++ };
        $rendered = $module->render($text_diagnostic);
    }
    ok( defined $rendered, "$language directly renders a translated text case" );
    is(
        $rendered,
        $text_diagnostic->render_as_legacy($language),
        "$language direct rendering matches the existing core renderer"
    );
    is( $text_diagnostic->{params}[0]{value},
        $original_keyword, "$language direct rendering preserves the original parameter bytes" );
    is( utf8::is_utf8( $text_diagnostic->{params}[0]{value} ),
        $original_utf8_flag, "$language direct rendering preserves the parameter UTF-8 flag" );
    is( $warned || 0, 0, "$language direct rendering does not invoke warning hooks" );
    is( $died   || 0, 0, "$language direct rendering does not invoke die hooks" );
}
is( $hooks, 0, 'direct rendering does not invoke exception hooks or delivery' );

$text_diagnostic->{params}[0]{value} = 'no';
for my $language ( sort keys %packs ) {
    my $rendered = $packs{$language}->render($text_diagnostic);
    is(
        $rendered,
        $text_diagnostic->render_as_legacy($language),
        "$language rendering uses the edited current parameter value"
    );
}
is( $text_diagnostic->{params}[0]{value}, 'no', 'direct rendering leaves the edited current value intact' );

ok( !defined cardinal_plural_form( 'zz', 1 ), 'unknown cardinal plural language remains undefined' );
ok( !defined ordinal_plural_form( 'zz', 1 ),  'unknown ordinal plural language remains undefined' );

SKIP: {
    my ($poison_language) = grep { $_ ne 'en' } sort keys %packs;
    skip 'registered English and translated packs are unavailable', 16
      unless $packs{en} && $poison_language;
    skip 'XS::APItest is not built', 16 unless eval { require XS::APItest; 1 };

    my $english      = $text_diagnostic->render_as_legacy('en');
    my $early_format = XS::APItest::diagpack_test_format_template('no');
    is( $early_format, $english, 'early English format helper uses the builtin engine' );
    my $english_only_schema     = get_diagnostic_data(2743);
    my $english_only_diagnostic = bless {
        code   => $english_only_schema->{code},
        number => $english_only_schema->{number},
        params => [],
      },
      'XPerl::Diagnostic';
    my $english_only_message = $english_only_diagnostic->render_as_legacy('en');
    is(
        $english_only_message,
        "Invalid diagnostic input for direct rendering\n",
        'the partial-override miss fixture has a real English template'
    );

    my $english_before_bad_registration = $text_diagnostic->render_as_legacy('en');
    for my $mode (1 .. 4) {
        eval { XS::APItest::diagpack_test_bad_catalog( 'en', $mode ); 1 };
        like( $@, qr/invalid diagnostic language pack catalog/,
            "incompatible catalog schema mode $mode is rejected" );
        is( $text_diagnostic->render_as_legacy('en'), $english_before_bad_registration,
            "rejected schema mode $mode preserves the prior capability" );
    }
    ok( eval { XS::APItest::diagpack_test_bad_catalog( 'en', 5 ); 1 },
        'a catalog with seven narrow selectors is accepted' );
    XS::APItest::diagpack_test_restore('en');
    is( $text_diagnostic->render_as_legacy('en'), $english_before_bad_registration,
        'restoring a seven narrow selector catalog exposes the prior capability' );

    my $missing_diagnostic = bless {
        code   => 'WARNING_UNTIE_INNER_REFERENCES_REMAIN',
        number => 2217,
        params => [ { name => 'arg1', type => 'uv', value => 1 } ],
      },
      'XPerl::Diagnostic';
    my $missing_message = $missing_diagnostic->render_as_legacy('en');
    my $subset_schema = get_diagnostic_data(2618);
    my %subset_selector_value = map {
        $_->{source} => $_->{values}[0]
    } grep { !$_->{plural_kind} && @{ $_->{values} || [] } }
      @{ $subset_schema->{selectors} };
    my $subset_diagnostic = bless {
        code   => $subset_schema->{code},
        number => $subset_schema->{number},
        params => [ map {
            my $name = $_->{name};
            { name => $name, type => $_->{type},
              value => exists $subset_selector_value{$name}
                ? $subset_selector_value{$name}
                : $_->{type} eq 'uv' ? 1 : '' }
        } @{ $subset_schema->{parameters} } ],
      },
      'XPerl::Diagnostic';
    XS::APItest::diagpack_test_partial_catalog('en');
    like( $text_diagnostic->render_as_legacy('en'), qr/^partial: /,
        'a pack-local row renders when its local index differs from core ordering' );
    like( $english_only_diagnostic->render_as_legacy('en'), qr/^partial: /,
        'a partial catalog can render a second supplied row' );
    like( $subset_diagnostic->render_as_legacy('en'), qr/^partial: /,
        'registration accepts a pack-local selector subset and order' );
    is( $missing_diagnostic->render_as_legacy('en'), $missing_message,
        'a missing partial-catalog row falls back to permanent builtin English' );
    my $inspected_fallback = get_diagnostic_data(2217)->{translations}{en}{cases};
    ok( $inspected_fallback && @$inspected_fallback,
        'inspection exposes the permanent English row omitted by registered EN' );
    XS::APItest::diagpack_test_restore('en');

    XS::APItest::diagpack_test_override( 'en', 4 );
    is(
        $text_diagnostic->render_as_legacy('en'),
        'registered English partial override',
        'core rendering uses the registered English override'
    );
    is( XS::APItest::diagpack_test_format_template('no'),
        $early_format, 'early format helper bypasses registered English callbacks' );

    eval { XS::APItest::diagpack_test_bad_register('en'); 1 };
    like( $@, qr/invalid diagnostic language pack catalog/, 'invalid replacement is rejected' );
    is(
        $text_diagnostic->render_as_legacy('en'),
        'registered English partial override',
        'rejected registration preserves the prior capability'
    );
    is( $english_only_diagnostic->render_as_legacy('en'),
        $english_only_message, 'partial registered English miss uses permanent built-in English' );
    XS::APItest::diagpack_test_override( 'en', 2 );
    is(
        $text_diagnostic->render_as_legacy('en'),
        'registered English replacement',
        'duplicate registration replaces the language lookup'
    );
    is( cardinal_plural_form( 'en', 1 ), 'one', 'cardinal helper is independent of registered engine callbacks' );
    is( ordinal_plural_form( 'en', 1 ),  'one', 'ordinal helper is independent of registered engine callbacks' );
    XS::APItest::diagpack_test_restore('en');
    is(
        $text_diagnostic->render_as_legacy('en'),
        'registered English partial override',
        'restoring a duplicate registration exposes the preceding capability'
    );
    XS::APItest::diagpack_test_restore('en');
    my $explicit_key_diagnostic = bless {
        code   => 'ERROR_OVERLOAD_CONSTANT_CONVERSION_FAILED',
        number => 1435,
        params => [
            { name => 'reason',        type => 'text', value => 'handler_returned_undefined' },
            { name => 'constant',      type => 'text', value => '42' },
            { name => 'overload_type', type => 'text', value => 'integer' },
        ],
      },
      'XPerl::Diagnostic';
    is(
        XS::APItest::diagpack_test_render_template( 1435, 1, [ 'unknown', '42', 'integer' ], 'en' ),
        $explicit_key_diagnostic->render_as_legacy('en'),
        'format vectors use declaration order with an explicit selector key'
    );

    XS::APItest::diagpack_test_override( 'en', 3 );
    is( cardinal_plural_form( 'en', 1 ), 'one', 'invalid pack callback does not affect cardinal queries' );
    is( ordinal_plural_form( 'en', 1 ),  'one', 'invalid pack callback does not affect ordinal queries' );
    XS::APItest::diagpack_test_restore('en');

    XS::APItest::diagpack_test_override( $poison_language, 1 );
    XS::APItest::diagpack_test_override( 'en',             1 );
    is( $text_diagnostic->render_as_legacy($poison_language),
        $english, 'fallback restarts from canonical values after target and registered English misses' );
    is( $text_diagnostic->{params}[0]{value}, 'no', 'failed pack attempts cannot mutate stored semantic parameters' );
    XS::APItest::diagpack_test_restore($poison_language);
    XS::APItest::diagpack_test_restore('en');
}

my $count_diagnostic = bless {
    code         => 'WARNING_UNTIE_INNER_REFERENCES_REMAIN',
    number       => 2217,
    selector_key => 0,
    params       => [ { name => 'arg1', type => 'uv', value => '0' } ],
  },
  'XPerl::Diagnostic';

my @cardinal_counts = ( 0, 1, 2, 3, 5, 6, 10, 11, 21, 99, 100, 101, 102, 103, 110, 111 );
push @cardinal_counts, '18446744073709551601', '18446744073709551611'
  if $Config{uvsize} >= 8;
push @cardinal_counts, '4294967281', '4294967291'
  if $Config{uvsize} == 4;
for my $language ( sort keys %packs ) {
    my $module = $packs{$language};
    for my $count (@cardinal_counts) {
        $count_diagnostic->{params}[0]{value} = $count;
        my $rendered = $module->render($count_diagnostic);
        ok( defined $rendered, "$language renders count $count from the current semantic value" );
        is(
            $rendered,
            $count_diagnostic->render_as_legacy($language),
            "$language plural selection for $count matches the core catalog"
        );
    }
}

my $omission_diagnostic = bless {
    code         => 'NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS',
    number       => 2479,
    selector_key => 0,
    params       => [ { name => 'omitted_count', type => 'uv', value => '0' } ],
  },
  'XPerl::Diagnostic';
for my $language ( sort keys %packs ) {
    my $module = $packs{$language};
    for my $count (@cardinal_counts) {
        $omission_diagnostic->{params}[0]{value} = $count;
        my $rendered = $module->render($omission_diagnostic);
        ok( defined $rendered, "$language renders omission count $count from the current semantic value" );
        is(
            $rendered,
            $omission_diagnostic->render_as_legacy($language),
            "$language omission plural selection for $count matches the core catalog"
        );
    }
}

SKIP: {
    skip 'Persian diagnostic pack is unavailable', 2 unless $packs{fa};

    $omission_diagnostic->{params}[0]{value} = 0;
    my $zero_omission = $packs{fa}->render($omission_diagnostic);
    $omission_diagnostic->{params}[0]{value} = 1;
    my $one_omission = $packs{fa}->render($omission_diagnostic);
    ok(
        defined($zero_omission) && defined($one_omission)
          && $zero_omission =~ /(?:\A|\s)0\s/
          && $one_omission =~ /(?:\A|\s)1\s/,
        'Persian omission template displays the actual count for both zero and one'
    );

    my $forward_hop_diagnostic = bless {
        code         => 'ERROR_INTERNAL_UNICODE_UTF8_FORWARD_HOP_START_OUT_OF_BOUNDS',
        number       => 1816,
        selector_key => 0,
        params       => [
            { name => 'arg1', type => 'ptr', value => 0 },
            { name => 'arg2', type => 'uv',  value => 0 },
            { name => 'arg3', type => 'ptr', value => 0 },
        ],
      },
      'XPerl::Diagnostic';
    my $zero_hop = $packs{fa}->render($forward_hop_diagnostic);
    $forward_hop_diagnostic->{params}[1]{value} = 1;
    my $one_hop = $packs{fa}->render($forward_hop_diagnostic);
    ok(
        defined($zero_hop) && defined($one_hop)
          && $zero_hop =~ /(?:\A|\s)0\s/
          && $one_hop =~ /(?:\A|\s)1\s/,
        'Persian forward-hop template displays the actual byte count for both zero and one'
    );
}

my $operation_exception;
my $coerce_integer = sub { no warnings 'numeric'; $_[0] |= 0 };
{
    local $SIG{__EXCEPT__} = sub { $operation_exception = $_[0] };
    eval { $coerce_integer->(*STDERR) };
    $operation_exception ||= $@;
}
my $operation_diagnostic      = $operation_exception->contents->[0];
my $operation_body_diagnostic = bless {%$operation_diagnostic}, ref $operation_diagnostic;
delete $operation_body_diagnostic->{location};
for my $language ( sort keys %packs ) {
    my $module   = $packs{$language};
    my $rendered = $module->render($operation_diagnostic);
    ok( defined $rendered, "$language renders the operation-word case" );
    is(
        $rendered,
        $operation_body_diagnostic->render_as_legacy($language),
        "$language operation words match the core catalog"
    );
}

my $api_test_loaded   = eval { require XS::APItest; 1 };
my $api_test_selected = $Config{extensions} =~ /(?:^|\s)XS\/APItest(?:\s|$)/;
if ($api_test_selected) {
    ok( $api_test_loaded, 'configured XS::APItest is loadable for the UTF-8 fixture' );
    diag($@) unless $api_test_loaded;
}
SKIP: {
    skip 'XS::APItest is not installed for the mixed UTF-8 fixture', 17 + 6 * keys(%packs)
      unless $api_test_loaded;
    my @short_utf8_diagnostics;
    for my $case ( [ "\xF3", 1 ], [ "\xF0\x90", 2 ] ) {
        my $exception;
        {
            use warnings 'utf8';
            local $SIG{__EXCEPT__} = sub { $exception = $_[0] };
            local $SIG{__WARN__}   = sub { };
            XS::APItest::utf8::test_utf8n_to_uvchr_error( $case->[0], $case->[1], 0 );
        }
        push @short_utf8_diagnostics, $exception->contents->[0]
          if $exception;
    }
    is( scalar @short_utf8_diagnostics, 2, 'both mixed UTF-8 operations produced captured diagnostics' );
    for my $short_diagnostic (@short_utf8_diagnostics) {
        my %params = map { $_->{name} => $_->{value} } @{ $short_diagnostic->{params} };
        is(
            join( '|', map { $_->{name} } @{ $short_diagnostic->{params} } ),
            'operation_identity|bytes|available_bytes|expected_bytes|context|operation',
            'the mixed UTF-8 diagnostic preserves its declared capture order'
        );
        is(
            $short_diagnostic->code,
            'WARNING_UTF8_SEQUENCE_TOO_SHORT',
            'the mixed UTF-8 case retains its diagnostic identity'
        );
        ok( $params{operation_identity}, 'the mixed UTF-8 case retains operation identity' );
        for my $name (qw(available_bytes expected_bytes operation_identity context)) {
            my ($record) = grep { $_->{name} eq $name } @{ $short_diagnostic->{params} };
            ok(
                B::svref_2object( \$record->{value} )->FLAGS & B::SVf_IOK(),
                "the captured $name retains a native integer value"
            );
        }
        ok(
            defined $short_diagnostic->render_as_legacy('en'),
            'the existing core renderer still handles the mixed UTF-8 case'
        );
        my $body = bless {%$short_diagnostic}, ref $short_diagnostic;
        delete $body->{location};
        for my $language ( sort keys %packs ) {
            my $rendered = $packs{$language}->render($short_diagnostic);
            ok( defined $rendered, "$language renders the captured context selector" );
            is(
                $rendered,
                $body->render_as_legacy($language),
                "$language matches core output with the captured context selector"
            );
        }

        my $schema = get_diagnostic_data( $short_diagnostic->number );
        my %records = map  { $_->{name} => $_ } @{ $short_diagnostic->{params} };
        my ($context_selector) = grep { $_->{source} eq 'context' } @{ $schema->{selectors} };
        my ($operation_selector_index) = grep {
            $context_selector->{values}[$_] eq 'operation'
        } 0 .. $#{ $context_selector->{values} };
        is( $records{context}{value}, $operation_selector_index + 1,
            'the captured grammatical selector uses its native ID' );
        my @missing = grep { !exists $records{$_} }
          map { $_->{name} } @{ $schema->{parameters} };
        is( join( ',', @missing ), '', 'the real capture retains every declared UTF-8 parameter' );

        my ($context)        = grep { $_->{name} eq 'context' } @{ $short_diagnostic->{params} };
        my $original_context = $context->{value};
        my $original_body    = $short_diagnostic->render_as_legacy('en');
        $context->{value} = $original_context == 1 ? 2 : 1;
        isnt( $short_diagnostic->render_as_legacy('en'),
            $original_body, 'core rendering recomputes the selector from the edited current value' );
        if ( $packs{en} ) {
            is(
                $packs{en}->render($short_diagnostic),
                $body->render_as_legacy('en'),
                'the English pack reads the edited selector value'
            );
        }
        $context->{value} = $original_context;
    }
}

my $dynamic_diagnostic = bless {
    code   => 'ERROR_PROPAGATION_EVAL_ERROR_TEXT',
    number => 1436,
    params => [
        { name => 'message', type => 'text', value => 'opaque text' },
        { name => 'length',  type => 'uv',   value => '11' },
    ],
  },
  'XPerl::Diagnostic';
for my $language ( sort keys %packs ) {
    ok(
        !defined $packs{$language}->render($dynamic_diagnostic),
        "$language reports an unavailable dynamic message as undef"
    );
}

my $missing_selector = bless {
    code         => 'ERROR_OVERLOAD_CONSTANT_CONVERSION_FAILED',
    number       => 1435,
    selector_key => 1,
    params       => [
        { name => 'constant',      type => 'text', value => '42' },
        { name => 'overload_type', type => 'text', value => 'integer' },
    ],
  },
  'XPerl::Diagnostic';
for my $language ( sort keys %packs ) {
    ok(
        !defined $packs{$language}->render($missing_selector),
        "$language does not decode a missing selector from the saved key"
    );
}

my $english_fallback;
for my $number_and_code (
    [ 2743, 'ERROR_DIAGNOSTIC_API_RENDER_INPUT_INVALID' ],
    [ 2744, 'ERROR_DIAGNOSTIC_API_RENDER_PARAMETER_INVALID' ],
  )
{
    my ( $number, $code ) = @$number_and_code;
    my $diagnostic = bless {
        code   => $code,
        number => $number,
        params => [],
      },
      'XPerl::Diagnostic';
    $english_fallback = $diagnostic->render_as_legacy('en');
    if ( $packs{en} ) {
        my $english_pack_message = $packs{en}->render($diagnostic);
        ok( defined $english_pack_message, "English pack renders its own $code entry" );
        is( $english_pack_message, $english_fallback, "English pack output agrees for $code" );
    }
    for my $language ( sort grep { $_ ne 'en' } keys %packs ) {
        my $cases = get_diagnostic_data($number)->{translations}{$language}{cases};
        if ( $cases && @$cases ) {
            my $translated = $packs{$language}->render($diagnostic);
            ok( defined $translated, "$language renders the translated $code" );
            is( $diagnostic->render_as_legacy($language),
                $translated, "$language core rendering uses the translated $code" );
        }
        else {
            ok( !defined $packs{$language}->render($diagnostic), "$language returns undef for English-only $code" );
            is( $diagnostic->render_as_legacy($language),
                $english_fallback, "$language core rendering falls back to the complete English $code" );
        }
    }
}

done_testing();
