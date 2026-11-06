/* telnet_app.h - TelnetApp component: an inline frame over the scrollback
 *
 * The component owns the input line and nothing else: a divider row (with
 * the status right-aligned in it) plus boba's textinput, painted as an
 * inline frame at the bottom of the terminal. Server output is not a child
 * component — it goes to the terminal's own scrollback through the
 * transcript (see telnet_app_echo).
 *
 * This is the main UI component for mudlark.
 */

#ifndef TELNET_APP_H
#define TELNET_APP_H

#include <stddef.h>

#include <boba/component.h>
#include <boba/components/textinput.h>
#include <boba/dynamic_buffer.h>
#include <boba/stream.h>
#include <boba/style.h>
#include <stdint.h>

#include "colors.h"

/* TelnetApp configuration */
typedef struct
{
    int terminal_width;
    int terminal_height;       /* NAWS only: the frame is as tall as its content */
    const char *prompt;        /* Initial prompt string */
    int show_prompt;           /* Show prompt (default: 1) */
    int history_size;          /* Input history size */
    TuiTranscript *transcript; /* borrowed; app owned by main.c */
} TelnetAppConfig;

/* TelnetApp model - the input line, framed by a divider. Status (mode
 * emojis) is embedded as the right-aligned title of that divider. */
typedef struct TelnetAppModel
{
    TuiModel base; /* Component base type */

    TuiTextInput *textinput; /* Child: user input (relative positioning) */

    /* The output seam: server/echo bytes stage here as system-stream
     * units (stream -1, byte-identity) and reach the terminal's
     * scrollback through boba's commit pass at the top of the next
     * flush. Borrowed: main.c creates it and frees it. NULL = echo is
     * dropped (a test or embedding without a transcript). */
    TuiTranscript *transcript;

    /* The divider's base style (faint) and its color role. The role is a
     * UiColor, resolved to a TuiColor per frame so the tier in force is
     * the tier painted. Set via telnet_app_set_border_color() — main.c
     * drives this from connection state. */
    TuiStyle border_style;
    UiColor border_color;

    int terminal_width;
    int terminal_height; /* NAWS only */

    /* 1 = paint an empty frame: the last flush erases the divider and the
     * input row in place so the shell prompt lands on a clean line. */
    int quitting;

    /* Surfaced as TuiView.window_title each frame. Owned (strdup'd);
     * NULL = leave the window title alone. */
    char *window_title;

    /* Right-aligned title rendered into the divider. Owned (strdup'd);
     * NULL or empty = bare divider. Set via telnet_app_set_status_text(). */
    char *status_text;

    /* Reusable scratch buffer for composing the divider title each frame,
     * avoiding a per-frame malloc/free. Owned; freed in telnet_app_free. */
    DynamicBuffer *title_buf;

    /* Line-ending normalization state (see echo_normalize): the kind of the
     * last CR/LF handed to the transcript ('\0' = none), and the scratch
     * buffer the normalized copy is built in. Owned; freed in
     * telnet_app_free. */
    char echo_last_break;
    DynamicBuffer *echo_buf;
} TelnetAppModel;

/* Echo text to the output seam (for terminal-echo builtin and the
 * telnet input path). The bytes stage into the transcript's system
 * stream; the next flush commits them to the terminal's scrollback.
 * Callers flush, as they always have — this function does not.
 *
 * The text is passed through boba's escape scan: SGR survives, cursor
 * movement / EL / OSC / DCS / APC is dropped.
 */
void telnet_app_echo(TelnetAppModel *app, const char *text, size_t len);

/* Build the app's transcript: system stream only (n_streams = 0), no
 * classifiers, no renderers. MUD output is already-rendered bytes, which
 * is exactly the system stream's contract. main.c owns the result and
 * attaches it to the runtime with tui_runtime_set_transcript(). */
TuiTranscript *telnet_app_transcript_create(void);

/* Set terminal size (call on window resize). Width drives the textinput's
 * wrapping; height is kept for NAWS. */
void telnet_app_set_terminal_size(TelnetAppModel *app, int width, int height);

/* Get the textinput component (for direct access) */
TuiTextInput *telnet_app_get_textinput(TelnetAppModel *app);

/* Set the right-aligned title rendered into the divider. NULL or
 * empty string clears it. The string is duplicated internally; callers
 * keep ownership of the input. */
void telnet_app_set_status_text(TelnetAppModel *app, const char *text);

/* Set the prompt string */
void telnet_app_set_prompt(TelnetAppModel *app, const char *prompt);

/* Set the color of the divider line above the textinput. main.c calls this
 * on connect/disconnect to reflect connection state. The RGB triple paints
 * on a truecolor terminal; the ANSI16 slot paints below that. */
void telnet_app_set_border_color(TelnetAppModel *app, UiColor color);

/* Set the window title. Pass NULL to clear. The title is surfaced as
 * TuiView.window_title on the next view(); call tui_runtime_wakeup() if
 * you need it applied immediately while the event loop is idle. */
void telnet_app_set_window_title(TelnetAppModel *app, const char *title);

/* Switch the frame to its quitting shape (empty, cursor hidden). The next
 * flush erases the frame in place; the scrollback above is untouched. */
void telnet_app_set_quitting(TelnetAppModel *app, int quitting);

/* Get component interface for TelnetApp */
const TuiComponent *telnet_app_component(void);

#endif /* TELNET_APP_H */
