/* test_terminal_caps.c - Color-tier degradation tests
 *
 * mudlark's UI palette is Dracula.  A truecolor terminal gets the exact RGB;
 * below that the color has to collapse into the palette the terminal actually
 * owns, and the collapse is the interesting part: the old threshold mapping
 * turned Dracula's cyan into white and its purple into magenta on 8- and
 * 16-color terminals.  These tests pin the collapse to "the slot that carries
 * the hue", so the palette stays recognizable at every color depth.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../include/terminal_caps.h"

#ifdef _WIN32
#define setenv(name, value, overwrite) _putenv_s((name), (value))
#define unsetenv(name)                 _putenv_s((name), "")
#endif

static int tests_run = 0;
static int tests_passed = 0;

#define RUN_TEST(fn)                 \
    do {                             \
        tests_run++;                 \
        fn();                        \
        tests_passed++;              \
        printf("  PASS: %s\n", #fn); \
    } while (0)

#define CHECK(cond)                                                \
    do {                                                           \
        if (!(cond)) {                                             \
            fprintf(stderr, "\n    FAILED: %s (line %d)\n", #cond, \
                    __LINE__);                                     \
            exit(1);                                               \
        }                                                          \
    } while (0)

#define CHECK_STR(actual, expected)                                              \
    do {                                                                         \
        const char *a_ = (actual);                                               \
        const char *e_ = (expected);                                             \
        if (strcmp(a_, e_) != 0) {                                               \
            fprintf(stderr, "\n    FAILED: got \"%s\", want \"%s\" (line %d)\n", \
                    a_, e_, __LINE__);                                           \
            exit(1);                                                             \
        }                                                                        \
    } while (0)

/* Force a color level through the environment the detector reads. */
static void use_color_level(const char *term, const char *colorterm)
{
    setenv("TERM", term, 1);
    unsetenv("TERM_PROGRAM");
    unsetenv("WT_SESSION");
    if (colorterm) {
        setenv("COLORTERM", colorterm, 1);
    } else {
        unsetenv("COLORTERM");
    }
    termcaps_refresh();
}

/* ======================================================================== */

/* Dracula's own colors sit exactly on the ANSI slots the spec names them by,
 * so a 16-color terminal shows them as the slot carrying the same hue. */
static void test_rgb_to_16_lands_on_hue_slot(void)
{
    CHECK(termcaps_rgb_to_16(0xFF, 0x55, 0x55) == 1); /* red */
    CHECK(termcaps_rgb_to_16(0x50, 0xFA, 0x7B) == 2); /* green */
    CHECK(termcaps_rgb_to_16(0xF1, 0xFA, 0x8C) == 3); /* yellow */
    CHECK(termcaps_rgb_to_16(0xBD, 0x93, 0xF9) == 4); /* blue */
    CHECK(termcaps_rgb_to_16(0xFF, 0x79, 0xC6) == 5); /* magenta */
    CHECK(termcaps_rgb_to_16(0x8B, 0xE9, 0xFD) == 6); /* cyan */
    CHECK(termcaps_rgb_to_16(0xF8, 0xF8, 0xF2) == 7); /* white */
    CHECK(termcaps_rgb_to_16(0x62, 0x72, 0xA4) == 8); /* bright black */
}

/* Colors the spec derives (no ANSI slot of their own) pick the nearest one. */
static void test_rgb_to_16_derived_colors(void)
{
    CHECK(termcaps_rgb_to_16(0xFF, 0xB8, 0x6C) == 3);  /* orange -> yellow */
    CHECK(termcaps_rgb_to_16(0x28, 0x2A, 0x36) == 0);  /* background -> black */
    CHECK(termcaps_rgb_to_16(0xA4, 0xFF, 0xFF) == 14); /* bright cyan */
}

/* On an 8-color terminal the bright half is gone, but the hue must survive:
 * purple stays blue, cyan stays cyan (this is what the old threshold mapping
 * got wrong — both came out as white). */
