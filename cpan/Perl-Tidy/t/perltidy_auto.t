use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

if ( system( 'git', '--version' ) != 0 ) {
    plan skip_all => 'perltidy-auto requires git';
}

plan tests => 17;

my $root  = tempdir( CLEANUP => 1 );
my $script = File::Spec->catfile( File::Spec->curdir(), 'bin',
    'perltidy-auto' );

sub path {
    return File::Spec->catfile( $root, @_ );
}

sub write_file {
    my ( $name, $contents ) = @_;
    open my $fh, '>', path($name) or die "cannot write $name: $!";
    print {$fh} $contents or die "cannot write $name: $!";
    close $fh or die "cannot close $name: $!";
}

sub read_file {
    my ($name) = @_;
    open my $fh, '<', path($name) or die "cannot read $name: $!";
    local $/;
    my $contents = <$fh>;
    close $fh or die "cannot close $name: $!";
    return $contents;
}

sub git {
    return system( 'git', '-C', $root, @_ ) == 0;
}

sub commit_all {
    ok( git( 'add', '.' ), 'stage test files' );
    ok(
        git(
            '-c', 'user.email=perltidy-auto\@localhost',
            '-c', 'user.name=perltidy-auto',
            'commit', '-qm', 'test fixture'
        ),
        'commit test files'
    );
}

ok( git('init', '-q'), 'initialize temporary Git repository' );

my $plain = <<'PLAIN';
if($x){
print $x;
}
PLAIN

write_file( 'plain.pl', $plain );
write_file( '.perltidy', "-i=2\n" );
mkdir path('subdir') or die "cannot create subdir: $!";
write_file( 'subdir/plain.pl', $plain );
write_file( 'explicit.conf', "-i=6\n" );
commit_all();

my $help_status = system( $^X, $script, '--help' );
is( $help_status, 0, '--help succeeds' );

my $no_args_status = system( $^X, $script );
isnt( $no_args_status, 0, 'missing file argument fails' );

is( system( $^X, $script, path('plain.pl') ), 0,
    'directory config formats the file' );
is( read_file('plain.pl'), <<'EXPECTED', 'directory config is honored' );
if ($x) {
  print $x;
}
EXPECTED

is( system( $^X, $script, '-c', path('explicit.conf'),
        path('subdir/plain.pl') ),
    0, '-c is accepted' );
is( read_file('subdir/plain.pl'), <<'EXPECTED', 'explicit config is honored' );
if ($x) {
      print $x;
}
EXPECTED

write_file( 'marker.pl', <<'MARKER' );
# perltidy -i=4 \
#   -npro
if($x){
print $x;
}
MARKER
ok( git( 'add', 'marker.pl' ), 'stage marker fixture' );
ok( git( '-c', 'user.email=perltidy-auto\@localhost',
        '-c', 'user.name=perltidy-auto', 'commit', '-qm', 'marker fixture' ),
    'commit marker fixture' );
is( system( $^X, $script, path('marker.pl') ), 0,
    'marker invocation succeeds' );
is( read_file('marker.pl'), <<'EXPECTED', 'marker and continuation are honored' );
# perltidy -i=4 \
#   -npro
if ($x) {
    print $x;
}
EXPECTED

my $dirty = read_file('plain.pl');
write_file( 'plain.pl', $dirty . "\n" );
isnt( system( $^X, $script, path('plain.pl') ), 0,
    'dirty tracked file is rejected' );
is( read_file('plain.pl'), $dirty . "\n", 'rejected file is unchanged' );
is( system( $^X, $script, '--force', path('plain.pl') ), 0,
    '--force formats a dirty tracked file' );

write_file( 'untracked.pl', $plain );
isnt( system( $^X, $script, path('untracked.pl') ), 0,
    'untracked file is rejected' );
