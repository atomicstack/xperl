package XPerl::Installer::Deps;

use strict;
use warnings;
use feature 'signatures';
use Archive::Tar;
use Config;
use CPAN::Meta;
use CPAN::Meta::Requirements;
use File::Spec;
use Module::Metadata;
use Parse::CPAN::Meta;

sub new ($class, %args) {
    die "fetcher and builder are required\n"
        unless $args{fetcher} && $args{builder};
    return bless {
        fetcher => $args{fetcher},
        builder => $args{builder},
        needed => CPAN::Meta::Requirements->new,
        visiting => {},
        installed => {},
        receipts => [],
    }, $class;
}

sub install ($self, $module) {
    $self->_install($module, '0');
    return {
        module => $module,
        status => 'installed',
        receipts => $self->{receipts},
    };
}

sub _install ($self, $module, $constraint) {
    $self->{needed}->add_string_requirement($module, $constraint);
    return if $self->_satisfied($module);
    die "dependency cycle at $module\n" if $self->{visiting}{$module};
    $self->{visiting}{$module} = 1;

    my $release = $self->{fetcher}->fetch($module);
    die "CPAN index version $release->{version} does not satisfy $module $constraint\n"
        unless $self->{needed}->accepts_module($module, $release->{version});
    my $meta = eval { _metadata($release->{archive}) };
    die "invalid CPAN metadata for $module ($release->{cpan_path}): $@"
        if $@;
    if ($meta) {
        $release->{distribution} = $meta->name;
        $release->{distribution_version} = $meta->version;
        my $required = $meta->effective_prereqs->merged_requirements(
            [qw(configure build test runtime)], ['requires']);
        for my $dependency (sort $required->required_modules) {
            my $range = $required->requirements_for_module($dependency);
            if ($dependency eq 'perl') {
                die "XPerl $^V does not satisfy perl $range\n"
                    unless $required->accepts_module('perl', $^V);
                next;
            }
            $self->_install($dependency, $range);
        }
    }

    if (!$self->_satisfied($module)) {
        die "distribution $release->{cpan_path} was already installed but lacks $module\n"
            if $self->{installed}{$release->{cpan_path}};
        my $receipt = $self->{builder}->install($release);
        $self->{installed}{$release->{cpan_path}} = 1;
        push @{$self->{receipts}}, $receipt->{receipt};
    }
    die "installed distribution does not provide required $module\n"
        unless $self->_satisfied($module);
    delete $self->{visiting}{$module};
}

sub _satisfied ($self, $module) {
    my $prefix = $self->{builder}->{prefix};
    my $site = File::Spec->catdir($prefix, 'lib', 'perl5');
    my @inc = ($site, File::Spec->catdir($site, $Config{archname}), @INC);
    my $metadata = Module::Metadata->new_from_module($module, inc => \@inc);
    return 0 unless $metadata;
    return $self->{needed}->accepts_module($module,
                                           $metadata->version // '0');
}

sub _metadata ($archive) {
    my $tar = Archive::Tar->new;
    $tar->read($archive, 1) or die "cannot read $archive\n";
    my @files = $tar->get_files;
    for my $suffix (qw(META.json META.yml)) {
        my ($file) = grep { $_->full_path =~ m{\A[^/]+/\Q$suffix\E\z} }
            @files;
        next unless $file;
        my $data = $suffix eq 'META.json'
            ? Parse::CPAN::Meta->load_json_string($file->get_content)
            : Parse::CPAN::Meta->load_yaml_string($file->get_content);
        return CPAN::Meta->new($data, { lazy_validation => 1 });
    }
    return;
}

1;