static void test_rgb_to_8_keeps_hue(void)
{
    CHECK(termcaps_rgb_to_8(0xBD, 0x93, 0xF9) == 4); /* purple -> blue */
    CHECK(termcaps_rgb_to_8(0x8B, 0xE9, 0xFD) == 6); /* cyan */
    CHECK(termcaps_rgb_to_8(0xFF, 0xB8, 0x6C) == 3); /* orange -> yellow */
    CHECK(termcaps_rgb_to_8(0x50, 0xFA, 0x7B) == 2); /* green */
}

/* Truecolor sends the exact palette value. */
static void test_format_truecolor_passthrough(void)
{
    use_color_level("xterm-256color", "truecolor");
    CHECK(termcaps_supports_truecolor());
    CHECK_STR(termcaps_format_fg_color(0x8B, 0xE9, 0xFD), "\033[38;2;139;233;253m");
    CHECK_STR(termcaps_format_bg_color(0x8B, 0xE9, 0xFD), "\033[48;2;139;233;253m");
}

/* 256-color uses the palette index, never a 24-bit sequence. */
static void test_format_256color_uses_index(void)
{
    char expected[32];
    use_color_level("xterm-256color", NULL);
    CHECK(termcaps_get_color_level() == TERM_COLOR_256);
    snprintf(expected, sizeof(expected), "\033[38;5;%dm",
             termcaps_rgb_to_256(0x8B, 0xE9, 0xFD));
    CHECK_STR(termcaps_format_fg_color(0x8B, 0xE9, 0xFD), expected);
}

/* 16-color uses base SGR 30-37 and bright SGR 90-97. */
static void test_format_16color_uses_sgr(void)
{
    use_color_level("xterm-color", NULL);
    CHECK(termcaps_get_color_level() == TERM_COLOR_16);
    CHECK_STR(termcaps_format_fg_color(0x8B, 0xE9, 0xFD), "\033[36m");
    CHECK_STR(termcaps_format_bg_color(0x8B, 0xE9, 0xFD), "\033[46m");
    /* A color landing in the bright half uses the 90-97 range. */
    CHECK_STR(termcaps_format_fg_color(0xA4, 0xFF, 0xFF), "\033[96m");
    CHECK_STR(termcaps_format_bg_color(0xA4, 0xFF, 0xFF), "\033[106m");
}

/* 8-color stays in 30-37/40-47 even for a bright color. */
static void test_format_8color_stays_base(void)
{
    use_color_level("unknownterm", NULL);
    CHECK(termcaps_get_color_level() == TERM_COLOR_8);
    CHECK_STR(termcaps_format_fg_color(0xBD, 0x93, 0xF9), "\033[34m");
    CHECK_STR(termcaps_format_bg_color(0xBD, 0x93, 0xF9), "\033[44m");
}

/* No color support means no escape sequence at all. */
static void test_format_none_is_empty(void)
{
    use_color_level("dumb", NULL);
    CHECK(termcaps_get_color_level() == TERM_COLOR_NONE);
    CHECK_STR(termcaps_format_fg_color(0x8B, 0xE9, 0xFD), "");
    CHECK_STR(termcaps_format_bg_color(0x8B, 0xE9, 0xFD), "");
    CHECK_STR(termcaps_format_reset(), "");
}

/* ======================================================================== */

int main(void)
{
    printf("terminal_caps tests:\n");

    RUN_TEST(test_rgb_to_16_lands_on_hue_slot);
    RUN_TEST(test_rgb_to_16_derived_colors);
    RUN_TEST(test_rgb_to_8_keeps_hue);
    RUN_TEST(test_format_truecolor_passthrough);
    RUN_TEST(test_format_256color_uses_index);
    RUN_TEST(test_format_16color_uses_sgr);
    RUN_TEST(test_format_8color_stays_base);
    RUN_TEST(test_format_none_is_empty);

    printf("\n%d/%d tests passed.\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
