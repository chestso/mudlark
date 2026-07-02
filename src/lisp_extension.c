/* Lisp extension implementation for mudlark */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "../include/telnet.h"
#include "../include/terminal_caps.h"
#include "lisp_extension.h"
#include "logging.h"
#include "path_utils.h"
#include "session.h"
#include "telnet_app.h"
#include <boba/cmd.h>
#include <boba/dynamic_buffer.h>
#include <boba/runtime.h>
#include <ditty/file_utils.h>
#include <ditty/lisp.h>
#include <gc/gc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mudlark_version.h"
#ifndef MUDLARK_VERSION
#define MUDLARK_VERSION "unknown"
#endif

/* Registered TelnetApp model for set-status builtin */
static TelnetAppModel *registered_status_sink = NULL;

/* Registered runtime for terminal control commands */
static TuiRuntime *registered_runtime = NULL;

/* Terminal echo callback */
static TerminalEchoCallback echo_callback = NULL;

/* Pending telnet-send buffer: \0-separated strings flushed by event loop */
static DynamicBuffer *pending_send_buf = NULL;
static int pending_send_scheduled = 0;
static TuiMsg flush_pending_sends(void *data);

/* CLI argument handler registry: hash table mapping flag name → handler symbol.
 * Lisp scripts call (register-cli-handler short long handler) to register.
 * After all -l files load, main.c calls lisp_x_dispatch_cli_args(). */
static LispObject *cli_handler_table = NULL;

/* Pending CLI args collected during main() arg parsing */
typedef struct
{
    char flag[64];
    char value[512];
} CliArg;
static CliArg *cli_pending_args = NULL;
static int cli_pending_count = 0;
static int cli_pending_capacity = 0;

/* Update terminal window title to "mudlark - session_name" */
static void update_terminal_title(void)
{
    if (!registered_runtime)
        return;
    Session *s = session_get_current();
    const char *name = s ? s->name : "default";
    char title[256];
    snprintf(title, sizeof(title), "mudlark - %s", name);

    /* v2: window title is declared on TuiView. Stash it on the model;
     * the next flush picks it up. Wake the event loop so the title is
     * applied without waiting for input. */
    TelnetAppModel *app = (TelnetAppModel *)tui_runtime_model(registered_runtime);
    if (app)
        telnet_app_set_window_title(app, title);
    tui_runtime_wakeup(registered_runtime);
}

/* ========================================================================
 * Hook storage helpers — hooks are stored in a *hooks* hash table
 * in each session's Lisp env.  Key = hook name string,
 * Value = sorted list of (fn . priority) cons cells.
 * ======================================================================== */

/* Get the *hooks* hash table from the current session's C struct, or NULL */
static LispObject *get_session_hooks(void)
{
    Session *s = session_get_current();
    if (!s || !s->hooks || LISP_TYPE(s->hooks) != LISP_HASH_TABLE) {
        return NULL;
    }
    return s->hooks;
}

/* Check if fn already exists in a hook entry list (by pointer identity) */
static int hooks_has_fn(LispObject *list, LispObject *fn)
{
    while (list != NIL && LISP_TYPE(list) == LISP_CONS) {
        LispObject *entry = lisp_car(list);
        if (entry && LISP_TYPE(entry) == LISP_CONS && lisp_car(entry) == fn) {
            return 1;
        }
        list = lisp_cdr(list);
    }
    return 0;
}

/* Insert (fn . priority) into a sorted list, return new list head */
static LispObject *hooks_insert_sorted(LispObject *fn, int priority,
                                       LispObject *list)
{
    LispObject *entry = lisp_make_cons(fn, lisp_make_integer(priority));

    /* Empty list or insert before first element */
    if (list == NIL || LISP_TYPE(list) != LISP_CONS) {
        return lisp_make_cons(entry, NIL);
    }

    /* Check if we should insert before the head */
    LispObject *head_entry = lisp_car(list);
    int head_prio = (int)LISP_INT_VAL(lisp_cdr(head_entry));
    if (priority < head_prio) {
        return lisp_make_cons(entry, list);
    }

    /* Walk the list to find insertion point — rebuild as we go since
     * Lisp cons cells are immutable-ish (we build a new spine) */
    LispObject *result = NIL;
    LispObject **tail = &result;
    int inserted = 0;

    while (list != NIL && LISP_TYPE(list) == LISP_CONS) {
        LispObject *cur = lisp_car(list);
        int cur_prio = (int)LISP_INT_VAL(lisp_cdr(cur));

        if (!inserted && priority < cur_prio) {
            *tail = lisp_make_cons(entry, NIL);
            tail = &LISP_CDR(*tail);
            inserted = 1;
        }

        *tail = lisp_make_cons(cur, NIL);
        tail = &LISP_CDR(*tail);
        list = lisp_cdr(list);
    }

    if (!inserted) {
        *tail = lisp_make_cons(entry, NIL);
    }

    return result;
}

/* Remove fn from hook entry list (by pointer identity), return new list */
static LispObject *hooks_remove_fn(LispObject *list, LispObject *fn)
{
    LispObject *result = NIL;
    LispObject **tail = &result;

    while (list != NIL && LISP_TYPE(list) == LISP_CONS) {
        LispObject *entry = lisp_car(list);
        if (entry && LISP_TYPE(entry) == LISP_CONS && lisp_car(entry) == fn) {
            /* Skip this entry — append rest and return */
            *tail = lisp_cdr(list);
            return result;
        }
        *tail = lisp_make_cons(entry, NIL);
        tail = &LISP_CDR(*tail);
        list = lisp_cdr(list);
    }

    return result;
}

/* Apply *default-hooks* entries into a hooks hash table */
static void apply_default_hooks_to_table(LispObject *hooks_table)
{
    if (!hooks_table || LISP_TYPE(hooks_table) != LISP_HASH_TABLE) {
        return;
    }
    Environment *base = session_get_base_env();
    if (!base) {
        return;
    }
    LispObject *defaults =
        env_lookup(base, LISP_SYM_VAL(lisp_intern("*default-hooks*")));
    if (!defaults || defaults == NIL) {
        return;
    }

    /* Walk list of (name-string fn . priority) triples */
    while (defaults != NIL && LISP_TYPE(defaults) == LISP_CONS) {
        LispObject *triple = lisp_car(defaults);
        if (triple && LISP_TYPE(triple) == LISP_CONS) {
            LispObject *name_obj = lisp_car(triple);
            LispObject *fn_and_prio = lisp_cdr(triple);
            if (name_obj && LISP_TYPE(name_obj) == LISP_STRING && fn_and_prio &&
                LISP_TYPE(fn_and_prio) == LISP_CONS) {
                LispObject *fn = lisp_car(fn_and_prio);
                LispObject *prio_obj = lisp_cdr(fn_and_prio);
                int priority = 50;
                if (prio_obj && LISP_TYPE(prio_obj) == LISP_INTEGER) {
                    priority = (int)LISP_INT_VAL(prio_obj);
                }

                struct HashEntry *he = hash_table_get_entry(hooks_table, name_obj);
                LispObject *hook_list = (he && he->value) ? he->value : NIL;

                if (!hooks_has_fn(hook_list, fn)) {
                    hook_list = hooks_insert_sorted(fn, priority, hook_list);
                    hash_table_set_entry(hooks_table, name_obj, hook_list);
                }
            }
        }
        defaults = lisp_cdr(defaults);
    }
}

/* Reusable scratch buffers for hook processing. These grow to a steady-state
 * size and are reused across calls, so the underlying allocations stabilize
 * and stop reallocating after warmup. */
static DynamicBuffer *ansi_strip_buf = NULL;
static DynamicBuffer *telnet_filter_buf = NULL;
static DynamicBuffer *telnet_filter_temp_buf = NULL;

/* Reusable storage for tab-completion candidates. The candidate strings are
 * packed back-to-back in completion_arena; completion_ptrs holds borrowed
 * pointers into that arena (NULL-terminated). Both are reused across Tab
 * presses instead of malloc/strdup/free per press. The pointers returned by
 * lisp_x_complete_prefix() are valid only until the next call. */
static DynamicBuffer *completion_arena = NULL;
static char **completion_ptrs = NULL;
static int completion_ptrs_cap = 0;

/* Helper: get the environment for Lisp evaluation (always base env) */
static Environment *get_current_env(void) { return session_get_base_env(); }

/* Strip ANSI escape sequences from input */
static char *strip_ansi_codes(const char *input, size_t len, size_t *out_len)
{
    if (!input || len == 0 || !out_len) {
        if (out_len)
            *out_len = 0;
        return NULL;
    }

    if (dynamic_buffer_ensure_size(ansi_strip_buf, len + 1) < 0) {
        *out_len = 0;
        return NULL;
    }
    char *out = ansi_strip_buf->data;

    size_t out_pos = 0;
    int in_escape = 0;
    int in_csi = 0;

    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)input[i];

        if (in_escape) {
            if (c == '[') {
                in_csi = 1;
                in_escape = 0;
            } else if (c >= 0x40 && c <= 0x5F) {
                in_escape = 0;
            } else if (c == 0x1B) {
                /* Another ESC */
            } else {
                in_escape = 0;
            }
            continue;
        }

        if (in_csi) {
            if ((c >= 0x40 && c <= 0x7E) || c == 0x1B) {
                in_csi = 0;
                if (c == 0x1B) {
                    in_escape = 1;
                }
            }
            continue;
        }

        if (c == 0x1B) {
            in_escape = 1;
            continue;
        }

        if (c >= 0x20 || c == '\n' || c == '\r' || c == '\t') {
            if (out_pos < ansi_strip_buf->size - 1) {
                out[out_pos++] = c;
            }
        }
    }

    out[out_pos] = '\0';
    ansi_strip_buf->len = out_pos;
    *out_len = out_pos;
    return out;
}

