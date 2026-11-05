package XPerl::Installer::Proposal;

use strict;
use warnings;
use feature 'signatures';
use Digest::SHA;
use File::Compare qw(compare);
use File::Find;
use File::Spec;

sub files ($root) {
    my %files;
    File::Find::find({
        no_chdir => 1,
        wanted => sub {
            return unless -f $File::Find::name && !-l $File::Find::name;
            my $relative = substr($File::Find::name, length($root) + 1);
            $files{$relative} = 1;
        },
    }, $root);
    return \%files;
}

sub write_patch ($class, %args) {
    my ($original, $source, $path, $new_files) =
        @args{qw(original source path new_files)};
    my $original_files = files($original);
    my $source_files = files($source);
    my %candidates = (%$original_files, %$new_files);
    open my $output, '>:raw', $path or die "cannot write $path: $!\n";
    my @changed;
    for my $relative (sort keys %candidates) {
        my $old = $original_files->{$relative}
            ? File::Spec->catfile($original, $relative) : undef;
        my $new = $source_files->{$relative}
            ? File::Spec->catfile($source, $relative) : undef;
        next unless $old || $new;
        if ($old && $new) {
            my $comparison = compare($old, $new);
            die "cannot compare $relative: $!\n" if $comparison < 0;
            next if $comparison == 0;
        }
        my $from = $old ? "a/$relative" : '/dev/null';
        my $to = $new ? "b/$relative" : '/dev/null';
        open my $diff, '-|', 'diff', '-u', '--label', $from,
            '--label', $to, $old // '/dev/null', $new // '/dev/null'
            or die "cannot start diff for $relative: $!\n";
        my $header = <$diff>;
        die "diff did not produce a patch for $relative\n"
            unless defined $header && $header =~ /^--- /;
        print {$output} $header;
        while (my $line = <$diff>) { print {$output} $line }
        close $diff;
        die "diff failed for $relative\n" unless $? >> 8 == 1;
        push @changed, $relative;
    }
    close $output or die "cannot close $path: $!\n";
    return { path => $path, files => \@changed } unless @changed;
    open my $input, '<:raw', $path or die "cannot read $path: $!\n";
    my $digest = Digest::SHA->new(256)->addfile($input)->hexdigest;
    return { path => $path, sha256 => $digest, files => \@changed };
}

1;
