/* Lisp interface for bloom-telnet */

#ifndef BLOOM_TELNET_LISP_H
#define BLOOM_TELNET_LISP_H

#include <bloom-boba/dynamic_buffer.h>
#include <stddef.h>

/* Initialize Lisp interpreter, environment, and load init file */
int lisp_x_init(void);

/* Load and evaluate additional Lisp file (after init) */
int lisp_x_load_file(const char *filepath);

/* Cleanup Lisp interpreter */
void lisp_x_cleanup(void);

/* Call telnet-input-hook with telnet data (stripped of ANSI codes) */
void lisp_x_call_telnet_input_hook(const char *text, size_t len);

/* Call user-input-hook with raw user input (filter hook).
 * Returns 1 if input was consumed (any handler returned nil), 0 otherwise. */
int lisp_x_call_user_input_hook(const char *text, size_t len);

/* Run all due timers - calls (run-timers) in Lisp each frame */
void lisp_x_run_timers(void);

/* Call telnet-input-transform-hook with telnet data (with ANSI codes) before
 * displaying Returns transformed text or original */
const char *lisp_x_call_telnet_input_transform_hook(const char *text,
                                                    size_t len,
                                                    size_t *out_len);

/* Forward declaration for Telnet type (defined in telnet.h) */
struct Telnet;

/* Call user-input-transform-hook with user input before sending to telnet
 * Returns LispObject * (string or list of strings) */
struct LispObject *lisp_x_call_user_input_transform_hook(const char *text);

/* Send a hook result (string or list of strings) to telnet */
void lisp_x_send_hook_result(struct LispObject *result, struct Telnet *telnet);

/* Get input history size from Lisp config (default: 100) */
int lisp_x_get_input_history_size(void);

/* Register telnet pointer on the current session */
void lisp_x_register_telnet(struct Telnet *t);

/* Forward declaration for TuiStatusBar type */
struct TuiStatusBar;

/* Register statusbar pointer for statusbar builtins */
void lisp_x_register_statusbar(struct TuiStatusBar *sb);

/* Get lisp environment (for accessing Lisp variables from C) */
void *lisp_x_get_environment(void);

/* Evaluate Lisp code and build echo buffer (eval-mode style)
 * Uses preallocated DynamicBuffer
 * Output format: "> code\r\n" + (result or "; Error: ...\r\n")
 * Returns: 0 on success, -1 on failure
 */
int lisp_x_eval_and_echo(const char *code, DynamicBuffer *buf);

/* Load init.lisp into base env. Called after TUI is initialized so that
 * terminal-echo, script-echo, termcap etc. work during loading. */
void lisp_x_load_init(void);

/* Get word-chars string from Lisp *word-chars* (NULL if not set) */
const char *lisp_x_get_word_chars(void);

/* Get prompt string from Lisp config (default: "> ") */
const char *lisp_x_get_prompt(void);

/* Get completions for a prefix string.
 * Returns NULL-terminated array of strings (caller must free each + array). */
char **lisp_x_complete_prefix(const char *prefix);

/* Extract RGB from a Lisp '(r g b) defvar.
 * Returns 0 on success, -1 on failure (variable missing or wrong shape).
 * Callers should fall back to colors.h defaults on failure. */
int lisp_x_get_color(const char *var_name, int *r, int *g, int *b);

/* Terminal echo callback type - called by terminal-echo builtin */
typedef void (*TerminalEchoCallback)(const char *text, size_t len);

/* Register terminal echo callback for terminal-echo builtin */
void lisp_x_register_echo_callback(TerminalEchoCallback callback);

/* Forward declaration for TuiRuntime type */
struct TuiRuntime;

/* Register runtime for terminal control commands (e.g. window title) */
void lisp_x_register_runtime(struct TuiRuntime *runtime);

/* Dispatch F-key press to Lisp fkey-hook */
void lisp_x_call_fkey_hook(int fkey_num);

/* Return ms until next timer fires, or -1 if no timers are active.
 * Used by the event loop to compute select() timeout. */
int lisp_x_next_timer_ms(void);

/* Store a CLI argument for later dispatch to Lisp handlers.
 * Called during arg parsing in main() for unknown --flag value pairs. */
void lisp_x_add_cli_arg(const char *flag, const char *value);

/* Dispatch collected CLI args to registered Lisp handlers.
 * Called after all -l files are loaded. Returns number of errors. */
int lisp_x_dispatch_cli_args(void);

#endif /* BLOOM_TELNET_LISP_H */
