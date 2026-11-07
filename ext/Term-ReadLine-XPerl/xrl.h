/*
 * xrl.h - the line editor behind Term::ReadLine::XPerl
 *
 * You may distribute under the terms of either the GNU General Public
 * License or the Artistic License, as specified in the README file.
 */

#ifndef XRL_H
#define XRL_H

#include <stddef.h>

typedef struct xrl xrl_t;

xrl_t      *xrl_new(int in_fd, int out_fd);
void        xrl_free(xrl_t *x);

/* returns a malloc'd line without its newline (the caller frees it), or
 * NULL at end of input */
char       *xrl_readline(xrl_t *x, const char *prompt, const char *preload);

int         xrl_history_add(xrl_t *x, const char *line);
int         xrl_history_load(xrl_t *x, const char *path);
int         xrl_history_save(xrl_t *x, const char *path);
int         xrl_history_set_max(xrl_t *x, int max);
size_t      xrl_history_count(xrl_t *x);
const char *xrl_history_get(xrl_t *x, size_t idx);

/* display columns of a code point: 2 for East Asian wide and emoji, 0 for
 * combining marks and C0/C1 controls */
int         xrl_wcwidth(unsigned long cp);

/* status of the last xrl_readline */
int         xrl_last_cancelled(xrl_t *x);
int         xrl_last_submit_forced(xrl_t *x);
int         xrl_raw_active(xrl_t *x);
/* ctrl-z presses so far; in test mode they are counted, not acted on */
int         xrl_suspends(xrl_t *x);
/* how many fatal signals (TERM, HUP, QUIT, ALRM) are trapped to restore
 * the terminal: those at their default action while an editor is raw */
int         xrl_signals_trapped(void);

/* test mode: behave as a cols x rows terminal without touching termios,
 * reading only the bytes queued with xrl_feed; an empty queue is end of
 * input */
void        xrl_set_test_mode(xrl_t *x, int cols, int rows);
void        xrl_feed(xrl_t *x, const char *bytes, size_t len);
/* in test mode, also send the cursor position query (and read the fed
 * reply) on entry to xrl_readline, as on a real terminal */
void        xrl_set_cursor_query(xrl_t *x, int on);

/* multiline: draw newlines in the buffer as new rows (default) or as ^J */
void        xrl_set_multiline(xrl_t *x, int on);

/* completion: the callback receives the buffer and the cursor offset and
 * fills in the candidate words and the offset where the word being
 * completed starts; it returns 0, or -1 to abort xrl_readline */
typedef struct {
    char  **words;
    char  **colors;     /* per word: an SGR prefix to list it in, or NULL */
    int    *display;    /* per word: 1 when it is only listed, never inserted */
    size_t  count;
    size_t  start;
} xrl_completions;

typedef int (*xrl_completion_cb)(void *ud, const char *buf, size_t len,
                                 size_t cursor, xrl_completions *out);
void        xrl_set_completion_cb(xrl_t *x, xrl_completion_cb cb, void *ud);
int         xrl_completions_add(xrl_completions *c, const char *w, size_t len);
/* as xrl_completions_add, listed in colour: color is an SGR prefix (the
 * reset is added), or NULL for plain. a display_only word is listed but
 * never inserted; when any are present the first tab lists every word */
int         xrl_completions_add_colored(xrl_completions *c, const char *w, size_t len,
                                        const char *color, size_t colorlen,
                                        int display_only);

/* key bindings: when the input matches a bound byte sequence the editor
 * leaves raw mode, moves to a fresh row and calls the callback, which
 * returns one of the XRL_BIND_* actions (or -1 to abort xrl_readline) and
 * fills in the result for XRL_BIND_EDIT and XRL_BIND_SUBMIT; the text is
 * malloc'd and the editor frees it */
enum { XRL_BIND_NONE = 0, XRL_BIND_EDIT = 1, XRL_BIND_SUBMIT = 2 };

typedef struct {
    char   *text;
    size_t  len;
    size_t  cursor;
    int     force;
} xrl_binding_result;

typedef int (*xrl_binding_cb)(void *ud, const char *seq, size_t seqlen,
                              const char *buf, size_t len, size_t cursor,
                              xrl_binding_result *res);
void        xrl_set_binding_cb(xrl_t *x, xrl_binding_cb cb, void *ud);
int         xrl_bind(xrl_t *x, const char *seq, size_t len);
void        xrl_unbind_all(xrl_t *x);

#endif
