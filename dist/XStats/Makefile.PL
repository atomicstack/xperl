use strict;
use warnings;
use ExtUtils::MakeMaker;
use Config;
use File::Spec;
use File::Path qw(remove_tree);

sub math_defines {
    my $directory = ".xstats-math-$$";
    mkdir $directory or die "Cannot create $directory: $!";
    my $quad   = $Config{nvtype} eq '__float128';
    my $suffix = $quad ? 'q' : $Config{nvtype} eq 'long double' ? 'l' : '';
    my $header = $quad ? 'quadmath.h' : 'math.h';
    my @defines;

    for my $function (qw(erf erfc)) {
        my $source = File::Spec->catfile( $directory, "$function.c" );
        my $log    = File::Spec->catfile( $directory, "$function.log" );
        open my $file, '>', $source or die "Cannot write $source: $!";
        print {$file} "#include <$header>\n",
          "int main(void) {\n",
          "    volatile $Config{nvtype} x = 0.5;\n",
          "    $Config{nvtype} (*volatile f)($Config{nvtype}) = $function$suffix;\n",
          "    return f(x) > 0 ? 0 : 1;\n}\n";
        close $file or die "Cannot close $source: $!";

        # Probe the selected symbol, not a canary for unrelated libm calls.
        # A function pointer prevents replacement with a compiler builtin.
        my $executable = File::Spec->catfile( $directory, "$function$Config{exe_ext}" );
        my $compiler   = "$Config{cc} $Config{ccflags} $Config{optimize}";
        my $command;

        if ( $Config{cc} =~ /\b(?:cl|clang-cl)(?:\.exe)?(?:[\s"]|$)/i ) {
            my $object = File::Spec->catfile( $directory, "$function$Config{obj_ext}" );
            $command = qq($compiler "$source" /Fo"$object" /Fe"$executable" )
              . qq(/link $Config{ldflags} $Config{libs});
        }
        elsif ( $^O eq 'VMS' ) {

            # An unavailable probe is an explicit unsupported math backend.
            # We do not infer long-double symbols from double-only probes.
            next;
        }
        else {
            $command = qq($compiler "$source" -o "$executable" )
              . qq($Config{ldflags} $Config{libs});
        }

        my $available = system(qq($command > "$log" 2>&1)) == 0 && -s $executable;
        push @defines, '-DXSTATS_HAS_NV_' . uc($function) if $available;
    }

    # Debug compilers can leave directory trees such as Darwin .dSYM bundles.
    remove_tree( $directory, { error => \my $errors } );
    for my $error (@$errors) {
        my ( $path, $reason ) = %$error;
        die "Cannot remove $path: $reason\n";
    }
    return join ' ', @defines;
}

WriteMakefile(
    NAME          => 'XStats',
    VERSION_FROM  => 'lib/XStats.pm',
    ABSTRACT_FROM => 'lib/XStats.pm',
    AUTHOR        => 'Yves Orton',
    LICENSE       => 'perl',
    PREREQ_PM     => {},
    DEFINE        => math_defines(),
    PM            => {
        'lib/XStats.pm'             => '$(INST_LIB)/XStats.pm',
        'lib/XStats/Full.pm'        => '$(INST_LIB)/XStats/Full.pm',
        'lib/XStats/Sparse.pm'      => '$(INST_LIB)/XStats/Sparse.pm',
        'lib/XStats/Functions.pm'   => '$(INST_LIB)/XStats/Functions.pm',
        'lib/XStats/Incremental.pm' => '$(INST_LIB)/XStats/Incremental.pm',
    },
    XS     => { 'XStats.xs' => 'XStats.c' },
    OBJECT => 'XStats$(OBJ_EXT)',
    depend => {
        'XStats$(OBJ_EXT)' =>
'xstats_impl.inc xstats_sum.h xstats_squares.h xstats_wide.h xstats_root.h xstats_order.h xstats_resample.inc xstats_probability.inc'
    },
    clean => { FILES => 'XStats.c' },
);
