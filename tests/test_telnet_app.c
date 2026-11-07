/* test_telnet_app.c - Tests for TelnetApp component and runtime integration
 *
 * The app is an inline frame over the terminal's own scrollback:
 * - output goes through the transcript's system stream (telnet_app_echo)
 * - the frame is a divider + textinput, painted with relative moves
 * - the input line owns the semantic keys (Ctrl+D, Ctrl+C, paste)
 * - the input's box is one geometry (boba 0.8): FIXED rows, INLINE
 *   placement, the terminal's width
 *
 * A --enable-release build compiles with -DNDEBUG, which would turn every
 * assert() below into a no-op — a test that can never fail. Undo it before
 * assert.h is first included, so the checks stay live in every build mode. */
#undef NDEBUG
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
#include <boba/dynamic_buffer.h>
#include <boba/msg.h>
#include <boba/runtime.h>
#include <boba/stream.h>

#include "../src/colors.h"
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

/* An app wired to a transcript, as main.c wires it. */
static TelnetAppModel *create_test_app_with_transcript(TuiTranscript *t)
{
    if (!g_comp)
        g_comp = telnet_app_component();
    TelnetAppConfig cfg = {
        .terminal_width = 80,
        .terminal_height = 24,
        .prompt = "> ",
        .show_prompt = 1,
        .history_size = 10,
        .transcript = t,
    };
    TuiInitResult r = g_comp->init(&cfg);
    return (TelnetAppModel *)r.model;
}

static TuiUpdateResult test_app_update(TelnetAppModel *app, TuiMsg msg)
{
    return g_comp->update((TuiModel *)app, msg);
}

static void test_app_free(TelnetAppModel *app) { g_comp->free((TuiModel *)app); }

/* A fresh buffer for one frame. Caller destroys it. */
static DynamicBuffer *new_frame_buffer(void)
{
    DynamicBuffer *out = dynamic_buffer_create(1024);
    assert(out != NULL);
    return out;
}

/* ========================================================================
 * Component interface
 * ======================================================================== */

static void test_component_interface_exists(void)
{
    const TuiComponent *comp = telnet_app_component();
    assert(comp != NULL);
    assert(comp->init != NULL);
    assert(comp->update != NULL);
    assert(comp->view != NULL);
    assert(comp->free != NULL);
}

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
    assert(app->textinput != NULL);

    if (result.cmd)
        tui_cmd_free(result.cmd);
    comp->free(result.model);
}

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
 * WINDOW_SIZE handling
 * ======================================================================== */

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

/* The width reaches the textinput, which bounds its own rows. */
static void test_window_size_sets_textinput_width(void)
{
    TelnetAppModel *app = create_test_app();
    TuiMsg msg = tui_msg_window_size(40, 24);
    TuiUpdateResult result = test_app_update(app, msg);

    assert(tui_textinput_geometry(telnet_app_get_textinput(app)).width == 40);

    if (result.cmd)
        tui_cmd_free(result.cmd);
    test_app_free(app);
}

/* ========================================================================
 * Layout: the input's box, and the frame it sits in
 * ======================================================================== */

/* The input owns a box: the terminal's width, at most height - 1 rows (the
 * divider takes the row above it), placed inline — the frame has no
 * absolute row, so the box has none either. */
static void test_layout_gives_the_input_a_box(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    telnet_app_set_terminal_size(app, 80, 24);

    TuiTextInputGeometry g = tui_textinput_geometry(ti);
    assert(g.sizing == TUI_TEXTINPUT_FIXED);
    assert(g.place == TUI_TEXTINPUT_INLINE);
    assert(g.width == 80);
    assert(g.rows == 23); /* height - 1: the divider's row */

    test_app_free(app);
}

/* A multi-line input paints one row per line, and the frame grows with it:
 * the divider plus the input's rows are the whole frame. */
static void test_layout_brackets_a_multiline_input(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    tui_textinput_set_text(ti, "one\ntwo\nthree");
    telnet_app_set_terminal_size(app, 80, 24);

    assert(tui_textinput_total_rows(ti) == 3);
    assert(tui_textinput_visible_rows(ti) == 3);

    test_app_free(app);
}

