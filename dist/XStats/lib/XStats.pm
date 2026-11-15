package XStats;

use strict;
use warnings;
use XPerl::Diagnostic::Catalog;

our $VERSION = '0.01';

{

    package XStats::Diagnostic::InvalidArgument;
    our @ISA = ('XPerl::Diagnostic::Error::Numeric::Domain');
}

my %argument_rules = (
    TOO_MANY_VALUES =>
      [ 'TooManyValues', 'XStats: %{argument} exceeds the supported array extent' ],
    INVALID_NUMERIC_VALUE =>
      [ 'NumericValue', 'XStats: %{argument} must be a plain number' ],
    INVALID_NUMERIC_ARRAY =>
      [ 'NumericArray', 'XStats: %{argument} must be a plain array of finite numbers' ],
    INVALID_BIN_EDGES => [
        'BinEdges',
        'XStats: %{argument} must contain at least two strictly increasing edges'
    ],
    INVALID_BIN_COUNT => [
        'BinCount',
        'XStats: %{argument} must be a positive U32 integer with room for its edges'
    ],
    INVALID_BIN_RANGE =>
      [ 'BinRange', 'XStats: %{argument} must contain two ordered finite endpoints' ],
    INVALID_BIN_CLOSURE =>
      [ 'BinClosure', 'XStats: %{argument} must be left or right' ],
    COLLAPSED_BIN_EDGES => [
        'CollapsedBinEdges', 'XStats: %{argument} produces indistinguishable bin edges'
    ],
    CONFLICTING_BIN_OPTIONS => [
        'ConflictingBinOptions',
        'XStats: %{argument} cannot combine edges with bins or range'
    ],
    STORED_DATA_REQUIRED =>
      [ 'StoredData', 'XStats: %{argument} requires stored observations' ],
    INVALID_PROBABILITY => [
        'Probability',
        'XStats: %{argument} must be a plain finite number between zero and one'
    ],
    INVALID_RANK =>
      [ 'Rank', 'XStats: %{argument} must be an integer from one through count' ],
    INVALID_QUANTILE_METHOD =>
      [ 'QuantileMethod', 'XStats: %{argument} must be linear or empirical' ],
    INVALID_TRIM_FRACTIONS =>
      [ 'TrimFractions', 'XStats: %{argument} must sum to less than one' ],
    INVALID_OPTION_LIST =>
      [ 'OptionList', 'XStats: %{argument} requires key/value options' ],
    UNKNOWN_OPTION => [ 'UnknownOption', 'XStats: unknown option for %{argument}' ],
    INVALID_SMOOTHING_WEIGHTS => [
        'SmoothingWeights',
        'XStats: %{argument} must be positive weights matching the observations'
    ],
    INVALID_ADJUSTMENT => [ 'Adjustment', 'XStats: %{argument} must be zero or one' ],
    INVALID_FILTER     => [ 'Filter', 'XStats: %{argument} must be a code reference' ],
    INVALID_MINIMUM_COUNT =>
      [ 'MinimumCount', 'XStats: %{argument} must be a positive U32 integer' ],
    INVALID_BOOTSTRAP_STATISTIC =>
      [ 'BootstrapStatistic', 'XStats: bootstrap %{argument} must be mean or median' ],
    INVALID_RESAMPLE_COUNT =>
      [ 'ResampleCount', 'XStats: %{argument} must be a positive U32 integer' ],
    INVALID_SEED => [ 'Seed', 'XStats: %{argument} must be an unsigned U32 integer' ],
    INVALID_INTERVAL_METHOD =>
      [ 'IntervalMethod', 'XStats: %{argument} must be percentile or basic' ],
    INVALID_CONFIDENCE =>
      [ 'Confidence', 'XStats: %{argument} must be strictly between zero and one' ],
    INVALID_MATH_DOMAIN =>
      [ 'MathDomain', 'XStats: value outside the domain of %{argument}' ],
    INVALID_ARITY =>
      [ 'Arity', 'XStats: incorrect number of arguments for %{argument}' ],
);

