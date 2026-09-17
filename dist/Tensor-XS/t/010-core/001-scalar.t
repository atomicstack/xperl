use v5.40;
use experimental qw[ class ];

use Test::More;
use Data::Dumper;

use Scalar;
use Vector;
use Matrix;

my $x = Scalar->initialize(2);
my $y = Scalar->initialize(3);
my $z = $x + $y;

isa_ok($x, Scalar::);
isa_ok($y, Scalar::);
isa_ok($z, Scalar::);

is($x->get, 2, '... got the expected x value');
is($y->get, 3, '... got the expected y value');
is($z->get, 5, '... got the expected result of x + y');

my $vec = Vector->initialize(10, [ 1 .. 10 ]);

is($vec->at( $x ), 3, '... scalars can be used for indexing vectors');
is($vec->at( $y ), 4, '... scalars can be used for indexing vectors');
is($vec->at( $z ), 6, '... scalars can be used for indexing vectors');

my $mat = Matrix->initialize([ $x, $y ], $z);

is($mat->max_value, 5, '... got the expected values');
is($mat->min_value, 5, '... got the expected values');

my $mat2 = $mat * $x;

is($mat2->max_value, 10, '... got the expected values');
is($mat2->min_value, 10, '... got the expected values');

done_testing;

__END__