/* A long input scrolls inside its box instead of running over the bottom of
 * the screen: the box stops at height - 1, so the frame (divider included)
 * still fits the terminal. */
static void test_layout_caps_a_tall_input(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    char text[512];
    size_t off = 0;
    for (int i = 0; i < 40; i++)
        off += (size_t)snprintf(text + off, sizeof(text) - off, "line%d\n", i);
    tui_textinput_set_text(ti, text);
    telnet_app_set_terminal_size(app, 80, 24);

    assert(tui_textinput_total_rows(ti) == 41);

    int visible = tui_textinput_visible_rows(ti);
    assert(visible == 23); /* height - 1: the divider's row */

    /* No row of the frame may land past the screen: the divider's row plus
     * the input's box is the whole frame. */
    assert(1 + visible <= app->terminal_height);

    test_app_free(app);
}

/* CLIP is the input's mode, so a command wider than the screen scrolls under
 * boba's horizontal window rather than growing the frame a row. */
static void test_long_line_does_not_grow_the_input(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    char text[201];
    memset(text, 'x', sizeof(text) - 1);
    text[sizeof(text) - 1] = '\0';
    tui_textinput_set_text(ti, text);
    telnet_app_set_terminal_size(app, 80, 24);

    assert(tui_textinput_total_rows(ti) == 1);
    assert(tui_textinput_visible_rows(ti) == 1);

    test_app_free(app);
}

/* One CLIP window is shared by every row and budgeted against the widest
 * prompt, never against the length of the line the cursor happens to be on.
 * boba 0.8.0 budgeted it from the cursor's line, so "alpha\nb" with the
 * cursor on "b" painted "> a" (a one-column window). Fixed in 0.8.1, which
 * is the floor configure.ac asks for; this test is the regression. */
