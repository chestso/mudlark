/* Terminal capability detection implementation for mudlark
 *
 * Detection strategy:
 * 1. Environment variables (primary, always runs)
 *    - $COLORTERM for truecolor detection
 *    - $TERM_PROGRAM for known terminal identification
 *    - $TERM for color level and terminal type
 *    - $LC_ALL/$LANG for encoding detection
 *
 * 2. Terminal queries (optional, when enabled)
 *    - OSC 4 color query for RGB support verification
 *    - Uses select() with 100ms timeout
 */

#include "../include/terminal_caps.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>
#endif

/* Static state */
static TerminalCaps g_caps;
static int g_initialized = 0;
static int g_query_enabled = 0;

/* Static buffers for formatted output */
static char g_fg_color_buf[32];
static char g_bg_color_buf[32];
static char g_describe_buf[512];

/* Known terminal programs that support truecolor */
static const char *truecolor_terminals[] = {
    "iTerm.app", "Apple_Terminal", /* macOS Terminal.app (10.14+) */
    "Hyper", "vscode", "Alacritty",
    "kitty", "WezTerm", "Tabby",
    "mintty", "ConEmu", "Windows Terminal",
    "contour", "foot", "rio",
    NULL
};

/* Known $TERM values that support 256 colors */
static const char *term_256color_patterns[] = { "-256color", "-256colour", NULL };

/* Known $TERM prefixes that support at least 16 colors */
static const char *term_16color_prefixes[] = {
    "xterm", "screen", "tmux", "rxvt", "linux", "vt100",
    "vt220", "ansi", "cygwin", "putty", NULL
};

/* Forward declarations */
static void detect_from_environment(void);
static void detect_color_level(void);
static void detect_unicode_level(void);
static int str_ends_with(const char *str, const char *suffix);
static int str_starts_with(const char *str, const char *prefix);
static int str_contains_ci(const char *str, const char *substr);

#ifndef _WIN32
static void detect_from_terminal_query(void);
#endif

/* Initialize terminal capability detection */
int termcaps_init(void)
{
    if (g_initialized) {
        return 0;
    }

    memset(&g_caps, 0, sizeof(g_caps));
    detect_from_environment();

    g_initialized = 1;
    return 0;
}

/* Cleanup terminal capability resources */
void termcaps_cleanup(void)
{
    g_initialized = 0;
    memset(&g_caps, 0, sizeof(g_caps));
}

/* Get detected terminal capabilities */
const TerminalCaps *termcaps_get(void)
{
    if (!g_initialized) {
        return NULL;
    }
    return &g_caps;
}

/* Refresh terminal capabilities */
void termcaps_refresh(void)
{
    if (!g_initialized) {
        termcaps_init();
        return;
    }

    memset(&g_caps, 0, sizeof(g_caps));
    detect_from_environment();
}

/* Query functions */
int termcaps_supports_color(void)
{
    return g_initialized && g_caps.color_level >= TERM_COLOR_8;
}

int termcaps_supports_256color(void)
{
    return g_initialized && g_caps.color_level >= TERM_COLOR_256;
}

int termcaps_supports_truecolor(void)
{
    return g_initialized && g_caps.color_level == TERM_COLOR_TRUECOLOR;
}

int termcaps_supports_unicode(void)
{
    return g_initialized && g_caps.unicode_level >= TERM_UNICODE_BASIC;
}

int termcaps_supports_full_unicode(void)
{
    return g_initialized && g_caps.unicode_level == TERM_UNICODE_FULL;
}

int termcaps_get_color_level(void)
{
    if (!g_initialized) {
        return 0;
    }
    return (int)g_caps.color_level;
}

const char *termcaps_get_term_type(void)
{
    if (!g_initialized) {
        return "";
    }
    return g_caps.term_type;
}

const char *termcaps_get_encoding(void)
{
    if (!g_initialized) {
        return "ASCII";
    }
    return g_caps.encoding;
}

/* Enable/disable terminal queries */
void termcaps_set_query_enabled(int enabled) { g_query_enabled = enabled; }

int termcaps_get_query_enabled(void) { return g_query_enabled; }

/* Detect capabilities from environment variables */
static void detect_from_environment(void)
{
    const char *term = getenv("TERM");
    const char *colorterm = getenv("COLORTERM");
    const char *term_program = getenv("TERM_PROGRAM");

    /* Copy environment values */
    if (term) {
        strncpy(g_caps.term_type, term, sizeof(g_caps.term_type) - 1);
    }
    if (colorterm) {
        strncpy(g_caps.colorterm, colorterm, sizeof(g_caps.colorterm) - 1);
    }
    if (term_program) {
        strncpy(g_caps.term_program, term_program, sizeof(g_caps.term_program) - 1);
    }

    /* Check for dumb terminal */
    if (!term || strcmp(term, "dumb") == 0 || term[0] == '\0') {
        g_caps.is_dumb_terminal = 1;
        g_caps.color_level = TERM_COLOR_NONE;
    } else {
        detect_color_level();
    }

    detect_unicode_level();
    g_caps.detected_from_env = 1;

#ifndef _WIN32
    /* Optional terminal query */
    if (g_query_enabled && !g_caps.is_dumb_terminal) {
        detect_from_terminal_query();
    }
#endif
}

