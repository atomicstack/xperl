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
use feature 'signatures';
no warnings 'experimental::signature_named_parameters';

sub named_required ( : $alpha, : $beta ) { }

for my $case (
    [
        q{named_required(alpha => 1)},
        'Missing required named parameter',
        'Param', 1
    ],
    [ q{named_required()}, 'Missing required named parameters', 'Param', 2 ],
    [
        q{named_required(alpha => 1, beta => 2, extra => 3)},
        'Unrecognized named parameter',
        'Param', 1
    ],
    [
        q{named_required(alpha => 1, beta => 2, extra => 3, other => 4)},
        'Unrecognized named parameters',
        'Param', 2
    ],
    [
        q{named_required(alpha => 1, beta => 2, 'a' .. 'z')},
        'Unrecognized named parameters',
        'Param', 6
    ],
  )
{
    eval $case->[0];
    my $exception = $@;
    my $before    = $exception->as_json;

    is( ref $exception,
        'XPerl::Exception', 'named-parameter failure is structured' );
    is( scalar @{ $exception->contents }, 1,
        'named-parameter diagnostics have one immediate root' );
    is( $exception->contents->[0]->contents_count, $case->[3] - 1,
        'the retained parameter diagnostics are nested under the first' );
    like(
        $exception->render_as_legacy('en'),
        qr/^\Q$case->[1]\E /,
        'English selects singular or plural wording'
    );
    like( $exception->render_as_legacy('fr'),
        qr/^\Q$case->[2]\E/, 'the group uses the requested language' );
    like(
        $exception->render_as_legacy('zz'),
        qr/^\Q$case->[1]\E /,
        'an unavailable translation falls back to English'
    );
    like(
        $exception->render_as_annotated('fr'),
        qr/^#\d+ FATAL_ERROR\.CORE_RUNTIME\./m,
        'annotated rendering retains diagnostic identity'
    );
    is( $exception->as_json, $before,
        'rendering the summary does not alter stored diagnostics' );

    if ( $case->[3] == 6 ) {
        my ($omitted) = grep {
            $_->code eq 'NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS'
        } @{ $exception->contents->[0]->contents };
        isa_ok( $omitted, 'XPerl::Diagnostic::Note::Omission',
            'producer-classified omitted-count child' );
        is( $omitted->severity, 'NOTE',
            'omitted-count child does not add a second error' );
        my ($omitted_count) = grep {
            $_->{name} eq 'omitted_count'
        } @{ $omitted->params };
        is( $omitted_count->{value}, 8,
            'the grouped diagnostic retains its exact omitted count' );
        like(
            $exception->render_as_legacy('en'),
            qr/'a', 'c', 'e', 'g', 'i', \.\.\./,
            'the name list keeps its five-name limit'
        );
    }
}

{
    for my $case (
        [ 1, 'Unrecognized named parameter', 'Param' ],
        [ 2, 'Unrecognized named parameters', 'Param' ],
    ) {
        my ($count, $english, $french) = @$case;
        my $diagnostic = bless {
            code => 'ERROR_CALL_BINDING_NAMED_PARAMETER_SUMMARY', number => 2630,
            kind => 'CORE_RUNTIME', severity => 'FATAL_ERROR', selector_key => 0,
            params => [
                { name => 'names', type => 'text', value => $count == 1 ? "'x'" : "'x', 'y'" },
                { name => 'function', type => 'text', value => 'main::named' },
                { name => 'requirement', type => 'text', value => 'unknown' },
                { name => 'count', type => 'uv', value => "$count" },
            ],
        }, 'XPerl::Diagnostic';
        like($diagnostic->render_as_legacy('en'), qr/^\Q$english\E/,
            "English named-parameter summary uses count $count");
        like($diagnostic->render_as_legacy('fr'), qr/^\Q$french\E/,
            "French named-parameter summary uses count $count");
    }
}

