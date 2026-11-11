/* mudlark - Terminal-based telnet client with Lisp scripting
 *
 * Main entry point. The TUI runtime (boba) owns the event loop,
 * raw mode, and signal handling. This file provides callbacks for
 * telnet I/O, tick timers, resize, and stdin post-processing.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <signal.h>
#include <termios.h>
#include <unistd.h>
#else
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#endif

#include "../include/telnet.h"
#include "colors.h"
#include "commands.h"
#include "lisp_extension.h"
#include "logging.h"
#include "telnet_app.h"
#include <boba/ansi_sequences.h>
#include <boba/cmd.h>
#include <boba/runtime.h>
#include <boba/terminal_profile.h>
#include <ditty/lisp.h>

#include "mudlark_version.h"
#ifndef MUDLARK_VERSION
#define MUDLARK_VERSION "unknown"
#endif

/* --- Crash visibility -------------------------------------------------------
 * In TUI mode stderr is redirected to a per-pid log file, so fatal errors
 * (including sanitizer aborts — the build uses -fno-sanitize-recover=undefined)
 * would otherwise vanish and leave the terminal stuck in raw/alt-screen mode.
 * These hooks write sanitizer reports to files, and a signal handler restores
 * the terminal and points the user at the diagnostics before re-raising. */

#ifndef _WIN32
/* Sanitizer reports -> files (survive the stderr redirect), with stacktraces. */
const char *__asan_default_options(void)
{
    return "abort_on_error=1:detect_leaks=0:log_path=/tmp/mudlark-asan:"
           "print_module_map=1";
}
const char *__ubsan_default_options(void)
{
    return "abort_on_error=1:print_stacktrace=1:log_path=/tmp/mudlark-ubsan";
}

static struct termios g_saved_termios;
static int g_have_saved_termios = 0;
static volatile sig_atomic_t g_tui_started = 0;
static char g_log_path[128];
static char g_crash_msg[256];
static int g_crash_msg_len = 0;

/* write() wrapper that ignores the result — for use inside the signal handler. */
static void sig_write(const char *s, size_t len)
{
    ssize_t n = write(STDOUT_FILENO, s, len);
    (void)n;
}

/* Async-signal-safe: only tcsetattr/write/signal/raise, message pre-formatted.
 * Inline mode has no alt screen to leave, so the restore is the mode set the
 * app turned on: show the cursor, pop the Kitty keyboard flags, disable
 * bracketed paste, reset SGR, and end the line so the shell prompt does not
 * land on the frame's last row. */
static void crash_handler(int sig)
{
    if (g_have_saved_termios)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_saved_termios);
    if (g_tui_started) {
        static const char restore[] = ANSI_SHOW_CURSOR ANSI_DISABLE_KITTY_KBD
            ANSI_DISABLE_BRACKETED_PASTE SGR_RESET "\r\n";
        sig_write(restore, sizeof(restore) - 1);
    }
    if (g_crash_msg_len > 0)
        sig_write(g_crash_msg, (size_t)g_crash_msg_len);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_crash_handlers(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    int sigs[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++)
        sigaction(sigs[i], &sa, NULL);
}
#endif /* _WIN32 */

/* Global state */
static Telnet *g_telnet = NULL;
static TelnetAppModel *g_app = NULL;
static TuiRuntime *g_runtime = NULL;
static TuiTranscript *g_transcript = NULL;
static int g_connected = 0;
static int g_quit_requested = 0;
static int g_server_echo = 0;
int g_term_rows = 24;
int g_term_cols = 80;

/* Convenience accessor for textinput component */
#define g_textinput (telnet_app_get_textinput(g_app))

/* Tab completion cycling state */
static char **g_tab_completions = NULL;
static int g_tab_count = 0;
static int g_tab_index = 0;
static int g_tab_word_start = -1;
static int g_tab_processed = 0;

/* Clear tab-completion cycling state. The completion strings/array are
 * borrowed from lisp_x_complete_prefix()'s reusable storage (valid only until
 * the next call), so we drop the reference here rather than freeing it. */
static void free_tab_completions(void)
{
    g_tab_completions = NULL;
    g_tab_count = 0;
    g_tab_index = 0;
    g_tab_word_start = -1;
}

/* Forward declarations */
static void cleanup(void);
static void update_divider_color(void);
static void print_usage(const char *progname);
static void print_version(void);
static int handle_telnet_data(char *recv_buffer, size_t buffer_size);
static void echo_to_viewport(const char *text, size_t len);
static void handle_app_cmd(TuiCmd *cmd, void *user_data);

