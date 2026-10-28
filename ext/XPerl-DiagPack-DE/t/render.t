use strict;
use warnings;

use Test::More;

my $initial_render_default = ${^DIAG_RENDER};
require XPerl::DiagPack::DE;
is( ${^DIAG_RENDER}, $initial_render_default,
    'loading the pack does not change the selected language' );

my $metadata = XPerl::DiagPack::DE->metadata;
is( $metadata->{language}, 'de', 'metadata reports the pack language' );
is( $metadata->{abi_version}, 5, 'metadata reports the pack ABI' );

my $utf8_keyword = pack 'U', 0xFC;
my $diagnostic = bless {
    code   => 'ERROR_SYNTAX_DECLARATION_USE_NO_IN_EXPRESSION',
    number => 1429,
    params => [
        { name => 'keyword', type => 'text', value => $utf8_keyword },
    ],
}, 'XPerl::Diagnostic';
my $stored_keyword = $diagnostic->{params}[0]{value};
my $original_keyword = "$stored_keyword";
my $original_utf8_flag = utf8::is_utf8($stored_keyword);
my $hook_calls = 0;
my $warning_calls = 0;
my $die_calls = 0;
my $rendered;
{
    local $SIG{__EXCEPT__} = sub { $hook_calls++ };
    local $SIG{__WARN__}   = sub { $warning_calls++ };
    local $SIG{__DIE__}    = sub { $die_calls++ };
    $rendered = XPerl::DiagPack::DE->render($diagnostic);
}
is(
    $rendered,
    '"' . $utf8_keyword . '" ist in einem Ausdruck nicht erlaubt',
    'direct rendering uses the German pack catalog'
);
is( $hook_calls, 0, 'direct rendering does not invoke exception hooks or delivery' );
is( $warning_calls, 0, 'direct rendering does not invoke warning hooks' );
is( $die_calls, 0, 'direct rendering does not invoke die hooks' );
is( $diagnostic->{params}[0]{value}, $original_keyword,
    'rendering leaves the stored parameter bytes unchanged' );
is( utf8::is_utf8( $diagnostic->{params}[0]{value} ), $original_utf8_flag,
    'rendering leaves the parameter UTF-8 flag unchanged' );

$diagnostic->{params}[0]{value} = 'no';
is(
    XPerl::DiagPack::DE->render($diagnostic),
    '"no" ist in einem Ausdruck nicht erlaubt',
    'rendering uses the current parameter value after an edit'
);

my $count_diagnostic = bless {
    code   => 'NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS',
    number => 2479,
    params => [
        { name => 'omitted_count', type => 'uv', value => '1' },
    ],
}, 'XPerl::Diagnostic';
is(
    XPerl::DiagPack::DE->render($count_diagnostic),
    'Ein weiteres Diagnoseelement zu benannten Parametern wurde ausgelassen',
    'German count selection uses the retained numeric parameter'
);
for my $count ( 0, 2 ) {
    my $other_count = bless {
        code   => 'NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS',
        number => 2479,
        params => [ { name => 'omitted_count', type => 'uv', value => $count } ],
    }, 'XPerl::Diagnostic';
    is(
        XPerl::DiagPack::DE->render($other_count),
        'Weitere Diagnosen zu benannten Parametern wurden ausgelassen',
        "German plural selection uses count $count"
    );
}

my $operation_exception;
my $coerce_integer = sub { no warnings 'numeric'; $_[0] |= 0 };
{
    local $SIG{__EXCEPT__} = sub { $operation_exception = $_[0] };
    eval { $coerce_integer->(*STDERR) };
    $operation_exception ||= $@;
}
my $operation_diagnostic = $operation_exception->contents->[0];
like(
    XPerl::DiagPack::DE->render($operation_diagnostic),
    qr/bitweisen Oder \(\|\).*nicht in eine Ganzzahl umgewandelt werden/,
    'German operation wording uses the retained operation identity'
);

my $missing = bless {
    code   => 'ERROR_PROPAGATION_EVAL_ERROR_TEXT',
    number => 1436,
    params => [
        { name => 'message', type => 'text', value => 'opaque text' },
        { name => 'length', type => 'uv', value => '11' },
    ],
}, 'XPerl::Diagnostic';
ok( !defined XPerl::DiagPack::DE->render($missing),
    'a missing German case returns undef without fallback' );

my $missing_selector = bless {
    code         => 'ERROR_OVERLOAD_CONSTANT_CONVERSION_FAILED',
    number       => 1435,
    selector_key => 1,
    params       => [
        { name => 'constant', type => 'text', value => '42' },
        { name => 'overload_type', type => 'text', value => 'integer' },
    ],
}, 'XPerl::Diagnostic';
ok( !defined XPerl::DiagPack::DE->render($missing_selector),
    'a missing retained selector source returns undef without decoding selector_key' );

my $invalid_record = bless {
    code   => 'ERROR_SYNTAX_DECLARATION_USE_NO_IN_EXPRESSION',
    number => 1429,
    params => [ { name => 'wrong_name', type => 'text', value => 'no' } ],
}, 'XPerl::Diagnostic';
my $invalid_exception;
eval { XPerl::DiagPack::DE->render($invalid_record); 1 }
    or $invalid_exception = $@;
isa_ok( $invalid_exception, 'XPerl::Exception', 'malformed diagnostic input raises a structured exception' );
is(
    $invalid_exception->contents->[0]->code,
    'ERROR_DIAGNOSTIC_API_RENDER_PARAMETER_INVALID',
    'malformed parameter records use the diagnostic API catalog'
);

done_testing();
