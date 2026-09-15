package dispatch::Predicates;

use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use B ();
use Exporter 'import';
use Scalar::Util ();
use overload ();

our $VERSION = '0.01';
our @EXPORT = qw(
    Any Int Integer Num Number
    NonRefVal BlessedVal DefinedVal RefVal True False
);
our @EXPORT_OK = @EXPORT;
our %EXPORT_TAGS = (all => \@EXPORT_OK);

sub Any ($subject) { 1 }

sub _native_numeric ($subject) {
    return 0 if ref $subject;
    my $flags = B::svref_2object(\$subject)->FLAGS;
    return !!(($flags & (B::SVf_IOK() | B::SVf_NOK()))
              && !($flags & B::SVf_POK()));
}

sub _numeric_value ($subject) {
    return 0 unless defined $subject;
    if (ref $subject) {
        return 0 unless Scalar::Util::blessed($subject)
            && overload::Method($subject, '0+');
        return eval { no warnings; 0 + $subject; 1 } ? 1 : 0;
    }
    return 0 unless Scalar::Util::looks_like_number($subject);
    my $ok = eval { no warnings; 0 + $subject; 1 };
    return $ok ? 1 : 0;
}

sub Num ($subject) { _numeric_value($subject) }

sub Int ($subject) {
    return 0 unless _numeric_value($subject);
    return eval { no warnings; $subject == int($subject) ? 1 : 0 } || 0;
}

sub Number ($subject) { _native_numeric($subject) }

sub Integer ($subject) {
    return 0 unless _native_numeric($subject);
    my $flags = B::svref_2object(\$subject)->FLAGS;
    return !!($flags & B::SVf_IOK());
}

sub NonRefVal ($subject) { !ref $subject }
sub BlessedVal ($subject) { !!Scalar::Util::blessed($subject) }
sub DefinedVal ($subject) { defined $subject }
sub RefVal ($subject) { !!ref $subject }
sub True ($subject) { !!$subject }
sub False ($subject) { !$subject }

1;

__END__

=head1 NAME

dispatch::Predicates - standard predicates for dispatch-on patterns

=head1 DESCRIPTION

This module exports the standard predicates used in C<dispatch_on> data-shape
patterns. See L<perldispatchon/Shared predicates> for the predicate list and
semantics.

=cut
