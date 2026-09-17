#!./perl
use strict;
use warnings;

use lib -d '../dist/Tensor-XS/lib'
    ? '../dist/Tensor-XS/lib'
    : 'dist/Tensor-XS/lib';
use experimental 'class';
use Test::More;

use Tensor;
use Vector;
use Matrix;
use Scalar;

my $tensor = Tensor->initialize([2, 2], [1, 2, 3, 4]);
is $tensor->at(1, 0), 3, 'Tensor element access works';
is_deeply $tensor->shape, [2, 2], 'Tensor shape is preserved';

my $vector = Vector->initialize(3, [1, 2, 3]);
is $vector->index_of(2), 1, 'Vector lookup works';

my $matrix = Matrix->eye(3);
is "$vector", '<1 2 3>', 'Vector stringification works';
my $product = $vector->matrix_multiply($matrix);
is "$product", '<1 2 3>',
    'Vector/matrix multiplication works';

my $scalar = Scalar->initialize(7);
cmp_ok 0 + $scalar, '==', 7, 'Scalar numeric conversion works';

done_testing;
