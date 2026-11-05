package XPerl::Installer::Registry;

use strict;
use warnings;
use feature 'signatures';
use Cwd qw(abs_path);
use Digest::SHA;
use Encode qw(encode);
use File::Spec;
use JSON::PP;
use version;
use builtin qw(jumphash_string siphash_2_4);
no warnings 'experimental::builtin';

sub new ($class, %args) {
    die "registry directory is required\n" unless $args{path} && -d $args{path};
    my $root = abs_path($args{path});
    my $config_path = File::Spec->catfile($root, 'registry.json');
    my $self = bless { path => $root }, $class;
    return $self unless -f $config_path;

    open my $input, '<:raw', $config_path
        or die "cannot read $config_path: $!\n";
    my $config = JSON::PP->new->decode(do { local $/; <$input> });
    my $count = $config->{active_repositories};
    die "unsupported registry configuration in $config_path\n"
        unless $config->{schema} == 2
            && $config->{placement} eq 'siphash24-zero-jump-v1'
            && $config->{fanout} eq 'siphash24-zero-first-byte-v1'
            && defined($count) && $count =~ /\A[1-8]\z/
            && ref($config->{repositories}) eq 'ARRAY'
            && @{$config->{repositories}} == $count;
    my @repositories;
    for my $id (0 .. $count - 1) {
        my $entry = $config->{repositories}[$id];
        die "invalid repository $id in $config_path\n"
            unless ref($entry) eq 'HASH'
                && defined($entry->{id}) && $entry->{id} == $id
                && defined($entry->{path}) && length($entry->{path})
                && !File::Spec->file_name_is_absolute($entry->{path});
        my $path = abs_path(File::Spec->catdir($root, $entry->{path}));
        die "repository $id is unavailable: $entry->{path}\n"
            unless defined($path) && -d $path;
        $repositories[$id] = $path;
    }
    die "repository 0 must be the bootstrap checkout\n"
        unless $repositories[0] eq $root;
    $self->{repositories} = \@repositories;
    return $self;
}

sub patches_for ($self, $release) {
    my $distribution = $release->{distribution};
    die "invalid distribution name\n"
        unless defined $distribution && $distribution =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/;
    my $base = $self->_distribution_directory($release);
    my $index = File::Spec->catfile($base, 'index.json');
    return { patches => [] } unless -f $index;
    open my $input, '<:raw', $index or die "cannot read $index: $!\n";
    my $json = do { local $/; <$input> };
    my $data = JSON::PP->new->decode($json);
    die "unsupported registry schema in $index\n"
        unless $data->{schema} == 1 && $data->{distribution} eq $distribution;
    my @releases = grep {
        $_->{version} eq $release->{distribution_version}
            && $_->{cpan_path} eq $release->{cpan_path}
    } @{$data->{releases}};
    die "duplicate registry release for $distribution\n" if @releases > 1;
    return { patches => [], index_sha256 => Digest::SHA::sha256_hex($json) }
        unless @releases;
    my $entry = $releases[0];
    die "registry source digest mismatch for $distribution\n"
        unless $entry->{source_sha256} eq $release->{sha256};
    my $running = version->parse("$^V");
    my @sets = grep {
        $running >= version->parse($_->{xperl}{min_inclusive})
            && $running < version->parse($_->{xperl}{max_exclusive})
    } @{$entry->{patch_sets}};
    die "ambiguous registry patch sets for $distribution\n" if @sets > 1;
    return { patches => [], index_sha256 => Digest::SHA::sha256_hex($json) }
        unless @sets;
    my $set = $sets[0];
    my @patches;
    for my $patch (@{$set->{patches}}) {
        my $relative = $patch->{path};
        die "invalid registry patch path: $relative\n"
            unless $relative =~ m{\Apatches/[A-Za-z0-9_.-]+\.patch\z};
        my $path = File::Spec->catfile($base, split m{/}, $relative);
        my $real = abs_path($path);
        my $patch_base = abs_path(File::Spec->catdir($base, 'patches'));
        die "patch escapes registry: $relative\n"
            unless defined $real && defined $patch_base
                && index($real, "$patch_base/") == 0;
        open my $file, '<:raw', $real or die "cannot read $real: $!\n";
        my $digest = Digest::SHA->new(256)->addfile($file)->hexdigest;
        die "patch digest mismatch: $relative\n"
            unless $digest eq $patch->{sha256};
        push @patches, { path => $real, sha256 => $digest };
    }
    my @recipes;
    for my $id (@{$set->{recipes} // []}) {
        die "invalid registry recipe id: $id\n"
            unless $id =~ /\A[A-Za-z0-9_.-]+\z/;
        my $path = File::Spec->catfile($self->{path}, 'recipes', "$id.md");
        my $real = abs_path($path);
        my $base = File::Spec->catdir($self->{path}, 'recipes');
        die "recipe escapes registry: $id\n"
            unless defined $real && index($real, "$base/") == 0;
        push @recipes, { id => $id, path => $real };
    }
    return {
        patch_set => $set->{id},
        index_sha256 => Digest::SHA::sha256_hex($json),
        patches => \@patches,
        recipes => \@recipes,
    };
}

sub _distribution_directory ($self, $release) {
    my $distribution = $release->{distribution};
    return File::Spec->catdir($self->{path}, 'distributions', $distribution)
        unless $self->{repositories};

    my $cpan_path = $release->{cpan_path} // '';
    my ($initial, $pair, $author) =
        $cpan_path =~ m{\A([A-Z])/([A-Z]{2})/([A-Z0-9_-]+)/[^/]+\z};
    die "invalid CPAN author path: $cpan_path\n"
        unless defined($author)
            && substr($author, 0, 1) eq $initial
            && substr($author, 0, 2) eq $pair;
    my $key = encode('UTF-8', "$author/$distribution");
    my $repository = jumphash_string($key, scalar @{$self->{repositories}});
    my $prefix = unpack 'H2', siphash_2_4($key, "\0" x 16);
    return File::Spec->catdir($self->{repositories}[$repository], 'data',
                              $prefix, $author, $distribution);
}

1;
