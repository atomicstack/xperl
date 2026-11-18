package XStats::Functions;
use strict;
use warnings;
use Exporter 'import';
use XStats::Full ();
our $VERSION = '0.01';
my @data_functions =
  qw(count sum sum_of_squares min max mean variance standard_deviation
  population_variance population_standard_deviation mean_stddev harmonic_mean geometric_mean skewness excess_kurtosis kurtosis median
  quantile order_statistic trimmed_mean mode interquartile_range median_absolute_deviation resample
  bootstrap_distribution bootstrap_interval interval_from_distribution covariance correlation linear_regression linear_trend exponential_smoothing
  range min_index max_index values sorted_values histogram summary filter_outlier);

my @probability_functions = qw(erf erfc erf_inv erfc_inv normal_cdf normal_survival
  normal_quantile normal_inverse_survival sigma_to_alpha alpha_to_sigma);
our @EXPORT_OK = ( @data_functions, @probability_functions );

for my $name (@data_functions) {
    my $method = XStats::Full->can($name);
    no strict 'refs';
    *{$name} = sub {
        my $data = shift;
        unshift @_, XStats::Full->new($data);
        goto &$method;
    };
}
for my $name (@probability_functions) {
    no strict 'refs';
    *{$name} = sub {
        XStats::Full::_invalid_argument( 'INVALID_ARITY', $name ) unless @_ == 1;
        return XStats::Full::_probability_function( $_[0], $name );
    };
}
1;

=head1 NAME

XStats::Functions - Functions for native descriptive statistics

=head1 SYNOPSIS

    use XStats::Functions qw(mean_stddev);
    my ($mean, $stddev) = mean_stddev(\@values);

=head1 DESCRIPTION

Descriptive and resampling functions accept an array reference followed by the corresponding XStats::Full
method arguments. Nothing is exported by default. See L<XStats> for the
numerical contract. Input conversion occurs once for each call.
Delegation to the object method preserves the public caller for module-owned
diagnostics and lexical language selection.

=head1 PROBABILITY FUNCTIONS

C<erf($x)> and C<erfc($x)> use the configured NV error functions.
C<erf_inv($y)> accepts [-1,1]; C<erfc_inv($q)> accepts [0,2].
Their mathematical endpoints return signed infinity.  NaN and values outside
their domains raise module-owned conditions.

C<normal_cdf($z)> is P(Z E<lt>= z) for a standard normal variable.
C<normal_survival($z)> is P(Z E<gt> z), evaluated directly to retain small
upper tails.  C<normal_quantile($p)> and
C<normal_inverse_survival($q)> invert these functions on [0,1].
Probability endpoints return the corresponding signed infinities.

C<sigma_to_alpha($sigma)> is the two-sided probability P(|Z| E<gt> sigma),
for nonnegative sigma.  C<alpha_to_sigma($alpha)> inverts it on [0,1].
Alpha zero returns infinity and alpha one returns zero sigma.  Infinite
inputs to the forward functions have their mathematical limiting values.
Tiny output probabilities may naturally underflow to zero.

These functions accept one scalar, unlike the array-based descriptive
functions.  They do not create a Full object or alter Perl's random state.
Native libm operations use the configured NV and active hardware rounding
mode.  Inverses use monotone brackets, with a log-erfc asymptotic expansion
for subnormal tails.  Results are numerical approximations, without a
universal correctly-rounded or ulp guarantee.  Missing native NV error
functions raise C<XStats::UNSUPPORTED_MATH> rather than narrowing the type.

=cut