my $diagnostics = XPerl::Diagnostic::Catalog->define(
    namespace  => 'XStats',
    conditions => {
        (
            map {
                $_ => {
                    class => 'XStats::Diagnostic::InvalidArgument::'
                      . $argument_rules{$_}[0],
                    parent    => 'XStats::Diagnostic::InvalidArgument',
                    severity  => 'FATAL_ERROR',
                    params    => [ { name => 'argument', type => 'text' } ],
                    templates => { en => $argument_rules{$_}[1] },
                }
            } keys %argument_rules
        ),
        (
            map {
                my ( $code, $class, $message, $parent ) = @$_;
                $code => {
                    class     => "XStats::Diagnostic::$class",
                    parent    => $parent,
                    severity  => 'FATAL_ERROR',
                    params    => [ { name => 'operation', type => 'text' } ],
                    templates => { en => $message },
                }
            } (
                [
                    'NONZERO_OBSERVATIONS_REQUIRED',
                    'NonzeroObservations',
                    'XStats: %{operation} requires nonzero observations',
                    'XPerl::Diagnostic::Error::Numeric::Domain'
                ],
                [
                    'NONNEGATIVE_OBSERVATIONS_REQUIRED',
                    'NonnegativeObservations',
                    'XStats: %{operation} requires nonnegative observations',
                    'XPerl::Diagnostic::Error::Numeric::Domain'
                ],
                [
                    'UNDEFINED_STATISTIC',
                    'UndefinedStatistic',
                    'XStats: %{operation} is undefined for these observations',
                    'XPerl::Diagnostic::Error::Numeric::Domain'
                ],
                [
                    'UNSUPPORTED_MATH',
                    'UnsupportedMath',
                    'XStats: %{operation} requires native NV error-function support',
                    'XPerl::Diagnostic::Error::Numeric'
                ],
                [
                    'NUMERICAL_RESOLUTION',
                    'NumericalResolution',
                    'XStats: %{operation} cannot be resolved at NV precision',
                    'XPerl::Diagnostic::Error::Numeric'
                ],
            )
        ),
        INPUT_OUT_OF_RANGE => {
            class     => 'XStats::Diagnostic::InputOutOfRange',
            parent    => 'XPerl::Diagnostic::Error::Numeric',
            severity  => 'FATAL_ERROR',
            params    => [ { name => 'argument', type => 'text' } ],
            templates =>
              { en => 'XStats: numeric input for %{argument} is out of range' },
        },
        RESULT_OVERFLOW => {
            class     => 'XStats::Diagnostic::ResultOverflow',
            parent    => 'XPerl::Diagnostic::Error::Numeric',
            severity  => 'FATAL_ERROR',
            params    => [ { name => 'statistic', type => 'text' } ],
            templates => { en => 'XStats: numerical overflow in %{statistic}' },
        },
        INSUFFICIENT_OBSERVATIONS => {
            class    => 'XStats::Diagnostic::InsufficientObservations',
            parent   => 'XPerl::Diagnostic::Error::Numeric::Domain',
            severity => 'FATAL_ERROR',
            params   => [
                { name => 'operation', type => 'text' },
                { name => 'actual',    type => 'uv' },
                { name => 'required',  type => 'uv' },
            ],
            templates => {
                en =>
'XStats: %{operation} requires observations (need %{required}, got %{actual})'
            },
        },
        NUMERICAL_INVARIANT => {
            class     => 'XStats::Diagnostic::NumericalInvariant',
            parent    => 'XPerl::Diagnostic::Error::Internal::Numeric',
            severity  => 'FATAL_ERROR',
            params    => [ { name => 'operation', type => 'text' } ],
            templates =>
              { en => 'XStats: invalid arithmetic state during %{operation}' },
        },
    },
);

sub _exception_at {
    my ( $condition, $values, $file, $line ) = @_;
    my $exception = XPerl::Exception->_new;
    $exception->append(
        $diagnostics->_capture( $condition, $values, $file, $line, 1 ) );
    $exception->_record_throw( { reason => 'throw', file => $file, line => $line } );
    return $exception;
}

require XSLoader;
XSLoader::load( __PACKAGE__, $VERSION );

for my $name (
    qw(count sum sum_of_squares min max mean variance standard_deviation range min_index max_index)
  )
{
    no strict 'refs';
    *{$name} = sub { die "Unexpected arguments" if @_ != 1; $_[0]->_stat($name) };
}
sub values        { die "Unexpected arguments" if @_ != 1; $_[0]->_values }
sub sorted_values { die "Unexpected arguments" if @_ != 1; $_[0]->_values(1) }

