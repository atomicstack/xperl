#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../Porting", $FindBin::Bin;
use BenchUtils qw(absolute write_text write_json);
use SourceReference;
use Encode qw(encode);
use Getopt::Long qw(GetOptions);

my ($notes, $output, $help);
GetOptions('notes=s' => \$notes, 'output=s' => \$output, 'help' => \$help) or die "Invalid options\n";
if ($help) {
    print "Usage: $0 [--notes JSON] [--output JSON]\n";
    exit;
}
die "Unexpected arguments: @ARGV\n" if @ARGV;
my $planning = absolute("$FindBin::Bin/..");
$notes //= "$planning/diagnostic-source-notes.json";
$output //= "$planning/diagnostic-source-context.json";
my $index = SourceReference::build_index($planning, $notes);
write_json($output, $index);
(my $overview = $output) =~ s/(?:\.[^\/.]+)?\z/.txt/;
write_text($overview, encode('UTF-8', SourceReference::render_overview($index)));
my ($functions, $reviewed) = (0, 0);
for my $file (values %{$index->{files}}) {
    $functions += @{$file->{functions}};
    $reviewed += grep { $_->{review}{status} eq 'focused-source-review' } @{$file->{functions}};
}
printf "%d files, %d function/macro spans; %d have current focused reviews\n",
    scalar(keys %{$index->{files}}), $functions, $reviewed;
print "$output\n$overview\n";