/* Detect color level from environment */
static void detect_color_level(void)
{
    const char *colorterm = g_caps.colorterm;
    const char *term_program = g_caps.term_program;
    const char *term = g_caps.term_type;

    /* Check $COLORTERM for truecolor */
    if (colorterm[0] != '\0') {
        if (strcmp(colorterm, "truecolor") == 0 ||
            strcmp(colorterm, "24bit") == 0) {
            g_caps.color_level = TERM_COLOR_TRUECOLOR;
            return;
        }
    }

    /* Check $TERM_PROGRAM for known truecolor terminals */
    if (term_program[0] != '\0') {
        for (int i = 0; truecolor_terminals[i] != NULL; i++) {
            if (strcmp(term_program, truecolor_terminals[i]) == 0) {
                g_caps.color_level = TERM_COLOR_TRUECOLOR;
                return;
            }
        }
    }

    /* Check for WT_SESSION (Windows Terminal) */
    if (getenv("WT_SESSION") != NULL) {
        g_caps.color_level = TERM_COLOR_TRUECOLOR;
        return;
    }

    /* Check $TERM for 256-color suffix */
    if (term[0] != '\0') {
        for (int i = 0; term_256color_patterns[i] != NULL; i++) {
            if (str_ends_with(term, term_256color_patterns[i])) {
                g_caps.color_level = TERM_COLOR_256;
                return;
            }
        }

        /* Check for 16-color capable terminals */
        for (int i = 0; term_16color_prefixes[i] != NULL; i++) {
            if (str_starts_with(term, term_16color_prefixes[i])) {
                g_caps.color_level = TERM_COLOR_16;
                return;
            }
        }

        /* Any non-dumb terminal gets at least 8 colors */
        g_caps.color_level = TERM_COLOR_8;
    }
}

/* Detect unicode level from locale environment */
static void detect_unicode_level(void)
{
    const char *locale_vars[] = { "LC_ALL", "LC_CTYPE", "LANG", NULL };
    const char *locale = NULL;

    /* Find first set locale variable */
    for (int i = 0; locale_vars[i] != NULL; i++) {
        locale = getenv(locale_vars[i]);
        if (locale && locale[0] != '\0') {
            break;
        }
    }

    if (!locale || locale[0] == '\0') {
        g_caps.unicode_level = TERM_UNICODE_NONE;
        strncpy(g_caps.encoding, "ASCII", sizeof(g_caps.encoding) - 1);
        return;
    }

    /* Check for UTF-8 */
    if (str_contains_ci(locale, "utf-8") || str_contains_ci(locale, "utf8")) {
        g_caps.unicode_level = TERM_UNICODE_FULL;
        strncpy(g_caps.encoding, "UTF-8", sizeof(g_caps.encoding) - 1);
        return;
    }

    /* Check for ISO-8859 (Latin) */
    if (str_contains_ci(locale, "iso-8859") || str_contains_ci(locale, "latin")) {
        g_caps.unicode_level = TERM_UNICODE_BASIC;
        strncpy(g_caps.encoding, "ISO-8859-1", sizeof(g_caps.encoding) - 1);
        return;
    }

    /* Default to ASCII */
    g_caps.unicode_level = TERM_UNICODE_NONE;
    strncpy(g_caps.encoding, "ASCII", sizeof(g_caps.encoding) - 1);
}

