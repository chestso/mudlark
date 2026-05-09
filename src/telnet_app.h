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
#include <bloom-boba/components/statusbar.h>
#include <bloom-boba/components/textinput.h>
#include <bloom-boba/components/viewport.h>

/* TelnetApp configuration */
typedef struct
{
    int terminal_width;
    int terminal_height;
    const char *prompt; /* Initial prompt string */
    int show_prompt;    /* Show prompt (default: 1) */
    int history_size;   /* Input history size */
} TelnetAppConfig;

/* TelnetApp model - composes viewport, textinput, and statusbar */
typedef struct
{
    TuiModel base; /* Component base type */

    TuiViewport *viewport;   /* Child: server output display (software scrolling) */
    TuiTextInput *textinput; /* Child: user input */
    TuiStatusBar *statusbar; /* Child: status line at bottom */

    int terminal_width;
    int terminal_height;

    /* 0 = textinput, 1 = viewport. Shift-Tab toggles. */
    int focused_widget;
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

/* Get the statusbar component (for direct access) */
TuiStatusBar *telnet_app_get_statusbar(TelnetAppModel *app);

/* Set the prompt string */
void telnet_app_set_prompt(TelnetAppModel *app, const char *prompt);

/* Scrolling control */
void telnet_app_scroll_up(TelnetAppModel *app, int lines);
void telnet_app_scroll_down(TelnetAppModel *app, int lines);
void telnet_app_page_up(TelnetAppModel *app);
void telnet_app_page_down(TelnetAppModel *app);

/* Get component interface for TelnetApp */
const TuiComponent *telnet_app_component(void);

#endif /* TELNET_APP_H */
