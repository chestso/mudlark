/* Special colon commands for mudlark */

#ifndef COMMANDS_H
#define COMMANDS_H

#include <stddef.h>

#include "../include/telnet.h"

/* Callback for echoing command output (e.g. to viewport) */
typedef void (*CommandEchoFn)(const char *text, size_t len);

/* Process special commands starting with ':'
 * Returns 1 if command was processed, 0 if not a command
 *
 * Parameters:
 *   text           - Input text to process
 *   telnet         - Telnet connection instance
 *   connected_mode - Pointer to connection state (updated by commands)
 *   quit_requested - Pointer to quit flag (set by :quit command)
 *   term_cols      - Terminal width (for NAWS)
 *   term_rows      - Terminal height (for NAWS)
 *   echo_fn        - Callback to output text (NULL falls back to printf)
 */
int process_command(const char *text, Telnet *telnet, int *connected_mode,
                    int *quit_requested, int term_cols, int term_rows,
                    CommandEchoFn echo_fn);

#endif /* COMMANDS_H */
