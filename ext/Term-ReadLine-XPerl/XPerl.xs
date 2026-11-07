/*
 * XPerl.xs - glue between Term::ReadLine::XPerl and the xrl line editor
 */

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "xrl.h"

typedef struct {
    xrl_t *x;
    SV    *complete;    /* borrowed for the duration of one readline */
    SV    *dispatch;
    SV    *err;         /* exception thrown by a callback */
} xrl_perl;

typedef xrl_perl *Term__ReadLine__XPerl__C;

/* call a Perl callback in list context, trapping exceptions in self->err;
 * returns the number of results left on the stack, or -1 */
static int
xp_call(pTHX_ xrl_perl *self, SV *cb, SV **args, int nargs)
{
    dSP;
    int i, count;

    PUSHMARK(SP);
    EXTEND(SP, nargs);
    for (i = 0; i < nargs; i++)
        PUSHs(args[i]);
    PUTBACK;
    count = call_sv(cb, G_LIST | G_EVAL);
    SPAGAIN;
    /* an exception object may overload bool to false: a reference in $@
     * is always a failure */
    if (SvROK(ERRSV) || SvTRUE(ERRSV)) {
        self->err = newSVsv(ERRSV);
        SP -= count;
        PUTBACK;
        return -1;
    }
    PUTBACK;
    return count;
}

/* The Perl wrappers in XPerl.pm convert and validate every result inside
 * the G_EVAL, so they hand back only plain byte strings and integers and
 * nothing below can croak past the editor's cleanup. */

/* the Perl side returns ($start, $word, $color, $display_only, ...): each
 * word with the SGR prefix to list it in (empty for plain) and whether it
 * is only listed, never inserted */
static int
xp_complete(void *ud, const char *buf, size_t len, size_t cursor,
            xrl_completions *out)
{
    dTHX;
    xrl_perl *self = (xrl_perl *)ud;
    SV       *args[2];
    int       count, ret = 0;

    ENTER;
    SAVETMPS;
    args[0] = sv_2mortal(newSVpvn(buf, len));
    args[1] = sv_2mortal(newSVuv(cursor));
    count = xp_call(aTHX_ self, self->complete, args, 2);
    if (count < 0)
        ret = -1;
    else {
        dSP;
        SV **base = SP - count + 1;
        int  i;
        if (count > 0)
            out->start = SvUV(base[0]);
        for (i = 1; i + 2 < count; i += 3) {
            STRLEN wl, cl;
            const char *w = SvPV(base[i], wl);
            const char *col = SvPV(base[i + 1], cl);
            xrl_completions_add_colored(out, w, wl, cl ? col : NULL, cl,
                                        SvTRUE(base[i + 2]) ? 1 : 0);
        }
        SP -= count;
        PUTBACK;
    }
    FREETMPS;
    LEAVE;
    return ret;
}

/* the Perl side returns (), ('edit', $buffer, $cursor) or
 * ('submit', $text, $force) */
static int
xp_binding(void *ud, const char *seq, size_t seqlen, const char *buf,
           size_t len, size_t cursor, xrl_binding_result *res)
{
    dTHX;
    xrl_perl *self = (xrl_perl *)ud;
    SV       *args[3];
    int       count, ret = XRL_BIND_NONE;

    ENTER;
    SAVETMPS;
    args[0] = sv_2mortal(newSVpvn(seq, seqlen));
    args[1] = sv_2mortal(newSVpvn(buf, len));
    args[2] = sv_2mortal(newSVuv(cursor));
    count = xp_call(aTHX_ self, self->dispatch, args, 3);
    if (count < 0)
        ret = -1;
    else {
        dSP;
        SV **base = SP - count + 1;
        if (count >= 2) {
            const char *act = SvPV_nolen(base[0]);
            STRLEN      tl;
            const char *t = SvPV(base[1], tl);
            if ((res->text = (char *)malloc(tl + 1))) {
                memcpy(res->text, t, tl);
                res->text[tl] = '\0';
                res->len = tl;
            }
            if (strEQ(act, "submit")) {
                ret = XRL_BIND_SUBMIT;
                res->force = count > 2 && SvTRUE(base[2]);
            }
            else {
                ret = XRL_BIND_EDIT;
                res->cursor = count > 2 ? SvUV(base[2]) : tl;
            }
        }
        SP -= count;
        PUTBACK;
    }
    FREETMPS;
    LEAVE;
    return ret;
}

MODULE = Term::ReadLine::XPerl  PACKAGE = Term::ReadLine::XPerl::C  PREFIX = xp_

PROTOTYPES: DISABLE

TYPEMAP: <<END
Term__ReadLine__XPerl__C    T_XRL

