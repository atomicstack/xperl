package XStats::Sparse;
use strict;
use warnings;
use XStats ();
our $VERSION = '0.01';
sub new   { XStats::_sparse_new( $_[0] ) }
sub add   { XStats::add(@_) }
sub merge { XStats::_merge(@_) }
sub _stat { XStats::_stat(@_) }
sub clear { XStats::clear(@_) }

for my $name (
    qw(count sum sum_of_squares min max mean variance standard_deviation
    population_variance population_standard_deviation mean_stddev range min_index max_index summary)
  )
{
    no strict 'refs';
    *{$name} = XStats->can($name);
}
1;

=head1 NAME

XStats::Sparse - Statistics without retaining observations

=head1 DESCRIPTION

C<new> creates an empty accumulator. C<add(\@values)> adds a batch atomically.
C<merge($other)> combines accumulators, including self-merge, which duplicates
observations. Both mutators return the receiving object. Storage is bounded.
C<clear> empties the accumulator for reuse and returns it. C<range>,
C<min_index> and C<max_index> use the same rules as the stored-data object.
Observation access is unavailable because observations are not retained.
C<sum_of_squares> uses exact products and final nearest-even rounding, with
overflow independent of the other summaries.
C<summary> returns the same fixed schema as stored objects.  Quartiles are
undef with C<requires_stored_data> reasons.  Other unavailable results have
independent reasons, so overflowing sums do not suppress finite means or SD.
The count is limited to U32. See L<XStats> for numerical conventions.

=cut
