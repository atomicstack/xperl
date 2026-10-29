/*    builtin.c
 *
 *    Copyright (C) 2021 by Paul Evans and others
 *
 *    You may distribute under the terms of either the GNU General Public
 *    License or the Artistic License, as specified in the README file.
 *
 */

/*
 *      Any sufficiently advanced technology is indistinguishable from magic.
 *              --Arthur C. Clarke
 *
 *     [_Profiles of the Future_]
 */

/* This file contains the code that implements functions in perl's "builtin::"
 * namespace
 */

#include "EXTERN.h"
#define PERL_IN_BUILTIN_C
#include "perl.h"

#include "XSUB.h"

/* copied from op.c */
#define SHORTVER(maj,min) (((maj) << 8) | (min))

struct BuiltinFuncDescriptor {
    const char *name;
    U16 since_ver;
    bool is_experimental;
    XSUBADDR_t xsub;
    OP *(*checker)(pTHX_ OP *, GV *, SV *);
    IV ckval;
};

#define warn_experimental_builtin(name) S_warn_experimental_builtin(aTHX_ name)
static void S_warn_experimental_builtin(pTHX_ const char *name)
{
    /* diag_listed_as: Built-in function '%s' is experimental */
    PERL_WARN_WARNING_EXPERIMENTAL_BUILTIN_FUNCTION_USED(name);
}


XS(XS_builtin_true);
XS(XS_builtin_true)
{
    dXSARGS;
    if(items)
        croak_xs_usage(cv, "");
    EXTEND(SP, 1);
    XSRETURN_YES;
}

XS(XS_builtin_false);
XS(XS_builtin_false)
{
    dXSARGS;
    if(items)
        croak_xs_usage(cv, "");
    EXTEND(SP, 1);
    XSRETURN_NO;
}

XS(XS_builtin_inf);
XS(XS_builtin_inf)
{
    dXSARGS;
    if(items)
        croak_xs_usage(cv, "");
#ifdef DOUBLE_HAS_INF
    EXTEND(SP, 1);
    XSRETURN_NV(NV_INF);
#else
    PERL_THROW_BUILTIN_INF_NOT_IMPLEMENTED();
#endif
}

XS(XS_builtin_nan);
XS(XS_builtin_nan)
{
    dXSARGS;
    if(items)
        croak_xs_usage(cv, "");
#ifdef DOUBLE_HAS_NAN
    EXTEND(SP, 1);
    XSRETURN_NV(NV_NAN);
#else
    PERL_THROW_BUILTIN_NAN_NOT_IMPLEMENTED();
#endif
}

XS(XS_builtin_rand_bytes);
XS(XS_builtin_rand_bytes)
{
    dXSARGS;
    NV count_nv;
    NV integer;
    UV count;

    if (items != 1)
        croak_xs_usage(cv, "count");

    if (!SvOK(ST(0)) || !looks_like_number(ST(0)))
        PERL_THROW_ERROR_RNG_BYTES_COUNT_INVALID();

    count_nv = SvNV(ST(0));
    integer = Perl_floor(count_nv);
    if (Perl_isnan(count_nv) || Perl_isinf(count_nv)
        || count_nv < 0.0 || count_nv != integer || count_nv > (NV)UV_MAX)
        PERL_THROW_ERROR_RNG_BYTES_COUNT_INVALID();

    count = SvUV(ST(0));
    if ((NV)count != integer || (STRLEN)count != count)
        PERL_THROW_ERROR_RNG_BYTES_COUNT_TOO_LARGE();

    {
        SV *result = sv_2mortal(Perl_call_rand_bytes(aTHX_ (STRLEN)count));
        SPAGAIN;
        ST(0) = result;
    }
    XSRETURN(1);
}

