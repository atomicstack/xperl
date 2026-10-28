package Diag::Classes;

use strict;
use warnings;

# Shared class policy for runtime table generation and the derived review report.
# Callers supply normalized diagnostics and the canonical warning hierarchy.
my %strict_class = (
    ERROR_STRICT_SUBS_BAREWORD_FORBIDDEN                    => 'Subs',
    ERROR_STRICT_REFS_BAREWORD_REFERENCE_FORBIDDEN          => 'Refs',
    ERROR_STRICT_REFS_STRING_REFERENCE_FORBIDDEN            => 'Refs',
    ERROR_STRICT_REFS_SUBROUTINE_STRING_REFERENCE_FORBIDDEN => 'Refs',
);

sub warning_classes {
    my ($path) = @_;
    return 'XPerl::Diagnostic::Warning' . ( @$path ? '::' . join( '::', map { package_component($_) } @$path ) : '' );
}

sub package_component {
    my ($name) = @_;
    return 'IO'   if $name eq 'io';
    return 'UTF8' if $name eq 'utf8';
    return join '', map { ucfirst lc $_ } split /_+/, $name;
}

sub macro_category {
    my ($macro) = @_;
    return unless defined $macro && $macro =~ /\AWARN_(.+)\z/;
    my $category = lc $1;
    $category =~ s/__/::/g;
    return $category;
}

# Record category paths once, preserving the existing warnings hierarchy.
sub walk_warning_tree {
    my ( $model, $tree, $path ) = @_;
    for my $name ( sort keys %$tree ) {
        my $entry = $tree->{$name};
        my $children =
            ref $entry->[1] eq 'HASH' ? $entry->[1]
          : ref $entry->[2] eq 'HASH' ? $entry->[2]
          :                             undef;
        next if $name eq 'all';
        my @parts = split /::/, $name;
        shift @parts if @parts > 1 && join( '::', @$path ) eq $parts[0];
        my @class_path = ( @$path, @parts );
        my $category   = lc $name;
        my $class      = warning_classes( \@class_path );
        die "Warning class collision for $class\n"
          if exists $model->{class_owner}{$class}
          && $model->{class_owner}{$class} ne $category;
        $model->{class_owner}{$class}          = $category;
        $model->{warning_path}{$category}      = $class;
        $model->{warning_component}{$category} = \@class_path;
        walk_warning_tree( $model, $children, \@class_path ) if $children;
    }
}

# Validate explicit parents and inherited capabilities before emitting C data.
sub validate_classes {
    my ($classes) = @_;
    for my $class ( sort keys %$classes ) {
        die "Invalid diagnostic class name '$class'\n"
          unless $class =~ /\AXPerl::(?:DiagGroup|Exception|Diagnostic(?:::[A-Za-z_]\w*)*)\z/;
        die "Class $class must have a hash definition\n" unless ref $classes->{$class} eq 'HASH';
        my $definition = $classes->{$class};
        die "Invalid parent for diagnostic class $class\n"
          if defined $definition->{parent} && ref $definition->{parent};
        die "Class $class must descend from XPerl::DiagGroup\n"
          if $class ne 'XPerl::DiagGroup' && !defined $definition->{parent};
        die "XPerl::DiagGroup cannot have a parent\n"
          if $class eq 'XPerl::DiagGroup' && defined $definition->{parent};
        die "Invalid leaf restriction for diagnostic class $class\n"
          if exists $definition->{leaf_only}
          && (!defined $definition->{leaf_only}
            || ref $definition->{leaf_only}
            || $definition->{leaf_only} !~ /\A[01]\z/ );
        my %seen;
        my $inherited_leaf = 0;
        my $current        = $class;

        while ( defined $current ) {
            die "Unknown diagnostic class $current (ancestor of $class)\n"
              unless exists $classes->{$current};
            die "Diagnostic class cycle at $current\n" if $seen{$current}++;
            $inherited_leaf ||= $classes->{$current}{leaf_only} ? 1 : 0;
            $current = $classes->{$current}{parent};
        }
        die "Class $class weakens an inherited leaf restriction\n"
          if $inherited_leaf
          && exists $classes->{$class}{leaf_only}
          && !$classes->{$class}{leaf_only};
        $classes->{$class}{leaf_only} = $inherited_leaf;
    }
}