/* Update border color based on connection status */
static void update_divider_color(void)
{
    if (!g_app)
        return;
    if (g_connected) {
        UiColor color;
        if (lisp_x_get_color("*color-divider-connected*", &color) < 0)
            color = UI_COLOR_DIVIDER_CONNECTED;
        telnet_app_set_border_color(g_app, color);
    } else {
        UiColor color;
        if (lisp_x_get_color("*color-divider-disconnected*", &color) < 0)
            color = UI_COLOR_DIVIDER_DISCONNECTED;
        telnet_app_set_border_color(g_app, color);
    }
}

/* Mirror the telnet layer's "the server owes an answer" into the frame.
 *
 * The telnet layer owns the fact: a line went out and nothing has come
 * back yet (telnet_awaiting_reply). The frame only shows it — while an
 * answer is owed the frame keeps the row the answer will land in free,
 * so the input line does not jump under the text that arrives.
 *
 * Called wherever the frame is about to be painted with a new answer
 * state: after a line was sent, after the server's output arrived, and
 * after an asynchronous send (telnet-send / send-input) went out. */
static void sync_reply_pending(void)
{
    int pending = g_connected && g_telnet && telnet_awaiting_reply(g_telnet);
    telnet_app_set_reply_pending(g_app, pending);
}

/* Cleanup function called at exit.
 * tui_runtime_run() handles its own stop/raw-mode restore and also
 * registers an atexit handler for abnormal exits. */
static void cleanup(void)
{
    free_tab_completions();

    if (g_telnet) {
        if (g_connected) {
            telnet_disconnect(g_telnet);
        }
        telnet_destroy(g_telnet);
        g_telnet = NULL;
    }

    /* g_app is owned by the runtime — just null our pointer */
    g_app = NULL;

    if (g_runtime) {
        tui_runtime_free(g_runtime);
        g_runtime = NULL;
    }

    /* The transcript outlives the runtime's use of it: boba borrows it,
     * main.c owns it. */
    if (g_transcript) {
        tui_transcript_free(g_transcript);
        g_transcript = NULL;
    }

    lisp_x_cleanup();
}

/* Print usage information */
static void print_usage(const char *progname)
{
    fprintf(stderr,
            "Usage: %s [OPTIONS] [hostname [port]]\n"
            "\n"
            "A terminal-based telnet client with Lisp scripting support.\n"
            "\n"
            "Options:\n"
            "  -h, --help          Show this help message\n"
            "  -v, --version       Show version information\n"
            "  -l, --load FILE     Load a Lisp script at startup\n"
            "  -L, --log SPEC      Enable logging (e.g. '*:DEBUG', "
            "'completion:DEBUG,*:WARN')\n"
            "\n"
            "Arguments:\n"
            "  hostname            Server hostname or IP address\n"
            "  port                Server port (default: 23)\n"
            "\n"
            "Loaded scripts may register additional flags (e.g. --tintin FILE).\n"
            "\n"
            "Commands (prefix with ':'):\n"
            "  :help               Show available commands\n"
            "  :connect HOST PORT  Connect to a server\n"
            "  :disconnect         Disconnect from server\n"
            "  :load FILE          Load a Lisp script\n"
            "  :quit               Exit the client\n"
            "\n",
            progname);
}

/* Print version information */
static void print_version(void)
{
    printf("mudlark %s\n", MUDLARK_VERSION);
}

/* --- Runtime event callbacks --- */

/* Return the telnet socket FD for the runtime to poll (-1 if not connected) */
static size_t get_telnet_fds(TuiIoSource *out, size_t cap, void *user_data)
{
    (void)user_data;
    if (cap == 0)
        return 0;
    if (!g_connected)
        return 0;
    out[0].handle = telnet_get_socket(g_telnet);
    out[0].flags = TUI_IO_READ;
    out[0].kind = TUI_SRC_FD;
    return 1;
}

/* Called when the telnet socket has data ready */
static void on_telnet_ready(intptr_t handle, unsigned ready, void *user_data)
{
    (void)handle;
    (void)ready;
    (void)user_data;
    char recv_buffer[4096];
    handle_telnet_data(recv_buffer, sizeof(recv_buffer));
}

/* Called every ~100ms tick */
static void on_tick(void *user_data)
{
    (void)user_data;
    lisp_x_run_timers();
}

