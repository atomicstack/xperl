package XPerl::Installer::Registry;

use strict;
use warnings;
use feature 'signatures';
use Cwd qw(abs_path);
use Digest::SHA;
use File::Spec;
use JSON::PP;
use version;

sub new ($class, %args) {
    die "registry directory is required\n" unless $args{path} && -d $args{path};
    return bless { path => abs_path($args{path}) }, $class;
}

sub patches_for ($self, $release) {
    my $distribution = $release->{distribution};
    die "invalid distribution name\n"
        unless defined $distribution && $distribution =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/;
    my $index = File::Spec->catfile($self->{path}, 'distributions',
                                    $distribution, 'index.json');
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
        my $path = File::Spec->catfile($self->{path}, 'distributions',
            $distribution, split m{/}, $relative);
        my $real = abs_path($path);
        my $base = File::Spec->catdir($self->{path}, 'distributions',
                                      $distribution, 'patches');
        die "patch escapes registry: $relative\n"
            unless defined $real && index($real, "$base/") == 0;
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

1;