XS(Perl_builtin_get_diagnostic_data);
XS(Perl_builtin_get_diagnostic_data)
{
    dXSARGS;
    SV *identifier;
    SV *result = NULL;

    if (items != 1)
        croak_xs_usage(cv, "number_or_code");

    identifier = ST(0);
    SvGETMAGIC(identifier);
    if (SvOK(identifier) && !SvROK(identifier)) {
        STRLEN length;
        const char *value = SvPV_nomg(identifier, length);
        bool decimal = length != 0;

        for (STRLEN i = 0; i < length; i++)
            if (!isDIGIT_A(value[i])) {
                decimal = FALSE;
                break;
            }

        if (decimal) {
            UV number = 0;
            bool valid = TRUE;

            for (STRLEN i = 0; i < length; i++) {
                const UV digit = (UV)(value[i] - '0');
                if (number > (UV_MAX - digit) / 10) {
                    valid = FALSE;
                    break;
                }
                number = number * 10 + digit;
            }
            if (valid)
                result = Perl_diag_data_by_number(aTHX_ number);
        }
        else
            result = Perl_diag_data_by_code(aTHX_ value, length);
    }

    SPAGAIN;
    ST(0) = result ? sv_2mortal(result) : &PL_sv_undef;
    XSRETURN(1);
}

enum {
    BUILTIN_CONST_FALSE,
    BUILTIN_CONST_TRUE,
    BUILTIN_CONST_INF,
    BUILTIN_CONST_NAN,
};

static OP *ck_builtin_const(pTHX_ OP *entersubop, GV *namegv, SV *ckobj)
{
    const struct BuiltinFuncDescriptor *builtin = NUM2PTR(const struct BuiltinFuncDescriptor *, SvUV(ckobj));

    if(builtin->is_experimental)
        warn_experimental_builtin(builtin->name);

    SV *prototype = newSVpvs("");
    SAVEFREESV(prototype);

    assert(entersubop->op_type == OP_ENTERSUB);

    entersubop = ck_entersub_args_proto(entersubop, namegv, prototype);

    SV *constval;
    switch(builtin->ckval) {
        case BUILTIN_CONST_FALSE: constval = &PL_sv_no; break;
        case BUILTIN_CONST_TRUE:  constval = &PL_sv_yes; break;
#ifdef DOUBLE_HAS_INF
        case BUILTIN_CONST_INF:   constval = newSVnv(NV_INF); break;
#else
        case BUILTIN_CONST_INF:   return entersubop;
#endif
#ifdef DOUBLE_HAS_NAN
        case BUILTIN_CONST_NAN:   constval = newSVnv(NV_NAN); break;
#else
        case BUILTIN_CONST_NAN:   return entersubop;
#endif
        default:
            PERL_PANIC_ERROR_INTERNAL_OPCODE_BUILTIN_CONSTANT_ID_UNKNOWN(builtin->ckval);
            break;
    }

    op_free(entersubop);

    return newSVOP(OP_CONST, 0, constval);
}

XS(XS_builtin_func1_scalar);
XS(XS_builtin_func1_scalar)
{
    dXSARGS;
    dXSI32;

    if(items != 1)
        croak_xs_usage(cv, "arg");

    switch(ix) {
        case OP_IS_BOOL:
            warn_experimental_builtin(PL_op_name[ix]);
            Perl_pp_is_bool(aTHX);
            break;

        case OP_IS_WEAK:
            Perl_pp_is_weak(aTHX);
            break;

        case OP_BLESSED:
            Perl_pp_blessed(aTHX);
            break;

        case OP_REFADDR:
            Perl_pp_refaddr(aTHX);
            break;

        case OP_REFTYPE:
            Perl_pp_reftype(aTHX);
            break;

        case OP_CEIL:
            Perl_pp_ceil(aTHX);
            break;

        case OP_FLOOR:
            Perl_pp_floor(aTHX);
            break;

        case OP_IS_TAINTED:
            Perl_pp_is_tainted(aTHX);
            break;

        case OP_STRINGIFY:
            {
                /* we could only call pp_stringify if we're sure there is a TARG
                   and if the XSUB is called from call_sv() or goto it may not
                   have one.
                */
                dXSTARG;
                sv_copypv(TARG, *PL_stack_sp);
                SvSETMAGIC(TARG);
                rpp_replace_1_1_NN(TARG);
            }
            break;

        default:
            PERL_PANIC_ERROR_INTERNAL_OPCODE_BUILTIN_SCALAR_DISPATCH_OP_UNKNOWN((IV) ix);
    }

    XSRETURN(1);
}

