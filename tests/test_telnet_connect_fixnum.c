/* test_telnet_connect_fixnum.c - Regression test for the telnet_connect
 * tagged-immediate segfault.
 *
 * `telnet_connect` reads `*connect-timeout*`, `*connect-max-retries*`,
 * `*tcp-keepalive-time*`, `*tcp-keepalive-interval*`,
 * `*telnet-log-directory*`, and several `*...-enabled*` symbols from the
 * Lisp environment. init.lisp defines the integer-valued ones as small
 * literals (e.g. `(defvar *connect-timeout* 2)`), which ditty encodes
 * as tagged immediates — not real heap pointers. Pre-fix code did
 * `obj->type == LISP_INTEGER` directly and SIGSEGV'd before any socket
 * work. This test reaches the variable-read path by attempting a connect
 * to a closed local port.
 */

#include <assert.h>
#include <stdio.h>

#include <ditty/lisp.h>
#include <ditty/lisp_value.h>

#include "../include/telnet.h"
#include "../src/lisp_extension.h"
#include "../src/session.h"

int g_term_cols = 80;
int g_term_rows = 24;

/* Stubs: lisp_extension.c references telnet_app helpers (window title,
 * status text). Tests don't link telnet_app.o, so provide no-ops. */
struct TelnetAppModel;
void telnet_app_set_window_title(struct TelnetAppModel *app, const char *title)
{
    (void)app;
    (void)title;
}
void telnet_app_set_status_text(struct TelnetAppModel *app, const char *text)
{
    (void)app;
    (void)text;
}

static int run = 0;
static int passed = 0;

#define RUN_TEST(fn)                 \
    do {                             \
        run++;                       \
        fn();                        \
        passed++;                    \
        printf("  PASS: %s\n", #fn); \
    } while (0)

/* Hitting telnet_connect with the default fixnum-valued *connect-timeout*
 * and *connect-max-retries* would SEGV pre-fix. Override them to 0/0 first
 * (still fixnums — same bug surface) so the test runs in milliseconds. */
static void test_telnet_connect_with_fixnum_vars(void)
{
    Environment *env = session_get_base_env();
    assert(env != NULL);

    /* Bind the same fixnum-valued vars init.lisp would set. Keep retries
     * and timeout small so a refused connect returns fast. They're still
     * fixnums — same bug surface. */
    LispObject *r1 = lisp_eval_string("(defvar *connect-timeout* 0)", env);
    LispObject *r2 = lisp_eval_string("(defvar *connect-max-retries* 0)", env);
    assert(r1 && LISP_TYPE(r1) != LISP_ERROR);
    assert(r2 && LISP_TYPE(r2) != LISP_ERROR);

    Telnet *t = telnet_create();
    assert(t != NULL);

    /* Port 1 is reserved/closed on a typical host: connect() returns
     * ECONNREFUSED fast. The point of the test is not the return value
     * but that we don't crash reading the fixnum-valued Lisp vars. */
    int rc = telnet_connect(t, "127.0.0.1", 1, NULL);
    assert(rc == -1);

    telnet_destroy(t);
}

int main(void)
{
    if (lisp_x_init() < 0) {
        fprintf(stderr, "lisp_x_init failed\n");
        return 1;
    }

    printf("telnet_connect fixnum regression tests:\n");
    RUN_TEST(test_telnet_connect_with_fixnum_vars);

    printf("\n%d/%d tests passed.\n", passed, run);
    lisp_x_cleanup();
    return (passed == run) ? 0 : 1;
}