/* Builtin: strip-ansi - Remove ANSI escape sequences from text */
static LispObject *builtin_strip_ansi(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL) {
        return lisp_make_error("strip-ansi requires 1 argument");
    }

    LispObject *text_obj = lisp_car(args);
    if (LISP_TYPE(text_obj) != LISP_STRING) {
        return lisp_make_error("strip-ansi: argument must be a string");
    }

    const char *text = LISP_STR_VAL(text_obj);
    size_t len = strlen(text);
    size_t out_len = 0;

    char *stripped = strip_ansi_codes(text, len, &out_len);
    if (!stripped) {
        return lisp_make_string("");
    }

    return lisp_make_string(stripped);
}

/* Builtin: terminal-echo - Output text to textview/stdout (local echo) */
static LispObject *builtin_terminal_echo(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL) {
        return NIL;
    }

    LispObject *text_obj = lisp_car(args);
    if (LISP_TYPE(text_obj) != LISP_STRING) {
        return lisp_make_error("terminal-echo: argument must be a string");
    }

    const char *text = LISP_STR_VAL(text_obj);
    size_t len = strlen(text);

    /* Use callback if registered (handles scroll region positioning) */
    if (echo_callback) {
        echo_callback(text, len);
    } else {
        /* Fallback: output to stdout, converting \n to \r\n */
        for (const char *p = text; *p; p++) {
            if (*p == '\n' && (p == text || *(p - 1) != '\r')) {
                putchar('\r');
            }
            putchar(*p);
        }
        fflush(stdout);
    }

    return NIL;
}

/* Builtin: telnet-send - Queue text for raw send via event loop */
static LispObject *builtin_telnet_send(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL)
        return lisp_make_error("telnet-send requires 1 argument");

    LispObject *text_obj = lisp_car(args);
    if (LISP_TYPE(text_obj) != LISP_STRING)
        return lisp_make_error("telnet-send: argument must be a string");

    if (!registered_runtime)
        return lisp_make_error("telnet-send: no runtime registered");

    const char *text = LISP_STR_VAL(text_obj);
    dynamic_buffer_append(pending_send_buf, text, strlen(text));
    dynamic_buffer_append(pending_send_buf, "\0", 1);

    if (!pending_send_scheduled) {
        tui_runtime_schedule(registered_runtime,
                             tui_cmd_custom(flush_pending_sends, NULL, NULL));
        pending_send_scheduled = 1;
    }
    return NIL;
}

/* Interned termcap symbols for pointer comparison */
static LispObject *sym_tc_cols = NULL;
static LispObject *sym_tc_rows = NULL;
static LispObject *sym_tc_type = NULL;
static LispObject *sym_tc_encoding = NULL;
static LispObject *sym_tc_color_level = NULL;
static LispObject *sym_tc_truecolor = NULL;
static LispObject *sym_tc_256color = NULL;
static LispObject *sym_tc_unicode = NULL;
static LispObject *sym_tc_describe = NULL;
static LispObject *sym_tc_reset = NULL;
static LispObject *sym_tc_fg_color = NULL;
static LispObject *sym_tc_bg_color = NULL;

/* Builtin: termcap - Unified terminal capability query */
static LispObject *builtin_termcap(LispObject *args, Environment *env)
{
    (void)env;
    extern int g_term_cols;
    extern int g_term_rows;

    if (args == NIL) {
        return lisp_make_error("termcap requires at least 1 argument");
    }

    LispObject *key = lisp_car(args);
    if (LISP_TYPE(key) != LISP_SYMBOL) {
        return lisp_make_error("termcap: first argument must be a symbol");
    }

    args = lisp_cdr(args);

    /* Simple queries */
    if (key == sym_tc_cols)
        return lisp_make_integer(g_term_cols);
    if (key == sym_tc_rows)
        return lisp_make_integer(g_term_rows);
    if (key == sym_tc_type) {
        const char *t = termcaps_get_term_type();
        return lisp_make_string(t ? t : "");
    }
    if (key == sym_tc_encoding) {
        const char *e = termcaps_get_encoding();
        return lisp_make_string(e ? e : "ASCII");
    }
    if (key == sym_tc_color_level)
        return lisp_make_integer(termcaps_get_color_level());
    if (key == sym_tc_truecolor)
        return termcaps_supports_truecolor() ? LISP_TRUE : NIL;
    if (key == sym_tc_256color)
        return termcaps_supports_256color() ? LISP_TRUE : NIL;
    if (key == sym_tc_unicode)
        return termcaps_supports_unicode() ? LISP_TRUE : NIL;
    if (key == sym_tc_describe) {
        const char *d = termcaps_describe();
        return lisp_make_string(d ? d : "");
    }
    if (key == sym_tc_reset) {
        const char *s = termcaps_format_reset();
        return lisp_make_string(s ? s : "");
    }

    /* Color queries with RGB args */
    if (key == sym_tc_fg_color || key == sym_tc_bg_color) {
        if (args == NIL)
            return lisp_make_error("termcap: fg-color/bg-color need r g b");
        LispObject *r_obj = lisp_car(args);
        args = lisp_cdr(args);
        if (args == NIL)
            return lisp_make_error("termcap: fg-color/bg-color need r g b");
        LispObject *g_obj = lisp_car(args);
        args = lisp_cdr(args);
        if (args == NIL)
            return lisp_make_error("termcap: fg-color/bg-color need r g b");
        LispObject *b_obj = lisp_car(args);

        if (LISP_TYPE(r_obj) != LISP_INTEGER ||
            LISP_TYPE(g_obj) != LISP_INTEGER ||
            LISP_TYPE(b_obj) != LISP_INTEGER) {
            return lisp_make_error("termcap: color args must be integers");
        }

        int r = (int)LISP_INT_VAL(r_obj);
        int g = (int)LISP_INT_VAL(g_obj);
        int b = (int)LISP_INT_VAL(b_obj);

        const char *seq = (key == sym_tc_fg_color)
                              ? termcaps_format_fg_color(r, g, b)
                              : termcaps_format_bg_color(r, g, b);
        return lisp_make_string(seq ? seq : "");
    }

    return lisp_make_error("termcap: unknown capability");
}

/* Forward declaration for load_lisp_system_file */
static int load_lisp_system_file(const char *filename, Environment *env);

/* Builtin: load-system-file - Load a Lisp file using standard search paths */
static LispObject *builtin_load_system_file(LispObject *args,
                                            Environment *env)
{
    if (args == NIL) {
        return lisp_make_error("load-system-file requires 1 argument");
    }

    LispObject *filename_obj = lisp_car(args);
    if (LISP_TYPE(filename_obj) != LISP_STRING) {
        return lisp_make_error("load-system-file: argument must be a string");
    }

    const char *filename = LISP_STR_VAL(filename_obj);
    int result = load_lisp_system_file(filename, env);

    if (result) {
        return LISP_TRUE;
    } else {
        return NIL;
    }
}

/* Load a Lisp file from standard search paths into the given environment */
static int load_lisp_system_file(const char *filename, Environment *env)
{
    if (!env || !filename) {
        return 0;
    }

    char *base_path = path_get_exe_directory();
    char exe_relative_path[1024] = { 0 };
    char lisp_subdir_path[256];
    char parent_lisp_path[256];
    char contrib_subdir_path[256];
    char parent_contrib_path[256];
    const char *search_paths[16];
    int path_count = 0;

    /* Try executable-relative path first */
    if (base_path) {
        if (path_construct_exe_relative(base_path, filename, exe_relative_path,
                                        sizeof(exe_relative_path))) {
            search_paths[path_count++] = exe_relative_path;
        }
        free(base_path);
    }

    /* Source tree paths for development */
    snprintf(lisp_subdir_path, sizeof(lisp_subdir_path), "lisp/%s", filename);
    search_paths[path_count++] = lisp_subdir_path;

    snprintf(parent_lisp_path, sizeof(parent_lisp_path), "../lisp/%s", filename);
    search_paths[path_count++] = parent_lisp_path;

    /* Contrib subdirectory */
    snprintf(contrib_subdir_path, sizeof(contrib_subdir_path), "lisp/contrib/%s",
             filename);
    search_paths[path_count++] = contrib_subdir_path;

    snprintf(parent_contrib_path, sizeof(parent_contrib_path),
             "../lisp/contrib/%s", filename);
    search_paths[path_count++] = parent_contrib_path;

    /* Installed paths */
    static char installed_path[TELNET_MAX_PATH];
    if (path_construct_installed_resource("lisp", filename, installed_path,
                                          sizeof(installed_path))) {
        search_paths[path_count++] = installed_path;
    }

    static char installed_contrib_path[TELNET_MAX_PATH];
    if (path_construct_installed_resource("lisp/contrib", filename,
                                          installed_contrib_path,
                                          sizeof(installed_contrib_path))) {
        search_paths[path_count++] = installed_contrib_path;
    }

    search_paths[path_count] = NULL;

    for (int i = 0; search_paths[i] != NULL; i++) {
        FILE *test = file_open(search_paths[i], "rb");
        if (test) {
            fclose(test);
            LispObject *result = lisp_load_file(search_paths[i], env);
            if (result && LISP_TYPE(result) == LISP_ERROR) {
                char *err_str = lisp_print(result);
                mudlark_log(LOG_ERROR, "lisp", "Error loading %s: %s", search_paths[i],
                            err_str);
            } else {
                mudlark_log(LOG_INFO, "lisp", "Loaded: %s", search_paths[i]);
                return 1;
            }
        }
    }

    mudlark_log(LOG_ERROR, "lisp", "Failed to load Lisp file: %s", filename);
    return 0;
}