sub population_variance {
    die "Unexpected arguments" if @_ != 1;
    $_[0]->_stat( 'variance', 1 );
}

sub population_standard_deviation {
    die "Unexpected arguments" if @_ != 1;
    $_[0]->_stat( 'standard_deviation', 1 );
}

sub mean_stddev {
    die "Options must be key/value pairs" unless @_ % 2;
    my ( $self, %options ) = @_;
    die "mean_stddev requires list context" unless wantarray;
    die "Unknown option" if grep { $_ ne 'population' } keys %options;
    return XStats::_mean_stddev( $self, $options{population} // 0 );
}

sub quantile {
    _invalid_argument( 'INVALID_OPTION_LIST', 'quantile' )
      unless @_ >= 2 && @_ % 2 == 0;
    my ( $self, $p, %options ) = @_;
    _invalid_argument( 'UNKNOWN_OPTION', 'quantile' )
      if grep { $_ ne 'method' } keys %options;
    my $method = exists $options{method} ? $options{method} : 'linear';
    _invalid_argument( 'INVALID_QUANTILE_METHOD', 'method' )
      if !defined($method) || ref($method);
    return $self->_quantile( $p, $method );
}

sub order_statistic {
    _invalid_argument( 'INVALID_ARITY', 'order_statistic' ) unless @_ == 2;
    $_[0]->_order_statistic( $_[1] );
}
sub mode { _invalid_argument( 'INVALID_ARITY', 'mode' ) unless @_ == 1; $_[0]->_mode }

sub trimmed_mean {
    _invalid_argument( 'INVALID_OPTION_LIST', 'trimmed_mean' ) unless @_ % 2;
    my ( $self, %options ) = @_;
    _invalid_argument( 'UNKNOWN_OPTION', 'trimmed_mean' )
      if grep { $_ ne 'lower' && $_ ne 'upper' } keys %options;
    return $self->_trimmed_mean(
        exists $options{lower} ? $options{lower} : 0,
        exists $options{upper} ? $options{upper} : 0
    );
}

sub summary {
    _invalid_argument( 'INVALID_ARITY', 'summary' ) unless @_ == 1;
    XStats::_summary( $_[0] );
}

sub histogram {
    _invalid_argument( 'INVALID_OPTION_LIST', 'histogram' ) unless @_ % 2;
    my ( $self, %options ) = @_;
    _invalid_argument( 'UNKNOWN_OPTION', 'histogram' )
      if grep { !/\A(?:edges|bins|range|closed)\z/ } keys %options;
    my $explicit = exists $options{edges};
    _invalid_argument( 'CONFLICTING_BIN_OPTIONS', 'histogram' )
      if $explicit && ( exists $options{bins} || exists $options{range} );
    return XStats::_histogram(
        $self,
        $explicit               ? $options{edges}  : $options{range},
        exists $options{bins}   ? $options{bins}   : 10,
        exists $options{closed} ? $options{closed} : 'left',
        $explicit,
        exists $options{range}
    );
}

sub _shape_options {
    my ( $operation, @args ) = @_;

    _invalid_argument( 'INVALID_OPTION_LIST', $operation ) if @args % 2;

    my %options = @args;
    _invalid_argument( 'UNKNOWN_OPTION', $operation )
      if grep { $_ ne 'adjusted' } keys %options;

    my $adjusted = exists $options{adjusted} ? $options{adjusted} : 1;
    _invalid_argument( 'INVALID_ADJUSTMENT', 'adjusted' )
      if !defined($adjusted) || ref($adjusted) || $adjusted !~ /\A[01]\z/;

    return $adjusted;
}

sub skewness {
    my $self = shift;

    return $self->_shape( 0, _shape_options( 'skewness', @_ ) );
}

sub excess_kurtosis {
    my $self = shift;

    return $self->_shape( 1, _shape_options( 'excess_kurtosis', @_ ) );
}
sub kurtosis { goto &excess_kurtosis }

sub filter_outlier {
    _invalid_argument( 'INVALID_ARITY', 'filter_outlier' ) unless @_ >= 2;

    my ( $self, $filter, @options ) = @_;

    _invalid_argument( 'INVALID_FILTER',      'filter' ) unless ref($filter) eq 'CODE';
    _invalid_argument( 'INVALID_OPTION_LIST', 'filter_outlier' ) if @options % 2;

    my %options = @options;
    _invalid_argument( 'UNKNOWN_OPTION', 'filter_outlier' )
      if grep { $_ ne 'min_count' } keys %options;

    # The callback may modify either object.  Keep its snapshot separate from
    # the result copy and return from the native helper before calling Perl.
    my $values = $self->values;
    require XStats::Full;
    my $snapshot = XStats::Full->new($values);
    my $minimum  = exists $options{min_count} ? $options{min_count} : 4;
    my $index    = $snapshot->_outlier_candidate($minimum);
    my $result = { values => $values, removed_index => undef, removed_value => undef };

    if ( defined $index ) {
        my $candidate = $values->[$index];

        # Rvalues keep argument aliases from changing the removal metadata.
        if ( $filter->( $snapshot, 0 + $candidate, 0 + $index ) ) {
            splice @$values, $index, 1;
            $result->{removed_index} = $index;
            $result->{removed_value} = $candidate;
        }
    }

    return $result;
}

sub exponential_smoothing {
    _invalid_argument( 'INVALID_OPTION_LIST', 'exponential_smoothing' ) unless @_ % 2;

    my ( $self, %options ) = @_;

    _invalid_argument( 'UNKNOWN_OPTION', 'exponential_smoothing' )
      if grep { $_ ne 'alpha' && $_ ne 'weights' } keys %options;

    _invalid_argument( 'INVALID_PROBABILITY', 'alpha' ) unless exists $options{alpha};

    return $self->_smooth( $options{alpha}, $options{weights},
        exists $options{weights} );
}

sub linear_trend {
    _invalid_argument( 'INVALID_ARITY', 'linear_trend' ) unless @_ == 1;

    my ($self) = @_;
    return $self->_linear_trend;
}

sub harmonic_mean {
    _invalid_argument( 'INVALID_ARITY', 'harmonic_mean' ) unless @_ == 1;

    my ($self) = @_;
    return $self->_nonlinear_mean(1);
}

sub geometric_mean {
    _invalid_argument( 'INVALID_ARITY', 'geometric_mean' ) unless @_ == 1;

    my ($self) = @_;
    return $self->_nonlinear_mean(0);
}

sub median {
    _invalid_argument( 'INVALID_ARITY', 'median' ) unless @_ == 1;

    return $_[0]->_quantile(0.5);
}

sub interquartile_range {
    _invalid_argument( 'INVALID_ARITY', 'interquartile_range' ) unless @_ == 1;

    return $_[0]->_interquartile_range;
}

sub median_absolute_deviation {
    _invalid_argument( 'INVALID_ARITY', 'median_absolute_deviation' ) unless @_ == 1;

    my ($self) = @_;
    my $median = $self->median;
    return $self->_mad($median);
}

sub _resampling_options {
    my ( $operation, @options ) = @_;
    _invalid_argument( 'INVALID_OPTION_LIST', $operation ) if @options % 2;

    my %options = @options;
    _invalid_argument( 'UNKNOWN_OPTION', $operation )
      if grep { !/\A(?:seed|resamples|statistic)\z/ } keys %options;

    return (
        exists $options{statistic} ? $options{statistic} : 'mean',
        exists $options{resamples} ? $options{resamples} : 10_000,
        exists $options{seed}      ? $options{seed}      : 1,
    );
}

sub resample {
    _invalid_argument( 'INVALID_OPTION_LIST', 'resample' ) unless @_ % 2;
    my ( $self, %options ) = @_;
    _invalid_argument( 'UNKNOWN_OPTION', 'resample' )
      if grep { $_ ne 'seed' } keys %options;

    return $self->_resample( 'mean', 1, exists $options{seed} ? $options{seed} : 1, 1 );
}

sub bootstrap_distribution {
    my $self = shift;

    return $self->_resample( _resampling_options( 'bootstrap_distribution', @_ ) );
}

sub bootstrap_interval {
    _invalid_argument( 'INVALID_OPTION_LIST', 'bootstrap_interval' ) unless @_ % 2;
    my ( $self, %options ) = @_;
    my $confidence = exists $options{confidence} ? delete $options{confidence} : 0.95;
    my $method     = exists $options{method} ? delete $options{method} : 'percentile';

    return $self->_bootstrap_interval(
        _resampling_options( 'bootstrap_interval', %options ),
        $confidence, $method );
}

sub interval_from_distribution {
    _invalid_argument( 'INVALID_OPTION_LIST', 'interval_from_distribution' )
      unless @_ % 2;
    my ( $self, %options ) = @_;
    _invalid_argument( 'UNKNOWN_OPTION', 'interval_from_distribution' )
      if grep { !/\A(?:estimate|confidence|method)\z/ } keys %options;

    return $self->_interval_from_distribution(
        $options{estimate},
        exists $options{confidence} ? $options{confidence} : 0.95,
        exists $options{method}     ? $options{method}     : 'percentile',
    );
}

for my $name (qw(covariance correlation linear_regression)) {
    no strict 'refs';
    *{$name} = sub {
        _invalid_argument( 'INVALID_ARITY', $name ) unless @_ == 2;
        $_[0]->_paired( $_[1], $name );
    };
}

1;

__END__

=head1 NAME

XStats - XS statistics library

=head1 SYNOPSIS

    use XStats;

=head1 DESCRIPTION

XStats::Full retains finite numeric observations in a packed native array
inside a blessed scalar's PV. Numeric strings are accepted. Undef, references,
sparse slots, magical values, tied arrays, NaN and infinities are rejected.
Integers are converted to Perl's NV type and may lose precision. A requested
result outside the finite NV range raises an exception. An overflowing sum
does not prevent a finite mean or median, or later additions that cancel it.

Numeric SVs use their stored numeric value, including dualvars.  String
observations and probabilities follow Perl's numeric string rules and convert directly in the
numerical backend without setting an NV cache on the input scalar.
Overflow and nonzero strings that round to zero raise
C<XStats::INPUT_OUT_OF_RANGE>, with an C<argument> parameter.
Representable subnormal inputs are accepted.

C<XStats::Sparse> retains bounded incremental summaries instead of the
observations.  Both classes use Perl's configured NV type.  C<XStats> and
C<XStats::Incremental> remain available as the original constructor names.

C<harmonic_mean> accepts nonzero signed values and sums scaled, rounded
NV reciprocals exactly before one final rational division.  Reciprocal
underflow or a zero sum at NV precision raises C<NUMERICAL_RESOLUTION>.
Mixed-sign inputs also raise this condition when the reciprocal sum is
indistinguishable from zero within a conservative division-error bound.
The bound is count times one NV ulp at one after scaling the quotients to
magnitudes at most one.  This can reject ill-conditioned signed inputs
whose exact denominator is nonzero.
C<geometric_mean> accepts nonnegative values and returns zero when any value
is zero, after checking the entire domain.  It separates exact binary
exponents from rounded native logarithms and exponentials.
Both require stored observations.  Reciprocal divisions and libm calls use native
NV arithmetic and the active rounding mode; they are not promises of a
correctly rounded mathematical mean.  Constants are returned exactly.
Unresolvable results raise a structured condition instead of being clamped.

C<skewness> and C<excess_kurtosis> default to adjusted sample estimators;
C<adjusted =E<gt> 0> selects the unadjusted moment estimators.
C<kurtosis> is an alias for excess kurtosis, so a normal distribution has
population excess zero.  Adjusted skewness requires three observations and
adjusted kurtosis requires four; unadjusted queries require two.
Constant data has undefined shape and raises C<UNDEFINED_STATISTIC>.
These queries use centred, scaled NV products and exact sums of the rounded
products.  They are approximations, particularly for shape close to zero,
and reject detected arithmetic range loss with C<NUMERICAL_RESOLUTION>.

C<linear_regression(\@responses)> returns slope, intercept, count,
correlation, C<r_squared>, C<residual_rms>, and an C<unavailable> map.
Residual RMS divides the residual sum of squares by count, not count minus
two.  Its exact paired numerator is evaluated before rounding the fitted
coefficients, so exact fits have zero residual RMS.  A constant response has
a valid constant fit but undefined correlation and R squared, with
C<constant_response> reasons in C<unavailable>.

C<linear_trend> treats the stored observations as responses and uses
predictors 1 through count.  It returns the same fit structure.

C<filter_outlier(\&predicate, min_count =E<gt> 4)> considers at most one
observation: the one furthest from the exact arithmetic mean.  Ties use the
first insertion position.  The predicate receives an independent Full
snapshot, the candidate value and its zero-based insertion index.  A true
return removes that observation from the result copy.  A false return keeps
all observations.  Fewer than C<min_count> observations skip the predicate.
The minimum must be a positive U32 integer.

The result is C<{ values =E<gt> [...], removed_index =E<gt> ..., removed_value
=E<gt> ... }>.  Both removal fields are undef when nothing is removed.
The method does not modify the source object.  Callback mutations of the
snapshot or source do not affect the result copy or candidate selection.
Callback exceptions propagate unchanged.

C<exponential_smoothing(alpha =E<gt> $alpha)> returns a new array in
insertion order.  Alpha is the current-observation weight, between zero and
one inclusive: S[0] = x[0] and S[t] = (1-alpha)*S[t-1] + alpha*x[t].
Alpha zero repeats the first value; alpha one copies the input.

With C<weights =E<gt> \@weights>, require one positive finite weight per
observation.  Start W[0] = w[0] and use
p = alpha*w[t] / ((1-alpha)*W[t-1] + alpha*w[t]), then
S[t] = (1-p)*S[t-1] + p*x[t] and W[t] = (1-p)*W[t-1] + p*w[t].
These weights are smoothing metadata and do not change ordinary statistics.
Each recurrence is evaluated from the exact dyadic NV inputs before rounding
its result once, including the updated weight.  No intermediate NV products
or rounded p value are needed.  Equal weights reproduce ordinary smoothing.
Empty inputs return an empty array.

=head1 METHODS

C<new(\@values)> copies observations. C<add(\@values)> atomically appends
a batch and returns the receiving object. Allocation grows geometrically.
C<count>, C<sum> and C<sum_of_squares> return zero for an empty dataset. C<min>, C<max>, C<mean>, C<variance>, and
C<standard_deviation> require observations. Sample variance and standard
deviation require at least two observations and use denominator n-1.
C<population_variance> and C<population_standard_deviation> use denominator n.

C<values> returns an array reference containing a copy of the converted
observations in insertion order. C<sorted_values> returns a sorted copy.
Neither method changes the object. C<clear> empties an object and returns it
for reuse, retaining its allocated capacity.

C<range> returns max minus min and raises a result-overflow exception if
that difference cannot be represented.  Range uses exact subtraction and
final nearest-even rounding, including under directed hardware modes.
C<min_index> and C<max_index> return
zero-based observation positions, selecting the first occurrence of a tie.
These three methods require at least one observation. Incremental positions
follow batch insertion order and treat a merge as appending the source's
observations.

C<summary> returns an independent hash containing C<count>, C<sum>,
C<sum_of_squares>, C<min>, C<max>, C<min_index>, C<max_index>, C<range>,
C<mean>, C<variance>, C<standard_deviation>, C<population_variance>,
C<population_standard_deviation>, C<q1>, C<median>, C<q3> and C<unavailable>.
Quartiles use linear interpolation.  One sorted copy serves all three.
Unavailable fields are undef, with reasons in the C<unavailable> hash:
C<empty>, C<insufficient_observations>, C<overflow> or C<requires_stored_data>.
Count and both sums are zero for empty data.  Incremental quartiles always
use C<requires_stored_data>, including for empty accumulators.
Overflow in one result leaves other results available.  Invalid arithmetic
state raises an exception instead of becoming an unavailable result.
Summary queries support read-only objects and do not alter native storage.

C<histogram(bins =E<gt> $count)> generates equal-width bins spanning the
observations' minimum and maximum.  The default count is 10.  An explicit
C<range =E<gt> [$lower, $upper]> sets the endpoints and permits empty data.
C<histogram(edges =E<gt> \@edges)> accepts at least two finite, strictly
increasing edges after NV conversion.  Explicit edges cannot be combined
with C<bins> or C<range>.  Histogram input arrays follow the same plain,
finite numeric rules as observations.

C<closed =E<gt> 'left'> is the default: bins are left-closed/right-open,
except the last upper endpoint is included.  C<closed =E<gt> 'right'> uses
left-open/right-closed bins, except the first lower endpoint is included.
Interior boundaries belong to exactly one bin.  Values outside the range
are counted separately.

The returned hash contains copied C<edges>, integer C<counts>, C<underflow>,
C<overflow>, total observation C<count> and C<closed>.  Generated bins also
include C<requested_bins>.  Counts plus underflow and overflow equal count.
An equal range produces one point bin with edges C<[$value, $value]> and
retains the requested bin count.  Only observations equal to that point
belong to its bin.

Generated interior edge j is the exact affine value
((bins-j)*lower + j*upper)/bins, rounded once to nearest-even NV.  Endpoints
are copied exactly.  If rounding collapses adjacent edges, the request raises
C<XStats::COLLAPSED_BIN_EDGES>.  Counts must be positive U32 integers whose
edge and count buffers fit the platform's array extent.  Callers must choose
bin counts that fit available memory.  Histograms require stored observations.

C<mean_stddev> returns (mean, sample standard deviation) in list context.
C<mean_stddev(population =E<gt> 1)> requests population standard deviation.
Scalar and void context are errors.

C<order_statistic($rank)> returns the observation at a one-based sorted rank,
from 1 through C<count>. C<quantile($p)> uses linear interpolation at
zero-based position (n-1)*p (the type 7 convention), with p between zero and
one. The affine combination is evaluated exactly and rounded once to
nearest-even NV. C<quantile($p, method =E<gt> 'empirical')> selects rank
max(1, ceil(n*p)). C<median> uses the linear quantile at 0.5.
C<interquartile_range> is quantile 0.75 minus quantile 0.25, with one sort
and an exact checked difference of the rounded NV quartiles.  These operations
preserve insertion order.

Probabilities mean the exact converted NV value, without an epsilon at rank
boundaries. For example, binary64 0.1 is slightly greater than 1/10, so its
empirical quantile of ten observations selects rank 2. Use
C<order_statistic> when an exact rank is wanted.

C<trimmed_mean(lower =E<gt> $fraction, upper =E<gt> $fraction)> defaults both
fractions to zero. Fractions must be nonnegative with an exact sum less than
one. Remove floor(n*lower) and floor(n*upper) observations from the respective
ends. The retained observations are summed exactly, then divided and rounded
once to nearest-even. This method requires at least one observation.

C<mode> returns C<{values =E<gt> [...], frequency =E<gt> N}>. It reports every
mode in increasing numeric order. Empty input returns an empty array and
frequency zero. All-distinct data returns every value with frequency one.
Mode compares converted NVs directly, including adjacent representable values.

The object representation is private binary storage, not serialization.
Do not modify the referenced scalar. Sums of converted observations are exact
internally. Sum and mean round once to NV, using nearest-even rounding. These
results are independent of observation order and incremental partitioning.
C<sum_of_squares> accumulates exact products of converted observations and
rounds once to nearest-even NV. Tiny squares contribute before rounding,
even when each product would underflow. Square overflow is reported only
when that result is requested. Stored objects cache the result on demand.
Incremental objects retain a separate bounded exact square accumulator.
The exact accumulator supports binary64, x87 extended and binary128 NV formats.
Other NV formats raise an unsupported-backend exception.

Selection and trimming argument conditions inherit from
C<XStats::Diagnostic::InvalidArgument>. Their codes distinguish
C<INVALID_PROBABILITY>, C<INVALID_RANK>, C<INVALID_QUANTILE_METHOD>,
C<INVALID_TRIM_FRACTIONS>, C<INVALID_OPTION_LIST>, C<UNKNOWN_OPTION> and
C<INVALID_ARITY>. Each carries an C<argument> parameter. Validation wording
belongs to the diagnostic catalog, so callers can inspect stable codes and
class ancestry independently of the rendered message.
Empty scalar-summary queries use the module condition
C<XStats::INSUFFICIENT_OBSERVATIONS>, with C<operation>, C<actual> and
C<required> parameters. An overflowing sum uses C<XStats::RESULT_OVERFLOW>,
with a C<statistic> parameter. These diagnostics inherit from the core numeric
error classes and travel in an C<XPerl::Exception>. Other error paths are
being migrated to this experimental module-catalog mechanism.

Centred calculations retain a residual for the
running mean, and squared deviations are scaled so standard deviation can
remain representable even when variance underflows to zero. Results still
round to the configured NV type. Centred results across differently partitioned
incremental calculations are not guaranteed bit-identical.

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut

=head1 RESAMPLING

C<resample(seed =E<gt> $seed)> returns an array reference with the same number
of observations, drawn uniformly with replacement.

C<bootstrap_distribution(statistic =E<gt> 'mean', resamples =E<gt> 10000,
seed =E<gt> 1)> returns an array reference of bootstrap statistics. The other
supported statistic is C<median>. Working storage is reused inside the C loop.
Seeds are unsigned 32-bit integers. Repeat counts are positive U32 integers.
Callers must choose counts that fit available memory and execution time.

The current generator is xoshiro128**, initialized with four SplitMix32-style
mixed words. Rejection sampling avoids modulo bias in case selection. Each
call owns its RNG state, with seed 1 by default. Calls with identical inputs,
options, and seed reproduce draws within this implementation. This is not a
cryptographic RNG. Algorithm changes in future versions may change streams.
The application's RNG state is unaffected.

C<bootstrap_interval> accepts those options plus C<confidence> (default
0.95) and C<method> (C<percentile>, the default, or C<basic>).  It returns
C<estimate>, C<lower>, C<upper>, C<standard_error>, C<confidence>, C<method>,
C<statistic>, C<resamples> and C<seed> in a hash reference.

For confidence c, percentile bounds use type 7 quantiles at (1-c)/2 and
(1+c)/2.  Positions use the exact converted NV confidence without rounding
away the division by two.  Basic bounds are 2*estimate minus the upper and
lower NV quantiles respectively.  Reflection uses checked exact arithmetic,
so an overflowing intermediate 2*estimate does not lose a finite answer.
Bootstrap generation, sorting and bounds calculation use packed NV buffers
without an intermediate array of Perl scalars.  Medians use native selection
with a sort fallback for adversarial partitions.

C<interval_from_distribution(estimate =E<gt> $estimate, confidence =E<gt>
0.95, method =E<gt> 'percentile')> treats the receiver's stored values as a
supplied bootstrap distribution.  It preserves their insertion order and
returns the same result schema, with undef C<seed> and C<statistic>.
The functional form accepts the distribution array reference first.
The estimate must be finite, confidence strictly between zero and one, and
both interval methods require at least two bootstrap statistics.
Standard error is their sample standard deviation.

Ordinary case resampling assumes independent, representative observations.
Correlated data may require block resampling, which is not implemented.
Statistics::CaseResampling uses reflected/basic bounds, a different empirical
rank convention and different tail probabilities.  XStats uses conventional
two-sided confidence tails and its documented type 7 interpolation.

=head1 OTHER STATISTICS

C<median_absolute_deviation> returns raw, unscaled MAD around the median.
Each deviation is rounded from its exact difference.  A deviation outside
finite NV range raises C<NUMERICAL_RESOLUTION>, even if the median of all
deviations would be finite.  The method does not materialize infinite
intermediate values.

C<covariance(\@y)> returns sample covariance. C<correlation(\@y)> returns
Pearson correlation. C<linear_regression(\@y)> returns a hash with C<slope>,
C<intercept>, and C<count> for y = intercept + slope*x. These require equal
lengths and at least two observations. Correlation requires both inputs to
vary. Regression requires varying x values.  Undefined constant-input
correlation and constant-predictor regression raise C<UNDEFINED_STATISTIC>. Incremental objects do not
support these operations or resampling and order statistics.

Paired operations form raw products and centred numerators exactly from the
converted NV observations. Covariance, correlation and both regression
coefficients round once using nearest-even, including subnormal results and
signed underflow to zero. Regression computes the intercept independently
of the rounded slope. Intermediate products can exceed NV range. Only an
unrepresentable requested result raises a result-overflow exception.

The temporary arithmetic uses Perl-owned scratch storage and does not enlarge
the object. Scalar variance uses scaled compensated moments and can differ
from exact C<covariance($self-E<gt>values)> in the last bits.

=cut
