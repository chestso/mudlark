/* Logging system implementation for mudlark */

#include "logging.h"
#include "../include/terminal_caps.h"
#include "colors.h"
#include "lisp_extension.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define MAX_FILTER_ENTRIES  16
#define LOG_FORMAT_BUF_SIZE 1024

typedef struct
{
    char tag[32];
    LogLevel min_level;
} FilterEntry;

static LogEchoFn g_echo_fn = NULL;
static FilterEntry g_filters[MAX_FILTER_ENTRIES];
static int g_filter_count = 0;
static LogLevel g_default_level = LOG_ERROR + 1; /* above max = nothing */
static int g_filter_active = 0;

static char g_format_buf[LOG_FORMAT_BUF_SIZE];

void mudlark_log_set_echo(LogEchoFn fn) { g_echo_fn = fn; }

static LogLevel parse_level(const char *s, size_t len)
{
    if (len == 5 && strncasecmp(s, "DEBUG", 5) == 0)
        return LOG_DEBUG;
    if (len == 4 && strncasecmp(s, "INFO", 4) == 0)
        return LOG_INFO;
    if (len == 4 && strncasecmp(s, "WARN", 4) == 0)
        return LOG_WARN;
    if (len == 5 && strncasecmp(s, "ERROR", 5) == 0)
        return LOG_ERROR;
    return LOG_INFO; /* default */
}

void mudlark_log_set_filter(const char *spec)
{
    g_filter_count = 0;
    g_default_level = LOG_ERROR + 1;
    g_filter_active = 0;

    if (!spec || spec[0] == '\0')
        return;

    g_filter_active = 1;
    const char *p = spec;

    while (*p && g_filter_count < MAX_FILTER_ENTRIES) {
        /* Skip whitespace and commas */
        while (*p == ',' || *p == ' ')
            p++;
        if (!*p)
            break;

        /* Find colon separator */
        const char *colon = strchr(p, ':');
        if (!colon)
            break;

        size_t tag_len = colon - p;
        const char *level_start = colon + 1;

        /* Find end of level (comma or end of string) */
        const char *level_end = level_start;
        while (*level_end && *level_end != ',' && *level_end != ' ')
            level_end++;

        LogLevel level = parse_level(level_start, level_end - level_start);

        if (tag_len == 1 && p[0] == '*') {
            /* Wildcard default */
            g_default_level = level;
        } else {
            FilterEntry *e = &g_filters[g_filter_count++];
            size_t copy_len =
                tag_len < sizeof(e->tag) - 1 ? tag_len : sizeof(e->tag) - 1;
            memcpy(e->tag, p, copy_len);
            e->tag[copy_len] = '\0';
            e->min_level = level;
        }

        p = level_end;
    }
}

static int filter_allows(LogLevel level, const char *tag)
{
    if (!g_filter_active)
        return 0;

    /* Check exact tag match */
    if (tag) {
        for (int i = 0; i < g_filter_count; i++) {
            if (strcmp(g_filters[i].tag, tag) == 0) {
                return level >= g_filters[i].min_level;
            }
        }
    }

    /* Fall through to default */
    return level >= g_default_level;
}

void mudlark_log(LogLevel level, const char *tag, const char *fmt, ...)
{
    int show_in_viewport = filter_allows(level, tag);

    /* Format the user message */
    const char *level_str;
    switch (level) {
    case LOG_DEBUG:
        level_str = "[debug] ";
        break;
    case LOG_INFO:
        level_str = "[info]  ";
        break;
    case LOG_WARN:
        level_str = "[warn]  ";
        break;
    case LOG_ERROR:
        level_str = "[error] ";
        break;
    default:
        level_str = "[????]  ";
        break;
    }

    va_list ap;
    va_start(ap, fmt);
    char msg_buf[LOG_FORMAT_BUF_SIZE - 128];
    vsnprintf(msg_buf, sizeof(msg_buf), fmt, ap);
    va_end(ap);

    /* Always log to stderr */
    fprintf(stderr, "%s%s\n", level_str, msg_buf);

    /* Send to viewport only if filter allows */
    if (show_in_viewport && g_echo_fn) {
        int cr, cg, cb;
        const char *color;
        const char *reset = termcaps_format_reset();
        switch (level) {
        case LOG_DEBUG:
            if (lisp_x_get_color("*color-log-debug*", &cr, &cg, &cb) < 0) {
                cr = COLOR_LOG_DEBUG_R;
                cg = COLOR_LOG_DEBUG_G;
                cb = COLOR_LOG_DEBUG_B;
            }
            color = termcaps_format_fg_color(cr, cg, cb);
            break;
        case LOG_INFO:
            if (lisp_x_get_color("*color-log-info*", &cr, &cg, &cb) < 0) {
                cr = COLOR_LOG_INFO_R;
                cg = COLOR_LOG_INFO_G;
                cb = COLOR_LOG_INFO_B;
            }
            color = termcaps_format_fg_color(cr, cg, cb);
            break;
        case LOG_WARN:
            if (lisp_x_get_color("*color-log-warn*", &cr, &cg, &cb) < 0) {
                cr = COLOR_LOG_WARN_R;
                cg = COLOR_LOG_WARN_G;
                cb = COLOR_LOG_WARN_B;
            }
            color = termcaps_format_fg_color(cr, cg, cb);
            break;
        case LOG_ERROR:
            if (lisp_x_get_color("*color-log-error*", &cr, &cg, &cb) < 0) {
                cr = COLOR_LOG_ERROR_R;
                cg = COLOR_LOG_ERROR_G;
                cb = COLOR_LOG_ERROR_B;
            }
            color = termcaps_format_fg_color(cr, cg, cb);
            break;
        default:
            color = "";
            break;
        }
        int n = snprintf(g_format_buf, sizeof(g_format_buf), "%s%s%s%s\n", color,
                         level_str, msg_buf, reset);
        if (n > 0) {
            size_t len = (size_t)n < sizeof(g_format_buf) ? (size_t)n
                                                          : sizeof(g_format_buf) - 1;
            g_echo_fn(g_format_buf, len);
        }
    }
}