{
    for my $case (
        [ 1, 2, 'One additional named parameter diagnostic was omitted',
          'Un diagnostic suppl' ],
        [ 2, 6, 'Additional named parameter diagnostics were omitted',
          "D'autres diagnostics" ],
    ) {
        my ( $count, $selector_key, $english, $french ) = @$case;
        my $diagnostic = bless {
            code => 'NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS', number => 2479,
            kind => 'CORE_RUNTIME', severity => 'FATAL_ERROR',
            selector_key => $selector_key,
            params => [
                { name => 'omitted_count', type => 'uv', value => "$count" },
            ],
        }, 'XPerl::Diagnostic';
        like( $diagnostic->render_as_legacy('en'), qr/\Q$english\E/,
            "omitted diagnostic count $count selects English wording" );
        like( $diagnostic->render_as_legacy('fr'), qr/\Q$french\E/,
            "omitted diagnostic count $count selects French wording" );
    }
}

{
    for my $case (
        [ 1, 2, 'is 1 byte beyond legal end position', "d'un octet" ],
        [ 2, 6, 'is 2 bytes beyond legal end position', 'de 2 octets' ],
    ) {
        my ( $distance, $selector_key, $english, $french ) = @$case;
        my $diagnostic = bless {
            code => 'ERROR_INTERNAL_UNICODE_UTF8_FORWARD_HOP_START_OUT_OF_BOUNDS', number => 1816,
            kind => 'CORE_RUNTIME', severity => 'INTERNAL_ERROR',
            selector_key => $selector_key,
            params => [
                { name => 'arg1', type => 'ptr', value => '0x100' },
                { name => 'arg2', type => 'uv', value => "$distance" },
                { name => 'arg3', type => 'ptr', value => '0x0ff' },
            ],
        }, 'XPerl::Diagnostic';
        like( $diagnostic->render_as_legacy('en'), qr/\Q$english\E/,
            "forward-hop distance $distance selects English grammar" );
        like( $diagnostic->render_as_legacy('fr'), qr/\Q$french\E/,
            "forward-hop distance $distance selects French grammar" );
    }
}

{
    for my $count (1, 2, 5) {
        my $diagnostic = bless {
            code => 'WARNING_LOCALE_STARTUP_FALLBACKS_FAILED', number => 2664,
            kind => 'CORE_RUNTIME', severity => 'WARNING', selector_key => 0,
            params => [
                { name => 'locales', type => 'text', value => "locale list $count" },
                { name => 'count', type => 'uv', value => "$count" },
            ],
        }, 'XPerl::Diagnostic';
        my $text = $diagnostic->render_as_legacy('en');
        like($text, qr/Failed to fall back/,
            "locale fallback summary renders with count $count");
        like($text, qr/\Qlocale list $count\E/,
            "locale fallback summary preserves its list with count $count");
        like($diagnostic->render_as_legacy('fr'), qr/Impossible d'utiliser/,
            "French locale fallback summary renders with count $count");
    }
}

{
    for my $case (
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_SCOPE_STACK_UNBALANCED', 2170, 'positive', 1,
          'Unbalanced scopes (ENTERs exceed LEAVEs): 1' ],
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_SCOPE_STACK_UNBALANCED', 2170, 'negative', 2,
          'Unbalanced scopes (LEAVEs exceed ENTERs): 2' ],
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_SAVE_STACK_UNBALANCED', 2171, 'positive', 1,
          'Unbalanced save stack (saves exceed restores): 1' ],
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_SAVE_STACK_UNBALANCED', 2171, 'negative', 3,
          'Unbalanced save stack (restores exceed saves): 3' ],
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_CONTEXT_STACK_UNBALANCED', 2173, 'positive', 1,
          'Unbalanced context stack (PUSHes exceed POPs): 1' ],
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_CONTEXT_STACK_UNBALANCED', 2173, 'negative', 4,
          'Unbalanced context stack (POPs exceed PUSHes): 4' ],
    ) {
        my ( $code, $number, $direction, $magnitude, $expected ) = @$case;
        my %selector_key = (
            negative => 1,
            positive => 2,
        );
        my $diagnostic = bless {
            code => $code, number => $number,
            kind => 'CORE_RUNTIME',
            severity => 'WARNING',
            selector_key => $selector_key{$direction},
            params => [
                { name => 'direction', type => 'text', value => $direction },
                { name => 'magnitude', type => 'uv', value => "$magnitude" },
            ],
        }, 'XPerl::Diagnostic';
        like( $diagnostic->render_as_legacy('en'), qr/\Q$expected\E/,
            "$code renders $direction with magnitude $magnitude" );
    }

    for my $case (
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_TEMP_STACK_FLOOR_UNBALANCED', 2172, -3,
          'Unbalanced temporary stack floor offset: -3' ],
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_TEMP_STACK_FLOOR_UNBALANCED', 2172, 4,
          'Unbalanced temporary stack floor offset: 4' ],
        [ 'WARNING_SEVERE_INTERNAL_DESTRUCTION_SCALAR_ALLOCATION_COUNT_NONZERO', 2175, -5,
          'SV allocation counter at shutdown: -5' ],
    ) {
        my ( $code, $number, $value, $expected ) = @$case;
        my $diagnostic = bless {
            code => $code, number => $number,
            kind => 'CORE_RUNTIME', severity => 'WARNING', selector_key => 0,
            params => [ { name => 'arg1', type => 'iv', value => "$value" } ],
        }, 'XPerl::Diagnostic';
        like( $diagnostic->render_as_legacy('en'), qr/\Q$expected\E/,
            "$code preserves its signed counter value $value" );
    }
}

