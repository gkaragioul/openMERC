/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit check: prints what the kit answers for a fixed set of inputs. run-kit-tests.sh links it once with the
 * kit sources and once with the old compiled kit objects and compares the two outputs line by line.
 * Nothing here changes the screen: the refresh switch is only asked with frame caps the current refresh already
 * divides (and fps <= 0), the pointer only with conditions that keep it shown.
 */
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "rlk_display.h"
#include "rlk_hud.h"
#include "rlk_mouse_motion.h"
#include "rlk_pointer.h"
#include "rlk_vrr.h"

static uint64_t rng = 0x9e3779b97f4a7c15ull;

static double
uniform(void) /* xorshift64*, [0, 1) */
{
	rng ^= rng >> 12;
	rng ^= rng << 25;
	rng ^= rng >> 27;
	return (double)((rng * 2685821657736338717ull) >> 11) / 9007199254740992.0;
}

/* one mouse session: reports every `report` s (+- jitter), frames every `frame` s (+- jitter) */
static void
mouse_session(const char *name, double report, double rjitter, double frame, double fjitter, double seconds,
	int pause_every)
{
	rlk_mouse_motion_t m;
	double next_report = 0.001, next_frame = 0.004, t = 0, sx = 0, sy = 0, gx = 0, gy = 0;
	int frames = 0, reports = 0;

	memset(&m, 0, sizeof m);
	rlk_mouse_motion_reset(&m, 0);

	while (t < seconds)
	{
		if (next_report <= next_frame)
		{
			t = next_report;
			const double dx = (uniform() - 0.3) * 8, dy = (uniform() - 0.5) * 3;
			rlk_mouse_motion_add(&m, t, dx, dy);
			gx += dx, gy += dy, reports++;
			next_report += report + (uniform() - 0.5) * 2 * rjitter;
			if (pause_every && reports % pause_every == 0)
			{
				next_report += 0.2; /* the hand stops */
			}
		}
		else
		{
			double dx, dy;
			t = next_frame;
			if (pause_every && frames % 97 == 96)
			{
				rlk_mouse_motion_reset(&m, t); /* back from a menu */
				dx = dy = 0;
			}
			else
			{
				rlk_mouse_motion_sample(&m, t, &dx, &dy);
			}
			sx += dx, sy += dy, frames++;
			printf("mouse %s %d %a %a %a\n", name, frames, dx, dy, m.interval);
			next_frame += frame + (uniform() - 0.5) * 2 * fjitter;
		}
	}

	printf("mouse %s total %a %a reports %a %a\n", name, sx, sy, gx, gy);
}

static void
mouse_tests(void)
{
	mouse_session("usb125_fps120", 0.008, 0.0005, 1.0 / 120, 0.0003, 3, 0);
	mouse_session("bt90_fps120", 1.0 / 90, 0.003, 1.0 / 120, 0.0003, 3, 0);
	mouse_session("hz1000_fps60", 0.001, 0.0001, 1.0 / 60, 0.002, 2, 0);
	mouse_session("usb125_fps144_pauses", 0.008, 0.001, 1.0 / 144, 0.0005, 4, 50);
	mouse_session("slow_frames", 0.008, 0.0005, 0.05, 0.02, 3, 0);

	{ /* odd inputs: equal and backwards time stamps, no reports, a fresh struct sampled first */
		rlk_mouse_motion_t m;
		double dx, dy;
		memset(&m, 0, sizeof m);
		rlk_mouse_motion_sample(&m, 1.0, &dx, &dy);
		printf("mouse odd fresh %a %a %a\n", dx, dy, m.last_t);
		rlk_mouse_motion_add(&m, 1.0, 3, 4);
		rlk_mouse_motion_add(&m, 1.0, 3, 4);
		rlk_mouse_motion_add(&m, 0.99, 1, 1);
		rlk_mouse_motion_sample(&m, 1.02, &dx, &dy);
		printf("mouse odd same %a %a %a\n", dx, dy, m.interval);
		rlk_mouse_motion_sample(&m, 1.00, &dx, &dy);
		printf("mouse odd back %a %a\n", dx, dy);
		for (int i = 0; i < 200; i++)
		{
			rlk_mouse_motion_add(&m, 1.1 + i * 0.0001, 1, -1); /* more than the ring holds */
		}
		rlk_mouse_motion_sample(&m, 1.11, &dx, &dy);
		printf("mouse odd ring %a %a %d %d\n", dx, dy, m.head, m.count);
		rlk_mouse_motion_sample(&m, 1.2, &dx, &dy);
		printf("mouse odd ring2 %a %a\n", dx, dy);
	}
}

