#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

my $planning = File::Spec->rel2abs(dirname(__FILE__) . '/..');
my ($results, $plotly);
my $output = "$planning/hash-benchmarks.html";
my $template = "$planning/scripts/hash-benchmarks-template.html";
GetOptions('results=s' => \$results, 'plotly=s' => \$plotly,
           'output=s' => \$output, 'template=s' => \$template) or die "invalid options\n";
die "usage: $0 --results DIRECTORY --plotly plotly.min.js\n" unless $results && $plotly;
my $json = JSON::PP->new->canonical;
sub read_text {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}
sub file_hash {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return sha256_hex(<$fh>);
}
sub average {
    my $sum = 0;
    $sum += $_ for @_;
    return $sum / @_;
}
sub layout {
    my ($info) = @_;
    my %part = (hv => $info->{hv_size}, body => $info->{hv_body_size},
                entries => $info->{entry_capacity} * $info->{he_size},
                heads => 0, links => 0, metadata => 0);
    if (!$info->{integer_chained}) {
        $part{heads} = $info->{index_capacity} * $info->{slot_size};
    }
    elsif (!$info->{linear}) {
        $part{heads} = $info->{index_capacity} * $info->{index_width};
        $part{links} = $info->{entry_capacity}
                    * ($info->{index_width} + ($info->{fingerprint_bits} || 0) / 8);
        $part{metadata} = $info->{metadata_bytes};
    }
    $part{total} = 0;
    $part{total} += $part{$_} for qw(hv body entries heads links metadata);
    die "size formula disagrees with diagnostics\n" if $part{total} != $info->{table_bytes};
    return \%part;
}

my $meta = $json->decode(read_text("$results/metadata.json"));
my %size_set = map { $_->{n} => 1 } @{$meta->{cases}};
my @sizes = sort { $a <=> $b } keys %size_set;
my %wanted = map { $_ => 1 } @sizes;
my %groups;
my %signatures;
my %identities;
my @raw = map { $json->decode($_) } grep { length } split /\n/, read_text("$results/raw.jsonl");
for my $row (@raw) {
    my $case = $row->{case};
    next unless $wanted{$case->{n}} && $case->{key_length} == 9;
    my $identity = join ':', $row->{trial}, $case->{id}, $row->{variant};
    die "duplicate sample $identity\n" if $identities{$identity}++;
    my $signature = join ':', $row->{trial}, $case->{id};
    die "content digest mismatch\n" if exists $signatures{$signature}
        && $signatures{$signature} ne $row->{result_sha256};
    $signatures{$signature} = $row->{result_sha256};
    my $group = join ':', @$case{qw(workload n stored_keys query_keys)}, $row->{variant};
    push @{$groups{$group}}, $row;
}
my @records;
for my $key (sort keys %groups) {
    my @rows = sort { $a->{trial} <=> $b->{trial} } @{$groups{$key}};
    die "expected seven samples for $key\n" unless @rows == 7;
    my @values = map { 0 + $_->{ns_per_operation} } @rows;
    my $mean = average(@values);
    my $squares = 0;
    $squares += ($_ - $mean) ** 2 for @values;
    my $sd = sqrt($squares / 6);
    # NIST's two-sided 95% Student t critical value for six degrees of freedom.
    my $half = 2.447 * $sd / sqrt(7);
    my @layouts = map { layout($_->{before}) } @rows;
    my %parts = map {
        my $name = $_;
        $name => average(map { $_->{$name} } @layouts)
    } qw(hv body entries heads links metadata total);
    my $case = $rows[0]{case};
    push @records, {
        n => 0 + $case->{n}, work => $case->{workload}, stored => $case->{stored_keys},
        query => $case->{query_keys}, variant => $rows[0]{variant},
        count => 7, mean => $mean, sd => $sd,
        low => $mean - $half, high => $mean + $half,
        size => \%parts,
        geometry => { map { $_ => 0 + $rows[0]{before}{$_} }
            qw(entry_capacity he_size index_capacity index_width) },
        samples => [map { +{ trial => $_->{trial}, ns => 0 + $_->{ns_per_operation},
            seed => $_->{hash_seed}, source => $_->{original_source} ||
                {directory => $results, case_id => $_->{case}{id}} } } @rows],
    };
}
die "incomplete report: missing measurement groups\n" unless @records == @sizes * 6 * 3;
my $data = {
    generated => strftime('%Y-%m-%d %H:%M UTC', gmtime),
    sizes => \@sizes, records => \@records,
    variants => [
        {id => 'blead', label => 'Blead', color => '#52657a', policy => 'Pointer chains'},
        {id => 'xperl-default', label => 'Previous XPerl', color => '#8053c4',
         policy => 'Linear through 4 · first heap allocation 2'},
        {id => 'xperl-linear8-alloc4', label => 'New default', color => '#087f65',
         policy => 'Linear through 8 · first heap allocation 4'},
    ],
    method => { samples => 7, key_length => 9, value_length => 32,
        operations => 200000, cpu => $meta->{cpu}, seeds => $meta->{seeds},
        interval => 'Mean ± 2.447 × sample SD / √7; 95% Student t interval, df = 6',
        interval_source => 'https://www.itl.nist.gov/div898/handbook/eda/section3/eda3672.htm',
        note => 'Intervals describe uncertainty in run means on this machine. They assume independent, approximately normal run means and do not describe individual-operation latency or variability over all hash seeds.',
    },
    provenance => { manifest => $meta->{manifest}, binaries => $meta->{binaries},
        worker_sha256 => $meta->{worker_sha256}, compat => $meta->{compat},
        raw_sha256 => file_hash("$results/raw.jsonl"),
        metadata_sha256 => file_hash("$results/metadata.json"),
        plotly_sha256 => file_hash($plotly), source_directory => $results },
};
my $encoded = $json->encode($data);
$encoded =~ s{</}{<\\/}g;
my $library = read_text($plotly);
$library =~ s{</script}{<\\/script}gi;
my $html = read_text($template);
die "template placeholders missing\n" unless $html =~ /\@\@DATA\@\@/ && $html =~ /\@\@PLOTLY\@\@/;
$html =~ s/\@\@DATA\@\@/$encoded/;
$html =~ s/\@\@PLOTLY\@\@/$library/;
open my $page, '>:encoding(UTF-8)', $output or die "$output: $!";
print {$page} $html;
close $page or die "$output: $!";
(my $data_path = $output) =~ s/\.html$/.json/;
open my $sidecar, '>:encoding(UTF-8)', $data_path or die "$data_path: $!";
print {$sidecar} $json->pretty->encode($data);
close $sidecar or die "$data_path: $!";
print "$output\n", scalar(@records), " groups; ", scalar(@raw), " checked samples\n";