{
    for my $value ( -1, 1 ) {
        my $diagnostic = bless {
            code => 'ERROR_INTERNAL_UNICODE_UTF16_FILTER_BLOCK_MODE_FORBIDDEN', number => 1550,
            kind => 'CORE_RUNTIME', severity => 'INTERNAL_ERROR', selector_key => 0,
            params => [ { name => 'arg2', type => 'iv', value => "$value" } ],
        }, 'XPerl::Diagnostic';
        like( $diagnostic->render_as_legacy('en'), qr/maxlen=\Q$value\E/,
            "UTF-16 filter block-mode panic preserves signed maxlen $value" );
    }

    my $diagnostic = bless {
        code => 'WARNING_MISC_VMS_LOGICAL_VALUE_TRUNCATED', number => 2340,
        kind => 'CORE_RUNTIME', severity => 'WARNING', selector_key => 0,
        params => [
            { name => 'arg1', type => 'text', value => 'PERL_TEST' },
            { name => 'arg2', type => 'uv', value => '510' },
        ],
    }, 'XPerl::Diagnostic';
    like( $diagnostic->render_as_legacy('en'), qr/byte limit 510/,
        'VMS truncation text labels the fixed byte limit without count agreement' );
}

{
    eval q{use strict; $xperl_missing = 1};
    my $exception  = $@;
    my $diagnostic = $exception->contents->[0];
    my $line       = $diagnostic->location->{line};

    like(
        $exception->render_as_legacy('en'),
        qr/ at \(eval \d+\) line $line/,
        'English source locations keep legacy syntax'
    );
    like(
        $exception->render_as_legacy('fr'),
        qr/ \N{LATIN SMALL LETTER A WITH GRAVE} \(eval \d+\) ligne $line/,
        'exception locations use the requested language'
    );
    like(
        $diagnostic->render_as_legacy('fr'),
        qr/ligne $line/,
        'standalone diagnostics translate their own location'
    );
    like(
        $exception->render_as_annotated('fr'),
        qr/ligne $line/,
        'annotated text uses the translated location'
    );

    my $light =
      bless { %$diagnostic, light => 1, context_follows_index => 999 },
      'XPerl::Diagnostic';
    like(
        $light->render_as_legacy('fr'),
        qr/contexte indisponible/,
'a standalone light diagnostic explains its missing context in the selected language'
    );
}

