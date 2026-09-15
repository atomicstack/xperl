/*    pp_ctl.c
 *
 *    Copyright (C) 1991, 1992, 1993, 1994, 1995, 1996, 1997, 1998, 1999, 2000,
 *    2001, 2002, 2003, 2004, 2005, 2006, 2007, 2008 by Larry Wall and others
 *
 *    You may distribute under the terms of either the GNU General Public
 *    License or the Artistic License, as specified in the README file.
 *
 */

/*
 *      Now far ahead the Road has gone,
 *          And I must follow, if I can,
 *      Pursuing it with eager feet,
 *          Until it joins some larger way
 *      Where many paths and errands meet.
 *          And whither then?  I cannot say.
 *
 *     [Bilbo on p.35 of _The Lord of the Rings_, I/i: "A Long-Expected Party"]
 */

/* This file contains control-oriented pp ("push/pop") functions that
 * execute the opcodes that make up a perl program. A typical pp function
 * expects to find its arguments on the stack, and usually pushes its
 * results onto the stack, hence the 'pp' terminology. Each OP structure
 * contains a pointer to the relevant pp_foo() function.
 *
 * Control-oriented means things like pp_enteriter() and pp_next(), which
 * alter the flow of control of the program.
 */


#include "EXTERN.h"
#define PERL_IN_PP_CTL_C
#include "perl.h"
#include "feature.h"

#define dopopto_cursub() \
    (PL_curstackinfo->si_cxsubix >= 0        \
        ? PL_curstackinfo->si_cxsubix        \
        : dopoptosub_at(cxstack, cxstack_ix))

#define dopoptosub(plop)	dopoptosub_at(cxstack, (plop))

PP(pp_wantarray)
{
    I32 cxix;
    const PERL_CONTEXT *cx;
    SV *sv;

    if (PL_op->op_private & OPpOFFBYONE) {
        if (!(cx = caller_cx(1,NULL))) {
            sv = &PL_sv_undef;
            goto ret;
        }
    }
    else {
      cxix = dopopto_cursub();
      if (cxix < 0) {
        sv = &PL_sv_undef;
        goto ret;
      }
      cx = &cxstack[cxix];
    }

    switch (cx->blk_gimme) {
    case G_LIST:
        sv = &PL_sv_yes;
        break;
    case G_SCALAR:
        sv = &PL_sv_no;
        break;
    default:
        sv = &PL_sv_undef;
        break;
    }

  ret:
    rpp_xpush_IMM(sv);
    return NORMAL;
}

PP(pp_regcreset)
{
    TAINT_NOT;
    return NORMAL;
}

PP(pp_regcomp)
{
    PMOP *pm = cPMOPx(cLOGOP->op_other);
    SV **args;
    int nargs;
    REGEXP *re = NULL;
    REGEXP *new_re;
    const regexp_engine *eng;
    bool is_bare_re= FALSE;

    if (PL_op->op_flags & OPf_STACKED) {
        dMARK;
        nargs = PL_stack_sp - MARK;
        args  = ++MARK;
    }
    else {
        nargs = 1;
        args  = PL_stack_sp;
    }

    /* prevent recompiling under /o and ithreads. */
#if defined(USE_ITHREADS)
    if (pm->op_pmflags & PMf_KEEP && PM_GETRE(pm))
        goto finish;
#endif

    re = PM_GETRE(pm);
    assert (re != (REGEXP*) &PL_sv_undef);
    eng = re ? RX_ENGINE(re) : current_re_engine();

    new_re = (eng->op_comp
                    ? eng->op_comp
                    : &Perl_re_op_compile
            )(aTHX_ args, nargs, pm->op_code_list, eng, re,
                &is_bare_re,
                (pm->op_pmflags & RXf_PMf_FLAGCOPYMASK),
                pm->op_pmflags |
                    (PL_op->op_flags & OPf_SPECIAL ? PMf_USE_RE_EVAL : 0));

    if (pm->op_pmflags & PMf_HAS_CV)
        ReANY(new_re)->qr_anoncv
                        = (CV*) SvREFCNT_inc(PAD_SV(PL_op->op_targ));

    if (is_bare_re) {
        REGEXP *tmp;
        /* The match's LHS's get-magic might need to access this op's regexp
           (e.g. $' =~ /$re/ while foo; see bug 70764).  So we must call
           get-magic now before we replace the regexp. Hopefully this hack can
           be replaced with the approach described at
           https://www.nntp.perl.org/group/perl.perl5.porters/2007/03/msg122415.html
           some day. */
        if (pm->op_type == OP_MATCH) {
            SV *lhs;
            const bool was_tainted = TAINT_get;
            if (pm->op_flags & OPf_STACKED)
                lhs = args[-1];
            else if (pm->op_targ)
                lhs = PAD_SV(pm->op_targ);
            else lhs = DEFSV;
            SvGETMAGIC(lhs);
            /* Restore the previous value of PL_tainted (which may have been
               modified by get-magic), to avoid incorrectly setting the
               RXf_TAINTED flag with RX_TAINT_on further down. */
            TAINT_set(was_tainted);
#ifdef NO_TAINT_SUPPORT
            PERL_UNUSED_VAR(was_tainted);
#endif
        }
        tmp = reg_temp_copy(NULL, new_re);
        ReREFCNT_dec(new_re);
        new_re = tmp;
    }

    if (re != new_re) {
        ReREFCNT_dec(re);
        PM_SETRE(pm, new_re);
    }


    assert(TAINTING_get || !TAINT_get);
    if (TAINT_get) {
        SvTAINTED_on((SV*)new_re);
        RX_TAINT_on(new_re);
    }

    /* handle the empty pattern */
    if (!RX_PRELEN(new_re) && PL_curpm) {
        if (PL_curpm == PL_reg_curpm) {
            if (PL_curpm_under && PL_curpm_under == PL_reg_curpm) {
                croak("Infinite recursion via empty pattern");
            }
        }
    }

#if !defined(USE_ITHREADS)
    /* can't change the optree at runtime either */
    /* PMf_KEEP is handled differently under threads to avoid these problems */
    if (pm->op_pmflags & PMf_KEEP) {
        cLOGOP->op_first->op_next = PL_op->op_next;
    }
#endif

#if defined(USE_ITHREADS)
  finish:
#endif
    rpp_popfree_to_NN(args - 1);
    return NORMAL;
}


/* s/.../expr/e is executed in order as if written as
 *
 * pp_subst();
 * while (pp_substcont()) {
 *     expr;
 * }
 *
 * Only on the second and later calls to pp_substcont() is there a scalar
 * on the stack holding the value of expr.
 *
 * Note that pp_subst() leaves its original 0-2 args on the stack to
 * avoid them being prematurely freed. It is pp_substcont()'s
 * responsibility to pop them after the last iteration.
 */

PP(pp_substcont)
{
    PERL_CONTEXT *cx = CX_CUR();
    PMOP * const pm = cPMOPx(cLOGOP->op_other);
    SV * const dstr = cx->sb_dstr;
    char *s = cx->sb_s;
    char *m = cx->sb_m;
    char *orig = cx->sb_orig;
    REGEXP * const rx = cx->sb_rx;
    SV *nsv = NULL;
    REGEXP *old = PM_GETRE(pm);

    PERL_ASYNC_CHECK();

    if(old != rx) {
        if(old)
            ReREFCNT_dec(old);
        PM_SETRE(pm,ReREFCNT_inc(rx));
    }

    rxres_restore(&cx->sb_rxres, rx);

    if (cx->sb_iters++) {
        /* second+ time round. Result is on stack */
        const SSize_t saviters = cx->sb_iters;
        if (cx->sb_iters > cx->sb_maxiters)
            DIE(aTHX_ "Substitution loop");

        SvGETMAGIC(*PL_stack_sp); /* possibly clear taint on $1 etc: #67962 */

        /* See "how taint works": pp_subst() in pp_hot.c */
        sv_catsv_nomg(dstr, *PL_stack_sp);
        if (sv_has_valuemagic(*PL_stack_sp))
            mg_propagate(*PL_stack_sp, dstr);
        rpp_popfree_1_NN();
        if (UNLIKELY(TAINT_get))
            cx->sb_rxtainted |= SUBST_TAINT_REPL;
        if (CxONCE(cx) || s < orig ||
                !CALLREGEXEC(rx, s, cx->sb_strend, orig,
                             (s == m), cx->sb_targ, NULL,
                    (REXEC_IGNOREPOS|REXEC_NOT_FIRST|REXEC_FAIL_ON_UNDERFLOW)))
        {
            /* no more iterations. Push return value etc */
            SV *targ = cx->sb_targ;
            SV *retval;

            assert(cx->sb_strend >= s);
            if(cx->sb_strend > s) {
                 if (DO_UTF8(dstr) && !SvUTF8(targ))
                      sv_catpvn_nomg_utf8_upgrade(dstr, s, cx->sb_strend - s, nsv);
                 else
                      sv_catpvn_nomg(dstr, s, cx->sb_strend - s);
            }
            if (RX_MATCH_TAINTED(rx)) /* run time pattern taint, eg locale */
                cx->sb_rxtainted |= SUBST_TAINT_PAT;

            if (pm->op_pmflags & PMf_NONDESTRUCT) {
                retval = dstr;
                /* From here on down we're using the copy, and leaving the
                   original untouched.  */
                targ = dstr;
            }
            else {
                SV_CHECK_THINKFIRST_COW_DROP(targ);
                if (isGV(targ)) croak_no_modify();
                SvPV_free(targ);
                SvPV_set(targ, SvPVX(dstr));
                SvCUR_set(targ, SvCUR(dstr));
                SvLEN_set(targ, SvLEN(dstr));
                if (DO_UTF8(dstr))
                    SvUTF8_on(targ);
                SvPV_set(dstr, NULL);
                if (sv_has_valuemagic(dstr))
                    mg_propagate(dstr, targ);

                PL_tainted = 0;
                retval = sv_newmortal();
                sv_setiv(retval, saviters - 1);

                (void)SvPOK_only_UTF8(targ);
            }

            /* pop the original args (if any) to pp_subst(),
             * then push the result */
            if (pm->op_pmflags & PMf_CONST)
                rpp_popfree_1_NN(); /* pop replacement string */
            if (pm->op_flags & OPf_STACKED)
                rpp_replace_1_1_NN(retval); /* pop LHS of =~ */
            else
                rpp_push_1(retval);

            /* update the taint state of various variables in
             * preparation for final exit.
             * See "how taint works": pp_subst() in pp_hot.c */
            if (TAINTING_get) {
                if ((cx->sb_rxtainted & SUBST_TAINT_PAT) ||
                    ((cx->sb_rxtainted & (SUBST_TAINT_STR|SUBST_TAINT_RETAINT))
                                    == (SUBST_TAINT_STR|SUBST_TAINT_RETAINT))
                )
                    (RX_MATCH_TAINTED_on(rx)); /* taint $1 et al */

                if (!(cx->sb_rxtainted & SUBST_TAINT_BOOLRET)
                    && (cx->sb_rxtainted & (SUBST_TAINT_STR|SUBST_TAINT_PAT))
                )
                    SvTAINTED_on(retval);  /* taint return value */
                /* needed for mg_set below */
                TAINT_set(
                    cBOOL(cx->sb_rxtainted &
                          (SUBST_TAINT_STR|SUBST_TAINT_PAT|SUBST_TAINT_REPL))
                );

                /* sv_magic(), when adding magic (e.g.taint magic), also
                 * recalculates any pos() magic, converting any byte offset
                 * to utf8 offset. Make sure pos() is reset before this
                 * happens rather than using the now invalid value (since
                 * we've just replaced targ's pvx buffer with the
                 * potentially shorter dstr buffer). Normally (i.e. in
                 * non-taint cases), pos() gets removed a few lines later
                 * with the SvSETMAGIC().
                 */
                {
                    MAGIC *mg;
                    mg = mg_find_mglob(targ);
                    if (mg) {
                        MgBYTEPOS_set(mg, targ, SvPVX(targ), -1);
                    }
                }

                SvTAINT(TARG);
            }
            /* PL_tainted must be correctly set for this mg_set */
            SvSETMAGIC(TARG);
            TAINT_NOT;

            CX_LEAVE_SCOPE(cx);
            CX_POPSUBST(cx);
            CX_POP(cx);

            PERL_ASYNC_CHECK();
            return pm->op_next;
            NOT_REACHED; /* NOTREACHED */
        }
        cx->sb_iters = saviters;
    }

    /* First iteration. The substitution expression hasn;'t been executed
     * this time */

    if (RX_MATCH_COPIED(rx) && RX_SUBBEG(rx) != orig) {
        m = s;
        s = orig;
        assert(!RX_SUBOFFSET(rx));
        cx->sb_orig = orig = RX_SUBBEG(rx);
        s = orig + (m - s);
        cx->sb_strend = s + (cx->sb_strend - m);
    }
    cx->sb_m = m = RX_OFFS_START(rx,0) + orig;
    if (m > s) {
        if (DO_UTF8(dstr) && !SvUTF8(cx->sb_targ))
            sv_catpvn_nomg_utf8_upgrade(dstr, s, m - s, nsv);
        else
            sv_catpvn_nomg(dstr, s, m-s);
    }
    cx->sb_s = RX_OFFS_END(rx,0) + orig;
    { /* Update the pos() information. */
        SV * const sv
            = (pm->op_pmflags & PMf_NONDESTRUCT) ? cx->sb_dstr : cx->sb_targ;
        MAGIC *mg;

        /* the string being matched against may no longer be a string,
         * e.g. $_=0; s/.../$_++/ge */

        if (!SvPOK(sv))
            SvPV_force_nomg_nolen(sv);

        if (!(mg = mg_find_mglob(sv))) {
            mg = sv_magicext_mglob(sv);
        }
        MgBYTEPOS_set(mg, sv, SvPVX(sv), m - orig);
    }
    if (old != rx)
        (void)ReREFCNT_inc(rx);
    /* update the taint state of various variables in preparation
     * for calling the code block.
     * See "how taint works": pp_subst() in pp_hot.c */
    if (TAINTING_get) {
        if (RX_MATCH_TAINTED(rx)) /* run time pattern taint, eg locale */
            cx->sb_rxtainted |= SUBST_TAINT_PAT;

        if ((cx->sb_rxtainted & SUBST_TAINT_PAT) ||
            ((cx->sb_rxtainted & (SUBST_TAINT_STR|SUBST_TAINT_RETAINT))
                            == (SUBST_TAINT_STR|SUBST_TAINT_RETAINT))
        )
            (RX_MATCH_TAINTED_on(rx)); /* taint $1 et al */

        if (cx->sb_iters > 1 && (cx->sb_rxtainted & 
                        (SUBST_TAINT_STR|SUBST_TAINT_PAT|SUBST_TAINT_REPL)))
            SvTAINTED_on((pm->op_pmflags & PMf_NONDESTRUCT)
                         ? cx->sb_dstr : cx->sb_targ);
        TAINT_NOT;
    }
    rxres_save(&cx->sb_rxres, rx);
    PL_curpm = pm;
    return pm->op_pmstashstartu.op_pmreplstart;
}


void
Perl_rxres_save(pTHX_ void **rsp, REGEXP *rx)
{
    PERL_ARGS_ASSERT_RXRES_SAVE;

    UV *p = (UV*)*rsp;
    U32 i;


    /* deal with regexp_paren_pair items */
    if (!p || p[1] < RX_NPARENS(rx)) {
#ifdef PERL_ANY_COW
        i = 7 + (RX_NPARENS(rx)+1) * 2;
#else
        i = 6 + (RX_NPARENS(rx)+1) * 2;
#endif
        if (!p)
            Newx(p, i, UV);
        else
            Renew(p, i, UV);
        *rsp = (void*)p;
    }

    /* what (if anything) to free on croak */
    *p++ = PTR2UV(RX_MATCH_COPIED(rx) ? RX_SUBBEG(rx) : NULL);
    RX_MATCH_COPIED_off(rx);
    *p++ = RX_NPARENS(rx);

#ifdef PERL_ANY_COW
    *p++ = PTR2UV(RX_SAVED_COPY(rx));
    RX_SAVED_COPY(rx) = NULL;
#endif

    *p++ = PTR2UV(RX_SUBBEG(rx));
    *p++ = (UV)RX_SUBLEN(rx);
    *p++ = (UV)RX_SUBOFFSET(rx);
    *p++ = (UV)RX_SUBCOFFSET(rx);
    for (i = 0; i <= RX_NPARENS(rx); ++i) {
        *p++ = (UV)RX_OFFSp(rx)[i].start;
        *p++ = (UV)RX_OFFSp(rx)[i].end;
    }
}

static void
S_rxres_restore(pTHX_ void **rsp, REGEXP *rx)
{
    PERL_ARGS_ASSERT_RXRES_RESTORE;

    UV *p = (UV*)*rsp;
    U32 i;

    RX_MATCH_COPY_FREE(rx);
    RX_MATCH_COPIED_set(rx, *p);
    *p++ = 0;
    RX_NPARENS(rx) = *p++;

#ifdef PERL_ANY_COW
    if (RX_SAVED_COPY(rx))
        SvREFCNT_dec (RX_SAVED_COPY(rx));
    RX_SAVED_COPY(rx) = INT2PTR(SV*,*p);
    *p++ = 0;
#endif

    RX_SUBBEG(rx) = INT2PTR(char*,*p++);
    RX_SUBLEN(rx) = (SSize_t)(*p++);
    RX_SUBOFFSET(rx) = (Size_t)*p++;
    RX_SUBCOFFSET(rx) = (SSize_t)*p++;
    for (i = 0; i <= RX_NPARENS(rx); ++i) {
        RX_OFFSp(rx)[i].start = (SSize_t)(*p++);
        RX_OFFSp(rx)[i].end = (SSize_t)(*p++);
    }
}

static void
S_rxres_free(pTHX_ void **rsp)
{
    PERL_ARGS_ASSERT_RXRES_FREE;

    UV * const p = (UV*)*rsp;

    if (p) {
        void *tmp = INT2PTR(char*,*p);
#ifdef PERL_POISON
#  ifdef PERL_ANY_COW
        U32 i = 9 + p[1] * 2;
#  else
        U32 i = 8 + p[1] * 2;
#  endif
#endif

#ifdef PERL_ANY_COW
        SvREFCNT_dec (INT2PTR(SV*,p[2]));
#endif
#ifdef PERL_POISON
        PoisonFree(p, i, sizeof(UV));
#endif

        Safefree(tmp);
        Safefree(p);
        *rsp = NULL;
    }
}

#define FORM_NUM_BLANK (1<<30)
#define FORM_NUM_POINT (1<<29)

PP_wrapped(pp_formline, 0, 1)
{
    dSP; dMARK; dORIGMARK;
    SV * const tmpForm = *++MARK;
    SV *formsv;		    /* contains text of original format */
    U32 *fpc;	    /* format ops program counter */
    char *t;	    /* current append position in target string */
    const char *f;	    /* current position in format string */
    I32 arg;
    SV *sv = NULL; /* current item */
    const char *item = NULL;/* string value of current item */
    I32 itemsize  = 0;	    /* length (chars) of item, possibly truncated */
    I32 itembytes = 0;	    /* as itemsize, but length in bytes */
    I32 fieldsize = 0;	    /* width of current field */
    I32 lines = 0;	    /* number of lines that have been output */
    bool chopspace = (strchr(PL_chopset, ' ') != NULL); /* does $: have space */
    const char *chophere = NULL; /* where to chop current item */
    STRLEN linemark = 0;    /* pos of start of line in output */
    NV value;
    bool gotsome = FALSE;   /* seen at least one non-blank item on this line */
    STRLEN len;             /* length of current sv */
    STRLEN linemax;	    /* estimate of output size in bytes */
    bool item_is_utf8 = FALSE;
    bool targ_is_utf8 = FALSE;
    const char *fmt;
    MAGIC *mg = NULL;
    U8 *source;		    /* source of bytes to append */
    STRLEN to_copy;	    /* how may bytes to append */
    char trans;		    /* what chars to translate */
    bool copied_form = FALSE; /* have we duplicated the form? */

    mg = doparseform(tmpForm);

    fpc = (U32*)mg->mg_ptr;
    /* the actual string the format was compiled from.
     * with overload etc, this may not match tmpForm */
    formsv = mg->mg_obj;


    SvPV_force(PL_formtarget, len);
    if (SvTAINTED(tmpForm) || SvTAINTED(formsv))
        SvTAINTED_on(PL_formtarget);
    if (DO_UTF8(PL_formtarget))
        targ_is_utf8 = TRUE;
    /* this is an initial estimate of how much output buffer space
     * to allocate. It may be exceeded later */
    linemax = (SvCUR(formsv) * (IN_BYTES ? 1 : 3) + 1);
    t = SvGROW(PL_formtarget, len + linemax + 1);
    /* XXX from now onwards, SvCUR(PL_formtarget) is invalid */
    t += len;
    f = SvPV_const(formsv, len);

    for (;;) {
        DEBUG_f( {
            const char *name = "???";
            arg = -1;
            switch (*fpc) {
            case FF_LITERAL:	arg = fpc[1]; name = "LITERAL";	break;
            case FF_BLANK:	arg = fpc[1]; name = "BLANK";	break;
            case FF_SKIP:	arg = fpc[1]; name = "SKIP";	break;
            case FF_FETCH:	arg = fpc[1]; name = "FETCH";	break;
            case FF_DECIMAL:	arg = fpc[1]; name = "DECIMAL";	break;

            case FF_CHECKNL:	name = "CHECKNL";	break;
            case FF_CHECKCHOP:	name = "CHECKCHOP";	break;
            case FF_SPACE:	name = "SPACE";		break;
            case FF_HALFSPACE:	name = "HALFSPACE";	break;
            case FF_ITEM:	name = "ITEM";		break;
            case FF_CHOP:	name = "CHOP";		break;
            case FF_LINEGLOB:	name = "LINEGLOB";	break;
            case FF_NEWLINE:	name = "NEWLINE";	break;
            case FF_MORE:	name = "MORE";		break;
            case FF_LINEMARK:	name = "LINEMARK";	break;
            case FF_END:	name = "END";		break;
            case FF_0DECIMAL:	name = "0DECIMAL";	break;
            case FF_LINESNGL:	name = "LINESNGL";	break;
            }
            if (arg >= 0)
                PerlIO_printf(Perl_debug_log, "%-16s%ld\n", name, (long) arg);
            else
                PerlIO_printf(Perl_debug_log, "%-16s\n", name);
        } );
        switch (*fpc++) {
        case FF_LINEMARK: /* start (or end) of a line */
            linemark = t - SvPVX(PL_formtarget);
            lines++;
            gotsome = FALSE;
            break;

        case FF_LITERAL: /* append <arg> literal chars */
            to_copy = *fpc++;
            source = (U8 *)f;
            f += to_copy;
            trans = '~';
            item_is_utf8 = (targ_is_utf8)
                           ? cBOOL(DO_UTF8(formsv))
                           : cBOOL(SvUTF8(formsv));
            goto append;

        case FF_SKIP: /* skip <arg> chars in format */
            f += *fpc++;
            break;

        case FF_FETCH: /* get next item and set field size to <arg> */
            arg = *fpc++;
            f += arg;
            fieldsize = arg;

            if (MARK < SP)
                sv = *++MARK;
            else {
                sv = &PL_sv_no;
                ck_warner(packWARN(WARN_SYNTAX), "Not enough format arguments");
            }
            if (SvTAINTED(sv))
                SvTAINTED_on(PL_formtarget);
            break;

        case FF_CHECKNL: /* find max len of item (up to \n) that fits field */
            {
                const char *s = item = SvPV_const(sv, len);
                const char *send = s + len;

                itemsize = 0;
                item_is_utf8 = DO_UTF8(sv);
                while (s < send) {
                    if (!isCNTRL(*s))
                        gotsome = TRUE;
                    else if (*s == '\n')
                        break;

                    if (item_is_utf8)
                        s += UTF8SKIP(s);
                    else
                        s++;
                    itemsize++;
                    if (itemsize == fieldsize)
                        break;
                }
                itembytes = s - item;
                chophere = s;
                break;
            }

        case FF_CHECKCHOP: /* like CHECKNL, but up to highest split point */
            {
                const char *s = item = SvPV_const(sv, len);
                const char *send = s + len;
                I32 size = 0;

                chophere = NULL;
                item_is_utf8 = DO_UTF8(sv);
                while (s < send) {
                    /* look for a legal split position */
                    if (isSPACE(*s)) {
                        if (*s == '\r') {
                            chophere = s;
                            itemsize = size;
                            break;
                        }
                        if (chopspace) {
                            /* provisional split point */
                            chophere = s;
                            itemsize = size;
                        }
                        /* we delay testing fieldsize until after we've
                         * processed the possible split char directly
                         * following the last field char; so if fieldsize=3
                         * and item="a b cdef", we consume "a b", not "a".
                         * Ditto further down.
                         */
                        if (size == fieldsize)
                            break;
                    }
                    else {
                        if (size == fieldsize)
                            break;
                        if (strchr(PL_chopset, *s)) {
                            /* provisional split point */
                            /* for a non-space split char, we include
                             * the split char; hence the '+1' */
                            chophere = s + 1;
                            itemsize = size + 1;
                        }
                        if (!isCNTRL(*s))
                            gotsome = TRUE;
                    }

                    if (item_is_utf8)
                        s += UTF8SKIP(s);
                    else
                        s++;
                    size++;
                }
                if (!chophere || s == send) {
                    chophere = s;
                    itemsize = size;
                }
                itembytes = chophere - item;

                break;
            }

        case FF_SPACE: /* append padding space (diff of field, item size) */
            arg = fieldsize - itemsize;
            if (arg) {
                fieldsize -= arg;
                while (arg-- > 0)
                    *t++ = ' ';
            }
            break;

        case FF_HALFSPACE: /* like FF_SPACE, but only append half as many */
            arg = fieldsize - itemsize;
            if (arg) {
                arg /= 2;
                fieldsize -= arg;
                while (arg-- > 0)
                    *t++ = ' ';
            }
            break;

        case FF_ITEM: /* append a text item, while blanking ctrl chars */
            to_copy = itembytes;
            source = (U8 *)item;
            trans = 1;
            goto append;

        case FF_CHOP: /* (for ^*) chop the current item */
            if (sv != &PL_sv_no) {
                const char *s = chophere;
                if (!copied_form &&
                    ((sv == tmpForm || SvSMAGICAL(sv))
                     || (SvGMAGICAL(tmpForm) && !sv_only_taint_gmagic(tmpForm))) ) {
                    /* sv and tmpForm are either the same SV, or magic might allow modification
                       of tmpForm when sv is modified, so copy */
                    SV *newformsv = sv_mortalcopy(formsv);
                    U32 *new_compiled;

                    f = SvPV_nolen(newformsv) + (f - SvPV_nolen(formsv));
                    Newx(new_compiled, mg->mg_len / sizeof(U32), U32);
                    memcpy(new_compiled, mg->mg_ptr, mg->mg_len);
                    SAVEFREEPV(new_compiled);
                    fpc = new_compiled + (fpc - (U32*)mg->mg_ptr);
                    formsv = newformsv;

                    copied_form = TRUE;
                }
                if (chopspace) {
                    while (isSPACE(*s))
                        s++;
                }
                if (SvPOKp(sv))
                    sv_chop(sv,s);
                else
                    /* tied, overloaded or similar strangeness.
                     * Do it the hard way */
                    sv_setpvn(sv, s, len - (s-item));
                SvSETMAGIC(sv);
                break;
            }
            /* FALLTHROUGH */

        case FF_LINESNGL: /* process ^*  */
            chopspace = 0;
            /* FALLTHROUGH */

        case FF_LINEGLOB: /* process @*  */
            {
                const bool oneline = fpc[-1] == FF_LINESNGL;
                const char *s = item = SvPV_const(sv, len);
                const char *const send = s + len;

                item_is_utf8 = DO_UTF8(sv);
                chophere = s + len;
                if (!len)
                    break;
                trans = 0;
                gotsome = TRUE;
                source = (U8 *) s;
                to_copy = len;
                while (s < send) {
                    if (*s++ == '\n') {
                        if (oneline) {
                            to_copy = s - item - 1;
                            chophere = s;
                            break;
                        } else {
                            if (s == send) {
                                to_copy--;
                            } else
                                lines++;
                        }
                    }
                }
            }

        append:
            /* append to_copy bytes from source to PL_formstring.
             * item_is_utf8 implies source is utf8.
             * if trans, translate certain characters during the copy */
            {
                void *free_me = NULL;
                STRLEN grow = 0;

                SvCUR_set(PL_formtarget,
                          t - SvPVX_const(PL_formtarget));

                if (targ_is_utf8 && !item_is_utf8) {
                    source = bytes_to_utf8_free_me(source, &to_copy, &free_me);
                    grow = to_copy;
                } else {
                    if (item_is_utf8 && !targ_is_utf8) {
                        U8 *s;
                        /* Upgrade targ to UTF8, and then we reduce it to
                           a problem we have a simple solution for.
                           Don't need get magic.  */
                        sv_utf8_upgrade_nomg(PL_formtarget);
                        targ_is_utf8 = TRUE;
                        /* re-calculate linemark */
                        s = (U8*)SvPVX(PL_formtarget);
                        /* the bytes we initially allocated to append the
                         * whole line may have been gobbled up during the
                         * upgrade, so allocate a whole new line's worth
                         * for safety */
                        grow = linemax;
                        while (linemark--)
                            s += UTF8_SAFE_SKIP(s,
                                            (U8 *) SvEND(PL_formtarget));
                        linemark = s - (U8*)SvPVX(PL_formtarget);
                    }
                    /* Easy. They agree.  */
                    assert (item_is_utf8 == targ_is_utf8);
                }
                if (!trans)
                    /* @* and ^* are the only things that can exceed
                     * the linemax, so grow by the output size, plus
                     * a whole new form's worth in case of any further
                     * output */
                    grow = linemax + to_copy;
                if (grow)
                    SvGROW(PL_formtarget, SvCUR(PL_formtarget) + grow + 1);
                t = SvPVX(PL_formtarget) + SvCUR(PL_formtarget);

                Copy(source, t, to_copy, char);
                if (trans) {
                    /* blank out ~ or control chars, depending on trans.
                     * works on bytes not chars, so relies on not
                     * matching utf8 continuation bytes */
                    U8 *s = (U8*)t;
                    U8 *send = s + to_copy;
                    while (s < send) {
                        const int ch = *s;
                        if (trans == '~' ? (ch == '~') : isCNTRL(ch))
                            *s = ' ';
                        s++;
                    }
                }

                t += to_copy;
                SvCUR_set(PL_formtarget, SvCUR(PL_formtarget) + to_copy);
                Safefree(free_me);
                break;
            }

        case FF_0DECIMAL: /* like FF_DECIMAL but for 0### */
            arg = *fpc++;
            fmt = (const char *)
                ((arg & FORM_NUM_POINT) ? "%#0*.*" NVff : "%0*.*" NVff);
            goto ff_dec;

        case FF_DECIMAL: /* do @##, ^##, where <arg>=(precision|flags) */
            arg = *fpc++;
            fmt = (const char *)
                ((arg & FORM_NUM_POINT) ? "%#*.*" NVff : "%*.*" NVff);
        ff_dec:
            /* If the field is marked with ^ and the value is undefined,
               blank it out. */
            if ((arg & FORM_NUM_BLANK) && !SvOK(sv)) {
                arg = fieldsize;
                while (arg--)
                    *t++ = ' ';
                break;
            }
            gotsome = TRUE;
            value = SvNV(sv);
            /* overflow evidence */
            if (num_overflow(value, fieldsize, arg)) {
                arg = fieldsize;
                while (arg--)
                    *t++ = '#';
                break;
            }
            /* Formats aren't yet marked for locales, so assume "yes". */
            {
                Size_t max = SvLEN(PL_formtarget) - (t - SvPVX(PL_formtarget));
                int len;
                arg &= ~(FORM_NUM_POINT|FORM_NUM_BLANK);
#ifdef USE_QUADMATH
                {
                    int len;
                    if (!quadmath_format_valid(fmt))
                        croak("panic: quadmath invalid format \"%s\"", fmt);
                    WITH_LC_NUMERIC_SET_TO_NEEDED(
                        len = quadmath_snprintf(t, max, fmt, (int) fieldsize,
                                               (int) arg, value);
                    );
                    if (len == -1)
                        croak("panic: quadmath_snprintf failed, format \"%s\"", fmt);
                }
#else
                /* we generate fmt ourselves so it is safe */
                GCC_DIAG_IGNORE_STMT(-Wformat-nonliteral);
                len = my_snprintf(t, max, fmt, (int) fieldsize, (int) arg, value);
                GCC_DIAG_RESTORE_STMT;
#endif
                PERL_MY_SNPRINTF_POST_GUARD(len, max);
            }
            t += fieldsize;
            break;

        case FF_NEWLINE: /* delete trailing spaces, then append \n */
            f++;
            while (t-- > (SvPVX(PL_formtarget) + linemark) && *t == ' ') ;
            t++;
            *t++ = '\n';
            break;

        case FF_BLANK: /* for arg==0: do '~'; for arg>0 : do '~~' */
            arg = *fpc++;
            if (gotsome) {
                if (arg) {		/* repeat until fields exhausted? */
                    fpc--;
                    goto end;
                }
            }
            else {
                t = SvPVX(PL_formtarget) + linemark;
                lines--;
            }
            break;

        case FF_MORE: /* replace long end of string with '...' */
            {
                const char *s = chophere;
                const char *send = item + len;
                if (chopspace) {
                    while (isSPACE(*s) && (s < send))
                        s++;
                }
                if (s < send) {
                    char *s1;
                    arg = fieldsize - itemsize;
                    if (arg) {
                        fieldsize -= arg;
                        while (arg-- > 0)
                            *t++ = ' ';
                    }
                    s1 = t - 3;
                    if (strBEGINs(s1,"   ")) {
                        while (s1 > SvPVX_const(PL_formtarget) && isSPACE(s1[-1]))
                            s1--;
                    }
                    *s1++ = '.';
                    *s1++ = '.';
                    *s1++ = '.';
                }
                break;
            }

        case FF_END: /* tidy up, then return */
        end:
            assert(t < SvPVX_const(PL_formtarget) + SvLEN(PL_formtarget));
            *t = '\0';
            SvCUR_set(PL_formtarget, t - SvPVX_const(PL_formtarget));
            if (targ_is_utf8)
                SvUTF8_on(PL_formtarget);
            FmLINES(PL_formtarget) += lines;
            SP = ORIGMARK;
            if (fpc[-1] == FF_BLANK)
                RETURNOP(cLISTOP->op_first);
            else
                RETPUSHYES;
        }
    }
}

/* also used for: pp_mapstart(), pp_anystart(), pp_allstart() */
PP(pp_grepstart)
{
    /* See the code comments at the start of pp_grepwhile() and
     * pp_mapwhile() for an explanation of how the stack is used
     * during a grep or map.
     */
    SV *src;
    SV **svp;

    if (PL_stack_base + TOPMARK == PL_stack_sp) {
        (void)POPMARK;

        switch(PL_op->op_type) {
            case OP_GREPSTART:
            case OP_MAPSTART:
                if (GIMME_V == G_SCALAR) {
                    rpp_extend(1);
                    *++PL_stack_sp = &PL_sv_zero;
                }
                break;

            case OP_ANYSTART:
                if (GIMME_V > G_VOID) {
                    rpp_extend(1);
                    rpp_push_IMM(&PL_sv_no);
                }
                break;

            case OP_ALLSTART:
                if (GIMME_V > G_VOID) {
                    rpp_extend(1);
                    rpp_push_IMM(&PL_sv_yes);
                }
                break;
        }

        return PL_op->op_next->op_next;
    }
    svp = PL_stack_base + TOPMARK + 1;
    PUSHMARK(svp);				/* push dst */
    PUSHMARK(svp);				/* push src */
    ENTER_with_name("grep");					/* enter outer scope */

    SAVETMPS;
    SAVE_DEFSV;
    ENTER_with_name("grep_item");					/* enter inner scope */
    SAVEVPTR(PL_curpm);

    src = PL_stack_base[TOPMARK];
    if (SvPADTMP(src)) {
        SV *newsrc = sv_mortalcopy(src);
        PL_tmps_floor++;
        PL_stack_base[TOPMARK] = newsrc;
#ifdef PERL_RC_STACK
        SvREFCNT_inc_simple_void_NN(newsrc);
        SvREFCNT_dec(src);
#endif
        src = newsrc;
    }
    SvTEMP_off(src);
    DEFSV_set(src);

    if (PL_op->op_type == OP_MAPSTART)
        PUSHMARK(PL_stack_sp);			/* push top */
    return cLOGOPx(PL_op->op_next)->op_other;
}

/* pp_grepwhile() lives in pp_hot.c */

PP(pp_mapwhile)
{
    /* Understanding the stack during a map.
     *
     * 'map expr, args' is implemented in the form of
     *
     *     grepstart; // which handles map too
     *     do {
     *          expr;
     *          mapwhile;
     *     } while (args);
     *
     * The stack examples below are in the form of 'perl -Ds' output,
     * where any stack element indexed by PL_markstack_ptr[i] has a star
     * just to the right of it.  In addition, the corresponding i value
     * is displayed under the indexed stack element.
     *
     * On entry to mapwhile, the stack looks like this:
     *
     *      =>   *  A1..An  X1  *  X2..Xn  C  *  R1..Rn  *  E1..En
     *      [-3]           [-2]          [-1]        [0]
     *
     * where:
     *   A1..An   Accumulated results from all previous iterations of expr
     *   X1..Xn   Random garbage
     *   C        The current (just processed) arg, still aliased to $_.
     *   R1..Rn   The args remaining to be processed.
     *   E1..En   the (list) result of the just-executed map expression.
     *
     * Note that it is easiest to think of stack marks [-1] and [-2] as both
     * being one too high, and so it would make more sense to have had the
     * marks like this:
     *
     *      =>   *  A1..An  *  X1..Xn  *  C  R1..Rn  *  E1..En
     *      [-3]       [-2]       [-1]           [0]
     *
     * where the stack is divided neatly into 4 groups:
     *   - accumulated results
     *   - discards and/or holes proactively created for later result storage
     *   - being, or yet to be, processed,
     *   - results of last expr
     * But off-by-one is the way it is currently, and it works as long as
     * we keep it consistent and bear it in mind.
     *
     * pp_mapwhile() does the following:
     *
     * - If there isn't enough space in the X1..Xn zone to insert the
     *   expression results, grow the stack and shift up everything above C.
     * - move E1..En to just above An
     * - at the same time, manipulate the tmps stack so that temporaries
     *   from executing expr can be freed without prematurely freeing
     *   E1..En.
     * - if on last iteration, pop all the marks, reset the stack pointer
     *   and update the return args based on caller context.
     * - else alias $_ to the next arg.
     *
     */

    const U8 gimme = GIMME_V;
    SSize_t items = (PL_stack_sp - PL_stack_base) - TOPMARK; /* how many new items */
    SSize_t count;
    SSize_t shift;
    SV** src;
    SV** dst;

#ifdef PERL_RC_STACK
    /* for ref-counted stack, we need to account for the currently-aliased
     * stack element, as it might (or might not) get over-written when
     * copying values from the expr to the end of the accumulated results
     * section of the list. By RC--ing and zeroing out the stack entry, we
     * ensure consistent handling.
     */
    dst = PL_stack_base + PL_markstack_ptr[-1];
    SvREFCNT_dec_NN(*dst);
    *dst = NULL;
#endif

    /* first, move source pointer to the next item in the source list */
    ++PL_markstack_ptr[-1];

    /* if there are new items, push them into the destination list */
    if (items && gimme != G_VOID) {
        /* might need to make room back there first */
        if (items > PL_markstack_ptr[-1] - PL_markstack_ptr[-2]) {
            /* XXX this implementation is very pessimal because the stack
             * is repeatedly extended for every set of items.  Is possible
             * to do this without any stack extension or copying at all
             * by maintaining a separate list over which the map iterates
             * (like foreach does). --gsar */

            /* everything in the stack after the destination list moves
             * towards the end the stack by the amount of room needed */
            shift = items - (PL_markstack_ptr[-1] - PL_markstack_ptr[-2]);

            /* items to shift up (accounting for the moved source pointer) */
            count = (PL_stack_sp - PL_stack_base) - (PL_markstack_ptr[-1] - 1);

            /* This optimization is by Ben Tilly and it does
             * things differently from what Sarathy (gsar)
             * is describing.  The downside of this optimization is
             * that leaves "holes" (uninitialized and hopefully unused areas)
             * to the Perl stack, but on the other hand this
             * shouldn't be a problem.  If Sarathy's idea gets
             * implemented, this optimization should become
             * irrelevant.  --jhi */
            if (shift < count)
                shift = count; /* Avoid shifting too often --Ben Tilly */

            rpp_extend(shift);
            src = PL_stack_sp;
            PL_stack_sp += shift;
            dst = PL_stack_sp;
            PL_markstack_ptr[-1] += shift;
            *PL_markstack_ptr += shift;
            while (count--)
                *dst-- = *src--;
#ifdef PERL_RC_STACK
            /* zero out the hole just created, so that on a
             * reference-counted stack, so that the just-shifted SVs
             * aren't counted twice.
             */
            Zero(src+1, (dst-src), SV*);
#endif
        }
        /* copy the new items down to the destination list */
        PL_markstack_ptr[-2] += items;
        dst = PL_stack_base + PL_markstack_ptr[-2] - 1;
        if (gimme == G_LIST) {
            /* add returned items to the collection (making mortal copies
             * if necessary), then clear the current temps stack frame
             * *except* for those items. We do this splicing the items
             * into the start of the tmps frame (so some items may be on
             * the tmps stack twice), then moving PL_tmps_floor above
             * them, then freeing the frame. That way, the only tmps that
             * accumulate over iterations are the return values for map.
             * We have to do to this way so that everything gets correctly
             * freed if we die during the map.
             */
            SSize_t tmpsbase;
            SSize_t i = items;
            /* make space for the slice */
            EXTEND_MORTAL(items);
            tmpsbase = PL_tmps_floor + 1;
            Move(PL_tmps_stack + tmpsbase,
                 PL_tmps_stack + tmpsbase + items,
                 PL_tmps_ix - PL_tmps_floor,
                 SV*);
            PL_tmps_ix += items;

            while (i-- > 0) {
#ifdef PERL_RC_STACK
                SV *sv = *PL_stack_sp;
                assert(!*dst); /* not overwriting ptrs to refcnted SVs */
                if (!SvTEMP(sv)) {
                    sv = sv_mortalcopy(sv);
                    /* NB - don't really need the mortalising above.
                     * A simple copy would suffice */
                    *dst-- = sv;
                    SvREFCNT_inc_simple_void_NN(sv);
                    rpp_popfree_1_NN();
                }
                else {
                    *dst-- = sv;
                    PL_stack_sp--;
                }

#else
                SV *sv = *PL_stack_sp--;
                if (!SvTEMP(sv))
                    sv = sv_mortalcopy(sv);
                *dst-- = sv;
#endif
                PL_tmps_stack[tmpsbase++] = SvREFCNT_inc_simple(sv);
            }
            /* clear the stack frame except for the items */
            PL_tmps_floor += items;
            FREETMPS;
            /* FREETMPS may have cleared the TEMP flag on some of the items */
            i = items;
            while (i-- > 0)
                SvTEMP_on(PL_tmps_stack[--tmpsbase]);
        }
        else {
            /* scalar context: we don't care about which values map returns
             * (we use undef here). And so we certainly don't want to do mortal
             * copies of meaningless values. */
            *(dst - items + 1) = &PL_sv_undef;
            rpp_popfree_to(PL_stack_sp - items);
            FREETMPS;
        }
    }
    else {
        if (items) {
            assert(gimme == G_VOID);
            rpp_popfree_to(PL_stack_sp - items);
        }
        FREETMPS;
    }
    LEAVE_with_name("grep_item");					/* exit inner scope */

    /* All done yet? */
    if (PL_markstack_ptr[-1] > TOPMARK) {

        (void)POPMARK;				/* pop top */
        LEAVE_with_name("grep");					/* exit outer scope */
        (void)POPMARK;				/* pop src */
        items = --*PL_markstack_ptr - PL_markstack_ptr[-1];
        (void)POPMARK;				/* pop dst */
        SV **svp = PL_stack_base + POPMARK; /* pop original mark */
        if (gimme == G_LIST)
            svp += items;
        rpp_popfree_to(svp);
        if (gimme == G_SCALAR) {
            dTARGET;
            TARGi(items, 1);
            /* XXX is the extend necessary? */
            rpp_xpush_1(targ);
        }
        return NORMAL;
    }
    else {
        SV *src;

        ENTER_with_name("grep_item");					/* enter inner scope */
        SAVEVPTR(PL_curpm);

        /* set $_ to the new source item */
        src = PL_stack_base[PL_markstack_ptr[-1]];
        if (SvPADTMP(src)) {
            SV *newsrc = sv_mortalcopy(src);
            PL_stack_base[PL_markstack_ptr[-1]] = newsrc;
#ifdef PERL_RC_STACK
            SvREFCNT_inc_simple_void_NN(newsrc);
            SvREFCNT_dec(src);
#endif
            src = newsrc;
        }
        if (SvPADTMP(src)) {
            src = sv_mortalcopy(src);
        }
        SvTEMP_off(src);
        DEFSV_set(src);

        return cLOGOP->op_other;
    }
}

PP(pp_anywhile)
{
    OPCODE op_type = cUNOP->op_first->op_type;

    bool match = SvTRUE_NN(*PL_stack_sp);
    rpp_popfree_1_NN();

    ++*PL_markstack_ptr;
    FREETMPS;
    LEAVE_with_name("grep_item");

    bool result;

    if((op_type == OP_ANYSTART && match) || (op_type == OP_ALLSTART && !match)) {
        /* shortcircuit; result is known. Stop here */
        result = match;
        goto leave_with_result;
    }

    if(UNLIKELY(PL_stack_base + *PL_markstack_ptr > PL_stack_sp)) {
        /* Ran out of items */
        result = (op_type == OP_ANYSTART) ? false : true;

leave_with_result:
        LEAVE_with_name("grep");
        (void)POPMARK;				/* pop src */
        --*PL_markstack_ptr;
        (void)POPMARK;				/* pop dst */
        SV **base = PL_stack_base + POPMARK;	/* pop original mark */

        rpp_popfree_to_NN(base);
        rpp_push_IMM(result ? &PL_sv_yes : &PL_sv_no);

        return NORMAL;
    }

    ENTER_with_name("grep_item");
    SAVEVPTR(PL_curpm);

    SV *src = PL_stack_base[TOPMARK];
    if (SvPADTMP(src)) {
        SV *newsrc = sv_mortalcopy(src);
        PL_stack_base[TOPMARK] = newsrc;
#ifdef PERL_RC_STACK
        SvREFCNT_inc_simple_void_NN(newsrc);
        SvREFCNT_dec(src);
#endif
        src = newsrc;
        PL_tmps_floor++;
    }
    SvTEMP_off(src);
    DEFSV_set(src);

    return cLOGOP->op_other;
}

/* Range stuff. */

PP(pp_range)
{
    dTARG;
    if (GIMME_V == G_LIST)
        return NORMAL;
    GETTARGET;
    if (SvTRUE_NN(targ))
        return cLOGOP->op_other;
    else
        return NORMAL;
}


PP_wrapped(pp_flip,((GIMME_V == G_LIST) ? 0 : 1), 0)
{
    dSP;

    if (GIMME_V == G_LIST) {
        RETURNOP(cLOGOPx(cUNOP->op_first)->op_other);
    }
    else {
        dTOPss;
        SV * const targ = PAD_SV(PL_op->op_targ);
        int flip = 0;

        if (PL_op->op_private & OPpFLIP_LINENUM) {
            if (GvIO(PL_last_in_gv)) {
                flip = SvIV(sv) == (IV)IoLINES(GvIOp(PL_last_in_gv));
            }
            else {
                GV * const gv = gv_fetchpvs(".", GV_ADD|GV_NOTQUAL, SVt_PV);
                if (gv && GvSV(gv))
                    flip = SvIV(sv) == SvIV(GvSV(gv));
            }
        } else {
            flip = SvTRUE_NN(sv);
        }
        if (flip) {
            sv_setiv(PAD_SV(cUNOP->op_first->op_targ), 1);
            if (PL_op->op_flags & OPf_SPECIAL) {
                sv_setiv(targ, 1);
                SETs(targ);
                RETURN;
            }
            else {
                sv_setiv(targ, 0);
                SP--;
                RETURNOP(cLOGOPx(cUNOP->op_first)->op_other);
            }
        }
        SvPVCLEAR(TARG);
        SETs(targ);
        RETURN;
    }
}


/* This code tries to decide if "$left .. $right" should use the
   magical string increment, or if the range is numeric. Initially,
   an exception was made for *any* string beginning with "0" (see
   [#18165], AMS 20021031), but now that is only applied when the
   string's length is also >1 - see the rules now documented in
   perlop [#133695] */

#define RANGE_IS_NUMERIC(left,right) ( \
        SvNIOKp(left)  || (SvOK(left)  && !SvPOKp(left))  || \
        SvNIOKp(right) || (SvOK(right) && !SvPOKp(right)) || \
        (((!SvOK(left) && SvOK(right)) || ((!SvOK(left) || \
          looks_like_number(left)) && SvPOKp(left) \
          && !(*SvPVX_const(left) == '0' && SvCUR(left)>1 ) )) \
         && (!SvOK(right) || looks_like_number(right))))


PP_wrapped(pp_flop, (GIMME_V == G_LIST) ? 2 : 1, 0)
{
    dSP;

    if (GIMME_V == G_LIST) {
        dPOPPOPssrl;

        SvGETMAGIC(left);
        SvGETMAGIC(right);

        if (RANGE_IS_NUMERIC(left,right)) {
            IV i, j, n;
            if ((SvOK(left) && !SvIOK(left) && SvNV_nomg(left) < IV_MIN) ||
                (SvOK(right) && (SvIOK(right)
                                 ? SvIsUV(right) && SvUV(right) > IV_MAX
                                 : SvNV_nomg(right) > (NV) IV_MAX)))
                DIE(aTHX_ "Range iterator outside integer range");
            i = SvIV_nomg(left);
            j = SvIV_nomg(right);
            if (j >= i) {
                /* Dance carefully around signed max. */
                bool overflow = (i <= 0 && j > SSize_t_MAX + i - 1);
                if (!overflow) {
                    n = j - i + 1;
                    /* The wraparound of signed integers is undefined
                     * behavior, but here we aim for count >=1, and
                     * negative count is just wrong. */
                    if (n < 1
#if IVSIZE > Size_t_size
                        || n > SSize_t_MAX
#endif
                        )
                        overflow = TRUE;
                }
                if (overflow)
                    croak("Out of memory during list extend");
                EXTEND_MORTAL(n);
                EXTEND(SP, n);
            }
            else
                n = 0;
            while (n--) {
                SV * const sv = sv_2mortal(newSViv(i));
                PUSHs(sv);
                if (n) /* avoid incrementing above IV_MAX */
                    i++;
            }
        }
        else {
            STRLEN len, llen;
            const char * const lpv = SvPV_nomg_const(left, llen);
            const char * const tmps = SvPV_nomg_const(right, len);

            SV *sv = newSVpvn_flags(lpv, llen, SvUTF8(left)|SVs_TEMP);
            if (DO_UTF8(right) && IN_UNI_8_BIT)
                len = sv_len_utf8_nomg(right);
            while (!SvNIOKp(sv) && SvCUR(sv) <= len) {
                XPUSHs(sv);
                if (strEQ(SvPVX_const(sv),tmps))
                    break;
                sv = sv_mortalcopy_flags(sv, SV_GMAGIC|SV_NOSTEAL);
                sv_inc(sv);
            }
        }
    }
    else {
        dTOPss;
        SV * const targ = PAD_SV(cUNOP->op_first->op_targ);
        int flop = 0;
        sv_inc(targ);

        if (PL_op->op_private & OPpFLIP_LINENUM) {
            if (GvIO(PL_last_in_gv)) {
                flop = SvIV(sv) == (IV)IoLINES(GvIOp(PL_last_in_gv));
            }
            else {
                GV * const gv = gv_fetchpvs(".", GV_ADD|GV_NOTQUAL, SVt_PV);
                if (gv && GvSV(gv)) flop = SvIV(sv) == SvIV(GvSV(gv));
            }
        }
        else {
            flop = SvTRUE_NN(sv);
        }

        if (flop) {
            sv_setiv(PAD_SV(cUNOPx(cUNOP->op_first)->op_first->op_targ), 0);
            sv_catpvs(targ, "E0");
        }
        SETs(targ);
    }

    RETURN;
}


/* Control. */

static const char * const context_name[] = {
    "pseudo-block",
    NULL, /* CXt_WHEN never actually needs "block" */
    NULL, /* CXt_BLOCK never actually needs "block" */
    NULL, /* CXt_GIVEN never actually needs "block" */
    NULL, /* CXt_LOOP_PLAIN never actually needs "loop" */
    NULL, /* CXt_LOOP_LAZYIV never actually needs "loop" */
    NULL, /* CXt_LOOP_LAZYSV never actually needs "loop" */
    NULL, /* CXt_LOOP_LIST never actually needs "loop" */
    NULL, /* CXt_LOOP_ARY never actually needs "loop" */
    "subroutine",
    "format",
    "eval",
    "substitution",
    "defer block",
    "case",
    "dispatch-on clause",
};

static I32
S_dopoptolabel(pTHX_ const char *label, STRLEN len, U32 flags)
{
    PERL_ARGS_ASSERT_DOPOPTOLABEL;

    I32 i;

    for (i = cxstack_ix; i >= 0; i--) {
        const PERL_CONTEXT * const cx = &cxstack[i];
        switch (CxTYPE(cx)) {
        case CXt_EVAL:
            if(CxTRY(cx))
                continue;
            /* FALLTHROUGH */
        case CXt_SUBST:
        case CXt_SUB:
        case CXt_FORMAT:
        case CXt_NULL:
            /* diag_listed_as: Exiting subroutine via %s */
            ck_warner(packWARN(WARN_EXITING), "Exiting %s via %s",
                      context_name[CxTYPE(cx)], OP_NAME(PL_op));
            if (CxTYPE(cx) == CXt_NULL) /* sort BLOCK */
                return -1;
            break;
        case CXt_LOOP_PLAIN:
        case CXt_LOOP_LAZYIV:
        case CXt_LOOP_LAZYSV:
        case CXt_LOOP_LIST:
        case CXt_LOOP_ARY:
        case CXt_DISPATCH:
          {
            STRLEN cx_label_len = 0;
            U32 cx_label_flags = 0;
            const char *cx_label = CxLABEL_len_flags(cx, &cx_label_len, &cx_label_flags);
            if (!cx_label || !(
                    ( (cx_label_flags & SVf_UTF8) != (flags & SVf_UTF8) ) ?
                        (flags & SVf_UTF8)
                            ? (bytes_cmp_utf8(
                                        (const U8*)cx_label, cx_label_len,
                                        (const U8*)label, len) == 0)
                            : (bytes_cmp_utf8(
                                        (const U8*)label, len,
                                        (const U8*)cx_label, cx_label_len) == 0)
                    : (len == cx_label_len && ((cx_label == label)
                                    || memEQ(cx_label, label, len))) )) {
                DEBUG_l(deb("(poptolabel(): skipping label at cx=%ld %s)\n",
                            (long)i, cx_label));
                continue;
            }
            DEBUG_l( deb("(poptolabel(): found label at cx=%ld %s)\n",
                         (long)i, label));
            return i;
          }
        }
    }
    return i;
}

/*
=for apidoc_section $callback
=for apidoc dowantarray

Implements the deprecated L<perlapi/C<GIMME>>.

=cut

Deprecated since 5.38

*/

U8
Perl_dowantarray(pTHX)
{
    PERL_ARGS_ASSERT_DOWANTARRAY;

    const U8 gimme = block_gimme();
    return (gimme == G_VOID) ? G_SCALAR : gimme;
}

/* note that this function has mostly been superseded by Perl_gimme_V */

U8
Perl_block_gimme(pTHX)
{
    PERL_ARGS_ASSERT_BLOCK_GIMME;

    const I32 cxix = dopopto_cursub();
    U8 gimme;
    if (cxix < 0)
        return G_VOID;

    gimme = (cxstack[cxix].blk_gimme & G_WANT);
    if (!gimme)
        croak("panic: bad gimme: %d\n", gimme);
    return gimme;
}

/*
=for apidoc is_lvalue_sub

Returns non-zero if the sub calling this function is being called in an lvalue
context.  Returns 0 otherwise.

=cut
*/

I32
Perl_is_lvalue_sub(pTHX)
{
    PERL_ARGS_ASSERT_IS_LVALUE_SUB;

    const I32 cxix = dopopto_cursub();
    assert(cxix >= 0);  /* We should only be called from inside subs */

    if (CxLVAL(cxstack + cxix) && CvLVALUE(cxstack[cxix].blk_sub.cv))
        return CxLVAL(cxstack + cxix);
    else
        return 0;
}

/* only used by cx_pushsub() */
I32
Perl_was_lvalue_sub(pTHX)
{
    PERL_ARGS_ASSERT_WAS_LVALUE_SUB;

    const I32 cxix = dopoptosub(cxstack_ix-1);
    assert(cxix >= 0);  /* We should only be called from inside subs */

    if (CxLVAL(cxstack + cxix) && CvLVALUE(cxstack[cxix].blk_sub.cv))
        return CxLVAL(cxstack + cxix);
    else
        return 0;
}

static I32
S_dopoptosub_at(pTHX_ const PERL_CONTEXT *cxstk, I32 startingblock)
{
    PERL_ARGS_ASSERT_DOPOPTOSUB_AT;

    I32 i;

    for (i = startingblock; i >= 0; i--) {
        const PERL_CONTEXT * const cx = &cxstk[i];
        switch (CxTYPE(cx)) {
        default:
            continue;
        case CXt_SUB:
            /* in sub foo { /(?{...})/ }, foo ends up on the CX stack
             * twice; the first for the normal foo() call, and the second
             * for a faked up re-entry into the sub to execute the
             * code block. Hide this faked entry from the world. */
            if (cx->cx_type & CXp_SUB_RE_FAKE)
                continue;
            DEBUG_l( deb("(dopoptosub_at(): found sub at cx=%ld)\n", (long)i));
            return i;

        case CXt_EVAL:
            if (CxTRY(cx))
                continue;
            DEBUG_l( deb("(dopoptosub_at(): found sub at cx=%ld)\n", (long)i));
            return i;

        case CXt_FORMAT:
            DEBUG_l( deb("(dopoptosub_at(): found sub at cx=%ld)\n", (long)i));
            return i;
        }
    }
    return i;
}

static I32
S_dopoptoeval(pTHX_ I32 startingblock)
{
    PERL_ARGS_ASSERT_DOPOPTOEVAL;

    I32 i;
    for (i = startingblock; i >= 0; i--) {
        const PERL_CONTEXT *cx = &cxstack[i];
        switch (CxTYPE(cx)) {
        default:
            continue;
        case CXt_EVAL:
            DEBUG_l( deb("(dopoptoeval(): found eval at cx=%ld)\n", (long)i));
            return i;
        }
    }
    return i;
}

static I32
S_dopoptoloop(pTHX_ I32 startingblock)
{
    PERL_ARGS_ASSERT_DOPOPTOLOOP;

    I32 i;
    for (i = startingblock; i >= 0; i--) {
        const PERL_CONTEXT * const cx = &cxstack[i];
        switch (CxTYPE(cx)) {
        case CXt_EVAL:
            if(CxTRY(cx))
                continue;
            /* FALLTHROUGH */
        case CXt_SUBST:
        case CXt_SUB:
        case CXt_FORMAT:
        case CXt_NULL:
            /* diag_listed_as: Exiting subroutine via %s */
            ck_warner(packWARN(WARN_EXITING), "Exiting %s via %s",
                      context_name[CxTYPE(cx)], OP_NAME(PL_op));
            if ((CxTYPE(cx)) == CXt_NULL) /* sort BLOCK */
                return -1;
            break;
        case CXt_LOOP_PLAIN:
        case CXt_LOOP_LAZYIV:
        case CXt_LOOP_LAZYSV:
        case CXt_LOOP_LIST:
        case CXt_LOOP_ARY:
            DEBUG_l( deb("(dopoptoloop(): found loop at cx=%ld)\n", (long)i));
            return i;
        case CXt_DISPATCH:
            DEBUG_l( deb("(dopoptoloop(): found case at cx=%ld)\n", (long)i));
            return i;
        }
    }
    return i;
}

/* find the next GIVEN or FOR (with implicit $_) loop context block */

static I32
S_dopoptogivenfor(pTHX_ I32 startingblock)
{
    PERL_ARGS_ASSERT_DOPOPTOGIVENFOR;

    I32 i;
    for (i = startingblock; i >= 0; i--) {
        const PERL_CONTEXT *cx = &cxstack[i];
        switch (CxTYPE(cx)) {
        default:
            continue;
        case CXt_GIVEN:
            DEBUG_l( deb("(dopoptogivenfor(): found given at cx=%ld)\n",
                         (long)i));
            return i;
        case CXt_DISPATCH:
            DEBUG_l( deb("(dopoptogivenfor(): found case at cx=%ld)\n",
                         (long)i));
            return i;
        case CXt_LOOP_PLAIN:
            assert(!(cx->cx_type & CXp_FOR_DEF));
            break;
        case CXt_LOOP_LAZYIV:
        case CXt_LOOP_LAZYSV:
        case CXt_LOOP_LIST:
        case CXt_LOOP_ARY:
            if (cx->cx_type & CXp_FOR_DEF) {
                DEBUG_l( deb("(dopoptogivenfor(): found foreach at cx=%ld)\n",
                         (long)i));
                return i;
            }
        }
    }
    return i;
}

static I32
S_dopoptowhen(pTHX_ I32 startingblock)
{
    PERL_ARGS_ASSERT_DOPOPTOWHEN;

    I32 i;
    for (i = startingblock; i >= 0; i--) {
        const PERL_CONTEXT *cx = &cxstack[i];
        switch (CxTYPE(cx)) {
        default:
            continue;
        case CXt_WHEN:
            DEBUG_l( deb("(dopoptowhen(): found when at cx=%ld)\n", (long)i));
            return i;
        }
    }
    return i;
}

/* dounwind(): pop all contexts above (but not including) cxix.
 * Note that it clears the savestack frame associated with each popped
 * context entry, but doesn't free any temps.
 * It does a cx_popblock() of the last frame that it pops, and leaves
 * cxstack_ix equal to cxix.
 */

void
Perl_dounwind(pTHX_ I32 cxix)
{
    PERL_ARGS_ASSERT_DOUNWIND;

    if (!PL_curstackinfo) /* can happen if die during thread cloning */
        return;

    while (cxstack_ix > cxix) {
        PERL_CONTEXT *cx = CX_CUR();

        CX_DEBUG(cx, "UNWIND");
        /* Note: we don't need to restore the base context info till the end. */

        CX_LEAVE_SCOPE(cx);

        switch (CxTYPE(cx)) {
        case CXt_SUBST:
            CX_POPSUBST(cx);
            /* CXt_SUBST is not a block context type, so skip the
             * cx_popblock(cx) below */
            if (cxstack_ix == cxix + 1) {
                cxstack_ix--;
                return;
            }
            break;
        case CXt_SUB:
            cx_popsub(cx);
            break;
        case CXt_EVAL:
            cx_popeval(cx);
            break;
        case CXt_LOOP_PLAIN:
        case CXt_LOOP_LAZYIV:
        case CXt_LOOP_LAZYSV:
        case CXt_LOOP_LIST:
        case CXt_LOOP_ARY:
            cx_poploop(cx);
            break;
        case CXt_WHEN:
            cx_popwhen(cx);
            break;
        case CXt_GIVEN:
            cx_popgiven(cx);
            break;
        case CXt_DISPATCH:
            cx_popdispatch(cx);
            break;
        case CXt_DISPATCH_ON:
            cx_popdispatchon(cx);
            break;
        case CXt_BLOCK:
        case CXt_NULL:
        case CXt_DEFER:
            /* these two don't have a POPFOO() */
            break;
        case CXt_FORMAT:
            cx_popformat(cx);
            break;
        }
        if (cxstack_ix == cxix + 1) {
            cx_popblock(cx);
        }
        cxstack_ix--;
    }

}


/* Like rpp_popfree_to(), but takes an offset rather than a pointer,
 * and frees everything above ix appropriately, *regardless* of the
 * refcountedness of the stack. If necessary it removes any split stack.
 * Intended for use during exit() and die() and similar.
*/
void
Perl_rpp_obliterate_stack_to(pTHX_ I32 ix)
{
    PERL_ARGS_ASSERT_RPP_OBLITERATE_STACK_TO;

#ifdef PERL_RC_STACK
    I32 nonrc_base = PL_curstackinfo->si_stack_nonrc_base;
    assert(ix >= 0);
    assert(ix <= PL_stack_sp - PL_stack_base);
    assert(nonrc_base <= PL_stack_sp - PL_stack_base + 1);

    if (nonrc_base && nonrc_base > ix) {
        /* abandon any non-refcounted stuff */
        PL_stack_sp = PL_stack_base + nonrc_base - 1;
        /* and mark the stack as fully refcounted again */
        PL_curstackinfo->si_stack_nonrc_base = 0;
    }

    if (rpp_stack_is_rc())
        rpp_popfree_to(PL_stack_base + ix);
    else
        PL_stack_sp = PL_stack_base + ix;
#else
    PL_stack_sp = PL_stack_base + ix;
#endif

}

/*
=for apidoc defer_error

Called to report compilation errors, doing one of:

=over

=item *

adding C<err> to C<$@> within an C<eval EXPR>,

=item *

appending C<err> to C<PL_errors>, to be reported when the next
exception is thrown, or

=item *

by warning, if called early in interpreter construction or late in
interpreter destruction, when PL_errors isn't available.

=back

and incrementing the parser error count if we're parsing.

This function may throw an exception if too many errors have been
produced.

This is intended for use during compilation.

=cut
*/

void
Perl_defer_error(pTHX_ SV *err)
{
    PERL_ARGS_ASSERT_DEFER_ERROR;
    if (err!=NULL) {
        if (PL_in_eval) {
            if (PL_in_eval & EVAL_KEEPERR) {
                    ck_warner(packWARN(WARN_MISC), "\t(in cleanup) %" SVf,
                              SVfARG(err));
            }
            else {
                sv_catsv(ERRSV, err);
            }
        }
        else if (PL_errors)
            sv_catsv(PL_errors, err);
        else
            warn("%" SVf, SVfARG(err));

        if (PL_parser) {
            ++PL_parser->error_count;
        }
    }

    if ( PL_parser && (err == NULL ||
         PL_parser->error_count >= PERL_STOP_PARSING_AFTER_N_ERRORS)
    ) {
        const char * const name = OutCopFILE(PL_curcop);
        SV * errsv = NULL;
        U8 raw_error_count = PERL_PARSE_ERROR_COUNT(PL_parser->error_count);

        if (PL_in_eval) {
            errsv = ERRSV;
        }

        if (err == NULL) {
            abort_execution(errsv, name);
        }
        else
        if (raw_error_count >= PERL_STOP_PARSING_AFTER_N_ERRORS) {
            if (errsv) {
                croak("%" SVf "%s has too many errors.\n",
                    SVfARG(errsv), name);
            } else {
                croak("%s has too many errors.\n", name);
            }
        }
    }
}


/* pop a CXt_EVAL context and in addition, if it was a require then
 * based on action:
 *     0: do nothing extra;
 *     1: undef  $INC{$name}; croak "$name did not return a true value";
 *     2: delete $INC{$name}; croak "$errsv: Compilation failed in require"
 */

static void
S_pop_eval_context_maybe_croak(pTHX_ PERL_CONTEXT *cx, SV *errsv, int action)
{
    SV  *namesv = NULL; /* init to avoid dumb compiler warning */
    bool do_croak;

    CX_LEAVE_SCOPE(cx);
    do_croak = action && (CxOLD_OP_TYPE(cx) == OP_REQUIRE);
    if (do_croak) {
        /* keep namesv alive after cx_popeval() */
        namesv = cx->blk_eval.old_namesv;
        cx->blk_eval.old_namesv = NULL;
        sv_2mortal(namesv);
    }
    cx_popeval(cx);
    cx_popblock(cx);
    CX_POP(cx);

    if (do_croak) {
        const char *fmt;
        HV *inc_hv = GvHVn(PL_incgv);

        if (action == 1) {
            (void)hv_delete_ent(inc_hv, namesv, G_DISCARD, 0);
            fmt = "%" SVf " did not return a true value";
            errsv = namesv;
        }
        else {
            (void)hv_store_ent(inc_hv, namesv, &PL_sv_undef, 0);
            fmt = "%" SVf "Compilation failed in require";
            if (!errsv)
                errsv = newSVpvs_flags("Unknown error\n", SVs_TEMP);
        }

        croak(fmt, SVfARG(errsv));
    }
}


/* die_unwind(): this is the final destination for the various croak()
 * functions. If we're in an eval, unwind the context and other stacks
 * back to the top-most CXt_EVAL and set $@ to msv; otherwise print msv
 * to STDERR and initiate an exit. Note that if the CXt_EVAL popped back
 * to is a require the exception will be rethrown, as requires don't
 * actually trap exceptions.
 */

void
Perl_die_unwind(pTHX_ SV *msv)
{
    PERL_ARGS_ASSERT_DIE_UNWIND;

    SV *exceptsv = msv;
    U8 in_eval = PL_in_eval;

    if (in_eval) {
        I32 cxix;

        /* We need to keep this SV alive through all the stack unwinding
         * and FREETMPSing below, while ensuing that it doesn't leak
         * if we call out to something which then dies (e.g. sub STORE{die}
         * when unlocalising a tied var). So we do a dance with
         * mortalising and SAVEFREEing.
         */
        if (PL_phase == PERL_PHASE_DESTRUCT) {
            exceptsv = sv_mortalcopy(exceptsv);
        } else {
            exceptsv = sv_2mortal(SvREFCNT_inc_simple_NN(exceptsv));
        }

        /*
         * Historically, perl used to set ERRSV ($@) early in the die
         * process and rely on it not getting clobbered during unwinding.
         * That sucked, because it was liable to get clobbered, so the
         * setting of ERRSV used to emit the exception from eval{} has
         * been moved to much later, after unwinding (see just before
         * JMPENV_JUMP below).	However, some modules were relying on the
         * early setting, by examining $@ during unwinding to use it as
         * a flag indicating whether the current unwinding was caused by
         * an exception.  It was never a reliable flag for that purpose,
         * being totally open to false positives even without actual
         * clobberage, but was useful enough for production code to
         * semantically rely on it.
         *
         * We'd like to have a proper introspective interface that
         * explicitly describes the reason for whatever unwinding
         * operations are currently in progress, so that those modules
         * work reliably and $@ isn't further overloaded.  But we don't
         * have one yet.  In its absence, as a stopgap measure, ERRSV is
         * now *additionally* set here, before unwinding, to serve as the
         * (unreliable) flag that it used to.
         *
         * This behaviour is temporary, and should be removed when a
         * proper way to detect exceptional unwinding has been developed.
         * As of 2010-12, the authors of modules relying on the hack
         * are aware of the issue, because the modules failed on
         * perls 5.13.{1..7} which had late setting of $@ without this
         * early-setting hack.
         */
        if (!(in_eval & EVAL_KEEPERR)) {
            /* remove any read-only/magic from the SV, so we don't
               get infinite recursion when setting ERRSV */
            SANE_ERRSV();
            sv_setsv_flags(ERRSV, exceptsv,
                        (SV_GMAGIC|SV_DO_COW_SVSETSV|SV_NOSTEAL));
        }

        if (in_eval & EVAL_KEEPERR) {
            ck_warner(packWARN(WARN_MISC), "\t(in cleanup) %" SVf,
                      SVfARG(exceptsv));
        }

        while ((cxix = dopoptoeval(cxstack_ix)) < 0
               && PL_curstackinfo->si_prev)
        {
            dounwind(-1);
            rpp_obliterate_stack_to(0);
            POPSTACK;
        }

        if (cxix >= 0) {
            PERL_CONTEXT *cx;
            U8 gimme;
            JMPENV *restartjmpenv;
            OP *restartop;

            if (cxix < cxstack_ix)
                dounwind(cxix);

            cx = CX_CUR();
            assert(CxTYPE(cx) == CXt_EVAL);

            rpp_obliterate_stack_to(cx->blk_oldsp);

            /* return false to the caller of eval */
            gimme = cx->blk_gimme;
            if (gimme == G_SCALAR)
                rpp_xpush_IMM(&PL_sv_undef);

            restartjmpenv = cx->blk_eval.cur_top_env;
            restartop     = cx->blk_eval.retop;

            /* We need a FREETMPS here to avoid late-called destructors
             * clobbering $@ *after* we set it below, e.g.
             *    sub DESTROY { eval { die "X" } }
             *    eval { my $x = bless []; die $x = 0, "Y" };
             *    is($@, "Y")
             * Here the clearing of the $x ref mortalises the anon array,
             * which needs to be freed *before* $& is set to "Y",
             * otherwise it gets overwritten with "X".
             *
             * However, the FREETMPS will clobber exceptsv, so preserve it
             * on the savestack for now.
             */
            SAVEFREESV(SvREFCNT_inc_simple_NN(exceptsv));
            FREETMPS;
            /* now we're about to pop the savestack, so re-mortalise it */
            sv_2mortal(SvREFCNT_inc_simple_NN(exceptsv));

            /* Note that unlike pp_entereval, pp_require isn't supposed to
             * trap errors. So if we're a require, after we pop the
             * CXt_EVAL that pp_require pushed, rethrow the error with
             * croak(exceptsv). This is all handled by the call below when
             * action == 2.
             */
            S_pop_eval_context_maybe_croak(aTHX_ cx, exceptsv, 2);

            if (!(in_eval & EVAL_KEEPERR)) {
                SANE_ERRSV();
                sv_setsv(ERRSV, exceptsv);
            }
            PL_restartjmpenv = restartjmpenv;
            PL_restartop = restartop;
            JMPENV_JUMP(3);
            NOT_REACHED; /* NOTREACHED */
        }
    }

    write_to_stderr(exceptsv);
    my_failure_exit();
    NOT_REACHED; /* NOTREACHED */
}


PP(pp_xor)
{
    SV *left  = PL_stack_sp[-1];
    SV *right = PL_stack_sp[0];
    bool ret = SvTRUE_NN(left) != SvTRUE_NN(right);
    if (PL_op->op_flags & OPf_STACKED) {
        sv_setbool(left, ret);
        rpp_replace_2_1(left);
    }
    else {
        rpp_replace_2_IMM_NN(boolSV(ret));
    }
    return NORMAL;
}


/*

=for apidoc_section $CV

=for apidoc caller_cx

The XSUB-writer's equivalent of L<caller()|perlfunc/caller>.  The
returned C<PERL_CONTEXT> structure can be interrogated to find all the
information returned to Perl by C<caller>.  Note that XSUBs don't get a
stack frame, so C<caller_cx(0, NULL)> will return information for the
immediately-surrounding Perl code.

This function skips over the automatic calls to C<&DB::sub> made on the
behalf of the debugger.  If the stack frame requested was a sub called by
C<DB::sub>, the return value will be the frame for the call to
C<DB::sub>, since that has the correct line number/etc. for the call
site.  If I<dbcxp> is non-C<NULL>, it will be set to a pointer to the
frame for the sub call itself.

=cut
*/

const PERL_CONTEXT *
Perl_caller_cx(pTHX_ I32 count, const PERL_CONTEXT **dbcxp)
{
    PERL_ARGS_ASSERT_CALLER_CX;

    I32 cxix = dopopto_cursub();
    const PERL_CONTEXT *cx;
    const PERL_CONTEXT *ccstack = cxstack;
    const PERL_SI *top_si = PL_curstackinfo;

    for (;;) {
        /* we may be in a higher stacklevel, so dig down deeper */
        while (cxix < 0 && top_si->si_type != PERLSI_MAIN) {
            top_si = top_si->si_prev;
            ccstack = top_si->si_cxstack;
            cxix = dopoptosub_at(ccstack, top_si->si_cxix);
        }
        if (cxix < 0)
            return NULL;
        /* caller() should not report the automatic calls to &DB::sub */
        if (PL_DBsub && GvCV(PL_DBsub) && cxix >= 0 &&
                ccstack[cxix].blk_sub.cv == GvCV(PL_DBsub))
            count++;
        if (!count--)
            break;
        cxix = dopoptosub_at(ccstack, cxix - 1);
    }

    cx = &ccstack[cxix];
    if (dbcxp) *dbcxp = cx;

    if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
        const I32 dbcxix = dopoptosub_at(ccstack, cxix - 1);
        /* We expect that ccstack[dbcxix] is CXt_SUB, anyway, the
           field below is defined for any cx. */
        /* caller() should not report the automatic calls to &DB::sub */
        if (PL_DBsub && GvCV(PL_DBsub) && dbcxix >= 0 && ccstack[dbcxix].blk_sub.cv == GvCV(PL_DBsub))
            cx = &ccstack[dbcxix];
    }

    return cx;
}

static void
S_caller_push_pkg(pTHX_ const HEK *stash_hek)
{
    if (!stash_hek)
        rpp_push_IMM(&PL_sv_undef);
    else {
        dTARGET;
        sv_sethek(TARG, stash_hek);
        rpp_push_1(TARG);
    }
}

static void
S_caller_push_line(pTHX_ const PERL_CONTEXT *cx)
{
    const COP *blk_old = cx->blk_oldcop;
    const COP *lcop = (CxTYPE(cx) == CXt_SUB)
        ? closest_cop(blk_old, OpSIBLING(blk_old), cx->blk_sub.callop, FALSE)
        : closest_cop(blk_old, OpSIBLING(blk_old), cx->blk_sub.retop, TRUE);
    if (!lcop)
        lcop = blk_old;
    rpp_push_1_norc( newSVuv( (UV)(CopLINE(lcop)) ) );
}

static void
S_caller_push_sub_hasargs(pTHX_ const PERL_CONTEXT *cx, const PERL_CONTEXT *dbcx, const bool want_hasargs)
{
    if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
        /* So is ccstack[dbcxix]. */
        if (CvHasNAME(dbcx->blk_sub.cv)) {
            rpp_push_1(cv_name(dbcx->blk_sub.cv, 0, 0));
            if (want_hasargs)
                rpp_push_IMM(boolSV(CxHASARGS(cx)));
        }
        else {
            rpp_push_1_norc( newSVpvs("(unknown)"));
            if (want_hasargs)
                rpp_push_IMM(boolSV(CxHASARGS(cx)));
        }
    }
    else {
        rpp_push_1_norc( newSVpvs("(eval)") );
        if (want_hasargs)
            rpp_push_IMM(&PL_sv_zero);
    }
}

static void
S_caller_push_bitmask(pTHX_ const PERL_CONTEXT *cx)
{
    SV * mask ;
    char *old_warnings = cx->blk_oldcop->cop_warnings;

    if  (old_warnings == pWARN_NONE)
        mask = newSVpvn(WARN_NONEstring, WARNsize) ;
    else if (old_warnings == pWARN_STD && (PL_dowarn & G_WARN_ON) == 0)
        mask = &PL_sv_undef ;
    else if (old_warnings == pWARN_ALL ||
              (old_warnings == pWARN_STD && PL_dowarn & G_WARN_ON)) {
        mask = newSVpvn(WARN_ALLstring, WARNsize) ;
    }
    else
        mask = newSVpvn(old_warnings, RCPV_LEN(old_warnings));
    rpp_push_1_norc(mask);
}

static void
S_caller_push_cop_hints_hash(pTHX_ const PERL_CONTEXT *cx)
{
    if (cx->blk_oldcop->cop_hints_hash) {
        rpp_push_1_norc( newRV_noinc(MUTABLE_SV(cop_hints_2hv(cx->blk_oldcop, 0))) );
    } else {
        rpp_push_IMM(&PL_sv_undef);
    }
}

PP(pp_caller)
{
    const PERL_CONTEXT *cx;
    const PERL_CONTEXT *dbcx;
    U8 gimme = GIMME_V;
    const HEK *stash_hek;
    bool has_arg = false;
    I32 count = cBOOL(PL_op->op_private & OPpOFFBYONE);

    if (PL_op->op_flags & OPf_KIDS) {
        if (PL_stack_sp[0]) {
            has_arg = true;
            count += SvIV(PL_stack_sp[0]);
        }
        rpp_popfree_1();
    }

    /* pp_caller traditionally had separate EXTEND(SP, 1) checks where
     * that was all that was needed, with this larger check occuring later.
     * However, when an application reaches a steady stack size - and often
     * prior to that, the stack will already have space to accomodate 11
     * more pointers. For example, during a perl build and run of the test
     * harness, gcov showed that pp_caller never had to extend the stack.
     * Consolidating the EXTENDs was found to shrink pp_caller by 46
     * instructions on a non-DEBUGGING, non-threaded gcc build.
     * Additionally, optimization of the caller-lslice pattern can now
     * cause pp_caller a varying assortment of SV*s to the stack, so an
     * early catch-all check is definitely preferable.*/
    rpp_extend(11);

    cx = caller_cx(count, &dbcx);
    if (!cx) {
        if (gimme != G_LIST) {
            rpp_push_IMM(&PL_sv_undef);
        }
        return NORMAL;
    }

    /* populate @DB::args ? */
    if (CxTYPE(cx) == CXt_SUB && CxHASARGS(cx)
        && CopSTASH_eq(PL_curcop, PL_debstash))
    {
        /* slot 0 of the pad contains the original @_ */
        AV * const ary = MUTABLE_AV(AvARRAY(MUTABLE_AV(
                            PadlistARRAY(CvPADLIST(cx->blk_sub.cv))[
                                cx->blk_sub.olddepth+1]))[0]);
        const SSize_t off = AvARRAY(ary) - AvALLOC(ary);

        Perl_init_dbargs(aTHX);

        if (AvMAX(PL_dbargs) < AvFILLp(ary) + off)
            av_extend(PL_dbargs, AvFILLp(ary) + off);

        /* Alias elements of @_ to @DB::args */
        for (SSize_t i = AvFILLp(ary) + off; i >= 0; i--) {
            SV* sv = AvALLOC(ary)[i];
            /* for a shifted @_, the elements between AvALLOC and AvARRAY
             * point to old SVs which may have been freed or even
             * reallocated in the meantime. In the interests of
             * reconstructing the original @_ before any shifting, use
             * those old values, even at the risk of them being wrong.
             * But if the ref count is 0, then don't use it because
             * further assigning that value anywhere will panic.
             * Of course there's nothing to stop a RC != 0 SV being
             * subsequently freed, but hopefully people quickly copy the
             * contents of @DB::args before doing anything else.
             */
            if (sv && (SvREFCNT(sv) == 0 || SvIS_FREED(sv)))
                sv = NULL;
            AvARRAY(PL_dbargs)[i] = sv;
        }
        AvFILLp(PL_dbargs) = AvFILLp(ary) + off;
    }

    CX_DEBUG(cx, "CALLER");
    assert(CopSTASH(cx->blk_oldcop));
    stash_hek = SvTYPE(CopSTASH(cx->blk_oldcop)) == SVt_PVHV
      ? HvNAME_HEK((HV*)CopSTASH(cx->blk_oldcop))
      : NULL;

    if (UNLIKELY(gimme == G_VOID))
        return NORMAL;

    /* Non-zero subscripts means that a caller->lslice optree has been
     * optimized away. Only the indicated subscripts must be returned. */
    U8 subscripts = PL_op->op_private &~ OPpOFFBYONE;

    if (gimme == G_SCALAR) {
        if(!subscripts)
            S_caller_push_pkg(aTHX_ stash_hek);
        else {
            /* Perl_scalarvoid might have toggled off superfluous bits
             * at compile time, but just in case execution is somewhere
             * where context is determined at runtime...*/
            U32 msb_subscript = 1 << msbit_pos32((U32)subscripts);

            switch(msb_subscript) {
                case OPpCALLER_PKG:
                    S_caller_push_pkg(aTHX_ stash_hek);
                    break;
                case OPpCALLER_FILE:
                    rpp_push_1_norc(newSVpv(OutCopFILE(cx->blk_oldcop), 0));
                    break;
                case OPpCALLER_LINE:
                    S_caller_push_line(aTHX_ cx);
                    break;
                case OPpCALLER_SUB:
                    if (!has_arg) {
                        rpp_push_IMM(&PL_sv_undef);
                    } else S_caller_push_sub_hasargs(aTHX_ cx, dbcx, false);
                    break;
                case OPpCALLER_HINTS:
                    if (!has_arg) {
                        rpp_push_IMM(&PL_sv_undef);
                    } else {
                        rpp_push_1_norc(newSViv( (IV)(CopHINTS_get(cx->blk_oldcop)) ));
                    }
                    break;
                case OPpCALLER_BITS:
                    if (!has_arg) {
                        rpp_push_IMM(&PL_sv_undef);
                    } else S_caller_push_bitmask(aTHX_ cx);
                    break;
                case OPpCALLER_HINTH:
                    if (!has_arg)
                        rpp_push_IMM(&PL_sv_undef);
                    else S_caller_push_cop_hints_hash(aTHX_ cx);
                    break;
                default:
                    NOT_REACHED;
            }
        }
        return NORMAL;
    }

    if (subscripts) {
        if (subscripts & OPpCALLER_PKG)
            S_caller_push_pkg(aTHX_ stash_hek);
        if (subscripts & OPpCALLER_FILE)
            rpp_push_1_norc(newSVpv(OutCopFILE(cx->blk_oldcop), 0));
        if (subscripts & OPpCALLER_LINE)
            S_caller_push_line(aTHX_ cx);

        if (!has_arg) {
            U32 f = (subscripts & (OPpCALLER_SUB|OPpCALLER_HINTS|OPpCALLER_BITS|OPpCALLER_HINTH));
            U32 cnt = bitcount32( f );

            while (cnt) {
                rpp_push_IMM(&PL_sv_undef);
                cnt--;
            }
        } else {
            if (subscripts & OPpCALLER_SUB)
                S_caller_push_sub_hasargs(aTHX_ cx, dbcx, false);
            if (subscripts & OPpCALLER_HINTS)
                rpp_push_1_norc(newSViv( (IV)(CopHINTS_get(cx->blk_oldcop)) ));
            if (subscripts & OPpCALLER_BITS)
                S_caller_push_bitmask(aTHX_ cx);
            if (subscripts & OPpCALLER_HINTH)
                S_caller_push_cop_hints_hash(aTHX_ cx);
        }
        return NORMAL;
    }

    /* No lslice optimization is in effect. This is straightforward
     * pp_caller from here onwards. */
    S_caller_push_pkg(aTHX_ stash_hek);

    rpp_push_1_norc(newSVpv(OutCopFILE(cx->blk_oldcop), 0));

    S_caller_push_line(aTHX_ cx);

    if (!has_arg)
        return NORMAL;

    S_caller_push_sub_hasargs(aTHX_ cx, dbcx, true);

    gimme = cx->blk_gimme;
    if (gimme == G_VOID)
        rpp_push_IMM(&PL_sv_undef);
    else
        rpp_push_IMM(boolSV((gimme & G_WANT) == G_LIST));
    if (CxTYPE(cx) == CXt_EVAL) {
        /* eval STRING */
        if (CxOLD_OP_TYPE(cx) == OP_ENTEREVAL) {
            SV *cur_text = cx->blk_eval.cur_text;
            if (SvCUR(cur_text) >= 2) {
                rpp_push_1_norc( newSVpvn_flags(SvPVX(cur_text), SvCUR(cur_text)-2,
                                     SvUTF8(cur_text)) );
            }
            else {
                /* I think this is will always be "", but be sure */
                rpp_push_1_norc(newSVsv_flags(cur_text, SV_GMAGIC|SV_NOSTEAL));
            }

            rpp_push_IMM(&PL_sv_no);
        }
        /* require */
        else if (cx->blk_eval.old_namesv) {
            rpp_push_1_norc(newSVsv(cx->blk_eval.old_namesv));
            rpp_push_IMM(&PL_sv_yes);
        }
        /* eval BLOCK (eval blocks have old_namesv == 0) */
        else {
            rpp_push_IMM(&PL_sv_undef);
            rpp_push_IMM(&PL_sv_undef);
        }
    }
    else {
        rpp_push_IMM(&PL_sv_undef);
        rpp_push_IMM(&PL_sv_undef);
    }

    rpp_push_1_norc(newSViv( (IV)(CopHINTS_get(cx->blk_oldcop)) ));

    S_caller_push_bitmask(aTHX_ cx);
    S_caller_push_cop_hints_hash(aTHX_ cx);

    return NORMAL;
}


PP_wrapped(pp_reset, MAXARG, 0)
{
    dSP;
    const char * tmps;
    STRLEN len = 0;
    if (MAXARG < 1 || (!TOPs && !POPs)) {
        EXTEND(SP, 1);
        tmps = NULL, len = 0;
    }
    else
        tmps = SvPVx_const(POPs, len);
    sv_resetpvn(tmps, len, CopSTASH(PL_curcop));
    PUSHs(&PL_sv_yes);
    RETURN;
}

/* like pp_nextstate, but used instead when the debugger is active */

PP(pp_dbstate)
{
    PL_curcop = (COP*)PL_op;
    TAINT_NOT;		/* Each statement is presumed innocent */
    rpp_popfree_to_NN(PL_stack_base + CX_CUR()->blk_oldsp);
    FREETMPS;

    PERL_ASYNC_CHECK();

    if (PL_op->op_flags & OPf_SPECIAL /* breakpoint */
            || PL_DBsingle_iv || PL_DBsignal_iv || PL_DBtrace_iv)
    {
        PERL_CONTEXT *cx;
        const U8 gimme = G_LIST;
        GV * const gv = PL_DBgv;
        CV * cv = NULL;

        if (gv && isGV_with_GP(gv))
            cv = GvCV(gv);

        if (!cv || (!CvROOT(cv) && !CvXSUB(cv)))
            DIE(aTHX_ "No DB::DB routine defined");

        if (CvDEPTH(cv) >= 1 && !(PL_debug & DEBUG_DB_RECURSE_FLAG))
            /* don't do recursive DB::DB call */
            return NORMAL;

        if (CvISXSUB(cv)) {
            ENTER;
            SAVEI32(PL_debug);
            PL_debug = 0;
            /* I suspect that saving the stack position is no longer
             * required. It was added in 5.001 by:
             * 
             *     NETaa13155: &DB::DB left trash on the stack.
             *     From: Thomas Koenig
             *     Files patched: lib/perl5db.pl pp_ctl.c
             *      The call by pp_dbstate() to &DB::DB left trash on the
             *      stack.  It now calls DB in list context, and DB returns
             *      ().
             *
             * but the details of what bug it fixed are long lost to
             * history.  SAVESTACK_POS() doesn't work well with stacks
             * which may be split into partly reference-counted and partly
             * not halves, so skip it and hope it doesn't cause any
             * problems.
             */
#ifndef PERL_RC_STACK
            SAVESTACK_POS();
#endif
            SAVETMPS;
            PUSHMARK(PL_stack_sp);
            rpp_invoke_xs(cv);
            FREETMPS;
            LEAVE;
            return NORMAL;
        }
        else {
#ifdef PERL_RC_STACK
            assert(!PL_curstackinfo->si_stack_nonrc_base);
#endif
            cx = cx_pushblock(CXt_SUB, gimme, PL_stack_sp, PL_savestack_ix);
            cx_pushsub(cx, cv, PL_op->op_next, 0);
            /* OP_DBSTATE's op_private holds hint bits rather than
             * the lvalue-ish flags seen in OP_ENTERSUB. So cancel
             * any CxLVAL() flags that have now been mis-calculated */
            cx->blk_u16 = 0;

            SAVEI32(PL_debug);
            PL_debug = 0;
            /* see comment above about SAVESTACK_POS */
#ifndef PERL_RC_STACK
            SAVESTACK_POS();
#endif
            CvDEPTH(cv)++;
            if (CvDEPTH(cv) >= 2)
                pad_push(CvPADLIST(cv), CvDEPTH(cv));
            PAD_SET_CUR_NOSAVE(CvPADLIST(cv), CvDEPTH(cv));
            return CvSTART(cv);
        }
    }
    else
        return NORMAL;
}


PP(pp_enter)
{
    U8 gimme = GIMME_V;

    (void)cx_pushblock(CXt_BLOCK, gimme, PL_stack_sp, PL_savestack_ix);
    return NORMAL;
}


PP(pp_leave)
{
    PERL_CONTEXT *cx;
    SV **oldsp;
    U8 gimme;

    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_BLOCK);

    if (PL_op->op_flags & OPf_SPECIAL)
        /* fake block should preserve $1 et al; e.g.  /(...)/ while ...; */
        cx->blk_oldpm = PL_curpm;

    oldsp = PL_stack_base + cx->blk_oldsp;
    gimme = cx->blk_gimme;

    if (gimme == G_VOID)
        rpp_popfree_to_NN(oldsp);
    else
        leave_adjust_stacks(oldsp, oldsp, gimme,
                                PL_op->op_private & OPpLVALUE ? 3 : 1);

    CX_LEAVE_SCOPE(cx);
    cx_popblock(cx);
    CX_POP(cx);

    return NORMAL;
}

static bool
S_outside_integer(pTHX_ SV *sv)
{
  if (SvOK(sv)) {
    const NV nv = SvNV_nomg(sv);
    if (Perl_isinfnan(nv))
      return TRUE;
#ifdef NV_PRESERVES_UV
    if (nv < (NV)IV_MIN || nv > (NV)IV_MAX)
      return TRUE;
#else
    if (nv <= (NV)IV_MIN)
      return TRUE;
    if ((nv > 0) &&
        ((nv > (NV)UV_MAX ||
          SvUV_nomg(sv) > (UV)IV_MAX)))
      return TRUE;
#endif
  }
  return FALSE;
}

PP(pp_enteriter)
{
    dMARK;
    PERL_CONTEXT *cx;
    const U8 gimme = GIMME_V;
    void *itervarp; /* GV or pad slot of the iteration variable */
    SV   *itersave; /* the old var in the iterator var slot */
    U8 cxflags = 0;
    U8 priv = PL_op->op_private;

    if (PL_op->op_targ) {			 /* "my" variable */
        itervarp = &PAD_SVl(PL_op->op_targ);
        itersave = *(SV**)itervarp;
        assert(itersave);
        if (priv & OPpLVAL_INTRO) {        /* for my $x (...) */
            /* the SV currently in the pad slot is never live during
             * iteration (the slot is always aliased to one of the items)
             * so it's always stale */
            SvPADSTALE_on(itersave);
        }
        SvREFCNT_inc_simple_void_NN(itersave);
        cxflags = CXp_FOR_PAD;
    }
    else {
        SV * const sv = *PL_stack_sp;
        itervarp = (void *)sv;
        if (LIKELY(isGV(sv))) {		/* symbol table variable */
            itersave = GvSV(sv);
            SvREFCNT_inc_simple_void(itersave);
            cxflags = CXp_FOR_GV;
            if (priv & OPpITER_DEF)
                cxflags |= CXp_FOR_DEF;
        }
        else {                          /* LV ref: for \$foo (...) */
            assert(SvTYPE(sv) == SVt_PVMG);
            itersave = NULL;
            MAGIC *mg = SvMAGIC(sv);
            assert(mg);
            assert(mg->mg_type == PERL_MAGIC_lvref);
            assert(mg->mg_obj);
            // LV ref around a package lexical, mg_obj gives its GV
            GV *gv = (GV *)mg->mg_obj;
            assert(SvTYPE(gv) == SVt_PVGV);
            switch(mg->mg_private & OPpLVREF_TYPE) {
                case OPpLVREF_SV: itersave =       GvSVn(gv); break;
                case OPpLVREF_AV: itersave = (SV *)GvAV(gv);  break;
                case OPpLVREF_HV: itersave = (SV *)GvHV(gv);  break;
                case OPpLVREF_CV: itersave = (SV *)GvCV(gv);  break;
            }
            SvREFCNT_inc_void(itersave);
            cxflags = CXp_FOR_LVREF;
        }
        /* we transfer ownership of 1 ref count of itervarp from the stack
         * to the CX entry, so no SvREFCNT_dec() needed */
        (void)rpp_pop_1_norc();
    }
    /* OPpITER_DEF (implicit $_) should only occur with a GV iter var */
    assert((cxflags & CXp_FOR_GV) || !(priv & OPpITER_DEF));

    /* Note that this context is initially set as CXt_NULL. Further on
     * down it's changed to one of the CXt_LOOP_*. Before it's changed,
     * there mustn't be anything in the blk_loop substruct that requires
     * freeing or undoing, in case we die in the meantime. And vice-versa.
     */
    cx = cx_pushblock(cxflags, gimme, MARK, PL_savestack_ix);
    cx_pushloop_for(cx, itervarp, itersave);

    if (PL_op->op_flags & OPf_STACKED) {
        /* OPf_STACKED implies either a single array: for(@), with a
         * single AV on the stack, or a range: for (1..5), with 1 and 5 on
         * the stack */
        SV *maybe_ary = *PL_stack_sp;
        if (SvTYPE(maybe_ary) != SVt_PVAV) {
            /* range */
            SV* sv = PL_stack_sp[-1];
            SV * const right = maybe_ary;
            assert(PL_op->op_next->op_type == OP_ITER);
            if (UNLIKELY((cxflags & CXp_FOR_LVREF) ||
                         (PL_op->op_next->op_private & OPpITER_REFALIAS)))
                DIE(aTHX_ "Assigned value is not a reference");
            SvGETMAGIC(sv);
            SvGETMAGIC(right);
            /* S_outside_integer will convert to NV and perform
             * assorted comparisons. Skip this effort for simple IV
             * cases. It should be possible to do this for all SvIOK,
             * but that would need edge cases in t/op/range.t to be
             * revisited, especially for (! $Config{d_nv_preserves_uv})
             */
            if (SvIOK_notUV(sv)    && SvIVX(sv) > -1 &&
                SvIOK_notUV(right) && SvIVX(right) > -1) {
                cx->cx_type |= CXt_LOOP_LAZYIV;
                cx->blk_loop.state_u.lazyiv.cur = SvIVX(sv);
                cx->blk_loop.state_u.lazyiv.end = SvIVX(right);
                rpp_popfree_2_NN();
            }
            else if (RANGE_IS_NUMERIC(sv,right)) {
                cx->cx_type |= CXt_LOOP_LAZYIV;
                if (S_outside_integer(aTHX_ sv) ||
                    S_outside_integer(aTHX_ right))
                    DIE(aTHX_ "Range iterator outside integer range");
                cx->blk_loop.state_u.lazyiv.cur = SvIV_nomg(sv);
                cx->blk_loop.state_u.lazyiv.end = SvIV_nomg(right);
                rpp_popfree_2_NN();
            }
            else {
                cx->cx_type |= CXt_LOOP_LAZYSV;
                cx->blk_loop.state_u.lazysv.cur = newSVsv(sv);
                cx->blk_loop.state_u.lazysv.end = right;

                /* we transfer ownership of 1 ref count of right from the
                 * stack to the CX .end entry, so no SvREFCNT_dec() needed */
                (void)rpp_pop_1_norc();

                rpp_popfree_1_NN(); /* free the (now copied) start SV */
                (void) SvPV_force_nolen(cx->blk_loop.state_u.lazysv.cur);
                /* This will do the upgrade to SVt_PV, and warn if the value
                   is uninitialised.  */
                (void) SvPV_nolen_const(right);
                /* Doing this avoids a check every time in pp_iter in pp_hot.c
                   to replace !SvOK() with a pointer to "".  */
                if (!SvOK(right)) {
                    SvREFCNT_dec(right);
                    cx->blk_loop.state_u.lazysv.end = &PL_sv_no;
                }
            }
        }
        else /* SvTYPE(maybe_ary) == SVt_PVAV */ {
            /* for (@array) {} */
            cx->cx_type |= CXt_LOOP_ARY;
            cx->blk_loop.state_u.ary.ary = MUTABLE_AV(maybe_ary);
            /* we transfer ownership of 1 ref count of the av from the
             * stack to the CX .ary entry, so no SvREFCNT_dec() needed */
            (void)rpp_pop_1_norc();
            cx->blk_loop.state_u.ary.ix =
                (priv & OPpITER_REVERSED) ?
                AvFILL(cx->blk_loop.state_u.ary.ary) + 1 :
                -1;
        }
        /* rpp_extend(1) not needed in this branch
         * because we just popped 1 item */
    }
    else { /* iterating over items on the stack */
        cx->cx_type |= CXt_LOOP_LIST;
        cx->blk_oldsp = PL_stack_sp - PL_stack_base;
        cx->blk_loop.state_u.stack.basesp = MARK - PL_stack_base;
        cx->blk_loop.state_u.stack.ix =
            (priv & OPpITER_REVERSED)
                ? cx->blk_oldsp + 1
                : cx->blk_loop.state_u.stack.basesp;
        /* pre-extend stack so pp_iter doesn't have to check every time
         * it pushes yes/no */
        rpp_extend(1);
    }

    return NORMAL;
}

PP(pp_enterloop)
{
    PERL_CONTEXT *cx;
    const U8 gimme = GIMME_V;

    cx = cx_pushblock(CXt_LOOP_PLAIN, gimme, PL_stack_sp, PL_savestack_ix);
    cx_pushloop_plain(cx);
    return NORMAL;
}


PP(pp_leaveloop)
{
    PERL_CONTEXT *cx;
    U8 gimme;
    SV **base;
    SV **oldsp;

    cx = CX_CUR();
    assert(CxTYPE_is_LOOP(cx));
    oldsp = PL_stack_base + cx->blk_oldsp;
    base = CxTYPE(cx) == CXt_LOOP_LIST
                ? PL_stack_base + cx->blk_loop.state_u.stack.basesp
                : oldsp;
    gimme = cx->blk_gimme;

    if (gimme == G_VOID)
        rpp_popfree_to_NN(base);
    else
        leave_adjust_stacks(oldsp, base, gimme,
                                PL_op->op_private & OPpLVALUE ? 3 : 1);

    CX_LEAVE_SCOPE(cx);
    cx_poploop(cx);	/* Stack values are safe: release loop vars ... */
    cx_popblock(cx);
    CX_POP(cx);

    return NORMAL;
}


/* This duplicates most of pp_leavesub, but with additional code to handle
 * return args in lvalue context. It was forked from pp_leavesub to
 * avoid slowing down that function any further.
 *
 * Any changes made to this function may need to be copied to pp_leavesub
 * and vice-versa.
 *
 * also tail-called by pp_return
 */

PP(pp_leavesublv)
{
    U8 gimme;
    PERL_CONTEXT *cx;
    SV **oldsp;
    OP *retop;

    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_SUB);

    if (CxMULTICALL(cx)) {
        /* entry zero of a stack is always PL_sv_undef, which
         * simplifies converting a '()' return into undef in scalar context */
        assert(PL_stack_sp > PL_stack_base || *PL_stack_base == &PL_sv_undef);
        return 0;
    }

    gimme = cx->blk_gimme;
    oldsp = PL_stack_base + cx->blk_oldsp; /* last arg of previous frame */

    if (gimme == G_VOID)
        rpp_popfree_to_NN(oldsp);
    else {
        U8   lval    = CxLVAL(cx);
        bool is_lval = (lval && !(lval & OPpENTERSUB_INARGS));
        const char *what = NULL;

        if (gimme == G_SCALAR) {
            if (is_lval) {
                /* check for bad return arg */
                if (oldsp < PL_stack_sp) {
                    SV *sv = *PL_stack_sp;
                    if ((SvPADTMP(sv) || SvREADONLY(sv))) {
                        what =
                            SvREADONLY(sv) ? (sv == &PL_sv_undef) ? "undef"
                            : "a readonly value" : "a temporary";
                    }
                    else goto ok;
                }
                else {
                    /* sub:lvalue{} will take us here. */
                    what = "undef";
                }
              croak:
                croak(
                          "Can't return %s from lvalue subroutine", what);
            }

          ok:
            leave_adjust_stacks(oldsp, oldsp, gimme, is_lval ? 3 : 2);

            if (lval & OPpDEREF) {
                /* lval_sub()->{...} and similar */
                SvGETMAGIC(*PL_stack_sp);
                if (!SvOK(*PL_stack_sp)) {
                    SV *sv = vivify_ref(*PL_stack_sp, CxLVAL(cx) & OPpDEREF);
                    rpp_replace_1_1_NN(sv);
                }
            }
        }
        else {
            assert(gimme == G_LIST);
            assert (!(lval & OPpDEREF));

            if (is_lval) {
                /* scan for bad return args */
                SV **p;
                for (p = PL_stack_sp; p > oldsp; p--) {
                    SV *sv = *p;
                    /* the PL_sv_undef exception is to allow things like
                     * this to work, where PL_sv_undef acts as 'skip'
                     * placeholder on the LHS of list assigns:
                     *    sub foo :lvalue { undef }
                     *    ($a, undef, foo(), $b) = 1..4;
                     */
                    if (sv != &PL_sv_undef && (SvPADTMP(sv) || SvREADONLY(sv)))
                    {
                        /* Might be flattened array after $#array =  */
                        what = SvREADONLY(sv)
                                ? "a readonly value" : "a temporary";
                        goto croak;
                    }
                }
            }

            leave_adjust_stacks(oldsp, oldsp, gimme, is_lval ? 3 : 2);
        }
    }

    CX_LEAVE_SCOPE(cx);
    cx_popsub(cx);	/* Stack values are safe: release CV and @_ ... */
    cx_popblock(cx);
    retop =  cx->blk_sub.retop;
    CX_POP(cx);

    return retop;
}

static const char *S_defer_blockname(PERL_CONTEXT *cx)
{
    return (cx->cx_type & CXp_FINALLY) ? "finally" : "defer";
}


PP(pp_return)
{
    dMARK;
    generator_mark_return();
    PERL_CONTEXT *cx;
    I32 cxix = dopopto_cursub();

    assert(cxstack_ix >= 0);
    if (cxix < cxstack_ix) {
        I32 i;
        /* Check for defer { return; } */
        for(i = cxstack_ix; i > cxix; i--) {
            if(CxTYPE(&cxstack[i]) == CXt_DEFER)
                /* diag_listed_as: Can't "%s" out of a "defer" block */
                /* diag_listed_as: Can't "%s" out of a "finally" block */
                /* GH 23948: probably not reachable from test suite, but
                 * possibly from XS code; retain */
                croak("Can't \"%s\" out of a \"%s\" block",
                        "return", S_defer_blockname(&cxstack[i]));
        }
        if (cxix < 0) {
            if (!(       PL_curstackinfo->si_type == PERLSI_SORT
                  || (   PL_curstackinfo->si_type == PERLSI_MULTICALL
                      && (cxstack[0].cx_type & CXp_SUB_RE_FAKE))
                 )
            )
                DIE(aTHX_ "Can't return outside a subroutine");
            /* We must be in:
             *  a sort block, which is a CXt_NULL not a CXt_SUB;
             *  or a /(?{...})/ block.
             * Handle specially. */
            assert(CxTYPE(&cxstack[0]) == CXt_NULL
                    || (   CxTYPE(&cxstack[0]) == CXt_SUB
                        && (cxstack[0].cx_type & CXp_SUB_RE_FAKE)));
            if (cxstack_ix > 0) {
                /* See comment below about context popping. Since we know
                 * we're scalar and not lvalue, we can preserve the return
                 * value in a simpler fashion than there. */
                SV *sv = *PL_stack_sp;
                assert(cxstack[0].blk_gimme == G_SCALAR);
                if (   (PL_stack_sp != PL_stack_base)
                    && !(SvFLAGS(sv) & (SVs_TEMP|SVs_PADTMP))
                )
#ifdef PERL_RC_STACK
                    rpp_replace_at_norc(PL_stack_sp, newSVsv(sv));
#else
                    *PL_stack_sp = sv_mortalcopy(sv);
#endif
                dounwind(0);
            }
            /* caller responsible for popping cxstack[0] */
            return 0;
        }

        /* There are contexts that need popping. Doing this may free the
         * return value(s), so preserve them first: e.g. popping the plain
         * loop here would free $x:
         *     sub f {  { my $x = 1; return $x } }
         * We may also need to shift the args down; for example,
         *    for (1,2) { return 3,4 }
         * leaves 1,2,3,4 on the stack. Both these actions will be done by
         * leave_adjust_stacks(), along with freeing any temps. Note that
         * whoever we tail-call (e.g. pp_leaveeval) will also call
         * leave_adjust_stacks(); however, the second call is likely to
         * just see a bunch of SvTEMPs with a ref count of 1, and so just
         * pass them through, rather than copying them again. So this
         * isn't as inefficient as it sounds.
         */
        cx = &cxstack[cxix];
        if (cx->blk_gimme != G_VOID)
            leave_adjust_stacks(MARK, PL_stack_base + cx->blk_oldsp,
                    cx->blk_gimme,
                    CxTYPE(cx) == CXt_SUB && CvLVALUE(cx->blk_sub.cv)
                        ? 3 : 0);
        dounwind(cxix);
        cx = &cxstack[cxix]; /* CX stack may have been realloced */
    }
    else {
        /* Like in the branch above, we need to handle any extra junk on
         * the stack. But because we're not also popping extra contexts, we
         * don't have to worry about prematurely freeing args. So we just
         * need to do the bare minimum to handle junk, and leave the main
         * arg processing in the function we tail call, e.g. pp_leavesub.
         * In list context we have to splice out the junk; in scalar
         * context we can leave as-is (pp_leavesub will later return the
         * top stack element). But for an  empty arg list, e.g.
         *    for (1,2) { return }
         * we need to set PL_stack_sp = oldsp so that pp_leavesub knows to
         * push &PL_sv_undef onto the stack.
         */
        SV **oldsp;
        cx = &cxstack[cxix];
        oldsp = PL_stack_base + cx->blk_oldsp;
        if (oldsp != MARK) {
            SSize_t nargs = PL_stack_sp - MARK;
            if (nargs) {
                if (cx->blk_gimme == G_LIST) {
                    /* shift return args to base of call stack frame */
#ifdef PERL_RC_STACK
                    /* free the items on the stack that will get
                     * overwritten */
                    SV **p;
                    for (p = MARK; p > oldsp; p--) {
                        SV *sv = *p;
                        *p = NULL;
                        SvREFCNT_dec(sv);
                    }
#endif
                    Move(MARK + 1, oldsp + 1, nargs, SV*);
                    PL_stack_sp  = oldsp + nargs;
                }
            }
            else
                rpp_popfree_to_NN(oldsp);
        }
    }

    /* fall through to a normal exit */
    switch (CxTYPE(cx)) {
    case CXt_EVAL:
        return CxEVALBLOCK(cx)
            ? Perl_pp_leavetry(aTHX)
            : Perl_pp_leaveeval(aTHX);
    case CXt_SUB:
        return CvLVALUE(cx->blk_sub.cv)
            ? Perl_pp_leavesublv(aTHX)
            : Perl_pp_leavesub(aTHX);
    case CXt_FORMAT:
        return Perl_pp_leavewrite(aTHX);
    default:
        DIE(aTHX_ "panic: return, type=%u", (unsigned) CxTYPE(cx));
    }
}

/* find the enclosing loop or labelled loop and dounwind() back to it. */

static PERL_CONTEXT *
S_unwind_loop(pTHX)
{
    I32 cxix;
    if (PL_op->op_flags & OPf_SPECIAL) {
        cxix = dopoptoloop(cxstack_ix);
        if (cxix < 0)
            /* diag_listed_as: Can't "last" outside a loop block */
            croak("Can't \"%s\" outside a loop block",
                OP_NAME(PL_op));
    }
    else {
        STRLEN label_len;
        const char * label;
        U32 label_flags;
        SV *sv;

        if (PL_op->op_flags & OPf_STACKED) {
            sv          = *PL_stack_sp;
            label       = SvPV(sv, label_len);
            label_flags = SvUTF8(sv);
        }
        else {
            sv          = NULL; /* not needed, but shuts up compiler warn */
            label       = cPVOP->op_pv;
            label_len   = strlen(label);
            label_flags = (cPVOP->op_private & OPpPV_IS_UTF8) ? SVf_UTF8 : 0;
        }

        cxix = dopoptolabel(label, label_len, label_flags);
        if (cxix < 0)
            /* diag_listed_as: Label not found for "last %s" */
            croak("Label not found for \"%s %" SVf "\"",
                                       OP_NAME(PL_op),
                                       SVfARG(PL_op->op_flags & OPf_STACKED
                                              && !SvGMAGICAL(sv)
                                              ? sv
                                              : newSVpvn_flags(label,
                                                    label_len,
                                                    label_flags | SVs_TEMP)));
        if (PL_op->op_flags & OPf_STACKED)
            rpp_popfree_1_NN();
    }

    if (cxix < cxstack_ix) {
        I32 i;
        /* Check for defer { last ... } etc */
        for(i = cxstack_ix; i > cxix; i--) {
            if(CxTYPE(&cxstack[i]) == CXt_DEFER)
                /* diag_listed_as: Can't "%s" out of a "defer" block */
                /* diag_listed_as: Can't "%s" out of a "finally" block */
                croak("Can't \"%s\" out of a \"%s\" block",
                        OP_NAME(PL_op), S_defer_blockname(&cxstack[i]));
        }
        dounwind(cxix);
    }
    return &cxstack[cxix];
}


PP(pp_last)
{
    PERL_CONTEXT *cx;
    OP* nextop;

    cx = S_unwind_loop(aTHX);

    if (CxTYPE(cx) == CXt_DISPATCH) {
        rpp_popfree_to_NN(PL_stack_base + cx->blk_oldsp);
        TAINT_NOT;
        CX_LEAVE_SCOPE(cx);
        cx_popdispatch(cx);
        cx_popblock(cx);
        nextop = cx->blk_dispatch.leave_op->op_next;
        CX_POP(cx);
        return nextop;
    }

    assert(CxTYPE_is_LOOP(cx));
    rpp_popfree_to_NN(PL_stack_base
                + (CxTYPE(cx) == CXt_LOOP_LIST
                    ?  cx->blk_loop.state_u.stack.basesp
                    : cx->blk_oldsp
                ));

    TAINT_NOT;

    /* Stack values are safe: */
    CX_LEAVE_SCOPE(cx);
    cx_poploop(cx);	/* release loop vars ... */
    cx_popblock(cx);
    nextop = cx->blk_loop.my_op->op_lastop->op_next;
    CX_POP(cx);

    return nextop;
}

static void S_dispatch_rollback_bindings(pTHX_ PERL_CONTEXT *cx);

PP(pp_next)
{
    PERL_CONTEXT *cx;

    /* if not a bare 'next' in the main scope, search for it */
    cx = CX_CUR();
    if (!((PL_op->op_flags & OPf_SPECIAL) && CxTYPE_is_LOOP(cx)))
        cx = S_unwind_loop(aTHX);

    if (CxTYPE(cx) == CXt_DISPATCH) {
        rpp_popfree_to_NN(PL_stack_base + cx->blk_oldsp);
        TAINT_NOT;
        CX_LEAVE_SCOPE(cx);
        cx_popdispatch(cx);
        cx_popblock(cx);
        {
            OP * const nextop = cx->blk_dispatch.leave_op->op_next;
            CX_POP(cx);
            return nextop;
        }
    }

    cx_topblock(cx);
    PL_curcop = cx->blk_oldcop;
    PERL_ASYNC_CHECK();
    return (cx)->blk_loop.my_op->op_nextop;
}

PP(pp_redo)
{
    PERL_CONTEXT *cx = S_unwind_loop(aTHX);

    if (CxTYPE(cx) == CXt_DISPATCH) {
        OP * const redo_op = cx->blk_dispatch.redo_op;
        AV *bindings = cx->blk_dispatch.committed_bindings;
        SSize_t i;

        S_dispatch_rollback_bindings(aTHX_ cx);
        if (bindings) {
            for (i = 0; i + 3 <= av_len(bindings); i += 4) {
                SV **padix_sv = av_fetch(bindings, i, FALSE);
                SV **kind_sv = av_fetch(bindings, i + 2, FALSE);
                SV **clear_sv = av_fetch(bindings, i + 3, FALSE);
                if (padix_sv && kind_sv && clear_sv && SvTRUE(*clear_sv)) {
                    const U8 kind = (U8)SvUV(*kind_sv);
                    SV *target = PAD_SV((PADOFFSET)SvUV(*padix_sv));
                    if (SvREFCNT(target) > 1 || SvOBJECT(target)) {
                        SV *replacement = kind == DISPATCH_BINDING_ARRAY
                            ? MUTABLE_SV(newAV()) : kind == DISPATCH_BINDING_HASH
                            ? MUTABLE_SV(newHV()) : newSV_type(SVt_NULL);
                        SvFLAGS(replacement) |= SVs_PADSTALE;
                        PAD_SVl((PADOFFSET)SvUV(*padix_sv)) = replacement;
                        SvREFCNT_dec(target);
                    }
                    else if (kind == DISPATCH_BINDING_ARRAY)
                        av_clear(MUTABLE_AV(target));
                    else if (kind == DISPATCH_BINDING_HASH)
                        hv_clear(MUTABLE_HV(target));
                    else
                        sv_setsv(target, &PL_sv_undef);
                }
            }
            SvREFCNT_dec((SV *)bindings);
            cx->blk_dispatch.committed_bindings = NULL;
        }

        FREETMPS;
        CX_LEAVE_SCOPE(cx);
        cx_topblock(cx);
        cx->blk_dispatch.on_active = FALSE;
        cx->blk_dispatch.dispatch_clause = DISPATCH_ON_NO_CLAUSE;
        PL_curcop = cx->blk_oldcop;
        PERL_ASYNC_CHECK();
        return redo_op;
    }

    OP* redo_op = cx->blk_loop.my_op->op_redoop;

    if (redo_op->op_type == OP_ENTER) {
        /* pop one less context to avoid $x being freed in while (my $x..) */
        cxstack_ix++;
        cx = CX_CUR();
        assert(CxTYPE(cx) == CXt_BLOCK);
        redo_op = redo_op->op_next;
    }

    FREETMPS;
    CX_LEAVE_SCOPE(cx);
    cx_topblock(cx);
    PL_curcop = cx->blk_oldcop;
    PERL_ASYNC_CHECK();
    return redo_op;
}

#define UNENTERABLE (OP *)1
#define GOTO_DEPTH 64

static OP *
S_dofindlabel(pTHX_ OP *o, const char *label, STRLEN len, U32 flags, OP **opstack, OP **oplimit)
{
    PERL_ARGS_ASSERT_DOFINDLABEL;

    OP **ops = opstack;
    static const char* const too_deep = "Target of goto is too deeply nested";

    if (ops >= oplimit)
        croak("%s", too_deep);
    if (o->op_type == OP_LEAVE ||
        o->op_type == OP_SCOPE ||
        o->op_type == OP_LEAVELOOP ||
        o->op_type == OP_LEAVESUB ||
        o->op_type == OP_LEAVETRY ||
        o->op_type == OP_LEAVEGIVEN)
    {
        *ops++ = cUNOPo->op_first;
    }
    else if (oplimit - opstack < GOTO_DEPTH) {
      if (o->op_flags & OPf_KIDS
          && cUNOPo->op_first->op_type == OP_PUSHMARK) {
        *ops++ = UNENTERABLE;
      }
      else if (o->op_flags & OPf_KIDS && PL_opargs[o->op_type]
          && OP_CLASS(o) != OA_LOGOP
          && o->op_type != OP_LINESEQ
          && o->op_type != OP_SREFGEN
          && o->op_type != OP_ENTEREVAL
          && o->op_type != OP_GLOB
          && o->op_type != OP_RV2CV) {
        OP * const kid = cUNOPo->op_first;
        if (OP_GIMME(kid, 0) != G_SCALAR || OpHAS_SIBLING(kid))
            *ops++ = UNENTERABLE;
      }
    }
    if (ops >= oplimit)
        croak("%s", too_deep);
    *ops = 0;
    if (o->op_flags & OPf_KIDS) {
        OP *kid;
        OP * const kid1 = cUNOPo->op_first;
        /* First try all the kids at this level, since that's likeliest. */
        for (kid = cUNOPo->op_first; kid; kid = OpSIBLING(kid)) {
            if (OP_TYPE_IS_COP_NN(kid)) {
                STRLEN kid_label_len;
                U32 kid_label_flags;
                const char *kid_label = CopLABEL_len_flags(kCOP,
                                                    &kid_label_len, &kid_label_flags);
                if (kid_label && (
                    ( (kid_label_flags & SVf_UTF8) != (flags & SVf_UTF8) ) ?
                        (flags & SVf_UTF8)
                            ? (bytes_cmp_utf8(
                                        (const U8*)kid_label, kid_label_len,
                                        (const U8*)label, len) == 0)
                            : (bytes_cmp_utf8(
                                        (const U8*)label, len,
                                        (const U8*)kid_label, kid_label_len) == 0)
                    : ( len == kid_label_len && ((kid_label == label)
                                    || memEQ(kid_label, label, len)))))
                    return kid;
            }
        }
        for (kid = cUNOPo->op_first; kid; kid = OpSIBLING(kid)) {
            bool first_kid_of_binary = FALSE;
            if (kid == PL_lastgotoprobe)
                continue;
            if (OP_TYPE_IS_COP_NN(kid)) {
                if (ops == opstack)
                    *ops++ = kid;
                else if (ops[-1] != UNENTERABLE
                      && (ops[-1]->op_type == OP_NEXTSTATE ||
                          ops[-1]->op_type == OP_DBSTATE))
                    ops[-1] = kid;
                else
                    *ops++ = kid;
            }
            if (kid == kid1 && ops != opstack && ops[-1] == UNENTERABLE) {
                first_kid_of_binary = TRUE;
                ops--;
            }
            if ((o = dofindlabel(kid, label, len, flags, ops, oplimit))) {
                if (kid->op_type == OP_PUSHDEFER)
                    croak("Can't \"goto\" into a \"defer\" block");
                return o;
            }
            if (first_kid_of_binary)
                *ops++ = UNENTERABLE;
        }
    }
    *ops = 0;
    return 0;
}


static void
S_check_op_type(pTHX_ OP * const o)
{
    /* Eventually we may want to stack the needed arguments
     * for each op.  For now, we punt on the hard ones. */
    /* XXX This comment seems to me like wishful thinking.  --sprout */
    if (o == UNENTERABLE)
        croak(
                  "Can't \"goto\" into a binary or list expression");
    if (o->op_type == OP_ENTERITER)
        croak(
                  "Can't \"goto\" into the middle of a foreach loop");
    if (o->op_type == OP_ENTERGIVEN)
        croak(
                  "Can't \"goto\" into a \"given\" block");
}

/* also used for: pp_dump() */

PP(pp_goto)
{
    OP *retop = NULL;
    I32 ix;
    PERL_CONTEXT *cx;
    OP *enterops[GOTO_DEPTH];
    bool into_construct = FALSE;
    const char *label = NULL;
    STRLEN label_len = 0;
    U32 label_flags = 0;
    const bool do_dump = (PL_op->op_type == OP_DUMP);
    static const char* const must_have_label = "goto must have label";

    if (PL_op->op_flags & OPf_STACKED) {
        /* goto EXPR  or  goto &foo */

        SV * const sv = *PL_stack_sp;
        SvGETMAGIC(sv);

        if (SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVCV) {
            /* This egregious kludge implements goto &subroutine */
            I32 cxix;
            PERL_CONTEXT *cx;
            CV *cv = CV_FROM_REF(sv);
            AV *arg = GvAV(PL_defgv);
            CV *old_cv = NULL;

            while (!CvROOT(cv) && !CvXSUB(cv)) {
                const GV * const gv = CvGV(cv);
                if (gv) {
                    GV *autogv;
                    SV *tmpstr;
                    /* autoloaded stub? */
                    if (cv != GvCV(gv) && (cv = GvCV(gv)))
                        continue;
                    autogv = gv_autoload_pvn(GvSTASH(gv), GvNAME(gv),
                                          GvNAMELEN(gv),
                                          GvNAMEUTF8(gv) ? SVf_UTF8 : 0);
                    if (autogv && (cv = GvCV(autogv)))
                        continue;
                    tmpstr = sv_newmortal();
                    gv_efullname3(tmpstr, gv, NULL);
                    DIE(aTHX_ "Goto undefined subroutine &%" SVf, SVfARG(tmpstr));
                }
                /* GH-23969: This exception should be retained because it can
                 * be reached from XS code. */
                DIE(aTHX_ "Goto undefined subroutine");
            }

            cxix = dopopto_cursub();
            if (cxix < 0) {
                DIE(aTHX_ "Can't goto subroutine outside a subroutine");
            }
            cx  = &cxstack[cxix];
            /* ban goto in eval: see <20050521150056.GC20213@iabyn.com> */
            if (CxTYPE(cx) == CXt_EVAL) {
                if (CxREALEVAL(cx))
                /* diag_listed_as: Can't goto subroutine from an eval-%s */
                    DIE(aTHX_ "Can't goto subroutine from an eval-string");
                else
                /* diag_listed_as: Can't goto subroutine from an eval-%s */
                    DIE(aTHX_ "Can't goto subroutine from an eval-block");
            }
            else if (CxMULTICALL(cx))
                DIE(aTHX_ "Can't goto subroutine from a sort sub (or similar callback)");

            /* First do some returnish stuff. */

            SvREFCNT_inc_simple_void(cv); /* avoid premature free during unwind */
            rpp_popfree_1_NN(); /* safe to free original sv now */

            FREETMPS;
            if (cxix < cxstack_ix) {
                dounwind(cxix);
            }
            cx = CX_CUR();
            cx_topblock(cx);

            /* protect @_ during save stack unwind. */
            if (arg)
                SvREFCNT_inc_NN(sv_2mortal(MUTABLE_SV(arg)));

            assert(PL_scopestack_ix == cx->blk_oldscopesp);
            CX_LEAVE_SCOPE(cx);

            if (CxTYPE(cx) == CXt_SUB && CxHASARGS(cx)) {
                /* this is part of cx_popsub_args() */
                AV* av = MUTABLE_AV(PAD_SVl(0));
                assert(AvARRAY(MUTABLE_AV(
                    PadlistARRAY(CvPADLIST(cx->blk_sub.cv))[
                            CvDEPTH(cx->blk_sub.cv)])) == PL_curpad);

                /* we are going to donate the current @_ from the old sub
                 * to the new sub. This first part of the donation puts a
                 * new empty AV in the pad[0] slot of the old sub,
                 * unless pad[0] and @_ differ (e.g. if the old sub did
                 * local *_ = []); in which case clear the old pad[0]
                 * array in the usual way */

                if (av != arg && !SvMAGICAL(av) && SvREFCNT(av) == 1
#ifndef PERL_RC_STACK
                    && !AvREAL(av)
#endif
                )
                    clear_defarray_simple(av);
                else
                    clear_defarray(av, av == arg);
            }

            /* don't restore PL_comppad here. It won't be needed if the
             * sub we're going to is non-XS, but restoring it early then
             * croaking (e.g. the "Goto undefined subroutine" below)
             * means the CX block gets processed again in dounwind,
             * but this time with the wrong PL_comppad */

            /* A destructor called during LEAVE_SCOPE could have undefined
             * our precious cv.  See bug #99850. */
            if (!CvROOT(cv) && !CvXSUB(cv)) {
                const GV * const gv = CvGV(cv);
                if (gv) {
                    SV * const tmpstr = sv_newmortal();
                    gv_efullname3(tmpstr, gv, NULL);
                    DIE(aTHX_ "Goto undefined subroutine &%" SVf,
                               SVfARG(tmpstr));
                }
                /* GH-23969: This exception should be retained because it can
                 * be reached from XS code. */
                DIE(aTHX_ "Goto undefined subroutine");
            }

            if (CxTYPE(cx) == CXt_SUB) {
                CvDEPTH(cx->blk_sub.cv) = cx->blk_sub.olddepth;
                /*on XS calls defer freeing the old CV as it could
                 * prematurely set PL_op to NULL, which could cause
                 * e..g XS subs using GIMME_V to SEGV */
                if (CvISXSUB(cv))
                    old_cv = cx->blk_sub.cv;
                else
                    SvREFCNT_dec_NN(cx->blk_sub.cv);
            }

            /* Now do some callish stuff. */
            if (CvISXSUB(cv)) {
                const SSize_t items = arg ? AvFILL(arg) + 1 : 0;
                const bool m = arg ? cBOOL(SvRMAGICAL(arg)) : 0;
                SV** mark;
                UNOP fake_goto_op;

                ENTER;
                SAVETMPS;
                SAVEFREESV(cv); /* later, undo the 'avoid premature free' hack */
                if (old_cv)
                    SAVEFREESV(old_cv); /* ditto, deferred freeing of old CV */

                /* put GvAV(defgv) back onto stack */
                if (items)
                    rpp_extend(items + 1); /* @_ could have been extended. */
                mark = PL_stack_sp;
                if (items) {
                    SSize_t index;
#ifdef PERL_RC_STACK
                    assert(AvREAL(arg));
#else
                    bool r = cBOOL(AvREAL(arg));
#endif
                    for (index=0; index<items; index++)
                    {
                        SV *sv;
                        if (m) {
                            SV ** const svp = av_fetch(arg, index, 0);
                            sv = svp ? *svp : NULL;
                        }
                        else sv = AvARRAY(arg)[index];

#ifdef PERL_RC_STACK
                        rpp_push_1(
                            sv
                            ? sv
                            : newSVavdefelem(arg, index, 1)
                        );
#else
                        rpp_push_1(
                            sv
                            ? (r ? SvREFCNT_inc_NN(sv_2mortal(sv)) : sv)
                            : sv_2mortal(newSVavdefelem(arg, index, 1))
                        );
#endif
                    }
                }

                if (CxTYPE(cx) == CXt_SUB && CxHASARGS(cx)) {
                    /* Restore old @_ */
                    CX_POP_SAVEARRAY(cx);
                }

                retop = cx->blk_sub.retop;
                PL_comppad = cx->blk_sub.prevcomppad;
                PL_curpad = LIKELY(PL_comppad) ? AvARRAY(PL_comppad) : NULL;

                /* Make a temporary a copy of the current GOTO op on the C
                 * stack, but with a modified gimme (we can't modify the
                 * real GOTO op as that's not thread-safe). This allows XS
                 * users of GIMME_V to get the correct calling context,
                 * even though there is no longer a CXt_SUB frame to
                 * provide that information.
                 */
                Copy(PL_op, &fake_goto_op, 1, UNOP);
                U8 gimme = (cx->blk_gimme & G_WANT);
                fake_goto_op.op_flags =
                                  (fake_goto_op.op_flags & ~OPf_WANT)
                                | gimme;
                PL_op = (OP*)&fake_goto_op;

                /* XS subs don't have a CXt_SUB, so pop it;
                 * this is a cx_popblock(), less all the stuff we already did
                 * for cx_topblock() earlier */
                PL_curcop = cx->blk_oldcop;
                /* this is cx_popsub, less all the stuff we already did */
                PL_curstackinfo->si_cxsubix = cx->blk_sub.old_cxsubix;

                CX_POP(cx);

                /* Push a mark for the start of arglist */
                PUSHMARK(mark);
                SSize_t markix = TOPMARK;
                rpp_invoke_xs(cv);

                /* Enforce some sanity in scalar context. */
                if (gimme == G_SCALAR) {
                    SV **svp = PL_stack_base + markix + 1;
                    if (svp != PL_stack_sp) {
#ifdef PERL_RC_STACK
                        if (svp < PL_stack_sp) {
                            /* move return value to bottom of stack frame
                             * and free everything else */
                            SV* retsv = *PL_stack_sp;
                            *PL_stack_sp = *svp;
                            *svp = retsv;
                            rpp_popfree_to_NN(svp);
                        }
                        else
                            rpp_push_IMM(&PL_sv_undef);
#else
                        *svp = svp > PL_stack_sp ? &PL_sv_undef : *PL_stack_sp;
                        PL_stack_sp = svp;
#endif
                    }
                }

                LEAVE;
            }
            else {
                PADLIST * const padlist = CvPADLIST(cv);

                SAVEFREESV(cv); /* later, undo the 'avoid premature free' hack */

                /* partial unrolled cx_pushsub(): */

                cx->blk_sub.cv = cv;
                cx->blk_sub.olddepth = CvDEPTH(cv);

                CvDEPTH(cv)++;
                SvREFCNT_inc_simple_void_NN(cv);
                if (CvDEPTH(cv) > 1) {
                    if (CvDEPTH(cv) == PERL_SUB_DEPTH_WARN && ckWARN(WARN_RECURSION))
                        sub_crush_depth(cv);
                    pad_push(padlist, CvDEPTH(cv));
                }
                PL_curcop = cx->blk_oldcop;
                PAD_SET_CUR_NOSAVE(padlist, CvDEPTH(cv));

                if (CxHASARGS(cx))
                {
                    /* second half of donating @_ from the old sub to the
                     * new sub: abandon the original pad[0] AV in the
                     * new sub, and replace it with the donated @_.
                     * pad[0] takes ownership of the extra refcount
                     * we gave arg earlier */
                    if (arg) {
                        SvREFCNT_dec(PAD_SVl(0));
                        PAD_SVl(0) = (SV *)arg;
                        SvREFCNT_inc_simple_void_NN(arg);
                    }

                    /* GvAV(PL_defgv) might have been modified on scope
                       exit, so point it at arg again. */
                    if (arg != GvAV(PL_defgv)) {
                        AV * const av = GvAV(PL_defgv);
                        GvAV(PL_defgv) = AvREFCNT_inc_simple(arg);
                        SvREFCNT_dec(av);
                    }
                }

                if (PERLDB_SUB) {	/* Checking curstash breaks DProf. */
                    Perl_get_db_sub(aTHX_ NULL, cv);
                    if (PERLDB_GOTO) {
                        CV * const gotocv = get_cvs("DB::goto", 0);
                        if (gotocv) {
                            PUSHMARK( PL_stack_sp );
                            call_sv(MUTABLE_SV(gotocv), G_SCALAR | G_NODEBUG);
                            PL_stack_sp--;
                        }
                    }
                }
                retop = CvSTART(cv);
            }
            goto finish;
        }
        else {
            /* goto EXPR */
            /* avoid premature free of label before popping it off stack */
            SvREFCNT_inc_NN(sv);
            sv_2mortal(sv);
            rpp_popfree_1_NN();
            label       = SvPV_nomg_const(sv, label_len);
            label_flags = SvUTF8(sv);
        }
    }
    else if (!(PL_op->op_flags & OPf_SPECIAL)) {
        /* goto LABEL  or  dump LABEL */
        label       = cPVOP->op_pv;
        label_flags = (cPVOP->op_private & OPpPV_IS_UTF8) ? SVf_UTF8 : 0;
        label_len   = strlen(label);
    }
    if (!(do_dump || label_len)) DIE(aTHX_ "%s", must_have_label);

    PERL_ASYNC_CHECK();

    if (label_len) {
        OP *gotoprobe = NULL;
        bool leaving_eval = FALSE;
        bool in_block = FALSE;
        bool pseudo_block = FALSE;
        PERL_CONTEXT *last_eval_cx = NULL;

        /* find label */

        PL_lastgotoprobe = NULL;
        *enterops = 0;
        for (ix = cxstack_ix; ix >= 0; ix--) {
            cx = &cxstack[ix];
            switch (CxTYPE(cx)) {
            case CXt_EVAL:
                leaving_eval = TRUE;
                if (!CxEVALBLOCK(cx)) {
                    gotoprobe = (last_eval_cx ?
                                last_eval_cx->blk_eval.old_eval_root :
                                PL_eval_root);
                    last_eval_cx = cx;
                    break;
                }
                /* else fall through */
            case CXt_LOOP_PLAIN:
            case CXt_LOOP_LAZYIV:
            case CXt_LOOP_LAZYSV:
            case CXt_LOOP_LIST:
            case CXt_LOOP_ARY:
            case CXt_GIVEN:
            case CXt_WHEN:
            case CXt_DISPATCH:
            case CXt_DISPATCH_ON:
                gotoprobe = OpSIBLING(cx->blk_oldcop);
                break;
            case CXt_SUBST:
                continue;
            case CXt_BLOCK:
                if (ix) {
                    PERL_CONTEXT *encl = &cxstack[ix - 1];
                    /* CXt_DEFER includes finally{} blocks */
                    if (CxTYPE(encl) == CXt_DEFER)
                        gotoprobe = encl->blk_defer.defer_root;
                    else
                        gotoprobe = OpSIBLING(cx->blk_oldcop);
                    in_block = TRUE;
                } else
                    gotoprobe = PL_main_root;
                break;
            case CXt_SUB:
                gotoprobe = CvROOT(cx->blk_sub.cv);
                pseudo_block = cBOOL(CxMULTICALL(cx));
                break;
            case CXt_FORMAT:
            case CXt_NULL:
                DIE(aTHX_ "Can't \"goto\" out of a pseudo block");
            case CXt_DEFER:
                /* diag_listed_as: Can't "%s" out of a "defer" block */
                DIE(aTHX_ "Can't \"%s\" out of a \"%s\" block", "goto", S_defer_blockname(cx));
            default:
                if (ix)
                    DIE(aTHX_ "panic: goto, type=%u, ix=%ld",
                        CxTYPE(cx), (long) ix);
                gotoprobe = PL_main_root;
                break;
            }
            if (gotoprobe) {
                OP *sibl1, *sibl2;

                retop = dofindlabel(gotoprobe, label, label_len, label_flags,
                                    enterops, enterops + GOTO_DEPTH);
                if (retop)
                    break;
                if ( (sibl1 = OpSIBLING(gotoprobe)) &&
                     sibl1->op_type == OP_UNSTACK &&
                     (sibl2 = OpSIBLING(sibl1)))
                {
                    retop = dofindlabel(sibl2,
                                        label, label_len, label_flags, enterops,
                                        enterops + GOTO_DEPTH);
                    if (retop)
                        break;
                }
            }
            if (pseudo_block)
                DIE(aTHX_ "Can't \"goto\" out of a pseudo block");
            PL_lastgotoprobe = gotoprobe;
        }
        if (!retop)
            DIE(aTHX_ "Can't find label %" UTF8f,
                       UTF8fARG(label_flags, label_len, label));

        /* if we're leaving an eval, check before we pop any frames
           that we're not going to punt, otherwise the error
           won't be caught */

        if (leaving_eval && *enterops && enterops[1]) {
            I32 i;
            for (i = 1; enterops[i]; i++)
                S_check_op_type(aTHX_ enterops[i]);
        }

        if (*enterops && enterops[1]) {
            I32 i = enterops[1] != UNENTERABLE
                 && enterops[1]->op_type == OP_ENTER && in_block
                    ? 2
                    : 1;
            if (enterops[i])
                into_construct = TRUE;
        }

        /* pop unwanted frames */

        if (ix < cxstack_ix) {
            if (ix < 0)
                DIE(aTHX_ "panic: docatch: illegal ix=%ld", (long)ix);
            dounwind(ix);
            cx = CX_CUR();
            cx_topblock(cx);
        }

        /* push wanted frames */

        if (*enterops && enterops[1]) {
            OP * const oldop = PL_op;
            ix = enterops[1] != UNENTERABLE
              && enterops[1]->op_type == OP_ENTER && in_block
                   ? 2
                   : 1;
            for (; enterops[ix]; ix++) {
                PL_op = enterops[ix];
                S_check_op_type(aTHX_ PL_op);
                DEBUG_l( deb("pp_goto: Entering %s\n",
                                         OP_NAME(PL_op)));
                PL_op->op_ppaddr(aTHX);
            }
            PL_op = oldop;
        }
    }

    if (into_construct)
        croak("Use of \"goto\" to jump into a construct is no longer permitted");

    if (do_dump) {
#ifdef VMS
        if (!retop) retop = PL_main_start;
#endif
        PL_restartop = retop;
        PL_do_undump = TRUE;

        my_unexec();

        PL_restartop = 0;		/* hmm, must be GNU unexec().. */
        PL_do_undump = FALSE;
    }

  finish:
    PERL_ASYNC_CHECK();
    return retop;
}

PP_wrapped(pp_exit, 1, 0)
{
    dSP;
    I32 anum;

    if (MAXARG < 1)
        anum = 0;
    else if (!TOPs) {
        anum = 0; (void)POPs;
    }
    else {
        anum = SvIVx(POPs);
#ifdef VMS
        if (anum == 1
         && SvTRUE(cop_hints_fetch_pvs(PL_curcop, "vmsish_exit", 0)))
            anum = 0;
        VMSISH_HUSHED  =
            VMSISH_HUSHED || (PL_curcop->op_private & OPpHUSH_VMSISH);
#endif
    }
    PL_exit_flags |= PERL_EXIT_EXPECTED;
    my_exit(anum);
    PUSHs(&PL_sv_undef);
    RETURN;
}

/* Eval. */

static void
S_save_lines(pTHX_ AV *array, SV *sv)
{
    PERL_ARGS_ASSERT_SAVE_LINES;

    const char *s = SvPVX_const(sv);
    const char * const send = SvPVX_const(sv) + SvCUR(sv);
    I32 line = 1;

    while (s && s < send) {
        const char *t;
        SV * const tmpstr = newSV_type(SVt_PVIV);

        t = (const char *)memchr(s, '\n', send - s);
        if (t)
            t++;
        else
            t = send;

        sv_setpvn_fresh(tmpstr, s, t - s);
        /* not breakable until we compile a COP for it */
        assert(SvIVX(tmpstr) == 0);
        SvIOK_on(tmpstr);
        av_store(array, line++, tmpstr);
        s = t;
    }
}

/*
=for apidoc docatch

Interpose, for the current op and RUNOPS loop,

    - a new JMPENV stack catch frame, and
    - an inner RUNOPS loop to run all the remaining ops following the
      current PL_op.

Then handle any exceptions raised while in that loop.
For a caught eval at this level, re-enter the loop with the specified
restart op (i.e. the op following the OP_LEAVETRY etc); otherwise re-throw
the exception.

docatch() is intended to be used like this:

    PP(pp_entertry)
    {
        if (CATCH_GET)
            return docatch(Perl_pp_entertry);

        ... rest of function ...
        return PL_op->op_next;
    }

If a new catch frame isn't needed, the op behaves normally. Otherwise it
calls docatch(), which recursively calls pp_entertry(), this time with
CATCH_GET() false, so the rest of the body of the entertry is run. Then
docatch() calls CALLRUNOPS() which executes all the ops following the
entertry. When the loop finally finishes, control returns to docatch(),
which pops the JMPENV and returns to the parent pp_entertry(), which
itself immediately returns. Note that *all* subsequent ops are run within
the inner RUNOPS loop, not just the body of the eval. For example, in

    sub TIEARRAY { eval {1}; my $x }
    tie @a, "main";

at the point the 'my' is executed, the C stack will look something like:

    #10 main()
    #9  perl_run()              # JMPENV_PUSH level 1 here
    #8  S_run_body()
    #7  Perl_runops_standard()  # main RUNOPS loop
    #6  Perl_pp_tie()
    #5  Perl_call_sv()
    #4  Perl_runops_standard()  # unguarded RUNOPS loop: no new JMPENV
    #3  Perl_pp_entertry()
    #2  S_docatch()             # JMPENV_PUSH level 2 here
    #1  Perl_runops_standard()  # docatch()'s RUNOPs loop
    #0  Perl_pp_padsv()

Basically, any section of the perl core which starts a RUNOPS loop may
make a promise that it will catch any exceptions and restart the loop if
necessary. If it's not prepared to do that (like call_sv() isn't), then
it sets CATCH_GET() to true, so that any later eval-like code knows to
set up a new handler and loop (via docatch()).

See L<perlinterp/"Exception handing"> for further details.

=cut
*/

static OP *
S_docatch(pTHX_ Perl_ppaddr_t firstpp)
{
    PERL_ARGS_ASSERT_DOCATCH;

    int ret;
    OP * const oldop = PL_op;
    dJMPENV;

    assert(CATCH_GET);
    JMPENV_PUSH(ret);
    assert(!CATCH_GET);

    switch (ret) {
    case 0: /* normal flow-of-control return from JMPENV_PUSH */

        /* re-run the current op, this time executing the full body of the
         * pp function */
        PL_op = firstpp(aTHX);
 redo_body:
        if (PL_op) {
            CALLRUNOPS(aTHX);
        }
        break;

    case 3: /* an exception raised within an eval */
        if (PL_restartjmpenv == PL_top_env) {
            /* die caught by an inner eval - continue inner loop */

            if (!PL_restartop)
                break;
            PL_restartjmpenv = NULL;
            PL_op = PL_restartop;
            PL_restartop = 0;
            goto redo_body;
        }
        /* FALLTHROUGH */

    default:
        JMPENV_POP;
        PL_op = oldop;
        JMPENV_JUMP(ret); /* re-throw the exception */
        NOT_REACHED; /* NOTREACHED */
    }
    JMPENV_POP;
    PL_op = oldop;
    return NULL;
}


/*
=for apidoc find_runcv

Locate the CV corresponding to the currently executing sub or eval.
If C<db_seqp> is non_null, skip CVs that are in the DB package and populate
C<*db_seqp> with the cop sequence number at the point that the DB:: code was
entered.  (This allows debuggers to eval in the scope of the breakpoint
rather than in the scope of the debugger itself.)

=cut
*/

CV*
Perl_find_runcv(pTHX_ U32 *db_seqp)
{
    PERL_ARGS_ASSERT_FIND_RUNCV;

    return find_runcv_where(0, 0, db_seqp);
}

/* If this becomes part of the API, it might need a better name. */
CV *
Perl_find_runcv_where(pTHX_ U8 cond, IV arg, U32 *db_seqp)
{
    PERL_ARGS_ASSERT_FIND_RUNCV_WHERE;

    PERL_SI	 *si;
    int		 level = 0;

    if (db_seqp)
        *db_seqp =
            PL_curcop == &PL_compiling
                ? PL_cop_seqmax
                : PL_curcop->cop_seq;

    for (si = PL_curstackinfo; si; si = si->si_prev) {
        I32 ix;
        for (ix = si->si_cxix; ix >= 0; ix--) {
            const PERL_CONTEXT *cx = &(si->si_cxstack[ix]);
            CV *cv = NULL;
            if (CxTYPE(cx) == CXt_SUB || CxTYPE(cx) == CXt_FORMAT) {
                cv = cx->blk_sub.cv;
                /* skip DB:: code */
                if (db_seqp && PL_debstash && CvSTASH(cv) == PL_debstash) {
                    *db_seqp = cx->blk_oldcop->cop_seq;
                    continue;
                }
                if (cx->cx_type & CXp_SUB_RE)
                    continue;
            }
            else if (CxTYPE(cx) == CXt_EVAL && !CxEVALBLOCK(cx))
                cv = cx->blk_eval.cv;
            if (cv) {
                switch (cond) {
                case FIND_RUNCV_padid_eq:
                    if (!CvPADLIST(cv)
                     || CvPADLIST(cv)->xpadl_id != (U32)arg)
                        continue;
                    return cv;
                case FIND_RUNCV_level_eq:
                    if (level++ != arg) continue;
                    /* FALLTHROUGH */
                default:
                    return cv;
                }
            }
        }
    }
    return cond == FIND_RUNCV_padid_eq ? NULL : PL_main_cv;
}


/* S_try_yyparse():
 *
 * Run yyparse() in a setjmp wrapper. Returns:
 *   0: yyparse() successful
 *   1: yyparse() failed
 *   3: yyparse() died
 *
 * This is used to trap Perl_croak() calls that are executed
 * during the compilation process and before the code has been
 * completely compiled. It is expected to be called from
 * doeval_compile() only. The parameter 'caller_op' is
 * only used in DEBUGGING to validate the logic is working
 * correctly.
 *
 * See also try_run_unitcheck().
 *
 */
static int
S_try_yyparse(pTHX_ int gramtype, OP *caller_op)
{
    /* if we die during compilation PL_restartop and PL_restartjmpenv
     * will be set by Perl_die_unwind(). We need to restore their values
     * if that happens as they are intended for the case where the code
     * compiles and dies during execution, not where it dies during
     * compilation. PL_restartop and caller_op->op_next should be the
     * same anyway, and when compilation fails then caller_op->op_next is
     * used as the next op after the compile.
     */
    JMPENV *restartjmpenv = PL_restartjmpenv;
    OP *restartop = PL_restartop;
    dJMPENV;
    int ret;
    PERL_UNUSED_ARG(caller_op); /* only used in debugging builds */

    assert(CxTYPE(CX_CUR()) == CXt_EVAL);
    JMPENV_PUSH(ret);
    switch (ret) {
    case 0:
        ret = yyparse(gramtype) ? 1 : 0;
        break;
    case 3:
        /* yyparse() died and we trapped the error. We need to restore
         * the old PL_restartjmpenv and PL_restartop values. */
        assert(PL_restartop == caller_op->op_next); /* we expect these to match */
        PL_restartjmpenv = restartjmpenv;
        PL_restartop = restartop;
        break;
    default:
        JMPENV_POP;
        JMPENV_JUMP(ret);
        NOT_REACHED; /* NOTREACHED */
    }
    JMPENV_POP;
    return ret;
}

/* S_try_run_unitcheck()
 *
 * Run PL_unitcheckav in a setjmp wrapper via call_list.
 * Returns:
 *   0: unitcheck blocks ran without error
 *   3: a unitcheck block died
 *
 * This is used to trap Perl_croak() calls that are executed
 * during UNITCHECK blocks executed after the compilation
 * process has completed but before the code itself has been
 * executed via the normal run loops. It is expected to be called
 * from doeval_compile() only. The parameter 'caller_op' is
 * only used in DEBUGGING to validate the logic is working
 * correctly.
 *
 * See also try_yyparse().
 */
static int
S_try_run_unitcheck(pTHX_ OP* caller_op)
{
    /* if we die during compilation PL_restartop and PL_restartjmpenv
     * will be set by Perl_die_unwind(). We need to restore their values
     * if that happens as they are intended for the case where the code
     * compiles and dies during execution, not where it dies during
     * compilation. UNITCHECK runs after compilation completes, and
     * if it dies we will execute the PL_restartop anyway via the
     * failed compilation code path. PL_restartop and caller_op->op_next
     * should be the same anyway, and when compilation fails then
     * caller_op->op_next is  used as the next op after the compile.
     */
    JMPENV *restartjmpenv = PL_restartjmpenv;
    OP *restartop = PL_restartop;
    dJMPENV;
    int ret;
    PERL_UNUSED_ARG(caller_op); /* only used in debugging builds */

    assert(CxTYPE(CX_CUR()) == CXt_EVAL);
    JMPENV_PUSH(ret);
    switch (ret) {
    case 0:
        call_list(PL_scopestack_ix, PL_unitcheckav);
        break;
    case 3:
        /* call_list died */
        /* call_list() died and we trapped the error. We should restore
         * the old PL_restartjmpenv and PL_restartop values, as they are
         * used only in the case where the code was actually run.
         * The assert validates that we will still execute the PL_restartop.
         */
        assert(PL_restartop == caller_op->op_next); /* we expect these to match */
        PL_restartjmpenv = restartjmpenv;
        PL_restartop = restartop;
        break;
    default:
        JMPENV_POP;
        JMPENV_JUMP(ret);
        NOT_REACHED; /* NOTREACHED */
    }
    JMPENV_POP;
    return ret;
}

/* Compile a require/do or an eval ''.
 *
 * outside is the lexically enclosing CV (if any) that invoked us.
 * seq     is the current COP scope value.
 * hh      is the saved hints hash, if any.
 *
 * Returns a bool indicating whether the compile was successful; if so,
 * PL_eval_start contains the first op of the compiled code; otherwise,
 * pushes undef.
 *
 * This function is called from two places: pp_require and pp_entereval.
 * These can be distinguished by whether PL_op is entereval.
 */

static bool
S_doeval_compile(pTHX_ U8 gimme, CV* outside, U32 seq, HV *hh)
{
    PERL_ARGS_ASSERT_DOEVAL_COMPILE;

    OP * const saveop = PL_op;
    bool clear_hints = saveop->op_type != OP_ENTEREVAL;
    COP * const oldcurcop = PL_curcop;
    bool in_require = (saveop->op_type == OP_REQUIRE);
    int yystatus;
    CV *evalcv;

    PL_in_eval = (in_require
                  ? (EVAL_INREQUIRE | (PL_in_eval & EVAL_INEVAL))
                  : (EVAL_INEVAL |
                        ((PL_op->op_private & OPpEVAL_RE_REPARSING)
                            ? EVAL_RE_REPARSING : 0)));

    PUSHMARK(PL_stack_sp);

    evalcv = MUTABLE_CV(newSV_type(SVt_PVCV));
    CvEVAL_on(evalcv);
    assert(CxTYPE(CX_CUR()) == CXt_EVAL);
    CX_CUR()->blk_eval.cv = evalcv;
    CX_CUR()->blk_gimme = gimme;

    CvOUTSIDE_SEQ(evalcv) = seq;
    CvOUTSIDE(evalcv) = CvREFCNT_inc_simple(outside);

    /* set up a scratch pad */

    CvPADLIST_set(evalcv, pad_new(padnew_SAVE));
    PL_op = NULL; /* avoid PL_op and PL_curpad referring to different CVs */


    SAVEMORTALIZESV(evalcv);	/* must remain until end of current statement */

    /* make sure we compile in the right package */

    if (CopSTASH_ne(PL_curcop, PL_curstash)) {
        SAVEGENERICSV(PL_curstash);
        PL_curstash = (HV *)CopSTASH(PL_curcop);
        if (SvTYPE(PL_curstash) != SVt_PVHV) PL_curstash = NULL;
        else {
            SvREFCNT_inc_simple_void(PL_curstash);
            save_item(PL_curstname);
            sv_sethek(PL_curstname, HvNAME_HEK(PL_curstash));
        }
    }
    /* XXX:ajgo do we really need to alloc an AV for begin/checkunit */
    SAVESPTR(PL_beginav);
    PL_beginav = newAV();
    SAVEFREESV(PL_beginav);
    SAVESPTR(PL_unitcheckav);
    PL_unitcheckav = newAV();
    SAVEFREESV(PL_unitcheckav);


    ENTER_with_name("evalcomp");
    SAVESPTR(PL_compcv);
    PL_compcv = evalcv;

    /* try to compile it */

    PL_eval_root = NULL;
    PL_curcop = &PL_compiling;
    if ((saveop->op_type != OP_REQUIRE) && (saveop->op_flags & OPf_SPECIAL))
        PL_in_eval |= EVAL_KEEPERR;
    else
        CLEAR_ERRSV();

    SAVEHINTS();
    if (clear_hints) {
        PL_hints = HINTS_DEFAULT;
        PL_prevailing_version = 0;
        hv_clear(GvHV(PL_hintgv));
        CLEARFEATUREBITS();
    }
    else {
        PL_hints = saveop->op_private & OPpEVAL_COPHH
                     ? oldcurcop->cop_hints : (U32)saveop->op_targ;
        PL_prevailing_version = 0; /* we might change this below */

        /* making 'use re eval' not be in scope when compiling the
         * qr/mabye_has_runtime_code_block/ ensures that we don't get
         * infinite recursion when S_has_runtime_code() gives a false
         * positive: the second time round, HINT_RE_EVAL isn't set so we
         * don't bother calling S_has_runtime_code() */
        if (PL_in_eval & EVAL_RE_REPARSING)
            PL_hints &= ~HINT_RE_EVAL;

        if (hh) {
            /* SAVEHINTS created a new HV in PL_hintgv, which we need to GC */
            SvREFCNT_dec(GvHV(PL_hintgv));
            GvHV(PL_hintgv) = hh;
            FETCHFEATUREBITSHH(hh);
            /* temporarily turn magical flags off so we can delete without it getting in the way */
            const U32 wasflags = SvFLAGS(hh);
            SvMAGICAL_off(hh);

            SV *versv;
            /* hh is a new copy for us to use; we are permitted to delete keys */
            if((versv = hv_deletes(hh, "CORE/prevailing_version", 0)) && SvOK(versv)) {
                SAVEI16(PL_prevailing_version);
                PL_prevailing_version = SvUV(versv);
            }

            SvFLAGS(hh) = wasflags;
        }
    }
    SAVECOMPILEWARNINGS();
    if (clear_hints) {
        if (PL_dowarn & G_WARN_ALL_ON)
            PL_compiling.cop_warnings = pWARN_ALL ;
        else if (PL_dowarn & G_WARN_ALL_OFF)
            PL_compiling.cop_warnings = pWARN_NONE ;
        else
            PL_compiling.cop_warnings = pWARN_STD ;
    }
    else {
        PL_compiling.cop_warnings =
            DUP_WARNINGS(oldcurcop->cop_warnings);
        cophh_free(CopHINTHASH_get(&PL_compiling));
        if (cop_fetch_label(oldcurcop, NULL, NULL)) {
            /* The label, if present, is the first entry on the chain. So rather
               than writing a blank label in front of it (which involves an
               allocation), just use the next entry in the chain.  */
            PL_compiling.cop_hints_hash
                = cophh_copy(oldcurcop->cop_hints_hash->refcounted_he_next);
            /* Check the assumption that this removed the label.  */
            assert(cop_fetch_label(&PL_compiling, NULL, NULL) == NULL);
        }
        else
            PL_compiling.cop_hints_hash = cophh_copy(oldcurcop->cop_hints_hash);
    }

    CALL_BLOCK_HOOKS(bhk_eval, saveop);

    /* we should never be CATCH_GET true here, as our immediate callers should
     * always handle that case. */
    assert(!CATCH_GET);
    /* compile the code */


    yystatus = (!in_require)
               ? S_try_yyparse(aTHX_ GRAMPROG, saveop)
               : yyparse(GRAMPROG);

    if (yystatus || PL_parser->error_count || !PL_eval_root) {
        PERL_CONTEXT *cx;
        SV *errsv;

        PL_op = saveop;
        if (yystatus != 3) {
            /* note that if yystatus == 3, then the require/eval died during
             * compilation, so the EVAL CX block has already been popped, and
             * various vars restored. This block applies similar steps after
             * the other "failed to compile" cases in yyparse, eg, where
             * yystatus=1, "failed, but did not die". */

            if (!in_require)
                invoke_exception_hook(ERRSV,FALSE);

            op_free(PL_eval_root);
            PL_eval_root = NULL;

            rpp_popfree_to(PL_stack_base + POPMARK); /* pop original mark */
            cx = CX_CUR();
            assert(CxTYPE(cx) == CXt_EVAL);
            /* If we are in an eval we need to make sure that $SIG{__DIE__}
             * handler is invoked so we simulate that part of the
             * Perl_die_unwind() process. In a require we will croak
             * so it will happen there. */
            /* pop the CXt_EVAL, and if was a require, croak */
            S_pop_eval_context_maybe_croak(aTHX_ cx, ERRSV, 2);

        }

        /* die_unwind() re-croaks when in require, having popped the
         * require EVAL context. So we should never catch a require
         * exception here */
        assert(!in_require);

        errsv = ERRSV;
        if (!*(SvPV_nolen_const(errsv)))
            sv_setpvs(errsv, "Compilation error");

        if (gimme == G_SCALAR) {
            if (yystatus == 3) {
                /* die_unwind already pushed undef in scalar context */
                assert(*PL_stack_sp == &PL_sv_undef);
            }
            else {
                rpp_xpush_1(&PL_sv_undef);
            }
        }
        return FALSE;
    }

    /* Compilation successful. Now clean up */

    LEAVE_with_name("evalcomp");

    CopLINE_set(&PL_compiling, 0);
    SAVEFREEOP(PL_eval_root);
    cv_forget_slab(evalcv);

    DEBUG_x(dump_eval());

    /* Register with debugger: */
    if (PERLDB_INTER && saveop->op_type == OP_REQUIRE) {
        CV * const cv = get_cvs("DB::postponed", 0);
        if (cv) {
            PUSHMARK(PL_stack_sp);
            rpp_xpush_1(MUTABLE_SV(CopFILEGV(&PL_compiling)));
            call_sv(MUTABLE_SV(cv), G_DISCARD);
        }
    }

    if (PL_unitcheckav && av_count(PL_unitcheckav)>0) {
        OP *es = PL_eval_start;
        /* TODO: are we sure we shouldn't do S_try_run_unitcheck()
        * when `in_require` is true? */
        if (in_require) {
            call_list(PL_scopestack_ix, PL_unitcheckav);
        }
        else if (S_try_run_unitcheck(aTHX_ saveop)) {
            /* there was an error! */

            /* Restore PL_OP */
            PL_op = saveop;

            SV *errsv = ERRSV;
            if (!*(SvPV_nolen_const(errsv))) {
                /* This happens when using:
                 * eval qq# UNITCHECK { die "\x00"; } #;
                 */
                sv_setpvs(errsv, "Unit check error");
            }

            if (gimme != G_LIST)
                rpp_xpush_1(&PL_sv_undef);
            return FALSE;
        }
        PL_eval_start = es;
    }

    CvDEPTH(evalcv) = 1;
    rpp_popfree_to_NN(PL_stack_base + POPMARK); /* pop original mark */
    PL_op = saveop;			/* The caller may need it. */
    PL_parser->lex_state = LEX_NOTPARSING;	/* $^S needs this. */

    return TRUE;
}


/* Return NULL if the file doesn't exist or isn't a file;
 * else return PerlIO_openn().
 */

static PerlIO *
S_check_type_and_open(pTHX_ SV *name)
{
    PERL_ARGS_ASSERT_CHECK_TYPE_AND_OPEN;

    Stat_t st;
    STRLEN len;
    PerlIO * retio;
    const char *p = SvPV_const(name, len);
    int st_rc;

    /* checking here captures a reasonable error message when
     * PERL_DISABLE_PMC is true, but when PMC checks are enabled, the
     * user gets a confusing message about looking for the .pmc file
     * rather than for the .pm file so do the check in S_doopen_pm when
     * PMC is on instead of here. S_doopen_pm calls this func.
     * This check prevents a \0 in @INC causing problems.
     */
#ifdef PERL_DISABLE_PMC
    if (!IS_SAFE_PATHNAME(p, len, "require"))
        return NULL;
#endif

    /* on Win32 stat is expensive (it does an open() and close() twice and
       a couple other IO calls), the open will fail with a dir on its own with
       errno EACCES, so only do a stat to separate a dir from a real EACCES
       caused by user perms */
#ifndef WIN32
    st_rc = PerlLIO_stat(p, &st);

    if (st_rc < 0)
        return NULL;
    else {
        int eno;
        if(S_ISBLK(st.st_mode)) {
            eno = EINVAL;
            goto not_file;
        }
        else if(S_ISDIR(st.st_mode)) {
            eno = EISDIR;
            not_file:
            errno = eno;
            return NULL;
        }
    }
#endif

    retio = PerlIO_openn(aTHX_ ":", PERL_SCRIPT_MODE, -1, 0, 0, NULL, 1, &name);
#ifdef WIN32
    /* EACCES stops the INC search early in pp_require to implement
       feature RT #113422 */
    if(!retio && errno == EACCES) { /* exists but probably a directory */
        int eno;
        st_rc = PerlLIO_stat(p, &st);
        if (st_rc >= 0) {
            if(S_ISDIR(st.st_mode))
                eno = EISDIR;
            else if(S_ISBLK(st.st_mode))
                eno = EINVAL;
            else
                eno = EACCES;
            errno = eno;
        }
    }
#endif
    return retio;
}

/* doopen_pm(): return the equivalent of PerlIO_openn() on the given name,
 * but first check for bad names (\0) and non-files.
 * Also if the filename ends in .pm and unless PERL_DISABLE_PMC,
 * try loading Foo.pmc first.
 */
#ifndef PERL_DISABLE_PMC
static PerlIO *
S_doopen_pm(pTHX_ SV *name)
{
    PERL_ARGS_ASSERT_DOOPEN_PM;

    STRLEN namelen;
    const char *p = SvPV_const(name, namelen);

    /* check the name before trying for the .pmc name to avoid the
     * warning referring to the .pmc which the user probably doesn't
     * know or care about
     */
    if (!IS_SAFE_PATHNAME(p, namelen, "require"))
        return NULL;

    if (memENDPs(p, namelen, ".pm")) {
        SV *const pmcsv = sv_mortalcopy_flags(name, SV_GMAGIC|SV_NOSTEAL|SV_DO_COW_SVSETSV);

        sv_catpvs(pmcsv, "c");

        PerlIO * pmcio = check_type_and_open(pmcsv);
        if (pmcio)
            return pmcio;
    }
    return check_type_and_open(name);
}
#else
#  define doopen_pm(name) check_type_and_open(name)
#endif /* !PERL_DISABLE_PMC */

/* require doesn't search in @INC for absolute names, or when the name is
   explicitly relative the current directory: i.e. ./, ../ */
PERL_STATIC_INLINE bool
S_path_is_searchable(const char *name)
{
    PERL_ARGS_ASSERT_PATH_IS_SEARCHABLE;

    if (PERL_FILE_IS_ABSOLUTE(name)
#ifdef WIN32
        || (*name == '.' && ((name[1] == '/' ||
                             (name[1] == '.' && name[2] == '/'))
                         || (name[1] == '\\' ||
                             ( name[1] == '.' && name[2] == '\\')))
            )
#else
        || (*name == '.' && (name[1] == '/' ||
                             (name[1] == '.' && name[2] == '/')))
#endif
         )
    {
        return FALSE;
    }
    else
        return TRUE;
}


/* implement 'require 5.010001' */

static OP *
S_require_version(pTHX_ SV *sv)
{
    sv = sv_2mortal(new_version(sv));
    rpp_popfree_1_NN();

    if (!Perl_sv_derived_from_pvn(aTHX_ PL_patchlevel, STR_WITH_LEN("version"), 0))
        upg_version(PL_patchlevel, TRUE);
    if (cUNOP->op_first->op_type == OP_CONST && cUNOP->op_first->op_private & OPpCONST_NOVER) {
        if ( vcmp(sv,PL_patchlevel) <= 0 )
            DIE(aTHX_ "Perls since %" SVf " too modern--this is %" SVf ", stopped",
                SVfARG(sv_2mortal(vnormal(sv))),
                SVfARG(sv_2mortal(vnormal(PL_patchlevel)))
            );
    }
    else {
        if ( vcmp(sv,PL_patchlevel) > 0 ) {
            I32 first = 0;
            AV *lav;
            SV * const req = SvRV(sv);
            SV * const pv = *hv_fetchs(MUTABLE_HV(req), "original", FALSE);

            /* get the left hand term */
            lav = AV_FROM_REF(*hv_fetchs(MUTABLE_HV(req), "version", FALSE));

            first  = SvIV(*av_fetch(lav,0,0));
            if (   first > (int)PERL_REVISION    /* probably 'use 6.0' */
                || hv_exists(MUTABLE_HV(req), "qv", 2 ) /* qv style */
                || av_count(lav) > 2             /* FP with > 3 digits */
                || strstr(SvPVX(pv),".0")        /* FP with leading 0 */
               ) {
                DIE(aTHX_ "Perl %" SVf " required--this is only "
                    "%" SVf ", stopped",
                    SVfARG(sv_2mortal(vnormal(req))),
                    SVfARG(sv_2mortal(vnormal(PL_patchlevel)))
                );
            }
            else { /* probably 'use 5.10' or 'use 5.8' */
                SV *hintsv;
                I32 second = 0;

                if (av_count(lav) > 1)
                    second = SvIV(*av_fetch(lav,1,0));

                second /= second >= 600  ? 100 : 10;
                hintsv = newSVpvf("v%d.%d.0", (int)first, (int)second);
                upg_version(hintsv, TRUE);

                DIE(aTHX_ "Perl %" SVf " required (did you mean %" SVf "?)"
                    "--this is only %" SVf ", stopped",
                    SVfARG(sv_2mortal(vnormal(req))),
                    SVfARG(sv_2mortal(vnormal(sv_2mortal(hintsv)))),
                    SVfARG(sv_2mortal(vnormal(PL_patchlevel)))
                );
            }
        }
    }

    rpp_push_IMM(&PL_sv_yes);
    return NORMAL;
}


/* Handle C<require Foo::Bar>, C<require "Foo/Bar.pm"> and C<do "Foo.pm">.
 * The first form will have already been converted at compile time to
 * the second form.
 * sv is still on the stack at this point. */

static OP *
S_require_file(pTHX_ SV *sv)
{
    PERL_CONTEXT *cx;
    const char *name;
    STRLEN len;
    char * unixname;
    STRLEN unixlen;
#ifdef VMS
    int vms_unixname = 0;
    char *unixdir;
#endif
    /* tryname is the actual pathname (with @INC prefix) which was loaded.
     * It's stored as a value in %INC, and used for error messages */
    const char *tryname = NULL;
    SV *namesv = NULL; /* SV equivalent of tryname */
    const U8 gimme = GIMME_V;
    int filter_has_file = 0;
    PerlIO *tryrsfp = NULL;
    SV *filter_cache = NULL;
    SV *filter_state = NULL;
    SV *filter_sub = NULL;
    SV *hook_sv = NULL;
    OP *op;
    int saved_errno;
    bool path_searchable;
    I32 old_savestack_ix;
    const bool op_is_require = PL_op->op_type == OP_REQUIRE;
    const char *const op_name = op_is_require ? "require" : "do";
    SV ** svp_cached = NULL;

    assert(op_is_require || PL_op->op_type == OP_DOFILE);

    if (!SvOK(sv))
        DIE(aTHX_ "Missing or undefined argument to %s", op_name);
    name = SvPV_nomg_const(sv, len);
    if (!(name && len > 0 && *name))
        DIE(aTHX_ "Missing or undefined argument to %s", op_name);

    if (
        PL_hook__require__before
        && SvROK(PL_hook__require__before)
        && SvTYPE(SvRV(PL_hook__require__before)) == SVt_PVCV
    ) {
        SV* name_sv = sv_mortalcopy(sv);
        SV *post_hook__require__before_sv = NULL;

        ENTER_with_name("call_PRE_REQUIRE");
        SAVETMPS;
        PUSHMARK(PL_stack_sp);
        rpp_xpush_1(name_sv); /* always use the object for method calls */
        call_sv(PL_hook__require__before, G_SCALAR);
        SV *rsv = *PL_stack_sp;
        if (SvOK(rsv) && SvROK(rsv) && SvTYPE(SvRV(rsv)) == SVt_PVCV) {
            /* the RC++ preserves it across the popping and/or FREETMPS
             * below */
            post_hook__require__before_sv = SvREFCNT_inc_simple_NN(rsv);
            rpp_popfree_1_NN();
        }
        if (!sv_streq(name_sv,sv)) {
            /* they modified the name argument, so do some sleight of hand */
            name = SvPV_nomg_const(name_sv, len);
            if (!(name && len > 0 && *name))
                DIE(aTHX_ "Missing or undefined argument to %s via %%{^HOOK}{require__before}",
                        op_name);
            sv = name_sv;
        }
        FREETMPS;
        LEAVE_with_name("call_PRE_REQUIRE");
        if (post_hook__require__before_sv) {
            SV *nsv = newSVsv(sv);
            MORTALDESTRUCTOR_SV(post_hook__require__before_sv, nsv);
            SvREFCNT_dec_NN(nsv);
            SvREFCNT_dec_NN(post_hook__require__before_sv);
        }
    }
    if (
        PL_hook__require__after
        && SvROK(PL_hook__require__after)
        && SvTYPE(SvRV(PL_hook__require__after)) == SVt_PVCV
    ) {
        SV *nsv = newSVsv(sv);
        MORTALDESTRUCTOR_SV(PL_hook__require__after, nsv);
        SvREFCNT_dec_NN(nsv);
    }

#ifndef VMS
        /* try to return earlier (save the SAFE_PATHNAME check) if INC already got the name */
        if (op_is_require) {
                /* can optimize to only perform one single lookup */
                svp_cached = hv_fetch(GvHVn(PL_incgv), (char*) name, len, 0);
                if (svp_cached &&
                    (SvGETMAGIC(*svp_cached), SvOK(*svp_cached)))
                {
                    rpp_replace_1_IMM_NN(&PL_sv_yes);
                    return NORMAL;
                }
        }
#endif

    if (!IS_SAFE_PATHNAME(name, len, op_name)) {
        if (!op_is_require) {
            CLEAR_ERRSV();
            rpp_replace_1_IMM_NN(&PL_sv_undef);
            return NORMAL;
        }
        DIE(aTHX_ "Can't locate %s:   %s",
            pv_escape(newSVpvs_flags("",SVs_TEMP),name,len,len*2,
                      NULL, SvUTF8(sv)?PERL_PV_ESCAPE_UNI:0),
            Strerror(ENOENT));
    }
    TAINT_PROPER(op_name);

    path_searchable = path_is_searchable(name);

#ifdef VMS
    /* The key in the %ENV hash is in the syntax of file passed as the argument
     * usually this is in UNIX format, but sometimes in VMS format, which
     * can result in a module being pulled in more than once.
     * To prevent this, the key must be stored in UNIX format if the VMS
     * name can be translated to UNIX.
     */
    
    if ((unixname =
          tounixspec(name, SvPVX(sv_2mortal(newSVpv("", VMS_MAXRSS-1)))))
         != NULL) {
        unixlen = strlen(unixname);
        vms_unixname = 1;
    }
    else
#endif
    {
        /* if not VMS or VMS name can not be translated to UNIX, pass it
         * through.
         */
        unixname = (char *) name;
        unixlen = len;
    }
    if (op_is_require) {
        /* reuse the previous hv_fetch result if possible */
        SV * const * const svp = svp_cached ? svp_cached : hv_fetch(GvHVn(PL_incgv), unixname, unixlen, 0);
        if ( svp ) {
            /* we already did a get magic if this was cached */
            if (!svp_cached)
                SvGETMAGIC(*svp);
            if (SvOK(*svp)) {
                rpp_replace_1_IMM_NN(&PL_sv_yes);
                return NORMAL;
            }
            else
                DIE(aTHX_ "Attempt to reload %s aborted.\n"
                            "Compilation failed in require", unixname);
        }

        /*XXX OPf_KIDS should always be true? -dapm 4/2017 */
        if (PL_op->op_flags & OPf_KIDS) {
            SVOP * const kid = cSVOPx(cUNOP->op_first);

            if (kid->op_type == OP_CONST && (kid->op_private & OPpCONST_BARE)) {
                /* Make sure that a bareword module name (e.g. ::Foo::Bar)
                 * doesn't map to a naughty pathname like /Foo/Bar.pm.
                 * Note that the parser will normally detect such errors
                 * at compile time before we reach here, but
                 * Perl_load_module() can fake up an identical optree
                 * without going near the parser, and being able to put
                 * anything as the bareword. So we include a duplicate set
                 * of checks here at runtime.
                 */
                const STRLEN package_len = len - 3;
                static const char slashdot[2] = {'/', '.'};
#ifdef DOSISH
                static const char backslashdot[2] = {'\\', '.'};
#endif

                /* Disallow *purported* barewords that map to absolute
                   filenames, filenames relative to the current or parent
                   directory, or (*nix) hidden filenames.  Also sanity check
                   that the generated filename ends .pm  */
                if (!path_searchable || len < 3 || name[0] == '.'
                    || !memEQs(name + package_len, len - package_len, ".pm"))
                    DIE(aTHX_ "Bareword in require maps to disallowed filename \"%" SVf "\"", sv);
                if (memchr(name, 0, package_len)) {
                    /* diag_listed_as: Bareword in require contains "%s" */
                    DIE(aTHX_ "Bareword in require contains \"\\0\"");
                }
                if (ninstr(name, name + package_len, slashdot,
                           slashdot + sizeof(slashdot))) {
                    /* diag_listed_as: Bareword in require contains "%s" */
                    DIE(aTHX_ "Bareword in require contains \"/.\"");
                }
#ifdef DOSISH
                if (ninstr(name, name + package_len, backslashdot,
                           backslashdot + sizeof(backslashdot))) {
                    /* diag_listed_as: Bareword in require contains "%s" */
                    DIE(aTHX_ "Bareword in require contains \"\\.\"");
                }
#endif
            }
        }
    }

    PERL_DTRACE_PROBE_FILE_LOADING(unixname);

    /* Try to locate and open a file, possibly using @INC  */

    /* with "/foo/bar.pm", "./foo.pm" and "../foo/bar.pm", try to load
     * the file directly rather than via @INC ... */
    if (!path_searchable) {
        /* At this point, name is SvPVX(sv)  */
        tryname = name;
        tryrsfp = doopen_pm(sv);
    }

    /* ... but if we fail, still search @INC for code references;
     * these are applied even on non-searchable paths (except
     * if we got EACESS).
     *
     * For searchable paths, just search @INC normally
     */
    AV *inc_checked = (AV*)sv_2mortal((SV*)newAV());
    if (!tryrsfp && !(errno == EACCES && !path_searchable)) {
        SSize_t inc_idx;
#ifdef VMS
        if (vms_unixname)
#endif
        {
            AV *incdir_av = (AV*)sv_2mortal((SV*)newAV());
            SV *nsv = sv; /* non const copy we can change if necessary */
            namesv = newSV_type(SVt_PV);
            AV *inc_ar = GvAVn(PL_incgv);
            SSize_t incdir_continue_inc_idx = -1;

            for (
                inc_idx = 0;
                (AvFILL(incdir_av)>=0 /* we have INCDIR items pending */
                    || inc_idx <= AvFILL(inc_ar));  /* @INC entries remain */
                inc_idx++
            ) {
                SV *dirsv;

                /* do we have any pending INCDIR items? */
                if (AvFILL(incdir_av)>=0) {
                    /* yep, shift it out */
                    dirsv = av_shift(incdir_av);
                    if (AvFILL(incdir_av)<0) {
                        /* incdir is now empty, continue from where
                         * we left off after we process this entry  */
                        inc_idx = incdir_continue_inc_idx;
                    }
                } else {
                    dirsv = *av_fetch(inc_ar, inc_idx, TRUE);
                }

                if (SvGMAGICAL(dirsv)) {
                    SvGETMAGIC(dirsv);
                    dirsv = newSVsv_nomg(dirsv);
                } else {
                    /* on the other hand, since we aren't copying we do need
                     * to increment */
                    SvREFCNT_inc(dirsv);
                }
                if (!SvOK(dirsv))
                    continue;

                av_push(inc_checked, dirsv);

                if (SvROK(dirsv)) {
                    int count;
                    SV **svp;
                    SV *loader = dirsv;
                    UV diruv = PTR2UV(SvRV(dirsv));

                    if (SvTYPE(SvRV(loader)) == SVt_PVAV
                        && !SvOBJECT(SvRV(loader)))
                    {
                        loader = *av_fetch(AV_FROM_REF(loader), 0, TRUE);
                        if (SvGMAGICAL(loader)) {
                            SvGETMAGIC(loader);
                            SV *l = sv_mortalcopy_flags(loader, SV_DO_COW_SVSETSV);
                            loader = l;
                        }
                    }

                    if (SvPADTMP(nsv)) {
                        nsv = sv_mortalcopy_flags(sv, SV_GMAGIC|SV_NOSTEAL|SV_DO_COW_SVSETSV);
                    }

                    const char *method = NULL;
                    bool is_incdir = FALSE;
                    SV * inc_idx_sv = save_scalar(PL_incgv);
                    sv_setiv(inc_idx_sv,inc_idx);
                    if (sv_isobject(loader)) {
                        /* if it is an object and it has an INC method, then
                         * call the method.
                         */
                        HV *pkg = SvSTASH(SvRV(loader));
                        GV * gv = gv_fetchmethod_pvn_flags(pkg, "INC", 3, GV_AUTOLOAD);
                        if (gv && isGV(gv)) {
                            method = "INC";
                        } else {
                            /* no point to autoload here, it would have been found above */
                            gv = gv_fetchmethod_pvn_flags(pkg, "INCDIR", 6, 0);
                            if (gv && isGV(gv)) {
                                method = "INCDIR";
                                is_incdir = TRUE;
                            }
                        }
                        /* But if we have no method, check if this is a
                         * coderef, if it is then we treat it as an
                         * unblessed coderef would be treated: we
                         * execute it. If it is some other and it is in
                         * an array ref wrapper, then really we don't
                         * know what to do with it, (why use the
                         * wrapper?) and we throw an exception to help
                         * debug. If it is not in a wrapper assume it
                         * has an overload and treat it as a string.
                         * Maybe in the future we can detect if it does
                         * have overloading and throw an error if not.
                         */
                        if (!method) {
                            if (SvTYPE(SvRV(loader)) != SVt_PVCV) {
                                if (amagic_applies(loader,string_amg,AMGf_unary))
                                    goto treat_as_string;
                                else {
                                    croak("Can't locate object method \"INC\", nor"
                                          " \"INCDIR\" nor string overload via"
                                          " package %" HvNAMEf_QUOTEDPREFIX " %s"
                                          " in @INC", pkg,
                                          dirsv == loader
                                          ? "in object hook"
                                          : "in object in ARRAY hook"
                                    );
                                }
                            }
                        }
                    }

                    sv_setpvf(namesv, "/loader/0x%" UVxf "/%s",
                                   diruv, name);
                    tryname = SvPVX_const(namesv);
                    tryrsfp = NULL;

                    ENTER_with_name("call_INC_hook");
                    SAVETMPS;
                    PUSHMARK(PL_stack_sp);
                    /* add the args array for method calls */
                    bool add_dirsv = (method && (loader != dirsv));
                    rpp_extend(2 + add_dirsv);
                    rpp_push_2(
                        /* always use the object for method calls */
                        method ? loader : dirsv,
                        nsv
                    );
                    if (add_dirsv)
                        rpp_push_1(dirsv);
                    if (method) {
                        count = call_method(method, G_LIST|G_EVAL);
                    } else {
                        count = call_sv(loader, G_LIST|G_EVAL);
                    }

                    if (count > 0) {
                        int i = 0;
                        SV *arg;
                        SV **base = PL_stack_sp - count + 1;

                        if (is_incdir) {
                            /* push the stringified returned items into the
                             * incdir_av array for processing immediately
                             * afterwards. we deliberately stringify or copy
                             * "special" arguments, so that overload logic for
                             * instance applies, but so that the end result is
                             * stable. We speficially do *not* support returning
                             * coderefs from an INCDIR call. */
                            while (count-->0) {
                                arg = base[i++];
                                SvGETMAGIC(arg);
                                if (!SvOK(arg))
                                    continue;
                                if (SvROK(arg)) {
                                    STRLEN l;
                                    char *pv = SvPV(arg,l);
                                    arg = newSVpvn(pv,l);
                                }
                                else if (SvGMAGICAL(arg)) {
                                    arg = newSVsv_nomg(arg);
                                }
                                else {
                                    SvREFCNT_inc(arg);
                                }
                                av_push(incdir_av, arg);
                            }
                            /* We copy $INC into incdir_continue_inc_idx
                             * so that when we finish processing the items
                             * we just inserted into incdir_av we can continue
                             * as though we had just finished executing the INCDIR
                             * hook. We honour $INC here just like we would for
                             * an INC hook, the hook might have rewritten @INC
                             * at the same time as returning something to us.
                             */
                            inc_idx_sv = GvSVn(PL_incgv);
                            incdir_continue_inc_idx = SvOK(inc_idx_sv)
                                                      ? SvIV(inc_idx_sv) : -1;

                            goto done_hook;
                        }

                        arg = base[i++];

                        if (SvROK(arg) && (SvTYPE(SvRV(arg)) <= SVt_PVLV)
                            && !isGV_with_GP(SvRV(arg))) {
                            filter_cache = SvRV(arg);

                            if (i < count) {
                                arg = base[i++];
                            }
                        }

                        if (SvROK(arg) && isGV_with_GP(SvRV(arg))) {
                            arg = SvRV(arg);
                        }

                        if (isGV_with_GP(arg)) {
                            IO * const io = GvIO((const GV *)arg);

                            ++filter_has_file;

                            if (io) {
                                tryrsfp = IoIFP(io);
                                if (IoOFP(io) && IoOFP(io) != IoIFP(io)) {
                                    PerlIO_close(IoOFP(io));
                                }
                                IoIFP(io) = NULL;
                                IoOFP(io) = NULL;
                            }

                            if (i < count) {
                                arg = base[i++];
                            }
                        }

                        if (SvROK(arg) && SvTYPE(SvRV(arg)) == SVt_PVCV) {
                            filter_sub = arg;
                            SvREFCNT_inc_simple_void_NN(filter_sub);

                            if (i < count) {
                                filter_state = base[i];
                                SvREFCNT_inc_simple_void(filter_state);
                            }
                        }

                        if (!tryrsfp && (filter_cache || filter_sub)) {
                            tryrsfp = PerlIO_open(BIT_BUCKET,
                                                  PERL_SCRIPT_MODE);
                        }
                      done_hook:
                        rpp_popfree_to_NN(base - 1);
                    } else {
                        SV *errsv= ERRSV;
                        if (SvTRUE(errsv) && !SvROK(errsv)) {
                            STRLEN l;
                            char *pv= SvPV(errsv,l);
                            /* Heuristic to tell if this error message
                             * includes the standard line number info:
                             * check if the line ends in digit dot newline.
                             * If it does then we add some extra info so
                             * its obvious this is coming from a hook.
                             * If it is a user generated error we try to
                             * leave it alone. l>12 is to ensure the
                             * other checks are in string, but also
                             * accounts for "at ... line 1.\n" to a
                             * certain extent. Really we should check
                             * further, but this is good enough for back
                             * compat I think.
                             */
                            if (l>=12 && pv[l-1] == '\n' && pv[l-2] == '.' && isDIGIT(pv[l-3]))
                                sv_catpvf(errsv, "%s %s hook died--halting @INC search",
                                          method ? method : "INC",
                                          method ? "method" : "sub");
                            croak_sv(errsv);
                        }
                    }

                    /* FREETMPS may free our filter_cache */
                    SvREFCNT_inc_simple_void(filter_cache);

                    /*
                     Let the hook override which @INC entry we visit
                     next by setting $INC to a different value than it
                     was before we called the hook. If they have
                     completely rewritten the array they might want us
                     to start traversing from the beginning, which is
                     represented by -1. We use undef as an equivalent of
                     -1. This can't be used as a way to call a hook
                     twice, as we still dedupe.
                     We have to do this before we LEAVE, as we localized
                     $INC before we called the hook.
                    */
                    inc_idx_sv = GvSVn(PL_incgv);
                    inc_idx = SvOK(inc_idx_sv) ? SvIV(inc_idx_sv) : -1;

                    FREETMPS;
                    LEAVE_with_name("call_INC_hook");

                    /*
                     It is possible that @INC has been replaced and that inc_ar
                     now points at a freed AV. So we have to refresh it from
                     the GV to be sure.
                    */
                    inc_ar = GvAVn(PL_incgv);

                    /* Now re-mortalize it. */
                    sv_2mortal(filter_cache);

                    /* Adjust file name if the hook has set an %INC entry.
                       This needs to happen after the FREETMPS above.  */
                    svp = hv_fetch(GvHVn(PL_incgv), name, len, 0);
                    /* we have to make sure that the value is not undef
                     * or the empty string, if it is then we should not
                     * set tryname to it as this will break error messages.
                     *
                     * This might happen if an @INC hook evals the module
                     * which was required in the first place and which
                     * triggered the @INC hook, and that eval dies.
                     * See https://github.com/Perl/perl5/issues/20535
                     */
                    if (svp && SvOK(*svp)) {
                        STRLEN len;
                        const char *tmp_pv = SvPV_const(*svp,len);
                        /* we also guard against the deliberate empty string.
                         * We do not guard against '0', if people want to set their
                         * file name to 0 that is up to them. */
                        if (len)
                            tryname = tmp_pv;
                    }

                    if (tryrsfp) {
                        hook_sv = dirsv;
                        break;
                    }

                    filter_has_file = 0;
                    filter_cache = NULL;
                    if (filter_state) {
                        SvREFCNT_dec_NN(filter_state);
                        filter_state = NULL;
                    }
                    if (filter_sub) {
                        SvREFCNT_dec_NN(filter_sub);
                        filter_sub = NULL;
                    }
                }
                else
                    treat_as_string:
                    if (path_searchable) {
                    /* match against a plain @INC element (non-searchable
                     * paths are only matched against refs in @INC) */
                    const char *dir;
                    STRLEN dirlen;
                    if (SvOK(dirsv)) {
                        dir = SvPV_nomg_const(dirsv, dirlen);
                    } else {
                        dir = "";
                        dirlen = 0;
                    }

                    if (!IS_SAFE_SYSCALL(dir, dirlen, "@INC entry", op_name))
                        continue;
#ifdef VMS
                    if ((unixdir =
                          tounixpath(dir, SvPVX(sv_2mortal(newSVpv("", VMS_MAXRSS-1)))))
                         == NULL)
                        continue;
                    sv_setpv(namesv, unixdir);
                    sv_catpv(namesv, unixname);
#else
                    /* The equivalent of		    
                       sv_setpvf(namesv, "%s/%s", dir, name);
                       but without the need to parse the format string, or
                       call strlen on either pointer, and with the correct
                       allocation up front.  */
                    {
                        char *tmp = SvGROW(namesv, dirlen + len + 2);

                        memcpy(tmp, dir, dirlen);
                        tmp +=dirlen;

                        /* Avoid '<dir>//<file>' */
                        if (!dirlen || *(tmp-1) != '/') {
                            *tmp++ = '/';
                        } else {
                            /* So SvCUR_set reports the correct length below */
                            dirlen--;
                        }

                        /* name came from an SV, so it will have a '\0' at the
                           end that we can copy as part of this memcpy().  */
                        memcpy(tmp, name, len + 1);

                        SvCUR_set(namesv, dirlen + len + 1);
                        SvPOK_on(namesv);
                    }
#endif
                    TAINT_PROPER(op_name);
                    tryname = SvPVX_const(namesv);
                    tryrsfp = doopen_pm(namesv);
                    if (tryrsfp) {
                        if (tryname[0] == '.' && tryname[1] == '/') {
                            ++tryname;
                            while (*++tryname == '/') {}
                        }
                        break;
                    }
                    else if (errno == EMFILE || errno == EACCES) {
                        /* no point in trying other paths if out of handles;
                         * on the other hand, if we couldn't open one of the
                         * files, then going on with the search could lead to
                         * unexpected results; see perl #113422
                         */
                        break;
                    }
                }
            }
        }
    }

    /* at this point we've ether opened a file (tryrsfp) or set errno */

    saved_errno = errno; /* sv_2mortal can realloc things */
    sv_2mortal(namesv);
    if (!tryrsfp) {
        /* we failed; croak if require() or return undef if do() */
        if (op_is_require) {
            if(saved_errno == EMFILE || saved_errno == EACCES) {
                /* diag_listed_as: Can't locate %s */
                DIE(aTHX_ "Can't locate %s:   %s: %s",
                    name, tryname, Strerror(saved_errno));
            } else {
                if (path_searchable) {          /* did we lookup @INC? */
                    SSize_t i;
                    SV *const msg = newSVpvs_flags("", SVs_TEMP);
                    SV *const inc = newSVpvs_flags("", SVs_TEMP);
                    for (i = 0; i <= AvFILL(inc_checked); i++) {
                        SV **svp= av_fetch(inc_checked, i, TRUE);
                        if (!svp || !*svp) continue;
                        sv_catpvs(inc, " ");
                        sv_catsv(inc, *svp);
                    }
                    if (memENDPs(name, len, ".pm")) {
                        const char *e = name + len - (sizeof(".pm") - 1);
                        const char *c;
                        bool utf8 = cBOOL(SvUTF8(sv));

                        /* if the filename, when converted from "Foo/Bar.pm"
                         * form back to Foo::Bar form, makes a valid
                         * package name (i.e. parseable by C<require
                         * Foo::Bar>), then emit a hint.
                         *
                         * this loop is modelled after the one in
                         S_parse_ident */
                        c = name;
                        while (c < e) {
                            Size_t advance;

                            if (utf8 && (advance = isIDFIRST_utf8_safe(c, e)))
                            {
                                c += advance;
                                while (   c < e
                                       && (advance = isIDCONT_utf8_safe(
                                                (const U8*) c, (const U8*) e)))
                                {
                                    c += advance;
                                }
                            }
                            else if (isWORDCHAR_A(*c)) {
                                while (c < e && isWORDCHAR_A(*c))
                                    c++;
                            }
                            else if (*c == '/')
                                c++;
                            else
                                break;
                        }

                        if (c == e && isIDFIRST_lazy_if_safe(name, e, utf8)) {
                            sv_catpvs(msg, " (you may need to install the ");
                            for (c = name; c < e; c++) {
                                if (*c == '/') {
                                    sv_catpvs(msg, "::");
                                }
                                else {
                                    sv_catpvn(msg, c, 1);
                                }
                            }
                            sv_catpvs(msg, " module)");
                        }
                    }
                    else if (memENDs(name, len, ".h")) {
                        sv_catpvs(msg, " (change .h to .ph maybe?) (did you run h2ph?)");
                    }
                    else if (memENDs(name, len, ".ph")) {
                        sv_catpvs(msg, " (did you run h2ph?)");
                    }

                    /* diag_listed_as: Can't locate %s */
                    DIE(aTHX_
                        "Can't locate %s in @INC%" SVf " (@INC entries checked:%" SVf ")",
                        name, msg, inc);
                }
            }
            DIE(aTHX_ "Can't locate %s", name);
        }
        else {
#ifdef DEFAULT_INC_EXCLUDES_DOT
            Stat_t st;
            PerlIO *io = NULL;
            dSAVE_ERRNO;
            /* the complication is to match the logic from doopen_pm() so
             * we don't treat do "sda1" as a previously successful "do".
            */
            bool do_warn = namesv && ckWARN_d(WARN_DEPRECATED__DOT_IN_INC)
                && PerlLIO_stat(name, &st) == 0 && !S_ISDIR(st.st_mode) && !S_ISBLK(st.st_mode)
                && (io = PerlIO_openn(aTHX_ ":", PERL_SCRIPT_MODE, -1, 0, 0, NULL, 1, &sv)) != NULL;
            if (io)
                PerlIO_close(io);

            RESTORE_ERRNO;
            if (do_warn) {
                warner(packWARN(WARN_DEPRECATED__DOT_IN_INC),
                       "do \"%s\" failed, '.' is no longer in @INC; "
                       "did you mean do \"./%s\"?",
                       name, name);
            }
#endif
            CLEAR_ERRSV();
            rpp_replace_1_IMM_NN(&PL_sv_undef);
            return NORMAL;
        }
    }
    else
        SETERRNO(0, SS_NORMAL);

    rpp_popfree_1_NN(); /* finished with sv now */

    /* Update %INC. Assume success here to prevent recursive requirement. */
    /* name is never assigned to again, so len is still strlen(name)  */
    /* Check whether a hook in @INC has already filled %INC */
    if (!hook_sv) {
        (void)hv_store(GvHVn(PL_incgv),
                       unixname, unixlen, newSVpv(tryname,0),0);
    } else {
        /* store the hook in the sv, note we have to *copy* hook_sv,
         * we don't want modifications to it to change @INC - see GH #20577
         */
        SV** const svp = hv_fetch(GvHVn(PL_incgv), unixname, unixlen, 0);
        if (!svp)
            (void)hv_store(GvHVn(PL_incgv),
                           unixname, unixlen, newSVsv(hook_sv), 0 );
    }

    /* Now parse the file */

    old_savestack_ix = PL_savestack_ix;
    SAVECOPFILE_FREE(&PL_compiling);
    CopFILE_set(&PL_compiling, tryname);
    lex_start(NULL, tryrsfp, 0);

    if (filter_sub || filter_cache) {
        /* We can use the SvPV of the filter PVIO itself as our cache, rather
           than hanging another SV from it. In turn, filter_add() optionally
           takes the SV to use as the filter (or creates a new SV if passed
           NULL), so simply pass in whatever value filter_cache has.  */
        SV * const fc = filter_cache ? newSV_type(SVt_NULL) : NULL;
        SV *datasv;
        if (fc) sv_copypv(fc, filter_cache);
        datasv = filter_add(S_run_user_filter, fc);
        IoLINES(datasv) = filter_has_file;
        IoTOP_GV(datasv) = MUTABLE_GV(filter_state);
        IoBOTTOM_GV(datasv) = MUTABLE_GV(filter_sub);
    }

    /* switch to eval mode */
    assert(!CATCH_GET);
    cx = cx_pushblock(CXt_EVAL, gimme, PL_stack_sp, old_savestack_ix);
    cx_pusheval(cx, PL_op->op_next, newSVpv(name, 0));

    SAVECOPLINE(&PL_compiling);
    CopLINE_set(&PL_compiling, 0);

    if (doeval_compile(gimme, NULL, PL_curcop->cop_seq, NULL))
        op = PL_eval_start;
    else
        op = PL_op->op_next;

    PERL_DTRACE_PROBE_FILE_LOADED(unixname);

    return op;
}


/* also used for: pp_dofile() */

PP(pp_require)
{
    /* If a suitable JMPENV catch frame isn't present, call docatch(),
     * which will:
     *   - add such a frame, and
     *   - start a new RUNOPS loop, which will (as the first op to run),
     *     recursively call this pp function again.
     * The main body of this function is then executed by the inner call.
     */
    if (CATCH_GET)
        return docatch(Perl_pp_require);

    {
        SV *sv = *PL_stack_sp;
        SvGETMAGIC(sv);
        /* these tail-called subs are responsible for popping sv off the
         * stack */
        return ((SvNIOKp(sv) || SvVOK(sv)) && PL_op->op_type != OP_DOFILE)
            ? S_require_version(aTHX_ sv)
            : S_require_file(aTHX_ sv);
    }
}


/* This is a op added to hold the hints hash for
   pp_entereval. The hash can be modified by the code
   being eval'ed, so we return a copy instead. */

PP(pp_hintseval)
{
    rpp_extend(1);
    rpp_push_1_norc(MUTABLE_SV(hv_copy_hints_hv(MUTABLE_HV(cSVOP_sv))));
    return NORMAL;
}


PP(pp_entereval)
{
    PERL_CONTEXT *cx;
    SV *sv;
    U8 gimme;
    U32 was;
    char tbuf[TYPE_DIGITS(long) + 12];
    bool saved_delete;
    char *tmpbuf;
    STRLEN len;
    CV* runcv;
    U32 seq, lex_flags;
    HV *saved_hh;
    bool bytes;
    I32 old_savestack_ix;

    /* If a suitable JMPENV catch frame isn't present, call docatch(),
     * which will:
     *   - add such a frame, and
     *   - start a new RUNOPS loop, which will (as the first op to run),
     *     recursively call this pp function again.
     * The main body of this function is then executed by the inner call.
     */
    if (CATCH_GET)
        return docatch(Perl_pp_entereval);

    assert(!CATCH_GET);

    gimme = GIMME_V;
    was = PL_breakable_sub_gen;
    saved_delete = FALSE;
    tmpbuf = tbuf;
    lex_flags = 0;
    saved_hh = NULL;
    bytes = PL_op->op_private & OPpEVAL_BYTES;

    if (PL_op->op_private & OPpEVAL_HAS_HH) {
        saved_hh = MUTABLE_HV(rpp_pop_1_norc());
    }
    else if (PL_hints & HINT_LOCALIZE_HH || (
                PL_op->op_private & OPpEVAL_COPHH
             && PL_curcop->cop_hints & HINT_LOCALIZE_HH
            )) {
        saved_hh = cop_hints_2hv(PL_curcop, 0);
        hv_magic(saved_hh, NULL, PERL_MAGIC_hints);
    }
    sv = *PL_stack_sp;
    if (!SvPOK(sv)) {
        /* make sure we've got a plain PV (no overload etc) before testing
         * for taint. Making a copy here is probably overkill, but better
         * safe than sorry */
        STRLEN len;
        const char * const p = SvPV_const(sv, len);

        sv = newSVpvn_flags(p, len, SVs_TEMP | SvUTF8(sv));
        lex_flags |= LEX_START_COPIED;

        if (bytes && SvUTF8(sv))
            SvPVbyte_force(sv, len);
    }
    else if (bytes && SvUTF8(sv)) {
        /* Don't modify someone else's scalar */
        STRLEN len;
        sv = newSVsv(sv);
        (void)sv_2mortal(sv);
        SvPVbyte_force(sv,len);
        lex_flags |= LEX_START_COPIED;
    }

    TAINT_IF_SV(sv);
    TAINT_PROPER("eval");

    old_savestack_ix = PL_savestack_ix;

    lex_start(sv, NULL, lex_flags | (PL_op->op_private & OPpEVAL_UNICODE
                           ? LEX_IGNORE_UTF8_HINTS
                           : bytes ? LEX_EVALBYTES : LEX_START_SAME_FILTER
                        )
             );

    rpp_popfree_1_NN(); /* can free sv now */

    /* switch to eval mode */

    if (PERLDB_NAMEEVAL && CopLINE(PL_curcop)) {
        SV * const temp_sv = sv_newmortal();
        sv_setpvf(temp_sv, "_<(eval %lu)[%s:%" LINE_Tf "]",
                       (unsigned long)++PL_evalseq,
                       CopFILE(PL_curcop), CopLINE(PL_curcop));
        tmpbuf = SvPVX(temp_sv);
        len = SvCUR(temp_sv);
    }
    else
        len = my_snprintf(tmpbuf, sizeof(tbuf), "_<(eval %lu)", (unsigned long)++PL_evalseq);
    SAVECOPFILE_FREE(&PL_compiling);
    CopFILE_set(&PL_compiling, tmpbuf+2);
    SAVECOPLINE(&PL_compiling);
    CopLINE_set(&PL_compiling, 1);
    /* special case: an eval '' executed within the DB package gets lexically
     * placed in the first non-DB CV rather than the current CV - this
     * allows the debugger to execute code, find lexicals etc, in the
     * scope of the code being debugged. Passing &seq gets find_runcv
     * to do the dirty work for us */
    runcv = find_runcv(&seq);

    assert(!CATCH_GET);
    cx = cx_pushblock((CXt_EVAL|CXp_REAL),
                        gimme, PL_stack_sp, old_savestack_ix);
    cx_pusheval(cx, PL_op->op_next, NULL);

    /* prepare to compile string */

    if (PERLDB_LINE_OR_SAVESRC && PL_curstash != PL_debstash)
        save_lines(CopFILEAV(&PL_compiling), PL_parser->linestr);
    else {
        /* XXX For C<eval "...">s within BEGIN {} blocks, this ends up
           deleting the eval's FILEGV from the stash before gv_check() runs
           (i.e. before run-time proper). To work around the coredump that
           ensues, we always turn GvMULTI_on for any globals that were
           introduced within evals. See force_ident(). GSAR 96-10-12 */
        char *const safestr = savepvn(tmpbuf, len);
        SAVEDELETE(PL_defstash, safestr, len);
        saved_delete = TRUE;
    }
    
    if (doeval_compile(gimme, runcv, seq, saved_hh)) {
        if (was != PL_breakable_sub_gen /* Some subs defined here. */
            ?  PERLDB_LINE_OR_SAVESRC
            :  PERLDB_SAVESRC_NOSUBS) {
            /* Retain the filegv we created.  */
        } else if (!saved_delete) {
            char *const safestr = savepvn(tmpbuf, len);
            SAVEDELETE(PL_defstash, safestr, len);
        }
        return PL_eval_start;
    } else {
        /* We have already left the scope set up earlier thanks to the LEAVE
           in doeval_compile().  */
        if (was != PL_breakable_sub_gen /* Some subs defined here. */
            ?  PERLDB_LINE_OR_SAVESRC
            :  PERLDB_SAVESRC_INVALID) {
            /* Retain the filegv we created.  */
        } else if (!saved_delete) {
            (void)hv_delete(PL_defstash, tmpbuf, len, G_DISCARD);
        }
        if (PL_op->op_private & OPpEVAL_EVALSV)
            /* signal compiletime failure to our eval_sv() caller */
            *++PL_stack_sp = NULL;
        return PL_op->op_next;
    }
}


/* also tail-called by pp_return */

PP(pp_leaveeval)
{
    SV **oldsp;
    U8 gimme;
    PERL_CONTEXT *cx;
    OP *retop;
    int failed;
    bool override_return = FALSE; /* is feature 'module_true' in effect? */
    CV *evalcv;
    bool keep;

    PERL_ASYNC_CHECK();

    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_EVAL);

    oldsp = PL_stack_base + cx->blk_oldsp;
    gimme = cx->blk_gimme;

    bool is_require= CxOLD_OP_TYPE(cx) == OP_REQUIRE;
    if (is_require) {
        /* We are in an require. Check if use feature 'module_true' is enabled,
         * and if so later on correct any returns from the require. */

        /* we might be called for an OP_LEAVEEVAL or OP_RETURN opcode
         * and the parse tree will look different for either case.
         * so find the right op to check later */
        if (OP_TYPE_IS_OR_WAS(PL_op, OP_RETURN)) {
            if (PL_op->op_flags & OPf_SPECIAL)
                override_return = true;
        }
        else if ((PL_op->op_flags & OPf_KIDS) && OP_TYPE_IS_OR_WAS(PL_op, OP_LEAVEEVAL)){
            COP *old_pl_curcop = PL_curcop;
            OP *check = cUNOPx(PL_op)->op_first;

            /* ok, we found something to check, we need to scan through
             * it and find the last OP_NEXTSTATE it contains and then read the
             * feature state out of the COP data it contains.
             */
            if (check) {
                if (!OP_TYPE_IS(check,OP_STUB)) {
                    const OP *kid = cLISTOPx(check)->op_first;
                    const OP *last_state = NULL;

                    for (; kid; kid = OpSIBLING(kid)) {
                        if (
                               OP_TYPE_IS_OR_WAS(kid, OP_NEXTSTATE)
                            || OP_TYPE_IS_OR_WAS(kid, OP_DBSTATE)
                        ){
                            last_state = kid;
                        }
                    }
                    if (last_state) {
                        PL_curcop = cCOPx(last_state);
                        if (FEATURE_MODULE_TRUE_IS_ENABLED) {
                            override_return = TRUE;
                        }
                    } else {
                        NOT_REACHED; /* NOTREACHED */
                    }
                }
            } else {
                NOT_REACHED; /* NOTREACHED */
            }
            PL_curcop = old_pl_curcop;
        }
    }

    /* we might override this later if 'module_true' is enabled */
    failed =    is_require
             && !(gimme == G_SCALAR
                    ? SvTRUE_NN(*PL_stack_sp)
                    : PL_stack_sp > oldsp);

    if (gimme == G_VOID) {
        rpp_popfree_to(oldsp);
        /* free now to avoid late-called destructors clobbering $@ */
        FREETMPS;
    }
    else
        leave_adjust_stacks(oldsp, oldsp, gimme, 0);

    /* the cx_popeval does a leavescope, which frees the optree associated
     * with eval, which if it frees the nextstate associated with
     * PL_curcop, sets PL_curcop to NULL. Which can mess up freeing a
     * regex when running under 'use re Debug' because it needs PL_curcop
     * to get the current hints. So restore it early.
     */
    PL_curcop = cx->blk_oldcop;

    /* grab this value before cx_popeval restores the old PL_in_eval */
    keep = cBOOL(PL_in_eval & EVAL_KEEPERR);
    retop = cx->blk_eval.retop;
    evalcv = cx->blk_eval.cv;
#ifdef DEBUGGING
    assert(CvDEPTH(evalcv) == 1);
#endif
    CvDEPTH(evalcv) = 0;

    if (override_return) {
        /* make sure that we use a standard return when feature 'module_load'
         * is enabled. Returns from require are problematic (consider what happens
         * when it is called twice) */
        if (gimme == G_SCALAR)
            rpp_replace_1_IMM_NN(&PL_sv_yes);
        assert(gimme == G_VOID || gimme == G_SCALAR);
        failed = 0;
    }

    /* pop the CXt_EVAL, and if a require failed, croak */
    S_pop_eval_context_maybe_croak(aTHX_ cx, NULL, failed);

    if (!keep)
        CLEAR_ERRSV();

    return retop;
}

/* Ops that implement try/catch syntax
 * Note the asymmetry here:
 *   pp_entertrycatch does two pushblocks
 *   pp_leavetrycatch pops only the outer one; the inner one is popped by
 *     pp_poptry or by stack-unwind of die within the try block
 */

PP(pp_entertrycatch)
{
    PERL_CONTEXT *cx;
    const U8 gimme = GIMME_V;

    /* If a suitable JMPENV catch frame isn't present, call docatch(),
     * which will:
     *   - add such a frame, and
     *   - start a new RUNOPS loop, which will (as the first op to run),
     *     recursively call this pp function again.
     * The main body of this function is then executed by the inner call.
     */
    if (CATCH_GET)
        return docatch(Perl_pp_entertrycatch);

    assert(!CATCH_GET);

    Perl_pp_enter(aTHX); /* performs cx_pushblock(CXt_BLOCK, ...) */

    save_scalar(PL_errgv);
    CLEAR_ERRSV();

    cx = cx_pushblock((CXt_EVAL|CXp_EVALBLOCK|CXp_TRY), gimme,
            PL_stack_sp, PL_savestack_ix);
    cx_pushtry(cx, cLOGOP->op_other);

    PL_in_eval = EVAL_INEVAL;

    return NORMAL;
}

PP(pp_leavetrycatch)
{
    /* leavetrycatch is leave */
    return Perl_pp_leave(aTHX);
}

PP(pp_poptry)
{
    /* poptry is leavetry */
    return Perl_pp_leavetry(aTHX);
}

PP(pp_catch)
{
    dTARGET;

    save_clearsv(&(PAD_SVl(PL_op->op_targ)));
    sv_setsv(TARG, ERRSV);
    CLEAR_ERRSV();

    return cLOGOP->op_other;
}

/* Common code for Perl_call_sv and Perl_fold_constants, put here to keep it
   close to the related Perl_create_eval_scope.  */
void
Perl_delete_eval_scope(pTHX)
{
    PERL_ARGS_ASSERT_DELETE_EVAL_SCOPE;

    PERL_CONTEXT *cx;
        
    cx = CX_CUR();
    CX_LEAVE_SCOPE(cx);
    cx_popeval(cx);
    cx_popblock(cx);
    CX_POP(cx);
}

/* Common-ish code salvaged from Perl_call_sv and pp_entertry, because it was
   also needed by Perl_fold_constants.  */
void
Perl_create_eval_scope(pTHX_ OP *retop, SV **sp, U32 flags)
{
    PERL_ARGS_ASSERT_CREATE_EVAL_SCOPE;

    PERL_CONTEXT *cx;
    const U8 gimme = GIMME_V;

    cx = cx_pushblock((CXt_EVAL|CXp_EVALBLOCK), gimme,
                    sp, PL_savestack_ix);
    cx_pusheval(cx, retop, NULL);

    PL_in_eval = EVAL_INEVAL;
    if (flags & G_KEEPERR)
        PL_in_eval |= EVAL_KEEPERR;
    else
        CLEAR_ERRSV();
    if (flags & G_FAKINGEVAL) {
        PL_eval_root = PL_op; /* Only needed so that goto works right. */
    }
}
    
PP(pp_entertry)
{
    OP *retop = cLOGOP->op_other->op_next;

    /* If a suitable JMPENV catch frame isn't present, call docatch(),
     * which will:
     *   - add such a frame, and
     *   - start a new RUNOPS loop, which will (as the first op to run),
     *     recursively call this pp function again.
     * The main body of this function is then executed by the inner call.
     */
    if (CATCH_GET)
        return docatch(Perl_pp_entertry);

    assert(!CATCH_GET);

    create_eval_scope(retop, PL_stack_sp, 0);

    return PL_op->op_next;
}


/* also tail-called by pp_return */

PP(pp_leavetry)
{
    SV **oldsp;
    U8 gimme;
    PERL_CONTEXT *cx;
    OP *retop;

    PERL_ASYNC_CHECK();

    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_EVAL);
    oldsp = PL_stack_base + cx->blk_oldsp;
    gimme = cx->blk_gimme;

    if (gimme == G_VOID) {
        rpp_popfree_to_NN(oldsp);
        /* free now to avoid late-called destructors clobbering $@ */
        FREETMPS;
    }
    else
        leave_adjust_stacks(oldsp, oldsp, gimme, 1);
    CX_LEAVE_SCOPE(cx);
    cx_popeval(cx);
    cx_popblock(cx);
    retop = CxTRY(cx) ? PL_op->op_next : cx->blk_eval.retop;
    CX_POP(cx);

    CLEAR_ERRSV();
    return retop;
}

PP(pp_entergiven)
{
    PERL_CONTEXT *cx;
    const U8 gimme = GIMME_V;
    SV *origsv = DEFSV;
    SV *subject = rpp_pop_1_norc();

    if (PL_op->op_targ) {
        SvGETMAGIC(subject);
        {
            SV *snapshot = newSV(0);
            sv_setsv_nomg(snapshot, subject);
            subject = snapshot;
        }
    }
    else
        assert(!PL_op->op_targ); /* used to be set for lexical $_ */
    GvSV(PL_defgv) = subject;

    cx = cx_pushblock(CXt_GIVEN, gimme, PL_stack_sp, PL_savestack_ix);
    cx_pushgiven(cx, origsv);
    cx->blk_givwhen.is_case = PL_op->op_targ != 0;

    return NORMAL;
}

PP(pp_enterdispatch)
{
    PERL_CONTEXT *cx;
    const U8 gimme = GIMME_V;
    SV * const origsv = DEFSV;
    /* The pop transfers ownership. Keep it exception-safe while fetching
     * magic and making the independent case snapshot. */
    SV *subject = sv_2mortal(rpp_pop_1_norc());
    const bool named_subject = PL_op->op_targ != 0;

    if (named_subject) {
        const OP *assignment = cLOGOPx(PL_op)->op_first;
        const OP *target;
        if (!assignment || assignment->op_type != OP_SASSIGN
            || !(assignment->op_flags & OPf_KIDS))
            Perl_croak(aTHX_ "dispatch named subject is not a scalar assignment");
        target = cUNOPx(assignment)->op_first;
        while (OpSIBLING(target))
            target = OpSIBLING(target);
        if (target->op_type != OP_PADSV && target->op_type != OP_PADSV_STORE)
            Perl_croak(aTHX_ "dispatch subject must be a scalar lexical");
        subject = PAD_SV(target->op_targ);
    }
    else {
        SvGETMAGIC(subject);
        SV *snapshot = newSV(0);
        sv_setsv_nomg(snapshot, subject);
        subject = snapshot;
        GvSV(PL_defgv) = subject;
    }

    cx = cx_pushblock(CXt_DISPATCH, gimme, PL_stack_sp, PL_savestack_ix);
    cx_pushdispatch(cx, origsv);
    cx->blk_dispatch.subject = subject;
    cx->blk_dispatch.localizes_defsv = !named_subject;
    return NORMAL;
}

PP(pp_leavegiven)
{
    PERL_CONTEXT *cx;
    U8 gimme;
    SV **oldsp;
    PERL_UNUSED_CONTEXT;

    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_GIVEN);
    oldsp = PL_stack_base + cx->blk_oldsp;
    gimme = cx->blk_gimme;

    if (gimme == G_VOID)
        rpp_popfree_to_NN(oldsp);
    else
        leave_adjust_stacks(oldsp, oldsp, gimme, 1);

    CX_LEAVE_SCOPE(cx);
    cx_popgiven(cx);
    cx_popblock(cx);
    CX_POP(cx);

    return NORMAL;
}

PP(pp_leavedispatch)
{
    PERL_CONTEXT *cx;
    U8 gimme;
    SV **oldsp;

    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_DISPATCH);
    oldsp = PL_stack_base + cx->blk_oldsp;
    gimme = cx->blk_gimme;

    if (gimme == G_VOID)
        rpp_popfree_to_NN(oldsp);
    else
        leave_adjust_stacks(oldsp, oldsp, gimme, 1);

    CX_LEAVE_SCOPE(cx);
    cx_popdispatch(cx);
    cx_popblock(cx);
    CX_POP(cx);
    return NORMAL;
}

struct dispatch_binding {
    PADOFFSET padix;
    SSize_t value_ix;
    U8 kind;
    bool clear_on_exit;
};

static PERL_CONTEXT *S_dispatch_context(pTHX);
static SV *S_dispatch_subject(pTHX);

struct dispatch_capture_owner {
    AV *values;
    size_t reserve;
    struct dispatch_capture_request *requests;
    size_t nrequests;
    size_t request_capacity;
    bool collecting;
};

enum case_constraint_rank {
    DISPATCH_CONSTRAINT_INVALID = 0,
    DISPATCH_CONSTRAINT_LITERAL,
    DISPATCH_CONSTRAINT_SHAPE,
    DISPATCH_CONSTRAINT_TEST,
    DISPATCH_CONSTRAINT_CAPTURE
};

enum dispatch_capture_location {
    DISPATCH_CAPTURE_INVALID = 0,
    DISPATCH_CAPTURE_ARRAY,
    DISPATCH_CAPTURE_HASH,
    DISPATCH_CAPTURE_VALUE,
    DISPATCH_CAPTURE_TAIL
};

struct dispatch_capture_request {
    const struct dispatch_pattern_node *node;
    SV *source;
    SV *key;
    SSize_t index;
    SSize_t end;
    enum dispatch_capture_location kind;
};

static void
S_dispatch_defer_capture(pTHX_ struct dispatch_capture_owner *owner,
                      const struct dispatch_pattern_node *node, SV *source,
                      SV *key, SSize_t index, SSize_t end,
                      enum dispatch_capture_location kind)
{
    struct dispatch_capture_request *request;
    assert(owner->nrequests < owner->request_capacity);
    request = &owner->requests[owner->nrequests++];
    request->node = node;
    request->source = sv_2mortal(SvREFCNT_inc(source));
    request->key = key ? sv_2mortal(SvREFCNT_inc(key)) : NULL;
    request->index = index;
    request->end = end;
    request->kind = kind;
}

/* The mortal AV owns every retained reference, including abandoned search
 * candidates. Indices survive AV growth and callbacks; array pointers do not.
 * Callers lend VALUE; newly constructed values must already be mortal. */
static SSize_t
S_dispatch_retain_capture(pTHX_ struct dispatch_capture_owner *owner, SV *value)
{
    AV *av = owner->values;
    SSize_t ix;
    if (!av) {
        owner->values = av = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
        if (owner->reserve > (size_t)SSize_t_MAX)
            Perl_croak(aTHX_ "Too many dispatch captures");
        if (owner->reserve)
            av_extend(av, (SSize_t)owner->reserve - 1);
    }
    if (AvFILLp(av) == SSize_t_MAX)
        Perl_croak(aTHX_ "Too many dispatch captures");
    ix = AvFILLp(av) + 1;
    if (ix > AvMAX(av))
        av_extend(av, ix);
    AvARRAY(av)[ix] = SvREFCNT_inc(value);
    AvFILLp(av) = ix;
    return ix;
}

static SV *
S_dispatch_pattern_pin_value(pTHX_ PADOFFSET padix)
{
    SV *value = PAD_SV(padix);
    if (SvGMAGICAL(value))
        SvGETMAGIC(value);
    return value;
}

static bool
S_dispatch_pattern_is_numerically_comparable(pTHX_ SV *value)
{
    /* A numeric cache or a reference can be used by == without a warning.
     * Otherwise require the string representation to parse as a number. */
    return SvNIOK(value) || SvROK(value) || looks_like_number(value);
}

static bool
S_dispatch_pattern_numeq(pTHX_ SV *left, SV *right)
{
    bool equal;

    /* looks_like_number() ignores magic.  Fetch magical operands once and
     * compare snapshots so the eligibility check and comparison see the
     * same values. */
    if (left == right && SvGMAGICAL(left)) {
        SvGETMAGIC(left);
        left = right = sv_2mortal(newSVsv_flags(left, 0));
    }
    else {
        if (SvGMAGICAL(left)) {
            SvGETMAGIC(left);
            left = sv_2mortal(newSVsv_flags(left, 0));
        }
        if (SvGMAGICAL(right)) {
            SvGETMAGIC(right);
            right = sv_2mortal(newSVsv_flags(right, 0));
        }
    }

    /* Preserve overloaded numeric comparison semantics. */
    if (SvAMAGIC(left) || SvAMAGIC(right))
        return sv_numeq(left, right);

    /* A comparison which would need a warning-worthy numeric conversion is
     * not a match.  looks_like_number() performs that check without warning,
     * and also keeps undef distinct from numeric zero. */
    if (!S_dispatch_pattern_is_numerically_comparable(aTHX_ left)
        || !S_dispatch_pattern_is_numerically_comparable(aTHX_ right))
        return FALSE;

    /* A numeric comparison in a pattern is a test, not a request to warn
     * about the spelling of a non-numeric string. */
    ENTER;
    SAVEI8(PL_dowarn);
    PL_dowarn = G_WARN_ALL_OFF;
    if (PL_curcop) {
        SAVECURCOPWARNINGS();
        PL_curcop->cop_warnings = pWARN_NONE;
    }
    equal = sv_numeq(left, right);
    LEAVE;
    return equal;
}

static bool
S_dispatch_pattern_streq(pTHX_ SV *left, SV *right, U32 flags)
{
    if (flags & SV_GMAGIC) {
        SvGETMAGIC(left);
        SvGETMAGIC(right);
        flags &= ~SV_GMAGIC;
    }
    /* Stringifying undef for a comparison would warn in ordinary Perl, so
     * it is not interchangeable with the defined empty string here. */
    if (!SvOK(left) || !SvOK(right))
        return FALSE;
    return sv_streq_flags(left, right, flags);
}

static I32
S_dispatch_pattern_ncmp(pTHX_ SV *left, SV *right)
{
    I32 cmp;

    ENTER;
    SAVEI8(PL_dowarn);
    PL_dowarn = G_WARN_ALL_OFF;
    if (PL_curcop) {
        SAVECURCOPWARNINGS();
        PL_curcop->cop_warnings = pWARN_NONE;
    }
    cmp = do_ncmp(left, right);
    LEAVE;
    return cmp;
}

static bool
S_dispatch_pattern_values_equal(pTHX_ SV *left, SV *right)
{
    SvGETMAGIC(left);
    SvGETMAGIC(right);
    if (!SvOK(left) || !SvOK(right))
        return !SvOK(left) && !SvOK(right);
    if (SvROK(left) || SvROK(right))
        return SvROK(left) && SvROK(right) && SvRV(left) == SvRV(right);
    if (!SvIsBOOL(left) && !SvPOK(left) && SvNIOK(left))
        return S_dispatch_pattern_numeq(aTHX_ left, right);
    return S_dispatch_pattern_streq(aTHX_ left, right, 0);
}

static const OP *
S_dispatch_pattern_numeric_coercion(pTHX_ const OP *op)
{
    const OP *zero;
    const OP *operand;

    if (!op || op->op_type != OP_ADD || !(op->op_flags & OPf_KIDS))
        return NULL;
    zero = cBINOPx(op)->op_first;
    operand = cBINOPx(op)->op_last;
    while (zero && zero->op_type == OP_NULL && (zero->op_flags & OPf_KIDS))
        zero = cUNOPx(zero)->op_first;
    while (operand && operand->op_type == OP_NULL
           && (operand->op_flags & OPf_KIDS))
        operand = cUNOPx(operand)->op_first;
    if (!zero || !operand || zero == operand || OpSIBLING(zero) != operand
        || zero->op_type != OP_CONST
        || (zero->op_private & OPpCONST_BARE)
        || !SvNIOK(cSVOPx_sv(zero)) || SvPOK(cSVOPx_sv(zero))
        || SvIsBOOL(cSVOPx_sv(zero)) || SvNV(cSVOPx_sv(zero)) != 0.0)
        return NULL;
    if (operand->op_type == OP_CONST)
        return (operand->op_private & OPpCONST_BARE) ? NULL : operand;
    if (operand->op_type == OP_UNDEF)
        return operand;
    if (operand->op_type == OP_DISPATCHCOERCE
        && (operand->op_private & DISPATCH_PATTERN_CRITERION_MASK)
            == DISPATCH_PATTERN_CRITERION_PIN)
        return operand;
    return NULL;
}

static bool
S_dispatch_pattern_is_a(pTHX_ SV *value, const SV *classname)
{
    SV *class_name = sv_2mortal(newSVsv((SV *)classname));
    return sv_isa_sv(value, class_name);
}

static void
S_dispatch_pattern_mark_concat(pTHX_ OP *pattern, bool in_concat)
{
    OP *kid;
    if (!pattern)
        return;
    if (pattern->op_type == OP_CONCAT) {
        pattern->op_private |= OPpCONCAT_PATTERN;
        in_concat = TRUE;
    }
    if (!(pattern->op_flags & OPf_KIDS))
        return;
    for (kid = cUNOPx(pattern)->op_first; kid; kid = OpSIBLING(kid)) {
        S_dispatch_pattern_mark_concat(aTHX_ kid, in_concat);
    }
}

void
Perl_dispatch_pattern_preserve_concat(pTHX_ OP *pattern)
{
    PERL_ARGS_ASSERT_DISPATCH_PATTERN_PRESERVE_CONCAT;
    S_dispatch_pattern_mark_concat(aTHX_ pattern, FALSE);
}

static const struct dispatch_pattern_node *
S_dispatch_pattern_unwrap(const struct dispatch_pattern_node *node)
{
    const OP *op;
    if (!node)
        return NULL;
    op = node->op;
    if (op && op->op_type == OP_NULL && node->nchild == 1)
        return node->child[0];
    return node;
}

static bool
S_dispatch_pattern_assignment_parts(const OP *op, const OP **target,
                                 const OP **subpattern)
{
    const OP *right;
    const OP *left;

    if (!op || op->op_type != OP_SASSIGN || !(op->op_flags & OPf_KIDS))
        return FALSE;
    right = cBINOPx(op)->op_first;
    left = cBINOPx(op)->op_last;
    if (!right || !left || right == left || OpSIBLING(right) != left
        || left->op_type != OP_PADSV)
        return FALSE;
    *target = left;
    *subpattern = right;
    return TRUE;
}

static size_t
S_dispatch_pattern_concat_count(const struct dispatch_pattern_node *node)
{
    const struct dispatch_pattern_node *part;
    size_t count = 0;
    U32 i;

    node = S_dispatch_pattern_unwrap(node);
    if (!node || !node->op)
        return 0;
    if (node->op->op_type != OP_CONCAT
        && node->op->op_type != OP_MULTICONCAT)
        return 1;
    for (i = 0; i < node->nchild; i++) {
        part = node->child[i];
        count += S_dispatch_pattern_concat_count(part);
    }
    return count;
}

static bool
S_dispatch_pattern_concat_flatten(const struct dispatch_pattern_node *node,
                              const struct dispatch_pattern_node **parts,
                              size_t max, size_t *nparts)
{
    U32 i;

    node = S_dispatch_pattern_unwrap(node);
    if (!node || !node->op)
        return FALSE;
    if (node->op->op_type == OP_CONCAT
        || node->op->op_type == OP_MULTICONCAT) {
        for (i = 0; i < node->nchild; i++)
            if (!S_dispatch_pattern_concat_flatten(node->child[i], parts,
                                               max, nparts))
                return FALSE;
        return TRUE;
    }
    if (*nparts >= max)
        return FALSE;
    parts[(*nparts)++] = node;
    return TRUE;
}

static bool
S_dispatch_pattern_concat_is_capture(pTHX_ const struct dispatch_pattern_node *node)
{
    const OP *op;

    node = S_dispatch_pattern_unwrap(node);
    op = node ? node->op : NULL;
    PERL_UNUSED_CONTEXT;
    return op && op->op_type == OP_PADSV;
}

static bool
S_dispatch_pattern_concat_is_literal(const struct dispatch_pattern_node *node)
{
    const OP *op;

    node = S_dispatch_pattern_unwrap(node);
    op = node ? node->op : NULL;
    return op && op->op_type == OP_CONST
        && !(op->op_private & OPpCONST_BARE);
}

static SV *
S_dispatch_pattern_concat_fixed_value(pTHX_ const struct dispatch_pattern_node *node)
{
    const OP *op;
    SV *value;

    node = S_dispatch_pattern_unwrap(node);
    op = node ? node->op : NULL;
    if (!op)
        return NULL;
    if (op->op_type == OP_CONST
        && !(op->op_private & OPpCONST_BARE))
        return newSVsv(cSVOPx_sv(op));
    if (op->op_type == OP_DISPATCHCOERCE
        && (op->op_private & DISPATCH_PATTERN_CRITERION_MASK)
            == DISPATCH_PATTERN_CRITERION_PIN) {
        const OP *target = (op->op_flags & OPf_KIDS)
            ? cUNOPx(op)->op_first : NULL;
        if (target && target->op_type == OP_PADSV) {
            value = S_dispatch_pattern_pin_value(aTHX_ target->op_targ);
            return value ? newSVsv(value) : newSVsv(&PL_sv_undef);
        }
    }
    return NULL;
}

static bool
S_dispatch_pattern_concat_find(const char *subject, STRLEN subject_len,
                           STRLEN start, const char *needle,
                           STRLEN needle_len, STRLEN *found)
{
    STRLEN pos;

    if (!needle_len) {
        *found = start;
        return TRUE;
    }
    if (needle_len > subject_len || start > subject_len - needle_len)
        return FALSE;
    for (pos = start; pos <= subject_len - needle_len; pos++) {
        if (memEQ(subject + pos, needle, needle_len)) {
            *found = pos;
            return TRUE;
        }
    }
    return FALSE;
}

static bool
S_dispatch_pattern_concat_match(pTHX_ const struct dispatch_pattern_node *node,
                             SV *value, SV *pattern_value,
                             struct dispatch_binding *bindings,
                             size_t *nbindings, struct dispatch_capture_owner *owner)
{
    const struct dispatch_pattern_node **parts = NULL;
    SV **fixed_values = NULL;
    size_t nparts = S_dispatch_pattern_concat_count(node);
    size_t capacity = nparts;
    size_t i, j, cursor = 0;
    const char *subject;
    STRLEN subject_len;
    bool matched = FALSE;
    SV *text;
    SV *workspace;

    PERL_UNUSED_VAR(pattern_value);

    if ((!SvPOK(value) && !SvAMAGIC(value)) || SvIsBOOL(value))
        return FALSE;
    text = sv_newmortal();
    sv_copypv(text, value);
    if (IN_BYTES)
        SvUTF8_off(text);
    else
        sv_utf8_upgrade(text);

    if (!nparts)
        Perl_croak(aTHX_ "unsupported dispatch pattern concatenation expression");
    workspace = sv_2mortal(newSV(capacity * sizeof(*parts)));
    parts = (const struct dispatch_pattern_node **)SvPVX(workspace);
    workspace = sv_2mortal(newSV(capacity * sizeof(*fixed_values)));
    fixed_values = (SV **)SvPVX(workspace);
    Zero(fixed_values, capacity, SV *);
    nparts = 0;
    if (!S_dispatch_pattern_concat_flatten(node, parts, capacity, &nparts))
        Perl_croak(aTHX_ "unsupported dispatch pattern concatenation expression");
    subject = SvPV_nomg_const(text, subject_len);

    /* Materialize each fixed fragment once. Normalize encodings before
     * byte-wise searching so equal characters have equal representations;
     * never upgrade the original pin or subject. Under 'use bytes', retain
     * the ordinary byte interpretation instead. */
    for (i = 0; i < nparts; i++) {
        SV *raw;
        if (S_dispatch_pattern_concat_is_capture(aTHX_ parts[i]))
            continue;
        raw = S_dispatch_pattern_concat_fixed_value(aTHX_ parts[i]);
        if (!raw)
            Perl_croak(aTHX_ "unsupported dispatch pattern concatenation component");
        sv_2mortal(raw);
        fixed_values[i] = sv_newmortal();
        sv_copypv(fixed_values[i], raw);
        if (IN_BYTES)
            SvUTF8_off(fixed_values[i]);
        else
            sv_utf8_upgrade(fixed_values[i]);
    }

    /* Adjacent literal fragments form one boundary.  Keeping them separate
     * can make a search stop at an occurrence that cannot complete the full
     * literal run. */
    for (i = 0; i < nparts; i++) {
        if (!S_dispatch_pattern_concat_is_literal(parts[i]))
            continue;
        for (j = i + 1; j < nparts
             && S_dispatch_pattern_concat_is_literal(parts[j]); j++) {
            sv_catsv(fixed_values[i], fixed_values[j]);
            sv_setpvs(fixed_values[j], "");
        }
    }

    /* Validate all capture boundaries before creating tentative bindings.
     * This also makes malformed patterns fail without leaving partially
     * constructed binding state behind. */
    for (i = 0; i < nparts; i++) {
        if (!S_dispatch_pattern_concat_is_capture(aTHX_ parts[i]))
            continue;
        for (j = 0; j < i; j++) {
            if (S_dispatch_pattern_concat_is_capture(aTHX_ parts[j])
                && S_dispatch_pattern_unwrap(parts[j])->binding_padix
                    == S_dispatch_pattern_unwrap(parts[i])->binding_padix)
                Perl_croak(aTHX_
                    "repeated capture names are not allowed in a dispatch pattern concatenation");
        }
        for (j = i + 1; j < nparts; j++) {
            STRLEN boundary_len;
            if (S_dispatch_pattern_concat_is_capture(aTHX_ parts[j]))
                Perl_croak(aTHX_
                    "adjacent captures are not allowed in a dispatch pattern concatenation");
            (void)SvPV(fixed_values[j], boundary_len);
            if (boundary_len)
                break;
        }
    }
    for (i = 0; i < nparts; i++) {
        const struct dispatch_pattern_node *part = parts[i];
        if (S_dispatch_pattern_concat_is_capture(aTHX_ part)) {
            size_t next = i + 1;
            STRLEN end = subject_len;
            SV *boundary = NULL;
            const char *boundary_pv;
            STRLEN boundary_len;

            /* Empty fixed fragments do not establish a boundary.  Skip them
             * while looking ahead so that capture pairs separated only by an
             * empty literal are rejected just like directly adjacent pairs. */
            while (next < nparts) {
                if (S_dispatch_pattern_concat_is_capture(aTHX_ parts[next]))
                    Perl_croak(aTHX_
                        "adjacent captures are not allowed in a dispatch pattern concatenation");
                boundary = fixed_values[next];
                boundary_pv = SvPV(boundary, boundary_len);
                if (boundary_len)
                    break;
                boundary = NULL;
                next++;
            }
            if (next < nparts) {
                if (!S_dispatch_pattern_concat_find(subject, subject_len, cursor,
                                                 boundary_pv, boundary_len,
                                                 &end)) {
                    goto out;
                }
            }
            {
                const PADOFFSET padix = S_dispatch_pattern_unwrap(part)->binding_padix;
                const STRLEN capture_len = end - cursor;
                SV *captured = newSVpvn_flags(subject + cursor, capture_len,
                                               SvUTF8(text) ? SVf_UTF8 : 0);
                bindings[*nbindings].padix = padix;
                bindings[*nbindings].value_ix = S_dispatch_retain_capture(aTHX_
                    owner, sv_2mortal(captured));
                bindings[*nbindings].kind = DISPATCH_BINDING_SCALAR;
                bindings[*nbindings].clear_on_exit =
                    S_dispatch_pattern_unwrap(part)->binding_local;
                (*nbindings)++;
                cursor = end;
            }
        }
        else {
            SV *fragment = fixed_values[i];
            const char *fragment_pv;
            STRLEN fragment_len;
            fragment_pv = SvPV(fragment, fragment_len);
            if (cursor > subject_len || fragment_len > subject_len - cursor
                || !memEQ(subject + cursor, fragment_pv, fragment_len)) {
                goto out;
            }
            cursor += fragment_len;
        }
    }
    matched = cursor == subject_len;
out:
    return matched;
}

static void
S_dispatch_pattern_scan_call(pTHX_ const OP *op, const OP **target,
                         const OP **invocant, U32 *nargs);

static bool
S_dispatch_pattern_empty_fields(const OP *op)
{
    /* In the indirect-call representation of Class {}, the braces produce
     * SCOPE(STUB), not an empty hash constructor. Recognize only this exact
     * empty block; a standalone stub is not a supported data shape. */
    const OP *kid;
    if (!op || op->op_type != OP_SCOPE || !(op->op_flags & OPf_KIDS))
        return FALSE;
    kid = cUNOPx(op)->op_first;
    return kid && kid->op_type == OP_STUB && !OpSIBLING(kid);
}

static const OP *
S_dispatch_pattern_find_shape_op(const OP *op)
{
    const OP *kid;

    if (!op)
        return NULL;
    if (S_dispatch_pattern_empty_fields(op))
        return op;
    if (op->op_type == OP_ANONHASH || op->op_type == OP_ANONLIST
        || op->op_type == OP_EMPTYAVHV
        || op->op_type == OP_REFGEN || op->op_type == OP_SREFGEN
        || op->op_type == OP_LIST
        || (op->op_type == OP_NULL && op->op_targ == OP_LIST))
        return op;
    if (!(op->op_flags & OPf_KIDS))
        return NULL;
    for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid)) {
        const OP *shape = S_dispatch_pattern_find_shape_op(kid);
        if (shape)
            return shape;
    }
    return NULL;
}

static bool
S_dispatch_pattern_object_call(pTHX_ const OP *op, const OP **class_op,
                           const OP **shape_op)
{
    const OP *target = NULL;
    const OP *invocant = NULL;
    U32 nargs = 0;

    if (!op || op->op_type != OP_ENTERSUB)
        return FALSE;
    S_dispatch_pattern_scan_call(aTHX_ cUNOPx(op)->op_first,
                             &target, &invocant, &nargs);
    if (!target || target->op_type != OP_METHOD_NAMED || !invocant
        || !S_dispatch_pattern_find_shape_op(invocant))
        return FALSE;
    *class_op = target;
    *shape_op = invocant;
    PERL_UNUSED_VAR(nargs);
    return TRUE;
}

static struct dispatch_pattern_node *
S_dispatch_pattern_compile_node(pTHX_ const OP *op, bool preserve_lists)
{
    const OP *kid;
    const OP *numeric_operand;
    U32 nchild = 0;
    U32 i = 0;
    struct dispatch_pattern_node *node;

    if (!op)
        return NULL;

    numeric_operand = S_dispatch_pattern_numeric_coercion(aTHX_ op);
    if (numeric_operand) {
        node = (struct dispatch_pattern_node *)PerlMemShared_calloc(
            1, sizeof(struct dispatch_pattern_node));
        node->op = op;
        node->comparison_mode = DISPATCH_PATTERN_COMPARE_NUMERIC;
        node->nchild = 1;
        node->child = (struct dispatch_pattern_node **)
            PerlMemShared_malloc(sizeof(struct dispatch_pattern_node *));
        node->child[0] = S_dispatch_pattern_compile_node(aTHX_ numeric_operand,
                                                     TRUE);
        return node;
    }

    if (op->op_type == OP_SASSIGN) {
        const OP *target;
        const OP *subpattern;
        if (!S_dispatch_pattern_assignment_parts(op, &target, &subpattern))
            Perl_croak(aTHX_
                "pattern assignment requires a scalar capture target");
        node = (struct dispatch_pattern_node *)PerlMemShared_calloc(
            1, sizeof(struct dispatch_pattern_node));
        node->op = op;
        node->binding_padix = target->op_targ;
        node->binding_local = TRUE;
        node->nchild = 1;
        node->child = (struct dispatch_pattern_node **)
            PerlMemShared_malloc(sizeof(struct dispatch_pattern_node *));
        node->child[0] = S_dispatch_pattern_compile_node(aTHX_ subpattern, TRUE);
        return node;
    }

    if (op->op_type == OP_NULL && (op->op_flags & OPf_KIDS)
        && (!preserve_lists || op->op_targ != OP_LIST))
        return S_dispatch_pattern_compile_node(aTHX_ cUNOPx(op)->op_first,
                                           preserve_lists);

    {
        const OP *class_op = NULL;
        const OP *shape_op = NULL;
        if (S_dispatch_pattern_object_call(aTHX_ op, &class_op, &shape_op)) {
            node = (struct dispatch_pattern_node *)PerlMemShared_calloc(
                1, sizeof(struct dispatch_pattern_node));
            node->op = op;
            node->object_class = cSVOPx_sv(class_op);
            node->object_shape = S_dispatch_pattern_compile_node(aTHX_ shape_op,
                                                              TRUE);
            return node;
        }
    }

    if (op->op_flags & OPf_KIDS) {
        for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid))
            nchild++;
    }

    node = (struct dispatch_pattern_node *)PerlMemShared_calloc(
        1, sizeof(struct dispatch_pattern_node));
    node->op = op;
    node->binding_padix = NOT_IN_PAD;
    node->binding_local = FALSE;
    if (op->op_type == OP_PADSV || op->op_type == OP_PADAV) {
        node->binding_padix = op->op_targ;
        node->binding_local = TRUE;
    }
    node->nchild = nchild;
    if (nchild) {
        const bool shape_preserve = preserve_lists
            || (op->op_type == OP_DISPATCHCOERCE
                && (op->op_private & DISPATCH_PATTERN_CRITERION_MASK)
                    == DISPATCH_PATTERN_CRITERION_OBJECT);
        node->child = (struct dispatch_pattern_node **)
            PerlMemShared_malloc(nchild * sizeof(struct dispatch_pattern_node *));
        for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid), i++)
            node->child[i] = S_dispatch_pattern_compile_node(aTHX_ kid,
                                                         shape_preserve);
    }
    return node;
}

static void S_dispatch_pattern_prepare_regex(pTHX_ const OP *pattern, HV *seen);
static void S_dispatch_pattern_validate(pTHX_ const OP *op);

static void
S_dispatch_pattern_rebind(pTHX_ OP *op, HV *padmap)
{
    OP *kid;

    if (!op)
        return;
    if (op->op_type == OP_PADSV || op->op_type == OP_PADAV
        || op->op_type == OP_PADHV || op->op_type == OP_PADANY) {
        SV **replacement = hv_fetch(padmap, (const char *)&op->op_targ,
                                    sizeof(op->op_targ), FALSE);
        if (replacement)
            op->op_targ = (PADOFFSET)SvUV(*replacement);
    }
    if (op->op_flags & OPf_KIDS)
        for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid))
            S_dispatch_pattern_rebind(aTHX_ kid, padmap);
}

void
Perl_dispatch_pattern_prepare(pTHX_ OP *pattern)
{
    PERL_ARGS_ASSERT_DISPATCH_PATTERN_PREPARE;
    if (!PL_parser || !PL_parser->dispatch_pattern_vars)
        return;

    /* Class-qualified hash shapes pass through an indirect-object block.
     * That temporary scope may have closed some capture declarations.
     * Declare replacements in the dispatch-on clause before parsing its guard
     * and body, then update the shape's pad references by identity without
     * searching older declarations with the same spelling. */
    {
        HV *padmap = NULL;
        HE *he;
        hv_iterinit(PL_parser->dispatch_pattern_vars);
        while ((he = hv_iternext(PL_parser->dispatch_pattern_vars))) {
            SV *padix = HeVAL(he);
            const PADOFFSET oldpad = (PADOFFSET)SvUV(padix);
            PADNAME *name = PAD_COMPNAME(oldpad);
            if (COP_SEQ_RANGE_LOW(name) != PERL_PADSEQ_INTRO
                && COP_SEQ_RANGE_HIGH(name) != PERL_PADSEQ_INTRO) {
                PADOFFSET newpad = pad_add_name_pvn(HeKEY(he), HeKLEN(he),
                    padadd_NO_DUP_CHECK | (HeKUTF8(he) ? SVf_UTF8 : 0),
                    NULL, NULL);
                if (!padmap)
                    padmap = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
                (void)hv_store(padmap, (const char *)&oldpad, sizeof(oldpad),
                               newSVuv((UV)newpad), 0);
                sv_setuv(padix, (UV)newpad);
            }
        }
        if (padmap)
            S_dispatch_pattern_rebind(aTHX_ pattern, padmap);
    }
    /* Validate while the parser's temporary pattern-name map is still live;
     * it is discarded before the guard/body and final optree construction. */
    S_dispatch_pattern_validate(aTHX_ pattern);
    S_dispatch_pattern_prepare_regex(aTHX_ pattern,
        MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV()))));
}

static void
S_dispatch_pattern_prepare_regex(pTHX_ const OP *pattern, HV *seen)
{
    REGEXP *re;
    SV *names_ref;
    AV *names;
    SSize_t i;
    const OP *kid;

    if (!pattern || !PL_parser->in_dispatch_pattern)
        return;
    if (pattern->op_type != OP_MATCH) {
        if (pattern->op_flags & OPf_KIDS)
            for (kid = cUNOPx(pattern)->op_first; kid; kid = OpSIBLING(kid))
                S_dispatch_pattern_prepare_regex(aTHX_ kid, seen);
        return;
    }
    re = PM_GETRE(cPMOPx(pattern));
    if (!re)
        return;
    if (RX_EXTFLAGS(re) & RXf_EVAL_SEEN)
        Perl_croak(aTHX_
            "regex code blocks are not supported in dispatch patterns");
    names_ref = CALLREG_NAMED_BUFF_ALL(re, RXapif_ALL | RXapif_REGNAMES);
    if (!names_ref || !SvROK(names_ref)) {
        SvREFCNT_dec(names_ref);
        return;
    }
    sv_2mortal(names_ref);
    names = MUTABLE_AV(SvRV(names_ref));
    for (i = 0; i <= av_len(names); i++) {
        SV **name_svp = av_fetch(names, i, FALSE);
        SV *padname;
        PADOFFSET padix;

        if (!name_svp || !*name_svp)
            continue;
        /* REGNAMES returns each name once per regex, even when several
         * groups share it.  Only collisions between separate regexes need
         * a warning: the engine selects the participating group within a
         * regex, but the clause publishes only its first binding per name.
         * Keep this separate from dispatch_pattern_vars, which also contains
         * ordinary destructuring targets. */
        if (hv_exists_ent(seen, *name_svp, 0))
            ck_warner_d(packWARN(WARN_SYNTAX),
            "Named capture '%" SVf "' occurs in multiple regexes in a dispatch-on clause; "
                "only the first regex maps to its lexical variable; "
                "later captures are not visible through that variable",
                SVfARG(*name_svp));
        else
            (void)hv_store_ent(seen, *name_svp, newSViv(1), 0);
        padname = newSVpvn("$", 1);
        sv_catsv(padname, *name_svp);
        if (hv_exists(PL_parser->dispatch_pattern_vars,
                      SvPV_nolen(padname), SvCUR(padname))) {
            SvREFCNT_dec_NN(padname);
            continue;
        }
        padix = pad_add_name_sv(padname, padadd_NO_DUP_CHECK, NULL, NULL);
        (void)hv_store(PL_parser->dispatch_pattern_vars,
                       SvPV_nolen(padname), SvCUR(padname),
                       newSVuv((UV)padix), 0);
        SvREFCNT_dec_NN(padname);
    }
}

static void
S_dispatch_pattern_compile_regex(pTHX_ struct dispatch_pattern_node *node, HV *seen)
{
    REGEXP *re;
    SV *names_ref;
    AV *names;
    SSize_t i;

    U32 childix;

    if (!node || !PL_parser)
        return;
    S_dispatch_pattern_compile_regex(aTHX_ node->object_shape, seen);
    for (childix = 0; childix < node->nchild; childix++)
        S_dispatch_pattern_compile_regex(aTHX_ node->child[childix], seen);
    if (node->op->op_type != OP_MATCH)
        return;
    re = PM_GETRE(cPMOPx(node->op));
    if (!re)
        return;
    names_ref = CALLREG_NAMED_BUFF_ALL(re, RXapif_ALL | RXapif_REGNAMES);
    if (!names_ref || !SvROK(names_ref)) {
        SvREFCNT_dec(names_ref);
        return;
    }
    names = MUTABLE_AV(SvRV(names_ref));
    for (i = 0; i <= av_len(names); i++) {
        SV **name_svp = av_fetch(names, i, FALSE);
        SV *padname;
        SV **padix_svp;

        if (!name_svp || !*name_svp)
            continue;
        /* Bind duplicate names from the first regex in SOURCE order. The
         * constraint scheduler may execute a later nested regex first, so
         * runtime insertion order cannot decide which regex owns the name.
         * This does not change the engine's own duplicate-group handling. */
        if (hv_exists_ent(seen, *name_svp, 0))
            continue;
        (void)hv_store_ent(seen, *name_svp, SvREFCNT_inc(&PL_sv_yes), 0);
        padname = newSVpvn("$", 1);
        sv_catsv(padname, *name_svp);
        padix_svp = hv_fetch(PL_parser->dispatch_pattern_vars,
                             SvPV_nolen(padname), SvCUR(padname), FALSE);
        if (!padix_svp) {
            SvREFCNT_dec_NN(padname);
            continue;
        }
        if (!node->regex_names) {
            node->regex_names = newAV();
            node->regex_padixes = newAV();
        }
        av_push(node->regex_names, newSVsv(*name_svp));
        av_push(node->regex_padixes, newSVsv(*padix_svp));
        SvREFCNT_dec_NN(padname);
    }
    SvREFCNT_dec_NN(names_ref);
}

static bool
S_dispatch_pattern_is_ellipsis(pTHX_ const OP *op)
{
    return op->op_type == OP_CONST
        && (op->op_flags & OPf_SPECIAL)
        && strEQ(SvPV_nolen_const(cSVOPx_sv(op)), "...");
}

static bool
S_dispatch_pattern_is_slurp(const OP *op)
{
    const OP *target = op;
    if (op->op_type == OP_DISPATCHCOERCE)
        target = cUNOPx(op)->op_first;
    return target && (target->op_type == OP_PADAV
                      || target->op_type == OP_PADHV);
}

static const OP *
S_dispatch_pattern_slurp_target(const OP *op)
{
    return op->op_type == OP_DISPATCHCOERCE ? cUNOPx(op)->op_first : op;
}

static void
S_dispatch_pattern_validate_concat(pTHX_ const OP *op)
{
    const OP *kid;

    if (!op)
        Perl_croak(aTHX_ "unsupported dispatch pattern concatenation expression");
    if (op->op_type == OP_NULL && (op->op_flags & OPf_KIDS)) {
        S_dispatch_pattern_validate_concat(aTHX_ cUNOPx(op)->op_first);
        return;
    }
    if (op->op_type == OP_CONCAT || op->op_type == OP_MULTICONCAT) {
        if (!(op->op_flags & OPf_KIDS))
            Perl_croak(aTHX_ "unsupported dispatch pattern concatenation expression");
        for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid))
            S_dispatch_pattern_validate_concat(aTHX_ kid);
        return;
    }
    if (op->op_type == OP_CONST
        && !(op->op_private & OPpCONST_BARE))
        return;
    if (op->op_type == OP_PADSV)
        return;
    if (op->op_type == OP_DISPATCHCOERCE
        && (op->op_private & DISPATCH_PATTERN_CRITERION_MASK)
            == DISPATCH_PATTERN_CRITERION_PIN) {
        const OP *target = (op->op_flags & OPf_KIDS)
            ? cUNOPx(op)->op_first : NULL;
        if (target && target->op_type == OP_PADSV)
            return;
    }
    Perl_croak(aTHX_ "unsupported dispatch pattern concatenation expression");
}

static void
S_dispatch_pattern_validate_concat_boundaries(pTHX_ const OP *op,
                                          bool *seen_capture,
                                          bool *has_literal)
{
    const OP *kid;

    while (op && op->op_type == OP_NULL && (op->op_flags & OPf_KIDS))
        op = cUNOPx(op)->op_first;
    if (!op)
        return;
    if (op->op_type == OP_CONCAT || op->op_type == OP_MULTICONCAT) {
        for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid))
            S_dispatch_pattern_validate_concat_boundaries(aTHX_ kid,
                                                       seen_capture,
                                                       has_literal);
        return;
    }
    if (op->op_type == OP_CONST && !(op->op_private & OPpCONST_BARE)) {
        STRLEN len;
        (void)SvPV_const(cSVOPx_sv(op), len);
        if (len)
            *has_literal = TRUE;
        return;
    }
    if (op->op_type == OP_PADSV) {
        if (*seen_capture && !*has_literal)
            Perl_croak(aTHX_
                "dispatch pattern captures must be separated by non-empty constant text");
        *seen_capture = TRUE;
        *has_literal = FALSE;
    }
}

static void
S_dispatch_pattern_note_hash_key(pTHX_ HV *keys, const OP *key)
{
    if (key->op_type == OP_CONST) {
        SV *name = cSVOPx_sv(key);
        if (hv_exists_ent(keys, name, 0))
            Perl_croak(aTHX_ "duplicate key \"%" SVf "\" in a dispatch hash pattern",
                       SVfARG(name));
        (void)hv_store_ent(keys, name, SvREFCNT_inc(&PL_sv_yes), 0);
    }
}

static void
S_dispatch_pattern_validate_object_fields(pTHX_ const OP *op)
{
    const OP *kid;
    bool need_value = FALSE;
    bool open = FALSE;
    bool slurp = FALSE;
    HV *keys = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));

    if (S_dispatch_pattern_empty_fields(op))
        return;
    if (!op || (op->op_type != OP_LIST
                && !(op->op_type == OP_NULL && op->op_targ == OP_LIST)))
        Perl_croak(aTHX_ "invalid object field pattern");
    for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid)) {
        if (kid->op_type == OP_PUSHMARK
            || (kid->op_type == OP_NULL && kid->op_targ == OP_PUSHMARK))
            continue;
        if (S_dispatch_pattern_is_ellipsis(aTHX_ kid)) {
            if (need_value || open || slurp)
                Perl_croak(aTHX_ "object ellipsis must follow field pairs");
            open = TRUE;
            continue;
        }
        if (S_dispatch_pattern_is_slurp(kid)) {
            if (need_value || open || slurp)
                Perl_croak(aTHX_ "object hash slurp must be the final pattern element and cannot use an ellipsis");
            slurp = TRUE;
            continue;
        }
        if (slurp)
            Perl_croak(aTHX_ "object hash slurp must be the final pattern element");
        if (open)
            Perl_croak(aTHX_ "object fields cannot follow an ellipsis");
        if (!need_value) {
            if (kid->op_type != OP_CONST)
                Perl_croak(aTHX_ "object field names must be constants");
            S_dispatch_pattern_note_hash_key(aTHX_ keys, kid);
            need_value = TRUE;
        }
        else {
            S_dispatch_pattern_validate(aTHX_ kid);
            need_value = FALSE;
        }
    }
    if (need_value)
        Perl_croak(aTHX_ "object field pattern requires key/value pairs");
}

static bool
S_dispatch_pattern_canonical_number(const char *start, const char *end)
{
    const char *digits;

    if (start < end && (*start == '+' || *start == '-'))
        start++;
    digits = start;
    while (digits < end && isDIGIT((U8)*digits))
        digits++;
    return digits - start <= 1 || *start != '0';
}

static bool
S_dispatch_pattern_numeric_match(pTHX_ SV *value, U8 criterion)
{
    const bool strict = (criterion & DISPATCH_PATTERN_CRITERION_STRICT) != 0;
    const U8 kind = criterion & DISPATCH_PATTERN_CRITERION_MASK;
    const char *start;
    const char *end;
    STRLEN len;
    UV integer_value;
    int number_type;
    bool integer_string;
    bool float_string;
    const bool native_number = SvNIOK(value) && !SvPOK(value)
        && !SvIsBOOL(value) && !SvROK(value);

    if (kind == DISPATCH_PATTERN_CRITERION_INT)
        return native_number && SvIOK(value);
    if (kind == DISPATCH_PATTERN_CRITERION_FLOAT)
        return native_number && SvNOK(value);
    if (kind == DISPATCH_PATTERN_CRITERION_NUM)
        return native_number;

    if (native_number) {
        if (kind == DISPATCH_PATTERN_CRITERION_INTSTR)
            return SvIOK(value);
        if (kind == DISPATCH_PATTERN_CRITERION_FLOATSTR)
            return SvNOK(value);
        return TRUE;
    }
    if (!SvPOK(value) || SvROK(value) || SvIsBOOL(value))
        return FALSE;

    start = SvPV_nomg_const(value, len);
    end = start + len;
    while (start < end && isSPACE((U8)*start))
        start++;
    while (end > start && isSPACE((U8)end[-1]))
        end--;
    if (start == end || (strict && (start != SvPVX_const(value)
                                    || end != SvPVX_const(value) + SvCUR(value))))
        return FALSE;

    number_type = grok_number(start, end - start, &integer_value);
    if (!number_type || (number_type & IS_NUMBER_TRAILING))
        return FALSE;
    integer_string = !(number_type & IS_NUMBER_NOT_INT);
    float_string = !integer_string;
    if (strict && !S_dispatch_pattern_canonical_number(start, end))
        return FALSE;

    if (kind == DISPATCH_PATTERN_CRITERION_INTSTR) {
        return integer_string;
    }
    if (kind == DISPATCH_PATTERN_CRITERION_FLOATSTR) {
        return float_string;
    }
    return integer_string || float_string;
}

static bool
S_dispatch_pattern_strict_numeq(pTHX_ SV *value)
{
    const char *start;
    STRLEN len;
    STRLEN n;

    if (!SvPOK(value) || SvROK(value))
        return TRUE;
    start = SvPV_nomg_const(value, len);
    if (!len || isSPACE((U8)start[0]))
        return FALSE;
    for (n = len; n; n--) {
        int number_type = grok_number(start, n, NULL);
        if (number_type && !(number_type & IS_NUMBER_TRAILING))
            return TRUE;
    }
    return FALSE;
}

static void
S_dispatch_pattern_scan_call(pTHX_ const OP *op, const OP **target,
                         const OP **invocant, U32 *nargs)
{
    for (; op; op = OpHAS_SIBLING(op) ? OpSIBLING(op) : NULL) {
        if (op->op_type == OP_PUSHMARK)
            continue;
        if (op->op_type == OP_NULL && op->op_targ == OP_RV2CV) {
            if (*target)
                Perl_croak(aTHX_ "dispatch pattern calls must have no arguments");
            *target = op;
            continue;
        }
        if (op->op_type == OP_NULL || op->op_type == OP_LIST) {
            S_dispatch_pattern_scan_call(aTHX_ cUNOPx(op)->op_first,
                                     target, invocant, nargs);
            continue;
        }
        if (op->op_type == OP_RV2CV || op->op_type == OP_PADCV
            || op->op_type == OP_METHOD_NAMED
            || op->op_type == OP_METHOD) {
            if (*target)
                Perl_croak(aTHX_ "dispatch pattern calls must have no arguments");
            *target = op;
            continue;
        }
        *invocant = op;
        (*nargs)++;
    }
}

static CV *
S_dispatch_pattern_call_cv(pTHX_ const OP *target)
{
    if (target->op_type == OP_PADCV)
        return MUTABLE_CV(PAD_SV(target->op_targ));
    if (target->op_type == OP_RV2CV)
        return rv2cv_op_cv((OP *)target, RV2CVOPCV_RETURN_STUB);
    if (target->op_type == OP_NULL && target->op_targ == OP_RV2CV) {
        const OP *rvop = cUNOPx(target)->op_first;
        while (rvop && rvop->op_type == OP_NULL)
            rvop = cUNOPx(rvop)->op_first;
        if (!rvop)
            return NULL;
        if (rvop->op_type == OP_GV) {
            GV *gv = cGVOPx_gv(rvop);
            if (isGV(gv))
                return GvCVu(gv);
            if (SvROK((SV *)gv) && SvTYPE(SvRV((SV *)gv)) == SVt_PVCV)
                return MUTABLE_CV(SvRV((SV *)gv));
            else {
                STRLEN len;
                const char *name = SvPV_const((SV *)gv, len);
                GV *realgv = gv_fetchpvn_flags(name, len,
                    GV_ADD, SVt_PVCV);
                if (realgv && isGV(realgv) && GvCVu(realgv))
                    return GvCVu(realgv);
                return NULL;
            }
        }
        if (rvop->op_type == OP_PADCV)
            return MUTABLE_CV(PAD_SV(rvop->op_targ));
        if (rvop->op_type == OP_CONST && SvROK(cSVOPx_sv(rvop)))
            return MUTABLE_CV(SvRV(cSVOPx_sv(rvop)));
    }
    return NULL;
}

/* A predicate is an ordinary Perl sub whose first signature parameter is
 * named $subject.  This lets a lexical sub shadow an imported predicate
 * without reserving its name in the parser. */
static bool
S_dispatch_pattern_is_predicate_cv(CV *cv)
{
    PADNAMELIST *names;
    PADNAME **name_array;
    PADOFFSET ix;

    if (!cv || !CvSIGNATURE(cv) || !CvPADLIST(cv))
        return FALSE;
    names = PadlistNAMES(CvPADLIST(cv));
    if (!names)
        return FALSE;
    name_array = PadnamelistARRAY(names);
    /* Pad slot zero is reserved for the CV name.  The signature's first
     * lexical is therefore in slot one. */
    for (ix = 1; ix <= PadnamelistMAXNAMED(names); ix++) {
        PADNAME *name = name_array[ix];
        if (name) {
            return PadnameLEN(name) == 8
                && memEQ(PadnamePV(name), "$subject", 8);
        }
    }
    return FALSE;
}

static const struct op_multiparam_aux *
S_dispatch_pattern_find_multiparam(const OP *op)
{
    const OP *kid;
    const struct op_multiparam_aux *found;

    if (!op)
        return NULL;
    if (op->op_type == OP_MULTIPARAM)
        return (const struct op_multiparam_aux *)cUNOP_AUXx(op)->op_aux;
    if (!(op->op_flags & OPf_KIDS))
        return NULL;
    for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid)) {
        found = S_dispatch_pattern_find_multiparam(kid);
        if (found)
            return found;
    }
    return NULL;
}

static bool
S_dispatch_pattern_predicate_arity_ok(CV *cv, U32 explicit_args)
{
    const struct op_multiparam_aux *arity =
        S_dispatch_pattern_find_multiparam(CvROOT(cv));
    const UV total_args = (UV)explicit_args + 1; /* implicit subject */

    if (!arity)
        return TRUE;
    /* Named parameters have their own name/value calling convention. Let
     * Perl's signature binder check those at the point of the call. */
    if (arity->n_named)
        return TRUE;
    if (total_args < arity->min_args)
        return FALSE;
    if (!arity->slurpy && total_args > arity->n_positional)
        return FALSE;
    return TRUE;
}

/* Collect the explicit arguments from a call tree.  Only list wrappers are
 * descended into: accepted arguments are constants, undef, or pin nodes. */
static void
S_dispatch_pattern_collect_call_args(pTHX_ const OP *op,
                                     const OP ***args, U32 *nargs,
                                     U32 *capacity, bool *past_target)
{
    for (; op; op = OpHAS_SIBLING(op) ? OpSIBLING(op) : NULL) {
        if (op->op_type == OP_PUSHMARK)
            continue;
        if (op->op_type == OP_NULL && op->op_targ == OP_RV2CV) {
            *past_target = TRUE;
            continue;
        }
        if (op->op_type == OP_NULL || op->op_type == OP_LIST) {
            S_dispatch_pattern_collect_call_args(aTHX_
                cUNOPx(op)->op_first, args, nargs, capacity, past_target);
            continue;
        }
        if (op->op_type == OP_RV2CV || op->op_type == OP_PADCV
            || op->op_type == OP_METHOD_NAMED
            || op->op_type == OP_METHOD) {
            *past_target = TRUE;
            continue;
        }
        if (!*past_target) {
            if (*nargs == *capacity) {
                *capacity = *capacity ? *capacity * 2 : 4;
                *args = (const OP **) (*args
                    ? PerlMem_realloc((Malloc_t)*args,
                        *capacity * sizeof(**args))
                    : PerlMem_malloc(*capacity * sizeof(**args)));
            }
            (*args)[(*nargs)++] = op;
        }
    }
}

static bool
S_dispatch_pattern_is_predicate(pTHX_ const OP *op)
{
    const OP *target = NULL;
    const OP *invocant = NULL;
    U32 nargs = 0;
    CV *cv;

    S_dispatch_pattern_scan_call(aTHX_ cUNOPx(op)->op_first,
                                 &target, &invocant, &nargs);
    PERL_UNUSED_VAR(invocant);
    cv = target ? S_dispatch_pattern_call_cv(aTHX_ target) : NULL;
    return S_dispatch_pattern_is_predicate_cv(cv);
}

static void
S_dispatch_pattern_free_call_args(pTHX_ void *args)
{
    PERL_UNUSED_CONTEXT;
    PerlMem_free(args);
}

static void
S_dispatch_pattern_validate(pTHX_ const OP *op)
{
    const OP *kid;
    const OP *numeric_operand;
    if (!op)
        return;

    numeric_operand = S_dispatch_pattern_numeric_coercion(aTHX_ op);
    if (numeric_operand) {
        S_dispatch_pattern_validate(aTHX_ numeric_operand);
        return;
    }

    if (op->op_type == OP_SASSIGN) {
        const OP *target;
        const OP *subpattern;
        if (!S_dispatch_pattern_assignment_parts(op, &target, &subpattern))
            Perl_croak(aTHX_
                "pattern assignment requires a scalar capture target");
        PERL_UNUSED_VAR(target);
        S_dispatch_pattern_validate(aTHX_ subpattern);
        return;
    }

    if (op->op_type == OP_REGCOMP)
        Perl_croak(aTHX_
            "dynamic regexes are only allowed as a guard condition");

    if (op->op_type == OP_ENTERSUB) {
        const OP *class_op = NULL;
        const OP *shape_op = NULL;
        if (S_dispatch_pattern_object_call(aTHX_ op, &class_op, &shape_op)) {
            const OP *fields = S_dispatch_pattern_find_shape_op(shape_op);
            if (fields && (S_dispatch_pattern_empty_fields(fields)
                           || fields->op_type == OP_LIST
                           || (fields->op_type == OP_NULL
                               && fields->op_targ == OP_LIST)))
                S_dispatch_pattern_validate_object_fields(aTHX_ fields);
            else
                S_dispatch_pattern_validate(aTHX_ shape_op);
            return;
        }
    }

    if (op->op_type == OP_ENTERSUB) {
        const OP *call_target = NULL;
        const OP *call_invocant = NULL;
        const OP **call_args = NULL;
        U32 nargs = 0;
        U32 ncall_args = 0;
        U32 call_args_capacity = 0;
        bool past_target = FALSE;
        CV *cv;

        S_dispatch_pattern_scan_call(aTHX_ cUNOPx(op)->op_first,
                                 &call_target, &call_invocant, &nargs);
        cv = call_target ? S_dispatch_pattern_call_cv(aTHX_ call_target) : NULL;
        if (S_dispatch_pattern_is_predicate_cv(cv)) {
            if (!S_dispatch_pattern_predicate_arity_ok(cv, nargs))
                Perl_croak(aTHX_
                    "dispatch predicate has the wrong number of arguments");
            S_dispatch_pattern_collect_call_args(aTHX_
                cUNOPx(op)->op_first, &call_args, &ncall_args,
                &call_args_capacity, &past_target);
            if (ncall_args != nargs) {
                PerlMem_free((Malloc_t)call_args);
                Perl_croak(aTHX_ "unsupported argument in dispatch predicate");
            }
            for (U32 argix = 0; argix < ncall_args; argix++) {
                const OP *arg = call_args[argix];
                if (arg->op_type != OP_CONST && arg->op_type != OP_UNDEF
                    && !(arg->op_type == OP_DISPATCHCOERCE
                         && (arg->op_private & DISPATCH_PATTERN_CRITERION_MASK)
                             == DISPATCH_PATTERN_CRITERION_PIN)) {
                    PerlMem_free((Malloc_t)call_args);
                    Perl_croak(aTHX_
                        "dispatch predicate arguments must be constants or pinned values");
                }
            }
            PerlMem_free((Malloc_t)call_args);
            return;
        }
        if (!call_target
            || ((call_target->op_type == OP_RV2CV
                 || (call_target->op_type == OP_NULL
                     && call_target->op_targ == OP_RV2CV)) && nargs)
            || (call_target->op_type != OP_RV2CV
                && !(call_target->op_type == OP_NULL
                     && call_target->op_targ == OP_RV2CV)
                && nargs != 1))
            Perl_croak(aTHX_ "unsupported dispatch pattern call");
        PERL_UNUSED_VAR(call_invocant);
        return;
    }
    if (op->op_type == OP_DISPATCHCOERCE
        && (op->op_private & DISPATCH_PATTERN_CRITERION_MASK)
            == DISPATCH_PATTERN_CRITERION_NUMEQ) {
        const OP *arg = (op->op_flags & OPf_KIDS)
            ? cUNOPx(op)->op_first : NULL;
        if (!arg || (arg->op_type != OP_CONST && arg->op_type != OP_UNDEF))
            Perl_croak(aTHX_ "NumEq() requires a literal argument in a dispatch-on pattern");
    }
    if (op->op_type == OP_DISPATCHCOERCE
        && (op->op_private & DISPATCH_PATTERN_CRITERION_MASK)
            == DISPATCH_PATTERN_CRITERION_OBJECT) {
        const OP *args = (op->op_flags & OPf_KIDS)
            ? cUNOPx(op)->op_first : NULL;
        const OP *arg;
        const OP *shape = NULL;
        if (args && args->op_type == OP_LIST) {
            arg = cLISTOPx(args)->op_first;
            if (arg && (arg->op_type == OP_PUSHMARK
                        || (arg->op_type == OP_NULL
                            && arg->op_targ == OP_PUSHMARK)))
                arg = OpSIBLING(arg);
            if (arg)
                shape = OpSIBLING(arg);
        }
        if (!args || args->op_type != OP_LIST || !shape)
            Perl_croak(aTHX_ "invalid object pattern");
        if (shape->op_type == OP_ANONHASH || shape->op_type == OP_LIST)
            S_dispatch_pattern_validate_object_fields(aTHX_ shape);
        else
            S_dispatch_pattern_validate(aTHX_ shape);
        return;
    }
    if (op->op_type == OP_CONCAT || op->op_type == OP_MULTICONCAT) {
        bool seen_capture = FALSE;
        bool has_literal = FALSE;
        S_dispatch_pattern_validate_concat(aTHX_ op);
        S_dispatch_pattern_validate_concat_boundaries(aTHX_ op,
                                                   &seen_capture,
                                                   &has_literal);
        return;
    }
    if (op->op_type == OP_NULL && (op->op_flags & OPf_KIDS)) {
        S_dispatch_pattern_validate(aTHX_ cUNOPx(op)->op_first);
        return;
    }

    if (op->op_type == OP_ANONLIST) {
        U32 logical_ix = 0;
        U32 ellipses = 0;
        U32 slurps = 0;
        U32 nchild = 0;
        for (kid = cLISTOPx(op)->op_first; kid; kid = OpSIBLING(kid)) {
            if (kid->op_type == OP_PUSHMARK)
                continue;
            nchild++;
            if (S_dispatch_pattern_is_ellipsis(aTHX_ kid))
                ellipses++;
            else if (S_dispatch_pattern_is_slurp(kid))
                slurps++;
        }
        if (ellipses > 2 || (ellipses == 2 && nchild < 3))
            Perl_croak(aTHX_ "array pattern has invalid ellipsis placement");
        if (slurps > 1)
            Perl_croak(aTHX_ "array pattern may contain only one slurp");
        for (kid = cLISTOPx(op)->op_first; kid; kid = OpSIBLING(kid)) {
            if (kid->op_type == OP_PUSHMARK)
                continue;
            if (S_dispatch_pattern_is_ellipsis(aTHX_ kid)) {
                if (logical_ix != 0 && logical_ix != nchild - 1)
                    Perl_croak(aTHX_ "array pattern ellipsis must be at an edge");
                logical_ix++;
                continue;
            }
            if (S_dispatch_pattern_is_slurp(kid)) {
                if (logical_ix != nchild - 1 || ellipses)
                    Perl_croak(aTHX_ "array slurp must be the final pattern element and cannot use an ellipsis");
                logical_ix++;
                continue;
            }
            S_dispatch_pattern_validate(aTHX_ kid);
            logical_ix++;
        }
        return;
    }

    if (op->op_type == OP_ANONHASH) {
        U32 ellipses = 0;
        U32 slurps = 0;
        U32 logical_ix = 0;
        U32 nchild = 0;
        HV *keys = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
        for (kid = cLISTOPx(op)->op_first; kid; kid = OpSIBLING(kid)) {
            if (kid->op_type == OP_PUSHMARK)
                continue;
            nchild++;
            if (S_dispatch_pattern_is_ellipsis(aTHX_ kid))
                ellipses++;
            else if (S_dispatch_pattern_is_slurp(kid))
                slurps++;
        }
        if (ellipses > 1)
            Perl_croak(aTHX_ "hash pattern may contain only one ellipsis");
        if (slurps > 1)
            Perl_croak(aTHX_ "hash pattern may contain only one slurp");
        if ((nchild - ellipses - slurps) & 1)
            Perl_croak(aTHX_ "hash pattern requires key/value pairs");
        for (kid = cLISTOPx(op)->op_first; kid; kid = OpSIBLING(kid)) {
            if (kid->op_type == OP_PUSHMARK)
                continue;
            if (S_dispatch_pattern_is_ellipsis(aTHX_ kid)) {
                if (logical_ix != nchild - 1)
                    Perl_croak(aTHX_ "hash pattern ellipsis must be last");
                logical_ix++;
                continue;
            }
            if (S_dispatch_pattern_is_slurp(kid)) {
                if (logical_ix != nchild - 1 || ellipses)
                    Perl_croak(aTHX_ "hash slurp must be the final pattern element and cannot use an ellipsis");
                logical_ix++;
                continue;
            }
            if (!(logical_ix & 1)) {
                if (PL_parser && PL_parser->in_dispatch_pattern
                    && kid->op_type != OP_CONST
                    && (kid->op_type != OP_ENTERSUB
                        || S_dispatch_pattern_is_predicate(aTHX_ kid))
                    && !(kid->op_type == OP_DISPATCHCOERCE
                         && (kid->op_private & DISPATCH_PATTERN_CRITERION_MASK)
                             == DISPATCH_PATTERN_CRITERION_PIN))
                    Perl_croak(aTHX_ "hash pattern keys must be constants, pins, or zero-argument calls");
                S_dispatch_pattern_note_hash_key(aTHX_ keys, kid);
            }
            S_dispatch_pattern_validate(aTHX_ kid);
            logical_ix++;
        }
        return;
    }

    /* The left side of match is a data-shape language, not an arbitrary Perl
     * expression.  Keep this list explicit: falling through to the generic
     * dynamic-leaf handling would silently give unsupported operators the
     * wrong meaning. */
    switch (op->op_type) {
    case OP_CONST:
    case OP_UNDEF:
    case OP_PADSV:
    case OP_PADAV:
    case OP_DISPATCHCOERCE:
    case OP_REFGEN:
    case OP_SREFGEN:
    case OP_CONCAT:
    case OP_MULTICONCAT:
    case OP_MATCH:
    case OP_ANONLIST:
    case OP_ANONHASH:
    case OP_EMPTYAVHV:
        break;
    default:
        Perl_croak(aTHX_ "unsupported dispatch pattern expression");
    }

    if (op->op_flags & OPf_KIDS)
        for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid))
            S_dispatch_pattern_validate(aTHX_ kid);
}

/* Return the value of a zero-argument function or class-method call used as
 * a data-shape constant.  The parser leaves these calls as ordinary
 * OP_ENTERSUB trees; keeping the call here means that their Perl dispatch
 * semantics remain unchanged while the rest of the pattern remains inert. */
static SV *
S_dispatch_pattern_call(pTHX_ const OP *op)
{
    const OP *target = NULL;
    const OP *invocant = NULL;
    U32 nargs = 0;
    SV *result = sv_newmortal();

    S_dispatch_pattern_scan_call(aTHX_ cUNOPx(op)->op_first,
                             &target, &invocant, &nargs);

    if (!target
        || ((target->op_type == OP_RV2CV
             || (target->op_type == OP_NULL && target->op_targ == OP_RV2CV))
            && nargs)
        || (target->op_type != OP_RV2CV
            && !(target->op_type == OP_NULL && target->op_targ == OP_RV2CV)
            && nargs != 1))
        Perl_croak(aTHX_ "dispatch pattern calls must have no arguments");

    if (target->op_type == OP_RV2CV
        || (target->op_type == OP_NULL && target->op_targ == OP_RV2CV)) {
        CV *cv = S_dispatch_pattern_call_cv(aTHX_ target);
        if (!cv)
            Perl_croak(aTHX_ "dispatch pattern call has no callable target");
        {
            dSP;
            I32 count;
            ENTER;
            SAVETMPS;
            PUSHMARK(SP);
            PUTBACK;
            count = call_sv(MUTABLE_SV(cv), G_SCALAR);
            SPAGAIN;
            if (count)
                sv_setsv(result, TOPs);
            PUTBACK;
            FREETMPS;
            LEAVE;
        }
    }
    else {
        if (!invocant || invocant->op_type != OP_CONST
            || target->op_type != OP_METHOD_NAMED)
            Perl_croak(aTHX_ "unsupported dispatch pattern method call");
        {
            dSP;
            I32 count;
            ENTER;
            SAVETMPS;
            PUSHMARK(SP);
            XPUSHs(cSVOPx_sv(invocant));
            PUTBACK;
            count = call_method(SvPV_nolen_const(cSVOPx_sv(target)), G_SCALAR);
            SPAGAIN;
            if (count)
                sv_setsv(result, TOPs);
            PUTBACK;
            FREETMPS;
            LEAVE;
        }
    }

    return SvREFCNT_inc_NN(result);
}

static bool
S_dispatch_pattern_predicate_call(pTHX_ const OP *op, SV *subject)
{
    const OP *target = NULL;
    const OP *invocant = NULL;
    const OP **args = NULL;
    U32 nargs = 0;
    U32 scanned_nargs = 0;
    U32 capacity = 0;
    U32 argix;
    bool past_target = FALSE;
    CV *cv;
    dSP;
    I32 count;

    S_dispatch_pattern_scan_call(aTHX_ cUNOPx(op)->op_first,
                                 &target, &invocant, &scanned_nargs);
    PERL_UNUSED_VAR(invocant);
    cv = target ? S_dispatch_pattern_call_cv(aTHX_ target) : NULL;
    if (!S_dispatch_pattern_is_predicate_cv(cv))
        Perl_croak(aTHX_ "dispatch pattern call is not a predicate");
    ENTER;
    SAVETMPS;
    S_dispatch_pattern_collect_call_args(aTHX_ cUNOPx(op)->op_first,
        &args, &nargs, &capacity, &past_target);
    if (args)
        SAVEDESTRUCTOR_X(S_dispatch_pattern_free_call_args, (void *)args);
    if (nargs != scanned_nargs) {
        FREETMPS;
        LEAVE;
        Perl_croak(aTHX_ "unsupported argument in dispatch predicate");
    }

    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(subject)));
    for (argix = 0; argix < nargs; argix++) {
        const OP *arg = args[argix];
        SV *argvalue = NULL;
        if (arg->op_type == OP_CONST)
            argvalue = cSVOPx_sv(arg);
        else if (arg->op_type == OP_UNDEF)
            argvalue = &PL_sv_undef;
        else if (arg->op_type == OP_DISPATCHCOERCE) {
            const OP *pin = (arg->op_flags & OPf_KIDS)
                ? cUNOPx(arg)->op_first : NULL;
            while (pin && pin->op_type == OP_NULL && (pin->op_flags & OPf_KIDS))
                pin = cUNOPx(pin)->op_first;
            if (pin && pin->op_type == OP_PADSV)
                argvalue = S_dispatch_pattern_pin_value(aTHX_ pin->op_targ);
        }
        if (!argvalue) {
            FREETMPS;
            LEAVE;
            Perl_croak(aTHX_ "invalid argument in dispatch predicate");
        }
        XPUSHs(sv_2mortal(newSVsv(argvalue)));
    }
    PUTBACK;
    count = call_sv(MUTABLE_SV(cv), G_SCALAR);
    SPAGAIN;
    if (count)
        argix = SvTRUE(TOPs);
    else
        argix = 0;
    SP -= count;
    PUTBACK;
    FREETMPS;
    LEAVE;
    return cBOOL(argix);
}

static void
S_dispatch_pattern_free_node(pTHX_ struct dispatch_pattern_node *node)
{
    U32 i;

    if (!node)
        return;
    S_dispatch_pattern_free_node(aTHX_ node->object_shape);
    for (i = 0; i < node->nchild; i++)
        S_dispatch_pattern_free_node(aTHX_ node->child[i]);
    SvREFCNT_dec((SV *)node->regex_names);
    SvREFCNT_dec((SV *)node->regex_padixes);
    PerlMemShared_free(node->child);
    PerlMemShared_free(node);
}

/* Each node can contribute at most one ordinary binding.  Counting all
 * nodes is conservative, including pins and constants, and avoids imposing
 * an arbitrary semantic limit on captures. */
static size_t
S_dispatch_pattern_binding_capacity(pTHX_ const struct dispatch_pattern_node *node)
{
    size_t count = 1;
    U32 i;
    if (!node)
        return 0;
    count += node->regex_names ? (size_t)av_count(node->regex_names) : 0;
    count += S_dispatch_pattern_binding_capacity(aTHX_ node->object_shape);
    for (i = 0; i < node->nchild; i++)
        count += S_dispatch_pattern_binding_capacity(aTHX_ node->child[i]);
    return count;
}

static size_t
S_dispatch_capture_occurrences(const struct dispatch_pattern_node *node, PADOFFSET padix)
{
    size_t count;
    U32 i;
    if (!node)
        return 0;
    count = (node->op->op_type == OP_PADSV
             || node->op->op_type == OP_SASSIGN)
        && node->binding_padix == padix;
    count += S_dispatch_capture_occurrences(node->object_shape, padix);
    for (i = 0; i < node->nchild; i++)
        count += S_dispatch_capture_occurrences(node->child[i], padix);
    return count;
}

static void
S_dispatch_schedule_constraints(struct dispatch_pattern_node *node,
                            const struct dispatch_pattern_node *root)
{
    const OP *op;
    U32 i;
    if (!node)
        return;
    op = node->op;
    if (op->op_type == OP_CONST || op->op_type == OP_UNDEF)
        node->constraint_rank = DISPATCH_CONSTRAINT_LITERAL;
    else if (node->object_shape || op->op_type == OP_SASSIGN
             || op->op_type == OP_ANONLIST
             || op->op_type == OP_ANONHASH || op->op_type == OP_REFGEN
             || op->op_type == OP_SREFGEN || op->op_type == OP_EMPTYAVHV)
        node->constraint_rank = DISPATCH_CONSTRAINT_SHAPE;
    else if (op->op_type == OP_PADSV
             && S_dispatch_capture_occurrences(root, node->binding_padix) == 1)
        node->constraint_rank = DISPATCH_CONSTRAINT_CAPTURE;
    else
        node->constraint_rank = DISPATCH_CONSTRAINT_TEST;
    S_dispatch_schedule_constraints(node->object_shape, root);
    for (i = 0; i < node->nchild; i++)
        S_dispatch_schedule_constraints(node->child[i], root);
}

UNOP_AUX_item *
Perl_dispatch_pattern_compile(pTHX_ const OP *pattern)
{
    struct dispatch_pattern_aux *aux;

    PERL_ARGS_ASSERT_DISPATCH_PATTERN_COMPILE;

    S_dispatch_pattern_validate(aTHX_ pattern);
    aux = (struct dispatch_pattern_aux *)PerlMemShared_calloc(
        1, sizeof(struct dispatch_pattern_aux));
    aux->magic = DISPATCH_PATTERN_AUX_MAGIC;
    aux->pattern = (OP *)pattern;
    aux->root = S_dispatch_pattern_compile_node(aTHX_ pattern, FALSE);
    S_dispatch_pattern_compile_regex(aTHX_ aux->root,
        MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV()))));
    aux->binding_capacity = S_dispatch_pattern_binding_capacity(aTHX_ aux->root);
    aux->dispatch_capture_capacity = aux->binding_capacity;
    S_dispatch_schedule_constraints(aux->root, aux->root);
    aux->kind = DISPATCH_PATTERN_COMPLEX;
    if (pattern->op_type == OP_UNDEF)
        aux->kind = DISPATCH_PATTERN_SIMPLE_UNDEF;
    else if (pattern->op_type == OP_CONST
             && SvIsBOOL(cSVOPx_sv(pattern)))
        aux->kind = DISPATCH_PATTERN_SIMPLE_BOOL;
    else if (pattern->op_type == OP_CONST
             && !(pattern->op_private & OPpCONST_BARE)
             && (SvIOK(cSVOPx_sv(pattern)) || SvNOK(cSVOPx_sv(pattern))))
        aux->kind = DISPATCH_PATTERN_SIMPLE_NUM;
    else if (pattern->op_type == OP_CONST
             && !(pattern->op_private & OPpCONST_BARE))
        aux->kind = DISPATCH_PATTERN_SIMPLE_STR;
    return (UNOP_AUX_item *)aux;
}

void
Perl_dispatch_pattern_free(pTHX_ UNOP_AUX_item *items)
{
    struct dispatch_pattern_aux *aux = (struct dispatch_pattern_aux *)items;
    PERL_ARGS_ASSERT_DISPATCH_PATTERN_FREE;
    PERL_UNUSED_CONTEXT;

    /* `pattern` owns the OPs referenced by the node graph.  Tear the graph
     * down before releasing that tree, and release dispatch only through its
     * separate clause/op reference count.  This is also why the node graph
     * never takes an OP or class-SV reference of its own. */
    if (aux && aux->magic == DISPATCH_PATTERN_AUX_MAGIC) {
        S_dispatch_pattern_free_node(aTHX_ aux->root);
        op_free(aux->pattern);
        if (aux->dispatch)
            Perl_dispatch_on_free(aTHX_ (UNOP_AUX_item *)aux->dispatch);
        PerlMemShared_free(aux);
    }
}

static bool
S_dispatch_pattern_is_wildcard(pTHX_ const struct dispatch_pattern_aux *aux)
{
    const OP *pattern;

    if (!aux || !aux->root || aux->root->nchild)
        return FALSE;
    pattern = aux->root->op;
    return pattern->op_type == OP_CONST
        && (pattern->op_private & OPpCONST_BARE)
        && strEQ(SvPV_nolen_const(cSVOPx_sv(pattern)), "_");
}

static bool
S_dispatch_clause(pTHX_ const OP *op, struct dispatch_pattern_aux **auxp,
                    OP **targetp)
{
    const OP *enter_on;
    const OP *condition;
    const struct dispatch_pattern_aux *aux;

    PERL_UNUSED_CONTEXT;
    if (op->op_type != OP_LEAVEDISPATCHON)
        return FALSE;
    enter_on = cUNOPx(op)->op_first;
    if (!enter_on || enter_on->op_type != OP_ENTERDISPATCHON)
        return FALSE;
    condition = cUNOPx(enter_on)->op_first;
    if (!condition || condition->op_type != OP_DISPATCH_ON)
        return FALSE;
    aux = (const struct dispatch_pattern_aux *)cUNOP_AUXx(condition)->op_aux;
    if (!aux || aux->magic != DISPATCH_PATTERN_AUX_MAGIC
        || (aux->kind == DISPATCH_PATTERN_COMPLEX
            && !S_dispatch_pattern_is_wildcard(aTHX_ aux))
        || !aux->root)
        return FALSE;
    *auxp = (struct dispatch_pattern_aux *)aux;
    if (targetp)
        *targetp = (OP *)enter_on;
    return TRUE;
}

static bool
S_dispatch_on_push(pTHX_ AV **valuesp, AV **clausesp, SV *value, U32 clause,
                     U32 capacity, U8 kind)
{
    SSize_t i;

    /* Optimized dispatch tables retain only the earliest source clause for a
     * value.  This makes the table's values unique, so a linear probe can
     * stop as soon as it finds a match. */
    if (*valuesp) {
        for (i = 0; i <= av_len(*valuesp); i++) {
            SV **old = av_fetch(*valuesp, i, FALSE);
            if (old && (kind == DISPATCH_PATTERN_SIMPLE_NUM
                        ? do_ncmp(*old, value) == 0
                        : sv_cmp(*old, value) == 0))
                return TRUE;
        }
    }
    if (!*valuesp) {
        *valuesp = newAV();
        if (capacity)
            av_extend(*valuesp, (SSize_t)capacity - 1);
    }
    if (!*clausesp) {
        *clausesp = newAV();
        if (capacity)
            av_extend(*clausesp, (SSize_t)capacity - 1);
    }
    av_push(*valuesp, SvREFCNT_inc_simple_NN(value));
    av_push(*clausesp, newSVuv((UV)clause));
    return FALSE;
}

static void
S_dispatch_on_add_iv_bound(struct dispatch_on_aux *dispatch, SV *value)
{
    const bool is_uv = SvUOK(value);
    const IV iv = SvIVX(value);
    const UV uv = SvUVX(value);

    if (!dispatch->iv_has_bounds) {
        dispatch->iv_has_bounds = TRUE;
        dispatch->iv_min_is_uv = is_uv;
        dispatch->iv_max_is_uv = is_uv;
        dispatch->iv_min_iv = iv;
        dispatch->iv_max_iv = iv;
        dispatch->iv_min_uv = uv;
        dispatch->iv_max_uv = uv;
        return;
    }
    if (is_uv) {
        if (dispatch->iv_min_is_uv) {
            if (uv < dispatch->iv_min_uv)
                dispatch->iv_min_uv = uv;
        }
        else if (iv >= 0 && uv < (UV)dispatch->iv_min_iv) {
            dispatch->iv_min_is_uv = TRUE;
            dispatch->iv_min_uv = uv;
        }
        if (dispatch->iv_max_is_uv) {
            if (uv > dispatch->iv_max_uv)
                dispatch->iv_max_uv = uv;
        }
        else if (iv < 0 || uv > (UV)dispatch->iv_max_iv) {
            dispatch->iv_max_is_uv = TRUE;
            dispatch->iv_max_uv = uv;
        }
    }
    else {
        if (dispatch->iv_min_is_uv) {
            if (iv < 0 || (UV)iv < dispatch->iv_min_uv) {
                dispatch->iv_min_is_uv = FALSE;
                dispatch->iv_min_iv = iv;
            }
        }
        else if (iv < dispatch->iv_min_iv)
            dispatch->iv_min_iv = iv;
        if (dispatch->iv_max_is_uv) {
            if (iv < 0 || (UV)iv > dispatch->iv_max_uv) {
                dispatch->iv_max_is_uv = FALSE;
                dispatch->iv_max_iv = iv;
            }
        }
        else if (iv > dispatch->iv_max_iv)
            dispatch->iv_max_iv = iv;
    }
}

static void
S_dispatch_on_add_nv_bound(struct dispatch_on_aux *dispatch, SV *value)
{
    const NV nv = SvNVX(value);

    if (!dispatch->nv_has_bounds) {
        dispatch->nv_min = nv;
        dispatch->nv_max = nv;
        dispatch->nv_has_bounds = TRUE;
    }
    else {
        if (nv < dispatch->nv_min)
            dispatch->nv_min = nv;
        if (nv > dispatch->nv_max)
            dispatch->nv_max = nv;
    }
}

static U8
S_dispatch_on_strategy(U32 clause_count)
{
    const char *mode = PerlEnv_getenv("PERL_CONST_DISPATCH_STRATEGY");

    /* Numeric constants use typed arrays.  String constants use an HV in
     * every enabled dispatch mode. */
    if (!mode || strEQ(mode, "auto"))
        return clause_count < 16 ? DISPATCH_ON_ARRAY_LINEAR
                              : DISPATCH_ON_ARRAY_BINARY;
    if (strEQ(mode, "array-binary"))
        return DISPATCH_ON_ARRAY_BINARY;
    if (strEQ(mode, "array-linear"))
        return DISPATCH_ON_ARRAY_LINEAR;
    if (strEQ(mode, "none"))
        return DISPATCH_ON_NONE;
    if (strEQ(mode, "hv"))
        return DISPATCH_ON_ARRAY_BINARY;
    return DISPATCH_ON_ARRAY_LINEAR;
}

static void
S_dispatch_on_key(pTHX_ SV *key, SV *value)
{
    if (UNLIKELY(!SvPOK(key) || SvLEN(key) < 3))
        sv_setpvs(key, "s:");
    else {
        SvPOK_only(key);
        Copy("s:", SvPVX_mutable(key), 2, char);
        SvCUR_set(key, 2);
        SvPVX_mutable(key)[2] = '\0';
    }
    SvUTF8_off(key);
    sv_catsv(key, value);
    if (IN_BYTES)
        SvUTF8_off(key);
}

static bool
S_dispatch_on_store(pTHX_ HV **tablep, SV *value, U32 clause)
{
    SV *key;
    bool duplicate;

    if (!*tablep)
        *tablep = newHV();
    key = newSVpvs("");
    S_dispatch_on_key(aTHX_ key, value);
    duplicate = hv_fetch_ent(*tablep, key, FALSE, 0) != NULL;
    if (!duplicate)
        (void)hv_store_ent(*tablep, key, newSVuv((UV)clause), 0);
    SvREFCNT_dec_NN(key);
    return duplicate;
}

static void
S_dispatch_on_warn_duplicate(pTHX_ SV *value, U8 kind,
                               const COP *first_cop, const COP *duplicate_cop)
{
    const char *value_text;
    const char *first_file = first_cop ? CopFILE(first_cop) : "<unknown>";
    const char *duplicate_file = duplicate_cop
        ? CopFILE(duplicate_cop) : "<unknown>";
    const line_t first_line = first_cop ? CopLINE(first_cop) : NOLINE;
    const line_t duplicate_line = duplicate_cop
        ? CopLINE(duplicate_cop) : NOLINE;
    const char *first_location = form("%s line %" LINE_Tf,
        first_file, first_line);
    const char *duplicate_location = form("%s line %" LINE_Tf,
        duplicate_file, duplicate_line);

    if (kind == DISPATCH_PATTERN_SIMPLE_UNDEF)
        value_text = "undef";
    else if (kind == DISPATCH_PATTERN_SIMPLE_BOOL)
        value_text = SvTRUE(value) ? "true" : "false";
    else
        value_text = SvPV_nolen_const(value);
    ck_warner_d(packWARN(WARN_SYNTAX),
        "duplicate dispatch pattern constant %s will never match; duplicate at "
        "%s, first at %s", value_text, duplicate_location, first_location);
}

static void
S_dispatch_on_warn_duplicates(pTHX_ OP *body)
{
    AV *iv_values = NULL;
    AV *iv_clauses = NULL;
    AV *nv_values = NULL;
    AV *nv_clauses = NULL;
    AV *pv_values = NULL;
    AV *pv_clauses = NULL;
    bool undef_seen = FALSE;
    bool bool_seen[2] = { FALSE, FALSE };
    const COP *undef_cop = NULL;
    const COP *bool_cop[2] = { NULL, NULL };
    AV *iv_sources = NULL;
    AV *nv_sources = NULL;
    AV *pv_sources = NULL;
    const COP *cop = NULL;
    OP *kid;

    for (kid = cLISTOPx(body)->op_first; kid; kid = OpSIBLING(kid)) {
        struct dispatch_pattern_aux *pattern_aux;
        const OP *pattern;
        SV *value;
        bool duplicate;

        if (OP_TYPE_IS_COP_NN(kid)) {
            cop = cCOPx(kid);
            continue;
        }
        if (!S_dispatch_clause(aTHX_ kid, &pattern_aux, NULL))
            continue;
        if (S_dispatch_pattern_is_wildcard(aTHX_ pattern_aux))
            break;
        pattern = pattern_aux->root->op;
        if (pattern_aux->kind == DISPATCH_PATTERN_SIMPLE_UNDEF) {
            duplicate = undef_seen;
            undef_seen = TRUE;
            if (duplicate)
                S_dispatch_on_warn_duplicate(aTHX_ NULL,
                    DISPATCH_PATTERN_SIMPLE_UNDEF, undef_cop, cop);
            else
                undef_cop = cop;
            continue;
        }
        value = cSVOPx_sv(pattern);
        if (pattern_aux->kind == DISPATCH_PATTERN_SIMPLE_BOOL) {
            const U32 bool_ix = SvTRUE(value) ? 1 : 0;
            duplicate = bool_seen[bool_ix];
            bool_seen[bool_ix] = TRUE;
            if (duplicate)
                S_dispatch_on_warn_duplicate(aTHX_ value,
                    DISPATCH_PATTERN_SIMPLE_BOOL, bool_cop[bool_ix], cop);
            else
                bool_cop[bool_ix] = cop;
        }
        else if (pattern_aux->kind == DISPATCH_PATTERN_SIMPLE_NUM) {
            AV **sourcesp = SvNOK(value) ? &nv_sources : &iv_sources;
            AV *sources = *sourcesp;
            SSize_t i;
            const COP *first_cop = NULL;

            if (SvNOK(value))
                duplicate = S_dispatch_on_push(aTHX_ &nv_values,
                    &nv_clauses, value, 0, 0, DISPATCH_PATTERN_SIMPLE_NUM);
            else
                duplicate = S_dispatch_on_push(aTHX_ &iv_values,
                    &iv_clauses, value, 0, 0, DISPATCH_PATTERN_SIMPLE_NUM);
            if (duplicate) {
                for (i = 0; i <= av_len(sources); i++) {
                    SV **old = av_fetch(SvNOK(value)
                        ? nv_values : iv_values, i, FALSE);
                    if (old && do_ncmp(*old, value) == 0) {
                        SV **source = av_fetch(sources, i, FALSE);
                        if (source)
                            first_cop = INT2PTR(const COP *, SvUVX(*source));
                        break;
                    }
                }
                S_dispatch_on_warn_duplicate(aTHX_ value,
                    DISPATCH_PATTERN_SIMPLE_NUM, first_cop, cop);
            }
            else {
                if (!sources)
                    sources = *sourcesp = newAV();
                av_push(sources, newSVuv(PTR2UV(cop)));
            }
        }
        else {
            AV *sources = pv_sources;
            SSize_t i;
            const COP *first_cop = NULL;
            duplicate = S_dispatch_on_push(aTHX_ &pv_values,
                &pv_clauses, value, 0, 0, DISPATCH_PATTERN_SIMPLE_STR);
            if (duplicate) {
                for (i = 0; i <= av_len(pv_values); i++) {
                    SV **old = av_fetch(pv_values, i, FALSE);
                    if (old && sv_cmp(*old, value) == 0) {
                        SV **source = av_fetch(sources, i, FALSE);
                        if (source)
                            first_cop = INT2PTR(const COP *, SvUVX(*source));
                        break;
                    }
                }
                S_dispatch_on_warn_duplicate(aTHX_ value,
                    DISPATCH_PATTERN_SIMPLE_STR, first_cop, cop);
            }
            else {
                if (!sources)
                    sources = pv_sources = newAV();
                av_push(sources, newSVuv(PTR2UV(cop)));
            }
        }
    }
    SvREFCNT_dec((SV *)iv_values);
    SvREFCNT_dec((SV *)iv_clauses);
    SvREFCNT_dec((SV *)nv_values);
    SvREFCNT_dec((SV *)nv_clauses);
    SvREFCNT_dec((SV *)pv_values);
    SvREFCNT_dec((SV *)pv_clauses);
    SvREFCNT_dec((SV *)iv_sources);
    SvREFCNT_dec((SV *)nv_sources);
    SvREFCNT_dec((SV *)pv_sources);
}

static void
S_dispatch_on_sort(pTHX_ AV *values, AV *clauses, U8 kind)
{
    SSize_t i, j, count;
    SV **value_array;
    SV **clause_array;

    if (!values || !clauses)
        return;
    count = av_len(values) + 1;
    value_array = AvARRAY(values);
    clause_array = AvARRAY(clauses);
    for (i = 1; i < count; i++) {
        SV *value = value_array[i];
        SV *clause = clause_array[i];
        for (j = i; j > 0; j--) {
            const I32 cmp = kind == DISPATCH_PATTERN_SIMPLE_NUM
                ? do_ncmp(value_array[j - 1], value)
                : sv_cmp(value_array[j - 1], value);
            if (cmp <= 0)
                break;
            value_array[j] = value_array[j - 1];
            clause_array[j] = clause_array[j - 1];
        }
        value_array[j] = value;
        clause_array[j] = clause;
    }
}

static bool
S_dispatch_on_default_is_noop(const OP *target, const OP *leave_on)
{
    const OP *op = target ? target->op_next : NULL;
    U32 steps = 0;

    while (op && op != leave_on && steps++ < 8) {
        if (op->op_type != OP_NEXTSTATE && op->op_type != OP_STUB
            && op->op_type != OP_NULL && op->op_type != OP_UNSTACK
            && op->op_type != OP_SCOPE)
            return FALSE;
        op = op->op_next;
    }
    return op == leave_on;
}

/* Traverse clause conditions, not their bodies or nested dispatches. Every
 * clause reserves enough owner slots for the enclosing case; retries may
 * still grow that reservation. This applies even without dispatch tables. */
static size_t
S_dispatch_reserve_captures(pTHX_ OP *op, size_t reserve)
{
    size_t total = 0;
    OP *kid;
    if (!op || op->op_type == OP_LEAVEDISPATCH)
        return 0;
    if (op->op_type == OP_DISPATCH_ON) {
        struct dispatch_pattern_aux *aux =
            (struct dispatch_pattern_aux *)cUNOP_AUXx(op)->op_aux;
        if (reserve)
            aux->dispatch_capture_capacity = reserve;
        return aux->binding_capacity;
    }
    if (op->op_type == OP_LEAVEDISPATCHON) {
        OP *enter = cUNOPx(op)->op_first;
        return enter ? S_dispatch_reserve_captures(aTHX_
            cUNOPx(enter)->op_first, reserve) : 0;
    }
    if (!(op->op_flags & OPf_KIDS))
        return 0;
    for (kid = cUNOPx(op)->op_first; kid; kid = OpSIBLING(kid)) {
        size_t count = S_dispatch_reserve_captures(aTHX_ kid, reserve);
        if (count > (size_t)SSize_t_MAX - total)
            Perl_croak(aTHX_ "Too many dispatch captures");
        total += count;
    }
    return total;
}

UNOP_AUX_item *
Perl_dispatch_on_compile(pTHX_ OP *body)
{
    struct dispatch_on_aux *dispatch;
    OP *kid;
    U32 nclause = 0;
    U32 clause_count;
    bool eligible = TRUE;
    bool has_constant = FALSE;

    PERL_ARGS_ASSERT_DISPATCH_ON_COMPILE;

    if (!body || body->op_type != OP_LINESEQ)
        return NULL;
    (void)S_dispatch_reserve_captures(aTHX_ body,
        S_dispatch_reserve_captures(aTHX_ body, 0));
    S_dispatch_on_warn_duplicates(aTHX_ body);
    for (kid = cLISTOPx(body)->op_first; kid; kid = OpSIBLING(kid)) {
        struct dispatch_pattern_aux *pattern_aux;
        if (OP_TYPE_IS_COP_NN(kid))
            continue;
        if (!S_dispatch_clause(aTHX_ kid, &pattern_aux, NULL)) {
            eligible = FALSE;
            break;
        }
        nclause++;
        if (S_dispatch_pattern_is_wildcard(aTHX_ pattern_aux))
            break;
        has_constant = TRUE;
    }
    if (!eligible || !nclause || !has_constant)
        return NULL;
    clause_count = nclause;

    dispatch = (struct dispatch_on_aux *)PerlMemShared_calloc(
        1, sizeof(struct dispatch_on_aux));
    dispatch->magic = DISPATCH_ON_AUX_MAGIC;
    dispatch->refcnt = 1;
    dispatch->strategy = S_dispatch_on_strategy(clause_count);
    dispatch->undef_clause = DISPATCH_ON_NO_CLAUSE;
    dispatch->bool_clause[0] = DISPATCH_ON_NO_CLAUSE;
    dispatch->bool_clause[1] = DISPATCH_ON_NO_CLAUSE;
    dispatch->default_clause = DISPATCH_ON_NO_CLAUSE;
    dispatch->clause_count = clause_count;
    dispatch->clause_targets = (OP **)PerlMemShared_calloc(
        clause_count, sizeof(OP *));
    if (dispatch->strategy == DISPATCH_ON_NONE) {
        PerlMemShared_free(dispatch->clause_targets);
        PerlMemShared_free(dispatch);
        return NULL;
    }

    nclause = 0;
    for (kid = cLISTOPx(body)->op_first; kid; kid = OpSIBLING(kid)) {
        struct dispatch_pattern_aux *pattern_aux;
        const OP *pattern;
        SV *value;
        bool duplicate;

        if (OP_TYPE_IS_COP_NN(kid))
            continue;
        OP *target;
        (void)S_dispatch_clause(aTHX_ kid, &pattern_aux, &target);
        pattern = pattern_aux->root->op;
        pattern_aux->dispatch = dispatch;
        pattern_aux->dispatch_clause = nclause++;
        dispatch->clause_targets[pattern_aux->dispatch_clause] = target;
        dispatch->refcnt++;

        if (pattern_aux->kind == DISPATCH_PATTERN_SIMPLE_UNDEF) {
            duplicate = dispatch->undef_clause != DISPATCH_ON_NO_CLAUSE;
            if (!duplicate)
                dispatch->undef_clause = pattern_aux->dispatch_clause;
            continue;
        }
        if (S_dispatch_pattern_is_wildcard(aTHX_ pattern_aux)) {
            if (dispatch->default_clause == DISPATCH_ON_NO_CLAUSE) {
                dispatch->default_clause = pattern_aux->dispatch_clause;
                dispatch->default_noop =
                    S_dispatch_on_default_is_noop(target, kid);
            }
            break;
        }
        value = cSVOPx_sv(pattern);
        if (pattern_aux->kind == DISPATCH_PATTERN_SIMPLE_BOOL) {
            const U32 bool_ix = SvTRUE(value) ? 1 : 0;
            duplicate = dispatch->bool_clause[bool_ix] != DISPATCH_ON_NO_CLAUSE;
            if (!duplicate)
                dispatch->bool_clause[bool_ix] = pattern_aux->dispatch_clause;
        }
        else if (pattern_aux->kind == DISPATCH_PATTERN_SIMPLE_NUM) {
            if (SvNOK(value))
                S_dispatch_on_add_nv_bound(dispatch, value);
            else
                S_dispatch_on_add_iv_bound(dispatch, value);
            if (SvNOK(value))
                duplicate = S_dispatch_on_push(aTHX_ &dispatch->nv_values,
                    &dispatch->nv_clauses, value, pattern_aux->dispatch_clause,
                    clause_count, DISPATCH_PATTERN_SIMPLE_NUM);
            else
                duplicate = S_dispatch_on_push(aTHX_ &dispatch->iv_values,
                    &dispatch->iv_clauses, value, pattern_aux->dispatch_clause,
                    clause_count, DISPATCH_PATTERN_SIMPLE_NUM);
        }
        else {
            const STRLEN len = IN_BYTES ? SvCUR(value) : sv_len_utf8_nomg(value);
            duplicate = S_dispatch_on_store(aTHX_ &dispatch->pv_table,
                value, pattern_aux->dispatch_clause);
            if (!dispatch->pv_has_bounds) {
                dispatch->pv_minlen = len;
                dispatch->pv_maxlen = len;
                dispatch->pv_has_bounds = TRUE;
            }
            else {
                if (len < dispatch->pv_minlen)
                    dispatch->pv_minlen = len;
                if (len > dispatch->pv_maxlen)
                    dispatch->pv_maxlen = len;
            }
        }
    }

    if (dispatch->strategy != DISPATCH_ON_ARRAY_LINEAR) {
        S_dispatch_on_sort(aTHX_ dispatch->iv_values, dispatch->iv_clauses,
            DISPATCH_PATTERN_SIMPLE_NUM);
        S_dispatch_on_sort(aTHX_ dispatch->nv_values, dispatch->nv_clauses,
            DISPATCH_PATTERN_SIMPLE_NUM);
    }

    return (UNOP_AUX_item *)dispatch;
}

void
Perl_dispatch_on_free(pTHX_ UNOP_AUX_item *items)
{
    struct dispatch_on_aux *dispatch = (struct dispatch_on_aux *)items;

    PERL_ARGS_ASSERT_DISPATCH_ON_FREE;
    PERL_UNUSED_CONTEXT;
    if (!dispatch || dispatch->magic != DISPATCH_ON_AUX_MAGIC)
        return;
    /* The initial reference belongs to OP_DISPATCH; each pattern clause
     * adds one while the dispatch table is built.  The optree owns all OP
     * pointers, while the ordinary AVs own the retained table values. */
    if (--dispatch->refcnt)
        return;
    SvREFCNT_dec((SV *)dispatch->iv_values);
    SvREFCNT_dec((SV *)dispatch->iv_clauses);
    SvREFCNT_dec((SV *)dispatch->nv_values);
    SvREFCNT_dec((SV *)dispatch->nv_clauses);
    SvREFCNT_dec((SV *)dispatch->pv_table);
    PerlMemShared_free(dispatch->clause_targets);
    PerlMemShared_free(dispatch);
}

static PERL_CONTEXT *
S_dispatch_context(pTHX)
{
    I32 i;
    PERL_UNUSED_CONTEXT;
    for (i = cxstack_ix; i >= 0; i--) {
        PERL_CONTEXT *cx = &cxstack[i];
        if (CxTYPE(cx) == CXt_DISPATCH)
            return cx;
    }
    return NULL;
}

static SV *
S_dispatch_subject(pTHX)
{
    PERL_CONTEXT *cx = S_dispatch_context(aTHX);
    return cx && CxTYPE(cx) == CXt_DISPATCH
        ? cx->blk_dispatch.subject : DEFSV;
}

static void
S_dispatch_discard_bindings(pTHX_ PERL_CONTEXT *cx)
{
    if (cx->blk_dispatch.on_bindings) {
        SvREFCNT_dec((SV *)cx->blk_dispatch.on_bindings);
        cx->blk_dispatch.on_bindings = NULL;
    }
}

static void
S_dispatch_set_array(pTHX_ SV *target, AV *source)
{
    SSize_t i;
    av_clear(MUTABLE_AV(target));
    for (i = 0; i <= av_len(source); i++) {
        SV **svp = av_fetch(source, i, FALSE);
        if (svp)
            av_push(MUTABLE_AV(target), SvREFCNT_inc(*svp));
    }
}

static void
S_dispatch_set_hash(pTHX_ SV *target, HV *source)
{
    HE *he;

    hv_clear(MUTABLE_HV(target));
    (void)hv_iterinit(source);
    while ((he = hv_iternext(source)))
        (void)hv_store_ent(MUTABLE_HV(target), newSVsv(hv_iterkeysv(he)),
                           newSVsv(HeVAL(he)), 0);
}

static void
S_dispatch_commit_bindings(pTHX_ PERL_CONTEXT *cx)
{
    AV *bindings = cx->blk_dispatch.on_bindings;

    if (!bindings)
        return;
    assert(!cx->blk_dispatch.committed_bindings);
    cx->blk_dispatch.committed_bindings = bindings;
    cx->blk_dispatch.on_bindings = NULL;
}

static void
S_dispatch_rollback_bindings(pTHX_ PERL_CONTEXT *cx)
{
    AV *bindings = cx->blk_dispatch.on_bindings;
    SSize_t i;

    if (!bindings)
        return;
    for (i = 0; i + 3 <= av_len(bindings); i += 4) {
        SV **padix_sv = av_fetch(bindings, i, FALSE);
        SV **old_value_sv = av_fetch(bindings, i + 1, FALSE);
        SV **kind_sv = av_fetch(bindings, i + 2, FALSE);
        if (padix_sv && old_value_sv && kind_sv) {
            const U8 kind = (U8)SvUV(*kind_sv);
            SV *target = PAD_SV((PADOFFSET)SvUV(*padix_sv));
            if (kind == DISPATCH_BINDING_HASH) {
                if (SvREFCNT(target) > 1 || SvOBJECT(target)) {
                    PAD_SVl((PADOFFSET)SvUV(*padix_sv)) =
                        MUTABLE_SV(newHV());
                    SvREFCNT_dec(target);
                }
                else
                    hv_clear(MUTABLE_HV(target));
                continue;
            }
            /* A guard can publish a closure even when it rejects the
             * clause. Restore the pad, not the lexical the closure owns. */
            if (SvREFCNT(target) > 1 || SvOBJECT(target)) {
                SV *replacement = kind == DISPATCH_BINDING_ARRAY
                    ? MUTABLE_SV(newAV()) : newSV_type(SVt_NULL);
                PAD_SVl((PADOFFSET)SvUV(*padix_sv)) = replacement;
                SvREFCNT_dec(target);
                target = replacement;
            }
            if (kind == DISPATCH_BINDING_ARRAY)
                S_dispatch_set_array(aTHX_ target, MUTABLE_AV(SvRV(*old_value_sv)));
            else if (kind == DISPATCH_BINDING_HASH)
                hv_clear(MUTABLE_HV(target));
            else
                sv_setsv(target, *old_value_sv);
        }
    }
    S_dispatch_discard_bindings(aTHX_ cx);
}

static bool
S_dispatch_pattern_match(pTHX_ const struct dispatch_pattern_node *node, SV *value,
                      SV *pattern_value,
                      struct dispatch_binding *bindings, size_t *nbindings,
                      struct dispatch_capture_owner *owner);

static void
S_dispatch_pattern_bind_regex(pTHX_ const struct dispatch_pattern_node *node,
                          struct dispatch_binding *bindings, size_t *nbindings,
                          struct dispatch_capture_owner *owner);

static const struct dispatch_pattern_node *
S_dispatch_pattern_find_shape_node(const struct dispatch_pattern_node *node)
{
    U32 i;

    if (!node)
        return NULL;
    if (S_dispatch_pattern_empty_fields(node->op)) {
        assert(node->nchild == 1 && node->child[0]->nchild == 0);
        return node->child[0];
    }
    if (node->op->op_type == OP_LIST
        || (node->op->op_type == OP_NULL && node->op->op_targ == OP_LIST))
        return node;
    for (i = 0; i < node->nchild; i++) {
        const struct dispatch_pattern_node *shape =
            S_dispatch_pattern_find_shape_node(node->child[i]);
        if (shape)
            return shape;
    }
    return NULL;
}

static const struct dispatch_pattern_node *
S_dispatch_pattern_find_op_node(const struct dispatch_pattern_node *node, const OP *op)
{
    U32 i;

    if (!node)
        return NULL;
    if (node->op == op)
        return node;
    for (i = 0; i < node->nchild; i++) {
        const struct dispatch_pattern_node *found =
            S_dispatch_pattern_find_op_node(node->child[i], op);
        if (found)
            return found;
    }
    return NULL;
}

static bool
S_dispatch_node_is_wildcard(pTHX_ const struct dispatch_pattern_node *node)
{
    const OP *op = S_dispatch_pattern_unwrap(node)->op;
    return op->op_type == OP_CONST && (op->op_private & OPpCONST_BARE)
        && strEQ(SvPV_nolen_const(cSVOPx_sv(op)), "_");
}

static U8
S_dispatch_on_rank(pTHX_ const struct dispatch_pattern_node *node)
{
    PERL_UNUSED_CONTEXT;
    node = S_dispatch_pattern_unwrap(node);
    return node->constraint_rank;
}

static bool
S_dispatch_on_array_item(pTHX_ const struct dispatch_pattern_node *node,
                         AV *av, SSize_t index, SV *pattern_value,
                         struct dispatch_binding *bindings, size_t *nbindings,
                         struct dispatch_capture_owner *owner)
{
    SV **svp;
    if (S_dispatch_node_is_wildcard(aTHX_ node))
        return TRUE;
    if (!owner->collecting
        && S_dispatch_on_rank(aTHX_ node) == DISPATCH_CONSTRAINT_CAPTURE) {
        S_dispatch_defer_capture(aTHX_ owner, node, (SV *)av, NULL, index, 0,
                             DISPATCH_CAPTURE_ARRAY);
        return TRUE;
    }
    svp = av_fetch(av, index, FALSE);
    return S_dispatch_pattern_match(aTHX_ node, svp ? *svp : &PL_sv_undef,
                                 pattern_value, bindings, nbindings, owner);
}

static bool
S_dispatch_pattern_match_object_fields(pTHX_ const struct dispatch_pattern_node *node,
                                    SV *value,
                                    struct dispatch_binding *bindings,
                                    size_t *nbindings,
                                    struct dispatch_capture_owner *owner)
{
    HV *hv;
    HV *covered;
    const struct dispatch_pattern_node *tail = NULL;
    size_t pairs = 0;
    bool open = FALSE;

    if (!SvROK(value) || SvTYPE(SvRV(value)) != SVt_PVHV)
        return FALSE;
    hv = MUTABLE_HV(sv_2mortal(SvREFCNT_inc(SvRV(value))));
    covered = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
    {
        U32 i;
        U8 rank;
        for (rank = DISPATCH_CONSTRAINT_LITERAL;
             rank <= DISPATCH_CONSTRAINT_CAPTURE; rank++) {
        for (i = 0; i < node->nchild; i++) {
            const struct dispatch_pattern_node *keynode = node->child[i];
            const struct dispatch_pattern_node *valnode;
            HE *he;
            if (keynode->op->op_type == OP_PUSHMARK
                || (keynode->op->op_type == OP_NULL
                    && keynode->op->op_targ == OP_PUSHMARK))
                continue;
            if (S_dispatch_pattern_is_ellipsis(aTHX_ keynode->op)) {
                open = TRUE;
                continue;
            }
            if (S_dispatch_pattern_is_slurp(keynode->op)) {
                tail = keynode;
                continue;
            }
            if (i + 1 >= node->nchild)
                return FALSE;
            valnode = node->child[++i];
            if (S_dispatch_on_rank(aTHX_ valnode) != rank)
                continue;
            if (keynode->op->op_type != OP_CONST)
                return FALSE;
            (void)hv_store_ent(covered, cSVOPx_sv(keynode->op),
                               SvREFCNT_inc(&PL_sv_yes), 0);
            if (S_dispatch_node_is_wildcard(aTHX_ valnode)) {
                if (!hv_exists_ent(hv, cSVOPx_sv(keynode->op), 0))
                    return FALSE;
                pairs++;
                continue;
            }
            if (rank == DISPATCH_CONSTRAINT_CAPTURE) {
                if (!hv_exists_ent(hv, cSVOPx_sv(keynode->op), 0))
                    return FALSE;
                S_dispatch_defer_capture(aTHX_ owner, valnode, (SV *)hv,
                    cSVOPx_sv(keynode->op), 0, 0, DISPATCH_CAPTURE_HASH);
                pairs++;
                continue;
            }
            /* A tied FETCH can return undef even when the key is absent.
             * A hash shape requires presence, not just a matching value. */
            if (SvRMAGICAL(hv) && mg_find((const SV *)hv, PERL_MAGIC_tied)
                && !hv_exists_ent(hv, cSVOPx_sv(keynode->op), 0))
                return FALSE;
            he = hv_fetch_ent(hv, cSVOPx_sv(keynode->op), FALSE, 0);
            if (!he || !S_dispatch_pattern_match(aTHX_ valnode, HeVAL(he),
                                              NULL, bindings, nbindings, owner))
                return FALSE;
            pairs++;
        }
        }
    }
    if (tail) {
        if (!owner->collecting)
            S_dispatch_defer_capture(aTHX_ owner, tail, (SV *)hv,
                                 (SV *)covered, 0, 0, DISPATCH_CAPTURE_TAIL);
        return TRUE;
    }
    if (open)
        return TRUE;
    if (SvRMAGICAL(hv) && mg_find((const SV *)hv, PERL_MAGIC_tied)) {
        size_t count = 0;
        (void)hv_iterinit(hv);
        while (hv_iternext(hv))
            count++;
        return pairs == count;
    }
    return pairs == (size_t)HvUSEDKEYS(hv);
}

static bool
S_dispatch_pattern_match(pTHX_ const struct dispatch_pattern_node *node, SV *value,
                      SV *pattern_value,
                      struct dispatch_binding *bindings, size_t *nbindings,
                      struct dispatch_capture_owner *owner)
{
    const OP *pattern;
    const OP *kid;

    /* User callbacks may remove this slot from its parent. Retain the SV
     * across the entire recursive invocation; do not snapshot ordinary
     * scalars, so in-place updates remain observable. */
    sv_2mortal(SvREFCNT_inc(value));
    if (SvGMAGICAL(value)) {
        /* Capture the fetched value, not the tied scalar that supplied it.
         * Further recursion and binding publication must use this same
         * observation; user code in guards remains free to fetch again. */
        SvGETMAGIC(value);
        value = sv_2mortal(newSVsv_flags(value, 0));
    }
    if (node->comparison_mode == DISPATCH_PATTERN_COMPARE_NUMERIC) {
        const struct dispatch_pattern_node *operand_node =
            S_dispatch_pattern_unwrap(node->child[0]);
        const OP *operand = operand_node ? operand_node->op : NULL;
        SV *compare_value = NULL;
        if (operand && operand->op_type == OP_CONST)
            compare_value = cSVOPx_sv(operand);
        else if (operand && operand->op_type == OP_UNDEF)
            compare_value = &PL_sv_undef;
        else if (operand && operand->op_type == OP_DISPATCHCOERCE
                 && (operand->op_private & DISPATCH_PATTERN_CRITERION_MASK)
                     == DISPATCH_PATTERN_CRITERION_PIN
                 && operand_node->nchild) {
            const struct dispatch_pattern_node *target_node =
                S_dispatch_pattern_unwrap(operand_node->child[0]);
            const OP *target = target_node ? target_node->op : NULL;
            if (target && target->op_type == OP_PADSV)
                compare_value = S_dispatch_pattern_pin_value(aTHX_
                    target->op_targ);
        }
        if (!compare_value)
            Perl_croak(aTHX_ "invalid numeric coercion in a dispatch pattern");
        return S_dispatch_pattern_numeq(aTHX_ value, compare_value);
    }
    node = S_dispatch_pattern_unwrap(node);
    pattern = node->op;

    if (pattern->op_type == OP_SASSIGN) {
        size_t i;
        const PADOFFSET padix = node->binding_padix;
        for (i = 0; i < *nbindings; i++) {
            if (bindings[i].padix == padix)
                break;
        }
        if (i < *nbindings) {
            if (!S_dispatch_pattern_values_equal(aTHX_
                    AvARRAY(owner->values)[bindings[i].value_ix], value))
                return FALSE;
        }
        else {
            bindings[*nbindings].padix = padix;
            bindings[*nbindings].value_ix =
                S_dispatch_retain_capture(aTHX_ owner, value);
            bindings[*nbindings].kind = DISPATCH_BINDING_SCALAR;
            bindings[*nbindings].clear_on_exit = node->binding_local;
            (*nbindings)++;
        }
        return node->nchild == 1
            && S_dispatch_pattern_match(aTHX_ node->child[0], value, NULL,
                                     bindings, nbindings, owner);
    }

    if (pattern->op_type == OP_UNDEF)
        return !SvOK(value);

    if (node->object_shape) {
        const struct dispatch_pattern_node *fields =
            S_dispatch_pattern_find_shape_node(node->object_shape);
        SV *logical = NULL;
        bool matched;

        if (!node->object_class
            || !S_dispatch_pattern_is_a(aTHX_ value, node->object_class))
            return FALSE;
        if (fields) {
            if (SvTYPE(SvRV(value)) == SVt_PVOBJ)
                logical = sv_2mortal(Perl_class_object_to_hash(aTHX_ value));
            matched = S_dispatch_pattern_match_object_fields(aTHX_
                fields, logical ? logical : value, bindings, nbindings, owner);
        }
        else {
            if ((node->object_shape->op->op_type == OP_ANONHASH
                 || (node->object_shape->op->op_type == OP_EMPTYAVHV
                     && (node->object_shape->op->op_private
                         & OPpEMPTYAVHV_IS_HV)))
                && SvTYPE(SvRV(value)) == SVt_PVOBJ)
                logical = sv_2mortal(Perl_class_object_to_hash(aTHX_ value));
            matched = S_dispatch_pattern_match(aTHX_ node->object_shape,
                                            logical ? logical : value,
                                            NULL, bindings, nbindings, owner);
        }
        return matched;
    }

    if (pattern->op_type == OP_DISPATCHCOERCE
        && (pattern->op_private & DISPATCH_PATTERN_CRITERION_MASK)
            == DISPATCH_PATTERN_CRITERION_OBJECT) {
        const struct dispatch_pattern_node *args = node->nchild
            ? node->child[0] : NULL;
        const struct dispatch_pattern_node *class_node;
        const struct dispatch_pattern_node *shape_node;
        SV *logical = NULL;
        bool matched;

        if (!args || args->op->op_type != OP_LIST || args->nchild < 2)
            return FALSE;
        {
            U32 argix = 0;
            if (args->child[argix]->op->op_type == OP_PUSHMARK
                || (args->child[argix]->op->op_type == OP_NULL
                    && args->child[argix]->op->op_targ == OP_PUSHMARK))
                argix++;
            if (argix + 1 >= args->nchild)
                return FALSE;
            class_node = args->child[argix];
            shape_node = args->child[argix + 1];
        }
        if (!class_node || class_node->op->op_type != OP_CONST
            || !S_dispatch_pattern_is_a(aTHX_ value,
                cSVOPx_sv(class_node->op)))
            return FALSE;
        if (shape_node->op->op_type == OP_LIST
            || (shape_node->op->op_type == OP_NULL
                && shape_node->op->op_targ == OP_LIST))
            matched = S_dispatch_pattern_match_object_fields(aTHX_
                shape_node, value, bindings, nbindings, owner);
        else {
            if ((shape_node->op->op_type == OP_ANONHASH
                 || (shape_node->op->op_type == OP_EMPTYAVHV
                     && (shape_node->op->op_private & OPpEMPTYAVHV_IS_HV)))
                && SvTYPE(SvRV(value)) == SVt_PVOBJ)
                logical = sv_2mortal(Perl_class_object_to_hash(aTHX_ value));
            matched = S_dispatch_pattern_match(aTHX_ shape_node,
                                            logical ? logical : value,
                                            NULL, bindings, nbindings, owner);
        }
        return matched;
    }

    if (pattern->op_type == OP_REFGEN || pattern->op_type == OP_SREFGEN) {
        const struct dispatch_pattern_node *referent_pattern =
            node->nchild ? node->child[0] : NULL;

        /* A reference constructor in a data shape describes the reference
         * itself.  Descend through nested REFGENs so that \$x matches a
         * SCALAR reference and \\$x matches a reference to one.  A scalar
         * target binds the referent, not the outer reference. */
        if (!referent_pattern || !SvROK(value))
            return FALSE;
        if (SvTYPE(SvRV(value)) >= SVt_PVAV
            || isGV_with_GP(SvRV(value))
            || SvTYPE(SvRV(value)) == SVt_REGEXP)
            return FALSE;
        return S_dispatch_pattern_match(aTHX_
            referent_pattern, SvRV(value),
            NULL, bindings, nbindings, owner);
    }

    if (pattern->op_type == OP_ENTERSUB) {
        if (S_dispatch_pattern_is_predicate(aTHX_ pattern))
            return S_dispatch_pattern_predicate_call(aTHX_ pattern, value);
        SV *called = sv_2mortal(S_dispatch_pattern_call(aTHX_ pattern));
        bool matched;

        if (!SvOK(called))
            matched = !SvOK(value);
        else if (SvROK(called))
            matched = S_dispatch_pattern_values_equal(aTHX_ called, value);
        else if (SvIsBOOL(called))
            matched = SvIsBOOL(value) && SvTRUE(value) == SvTRUE(called);
        else if (!SvPOK(called) && SvNIOK(called))
            matched = ((!SvPOK(value) && SvNIOK(value) && !SvIsBOOL(value))
                       || SvAMAGIC(value))
                && do_ncmp(value, called) == 0;
        else
            matched = (SvPOK(value) || SvAMAGIC(value)) && !SvIsBOOL(value)
                && S_dispatch_pattern_streq(aTHX_ value, called, 0);
        return matched;
    }

    if (pattern->op_type == OP_DISPATCHCOERCE
        && !S_dispatch_pattern_is_slurp(pattern)
        && pattern->op_private >= 4) {
        bool matched;
        const OP *target = (pattern->op_flags & OPf_KIDS)
            ? cUNOPx(pattern)->op_first : NULL;
        const U8 criterion = pattern->op_private & DISPATCH_PATTERN_CRITERION_MASK;
        if (criterion == DISPATCH_PATTERN_CRITERION_PIN) {
            SV *pinvalue = target && target->op_type == OP_PADSV
                ? S_dispatch_pattern_pin_value(aTHX_ target->op_targ) : NULL;
            return pinvalue && S_dispatch_pattern_values_equal(aTHX_
                pinvalue, value);
        }
        if (criterion == DISPATCH_PATTERN_CRITERION_INT
            || criterion == DISPATCH_PATTERN_CRITERION_FLOAT
            || criterion == DISPATCH_PATTERN_CRITERION_INTSTR
            || criterion == DISPATCH_PATTERN_CRITERION_FLOATSTR
            || criterion == DISPATCH_PATTERN_CRITERION_NUM
            || criterion == DISPATCH_PATTERN_CRITERION_NUMSTR) {
            matched = S_dispatch_pattern_numeric_match(aTHX_ value, pattern->op_private);
        }
        else if (criterion == DISPATCH_PATTERN_CRITERION_NUMEQ) {
            const OP *arg = target;
            if (!arg || (arg->op_type != OP_CONST && arg->op_type != OP_UNDEF))
                Perl_croak(aTHX_ "NumEq() requires a literal argument in a dispatch-on pattern");
            if ((pattern->op_private & DISPATCH_PATTERN_CRITERION_STRICT)
                && !S_dispatch_pattern_strict_numeq(aTHX_ value))
                return FALSE;
            matched = do_ncmp(value,
                              arg->op_type == OP_CONST
                              ? cSVOPx_sv(arg) : &PL_sv_undef) == 0;
            return matched;
        }
        else if (criterion == DISPATCH_PATTERN_CRITERION_DEFINEDVAL)
            matched = SvOK(value);
        else if (criterion == DISPATCH_PATTERN_CRITERION_TRUE)
            matched = SvTRUE(value);
        else if (criterion == DISPATCH_PATTERN_CRITERION_FALSE)
            matched = !SvTRUE(value);
        else if (criterion == DISPATCH_PATTERN_CRITERION_REFVAL)
            matched = SvROK(value);
        else if (criterion == DISPATCH_PATTERN_CRITERION_SCALARVAL)
            matched = !SvROK(value);
        else
            matched = SvROK(value) && SvOBJECT(SvRV(value));
        if (!matched || !target)
            return matched;
        if (target->op_type != OP_PADSV)
            return FALSE;
        {
            size_t i;
            const PADOFFSET padix = target->op_targ;
            const struct dispatch_pattern_node *target_node =
                S_dispatch_pattern_find_op_node(node, target);
            for (i = 0; i < *nbindings; i++)
                if (bindings[i].padix == padix)
                    return S_dispatch_pattern_values_equal(aTHX_
                        AvARRAY(owner->values)[bindings[i].value_ix], value);
            bindings[*nbindings].padix = padix;
            bindings[*nbindings].value_ix = S_dispatch_retain_capture(aTHX_ owner, value);
            bindings[*nbindings].kind = DISPATCH_BINDING_SCALAR;
            bindings[*nbindings].clear_on_exit = target_node
                ? target_node->binding_local : TRUE;
            (*nbindings)++;
        }
        return TRUE;
    }

    if (pattern->op_type == OP_CONCAT
        || pattern->op_type == OP_MULTICONCAT) {
        return S_dispatch_pattern_concat_match(aTHX_ node, value, pattern_value,
                                            bindings, nbindings, owner);
    }

    if (pattern->op_type == OP_CONST) {
        SV *pattern_sv = cSVOPx_sv(pattern);
        if (pattern->op_private & OPpCONST_BARE
            && strEQ(SvPV_nolen_const(pattern_sv), "_"))
            return TRUE;
        if (SvIsBOOL(pattern_sv))
            return SvIsBOOL(value) && (SvTRUE(value) == SvTRUE(pattern_sv));
        if (!SvIsBOOL(pattern_sv) && !SvPOK(pattern_sv)
            && SvNIOK(pattern_sv))
            return S_dispatch_pattern_numeq(aTHX_ value, pattern_sv);
        return S_dispatch_pattern_streq(aTHX_ value, pattern_sv, 0);
    }

    if (pattern->op_type == OP_PADSV) {
        size_t i;
        const PADOFFSET padix = node->binding_padix;
        if (!owner->collecting
            && S_dispatch_on_rank(aTHX_ node) == DISPATCH_CONSTRAINT_CAPTURE) {
            S_dispatch_defer_capture(aTHX_ owner, node, value, NULL, 0, 0,
                                 DISPATCH_CAPTURE_VALUE);
            return TRUE;
        }
        for (i = 0; i < *nbindings; i++) {
            if (bindings[i].padix == padix)
                return S_dispatch_pattern_values_equal(aTHX_
                    AvARRAY(owner->values)[bindings[i].value_ix], value);
        }
        bindings[*nbindings].padix = padix;
        bindings[*nbindings].value_ix = S_dispatch_retain_capture(aTHX_ owner, value);
        bindings[*nbindings].kind = DISPATCH_BINDING_SCALAR;
        bindings[*nbindings].clear_on_exit = node->binding_local;
        (*nbindings)++;
        return TRUE;
    }

    if (pattern->op_type == OP_MATCH) {
        PMOP *pattern_pm = cPMOPx(pattern);
        PMOP *matcher = S_make_matcher(aTHX_ PM_GETRE(pattern_pm));
        const bool matched = S_matcher_matches_sv(aTHX_ matcher, value);

        S_destroy_matcher(aTHX_ matcher);
        /* Keep the retained pattern PMOP current while the clause body can
         * inspect the ordinary regexp captures ($1, %+ and friends).  The
         * temporary matcher owns no capture state of its own; it only
         * provides the stacked operand needed by pp_match().  This must be
         * done after its temporary scope is left, because that scope restores
         * PL_curpm. */
        if (matched) {
            PL_curpm = pattern_pm;
            S_dispatch_pattern_bind_regex(aTHX_ node, bindings, nbindings, owner);
        }
        return matched;
    }

    /* Empty constructors are BASEOPs, not childless LISTOPs. The compiled
     * shape already records zero children, so reuse the normal container
     * matching paths without reading an op_first from these operations.
     * This also preserves tied FETCHSIZE/key-iteration semantics. */
    if (pattern->op_type == OP_ANONLIST
        || (pattern->op_type == OP_EMPTYAVHV
            && !(pattern->op_private & OPpEMPTYAVHV_IS_HV))) {
        AV *av;
        struct dispatch_pattern_node * const *fixed = node->child;
        size_t nfixed = 0;
        bool leading_open = FALSE;
        bool trailing_open = FALSE;
        const struct dispatch_pattern_node *slurp = NULL;
        size_t i;
        U32 childix;

        if (SvROK(value) == 0 || SvTYPE(SvRV(value)) != SVt_PVAV)
            return FALSE;
        av = MUTABLE_AV(sv_2mortal(SvREFCNT_inc(SvRV(value))));
        for (childix = 0; childix < node->nchild; childix++)
        {
            const struct dispatch_pattern_node *child = node->child[childix];
            kid = child->op;
            if (kid->op_type == OP_PUSHMARK) {
                fixed++;
                continue;
            }
            if (kid->op_type == OP_CONST
                && (kid->op_flags & OPf_SPECIAL)
                && strEQ(SvPV_nolen_const(cSVOPx_sv(kid)), "...")) {
                if (nfixed == 0) {
                    if (leading_open)
                        return FALSE;
                    leading_open = TRUE;
                    fixed++;
                }
                else if (trailing_open)
                    return FALSE;
                else
                    trailing_open = TRUE;
                continue;
            }
            if (S_dispatch_pattern_is_slurp(kid)) {
                if (slurp || trailing_open || leading_open
                    || childix + 1 != node->nchild)
                    return FALSE;
                slurp = child;
                continue;
            }
            if (trailing_open)
                return FALSE;
            nfixed++;
        }

        {
            const SSize_t nvalues = AvFILL(av) + 1;
            AV *pattern_av = pattern_value && SvROK(pattern_value)
                && SvTYPE(SvRV(pattern_value)) == SVt_PVAV
                ? MUTABLE_AV(SvRV(pattern_value)) : NULL;
            SSize_t first = leading_open ? 0 : 0;
            SSize_t last = nvalues - (SSize_t)nfixed;

            if (nvalues < (SSize_t)nfixed)
                return FALSE;
            if (!leading_open && !trailing_open && nvalues != (SSize_t)nfixed)
                if (!slurp)
                    return FALSE;
            /* Candidate order remains leftmost-first, but each candidate
             * checks its anchors and other constraints before capture-only
             * locations are queued. No capture fetch is needed for a miss. */
            if (leading_open && !trailing_open)
                first = last;
            else if (!leading_open)
                last = first;
            for (; first <= last; first++) {
                const size_t saved = *nbindings;
                const size_t saved_requests = owner->nrequests;
                U8 rank;
                bool ok = TRUE;
                for (rank = DISPATCH_CONSTRAINT_LITERAL;
                     ok && rank <= DISPATCH_CONSTRAINT_CAPTURE; rank++) {
                    for (i = 0; i < nfixed; i++) {
                        SV **pattern_svp;
                        if (S_dispatch_on_rank(aTHX_ fixed[i]) != rank)
                            continue;
                        pattern_svp = pattern_av
                            ? av_fetch(pattern_av, i + (leading_open ? 1 : 0), FALSE)
                            : NULL;
                        if (!S_dispatch_on_array_item(aTHX_ fixed[i], av,
                                first + (SSize_t)i,
                                pattern_svp ? *pattern_svp : NULL,
                                bindings, nbindings, owner)) {
                            ok = FALSE;
                            break;
                        }
                    }
                }
                if (ok) {
                    if (slurp)
                        S_dispatch_defer_capture(aTHX_ owner, slurp, (SV *)av,
                            NULL, (SSize_t)nfixed, nvalues, DISPATCH_CAPTURE_TAIL);
                    return TRUE;
                }
                *nbindings = saved;
                owner->nrequests = saved_requests;
            }
            return FALSE;
        }
    }

    if (pattern->op_type == OP_ANONHASH
        || (pattern->op_type == OP_EMPTYAVHV
            && (pattern->op_private & OPpEMPTYAVHV_IS_HV))) {
        HV *hv;
        HV *pattern_hv = NULL;
        HV *covered;
        bool open = FALSE;
        const struct dispatch_pattern_node *slurp = NULL;

        if (SvROK(value) == 0 || SvTYPE(SvRV(value)) != SVt_PVHV)
            return FALSE;
        hv = MUTABLE_HV(sv_2mortal(SvREFCNT_inc(SvRV(value))));
        /* Coverage, not the number of syntactic pairs, determines exactness.
         * Runtime keys may coincide; both value constraints still apply,
         * but they cover only one subject key.  Do not diagnose collisions. */
        covered = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
        if (pattern_value && SvROK(pattern_value)
            && SvTYPE(SvRV(pattern_value)) == SVt_PVHV)
            pattern_hv = MUTABLE_HV(SvRV(pattern_value));
        {
            U32 childix;
            U8 rank;
            for (rank = DISPATCH_CONSTRAINT_LITERAL;
                 rank <= DISPATCH_CONSTRAINT_CAPTURE; rank++) {
            for (childix = 0; childix < node->nchild; childix++)
        {
            const struct dispatch_pattern_node *keynode;
            const struct dispatch_pattern_node *valnode;
            const OP *valop;
            SV *keysv;
            HE *he;
            kid = node->child[childix]->op;
            if (kid->op_type == OP_PUSHMARK)
                continue;
            if (kid->op_type == OP_CONST
                && (kid->op_flags & OPf_SPECIAL)
                && strEQ(SvPV_nolen_const(cSVOPx_sv(kid)), "...")) {
                open = TRUE;
                continue;
            }
            if (S_dispatch_pattern_is_slurp(kid)) {
                if ((slurp && slurp != node->child[childix])
                    || childix + 1 != node->nchild)
                    return FALSE;
                slurp = node->child[childix];
                continue;
            }
            keynode = node->child[childix++];
            valnode = childix < node->nchild ? node->child[childix] : NULL;
            valop = valnode ? valnode->op : NULL;
            if (!valop)
                return FALSE;
            if ((keynode->op->op_type == OP_CONST
                 ? S_dispatch_on_rank(aTHX_ valnode) : DISPATCH_CONSTRAINT_TEST) != rank)
                continue;
            keysv = (keynode->op->op_type == OP_CONST)
                ? cSVOPx_sv(keynode->op) : NULL;
            if (!keysv) {
                keysv = keynode->op->op_type == OP_ENTERSUB
                    ? S_dispatch_pattern_call(aTHX_ keynode->op)
                    : S_dispatch_pattern_concat_fixed_value(aTHX_ keynode);
                if (keysv) {
                    SV *rawkey = sv_2mortal(keysv);
                    keysv = sv_newmortal();
                    /* Fetch and coverage must use the same string, even
                     * when the key has stateful stringification overload. */
                    sv_copypv(keysv, rawkey);
                }
            }
            if (!keysv || !valop)
                return FALSE;
            if (S_dispatch_node_is_wildcard(aTHX_ valnode)) {
                if (!hv_exists_ent(hv, keysv, 0))
                    return FALSE;
                (void)hv_store_ent(covered, keysv, SvREFCNT_inc(&PL_sv_yes), 0);
                continue;
            }
            if (S_dispatch_on_rank(aTHX_ valnode) == DISPATCH_CONSTRAINT_CAPTURE) {
                if (!hv_exists_ent(hv, keysv, 0))
                    return FALSE;
                S_dispatch_defer_capture(aTHX_ owner, valnode, (SV *)hv,
                    keysv, 0, 0, DISPATCH_CAPTURE_HASH);
                (void)hv_store_ent(covered, keysv, SvREFCNT_inc(&PL_sv_yes), 0);
                continue;
            }
            if (SvRMAGICAL(hv) && mg_find((const SV *)hv, PERL_MAGIC_tied)
                && !hv_exists_ent(hv, keysv, 0))
                return FALSE;
            he = hv_fetch_ent(hv, keysv, FALSE, 0);
            {
                HE *pattern_he = pattern_hv
                    ? hv_fetch_ent(pattern_hv, keysv, FALSE, 0) : NULL;
                if (!he || !S_dispatch_pattern_match(aTHX_ valnode, HeVAL(he),
                                                  pattern_he ? HeVAL(pattern_he) : NULL,
                                                  bindings, nbindings, owner))
                    return FALSE;
            }
            (void)hv_store_ent(covered, keysv, SvREFCNT_inc(&PL_sv_yes), 0);
        }
        }
        }
        if (slurp) {
            S_dispatch_defer_capture(aTHX_ owner, slurp, (SV *)hv,
                                 NULL, 0, 0, DISPATCH_CAPTURE_TAIL);
            owner->requests[owner->nrequests - 1].key =
                sv_2mortal(SvREFCNT_inc((SV *)covered));
        }
        if (open || slurp)
            return TRUE;
        if (SvRMAGICAL(hv) && mg_find((const SV *)hv, PERL_MAGIC_tied)) {
            SSize_t count = 0;
            (void)hv_iterinit(hv);
            while (hv_iternext(hv))
                count++;
            return (SSize_t)HvUSEDKEYS(covered) == count;
        }
        return HvUSEDKEYS(covered) == HvUSEDKEYS(hv);
    }

    /* The enclosing pattern expression has already been evaluated.  For a
     * dynamic leaf, compare against the value produced for this node. */
    return pattern_value && sv_eq(value, pattern_value);
}

static void
S_dispatch_pattern_bind_regex(pTHX_ const struct dispatch_pattern_node *node,
                           struct dispatch_binding *bindings,
                           size_t *nbindings, struct dispatch_capture_owner *owner)
{
    SSize_t i;

    if (!node->regex_names || !node->regex_padixes)
        return;
    for (i = 0; i <= av_len(node->regex_names); i++) {
        SV **name_svp = av_fetch(node->regex_names, i, FALSE);
        SV **padix_svp = av_fetch(node->regex_padixes, i, FALSE);
        SV *captured;
        size_t j;

        if (!name_svp || !padix_svp)
            continue;
        captured = CALLREG_NAMED_BUFF_FETCH(
            PM_GETRE(cPMOPx(node->op)),
            *name_svp, 0);
        if (!captured)
            captured = newSVsv(&PL_sv_undef);
        for (j = 0; j < *nbindings; j++) {
            if (bindings[j].padix == (PADOFFSET)SvUV(*padix_svp)) {
                SvREFCNT_dec_NN(captured);
                break;
            }
        }
        if (j < *nbindings)
            continue;
        bindings[*nbindings].padix = (PADOFFSET)SvUV(*padix_svp);
        bindings[*nbindings].value_ix = S_dispatch_retain_capture(aTHX_
            owner, sv_2mortal(captured));
        bindings[*nbindings].kind = DISPATCH_BINDING_SCALAR;
        bindings[*nbindings].clear_on_exit = TRUE;
        (*nbindings)++;
    }
}

/* Resolve only the winning candidate's capture locations. Pattern checks
 * and regex execution have already happened; never repeat them here. */
static bool
S_dispatch_collect_captures(pTHX_ struct dispatch_capture_owner *owner,
                         struct dispatch_binding *bindings, size_t *nbindings)
{
    size_t i;
    owner->collecting = TRUE;
    for (i = 0; i < owner->nrequests; i++) {
        const struct dispatch_capture_request *request = &owner->requests[i];
        SV *value = request->source;
        SV **svp;
        HE *he;
        if (request->kind == DISPATCH_CAPTURE_ARRAY) {
            svp = av_fetch(MUTABLE_AV(value), request->index, FALSE);
            value = svp ? *svp : &PL_sv_undef;
        }
        else if (request->kind == DISPATCH_CAPTURE_HASH) {
            HV *hv = MUTABLE_HV(value);
            if (SvRMAGICAL(hv) && mg_find((const SV *)hv, PERL_MAGIC_tied)
                && !hv_exists_ent(hv, request->key, 0))
                return FALSE;
            he = hv_fetch_ent(hv, request->key, FALSE, 0);
            if (!he)
                return FALSE;
            value = HeVAL(he);
        }
        else if (request->kind == DISPATCH_CAPTURE_TAIL) {
            const struct dispatch_pattern_node *slurp = request->node;
            const OP *target = S_dispatch_pattern_slurp_target(slurp->op);
            const bool source_is_hash = SvTYPE(value) == SVt_PVHV;
            if (target->op_type == OP_PADHV) {
                HV *rest = MUTABLE_HV(sv_2mortal(MUTABLE_SV(newHV())));
                if (source_is_hash) {
                    HV *covered = MUTABLE_HV(request->key);
                    (void)hv_iterinit(MUTABLE_HV(value));
                    while ((he = hv_iternext(MUTABLE_HV(value)))) {
                        SV *key = hv_iterkeysv(he);
                        if (!hv_exists_ent(covered, key, 0))
                            (void)hv_store_ent(rest, newSVsv(key),
                                               newSVsv(HeVAL(he)), 0);
                    }
                }
                else {
                    const SSize_t start = request->index;
                    const SSize_t end = request->end;
                    SSize_t j;
                    if ((end - start) & 1) {
                        SV **first = av_fetch(MUTABLE_AV(value), start, FALSE);
                        const char *warning = first && SvROK(*first)
                            && (SvTYPE(SvRV(*first)) == SVt_PVAV
                                || SvTYPE(SvRV(*first)) == SVt_PVHV)
                            ? "Reference found where even-sized list expected"
                            : "Odd number of elements in hash assignment";
                        if (ckWARN(WARN_MISC))
                            ck_warner(packWARN(WARN_MISC), "%s", warning);
                    }
                    for (j = start; j < end; j += 2) {
                        SV **key = av_fetch(MUTABLE_AV(value), j, FALSE);
                        SV **val = j + 1 < end
                            ? av_fetch(MUTABLE_AV(value), j + 1, FALSE) : NULL;
                        (void)hv_store_ent(rest,
                            newSVsv(key ? *key : &PL_sv_undef),
                            newSVsv(val ? *val : &PL_sv_undef), 0);
                    }
                }
                bindings[*nbindings].padix = target->op_targ;
                bindings[*nbindings].value_ix =
                    S_dispatch_retain_capture(aTHX_ owner, (SV *)rest);
                bindings[*nbindings].kind = DISPATCH_BINDING_HASH;
            }
            else {
                AV *rest = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
                SSize_t j;
                if (source_is_hash) {
                    HV *covered = MUTABLE_HV(request->key);
                    (void)hv_iterinit(MUTABLE_HV(value));
                    while ((he = hv_iternext(MUTABLE_HV(value)))) {
                        SV *key = hv_iterkeysv(he);
                        if (!hv_exists_ent(covered, key, 0)) {
                            av_push(rest, newSVsv(key));
                            av_push(rest, newSVsv(HeVAL(he)));
                        }
                    }
                }
                else {
                    for (j = request->index; j < request->end; j++) {
                        svp = av_fetch(MUTABLE_AV(value), j, FALSE);
                        av_push(rest, svp ? newSVsv(*svp) : newSV(0));
                    }
                }
                bindings[*nbindings].padix = slurp->binding_padix != NOT_IN_PAD
                    ? slurp->binding_padix : target->op_targ;
                bindings[*nbindings].value_ix =
                    S_dispatch_retain_capture(aTHX_ owner, (SV *)rest);
                bindings[*nbindings].kind = DISPATCH_BINDING_ARRAY;
            }
            bindings[*nbindings].clear_on_exit = TRUE;
            (*nbindings)++;
            continue;
        }
        else
            assert(request->kind == DISPATCH_CAPTURE_VALUE);
        if (!S_dispatch_pattern_match(aTHX_ request->node, value, NULL,
                                   bindings, nbindings, owner))
            return FALSE;
    }
    return TRUE;
}

PP(pp_dispatch_on)
{
    struct dispatch_binding local_bindings[64];
    struct dispatch_capture_request local_requests[64];
    struct dispatch_binding *bindings = local_bindings;
    size_t nbindings = 0;
    struct dispatch_capture_owner capture_owner = { NULL, 0, NULL, 0, 0, FALSE };
    struct dispatch_capture_owner *owner = &capture_owner;
    PERL_CONTEXT *cx = S_dispatch_context(aTHX);
    SV *subject = S_dispatch_subject(aTHX);
    const struct dispatch_pattern_aux *aux =
        (const struct dispatch_pattern_aux *)cUNOP_AUXx(PL_op)->op_aux;
    const struct dispatch_pattern_node *pattern =
        (aux && aux->magic == DISPATCH_PATTERN_AUX_MAGIC && aux->root)
        ? aux->root : NULL;
    if (!pattern)
        Perl_croak(aTHX_ "missing compiled dispatch pattern");
    owner->reserve = aux->dispatch_capture_capacity;
    owner->requests = local_requests;
    owner->request_capacity = aux->binding_capacity;
    if (aux->binding_capacity > C_ARRAY_LENGTH(local_bindings)) {
        /* Mortal storage also releases the buffer if matching throws. */
        SV *storage = sv_2mortal(newSV(
            aux->binding_capacity * sizeof(struct dispatch_binding)));
        bindings = (struct dispatch_binding *)SvPVX(storage);
        storage = sv_2mortal(newSV(
            aux->binding_capacity * sizeof(struct dispatch_capture_request)));
        owner->requests = (struct dispatch_capture_request *)SvPVX(storage);
    }
    bool matched;
    if (cx && cx->blk_dispatch.on_active && aux->dispatch)
        matched = aux->dispatch_clause == cx->blk_dispatch.dispatch_clause;
    else if (aux->kind == DISPATCH_PATTERN_SIMPLE_UNDEF)
        matched = !SvOK(subject);
    else if (aux->kind == DISPATCH_PATTERN_SIMPLE_BOOL)
        matched = SvIsBOOL(subject)
            && (SvTRUE(subject) == SvTRUE(cSVOPx_sv(pattern->op)));
    else if (aux->kind == DISPATCH_PATTERN_SIMPLE_NUM)
        matched = S_dispatch_pattern_numeq(aTHX_ subject,
                                      cSVOPx_sv(pattern->op));
    else if (aux->kind == DISPATCH_PATTERN_SIMPLE_STR)
        matched = S_dispatch_pattern_streq(aTHX_ subject,
            cSVOPx_sv(pattern->op), SV_GMAGIC);
    else if (aux->always_matches || S_dispatch_pattern_is_wildcard(aTHX_ aux))
        matched = TRUE;
    else
        matched = S_dispatch_pattern_match(aTHX_
            pattern, subject, *PL_stack_sp,
            bindings, &nbindings, owner);
    size_t i;

    if (matched && owner->nrequests)
        matched = S_dispatch_collect_captures(aTHX_ owner, bindings, &nbindings);
    /* Recursive callbacks can grow the context stack. */
    cx = S_dispatch_context(aTHX);
    if (cx && CxTYPE(cx) == CXt_DISPATCH) {
        S_dispatch_discard_bindings(aTHX_ cx);
        if (matched && nbindings) {
            AV *pending = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
            for (i = 0; i < nbindings; i++) {
                av_push(pending, newSVuv((UV)bindings[i].padix));
                if (bindings[i].kind == DISPATCH_BINDING_ARRAY) {
                    AV *old = MUTABLE_AV(sv_2mortal(MUTABLE_SV(newAV())));
                    S_dispatch_set_array(aTHX_ (SV *)old,
                                     MUTABLE_AV(PAD_SV(bindings[i].padix)));
                    av_push(pending, newRV_inc((SV *)old));
                    av_push(pending, newSViv(1));
                    av_push(pending, newSViv(bindings[i].clear_on_exit));
                    S_dispatch_set_array(aTHX_ PAD_SV(bindings[i].padix),
                                     MUTABLE_AV(AvARRAY(owner->values)[bindings[i].value_ix]));
                }
                else if (bindings[i].kind == DISPATCH_BINDING_HASH) {
                    av_push(pending, newSV(0));
                    av_push(pending, newSViv(DISPATCH_BINDING_HASH));
                    av_push(pending, newSViv(bindings[i].clear_on_exit));
                    S_dispatch_set_hash(aTHX_ PAD_SV(bindings[i].padix),
                                    MUTABLE_HV(AvARRAY(owner->values)[bindings[i].value_ix]));
                }
                else {
                    av_push(pending, newSVsv(PAD_SV(bindings[i].padix)));
                    av_push(pending, newSViv(0));
                    av_push(pending, newSViv(bindings[i].clear_on_exit));
                    sv_setsv(PAD_SV(bindings[i].padix), AvARRAY(owner->values)[bindings[i].value_ix]);
                }
            }
            cx = S_dispatch_context(aTHX);
            cx->blk_dispatch.on_bindings = MUTABLE_AV(SvREFCNT_inc(pending));
        }
    }
    else if (matched) {
        for (i = 0; i < nbindings; i++) {
            if (bindings[i].kind == DISPATCH_BINDING_ARRAY)
                S_dispatch_set_array(aTHX_ PAD_SV(bindings[i].padix),
                                 MUTABLE_AV(AvARRAY(owner->values)[bindings[i].value_ix]));
            else if (bindings[i].kind == DISPATCH_BINDING_HASH)
                S_dispatch_set_hash(aTHX_ PAD_SV(bindings[i].padix),
                                MUTABLE_HV(AvARRAY(owner->values)[bindings[i].value_ix]));
            else
                sv_setsv(PAD_SV(bindings[i].padix), AvARRAY(owner->values)[bindings[i].value_ix]);
        }
    }

    rpp_popfree_1_NN();
    rpp_push_IMM(boolSV(matched));
    return NORMAL;
}

static void
S_dispatch_on_candidate(pTHX_ const AV *values, const AV *clauses, SV *subject,
                          U8 kind, U32 *best)
{
    SSize_t i;
    SV **value_array;
    SV **clause_array;
    const SSize_t count = values ? AvFILLp((AV *)values) + 1 : 0;
    if (!values || !clauses)
        return;
    value_array = AvARRAY((AV *)values);
    clause_array = AvARRAY((AV *)clauses);
    for (i = 0; i < count; i++) {
        SV *value = value_array[i];
        SV *clause = clause_array[i];
        bool matched = FALSE;
        if (!value || !clause)
            continue;
        switch (kind) {
        case DISPATCH_PATTERN_SIMPLE_BOOL:
            matched = SvIsBOOL(subject)
                && (SvTRUE(subject) == SvTRUE(value));
            break;
        case DISPATCH_PATTERN_SIMPLE_NUM:
            matched = S_dispatch_pattern_numeq(aTHX_ subject, value);
            break;
        case DISPATCH_PATTERN_SIMPLE_STR:
            matched = S_dispatch_pattern_streq(aTHX_ subject, value, SV_GMAGIC);
            break;
        }
        if (matched) {
            if (SvUV(clause) < *best)
                *best = (U32)SvUV(clause);
            return;
        }
    }
}

static bool
S_dispatch_on_iv_in_bounds(const struct dispatch_on_aux *dispatch,
                              SV *subject)
{
    bool is_uv;
    IV iv;
    UV uv;

    if (!dispatch->iv_has_bounds || !SvIOK(subject))
        return TRUE;
    is_uv = SvUOK(subject);
    iv = SvIVX(subject);
    uv = SvUVX(subject);
    if (dispatch->iv_min_is_uv
        ? (is_uv ? uv < dispatch->iv_min_uv
                 : iv < 0 || (UV)iv < dispatch->iv_min_uv)
        : (is_uv ? dispatch->iv_min_iv >= 0
                       && uv < (UV)dispatch->iv_min_iv
                 : iv < dispatch->iv_min_iv))
        return FALSE;
    if (dispatch->iv_max_is_uv
        ? (is_uv ? uv > dispatch->iv_max_uv
                 : iv >= 0 && (UV)iv > dispatch->iv_max_uv)
        : (is_uv ? dispatch->iv_max_iv < 0
                       || uv > (UV)dispatch->iv_max_iv
                 : iv > dispatch->iv_max_iv))
        return FALSE;
    return TRUE;
}

static bool
S_dispatch_on_nv_in_bounds(const struct dispatch_on_aux *dispatch,
                              SV *subject)
{
    NV nv;

    if (!dispatch->nv_has_bounds || !SvNOK(subject))
        return TRUE;
    nv = SvNVX(subject);
    return nv >= dispatch->nv_min && nv <= dispatch->nv_max;
}

static void
S_dispatch_on_binary_candidate(pTHX_ const AV *values, const AV *clauses,
                                  SV *subject, U8 kind, U32 *best)
{
    SSize_t lo = 0;
    SSize_t hi;
    SSize_t i;
    SV **value_array;
    SV **clause_array;
    const SSize_t count = values ? AvFILLp((AV *)values) + 1 : 0;

    if (!values || !clauses)
        return;
    value_array = AvARRAY((AV *)values);
    clause_array = AvARRAY((AV *)clauses);
    hi = count;
    while (lo < hi) {
        const SSize_t mid = lo + (hi - lo) / 2;
        SV *value = value_array[mid];
        const I32 cmp = kind == DISPATCH_PATTERN_SIMPLE_NUM
            ? S_dispatch_pattern_ncmp(aTHX_ value, subject)
            : sv_cmp(value, subject);
        if (cmp < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    for (i = lo; i < count; i++) {
        SV *value = value_array[i];
        if ((kind == DISPATCH_PATTERN_SIMPLE_NUM
             ? S_dispatch_pattern_ncmp(aTHX_ value, subject)
             : sv_cmp(value, subject)) != 0)
            break;
        if (clause_array[i] && SvUV(clause_array[i]) < *best)
            *best = (U32)SvUV(clause_array[i]);
    }
}

static void
S_dispatch_on_hv_candidate(pTHX_ const HV *table, SV *subject, U32 *best,
                             SV *key)
{
    HE *entry;

    if (!table)
        return;
    S_dispatch_on_key(aTHX_ key, subject);
    entry = hv_fetch_ent((HV *)table, key, FALSE, 0);
    if (entry && SvUV(HeVAL(entry)) < *best)
        *best = (U32)SvUV(HeVAL(entry));
}

PP(pp_dispatch)
{
    dTARGET;
    PERL_CONTEXT *cx = S_dispatch_context(aTHX);
    SV *subject = S_dispatch_subject(aTHX);
    struct dispatch_on_aux *dispatch =
        (struct dispatch_on_aux *)cUNOP_AUXx(PL_op)->op_aux;
    U32 best = DISPATCH_ON_NO_CLAUSE;

    if (!cx || CxTYPE(cx) != CXt_DISPATCH
        || !dispatch || dispatch->magic != DISPATCH_ON_AUX_MAGIC)
        return NORMAL;

    /* An overloaded subject must use the ordinary matcher.  The optimized
     * indexes cannot preserve the selected overload for ordering or equality,
     * and must not turn an overloaded comparison into raw SV data.
     */
    if (SvGMAGICAL(subject)
        || (SvROK(subject) && SvOBJECT(SvRV(subject))) || SvAMAGIC(subject)) {
        cx->blk_dispatch.on_active = FALSE;
        return NORMAL;
    }

    best = dispatch->default_clause;

    if (!SvOK(subject)
        && dispatch->undef_clause != DISPATCH_ON_NO_CLAUSE
        && dispatch->undef_clause < best)
        best = dispatch->undef_clause;
    if (SvIsBOOL(subject)
        && (dispatch->bool_clause[0] != DISPATCH_ON_NO_CLAUSE
            || dispatch->bool_clause[1] != DISPATCH_ON_NO_CLAUSE)) {
        const U32 bool_clause = SvTRUE(subject) ? dispatch->bool_clause[1]
                                           : dispatch->bool_clause[0];
        if (bool_clause != DISPATCH_ON_NO_CLAUSE && bool_clause < best)
            best = bool_clause;
    }
    if (SvOK(subject)) {
        /* Numeric and string literals use different comparison modes, but
         * either mode can match any defined non-overloaded subject. Search
         * both indexes and retain the first source-order clause. */
        if (dispatch->strategy == DISPATCH_ON_ARRAY_LINEAR) {
            if (dispatch->iv_values
                && S_dispatch_pattern_is_numerically_comparable(aTHX_ subject)
                && ((!SvPOK(subject) && SvNIOK(subject))
                    ? S_dispatch_on_iv_in_bounds(dispatch, subject) : TRUE))
                S_dispatch_on_candidate(aTHX_ dispatch->iv_values,
                    dispatch->iv_clauses, subject, DISPATCH_PATTERN_SIMPLE_NUM,
                    &best);
            if (dispatch->nv_values
                && S_dispatch_pattern_is_numerically_comparable(aTHX_ subject)
                && ((!SvPOK(subject) && SvNIOK(subject))
                    ? S_dispatch_on_nv_in_bounds(dispatch, subject) : TRUE))
                S_dispatch_on_candidate(aTHX_ dispatch->nv_values,
                    dispatch->nv_clauses, subject, DISPATCH_PATTERN_SIMPLE_NUM,
                    &best);
        }
        else {
            if (dispatch->iv_values
                && S_dispatch_pattern_is_numerically_comparable(aTHX_ subject)
                && ((!SvPOK(subject) && SvNIOK(subject))
                    ? S_dispatch_on_iv_in_bounds(dispatch, subject) : TRUE))
                S_dispatch_on_binary_candidate(aTHX_ dispatch->iv_values,
                    dispatch->iv_clauses, subject, DISPATCH_PATTERN_SIMPLE_NUM,
                    &best);
            if (dispatch->nv_values
                && S_dispatch_pattern_is_numerically_comparable(aTHX_ subject)
                && ((!SvPOK(subject) && SvNIOK(subject))
                    ? S_dispatch_on_nv_in_bounds(dispatch, subject) : TRUE))
                S_dispatch_on_binary_candidate(aTHX_ dispatch->nv_values,
                    dispatch->nv_clauses, subject, DISPATCH_PATTERN_SIMPLE_NUM,
                    &best);
        }
        if (dispatch->pv_table) {
            bool in_bounds = TRUE;
            if (SvPOK(subject)) {
                const STRLEN len = IN_BYTES
                    ? SvCUR(subject) : sv_len_utf8_nomg(subject);
                in_bounds = !dispatch->pv_has_bounds
                    || (len >= dispatch->pv_minlen
                        && len <= dispatch->pv_maxlen);
            }
            if (in_bounds)
                S_dispatch_on_hv_candidate(aTHX_ dispatch->pv_table,
                    subject, &best, TARG);
        }
    }

    cx->blk_dispatch.dispatch_clause = best;
    cx->blk_dispatch.on_active = TRUE;
    if (best == dispatch->default_clause && dispatch->default_noop
        && dispatch->miss_target)
    {
        return dispatch->miss_target;
    }
    if (best != DISPATCH_ON_NO_CLAUSE) {
        OP *target = dispatch->clause_targets[best];
        if (!(target->op_flags & OPf_SPECIAL)) {
            rpp_extend(1);
            rpp_push_IMM(&PL_sv_yes);
        }
        return target;
    }
    /* A miss follows the ordinary clause chain so that the body scope is
     * unwound before leavegiven runs.  When the scoped body has an explicit
     * leave op, jump to it and avoid executing the unreachable clause chain. */
    if (dispatch->miss_target)
        return dispatch->miss_target;
    return NORMAL;
}

PP(pp_dispatchcoerce)
{
    /* Dispatch pattern markers are consumed by the dispatch matcher. */
    return NORMAL;
}

/* Helper routines used by pp_smartmatch */
static PMOP *
S_make_matcher(pTHX_ REGEXP *re)
{
    PERL_ARGS_ASSERT_MAKE_MATCHER;

    PMOP *matcher = cPMOPx(newPMOP(OP_MATCH, OPf_WANT_SCALAR | OPf_STACKED));

    PM_SETRE(matcher, ReREFCNT_inc(re));

    SAVEFREEOP((OP *) matcher);
    ENTER_with_name("matcher"); SAVETMPS;
    SAVEOP();
    return matcher;
}

static bool
S_matcher_matches_sv(pTHX_ PMOP *matcher, SV *sv)
{
    PERL_ARGS_ASSERT_MATCHER_MATCHES_SV;

    bool result;

    PL_op = (OP *) matcher;
    rpp_xpush_1(sv);
    (void) Perl_pp_match(aTHX);
    result = SvTRUEx(*PL_stack_sp);
    rpp_popfree_1_NN();
    return result;
}

static void
S_destroy_matcher(pTHX_ PMOP *matcher)
{
    PERL_ARGS_ASSERT_DESTROY_MATCHER;
    PERL_UNUSED_ARG(matcher);

    FREETMPS;
    LEAVE_with_name("matcher");
}


/* Do a smart match */
PP(pp_smartmatch)
{
    DEBUG_M(deb("Starting smart match resolution\n"));
    return do_smartmatch(NULL, NULL, 0);
}


/* This version of do_smartmatch() implements the
 * table of smart matches that is found in perlsyn.
 */
static OP *
S_do_smartmatch(pTHX_ HV *seen_this, HV *seen_other, const bool copied)
{
    PERL_ARGS_ASSERT_DO_SMARTMATCH;

    bool object_on_left = FALSE;
    SV *e = PL_stack_sp[0];  /* e is for 'expression' */
    SV *d = PL_stack_sp[-1]; /* d is for 'default', as in PL_defgv */

    /* Take care only to invoke mg_get() once for each argument.
     * Currently we do this by copying the SV if it's magical. */
    if (d) {
        if (!copied && SvGMAGICAL(d))
            d = sv_mortalcopy(d);
    }
    else
        d = &PL_sv_undef;

    assert(e);
    if (SvGMAGICAL(e))
        e = sv_mortalcopy(e);

    /* First of all, handle overload magic of the rightmost argument */
    if (SvAMAGIC(e)) {
        SV * tmpsv;
        DEBUG_M(deb("    applying rule Any-Object\n"));
        DEBUG_M(deb("        attempting overload\n"));

        tmpsv = amagic_call(d, e, smart_amg, AMGf_noleft);
        if (tmpsv) {
            rpp_replace_2_1_NN(tmpsv);
            return NORMAL;
        }
        DEBUG_M(deb("        failed to run overload method; continuing...\n"));
    }

    /* ~~ undef */
    if (!SvOK(e)) {
        DEBUG_M(deb("    applying rule Any-undef\n"));
        if (SvOK(d))
            goto ret_no;
        else
            goto ret_yes;
    }

    if (SvROK(e) && SvOBJECT(SvRV(e)) && (SvTYPE(SvRV(e)) != SVt_REGEXP)) {
        DEBUG_M(deb("    applying rule Any-Object\n"));
        croak("Smart matching a non-overloaded object breaks encapsulation");
    }
    if (SvROK(d) && SvOBJECT(SvRV(d)) && (SvTYPE(SvRV(d)) != SVt_REGEXP))
        object_on_left = TRUE;

    /* ~~ sub */
    if (SvROK(e) && SvTYPE(SvRV(e)) == SVt_PVCV) {
        if (object_on_left) {
            goto sm_any_sub; /* Treat objects like scalars */
        }
        else if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVHV) {
            /* Test sub truth for each key */
            HE *he;
            bool andedresults = TRUE;
            HV *hv = (HV*) SvRV(d);
            I32 numkeys = hv_iterinit(hv);
            DEBUG_M(deb("    applying rule Hash-CodeRef\n"));
            if (numkeys == 0)
                goto ret_yes;
            push_stackinfo(PERLSI_SMARTMATCH, 1);
            while ( (he = hv_iternext(hv)) ) {
                DEBUG_M(deb("        testing hash key...\n"));
                ENTER_with_name("smartmatch_hash_key_test");
                SAVETMPS;
                PUSHMARK(PL_stack_sp);
                rpp_xpush_1(hv_iterkeysv(he));
                (void)call_sv(e, G_SCALAR);
                andedresults = SvTRUEx(PL_stack_sp[0]) && andedresults;
                rpp_popfree_1_NN();
                FREETMPS;
                LEAVE_with_name("smartmatch_hash_key_test");
            }
            pop_stackinfo();
            if (andedresults)
                goto ret_yes;
            else
                goto ret_no;
        }
        else if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVAV) {
            /* Test sub truth for each element */
            Size_t i;
            bool andedresults = TRUE;
            AV *av = (AV*) SvRV(d);
            const Size_t len = av_count(av);
            DEBUG_M(deb("    applying rule Array-CodeRef\n"));
            if (len == 0)
                goto ret_yes;
            push_stackinfo(PERLSI_SMARTMATCH, 1);
            for (i = 0; i < len; ++i) {
                SV * const * const svp = av_fetch(av, i, FALSE);
                DEBUG_M(deb("        testing array element...\n"));
                ENTER_with_name("smartmatch_array_elem_test");
                SAVETMPS;
                PUSHMARK(PL_stack_sp);
                if (svp)
                    rpp_xpush_1(*svp);
                (void)call_sv(e, G_SCALAR);
                andedresults = SvTRUEx(PL_stack_sp[0]) && andedresults;
                rpp_popfree_1_NN();
                FREETMPS;
                LEAVE_with_name("smartmatch_array_elem_test");
            }
            pop_stackinfo();
            if (andedresults)
                goto ret_yes;
            else
                goto ret_no;
        }
        else {
          sm_any_sub:
            DEBUG_M(deb("    applying rule Any-CodeRef\n"));
            push_stackinfo(PERLSI_SMARTMATCH, 1);
            ENTER_with_name("smartmatch_coderef");
            PUSHMARK(PL_stack_sp);
            rpp_xpush_1(d);
            (void)call_sv(e, G_SCALAR);
            LEAVE_with_name("smartmatch_coderef");
            SV *retsv = *PL_stack_sp--;
            pop_stackinfo();
            rpp_replace_2_1(retsv);
#ifdef PERL_RC_STACK
            SvREFCNT_dec(retsv);
#endif
            return NORMAL;
        }
    }
    /* ~~ %hash */
    else if (SvROK(e) && SvTYPE(SvRV(e)) == SVt_PVHV) {
        if (object_on_left) {
            goto sm_any_hash; /* Treat objects like scalars */
        }
        else if (!SvOK(d)) {
            DEBUG_M(deb("    applying rule Any-Hash ($a undef)\n"));
            goto ret_no;
        }
        else if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVHV) {
            /* Check that the key-sets are identical */
            HE *he;
            HV *other_hv = HV_FROM_REF(d);
            bool tied;
            bool other_tied;
            U32 this_key_count  = 0,
                other_key_count = 0;
            HV *hv = HV_FROM_REF(e);

            DEBUG_M(deb("    applying rule Hash-Hash\n"));
            /* Tied hashes don't know how many keys they have. */
            tied = cBOOL(SvTIED_mg((SV*)hv, PERL_MAGIC_tied));
            other_tied = cBOOL(SvTIED_mg((const SV *)other_hv, PERL_MAGIC_tied));
            if (!tied ) {
                if(other_tied) {
                    /* swap HV sides */
                    HV * const temp = other_hv;
                    other_hv = hv;
                    hv = temp;
                    tied = TRUE;
                    other_tied = FALSE;
                }
                else if(HvUSEDKEYS((const HV *) hv) != HvUSEDKEYS(other_hv))
                    goto ret_no;
            }

            /* The hashes have the same number of keys, so it suffices
               to check that one is a subset of the other. */
            (void) hv_iterinit(hv);
            while ( (he = hv_iternext(hv)) ) {
                SV *key = hv_iterkeysv(he);

                DEBUG_M(deb("        comparing hash key...\n"));
                ++ this_key_count;
                
                if(!hv_exists_ent(other_hv, key, 0)) {
                    (void) hv_iterinit(hv);	/* reset iterator */
                    goto ret_no;
                }
            }
            
            if (other_tied) {
                (void) hv_iterinit(other_hv);
                while ( hv_iternext(other_hv) )
                    ++other_key_count;
            }
            else
                other_key_count = HvUSEDKEYS(other_hv);
            
            if (this_key_count != other_key_count)
                goto ret_no;
            else
                goto ret_yes;
        }
        else if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVAV) {
            AV * const other_av = AV_FROM_REF(d);
            const Size_t other_len = av_count(other_av);
            Size_t i;
            HV *hv = HV_FROM_REF(e);

            DEBUG_M(deb("    applying rule Array-Hash\n"));
            for (i = 0; i < other_len; ++i) {
                SV ** const svp = av_fetch(other_av, i, FALSE);
                DEBUG_M(deb("        checking for key existence...\n"));
                if (svp) {	/* ??? When can this not happen? */
                    if (hv_exists_ent(hv, *svp, 0))
                        goto ret_yes;
                }
            }
            goto ret_no;
        }
        else if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_REGEXP) {
            DEBUG_M(deb("    applying rule Regex-Hash\n"));
          sm_regex_hash:
            {
                PMOP * const matcher = make_matcher((REGEXP*) SvRV(d));
                HE *he;
                HV *hv = HV_FROM_REF(e);

                (void) hv_iterinit(hv);
                while ( (he = hv_iternext(hv)) ) {
                    DEBUG_M(deb("        testing key against pattern...\n"));
                    if (matcher_matches_sv(matcher, hv_iterkeysv(he))) {
                        (void) hv_iterinit(hv);
                        destroy_matcher(matcher);
                        goto ret_yes;
                    }
                }
                destroy_matcher(matcher);
                goto ret_no;
            }
        }
        else {
          sm_any_hash:
            DEBUG_M(deb("    applying rule Any-Hash\n"));
            if (hv_exists_ent(HV_FROM_REF(e), d, 0))
                goto ret_yes;
            else
                goto ret_no;
        }
    }
    /* ~~ @array */
    else if (SvROK(e) && SvTYPE(SvRV(e)) == SVt_PVAV) {
        if (object_on_left) {
            goto sm_any_array; /* Treat objects like scalars */
        }
        else if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVHV) {
            AV * const other_av = AV_FROM_REF(e);
            const Size_t other_len = av_count(other_av);
            Size_t i;

            DEBUG_M(deb("    applying rule Hash-Array\n"));
            for (i = 0; i < other_len; ++i) {
                SV ** const svp = av_fetch(other_av, i, FALSE);

                DEBUG_M(deb("        testing for key existence...\n"));
                if (svp) {	/* ??? When can this not happen? */
                    if (hv_exists_ent(HV_FROM_REF(d), *svp, 0))
                        goto ret_yes;
                }
            }
            goto ret_no;
        }
        if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVAV) {
            AV *other_av = AV_FROM_REF(d);
            DEBUG_M(deb("    applying rule Array-Array\n"));
            if (av_count(AV_FROM_REF(e)) != av_count(other_av))
                goto ret_no;
            else {
                Size_t i;
                const Size_t other_len = av_count(other_av);

                if (NULL == seen_this) {
                    seen_this = (HV*)newSV_type_mortal(SVt_PVHV);
                }
                if (NULL == seen_other) {
                    seen_other = (HV*)newSV_type_mortal(SVt_PVHV);
                }
                for(i = 0; i < other_len; ++i) {
                    SV * const * const this_elem = av_fetch(AV_FROM_REF(e), i, FALSE);
                    SV * const * const other_elem = av_fetch(other_av, i, FALSE);

                    if (!this_elem || !other_elem) {
                        if ((this_elem && SvOK(*this_elem))
                                || (other_elem && SvOK(*other_elem)))
                            goto ret_no;
                    }
                    else if (hv_exists_ent(seen_this,
                                sv_2mortal(newSViv(PTR2IV(*this_elem))), 0) ||
                            hv_exists_ent(seen_other,
                                sv_2mortal(newSViv(PTR2IV(*other_elem))), 0))
                    {
                        if (*this_elem != *other_elem)
                            goto ret_no;
                    }
                    else {
                        (void)hv_store_ent(seen_this,
                                sv_2mortal(newSViv(PTR2IV(*this_elem))),
                                &PL_sv_undef, 0);
                        (void)hv_store_ent(seen_other,
                                sv_2mortal(newSViv(PTR2IV(*other_elem))),
                                &PL_sv_undef, 0);
                        rpp_xpush_2(*other_elem, *this_elem);
                        DEBUG_M(deb("        recursively comparing array element...\n"));
                        (void) do_smartmatch(seen_this, seen_other, 0);
                        DEBUG_M(deb("        recursion finished\n"));
                        
                         bool ok = SvTRUEx(PL_stack_sp[0]);
                         rpp_popfree_1_NN();
                        if (!ok)
                            goto ret_no;
                    }
                }
                goto ret_yes;
            }
        }
        else if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_REGEXP) {
            DEBUG_M(deb("    applying rule Regex-Array\n"));
          sm_regex_array:
            {
                PMOP * const matcher = make_matcher((REGEXP*) SvRV(d));
                const Size_t this_len = av_count(AV_FROM_REF(e));
                Size_t i;

                for(i = 0; i < this_len; ++i) {
                    SV * const * const svp = av_fetch(AV_FROM_REF(e), i, FALSE);
                    DEBUG_M(deb("        testing element against pattern...\n"));
                    if (svp && matcher_matches_sv(matcher, *svp)) {
                        destroy_matcher(matcher);
                        goto ret_yes;
                    }
                }
                destroy_matcher(matcher);
                goto ret_no;
            }
        }
        else if (!SvOK(d)) {
            /* undef ~~ array */
            const Size_t this_len = av_count(AV_FROM_REF(e));
            Size_t i;

            DEBUG_M(deb("    applying rule Undef-Array\n"));
            for (i = 0; i < this_len; ++i) {
                SV * const * const svp = av_fetch(AV_FROM_REF(e), i, FALSE);
                DEBUG_M(deb("        testing for undef element...\n"));
                if (!svp || !SvOK(*svp))
                    goto ret_yes;
            }
            goto ret_no;
        }
        else {
          sm_any_array:
            {
                Size_t i;
                const Size_t this_len = av_count(AV_FROM_REF(e));

                DEBUG_M(deb("    applying rule Any-Array\n"));
                for (i = 0; i < this_len; ++i) {
                    SV * const * const svp = av_fetch(AV_FROM_REF(e), i, FALSE);
                    if (!svp)
                        continue;

                    rpp_xpush_2(d, *svp);
                    /* infinite recursion isn't supposed to happen here */
                    DEBUG_M(deb("        recursively testing array element...\n"));
                    (void) do_smartmatch(NULL, NULL, 1);
                    DEBUG_M(deb("        recursion finished\n"));
                    bool ok = SvTRUEx(PL_stack_sp[0]);
                    rpp_popfree_1_NN();
                    if (ok)
                        goto ret_yes;
                }
                goto ret_no;
            }
        }
    }
    /* ~~ qr// */
    else if (SvROK(e) && SvTYPE(SvRV(e)) == SVt_REGEXP) {
        if (!object_on_left && SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVHV) {
            SV *t = d; d = e; e = t;
            DEBUG_M(deb("    applying rule Hash-Regex\n"));
            goto sm_regex_hash;
        }
        else if (!object_on_left && SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVAV) {
            SV *t = d; d = e; e = t;
            DEBUG_M(deb("    applying rule Array-Regex\n"));
            goto sm_regex_array;
        }
        else {
            PMOP * const matcher = make_matcher((REGEXP*) SvRV(e));
            bool result;

            DEBUG_M(deb("    applying rule Any-Regex\n"));
            result = matcher_matches_sv(matcher, d);
            destroy_matcher(matcher);
            if (result)
                goto ret_yes;
            else
                goto ret_no;
        }
    }
    /* ~~ scalar */
    /* See if there is overload magic on left */
    else if (object_on_left && SvAMAGIC(d)) {
        SV *tmpsv;
        DEBUG_M(deb("    applying rule Object-Any\n"));
        DEBUG_M(deb("        attempting overload\n"));
        tmpsv = amagic_call(d, e, smart_amg, AMGf_noright);
        if (tmpsv) {
            rpp_replace_2_1_NN(tmpsv);
            return NORMAL;
        }

        DEBUG_M(deb("        failed to run overload method; falling back...\n"));
        goto sm_any_scalar;
    }
    else if (!SvOK(d)) {
        /* undef ~~ scalar ; we already know that the scalar is SvOK */
        DEBUG_M(deb("    applying rule undef-Any\n"));
        goto ret_no;
    }
    else
  sm_any_scalar:
    if (SvNIOK(e) || (SvPOK(e) && looks_like_number(e) && SvNIOK(d))) {
        DEBUG_M(if (SvNIOK(e))
                    deb("    applying rule Any-Num\n");
                else
                    deb("    applying rule Num-numish\n");
        );
        /* numeric comparison */
        rpp_xpush_2(d, e);
        if (CopHINTS_get(PL_curcop) & HINT_INTEGER)
            (void) Perl_pp_i_eq(aTHX);
        else
            (void) Perl_pp_eq(aTHX);
        bool ok = SvTRUEx(PL_stack_sp[0]);
        rpp_popfree_1_NN();
        if (ok)
            goto ret_yes;
        else
            goto ret_no;
    }
    
    /* As a last resort, use string comparison */
    DEBUG_M(deb("    applying rule Any-Any\n"));
    rpp_xpush_2(d, e);
    Perl_pp_seq(aTHX);
    {
        bool ok = SvTRUEx(PL_stack_sp[0]);
        rpp_popfree_1_NN();
        if (ok)
            goto ret_yes;
        else
            goto ret_no;
    }

  ret_no:
    rpp_replace_2_IMM_NN(&PL_sv_no);
    return NORMAL;

  ret_yes:
    rpp_replace_2_IMM_NN(&PL_sv_yes);
    return NORMAL;
}


PP(pp_enterwhen)
{
    PERL_CONTEXT *cx;
    PERL_CONTEXT *given = S_dispatch_context(aTHX);
    const U8 gimme = GIMME_V;

    /* This is essentially an optimization: if the match
       fails, we don't want to push a context and then
       pop it again right away, so we skip straight
       to the op that follows the leavewhen.
    */
    if (!(PL_op->op_flags & OPf_SPECIAL)) { /* SPECIAL implies no condition */
        bool tr = SvTRUEx(*PL_stack_sp);
        rpp_popfree_1_NN();
        if (!tr) {
            if (given && CxTYPE(given) == CXt_DISPATCH)
                S_dispatch_rollback_bindings(aTHX_ given);
            if (gimme == G_SCALAR)
                rpp_push_IMM(&PL_sv_undef);
            return cLOGOP->op_other->op_next;
        }
    }

    if (given && CxTYPE(given) == CXt_DISPATCH)
        S_dispatch_commit_bindings(aTHX_ given);

    cx = cx_pushblock(CXt_WHEN, gimme, PL_stack_sp, PL_savestack_ix);
    cx_pushwhen(cx);

    return NORMAL;
}

PP(pp_enterdispatchon)
{
    PERL_CONTEXT *cx;
    PERL_CONTEXT *dispatchctx = S_dispatch_context(aTHX);
    const U8 gimme = GIMME_V;

    if (!(PL_op->op_flags & OPf_SPECIAL)) {
        bool matched = SvTRUEx(*PL_stack_sp);
        rpp_popfree_1_NN();
        if (!matched) {
            if (dispatchctx && CxTYPE(dispatchctx) == CXt_DISPATCH)
                S_dispatch_rollback_bindings(aTHX_ dispatchctx);
            if (gimme == G_SCALAR)
                rpp_push_IMM(&PL_sv_undef);
            return cLOGOP->op_other->op_next;
        }
    }

    if (dispatchctx && CxTYPE(dispatchctx) == CXt_DISPATCH)
        S_dispatch_commit_bindings(aTHX_ dispatchctx);

    cx = cx_pushblock(CXt_DISPATCH_ON, gimme, PL_stack_sp, PL_savestack_ix);
    cx_pushdispatchon(cx);
    return NORMAL;
}

PP(pp_leavewhen)
{
    I32 cxix;
    PERL_CONTEXT *cx;
    U8 gimme;
    SV **oldsp;

    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_WHEN);
    gimme = cx->blk_gimme;

    cxix = dopoptogivenfor(cxstack_ix);
    if (cxix < 0)
        /* diag_listed_as: Can't "when" outside a topicalizer */
        DIE(aTHX_ "Can't \"%s\" outside a topicalizer",
                   PL_op->op_flags & OPf_SPECIAL ? "default" : "when");

    oldsp = PL_stack_base + cx->blk_oldsp;
    if (gimme == G_VOID)
        rpp_popfree_to_NN(oldsp);
    else
        leave_adjust_stacks(oldsp, oldsp, gimme, 1);

    /* pop the WHEN, BLOCK and anything else before the GIVEN/FOR */
    assert(cxix < cxstack_ix);
    dounwind(cxix);

    cx = &cxstack[cxix];

    if (CxFOREACH(cx)) {
        /* emulate pp_next. Note that any stack(s) cleanup will be
         * done by the pp_unstack which op_nextop should point to */
        cx = CX_CUR();
        cx_topblock(cx);
        PL_curcop = cx->blk_oldcop;
        return cx->blk_loop.my_op->op_nextop;
    }
    else {
        PERL_ASYNC_CHECK();
        if (CxTYPE(cx) == CXt_DISPATCH) {
            assert(cx->blk_dispatch.leave_op->op_type == OP_LEAVEDISPATCH);
            return cx->blk_dispatch.leave_op;
        }
        assert(cx->blk_givwhen.leave_op->op_type == OP_LEAVEGIVEN);
        return cx->blk_givwhen.leave_op;
    }
}

PP(pp_leavedispatchon)
{
    I32 cxix;
    PERL_CONTEXT *cx;
    U8 gimme;
    SV **oldsp;

    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_DISPATCH_ON);
    gimme = cx->blk_gimme;
    oldsp = PL_stack_base + cx->blk_oldsp;

    if (gimme == G_VOID)
        rpp_popfree_to_NN(oldsp);
    else
        leave_adjust_stacks(oldsp, oldsp, gimme, 1);

    for (cxix = cxstack_ix - 1; cxix >= 0; cxix--)
        if (CxTYPE(&cxstack[cxix]) == CXt_DISPATCH)
            break;
    if (cxix < 0)
        DIE(aTHX_ "dispatch-on clause outside a dispatch");

    dounwind(cxix);
    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_DISPATCH);
    return cx->blk_dispatch.leave_op;
}

PP(pp_continue)
{
    I32 cxix;
    PERL_CONTEXT *cx;
    OP *nextop;
    
    cxix = dopoptowhen(cxstack_ix); 
    if (cxix < 0)   
        DIE(aTHX_ "Can't \"continue\" outside a when block");

    if (cxix < cxstack_ix)
        dounwind(cxix);
    
    cx = CX_CUR();
    assert(CxTYPE(cx) == CXt_WHEN);
    rpp_popfree_to_NN(PL_stack_base + cx->blk_oldsp);
    CX_LEAVE_SCOPE(cx);
    cx_popwhen(cx);
    cx_popblock(cx);
    nextop = cx->blk_givwhen.leave_op->op_next;
    CX_POP(cx);

    return nextop;
}

PP(pp_break)
{
    I32 cxix;
    PERL_CONTEXT *cx;

    cxix = dopoptogivenfor(cxstack_ix);
    if (cxix < 0)
        DIE(aTHX_ "Can't \"break\" outside a given block");

    cx = &cxstack[cxix];
    if (CxFOREACH(cx))
        DIE(aTHX_ "Can't \"break\" in a loop topicalizer");

    if (cxix < cxstack_ix)
        dounwind(cxix);

    /* Restore the sp at the time we entered the given block */
    cx = CX_CUR();
    rpp_popfree_to_NN(PL_stack_base + cx->blk_oldsp);

    return CxTYPE(cx) == CXt_DISPATCH
        ? cx->blk_dispatch.leave_op : cx->blk_givwhen.leave_op;
}

static void
invoke_defer_block_(pTHX_ U8 type, void * arg_)
{
    OP *start = cLOGOPx(arg_)->op_other;
#ifdef DEBUGGING
    I32 was_cxstack_ix = cxstack_ix;
#endif

    cx_pushblock(type, G_VOID, PL_stack_sp, PL_savestack_ix);
    CX_CUR()->blk_defer.defer_root =
        cUNOPx(cLOGOPx(arg_)->op_first)->op_first;
    ENTER;
    SAVETMPS;

    SAVEOP();
    OP *was_PL_op = PL_op;
    PL_op = start;

    dJMPENV;
    int ret;
    JMPENV_PUSH(ret);
    switch (ret) {
    case 0: /* normal start */
redo_body:
        CALLRUNOPS(aTHX);
        break;

    case 3: /* exception happened */
        if (PL_restartjmpenv == PL_top_env) {
            if (!PL_restartop)
                break;
            PL_restartjmpenv = NULL;
            PL_op = PL_restartop;
            PL_restartop = NULL;
            goto redo_body;
        }

        /* FALLTHROUGH */
    default:
        JMPENV_POP;
        PL_op = was_PL_op;
        JMPENV_JUMP(ret);
        NOT_REACHED;
    }

    JMPENV_POP;

    FREETMPS;
    LEAVE;

    {
        PERL_CONTEXT *cx;

        cx = CX_CUR();
        assert(CxTYPE(cx) == CXt_DEFER);

        /* since we're called during a scope cleanup (including after
         * a croak), theere's no guarantee thr stack is currently
         * ref-counted */
#ifdef PERL_RC_STACK
        if (rpp_stack_is_rc())
            rpp_popfree_to_NN(PL_stack_base + cx->blk_oldsp);
        else
#endif
            PL_stack_sp = PL_stack_base + cx->blk_oldsp;


        CX_LEAVE_SCOPE(cx);
        cx_popblock(cx);
        CX_POP(cx);
    }

    assert(cxstack_ix == was_cxstack_ix);
}

static void
invoke_defer_block(pTHX_ void * arg_)
{
    invoke_defer_block_(aTHX_ CXt_DEFER, arg_);
}

static void
invoke_finally_block(pTHX_ void * arg_)
{
    invoke_defer_block_(aTHX_ CXt_DEFER|CXp_FINALLY, arg_);
}

PP(pp_pushdefer)
{
    if(PL_op->op_private & OPpDEFER_FINALLY)
        SAVEDESTRUCTOR_X(invoke_finally_block, PL_op);
    else
        SAVEDESTRUCTOR_X(invoke_defer_block, PL_op);

    return NORMAL;
}

PP(pp_yield)
{
    dSP;
    dMARK;
    generator_yield_values(MARK + 1, SP - MARK);
    rpp_popfree_to_NN(MARK);
    generator_yield_suspend();
    return PL_op->op_next;
}

static MAGIC *
S_doparseform(pTHX_ SV *sv)
{
    PERL_ARGS_ASSERT_DOPARSEFORM;

    STRLEN len;
    char *s = SvPV(sv, len);
    char *send;
    char *base = NULL; /* start of current field */
    I32 skipspaces = 0; /* number of contiguous spaces seen */
    bool noblank   = FALSE; /* ~ or ~~ seen on this line */
    bool repeat    = FALSE; /* ~~ seen on this line */
    bool postspace = FALSE; /* a text field may need right padding */
    U32 *fops;
    U32 *fpc;
    U32 *linepc = NULL;	    /* position of last FF_LINEMARK */
    I32 arg;
    bool ischop;	    /* it's a ^ rather than a @ */
    bool unchopnum = FALSE; /* at least one @ (i.e. non-chop) num field seen */
    int maxops = 12; /* FF_LINEMARK + FF_END + 10 (\0 without preceding \n) */
    MAGIC *mg = NULL;
    SV *sv_copy;

    if (len == 0)
        croak("Null picture in formline");

    if (SvTYPE(sv) >= SVt_PVMG) {
        /* This might, of course, still return NULL.  */
        mg = mg_find(sv, PERL_MAGIC_fm);
    } else {
        sv_upgrade(sv, SVt_PVMG);
    }

    if (mg) {
        /* still the same as previously-compiled string? */
        SV *old = mg->mg_obj;
        if ( ! (cBOOL(SvUTF8(old)) ^ cBOOL(SvUTF8(sv)))
            && len == SvCUR(old)
            && strnEQ(SvPVX(old), s, len)
        ) {
            DEBUG_f(PerlIO_printf(Perl_debug_log,"Re-using compiled format\n"));
            return mg;
        }

        DEBUG_f(PerlIO_printf(Perl_debug_log, "Re-compiling format\n"));
        Safefree(mg->mg_ptr);
        mg->mg_ptr = NULL;
        SvREFCNT_dec(old);
        mg->mg_obj = NULL;
    }
    else {
        DEBUG_f(PerlIO_printf(Perl_debug_log, "Compiling format\n"));
        mg = sv_magicext(sv, NULL, PERL_MAGIC_fm, &PL_vtbl_fm, NULL, 0);
    }

    sv_copy = newSVpvn_utf8(s, len, SvUTF8(sv));
    s = SvPV(sv_copy, len); /* work on the copy, not the original */
    send = s + len;


    /* estimate the buffer size needed */
    for (base = s; s <= send; s++) {
        if (*s == '\n' || *s == '@' || *s == '^')
            maxops += 10;
    }
    s = base;
    base = NULL;

    Newx(fops, maxops, U32);
    fpc = fops;

    if (s < send) {
        linepc = fpc;
        *fpc++ = FF_LINEMARK;
        noblank = repeat = FALSE;
        base = s;
    }

    while (s <= send) {
        switch (*s++) {
        default:
            skipspaces = 0;
            continue;

        case '~':
            if (*s == '~') {
                repeat = TRUE;
                skipspaces++;
                s++;
            }
            noblank = TRUE;
            /* FALLTHROUGH */
        case ' ': case '\t':
            skipspaces++;
            continue;
        case 0:
            if (s < send) {
                skipspaces = 0;
                continue;
            }
            /* FALLTHROUGH */
        case '\n':
            arg = s - base;
            skipspaces++;
            arg -= skipspaces;
            if (arg) {
                if (postspace)
                    *fpc++ = FF_SPACE;
                *fpc++ = FF_LITERAL;
                *fpc++ = (U32)arg;
            }
            postspace = FALSE;
            if (s <= send)
                skipspaces--;
            if (skipspaces) {
                *fpc++ = FF_SKIP;
                *fpc++ = (U32)skipspaces;
            }
            skipspaces = 0;
            if (s <= send)
                *fpc++ = FF_NEWLINE;
            if (noblank) {
                *fpc++ = FF_BLANK;
                if (repeat)
                    arg = fpc - linepc + 1;
                else
                    arg = 0;
                *fpc++ = (U32)arg;
            }
            if (s < send) {
                linepc = fpc;
                *fpc++ = FF_LINEMARK;
                noblank = repeat = FALSE;
                base = s;
            }
            else
                s++;
            continue;

        case '@':
        case '^':
            ischop = s[-1] == '^';

            if (postspace) {
                *fpc++ = FF_SPACE;
                postspace = FALSE;
            }
            arg = (s - base) - 1;
            if (arg) {
                *fpc++ = FF_LITERAL;
                *fpc++ = (U32)arg;
            }

            base = s - 1;
            *fpc++ = FF_FETCH;
            if (*s == '*') { /*  @* or ^*  */
                s++;
                *fpc++ = 2;  /* skip the @* or ^* */
                if (ischop) {
                    *fpc++ = FF_LINESNGL;
                    *fpc++ = FF_CHOP;
                } else
                    *fpc++ = FF_LINEGLOB;
            }
            else if (*s == '#' || (*s == '.' && s[1] == '#')) { /* @###, ^### */
                arg = ischop ? FORM_NUM_BLANK : 0;
                base = s - 1;
                while (*s == '#')
                    s++;
                if (*s == '.') {
                    const char * const f = ++s;
                    while (*s == '#')
                        s++;
                    arg |= FORM_NUM_POINT + (s - f);
                }
                *fpc++ = s - base;		/* fieldsize for FETCH */
                *fpc++ = FF_DECIMAL;
                *fpc++ = (U32)arg;
                unchopnum |= ! ischop;
            }
            else if (*s == '0' && s[1] == '#') {  /* Zero padded decimals */
                arg = ischop ? FORM_NUM_BLANK : 0;
                base = s - 1;
                s++;                                /* skip the '0' first */
                while (*s == '#')
                    s++;
                if (*s == '.') {
                    const char * const f = ++s;
                    while (*s == '#')
                        s++;
                    arg |= FORM_NUM_POINT + (s - f);
                }
                *fpc++ = s - base;                /* fieldsize for FETCH */
                *fpc++ = FF_0DECIMAL;
                *fpc++ = (U32)arg;
                unchopnum |= ! ischop;
            }
            else {				/* text field */
                I32 prespace = 0;
                bool ismore = FALSE;

                if (*s == '>') {
                    while (*++s == '>') ;
                    prespace = FF_SPACE;
                }
                else if (*s == '|') {
                    while (*++s == '|') ;
                    prespace = FF_HALFSPACE;
                    postspace = TRUE;
                }
                else {
                    if (*s == '<')
                        while (*++s == '<') ;
                    postspace = TRUE;
                }
                if (*s == '.' && s[1] == '.' && s[2] == '.') {
                    s += 3;
                    ismore = TRUE;
                }
                *fpc++ = s - base;		/* fieldsize for FETCH */

                *fpc++ = ischop ? FF_CHECKCHOP : FF_CHECKNL;

                if (prespace)
                    *fpc++ = (U32)prespace; /* add SPACE or HALFSPACE */
                *fpc++ = FF_ITEM;
                if (ismore)
                    *fpc++ = FF_MORE;
                if (ischop)
                    *fpc++ = FF_CHOP;
            }
            base = s;
            skipspaces = 0;
            continue;
        }
    }
    *fpc++ = FF_END;

    assert (fpc <= fops + maxops); /* ensure our buffer estimate was valid */
    arg = fpc - fops;

    mg->mg_ptr = (char *) fops;
    mg->mg_len = arg * sizeof(U32);
    mg->mg_obj = sv_copy;
    mg->mg_flags |= MGf_REFCOUNTED;

    if (unchopnum && repeat)
        die("Repeated format line will never terminate (~~ and @#)");

    return mg;
}


static bool
S_num_overflow(NV value, I32 fldsize, I32 frcsize)
{
    PERL_ARGS_ASSERT_NUM_OVERFLOW;

    /* Can value be printed in fldsize chars, using %*.*f ? */
    NV pwr = 1;
    NV eps = 0.5;
    bool res = FALSE;
    int intsize = fldsize - (value < 0 ? 1 : 0);

    if (frcsize & FORM_NUM_POINT)
        intsize--;
    frcsize &= ~(FORM_NUM_POINT|FORM_NUM_BLANK);
    intsize -= frcsize;

    while (intsize--) pwr *= 10.0;
    while (frcsize--) eps /= 10.0;

    if( value >= 0 ){
        if (value + eps >= pwr)
            res = TRUE;
    } else {
        if (value - eps <= -pwr)
            res = TRUE;
    }
    return res;
}

static I32
S_run_user_filter(pTHX_ int idx, SV *buf_sv, int maxlen)
{
    PERL_ARGS_ASSERT_RUN_USER_FILTER;

    SV * const datasv = FILTER_DATA(idx);
    const int filter_has_file = IoLINES(datasv);
    SV * const filter_state = MUTABLE_SV(IoTOP_GV(datasv));
    SV * const filter_sub = MUTABLE_SV(IoBOTTOM_GV(datasv));
    I32 status = 0;
    SV *upstream;
    STRLEN got_len;
    char *got_p = NULL;
    char *prune_from = NULL;
    bool read_from_cache = FALSE;
    STRLEN umaxlen;
    SV *err = NULL;

    assert(maxlen >= 0);
    umaxlen = maxlen;

    /* I was having segfault trouble under Linux 2.2.5 after a
       parse error occurred.  (Had to hack around it with a test
       for PL_parser->error_count == 0.)  Solaris doesn't segfault --
       not sure where the trouble is yet.  XXX */

    {
        SV *const cache = datasv;
        if (SvOK(cache)) {
            STRLEN cache_len;
            const char *cache_p = SvPV(cache, cache_len);
            STRLEN take = 0;

            if (umaxlen) {
                /* Running in block mode and we have some cached data already.
                 */
                if (cache_len >= umaxlen) {
                    /* In fact, so much data we don't even need to call
                       filter_read.  */
                    take = umaxlen;
                }
            } else {
                const char *const first_nl =
                    (const char *)memchr(cache_p, '\n', cache_len);
                if (first_nl) {
                    take = first_nl + 1 - cache_p;
                }
            }
            if (take) {
                sv_catpvn(buf_sv, cache_p, take);
                sv_chop(cache, cache_p + take);
                /* Definitely not EOF  */
                return 1;
            }

            sv_catsv(buf_sv, cache);
            if (umaxlen) {
                umaxlen -= cache_len;
            }
            SvOK_off(cache);
            read_from_cache = TRUE;
        }
    }

    /* Filter API says that the filter appends to the contents of the buffer.
       Usually the buffer is "", so the details don't matter. But if it's not,
       then clearly what it contains is already filtered by this filter, so we
       don't want to pass it in a second time.
       I'm going to use a mortal in case the upstream filter croaks.  */
    upstream = ((SvOK(buf_sv) && sv_len(buf_sv)) || SvGMAGICAL(buf_sv))
        ? newSV_type_mortal(SVt_PV) : buf_sv;
    SvUPGRADE(upstream, SVt_PV);
        
    if (filter_has_file) {
        status = FILTER_READ(idx+1, upstream, 0);
    }

    if (filter_sub && status >= 0) {
        dSP;
        int count;

        ENTER_with_name("call_filter_sub");
        SAVE_DEFSV;
        SAVETMPS;
        EXTEND(SP, 2);

        DEFSV_set(upstream);
        PUSHMARK(SP);
        PUSHs(&PL_sv_zero);
        if (filter_state) {
            PUSHs(filter_state);
        }
        PUTBACK;
        count = call_sv(filter_sub, G_SCALAR|G_EVAL);
        SPAGAIN;

        if (count > 0) {
            SV *out = POPs;
            SvGETMAGIC(out);
            if (SvOK(out)) {
                status = SvIV(out);
            }
            else {
                SV * const errsv = ERRSV;
                if (SvTRUE_NN(errsv))
                    err = newSVsv(errsv);
            }
        }

        PUTBACK;
        FREETMPS;
        LEAVE_with_name("call_filter_sub");
    }

    if (SvGMAGICAL(upstream)) {
        mg_get(upstream);
        if (upstream == buf_sv) mg_free(buf_sv);
    }
    if (SvIsCOW(upstream)) sv_force_normal(upstream);
    if(!err && SvOK(upstream)) {
        got_p = SvPV_nomg(upstream, got_len);
        if (umaxlen) {
            if (got_len > umaxlen) {
                prune_from = got_p + umaxlen;
            }
        } else {
            char *const first_nl = (char *)memchr(got_p, '\n', got_len);
            if (first_nl && first_nl + 1 < got_p + got_len) {
                /* There's a second line here... */
                prune_from = first_nl + 1;
            }
        }
    }
    if (!err && prune_from) {
        /* Oh. Too long. Stuff some in our cache.  */
        STRLEN cached_len = got_p + got_len - prune_from;
        SV *const cache = datasv;

        if (SvOK(cache)) {
            /* Cache should be empty.  */
            assert(!SvCUR(cache));
        }

        sv_setpvn(cache, prune_from, cached_len);
        /* If you ask for block mode, you may well split UTF-8 characters.
           "If it breaks, you get to keep both parts"
           (Your code is broken if you  don't put them back together again
           before something notices.) */
        if (SvUTF8(upstream)) {
            SvUTF8_on(cache);
        }
        if (SvPOK(upstream)) SvCUR_set(upstream, got_len - cached_len);
        else
            /* Cannot just use sv_setpvn, as that could free the buffer
               before we have a chance to assign it. */
            sv_usepvn(upstream, savepvn(got_p, got_len - cached_len),
                      got_len - cached_len);
        *prune_from = 0;
        /* Can't yet be EOF  */
        if (status == 0)
            status = 1;
    }

    /* If they are at EOF but buf_sv has something in it, then they may never
       have touched the SV upstream, so it may be undefined.  If we naively
       concatenate it then we get a warning about use of uninitialised value.
    */
    if (!err && upstream != buf_sv &&
        SvOK(upstream)) {
        sv_catsv_nomg(buf_sv, upstream);
    }
    else if (SvOK(upstream)) (void)SvPV_force_nolen(buf_sv);

    if (status <= 0) {
        IoLINES(datasv) = 0;
        if (filter_state) {
            SvREFCNT_dec(filter_state);
            IoTOP_GV(datasv) = NULL;
        }
        if (filter_sub) {
            SvREFCNT_dec(filter_sub);
            IoBOTTOM_GV(datasv) = NULL;
        }
        filter_del(S_run_user_filter);
    }

    if (err)
        croak_sv(err);

    if (status == 0 && read_from_cache) {
        /* If we read some data from the cache (and by getting here it implies
           that we emptied the cache) then we aren't yet at EOF, and mustn't
           report that to our caller.  */
        return 1;
    }
    return status;
}

/*
 * ex: set ts=8 sts=4 sw=4 et:
 */
