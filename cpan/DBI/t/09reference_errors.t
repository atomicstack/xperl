#!perl

use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken);
use DBI;

plan skip_all => 'requires local handles' if $ENV{DBI_AUTOPROXY};

{
    package DBI::Test::ReferenceError;
    use overload '""' => sub { $_[0]{text} }, '0+' => sub { 42 }, fallback => 1;
    sub DESTROY { ++${ $_[0]{released} } }
}

for my $field (qw(err errstr state)) {
    for my $clear (qw(explicit dispatch)) {
        my $dbh = DBI->connect('dbi:Sponge:', '', '', {
            RaiseError => 0, PrintError => 0,
        });
        my $released = 0;
        my $value = bless { text => $field eq 'state' ? 'AA123' : '42',
                            released => \$released }, 'DBI::Test::ReferenceError';
        my $weak = $value;
        weaken($weak);
        my @error = (42, 'example error', 'AA123');
        my %position = (err => 0, errstr => 1, state => 2);
        $error[$position{$field}] = $value;
        $dbh->set_err(@error);
        @error = ();
        undef $value;

        isa_ok($dbh->$field, 'DBI::Test::ReferenceError', "$field retains its value");
        ok(defined $weak, "$field keeps its reference alive before $clear clearing");
        if ($clear eq 'explicit') {
            $dbh->set_err(undef, undef);
        }
        else {
            is($dbh->quote('ok'), "'ok'", 'a normal method clears the previous error');
        }
        ok(!defined $weak, "$clear clearing releases the $field reference");
        is($released, 1, "$clear clearing destroys the $field value once");
        is($dbh->err, undef, 'error code is cleared');
        is($dbh->errstr, undef, 'error text is cleared');
        is($dbh->state, '', 'SQL state is cleared');
    }
}

{
    my $dbh = DBI->connect('dbi:Sponge:', '', '', {
        RaiseError => 0, PrintError => 0,
    });
    my $released = 0;
    my $state = bless { text => 'AA123', released => \$released },
        'DBI::Test::ReferenceError';
    my $weak = $state;
    weaken($weak);
    $dbh->set_err(42, 'first error', $state);
    undef $state;
    $dbh->set_err(43, 'replacement error');
    ok(!defined $weak, 'a replacement error releases the previous state reference');
    is($released, 1, 'the previous SQL state is destroyed once');
    is($dbh->state, 'S1000', 'missing SQL state keeps the general-error fallback');
}

{
    package DBI::Test::ReentrantError;
    use overload '""' => sub { $_[0]{text} }, '0+' => sub { 42 }, fallback => 1;
    sub DESTROY {
        my ($self) = @_;
        my $dbh = $self->{dbh};
        $self->{observed}->([ $dbh->err, $dbh->errstr, $dbh->state ]);
        $dbh->set_err(91, 'nested error', 'BB123');
    }
}

for my $field (qw(err errstr state)) {
    for my $clear (qw(explicit dispatch)) {
        my $dbh = DBI->connect('dbi:Sponge:', '', '', {
            RaiseError => 0, PrintError => 0,
        });
        my @observed;
        my $value = bless {
            dbh => $dbh,
            text => $field eq 'state' ? 'AA123' : 'old error',
            observed => sub { @observed = @{ $_[0] } },
        }, 'DBI::Test::ReentrantError';
        my @error = (42, 'old error', 'AA123');
        my %position = (err => 0, errstr => 1, state => 2);
        $error[$position{$field}] = $value;
        $dbh->set_err(@error);
        @error = ();
        undef $value;
        if ($clear eq 'explicit') {
            $dbh->set_err(undef, undef);
        }
        else {
            $dbh->quote('ok');
        }
        is_deeply(\@observed, [undef, undef, ''],
            "$clear clearing finishes before the $field destructor runs");
        is_deeply([$dbh->err, $dbh->errstr, $dbh->state], [91, 'nested error', 'BB123'],
            "$clear clearing preserves an error set by the $field destructor");
        $dbh->set_err(undef, undef);
    }
}

done_testing;