/* Return ms until next timer, or -1 to block indefinitely */
static int get_tick_timeout_ms(void *user_data)
{
    (void)user_data;
    return lisp_x_next_timer_ms();
}

/* Called after terminal resize (runtime already sent WINDOW_SIZE to component)
 */
static void on_resize(int width, int height, void *user_data)
{
    (void)user_data;
    g_term_cols = width;
    g_term_rows = height;
    if (g_connected && g_telnet) {
        telnet_set_terminal_size(g_telnet, g_term_cols, g_term_rows);
    }
}

/* Called after stdin input is processed through the runtime */
static void on_stdin_processed(void *user_data)
{
    (void)user_data;
    if (!g_tab_processed) {
        free_tab_completions();
    }
    g_tab_processed = 0;
}

/* Process a submitted line */
static void process_line(const char *line)
{
    TuiTextInput *textinput = g_textinput;
    if (line[0] != '\0' && !g_server_echo) {
        tui_textinput_history_add(textinput, line);
    }

    /* Check for command */
    if (line[0] == ':') {
        int was_connected = g_connected;
        echo_to_viewport("\n", 1);
        process_command(line, g_telnet, &g_connected, &g_quit_requested,
                        g_term_cols, g_term_rows, echo_to_viewport);
        if (g_quit_requested && g_runtime) {
            /* Switch the frame to its empty shape first: the flush that
             * follows this update erases the divider and the input row in
             * place, so the shell prompt lands on a clean line and the
             * transcript stays in the scrollback. */
            telnet_app_set_quitting(g_app, 1);
            tui_runtime_schedule(g_runtime, tui_cmd_quit());
        }
        if (g_connected != was_connected) {
            update_divider_color();
            if (!g_connected && g_server_echo) {
                g_server_echo = 0;
                tui_textinput_set_echo_mode(g_textinput, 0);
                lisp_x_try_eval_string("(status-mode-remove 'echo-off)");
            }
        }
    } else {
        /* The echo's flush paints the frame, so the frame's answer state
         * has to be right before it: an answer owed by an earlier line
         * still shows, a line that is about to be sent does not (it is
         * not owed until it is on the wire). */
        sync_reply_pending();

        if (g_server_echo) {
            /* Password mode: don't echo the typed text, just the newline */
            echo_to_viewport("\n", 1);
        } else {
            /* Echo user input to the scrollback in the configured role */
            UiColor color;
            if (lisp_x_get_color("*color-user-input*", &color) < 0)
                color = UI_COLOR_USER_INPUT;
            const char *echo_color = ui_fg_sgr(color);
            const char *reset = ui_reset_sgr();
            echo_to_viewport(echo_color, strlen(echo_color));
            echo_to_viewport(line, strlen(line));
            echo_to_viewport(reset, strlen(reset));
            echo_to_viewport("\n", 1);
        }

        /* Call user input filter hook — if consumed, skip transform+send */
        if (!lisp_x_call_user_input_hook(line, strlen(line))) {
            /* Process through user input transform hook */
            LispObject *result = lisp_x_call_user_input_transform_hook(line);
            if (g_connected) {
                /* The line is on the wire: the server owes an answer. */
                lisp_x_send_hook_result(result, g_telnet);
            } else if (result && result != NIL) {
                /* Nothing was sent: no answer is owed. */
                sync_reply_pending();
                echo_to_viewport("Not connected. Use :connect <host> <port>\n", 43);
            }
        }
    }

    /* The line may have gone to the server (or an earlier line may still
     * be waiting for its answer): mirror the telnet layer's state into
     * the frame before it is painted again. */
    sync_reply_pending();

    /* Update prompt */
    const char *prompt = lisp_x_get_prompt();
    telnet_app_set_prompt(g_app, prompt);
}

/* Echo callback for terminal-echo builtin (and the log, command and
 * connect paths). The name predates inline mode and is kept so call sites
 * do not move; the bytes now stage in the transcript's system stream and
 * this flush's commit pass writes them to the terminal's scrollback. */
static void echo_to_viewport(const char *text, size_t len)
{
    if (g_app) {
        telnet_app_echo(g_app, text, len);

        /* One paint: commit the staged bytes and repaint the frame. */
        tui_runtime_flush(g_runtime);
    }
}

