#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

use strict;
use warnings;

sub diagnostic {
    return XPerl::Diagnostic->_new( { code => 'ERROR_USER_TEXT', params => [] } );
}

my $parent    = diagnostic();
my $leaf      = XPerl::Diagnostic::Note->_new( { code => 'ERROR_USER_TEXT', params => [] } );
my $malformed = diagnostic();
$malformed->{contents} = 42;

my @cases = (
    [
        'ERROR_DIAGNOSTIC_API_CHILDREN_LIST_NOT_ARRAY',
        sub {
            XPerl::Diagnostic->_new( { code => 'ERROR_USER_TEXT', params => [], contents => 42 } );
        }
    ],
    [
        'ERROR_DIAGNOSTIC_API_CHILDREN_MEMBER_NOT_DIAGNOSTIC',
        sub {
            XPerl::Diagnostic->_new( { code => 'ERROR_USER_TEXT', params => [], contents => [42] } );
        }
    ],
    [ 'ERROR_DIAGNOSTIC_API_CHILDREN_LEAF_CONTAINER_FORBIDDEN',                sub { $leaf->append($parent) } ],
    [ 'ERROR_DIAGNOSTIC_API_CHILDREN_DERIVED_LIST_NOT_ARRAY',       sub { $parent->derive(42) } ],
    [ 'ERROR_DIAGNOSTIC_API_CHILDREN_DERIVED_MEMBER_NOT_DIAGNOSTIC', sub { $parent->derive( [42] ) } ],
    [ 'ERROR_DIAGNOSTIC_API_CHILDREN_DERIVE_CYCLE',                     sub { $parent->derive( [$parent] ) } ],
    [ 'ERROR_DIAGNOSTIC_API_CHILDREN_STORED_LIST_NOT_ARRAY',         sub { $malformed->contents } ],
    [ 'ERROR_DIAGNOSTIC_API_CHILDREN_APPEND_CYCLE',               sub { $parent->append($parent) } ],
    [ 'ERROR_DIAGNOSTIC_API_CHILDREN_APPENDED_ITEM_NOT_DIAGNOSTIC',       sub { $parent->append(42) } ],
    [ 'ERROR_DIAGNOSTIC_API_CHILDREN_EXCEPTION_ITEM_NOT_DIAGNOSTIC',            sub { XPerl::Exception->_new()->append(42) } ],
    [ 'ERROR_DIAGNOSTIC_API_RECEIVER_TYPE_MISMATCH',                  sub { XPerl::DiagGroup::contents( {} ) } ],
    [ 'ERROR_DIAGNOSTIC_API_RENDER_CONTEXT_NOT_HASH',          sub { $parent->render_as_legacy( 'en', 42 ) } ],
    [ 'ERROR_DIAGNOSTIC_API_CONSTRUCTION_FIELDS_NOT_HASH',                  sub { XPerl::Diagnostic->_new(42) } ],
    [ 'ERROR_DIAGNOSTIC_API_CONSTRUCTION_CODE_MISSING',        sub { XPerl::Diagnostic->_new( { params => [] } ) } ],
    [ 'ERROR_DIAGNOSTIC_API_CONSTRUCTION_PARAMETERS_NOT_ARRAY', sub { XPerl::Diagnostic->_new( { code   => 'ERROR_USER_TEXT', params => 42 } ) } ],
    [
        'ERROR_DIAGNOSTIC_API_CONSTRUCTION_LOCATION_NOT_HASH',
        sub {
            XPerl::Diagnostic->_new( { code => 'ERROR_USER_TEXT', params => [], location => 42 } );
        }
    ],
    [
        'ERROR_DIAGNOSTIC_API_CONSTRUCTION_WARNING_CATEGORIES_NOT_ARRAY',
        sub {
            XPerl::Diagnostic->_new( { code => 'ERROR_USER_TEXT', params => [], warning_categories => 42 } );
        }
    ],
    [
        'ERROR_DIAGNOSTIC_API_CONSTRUCTION_LIGHT_FLAG_NOT_SCALAR',
        sub {
            XPerl::Diagnostic->_new( { code => 'ERROR_USER_TEXT', params => [], light => [] } );
        }
    ],
    [
        'ERROR_DIAGNOSTIC_API_CONSTRUCTION_CONTEXT_INDEX_INVALID',
        sub {
            XPerl::Diagnostic->_new( { code => 'ERROR_USER_TEXT', params => [], context_follows_index => -1 } );
        }
    ],
    [ 'ERROR_DIAGNOSTIC_API_THROW_EVENT_NOT_HASH', sub { XPerl::Exception->_new()->_record_throw(42) } ],
    [
        'ERROR_DIAGNOSTIC_API_THROW_MESSAGE_INDEX_RESERVED', sub { XPerl::Exception->_new()->_record_throw( { message_index => 0 } ) }
    ],
    [
        'ERROR_DIAGNOSTIC_API_THROW_RETHROW_DIAGNOSTIC_MISSING',
        sub { XPerl::Exception->_new()->_record_throw( { reason => 'rethrow' } ) }
    ],
    [ 'ERROR_DIAGNOSTIC_API_RENDER_FORMAT_UNKNOWN', sub { $parent->render('bogus') } ],
);

for my $index ( 0 .. $#cases ) {
    my ( $code, $operation ) = @{ $cases[$index] };
    my $ok        = eval { $operation->(); 1 };
    my $exception = $@;
    ok( !$ok, "$code rejects invalid input" );
    isa_ok( $exception, 'XPerl::Exception' );
    my $diagnostic = $exception->contents->[0];
    is( $diagnostic->code,   $code,         "$code has a symbolic catalog identity" );
    is( $diagnostic->number, 2720 + $index, "$code has a stable diagnostic number" );

    if ( $code eq 'ERROR_DIAGNOSTIC_API_RECEIVER_TYPE_MISMATCH' ) {
        is( $diagnostic->params->[0]{name},  'class_name',       'expected class has a semantic parameter name' );
        is( $diagnostic->params->[0]{value}, 'XPerl::DiagGroup', 'expected class remains structured data' );
    }
    elsif ( $code eq 'ERROR_DIAGNOSTIC_API_RENDER_FORMAT_UNKNOWN' ) {
        is( $diagnostic->params->[0]{name},  'format', 'unknown format has a semantic parameter name' );
        is( $diagnostic->params->[0]{value}, 'bogus',  'unknown format remains structured data' );
    }
}

is( $parent->contents_count, 0, 'rejected append and derive operations leave the parent unchanged' );
is( $leaf->contents_count,   0, 'rejected leaf append leaves the leaf unchanged' );

done_testing;
