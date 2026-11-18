package XStats::Full;
use strict;
use warnings;
use XStats ();
our $VERSION = '0.01';

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
    return XStats::Full::_mean_stddev( $self, $options{population} // 0 );
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
    XStats::Full::_summary( $_[0] );
}

sub histogram {
    _invalid_argument( 'INVALID_OPTION_LIST', 'histogram' ) unless @_ % 2;
    my ( $self, %options ) = @_;
    _invalid_argument( 'UNKNOWN_OPTION', 'histogram' )
      if grep { !/\A(?:edges|bins|range|closed)\z/ } keys %options;
    my $explicit = exists $options{edges};
    _invalid_argument( 'CONFLICTING_BIN_OPTIONS', 'histogram' )
      if $explicit && ( exists $options{bins} || exists $options{range} );
    return XStats::Full::_histogram(
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

=head1 NAME

XStats::Full - Statistics with retained observations

=head1 SYNOPSIS

    use XStats::Full;
    my $stats = XStats::Full->new([1, 2, 3]);
    my $median = $stats->median;

=head1 DESCRIPTION

Retain observations in insertion order for descriptive statistics, selection,
resampling and paired calculations.  Values use Perl's configured NV type.
See L<XStats> for methods and numerical conventions.

=cut