/* Handle app-level commands from the runtime (LINE_SUBMIT, TAB_COMPLETE) */
static void handle_app_cmd(TuiCmd *cmd, void *user_data)
{
    (void)user_data;

    if (cmd->type == TUI_CMD_LINE_SUBMIT) {
        free_tab_completions();
        char *text = cmd->payload.line;
        /* Split multiline input and process each line individually */
        char *saveptr = NULL;
        char *line = strtok_r(text, "\n", &saveptr);
        if (line) {
            while (line) {
                process_line(line);
                line = strtok_r(NULL, "\n", &saveptr);
            }
        } else {
            /* Empty submit */
            process_line("");
        }
    } else if (cmd->type == TUI_CMD_TAB_COMPLETE) {
        g_tab_processed = 1;
        int word_start = cmd->payload.tab_complete.word_start;

        if (g_tab_completions && g_tab_word_start == word_start) {
            /* Cycling: advance to next completion */
            g_tab_index = (g_tab_index + 1) % g_tab_count;
            tui_textinput_insert_completion(g_textinput, word_start,
                                            g_tab_completions[g_tab_index]);
        } else {
            /* First Tab at this position: fetch completions */
            free_tab_completions();
            char *prefix = cmd->payload.tab_complete.prefix;
            char **completions = lisp_x_complete_prefix(prefix);

            if (completions && completions[0]) {
                int count = 0;
                while (completions[count])
                    count++;

                g_tab_completions = completions;
                g_tab_count = count;
                g_tab_index = 0;
                g_tab_word_start = word_start;

                tui_textinput_insert_completion(g_textinput, word_start,
                                                completions[0]);
            }
        }
    } else {
        free_tab_completions();
    }

    tui_cmd_free(cmd);
}

/* Handle incoming telnet data. Returns 0 on success, -1 on disconnect */
static int handle_telnet_data(char *recv_buffer, size_t buffer_size)
{
    for (;;) {
        int received = telnet_receive(g_telnet, recv_buffer, buffer_size - 1);

        if (received < 0) {
            g_connected = 0;
            /* No answer will come: the frame gives the row back. */
            sync_reply_pending();
            if (g_server_echo) {
                g_server_echo = 0;
                tui_textinput_set_echo_mode(g_textinput, 0);
                lisp_x_try_eval_string("(status-mode-remove 'echo-off)");
            }
            update_divider_color();
            echo_to_viewport("\n*** Connection lost ***\n", 25);
            return -1;
        }

        if (received == 0)
            break;

        recv_buffer[received] = '\0';

        /* Check for echo state change (password mode toggle) */
        int echo_now = telnet_get_server_echo(g_telnet);
        if (echo_now != g_server_echo) {
            g_server_echo = echo_now;
            tui_textinput_set_echo_mode(g_textinput, echo_now);
            if (echo_now)
                lisp_x_try_eval_string(
                    "(status-mode-set 'echo-off \"\xF0\x9F\x94\x92\" 200)");
            else
                lisp_x_try_eval_string("(status-mode-remove 'echo-off)");
        }

        /* Call input hooks */
        lisp_x_call_telnet_input_hook(recv_buffer, received);
        size_t filtered_len;
        const char *filtered = lisp_x_call_telnet_input_transform_hook(
            recv_buffer, received, &filtered_len);

        /* Echo through the output seam (the flush is once per drain).
         * The server's output is the answer to whatever was pending: the
         * frame gives up the row it kept free for it, and the answer
         * lands in that row. */
        telnet_app_echo(g_app, filtered, filtered_len);
    }

    /* The server's output is the answer: the frame gives the row it kept
     * free back before it is painted again. */
    sync_reply_pending();

    /* Re-render full screen after processing all available data */
    tui_runtime_flush(g_runtime);

    return 0;
}

/* Main event loop — delegates to tui_runtime_run() which owns
 * raw mode, signals, and the select() loop. */
static int run_event_loop(void) { return tui_runtime_run(g_runtime); }

