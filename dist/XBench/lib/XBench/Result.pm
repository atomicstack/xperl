use v5.41;
use feature 'class';
no warnings 'experimental::class';

class XBench::Result;

use XStats::Full ();
use JSON::PP     ();

our $VERSION = '0.01';

field $name :param :reader;
field $iterations :param :reader;
field $elapsed :param :reader;
field $stop_reason :param :reader;
field $precision_met :param :reader;
field $confidence :param :reader;
field $resolution_floor :param :reader;
field $calibration_calls :param :reader;
field $warmup_calls :param :reader;
field $baseline_subtracted :param :reader;
field $settings :param;
field $environment :param;
field $raw :param;
field $adjusted :param;
field $baselines :param;
field $kept :param;
field $interval :param;
field $statistics;

ADJUST {
    $settings    = {%$settings};
    $environment = {%$environment};
    $raw         = [@$raw];
    $adjusted    = [@$adjusted];
    $baselines   = [@$baselines];
    $kept        = [@$kept];
    $interval    = {%$interval};
    $statistics  = XStats::Full->new($kept);
}

method mean                { $statistics->mean }
method standard_deviation  { $statistics->standard_deviation }
method standard_error      { $self->standard_deviation / sqrt( $self->samples ) }
method median              { $statistics->median }
method mad                 { $statistics->median_absolute_deviation }
method samples             { scalar @$kept }
method total_samples       { scalar @$raw }
method rejected            { $self->total_samples - $self->samples }
method raw_samples         { [@$raw] }
method adjusted_samples    { [@$adjusted] }
method baseline_samples    { [@$baselines] }
method kept_samples        { [@$kept] }
method confidence_interval { return {%$interval} }
method settings            { return {%$settings} }
method environment         { return {%$environment} }

method precision_error {
    my $mean        = $self->mean;
    my $error       = abs( $interval->{lower} - $mean );
    my $upper_error = abs( $interval->{upper} - $mean );

    $error = $upper_error if $upper_error > $error;
    return $error > $resolution_floor ? $error : $resolution_floor;
}

method relative_error {
    my $mean = $self->mean;
    return undef unless $mean > 0;

    return $self->precision_error / $mean;
}

method resolved {
    return $interval->{lower} > $resolution_floor ? 1 : 0;
}

method as_hash {
    return {
        name                => $name,
        units               => 'seconds_per_operation',
        mean                => $self->mean,
        standard_deviation  => $self->standard_deviation,
        standard_error      => $self->standard_error,
        median              => $self->median,
        mad                 => $self->mad,
        samples             => $self->samples,
        total_samples       => $self->total_samples,
        rejected            => $self->rejected,
        iterations          => $iterations,
        elapsed             => $elapsed,
        stop_reason         => $stop_reason,
        precision_met       => $precision_met,
        resolved            => $self->resolved,
        confidence          => $confidence,
        confidence_interval => $self->confidence_interval,
        precision_error     => $self->precision_error,
        relative_error      => $self->relative_error,
        resolution_floor    => $resolution_floor,
        calibration_calls   => $calibration_calls,
        warmup_calls        => $warmup_calls,
        baseline_subtracted => $baseline_subtracted,
        settings            => $self->settings,
        environment         => $self->environment,
        raw_samples         => $self->raw_samples,
        adjusted_samples    => $self->adjusted_samples,
        baseline_samples    => $self->baseline_samples,
        kept_samples        => $self->kept_samples,
    };
}

method as_json {
    return JSON::PP->new->canonical->encode( $self->as_hash );
}

method as_text {
    return sprintf "%s: mean %.9g s/op, SD %.9g; %.1f%% CI [%.9g, %.9g]; "
      . "%u/%u samples, %u ops/sample; %s\n",
      $name, $self->mean, $self->standard_deviation, 100 * $confidence,
      $interval->{lower}, $interval->{upper}, $self->samples,
      $self->total_samples, $iterations, $stop_reason;
}

1;

=head1 NAME

XBench::Result - Measurements and uncertainty from an XBench case

=head1 DESCRIPTION

Results use seconds per operation.  C<samples> counts retained measured
batches, while C<iterations> counts operations per batch.  C<mean>,
C<standard_deviation>, C<standard_error>, C<median> and C<mad> describe the
retained adjusted samples.  Standard error is sample SD divided by the
square root of the retained batch count.

C<confidence_interval> returns the bootstrap interval.  C<precision_error>
is its maximum distance from the mean, with a clock-resolution floor.
C<relative_error> is undef for nonpositive means.  C<resolved> requires the
lower confidence bound to exceed that floor.

C<raw_samples>, C<adjusted_samples>, C<baseline_samples> and C<kept_samples>
return independent array copies.  C<as_hash> and C<as_json> include these
arrays and the stopping and calibration metadata.  C<as_text> formats the
mean, sample SD and confidence interval explicitly.  None prints implicitly.
Settings and environment snapshots record the precision/filter choices,
interpreter, compiler, build flags, NV type and threading configuration.
Environment fields describe the benchmark driver.  Their accessors return
independent copies.
The environment's C<measurement> field distinguishes C<wall_clock> timings
from C<reported> batches; C<measurement_resolution> records their clock
resolution before division by C<iterations>.

Construct results through L<XBench>; their constructor is internal.

=cut
