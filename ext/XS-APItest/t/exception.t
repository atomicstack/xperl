use Test::More tests => 32;
use Scalar::Util qw(refaddr);

BEGIN { use_ok('XS::APItest') };

#########################

my $rv;

$XS::APItest::exception_caught = undef;

$rv = eval { apitest_exception(0) };
is($@, '');
ok(defined $rv);
is($rv, 42);
is($XS::APItest::exception_caught, 0);

$XS::APItest::exception_caught = undef;

$rv = eval { apitest_exception(1) };
is($@, "boo\n");
ok(not defined $rv);
is($XS::APItest::exception_caught, 1);

$rv = eval { mycroak("foobar\n"); 1 };
is($@, "foobar\n", 'croak');
ok(not defined $rv);

$rv = eval { $@ = bless{}, "foo"; mycroak(undef); 1 };
is(ref($@), "foo", 'croak(NULL)');
ok(not defined $rv);

for my $reference (\do { my $value = 10 }, [], {}, bless({}, 'ExceptionObject')) {
    my ($hook_value, $caught, $canonical);
    {
        local $SIG{__DIE__} = sub { $hook_value = $_[0] };
        eval { XS::APItest::mycroak_sv($reference) };
        $caught = $@;
        $canonical = ${^ERROR_OBJ};
    }
    my $kind = ref $reference;
    is(refaddr($caught), refaddr($reference),
       "croak_sv preserves $kind identity in \$@");
    is(refaddr($hook_value), refaddr($reference),
       "croak_sv preserves $kind identity in __DIE__");
    isa_ok($canonical, 'XPerl::Exception');
    is($canonical->contents->[0]->code, 'ERROR_USER_REFERENCE',
       "croak_sv captures a structured $kind reference diagnostic");
    is(refaddr($canonical->contents->[0]->params->[0]{value}),
       refaddr($reference), "the $kind diagnostic retains the original reference");
}
