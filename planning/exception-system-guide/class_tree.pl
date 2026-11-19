#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../Porting", $FindBin::Bin;
use BenchUtils qw(absolute);
use ClassTree qw(review_evidence render_class_tree);
use Getopt::Long qw(GetOptions);

my ($output, @evidence, $help);
GetOptions('output=s' => \$output, 'review-evidence=s{2}' => \@evidence,
    'help' => \$help) or die "Invalid options\n";
if ($help) {
    print "Usage: $0 --output HTML | --review-evidence INPUT OUTPUT\n";
    exit;
}
die "Unexpected arguments: @ARGV\n" if @ARGV;
die "Choose --output or --review-evidence\n" unless !!$output != !!@evidence;
my $planning = absolute("$FindBin::Bin/..");
if (@evidence) { review_evidence($planning, @evidence) }
else { render_class_tree($planning, absolute($output), $FindBin::Bin) }