int main(int argc, char *argv[])
{
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif

    const char *hostname = NULL;
    int port = 23;
    const char **load_files = NULL;
    int load_file_count = 0;
    int load_file_capacity = 0;

    /* Parse command line arguments.
     * Manual parsing to support unknown --flag value pairs that Lisp scripts
     * can register handlers for via (register-cli-handler). */
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];

        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(arg, "-v") == 0 || strcmp(arg, "--version") == 0) {
            print_version();
            return 0;
        } else if (strcmp(arg, "-l") == 0 || strcmp(arg, "--load") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Error: %s requires an argument\n", arg);
                return 1;
            }
            if (load_file_count >= load_file_capacity) {
                load_file_capacity = load_file_capacity ? load_file_capacity * 2 : 4;
                load_files = realloc(load_files, load_file_capacity * sizeof(char *));
            }
            load_files[load_file_count++] = argv[i];
        } else if (strcmp(arg, "-L") == 0 || strcmp(arg, "--log") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Error: %s requires an argument\n", arg);
                return 1;
            }
            mudlark_log_set_filter(argv[i]);
        } else if (strncmp(arg, "--", 2) == 0 && strlen(arg) > 2) {
            /* Unknown long option: collect for Lisp dispatch */
            const char *flag = arg + 2;
            if (++i >= argc) {
                fprintf(stderr, "Error: --%s requires an argument\n", flag);
                return 1;
            }
            lisp_x_add_cli_arg(flag, argv[i]);
        } else if (arg[0] == '-' && arg[1] != '\0' && arg[1] != '-') {
            /* Unknown short option: single char after '-' */
            /* Skip known short options that take no arg */
            char short_flag[2] = { arg[1], '\0' };
            if (++i >= argc) {
                fprintf(stderr, "Error: -%s requires an argument\n", short_flag);
                return 1;
            }
            lisp_x_add_cli_arg(short_flag, argv[i]);
        } else {
            /* Positional argument: hostname or port */
            if (!hostname) {
                hostname = arg;
            } else {
                port = atoi(arg);
                if (port <= 0 || port > 65535) {
                    fprintf(stderr, "Invalid port: %s\n", arg);
                    return 1;
                }
            }
        }
    }

    /* Save the terminal state and pre-format a crash message so a fatal signal
     * (e.g. a sanitizer abort) can restore the terminal and tell the user where
     * to look. stderr is redirected to the log file later, once the TUI is up,
     * so fatal errors before that still reach the real terminal. */
#ifndef _WIN32
    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &g_saved_termios) == 0)
        g_have_saved_termios = 1;
    snprintf(g_log_path, sizeof(g_log_path), "/tmp/mudlark.%d.log",
             (int)getpid());
    g_crash_msg_len = snprintf(g_crash_msg, sizeof(g_crash_msg),
                               "\r\nmudlark exited abnormally. Diagnostics: "
                               "%s (sanitizer: /tmp/mudlark-*san.%d)\r\n",
                               g_log_path, (int)getpid());
    if (g_crash_msg_len < 0)
        g_crash_msg_len = 0;
    install_crash_handlers();
#endif

    /* Initialize GC */
    GC_INIT();

    /* Register cleanup */
    atexit(cleanup);

    /* Initialize Lisp */
    if (lisp_x_init() < 0) {
        fprintf(stderr, "Failed to initialize Lisp interpreter\n");
        return 1;
    }

    /* Register terminal echo callback */
    lisp_x_register_echo_callback(echo_to_viewport);

    /* Create telnet client */
    g_telnet = telnet_create();
    if (!g_telnet) {
        fprintf(stderr, "Failed to create telnet client\n");
        return 1;
    }

    /* Create the output seam: system stream only (MUD output is
     * already-rendered bytes). The runtime borrows it; main.c owns it. */
    g_transcript = telnet_app_transcript_create();
    if (!g_transcript) {
        fprintf(stderr, "Failed to create transcript\n");
        return 1;
    }

    /* Create TelnetApp via runtime (the divider + input frame) */
    TelnetAppConfig app_config = {
        .terminal_width = g_term_cols,
        .terminal_height = g_term_rows,
        .prompt = lisp_x_get_prompt(),
        .show_prompt = 1,
        .history_size = lisp_x_get_input_history_size(),
        .transcript = g_transcript,
    };
    /* Render mode (inline), bracketed paste and Kitty keyboard
     * enhancements are declared on TuiView (see telnet_app_view) — not
     * runtime-config fields. */
    TuiRuntimeConfig runtime_config = {
        .raw_mode = 1,
        .output = stdout,
        .cmd_handler = handle_app_cmd,
        .cmd_handler_data = NULL,
        .fill_io_sources = get_telnet_fds,
        .on_io_ready = on_telnet_ready,
        .on_tick = on_tick,
        .get_tick_timeout_ms = get_tick_timeout_ms,
        .on_resize = on_resize,
        .on_stdin_processed = on_stdin_processed,
        .event_data = NULL,
    };
    g_runtime = tui_runtime_create((TuiComponent *)telnet_app_component(),
                                   &app_config, &runtime_config);
    if (!g_runtime) {
        fprintf(stderr, "Failed to create runtime\n");
        return 1;
    }
    g_app = (TelnetAppModel *)tui_runtime_model(g_runtime);

    /* Attach the transcript: its commit pass then runs at the top of
     * every flush, so all units staged in one drain reach the scrollback
     * through exactly one write. */
    tui_runtime_set_transcript(g_runtime, g_transcript);

    /* Register runtime with Lisp extension for terminal control commands */
    lisp_x_register_runtime(g_runtime);

    /* Set initial divider color (gray = disconnected) */
    update_divider_color();

    /* Register TelnetApp model with Lisp extension as the set-status sink */
    lisp_x_register_status_sink(g_app);

    /* An asynchronous send (telnet-send / send-input) happens outside the
     * submit path: the frame learns that an answer is owed from here. */
    lisp_x_register_after_send_callback(sync_reply_pending);

    /* Now that the output seam exists, route log messages through it */
    mudlark_log_set_echo(echo_to_viewport);

    /* From here the TUI owns the screen; redirect stderr to the log file so raw
     * diagnostics (sanitizer reports, libc messages) are captured instead of
     * corrupting the display. Earlier fatal errors still reached the terminal. */
