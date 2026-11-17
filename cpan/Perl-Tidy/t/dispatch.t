use strict;
use warnings;
use Test::More;
use Perl::Tidy;

my $source = <<'SOURCE';
# allow 'if' within on(..)
dispatch ($person) {
    on( { name => $name, age => $age, ... } if $age < 18 ) {
        say "$name is a minor";
    }
    on( { name => $name, salary => $salary, ... } ) {
        say "$name earns $salary";
    }
}

# treat 'as' as a binary operator
dispatch ( read_record() as $record ) {
    on( { type => "ok", ... } ) { use_record($record) }
}

# allow pin prefix '^' (treat as sigil for formatting)
dispatch ($value) {
    on($value)    { say "the subject matched itself" }
    on( ^$value ) { say "the explicit pin also matched" }
}
SOURCE

my $expected = <<'EXPECTED';
# allow 'if' within on(..)
dispatch ($person) {
    on ( { name => $name, age => $age, ... } if $age < 18 ) {
        say "$name is a minor";
    }
    on ( { name => $name, salary => $salary, ... } ) {
        say "$name earns $salary";
    }
}

# treat 'as' as a binary operator
dispatch ( read_record() as $record ) {
    on ( { type => "ok", ... } ) { use_record($record) }
}

# allow pin prefix '^' (treat as sigil for formatting)
dispatch ($value) {
    on ($value)    { say "the subject matched itself" }
    on ( ^$value ) { say "the explicit pin also matched" }
}
EXPECTED

for my $option ( '', '--use-feature=dispatch' ) {
    my ( $output, $stderr, $errors ) = ( '', '', '' );
    my $status = Perl::Tidy::perltidy(
        source      => \$source,
        destination => \$output,
        stderr      => \$stderr,
        errorfile   => \$errors,
        argv        => "-npro $option",
    );
    is( $status, 0, "dispatch syntax accepted: '$option'" );
    is( $stderr, '', 'no stderr' );
    is( $errors, '', 'no parsing diagnostics' );
    is( $output, $expected, 'format guards, bindings, and pins' );
}

# Explicit keyword settings must not affect subsequent API calls.
my $calls = 'dispatch($x); on($x); match($x);' . "\n";
for my $option ( '', '--use-feature=dispatch', '--use-feature=nodispatch', '' ) {
    my ( $output, $stderr, $errors ) = ( '', '', '' );
    my $status = Perl::Tidy::perltidy(
        source      => \$calls,
        destination => \$output,
        stderr      => \$stderr,
        errorfile   => \$errors,
        argv        => "-npro $option",
    );
    my $space = $option eq '--use-feature=dispatch' ? ' ' : '';
    my $want = 'dispatch' . $space . '($x);' . "\n"
      . 'on' . $space . '($x);' . "\n"
      . 'match($x);' . "\n";
    is( $status, 0, "function calls accepted: '$option'" );
    is( $output, $want, "keyword spacing is local to '$option'" );
}

{
    my ( $output, $stderr, $errors ) = ( '', '', '' );
    my $status = Perl::Tidy::perltidy(
        source      => \$source,
        destination => \$output,
        stderr      => \$stderr,
        errorfile   => \$errors,
        argv        => '-npro --use-feature=nodispatch',
    );
    is( $status, 2, 'nodispatch restores syntax diagnostics' );
    like( $errors, qr/found 'if' in non-block/, 'guard reported with nodispatch' );
}

done_testing();
