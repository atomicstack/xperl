#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use BenchHashCompare;
BenchHashCompare::main(1, $FindBin::Bin, __FILE__, @ARGV);
