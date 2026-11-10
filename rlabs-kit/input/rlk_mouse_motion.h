/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit: mouse movement resampled to frame times (origin: the Thief Gold Mac port, SoF 2026-11-05).
 *
 * A mouse reports at its own rate (USB 125 Hz, Bluetooth 90-133 Hz with jitter). Summing the reports that arrived
 * since the last frame gives uneven steps at 120 fps: some frames get no report, the next gets two. Instead the
 * reports are kept with their time stamps as a running total, and each frame takes the total as it was one report
 * interval ago, interpolated between reports: the same movement, spread evenly over frame times, one interval late.
 *
 * This version was written on 2026-11-08 for the Soldier of Fortune port; it keeps the earlier kit's
 * behaviour (tests/run-kit-tests.sh checks it).
 */
#ifndef RLK_MOUSE_MOTION_H
#define RLK_MOUSE_MOTION_H

#ifdef __cplusplus
extern "C" {
#endif

#define RLK_MOUSE_MOTION_SAMPLES 64

typedef struct
{
	double t[RLK_MOUSE_MOTION_SAMPLES]; /* report times (seconds), a ring starting at head */
	double x[RLK_MOUSE_MOTION_SAMPLES]; /* running total after each report */
	double y[RLK_MOUSE_MOTION_SAMPLES];
	int head;                           /* oldest kept report */
	int count;                          /* reports kept */
	double dropped_t;                   /* the last report pushed out of the ring (or the reset point) */
	double dropped_x;
	double dropped_y;
	double total_x;                     /* running total of all movement */
	double total_y;
	double interval;                    /* estimated report interval (seconds) */
	double last_t;                      /* the time the last sample was taken at */
	double out_x;                       /* the total handed out so far */
	double out_y;
} rlk_mouse_motion_t;

/* start over at time `now` (seconds), keeping the totals and the interval estimate: after a menu, the console or
   a pause, movement made meanwhile is not replayed */
void rlk_mouse_motion_reset(rlk_mouse_motion_t *m, double now);

/* one mouse report: its time stamp (seconds) and relative movement */
void rlk_mouse_motion_add(rlk_mouse_motion_t *m, double t, double dx, double dy);

/* the movement to apply this frame (taken at `now` minus one report interval, 2-16 ms) */
void rlk_mouse_motion_sample(rlk_mouse_motion_t *m, double now, double *dx, double *dy);

#ifdef __cplusplus
}
#endif

#endif