XS(XS_builtin_trim);
XS(XS_builtin_trim)
{
    dXSARGS;

    if (items != 1) {
        croak_xs_usage(cv, "arg");
    }

    dXSTARG;
    SV *source = TOPs;
    STRLEN len;
    const U8 *start;

    SvGETMAGIC(source);

    if (SvOK(source))
        start = (const U8*)SvPV_nomg_const(source, len);
    else {
        if (ckWARN(WARN_UNINITIALIZED))
            report_uninit(source);
        start = (const U8*)"";
        len = 0;
    }

    if (DO_UTF8(source)) {
        const U8 *end = start + len;

        /* Find the first non-space */
        while(len) {
            STRLEN thislen;
            if (!isSPACE_utf8_safe(start, end))
                break;
            start += (thislen = UTF8SKIP(start));
            len -= thislen;
        }

        /* Find the final non-space */
        STRLEN thislen;
        const U8 *cur_end = end;
        while ((thislen = is_SPACE_utf8_safe_backwards(cur_end, start))) {
            cur_end -= thislen;
        }
        len -= (end - cur_end);
    }
    else if (len) {
        while(len) {
            if (!isSPACE_L1(*start))
                break;
            start++;
            len--;
        }

        while(len) {
            if (!isSPACE_L1(start[len-1]))
                break;
            len--;
        }
    }

    sv_setpvn(TARG, (const char *)start, len);

    if (DO_UTF8(source))
        SvUTF8_on(TARG);
    else
        SvUTF8_off(TARG);

    SETTARG;

    XSRETURN(1);
}

XS(XS_builtin_export_lexically);
XS(XS_builtin_export_lexically)
{
    dXSARGS;

    warn_experimental_builtin("export_lexically");

    if(!PL_compcv)
        PERL_THROW_ERROR_LEXICAL_EXPORT_OUTSIDE_COMPILATION();

    if(items % 2)
        PERL_THROW_ERROR_LEXICAL_EXPORT_ODD_ARGUMENT_COUNT();

    for(int i = 0; i < items; i += 2) {
        SV *name = ST(i);
        SV *ref  = ST(i+1);

        if(!SvROK(ref))
            /* diag_listed_as: Expected %s reference in export_lexically */
            PERL_THROW_ERROR_LEXICAL_EXPORT_REFERENCE_REQUIRED();

        char sigil = SvPVX(name)[0];
        SV *rv = SvRV(ref);

        const char *bad = NULL;
        switch(sigil) {
            default:
                /* overwrites the pointer on the stack; but this is fine, the
                 * caller's value isn't modified */
                ST(i) = name = sv_2mortal(newSVpvf("&%" SVf, SVfARG(name)));

                /* FALLTHROUGH */
            case '&':
                if(SvTYPE(rv) != SVt_PVCV)
                    bad = "code";
                break;

            case '$':
                /* Permit any of SVt_NULL to SVt_PVMG. Technically this also
                 * includes SVt_INVLIST but it isn't thought possible for pureperl
                 * code to ever manage to see one of those. */
                if(SvTYPE(rv) > SVt_PVMG)
                    bad = "SCALAR";
                break;

            case '@':
                if(SvTYPE(rv) != SVt_PVAV)
                    bad = "ARRAY";
                break;

            case '%':
                if(SvTYPE(rv) != SVt_PVHV)
                    bad = "HASH";
                break;
        }

        if(bad)
            PERL_THROW_ERROR_LEXICAL_EXPORT_REFERENCE_TYPE_MISMATCH(
                PERL_DIAG_SELECTOR_FROM_ERROR_LEXICAL_EXPORT_REFERENCE_TYPE_MISMATCH_REFERENCE_TYPE(
                    bad));
    }

    prepare_export_lexical();

    for(int i = 0; i < items; i += 2) {
        SV *name = ST(i);
        SV *ref  = ST(i+1);

        export_lexical(name, SvRV(ref));
    }

    finish_export_lexical();
}

