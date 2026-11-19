#!./perl

BEGIN {
    chdir 't' if -d 't';
    require './test.pl';
    set_up_inc('../lib');
    require Config;
}

use strict;
use warnings;

my $source1 = <<'CODE';
use v5.42;
use feature 'class';
no warnings;
role Shared { method value { 17 } }
eval q{class Consumer :implements(Shared) {}; 1 } or die $@;
my $old = Consumer->new;
my $old_method = Consumer->can('value');
delete $main::{'Consumer::'};
eval q{class Consumer :implements(Shared) {}; 1 } or die $@;
my $new = Consumer->new;
my $new_method = Consumer->can('value');
print 'old-old=', $old_method->($old), "\n";
print 'new-new=', $new_method->($new), "\n";
for my $pair (['old-new', $old_method, $new], ['new-old', $new_method, $old]) {
    my ($label, $method, $object) = @$pair;
    my $ok = eval { $method->($object); 1 };
    print "$label=", $ok ? 'accepted' : 'rejected', "\n";
}
CODE
fresh_perl_is($source1, "old-old=17\nnew-new=17\nold-new=rejected\nnew-old=rejected\n", {},
    'composed methods retain consumer identity across package redeclaration');

my $source2 = <<'CODE';
use v5.42;
use feature 'class';
no warnings;
use Scalar::Util qw(weaken);
role Shared { method value { 17 } }
eval q{class Consumer :implements(Shared) {}; 1 } or die $@;
my $method = Consumer->can('value');
my $stash = do { no strict 'refs'; \%{'Consumer::'} };
weaken($stash);
delete $main::{'Consumer::'};
print defined($stash) ? "retained\n" : "released\n";
eval q{class Consumer :implements(Shared) {}; 1 } or die $@;
my $ok = eval { $method->(Consumer->new); 1 };
print $ok ? "accepted\n" : "rejected\n";
CODE
fresh_perl_is($source2, "released\nrejected\n", {},
    'retained composed method neither pins nor rebinds an expired consumer');

my $source3 = <<'CODE';
use v5.42;
use feature 'class';
no warnings;
eval q{class Former { method value { 17 } }; 1 } or die $@;
my $method = Former->can('value');
delete $main::{'Former::'};
eval q{class Former {}; 1 } or die $@;
my $ok = eval { $method->(Former->new); 1 };
print $ok ? "accepted\n" : "rejected\n";
CODE
fresh_perl_is($source3, "rejected\n", {},
    'retained ordinary method rejects a missing defining stash');

my $source4 = <<'CODE';
use v5.42;
use feature 'class';
no warnings;
eval q{
    class Parent { field $value = 17; method value { $value } }
    class Child :isa(Parent) { field $extra = 29; method extra { $extra } }
; 1 } or die $@;
my $parent_method = Parent->can('value');
delete $main::{'Parent::'};
eval q{class Parent { field @first; field @second; }; 1 } or die $@;
my $child = Child->new;
print $parent_method->($child), ',', $child->extra, "\n";
CODE
fresh_perl_is($source4, "17,29\n", {},
    'construction follows the retained native superclass after its name is reused');

SKIP: {
    skip 'Perl not compiled with useithreads', 1 unless $Config::Config{useithreads};
    my $source5 = <<'CODE';
use v5.42;
use feature 'class';
no warnings;
use threads;
class Root { field $base = 41; method base { $base } }
role Shared { field $value = 17; method value { $value } }
eval q{class Consumer :isa(Root) :implements(Shared) {}; 1 } or die $@;
my $old = Consumer->new;
my $old_method = Consumer->can('value');
delete $main::{'Consumer::'};
eval q{class Consumer :isa(Root) :implements(Shared) {}; 1 } or die $@;
my $new = Consumer->new;
my $new_method = Consumer->can('value');
my $result = threads->create(sub {
    my @values = ($old_method->($old), $new_method->($new), $old->base, $new->base);
    for my $pair ([$old_method, $new], [$new_method, $old]) {
        my $ok = eval { $pair->[0]->($pair->[1]); 1 };
        push @values, $ok ? 'accepted' : 'rejected';
    }
    return join ',', @values;
})->join;
print "$result\n";
CODE
    fresh_perl_is($source5, "17,17,41,41,rejected,rejected\n", {},
        'thread cloning remaps composed consumer identities and weak context tokens');
}

my $source6 = <<'CODE';
use v5.42;
use feature 'class';
no warnings;
eval q{
    class Same { field $a = 11; method a { $a } }
    class Left :isa(Same) {}
; 1 } or die $@;
my $old_method = Same->can('a');
delete $main::{'Same::'};
eval q{class Same { field $b = 22; method b { $b } }; 1 } or die $@;
@Both::ISA = ('Left', 'Same');
my $object = Both->new;
print $old_method->($object), ',', $object->b, "\n";
for my $convert (
    sub { builtin::class_object_to_hash($object) },
    sub { builtin::class_object_from_hash({ Same => { '$a' => 11, '$b' => 22 } }, 'Both') },
) {
    eval { $convert->() };
    print "$@" =~ /cannot distinguish multiple owners named Same/ ? "rejected\n" : "unexpected:$@\n";
}
CODE
fresh_perl_is($source6, "11,22\nrejected\nrejected\n", {},
    'snapshot conversion rejects ambiguous class-name buckets in both directions');

done_testing();
