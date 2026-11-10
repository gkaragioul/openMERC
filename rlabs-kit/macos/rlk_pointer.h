/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit: one pointer over the game window (origin: the Thief Gold Mac port). Games draw
 * their own cursor; the macOS arrow must not show over the focused game window, and must come back everywhere else.
 * While the app is active, its window is key and the pointer is inside the window frame: a blank cursor is set and
 * the arrow is hidden with CGDisplayHideCursor (counted, at most 4 deep); otherwise every hide is undone.
 *
 * This version was written on 2026-11-08 for the Soldier of Fortune port; it keeps the earlier kit's
 * behaviour and log lines.
 */
#ifndef RLK_POINTER_H
#define RLK_POINTER_H

#ifdef __cplusplus
extern "C" {
#endif

/* every frame: `nswindow` the game's NSWindow * (may be NULL), `focused` whether it has input focus */
void rlk_pointer_update(void *nswindow, int focused);

/* show the arrow again (before the window goes away) */
void rlk_pointer_release(void);

/* for logs and tests: hides now in effect, and how often the arrow stayed visible right after a hide */
int rlk_pointer_hides(void);
int rlk_pointer_still_visible_reports(void);

#ifdef __cplusplus
}
#endif

#endif
