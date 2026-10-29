/* Default UI color constants for mudlark.
 *
 * These are C-level fallbacks used when the corresponding Lisp defvar
 * (defined in init.lisp) cannot be read.  Keep them in sync.
 *
 * Palette: Dracula (https://draculatheme.com/spec). Only foreground colors
 * live here — no background is ever painted, so a transparent terminal
 * background shows through.
 */

#ifndef MUDLARK_COLORS_H
#define MUDLARK_COLORS_H

/* User input echo — cyan */
#define COLOR_USER_INPUT_R 139
#define COLOR_USER_INPUT_G 233
#define COLOR_USER_INPUT_B 253

/* Divider — connected (green) */
#define COLOR_DIVIDER_CONNECTED_R 80
#define COLOR_DIVIDER_CONNECTED_G 250
#define COLOR_DIVIDER_CONNECTED_B 123

/* Divider — disconnected (comment) */
#define COLOR_DIVIDER_DISCONNECTED_R 98
#define COLOR_DIVIDER_DISCONNECTED_G 114
#define COLOR_DIVIDER_DISCONNECTED_B 164

/* Log level colors */
#define COLOR_LOG_DEBUG_R 98
#define COLOR_LOG_DEBUG_G 114
#define COLOR_LOG_DEBUG_B 164

#define COLOR_LOG_INFO_R 139
#define COLOR_LOG_INFO_G 233
#define COLOR_LOG_INFO_B 253

#define COLOR_LOG_WARN_R 241
#define COLOR_LOG_WARN_G 250
#define COLOR_LOG_WARN_B 140

#define COLOR_LOG_ERROR_R 255
#define COLOR_LOG_ERROR_G 85
#define COLOR_LOG_ERROR_B 85

#endif /* MUDLARK_COLORS_H */
