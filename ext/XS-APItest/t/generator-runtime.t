#!perl

BEGIN {
    chdir 't' if -d 't';
    require '../../../t/test.pl';
    set_up_inc('../../../lib');
}

use strict;
use warnings;
use XS::APItest;

plan(tests => 3);

ok(process_state_roundtrip(), 'process state saves and restores');
is(process_scheduler_reject(), -1, 'scheduler rejects an incomplete setup');
ok(process_scheduler_switch(), 'scheduler alternates independent process states');
