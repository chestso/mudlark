/* Default UI color constants for mudlark.
 *
 * These are C-level fallbacks used when the corresponding Lisp defvar
 * (defined in init.lisp) cannot be read.  Keep them in sync.
 */

#ifndef MUDLARK_COLORS_H
#define MUDLARK_COLORS_H

/* User input echo */
#define COLOR_USER_INPUT_R 255
#define COLOR_USER_INPUT_G 215
#define COLOR_USER_INPUT_B 0

/* Divider — connected */
#define COLOR_DIVIDER_CONNECTED_R 37
#define COLOR_DIVIDER_CONNECTED_G 160
#define COLOR_DIVIDER_CONNECTED_B 101

/* Divider — disconnected */
#define COLOR_DIVIDER_DISCONNECTED_R 88
#define COLOR_DIVIDER_DISCONNECTED_G 88
#define COLOR_DIVIDER_DISCONNECTED_B 88

/* Log level colors */
#define COLOR_LOG_DEBUG_R 128
#define COLOR_LOG_DEBUG_G 128
#define COLOR_LOG_DEBUG_B 128

#define COLOR_LOG_INFO_R 128
#define COLOR_LOG_INFO_G 128
#define COLOR_LOG_INFO_B 128

#define COLOR_LOG_WARN_R 255
#define COLOR_LOG_WARN_G 200
#define COLOR_LOG_WARN_B 0

#define COLOR_LOG_ERROR_R 255
#define COLOR_LOG_ERROR_G 80
#define COLOR_LOG_ERROR_B 80

#endif /* MUDLARK_COLORS_H */