/* Interned log level symbols for pointer comparison */
static LispObject *sym_log_debug = NULL;
static LispObject *sym_log_info = NULL;
static LispObject *sym_log_warn = NULL;
static LispObject *sym_log_error = NULL;

/* Builtin: mudlark-log - Log a message with level and tag */
static LispObject *builtin_mudlark_log(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL)
        return lisp_make_error("mudlark-log requires 3 arguments: level tag message");

    LispObject *level_obj = lisp_car(args);
    args = lisp_cdr(args);
    if (args == NIL)
        return lisp_make_error("mudlark-log requires 3 arguments: level tag message");

    LispObject *tag_obj = lisp_car(args);
    args = lisp_cdr(args);
    if (args == NIL)
        return lisp_make_error("mudlark-log requires 3 arguments: level tag message");

    LispObject *msg_obj = lisp_car(args);

    if (LISP_TYPE(level_obj) != LISP_SYMBOL)
        return lisp_make_error("mudlark-log: level must be a symbol");
    if (LISP_TYPE(tag_obj) != LISP_STRING)
        return lisp_make_error("mudlark-log: tag must be a string");
    if (LISP_TYPE(msg_obj) != LISP_STRING)
        return lisp_make_error("mudlark-log: message must be a string");

    LogLevel level;
    if (level_obj == sym_log_debug)
        level = LOG_DEBUG;
    else if (level_obj == sym_log_info)
        level = LOG_INFO;
    else if (level_obj == sym_log_warn)
        level = LOG_WARN;
    else if (level_obj == sym_log_error)
        level = LOG_ERROR;
    else
        return lisp_make_error(
            "mudlark-log: level must be 'debug, 'info, 'warn, or 'error");

    mudlark_log(level, LISP_STR_VAL(tag_obj), "%s", LISP_STR_VAL(msg_obj));
    return NIL;
}

/* Builtin: set-log-filter - Set log filter at runtime */
static LispObject *builtin_set_log_filter(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL)
        return lisp_make_error("set-log-filter requires 1 argument");

    LispObject *spec_obj = lisp_car(args);
    if (LISP_TYPE(spec_obj) != LISP_STRING)
        return lisp_make_error("set-log-filter: argument must be a string");

    mudlark_log_set_filter(LISP_STR_VAL(spec_obj));
    return NIL;
}

/* Builtin: set-status - Set the right-aligned status string embedded in
 * the top divider above the textinput. (set-status) or (set-status "")
 * clears it. */
static LispObject *builtin_set_status(LispObject *args, Environment *env)
{
    (void)env;

    if (!registered_status_sink) {
        return NIL;
    }

    if (args == NIL) {
        telnet_app_set_status_text(registered_status_sink, NULL);
        return NIL;
    }

    LispObject *text_obj = lisp_car(args);
    if (text_obj == NIL) {
        telnet_app_set_status_text(registered_status_sink, NULL);
        return NIL;
    }
    if (LISP_TYPE(text_obj) != LISP_STRING) {
        return lisp_make_error("set-status: argument must be a string or nil");
    }

    telnet_app_set_status_text(registered_status_sink, LISP_STR_VAL(text_obj));
    return NIL;
}

/* ========================================================================
 * Session management Lisp builtins
 * ======================================================================== */

/* Builtin: (telnet-session-create "name") -> session id */
static LispObject *builtin_session_create(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL) {
        return lisp_make_error("telnet-session-create requires 1 argument");
    }

    LispObject *name_obj = lisp_car(args);
    if (LISP_TYPE(name_obj) != LISP_STRING) {
        return lisp_make_error("telnet-session-create: argument must be a string");
    }

    Session *s = session_create(LISP_STR_VAL(name_obj));
    if (!s) {
        return lisp_make_error("telnet-session-create: failed to create session");
    }

    /* Populate session's hooks table from defaults */
    apply_default_hooks_to_table(s->hooks);

    /* Echo creation message to terminal */
    char msg[256];
    snprintf(msg, sizeof(msg), "Created session %d: \"%s\"\r\n", s->id, s->name);
    if (echo_callback) {
        echo_callback(msg, strlen(msg));
    }

    return lisp_make_integer(s->id);
}

/* Builtin: (telnet-session-list) -> list of (id . "name") pairs */
static LispObject *builtin_session_list(LispObject *args, Environment *env)
{
    (void)args;
    (void)env;

    int count = 0;
    Session **all = session_get_all(&count);

    LispObject *result = NIL;
    /* Build list in reverse so order is preserved */
    for (int i = count - 1; i >= 0; i--) {
        if (all[i]) {
            LispObject *pair = lisp_make_cons(lisp_make_integer(all[i]->id),
                                              lisp_make_string(all[i]->name));
            result = lisp_make_cons(pair, result);
        }
    }

    return result;
}

/* Builtin: (telnet-session-current) -> current session id */
static LispObject *builtin_session_current(LispObject *args, Environment *env)
{
    (void)args;
    (void)env;

    Session *s = session_get_current();
    if (!s) {
        return NIL;
    }
    return lisp_make_integer(s->id);
}

/* Builtin: (telnet-session-switch id) -> t or error */
static LispObject *builtin_session_switch(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL) {
        return lisp_make_error("telnet-session-switch requires 1 argument");
    }

    LispObject *id_obj = lisp_car(args);
    if (LISP_TYPE(id_obj) != LISP_INTEGER) {
        return lisp_make_error(
            "telnet-session-switch: argument must be an integer");
    }

    int id = (int)LISP_INT_VAL(id_obj);
    Session *s = session_find_by_id(id);
    if (!s) {
        return lisp_make_error("telnet-session-switch: no session with that id");
    }

    session_set_current(s);
    update_terminal_title();
    return LISP_TRUE;
}

/* Builtin: (telnet-session-name) or (telnet-session-name id) -> name string */
static LispObject *builtin_session_name(LispObject *args, Environment *env)
{
    (void)env;

    Session *s;
    if (args == NIL) {
        s = session_get_current();
    } else {
        LispObject *id_obj = lisp_car(args);
        if (LISP_TYPE(id_obj) != LISP_INTEGER) {
            return lisp_make_error(
                "telnet-session-name: argument must be an integer");
        }
        s = session_find_by_id((int)LISP_INT_VAL(id_obj));
    }

    if (!s) {
        return NIL;
    }
    return lisp_make_string(s->name);
}

/* Builtin: (telnet-session-destroy id) -> t or error */
static LispObject *builtin_session_destroy(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL) {
        return lisp_make_error("telnet-session-destroy requires 1 argument");
    }

    LispObject *id_obj = lisp_car(args);
    if (LISP_TYPE(id_obj) != LISP_INTEGER) {
        return lisp_make_error(
            "telnet-session-destroy: argument must be an integer");
    }

    int id = (int)LISP_INT_VAL(id_obj);

    /* Capture name before destroy removes the session */
    Session *target = session_find_by_id(id);
    const char *name = target ? target->name : "unknown";
    char msg[256];
    snprintf(msg, sizeof(msg), "Destroyed session %d: \"%s\"\r\n", id, name);

    int result = session_destroy(id);
    if (result < 0) {
        return lisp_make_error(
            "telnet-session-destroy: failed (not found or current session)");
    }

    if (echo_callback) {
        echo_callback(msg, strlen(msg));
    }

    return LISP_TRUE;
}

/* ========================================================================
 * Hook system Lisp builtins
 * ======================================================================== */

/* Builtin: (add-hook 'hook-name fn) or (add-hook 'hook-name fn priority) */
static LispObject *builtin_add_hook(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL) {
        return lisp_make_error("add-hook requires at least 2 arguments");
    }

    LispObject *name_obj = lisp_car(args);
    args = lisp_cdr(args);
    if (args == NIL) {
        return lisp_make_error("add-hook requires at least 2 arguments");
    }

    LispObject *fn_obj = lisp_car(args);
    args = lisp_cdr(args);

    if (LISP_TYPE(name_obj) != LISP_SYMBOL) {
        return lisp_make_error("add-hook: first argument must be a symbol");
    }
    if (LISP_TYPE(fn_obj) != LISP_SYMBOL) {
        return lisp_make_error("add-hook: second argument must be a symbol");
    }

    int priority = 50;
    if (args != NIL) {
        LispObject *prio_obj = lisp_car(args);
        if (LISP_TYPE(prio_obj) != LISP_INTEGER) {
            return lisp_make_error("add-hook: priority must be an integer");
        }
        priority = (int)LISP_INT_VAL(prio_obj);
    }

    LispObject *hooks_table = get_session_hooks();
    if (!hooks_table) {
        /* No session yet (e.g. during init.lisp loading) — prepend to
         * *default-hooks* in base_env as (name-string fn . priority) */
        Environment *base = session_get_base_env();
        if (!base) {
            return lisp_make_error("add-hook: no base environment");
        }
        Symbol *default_hooks_sym = LISP_SYM_VAL(lisp_intern("*default-hooks*"));
        LispObject *defaults = env_lookup(base, default_hooks_sym);
        if (!defaults) {
            defaults = NIL;
        }
        LispObject *name_str = lisp_make_string(LISP_SYM_VAL(name_obj)->name);
        LispObject *fn_and_prio =
            lisp_make_cons(fn_obj, lisp_make_integer(priority));
        LispObject *triple = lisp_make_cons(name_str, fn_and_prio);
        defaults = lisp_make_cons(triple, defaults);
        env_set(base, default_hooks_sym, defaults);
        return NIL;
    }

    struct HashEntry *he = hash_table_get_entry(hooks_table, name_obj);
    LispObject *hook_list = (he && he->value) ? he->value : NIL;

    if (hooks_has_fn(hook_list, fn_obj)) {
        return NIL; /* Already registered */
    }

    hook_list = hooks_insert_sorted(fn_obj, priority, hook_list);
    hash_table_set_entry(hooks_table, name_obj, hook_list);
    return NIL;
}

