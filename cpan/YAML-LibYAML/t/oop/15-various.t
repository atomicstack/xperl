use strict;
use warnings;
use Test::More;
use YAML::XS;

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

done_testing;
