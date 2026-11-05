package XPerl::Installer::Fetch;

use strict;
use warnings;
use feature 'signatures';
use Archive::Tar;
use Digest::SHA;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use HTTP::Tiny;
use IO::Uncompress::Gunzip;

sub new ($class, %args) {
    my $cache = $args{cache}
        // File::Spec->catdir($ENV{HOME} // File::Spec->tmpdir, '.xperl', 'cache');
    my $mirror = $args{mirror} // 'https://www.cpan.org';
    die "cache path must not be empty\n" unless length $cache;
    die "mirror must be a directory or HTTPS URL\n"
        unless -d $mirror || $mirror =~ m{\Ahttps://[^/]+(?:/.*)?\z};
    return bless { cache => $cache, mirror => $mirror }, $class;
}

sub resolve ($self, $module, %args) {
    die "invalid CPAN module name\n"
        unless defined $module
            && $module =~ /\A[A-Za-z_][A-Za-z_0-9]*(?:::[A-Za-z_][A-Za-z_0-9]*)*\z/;

    my $index = File::Spec->catfile($self->{cache}, '02packages.details.txt.gz');
    $self->_download('modules/02packages.details.txt.gz', $index)
        if $args{refresh} || !-f $index;

    my $gzip = IO::Uncompress::Gunzip->new($index)
        or die "cannot read CPAN package index $index: $IO::Uncompress::Gunzip::GunzipError\n";
    my $in_header = 1;
    while (my $line = <$gzip>) {
        if ($in_header) {
            $in_header = 0 if $line =~ /^\s*$/;
            next;
        }
        my ($name, $version, $path) = split /\s+/, $line;
        next unless defined $path && $name eq $module;
        chomp $path;
        _check_release_path($path);
        return { module => $module, version => $version, cpan_path => $path };
    }
    die "CPAN module not found: $module\n";
}

sub fetch ($self, $module, %args) {
    my $result = $self->resolve($module, %args);
    my $path = $result->{cpan_path};
    my $archive = File::Spec->catfile($self->{cache}, 'authors', 'id',
                                      split m{/}, $path);
    $self->_download("authors/id/$path", $archive)
        if $args{refresh} || !-f $archive;
    $result->{archive} = $archive;
    $result->{sha256} = _digest($archive);
    $result->{archive_members} = _check_archive($archive);
    return $result;
}

sub _download ($self, $relative, $target) {
    my ($volume, $directory) = (File::Spec->splitpath($target))[0, 1];
    make_path(File::Spec->catpath($volume, $directory, ''));
    my $partial = "$target.part.$$";
    if (-d $self->{mirror}) {
        my $source = File::Spec->catfile($self->{mirror}, split m{/}, $relative);
        copy($source, $partial) or die "cannot copy $source: $!\n";
    }
    else {
        my $url = $self->{mirror} =~ m{/$}
            ? "$self->{mirror}$relative" : "$self->{mirror}/$relative";
        my $response = HTTP::Tiny->new(timeout => 60, verify_SSL => 1)
                                 ->mirror($url, $partial);
        die "download failed for $url: $response->{status} $response->{reason}\n"
            unless $response->{success};
    }
    rename($partial, $target) or die "cannot save $target: $!\n";
}

sub _digest ($path) {
    open my $file, '<:raw', $path or die "cannot read $path: $!\n";
    my $sha = Digest::SHA->new(256);
    $sha->addfile($file);
    return $sha->hexdigest;
}

sub _check_release_path ($path) {
    die "unsafe or unsupported CPAN release path: $path\n"
        unless $path =~ m{\A[A-Za-z0-9_.+/-]+\z}
            && $path !~ m{(?:\A|/)\.\.? (?:/|\z)}x
            && $path =~ m{\A[A-Z]/[A-Z]{2}/[^/]+/[^/]+\.(?:tar\.gz|tgz)\z};
}

sub _check_archive ($archive) {
    my $tar = Archive::Tar->new;
    $tar->read($archive, 1) or die "cannot read archive $archive\n";
    my @files = $tar->get_files;
    die "empty archive: $archive\n" unless @files;
    for my $file (@files) {
        my $name = $file->name;
        die "unsafe archive member: $name\n"
            if $name =~ m{\A/} || $name =~ m{(?:\A|/)\.\.? (?:/|\z)}x;
        die "archive contains a link: $name\n"
            if $file->is_symlink || $file->is_hardlink;
    }
    return scalar @files;
}

1;
