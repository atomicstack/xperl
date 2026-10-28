package Diag::Documentation;

use strict;
use warnings;

# Keep spelling and whitespace in the documentation data. Nested lists belong
# to an explanation, and adjacent headings can share that explanation.
sub import_pod {
    my ($pod) = @_;
    my ($depth, $offset, $end) = (0, 0);
    my @starts;
    for my $line (split /(?<=\n)/, $pod) {
        if ($line =~ /^=over\b/) {
            ++$depth;
        }
        elsif ($line =~ /^=back\b/) {
            $end = $offset if $depth == 1 && @starts && !defined $end;
            die "unbalanced diagnostic POD list\n" if --$depth < 0;
        }
        elsif ($depth == 1 && $line =~ /^=item /) {
            die "multiple diagnostic POD lists\n" if defined $end;
            push @starts, $offset;
        }
        $offset += length $line;
    }
    die "unbalanced or missing diagnostic POD list\n"
        if $depth || !@starts || !defined $end;

    my @entries;
    my @headings;
    for my $i (0 .. $#starts) {
        my $stop = $i == $#starts ? $end : $starts[$i + 1];
        my $block = substr($pod, $starts[$i], $stop - $starts[$i]);
        my ($heading, $text) = $block =~ /\A=item (.*?\n\n)(.*)\z/s;
        die "diagnostic heading has no terminating blank line\n"
            unless defined $heading;
        push @headings, $heading;
        next if $text eq '' && $i != $#starts;
        push @entries, {
            code => sprintf('PERLDIAG_%04d', scalar(@entries) + 1),
            headings => [@headings],
            text => $text,
        };
        @headings = ();
    }
    return {
        intro => substr($pod, 0, $starts[0]),
        entries => \@entries,
        trailer => substr($pod, $end),
    };
}

sub render {
    my ($data) = @_;
    die "diagnostic documentation is not a hash reference\n"
        unless ref($data) eq 'HASH';
    for my $field (qw(intro trailer)) {
        die "diagnostic documentation has no $field text\n"
            unless defined $data->{$field} && !ref($data->{$field});
    }
    die "diagnostic documentation has no entries\n"
        unless ref($data->{entries}) eq 'ARRAY' && @{$data->{entries}};
    my %codes;
    my $pod = $data->{intro};
    for my $entry (@{$data->{entries}}) {
        die "invalid diagnostic documentation entry\n"
            unless ref($entry) eq 'HASH' && defined $entry->{code}
                && $entry->{code} =~ /\A[A-Z][A-Z0-9_]*\z/;
        die "duplicate documentation code $entry->{code}\n" if $codes{$entry->{code}}++;
        die "documentation $entry->{code} has no headings\n"
            unless ref($entry->{headings}) eq 'ARRAY' && @{$entry->{headings}};
        for my $heading (@{$entry->{headings}}) {
            die "documentation $entry->{code} has an invalid heading\n"
                unless defined $heading && !ref($heading) && $heading =~ /\n\n\z/;
            $pod .= '=item ' . $heading;
        }
        die "documentation $entry->{code} has no explanation\n"
            unless defined $entry->{text} && !ref($entry->{text});
        $pod .= $entry->{text};
    }
    return $pod . $data->{trailer};
}

1;
