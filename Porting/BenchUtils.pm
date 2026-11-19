package BenchUtils;

use strict;
use warnings;
use Exporter 'import';
use Cwd qw(abs_path getcwd);
use Digest::SHA ();
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use IPC::Open3;
use JSON::PP;
use POSIX qw(WNOHANG uname);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

our @EXPORT_OK = qw(read_text write_text read_json write_json json sha256
    run absolute median minimum maximum value_range shuffle rng random32
    hash_seed csv_rows csv_line parse_sizes perl_info source_info source_patch
    cpu_info pin_cpu platform_info);
my $json = JSON::PP->new->utf8->canonical;

sub read_text {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!\n";
    local $/;
    return <$fh>;
}

sub write_text {
    my ($path, $text) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "Cannot write $path: $!\n";
    print {$fh} $text or die "Cannot write $path: $!\n";
    close $fh or die "Cannot close $path: $!\n";
}

sub json { return $json->encode($_[0]) }
sub read_json { return $json->decode(read_text($_[0])) }

sub write_json {
    my ($path, $value) = @_;
    write_text($path, JSON::PP->new->utf8->canonical->pretty->encode($value));
}

sub sha256 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!\n";
    return Digest::SHA->new(256)->addfile($fh)->hexdigest;
}

sub absolute {
    my ($path) = @_;
    return abs_path($path) // File::Spec->rel2abs($path);
}

# Capture to files rather than waiting on pipes. This avoids pipe-buffer
# deadlocks and works on systems where select cannot monitor child pipes.
# Deadlines are opt-in: large benchmark batches can legitimately take hours.
sub run {
    my ($command, %options) = @_;
    my $cwd = getcwd();
    my $output = File::Temp->new;
    my $error = File::Temp->new;
    binmode $output;
    binmode $error;
    my $start = clock_gettime(CLOCK_MONOTONIC);
    my ($input, $pid);
    my $spawned;
    {
        local %ENV = %ENV;
        delete @ENV{@{$options{unset} || []}};
        my $env = $options{env} || {};
        $ENV{$_} = $env->{$_} for keys %$env;
        chdir $options{cwd} or die "Cannot chdir $options{cwd}: $!\n"
            if defined $options{cwd};
        $spawned = eval {
            $pid = open3($input, '>&'.fileno($output), '>&'.fileno($error), @$command);
            1;
        };
    }
    my $spawn_error = $@;
    chdir $cwd or die "Cannot restore directory $cwd: $!\n";
    if (!$spawned) {
        die $spawn_error unless $options{allow_failure};
        return {stdout => '', stderr => $spawn_error, status => 127 << 8,
            wall_seconds => clock_gettime(CLOCK_MONOTONIC) - $start};
    }
    close $input;

    my $timeout = $options{timeout};
    my ($status, $failure);
    eval {
        while (1) {
            my $waited = waitpid($pid, defined($timeout) ? WNOHANG : 0);
            if ($waited == $pid) {
                $status = $?;
                last;
            }
            if ($waited < 0) {
                next if $!{EINTR};
                die "Cannot wait for child $pid: $!\n";
            }
            die "Command timed out after $timeout seconds\n"
                if defined($timeout) && clock_gettime(CLOCK_MONOTONIC) - $start > $timeout;
            sleep 0.001;
        }
        1;
    } or $failure = $@;
    if ($failure) {
        kill 'TERM', $pid;
        sleep 0.05;
        kill 'KILL', $pid;
        waitpid($pid, 0);
        die "${failure}Command: @$command\n";
    }
    my $wall = clock_gettime(CLOCK_MONOTONIC) - $start;
    seek $output, 0, 0 or die "Cannot rewind stdout: $!\n";
    seek $error, 0, 0 or die "Cannot rewind stderr: $!\n";
    local $/;
    my $result = {stdout => scalar(<$output>) // '', stderr => scalar(<$error>) // '',
        status => $status, wall_seconds => $wall};
    die "Command failed ($status): @$command\n$result->{stderr}"
        if $status && !$options{allow_failure};
    return $result;
}

sub median {
    my @values = sort { $a <=> $b } grep { defined && $_ ne '' } @_;
    return undef unless @values;
    return @values % 2 ? $values[@values / 2]
        : ($values[@values / 2 - 1] + $values[@values / 2]) / 2;
}

sub minimum {
    my @values = sort { $a <=> $b } @_;
    return @values ? $values[0] : undef;
}

sub maximum {
    my @values = sort { $a <=> $b } @_;
    return @values ? $values[-1] : undef;
}

sub value_range { return [minimum(@_), maximum(@_)] }

# Keep driver randomness separate from the measured interpreter's hash seed.
# Metadata names this PRNG; archived datasets identify earlier experiments.
sub rng {
    my $seed = $_[0] & 0xffffffff;
    $seed ||= 1;
    return \$seed;
}

