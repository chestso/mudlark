/* telnet_app.c - TelnetApp component implementation
 *
 * Inline layout (boba TUI_RENDER_INLINE):
 * - The primary screen buffer, no alt screen, no mouse reporting
 * - Server output is committed to the terminal's own scrollback through
 *   the transcript's system stream (see telnet_app_echo)
 * - The frame is the live part only: a divider row (status as its
 *   right-aligned title) and the textinput below it
 * - The terminal owns scrolling, selection and search
 */

#include "telnet_app.h"
#include "colors.h"
#include "lisp_extension.h"
#include <boba/ansi_sequences.h>
#include <boba/cmd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TELNET_APP_TYPE_ID (TUI_COMPONENT_TYPE_BASE + 10)

/* Create a new TelnetApp component */
static TuiInitResult telnet_app_init(void *cfg)
{
    const TelnetAppConfig *config = (const TelnetAppConfig *)cfg;
    TelnetAppModel *app = (TelnetAppModel *)malloc(sizeof(TelnetAppModel));
    if (!app)
        return tui_init_result_none(NULL);

    memset(app, 0, sizeof(TelnetAppModel));
    app->base.type = TELNET_APP_TYPE_ID;

    /* Set terminal dimensions from config or defaults */
    app->terminal_width =
        config && config->terminal_width > 0 ? config->terminal_width : 80;
    app->terminal_height =
        config && config->terminal_height > 0 ? config->terminal_height : 24;

    /* Output seam (borrowed; main.c owns it and attaches it to the
     * runtime). */
    app->transcript = config ? config->transcript : NULL;

    /* Create textinput child (user input) with multiline support. It
     * renders in RELATIVE mode (no terminal row): the inline frame has no
     * absolute coordinate frame, so the textinput returns its cursor in
     * its own coordinates and the composer offsets it by the divider
     * row.
     *
     * CLIP (boba's default), not WRAP: a command line is one visual row in
     * nearly every session, and a line wider than the screen scrolls under
     * boba's one horizontal window the way readline does, rather than
     * growing the frame a row further up. CLIP's window is shared by every
     * row and budgeted against the widest prompt, so a multi-line input
     * whose cursor sits on a short line no longer clips its longer rows to
     * that line's length — in boba 0.8.0 "alpha\nb" with the cursor on "b"
     * painted "> a" — which is why the version floor in configure.ac is
     * 0.8.1. */
    TuiTextInputConfig textinput_cfg = { .multiline = 1 };
    app->textinput = tui_textinput_create(&textinput_cfg);
    if (!app->textinput) {
        free(app);
        return tui_init_result_none(NULL);
    }

    /* Reusable scratch buffers: the divider's title composition and the
     * normalized copy of the output bytes (see echo_normalize). */
    app->title_buf = dynamic_buffer_create(64);
    app->echo_buf = dynamic_buffer_create(256);
    if (!app->title_buf || !app->echo_buf) {
        if (app->title_buf)
            dynamic_buffer_destroy(app->title_buf);
        if (app->echo_buf)
            dynamic_buffer_destroy(app->echo_buf);
        tui_textinput_free(app->textinput);
        free(app);
        return tui_init_result_none(NULL);
    }

    /* Divider style above the input line: faint, with the role's tier
     * resolved per frame (see telnet_app_view). main.c overrides the role
     * via telnet_app_set_border_color() on connect/disconnect. */
    app->border_style = tui_style_faint(tui_style_new(), 1);
    app->border_color = UI_COLOR_DIVIDER_DISCONNECTED;

    telnet_app_set_terminal_size(app, app->terminal_width, app->terminal_height);

    if (config) {
        if (config->prompt) {
            tui_textinput_set_prompt(app->textinput, config->prompt);
        }
        tui_textinput_set_show_prompt(app->textinput, config->show_prompt);
        if (config->history_size > 0) {
            tui_textinput_set_history_size(app->textinput, config->history_size);
        }
    }

    return tui_init_result_none((TuiModel *)app);
}

/* Free TelnetApp component */
static void telnet_app_free(TuiModel *model)
{
    TelnetAppModel *app = (TelnetAppModel *)model;
    if (!app)
        return;

    if (app->textinput) {
        tui_textinput_free(app->textinput);
    }
    free(app->window_title);
    free(app->status_text);
    if (app->title_buf) {
        dynamic_buffer_destroy(app->title_buf);
    }
    if (app->echo_buf) {
        dynamic_buffer_destroy(app->echo_buf);
    }
    free(app);
}

