/* SPDX-License-Identifier: GPL-2.0-or-later */
/* RLabs kit: variable refresh on macOS Metal. See rlk_vrr.h. Built with -fobjc-arc. */

#import <AppKit/AppKit.h>
#include <stdio.h>

#include "rlk_vrr.h"

int
rlk_vrr_screen_range(void *nswindow, double *slowest_hz, double *fastest_hz)
{
	NSWindow *window = (__bridge NSWindow *)nswindow;
	NSScreen *screen = window ? window.screen : nil;

	if (!screen)
	{
		return 0;
	}

	const NSTimeInterval fastest = screen.minimumRefreshInterval;
	const NSTimeInterval slowest = screen.maximumRefreshInterval;

	if (!(fastest > 0 && slowest > fastest * 1.25))
	{
		return 0;
	}

	if (slowest_hz)
	{
		*slowest_hz = 1.0 / slowest;
	}

	if (fastest_hz)
	{
		*fastest_hz = 1.0 / fastest;
	}

	return 1;
}

int
rlk_vrr_update(void *nswindow, int fullscreen, int enabled, char *line, size_t line_size)
{
	static int last = -1;
	double slowest = 0, fastest = 0;
	const char *why = "screen has no variable refresh";
	const int capable = rlk_vrr_screen_range(nswindow, &slowest, &fastest);

	if (capable)
	{
		why = "windowed";
	}

	const int on = fullscreen && enabled ? capable : 0;

	if (!line || !line_size)
	{
		last = on;
		return on;
	}

	line[0] = 0;

	if (last == on)
	{
		return on;
	}

	last = on;

	if (on)
	{
		snprintf(line, line_size, "display: variable refresh %.0f-%.0f Hz, frames shown when ready", slowest, fastest);
	}
	else
	{
		snprintf(line, line_size, "display: fixed refresh pacing (%s)", enabled ? why : "turned off");
	}

	return on;
}

double
rlk_vrr_interval(int maxfps, double fastest_hz)
{
	const double cap = maxfps > 0 ? (double)maxfps : 120.0;
	const double hz = (fastest_hz < cap && fastest_hz > 0) ? fastest_hz : cap;

	return 1.0 / hz;
}
