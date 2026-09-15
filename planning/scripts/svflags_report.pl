#!perl

use strict;
use warnings;
no warnings 'experimental::builtin';

use B qw(svref_2object SVf_IOK SVf_NOK SVf_POK SVf_ROK
         SVp_IOK SVp_NOK SVp_POK);
use builtin qw(created_as_number true false);

# This is a diagnostic report, not a test.  Every operation gets a fresh
# scalar from its factory, so the flags shown are the flags left on the input
# scalar by that operation.  Run it with the perl whose SV behavior is being
# investigated, for example:
#
#     ./perl -Ilib planning/scripts/svflags_report.pl
#
# The result is intentionally plain text so reports from different builds can
# be diffed.  Warnings are captured per operation and printed in abbreviated
# form in the Warns column.

{
    package SVFlagsReport::Overloaded;
    use overload
        '""' => sub { 'overloaded-string' },
        '0+'  => sub { 17 },
        bool  => sub { 1 },
        fallback => 1;
    sub new { bless {}, shift }
}

sub compile_input {
    my ($source) = @_;
    my $factory = eval "sub { $source }";
    die "cannot compile input expression <$source>: $@" if $@;
    return $factory;
}

my @input_sources = (
    'undef',
    "''",
    "'0'",
    "'0.0'",
    "'0E0'",
    "'0000'",
    "'+1'",
    "'+1foo'",
    "'+1E5'",
    "'+1.1E1'",
    "'-1.25e-3'",
    '11',
    "do { my \$v = '+1.1E1'; my \$n = 0 + \$v; \$n }",
    "do { my \$v = '+1.1E1'; my \$n = 0 + \$v; \$v }",
    '1.25',
    "do { my \$v = '1.25'; my \$n = 0 + \$v; \$n }",
    "do { my \$v = '1.25'; my \$n = 0 + \$v; \$v }",
    '1e5',
    "do { my \$v = '1e5'; my \$n = 0 + \$v; \$n }",
    "do { my \$v = '1E5'; my \$n = 0 + \$v; \$v }",
    "do { my \$v = '0000'; my \$n = 0 + \$v; \$n }",
    "do { my \$v = '0000'; my \$n = 0 + \$v; \$v }",
    "do { my \$v = '0E0'; my \$n = 0 + \$v; \$n }",
    "do { my \$v = '0E0'; my \$n = 0 + \$v; \$v }",
    "'  +1'",
    "'+1  '",
    "'  +1  '",
    '1',
    '-1',
    '1.25',
    '1.0',
    "'Inf'",
    "'NaN'",
    "'abc'",
    "'false'",
    "'no'",
    "'0 but true'",
    "'   '",
    '!!1',
    '!!0',
    'true()',
    'false()',
    '[]',
    '{}',
    'sub { }',
    'SVFlagsReport::Overloaded->new',
);

my @inputs = map { [ $_, compile_input($_) ] } @input_sources;

my @operations = (
    [ '$x'       => sub { my $v = ${ $_[0] }; return $v } ],
    [ '"$x"'     => sub { my $v = "${ $_[0] }"; return $v } ],
    [ '$x . ""'   => sub { my $v = ${ $_[0] } . ''; return $v } ],
    [ 'length $x' => sub { my $v = length ${ $_[0] }; return $v } ],
    [ 'substr "$x", 0' => sub { my $v = substr "${ $_[0] }", 0; return $v } ],
    [ '0 + $x'   => sub { my $v = 0 + ${ $_[0] }; return $v } ],
    [ '$x + 0'   => sub { my $v = ${ $_[0] } + 0; return $v } ],
    [ '0 + $x'   => sub { my $v = 0 + ${ $_[0] }; return $v } ],
    [ 'int $x'   => sub { my $v = int ${ $_[0] }; return $v } ],
    [ '$x += 0'  => sub { ${ $_[0] } += 0; return ${ $_[0] } } ],
    [ '$x .= ""' => sub { ${ $_[0] } .= ''; return ${ $_[0] } } ],
    [ '"" . $x'  => sub { my $v = '' . ${ $_[0] }; return $v } ],
    [ '!!$x'     => sub { my $v = !!${ $_[0] }; return $v } ],
    [ '$x == 0'  => sub { my $v = ${ $_[0] } == 0; return $v } ],
    [ '$x eq "0"' => sub { my $v = ${ $_[0] } eq '0'; return $v } ],
    [ '++$x'     => sub { ++${ $_[0] }; return ${ $_[0] } } ],
);