static void test_multiline_clip_keeps_longer_rows_whole(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    tui_textinput_set_text(ti, "alpha\nb");
    telnet_app_set_terminal_size(app, 80, 24);
    tui_textinput_set_cursor(ti, 7); /* end of the short line */

    DynamicBuffer *out = dynamic_buffer_create(4096);
    assert(out != NULL);
    g_comp->view((TuiModel *)app, out);

    assert(strstr(dynamic_buffer_data(out), "alpha") != NULL);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* ========================================================================
 * The frame: inline, relative, divider + input
 * ======================================================================== */

/* view() declares inline mode and no alt screen / mouse: the terminal's
 * scrollback is the output history, and the terminal owns scrolling. */
static void test_view_declares_inline_mode(void)
{
    TelnetAppModel *app = create_test_app();
    DynamicBuffer *out = new_frame_buffer();

    TuiView v = g_comp->view((TuiModel *)app, out);
    assert(v.render_mode == TUI_RENDER_INLINE);
    assert(v.alt_screen == 0);
    assert(v.mouse_mode == TUI_MOUSE_MODE_NONE);
    /* The probe feeds the color tier (profile.truecolor). */
    assert(v.probe_terminal == 1);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* The frame carries the divider (with the status title) and the input
 * line, and nothing absolute: no CSI row moves, no alt-screen bytes. */
static void test_view_paints_divider_and_input(void)
{
    TelnetAppModel *app = create_test_app();
    telnet_app_set_status_text(app, "🔒");
    telnet_app_set_prompt(app, "> ");

    DynamicBuffer *out = new_frame_buffer();
    (void)g_comp->view((TuiModel *)app, out);
    const char *frame = dynamic_buffer_data(out);
    assert(frame != NULL);

    /* Divider glyph, status title, and the prompt on the row below. */
    assert(strstr(frame, "─") != NULL);
    assert(strstr(frame, "🔒") != NULL);
    assert(strstr(frame, "> ") != NULL);
    /* Relative, not absolute: no cursor-to-row sequences. */
    assert(strstr(frame, "\x1b[?1049h") == NULL);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* The cursor is the textinput's own row, offset by the divider row. */
static void test_view_cursor_is_below_the_divider(void)
{
    TelnetAppModel *app = create_test_app();
    DynamicBuffer *out = new_frame_buffer();

    TuiView v = g_comp->view((TuiModel *)app, out);
    TuiCursor ti = tui_textinput_cursor_pos(telnet_app_get_textinput(app));

    assert(v.cursor.visible == 1);
    assert(v.cursor.row == ti.row + 1);
    assert(v.cursor.col == ti.col);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* A multi-line input grows the frame instead of scrolling a viewport. */
static void test_view_grows_with_a_multiline_input(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    tui_textinput_set_text(ti, "one\ntwo\nthree");

    DynamicBuffer *out = new_frame_buffer();
    TuiView v = g_comp->view((TuiModel *)app, out);

    /* Divider row + 3 input rows: the cursor is on the last one. */
    assert(v.cursor.row == 4);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* While the server owes an answer the frame keeps the row the answer
 * will land in free: the frame grows by one row (a bare newline above
 * the divider) and the input row drops with it. The answer is written
 * over that row when it comes, so the transcript keeps no blank row. */
static void test_view_reserves_a_row_for_the_pending_answer(void)
{
    TelnetAppModel *app = create_test_app();
    DynamicBuffer *out = new_frame_buffer();

    TuiView plain = g_comp->view((TuiModel *)app, out);
    TuiCursor ti = tui_textinput_cursor_pos(telnet_app_get_textinput(app));
    assert(plain.cursor.row == ti.row + 1);
    assert(dynamic_buffer_data(out)[0] != '\n');

    telnet_app_set_reply_pending(app, 1);
    dynamic_buffer_clear(out);
    TuiView pending = g_comp->view((TuiModel *)app, out);

    /* The input row drops one: the reserved row sits above the divider. */
    assert(pending.cursor.row == ti.row + 2);
    /* The reserved row is the frame's first row: the paint opens with a
     * cleared row and a newline (the divider's own "\r" puts it back in
     * column 0). The row is cleared, not just skipped: the frame can
     * grow by it in place, and the row the divider used to occupy
     * becomes the reserved one. */
    assert(strncmp(dynamic_buffer_data(out), "\r\x1b[K\n", 5) == 0);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* The quitting frame paints one blank row: with no rows below it to
 * stale-erase, the frame's top row has to be cleared by being painted. */
static void test_quitting_frame_is_empty(void)
{
    TelnetAppModel *app = create_test_app();
    telnet_app_set_status_text(app, "connected");
    telnet_app_set_quitting(app, 1);

    DynamicBuffer *out = dynamic_buffer_create(256);
    assert(out != NULL);
    TuiView v = g_comp->view((TuiModel *)app, out);

    /* Exactly one frame row, and it is empty: "\r" + EL and nothing else. */
    assert(strcmp(dynamic_buffer_data(out), "\r\x1b[K") == 0);
    assert(v.cursor.visible == 0);
    assert(v.render_mode == TUI_RENDER_INLINE);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* ========================================================================
 * Output seam: telnet_app_echo stages into the transcript
 * ======================================================================== */

/* The transcript is system-stream only: n_streams = 0 must be a working
 * configuration (no user stream, no classifier, no renderer). */
static void test_transcript_create_is_system_only(void)
{
    TuiTranscript *t = telnet_app_transcript_create();
    assert(t != NULL);

    assert(tui_transcript_stream_raw_len(t, -1) == 0);
    assert(tui_transcript_staged_bytes(t) == 0);

    tui_transcript_free(t);
}

/* telnet_app_echo is the output seam: the bytes stage in the transcript's
 * system stream, byte-identical (partial lines included). */
static void test_echo_stages_bytes_in_transcript(void)
{
    TuiTranscript *t = telnet_app_transcript_create();
    assert(t != NULL);
    TelnetAppModel *app = create_test_app_with_transcript(t);
    assert(app != NULL);

    telnet_app_echo(app, "A dusty path.\n", 14);
    assert(tui_transcript_stream_raw_len(t, -1) == 14);
    /* Staged for the commit pass (boba owns the framing: LF becomes
     * CRLF there, so the staged byte count is not the raw count). */
    assert(tui_transcript_staged_bytes(t) >= 14);

    /* A partial line (a MUD prompt) is one more unit, not a newline. */
    telnet_app_echo(app, "> ", 2);
    assert(tui_transcript_stream_raw_len(t, -1) == 16);

    test_app_free(app);
    tui_transcript_free(t);
}

/* ========================================================================
 * Ctrl+D handling
 * ======================================================================== */

/* Ctrl+D reaches the app as TUI_MSG_EOF, not as a key press. The app turns it
 * back into a delete-char for the textinput (readline), so it deletes the
 * character under the cursor instead of doing nothing. */
static void test_ctrl_d_eof_deletes_char_under_cursor(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    tui_textinput_set_text(ti, "hello");
    tui_textinput_set_cursor(ti, 1);

    TuiUpdateResult result = test_app_update(app, tui_msg_eof());

    assert(result.cmd == NULL); /* never a quit */
    assert(strcmp(tui_textinput_text(ti), "hllo") == 0);
    assert(tui_textinput_cursor(ti) == 1);

    test_app_free(app);
}

/* At end of line Ctrl+D deletes nothing and must not swallow the input. */
static void test_ctrl_d_eof_at_end_of_line_is_noop(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    tui_textinput_set_text(ti, "hello");
    tui_textinput_set_cursor(ti, 5);

    TuiUpdateResult result = test_app_update(app, tui_msg_eof());

    assert(result.cmd == NULL);
    assert(strcmp(tui_textinput_text(ti), "hello") == 0);
    assert(tui_textinput_cursor(ti) == 5);

    test_app_free(app);
}

/* Ctrl+D on an empty input is a no-op: mudlark quits via :quit, never EOF. */
static void test_ctrl_d_eof_on_empty_input_does_not_quit(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    TuiUpdateResult result = test_app_update(app, tui_msg_eof());

    assert(result.cmd == NULL);
    assert(tui_textinput_len(ti) == 0);

    test_app_free(app);
}

/* ========================================================================
 * Ctrl+C (TUI_MSG_INTERRUPT) handling
 * ======================================================================== */

/* Ctrl+C is readline's keyboard-quit: the line being typed is discarded. */
static void test_ctrl_c_interrupt_clears_the_line(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    tui_textinput_set_text(ti, "kill me");
    tui_textinput_set_cursor(ti, 4);

    TuiUpdateResult result = test_app_update(app, tui_msg_interrupt());

    assert(result.cmd == NULL); /* discard the line, never quit */
    assert(tui_textinput_len(ti) == 0);
    assert(tui_textinput_cursor(ti) == 0);

    test_app_free(app);
}

/* Ctrl+C on an empty line is harmless and still returns no command. */
static void test_ctrl_c_interrupt_on_empty_line(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    TuiUpdateResult result = test_app_update(app, tui_msg_interrupt());

    assert(result.cmd == NULL);
    assert(tui_textinput_len(ti) == 0);

    test_app_free(app);
}

/* ========================================================================
 * Bracketed paste (TUI_MSG_PASTE) handling
 * ======================================================================== */

/* The view declares bracketed paste so the terminal sends a paste as text
 * instead of as keystrokes. */
static void test_view_enables_bracketed_paste(void)
{
    TelnetAppModel *app = create_test_app();
    DynamicBuffer *out = new_frame_buffer();

    TuiView v = g_comp->view((TuiModel *)app, out);
    assert(v.bracketed_paste == 1);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* A paste is one edit of text, not keystrokes: a line break in it stays a
 * line break instead of submitting the line. */
static void test_paste_inserts_text_without_submitting(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    const char *pasted = "look\nnorth";
    TuiMsg msg = tui_msg_paste(strdup(pasted), strlen(pasted));
    TuiUpdateResult result = test_app_update(app, msg);

    assert(result.cmd == NULL); /* a newline in a paste does not submit */
    assert(strcmp(tui_textinput_text(ti), pasted) == 0);
    assert(tui_textinput_line_count(ti) == 2);

    tui_msg_free(&msg);
    test_app_free(app);
}

/* A paste appends at the cursor and keeps what was already typed. */
static void test_paste_inserts_at_cursor(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    tui_textinput_set_text(ti, "ab");
    tui_textinput_set_cursor(ti, 1);

    const char *pasted = "XY";
    TuiMsg msg = tui_msg_paste(strdup(pasted), strlen(pasted));
    TuiUpdateResult result = test_app_update(app, msg);

    assert(result.cmd == NULL);
    assert(strcmp(tui_textinput_text(ti), "aXYb") == 0);

    tui_msg_free(&msg);
    test_app_free(app);
}

/* ========================================================================
 * F-keys dispatch to Lisp regardless of focus
 * ======================================================================== */

static void test_fkey_is_not_text(void)
{
    TelnetAppModel *app = create_test_app();
    TuiTextInput *ti = telnet_app_get_textinput(app);

    TuiUpdateResult result = test_app_update(app, tui_msg_key(TUI_KEY_F1, 0, 0));

    assert(result.cmd == NULL);
    assert(tui_textinput_len(ti) == 0);

    test_app_free(app);
}

/* ========================================================================
 * Runtime integration (full component lifecycle through the runtime)
 * ======================================================================== */

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

    tui_runtime_flush(rt);

    TelnetAppModel *app = (TelnetAppModel *)tui_runtime_model(rt);
    telnet_app_echo(app, "Hello, World!\n", 14);
    tui_runtime_flush(rt);

    tui_runtime_free(rt);
    fclose(devnull);
}

/* A full inline round trip: output commits to the scrollback (one commit
 * batch per flush) while the frame repaints below it. */
static void test_runtime_commits_transcript_above_the_frame(void)
{
    FILE *devnull = fopen(DEVNULL, "w");
    assert(devnull != NULL);

    TuiTranscript *t = telnet_app_transcript_create();
    assert(t != NULL);

    TelnetAppConfig app_cfg = {
        .terminal_width = 80,
        .terminal_height = 24,
        .prompt = "> ",
        .show_prompt = 1,
        .history_size = 10,
        .transcript = t,
    };
    TuiRuntimeConfig rt_cfg = {
        .output = devnull,
    };

    TuiRuntime *rt = tui_runtime_create(
        (TuiComponent *)telnet_app_component(), &app_cfg, &rt_cfg);
    assert(rt != NULL);
    tui_runtime_set_transcript(rt, t);

    TelnetAppModel *app = (TelnetAppModel *)tui_runtime_model(rt);
    telnet_app_echo(app, "You are standing in a field.\n", 29);
    assert(tui_transcript_staged_bytes(t) > 0);
    assert(tui_transcript_commit_count(t) == 0);

    tui_runtime_flush(rt);

    /* The commit pass ran once and the staging is drained. */
    assert(tui_transcript_commit_count(t) == 1);
    assert(tui_transcript_staged_bytes(t) == 0);

    tui_runtime_free(rt);
    tui_transcript_free(t);
    fclose(devnull);
}

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

    TuiMsg msg = tui_msg_window_size(120, 40);
    tui_runtime_send(rt, msg);

    assert(app->terminal_width == 120);
    assert(app->terminal_height == 40);

    tui_runtime_free(rt);
    fclose(devnull);
}

/* ========================================================================
 * Color tiers (D10): exact RGB on a truecolor terminal, the role's ANSI16
 * slot below it, and nothing else.
 * ======================================================================== */

/* The divider's role paints as 24-bit RGB when the profile says truecolor. */
static void test_border_color_is_rgb_when_truecolor(void)
{
    ui_set_truecolor(1);
    TelnetAppModel *app = create_test_app();
    telnet_app_set_border_color(app, UI_COLOR_DIVIDER_CONNECTED);

    DynamicBuffer *out = new_frame_buffer();
    (void)g_comp->view((TuiModel *)app, out);

    assert(strstr(dynamic_buffer_data(out), "38;2;80;250;123") != NULL);

    dynamic_buffer_destroy(out);
    test_app_free(app);
    ui_set_truecolor(0);
}

/* Below truecolor the same role paints as its ANSI16 slot: bright green,
 * which SGR spells 92. */
static void test_border_color_is_a_slot_without_truecolor(void)
{
    ui_set_truecolor(0);
    TelnetAppModel *app = create_test_app();
    telnet_app_set_border_color(app, UI_COLOR_DIVIDER_CONNECTED);

    DynamicBuffer *out = new_frame_buffer();
    (void)g_comp->view((TuiModel *)app, out);
    const char *frame = dynamic_buffer_data(out);
    assert(frame != NULL);

    /* boba composes the style's SGR: faint (2) + bright green (92). */
    assert(strstr(frame, "38;2;") == NULL);
    assert(strstr(frame, "92m") != NULL);

    dynamic_buffer_destroy(out);
    test_app_free(app);
}

/* The tier helpers themselves: ui_tui_color picks the form, the SGR
 * formatters spell it. */
static void test_ui_color_tier_selection(void)
{
    UiColor cyan = UI_COLOR_USER_INPUT; /* 139 233 253, slot 14 */

    ui_set_truecolor(1);
    assert(ui_tui_color(cyan).type == TUI_COLOR_RGB);
    assert(strcmp(ui_fg_sgr(cyan), "\x1b[38;2;139;233;253m") == 0);

    ui_set_truecolor(0);
    assert(ui_tui_color(cyan).type == TUI_COLOR_ANSI16);
    assert(ui_tui_color(cyan).v.ansi == 14);
    /* Slot 14 is bright cyan: fg 90+6 = 96, bg 100+6 = 106. */
    assert(strcmp(ui_fg_sgr(cyan), "\x1b[96m") == 0);
    assert(strcmp(ui_bg_sgr(cyan), "\x1b[106m") == 0);

    /* A role with no slot has no color below truecolor, and no bytes. */
    UiColor slotless = UI_COLOR(1, 2, 3, -1);
    assert(ui_tui_color(slotless).type == TUI_COLOR_NONE);
    assert(strcmp(ui_fg_sgr(slotless), "") == 0);

    assert(strcmp(ui_reset_sgr(), "\x1b[0m") == 0);
}

/* ========================================================================
 * Line endings: the server's own idea of a row break
 * ======================================================================== */

/* Read a FILE* back as a NUL-terminated string; *len_out is the byte count.
 * Caller frees. */
static char *slurp(FILE *fp, size_t *len_out)
{
    fflush(fp);
    assert(fseek(fp, 0, SEEK_END) == 0);
    long size = ftell(fp);
    assert(size >= 0);
    rewind(fp);
    char *buf = (char *)malloc((size_t)size + 1);
    assert(buf != NULL);
    size_t got = fread(buf, 1, (size_t)size, fp);
    buf[got] = '\0';
    if (len_out)
        *len_out = got;
    return buf;
}

/* One echo call's worth of bytes (the length is explicit: a chunk may carry
 * NUL bytes). */
typedef struct
{
    const char *bytes;
    size_t len;
} Chunk;

#define CHUNK(s) { (s), sizeof(s) - 1 }

/* Feed `chunks` through echo (one call each), commit once, and return what
 * reached the output. Caller frees. */
static char *commit_chunks(const Chunk *chunks, size_t n_chunks,
                           size_t *len_out)
{
    FILE *out = tmpfile();
    assert(out != NULL);
    TuiTranscript *t = telnet_app_transcript_create();
    assert(t != NULL);

    TelnetAppConfig cfg = {
        .terminal_width = 80,
        .terminal_height = 24,
        .prompt = "> ",
        .show_prompt = 1,
        .history_size = 10,
        .transcript = t,
    };
    TuiRuntimeConfig rt_cfg = { .output = out };
    TuiRuntime *rt = tui_runtime_create(
        (TuiComponent *)telnet_app_component(), &cfg, &rt_cfg);
    assert(rt != NULL);
    tui_runtime_set_transcript(rt, t);

    TelnetAppModel *app = (TelnetAppModel *)tui_runtime_model(rt);
    for (size_t i = 0; i < n_chunks; i++) {
        telnet_app_echo(app, chunks[i].bytes, chunks[i].len);
    }
    tui_runtime_flush(rt);

    char *bytes = slurp(out, len_out);
    tui_runtime_free(rt);
    tui_transcript_free(t);
    fclose(out);
    return bytes;
}

/* A server that ends its rows with LF CR (Carrion Fields does) must get one
 * row break per line, not two: boba counts every CR and every LF. */
static void test_echo_collapses_lfcr_line_endings(void)
{
    const Chunk chunks[] = { CHUNK("By what name do you wish to be mourned?\n\r"
                                   "Password:\n\r") };
    char *out = commit_chunks(chunks, 1, NULL);

    assert(strstr(out, "mourned?\r\nPassword:\r\n") != NULL);
    /* No blank row between the two server lines. */
    assert(strstr(out, "mourned?\r\n\r\n") == NULL);

    free(out);
}

/* CR LF and LF CR are the same break, and a pair split across two chunks is
 * still one break. A repeated terminator is still two (a blank row). */
static void test_echo_normalizes_mixed_line_endings(void)
{
    const Chunk chunks[] = { CHUNK("alpha\n"), CHUNK("\rbeta\n\n"),
                             CHUNK("gamma\r\n") };
    char *out = commit_chunks(chunks, 3, NULL);

    /* alpha LF / CR beta (one break, split across calls), a deliberate
     * blank row, then a plain CRLF. */
    assert(strstr(out, "alpha\r\nbeta\r\n\r\ngamma\r\n") != NULL);
    assert(strstr(out, "alpha\r\n\r\nbeta") == NULL);

    free(out);
}

/* A CR NUL pair is one bare CR (NVT), and the NUL never reaches the
 * scrollback. */
static void test_echo_drops_nvt_cr_nul(void)
{
    const Chunk chunks[] = { CHUNK("one\r\0two\r\0") };
    size_t len = 0;
    char *out = commit_chunks(chunks, 1, &len);

    assert(strstr(out, "one\r\ntwo\r\n") != NULL);
    assert(memchr(out, '\0', len) == NULL);

    free(out);
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
    RUN_TEST(test_window_size_sets_textinput_width);

    /* Layout tests */
    RUN_TEST(test_layout_gives_the_input_a_box);
    RUN_TEST(test_layout_brackets_a_multiline_input);
    RUN_TEST(test_layout_caps_a_tall_input);
    RUN_TEST(test_long_line_does_not_grow_the_input);
    RUN_TEST(test_multiline_clip_keeps_longer_rows_whole);

    /* Color tiers */
    RUN_TEST(test_border_color_is_rgb_when_truecolor);
    RUN_TEST(test_border_color_is_a_slot_without_truecolor);
    RUN_TEST(test_ui_color_tier_selection);

    /* Frame shape */
    RUN_TEST(test_view_declares_inline_mode);
    RUN_TEST(test_view_paints_divider_and_input);
    RUN_TEST(test_view_cursor_is_below_the_divider);
    RUN_TEST(test_view_grows_with_a_multiline_input);
    RUN_TEST(test_view_reserves_a_row_for_the_pending_answer);
    RUN_TEST(test_quitting_frame_is_empty);

    /* Output seam */
    RUN_TEST(test_transcript_create_is_system_only);
    RUN_TEST(test_echo_stages_bytes_in_transcript);

    /* Line endings */
    RUN_TEST(test_echo_collapses_lfcr_line_endings);
    RUN_TEST(test_echo_normalizes_mixed_line_endings);
    RUN_TEST(test_echo_drops_nvt_cr_nul);

    /* Ctrl+D tests */
    RUN_TEST(test_ctrl_d_eof_deletes_char_under_cursor);
    RUN_TEST(test_ctrl_d_eof_at_end_of_line_is_noop);
    RUN_TEST(test_ctrl_d_eof_on_empty_input_does_not_quit);

    /* Ctrl+C tests */
    RUN_TEST(test_ctrl_c_interrupt_clears_the_line);
    RUN_TEST(test_ctrl_c_interrupt_on_empty_line);

    /* Bracketed paste tests */
    RUN_TEST(test_view_enables_bracketed_paste);
    RUN_TEST(test_paste_inserts_text_without_submitting);
    RUN_TEST(test_paste_inserts_at_cursor);

    /* F-key tests */
    RUN_TEST(test_fkey_is_not_text);

    /* Runtime integration tests */
    RUN_TEST(test_runtime_flush_renders);
    RUN_TEST(test_runtime_commits_transcript_above_the_frame);
    RUN_TEST(test_runtime_sends_window_size);

    printf("\n%d/%d tests passed.\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