/* Update TelnetApp with a message */
static TuiUpdateResult telnet_app_update(TuiModel *model, TuiMsg msg)
{
    TelnetAppModel *app = (TelnetAppModel *)model;
    if (!app)
        return tui_update_result_none();

    /* Handle window size message at app level. The input is told first: boba
     * 0.8's textinput consumes TUI_MSG_WINDOW_SIZE itself (it keeps the
     * terminal size to clamp its own box, and re-lays-out a resize whether or
     * not it is focused), and telnet_app_set_terminal_size() then measures
     * the box the input will paint — against the size it was just given. */
    if (msg.type == TUI_MSG_WINDOW_SIZE) {
        tui_textinput_update(app->textinput, msg);
        telnet_app_set_terminal_size(app, msg.data.size.width,
                                     msg.data.size.height);
        /* The transcript plans its live region (and, at the seam, its
         * row arithmetic) from the width, so it hears about every
         * resize too. */
        if (app->transcript)
            tui_transcript_update(app->transcript, msg);
        return tui_update_result_none();
    }

    /* Ctrl+D, Ctrl+C and a bracketed paste reach the app as semantic
     * messages, never as key presses: boba's parser decides the meaning and
     * leaves the consequence here. All three belong to the input line,
     * which is the only widget there is. */

    /* Ctrl+D is readline's delete-char: re-issued as the ctrl+d key press the
     * textinput's own deletion path is written for, so it deletes the
     * character under the cursor (and takes its undo snapshot). It is never a
     * quit — quitting is `:quit`. boba 0.7.1 handles TUI_MSG_EOF itself with
     * exactly this edit; the translation stays so the key does not depend on
     * which boba the binary was linked against. */
    if (msg.type == TUI_MSG_EOF)
        msg = tui_msg_key(TUI_KEY_NONE, 'd', TUI_MOD_CTRL);

    /* Ctrl+C is readline's keyboard-quit: discard the line being typed. */
    if (msg.type == TUI_MSG_INTERRUPT) {
        tui_textinput_clear(app->textinput);
        return tui_update_result_none();
    }

    /* A bracketed paste is text, one edit, not synthesized keystrokes: the
     * textinput inserts the payload, so a pasted line break stays a line
     * break instead of submitting the line. */
    if (msg.type == TUI_MSG_PASTE)
        return tui_textinput_update(app->textinput, msg);

    if (msg.type == TUI_MSG_KEY_PRESS) {
        /* F-keys dispatch to Lisp. */
        if (msg.data.key.key >= TUI_KEY_F1 && msg.data.key.key <= TUI_KEY_F12) {
            int fkey_num = msg.data.key.key - TUI_KEY_F1 + 1;
            lisp_x_call_fkey_hook(fkey_num);
            return tui_update_result_none();
        }

        return tui_textinput_update(app->textinput, msg);
    }

    return tui_update_result_none();
}

/* Build the divider row on the CURRENT row: carriage return + erase, then
 * the rule. `title` (optional) is embedded per `align` + padding. */
static void render_divider_here(DynamicBuffer *out, int width,
                                const TuiBorder *border, const TuiStyle *style,
                                const char *title)
{
    if (width <= 0 || !border)
        return;
    char *line = tui_border_render_horizontal(border, 1, width, style, title,
                                              TUI_BORDER_TITLE_RIGHT, 0, 0);
    if (!line)
        return;
    dynamic_buffer_append_str(out, "\r");
    dynamic_buffer_append_str(out, EL_TO_END);
    dynamic_buffer_append_str(out, line);
    free(line);
}

/* Render the divider with `title` right-aligned, padded with one space on
 * each side and capped with one trailing edge tile — the line reads
 * ───── TITLE ─. The trailing tile is read from the same border the rest of
 * the line is rendered with, so the tail glyph can never drift from the
 * divider's own edge char.
 *
 * Works around boba's title_pad_right adding a literal space
 * instead of an edge tile (matches lipgloss's design: caller composes
 * whatever surrounds the title). NULL or empty `title` falls back to a
 * plain divider. */
static void render_divider_titled(DynamicBuffer *out, int width,
                                  const TuiBorder *border,
                                  const TuiStyle *style, const char *title,
                                  DynamicBuffer *scratch)
{
    if (!title || !*title || !border) {
        render_divider_here(out, width, border, style, NULL);
        return;
    }
    const char *edge = border->top ? border->top : "";
    /* Composed title: " " + title + " " + edge, built into the reusable
     * scratch buffer so the render path does no per-frame heap churn. */
    dynamic_buffer_clear(scratch);
    if (dynamic_buffer_append(scratch, " ", 1) != 0 ||
        dynamic_buffer_append_str(scratch, title) != 0 ||
        dynamic_buffer_append(scratch, " ", 1) != 0 ||
        dynamic_buffer_append_str(scratch, edge) != 0) {
        render_divider_here(out, width, border, style, title);
        return;
    }
    render_divider_here(out, width, border, style,
                        dynamic_buffer_data(scratch));
}