/* Builtin: (remove-hook 'hook-name fn) */
static LispObject *builtin_remove_hook(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL) {
        return lisp_make_error("remove-hook requires 2 arguments");
    }

    LispObject *name_obj = lisp_car(args);
    args = lisp_cdr(args);
    if (args == NIL) {
        return lisp_make_error("remove-hook requires 2 arguments");
    }

    LispObject *fn_obj = lisp_car(args);

    if (LISP_TYPE(name_obj) != LISP_SYMBOL) {
        return lisp_make_error("remove-hook: first argument must be a symbol");
    }
    if (LISP_TYPE(fn_obj) != LISP_SYMBOL) {
        return lisp_make_error("remove-hook: second argument must be a symbol");
    }

    LispObject *hooks_table = get_session_hooks();
    if (!hooks_table) {
        return lisp_make_error("remove-hook: no current session");
    }

    struct HashEntry *he = hash_table_get_entry(hooks_table, name_obj);
    if (!he || !he->value || he->value == NIL) {
        return NIL;
    }

    LispObject *new_list = hooks_remove_fn(he->value, fn_obj);
    hash_table_set_entry(hooks_table, name_obj, new_list);
    return NIL;
}

/* Builtin: (clear-hook 'hook-name) — remove all handlers from a hook */
static LispObject *builtin_clear_hook(LispObject *args, Environment *env)
{
    (void)env;

    if (args == NIL) {
        return lisp_make_error("clear-hook requires 1 argument");
    }

    LispObject *name_obj = lisp_car(args);
    if (LISP_TYPE(name_obj) != LISP_SYMBOL) {
        return lisp_make_error("clear-hook: argument must be a symbol");
    }

    LispObject *hooks_table = get_session_hooks();
    if (!hooks_table) {
        return lisp_make_error("clear-hook: no current session");
    }

    hash_table_set_entry(hooks_table, name_obj, NIL);
    return NIL;
}

/* Builtin: (run-hook 'hook-name &rest args) */
static LispObject *builtin_run_hook(LispObject *args, Environment *env)
{
    if (args == NIL) {
        return lisp_make_error("run-hook requires at least 1 argument");
    }

    LispObject *name_obj = lisp_car(args);
    LispObject *hook_args = lisp_cdr(args);

    if (LISP_TYPE(name_obj) != LISP_SYMBOL) {
        return lisp_make_error("run-hook: first argument must be a symbol");
    }

    LispObject *hooks_table = get_session_hooks();
    if (!hooks_table) {
        return NIL;
    }

    const char *name = LISP_SYM_VAL(name_obj)->name;
    struct HashEntry *he = hash_table_get_entry(hooks_table, name_obj);
    if (!he || !he->value || he->value == NIL) {
        return NIL;
    }

    LispObject *hook_list = he->value;
    while (hook_list != NIL && LISP_TYPE(hook_list) == LISP_CONS) {
        LispObject *entry = lisp_car(hook_list);
        LispObject *fn_sym = lisp_car(entry);

        /* Resolve symbol to its current function value */
        LispObject *fn = NULL;
        if (fn_sym && LISP_TYPE(fn_sym) == LISP_SYMBOL) {
            fn = env_lookup(env, LISP_SYM_VAL(fn_sym));
        }
        if (!fn || !lisp_is_callable(fn)) {
            mudlark_log(LOG_ERROR, "hooks",
                        "run-hook %s: handler '%s' is not callable", name,
                        (fn_sym && LISP_TYPE(fn_sym) == LISP_SYMBOL)
                            ? LISP_SYM_VAL(fn_sym)->name
                            : "?");
            hook_list = lisp_cdr(hook_list);
            continue;
        }

        /* Build call: (fn arg1 arg2 ...) */
        LispObject *call = lisp_make_cons(fn, hook_args);
        LispObject *result = lisp_eval(call, env);
        if (result && LISP_TYPE(result) == LISP_ERROR) {
            char *err_str = lisp_print(result);
            if (err_str) {
                mudlark_log(LOG_ERROR, "hooks", "run-hook %s: %s", name, err_str);
            }
        }

        hook_list = lisp_cdr(hook_list);
    }

    return NIL;
}

/* Builtin: (run-filter-hook 'hook-name value)
 * Calls every handler with the original value (not chained).
 * Returns nil if any handler returned nil, otherwise the original value.
 * All handlers are always called (no short-circuit). */
static LispObject *builtin_run_filter_hook(LispObject *args, Environment *env)
{
    if (args == NIL) {
        return lisp_make_error("run-filter-hook requires 2 arguments");
    }

    LispObject *name_obj = lisp_car(args);
    args = lisp_cdr(args);
    if (args == NIL) {
        return lisp_make_error("run-filter-hook requires 2 arguments");
    }

    LispObject *value = lisp_car(args);

    if (LISP_TYPE(name_obj) != LISP_SYMBOL) {
        return lisp_make_error("run-filter-hook: first argument must be a symbol");
    }

    LispObject *hooks_table = get_session_hooks();
    if (!hooks_table) {
        return value;
    }

    const char *name = LISP_SYM_VAL(name_obj)->name;
    struct HashEntry *he = hash_table_get_entry(hooks_table, name_obj);
    if (!he || !he->value || he->value == NIL) {
        return value;
    }

    int consumed = 0;
    LispObject *hook_list = he->value;
    while (hook_list != NIL && LISP_TYPE(hook_list) == LISP_CONS) {
        LispObject *entry = lisp_car(hook_list);
        LispObject *fn_sym = lisp_car(entry);

        /* Resolve symbol to its current function value */
        LispObject *fn = NULL;
        if (fn_sym && LISP_TYPE(fn_sym) == LISP_SYMBOL) {
            fn = env_lookup(env, LISP_SYM_VAL(fn_sym));
        }
        if (!fn || !lisp_is_callable(fn)) {
            mudlark_log(LOG_ERROR, "hooks",
                        "run-filter-hook %s: handler '%s' is not callable", name,
                        (fn_sym && LISP_TYPE(fn_sym) == LISP_SYMBOL)
                            ? LISP_SYM_VAL(fn_sym)->name
                            : "?");
            hook_list = lisp_cdr(hook_list);
            continue;
        }

        /* Call handler with the original value (not chained) */
        LispObject *call_args = lisp_make_cons(value, NIL);
        LispObject *call = lisp_make_cons(fn, call_args);
        LispObject *result = lisp_eval(call, env);
        if (result && LISP_TYPE(result) == LISP_ERROR) {
            char *err_str = lisp_print(result);
            if (err_str) {
                mudlark_log(LOG_ERROR, "hooks", "run-filter-hook %s: %s", name, err_str);
            }
        } else if (!result || result == NIL) {
            consumed = 1;
        }

        hook_list = lisp_cdr(hook_list);
    }

    return consumed ? NIL : value;
}

