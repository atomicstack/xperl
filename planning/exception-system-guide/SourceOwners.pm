package SourceOwners;

use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(definition_index enclosing_definition);
my %control = map { $_ => 1 } qw(if for while switch catch sizeof alignof _Alignof decltype);
my %wrappers = map { $_ => 1 } qw(PP PP_wrapped XS XS_INTERNAL XS_EXTERNAL XS_EUPXS);
my %attributes = map { $_ => 1 } qw(__attribute__ __declspec noexcept);
my %qualifiers = map { $_ => 1 } qw(const volatile override final PERL_UNUSED_DECL);

sub blank {
    my ($text) = @_;
    $text =~ s/[^\n]/ /g;
    return $text;
}

sub line_at {
    my ($starts, $offset) = @_;
    my ($low, $high) = (0, scalar @$starts);
    while ($low < $high) {
        my $middle = int(($low + $high) / 2);
        if ($starts->[$middle] <= $offset) { $low = $middle + 1 }
        else { $high = $middle }
    }
    return $low;
}

sub signature {
    my ($tokens, $closing, $parentheses) = @_;
    --$closing while $closing >= 0 && $qualifiers{$tokens->[$closing][0]};
    while ($closing >= 0 && $tokens->[$closing][0] eq ')') {
        my $opening = $parentheses->{$closing};
        return unless defined($opening) && $opening > 0;
        my $name_index = $opening - 1;
        my $name = $tokens->[$name_index][0];
        if ($attributes{$name}) {
            $closing = $opening - 2;
            next;
        }
        return if $control{$name} || $name !~ /\A[A-Za-z_]\w*\z/;
        if ($wrappers{$name}) {
            my @arguments = @$tokens[$opening + 1 .. $closing - 1];
            @arguments = ($arguments[0])
                if $name eq 'PP_wrapped' && @arguments > 1 && $arguments[1][0] eq ',';
            return unless @arguments == 1 && $arguments[0][0] =~ /\A[A-Za-z_]\w*\z/;
            return ($arguments[0][0], $arguments[0][1]);
        }
        my $start = $name_index;
        $start -= 2 while $start >= 2 && $tokens->[$start - 1][0] eq '::';
        return (join('', map { $_->[0] } @$tokens[$start .. $name_index]), $tokens->[$start][1]);
    }
    return;
}

# This is a lexical index, not a C parser. Mask noncode without moving line
# boundaries, and keep continued macros separate from apparent C bodies.
sub definition_index {
    my ($text, $filename) = @_;
    my @starts = (0);
    push @starts, $+[0] while $text =~ /\n/g;
    my $masked = $text;
    $masked =~ s{("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|/\*.*?\*/|//[^\n]*)}{blank($1)}gse;
    $masked =~ s{(^=\w.*?^=cut[^\n]*)}{blank($1)}gmse;
    my (@definitions, @pieces);
    my ($offset, $in_directive, $macro) = (0, 0, undef);
    for my $line (split /(?<=\n)/, $masked) {
        if (!$in_directive && $line =~ /^[ \t]*\#/) {
            $macro = $line =~ /^[ \t]*\#[ \t]*define[ \t]+([A-Za-z_]\w*)/
                ? [$1, line_at(\@starts, $offset)] : undef;
            $in_directive = 1;
        }
        if ($in_directive) {
            push @pieces, blank($line);
            if ($line !~ /\\\r?\n?\z/) {
                push @definitions, {name => $macro->[0], kind => 'macro',
                    start => $macro->[1], end => line_at(\@starts, $offset)} if $macro;
                $macro = undef;
                $in_directive = 0;
            }
        }
        else {
            push @pieces, $line;
        }
        $offset += length $line;
    }
    $masked = join '', @pieces;
    my @tokens;
    push @tokens, [$&, $-[0], $+[0]] while $masked =~ /[A-Za-z_]\w*|::|[^\s]/g;
    my (%parentheses, %braces, @paren_stack, @brace_stack, @candidates);
    for my $index (0 .. $#tokens) {
        my $value = $tokens[$index][0];
        if ($value eq '(') { push @paren_stack, $index }
        elsif ($value eq ')' && @paren_stack) { $parentheses{$index} = pop @paren_stack }
        elsif ($value eq '{') {
            push @brace_stack, $index;
            my @found = signature(\@tokens, $index - 1, \%parentheses);
            push @candidates, [$index, @found] if @found;
        }
        elsif ($value eq '}' && @brace_stack) { $braces{pop @brace_stack} = $index }
    }
    for my $candidate (@candidates) {
        my ($index, $name, $start) = @$candidate;
        next unless exists $braces{$index};
        push @definitions, {name => $name, kind => 'function',
            start => line_at(\@starts, $start), end => line_at(\@starts, $tokens[$braces{$index}][2])};
    }
    push @definitions, xs_definitions($masked, \@starts) if $filename =~ /\.xs\z/;
    return \@definitions;
}

sub xs_definitions {
    my ($masked, $starts) = @_;
    my (@headers, @boundaries, @definitions);
    push @headers, [$1, $-[0]] while $masked =~ /^([A-Za-z_]\w*(?:::\w+)*)[ \t]*\(/gm;
    push @boundaries, $-[0] while $masked =~ /^(?:MODULE[ \t]*=|(?:BOOT|INCLUDE|PROTOTYPES|TYPEMAP)\s*:)/gm;
    for my $index (0 .. $#headers) {
        my ($name, $start) = @{$headers[$index]};
        my $end = $index < $#headers ? $headers[$index + 1][1] : length $masked;
        for my $boundary (@boundaries) {
            $end = $boundary if $boundary > $start && $boundary < $end;
        }
        my $body = substr($masked, $start, $end - $start);
        next unless $body =~ /^[ \t]*(?:CODE|PPCODE|PREINIT|INIT|INPUT|OUTPUT|ALIAS|CLEANUP)\s*:/m;
        my $section = $-[0];
        my $closing = index($body, ')');
        next if $closing < 0 || substr($body, $closing + 1, $section - $closing - 1) =~ /[;{]/;
        push @definitions, {name => $name, kind => 'XS function',
            start => line_at($starts, $start), end => line_at($starts, $end > $start ? $end - 1 : $start)};
    }
    return @definitions;
}

sub enclosing_definition {
    my ($definitions, $line) = @_;
    my @matches = sort {
        ($a->{kind} ne 'macro') <=> ($b->{kind} ne 'macro')
            || ($a->{end} - $a->{start}) <=> ($b->{end} - $b->{start})
    } grep { $_->{start} <= $line && $line <= $_->{end} } @$definitions;
    return {name => '', kind => 'undetermined'} unless @matches;
    return {name => $matches[0]{name}, kind => $matches[0]{kind}};
}

1;