/* Render TelnetApp.
 *
 * The frame is two-or-more rows at the bottom of the terminal's own
 * output: the divider (status right-aligned in it), then the textinput,
 * which may soft-wrap onto further rows. Everything above the frame is
 * scrollback the terminal owns.
 *
 * All positioning is relative — boba's inline render moves the cursor up
 * over the previous frame and writes this one from there — so each row
 * clears itself with "\r" + EL instead of an absolute CSI row move. The
 * cursor is the textinput's own, offset by the divider row.
 */
static TuiView telnet_app_view(const TuiModel *model, DynamicBuffer *out)
{
    const TelnetAppModel *app = (const TelnetAppModel *)model;
    if (!app || !out)
        return tui_view_default(out);

    TuiView v = tui_view_default(out);
    v.render_mode = TUI_RENDER_INLINE;
    /* Bracketed paste: a paste then arrives as TUI_MSG_PASTE text instead of
     * keystrokes, so a pasted line break does not submit the line. */
    v.bracketed_paste = 1;
    v.kbd_enhancements = TUI_KBD_KITTY;
    v.window_title = app->window_title;
    /* Declared so boba's capability probe runs at startup: profile.truecolor
     * decides the color tier (see colors.c), and it is only seeded by a
     * flush that declares this. main.c flushes once, right after
     * tui_runtime_start(), so init.lisp formats its banner at the right
     * tier. */
    v.probe_terminal = 1;

    /* Quitting: the frame is empty, so the final paint erases the divider
     * and the input row in place and the scrollback above keeps the
     * transcript. (This is the shape that survives the flush after a
     * drain: tui_runtime_clear_inline would be undone by it.) The one
     * emitted row is a bare "\r" + EL — boba's inline stale-row erase only
     * covers rows BELOW the last painted one, so the frame's top row has
     * to be cleared by being painted empty, not by being skipped. */
    if (app->quitting) {
        dynamic_buffer_append_str(out, "\r");
        dynamic_buffer_append_str(out, EL_TO_END);
        v.cursor = tui_cursor_hidden();
        return v;
    }

    /* The role resolves in the tier in force NOW: a profile that landed
     * after the last frame simply changes what this one draws. */
    TuiStyle divider =
        tui_style_foreground(app->border_style, ui_tui_color(app->border_color));
    render_divider_titled(out, app->terminal_width, &TUI_BORDER_NORMAL,
                          &divider, app->status_text, app->title_buf);
    dynamic_buffer_append_str(out, "\r\n");
    tui_textinput_view(app->textinput, out);

    /* The textinput's rows start one below the divider. */
    TuiCursor c = tui_textinput_cursor_pos(app->textinput);
    v.cursor = c.visible ? tui_cursor_at(c.row + 1, c.col) : tui_cursor_hidden();
    return v;
}

/* Hand the transcript sane line terminators.
 *
 * boba's row scanner turns EVERY CR and every LF into a row break — it only
 * folds the pair when both bytes sit in the same chunk — and MUD servers are
 * not careful about endings. Carrion Fields, for one, ends its rows with
 * "\n\r", which would double every line break into a blank row.
 *
 * NVT says CR LF ends a row and CR NUL is a bare CR, so the messy reality is
 * normalized here, once, before the bytes reach the transcript:
 *
 *   CR LF / LF CR   one row break, whichever order the server used
 *   CR CR / LF LF   two row breaks, as sent
 *   NUL             dropped (NVT padding after a CR)
 *
 * The kind of the last terminator is remembered across calls, because a
 * chunk boundary can fall between the two halves of a pair.
 */
static void echo_normalize(TelnetAppModel *app, const char *text, size_t len,
                           const char **out, size_t *out_len)
{
    DynamicBuffer *buf = app->echo_buf;
    dynamic_buffer_clear(buf);

    int pending = app->echo_last_break;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c == '\r' || c == '\n') {
            if (pending != 0 && c != (unsigned char)pending) {
                /* The other half of a CR LF / LF CR pair: one row break. */
                pending = 0;
                continue;
            }
            pending = (int)c;
            dynamic_buffer_append(buf, text + i, 1);
            continue;
        }
        if (c == 0x00)
            continue; /* NVT padding */
        pending = 0;
        dynamic_buffer_append(buf, text + i, 1);
    }
    app->echo_last_break = (char)pending;

    *out = dynamic_buffer_data(buf);
    *out_len = dynamic_buffer_len(buf);
}

