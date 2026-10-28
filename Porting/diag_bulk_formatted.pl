#!/usr/bin/perl

# Convert fixed diagnostic formats, including mixed printf and Perl fragments.
# Run in report mode first, then use --apply and regenerate with regen/diag.pl.

use strict;
use warnings;
use charnames ':full';
require './regen/diag_lib.pm';

our ( $CONF, $META );

my $apply = grep { $_ eq '--apply' } @ARGV;
my $regex_fail = grep { $_ eq '--regex-fail' } @ARGV;
my $prefixed_croak = grep { $_ eq '--prefixed-croak' } @ARGV;
my $die = grep { $_ eq '--die' } @ARGV;
my $lowercase_die = grep { $_ eq '--lowercase-die' } @ARGV;
my $special_emitters = grep { $_ eq '--special-emitters' } @ARGV;
my $warnings = grep { $_ eq '--warnings' } @ARGV;
my $prefixed_warnings = grep { $_ eq '--prefixed-warnings' } @ARGV;
my $regex_warnings = grep { $_ eq '--regex-warnings' } @ARGV;
my @selected = grep { !/^--/ } @ARGV;
do './diag_conf.pl';
my $conf = $CONF;
die "diag_conf.pl did not define a hash reference\n" unless ref($conf) eq 'HASH';
my (%by_key, %used, $next);
my $catalog_changed = 0;
for my $d (@{Diag::Migration::diagnostics($conf)}) {
    my $key = Diag::Migration::signature($d);
    $by_key{$key} = $d if defined $key;
    for my $alias (@{$d->{emit}{aliases} || []}) {
        my %alias_diag = (%$d, emit => {%{$d->{emit}}, api => $alias});
        my $alias_key = Diag::Migration::signature(\%alias_diag);
        $by_key{$alias_key} = $d if defined $alias_key;
    }
    $used{$d->{code}} = 1;
    $next = $d->{number} if !defined($next) || $d->{number} > $next;
}
++$next;
my $macros = Diag::Migration::format_macros();
my $constants = Diag::Migration::format_constants();
my @files = @selected ? @selected : Diag::Migration::source_files();
for my $file (@files) {
    die "Refusing path outside this checkout: $file\n" if $file =~ m!(?:^/|(?:^|/)\.\.(?:/|$))!;
    my $source = Diag::Migration::read_source($file);
    my %file_constants = (%$constants, %{Diag::Migration::local_format_constants($source)});
    my $names = $regex_fail ? qr/FAIL[23]?/
        : $prefixed_croak ? qr/Perl_croak(?:_nocontext)?/
        : $die ? qr/PERL_DIAG_LEGACY_DIE/
        : $lowercase_die ? qr/die/
        : $special_emitters ? qr/(?:Perl_)?(?:croak_caller|noperl_die)/
        : $warnings ? qr/PERL_DIAG_LEGACY_(?:ck_warner_d|ck_warner|warner)/
        : $prefixed_warnings ? qr/Perl_(?:warn(?:_nocontext)?|(?:ck_)?warner(?:_d|_nocontext)?)/
        : $regex_warnings ? qr/(?:ckWARN(?:reg|dep|regdep|[2345]reg(?:_d)?|experimental(?:_with_arg)?)|vWARN(?:_dep|[2345])?|(?:reg_)?warn_non_literal_string|ckWARN2_non_literal_string)/
        : qr/PERL_DIAG_LEGACY_(?:croak|warn)/;
    my @changes;
    for my $call (Diag::Migration::calls($source, $names)) {
        next if Diag::Migration::api_boundary($file, $call, $source);
        my ($expression, @values) = @{$call->{args}};
        my $category;
        my ($location, $once);
        if ($regex_warnings) {
            $location = $expression;
            $category = $call->{name} =~ /(?:dep|experimental|^warn_non_literal|ckWARN2_non_literal)/
                ? shift @values : 'packWARN(WARN_REGEXP)';
            my $bare_category = $category;
            $once = $category if $call->{name} =~ /experimental/;
            $category = "packWARN($category)" if $call->{name} =~ /(?:dep|experimental)/;
            $category = "packWARN2($bare_category, WARN_REGEXP)" if $call->{name} eq 'ckWARNregdep';
            $expression = shift @values;
            if ($call->{name} =~ /^(?:reg_)?warn_non_literal_string$/) {
                unshift @values, $expression;
                $expression = '"%s"';
            }
        }
        my $categorized = $warnings || ($prefixed_warnings && $call->{name} =~ /warner/);
        if ($prefixed_warnings && $call->{name} !~ /nocontext$/) {
            unless ($expression =~ s/^aTHX_\s*//) {
                print "SKIP\t$file:$call->{line}\texplicit interpreter or declaration\n";
                next;
            }
        }
        if ($categorized) {
            $category = $expression;
            $expression = shift @values;
        }
        if ($call->{name} eq 'Perl_croak') {
            unless ($expression =~ s/^aTHX_\s*//) {
                print "SKIP\t$file:$call->{line}\texplicit interpreter or declaration\n";
                next;
            }
        }
        $expression = Diag::Migration::resolve_format($expression, \%file_constants);
        my $parsed = Diag::Migration::parse_format($expression, \@values, $macros);
        unless ($parsed) {
            print "SKIP\t$file:$call->{line}\t$call->{name}\t$expression\n";
            next;
        }
        if ($regex_fail) {
            my $index = 1 + @{$parsed->{params}};
            my ($pattern, $ellipses) = ("arg$index", 'arg' . ($index + 1));
            $parsed->{message_template}{en} .= " in regex m/%{$pattern}%{$ellipses}/";
            push @{$parsed->{params}},
                { name => $pattern, type => 'text', format_str => 'UTF8f', pass => 'UTF8fARG', inputs => [
                    { name => "${pattern}_utf8", type => 'iv' },
                    { name => "${pattern}_length", type => 'uv' },
                    { name => "${pattern}_text", type => 'text' },
                ] }, { name => $ellipses, type => 'text', format_str => 's' };
            push @{$parsed->{values}}, 'UTF', 'len', 'RExC_precomp', 'ellipses';
        }
        $parsed->{emit}{api} = $call->{name} =~ /warn$/ ? 'WARN'
            : $call->{name} =~ /croak_caller$/ ? 'CROAK_CALLER'
            : $call->{name} =~ /noperl_die$/ ? 'NOPERL_DIE'
            : $call->{name} eq 'die' ? 'DIE_NOCONTEXT'
            : $call->{name} eq 'PERL_DIAG_LEGACY_DIE' ? 'DIE'
            : $call->{name} =~ /nocontext$/ ? 'CROAK_NOCONTEXT'
            : $call->{name} eq 'Perl_croak' ? 'CROAK_CONTEXT' : 'CROAK';
        if ($categorized) {
            ($parsed->{emit}{api}) = $call->{name} =~ /(?:PERL_DIAG_LEGACY_|Perl_)(\w+)/;
            $parsed->{emit}{api} = uc $parsed->{emit}{api};
            $parsed->{emit}{api} .= '_CONTEXT' if $prefixed_warnings && $call->{name} !~ /nocontext$/;
            my $categories = Diag::Migration::warning_categories($category);
            if ($categories) {
                $parsed->{warning_categories} = $categories;
            }
            else {
                $parsed->{emit}{params} = [{ name => 'category', type => 'uv' }];
                push @{$parsed->{values}}, $category;
            }
        }
        elsif ($prefixed_warnings) {
            $parsed->{emit}{api} = $call->{name} =~ /nocontext$/ ? 'WARN_NOCONTEXT' : 'WARN_CONTEXT';
        }
        if ($regex_warnings) {
            $parsed->{emit}{api} = $call->{name} =~ /(?:^vWARN|warn_non_literal_string$)/ ? 'WARNER_CONTEXT'
                : $call->{name} =~ /(?:dep|experimental|_d$)/ ? 'CK_WARNER_D_CONTEXT' : 'CK_WARNER_CONTEXT';
            my $categories = Diag::Migration::warning_categories($category);
            $parsed->{warning_categories} = $categories if $categories;
            unless ($categories) {
                $parsed->{emit}{params} = [{ name => 'category', type => 'uv' }];
                push @{$parsed->{values}}, $category;
            }
            $parsed->{emit}{regex_location} = 1;
            $parsed->{emit}{warn_once} = $once if $once;
            push @{$parsed->{emit}{params}}, { name => 'location', type => 'ptr', role => 'regex_location' };
            push @{$parsed->{values}}, $location;
        }
        my $key = Diag::Migration::signature($parsed);
        my $diag = $by_key{$key};
        if (!$diag && ($warnings || $prefixed_warnings || $regex_warnings)) {
            my @deliveries = $categorized || $regex_warnings ? qw(WARNER CK_WARNER CK_WARNER_D WARNER_CONTEXT CK_WARNER_CONTEXT CK_WARNER_D_CONTEXT WARNER_NOCONTEXT)
                : qw(WARN WARN_CONTEXT WARN_NOCONTEXT);
            for my $delivery (@deliveries) {
                my %normal = (%$parsed, emit => {%{$parsed->{emit}}, api => $delivery});
                $diag = $by_key{Diag::Migration::signature(\%normal)};
                last if $diag;
            }
            if ($diag) {
                push @{$diag->{emit}{aliases}}, $parsed->{emit}{api};
                ++$catalog_changed;
                $by_key{$key} = $diag;
            }
        }
        if (!$diag && $parsed->{emit}{api} =~ /^(?:DIE(?:_NOCONTEXT)?|CROAK(?:_(?:NOCONTEXT|CONTEXT|CALLER))?|NOPERL_DIE)$/) {
            for my $delivery (qw(CROAK CROAK_CONTEXT CROAK_NOCONTEXT DIE)) {
                my %normal = (%$parsed, emit => {%{$parsed->{emit}}, api => $delivery});
                $diag = $by_key{Diag::Migration::signature(\%normal)};
                last if $diag;
            }
            if ($diag) {
                push @{$diag->{emit}{aliases}}, $parsed->{emit}{api};
                ++$catalog_changed;
                $by_key{$key} = $diag;
            }
        }
        if (!$diag) {
            my $code = 'CORE_' . uc $parsed->{message_template}{en};
            $code =~ s/[^A-Z0-9]+/_/g;
            $code =~ s/_$//;
            $code .= "_$next" while $used{$code};
            $used{$code} = 1;
            $diag = {
                kind => 'CORE_RUNTIME', code => $code,
                message_template => $parsed->{message_template},
                number => $next++,
                severity => $warnings || $prefixed_warnings || $regex_warnings
                    || $parsed->{emit}{api} eq 'WARN' ? 'W' : 'F',
                params => $parsed->{params}, emit => {api => $parsed->{emit}{api}},
            };
            $diag->{warning_categories} = $parsed->{warning_categories}
                if $parsed->{warning_categories};
            $diag->{emit}{params} = $parsed->{emit}{params} if $parsed->{emit}{params};
            $diag->{emit}{interpreter_suffix} = 1 if $parsed->{emit}{interpreter_suffix};
            $diag->{emit}{regex_location} = 1 if $parsed->{emit}{regex_location};
            $diag->{emit}{warn_once} = $parsed->{emit}{warn_once} if $parsed->{emit}{warn_once};
            my $severity = Diag::Migration::severity_name($conf, $diag->{severity});
            $diag->{severity} = $severity;
            $conf->{diagnostics}{$severity}{$diag->{kind}}{$diag->{code}} = $diag;
            ++$catalog_changed;
            $by_key{$key} = $diag;
        }
        my $macro = ($diag->{emit}{api} || 'DIE') eq $parsed->{emit}{api}
            ? Diag::Migration::macro_name($diag) : "PERL_DIAG_$parsed->{emit}{api}_$diag->{code}";
        my $replacement = $macro . '(' . join(', ', @{$parsed->{values}}) . ')';
        $replacement = "FAIL_($replacement)" if $regex_fail;
        push @changes, [ $call->{start}, $call->{end}, $replacement ];
        print "CONVERT\t$file:$call->{line}\t$macro\n";
    }
    if ($apply && @changes) {
        for my $change (reverse @changes) {
            my ($start, $end, $replacement) = @$change;
            substr($source, $start, $end - $start) = $replacement;
        }
        open my $out, '>', $file or die "Can't write $file: $!\n";
        print {$out} $source;
        close $out or die "Can't close $file: $!\n";
    }
}
Diag::Migration::write_catalog($conf) if $apply && $catalog_changed;
