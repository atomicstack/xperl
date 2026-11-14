use strict;
use warnings;
use Test::More;
use YAML::XS;
use Scalar::Util qw(isdual);

subtest 'null key' => sub {
    my $xs = YAML::XS->new;
    my $yaml = <<'EOM';
null: value
EOM
    my $data;
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $data = $xs->load($yaml);
    }
    is_deeply $data, { '' => 'value' }, 'null key loaded as empty string';
    is_deeply \@warnings, [], 'automatic conversion without warning';
};

subtest 'dump preserves a numeric input' => sub {
    my $xs = YAML::XS->new(header => 0);
    my $value = 1.0;
    ok !isdual($value), 'input has no cached string';
    is $xs->dump($value), "1.0\n", 'dump includes the decimal point';
    ok !isdual($value), 'dump does not stringify the input';
    is $xs->dump($value), "1.0\n", 'the input can be dumped again';
};

done_testing;