INPUT
T_XRL
    if (SvROK($arg) && sv_derived_from($arg, \"Term::ReadLine::XPerl::C\"))
        $var = INT2PTR($type, SvIV(SvRV($arg)));
    else
        croak(\"\%s: not a Term::ReadLine::XPerl::C object\", \"${Package}::$func_name\");

OUTPUT
T_XRL
    sv_setref_pv($arg, \"Term::ReadLine::XPerl::C\", (void *)$var);
END

Term__ReadLine__XPerl__C
xp_new(const char *klass, int in_fd, int out_fd)
  CODE:
    PERL_UNUSED_VAR(klass);
    Newxz(RETVAL, 1, xrl_perl);
    RETVAL->x = xrl_new(in_fd, out_fd);
    if (!RETVAL->x) {
        Safefree(RETVAL);
        croak("Term::ReadLine::XPerl: out of memory");
    }
  OUTPUT:
    RETVAL

void
xp_DESTROY(Term__ReadLine__XPerl__C self)
  CODE:
    if (self->err)
        SvREFCNT_dec(self->err);
    xrl_free(self->x);
    Safefree(self);

int
xp_CLONE_SKIP(...)
  CODE:
    PERL_UNUSED_VAR(items);
    RETVAL = 1;
  OUTPUT:
    RETVAL

SV *
xp_readline(Term__ReadLine__XPerl__C self, SV *prompt, SV *preload, SV *complete, SV *dispatch, AV *seqs, int multiline)
  CODE:
    {
        char  *line;
        SSize_t i;
        self->complete = SvOK(complete) ? complete : NULL;
        self->dispatch = SvOK(dispatch) ? dispatch : NULL;
        xrl_set_completion_cb(self->x, self->complete ? xp_complete : NULL, self);
        xrl_set_binding_cb(self->x, self->dispatch ? xp_binding : NULL, self);
        xrl_unbind_all(self->x);
        for (i = 0; i <= av_top_index(seqs); i++) {
            SV **s = av_fetch(seqs, i, 0);
            if (s) {
                STRLEN sl;
                const char *p = SvPVbyte(*s, sl);
                xrl_bind(self->x, p, sl);
            }
        }
        xrl_set_multiline(self->x, multiline);
        line = xrl_readline(self->x, SvPV_nolen(prompt), SvPV_nolen(preload));
        self->complete = self->dispatch = NULL;
        xrl_set_completion_cb(self->x, NULL, NULL);
        xrl_set_binding_cb(self->x, NULL, NULL);
        if (self->err) {
            SV *err = sv_2mortal(self->err);
            self->err = NULL;
            free(line);
            croak_sv(err);
        }
        if (line) {
            RETVAL = newSVpv(line, 0);
            free(line);
        }
        else
            RETVAL = &PL_sv_undef;
    }
  OUTPUT:
    RETVAL

int
xp_history_add(Term__ReadLine__XPerl__C self, const char *line)
  CODE:
    RETVAL = xrl_history_add(self->x, line);
  OUTPUT:
    RETVAL

int
xp_history_load(Term__ReadLine__XPerl__C self, const char *path)
  CODE:
    RETVAL = xrl_history_load(self->x, path);
  OUTPUT:
    RETVAL

int
xp_history_save(Term__ReadLine__XPerl__C self, const char *path)
  CODE:
    RETVAL = xrl_history_save(self->x, path);
  OUTPUT:
    RETVAL

void
xp_history_set_max(Term__ReadLine__XPerl__C self, int max)
  CODE:
    xrl_history_set_max(self->x, max);

void
xp_history_list(Term__ReadLine__XPerl__C self)
  PPCODE:
    {
        size_t i, n = xrl_history_count(self->x);
        EXTEND(SP, (SSize_t)n);
        for (i = 0; i < n; i++)
            mPUSHp(xrl_history_get(self->x, i),
                   strlen(xrl_history_get(self->x, i)));
    }

void
xp_set_test_mode(Term__ReadLine__XPerl__C self, int cols, int rows)
  CODE:
    xrl_set_test_mode(self->x, cols, rows);

void
xp_feed(Term__ReadLine__XPerl__C self, SV *bytes)
  CODE:
    {
        STRLEN len;
        const char *p = SvPVbyte(bytes, len);
        xrl_feed(self->x, p, len);
    }

int
xp_last_cancelled(Term__ReadLine__XPerl__C self)
  CODE:
    RETVAL = xrl_last_cancelled(self->x);
  OUTPUT:
    RETVAL

int
xp_last_submit_forced(Term__ReadLine__XPerl__C self)
  CODE:
    RETVAL = xrl_last_submit_forced(self->x);
  OUTPUT:
    RETVAL

int
xp_raw_active(Term__ReadLine__XPerl__C self)
  CODE:
    RETVAL = xrl_raw_active(self->x);
  OUTPUT:
    RETVAL

int
xp_suspends(Term__ReadLine__XPerl__C self)
  CODE:
    RETVAL = xrl_suspends(self->x);
  OUTPUT:
    RETVAL

int
xp_signals_trapped(Term__ReadLine__XPerl__C self)
  CODE:
    PERL_UNUSED_VAR(self);
    RETVAL = xrl_signals_trapped();
  OUTPUT:
    RETVAL

void
xp_set_cursor_query(Term__ReadLine__XPerl__C self, int on)
  CODE:
    xrl_set_cursor_query(self->x, on);
