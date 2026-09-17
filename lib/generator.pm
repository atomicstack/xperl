package generator;

use v5.40;

sub import {
    require feature;
    feature->import('generator', 'signatures');
}

1;

=head1 NAME

generator - enable generator syntax and generator object methods

=head1 SYNOPSIS

    use generator;

    my $g = gen {
        yield 1;
    };

    $g->exhausted();
    generator::exhausted($g);

=head1 DESCRIPTION

This pragma enables the experimental C<generator> and C<signatures> features.
It also loads the C<generator> package, whose predicate methods can be called
on a generator or as package functions.  It is equivalent to:

    use feature qw(generator signatures);

The declarations apply from the point of the C<use generator> statement to
the end of the current lexical scope.  The pragma is the normal entry point
for code that uses generators, especially parameterized generators.  Code
that only needs the two generator keywords can use C<use feature 'generator'>
instead.

The C<gen> and C<yield> constructs are feature syntax.  Generators are blessed
into package C<generator> and remain callable as CODE references.  The
predicate methods are C<exhausted>, C<completed>, C<failed>, and C<running>;
the same names can be called as C<generator::> package functions.

See L<perlgenerator> for the complete guide.

=cut
