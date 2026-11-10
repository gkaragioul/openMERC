/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit: run the game's screen at a refresh the frame cap divides (design decision 2026-11-03, Time Crisis and
 * Thief: a 144 Hz screen shows a 120 fps cap unevenly; at 120 Hz every frame is shown for one refresh). The switch
 * is for this app only (kCGConfigureForAppOnly): macOS puts the screen back when the game quits.
 *
 * This version was written on 2026-11-08 for the Soldier of Fortune port; it keeps the earlier kit's
 * behaviour and log lines.
 */
#ifndef RLK_DISPLAY_H
#define RLK_DISPLAY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Switch the screen of `nswindow` (NSWindow *; its screen, else the main screen) to the fastest mode of the same
   size whose refresh `fps` divides, when the current refresh is not already divisible. `fps` <= 0 restores a
   switched screen. Returns the refresh now in effect (Hz), or 0 when the screen could not be read; a log line goes
   to `line` (may be NULL), "" when there is nothing to say. */
long rlk_display_match_refresh(void *nswindow, int fps, char *line, size_t line_size);

/* put the screen back if this process switched it */
void rlk_display_restore(void);

#ifdef __cplusplus
}
#endif

#endif