# Build a fresh model. The review workbook is output, never an input to regen.
sub build_model {
    my ( $diagnostics, $definitions, $warning_tree, $warnings_header ) = @_;
    die "Missing diagnostic class definitions\n" unless ref $definitions eq 'HASH';
    my $model = { classes => {}, warning_path => {}, warning_component => {}, class_owner => {} };
    for my $name ( keys %$definitions ) {
        die "Class $name must have a hash definition\n" unless ref $definitions->{$name} eq 'HASH';
        $model->{classes}{$name} = { %{ $definitions->{$name} } };
    }
    walk_warning_tree( $model, $warning_tree->{all}[1], [] );
    $model->{warning_path}{all}      = 'XPerl::Diagnostic::Warning';
    $model->{warning_component}{all} = [];
    for my $macro ( $warnings_header =~ /^#define\s+(WARN_\w+)\s+\d+/mg ) {
        my $category = macro_category($macro);
        if ( $category eq 'all' ) {
            $model->{classes}{'XPerl::Diagnostic::Warning'}{warning_category} = 'all';
            $model->{classes}{'XPerl::Diagnostic::Warning'}{warning_symbol}   = $macro;
            next;
        }
        die "Active warning category $macro is absent from WARNING_TREE\n"
          unless exists $model->{warning_path}{$category};
        my $class = $model->{warning_path}{$category};
        die "Class $class conflicts with the warning hierarchy\n"
          if exists $model->{classes}{$class};
        my $path = $model->{warning_component}{$category};
        my $parent =
          @$path > 1
          ? warning_classes( [ @$path[ 0 .. $#$path - 1 ] ] )
          : 'XPerl::Diagnostic::Warning';
        $model->{classes}{$class} =
          { parent => $parent, leaf_only => 0, warning_category => $category, warning_symbol => $macro };
    }
    validate_classes( $model->{classes} );
    my @columns = qw(number code severity kind counts_as_error emit_api warning_categories
      category_policy role proposed_class allowed_class leaf_only grouping_role review_status rationale);
    my @rows;
    my %by_code;
    for my $diag ( sort { $a->{number} <=> $b->{number} } @$diagnostics ) {
        my $row = classification_row( $model, $diag );
        my %fields;
        @fields{@columns} = @$row;
        die "Duplicate catalog code $diag->{code}\n" if exists $by_code{ $diag->{code} };
        my $class = $fields{proposed_class};
        die "Unknown class $class for $diag->{code}\n"
          if $class ne 'none' && !exists $model->{classes}{$class};
        die "Renderer classification mismatch for $diag->{code}\n"
          if ( ( $diag->{emit}{api} eq 'RENDER' ) ? 1 : 0 ) != ( ( $fields{role} eq 'formatting helper' ) ? 1 : 0 );
        $by_code{ $diag->{code} } = \%fields;
        push @rows, $row;
    }
    $model->{columns} = \@columns;
    $model->{rows}    = \@rows;
    $model->{by_code} = \%by_code;
    return $model;
}

# A deterministic, readable projection for human review.
sub workbook {
    my ($model) = @_;
    return join( "\t", @{ $model->{columns} } ) . "\n" . join(
        '',
        map {
            join( "\t", map { defined $_ ? $_ : '' } @$_ ) . "\n"
        } @{ $model->{rows} }
    );
}

# Return explicit runtime parent/capability rows in stable name order.
sub registry_rows {
    my ($model) = @_;
    return [
        map {
            my $name  = $_;
            my $entry = $model->{classes}{$name};
            [
                $name, $entry->{parent},
                $entry->{leaf_only}        ? 1                       : 0,
                $entry->{warning_category} ? 'WARNING_TREE category' : 'catalog class',
                $entry->{warning_category} || '-'
            ]
        } sort keys %{ $model->{classes} }
    ];
}

# Category zero (WARN_ALL) is valid. Offset IDs reserve zero for non-category classes.
sub runtime_registry_rows {
    my ($model) = @_;
    return [
        map {
            my $name  = $_;
            my $entry = $model->{classes}{$name};
            [ $name, $entry->{parent}, $entry->{leaf_only} ? 1 : 0, $entry->{warning_symbol} ]
        } sort keys %{ $model->{classes} }
    ];
}

sub registry_report {
    my ($model) = @_;
    return "class\tparent\tleaf_only\tsource\twarning_category\n" . join(
        '',
        map {
            join( "\t", map { defined $_ ? $_ : '' } @$_ ) . "\n"
        } @{ registry_rows($model) }
    );
}

sub classification_row {
    my ( $model, $diag ) = @_;
    my $api             = $diag->{emit}{api} || '';
    my @categories      = @{ $diag->{warning_categories} || [] };
    my $is_renderer     = $api eq 'RENDER';
    my $is_warning      = $diag->{severity} =~ /\A(?:WARNING|DEPRECATION)\z/;
    my $class           = 'XPerl::Diagnostic::Error';
    my $allowed_class   = $class;
    my $leaf            = 'no';
    my $grouping        = 'ordinary diagnostic; container-capable';
    my $status          = 'needs producer review';
    my $rationale       = 'Use the Error base until a narrower semantic family is reviewed.';
    my $category_policy = 'not applicable';
    my $role            = 'diagnostic';

    if ($is_renderer) {
        $leaf      = 'n/a';
        $grouping  = 'formatting helper; not an instance';
        $status    = 'generator contract';
        $rationale = 'RENDER formats existing catalog values without constructing a diagnostic.';
        $role      = 'formatting helper';
    }
    elsif ( my $restriction = $strict_class{ $diag->{code} } ) {
        $class         = "XPerl::Diagnostic::Error::Strict::$restriction";
        $allowed_class = $class;
        $status        = 'strict producer candidate';
        $rationale =
          $restriction eq 'Subs'
          ? 'op.c emits this for a bareword marked as forbidden by strict-subs parsing.'
          : 'C producers guard this diagnostic with HINT_STRICT_REFS or the matching strict-reference op flag.';
    }
    elsif ( $diag->{severity} eq 'INTERNAL_ERROR' ) {
        $class         = 'XPerl::Diagnostic::Error::Internal';
        $allowed_class = $class;
        $status        = 'broad internal family';
        $rationale     = 'The catalog marks this as an interpreter internal error.';
    }
    elsif ( $is_warning && $diag->{is_hint} ) {
        $class         = 'XPerl::Diagnostic::Note::Hint';
        $allowed_class = $class;
        $leaf          = 'yes';
        $grouping      = 'supplementary hint; producer grouping review pending';
        $status        = 'hint migration review';
        if ( $diag->{code} =~ /^NOTE_HINT_OPERATOR_EXPECTED_(?:MISSING_SEMICOLON|PREDECLARE|MISSING_OPERATOR)\z/ ) {
            $grouping = 'supplementary Note nested under WARNING_SYNTAX_OPERATOR_EXPECTED';
            $status   = 'producer-reviewed nested Note';
        }
        elsif ( $diag->{code} eq 'NOTE_HINT_STACK_UNWIND_DEFERRED' ) {
            $grouping = 'temporary delivery Note';
            $status   = 'producer-reviewed delivery annotation';
        }
        if (@categories) {
            my @paths = map {
                my $category = macro_category($_);
                die "No warning tree class for hint $diag->{code} category $_\n"
                  unless defined $category && exists $model->{warning_component}{$category};
                $model->{warning_component}{$category};
            } @categories;
            my $common = 0;
            while (1) {
                my $component = $paths[0][$common];
                last unless defined $component;
                last if grep { !defined $_->[$common] || $_->[$common] ne $component } @paths;
                $common++;
            }
            my $current_class = warning_classes( [ @{ $paths[0] }[ 0 .. $common - 1 ] ] );
            $category_policy = "fixed: $categories[0]";
            $allowed_class   = "current $current_class; proposed $class after migration review";
        }
        else {
            $category_policy = 'uncategorized; verify producer policy';
        }
        $rationale =
          'The catalog explicitly marks this record as a hint; preserve its warning policy during migration.';
        if ( $diag->{code} =~ /^NOTE_HINT_OPERATOR_EXPECTED_(?:MISSING_SEMICOLON|PREDECLARE|MISSING_OPERATOR)\z/ ) {
            $allowed_class = $class;
            $rationale     = 'toke.c appends this WARN_SYNTAX detail to the WARNING_SYNTAX_OPERATOR_EXPECTED '
              . 'diagnostic, whose metadata declares a following hint.';
        }
        elsif ( $diag->{code} eq 'NOTE_HINT_STACK_UNWIND_DEFERRED' ) {
            $rationale = 'The delivery planner adds this Note to a temporary action view '
              . 'after __EXCEPT__; the caught exception tree is not mutated.';
        }
        $role = 'supplementary hint';
    }
    elsif ( $is_warning && @categories ) {
        my @paths = map {
            my $category = macro_category($_);
            die "Unknown warning category $_ on $diag->{code}\n"
              unless defined $category && exists $model->{warning_path}{$category};
            $model->{warning_component}{$category};
        } @categories;
        my $common = 0;
        while (1) {
            my $component = $paths[0][$common];
            last unless defined $component;
            last if grep { !defined $_->[$common] || $_->[$common] ne $component } @paths;
            $common++;
        }
        $class         = warning_classes( [ @{ $paths[0] }[ 0 .. $common - 1 ] ] );
        $allowed_class = $class;
        $category_policy =
          @categories == 1
          ? "fixed: $categories[0]"
          : 'fixed category set; LCA class plus exact membership';
        $status    = 'warning tree mapping';
        $rationale = 'Fixed warning categories map through WARNING_TREE; the catalog retains exact membership.';
    }
    elsif ($is_warning) {
        $class           = 'XPerl::Diagnostic::Warning';
        $allowed_class   = $class;
        $category_policy = 'no fixed catalog category; producer review required';
        $grouping        = 'warning; verify independent or supplementary role';
        $status          = 'warning producer review';
        $rationale       = 'The catalog supplies no fixed category; preserve the Warning base pending producer review.';
    }

    my @categories_text  = @categories;
    my $dynamic_category = grep { $_->{type} eq 'uv' && $_->{name} =~ /category/i } @{ $diag->{emit}{params} || [] };
    if ( $is_warning && $dynamic_category ) {
        $class           = 'XPerl::Diagnostic::Warning';
        $allowed_class   = 'XPerl::Diagnostic::Warning::* (runtime LCA)';
        $category_policy = 'runtime category; LCA plus exact category membership';
        $status          = 'dynamic mapping review';
        $rationale =
'A runtime category parameter selects the warning policy; review call sites to define allowed category classes.';
    }

    if ( $diag->{has_following_hint} ) {
        $grouping  = 'primary with following operator Note';
        $status    = 'producer-reviewed nested Note';
        $rationale = 'toke.c emits WARNING_SYNTAX_OPERATOR_EXPECTED before its optional '
          . 'WARN_SYNTAX hint and preserves the existing warning category.';
    }
    if ( $diag->{code} eq 'WARNING_SYNTAX_RUNAWAY_MULTILINE_STRING_SUGGESTION' ) {
        $grouping  = 'independent warning; producer association is not guaranteed';
        $status    = 'producer reviewed warning';
        $rationale = 'Producer paths append this Syntax warning after different parser records; '
          . 'preserve its independent warning policy and hook delivery.';
    }
    if ( $diag->{code} eq 'WARNING_IO_DIRHANDLE_USED_AS_FILEHANDLE_SUGGESTION' ) {
        $grouping  = 'independent warning; separately emitted by producer';
        $status    = 'producer reviewed warning';
        $rationale = 'util.c emits this IO warning after a separate filehandle warning; '
          . 'preserve category policy and the existing hook count.';
    }
    if (   $diag->{code} eq 'ERROR_CALL_BINDING_NAMED_PARAMETER_REQUIRED_NAME_MISSING'
        || $diag->{code} eq 'ERROR_CALL_BINDING_NAMED_PARAMETER_UNKNOWN_NAME' )
    {
        $grouping  = 'primary with same-call named-parameter detail children';
        $status    = 'producer grouping reviewed';
        $rationale = 'pp.c nests retained same-call parameter records under the first diagnostic; '
          . 'preserve the existing five-name summary limit.';
    }
    if ( $diag->{code} eq 'NOTE_OMISSION_NAMED_PARAMETER_DIAGNOSTICS' ) {
        $grouping  = 'omitted-count child under named-parameter root';
        $status    = 'producer-specific NOTE severity override';
        $rationale = 'The catalog assigns Note::Omission; pp.c retains the NOTE severity override '
          . 'when nesting this omitted-count child.';
    }
    if ( defined $diag->{class} ) {
        $class = $diag->{class};
        die "Unknown class $class for $diag->{code}\n"
          unless exists $model->{classes}{$class};
        $allowed_class = $class;
        $leaf          = $model->{classes}{$class}{leaf_only} ? 'yes' : 'no';
        $status        = 'explicit catalog class';
        $rationale     = 'The catalog explicitly assigns this diagnostic class.';
    }
    return [
        $diag->{number},               $diag->{code},                              $diag->{severity},
        $diag->{kind},                 $diag->{counts_as_error} ? 1 : 0,           $api,
        join( ',', @categories_text ), $category_policy,                           $role,
        $class,                        $class eq 'none' ? 'none' : $allowed_class, $leaf,
        $grouping,                     $status,                                    $rationale,
    ];
}

1;
