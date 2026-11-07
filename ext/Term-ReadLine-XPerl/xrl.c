/*
 * xrl.c - the line editor behind Term::ReadLine::XPerl
 *
 * You may distribute under the terms of either the GNU General Public
 * License or the Artistic License, as specified in the README file.
 *
 * A small self-contained line editor: termios raw mode, a VT100 escape
 * subset, UTF-8 aware editing, history, completion and key binding
 * callbacks.  It needs no library beyond libc.
 */

#include "xrl.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef XRL_HAVE_TERMIOS
#  include <termios.h>
#  include <signal.h>
#  include <sys/ioctl.h>
#  ifdef XRL_HAVE_POLL
#    include <poll.h>
#  else
#    include <sys/time.h>
#    include <sys/types.h>
#    ifdef XRL_HAVE_SYS_SELECT
#      include <sys/select.h>
#    endif
#  endif
#endif

#define XRL_HISTORY_DEFAULT_MAX 1000
#define XRL_MAX_SEQ 32           /* longest bindable key sequence */

/* ---- growable byte buffer ---------------------------------------------- */

typedef struct {
    char   *b;
    size_t  len;
    size_t  cap;
} xbuf;

struct xrl {
    int     in_fd;
    int     out_fd;

    char  **hist;
    size_t  hist_len;
    size_t  hist_max;

    int     multiline;
    int     cancelled;     /* last readline ended with ctrl-c */
    int     forced;        /* last readline was a forced submit */

    int     test_mode;     /* no termios, input from the feed queue only */
    int     test_cols;
    int     test_rows;
    xbuf    feed;
    size_t  feed_pos;

    xbuf    pushback;      /* bytes read ahead and given back */
    size_t  pushback_pos;

    xrl_completion_cb complete_cb;
    void   *complete_ud;
    xrl_binding_cb bind_cb;
    void   *bind_ud;
    xbuf   *binds;
    size_t  nbinds;
    int     aborted;       /* a callback asked to abort */

    int     cursor_query;  /* test mode: query the cursor column anyway */
    int     no_cursor_reply; /* a query timed out: do not ask again */
    int     raw_active;
    int     suspends;      /* ctrl-z presses (test mode counts, no signal) */
#ifdef XRL_HAVE_TERMIOS
    struct termios orig;
#endif
};

static int xbuf_reserve(xbuf *s, size_t extra) {
    if (s->len + extra + 1 > s->cap) {
        size_t cap = s->cap ? s->cap : 64;
        char  *nb;
        while (cap < s->len + extra + 1)
            cap *= 2;
        nb = (char *)realloc(s->b, cap);
        if (!nb)
            return -1;
        s->b   = nb;
        s->cap = cap;
    }
    return 0;
}

static int xbuf_add(xbuf *s, const char *p, size_t n) {
    if (xbuf_reserve(s, n) < 0)
        return -1;
    memcpy(s->b + s->len, p, n);
    s->len += n;
    s->b[s->len] = '\0';
    return 0;
}

static int xbuf_addc(xbuf *s, char c) {
    return xbuf_add(s, &c, 1);
}

/* ---- terminal ----------------------------------------------------------- */

static xrl_t *raw_owner;        /* the editor that currently holds raw mode */

/* fatal signals left at their default action would end the process with
 * the terminal still raw.  while raw, each is trapped by a handler that
 * restores the terminal and then dies of the signal as before. */
#ifdef XRL_HAVE_TERMIOS
static const int fatal_sigs[] = { SIGTERM, SIGHUP, SIGQUIT, SIGALRM };
#  define XRL_NFATAL (sizeof fatal_sigs / sizeof fatal_sigs[0])
static struct sigaction fatal_saved[XRL_NFATAL];
static int              fatal_trapped[XRL_NFATAL];

static void fatal_restore(int sig) {
    struct sigaction dfl;
    sigset_t         set;
    if (raw_owner && !raw_owner->test_mode)
        tcsetattr(raw_owner->in_fd, TCSANOW, &raw_owner->orig);
    memset(&dfl, 0, sizeof dfl);
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(sig, &dfl, NULL);
    sigemptyset(&set);
    sigaddset(&set, sig);
    sigprocmask(SIG_UNBLOCK, &set, NULL);
    raise(sig);
}

static void trap_fatal(void) {
    size_t i;
    for (i = 0; i < XRL_NFATAL; i++) {
        struct sigaction old, act;
        if (fatal_trapped[i] || sigaction(fatal_sigs[i], NULL, &old) < 0)
            continue;
        if ((old.sa_flags & SA_SIGINFO) || old.sa_handler != SIG_DFL)
            continue;           /* perl's handler, ignored, or someone else's */
        memset(&act, 0, sizeof act);
        act.sa_handler = fatal_restore;
        sigemptyset(&act.sa_mask);
        if (sigaction(fatal_sigs[i], &act, NULL) == 0) {
            fatal_saved[i]   = old;
            fatal_trapped[i] = 1;
        }
    }
}

/* put back the default action, unless something replaced our handler */
static void untrap_fatal(void) {
    size_t i;
    for (i = 0; i < XRL_NFATAL; i++) {
        struct sigaction cur;
        if (!fatal_trapped[i])
            continue;
        fatal_trapped[i] = 0;
        if (sigaction(fatal_sigs[i], NULL, &cur) == 0
            && !(cur.sa_flags & SA_SIGINFO) && cur.sa_handler == fatal_restore)
            sigaction(fatal_sigs[i], &fatal_saved[i], NULL);
    }
}
#endif

int xrl_signals_trapped(void) {
    int n = 0;
#ifdef XRL_HAVE_TERMIOS
    size_t i;
    for (i = 0; i < XRL_NFATAL; i++)
        n += fatal_trapped[i];
#endif
    return n;
}

static void raw_off(xrl_t *x) {
    if (!x->raw_active)
        return;
#ifdef XRL_HAVE_TERMIOS
    if (!x->test_mode)
        tcsetattr(x->in_fd, TCSADRAIN, &x->orig);
    untrap_fatal();
#endif
    x->raw_active = 0;
    if (raw_owner == x)
        raw_owner = NULL;
}

#ifdef XRL_HAVE_TERMIOS
static void restore_at_exit(void) {
    if (raw_owner)
        raw_off(raw_owner);
}
#endif

