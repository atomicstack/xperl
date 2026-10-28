package Perl::Regen::Warnings;

use strict;
use warnings;

sub DEFAULT_ON ()  { 1 }
sub DEFAULT_OFF () { 2 }

# Return a fresh warning hierarchy for warning generation and diagnostic classes.
# Keep category relationships here so both generators use the same authority.
sub tree {
    return {
        'all' => [
            5.008,
            {
                'io' => [
                    5.008,
                    {
                        'pipe'     => [ 5.008, DEFAULT_OFF ],
                        'unopened' => [ 5.008, DEFAULT_OFF ],
                        'closed'   => [ 5.008, DEFAULT_OFF ],
                        'newline'  => [ 5.008, DEFAULT_OFF ],
                        'exec'     => [ 5.008, DEFAULT_OFF ],
                        'layer'    => [ 5.008, DEFAULT_OFF ],
                        'syscalls' => [ 5.019, DEFAULT_OFF ],
                    }
                ],
                'syntax' => [
                    5.008,
                    {
                        'ambiguous'    => [ 5.008, DEFAULT_OFF ],
                        'semicolon'    => [ 5.008, DEFAULT_OFF ],
                        'precedence'   => [ 5.008, DEFAULT_OFF ],
                        'bareword'     => [ 5.008, DEFAULT_OFF ],
                        'reserved'     => [ 5.008, DEFAULT_OFF ],
                        'digit'        => [ 5.008, DEFAULT_OFF ],
                        'parenthesis'  => [ 5.008, DEFAULT_OFF ],
                        'printf'       => [ 5.008, DEFAULT_OFF ],
                        'prototype'    => [ 5.008, DEFAULT_OFF ],
                        'qw'           => [ 5.008, DEFAULT_OFF ],
                        'illegalproto' => [ 5.011, DEFAULT_OFF ],
                    }
                ],
                'severe' => [
                    5.008,
                    {
                        'inplace'   => [ 5.008, DEFAULT_ON ],
                        'internal'  => [ 5.008, DEFAULT_OFF ],
                        'debugging' => [ 5.008, DEFAULT_ON ],
                        'malloc'    => [ 5.008, DEFAULT_ON ],
                    }
                ],
                'deprecated' => [
                    5.008,
                    DEFAULT_ON,
                    {
                        'deprecated::goto_construct'           => [ 5.011003, DEFAULT_ON ],
                        'deprecated::unicode_property_name'    => [ 5.011003, DEFAULT_ON ],
                        'deprecated::dot_in_inc'               => [ 5.025011, DEFAULT_ON ],
                        'deprecated::version_downgrade'        => [ 5.035009, DEFAULT_ON ],
                        'deprecated::delimiter_will_be_paired' => [ 5.035010, DEFAULT_ON ],
                        'deprecated::subsequent_use_version'   => [ 5.039008, DEFAULT_ON ],
                    }
                ],
                'void'          => [ 5.008, DEFAULT_OFF ],
                'recursion'     => [ 5.008, DEFAULT_OFF ],
                'redefine'      => [ 5.008, DEFAULT_OFF ],
                'numeric'       => [ 5.008, DEFAULT_OFF ],
                'uninitialized' => [ 5.008, DEFAULT_OFF ],
                'once'          => [ 5.008, DEFAULT_OFF ],
                'misc'          => [ 5.008, DEFAULT_OFF ],
                'regexp'        => [ 5.008, DEFAULT_OFF ],
                'glob'          => [ 5.008, DEFAULT_ON ],
                'untie'         => [ 5.008, DEFAULT_OFF ],
                'substr'        => [ 5.008, DEFAULT_OFF ],
                'taint'         => [ 5.008, DEFAULT_OFF ],
                'signal'        => [ 5.008, DEFAULT_OFF ],
                'closure'       => [ 5.008, DEFAULT_OFF ],
                'overflow'      => [ 5.008, DEFAULT_OFF ],
                'portable'      => [ 5.008, DEFAULT_OFF ],
                'utf8'          => [
                    5.008,
                    {
                        'surrogate'   => [ 5.013, DEFAULT_OFF ],
                        'nonchar'     => [ 5.013, DEFAULT_OFF ],
                        'non_unicode' => [ 5.013, DEFAULT_OFF ],
                    }
                ],
                'exiting'      => [ 5.008, DEFAULT_OFF ],
                'pack'         => [ 5.008, DEFAULT_OFF ],
                'unpack'       => [ 5.008, DEFAULT_OFF ],
                'threads'      => [ 5.008, DEFAULT_OFF ],
                'imprecision'  => [ 5.011, DEFAULT_OFF ],
                'experimental' => [
                    5.017,
                    {
                        'experimental::lexical_subs'               => [ 5.017, DEFAULT_ON ],
                        'experimental::regex_sets'                 => [ 5.017, DEFAULT_OFF ],
                        'experimental::smartmatch'                 => [ 5.017, DEFAULT_ON ],
                        'experimental::postderef'                  => [ 5.019, DEFAULT_ON ],
                        'experimental::signatures'                 => [ 5.019, DEFAULT_ON ],
                        'experimental::refaliasing'                => [ 5.021, DEFAULT_ON ],
                        'experimental::re_strict'                  => [ 5.021, DEFAULT_ON ],
                        'experimental::const_attr'                 => [ 5.021, DEFAULT_ON ],
                        'experimental::bitwise'                    => [ 5.021, DEFAULT_ON ],
                        'experimental::declared_refs'              => [ 5.025, DEFAULT_ON ],
                        'experimental::script_run'                 => [ 5.027, DEFAULT_ON ],
                        'experimental::alpha_assertions'           => [ 5.027, DEFAULT_ON ],
                        'experimental::private_use'                => [ 5.029, DEFAULT_ON ],
                        'experimental::uniprop_wildcards'          => [ 5.029, DEFAULT_ON ],
                        'experimental::vlb'                        => [ 5.029, DEFAULT_ON ],
                        'experimental::isa'                        => [ 5.031, DEFAULT_ON ],
                        'experimental::try'                        => [ 5.033, DEFAULT_ON ],
                        'experimental::defer'                      => [ 5.035, DEFAULT_ON ],
                        'experimental::for_list'                   => [ 5.035, DEFAULT_ON ],
                        'experimental::builtin'                    => [ 5.035, DEFAULT_ON ],
                        'experimental::args_array_with_signatures' => [ 5.035, DEFAULT_ON ],
                        'experimental::extra_paired_delimiters'    => [ 5.035, DEFAULT_ON ],
                        'experimental::class'                      => [ 5.037, DEFAULT_ON ],
                        'experimental::keyword_any'                => [ 5.041, DEFAULT_ON ],
                        'experimental::keyword_all'                => [ 5.041, DEFAULT_ON ],
                        'experimental::signature_named_parameters' => [ 5.043, DEFAULT_ON ],
                        'experimental::enhanced_xx'                => [ 5.043, DEFAULT_ON ],
                        'experimental::namespaces'                 => [ 5.045, DEFAULT_ON ],
                        'experimental::equ'                        => [ 5.043, DEFAULT_ON ],
                    }
                ],

                'missing'        => [ 5.021, DEFAULT_OFF ],
                'redundant'      => [ 5.021, DEFAULT_OFF ],
                'locale'         => [ 5.021, DEFAULT_ON ],
                'shadow'         => [ 5.027, DEFAULT_OFF ],
                'scalar'         => [ 5.035, DEFAULT_OFF ],
                'missing_import' => [ 5.043, DEFAULT_ON ],

                #'default'     => [ 5.008, DEFAULT_ON ],
            }
        ]
    };
}

1;