/* Builtin: (run-transform-hook 'hook-name initial-value) */
static LispObject *builtin_run_transform_hook(LispObject *args,
                                              Environment *env)
{
    if (args == NIL) {
        return lisp_make_error("run-transform-hook requires 2 arguments");
    }

    LispObject *name_obj = lisp_car(args);
    args = lisp_cdr(args);
    if (args == NIL) {
        return lisp_make_error("run-transform-hook requires 2 arguments");
    }

    LispObject *value = lisp_car(args);

    if (LISP_TYPE(name_obj) != LISP_SYMBOL) {
        return lisp_make_error(
            "run-transform-hook: first argument must be a symbol");
    }

    LispObject *hooks_table = get_session_hooks();
    if (!hooks_table) {
        return value;
    }

    const char *name = LISP_SYM_VAL(name_obj)->name;
    struct HashEntry *he = hash_table_get_entry(hooks_table, name_obj);
    if (!he || !he->value || he->value == NIL) {
        return value;
    }

    LispObject *hook_list = he->value;
    while (hook_list != NIL && LISP_TYPE(hook_list) == LISP_CONS) {
        LispObject *entry = lisp_car(hook_list);
        LispObject *fn_sym = lisp_car(entry);

        /* Resolve symbol to its current function value */
        LispObject *fn = NULL;
        if (fn_sym && LISP_TYPE(fn_sym) == LISP_SYMBOL) {
            fn = env_lookup(env, LISP_SYM_VAL(fn_sym));
        }
        if (!fn || !lisp_is_callable(fn)) {
            mudlark_log(LOG_ERROR, "hooks",
                        "run-transform-hook %s: handler '%s' is not callable", name,
                        (fn_sym && LISP_TYPE(fn_sym) == LISP_SYMBOL)
                            ? LISP_SYM_VAL(fn_sym)->name
                            : "?");
            hook_list = lisp_cdr(hook_list);
            continue;
        }

        if (value != NIL && LISP_TYPE(value) == LISP_CONS) {
            /* List value: call handler once per element, collect results */
            LispObject *result_head = NIL;
            LispObject **result_tail = &result_head;
            LispObject *elem = value;
            while (elem != NIL && LISP_TYPE(elem) == LISP_CONS) {
                LispObject *item = lisp_car(elem);
                LispObject *call_args = lisp_make_cons(item, NIL);
                LispObject *call = lisp_make_cons(fn, call_args);
                LispObject *result = lisp_eval(call, env);
                if (result && LISP_TYPE(result) == LISP_ERROR) {
                    char *err_str = lisp_print(result);
                    if (err_str) {
                        mudlark_log(LOG_ERROR, "hooks", "run-transform-hook %s: %s", name,
                                    err_str);
                    }
                    /* On error, keep original element */
                    *result_tail = lisp_make_cons(item, NIL);
                    result_tail = &LISP_CDR(*result_tail);
                } else if (result != NIL) {
                    if (LISP_TYPE(result) == LISP_CONS) {
                        /* Handler returned a list — splice elements in */
                        LispObject *sub = result;
                        while (sub != NIL && LISP_TYPE(sub) == LISP_CONS) {
                            LispObject *sub_item = lisp_car(sub);
                            if (sub_item != NIL) {
                                *result_tail = lisp_make_cons(sub_item, NIL);
                                result_tail = &LISP_CDR(*result_tail);
                            }
                            sub = lisp_cdr(sub);
                        }
                    } else {
                        *result_tail = lisp_make_cons(result, NIL);
                        result_tail = &LISP_CDR(*result_tail);
                    }
                }
                /* nil results are filtered out */
                elem = lisp_cdr(elem);
            }
            value = result_head;
        } else {
            /* Scalar value: call handler normally */
            LispObject *call_args = lisp_make_cons(value, NIL);
            LispObject *call = lisp_make_cons(fn, call_args);
            LispObject *result = lisp_eval(call, env);
            if (result && LISP_TYPE(result) == LISP_ERROR) {
                char *err_str = lisp_print(result);
                if (err_str) {
                    mudlark_log(LOG_ERROR, "hooks", "run-transform-hook %s: %s", name,
                                err_str);
                }
                /* On error, keep previous value */
            } else {
                value = result;
            }
        }

        hook_list = lisp_cdr(hook_list);
    }

    return value;
}

/* Helper: register a builtin using interned symbol */
#define REG(name, func)                              \
    env_define(env, LISP_SYM_VAL(lisp_intern(name)), \
               lisp_make_builtin(func, name), pkg_core)

/* Send a hook result (string or list of strings) to telnet */
void lisp_x_send_hook_result(LispObject *result, Telnet *telnet)
{
    if (!result || result == NIL || !telnet)
        return;

    if (LISP_TYPE(result) == LISP_STRING) {
        const char *s = LISP_STR_VAL(result);
        telnet_send_with_crlf(telnet, s, strlen(s));
    } else if (LISP_TYPE(result) == LISP_CONS) {
        LispObject *elem = result;
        while (elem != NIL && LISP_TYPE(elem) == LISP_CONS) {
            LispObject *item = lisp_car(elem);
            if (item && LISP_TYPE(item) == LISP_STRING) {
                const char *s = LISP_STR_VAL(item);
                telnet_send_with_crlf(telnet, s, strlen(s));
            }
            elem = lisp_cdr(elem);
        }
    }
}

/* Callback for telnet-send: flush all pending raw sends */
static TuiMsg flush_pending_sends(void *data)
{
    (void)data;
    Session *s = session_get_current();
    if (s && s->telnet) {
        const char *p = dynamic_buffer_data(pending_send_buf);
        const char *end = p + dynamic_buffer_len(pending_send_buf);
        while (p < end) {
            size_t len = strlen(p);
            telnet_send_with_crlf(s->telnet, p, len);
            p += len + 1;
        }
    }
    dynamic_buffer_clear(pending_send_buf);
    pending_send_scheduled = 0;
    return tui_msg_none();
}

/* Callback for send-input: process text through user-input-transform-hook and
 * send */
static TuiMsg send_input_callback(void *data)
{
    char *text = (char *)data;
    Session *s = session_get_current();
    if (s && s->telnet) {
        if (!lisp_x_call_user_input_hook(text, strlen(text))) {
            LispObject *result = lisp_x_call_user_input_transform_hook(text);
            lisp_x_send_hook_result(result, s->telnet);
        }
    }
    return tui_msg_none();
}

/* Builtin: send-input - Queue text for processing through the input pipeline.
 * Async: returns immediately, event loop processes on next iteration.
 * Does NOT affect text input history or state. */
static LispObject *builtin_send_input(LispObject *args, Environment *env)
{
    (void)env;
    if (args == NIL)
        return lisp_make_error("send-input requires a string argument");
    LispObject *text_obj = lisp_car(args);
    if (!text_obj || LISP_TYPE(text_obj) != LISP_STRING)
        return lisp_make_error("send-input: argument must be a string");
    if (!registered_runtime)
        return lisp_make_error("send-input: no runtime registered");

    char *text = strdup(LISP_STR_VAL(text_obj));
    if (!text)
        return lisp_make_error("send-input: out of memory");

    tui_runtime_schedule(registered_runtime,
                         tui_cmd_custom(send_input_callback, text, free));
    return NIL;
}

/* Builtin: wake-event-loop - Wake the event loop so it recomputes timeout */
static LispObject *builtin_wake_event_loop(LispObject *args, Environment *env)
{
    (void)args;
    (void)env;

    if (registered_runtime)
        tui_runtime_wakeup(registered_runtime);

    return NIL;
}

/* Builtin: (register-cli-handler short-flag long-flag handler-fn)
 * Registers a Lisp function to handle a CLI flag.
 * short-flag: single char string (e.g., "t") or nil
 * long-flag: long name string (e.g., "tintin")
 * handler-fn: symbol naming the handler function */
static LispObject *builtin_register_cli_handler(LispObject *args,
                                                Environment *env)
{
    (void)env;
    if (!cli_handler_table) {
        cli_handler_table = lisp_make_hash_table();
    }

    /* Parse args: (short long handler) */
    LispObject *short_arg = lisp_car(args);
    LispObject *long_arg = lisp_car(lisp_cdr(args));
    LispObject *handler = lisp_car(lisp_cdr(lisp_cdr(args)));

    if (!handler || LISP_TYPE(handler) != LISP_SYMBOL) {
        return lisp_make_error("register-cli-handler: handler must be a symbol");
    }

    /* Register long flag */
    if (long_arg && LISP_TYPE(long_arg) == LISP_STRING) {
        hash_table_set_entry(cli_handler_table, long_arg, handler);
    }

    /* Register short flag */
    if (short_arg && LISP_TYPE(short_arg) == LISP_STRING) {
        hash_table_set_entry(cli_handler_table, short_arg, handler);
    }

    return NIL;
}

/* Store a CLI argument for later dispatch to Lisp handlers */
void lisp_x_add_cli_arg(const char *flag, const char *value)
{
    if (cli_pending_count >= cli_pending_capacity) {
        cli_pending_capacity = cli_pending_capacity ? cli_pending_capacity * 2 : 8;
        cli_pending_args =
            realloc(cli_pending_args, cli_pending_capacity * sizeof(CliArg));
    }
    CliArg *arg = &cli_pending_args[cli_pending_count++];
    snprintf(arg->flag, sizeof(arg->flag), "%s", flag);
    snprintf(arg->value, sizeof(arg->value), "%s", value);
}

/* Dispatch collected CLI args to registered Lisp handlers */
int lisp_x_dispatch_cli_args(void)
{
    Environment *env = get_current_env();
    if (!env || !cli_pending_args || cli_pending_count == 0)
        return 0;

    int errors = 0;
    for (int i = 0; i < cli_pending_count; i++) {
        CliArg *arg = &cli_pending_args[i];

        /* Look up handler in registry */
        LispObject *handler_sym = NULL;
        if (cli_handler_table) {
            LispObject *key = lisp_make_string(arg->flag);
            struct HashEntry *he = hash_table_get_entry(cli_handler_table, key);
            if (he)
                handler_sym = he->value;
        }

        if (!handler_sym || handler_sym == NIL) {
            mudlark_log(LOG_ERROR, "cli", "Unknown flag: --%s", arg->flag);
            if (echo_callback) {
                char buf[256];
                snprintf(buf, sizeof(buf), "Unknown flag: --%s\r\n", arg->flag);
                echo_callback(buf, strlen(buf));
            }
            errors++;
            continue;
        }

        /* Resolve symbol to function and call directly */
        LispObject *handler_fn = env_lookup(env, LISP_SYM_VAL(handler_sym));
        if (!handler_fn || !lisp_is_callable(handler_fn)) {
            mudlark_log(LOG_ERROR, "cli", "CLI handler for --%s is not callable",
                        arg->flag);
            errors++;
            continue;
        }

        LispObject *value_arg = lisp_make_string(arg->value);
        volatile LispObject *result = lisp_call_1(handler_fn, value_arg, env);
        if (result && LISP_TYPE((LispObject *)result) == LISP_ERROR) {
            char *err = lisp_print((LispObject *)result);
            mudlark_log(LOG_ERROR, "cli", "Error handling --%s: %s", arg->flag, err);
            errors++;
        }
    }

    /* Free pending args */
    free(cli_pending_args);
    cli_pending_args = NULL;
    cli_pending_count = 0;
    cli_pending_capacity = 0;

    return errors;
}

