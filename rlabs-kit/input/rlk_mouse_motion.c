/* SPDX-License-Identifier: GPL-2.0-or-later */
/* RLabs kit: mouse movement resampled to frame times. See rlk_mouse_motion.h. */

#include <math.h>
#include <string.h>

#include "rlk_mouse_motion.h"

#define N RLK_MOUSE_MOTION_SAMPLES
#define DEFAULT_INTERVAL 0.008 /* 125 Hz, until reports say otherwise */

void
rlk_mouse_motion_reset(rlk_mouse_motion_t *m, double now)
{
	const double x = m->total_x, y = m->total_y;
	const double interval = m->interval > 0 ? m->interval : DEFAULT_INTERVAL;

	memset(m, 0, sizeof *m);
	m->out_x = m->dropped_x = m->total_x = x;
	m->out_y = m->dropped_y = m->total_y = y;
	m->last_t = m->dropped_t = now;
	m->interval = interval;
}

void
rlk_mouse_motion_add(rlk_mouse_motion_t *m, double t, double dx, double dy)
{
	int n, i;

	if (!(m->interval > 0))
	{
		m->interval = DEFAULT_INTERVAL;
	}

	n = m->count;

	if (n > 0)
	{
		/* follow the mouse's report rate: gaps of 0.5-50 ms, 10% per report */
		const double dt = t - m->t[(m->head + n - 1) % N];

		if (dt > 0.0005 && dt < 0.05)
		{
			m->interval = fma(m->interval, 0.9, dt * 0.1);
		}

		if (n == N)
		{
			m->dropped_t = m->t[m->head];
			m->dropped_x = m->x[m->head];
			m->dropped_y = m->y[m->head];
			m->head = (m->head + 1) % N;
			n = N - 1;
		}
	}

	m->total_x += dx;
	m->total_y += dy;
	m->count = n + 1;
	i = (m->head + n) % N;
	m->t[i] = t;
	m->x[i] = m->total_x;
	m->y[i] = m->total_y;
}

void
rlk_mouse_motion_sample(rlk_mouse_motion_t *m, double now, double *dx, double *dy)
{
	double interval = m->interval > 0 ? m->interval : DEFAULT_INTERVAL;
	double target, x = m->dropped_x, y = m->dropped_y;
	int k;

	if (interval < 0.002)
	{
		interval = 0.002;
	}

	if (interval > 0.016)
	{
		interval = 0.016;
	}

	target = now - interval;

	if (target < m->last_t)
	{
		target = m->last_t; /* never back in time */
	}

	/* newest report first: at or after a report, its total; between two reports, interpolated (a report's movement
	   is spread over at most one interval before it, so a pause is not stretched into slow motion) */
	for (k = m->count - 1; k >= 0; k--)
	{
		const int j = (m->head + k) % N;
		const int p = k > 0 ? (m->head + k - 1) % N : -1;
		double pt;

		if (target >= m->t[j])
		{
			x = m->x[j];
			y = m->y[j];
			break;
		}

		pt = p >= 0 ? m->t[p] : m->dropped_t;

		if (m->t[j] - pt > interval)
		{
			pt = m->t[j] - interval;
		}

		if (target > pt)
		{
			const double px = p >= 0 ? m->x[p] : m->dropped_x;
			const double py = p >= 0 ? m->y[p] : m->dropped_y;
			const double f = (target - pt) / (m->t[j] - pt);

			x = fma(m->x[j] - px, f, px);
			y = fma(m->y[j] - py, f, py);
			break;
		}
	}

	*dx = x - m->out_x;
	*dy = y - m->out_y;
	m->last_t = target;
	m->out_x = x;
	m->out_y = y;
}