static int raw_on(xrl_t *x) {
    if (x->raw_active)
        return 0;
    if (!x->test_mode) {
#ifdef XRL_HAVE_TERMIOS
        static int registered;
        struct termios raw;
        if (tcgetattr(x->in_fd, &x->orig) < 0)
            return -1;
        raw = x->orig;
        raw.c_iflag &= ~(tcflag_t)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
        raw.c_oflag &= ~(tcflag_t)OPOST;
        raw.c_cflag |= CS8;
        raw.c_lflag &= ~(tcflag_t)(ECHO | ICANON | IEXTEN | ISIG);
        raw.c_cc[VMIN]  = 1;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(x->in_fd, TCSADRAIN, &raw) < 0)
            return -1;
        if (!registered) {
            atexit(restore_at_exit);
            registered = 1;
        }
        raw_owner = x;
#else
        return -1;
#endif
    }
#ifdef XRL_HAVE_TERMIOS
    trap_fatal();
#endif
    x->raw_active = 1;
    return 0;
}

static int term_cols(xrl_t *x) {
    if (x->test_mode)
        return x->test_cols > 0 ? x->test_cols : 80;
#if defined(XRL_HAVE_TERMIOS) && defined(TIOCGWINSZ)
    {
        struct winsize ws;
        if (ioctl(x->out_fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0)
            return ws.ws_col;
    }
#endif
    return 80;
}

static void out_write(xrl_t *x, const char *p, size_t n) {
    if (x->out_fd < 0)
        return;
    while (n) {
        ssize_t w = write(x->out_fd, p, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            return;
        p += w;
        n -= (size_t)w;
    }
}

static void xbuf_addf(xbuf *s, const char *fmt, int n) {
    char tmp[32];
    int  len = snprintf(tmp, sizeof tmp, fmt, n);
    if (len > 0)
        xbuf_add(s, tmp, (size_t)len);
}

/* ---- object --------------------------------------------------------------- */

xrl_t *xrl_new(int in_fd, int out_fd) {
    xrl_t *x = (xrl_t *)calloc(1, sizeof *x);
    if (!x)
        return NULL;
    x->in_fd    = in_fd;
    x->out_fd   = out_fd;
    x->hist_max  = XRL_HISTORY_DEFAULT_MAX;
    x->multiline = 1;
    return x;
}

void xrl_free(xrl_t *x) {
    size_t i;
    if (!x)
        return;
    raw_off(x);
    free(x->feed.b);
    free(x->pushback.b);
    xrl_unbind_all(x);
    for (i = 0; i < x->hist_len; i++)
        free(x->hist[i]);
    free(x->hist);
    free(x);
}

/* ---- history ----------------------------------------------------------- */

static void history_trim(xrl_t *x) {
    if (x->hist_len > x->hist_max) {
        size_t drop = x->hist_len - x->hist_max, i;
        for (i = 0; i < drop; i++)
            free(x->hist[i]);
        memmove(x->hist, x->hist + drop, x->hist_max * sizeof *x->hist);
        x->hist_len = x->hist_max;
    }
}

int xrl_history_add(xrl_t *x, const char *line) {
    char  *copy;
    char **nh;
    if (!line || x->hist_max == 0)
        return 0;
    if (x->hist_len && strcmp(x->hist[x->hist_len - 1], line) == 0)
        return 0;
    if (!(copy = strdup(line)))
        return 0;
    nh = (char **)realloc(x->hist, (x->hist_len + 1) * sizeof *nh);
    if (!nh) {
        free(copy);
        return 0;
    }
    x->hist = nh;
    x->hist[x->hist_len++] = copy;
    history_trim(x);
    return 1;
}

int xrl_history_set_max(xrl_t *x, int max) {
    x->hist_max = max < 0 ? 0 : (size_t)max;
    history_trim(x);
    return 1;
}

size_t xrl_history_count(xrl_t *x) {
    return x->hist_len;
}

const char *xrl_history_get(xrl_t *x, size_t idx) {
    return idx < x->hist_len ? x->hist[idx] : NULL;
}

/* file format: one entry per line; "\n" inside an entry is written as the
 * two bytes \ n and a backslash as \ \ */
int xrl_history_load(xrl_t *x, const char *path) {
    FILE *f = fopen(path, "r");
    xbuf  line = { NULL, 0, 0 };
    int   c, ok = 1;
    if (!f)
        return 0;
    for (;;) {
        c = getc(f);
        if (c == EOF || c == '\n') {
            if (line.len || c == '\n')
                xrl_history_add(x, line.b ? line.b : "");
            line.len = 0;
            if (line.b)
                line.b[0] = '\0';
            if (c == EOF)
                break;
            continue;
        }
        if (c == '\\') {
            int n = getc(f);
            if (n == 'n')
                c = '\n';
            else if (n == '\\')
                c = '\\';
            else if (n != EOF)
                ungetc(n, f);
        }
        if (xbuf_addc(&line, (char)c) < 0) {
            ok = 0;
            break;
        }
    }
    if (ferror(f))
        ok = 0;
    fclose(f);
    free(line.b);
    return ok;
}

/* the file is written beside path under a new name and renamed over it,
 * so a write cut short (a full disk, a signal) never leaves half a
 * history behind */
int xrl_history_save(xrl_t *x, const char *path) {
    size_t plen = strlen(path);
    char  *tmp  = (char *)malloc(plen + 40);
    int    fd   = -1, attempt;
    FILE  *f;
    size_t i;
    int    ok = 1;
    if (!tmp)
        return 0;
    for (attempt = 0; attempt < 100 && fd < 0; attempt++) {
        sprintf(tmp, "%s.%ld.%d.tmp", path, (long)getpid(), attempt);
        fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0 && errno != EEXIST)
            break;
    }
    if (fd < 0) {
        free(tmp);
        return 0;
    }
    if (!(f = fdopen(fd, "w"))) {
        close(fd);
        unlink(tmp);
        free(tmp);
        return 0;
    }
    for (i = 0; i < x->hist_len; i++) {
        const char *p;
        for (p = x->hist[i]; *p; p++) {
            if (*p == '\n')
                fputs("\\n", f);
            else if (*p == '\\')
                fputs("\\\\", f);
            else
                putc(*p, f);
        }
        putc('\n', f);
    }
    if (ferror(f))
        ok = 0;
    if (fclose(f) != 0)
        ok = 0;
    if (ok && rename(tmp, path) != 0)
        ok = 0;
    if (!ok)
        unlink(tmp);
    free(tmp);
    return ok;
}

/* ---- reading ------------------------------------------------------------ */

/* read one line with read(2), no echo and no editing */
static char *read_plain_line(xrl_t *x) {
    xbuf line = { NULL, 0, 0 };
    int  got_any = 0;
    for (;;) {
        char    c;
        ssize_t r = read(x->in_fd, &c, 1);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            break;
        got_any = 1;
        if (c == '\n')
            break;
        if (xbuf_addc(&line, c) < 0) {
            free(line.b);
            return NULL;
        }
    }
    if (!got_any)
        return NULL;
    return line.b ? line.b : strdup("");
}
/* ---- input -------------------------------------------------------------- */

void xrl_set_test_mode(xrl_t *x, int cols, int rows) {
    x->test_mode = 1;
    x->test_cols = cols;
    x->test_rows = rows;
}

void xrl_feed(xrl_t *x, const char *bytes, size_t len) {
    if (x->feed_pos && x->feed_pos == x->feed.len)
        x->feed.len = x->feed_pos = 0;
    xbuf_add(&x->feed, bytes, len);
}

int xrl_last_cancelled(xrl_t *x)     { return x->cancelled; }
int xrl_last_submit_forced(xrl_t *x) { return x->forced; }
int xrl_raw_active(xrl_t *x)         { return x->raw_active; }
int xrl_suspends(xrl_t *x)           { return x->suspends; }

void xrl_set_multiline(xrl_t *x, int on) {
    x->multiline = on ? 1 : 0;
}

void xrl_set_completion_cb(xrl_t *x, xrl_completion_cb cb, void *ud) {
    x->complete_cb = cb;
    x->complete_ud = ud;
}

void xrl_set_binding_cb(xrl_t *x, xrl_binding_cb cb, void *ud) {
    x->bind_cb = cb;
    x->bind_ud = ud;
}

int xrl_bind(xrl_t *x, const char *seq, size_t len) {
    xbuf *nb;
    if (!len || len > XRL_MAX_SEQ)
        return 0;
    nb = (xbuf *)realloc(x->binds, (x->nbinds + 1) * sizeof *nb);
    if (!nb)
        return 0;
    x->binds = nb;
    memset(&nb[x->nbinds], 0, sizeof *nb);
    if (xbuf_add(&nb[x->nbinds], seq, len) < 0)
        return 0;
    x->nbinds++;
    return 1;
}

void xrl_unbind_all(xrl_t *x) {
    size_t i;
    for (i = 0; i < x->nbinds; i++)
        free(x->binds[i].b);
    free(x->binds);
    x->binds  = NULL;
    x->nbinds = 0;
}

static char *copy_bytes(const char *p, size_t len) {
    char *copy = (char *)malloc(len + 1);
    if (copy) {
        memcpy(copy, p, len);
        copy[len] = '\0';
    }
    return copy;
}

int xrl_completions_add_colored(xrl_completions *c, const char *w, size_t len,
                                const char *color, size_t colorlen,
                                int display_only) {
    char **nw, **nc, *word, *col = NULL;
    int   *nd;
    if (!(nw = (char **)realloc(c->words, (c->count + 1) * sizeof *nw)))
        return -1;
    c->words = nw;
    if (!(nc = (char **)realloc(c->colors, (c->count + 1) * sizeof *nc)))
        return -1;
    c->colors = nc;
    if (!(nd = (int *)realloc(c->display, (c->count + 1) * sizeof *nd)))
        return -1;
    c->display = nd;
    if (!(word = copy_bytes(w, len)))
        return -1;
    if (color && colorlen && !(col = copy_bytes(color, colorlen))) {
        free(word);
        return -1;
    }
    c->words[c->count]     = word;
    c->colors[c->count]    = col;
    c->display[c->count++] = display_only ? 1 : 0;
    return 0;
}

int xrl_completions_add(xrl_completions *c, const char *w, size_t len) {
    return xrl_completions_add_colored(c, w, len, NULL, 0, 0);
}

static void completions_free(xrl_completions *c) {
    size_t i;
    for (i = 0; i < c->count; i++) {
        free(c->words[i]);
        free(c->colors[i]);
    }
    free(c->words);
    free(c->colors);
    free(c->display);
    memset(c, 0, sizeof *c);
}

/* give bytes back to the input, to be read again before anything else */
static void unread(xrl_t *x, const char *p, size_t n) {
    xbuf rest = { NULL, 0, 0 };
    if (x->pushback_pos < x->pushback.len)
        xbuf_add(&rest, x->pushback.b + x->pushback_pos,
                 x->pushback.len - x->pushback_pos);
    x->pushback.len = x->pushback_pos = 0;
    xbuf_add(&x->pushback, p, n);
    if (rest.len)
        xbuf_add(&x->pushback, rest.b, rest.len);
    free(rest.b);
}

/* the next input byte: given-back bytes, queued test input, the terminal */
static int read_byte(xrl_t *x) {
    if (x->pushback_pos < x->pushback.len)
        return (unsigned char)x->pushback.b[x->pushback_pos++];
    if (x->feed_pos < x->feed.len)
        return (unsigned char)x->feed.b[x->feed_pos++];
    if (x->test_mode)
        return -1;
    for (;;) {
        unsigned char c;
        ssize_t       r = read(x->in_fd, &c, 1);
        if (r == 1)
            return c;
        if (r < 0 && errno == EINTR)
            continue;
        return -1;
    }
}

enum {
    KEY_EOF = -1,
    KEY_IGNORE = 0x110000,
    KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_DELETE,
    KEY_ALT_B, KEY_ALT_F, KEY_ALT_D, KEY_ALT_ENTER, KEY_BINDING
};

static int read_escape(xrl_t *x) {
    int c = read_byte(x);
    if (c < 0)
        return KEY_EOF;
    if (c == '[') {
        int param = 0, n;
        for (;;) {          /* parameter and intermediate bytes, then final */
            n = read_byte(x);
            if (n < 0)
                return KEY_EOF;
            if (n >= '0' && n <= '9') {
                if (param < 1000)
                    param = param * 10 + (n - '0');
            }
            else if (n == ';')
                param = 10000;
            else if (n < 0x40 || n > 0x7e)
                continue;
            else
                break;
        }
        if (param >= 10000)         /* modified keys: ignored */
            return KEY_IGNORE;
        switch (n) {
        case 'A': return KEY_UP;
        case 'B': return KEY_DOWN;
        case 'C': return KEY_RIGHT;
        case 'D': return KEY_LEFT;
        case 'H': return KEY_HOME;
        case 'F': return KEY_END;
        case '~':
            switch (param) {
            case 1: case 7: return KEY_HOME;
            case 4: case 8: return KEY_END;
            case 3:         return KEY_DELETE;
            }
        }
        return KEY_IGNORE;
    }
    if (c == 'O') {
        int n = read_byte(x);
        switch (n) {
        case -1:  return KEY_EOF;
        case 'A': return KEY_UP;
        case 'B': return KEY_DOWN;
        case 'C': return KEY_RIGHT;
        case 'D': return KEY_LEFT;
        case 'H': return KEY_HOME;
        case 'F': return KEY_END;
        }
        return KEY_IGNORE;
    }
    switch (c) {
    case 'b': return KEY_ALT_B;
    case 'f': return KEY_ALT_F;
    case 'd': return KEY_ALT_D;
    case '\r': return KEY_ALT_ENTER;
    }
    return KEY_IGNORE;
}

void xrl_set_cursor_query(xrl_t *x, int on) {
    x->cursor_query = on ? 1 : 0;
}

/* like read_byte, but wait at most ms milliseconds for the terminal */
static int read_byte_timeout(xrl_t *x, int ms) {
    if (x->pushback_pos < x->pushback.len || x->feed_pos < x->feed.len
        || x->test_mode)
        return read_byte(x);
#if defined(XRL_HAVE_TERMIOS) && defined(XRL_HAVE_POLL)
    {
        struct pollfd p;
        int           r;
        p.fd      = x->in_fd;
        p.events  = POLLIN;
        p.revents = 0;
        do
            r = poll(&p, 1, ms);
        while (r < 0 && errno == EINTR);
        if (r <= 0)
            return -1;
    }
#elif defined(XRL_HAVE_TERMIOS)
    {
        fd_set         set;
        struct timeval tv;
        int            r;
        do {
            FD_ZERO(&set);
            FD_SET(x->in_fd, &set);
            tv.tv_sec  = ms / 1000;
            tv.tv_usec = (ms % 1000) * 1000;
            r = select(x->in_fd + 1, &set, NULL, NULL, &tv);
        } while (r < 0 && errno == EINTR);
        if (r <= 0)
            return -1;
    }
#else
    (void)ms;
#endif
    return read_byte(x);
}

/* ask the terminal where the cursor is (ESC [ 6 n, answered by
 * ESC [ row ; col R) and start a fresh row when earlier output left the
 * cursor mid-line; anything other than the answer is given back as input;
 * a query that gets no reply at all is not repeated */
static void fresh_line(xrl_t *x) {
    char   r[32];
    size_t n = 0;
    int    col = 0, semi = 0;
    out_write(x, "\033[6n", 4);
    while (n < sizeof r) {
        int c = read_byte_timeout(x, 100);
        if (c < 0)
{
            if (n == 0)     /* nothing at all: the terminal does not answer */
                x->no_cursor_reply = 1;
            break;
        }
        r[n++] = (char)c;
        if ((n == 1 && c != '\033') || (n == 2 && c != '['))
            break;
        if (n > 2) {
            if (c == 'R' && semi)
                break;
            if (c == ';' && !semi)
                semi = 1;
            else if (c >= '0' && c <= '9') {
                if (semi && col < 10000)
                    col = col * 10 + (c - '0');
            }
            else
                break;
        }
    }
    if (n < 3 || r[n - 1] != 'R' || !semi) {
        if (n)
            unread(x, r, n);
        return;
    }
    if (col > 1)
        out_write(x, "\r\n", 2);
}

/* ---- editing ------------------------------------------------------------ */

typedef struct {
    xrl_t      *x;
    const char *prompt;
    xbuf        buf;
    size_t      pos;
    int         oldrow;     /* cursor row, relative to the prompt row */
    int         pending;    /* a key to handle before reading more, or 0 */
    int         cur_key;
    int         last_key;   /* the key handled before the current one */
    int         no_bindings;
    char        seq[XRL_MAX_SEQ];   /* the key sequence of KEY_BINDING */
    size_t      seqlen;
    int         navigating; /* walking the history with up/down */
    size_t      hist_idx;
    xbuf        nav_saved;  /* the typed text navigation started from */
} xrl_edit;

/* 2: seq is a bound sequence, 1: a proper prefix of one, 0: neither */
static int binding_match(xrl_t *x, const char *seq, size_t n) {
    size_t i;
    int    r = 0;
    for (i = 0; i < x->nbinds; i++) {
        const xbuf *b = &x->binds[i];
        if (b->len >= n && memcmp(b->b, seq, n) == 0) {
            if (b->len == n)
                return 2;
            r = 1;
        }
    }
    return r;
}

static int read_key(xrl_edit *e) {
    xrl_t *x = e->x;
    int    c;
    if (e->pending) {
        c = e->pending;
        e->pending = 0;
        return c;
    }
    c = read_byte(x);
    if (c < 0)
        return KEY_EOF;
    if (x->nbinds && x->bind_cb && !e->no_bindings) {
        size_t n = 0;
        e->seq[n++] = (char)c;
        for (;;) {
            int m = binding_match(x, e->seq, n), b;
            if (m == 2) {
                e->seqlen = n;
                return KEY_BINDING;
            }
            if (m == 0 || n == sizeof e->seq || (b = read_byte(x)) < 0)
                break;
            e->seq[n++] = (char)b;
        }
        if (n > 1)
            unread(x, e->seq + 1, n - 1);
    }
    if (c == '\033')
        return read_escape(x);
    return c;
}

static int is_char_start(char c) {
    return ((unsigned char)c & 0xC0) != 0x80;
}

/* ---- UTF-8 and display width -------------------------------------------- */

/* decode the UTF-8 character at p; an invalid byte decodes as itself */
static unsigned long decode_char(const char *p, size_t avail, size_t *adv) {
    const unsigned char *s = (const unsigned char *)p;
    unsigned long        cp;
    size_t               n, i;
    if (s[0] < 0x80)      { *adv = 1; return s[0]; }
    else if (s[0] < 0xC2) { *adv = 1; return s[0]; }
    else if (s[0] < 0xE0) { n = 2; cp = s[0] & 0x1F; }
    else if (s[0] < 0xF0) { n = 3; cp = s[0] & 0x0F; }
    else if (s[0] < 0xF5) { n = 4; cp = s[0] & 0x07; }
    else                  { *adv = 1; return s[0]; }
    if (n > avail) {
        *adv = 1;
        return s[0];
    }
    for (i = 1; i < n; i++) {
        if ((s[i] & 0xC0) != 0x80) {
            *adv = 1;
            return s[0];
        }
        cp = (cp << 6) | (s[i] & 0x3F);
    }
    *adv = n;
    return cp;
}

typedef struct { unsigned long lo, hi; } xrl_range;

/* combining and other zero-width code points (the common blocks) */
static const xrl_range zero_width[] = {
    { 0x0300, 0x036F }, { 0x0483, 0x0489 }, { 0x0591, 0x05BD },
    { 0x05BF, 0x05C7 }, { 0x0610, 0x061A }, { 0x064B, 0x065F },
    { 0x0670, 0x0670 }, { 0x06D6, 0x06ED }, { 0x0900, 0x0903 },
    { 0x093A, 0x094F }, { 0x0951, 0x0957 }, { 0x0E31, 0x0E31 },
    { 0x0E34, 0x0E3A }, { 0x0E47, 0x0E4E }, { 0x1AB0, 0x1AFF },
    { 0x1DC0, 0x1DFF }, { 0x200B, 0x200F }, { 0x202A, 0x202E },
    { 0x2060, 0x2064 }, { 0x20D0, 0x20FF }, { 0x302A, 0x302F },
    { 0x3099, 0x309A }, { 0xFE00, 0xFE0F }, { 0xFE20, 0xFE2F },
    { 0xFEFF, 0xFEFF }, { 0x1F3FB, 0x1F3FF }, { 0xE0000, 0xE0FFF },
};

/* East Asian Wide and Fullwidth, and emoji presentation blocks */
static const xrl_range double_width[] = {
    { 0x1100, 0x115F }, { 0x231A, 0x231B }, { 0x2329, 0x232A },
    { 0x23E9, 0x23EC }, { 0x23F0, 0x23F3 }, { 0x25FD, 0x25FE },
    { 0x2614, 0x2615 }, { 0x2648, 0x2653 }, { 0x26AA, 0x26AB },
    { 0x26BD, 0x26BE }, { 0x26C4, 0x26C5 }, { 0x26F2, 0x26F5 },
    { 0x26FA, 0x26FD }, { 0x2705, 0x2705 }, { 0x270A, 0x270B },
    { 0x2728, 0x2728 }, { 0x274C, 0x274C }, { 0x2753, 0x2757 },
    { 0x2795, 0x2797 }, { 0x27B0, 0x27B0 }, { 0x27BF, 0x27BF },
    { 0x2B1B, 0x2B1C }, { 0x2B50, 0x2B55 }, { 0x2E80, 0x303E },
    { 0x3041, 0x3247 }, { 0x3250, 0x4DBF }, { 0x4E00, 0xA4CF },
    { 0xA960, 0xA97F }, { 0xAC00, 0xD7A3 }, { 0xF900, 0xFAFF },
    { 0xFE10, 0xFE19 }, { 0xFE30, 0xFE6F }, { 0xFF00, 0xFF60 },
    { 0xFFE0, 0xFFE6 }, { 0x16FE0, 0x18CFF }, { 0x1B000, 0x1B2FF },
    { 0x1F004, 0x1F004 }, { 0x1F0CF, 0x1F0CF }, { 0x1F18E, 0x1F18E },
    { 0x1F191, 0x1F19A }, { 0x1F200, 0x1F2FF }, { 0x1F300, 0x1F320 },
    { 0x1F32D, 0x1F335 }, { 0x1F337, 0x1F37C }, { 0x1F37E, 0x1F393 },
    { 0x1F3A0, 0x1F3CA }, { 0x1F3CF, 0x1F3D3 }, { 0x1F3E0, 0x1F3F0 },
    { 0x1F3F4, 0x1F3F4 }, { 0x1F3F8, 0x1F3FA }, { 0x1F400, 0x1F43E },
    { 0x1F440, 0x1F440 }, { 0x1F442, 0x1F4FC }, { 0x1F4FF, 0x1F53D },
    { 0x1F54B, 0x1F54E }, { 0x1F550, 0x1F567 }, { 0x1F57A, 0x1F57A },
    { 0x1F595, 0x1F596 }, { 0x1F5A4, 0x1F5A4 }, { 0x1F5FB, 0x1F64F },
    { 0x1F680, 0x1F6C5 }, { 0x1F6CC, 0x1F6CC }, { 0x1F6D0, 0x1F6D2 },
    { 0x1F6D5, 0x1F6D7 }, { 0x1F6DC, 0x1F6DF }, { 0x1F6EB, 0x1F6EC },
    { 0x1F6F4, 0x1F6FC }, { 0x1F7E0, 0x1F7EB }, { 0x1F7F0, 0x1F7F0 },
    { 0x1F90C, 0x1F93A }, { 0x1F93C, 0x1F945 }, { 0x1F947, 0x1F9FF },
    { 0x1FA70, 0x1FAFF }, { 0x20000, 0x2FFFD }, { 0x30000, 0x3FFFD },
};

static int in_ranges(unsigned long cp, const xrl_range *r, size_t n) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (cp < r[mid].lo)
            hi = mid;
        else if (cp > r[mid].hi)
            lo = mid + 1;
        else
            return 1;
    }
    return 0;
}