/* Register all builtins on the given environment */
static void register_builtins(Environment *env)
{
    REG("strip-ansi", builtin_strip_ansi);
    REG("terminal-echo", builtin_terminal_echo);
    REG("telnet-send", builtin_telnet_send);
    REG("send-input", builtin_send_input);
    REG("wake-event-loop", builtin_wake_event_loop);

    /* Terminal capability builtin */
    lisp_set_docstring(
        "termcap",
        "Query terminal capabilities.\n"
        "\n"
        "Usage:\n"
        "- `(termcap 'cols)` - terminal width\n"
        "- `(termcap 'rows)` - terminal height\n"
        "- `(termcap 'type)` - terminal type string (e.g. \"xterm-256color\")\n"
        "- `(termcap 'encoding)` - character encoding (e.g. \"UTF-8\")\n"
        "- `(termcap 'color-level)` - color support level (0-3)\n"
        "- `(termcap 'truecolor?)` - t if truecolor is supported\n"
        "- `(termcap '256color?)` - t if 256 colors supported\n"
        "- `(termcap 'unicode?)` - t if unicode is supported\n"
        "- `(termcap 'describe)` - human-readable capability summary\n"
        "- `(termcap 'reset)` - SGR reset escape sequence\n"
        "- `(termcap 'fg-color r g b)` - foreground color escape sequence\n"
        "- `(termcap 'bg-color r g b)` - background color escape sequence");
    REG("termcap", builtin_termcap);

    /* System file loader (uses standard search paths) */
    REG("load-system-file", builtin_load_system_file);

    /* Intern termcap symbols for pointer comparison */
    sym_tc_cols = lisp_intern("cols");
    sym_tc_rows = lisp_intern("rows");
    sym_tc_type = lisp_intern("type");
    sym_tc_encoding = lisp_intern("encoding");
    sym_tc_color_level = lisp_intern("color-level");
    sym_tc_truecolor = lisp_intern("truecolor?");
    sym_tc_256color = lisp_intern("256color?");
    sym_tc_unicode = lisp_intern("unicode?");
    sym_tc_describe = lisp_intern("describe");
    sym_tc_reset = lisp_intern("reset");
    sym_tc_fg_color = lisp_intern("fg-color");
    sym_tc_bg_color = lisp_intern("bg-color");

    /* Intern log level symbols for pointer comparison in mudlark-log */
    sym_log_debug = lisp_intern("debug");
    sym_log_info = lisp_intern("info");
    sym_log_warn = lisp_intern("warn");
    sym_log_error = lisp_intern("error");

    /* Logging builtins */
    REG("mudlark-log", builtin_mudlark_log);
    REG("set-log-filter", builtin_set_log_filter);

    /* Status text — raw sink for the right-aligned title rendered into
     * the top divider above the textinput. The mode registry in Lisp
     * (status-mode-set / status-mode-remove) composes entries and calls
     * this. */
    lisp_set_docstring("set-status",
                       "Set the right-aligned status string in the top divider.\n"
                       "\n"
                       "Usage: (set-status \"text\")\n"
                       "       (set-status)        ; clear\n"
                       "       (set-status nil)    ; clear\n"
                       "\n"
                       "Raw API. Use status-mode-set / status-mode-remove for\n"
                       "the higher-level mode registry.");
    REG("set-status", builtin_set_status);

    /* Session management builtins */
    REG("telnet-session-create", builtin_session_create);
    REG("telnet-session-list", builtin_session_list);
    REG("telnet-session-current", builtin_session_current);
    REG("telnet-session-switch", builtin_session_switch);
    REG("telnet-session-name", builtin_session_name);
    REG("telnet-session-destroy", builtin_session_destroy);

    /* Hook system builtins */
    REG("add-hook", builtin_add_hook);
    REG("remove-hook", builtin_remove_hook);
    REG("clear-hook", builtin_clear_hook);
    REG("run-hook", builtin_run_hook);
    REG("run-filter-hook", builtin_run_filter_hook);
    REG("run-transform-hook", builtin_run_transform_hook);

    /* CLI argument handler registration */
    REG("register-cli-handler", builtin_register_cli_handler);
}

#undef REG

/* Initialize Lisp interpreter and environment */
int lisp_x_init(void)
{
    Environment *base_env = lisp_init();
    if (!base_env) {
        mudlark_log(LOG_ERROR, "lisp", "Failed to initialize Lisp interpreter");
        return -1;
    }

    /* Initialize session manager with base environment */
    if (session_manager_init(base_env) < 0) {
        mudlark_log(LOG_ERROR, "lisp", "Failed to initialize session manager");
        lisp_cleanup();
        return -1;
    }

    /* Allocate reusable scratch buffers */
    ansi_strip_buf = dynamic_buffer_create(4096);
    telnet_filter_buf = dynamic_buffer_create(4096);
    telnet_filter_temp_buf = dynamic_buffer_create(4096);
    pending_send_buf = dynamic_buffer_create(256);

    if (!ansi_strip_buf || !telnet_filter_buf || !telnet_filter_temp_buf ||
        !pending_send_buf) {
        mudlark_log(LOG_ERROR, "lisp", "Failed to allocate buffers");
        lisp_x_cleanup();
        return -1;
    }

    /* Register all builtins on the base environment */
    register_builtins(base_env);

    /* Version string accessible from Lisp */
    env_define(base_env, LISP_SYM_VAL(lisp_intern("*version*")),
               lisp_make_string(MUDLARK_VERSION), pkg_core);

    /* Initialize *default-hooks* in base env (collects hooks registered
     * during init.lisp before any session exists) */
    env_define(base_env, LISP_SYM_VAL(lisp_intern("*default-hooks*")), NIL,
               pkg_core);

    /* Default session is created later in lisp_x_load_init() once the
     * TUI is ready, so echo_callback can display the creation message */

    return 0;
}

/* Derive package name from filepath: strip directory and .lisp extension */
static const char *derive_package_name(const char *filepath, char *buf,
                                       size_t bufsize)
{
    const char *base = strrchr(filepath, '/');
    base = base ? base + 1 : filepath;

    const char *dot = strrchr(base, '.');
    size_t len = dot ? (size_t)(dot - base) : strlen(base);
    if (len >= bufsize)
        len = bufsize - 1;

    memcpy(buf, base, len);
    buf[len] = '\0';
    return buf;
}

/* Load additional Lisp file into the current session environment */
int lisp_x_load_file(const char *filepath)
{
    Environment *env = get_current_env();
    if (!env || !filepath) {
        return -1;
    }

    /* Auto-append .lisp extension if not present */
    char normalized[512];
    const char *effective_path = filepath;
    size_t flen = strlen(filepath);
    if (flen < 5 || strcmp(filepath + flen - 5, ".lisp") != 0) {
        snprintf(normalized, sizeof(normalized), "%s.lisp", filepath);
        effective_path = normalized;
    }

    /* Derive package name from filename and set *package* */
    char pkg_name[256];
    derive_package_name(effective_path, pkg_name, sizeof(pkg_name));
    LispObject *saved_pkg = env_lookup(env, LISP_SYM_VAL(sym_star_package_star));
    env_set(env, LISP_SYM_VAL(sym_star_package_star), lisp_intern(pkg_name));

    int ret;

    /* If path is absolute, load directly */
    if (path_is_absolute(effective_path)) {
        LispObject *result = lisp_load_file(effective_path, env);
        if (result && LISP_TYPE(result) == LISP_ERROR) {
            char *err_str = lisp_print(result);
            mudlark_log(LOG_ERROR, "lisp", "Error loading %s: %s", filepath, err_str);
            ret = -1;
        } else {
            ret = 0;
        }
    } else {
        /* Try standard search paths */
        ret = load_lisp_system_file(effective_path, env) ? 0 : -1;
    }

    /* Restore *package* */
    if (saved_pkg) {
        env_set(env, LISP_SYM_VAL(sym_star_package_star), saved_pkg);
    }

    return ret;
}

/* Cleanup Lisp interpreter */
void lisp_x_cleanup(void)
{
    if (ansi_strip_buf) {
        dynamic_buffer_destroy(ansi_strip_buf);
        ansi_strip_buf = NULL;
    }

    if (telnet_filter_buf) {
        dynamic_buffer_destroy(telnet_filter_buf);
        telnet_filter_buf = NULL;
    }

    if (telnet_filter_temp_buf) {
        dynamic_buffer_destroy(telnet_filter_temp_buf);
        telnet_filter_temp_buf = NULL;
    }

    if (pending_send_buf) {
        dynamic_buffer_destroy(pending_send_buf);
        pending_send_buf = NULL;
        pending_send_scheduled = 0;
    }

    if (completion_arena) {
        dynamic_buffer_destroy(completion_arena);
        completion_arena = NULL;
    }
    free(completion_ptrs);
    completion_ptrs = NULL;
    completion_ptrs_cap = 0;

    registered_status_sink = NULL;
    registered_runtime = NULL;

    /* Cleanup all sessions and base environment */
    session_manager_cleanup();

    lisp_cleanup();
}

