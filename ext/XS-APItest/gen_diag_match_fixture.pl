use 5.008;
use strict;
use warnings;
use JSON::PP qw(decode_json);

my ( $input, $output ) = @ARGV;
die "usage: $0 input.json output.inc\n" unless $input && $output;

open my $in, '<', $input or die "cannot read $input: $!\n";
local $/;
my $fixture = decode_json(<$in>);
close $in or die "cannot close $input: $!\n";

my $wide_count = $fixture->{wide_value_count};
die "invalid wide value count\n"
  unless defined($wide_count) && $wide_count == 65535;
my $prefix = $fixture->{wide_prefix};
die "invalid wide value prefix\n" unless defined($prefix) && $prefix =~ /\A[A-Za-z_]+\z/;
my $number = $fixture->{diagnostic_number};
die "invalid diagnostic number\n" unless defined($number) && $number =~ /\A[0-9]+\z/;

open my $out, '>', $output or die "cannot write $output: $!\n";
print {$out} "static const char * const APItest_diag_wide_values[] = {\n";
for my $value_id ( 1 .. $wide_count ) {
    printf {$out} "    \"%s%05d\",\n", $prefix, $value_id;
}
print {$out} "};\n\n";

my @cases   = @{ $fixture->{cases} };
my $layouts = $fixture->{layouts};
for my $layout_index ( 0 .. $#$layouts ) {
    my $layout    = $layouts->[$layout_index];
    my $name      = $layout->{name};
    my @selectors = @{ $layout->{selectors} };
    die "invalid fixture name\n"             unless $name =~ /\A[a-z0-9_]+\z/;
    die "invalid selector count for $name\n" unless @selectors <= 7;
    my $has_wide = grep { $_ eq 'wide' } @selectors;
    die "invalid wide selector count for $name\n"
      unless grep( { $_ eq 'wide' } @selectors ) <= 1;

    print {$out} "static const perl_diag_selector_t APItest_diag_selectors_$name\[\] = {\n";
    my $narrow_index = 0;
    for my $index ( 0 .. $#selectors ) {
        my $selector = $selectors[$index];
        my ( $width, $shift, $values, $value_count );
        if ( $selector eq 'wide' ) {
            ( $width, $shift, $values, $value_count ) = ( 16, 48, 'APItest_diag_wide_values', 65535 );
        }
        elsif ( $selector =~ /\An[1-7]\z/ ) {
            ( $width, $shift, $values, $value_count ) = ( 8, 8 * $narrow_index++, 'NULL', 2 );
        }
        else {
            die "invalid selector '$selector' in $name\n";
        }
        print {$out} "    { \"$selector\", $index, 0, $values, $value_count, "
          . "$width, $shift, NULL, FALSE, FALSE, NULL, FALSE },\n";
    }
    print {$out} "};\n";

    my @layout_cases;
    my @selected_cases =
      $has_wide
      ? grep { $_->{name} !~ /\An(?:1|6|7)_only\z/ } @cases
      : grep { $_->{name} =~ /\A(?:wildcard|n1_only|n7_only)\z/ } @cases;
    if ( $name eq 'six_narrow_plus_wide' ) {
        push @selected_cases, grep { $_->{name} eq 'n6_only' } @cases;
    }
    for my $case (@selected_cases) {
        my $pattern      = 0;
        my $narrow_index = 0;
        my $specificity  = 0;
        for my $index ( 0 .. $#selectors ) {
            my $selector = $selectors[$index];
            my $value    = $case->{$selector} || 0;
            my $shift    = $selector eq 'wide' ? 48 : 8 * $narrow_index++;
            $pattern |= $value << $shift;
            $specificity++ if $value;
        }
        push @layout_cases, [ $case->{name}, $pattern, $specificity ];
    }
    @layout_cases = sort { $b->[2] <=> $a->[2] || $a->[1] <=> $b->[1] } @layout_cases;
    print {$out} "static const perl_diag_template_case_t APItest_diag_cases_$name\[\] = {\n";
    for my $case (@layout_cases) {
        printf {$out} "    { %u, UINT64_C(0x%016x), \"%s\", 0, 0 },\n", $number, $case->[1], $case->[0];
    }
    print {$out} "    { 0, UINT64_C(0), NULL, 0, 0 },\n};\n";
    print {$out} "\n" if $layout_index < $#$layouts;
}
close $out or die "cannot close $output: $!\n";
