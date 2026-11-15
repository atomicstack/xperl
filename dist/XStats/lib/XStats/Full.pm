package XStats::Full;
use strict;
use warnings;
use parent 'XStats';
our $VERSION = '0.01';
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
