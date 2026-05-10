/* telnet_app.c - TelnetApp component implementation
 *
 * Implements software-based scrolling (Bubbletea-style):
 * - No ANSI scroll regions
 * - Viewport stores lines in memory
 * - View renders visible lines with absolute positioning
 * - Full control over cursor position
 */

#include "telnet_app.h"
#include "lisp_extension.h"
#include <bloom-boba/ansi_sequences.h>
#include <bloom-boba/cmd.h>
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

    /* Create viewport child (server output with software scrolling) */
    app->viewport = tui_viewport_create();
    if (!app->viewport) {
        free(app);
        return tui_init_result_none(NULL);
    }

    /* Create textinput child (user input) with multiline support */
    TuiTextInputConfig textinput_cfg = { .multiline = 1 };
    app->textinput = tui_textinput_create(&textinput_cfg);
    if (!app->textinput) {
        tui_viewport_free(app->viewport);
        free(app);
        return tui_init_result_none(NULL);
    }

    /* Border style flanking the textinput. main.c overrides via
     * telnet_app_set_border_color() on connect/disconnect. */
    app->border_style = tui_style_faint(tui_style_new(), 1);

    /* Create statusbar child */
    app->statusbar = tui_statusbar_create();
    if (!app->statusbar) {
        tui_textinput_free(app->textinput);
        tui_viewport_free(app->viewport);
        free(app);
        return tui_init_result_none(NULL);
    }

    /* Configure layout using dynamic height queries */
    telnet_app_set_terminal_size(app, app->terminal_width, app->terminal_height);

    /* Initial focus matches component defaults (textinput focused,
     * viewport blurred); Shift-Tab toggles in update(). */
    app->focused_widget = 0;

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

    if (app->viewport) {
        tui_viewport_free(app->viewport);
    }
    if (app->textinput) {
        tui_textinput_free(app->textinput);
    }
    if (app->statusbar) {
        tui_statusbar_free(app->statusbar);
    }
    free(app->window_title);
    free(app);
}

/* Update TelnetApp with a message */
static TuiUpdateResult telnet_app_update(TuiModel *model, TuiMsg msg)
{
    TelnetAppModel *app = (TelnetAppModel *)model;
    if (!app)
        return tui_update_result_none();

    /* Handle window size message at app level */
    if (msg.type == TUI_MSG_WINDOW_SIZE) {
        telnet_app_set_terminal_size(app, msg.data.size.width,
                                     msg.data.size.height);
        return tui_update_result_none();
    }

    /* Handle mouse events (scroll wheel) */
    if (msg.type == TUI_MSG_MOUSE) {
        if (msg.data.mouse.button == TUI_MOUSE_WHEEL_UP) {
            telnet_app_scroll_up(app, 3);
        } else if (msg.data.mouse.button == TUI_MOUSE_WHEEL_DOWN) {
            telnet_app_scroll_down(app, 3);
        }
        return tui_update_result_none();
    }

    /* Route key messages based on focused widget. */
    if (msg.type == TUI_MSG_KEY_PRESS) {
        /* Shift-Tab toggles focus between textinput and viewport. */
        if (msg.data.key.key == TUI_KEY_TAB &&
            (msg.data.key.mods & TUI_MOD_SHIFT)) {
            app->focused_widget ^= 1;
            TuiMsg ti = app->focused_widget == 0 ? tui_msg_focus()
                                                 : tui_msg_blur();
            TuiMsg vp = app->focused_widget == 1 ? tui_msg_focus()
                                                 : tui_msg_blur();
            TuiUpdateResult ri = tui_textinput_update(app->textinput, ti);
            TuiUpdateResult rv = tui_viewport_component()->update(
                (TuiModel *)app->viewport, vp);
            return (TuiUpdateResult){ .cmd = tui_cmd_batch2(ri.cmd, rv.cmd) };
        }

        /* Page up/down scroll the viewport regardless of focus. */
        if (msg.data.key.key == TUI_KEY_PAGE_UP) {
            telnet_app_page_up(app);
            return tui_update_result_none();
        } else if (msg.data.key.key == TUI_KEY_PAGE_DOWN) {
            telnet_app_page_down(app);
            return tui_update_result_none();
        }

        /* F-keys dispatch to Lisp regardless of focus. */
        if (msg.data.key.key >= TUI_KEY_F1 && msg.data.key.key <= TUI_KEY_F12) {
            int fkey_num = msg.data.key.key - TUI_KEY_F1 + 1;
            lisp_x_call_fkey_hook(fkey_num);
            return tui_update_result_none();
        }

        if (app->focused_widget == 1) {
            return tui_viewport_component()->update((TuiModel *)app->viewport,
                                                    msg);
        }

        TuiUpdateResult result = tui_textinput_update(app->textinput, msg);
        /* Recalculate layout in case textinput height changed (multiline) */
        telnet_app_set_terminal_size(app, app->terminal_width,
                                     app->terminal_height);
        tui_viewport_scroll_to_bottom(app->viewport);
        return result;
    }

    return tui_update_result_none();
}

