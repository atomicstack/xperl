package iterator;

use v5.40;

sub RUNNING   () { 1 }
sub COMPLETED () { 2 }
sub FAILED    () { 3 }

sub next_val {
    my $iterator = shift;
    return $iterator->(@_);
}

sub restartable {
    return;
}

sub restart {
    die "iterator does not support restarting\n";
}

1;

=head1 NAME

iterator - lifecycle protocol for callable iterators

=head1 DESCRIPTION

The C<iterator> package provides the lifecycle protocol used by callable
iterators.  An iterator is a blessed code reference, so it remains callable
with the normal Perl syntax.

The C<next_val> method is a convenience spelling for calling that code
reference.  It forwards all arguments and preserves the caller's context.

The constructor marks the code reference as C<RUNNING>.  The iterator body can
    use C<__SUB__> to set its state before returning its final value:

    my $it = iterator->new(sub {
        state $i = 0;
        __SUB__->set_state(iterator::COMPLETED) if $i == $#items;
        return $items[$i++];
    });

The state describes whether another call may produce a value.  A completed
iterator may still return its final value on the call that marks it completed.
An empty return is therefore not, by itself, evidence of exhaustion.

An iterator is expected to maintain this state accurately.  In particular, it
must mark itself C<COMPLETED> when it has no more results to produce.  This is
what allows callers to distinguish an ordinary empty return from the end of a
sequence.  Perl does not automatically mark an iterator C<FAILED> when its
body dies; the iterator implementation or its caller decides whether that is
the appropriate state.

The C<generator> package is a specialized iterator.  Its continuation and
state behavior are documented separately.

The usual spelling for the current callable is C<__SUB__>.  Its fully
qualified spelling, C<CORE::__SUB__>, is also available when the unqualified
keyword is not enabled.

The default iterator is not restartable.  Classes that can recreate their
sequence may override C<restartable> and C<restart>; the base C<restart>
method reports that restarting is unsupported.

=cut