int xrl_wcwidth(unsigned long cp) {
    if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0))
        return 0;
    if (in_ranges(cp, zero_width, sizeof zero_width / sizeof *zero_width))
        return 0;
    if (in_ranges(cp, double_width, sizeof double_width / sizeof *double_width))
        return 2;
    return 1;
}

/* character boundaries in the edit buffer: code points, not bytes */
static size_t next_char(const xbuf *b, size_t pos) {
    size_t adv;
    if (pos >= b->len)
        return pos;
    decode_char(b->b + pos, b->len - pos, &adv);
    return pos + adv;
}

static size_t prev_char(const xbuf *b, size_t pos) {
    size_t start = pos, adv;
    if (!pos)
        return 0;
    while (start > 0 && pos - start < 4) {
        start--;
        if (is_char_start(b->b[start]))
            break;
    }
    decode_char(b->b + start, b->len - start, &adv);
    return start + adv == pos ? start : pos - 1;
}

/* display columns of the character at p, and its length in bytes */
static int char_width(const char *p, size_t avail, size_t *adv) {
    unsigned char c = (unsigned char)*p;
    if (c < 0x20 || c == 0x7f) {
        *adv = 1;
        return 2;           /* drawn as ^X */
    }
    return xrl_wcwidth(decode_char(p, avail, adv));
}