/* Position cursor at (row, 1), clear-to-EOL, write a styled border edge. */
static void render_border_at(DynamicBuffer *out, int row, int width, int top,
                             const TuiStyle *style)
{
    if (row <= 0 || width <= 0)
        return;
    char *line = tui_border_render_horizontal(&TUI_BORDER_NORMAL, top, width,
                                              style, NULL,
                                              TUI_BORDER_TITLE_LEFT, 0, 0);
    if (!line)
        return;
    char pos[32];
    snprintf(pos, sizeof(pos), CSI "%d;1H", row);
    dynamic_buffer_append_str(out, pos);
    dynamic_buffer_append_str(out, EL_TO_END);
    dynamic_buffer_append_str(out, line);
    free(line);
}

/* Render TelnetApp.
 *
 * Returns a TuiView that declares alt-screen + cell-motion mouse +
 * Kitty keyboard enhancements per frame, plus the cursor (delegated to
 * whichever child currently owns focus) and any pending window title.
 *
 * In viewport-focused mode the cursor is shown immediately at the
 * top-left of the visible region; C-SPC drops/clears the selection mark.
 */
static TuiView telnet_app_view(const TuiModel *model, DynamicBuffer *out)
{
    const TelnetAppModel *app = (const TelnetAppModel *)model;
    if (!app || !out)
        return tui_view_default(out);

    /* Layered render: viewport, top border, textinput, bottom border, statusbar. */
    tui_viewport_view(app->viewport, out);
    render_border_at(out, app->top_border_row, app->terminal_width, 1,
                     &app->border_style);
    tui_textinput_view(app->textinput, out);
    render_border_at(out, app->bottom_border_row, app->terminal_width, 0,
                     &app->border_style);
    tui_statusbar_view(app->statusbar, out);

    TuiView v = tui_view_default(out);
    v.alt_screen = 1;
    v.mouse_mode = TUI_MOUSE_MODE_CELL_MOTION;
    v.kbd_enhancements = TUI_KBD_KITTY;
    v.window_title = app->window_title;
    v.cursor = (app->focused_widget == 1)
                   ? tui_viewport_cursor_pos(app->viewport)
                   : tui_textinput_cursor_pos(app->textinput);
    return v;
}

/* Echo text to the viewport */
void telnet_app_echo(TelnetAppModel *app, const char *text, size_t len)
{
    if (!app || !text || len == 0)
        return;

    /* Append to viewport - it handles line storage and scrolling */
    tui_viewport_append(app->viewport, text, len);
}

/* Set terminal size */
void telnet_app_set_terminal_size(TelnetAppModel *app, int width, int height)
{
    if (!app)
        return;

    app->terminal_width = width;
    app->terminal_height = height;

    int content_lines = tui_textinput_get_height(app->textinput);
    int statusbar_h = tui_statusbar_get_height(app->statusbar); /* 1 */

    /* Layout, bottom-up: statusbar on the last row, then bottom border,
     * textinput content rows, top border, and finally the viewport. */
    int statusbar_row = height;
    app->bottom_border_row = statusbar_row - statusbar_h;
    int textinput_row = app->bottom_border_row - content_lines;
    app->top_border_row = textinput_row - 1;

    int viewport_h = app->top_border_row - 1;
    if (viewport_h < 1)
        viewport_h = 1;

    if (app->viewport) {
        tui_viewport_set_size(app->viewport, width, viewport_h);
        tui_viewport_set_render_position(app->viewport, 1, 1);
    }

    if (app->textinput) {
        tui_textinput_set_terminal_width(app->textinput, width);
        tui_textinput_set_terminal_row(app->textinput, textinput_row);
    }

    if (app->statusbar) {
        tui_statusbar_set_terminal_width(app->statusbar, width);
        tui_statusbar_set_terminal_row(app->statusbar, statusbar_row);
    }
}

/* Get the textinput component */
TuiTextInput *telnet_app_get_textinput(TelnetAppModel *app)
{
    return app ? app->textinput : NULL;
}

/* Get the viewport component */
TuiViewport *telnet_app_get_viewport(TelnetAppModel *app)
{
    return app ? app->viewport : NULL;
}

/* Get the statusbar component */
TuiStatusBar *telnet_app_get_statusbar(TelnetAppModel *app)
{
    return app ? app->statusbar : NULL;
}

/* Set the prompt string */
void telnet_app_set_prompt(TelnetAppModel *app, const char *prompt)
{
    if (app && app->textinput) {
        tui_textinput_set_prompt(app->textinput, prompt);
    }
}

/* Set the foreground color of the top + bottom border lines. */
void telnet_app_set_border_color(TelnetAppModel *app, uint8_t r, uint8_t g,
                                 uint8_t b)
{
    if (!app)
        return;
    app->border_style = tui_style_foreground(tui_style_new(),
                                             tui_color_rgb(r, g, b));
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

/* Scroll up by N lines */
void telnet_app_scroll_up(TelnetAppModel *app, int lines)
{
    if (app && app->viewport) {
        tui_viewport_scroll_up(app->viewport, lines);
    }
}

/* Scroll down by N lines */
void telnet_app_scroll_down(TelnetAppModel *app, int lines)
{
    if (app && app->viewport) {
        tui_viewport_scroll_down(app->viewport, lines);
    }
}

/* Page up */
void telnet_app_page_up(TelnetAppModel *app)
{
    if (app && app->viewport) {
        tui_viewport_page_up(app->viewport);
    }
}

/* Page down */
void telnet_app_page_down(TelnetAppModel *app)
{
    if (app && app->viewport) {
        tui_viewport_page_down(app->viewport);
    }
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
