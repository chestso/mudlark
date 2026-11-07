/* telnet_internal.h - Telnet struct definition (private to src/ and tests/) */

#ifndef TELNET_INTERNAL_H
#define TELNET_INTERNAL_H

#include "../include/telnet.h"
#include <boba/dynamic_buffer.h>
#include <stdio.h>

/* Telnet protocol constants (RFC 854). They live here so the tests can
 * drive the negotiation path directly. */
#define TELNET_IAC  255 /* Interpret As Command */
#define TELNET_SE   240 /* Subnegotiation End */
#define TELNET_NOP  241 /* No operation */
#define TELNET_DM   242 /* Data mark */
#define TELNET_BRK  243 /* Break */
#define TELNET_IP   244 /* Interrupt process */
#define TELNET_AO   245 /* Abort output */
#define TELNET_AYT  246 /* Are you there */
#define TELNET_EC   247 /* Erase character */
#define TELNET_EL   248 /* Erase line */
#define TELNET_GA   249 /* Go ahead */
#define TELNET_SB   250 /* Subnegotiation begin */
#define TELNET_WILL 251
#define TELNET_WONT 252
#define TELNET_DO   253
#define TELNET_DONT 254

/* Telnet options */
#define TELNET_OPT_ECHO              1
#define TELNET_OPT_SUPPRESS_GO_AHEAD 3
#define TELNET_OPT_TERMINAL_TYPE     24
#define TELNET_OPT_NAWS              31

typedef enum
{
    TELNET_DATA_NORMAL,
    TELNET_DATA_IAC,
    TELNET_DATA_WILL,
    TELNET_DATA_WONT,
    TELNET_DATA_DO,
    TELNET_DATA_DONT,
} TelnetDataState;

struct Telnet
{
    int socket;
    TelnetState state;
    int rows, cols;
    int server_echo; /* Server is echoing (password mode) */
    TelnetDataState
        data_state;          /* IAC state machine (persists across recv calls) */
    FILE *log_file;          /* Log file handle for I/O logging */
    char log_filename[1024]; /* Path to current log file */
    DynamicBuffer
        *send_buffer;           /* Buffer for IAC escaping (reused across calls) */
    DynamicBuffer *crlf_buffer; /* Buffer for adding CRLF to Lisp sends (reused
                                   across calls) */
    DynamicBuffer
        *user_input_buffer; /* Buffer for user input LF->CRLF conversion */

    /* 1 = a line went to the server and nothing has come back yet: the
     * server owes an answer. Set by the line-sending path
     * (telnet_send_with_crlf), cleared by the first byte that arrives (and
     * by a disconnect). Protocol traffic (IAC negotiation, NAWS) is not a
     * user line and never sets it. */
    int awaiting_reply;
};

/* Send a Telnet command (IAC negotiation) on a socket. Not a user line:
 * it never reserves a row for an answer. */
int telnet_send_command(int socket, int cmd, int opt);

#endif /* TELNET_INTERNAL_H */