#ifndef _WIN32
/* Detect capabilities using terminal escape sequence queries */
static void detect_from_terminal_query(void)
{
    /* Only run if stdin/stdout are TTYs */
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        return;
    }

    /* Save terminal settings */
    struct termios orig_termios, raw_termios;
    if (tcgetattr(STDIN_FILENO, &orig_termios) < 0) {
        return;
    }

    /* Set raw mode for query */
    raw_termios = orig_termios;
    raw_termios.c_lflag &= ~(ECHO | ICANON);
    raw_termios.c_cc[VMIN] = 0;
    raw_termios.c_cc[VTIME] = 0;

    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw_termios) < 0) {
        return;
    }

    /* Query OSC 4 for color 0 (black) - terminals supporting RGB will respond */
    /* Format: OSC 4 ; 0 ; ? ST */
    const char *query = "\033]4;0;?\007";
    if (write(STDOUT_FILENO, query, strlen(query)) < 0) {
        tcsetattr(STDIN_FILENO, TCSANOW, &orig_termios);
        return;
    }

    /* Wait for response with 100ms timeout */
    fd_set read_fds;
    struct timeval tv;
    FD_ZERO(&read_fds);
    FD_SET(STDIN_FILENO, &read_fds);
    tv.tv_sec = 0;
    tv.tv_usec = 100000; /* 100ms */

    int ready = select(STDIN_FILENO + 1, &read_fds, NULL, NULL, &tv);

    if (ready > 0) {
        /* Got response - terminal supports RGB color queries */
        char response[128];
        ssize_t n = read(STDIN_FILENO, response, sizeof(response) - 1);
        if (n > 0) {
            response[n] = '\0';
            /* If we got a response containing rgb: this terminal supports truecolor
             */
            if (strstr(response, "rgb:") != NULL) {
                if (g_caps.color_level < TERM_COLOR_TRUECOLOR) {
                    g_caps.color_level = TERM_COLOR_TRUECOLOR;
                }
                g_caps.detected_from_query = 1;
            }
        }
    }

    /* Restore terminal settings */
    tcsetattr(STDIN_FILENO, TCSANOW, &orig_termios);
}
#endif

/* String utility: check if string ends with suffix */
static int str_ends_with(const char *str, const char *suffix)
{
    if (!str || !suffix) {
        return 0;
    }
    size_t str_len = strlen(str);
    size_t suffix_len = strlen(suffix);
    if (suffix_len > str_len) {
        return 0;
    }
    return strcmp(str + str_len - suffix_len, suffix) == 0;
}

/* String utility: check if string starts with prefix */
static int str_starts_with(const char *str, const char *prefix)
{
    if (!str || !prefix) {
        return 0;
    }
    return strncmp(str, prefix, strlen(prefix)) == 0;
}

/* String utility: case-insensitive substring search */
static int str_contains_ci(const char *str, const char *substr)
{
    if (!str || !substr) {
        return 0;
    }

    size_t str_len = strlen(str);
    size_t substr_len = strlen(substr);

    if (substr_len > str_len) {
        return 0;
    }

    for (size_t i = 0; i <= str_len - substr_len; i++) {
        int match = 1;
        for (size_t j = 0; j < substr_len; j++) {
            if (tolower((unsigned char)str[i + j]) !=
                tolower((unsigned char)substr[j])) {
                match = 0;
                break;
            }
        }
        if (match) {
            return 1;
        }
    }
    return 0;
}

/* Convert RGB to 256-color palette index */
int termcaps_rgb_to_256(int r, int g, int b)
{
    /* Clamp values */
    if (r < 0)
        r = 0;
    if (r > 255)
        r = 255;
    if (g < 0)
        g = 0;
    if (g > 255)
        g = 255;
    if (b < 0)
        b = 0;
    if (b > 255)
        b = 255;

    /* Check for grayscale (colors 232-255) */
    /* Grayscale ramp: 232 (8,8,8) to 255 (238,238,238) in steps of 10 */
    if (r == g && g == b) {
        if (r < 4) {
            return 16; /* Black from color cube */
        }
        if (r > 243) {
            return 231; /* White from color cube */
        }
        /* Map to grayscale ramp (232-255) */
        return 232 + (r - 8) / 10;
    }

    /* Map to 6x6x6 color cube (colors 16-231) */
    /* Each component maps: 0-95 -> 0, 95-135 -> 1, 135-175 -> 2, etc. */
    int ri = (r < 48) ? 0 : (r < 115) ? 1
                                      : (r - 35) / 40;
    int gi = (g < 48) ? 0 : (g < 115) ? 1
                                      : (g - 35) / 40;
    int bi = (b < 48) ? 0 : (b < 115) ? 1
                                      : (b - 35) / 40;

    if (ri > 5)
        ri = 5;
    if (gi > 5)
        gi = 5;
    if (bi > 5)
        bi = 5;

    return 16 + 36 * ri + 6 * gi + bi;
}

/* Convert RGB to 8-color ANSI index */
int termcaps_rgb_to_8(int r, int g, int b)
{
    /* Clamp values */
    if (r < 0)
        r = 0;
    if (r > 255)
        r = 255;
    if (g < 0)
        g = 0;
    if (g > 255)
        g = 255;
    if (b < 0)
        b = 0;
    if (b > 255)
        b = 255;

    /* Simple threshold mapping:
     * 0 = black, 1 = red, 2 = green, 3 = yellow
     * 4 = blue, 5 = magenta, 6 = cyan, 7 = white
     */
    int threshold = 128;
    int rb = (r >= threshold) ? 1 : 0;
    int gb = (g >= threshold) ? 1 : 0;
    int bb = (b >= threshold) ? 1 : 0;

    /* ANSI color index = 4*blue + 2*green + 1*red */
    return rb + 2 * gb + 4 * bb;
}