/* Call telnet-input-hook with stripped ANSI text */
void lisp_x_call_telnet_input_hook(const char *text, size_t len)
{
    Environment *env = get_current_env();
    if (!env || !text || len == 0) {
        return;
    }

    size_t stripped_len = 0;
    char *stripped_text = strip_ansi_codes(text, len, &stripped_len);
    if (!stripped_text || stripped_len == 0) {
        mudlark_log(LOG_DEBUG, "hooks",
                    "input-hook: stripped text empty (raw len=%zu)", len);
        return;
    }

    LispObject *hook =
        env_lookup(env, LISP_SYM_VAL(lisp_intern("telnet-input-hook")));
    if (!lisp_is_callable(hook)) {
        mudlark_log(LOG_DEBUG, "hooks", "input-hook: hook not found or wrong type");
        return;
    }

    mudlark_log(LOG_DEBUG, "hooks", "input-hook: calling with %zu bytes",
                stripped_len);

    volatile LispObject *text_arg = lisp_make_string(stripped_text);
    if (!text_arg || LISP_TYPE((LispObject *)text_arg) == LISP_ERROR) {
        mudlark_log(LOG_DEBUG, "hooks", "input-hook: failed to create string arg");
        return;
    }

    volatile LispObject *args = lisp_make_cons((LispObject *)text_arg, NIL);
    volatile LispObject *call_expr = lisp_make_cons(hook, (LispObject *)args);
    LispObject *result = lisp_eval((LispObject *)call_expr, env);

    if (result && LISP_TYPE(result) == LISP_ERROR) {
        char *err_str = lisp_print(result);
        if (err_str) {
            mudlark_log(LOG_ERROR, "hooks", "telnet-input-hook: %s", err_str);
        }
    }
}

/* Call user-input-hook with raw user input (filter hook).
 * Returns 1 if input was consumed (any handler returned nil), 0 otherwise. */
int lisp_x_call_user_input_hook(const char *text, size_t len)
{
    Environment *env = get_current_env();
    if (!env || !text || len == 0) {
        return 0;
    }

    LispObject *hook =
        env_lookup(env, LISP_SYM_VAL(lisp_intern("user-input-hook")));
    if (!lisp_is_callable(hook)) {
        mudlark_log(LOG_DEBUG, "hooks",
                    "user-input-hook: hook not found or wrong type");
        return 0;
    }

    mudlark_log(LOG_DEBUG, "hooks", "user-input-hook: calling with %zu bytes", len);

    volatile LispObject *text_arg = lisp_make_string(text);
    if (!text_arg || LISP_TYPE((LispObject *)text_arg) == LISP_ERROR) {
        mudlark_log(LOG_DEBUG, "hooks",
                    "user-input-hook: failed to create string arg");
        return 0;
    }

    volatile LispObject *args = lisp_make_cons((LispObject *)text_arg, NIL);
    volatile LispObject *call_expr = lisp_make_cons(hook, (LispObject *)args);
    LispObject *result = lisp_eval((LispObject *)call_expr, env);

    if (result && LISP_TYPE(result) == LISP_ERROR) {
        char *err_str = lisp_print(result);
        if (err_str) {
            mudlark_log(LOG_ERROR, "hooks", "user-input-hook: %s", err_str);
        }
        return 0;
    }

    /* nil result means input was consumed by a filter handler */
    return (!result || result == NIL) ? 1 : 0;
}

/* Run all due timers */
void lisp_x_run_timers(void)
{
    Environment *env = get_current_env();
    if (!env)
        return;

    LispObject *fn = env_lookup(env, LISP_SYM_VAL(lisp_intern("run-timers")));
    if (!lisp_is_callable(fn))
        return;

    volatile LispObject *call = lisp_make_cons(fn, NIL);
    LispObject *result = lisp_eval((LispObject *)call, env);

    if (result && LISP_TYPE(result) == LISP_ERROR) {
        char *err_str = lisp_print(result);
        if (err_str) {
            mudlark_log(LOG_ERROR, "hooks", "run-timers: %s", err_str);
        }
    }
}

/* Return ms until next timer fires, or -1 if no timers are active.
   Reads the cached *timer-next-fire-ms* variable maintained by Lisp. */
