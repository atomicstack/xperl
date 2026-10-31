#!/usr/bin/perl -w

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
}

{
    package HashOALocalizeScalar;

    sub TIESCALAR {
        my ($class, $hash) = @_;
        return bless { hash => $hash, value => 'original', grew => 0 }, $class;
    }

    sub FETCH {
        my ($self) = @_;
        unless ($self->{grew}++) {
            $self->{hash}{"growth:$_"} = $_ for 0 .. 2047;
        }
        return $self->{value};
    }

    sub STORE {
        $_[0]{value} = $_[1];
    }
}

my %hash;
tie $hash{target}, 'HashOALocalizeScalar', \%hash;

{
    local $hash{target} = 'localized';
    is($hash{'growth:2047'}, 2047,
       'magic during localization can grow the same hash');
}

is($hash{target}, 'original', 'localized hash element is restored');
is(scalar(keys %hash), 2049, 'growth entries remain present after restore');

my $linear_localize = <<'PERL';
package LinearLocalizeMagic;
sub TIESCALAR { bless { hash => $_[1], limit => $_[2], fetched => 0 }, $_[0] }
sub FETCH {
    my ($self) = @_;
    unless ($self->{fetched}++) {
        delete $self->{hash}{first};
        $self->{hash}{"growth:$_"} = $_ for 0 .. $self->{limit} - 1;
    }
    return 'original';
}
sub STORE { }

my $limit = shift;
my %hash;
$hash{first} = 1;
tie $hash{target}, 'LinearLocalizeMagic', \%hash, $limit;
{
    local $hash{target} = 'localized';
    die "linear localization lost growth\n"
        unless exists $hash{"growth:" . ($limit - 1)};
}
die "linear localization failed to restore\n"
    unless $hash{target} eq 'original';
die "linear deletion failed\n" if exists $hash{first};
print "ok\n";
PERL

for my $limit (2, 4, 8) {
    my ($out, $err) = runperl_and_capture(
        { PERL_HASH_LINEAR_MAX => $limit },
        ['-I../lib', '-e', $linear_localize, $limit]);
    is($out, "ok\n", "localization survives delete and promotion at limit $limit")
        or diag $err;
}

my ($croak_out, $croak_err) = runperl_and_capture(
    { PERL_HASH_LINEAR_MAX => 2 },
    ['-I../lib', '-e', <<'PERL']);
package LinearLocalizeCroak;
sub TIESCALAR { bless {}, $_[0] }
sub FETCH { die "FETCH croaked\n" }
sub STORE { }

my %hash;
$hash{other} = 1;
tie $hash{target}, 'LinearLocalizeCroak';
my $ok = eval { local $hash{target} = 'localized'; 1 };
die "FETCH did not croak\n" if $ok;
die "croaking localization damaged hash\n"
    unless $@ =~ /FETCH croaked/ && exists $hash{other}
        && exists $hash{target};
print "ok\n";
PERL
is($croak_out, "ok\n", 'croaking magic during localization cleans up the saved key')
    or diag $croak_err;

SKIP: {
    skip('threads unavailable', 4)
        unless eval { require threads; 1 };

    {
        package HashOATiedIterator;
        sub TIEHASH { bless { data => {}, remaining => [] }, $_[0] }
        sub STORE { $_[0]{data}{$_[1]} = $_[2] }
        sub FETCH { $_[0]{data}{$_[1]} }
        sub EXISTS { exists $_[0]{data}{$_[1]} }
        sub DELETE { delete $_[0]{data}{$_[1]} }
        sub CLEAR { %{$_[0]{data}} = () }
        sub FIRSTKEY {
            my ($self) = @_;
            $self->{remaining} = [sort keys %{$self->{data}}];
            return shift @{$self->{remaining}};
        }
        sub NEXTKEY { shift @{$_[0]{remaining}} }
    }

    tie my %tied, 'HashOATiedIterator';
    @tied{qw(a b c)} = qw(1 2 3);
    is(scalar each %tied, 'a', 'tied hash iterator is positioned before clone');
    my $thr = threads->create(sub {
        my @items;
        while (my ($key, $value) = each %tied) {
            push @items, "$key=$value";
        }
        return join ',', @items;
    });
    is($thr->join, 'b=2,c=3', 'thread clone resumes tied hash iteration');

    my %empty;
    keys %empty;
    my $empty_thr = threads->create(sub { scalar keys %empty });
    is($empty_thr->join, 0, 'thread clone preserves empty hash iterator state');

    tie my %empty_tied, 'HashOATiedIterator';
    scalar each %empty_tied;
    my $empty_tied_thr = threads->create(sub { scalar keys %empty_tied });
    is($empty_tied_thr->join, 0,
       'thread clone preserves empty magical hash iterator state');
}

done_testing();