/* Format foreground color escape sequence */
const char *termcaps_format_fg_color(int r, int g, int b)
{
    if (!g_initialized || g_caps.color_level == TERM_COLOR_NONE) {
        g_fg_color_buf[0] = '\0';
        return g_fg_color_buf;
    }

    switch (g_caps.color_level) {
    case TERM_COLOR_TRUECOLOR:
        snprintf(g_fg_color_buf, sizeof(g_fg_color_buf), "\033[38;2;%d;%d;%dm", r,
                 g, b);
        break;

    case TERM_COLOR_256:
    {
        int idx = termcaps_rgb_to_256(r, g, b);
        snprintf(g_fg_color_buf, sizeof(g_fg_color_buf), "\033[38;5;%dm", idx);
        break;
    }

    case TERM_COLOR_16:
    case TERM_COLOR_8:
    {
        int idx = termcaps_rgb_to_8(r, g, b);
        /* For 16-color, use bright variants for lighter colors */
        if (g_caps.color_level == TERM_COLOR_16 &&
            (r > 200 || g > 200 || b > 200)) {
            snprintf(g_fg_color_buf, sizeof(g_fg_color_buf), "\033[%dm", 90 + idx);
        } else {
            snprintf(g_fg_color_buf, sizeof(g_fg_color_buf), "\033[%dm", 30 + idx);
        }
        break;
    }

    default:
        g_fg_color_buf[0] = '\0';
        break;
    }

    return g_fg_color_buf;
}

/* Format background color escape sequence */
const char *termcaps_format_bg_color(int r, int g, int b)
{
    if (!g_initialized || g_caps.color_level == TERM_COLOR_NONE) {
        g_bg_color_buf[0] = '\0';
        return g_bg_color_buf;
    }

    switch (g_caps.color_level) {
    case TERM_COLOR_TRUECOLOR:
        snprintf(g_bg_color_buf, sizeof(g_bg_color_buf), "\033[48;2;%d;%d;%dm", r,
                 g, b);
        break;

    case TERM_COLOR_256:
    {
        int idx = termcaps_rgb_to_256(r, g, b);
        snprintf(g_bg_color_buf, sizeof(g_bg_color_buf), "\033[48;5;%dm", idx);
        break;
    }

    case TERM_COLOR_16:
    case TERM_COLOR_8:
    {
        int idx = termcaps_rgb_to_8(r, g, b);
        if (g_caps.color_level == TERM_COLOR_16 &&
            (r > 200 || g > 200 || b > 200)) {
            snprintf(g_bg_color_buf, sizeof(g_bg_color_buf), "\033[%dm", 100 + idx);
        } else {
            snprintf(g_bg_color_buf, sizeof(g_bg_color_buf), "\033[%dm", 40 + idx);
        }
        break;
    }

    default:
        g_bg_color_buf[0] = '\0';
        break;
    }

    return g_bg_color_buf;
}

/* Format reset sequence */
const char *termcaps_format_reset(void)
{
    if (!g_initialized || g_caps.color_level == TERM_COLOR_NONE) {
        return "";
    }
    return "\033[0m";
}

/* Human-readable description of capabilities */
const char *termcaps_describe(void)
{
    if (!g_initialized) {
        strncpy(g_describe_buf, "Terminal capabilities not initialized",
                sizeof(g_describe_buf) - 1);
        return g_describe_buf;
    }

    const char *color_names[] = { "none", "8-color", "16-color", "256-color",
                                  "truecolor" };
    const char *unicode_names[] = { "ASCII", "basic (Latin-1)", "full UTF-8" };

    int color_idx = (int)g_caps.color_level;
    int unicode_idx = (int)g_caps.unicode_level;

    if (color_idx < 0 || color_idx > 4)
        color_idx = 0;
    if (unicode_idx < 0 || unicode_idx > 2)
        unicode_idx = 0;

    snprintf(g_describe_buf, sizeof(g_describe_buf),
             "Terminal: %s%s%s\n"
             "Color support: %s\n"
             "Unicode: %s (%s)\n"
             "Detection: %s%s",
             g_caps.term_type[0] ? g_caps.term_type : "(unknown)",
             g_caps.term_program[0] ? " (" : "",
             g_caps.term_program[0] ? g_caps.term_program : "",
             color_names[color_idx], unicode_names[unicode_idx], g_caps.encoding,
             g_caps.detected_from_env ? "environment" : "",
             g_caps.detected_from_query ? "+query" : "");

    /* Close parenthesis if term_program was shown */
    if (g_caps.term_program[0]) {
        size_t len = strlen(g_describe_buf);
        /* Find first newline and insert ) before it */
        char *nl = strchr(g_describe_buf, '\n');
        if (nl) {
            memmove(nl + 1, nl, strlen(nl) + 1);
            *nl = ')';
        }
    }

    return g_describe_buf;
}