XS(XS_builtin_func1_void);
XS(XS_builtin_func1_void)
{
    dXSARGS;
    dXSI32;

    if(items != 1)
        croak_xs_usage(cv, "arg");

    switch(ix) {
        case OP_WEAKEN:
            Perl_pp_weaken(aTHX);
            break;

        case OP_UNWEAKEN:
            Perl_pp_unweaken(aTHX);
            break;

        default:
            PERL_PANIC_ERROR_INTERNAL_OPCODE_BUILTIN_VOID_DISPATCH_OP_UNKNOWN((IV) ix);
    }

    XSRETURN(0);
}

XS(XS_builtin_created_as_string)
{
    dXSARGS;

    if(items != 1)
        croak_xs_usage(cv, "arg");

    SV *arg = ST(0);
    SvGETMAGIC(arg);

    /* SV was created as string if it has POK and isn't bool */
    ST(0) = boolSV(SvPOK(arg) && !SvIsBOOL(arg));
    XSRETURN(1);
}

XS(XS_builtin_created_as_number)
{
    dXSARGS;

    if(items != 1)
        croak_xs_usage(cv, "arg");

    SV *arg = ST(0);
    SvGETMAGIC(arg);

    /* SV was created as number if it has NOK or IOK but not POK and is not bool */
    ST(0) = boolSV(SvNIOK(arg) && !SvPOK(arg) && !SvIsBOOL(arg));
    XSRETURN(1);
}

static OP *ck_builtin_func1(pTHX_ OP *entersubop, GV *namegv, SV *ckobj)
{
    const struct BuiltinFuncDescriptor *builtin = NUM2PTR(const struct BuiltinFuncDescriptor *, SvUV(ckobj));

    if(builtin->is_experimental)
        warn_experimental_builtin(builtin->name);

    SV *prototype = newSVpvs("$");
    SAVEFREESV(prototype);

    assert(entersubop->op_type == OP_ENTERSUB);

    entersubop = ck_entersub_args_proto(entersubop, namegv, prototype);

    OPCODE opcode = builtin->ckval;
    if(!opcode)
        return entersubop;

    OP *pushop = cUNOPx(entersubop)->op_first;
    if (!OpHAS_SIBLING(pushop)) {
        pushop = cUNOPx(pushop)->op_first;
    }

    OP *argop = OpSIBLING(pushop);

    if (!argop || !OpHAS_SIBLING(argop) || OpHAS_SIBLING(OpSIBLING(argop)))
        return entersubop;

    {
        OP *const excised = op_sibling_splice(NULL, pushop, 1, NULL);
        PERL_UNUSED_VAR(excised);
        assert(excised == argop);
    }

    U8 wantflags = entersubop->op_flags & OPf_WANT;

    op_free(entersubop);

    if(opcode == OP_STRINGIFY)
        /* Even though pp_stringify only looks at TOPs and conceptually works
         * on a single argument, it happens to be a LISTOP. I've no idea why
         */
        return newLISTOPn(opcode, wantflags,
            argop,
            NULL);
    else {
        OP * const op = newUNOP(opcode, wantflags, argop);

        /* since these pp funcs can be called from XS, and XS may be called
           without a normal ENTERSUB, we need to indicate to them that a targ
           has been allocated.
        */
        if (op->op_targ)
            op->op_private |= OPpENTERSUB_HASTARG;

        return op;
    }
}

/* This does not use the XS() macro so that op.c can see its prototype */
void
Perl_XS_builtin_indexed(pTHX_ CV *cv)
{
    PERL_ARGS_ASSERT_XS_BUILTIN_INDEXED;

    dXSARGS;
    PERL_UNUSED_ARG(cv);

    switch(GIMME_V) {
        case G_VOID:
            PERL_WARN_WARNING_VOID_USELESS_EXPRESSION_PV(
                perl_diag_selector_domain_2072_0_literal_5,
                perl_diag_word_operation_none, "builtin::indexed");
            XSRETURN(0);

        case G_SCALAR:
            PERL_WARN_WARNING_SCALAR_USELESS_EXPRESSION("builtin::indexed");
            ST(0) = sv_2mortal(newSViv(items * 2));
            XSRETURN(1);

        case G_LIST:
            break;
    }

    SSize_t retcount = items * 2;
    EXTEND(SP, retcount);

    /* Copy from [items-1] down to [0] so we don't have to make
     * temporary copies */
    for(SSize_t index = items - 1; index >= 0; index--) {
        /* Copy, not alias */
        ST(index * 2 + 1) = sv_mortalcopy(ST(index));
        ST(index * 2)     = sv_2mortal(newSViv(index));
    }

    XSRETURN(retcount);
}

