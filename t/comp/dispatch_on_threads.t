#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc( qw(. ../lib) );
}

use feature 'dispatch_on';

eval { require threads; threads->create(sub { 1 })->join };
if ($@) {
    skip_all('threads are not available');
}

plan(7);

my $empty = threads->create(sub {
    my @results;
    for my $v ([], {}, [1], {a => 1}) {
        dispatch ($v) {
            on ([]) { push @results, 'array' }
            on ({}) { push @results, 'hash' }
            on (_)  { push @results, 'full' }
        }
    }
    return join ',', @results;
});
is($empty->join, 'array,hash,full,full',
   'empty container shapes survive thread cloning');

sub regex_closure {
    dispatch (['a', 'b']) {
        on ([/(?<first>a)/, /(?<second>b)/]) {
            return sub { "$first,$second" };
        }
    }
}

my $captures = threads->create(sub { regex_closure()->() });
is($captures->join, 'a,b',
   'cloned multi-regex shapes preserve captures in escaped closures');

sub run_case_in_thread {
    my ($subject) = @_;
    my $result = do {
        dispatch ($subject) {
            on ([ 1, $value ]) { $value }
            on (_) { undef }
        }
    };
    return defined($result) ? $result : 'undef';
}

my @threads = map threads->create(\&run_case_in_thread, $_),
    [ 1, 2 ], [ 1, 9 ], [ 2, 3 ];
my @results = map $_->join, @threads;
is(join(',', @results), '2,9,undef',
   'cloned dispatch patterns keep independent thread state');

my $nested = threads->create(sub {
    my ($subject) = @_;
    dispatch ($subject) {
        on ([ 1, $outer ]) {
            dispatch ($outer) {
                on (2) { 'nested' }
                on (_) { 'wrong' }
            }
        }
        on (_) { 'wrong' }
    }
}, [ 1, 2 ]);
is($nested->join, 'nested', 'nested dispatches work in a cloned thread');

my $exception = threads->create(sub {
    eval { dispatch (die 'thread subject failure') { on (_) { 1 } } };
    my $error = $@;
    my $after = do { dispatch (2) { on (2) { 'after' } } };
    return $error =~ /thread subject failure/ && $after eq 'after';
});
ok($exception->join, 'thread exceptions restore dispatch state');

my $void = threads->create(sub {
    my $seen = 0;
    dispatch (1) { on (1) { $seen++ } };
    return $seen;
});
is($void->join, 1, 'dispatch-on clauses execute once in a cloned thread');

my $separate = threads->create(sub {
    my $subject = [ 1, 4 ];
    my $result = do { dispatch ($subject) { on ([ 1, $item ]) { $item } } };
    $subject->[1] = 8;
    return $result == 4 && $subject->[1] == 8;
});
ok($separate->join, 'thread-local subjects remain mutable after matching');
