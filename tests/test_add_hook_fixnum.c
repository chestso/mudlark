/* test_add_hook_fixnum.c - Regression test for the add-hook fixnum segfault
 *
 * bloom-lisp uses tagged immediates: small integers are encoded inline as
 * `(value << 3) | LISP_TAG_FIXNUM` and are NOT real heap pointers. Code
 * that wants the type tag must go through LISP_TYPE(v) / LISP_INT_VAL(v).
 *
 * `builtin_add_hook` previously dereferenced `prio_obj->type` directly,
 * which segfaulted the moment the priority arg was a fixnum literal:
 *
 *     (add-hook 'h 'f 1)   ; 1 is a tagged fixnum -> (LispObject*)0x9
 *
 * The crash signature reproduced from `init.lisp` at startup.
 *
 * This test exercises the C builtin (not the pure-Lisp mock used by
 * tests/hooks.lisp) by initializing the real Lisp environment and
 * evaluating add-hook expressions through `lisp_eval_string`.
 */

#include <assert.h>
#include <stdio.h>

#include <bloom-lisp/lisp.h>
#include <bloom-lisp/lisp_value.h>

#include "../src/lisp_extension.h"
#include "../src/session.h"

/* Globals normally defined in main.c — tests link against
 * lisp_extension.o which references them via extern. */
int g_term_cols = 80;
int g_term_rows = 24;

/* Stubs: lisp_extension.c references telnet_app helpers (window title,
 * status text). Tests don't link telnet_app.o (which would pull in TUI
 * deps), so provide no-ops. */
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

/* The crashing form from init.lisp:738. Before the fix this segfaulted
 * because `prio_obj->type` was read on a tagged-immediate fixnum. */
static void test_add_hook_with_fixnum_priority(void)
{
    Environment *env = session_get_base_env();
    assert(env != NULL);

    LispObject *result = lisp_eval_string("(add-hook 'h 'f 1)", env);
    assert(result != NULL);
    assert(LISP_TYPE(result) != LISP_ERROR);
}

/* Bignum priority: heap-allocated integer, exercises the
 * LISP_INT_VAL accessor on a non-fixnum LISP_INTEGER. */
static void test_add_hook_with_bignum_priority(void)
{
    Environment *env = session_get_base_env();
    LispObject *result =
        lisp_eval_string("(add-hook 'h2 'f2 100000000000)", env);
    assert(result != NULL);
    assert(LISP_TYPE(result) != LISP_ERROR);
}

/* Two-arg form (no priority) — same code path as init.lisp:395. */
static void test_add_hook_two_args(void)
{
    Environment *env = session_get_base_env();
    LispObject *result = lisp_eval_string("(add-hook 'h3 'f3)", env);
    assert(result != NULL);
    assert(LISP_TYPE(result) != LISP_ERROR);
}

/* Non-integer priority must produce a Lisp error, not a segfault.
 * This exercises the LISP_TYPE check on a tagged-immediate non-integer. */
static void test_add_hook_rejects_non_integer_priority(void)
{
    Environment *env = session_get_base_env();
    LispObject *result = lisp_eval_string("(add-hook 'h4 'f4 \"high\")", env);
    assert(result != NULL);
    assert(LISP_TYPE(result) == LISP_ERROR);
}

int main(void)
{
    if (lisp_x_init() < 0) {
        fprintf(stderr, "lisp_x_init failed\n");
        return 1;
    }

    printf("add-hook fixnum regression tests:\n");
    RUN_TEST(test_add_hook_with_fixnum_priority);
    RUN_TEST(test_add_hook_with_bignum_priority);
    RUN_TEST(test_add_hook_two_args);
    RUN_TEST(test_add_hook_rejects_non_integer_priority);

    printf("\n%d/%d tests passed.\n", passed, run);
    lisp_x_cleanup();
    return (passed == run) ? 0 : 1;
}