/* Both builtins share argument handling. XSUBANY selects the rule family,
 * keeping cardinal and ordinal mappings independent of template selection. */
XS(Perl_builtin_plural_form);
XS(Perl_builtin_plural_form)
{
    dXSARGS;
    dXSI32;
    if (items != 2)
        croak_xs_usage(cv, "language, n");

    /* Snapshot magical arguments once. FETCH may run Perl and change either
     * argument, so keep the language PV alive while reading the number. */
    SV *language_sv = sv_mortalcopy(ST(0));
    SV *n_sv = sv_mortalcopy(ST(1));
    STRLEN language_length;
    STRLEN n_length;
    const char *language;
    const char *digits;
    const char *end;
    UV n;

    if (!SvOK(n_sv) || SvROK(n_sv))
        croak_xs_usage(cv, "language, unsigned integer n");
    digits = SvPV(n_sv, n_length);
    end = digits + n_length;
    while (digits + 1 < end && *digits == '0')
        digits++;
    const char *parsed_end = end;
    if (!grok_atoUV(digits, &n, &parsed_end) || parsed_end != end)
        croak_xs_usage(cv, "language, unsigned integer n");

    if (!SvOK(language_sv) || SvROK(language_sv))
        XSRETURN_UNDEF;
    language = SvPV(language_sv, language_length);
    if (strlen(language) != language_length)
        XSRETURN_UNDEF;

    const char *form = ix
        ? Perl_ordinal_plural_form(aTHX_ language, n)
        : Perl_cardinal_plural_form(aTHX_ language, n);
    if (!form)
        XSRETURN_UNDEF;
    ST(0) = sv_2mortal(newSVpv(form, 0));
    XSRETURN(1);
}

XS(XS_builtin_load_module);
XS(XS_builtin_load_module)
{
    dXSARGS;
    if (items != 1)
        croak_xs_usage(cv, "arg");
    SV *module_name = newSVsv(ST(0));
    if (!SvPOK(module_name)) {
        SvREFCNT_dec(module_name);
        croak_xs_usage(cv, "defined string");
    }
    load_module(PERL_LOADMOD_NOIMPORT, module_name, NULL, NULL);
    /* The loaded module's name is left intentionally on the stack for the
     * caller's benefit, and becomes load_module's return value. */
    XSRETURN(1);
}

XS(XS_builtin_package_implements);
XS(XS_builtin_class_object_to_hash);
XS(XS_builtin_class_object_from_hash);

/*
=for apidoc_section $SV
=for apidoc builtin_package_implements

Returns TRUE if a package or object implements the specified role without
dispatching an overridable method.

=cut
*/
bool
Perl_builtin_package_implements(pTHX_ SV *package_or_object, SV *role)
{
    PERL_ARGS_ASSERT_BUILTIN_PACKAGE_IMPLEMENTS;
    return sv_implements_role_sv(package_or_object, role);
}

XS(XS_builtin_package_implements)
{
    dXSARGS;

    if (items != 2)
        croak_xs_usage(cv, "package-or-object, role");

    if (builtin_package_implements(ST(0), ST(1)))
        XSRETURN_YES;

    XSRETURN_NO;
}
XS(XS_builtin_class_object_to_hash)
{
    dXSARGS;
    if (items != 1)
        croak_xs_usage(cv, "object");
    ST(0) = sv_2mortal(class_object_to_hash(ST(0)));
    XSRETURN(1);
}

XS(XS_builtin_class_object_from_hash)
{
    dXSARGS;
    if (items != 2)
        croak_xs_usage(cv, "hashref, classname");
    ST(0) = sv_2mortal(class_object_from_hash(ST(0), ST(1)));
    XSRETURN(1);
}

/* These pp_ funcs all need to use dXSTARG */

