/* Default UI color constants for mudlark.
 *
 * These are C-level fallbacks used when the corresponding Lisp defvar
 * (defined in init.lisp) cannot be read.  Keep them in sync.
 *
 * Palette: Dracula (https://draculatheme.com/spec). Only foreground colors
 * live here — no background is ever painted, so a transparent terminal
 * background shows through.
 *
 * Each role carries TWO spellings, because the terminal gets two tiers
 * (no RGB-to-palette math anywhere: see D10 in INLINE-MODE-DESIGN.md):
 *
 *   - the exact Dracula RGB triple, used where boba's profile says the
 *     terminal is truecolor;
 *   - the ANSI16 slot the Dracula terminal themes put that hue in. Slots
 *     0-7 are the base colors, 8-15 the bright variants; the bright slot
 *     is the one that matches the Dracula hexes (bright cyan is #8BE9FD,
 *     bright black is #6272A4, and so on). A role with no slot (-1) simply
 *     has no color below truecolor.
 *
 * A color role is a UiColor, and the tier decision lives in ui_tui_color()
 * and the ui_*_sgr() formatters in colors.c — one place, so no call site
 * can pick the wrong tier or downgrade on its own.
 */

#ifndef MUDLARK_COLORS_H
#define MUDLARK_COLORS_H

#include <stdint.h>

#include <boba/style.h>

/* ------------------------------------------------------------------ */
/* The color role                                                      */
/* ------------------------------------------------------------------ */

/* An RGB triple plus the ANSI16 slot used when the terminal cannot show
 * 24-bit. slot -1 = this role has no color below truecolor. */
typedef struct
{
    uint8_t r, g, b;
    int8_t slot;
} UiColor;

#define UI_COLOR(r, g, b, slot) \
    ((UiColor){ (uint8_t)(r), (uint8_t)(g), (uint8_t)(b), (int8_t)(slot) })

/* ------------------------------------------------------------------ */
/* Dracula palette (RGB components)                                    */
/* ------------------------------------------------------------------ */

/* User input echo — cyan */
#define COLOR_USER_INPUT_R    139
#define COLOR_USER_INPUT_G    233
#define COLOR_USER_INPUT_B    253
#define COLOR_USER_INPUT_SLOT 14 /* Dracula AnsiBrightCyan */

/* Divider — connected (green) */
#define COLOR_DIVIDER_CONNECTED_R    80
#define COLOR_DIVIDER_CONNECTED_G    250
#define COLOR_DIVIDER_CONNECTED_B    123
#define COLOR_DIVIDER_CONNECTED_SLOT 10 /* Dracula AnsiBrightGreen */

/* Divider — disconnected (comment) */
#define COLOR_DIVIDER_DISCONNECTED_R    98
#define COLOR_DIVIDER_DISCONNECTED_G    114
#define COLOR_DIVIDER_DISCONNECTED_B    164
#define COLOR_DIVIDER_DISCONNECTED_SLOT 8 /* Dracula AnsiBrightBlack */

/* Log level colors */
#define COLOR_LOG_DEBUG_R    98
#define COLOR_LOG_DEBUG_G    114
#define COLOR_LOG_DEBUG_B    164
#define COLOR_LOG_DEBUG_SLOT 8 /* Dracula AnsiBrightBlack */

#define COLOR_LOG_INFO_R    139
#define COLOR_LOG_INFO_G    233
#define COLOR_LOG_INFO_B    253
#define COLOR_LOG_INFO_SLOT 14 /* Dracula AnsiBrightCyan */

#define COLOR_LOG_WARN_R    241
#define COLOR_LOG_WARN_G    250
#define COLOR_LOG_WARN_B    140
#define COLOR_LOG_WARN_SLOT 11 /* Dracula AnsiBrightYellow */

#define COLOR_LOG_ERROR_R    255
#define COLOR_LOG_ERROR_G    85
#define COLOR_LOG_ERROR_B    85
#define COLOR_LOG_ERROR_SLOT 9 /* Dracula AnsiBrightRed */

/* ------------------------------------------------------------------ */
/* The roles                                                           */
/* ------------------------------------------------------------------ */

#define UI_COLOR_USER_INPUT                                              \
    UI_COLOR(COLOR_USER_INPUT_R, COLOR_USER_INPUT_G, COLOR_USER_INPUT_B, \
             COLOR_USER_INPUT_SLOT)

#define UI_COLOR_DIVIDER_CONNECTED                                 \
    UI_COLOR(COLOR_DIVIDER_CONNECTED_R, COLOR_DIVIDER_CONNECTED_G, \
             COLOR_DIVIDER_CONNECTED_B, COLOR_DIVIDER_CONNECTED_SLOT)

#define UI_COLOR_DIVIDER_DISCONNECTED                                    \
    UI_COLOR(COLOR_DIVIDER_DISCONNECTED_R, COLOR_DIVIDER_DISCONNECTED_G, \
             COLOR_DIVIDER_DISCONNECTED_B, COLOR_DIVIDER_DISCONNECTED_SLOT)

#define UI_COLOR_LOG_DEBUG                                            \
    UI_COLOR(COLOR_LOG_DEBUG_R, COLOR_LOG_DEBUG_G, COLOR_LOG_DEBUG_B, \
             COLOR_LOG_DEBUG_SLOT)

#define UI_COLOR_LOG_INFO                                          \
    UI_COLOR(COLOR_LOG_INFO_R, COLOR_LOG_INFO_G, COLOR_LOG_INFO_B, \
             COLOR_LOG_INFO_SLOT)

#define UI_COLOR_LOG_WARN                                          \
    UI_COLOR(COLOR_LOG_WARN_R, COLOR_LOG_WARN_G, COLOR_LOG_WARN_B, \
             COLOR_LOG_WARN_SLOT)

#define UI_COLOR_LOG_ERROR                                            \
    UI_COLOR(COLOR_LOG_ERROR_R, COLOR_LOG_ERROR_G, COLOR_LOG_ERROR_B, \
             COLOR_LOG_ERROR_SLOT)

/* ------------------------------------------------------------------ */
/* The tier                                                            */
/* ------------------------------------------------------------------ */

/* Seed the tier from boba's terminal profile. main.c calls this once, right
 * after the flush that starts the capability probe: `truecolor` is
 * environment-derived and final from probe start, so one seed per process
 * describes the whole session. Before it is called the low tier is assumed,
 * which is the safe direction to be wrong in. */
void ui_set_truecolor(int truecolor);

/* 1 = the terminal was reported (or seeded) as truecolor. */
int ui_truecolor(void);

/* The role in the tier in force, for boba styles and row sinks. */
TuiColor ui_tui_color(UiColor c);

/* The role as a raw SGR foreground / background sequence, for byte writers
 * (echo and log lines). Both return a static buffer that the next call to
 * the SAME function overwrites; copy the result if you need to keep it.
 * "" for a role with no color below truecolor. */
const char *ui_fg_sgr(UiColor c);
const char *ui_bg_sgr(UiColor c);

/* The SGR reset both tiers share: "\x1b[0m". */
const char *ui_reset_sgr(void);

#endif /* MUDLARK_COLORS_H */
