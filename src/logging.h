/* Logging system for mudlark
 *
 * Routes log messages to the viewport with colored prefixes.
 * Filterable via CLI --log option and Lisp (set-log-filter) at runtime.
 */

#ifndef MUDLARK_LOGGING_H
#define MUDLARK_LOGGING_H

#include <stddef.h>

typedef enum
{
    LOG_DEBUG,
    LOG_INFO,
    LOG_WARN,
    LOG_ERROR
} LogLevel;

/* Callback type for routing log output to the viewport */
typedef void (*LogEchoFn)(const char *text, size_t len);

/* Set the echo function for viewport output.
 * Before this is called, log messages go to stderr. */
void mudlark_log_set_echo(LogEchoFn fn);

/* Set filter specification.
 * Format: comma-separated "tag:LEVEL" pairs.
 * Examples: "*:INFO", "completion:DEBUG,*:WARN"
 * If never called or spec is NULL, logging is off. */
void mudlark_log_set_filter(const char *spec);

/* Log a message. tag may be NULL (matches only "*" filter).
 * fmt is printf-style format string. */
void mudlark_log(LogLevel level, const char *tag, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

#endif /* MUDLARK_LOGGING_H */