PP(pp_refaddr)
{
    dXSTARG;
    SV *arg = *PL_stack_sp;

    SvGETMAGIC(arg);

    if(SvROK(arg))
        sv_setuv_mg(TARG, PTR2UV(SvRV(arg)));
    else {
        sv_set_undef(TARG);
        SvSETMAGIC(TARG);
    }

    rpp_replace_1_1_NN(TARG);
    return NORMAL;
}

PP(pp_reftype)
{
    dXSTARG;
    SV *arg = *PL_stack_sp;

    SvGETMAGIC(arg);

    if(SvROK(arg))
        sv_setpv_mg(TARG, sv_reftype(SvRV(arg), FALSE));
    else {
        sv_set_undef(TARG);
        SvSETMAGIC(TARG);
    }

    rpp_replace_1_1_NN(TARG);
    return NORMAL;
}

PP(pp_ceil)
{
    dXSTARG;
    TARGn(Perl_ceil(SvNVx(*PL_stack_sp)), 1);
    rpp_replace_1_1_NN(TARG);
    return NORMAL;
}

PP(pp_floor)
{
    dXSTARG;
    TARGn(Perl_floor(SvNVx(*PL_stack_sp)), 1);
    rpp_replace_1_1_NN(TARG);
    return NORMAL;
}

static OP *ck_builtin_funcN(pTHX_ OP *entersubop, GV *namegv, SV *ckobj)
{
    const struct BuiltinFuncDescriptor *builtin = NUM2PTR(const struct BuiltinFuncDescriptor *, SvUV(ckobj));

    if(builtin->is_experimental)
        warn_experimental_builtin(builtin->name);

    SV *prototype = newSVpvs("@");
    SAVEFREESV(prototype);

    assert(entersubop->op_type == OP_ENTERSUB);

    entersubop = ck_entersub_args_proto(entersubop, namegv, prototype);
    return entersubop;
}

#define NO_BUNDLE SHORTVER(255,255)

static const struct BuiltinFuncDescriptor builtins[] = {
    /* constants */
    { "true",  SHORTVER(5,39), false, &XS_builtin_true,   &ck_builtin_const, BUILTIN_CONST_TRUE  },
    { "false", SHORTVER(5,39), false, &XS_builtin_false,  &ck_builtin_const, BUILTIN_CONST_FALSE },
    { "inf",        NO_BUNDLE, true,  &XS_builtin_inf,    &ck_builtin_const, BUILTIN_CONST_INF   },
    { "nan",        NO_BUNDLE, true,  &XS_builtin_nan,    &ck_builtin_const, BUILTIN_CONST_NAN   },
    { "rand_bytes", NO_BUNDLE, true,  &XS_builtin_rand_bytes, &ck_builtin_func1, 0 },
    { "get_diagnostic_data", NO_BUNDLE, true, &Perl_builtin_get_diagnostic_data, &ck_builtin_func1, 0 },

    /* unary functions */
    { "is_bool",         NO_BUNDLE, true,  &XS_builtin_func1_scalar, &ck_builtin_func1, OP_IS_BOOL    },
    { "weaken",     SHORTVER(5,39), false, &XS_builtin_func1_void,   &ck_builtin_func1, OP_WEAKEN     },
    { "unweaken",   SHORTVER(5,39), false, &XS_builtin_func1_void,   &ck_builtin_func1, OP_UNWEAKEN   },
    { "is_weak",    SHORTVER(5,39), false, &XS_builtin_func1_scalar, &ck_builtin_func1, OP_IS_WEAK    },
    { "blessed",    SHORTVER(5,39), false, &XS_builtin_func1_scalar, &ck_builtin_func1, OP_BLESSED    },
    { "refaddr",    SHORTVER(5,39), false, &XS_builtin_func1_scalar, &ck_builtin_func1, OP_REFADDR    },
    { "reftype",    SHORTVER(5,39), false, &XS_builtin_func1_scalar, &ck_builtin_func1, OP_REFTYPE    },
    { "ceil",       SHORTVER(5,39), false, &XS_builtin_func1_scalar, &ck_builtin_func1, OP_CEIL       },
    { "floor",      SHORTVER(5,39), false, &XS_builtin_func1_scalar, &ck_builtin_func1, OP_FLOOR      },
    { "is_tainted", SHORTVER(5,39), false, &XS_builtin_func1_scalar, &ck_builtin_func1, OP_IS_TAINTED },
    { "trim",       SHORTVER(5,39), false, &XS_builtin_trim,         &ck_builtin_func1, 0             },
    { "stringify",       NO_BUNDLE, true,  &XS_builtin_func1_scalar, &ck_builtin_func1, OP_STRINGIFY  },

    { "created_as_string", NO_BUNDLE, true, &XS_builtin_created_as_string, &ck_builtin_func1, 0 },
    { "created_as_number", NO_BUNDLE, true, &XS_builtin_created_as_number, &ck_builtin_func1, 0 },

    { "cardinal_plural_form", NO_BUNDLE, true, &Perl_builtin_plural_form, &ck_builtin_funcN, 0 },
    { "ordinal_plural_form",  NO_BUNDLE, true, &Perl_builtin_plural_form, &ck_builtin_funcN, 1 },

    { "load_module", NO_BUNDLE, true, &XS_builtin_load_module, &ck_builtin_func1, 0 },

    { "package_implements", NO_BUNDLE, true, &XS_builtin_package_implements, NULL, 0 },
    { "class_object_to_hash", NO_BUNDLE, true, &XS_builtin_class_object_to_hash, NULL, 0 },
    { "class_object_from_hash", NO_BUNDLE, true, &XS_builtin_class_object_from_hash, NULL, 0 },
    /* list functions */
    { "indexed",          SHORTVER(5,39), false, &Perl_XS_builtin_indexed,     &ck_builtin_funcN, 0 },
    { "export_lexically",      NO_BUNDLE, true,  &XS_builtin_export_lexically, NULL,              0 },

    { NULL, 0, false, NULL, NULL, 0 }
};