/* Echo text to the output seam: one system-stream unit (-1), staged and
 * committed by the next flush. Byte-identity is the system stream's
 * contract, so a partial last line (a MUD prompt) stays an open row and
 * the next write continues it — which is also why the line endings are
 * normalized first: boba counts every CR and every LF as a row break. */
void telnet_app_echo(TelnetAppModel *app, const char *text, size_t len)
{
    if (!app || !text || len == 0)
        return;

    if (app->transcript) {
        const char *bytes = text;
        size_t n = len;
        echo_normalize(app, text, len, &bytes, &n);
        if (n > 0) {
            TuiMsg msg = tui_msg_stream_text(-1, bytes, n);
            tui_transcript_update(app->transcript, msg);
            tui_msg_free(&msg);
        }
    }
}

/* Build the transcript: system stream only. n_streams = 0 means no
 * classifier and no render_block — output is already-rendered bytes. */
TuiTranscript *telnet_app_transcript_create(void)
{
    TuiTranscriptConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.n_streams = 0;
    return tui_transcript_create(&cfg);
}

/* Set terminal size. The width is the input's content width; the height
 * caps the rows it may paint (see telnet_app_set_terminal_size) and is
 * kept for NAWS. */
void telnet_app_set_terminal_size(TelnetAppModel *app, int width, int height)
{
    if (!app)
        return;

    app->terminal_width = width;
    app->terminal_height = height;

    if (!app->textinput)
        return;

    /* boba 0.8's geometry is one struct: the input owns a box of `rows` at
     * `width` (FIXED), and the frame is inline, so the box has no absolute
     * row (INLINE) — the divider above it and the input's own rows are what
     * the frame is made of.
     *
     * The box is capped at height - 1 (the divider takes the row above it),
     * so a long multi-line input scrolls inside its box instead of pushing
     * the cursor off the bottom of the screen. The frame's height follows
     * the rows the input actually paints: boba's textinput emits one row
     * separator per row in INLINE mode, which is what the runtime counts. */
    int max_rows = height - 1;
    if (max_rows < 1)
        max_rows = 1;

    TuiTextInputGeometry geom = tui_textinput_geometry(app->textinput);
    geom.sizing = TUI_TEXTINPUT_FIXED;
    geom.place = TUI_TEXTINPUT_INLINE;
    geom.width = width;
    geom.rows = max_rows;
    tui_textinput_set_geometry(app->textinput, &geom);
}

/* Get the textinput component */
TuiTextInput *telnet_app_get_textinput(TelnetAppModel *app)
{
    return app ? app->textinput : NULL;
}

/* Set the right-aligned status text rendered into the divider. */
void telnet_app_set_status_text(TelnetAppModel *app, const char *text)
{
    if (!app)
        return;
    free(app->status_text);
    app->status_text = (text && *text) ? strdup(text) : NULL;
}

/* Set the prompt string */
void telnet_app_set_prompt(TelnetAppModel *app, const char *prompt)
{
    if (app && app->textinput) {
        tui_textinput_set_prompt(app->textinput, prompt);
    }
}

/* Set the foreground color of the divider line. The role is stored as a
 * UiColor and resolved to a TuiColor in view(), so a tier change (the
 * capability profile landing after the first flush) needs no special case
 * here. */
void telnet_app_set_border_color(TelnetAppModel *app, UiColor color)
{
    if (!app)
        return;
    app->border_color = color;
}

/* Set the window title. The next view() will surface it via
 * TuiView.window_title; the runtime emits OSC 2 on the next flush. */
void telnet_app_set_window_title(TelnetAppModel *app, const char *title)
{
    if (!app)
        return;
    free(app->window_title);
    app->window_title = title ? strdup(title) : NULL;
}

/* Enter the quitting frame: nothing painted, cursor hidden, so the final
 * flush erases the frame area and the terminal keeps the scrollback. */
void telnet_app_set_quitting(TelnetAppModel *app, int quitting)
{
    if (!app)
        return;
    app->quitting = quitting ? 1 : 0;
}

/* Static component interface instance */
static const TuiComponent telnet_app_component_instance = {
    .init = telnet_app_init,
    .update = telnet_app_update,
    .view = telnet_app_view,
    .free = telnet_app_free,
};

/* Get component interface for TelnetApp */
const TuiComponent *telnet_app_component(void)
{
    return &telnet_app_component_instance;
}
