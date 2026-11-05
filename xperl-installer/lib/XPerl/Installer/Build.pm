package XPerl::Installer::Build;

use strict;
use warnings;
use feature 'signatures';
use Archive::Tar;
use Config;
use Cwd qw(abs_path getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Select;
use IPC::Open3;
use JSON::PP;
use Symbol qw(gensym);

sub new ($class, %args) {
    die "installation prefix is required\n"
        unless defined $args{prefix} && length $args{prefix};
    die "work directory is required\n"
        unless defined $args{workdir} && length $args{workdir};
    make_path($args{prefix}, $args{workdir});
    return bless {
        prefix  => abs_path($args{prefix}),
        workdir => abs_path($args{workdir}),
        registry => $args{registry},
    }, $class;
}

sub install ($self, $release) {
    my $work = tempdir('release-XXXXXXXX', DIR => $self->{workdir},
                       CLEANUP => 0);
    my $record = {
        module        => $release->{module},
        version       => $release->{version},
        cpan_path     => $release->{cpan_path},
        source_sha256 => $release->{sha256},
        prefix        => $self->{prefix},
        xperl         => abs_path($^X),
        xperl_version => "$^V",
        workdir       => $work,
        phases        => [],
    };

    my $error;
    eval {
        my $source = _unpack($release->{archive}, $work);
        if ($self->{registry}) {
            my $selection = $self->{registry}->patches_for($release);
            $record->{registry} = {
                patch_set => $selection->{patch_set},
                index_sha256 => $selection->{index_sha256},
                patches => [map { $_->{sha256} } @{$selection->{patches}}],
            };
            my $number = 0;
            for my $patch (@{$selection->{patches}}) {
                my $log = File::Spec->catfile($work, "patch-" . ++$number . ".log");
                my @command = ('patch', '--batch', '--forward', '-p1',
                               '-i', $patch->{path});
                my $status = $self->_run($source, $log, @command);
                push @{$record->{phases}}, {
                    name => 'patch', command => \@command,
                    exit_status => $status, log => $log,
                };
                die "patch failed (exit $status); see $log\n" if $status;
            }
        }
        die "only Makefile.PL distributions are supported\n"
            unless -f File::Spec->catfile($source, 'Makefile.PL');
        my $perl = abs_path($^X);
        my $make = $Config{make} || 'make';
        my $core = dirname($perl);
        my @make_command = ($make,
            (-f File::Spec->catfile($core, 'perl.h')
                 && -f File::Spec->catfile($core, 'config.h')
                ? ("PERL_INC=$core") : ()));
        my @steps = (
            ['configure', $perl, 'Makefile.PL',
                "INSTALL_BASE=$self->{prefix}"],
            ['build', @make_command],
            ['test', @make_command, 'test'],
            ['install', @make_command, 'install'],
        );
        for my $step (@steps) {
            my ($phase, @command) = @$step;
            my $log = File::Spec->catfile($work, "$phase.log");
            my $status = $self->_run($source, $log, @command);
            push @{$record->{phases}}, {
                name => $phase, command => \@command,
                exit_status => $status, log => $log,
            };
            die "$phase failed (exit $status); see $log\n" if $status;
        }
        $record->{status} = 'installed';
        1;
    } or $error = $@ || "installation failed\n";
    $record->{status} = 'failed' if $error;
    my $receipt = File::Spec->catfile($work, 'receipt.json');
    open my $out, '>', $receipt or die "cannot write $receipt: $!\n";
    print {$out} JSON::PP->new->canonical->pretty->encode($record);
    close $out or die "cannot close $receipt: $!\n";
    die "$error receipt: $receipt\n" if $error;
    $record->{receipt} = $receipt;
    return $record;
}

sub _unpack ($archive, $work) {
    my $tar = Archive::Tar->new;
    $tar->read($archive, 1) or die "cannot read $archive\n";
    my @files = $tar->get_files;
    die "empty archive: $archive\n" unless @files;
    my %roots;
    for my $file (@files) {
        my $name = $file->full_path;
        my ($root) = $name =~ m{\A([^/]+)};
        die "unsafe archive member: $name\n"
            unless defined $root && $name !~ m{(?:\A|/)\.\.? (?:/|\z)}x
                && $name !~ /[\\:\0]/ && !$file->is_symlink
                && !$file->is_hardlink
                && ($name =~ m{/} || $file->is_dir);
        $roots{$root} = 1;
    }
    die "archive has multiple source roots\n" unless keys(%roots) == 1;
    my ($root) = keys %roots;
    my $before = getcwd();
    chdir $work or die "cannot enter $work: $!\n";
    my $ok = $tar->extract;
    my $message = $Archive::Tar::error;
    chdir $before or die "cannot return to $before: $!\n";
    die "cannot extract $archive: $message\n" unless $ok;
    return File::Spec->catdir($work, $root);
}

sub _run ($self, $source, $log_path, @command) {
    open my $log, '>', $log_path or die "cannot write $log_path: $!\n";
    my $before = getcwd();
    my @include = grep { defined $_ && !ref $_ && -d $_ } @INC;
    @include = map { abs_path($_) } @include;
    my $site = File::Spec->catdir($self->{prefix}, 'lib', 'perl5');
    my $arch = File::Spec->catdir($site, $Config{archname});
    local %ENV = %ENV;
    $ENV{PERL5LIB} = join($Config{path_sep}, $site, $arch, @include);
    chdir $source or die "cannot enter $source: $!\n";
    my ($input, $output, $error) = (gensym, gensym, gensym);
    my $pid = eval { open3($input, $output, $error, @command) };
    my $start_error = $@;
    if (!$pid) {
        chdir $before or die "cannot return to $before: $!\n";
        die "cannot start @command: $start_error\n";
    }
    close $input;
    my $select = IO::Select->new($output, $error);
    while (my @ready = $select->can_read) {
        for my $fh (@ready) {
            my $length = sysread($fh, my $buffer, 8192);
            die "cannot read command output: $!\n" unless defined $length;
            if ($length) { print {$log} $buffer }
            else { $select->remove($fh); close $fh }
        }
    }
    waitpid($pid, 0);
    my $status = $?;
    chdir $before or die "cannot return to $before: $!\n";
    close $log or die "cannot close $log_path: $!\n";
    return $status & 127 ? 128 + ($status & 127) : $status >> 8;
}

1;
