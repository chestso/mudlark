/* test_telnet_app.c - Tests for TelnetApp component and runtime integration
 *
 * Tests the uncommitted changes in telnet_app.c:
 * - Mouse scroll wheel handling in telnet_app_update()
 * - PageUp/PageDown key handling in telnet_app_update()
 * - WINDOW_SIZE message handling in telnet_app_update()
 * - telnet_app_component() interface for runtime integration
 */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define DEVNULL "NUL"
#else
#define DEVNULL "/dev/null"
#endif

#include <boba/cmd.h>
#include <boba/component.h>
#include <boba/components/viewport.h>
#include <boba/dynamic_buffer.h>
#include <boba/msg.h>
#include <boba/runtime.h>

#include "../src/telnet_app.h"

/* Stub for lisp_x_call_fkey_hook (linked from telnet_app.o) */
void lisp_x_call_fkey_hook(int fkey_num) { (void)fkey_num; }

static int tests_run = 0;
static int tests_passed = 0;

#define RUN_TEST(fn)                 \
    do {                             \
        tests_run++;                 \
        fn();                        \
        tests_passed++;              \
        printf("  PASS: %s\n", #fn); \
    } while (0)

/* ========================================================================
 * Helpers: create/update/free via component interface
 * ======================================================================== */

static const TuiComponent *g_comp = NULL;

static TelnetAppModel *create_test_app(void)
{
    if (!g_comp)
        g_comp = telnet_app_component();
    TelnetAppConfig cfg = {
        .terminal_width = 80,
        .terminal_height = 24,
        .prompt = "> ",
        .show_prompt = 1,
        .history_size = 10,
    };
    TuiInitResult r = g_comp->init(&cfg);
    return (TelnetAppModel *)r.model;
}

static TuiUpdateResult test_app_update(TelnetAppModel *app, TuiMsg msg)
{
    return g_comp->update((TuiModel *)app, msg);
}

static void test_app_free(TelnetAppModel *app)
{
    g_comp->free((TuiModel *)app);
}

/* ========================================================================
 * Tests for telnet_app_component() (new in uncommitted changes)
 * ======================================================================== */

/* Test that telnet_app_component() returns a valid component interface */
static void test_component_interface_exists(void)
{
    const TuiComponent *comp = telnet_app_component();
    assert(comp != NULL);
    assert(comp->init != NULL);
    assert(comp->update != NULL);
    assert(comp->view != NULL);
    assert(comp->free != NULL);
}

/* Test that component init creates a valid model */
static void test_component_init(void)
{
    const TuiComponent *comp = telnet_app_component();
    TelnetAppConfig cfg = {
        .terminal_width = 100,
        .terminal_height = 40,
        .prompt = "$ ",
        .show_prompt = 1,
        .history_size = 50,
    };

    TuiInitResult result = comp->init(&cfg);
    assert(result.model != NULL);

    TelnetAppModel *app = (TelnetAppModel *)result.model;
    assert(app->terminal_width == 100);
    assert(app->terminal_height == 40);

    if (result.cmd)
        tui_cmd_free(result.cmd);
    comp->free(result.model);
}

/* Test that component can be used with tui_runtime_create */
static void test_component_with_runtime(void)
{
    FILE *devnull = fopen(DEVNULL, "w");
    assert(devnull != NULL);

    TelnetAppConfig app_cfg = {
        .terminal_width = 80,
        .terminal_height = 24,
        .prompt = "> ",
        .show_prompt = 1,
        .history_size = 10,
    };
    /* alt-screen is now declared on TuiView (see telnet_app_view) — no
     * longer a runtime-config field. */
    TuiRuntimeConfig rt_cfg = {
        .output = devnull,
    };

    TuiRuntime *rt = tui_runtime_create(
        (TuiComponent *)telnet_app_component(), &app_cfg, &rt_cfg);
    assert(rt != NULL);

    TelnetAppModel *app = (TelnetAppModel *)tui_runtime_model(rt);
    assert(app != NULL);
    assert(app->terminal_width == 80);
    assert(app->terminal_height == 24);

    tui_runtime_free(rt);
    fclose(devnull);
}

/* ========================================================================
 * Tests for WINDOW_SIZE handling (moved into component in uncommitted changes)
 * ======================================================================== */

/* Test that WINDOW_SIZE message updates component dimensions */
static void test_window_size_updates_dimensions(void)
{
    TelnetAppModel *app = create_test_app();
    assert(app->terminal_width == 80);
    assert(app->terminal_height == 24);

    TuiMsg msg = tui_msg_window_size(132, 50);
    TuiUpdateResult result = test_app_update(app, msg);

    assert(app->terminal_width == 132);
    assert(app->terminal_height == 50);

    if (result.cmd)
        tui_cmd_free(result.cmd);
    test_app_free(app);
}

/* Test that WINDOW_SIZE with small dimensions works */
static void test_window_size_small(void)
{
    TelnetAppModel *app = create_test_app();

    TuiMsg msg = tui_msg_window_size(20, 5);
    TuiUpdateResult result = test_app_update(app, msg);

    assert(app->terminal_width == 20);
    assert(app->terminal_height == 5);

    if (result.cmd)
        tui_cmd_free(result.cmd);
    test_app_free(app);
}

/* ========================================================================
 * Tests for mouse scroll handling (moved into component in uncommitted changes)
 * ======================================================================== */

/* Test that mouse wheel up scrolls the viewport up */
static void test_mouse_wheel_up_scrolls(void)
{
    TelnetAppModel *app = create_test_app();

    /* Add enough content to enable scrolling */
    for (int i = 0; i < 50; i++) {
        telnet_app_echo(app, "line\n", 5);
    }

    /* Scroll to bottom first (default position) */
    TuiViewport *vp = telnet_app_get_viewport(app);
    int initial_offset = (int)vp->y_offset;

    /* Send mouse wheel up */
    TuiMsg msg = tui_msg_mouse(TUI_MOUSE_WHEEL_UP, TUI_MOUSE_ACTION_PRESS, 1,
                               1, 0);
    TuiUpdateResult result = test_app_update(app, msg);

    int new_offset = (int)vp->y_offset;
    assert(new_offset < initial_offset); /* Scrolled up (offset decreased) */

    if (result.cmd)
        tui_cmd_free(result.cmd);
    test_app_free(app);
}

/* Test that mouse wheel down scrolls the viewport down */
static void test_mouse_wheel_down_scrolls(void)
{
    TelnetAppModel *app = create_test_app();

    /* Add content and scroll up first */
    for (int i = 0; i < 50; i++) {
        telnet_app_echo(app, "line\n", 5);
    }
    telnet_app_scroll_up(app, 10);

    TuiViewport *vp = telnet_app_get_viewport(app);
    int initial_offset = (int)vp->y_offset;

    /* Send mouse wheel down */
    TuiMsg msg = tui_msg_mouse(TUI_MOUSE_WHEEL_DOWN, TUI_MOUSE_ACTION_PRESS, 1,
                               1, 0);
    TuiUpdateResult result = test_app_update(app, msg);

    int new_offset = (int)vp->y_offset;
    assert(new_offset > initial_offset); /* Scrolled down (offset increased) */

    if (result.cmd)
        tui_cmd_free(result.cmd);
    test_app_free(app);
}

/* Test that mouse scroll returns no command */
static void test_mouse_scroll_no_cmd(void)
{
    TelnetAppModel *app = create_test_app();

    TuiMsg msg = tui_msg_mouse(TUI_MOUSE_WHEEL_UP, TUI_MOUSE_ACTION_PRESS, 1, 1,
                               0);
    TuiUpdateResult result = test_app_update(app, msg);
    assert(result.cmd == NULL);

    test_app_free(app);
}

/* Test that non-scroll mouse events are handled without crashing */
static void test_mouse_click_no_crash(void)
{
    TelnetAppModel *app = create_test_app();

    TuiMsg msg =
        tui_msg_mouse(TUI_MOUSE_LEFT, TUI_MOUSE_ACTION_PRESS, 5, 10, 0);
    TuiUpdateResult result = test_app_update(app, msg);
    assert(result.cmd == NULL);

    test_app_free(app);
}

/* ========================================================================
 * Tests for PageUp/PageDown handling (moved into component in uncommitted)
 * ======================================================================== */

/* Test that PageUp scrolls the viewport up */
static void test_page_up_scrolls(void)
{
    TelnetAppModel *app = create_test_app();

    /* Add enough content to scroll */
    for (int i = 0; i < 100; i++) {
        telnet_app_echo(app, "line\n", 5);
    }

    TuiViewport *vp = telnet_app_get_viewport(app);
    int initial_offset = (int)vp->y_offset;

    /* Send PageUp key */
    TuiMsg msg = tui_msg_key(TUI_KEY_PAGE_UP, 0, 0);
    TuiUpdateResult result = test_app_update(app, msg);

    int new_offset = (int)vp->y_offset;
    assert(new_offset < initial_offset);

    if (result.cmd)
        tui_cmd_free(result.cmd);
    test_app_free(app);
}

/* Test that PageDown scrolls the viewport down */
static void test_page_down_scrolls(void)
{
    TelnetAppModel *app = create_test_app();

    /* Add content and scroll up */
    for (int i = 0; i < 100; i++) {
        telnet_app_echo(app, "line\n", 5);
    }
    telnet_app_page_up(app);

    TuiViewport *vp = telnet_app_get_viewport(app);
    int initial_offset = (int)vp->y_offset;

    /* Send PageDown key */
    TuiMsg msg = tui_msg_key(TUI_KEY_PAGE_DOWN, 0, 0);
    TuiUpdateResult result = test_app_update(app, msg);

    int new_offset = (int)vp->y_offset;
    assert(new_offset > initial_offset);

    if (result.cmd)
        tui_cmd_free(result.cmd);
    test_app_free(app);
}

/* Test that PageUp/PageDown return no command */
static void test_page_keys_no_cmd(void)
{
    TelnetAppModel *app = create_test_app();

    TuiMsg msg_up = tui_msg_key(TUI_KEY_PAGE_UP, 0, 0);
    TuiUpdateResult result_up = test_app_update(app, msg_up);
    assert(result_up.cmd == NULL);

    TuiMsg msg_down = tui_msg_key(TUI_KEY_PAGE_DOWN, 0, 0);
    TuiUpdateResult result_down = test_app_update(app, msg_down);
    assert(result_down.cmd == NULL);

    test_app_free(app);
}

/* ========================================================================
 * Tests for runtime integration (full component lifecycle through runtime)
 * ======================================================================== */

/* Test that runtime flush renders without crashing */
static void test_runtime_flush_renders(void)
{
    FILE *devnull = fopen(DEVNULL, "w");
    assert(devnull != NULL);

    TelnetAppConfig app_cfg = {
        .terminal_width = 80,
        .terminal_height = 24,
        .prompt = "> ",
        .show_prompt = 1,
        .history_size = 10,
    };
    TuiRuntimeConfig rt_cfg = {
        .output = devnull,
    };

    TuiRuntime *rt = tui_runtime_create(
        (TuiComponent *)telnet_app_component(), &app_cfg, &rt_cfg);
    assert(rt != NULL);

    /* Flush should render the component without crashing */
    tui_runtime_flush(rt);

    /* Add some content and flush again */
    TelnetAppModel *app = (TelnetAppModel *)tui_runtime_model(rt);
    telnet_app_echo(app, "Hello, World!\n", 14);
    tui_runtime_flush(rt);

    tui_runtime_free(rt);
    fclose(devnull);
}

/* Test that sending WINDOW_SIZE through runtime updates the component */
static void test_runtime_sends_window_size(void)
{
    FILE *devnull = fopen(DEVNULL, "w");
    assert(devnull != NULL);

    TelnetAppConfig app_cfg = {
        .terminal_width = 80,
        .terminal_height = 24,
        .prompt = "> ",
        .show_prompt = 1,
        .history_size = 10,
    };
    TuiRuntimeConfig rt_cfg = {
        .output = devnull,
    };

    TuiRuntime *rt = tui_runtime_create(
        (TuiComponent *)telnet_app_component(), &app_cfg, &rt_cfg);
    assert(rt != NULL);

    TelnetAppModel *app = (TelnetAppModel *)tui_runtime_model(rt);
    assert(app->terminal_width == 80);
    assert(app->terminal_height == 24);

    /* Send window size through the runtime */
    TuiMsg msg = tui_msg_window_size(120, 40);
    tui_runtime_send(rt, msg);

    assert(app->terminal_width == 120);
    assert(app->terminal_height == 40);

    tui_runtime_free(rt);
    fclose(devnull);
}

/* ======================================================================== */

int main(void)
{
    printf("telnet_app tests:\n");

    /* Component interface tests */
    RUN_TEST(test_component_interface_exists);
    RUN_TEST(test_component_init);
    RUN_TEST(test_component_with_runtime);

    /* WINDOW_SIZE tests */
    RUN_TEST(test_window_size_updates_dimensions);
    RUN_TEST(test_window_size_small);

    /* Mouse scroll tests */
    RUN_TEST(test_mouse_wheel_up_scrolls);
    RUN_TEST(test_mouse_wheel_down_scrolls);
    RUN_TEST(test_mouse_scroll_no_cmd);
    RUN_TEST(test_mouse_click_no_crash);

    /* PageUp/PageDown tests */
    RUN_TEST(test_page_up_scrolls);
    RUN_TEST(test_page_down_scrolls);
    RUN_TEST(test_page_keys_no_cmd);

    /* Runtime integration tests */
    RUN_TEST(test_runtime_flush_renders);
    RUN_TEST(test_runtime_sends_window_size);

    printf("\n%d/%d tests passed.\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