{
    eval q{use strict; $context_missing = 1};
    my $original = $@->contents->[0];
    for my $case (
        [
            near => ', near "token"',
            "pr\N{LATIN SMALL LETTER E WITH GRAVE}s de \"token\""
        ],
        [ eof            => ', at EOF',          'en fin de fichier' ],
        [ next_token     => ', next token ???',  'token suivant ???' ],
        [ next_char      => ', next char token', 'suivant token' ],
        [ end_of_line    => ', at end of line',  'en fin de ligne' ],
        [ within_pattern => ', within pattern',  'dans le motif' ],
        [ within_string  => ', within string',   'dans la cha' ],
        [ plain          => '.',                 'ligne 7.' ],
        [ empty_near     => ', ',                'ligne 7, ' ],
      )
    {
        my $diagnostic = bless {
            %$original,
            location => {
                file                 => 'context.pl',
                line                 => 7,
                parser_context       => $case->[0],
                parser_context_value => 'token',
            }
          },
          'XPerl::Diagnostic';
        my $exception = XPerl::Exception->_new();
        $exception->append($diagnostic);
        like( $exception->render_as_legacy('en'),
            qr/\Q$case->[1]\E\n\z/,
            "English parser context $case->[0] uses its complete case" );
        like( $exception->render_as_legacy('fr'),
            qr/\Q$case->[2]\E/,
            "French parser context $case->[0] uses its complete case" );
        like( $exception->render_as_annotated('en'),
            ($case->[0] eq 'near'
                ? qr/ near "token" at context\.pl line 7\.\n\z/
                : qr/\Q$case->[1]\E\n\z/),
            "annotated English preserves parser context $case->[0]" );
        like( $exception->render_as_annotated('fr'),
            qr/\Q$case->[2]\E/,
            "annotated French preserves parser context $case->[0]" );
    }

    for my $case (
        [ en => ' at context.pl line 7' ],
        [ de => ' in context.pl, Zeile 7' ],
        [ fr => " \N{LATIN SMALL LETTER A WITH GRAVE} context.pl ligne 7" ],
        [ it => ' in context.pl alla riga 7' ],
        [ zz => ' at context.pl line 7' ],
    ) {
        my ($language, $location) = @$case;
        for my $context (qw(plain source parser location_only unknown)) {
            for my $kind (qw(CORE_COMPILE CORE_RUNTIME)) {
                my $diagnostic = bless {
                    %$original,
                    kind => $kind,
                    location => {
                        file => 'context.pl', line => 7,
                        parser_context => $context,
                        parser_context_value => 'token',
                    },
                }, 'XPerl::Diagnostic';
                my $exception = XPerl::Exception->_new();
                $exception->append($diagnostic);
                like($exception->render_as_legacy($language),
                    qr/\Q$location\E\.\n\z/,
                    "$language $kind context $context preserves location punctuation");
            }
        }
    }

}