sub random32 {
    my ($state) = @_;
    $$state ^= ($$state << 13) & 0xffffffff;
    $$state ^= $$state >> 17;
    $$state ^= ($$state << 5) & 0xffffffff;
    return $$state &= 0xffffffff;
}

sub shuffle {
    my ($state, @values) = @_;
    for (my $i = $#values; $i > 0; --$i) {
        my $j = random32($state) % ($i + 1);
        @values[$i, $j] = @values[$j, $i];
    }
    return @values;
}

sub hash_seed { return sprintf '0x%08x%08x', random32($_[0]), random32($_[0]) }

sub parse_sizes {
    my ($text, $positive) = @_;
    my (@sizes, %seen);
    for my $part (split /,/, $text) {
        $part =~ s/^\s+|\s+$//g;
        next unless length $part;
        if ($part =~ /\A(\d+)(?:-|\.\.)(\d+)\z/) {
            die "Descending size range: $part\n" if $1 > $2;
            push @sizes, $1 .. $2;
        }
        elsif ($part =~ /\A\d+\z/) {
            push @sizes, 0 + $part;
        }
        else {
            die "Invalid size: $part\n";
        }
    }
    my $kind = $positive ? 'positive' : 'nonnegative';
    die "Sizes must be a nonempty list of distinct $kind integers\n"
        if !@sizes || grep { ($positive && !$_) || $seen{$_}++ } @sizes;
    return @sizes;
}

sub csv_line {
    return join(',', map {
        my $value = defined $_ ? "$_" : '';
        $value =~ s/"/""/g;
        $value =~ /[,"\r\n]/ ? qq("$value") : $value;
    } @_) . "\n";
}

sub csv_rows {
    my ($text) = @_;
    my (@rows, @row);
    pos($text) = 0;
    while (pos($text) < length $text) {
        my $field;
        if ($text =~ /\G"((?:[^"]|"")*)"(?=,|\r?\n|\z)/gc) {
            $field = $1;
            $field =~ s/""/"/g;
        }
        elsif ($text =~ /\G([^,"\r\n]*)(?=,|\r?\n|\z)/gc) {
            $field = $1;
        }
        else {
            die "Invalid CSV near offset ".pos($text)."\n";
        }
        push @row, $field;
        if ($text =~ /\G,/gc) {
            if (pos($text) == length $text) {
                push @row, '';
                push @rows, [@row];
                @row = ();
            }
        }
        else {
            $text =~ /\G\r?\n/gc;
            push @rows, [@row];
            @row = ();
        }
    }
    return @rows;
}

sub source_info {
    my ($root) = @_;
    my $revision = run(['git', '-C', $root, 'rev-parse', 'HEAD'], allow_failure => 1);
    return {revision => undef, dirty => undef, source_kind => 'archived-build-without-git-metadata'}
        if $revision->{status};
    $revision->{stdout} =~ s/\s+\z//;
    my $dirty = length run(['git', '-C', $root, 'status', '--porcelain'])->{stdout};
    return {revision => $revision->{stdout},
        dirty => $dirty ? JSON::PP::true : JSON::PP::false, source_kind => 'git-checkout'};
}

sub source_patch {
    my ($root, $path) = @_;
    my $result = run(['git', '-C', $root, 'diff', 'HEAD', '--binary'], allow_failure => 1);
    return {path => undef, bytes => undef, sha256 => undef, kind => 'unavailable-no-git-source-tree'}
        if $result->{status};
    write_text($path, $result->{stdout});
    return {path => $path, bytes => length($result->{stdout}), sha256 => sha256($path), kind => 'git-diff'};
}

sub perl_info {
    my ($perl, $lib) = @_;
    $lib //= File::Spec->catdir(dirname($perl), 'lib');
    my $program = 'print JSON::PP::encode_json({version => "$^V", map {$_ => $Config::Config{$_}} qw(cc ccflags optimize gccversion useithreads usemultiplicity archname)});';
    return $json->decode(run([$perl, "-I$lib", '-MConfig', '-MJSON::PP', '-e', $program])->{stdout});
}

sub cpu_info {
    return '' unless -r '/proc/cpuinfo';
    my $text = read_text('/proc/cpuinfo');
    return $1 if $text =~ /^model name\s*:\s*(.*)$/m;
    return '';
}

sub pin_cpu {
    my ($cpu) = @_;
    return unless defined $cpu;
    die "--cpu requires Linux taskset\n" unless $^O eq 'linux' && $cpu =~ /\A\d+\z/;
    run(['taskset', '-pc', $cpu, $$]);
}

sub platform_info {
    my $allowed;
    if (-r '/proc/self/status') {
        my $status = read_text('/proc/self/status');
        $allowed = [parse_sizes($1)] if $status =~ /^Cpus_allowed_list:\s*(\S+)/m;
    }
    return {kernel => join(' ', uname()), machine => (uname())[4], cpu => cpu_info(),
        allowed_cpus => $allowed, perl => "$^V", driver_prng => 'xorshift32'};
}

1;
