use strict;
use warnings;
use Test::More;
use B            qw(svref_2object SVp_IOK SVp_NOK);
use Scalar::Util qw(dualvar);
use XStats::Full;
use XStats::Sparse;
use XStats::Functions qw(mean);

for my $class ( 'XStats::Full', 'XStats::Sparse' ) {
    my $build =
      $class eq 'XStats::Full'
      ? sub { XStats::Full->new( $_[0] ) }
      : sub { XStats::Sparse->new->add( $_[0] ) };
    my @strings = ( " \t1.25\r\n", '1e2', '-2', '0 but true', '.5', '0e-999999' );
    my $mask    = SVp_IOK | SVp_NOK;
    my @before  = map { svref_2object( \$_ )->FLAGS & $mask } @strings;
    my $object  = $build->( \@strings );
    is( $object->sum, 99.75, "$class parses Perl numeric strings" );
    is_deeply( [ map { svref_2object( \$_ )->FLAGS & $mask } @strings ],
        \@before, "$class does not populate input numeric caches" );
    is( $build->( [ dualvar( 7, '1e999999' ) ] )->mean,
        7, "$class uses an integer dualvar's numeric value" );
    is( $build->( [ dualvar( 2.5, 'not a number' ) ] )->mean,
        2.5, "$class uses a floating dualvar's numeric value" );
    cmp_ok( $build->( ['1e-310'] )->sum,
        '>', 0, "$class accepts a representable tiny value" );

    for my $input ( '1e999999', '-1e999999', '1e-999999', '-1e-999999' ) {
        my $data = $build->( [ 1, 2 ] );
        my ( @warnings, $error );
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            eval { $data->add( [ 3, $input, 4 ] ) };
            $error = $@;
        }
        isa_ok( $error, 'XPerl::Exception', "$class range error for $input" );
        ok(
            $error->has_diagnostic(
                'XStats::INPUT_OUT_OF_RANGE', argument => 'values'
            ),
            'input range failure identifies the argument'
        );
        isa_ok( $error->find_diagnostic('XStats::INPUT_OUT_OF_RANGE'),
            'XStats::Diagnostic::InputOutOfRange' );
        is_deeply( \@warnings, [], 'conversion does not emit Perl warnings' );
        is( $data->count, 2, 'failed batch leaves the count unchanged' );
        is( $data->sum,   3, 'failed batch leaves the sum unchanged' );
    }
}

is( mean( [ '1.25', '2.75' ] ), 2, 'functions use the same string conversion' );
my $data = XStats::Full->new( [ 1, 2 ] );
is( $data->quantile( dualvar( .5, 'not a probability' ) ),
    1.5, 'probabilities use a dualvar numeric value' );
eval { $data->quantile('1e-999999') };
my $error = $@;
ok( $error->has_diagnostic( 'XStats::INPUT_OUT_OF_RANGE', argument => 'probability' ),
    'probabilities use direct conversion and range diagnostics' );

done_testing;
