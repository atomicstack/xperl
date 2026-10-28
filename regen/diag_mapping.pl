#!/usr/bin/env perl

use strict;
use warnings;
use charnames ':full';
use FindBin qw($RealBin);

my $tap = @ARGV == 1 && $ARGV[0] eq '--tap';
die "Usage: perl regen/diag_mapping.pl [--tap]\n" if @ARGV && !$tap;

our ( $CONF, $META );
chdir "$RealBin/.." or die "Cannot enter Perl source tree: $!\n";
require './regen/diag_lib.pm';
require './regen/diag_classes.pm';
require './regen/warnings_data.pm';
do './diag_conf.pl' or die $@ || $!;

my $diagnostics = Diag::Migration::diagnostics($CONF);
my $model       = Diag::Classes::build_model(
    $diagnostics,
    $CONF->{diagnostic_classes},
    Perl::Regen::Warnings::tree(),
    Diag::Migration::read_source('warnings.h')
);
my $workbook = Diag::Classes::workbook($model);
my $registry = Diag::Classes::registry_report($model);

# The generic regeneration test discovers this script too. Review reports
# are optional development files, not shipped generator inputs. Check those
# present without printing TSV or creating reports in a release tree.
if ($tap) {
    my $matches = 1;
    for my $report (
        [ 'planning/diagnostic-classification.tsv', $workbook ],
        [ 'planning/diagnostic-class-registry.tsv', $registry ],
      )
    {
        my ( $path, $expected ) = @$report;
        next unless -f $path;
        $matches = 0 if Diag::Migration::read_source($path) ne $expected;
    }
    print( $matches ? 'ok' : 'not ok', " - diagnostic class model and available review reports\n" );
    exit( $matches  ? 0    : 1 );
}

print $workbook;

my $path = 'planning/diagnostic-class-registry.tsv';
open my $out, '>', $path or die "Cannot write $path: $!\n";
print {$out} $registry;
close $out or die "Cannot close $path: $!\n";