{
    eval q{qr/(abc/};
    my $exception = $@;
    like(
        $exception->render_as_legacy('en'),
        qr/in regex; marked by <-- HERE/,
        'English regex context remains informative'
    );
    like(
        $exception->render_as_legacy('fr'),
qr/expression r\N{LATIN SMALL LETTER E WITH ACUTE}guli\N{LATIN SMALL LETTER E WITH GRAVE}re/,
        'the regex context wrapper uses the selected language'
    );
    like( $exception->render_as_legacy('fr'),
        qr/<-- HERE/, 'translation retains the regex position marker' );
}

{
    my $output = runperl( prog => 'myfunc 1,2,3', stderr => 1 );
    like(
        $output,
        qr/Do you need to predeclare "myfunc"\?/,
        'automatic language fallback selects the English inline hint'
    );
}

for my $files ( [ 'first.pl', 'duplicate.pl' ], [ 'same.pl', 'same.pl' ] ) {
    my ( $first_file, $duplicate_file ) = @$files;
    my $warning;
    {
        local $SIG{__EXCEPT__} = sub { $warning = $_[0] };
        local $SIG{__WARN__}   = sub { };
        eval qq{
            use feature 'dispatch_on';
            use warnings 'syntax';
            dispatch (0) {
#line 11 "$first_file"
                on (1) { }
#line 29 "$duplicate_file"
                on (1) { }
            }
            1;
        };
        is( $@, '', 'duplicate dispatch compilation remains continuable' );
    }
    my ($diagnostic) =
      $warning
      ? grep { $_->code eq 'WARNING_SYNTAX_DISPATCH_CONSTANT_UNREACHABLE' }
      @{ $warning->contents }
      : ();
    ok( $diagnostic, 'duplicate dispatch has a catalog diagnostic' );
    my %params =
      $diagnostic
      ? map { $_->{name} => $_->{value} } @{ $diagnostic->params }
      : ();
    is( $params{first_file}, $first_file,
        'the first filename is separate data' );
    is( $params{first_line}, 11, 'the first line is separate data' );
    is( $params{duplicate_file}, $duplicate_file,
        'the duplicate filename is separate data' );
    is( $params{duplicate_line}, 29, 'the duplicate line is separate data' );
    like(
        $diagnostic->render_as_legacy('en'),
qr/duplicate at \Q$duplicate_file\E line 29, first at \Q$first_file\E line 11/,
        'English keeps both locations in their legacy order'
    );
    like(
        $diagnostic->render_as_legacy('fr'),
qr/doublon \N{LATIN SMALL LETTER A WITH GRAVE} \Q$duplicate_file\E ligne 29, premi/,
        'French renders the location relationship from separate values'
    );
}

for my $case (
    [
        'lb=surrogate',
"Surrogates should never appear in well-formed text, and therefore shouldn't be the basis for line breaking",
        'codets de substitution'
    ],
    [
        'Hyphen',
'Supplanted by Line_Break property values; see www.unicode.org/reports/tr14',
        'Line_Break'
    ],
  )
{
    my ( $property, $english_reason, $french_reason ) = @$case;
    my $warning;
    {
        local $SIG{__EXCEPT__} = sub { $warning = $_[0] };
        local $SIG{__WARN__}   = sub { };
        my $regex = qr/\p{$property}/;
    }
    my ($diagnostic) =
      $warning
      ? grep { $_->code eq 'WARNING_DEPRECATED_UNICODE_PROPERTY_NAME_PROPERTY_NAME_USED' }
      @{ $warning->contents }
      : ();
    ok( $diagnostic, "deprecated property $property is structured" );
    my %params =
      $diagnostic
      ? map { $_->{name} => $_->{value} } @{ $diagnostic->params }
      : ();
    is( $params{property}, $property,
        'the property retains its semantic name' );
    is( $params{detail}, '',
        'a known reason does not store English explanation text' );
    ok( $diagnostic->selector_key, 'the semantic reason has a selector key' );
    is(
        join( '|', @{ $diagnostic->warning_categories } ),
        'WARN_DEPRECATED__UNICODE_PROPERTY_NAME',
        'the warning category is preserved'
    );
    like( $diagnostic->render_as_legacy('en'),
        qr/\Q$english_reason\E/,
        'English preserves the complete Unicode explanation' );
    like( $diagnostic->render_as_legacy('fr'),
        qr/\Q$french_reason\E/,
        'French selects a complete translated explanation' );

    my $fallback = bless {
        %$diagnostic,
        selector_key => 0,
        params       => [
            { name => 'property', type => 'text', value => 'FutureProperty' },
            { name => 'reason', type => 'text', value => 'other' },
            {
                name  => 'detail',
                type  => 'text',
                value =>
                  "A new Unicode explanation \N{GREEK CAPITAL LETTER OMEGA}"
            },
        ]
      },
      'XPerl::Diagnostic';
    like(
        $fallback->render_as_legacy('en'),
qr/FutureProperty.*because: A new Unicode explanation \N{GREEK CAPITAL LETTER OMEGA}/,
        'a future reason retains the external explanation'
    );
    like(
        $fallback->render_as_legacy('fr'),
qr/FutureProperty.*A new Unicode explanation \N{GREEK CAPITAL LETTER OMEGA}/,
        'translation fallback keeps unknown reason details'
    );
}

{
    require XS::APItest;
    is( XS::APItest::constrained_diagnostic_text(0),
        "Signal SIGTEST received, but no signal handler set.\n",
        'signal output uses the allocation-free catalog format' );
    is( XS::APItest::constrained_diagnostic_text(1),
        'Fatal VMS error (status=17) at bootstrap.c, line 23',
        'the VMS startup format shares its ordinary diagnostic template' );
    is( XS::APItest::constrained_diagnostic_text(2),
        "external error, possible problematic module: 'module.dll'",
        'the module-load template preserves external system error data' );
    eval { XS::APItest::locale_panic_diagnostic( 12345, 9 ) };
    my $exception = $@;
    is( ref($exception), 'XPerl::Exception',
        'a locale panic throws a structured exception' );
    my $diagnostic = $exception->contents->[0];
    is( $diagnostic->code, 'ERROR_INTERNAL_LOCALE_NAME_CATEGORY_UNKNOWN',
        'the panic retains its specific diagnostic identity' );
    is( $diagnostic->params->[0]{value},
        '12345', 'the category is semantic parameter data' );
    my $panic = $diagnostic->location->{panic};
    is( $panic->{errno}, 9, 'parameter capture preserves the failing errno' );
    is( $panic->{caller_file}, 'locale-test-caller.c',
        'the higher caller file is structured data' );
    is( $panic->{caller_line}, 71,
        'the higher caller line is structured data' );
    like(
        $exception->render_as_legacy('en'),
qr/panic: Unknown locale category 12345; errno=9.*Called by locale-test-caller\.c: 71/s,
        'legacy rendering assembles the panic from catalog formats'
    );
    like(
        $diagnostic->render_as_json,
        qr/"panic":\{.*"errno":9.*"caller_line":71/s,
        'JSON retains numeric panic context'
    );
    eval '1';
}

for my $case (
    [ 'en', 'Setting locale failed', 'Please check', 'unset', 'Falling back' ],
    [
        'fr',
        'Setting locale failed',
        'Please check',
        'unset',
        'Falling back'
    ],
  )
{
  SKIP: {
        skip 'setlocale is unavailable', 5 unless $Config{d_setlocale};
        my ( $language, $failure, $check, $unset, $fallback ) = @$case;
        local $ENV{PERL_DIAG_RENDER} = "$language:legacy";
        local $ENV{LC_ALL}           = 'xperl_deliberately_invalid_locale';
        local $ENV{LANG}             = 'C';
        local $ENV{PERL_BADLANG}     = 1;
        delete local $ENV{LC_CTYPE};
        my $output = runperl( prog => 'print qq[ready\n]', stderr => 1 );
        utf8::decode($output);
        my $source = $language eq 'fr'
            ? 'permanent English before language-pack loading' : 'the catalog';
        like( $output, qr/\Q$failure\E/,
            "$language startup failure uses $source" );
        like( $output, qr/\Q$check\E/,
            "$language startup explanation uses $source" );
        like(
            $output,
            qr/LC_ALL = "xperl_deliberately_invalid_locale"/,
            'the failed environment value is preserved'
        );
        like(
            $output,
            qr/LC_CTYPE = \(\Q$unset\E\)/,
            "$language renders an unset environment value"
        );
        like( $output, qr/\Q$fallback\E.*\nready\n/s,
            "$language fallback output preserves startup continuation" );
    }
}

for my $case (
    [ "finished\n", 1 ],
    [ "finished", 0 ],
    [ "first\nsecond", 0 ],
    [ "\x{263a}\n", 1 ],
) {
    my ($message, $terminated) = @$case;
    my ($exception, $delivered);
    {
        local ${^DIAG_RENDER} = 'en:annotated';
        local $SIG{__EXCEPT__} = sub { $exception = $_[0] };
        local $SIG{__WARN__} = sub { $delivered = $_[0] };
        warn 'prefix:', $message;
    }
    my $diagnostic = $exception->contents->[0];
    my $location = $diagnostic->location;
    ok( $location->{file} && $location->{line},
        'warning retains its structured source location' );
    my $before = $exception->as_json;
    for my $language (qw(en fr sr)) {
        my $rendered = $exception->render_as_annotated($language);
        if ($terminated) {
            is( $rendered, "#2439 WARNING.USER_RUNTIME.WARNING_USER_TEXT\nprefix:$message",
                "$language final newline suppresses header and body locations" );
            is( $exception->render_as_legacy($language), "prefix:$message",
                "$language final newline preserves legacy warning text" );
        }
        else {
            like( $rendered, qr/\Q$location->{file}:$location->{line}\E\n/,
                "$language unterminated warning retains its header location" );
        }
    }
    is( $delivered, $exception->render_as_annotated('en'),
        'warning hook receives the selected annotated rendering' );
    is( $exception->as_json, $before,
        'rendering does not remove retained location metadata' );
}

{
    eval { die "terminated error\n" };
    my $exception = $@;
    my $file = $exception->contents->[0]->location->{file};
    unlike( $exception->render_as_annotated('en'), qr/\Q$file\E/,
        'a final newline also suppresses annotated user-error locations' );
}

{
    eval q{use strict; $header_missing = 1};
    my $original = $@->contents->[0];
    my $exception = XPerl::Exception->_new();
    for my $line (7, 7, 8, 7) {
        my $diagnostic = bless {
            %$original, location => { file => 'headers.pl', line => $line },
        }, ref $original;
        $exception->append($diagnostic);
    }
    my $before = $exception->as_json;
    my $rendered = $exception->render_as_annotated('en');
    is( scalar(() = $rendered =~ /^#2440 /mg), 3,
        'annotated rendering shares only consecutive identical headers' );
    is( scalar(() = $rendered =~ /^Global symbol /mg), 4,
        'sharing headers retains every diagnostic body' );
    like( $rendered, qr/headers\.pl:7\n.*\n.*\n#2440 .*headers\.pl:8\n/s,
        'a changed location starts another header' );
    is( $exception->render_as_annotated('en'), $rendered,
        'a new render starts with a fresh header' );
    is( $exception->as_json, $before,
        'sharing headers does not merge or modify diagnostic records' );
}

{
    local $ENV{PERL_DIAG_RENDER} = 'en:modern';
    my $output = runperl(
        prog => q{use strict; $x = $y + 1 1; $foo->$bar()}, stderr => 1,
    );
    is( scalar(() = $output =~ /^#2440 /mg), 1,
        'automatic output shares headers across delivery groups' );
    is( scalar(() = $output =~ /near "1 1"/g), 2,
        'the warning and syntax error both retain the nearby source' );
    like( $output, qr/^Syntax error near "1 1" at -e line 1\.\n/m,
        'annotated syntax errors use sentence case and context before location' );
    like( $output, qr/^  An operator may be missing before "1"\.\n/m,
        'a contained hint gets its own indented line' );
    unlike( $output, qr/#2514|NOTE_HINT_OPERATOR_EXPECTED_MISSING_OPERATOR/,
        'the container supplies the header for its hint' );
    unlike( $output, qr/\. at -e line|\n at -e line/,
        'annotated locations do not follow a terminated message' );
    like( $output, qr/Execution of -e aborted due to compilation errors\.\n\z/,
        'compilation-aborted text has no trailing location line' );

    local $SIG{__WARN__} = sub { };
    eval q{my $value = 1 1};
    my $exception = $@;
    my ($warning) = grep { $_->code eq 'WARNING_SYNTAX_OPERATOR_EXPECTED' }
        @{ $exception->contents };
    ok( $warning, 'the parser retains the operator-expected warning' );
    my $hint = $warning->contents->[0];
    isa_ok( $hint, 'XPerl::Diagnostic::Note::Hint' );
    is( $hint->severity, 'NOTE', 'the explanatory child has NOTE severity' );
    ok( !exists $hint->{warning_categories},
        'the hint does not carry an independent warning policy' );
    local $ENV{PERL_DIAG_RENDER} = 'en:legacy';
    my $legacy = runperl(
        prog => q{use strict; $x = $y + 1 1; $foo->$bar()}, stderr => 1,
    );
    like( $legacy, qr/Number found where operator expected \(Missing operator before "1"\?\) at -e line 1, near "1 1"/,
        'legacy rendering retains its inline hint and parser context' );

    local $ENV{PERL_DIAG_RENDER} = 'en:annotated:JSON';
    my $records = runperl(
        prog => q{use strict; $x = $y + 1 1;}, stderr => 1,
    );
    require JSON::PP;
    my @strict_records = grep {
        $_->{contents}[0]{code}
            eq 'ERROR_STRICT_VARS_GLOBAL_SYMBOL_REQUIRES_EXPLICIT_PACKAGE_NAME'
    } map { JSON::PP::decode_json($_) } split /\n/, $records;
    is( scalar @strict_records, 2, 'JSON retains both strict-variable groups' );
    for my $record (@strict_records) {
        like( $record->{message}, qr/^#2440 /,
            'each JSON group keeps a complete annotated header' );
    }

    local $ENV{PERL_DIAG_RENDER} = 'en:annotated';
    my $hooks = runperl(
        prog => q{BEGIN { $SIG{__DIE__} = sub {
            print STDERR "hook=", ($_[0] =~ /^#2440 / ? 1 : 0), "\n";
        } } use strict; $x = $y + 1 1;}, stderr => 1,
    );
    is( scalar(() = $hooks =~ /^hook=1$/mg), 2,
        'separate die-hook arguments retain complete headers' );
    is( scalar(() = $hooks =~ /^#2440 /mg), 2,
        'output after a hook starts with a fresh header' );

    my $quiet = runperl(
        prog => q{no warnings 'syntax'; my $x = 1 1;}, stderr => 1,
    );
    unlike( $quiet, qr/operator expected|An operator may be missing/,
        'disabling syntax warnings suppresses the parent and its hint' );
}

done_testing();