static bool S_parse_version(const char *vstr, const char *vend, UV *vmajor, UV *vminor)
{
    /* Parse a string like "5.35" to yield 5 and 35. Ignores an optional
     * trailing third component e.g. "5.35.7". Returns false on parse errors.
     */

    const char *end = vend;
    if (!grok_atoUV(vstr, vmajor, &end))
        return FALSE;

    vstr = end;
    if (*vstr++ != '.')
        return FALSE;

    end = vend;
    if (!grok_atoUV(vstr, vminor, &end))
        return FALSE;

    if(*vminor > 255)
        return FALSE;

    vstr = end;

    if(vstr[0] == '.') {
        vstr++;

        UV _dummy;
        if(!grok_atoUV(vstr, &_dummy, &end))
            return FALSE;
        if(_dummy > 255)
            return FALSE;

        vstr = end;
    }

    if(vstr != vend)
        return FALSE;

    return TRUE;
}

#define import_sym(sym)  S_import_sym(aTHX_ sym)
static bool S_cv_is_builtin(pTHX_ CV *cv);
static void S_import_sym(pTHX_ SV *sym)
{
    SV *ampname = sv_2mortal(newSVpvf("&%" SVf, SVfARG(sym)));
    SV *fqname = sv_2mortal(newSVpvf("builtin::%" SVf, SVfARG(sym)));

    CV *cv = get_cv(SvPV_nolen(fqname), SvUTF8(fqname) ? SVf_UTF8 : 0);
    if(!cv)
        PERL_THROW_ERROR_LEXICAL_IMPORT_UNKNOWN_BUILTIN(sym);

    /* A version declaration can import a builtin bundle before -E's
     * implicit builtin ':all'.  Re-importing the same lexical function is
     * harmless and must not produce a duplicate-declaration warning. */
    {
        PADOFFSET off = pad_findmy_sv(ampname, 0);
        if (off != NOT_IN_PAD
            && S_cv_is_builtin(aTHX_ (CV *)PL_curpad[off]))
            return;
    }

    export_lexical(ampname, (SV *)cv);
}

#define cv_is_builtin(cv)  S_cv_is_builtin(aTHX_ cv)
static bool S_cv_is_builtin(pTHX_ CV *cv)
{
    char *file = CvFILE(cv);
    return file && strEQ(file, __FILE__);
}

