/* telnet_app.h - TelnetApp component: composes textview + textinput
 *
 * This component demonstrates the Elm Architecture composition pattern:
 * - Embeds child components (textview, textinput) in its model
 * - Routes messages to children in update()
 * - Composes child views with scroll regions in view()
 *
 * This is the main UI component for bloom-telnet.
 */

#ifndef TELNET_APP_H
#define TELNET_APP_H

#include <stddef.h>

#include <bloom-boba/component.h>
#include <bloom-boba/components/textinput.h>
#include <bloom-boba/components/viewport.h>
#include <bloom-boba/style.h>
#include <stdint.h>

/* TelnetApp configuration */
typedef struct
{
    int terminal_width;
    int terminal_height;
    const char *prompt; /* Initial prompt string */
    int show_prompt;    /* Show prompt (default: 1) */
    int history_size;   /* Input history size */
} TelnetAppConfig;

/* TelnetApp model - composes viewport + textinput. Status (mode emojis)
 * is embedded as the right-aligned title of the top divider. */
typedef struct TelnetAppModel
{
    TuiModel base; /* Component base type */

    TuiViewport *viewport;   /* Child: server output display (software scrolling) */
    TuiTextInput *textinput; /* Child: user input */

    /* Style for the top + bottom border lines that flank the textinput.
     * Set via telnet_app_set_border_color() — main.c drives this from
     * connection state. */
    TuiStyle border_style;

    int terminal_width;
    int terminal_height;

    /* Computed in telnet_app_set_terminal_size, consumed in telnet_app_view. */
    int top_border_row;
    int bottom_border_row;

    /* 0 = textinput, 1 = viewport. Shift-Tab toggles. */
    int focused_widget;

    /* Surfaced as TuiView.window_title each frame. Owned (strdup'd);
     * NULL = leave the window title alone. */
    char *window_title;

    /* Right-aligned title rendered into the top divider. Owned (strdup'd);
     * NULL or empty = bare divider. Set via telnet_app_set_status_text(). */
    char *status_text;
} TelnetAppModel;

/* Custom message types for TelnetApp */
typedef enum
{
    TELNET_APP_MSG_ECHO = TUI_MSG_CUSTOM_BASE + 100, /* Echo text to textview */
} TelnetAppMsgType;

/* Echo message data */
typedef struct
{
    const char *text;
    size_t len;
} TelnetAppEchoData;

/* Echo text to the textview (for terminal-echo builtin)
 * Outputs text to terminal and stores in textview buffer.
 * Converts \n to \r\n for terminal output.
 */
void telnet_app_echo(TelnetAppModel *app, const char *text, size_t len);

/* Set terminal size (call on window resize) */
void telnet_app_set_terminal_size(TelnetAppModel *app, int width, int height);

/* Get the textinput component (for direct access) */
TuiTextInput *telnet_app_get_textinput(TelnetAppModel *app);

/* Get the viewport component (for direct access) */
TuiViewport *telnet_app_get_viewport(TelnetAppModel *app);

/* Set the right-aligned title rendered into the top divider. NULL or
 * empty string clears it. The string is duplicated internally; callers
 * keep ownership of the input. */
void telnet_app_set_status_text(TelnetAppModel *app, const char *text);

/* Set the prompt string */
void telnet_app_set_prompt(TelnetAppModel *app, const char *prompt);

/* Set the foreground color of the top + bottom border lines flanking
 * the textinput. main.c calls this on connect/disconnect to reflect
 * connection state. */
void telnet_app_set_border_color(TelnetAppModel *app, uint8_t r, uint8_t g,
                                 uint8_t b);

/* Set the window title. Pass NULL to clear. The title is surfaced as
 * TuiView.window_title on the next view(); call tui_runtime_wakeup() if
 * you need it applied immediately while the event loop is idle. */
void telnet_app_set_window_title(TelnetAppModel *app, const char *title);

/* Scrolling control */
void telnet_app_scroll_up(TelnetAppModel *app, int lines);
void telnet_app_scroll_down(TelnetAppModel *app, int lines);
void telnet_app_page_up(TelnetAppModel *app);
void telnet_app_page_down(TelnetAppModel *app);

/* Get component interface for TelnetApp */
const TuiComponent *telnet_app_component(void);

#endif /* TELNET_APP_H */
