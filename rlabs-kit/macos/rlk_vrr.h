/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit: variable refresh (VRR) on macOS Metal (play-test 2026-11-05: "add vrr if it will help"). On ProMotion and
 * Adaptive-Sync screens in full screen, present each frame after a minimum duration instead of on whole refreshes:
 * a frame that misses its interval shows a few ms later instead of a whole refresh later, and a 144 Hz VRR screen
 * shows 120 fps without switching the screen to 120 Hz. A fixed screen mode would turn Adaptive-Sync off, so a VRR
 * screen in full screen is left in its own mode (the caller skips rlk_display_match_refresh).
 * Method: in full screen, present each frame after a minimum duration.
 *
 * This version was written on 2026-11-08 for the Soldier of Fortune port; it keeps the earlier kit's
 * behaviour and log lines.
 */
#ifndef RLK_VRR_H
#define RLK_VRR_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when the screen of `nswindow` (an NSWindow *) has a variable refresh range (its longest refresh interval more
   than 1.25 times its shortest); the range in Hz goes to slowest_hz / fastest_hz (either may be NULL) */
int rlk_vrr_screen_range(void *nswindow, double *slowest_hz, double *fastest_hz);

/* whether to present with a minimum duration now: full screen, `enabled` (r_vrr and vsync) and a VRR screen. When
   the answer changes and `line` is given, a log line for it ("display: variable refresh 48-120 Hz, frames shown
   when ready" / "display: fixed refresh pacing (windowed)"); otherwise line is "" */
int rlk_vrr_update(void *nswindow, int fullscreen, int enabled, char *line, size_t line_size);

/* the minimum duration between frames: 1 / the frame cap (maxfps, or 120 when 0), or 1 / the screen's fastest
   refresh when that is lower */
double rlk_vrr_interval(int maxfps, double fastest_hz);

#ifdef __cplusplus
}
#endif

#endif