static int is_word(unsigned char c) {
    return c >= 0x80 || c == '_' || (c >= '0' && c <= '9')
        || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static int is_space(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n';
}

/* readline's forward-word: skip non-word characters, then word characters */
static size_t word_end(const xbuf *b, size_t pos) {
    while (pos < b->len && !is_word((unsigned char)b->b[pos]))
        pos++;
    while (pos < b->len && is_word((unsigned char)b->b[pos]))
        pos++;
    return pos;
}

static size_t word_start(const xbuf *b, size_t pos) {
    while (pos && !is_word((unsigned char)b->b[pos - 1]))
        pos--;
    while (pos && is_word((unsigned char)b->b[pos - 1]))
        pos--;
    return pos;
}

static void buf_delete(xbuf *b, size_t from, size_t to) {
    if (to <= from || to > b->len)
        return;
    memmove(b->b + from, b->b + to, b->len - to);
    b->len -= to - from;
    b->b[b->len] = '\0';
}

static int buf_insert(xbuf *b, size_t at, const char *p, size_t n) {
    if (xbuf_reserve(b, n) < 0)
        return -1;
    memmove(b->b + at + n, b->b + at, b->len - at);
    memcpy(b->b + at, p, n);
    b->len += n;
    b->b[b->len] = '\0';
    return 0;
}

/* lay out one character of width w: wrap the way the terminal will */
typedef struct {
    int cols, row, col, pending;
} xrl_layout;

static void lay_char(xrl_layout *l, int w) {
    if (w == 0)                 /* joins the previous cell: no wrap */
        return;
    if (l->pending) {
        l->row++;
        l->col = 0;
        l->pending = 0;
    }
    else if (l->col + w > l->cols) {    /* a wide character that won't fit */
        l->row++;
        l->col = 0;
    }
    l->col += w;
    if (l->col >= l->cols)
        l->pending = 1;
}

static void lay_where(const xrl_layout *l, int *row, int *col) {
    *row = l->row + (l->pending ? 1 : 0);
    *col = l->pending ? 0 : l->col;
}

/* prompt width: escape sequences (CSI ... final) take no columns */
static int prompt_width(xrl_layout *l, const char *p, xbuf *o) {
    size_t n = strlen(p), i = 0;
    int    start = l->col;
    while (i < n) {
        size_t adv;
        int    w;
        if (p[i] == '\033' && i + 1 < n && p[i + 1] == '[') {
            size_t j = i + 2;
            while (j < n && ((unsigned char)p[j] < 0x40 || (unsigned char)p[j] > 0x7e))
                j++;
            i = j < n ? j + 1 : n;
            continue;
        }
        w = char_width(p + i, n - i, &adv);
        if ((unsigned char)p[i] < 0x20 || p[i] == 0x7f)
            w = 0;
        lay_char(l, w);
        i += adv;
    }
    xbuf_add(o, p, n);
    return l->row * l->cols + l->col - start;
}

static void refresh(xrl_edit *e) {
    xrl_t     *x = e->x;
    xbuf       o = { NULL, 0, 0 };
    xrl_layout l;
    int        crow = 0, ccol = 0, indent;
    size_t     i;

    l.cols = term_cols(x);
    l.row = l.col = l.pending = 0;
    if (e->oldrow > 0)
        xbuf_addf(&o, "\033[%dA", e->oldrow);
    xbuf_add(&o, "\r\033[J", 4);
    indent = prompt_width(&l, e->prompt, &o);
    if (indent >= l.cols)
        indent = 0;
    for (i = 0; i < e->buf.len;) {
        const char   *p = e->buf.b + i;
        unsigned char c = (unsigned char)*p;
        size_t        adv;
        int           w;
        if (i == e->pos)
            lay_where(&l, &crow, &ccol);
        if (c == '\n' && x->multiline) {
            int k;
            xbuf_add(&o, "\r\n", 2);
            for (k = 0; k < indent; k++)
                xbuf_addc(&o, ' ');
            l.row++;
            l.col = indent;
            l.pending = 0;
            i++;
            continue;
        }
        w = char_width(p, e->buf.len - i, &adv);
        lay_char(&l, w);
        if (c < 0x20 || c == 0x7f) {
            xbuf_addc(&o, '^');
            xbuf_addc(&o, (char)(c ^ 0x40));
        }
        else
            xbuf_add(&o, p, adv);
        i += adv;
    }
    if (e->pos >= e->buf.len)
        lay_where(&l, &crow, &ccol);
    if (l.pending) {            /* make the terminal leave the full row */
        xbuf_add(&o, "\r\n", 2);
        l.row++;
        l.col = 0;
        l.pending = 0;
    }
    if (l.row > crow)
        xbuf_addf(&o, "\033[%dA", l.row - crow);
    xbuf_addc(&o, '\r');
    if (ccol > 0)
        xbuf_addf(&o, "\033[%dC", ccol);
    e->oldrow = crow;
    out_write(x, o.b, o.len);
    free(o.b);
}

/* move to the end of the input and leave the terminal on a fresh row */
static void finish_line(xrl_edit *e) {
    e->pos = e->buf.len;
    refresh(e);
    out_write(e->x, "\r\n", 2);
}

static char *take_buffer(xrl_edit *e) {
    char *r = e->buf.b ? e->buf.b : strdup("");
    e->buf.b = NULL;
    return r;
}

static void set_buffer(xrl_edit *e, const char *p, size_t n, size_t pos) {
    e->buf.len = 0;
    xbuf_add(&e->buf, p ? p : "", p ? n : 0);
    e->pos = pos > e->buf.len ? e->buf.len : pos;
    while (e->pos && e->pos < e->buf.len && !is_char_start(e->buf.b[e->pos]))
        e->pos--;
}

static void bell(xrl_edit *e) {
    out_write(e->x, "\a", 1);
}

/* ---- history navigation and search -------------------------------------- */

/* up (dir < 0) or down (dir > 0) to the next entry starting with the text
 * typed before navigation began */
static void history_step(xrl_edit *e, int dir) {
    xrl_t *x = e->x;
    size_t i, plen;
    if (!e->navigating) {
        if (dir > 0)
            return;
        e->nav_saved.len = 0;
        xbuf_add(&e->nav_saved, e->buf.b ? e->buf.b : "", e->buf.len);
        e->hist_idx   = x->hist_len;
        e->navigating = 1;
    }
    plen = e->nav_saved.len;
    for (i = e->hist_idx;;) {
        if (dir < 0) {
            if (i == 0)
                return;                 /* nothing older: stay put */
            i--;
        }
        else if (++i >= x->hist_len) {  /* past the newest: back to the text */
            set_buffer(e, e->nav_saved.b, e->nav_saved.len, e->nav_saved.len);
            e->hist_idx   = x->hist_len;
            e->navigating = 0;
            return;
        }
        if (strncmp(x->hist[i], plen ? e->nav_saved.b : "", plen) == 0)
            break;
    }
    e->hist_idx = i;
    set_buffer(e, x->hist[i], strlen(x->hist[i]), (size_t)-1);
}

/* search backwards from history index `from` (inclusive) for `q` */
static int search_from(xrl_edit *e, const xbuf *q, long from, long *found) {
    long i;
    for (i = from; i >= 0; i--) {
        const char *m = strstr(e->x->hist[i], q->b);
        if (m) {
            *found = i;
            set_buffer(e, e->x->hist[i], strlen(e->x->hist[i]),
                       (size_t)(m - e->x->hist[i]));
            return 1;
        }
    }
    return 0;
}

/* ctrl-r: incremental reverse search; returns KEY_EOF at end of input,
 * otherwise 0 with any key that ends the search left in e->pending */
static int reverse_search(xrl_edit *e) {
    xrl_t      *x = e->x;
    const char *prompt = e->prompt;
    xbuf        q = { NULL, 0, 0 }, saved = { NULL, 0, 0 }, pr = { NULL, 0, 0 };
    size_t      saved_pos = e->pos;
    long        idx = (long)x->hist_len;
    int         failed = 0, r = 0;

    xbuf_add(&q, "", 0);
    xbuf_add(&saved, e->buf.b ? e->buf.b : "", e->buf.len);
    e->no_bindings = 1;
    for (;;) {
        int c;
        pr.len = 0;
        xbuf_add(&pr, failed ? "(failed reverse-i-search)'" : "(reverse-i-search)'",
                 failed ? 26 : 19);
        xbuf_add(&pr, q.b, q.len);
        xbuf_add(&pr, "': ", 3);
        e->prompt = pr.b;
        refresh(e);
        c = read_key(e);
        if (c == KEY_EOF) {
            r = KEY_EOF;
            break;
        }
        if (c == 0x12) {                        /* ctrl-r: older match */
            if (q.len && idx > 0)
                failed = !search_from(e, &q, idx - 1, &idx);
        }
        else if (c == 0x7f || c == 8) {         /* backspace */
            if (q.len) {
                q.len = prev_char(&q, q.len);
                q.b[q.len] = '\0';
            }
            failed = 0;
            if (q.len)
                failed = !search_from(e, &q, (long)x->hist_len - 1, &idx);
        }
        else if (c == 7 || c == 3) {            /* ctrl-g, ctrl-c: cancel */
            set_buffer(e, saved.b, saved.len, saved_pos);
            break;
        }
        else if (c >= 0x20 && c < 0x100) {
            char ch = (char)c;
            xbuf_add(&q, &ch, 1);
            if (!failed)
                failed = !search_from(e, &q,
                    idx < (long)x->hist_len ? idx : (long)x->hist_len - 1, &idx);
        }
        else {                                  /* accept, then handle c */
            e->pending = c;
            break;
        }
    }
    e->prompt      = prompt;
    e->no_bindings = 0;
    free(q.b);
    free(saved.b);
    free(pr.b);
    return r;
}

/* ---- completion ---------------------------------------------------------- */

static void list_words(xrl_edit *e, xrl_completions *c) {
    xbuf   o = { NULL, 0, 0 };
    size_t i, saved_pos = e->pos, maxw = 0, *w;
    int    cols = term_cols(e->x), ncols, nrows, r, k;

    w = (size_t *)calloc(c->count, sizeof *w);
    if (!w)
        return;
    for (i = 0; i < c->count; i++) {
        const char *p = c->words[i];
        size_t      n = strlen(p), j = 0, adv;
        while (j < n) {
            w[i] += (size_t)char_width(p + j, n - j, &adv);
            j += adv;
        }
        if (w[i] > maxw)
            maxw = w[i];
    }
    ncols = cols / (int)(maxw + 2);
    if (ncols < 1)
        ncols = 1;
    nrows = ((int)c->count + ncols - 1) / ncols;

    finish_line(e);
    for (r = 0; r < nrows; r++) {
        for (k = 0; k < ncols; k++) {
            size_t idx = (size_t)k * (size_t)nrows + (size_t)r, pad;
            if (idx >= c->count)
                break;
            /* the colour takes no columns: widths come from the words */
            if (c->colors[idx])
                xbuf_add(&o, c->colors[idx], strlen(c->colors[idx]));
            xbuf_add(&o, c->words[idx], strlen(c->words[idx]));
            if (c->colors[idx])
                xbuf_add(&o, "\033[0m", 4);
            if (idx + (size_t)nrows < c->count)
                for (pad = w[idx]; pad < maxw + 2; pad++)
                    xbuf_addc(&o, ' ');
        }
        xbuf_add(&o, "\r\n", 2);
    }
    out_write(e->x, o.b, o.len);
    free(o.b);
    free(w);
    e->oldrow = 0;
    e->pos    = saved_pos;
}

/* tab: returns -1 when the callback aborts */
static int complete(xrl_edit *e) {
    xrl_t          *x = e->x;
    xrl_completions c;
    size_t          start, cur, lcp = 0, i, first = 0, ninsert = 0;

    if (!x->complete_cb) {
        bell(e);
        return 0;
    }
    memset(&c, 0, sizeof c);
    if (x->complete_cb(x->complete_ud, e->buf.b ? e->buf.b : "", e->buf.len,
                       e->pos, &c) < 0) {
        completions_free(&c);
        return -1;
    }
    start = c.start > e->pos ? e->pos : c.start;
    cur   = e->pos - start;
    /* only insertable words are inserted; display-only ones are listed */
    for (i = 0; i < c.count; i++)
        if (!c.display[i] && !ninsert++)
            first = i;
    if (ninsert) {
        lcp = strlen(c.words[first]);
        for (i = first + 1; i < c.count; i++) {
            size_t j = 0;
            if (c.display[i])
                continue;
            while (j < lcp && c.words[i][j] == c.words[first][j])
                j++;
            lcp = j;
        }
        while (lcp && lcp < strlen(c.words[first]) && !is_char_start(c.words[first][lcp]))
            lcp--;
    }
    if (c.count == 0) {
        bell(e);
    }
    else if (ninsert < c.count) {
        /* display-only words: list everything on the first tab, after
         * inserting what the insertable ones agree on */
        if (ninsert && (ninsert == 1 || lcp > cur)) {
            buf_delete(&e->buf, start, e->pos);
            e->pos = start;
            if (buf_insert(&e->buf, start, c.words[first], lcp) == 0)
                e->pos = start + lcp;
        }
        list_words(e, &c);
    }
    else if (ninsert == 1 || lcp > cur) {
        buf_delete(&e->buf, start, e->pos);
        e->pos = start;
        if (buf_insert(&e->buf, start, c.words[first], lcp) == 0)
            e->pos = start + lcp;
    }
    else if (e->last_key == '\t')
        list_words(e, &c);
    else
        bell(e);
    completions_free(&c);
    return 0;
}

/* ---- key bindings -------------------------------------------------------- */

/* returns -1 to abort, 1 with *line set to submit, 0 to keep editing */
static int run_binding(xrl_edit *e, char **line) {
    xrl_t             *x = e->x;
    xrl_binding_result res;
    size_t             pos = e->pos;
    int                act;

    memset(&res, 0, sizeof res);
    finish_line(e);
    e->pos = pos;
    raw_off(x);
    act = x->bind_cb(x->bind_ud, e->seq, e->seqlen,
                     e->buf.b ? e->buf.b : "", e->buf.len, e->pos, &res);
    if (act < 0) {
        free(res.text);
        return -1;
    }
    raw_on(x);
    e->oldrow = 0;
    if (act == XRL_BIND_SUBMIT) {
        x->forced = res.force ? 1 : 0;
        *line = res.text ? res.text : strdup("");
        return 1;
    }
    if (act == XRL_BIND_EDIT)
        set_buffer(e, res.text, res.len, res.cursor);
    free(res.text);
    return 0;
}

static char *edit_loop(xrl_edit *e) {
    xrl_t *x = e->x;
    refresh(e);
    for (;;) {
        int c = read_key(e);
        if (c != KEY_UP && c != KEY_DOWN)
            e->navigating = 0;
        if (c != KEY_EOF && e->cur_key)
            e->last_key = e->cur_key;
        e->cur_key = c;
        switch (c) {
        case KEY_EOF:
            finish_line(e);
            return NULL;
        case '\n': case KEY_ALT_ENTER:          /* ctrl-j, alt-enter */
            x->forced = 1;
            finish_line(e);
            return take_buffer(e);
        case '\r':
            finish_line(e);
            return take_buffer(e);
        case KEY_UP:
            history_step(e, -1);
            break;
        case KEY_DOWN:
            history_step(e, 1);
            break;
        case 0x12:                              /* ctrl-r */
            if (reverse_search(e) == KEY_EOF) {
                finish_line(e);
                return NULL;
            }
            break;
        case '\t':
            if (complete(e) < 0) {
                finish_line(e);
                x->aborted = 1;
                return NULL;
            }
            break;
        case KEY_BINDING: {
            char *line = NULL;
            int   r    = run_binding(e, &line);
            if (r < 0) {
                x->aborted = 1;
                return NULL;
            }
            if (r > 0)
                return line;
            break;
        }
        case 3:                                 /* ctrl-c */
            finish_line(e);
            x->cancelled = 1;
            e->buf.len = 0;
            return strdup("");
        case 4:                                 /* ctrl-d */
            if (e->buf.len == 0) {
                finish_line(e);
                return NULL;
            }
            buf_delete(&e->buf, e->pos, next_char(&e->buf, e->pos));
            break;
        case 0x7f: case 8:                      /* backspace, ctrl-h */
            if (e->pos) {
                size_t p = prev_char(&e->buf, e->pos);
                buf_delete(&e->buf, p, e->pos);
                e->pos = p;
            }
            break;
        case KEY_DELETE:
            buf_delete(&e->buf, e->pos, next_char(&e->buf, e->pos));
            break;
        case 1: case KEY_HOME:                  /* ctrl-a */
            e->pos = 0;
            break;
        case 5: case KEY_END:                   /* ctrl-e */
            e->pos = e->buf.len;
            break;
        case 2: case KEY_LEFT:                  /* ctrl-b */
            e->pos = prev_char(&e->buf, e->pos);
            break;
        case 6: case KEY_RIGHT:                 /* ctrl-f */
            e->pos = next_char(&e->buf, e->pos);
            break;
        case KEY_ALT_B:
            e->pos = word_start(&e->buf, e->pos);
            break;
        case KEY_ALT_F:
            e->pos = word_end(&e->buf, e->pos);
            break;
        case KEY_ALT_D:
            buf_delete(&e->buf, e->pos, word_end(&e->buf, e->pos));
            break;
        case 0x0b:                              /* ctrl-k */
            buf_delete(&e->buf, e->pos, e->buf.len);
            break;
        case 0x15:                              /* ctrl-u */
            buf_delete(&e->buf, 0, e->pos);
            e->pos = 0;
            break;
        case 0x17: {                            /* ctrl-w */
            size_t p = e->pos;
            while (p && is_space((unsigned char)e->buf.b[p - 1]))
                p--;
            while (p && !is_space((unsigned char)e->buf.b[p - 1]))
                p--;
            buf_delete(&e->buf, p, e->pos);
            e->pos = p;
            break;
        }
        case 0x0c:                              /* ctrl-l */
            out_write(x, "\033[H\033[2J", 7);
            e->oldrow = 0;
            break;
        case 0x1a: {                            /* ctrl-z */
            /* raw mode turns off ISIG, so stop ourselves as the tty
             * driver would have, with the terminal restored; on resume
             * take raw mode again (the shell may have changed the modes)
             * and redraw on a fresh row */
            size_t pos = e->pos;
            finish_line(e);
            e->pos = pos;
            raw_off(x);
            x->suspends++;
#if defined(XRL_HAVE_TERMIOS) && defined(SIGTSTP)
            if (!x->test_mode)
                kill(getpid(), SIGTSTP);
#endif
            raw_on(x);
            e->oldrow = 0;
            break;
        }
        default:
            if (c >= 0x20 && c < 0x100 && c != 0x7f) {
                /* gather a whole UTF-8 character before drawing it */
                char   ch[4];
                size_t n = 1, need = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
                ch[0] = (char)c;
                while (n < need) {
                    int b = read_byte(x);
                    if (b < 0)
                        break;
                    if ((b & 0xC0) != 0x80) {
                        char nb = (char)b;
                        unread(x, &nb, 1);
                        break;
                    }
                    ch[n++] = (char)b;
                }
                if (buf_insert(&e->buf, e->pos, ch, n) == 0)
                    e->pos += n;
            }
            else
                continue;                       /* ignored: no redraw */
        }
        refresh(e);
    }
}

char *xrl_readline(xrl_t *x, const char *prompt, const char *preload) {
    xrl_edit e;
    char    *line;

    x->cancelled = x->forced = x->aborted = 0;
    if (!x->test_mode && !isatty(x->in_fd))
        return read_plain_line(x);
    if (raw_on(x) < 0)
        return read_plain_line(x);
    if (!x->no_cursor_reply
        && (x->test_mode ? x->cursor_query : isatty(x->out_fd)))
        fresh_line(x);

    memset(&e, 0, sizeof e);
    e.x      = x;
    e.prompt = prompt ? prompt : "";
    if (preload && *preload)
        xbuf_add(&e.buf, preload, strlen(preload));
    e.pos = e.buf.len;

    line = edit_loop(&e);
    free(e.buf.b);
    free(e.nav_saved.b);
    raw_off(x);
    return line;
}