void
Perl_import_builtin_bundle(pTHX_ U16 ver)
{
    PERL_ARGS_ASSERT_IMPORT_BUILTIN_BUNDLE;

    SV *ampname = sv_newmortal();

    for(int i = 0; builtins[i].name; i++) {
        sv_setpvf(ampname, "&%s", builtins[i].name);

        bool want = (builtins[i].since_ver <= ver);

        bool got = false;
        PADOFFSET off = pad_findmy_sv(ampname, 0);
        CV *cv;
        if(off != NOT_IN_PAD &&
                SvTYPE((cv = (CV *)PL_curpad[off])) == SVt_PVCV &&
                cv_is_builtin(cv))
            got = true;

        if(!got && want) {
            import_sym(newSVpvn_flags(builtins[i].name, strlen(builtins[i].name), SVs_TEMP));
        }
    }
}

XS(XS_builtin_import);
XS(XS_builtin_import)
{
    dXSARGS;

    if(!PL_compcv)
        PERL_THROW_ERROR_LEXICAL_IMPORT_OUTSIDE_COMPILATION();

    prepare_export_lexical();

    for(int i = 1; i < items; i++) {
        SV *sym = ST(i);
        STRLEN symlen;
        const char *sympv = SvPV(sym, symlen);
        if(strEQ(sympv, "import"))
            PERL_THROW_ERROR_LEXICAL_IMPORT_UNKNOWN_BUILTIN(sym);

        if(sympv[0] == ':') {
            if (strEQ(sympv, ":all")) {
                for (int j = 0; builtins[j].name; j++)
                    import_sym(newSVpvn_flags(builtins[j].name,
                                               strlen(builtins[j].name),
                                               SVs_TEMP));
                continue;
            }
            UV vmajor, vminor;
            if(!S_parse_version(sympv + 1, sympv + symlen, &vmajor, &vminor))
                PERL_THROW_ERROR_LEXICAL_IMPORT_INVALID_VERSION_BUNDLE(sym);

            U16 want_ver = SHORTVER(vmajor, vminor);

            if(want_ver < SHORTVER(5,39) ||
                    /* round up devel version to next major release; e.g. 5.39 => 5.40 */
                    want_ver > SHORTVER(PERL_REVISION, PERL_VERSION + (PERL_VERSION % 2)))
                PERL_THROW_ERROR_LEXICAL_IMPORT_UNSUPPORTED_VERSION_BUNDLE(sympv, PERL_VERSION_STRING);

            import_builtin_bundle(want_ver);

            continue;
        }

        import_sym(sym);
    }

    finish_export_lexical();
}

void
Perl_boot_core_builtin(pTHX)
{
    PERL_ARGS_ASSERT_BOOT_CORE_BUILTIN;

    I32 i;
    for(i = 0; builtins[i].name; i++) {
        const struct BuiltinFuncDescriptor *builtin = &builtins[i];

        const char *proto = NULL;
        if(builtin->checker == &ck_builtin_const)
            proto = "";
        else if(builtin->checker == &ck_builtin_func1)
            proto = "$";
        else if(builtin->checker == &ck_builtin_funcN)
            proto = "@";

        SV *name = newSVpvs_flags("builtin::", SVs_TEMP);
        sv_catpv(name, builtin->name);
        CV *cv = newXS_flags(SvPV_nolen(name), builtin->xsub, __FILE__, proto, 0);
        XSANY.any_i32 = builtin->ckval;

        if (   builtin->xsub == &XS_builtin_func1_void
            || builtin->xsub == &XS_builtin_func1_scalar)
        {
            /* these XS functions just call out to the relevant pp()
             * functions, so they must operate with a reference-counted
             * stack if the pp() do too.
             */
                CvXS_RCSTACK_on(cv);
        }

        if(builtin->checker) {
            cv_set_call_checker_flags(cv, builtin->checker, newSVuv(PTR2UV(builtin)), 0);
        }
    }

    newXS_flags("builtin::import", &XS_builtin_import, __FILE__, NULL, 0);
}

/*
 * ex: set ts=8 sts=4 sw=4 et:
 */