static void
vrr_tests(NSWindow *window)
{
	const int caps[] = {-1, 0, 1, 30, 60, 90, 119, 120, 144, 240};
	const double fastest[] = {-5, 0, 24, 48, 60, 90, 119.88, 120, 144, 165, 240, 1e9};
	char line[160];

	for (size_t i = 0; i < sizeof caps / sizeof caps[0]; i++)
	{
		for (size_t j = 0; j < sizeof fastest / sizeof fastest[0]; j++)
		{
			printf("vrr interval %d %g %a\n", caps[i], fastest[j], rlk_vrr_interval(caps[i], fastest[j]));
		}
	}

	{
		double s = -1, f = -1;
		const int r0 = rlk_vrr_screen_range(NULL, &s, &f);
		printf("vrr range null %d %a %a\n", r0, s, f);
		s = f = -1;
		const int r1 = rlk_vrr_screen_range((__bridge void *)window, &s, &f);
		printf("vrr range window %d %a %a\n", r1, s, f);
		printf("vrr range window nullptrs %d\n", rlk_vrr_screen_range((__bridge void *)window, NULL, NULL));
	}

	{
		const int seq[][3] = {{1, 1, 1}, {1, 1, 1}, {0, 1, 1}, {1, 0, 1}, {1, 1, 0}, {0, 0, 1}, {1, 1, 1}, {0, 1, 0},
			{0, 1, 1}};
		for (size_t i = 0; i < sizeof seq / sizeof seq[0]; i++)
		{
			strcpy(line, "untouched");
			const int on = rlk_vrr_update((__bridge void *)window, seq[i][0], seq[i][1], seq[i][2] ? line : NULL,
				seq[i][2] ? sizeof line : 0);
			printf("vrr update %zu fs=%d en=%d -> %d \"%s\"\n", i, seq[i][0], seq[i][1], on, seq[i][2] ? line : "-");
		}
		strcpy(line, "untouched");
		printf("vrr update null -> %d \"%s\"\n", rlk_vrr_update(NULL, 1, 1, line, sizeof line), line);
	}
}

static void
display_tests(NSWindow *window)
{
	char line[160];
	CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
	const long hz = mode ? lround(CGDisplayModeGetRefreshRate(mode)) : 0;

	if (mode)
	{
		CGDisplayModeRelease(mode);
	}

	strcpy(line, "untouched");
	printf("display null -> %ld \"%s\"\n", rlk_display_match_refresh(NULL, 120, line, sizeof line), line);
	strcpy(line, "untouched");
	printf("display fps0 -> %ld \"%s\"\n", rlk_display_match_refresh((__bridge void *)window, 0, line, sizeof line), line);
	printf("display fps-1 noline -> %ld\n", rlk_display_match_refresh((__bridge void *)window, -1, NULL, 0));

	/* only frame caps the current refresh divides: nothing is switched */
	const long divisors[] = {1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 24, 30, 40, 48, 60, 72, 120, 144, 165, 240};
	for (size_t i = 0; hz > 0 && i < sizeof divisors / sizeof divisors[0]; i++)
	{
		if (hz % divisors[i] == 0)
		{
			strcpy(line, "untouched");
			printf("display fps%ld -> %ld \"%s\"\n", divisors[i],
				rlk_display_match_refresh((__bridge void *)window, (int)divisors[i], line, sizeof line), line);
		}
	}

	rlk_display_restore(); /* nothing switched: nothing to do */
	printf("display restore done\n");
}

static void
hud_tests(void)
{
	const char *values[] = {NULL, "1", "10", "0", "", "1", "1"}; /* odd index: on, even: off */
	CAMetalLayer *layer = [CAMetalLayer layer];

	for (size_t i = 0; i < sizeof values / sizeof values[0]; i++)
	{
		if (values[i])
		{
			setenv("MTL_HUD_ENABLED", values[i], 1);
		}
		else
		{
			unsetenv("MTL_HUD_ENABLED");
		}
		printf("hud available \"%s\" %d\n", values[i] ? values[i] : "(unset)", rlk_hud_available());
		fflush(stdout);
		rlk_hud_set((__bridge void *)layer, (int)(i & 1));
		fflush(stderr);
		rlk_hud_set(NULL, 1);
		NSDictionary *p = layer.developerHUDProperties;
		printf("hud layer mode %s\n", p ? [[p description] UTF8String] : "(none)");
	}
}

static void
pointer_tests(NSWindow *window)
{
	/* this test process is never the active app: every call must leave the pointer shown */
	rlk_pointer_update(NULL, 1);
	rlk_pointer_update((__bridge void *)window, 0);
	rlk_pointer_update((__bridge void *)window, 1);
	rlk_pointer_release();
	printf("pointer hides %d reports %d\n", rlk_pointer_hides(), rlk_pointer_still_visible_reports());
}

int
main(void)
{
	@autoreleasepool
	{
		[NSApplication sharedApplication];
		NSRect frame = NSScreen.mainScreen.frame;
		NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(frame.origin.x + 10, frame.origin.y + 10,
			64, 64) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
		window.releasedWhenClosed = NO;

		setvbuf(stdout, NULL, _IOLBF, 0);
		mouse_tests();
		vrr_tests(window);
		display_tests(window);
		hud_tests();
		pointer_tests(window);
		printf("end\n");
	}
	return 0;
}
