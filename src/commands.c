/* Special colon commands implementation for mudlark */

#include "commands.h"
#include "../include/telnet.h"
#include "lisp_extension.h"
#include <boba/dynamic_buffer.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* File-level echo callback, set per process_command call */
static CommandEchoFn s_echo_fn = NULL;

/* Helper: Output message via echo callback or stdout */
static void output_message(const char *msg)
{
    if (s_echo_fn) {
        s_echo_fn(msg, strlen(msg));
    } else {
        printf("%s", msg);
        fflush(stdout);
    }
}

/* Helper: Output formatted message via echo callback or stdout */
__attribute__((format(printf, 1, 2))) static void
output_messagef(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        if (s_echo_fn) {
            s_echo_fn(buf, (size_t)n);
        } else {
            printf("%s", buf);
            fflush(stdout);
        }
    }
}

/* Process special commands (starting with :) */
int process_command(const char *text, Telnet *telnet, int *connected_mode,
                    int *quit_requested, int term_cols, int term_rows,
                    CommandEchoFn echo_fn)
{
    s_echo_fn = echo_fn;
    if (!text || text[0] != ':')
        return 0; /* Not a command */

    /* Skip the leading ':' */
    const char *cmd = text + 1;

    /* :help or :h command */
    if (strcmp(cmd, "help") == 0 || strcmp(cmd, "h") == 0) {
        output_message(
            "\n"
            "Available commands:\n"
            "  :help, :h                     - Show this help message\n"
            "  :connect <server> <port>      - Connect to a telnet server\n"
            "  :connect <server>:<port>      - Connect to a telnet server\n"
            "  :disconnect                   - Disconnect from current server\n"
            "  :load <filepath>              - Load and execute a Lisp file\n"
            "  :eval <code>                  - Evaluate Lisp code and show"
            "result\n"
            "  :quit, :q                     - Exit application\n"
            "\n");
        return 1;
    }

    /* :disconnect command */
    if (strcmp(cmd, "disconnect") == 0) {
        if (*connected_mode) {
            telnet_disconnect(telnet);
            *connected_mode = 0;
            output_message("\n*** Disconnected ***\n");
        } else {
            output_message("\n*** Not connected ***\n");
        }
        return 1;
    }

    /* :quit or :q command */
    if (strcmp(cmd, "quit") == 0 || strcmp(cmd, "q") == 0) {
        output_message("\n*** Exiting... ***\n");
        *quit_requested = 1;
        return 1;
    }

    /* :load command */
    if (strncmp(cmd, "load ", 5) == 0) {
        const char *filepath = cmd + 5;

        /* Skip leading spaces */
        while (*filepath == ' ')
            filepath++;

        if (*filepath == '\0') {
            output_message("\n*** Usage: :load <filepath> ***\n");
            return 1;
        }

        /* Remove trailing whitespace */
        size_t len = strlen(filepath);
        while (len > 0 &&
               (filepath[len - 1] == ' ' || filepath[len - 1] == '\t' ||
                filepath[len - 1] == '\r' || filepath[len - 1] == '\n')) {
            len--;
        }

        if (len == 0) {
            output_message("\n*** Error: Invalid filepath ***\n");
            return 1;
        }

        /* Copy filepath */
        char load_filepath[512] = { 0 };
        if (len >= sizeof(load_filepath)) {
            output_message("\n*** Error: Filepath too long ***\n");
            return 1;
        }
        memcpy(load_filepath, filepath, len);
        load_filepath[len] = '\0';

        /* Show loading message */
        output_messagef("\n*** Loading: %s ***\n", load_filepath);

        /* Load and execute the file */
        int result = lisp_x_load_file(load_filepath);
        if (result < 0) {
            output_messagef("\n*** Failed to load: %s ***\n", load_filepath);
        } else {
            output_message("\n*** File loaded successfully ***\n");
        }

        return 1;
    }

    /* :eval <code> - Evaluate Lisp code and echo result */
    if (strncmp(cmd, "eval ", 5) == 0) {
        const char *code = cmd + 5;

        /* Skip leading spaces */
        while (*code == ' ')
            code++;

        if (*code == '\0') {
            output_message("\n*** Usage: :eval <lisp-code> ***\n");
            return 1;
        }

        /* Use static preallocated buffer for eval output */
        static DynamicBuffer *eval_buf = NULL;
        if (!eval_buf) {
            eval_buf = dynamic_buffer_create(4096);
            if (!eval_buf) {
                output_message("\n*** Error: Buffer allocation failed ***\n");
                return 1;
            }
        }

        /* Echo the form before evaluating (so terminal-echo output appears after)
         */
        output_messagef("> %s\n", code);

        /* Delegate to eval mode logic */
        if (lisp_x_eval_and_echo(code, eval_buf) < 0) {
            output_message("\n*** Error: Buffer operation failed ***\n");
            return 1;
        }

        const char *data = dynamic_buffer_data(eval_buf);
        size_t data_len = dynamic_buffer_len(eval_buf);
        if (s_echo_fn) {
            s_echo_fn(data, data_len);
        } else {
            printf("%s", data);
            fflush(stdout);
        }
        return 1;
    }

    /* :connect command */
    if (strncmp(cmd, "connect ", 8) == 0) {
        const char *args = cmd + 8;

        /* Skip leading spaces */
        while (*args == ' ')
            args++;

        if (*args == '\0') {
            output_message("\n*** Usage: :connect <server> <port> or :connect "
                           "<server>:<port> ***\n");
            return 1;
        }

        /* Parse hostname and port */
        char hostname[256] = { 0 };
        int port = 0;

        /* Check for <server>:<port> format */
        const char *colon = strchr(args, ':');
        if (colon) {
            /* Format: server:port */
            size_t hostname_len = colon - args;
            if (hostname_len >= sizeof(hostname)) {
                output_message("\n*** Error: Hostname too long ***\n");
                return 1;
            }
            memcpy(hostname, args, hostname_len);
            hostname[hostname_len] = '\0';
            port = atoi(colon + 1);
        } else {
            /* Format: server port */
            const char *space = strchr(args, ' ');
            if (!space) {
                output_message("\n*** Usage: :connect <server> <port> or :connect "
                               "<server>:<port> ***\n");
                return 1;
            }
            size_t hostname_len = space - args;
            if (hostname_len >= sizeof(hostname)) {
                output_message("\n*** Error: Hostname too long ***\n");
                return 1;
            }
            memcpy(hostname, args, hostname_len);
            hostname[hostname_len] = '\0';

            /* Skip spaces before port */
            const char *port_str = space + 1;
            while (*port_str == ' ')
                port_str++;
            port = atoi(port_str);
        }

        /* Validate port */
        if (port <= 0 || port > 65535) {
            output_message(
                "\n*** Error: Invalid port number (must be 1-65535) ***\n");
            return 1;
        }

        /* Disconnect if already connected */
        if (*connected_mode) {
            telnet_disconnect(telnet);
            *connected_mode = 0;
        }

        /* Attempt connection */
        output_messagef("\n*** Connecting to %s:%d... ***\n", hostname, port);

        if (telnet_connect(telnet, hostname, port, s_echo_fn) < 0) {
            output_messagef("\n*** Failed to connect to %s:%d ***\n", hostname, port);
        } else {
            *connected_mode = 1;
            output_message("\n*** Connected ***\n");

            /* Send NAWS with terminal size */
            telnet_set_terminal_size(telnet, term_cols, term_rows);
        }
        return 1;
    }

    /* Unknown command */
    output_messagef(
        "\n*** Unknown command: %s (type :help for available commands) ***\n",
        cmd);
    return 1;
}
