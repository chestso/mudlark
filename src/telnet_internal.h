/* telnet_internal.h - Telnet struct definition (private to src/ and tests/) */

#ifndef TELNET_INTERNAL_H
#define TELNET_INTERNAL_H

#include "../include/telnet.h"
#include <boba/dynamic_buffer.h>
#include <stdio.h>

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
};

#endif /* TELNET_INTERNAL_H */