my @flag_names = (
    [ SVf_IOK(),     'IOK' ],
    [ SVf_NOK(),     'NOK' ],
    [ SVf_POK(),     'POK' ],
    [ SVf_ROK(),     'ROK' ],
    [ SVp_IOK(),     'IOKp' ],
    [ SVp_NOK(),     'NOKp' ],
    [ SVp_POK(),     'POKp' ],
);

sub flags_for {
    my ($value) = @_;
    my $flags = svref_2object($value)->FLAGS;
    my @names = map { $_->[1] } grep { $flags & $_->[0] } @flag_names;
    return @names ? join('|', @names) : '-';
}

sub created_number_flag {
    my ($value) = @_;
    return builtin::created_as_number($value) ? 'yes' : 'no';
}

sub warning_classes {
    my ($warnings) = @_;
    return 'no' unless @$warnings;
    my %seen;
    for my $warning (@$warnings) {
        my $text = lc $warning;
        my $class =
              $text =~ /uninitialized/                         ? 'uninitialized'
            : $text =~ /(?:isn't|is not) numeric|\bnumeric\b/ ? 'numeric'
            : $text =~ /redefined/                             ? 'redefined'
            : $text =~ /experimental/                          ? 'experimental'
            : $text =~ /deprecated/                            ? 'deprecated'
            : 'other';
        $seen{$class} = 1;
    }
    return join(',', grep { $seen{$_} } qw(uninitialized numeric
        redefined experimental deprecated other));
}

printf "%-68s %-18s %-34s %-7s %-16s %-5s %-s\n",
    qw(Expression Operation TypeFlags Boolean Warns CAN Result);
printf "%-68s %-18s %-34s %-7s %-16s %-5s %-s\n",
    '-' x 68, '-' x 18, '-' x 34, '-' x 7, '-' x 16, '-' x 5, '-' x 24;

for my $input (@inputs) {
    my ($name, $factory) = @$input;
    for my $operation (@operations) {
        my ($operation_source, $code) = @$operation;
        my $value = $factory->();
        my $boolean = eval { !!$value ? 'true' : 'false' };
        $boolean = 'ERROR' if $@;
        my @warnings;
        my ($result, $error);
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            local $@;
            $result = eval { $code->(\$value) };
            $error = $@;
        }
        my $result_text;
        if ($error) {
            $result_text = 'ERROR: ' . $error;
            $result_text =~ s/\s+/ /g;
            $result_text = substr($result_text, 0, 90) . '...'
                if length($result_text) > 93;
        }
        elsif (!defined $result) {
            $result_text = 'undef';
        }
        elsif (ref $result) {
            $result_text = 'ref(' . ref($result) . ')';
        }
        else {
            $result_text = "$result";
            $result_text =~ s/\s+/ /g;
            $result_text = substr($result_text, 0, 90) . '...'
                if length($result_text) > 93;
        }
        printf "%-68s %-18s %-34s %-7s %-16s %-5s %-s\n",
            $name, $operation_source, flags_for(\$value), $boolean,
            warning_classes(\@warnings), created_number_flag($value),
            $result_text;
    }
}

print "\nExpression checks\n";
printf "%-24s %-34s %-16s %-s\n",
    qw(Expression TypeFlags Warns Result);
printf "%-24s %-34s %-16s %-s\n",
    '-' x 24, '-' x 34, '-' x 16, '-' x 24;

for my $source ('undef + 0', '0 + undef', 'undef() + 0', '0 + undef()') {
    my @warnings;
    my ($factory, $compile_error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        local $@;
        $factory = eval "sub { $source }";
        $compile_error = $@;
    }
    if ($compile_error) {
        printf "%-24s %-34s %-16s %-s\n",
            $source, '-', 'compile_error', 'not compiled';
        next;
    }

    my ($result, $runtime_error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        local $@;
        $result = eval { $factory->() };
        $runtime_error = $@;
    }
    my $result_text;
    if ($runtime_error) {
        $result_text = 'runtime_error';
    }
    elsif (!defined $result) {
        $result_text = 'undef';
    }
    else {
        $result_text = "$result";
        $result_text =~ s/\s+/ /g;
    }
    printf "%-24s %-34s %-16s %-s\n",
        $source, flags_for(\$result), warning_classes(\@warnings),
        $result_text;
}
