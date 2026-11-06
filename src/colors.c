/* colors.c - the one place a color role becomes a terminal fact.
 *
 * Two tiers, no approximations (D10 in INLINE-MODE-DESIGN.md):
 *
 *   truecolor  the role's exact RGB triple -> 38;2;r;g;b / TUI_COLOR_RGB
 *   otherwise  the role's ANSI16 slot       -> 3n/9n        / TUI_COLOR_ANSI16
 *
 * The tier is boba's answer (`profile.truecolor`), seeded once by main.c
 * after the flush that starts the capability probe. Nothing here detects a
 * terminal, converts RGB to a palette index, or inspects the environment:
 * one authority per fact.
 */

#include "colors.h"
#include <stdio.h>

static int g_truecolor = 0;

void ui_set_truecolor(int truecolor) { g_truecolor = truecolor ? 1 : 0; }

int ui_truecolor(void) { return g_truecolor; }

TuiColor ui_tui_color(UiColor c)
{
    if (g_truecolor)
        return tui_color_rgb(c.r, c.g, c.b);
    if (c.slot >= 0)
        return tui_color_ansi(c.slot);
    return tui_color_none();
}

/* One SGR formatter for both foreground and background: `bg` picks the
 * 48/40/100 base and the 38/30/90 otherwise. Slots 8-15 are the bright
 * variants, which SGR spells as 90-97 / 100-107. */
static const char *ui_sgr(UiColor c, int bg, char *buf, size_t cap)
{
    if (g_truecolor) {
        snprintf(buf, cap, "\x1b[%d;2;%d;%d;%dm", bg ? 48 : 38, (int)c.r,
                 (int)c.g, (int)c.b);
        return buf;
    }
    if (c.slot < 0)
        return "";
    int slot = (int)c.slot & 0x0f;
    int base = slot < 8 ? (bg ? 40 : 30) : (bg ? 100 : 90);
    snprintf(buf, cap, "\x1b[%dm", base + (slot & 0x07));
    return buf;
}

const char *ui_fg_sgr(UiColor c)
{
    static char buf[32];
    return ui_sgr(c, 0, buf, sizeof(buf));
}

const char *ui_bg_sgr(UiColor c)
{
    static char buf[32];
    return ui_sgr(c, 1, buf, sizeof(buf));
}

const char *ui_reset_sgr(void) { return "\x1b[0m"; }
