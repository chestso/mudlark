/* Terminal capability detection for mudlark
 *
 * Provides hybrid detection of terminal capabilities using environment
 * variables (primary) with optional fallback to terminal escape sequence queries.
 */

#ifndef TERMINAL_CAPS_H
#define TERMINAL_CAPS_H

#include <stddef.h>

/* Color support levels */
typedef enum
{
    TERM_COLOR_NONE = 0,     /* No color support (dumb terminal) */
    TERM_COLOR_8 = 1,        /* Basic 8 colors (SGR 30-37, 40-47) */
    TERM_COLOR_16 = 2,       /* 16 colors (includes bright variants 90-97, 100-107) */
    TERM_COLOR_256 = 3,      /* 256 color palette (SGR 38;5;N) */
    TERM_COLOR_TRUECOLOR = 4 /* 24-bit RGB (SGR 38;2;R;G;B) */
} TermColorLevel;

/* Unicode support levels */
typedef enum
{
    TERM_UNICODE_NONE = 0,  /* ASCII only */
    TERM_UNICODE_BASIC = 1, /* Latin-1 / ISO-8859-1 */
    TERM_UNICODE_FULL = 2   /* Full UTF-8 support */
} TermUnicodeLevel;

/* Terminal capabilities structure */
typedef struct
{
    TermColorLevel color_level;     /* Detected color support */
    TermUnicodeLevel unicode_level; /* Detected unicode support */

    /* Terminal identification */
    char term_type[64];    /* Value of $TERM */
    char term_program[64]; /* Value of $TERM_PROGRAM (if set) */
    char colorterm[64];    /* Value of $COLORTERM (if set) */
    char encoding[32];     /* Detected encoding (UTF-8, ASCII, etc.) */

    /* Detection flags */
    int detected_from_env;   /* 1 if detected from environment variables */
    int detected_from_query; /* 1 if detected from terminal queries */
    int is_dumb_terminal;    /* 1 if $TERM is "dumb" or unset */
} TerminalCaps;

/* Initialize terminal capability detection.
 * This should be called early in program startup, before entering raw mode.
 * Returns 0 on success, -1 on error.
 */
int termcaps_init(void);

/* Clean up terminal capability resources.
 * Should be called during program cleanup.
 */
void termcaps_cleanup(void);

/* Get the detected terminal capabilities.
 * Returns pointer to static TerminalCaps structure, or NULL if not initialized.
 */
const TerminalCaps *termcaps_get(void);

/* Refresh terminal capabilities (re-detect from environment).
 * Useful after terminal changes or environment variable modifications.
 */
void termcaps_refresh(void);

/* Query functions for specific capabilities */
int termcaps_supports_color(void);        /* Returns 1 if any color support */
int termcaps_supports_256color(void);     /* Returns 1 if 256+ colors */
int termcaps_supports_truecolor(void);    /* Returns 1 if 24-bit RGB */
int termcaps_supports_unicode(void);      /* Returns 1 if any unicode support */
int termcaps_supports_full_unicode(void); /* Returns 1 if full UTF-8 */

/* Get color level as integer (0-4) */
int termcaps_get_color_level(void);

/* Get terminal type string */
const char *termcaps_get_term_type(void);

/* Get detected encoding string */
const char *termcaps_get_encoding(void);

/* Color conversion utilities */

/* Convert 24-bit RGB to closest 256-color palette index.
 * Uses standard 6x6x6 color cube plus grayscale ramp.
 */
int termcaps_rgb_to_256(int r, int g, int b);

/* Convert 24-bit RGB to closest 8-color ANSI index (0-7).
 * Maps to: black, red, green, yellow, blue, magenta, cyan, white
 */
int termcaps_rgb_to_8(int r, int g, int b);

/* Capability-aware color formatting.
 * These functions return escape sequences appropriate for the detected
 * terminal capabilities.
 *
 * WARNING: Each function returns a pointer to its own static buffer.
 * The buffer is overwritten on subsequent calls to the SAME function.
 * Copy the result if you need to preserve it across multiple calls.
 * Note: fg and bg use separate buffers, so interleaving those is safe.
 *
 * For foreground colors:
 *   - Truecolor: \033[38;2;R;G;Bm
 *   - 256-color: \033[38;5;Nm
 *   - 16-color:  \033[3N;1m or \033[3Nm
 *   - 8-color:   \033[3Nm
 *   - No color:  empty string
 *
 * For background colors:
 *   - Truecolor: \033[48;2;R;G;Bm
 *   - 256-color: \033[48;5;Nm
 *   - 16-color:  \033[4N;1m or \033[4Nm
 *   - 8-color:   \033[4Nm
 *   - No color:  empty string
 */
const char *termcaps_format_fg_color(int r, int g, int b);
const char *termcaps_format_bg_color(int r, int g, int b);

/* Format reset sequence (empty string if no color support) */
const char *termcaps_format_reset(void);

/* Human-readable description of detected capabilities.
 * WARNING: Returns pointer to static buffer, overwritten on each call.
 */
const char *termcaps_describe(void);

/* Optional: Enable/disable terminal query probing.
 * When enabled, uses DA1/OSC4 escape sequences to probe terminal.
 * Default is disabled (environment-only detection).
 */
void termcaps_set_query_enabled(int enabled);
int termcaps_get_query_enabled(void);

#endif /* TERMINAL_CAPS_H */
