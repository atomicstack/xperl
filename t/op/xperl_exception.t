#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;
use Config;
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

done_testing();
