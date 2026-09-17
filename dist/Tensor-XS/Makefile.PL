use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Tensor::XS',
    VERSION_FROM => 'lib/Tensor/XS.pm',
    PM           => {
        'lib/Matrix.pm'   => '$(INST_LIB)/Matrix.pm',
        'lib/MNIST.pm'    => '$(INST_LIB)/MNIST.pm',
        'lib/Scalar.pm'   => '$(INST_LIB)/Scalar.pm',
        'lib/Tensor.pm'   => '$(INST_LIB)/Tensor.pm',
        'lib/Tensor/XS.pm' => '$(INST_LIB)/Tensor/XS.pm',
        'lib/Vector.pm'   => '$(INST_LIB)/Vector.pm',
    },
    test         => { TESTS => 't/*.t t/*/*.t' },
);