#ifndef _WIN32
    if (isatty(STDERR_FILENO))
        freopen(g_log_path, "w", stderr);
#endif

    /* Enter the terminal mode before loading scripts so their output
     * (script-echo banners, log lines) can be committed: in inline mode the
     * runtime holds no screen of its own, it just starts tracking the
     * terminal. The flush below is what seeds the capability profile —
     * every color formatted before it would resolve at the low tier. */
    tui_runtime_start(g_runtime);
    tui_runtime_flush(g_runtime);
#ifndef _WIN32
    g_tui_started = 1;
#endif

    /* The color tier, from boba's profile: `truecolor` is
     * environment-derived and final from probe start, so one seed per
     * process describes the whole session. Everything formatted below
     * (the banner, the divider, echoed input, log lines) reads it. */
    ui_set_truecolor(tui_runtime_terminal_profile(g_runtime)->truecolor);

    /* Create default session and load init.lisp now that TUI is ready
     * (needs terminal-echo, termcap, etc.) */
    lisp_x_load_init();

    /* Update prompt now that init.lisp has set *prompt* */
    telnet_app_set_prompt(g_app, lisp_x_get_prompt());

    /* Set word chars from Lisp *word-chars* (single source of truth) */
    const char *word_chars = lisp_x_get_word_chars();
    if (word_chars) {
        tui_textinput_set_word_chars(g_textinput, word_chars);
    }

    /* Register telnet with the default session (must be after session creation)
     */
    lisp_x_register_telnet(g_telnet);

    /* Load additional scripts if specified (after init.lisp so script-echo etc.
     * are available, and once the frame is live so logs are visible) */
    for (int i = 0; i < load_file_count; i++) {
        if (lisp_x_load_file(load_files[i]) < 0) {
            mudlark_log(LOG_ERROR, "lisp", "Failed to load: %s", load_files[i]);
        }
    }

    /* Dispatch CLI args to Lisp handlers registered by loaded scripts */
    lisp_x_dispatch_cli_args();

    /* Connect if hostname provided */
    if (hostname) {
        char msg[256];
        snprintf(msg, sizeof(msg), "Connecting to %s:%d...\n", hostname, port);
        telnet_app_echo(g_app, msg, strlen(msg));
        if (telnet_connect(g_telnet, hostname, port, echo_to_viewport) < 0) {
            snprintf(msg, sizeof(msg), "Failed to connect to %s:%d\n", hostname,
                     port);
            telnet_app_echo(g_app, msg, strlen(msg));
        } else {
            g_connected = 1;
            update_divider_color();
            telnet_set_terminal_size(g_telnet, g_term_cols, g_term_rows);
            telnet_app_echo(g_app, "Connected.\n", 11);
        }
    }

    /* Run main event loop */
    int result = run_event_loop();

    /* tui_runtime_stop() (inside the loop's teardown) has moved the cursor
     * below the erased frame and restored the terminal modes, so the
     * goodbye line prints on a fresh row. */
    printf("Goodbye.\n");

    /* Cleanup handled by atexit */
    free(load_files);

    return result;
}
