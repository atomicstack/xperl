#!/usr/bin/perl

use strict;
use warnings;

die "Usage: regen/diag_pack.pl [--tap]\n"
  if grep { $_ ne '--tap' } @ARGV;

# regen.pl runs this after diag.pl. Translation environment settings have
# already been consumed by the core catalog generator; this pass packages
# those results and must not start another translation write/import.
local $ENV{MAKE_TRANS_TABLE};
local $ENV{LOAD_TRANS_TABLE};

require './regen/diag.pl';
@ARGV = ('--generate-pack=all');
main::main();