int lisp_x_next_timer_ms(void)
{
    Environment *env = get_current_env();
    if (!env)
        return -1;

    LispObject *cached =
        env_lookup(env, LISP_SYM_VAL(lisp_intern("*timer-next-fire-ms*")));
    if (!cached || cached == NIL)
        return -1;

    long long fire_time = -1;
    if (LISP_TYPE(cached) == LISP_INTEGER)
        fire_time = LISP_INT_VAL(cached);
    else if (LISP_TYPE(cached) == LISP_NUMBER)
        fire_time = (long long)LISP_NUM_VAL(cached);

    if (fire_time < 0)
        return -1;

    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    long long now_ms = (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;

    long long delta = fire_time - now_ms;
    if (delta <= 0)
        return 0;
    return (int)delta;
}

/* Call telnet-input-transform-hook */
const char *lisp_x_call_telnet_input_transform_hook(const char *text,
                                                    size_t len,
                                                    size_t *out_len)
{
    Environment *env = get_current_env();
    if (!env || !text || len == 0 || !out_len) {
        if (out_len)
            *out_len = len;
        return text;
    }

    LispObject *hook = env_lookup(
        env, LISP_SYM_VAL(lisp_intern("telnet-input-transform-hook")));
    if (!lisp_is_callable(hook)) {
        *out_len = len;
        return text;
    }

    dynamic_buffer_clear(telnet_filter_temp_buf);
    if (dynamic_buffer_append(telnet_filter_temp_buf, text, len) < 0 ||
        dynamic_buffer_append(telnet_filter_temp_buf, "\0", 1) < 0) {
        *out_len = len;
        return text;
    }

    volatile LispObject *arg = lisp_make_string(telnet_filter_temp_buf->data);
    if (!arg || LISP_TYPE((LispObject *)arg) == LISP_ERROR) {
        *out_len = len;
        return text;
    }

    volatile LispObject *args = lisp_make_cons((LispObject *)arg, NIL);
    volatile LispObject *call_expr = lisp_make_cons(hook, (LispObject *)args);
    LispObject *result = lisp_eval((LispObject *)call_expr, env);

    if (!result || LISP_TYPE(result) == LISP_ERROR) {
        char *err_str = lisp_print(result);
        if (err_str) {
            mudlark_log(LOG_ERROR, "hooks", "telnet-input-transform-hook: %s", err_str);
        }
        *out_len = len;
        return text;
    }

    if (LISP_TYPE(result) != LISP_STRING) {
        *out_len = len;
        return text;
    }

    const char *transformed = LISP_STR_VAL(result);
    size_t transformed_len = strlen(transformed);

    dynamic_buffer_clear(telnet_filter_buf);
    if (dynamic_buffer_append(telnet_filter_buf, transformed,
                              transformed_len) < 0 ||
        dynamic_buffer_append(telnet_filter_buf, "\0", 1) < 0) {
        *out_len = len;
        return text;
    }
    *out_len = transformed_len;

    return telnet_filter_buf->data;
}

/* Call user-input-transform-hook */
LispObject *lisp_x_call_user_input_transform_hook(const char *text)
{
    Environment *env = get_current_env();
    if (!env || !text) {
        return lisp_make_string(text ? text : "");
    }

    LispObject *hook = env_lookup(
        env, LISP_SYM_VAL(lisp_intern("user-input-transform-hook")));
    if (!lisp_is_callable(hook)) {
        return lisp_make_string(text);
    }

    volatile LispObject *text_arg = lisp_make_string(text);
    if (!text_arg || LISP_TYPE((LispObject *)text_arg) == LISP_ERROR) {
        return lisp_make_string(text);
    }

    volatile LispObject *args = lisp_make_cons((LispObject *)text_arg, NIL);
    volatile LispObject *call_expr = lisp_make_cons(hook, (LispObject *)args);
    LispObject *result = lisp_eval((LispObject *)call_expr, env);

    if (!result || LISP_TYPE(result) == LISP_ERROR) {
        char *err_str = lisp_print(result);
        if (err_str) {
            mudlark_log(LOG_ERROR, "hooks", "user-input-transform-hook: %s", err_str);
        }
        if (text && text[0] == '#') {
            return lisp_make_string("");
        }
        return lisp_make_string(text);
    }

    return result;
}

/* Get input history size from Lisp config */
int lisp_x_get_input_history_size(void)
{
    Environment *env = get_current_env();
    if (!env) {
        return 1000;
    }

    LispObject *value =
        env_lookup(env, LISP_SYM_VAL(lisp_intern("*input-history-size*")));
    if (value && LISP_TYPE(value) == LISP_INTEGER) {
        int size = (int)LISP_INT_VAL(value);
        if (size > 0) {
            return size;
        }
    }
    return 1000;
}

/* Register telnet instance on the current session */
void lisp_x_register_telnet(Telnet *t)
{
    Session *s = session_get_current();
    if (s) {
        s->telnet = t;
    }
}

/* Register TelnetApp model as the sink for set-status */
void lisp_x_register_status_sink(TelnetAppModel *app)
{
    registered_status_sink = app;
}

/* Get lisp environment (base env, shared across all sessions) */
void *lisp_x_get_environment(void) { return get_current_env(); }

/* Evaluate Lisp code and echo results */
int lisp_x_eval_and_echo(const char *code, DynamicBuffer *buf)
{
    Environment *env = get_current_env();
    if (!env || !code || !buf) {
        return -1;
    }

    dynamic_buffer_clear(buf);

    /* Evaluate */
    LispObject *result = lisp_eval_string(code, env);

    if (result && LISP_TYPE(result) == LISP_ERROR) {
        dynamic_buffer_append_str(buf, "; Error: ");
        char *err_str = lisp_print(result);
        if (err_str) {
            /* Replace \n with \r\n */
            for (const char *p = err_str; *p; p++) {
                if (*p == '\n') {
                    dynamic_buffer_append(buf, "\r\n", 2);
                } else {
                    dynamic_buffer_append(buf, p, 1);
                }
            }
        }
        dynamic_buffer_append_str(buf, "\r\n");
    } else if (result) {
        char *result_str = lisp_print(result);
        if (result_str) {
            for (const char *p = result_str; *p; p++) {
                if (*p == '\n') {
                    dynamic_buffer_append(buf, "\r\n", 2);
                } else {
                    dynamic_buffer_append(buf, p, 1);
                }
            }
            dynamic_buffer_append_str(buf, "\r\n");
        }
    }

    return 0;
}

/* Create default session, load init.lisp, and apply default hooks.
 * Called from main() after the TUI is initialized so that terminal-echo,
 * script-echo, termcap etc. work during loading. */
void lisp_x_load_init(void)
{
    /* Create the default session now that echo_callback is available */
    Session *s = session_create("default");
    if (!s) {
        mudlark_log(LOG_ERROR, "lisp", "Failed to create default session");
        return;
    }
    session_set_current(s);
    update_terminal_title();

    /* Echo creation message to terminal */
    char msg[256];
    snprintf(msg, sizeof(msg), "Created session %d: \"%s\"\r\n", s->id, s->name);
    if (echo_callback) {
        echo_callback(msg, strlen(msg));
    }

    /* Load init.lisp into base env (shared across all sessions) */
    Environment *base_env = session_get_base_env();
    load_lisp_system_file("init.lisp", base_env);

    /* Apply default hooks (registered during init.lisp) to session's hooks table
     */
    apply_default_hooks_to_table(s->hooks);
}

/* Get word-chars string from Lisp config */
const char *lisp_x_get_word_chars(void)
{
    Environment *env = get_current_env();
    if (!env)
        return NULL;

    LispObject *value =
        env_lookup(env, LISP_SYM_VAL(lisp_intern("*word-chars*")));
    if (value && LISP_TYPE(value) == LISP_STRING)
        return LISP_STR_VAL(value);
    return NULL;
}

/* Get prompt string from Lisp config */
const char *lisp_x_get_prompt(void)
{
    Environment *env = get_current_env();
    if (!env) {
        return "> ";
    }

    LispObject *value = env_lookup(env, LISP_SYM_VAL(lisp_intern("*prompt*")));
    if (value && LISP_TYPE(value) == LISP_STRING) {
        return LISP_STR_VAL(value);
    }
    return "> ";
}

/* Extract RGB from a Lisp '(r g b) defvar */
int lisp_x_get_color(const char *var_name, int *r, int *g, int *b)
{
    Environment *env = get_current_env();
    if (!env || !var_name || !r || !g || !b)
        return -1;

    LispObject *val = env_lookup(env, LISP_SYM_VAL(lisp_intern(var_name)));
    if (!val || LISP_TYPE(val) != LISP_CONS)
        return -1;

    LispObject *r_obj = lisp_car(val);
    LispObject *rest = lisp_cdr(val);
    if (!r_obj || LISP_TYPE(r_obj) != LISP_INTEGER || !rest ||
        LISP_TYPE(rest) != LISP_CONS)
        return -1;

    LispObject *g_obj = lisp_car(rest);
    rest = lisp_cdr(rest);
    if (!g_obj || LISP_TYPE(g_obj) != LISP_INTEGER || !rest ||
        LISP_TYPE(rest) != LISP_CONS)
        return -1;

    LispObject *b_obj = lisp_car(rest);
    if (!b_obj || LISP_TYPE(b_obj) != LISP_INTEGER)
        return -1;

    *r = (int)LISP_INT_VAL(r_obj);
    *g = (int)LISP_INT_VAL(g_obj);
    *b = (int)LISP_INT_VAL(b_obj);
    return 0;
}

/* Get completions for a prefix string */
char **lisp_x_complete_prefix(const char *prefix)
{
    Environment *env = get_current_env();
    if (!env || !prefix) {
        mudlark_log(LOG_DEBUG, "completion", "no env or prefix");
        return NULL;
    }

    /* Look up completion-hook */
    LispObject *hook =
        env_lookup(env, LISP_SYM_VAL(lisp_intern("completion-hook")));
    if (!lisp_is_callable(hook)) {
        mudlark_log(LOG_DEBUG, "completion", "hook not found or wrong type");
        return NULL;
    }

    mudlark_log(LOG_DEBUG, "completion", "prefix=\"%s\"", prefix);

    /* Call hook with prefix text */
    volatile LispObject *arg = lisp_make_string(prefix);
    volatile LispObject *args = lisp_make_cons((LispObject *)arg, NIL);
    volatile LispObject *call_expr = lisp_make_cons(hook, (LispObject *)args);
    LispObject *result = lisp_eval((LispObject *)call_expr, env);

    if (!result || LISP_TYPE(result) == LISP_ERROR || result == NIL) {
        if (!result)
            mudlark_log(LOG_DEBUG, "completion", "eval returned NULL");
        else if (LISP_TYPE(result) == LISP_ERROR)
            mudlark_log(LOG_DEBUG, "completion", "eval error: %s", lisp_print(result));
        else
            mudlark_log(LOG_DEBUG, "completion", "eval returned NIL");
        return NULL;
    }

    /* Convert result list to char** array */
    int count = 0;
    LispObject *p = result;
    while (p != NIL && LISP_TYPE(p) == LISP_CONS) {
        count++;
        p = lisp_cdr(p);
    }

    if (count == 0) {
        mudlark_log(LOG_DEBUG, "completion", "result list empty");
        return NULL;
    }

    mudlark_log(LOG_DEBUG, "completion", "%d candidates", count);

    /* Lazily create the reusable arena */
    if (!completion_arena) {
        completion_arena = dynamic_buffer_create(256);
        if (!completion_arena) {
            return NULL;
        }
    }

    /* Grow the pointer array if needed (amortized; +1 for the NULL terminator) */
    if (completion_ptrs_cap < count + 1) {
        int new_cap = completion_ptrs_cap ? completion_ptrs_cap * 2 : 16;
        while (new_cap < count + 1) {
            new_cap *= 2;
        }
        char **grown = realloc(completion_ptrs, new_cap * sizeof(char *));
        if (!grown) {
            return NULL;
        }
        completion_ptrs = grown;
        completion_ptrs_cap = new_cap;
    }

    /* Pass 1: pack all candidate strings into the arena, recording each one's
     * byte offset in the pointer slot (the arena may realloc as it grows, so
     * we can't take addresses yet). */
    dynamic_buffer_clear(completion_arena);
    int i = 0;
    p = result;
    while (p != NIL && LISP_TYPE(p) == LISP_CONS && i < count) {
        LispObject *item = lisp_car(p);
        const char *s =
            (item && LISP_TYPE(item) == LISP_STRING) ? LISP_STR_VAL(item) : "";
        size_t offset = dynamic_buffer_len(completion_arena);
        /* Append the string plus its NUL terminator so each is a C string */
        if (dynamic_buffer_append(completion_arena, s, strlen(s)) != 0 ||
            dynamic_buffer_append(completion_arena, "", 1) != 0) {
            return NULL;
        }
        completion_ptrs[i] = (char *)(uintptr_t)offset;
        i++;
        p = lisp_cdr(p);
    }

    /* Pass 2: now the arena is final, rebase the recorded offsets to real
     * pointers into its buffer. */
    char *base = (char *)dynamic_buffer_data(completion_arena);
    for (int j = 0; j < count; j++) {
        completion_ptrs[j] = base + (uintptr_t)completion_ptrs[j];
    }
    completion_ptrs[count] = NULL;

    return completion_ptrs;
}

/* Register terminal echo callback */
void lisp_x_register_echo_callback(TerminalEchoCallback callback)
{
    echo_callback = callback;
}

/* Register runtime for terminal control commands */
void lisp_x_register_runtime(TuiRuntime *runtime)
{
    registered_runtime = runtime;
}

/* Dispatch F-key press to Lisp fkey-hook */
void lisp_x_call_fkey_hook(int fkey_num)
{
    Environment *env = get_current_env();
    if (!env)
        return;

    LispObject *args =
        lisp_make_cons(lisp_intern("fkey-hook"),
                       lisp_make_cons(lisp_make_integer(fkey_num), NIL));
    builtin_run_hook(args, env);
}
