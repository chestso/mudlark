/* colors.c - the one place a color role becomes a terminal fact.
 *
 * Two tiers, no approximations (D10 in INLINE-MODE-DESIGN.md):
 *
 *   truecolor  the role's exact RGB triple -> 38;2;r;g;b / TUI_COLOR_RGB
 *   otherwise  the role's ANSI16 slot       -> 3n/9n        / TUI_COLOR_ANSI16
 *
 * The tier is boba's answer (`profile.truecolor`), read from the terminal
 * profile main.c registers once the runtime exists — and from a hand-built
 * profile in tests. Nothing here detects a terminal, converts RGB to a
 * palette index, or inspects the environment: one authority per fact. The
 * SGR spelling is boba's too: tui_color_format_fg/bg turn the chosen
 * carrier into bytes, so the bright-slot arithmetic is written once, in
 * the library that already owns the sequences.
 */

#include "colors.h"

#include <boba/ansi_sequences.h>

static const TuiTerminalProfile *g_profile = NULL;

void ui_set_terminal_profile(const TuiTerminalProfile *profile)
{
    g_profile = profile;
}

int ui_truecolor(void) { return g_profile ? g_profile->truecolor : 0; }

TuiColor ui_tui_color(UiColor c)
{
    if (ui_truecolor())
        return tui_color_rgb(c.r, c.g, c.b);
    if (c.slot >= 0)
        return tui_color_ansi(c.slot);
    return tui_color_none();
}

const char *ui_fg_sgr(UiColor c)
{
    static char buf[32];
    return tui_color_format_fg(ui_tui_color(c), buf, sizeof buf) ? buf : "";
}

const char *ui_bg_sgr(UiColor c)
{
    static char buf[32];
    return tui_color_format_bg(ui_tui_color(c), buf, sizeof buf) ? buf : "";
}

const char *ui_reset_sgr(void) { return SGR_RESET; }
