/* SPDX-License-Identifier: GPL-2.0-or-later */
/* RLabs kit: screen refresh matched to the frame cap. See rlk_display.h. Built with -fobjc-arc. */

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdio.h>

#include "rlk_display.h"

static bool switched;

void
rlk_display_restore(void)
{
	if (switched)
	{
		CGRestorePermanentDisplayConfiguration();
		switched = false;
	}
}

static CGDirectDisplayID
window_display(NSWindow *window)
{
	NSScreen *screen = window.screen ? window.screen : NSScreen.mainScreen;
	NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];

	return number ? number.unsignedIntValue : 0;
}

long
rlk_display_match_refresh(void *nswindow, int fps, char *line, size_t line_size)
{
	long result = 0;

	if (line && line_size)
	{
		line[0] = 0;
	}

	@autoreleasepool
	{
		NSWindow *window = (__bridge NSWindow *)nswindow;

		if (!window)
		{
			if (line)
			{
				snprintf(line, line_size, "display: no window to read the screen from");
			}
			return 0;
		}

		if (fps <= 0 && switched)
		{
			if (line)
			{
				snprintf(line, line_size, "display: refresh restored");
			}
			rlk_display_restore();
		}

		const CGDirectDisplayID display = window_display(window);

		if (!display)
		{
			if (line)
			{
				snprintf(line, line_size, "display: the window's screen is unknown");
			}
			return 0;
		}

		CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);

		if (!current)
		{
			if (line)
			{
				snprintf(line, line_size, "display: no mode for screen %u", display);
			}
			return 0;
		}

		const long hz = lround(CGDisplayModeGetRefreshRate(current));
		result = hz;

		if (fps < 1 || hz < 1 || hz % fps == 0)
		{
			if (fps >= 1 && line && !line[0])
			{
				snprintf(line, line_size, "display: %ld Hz, which %d fps divides; left as is", hz, fps);
			}
			CGDisplayModeRelease(current);
			return result;
		}

		/* the fastest mode of the same size (points and pixels, usable for the desktop) that fps divides */
		const void *keys[] = {kCGDisplayShowDuplicateLowResolutionModes};
		const void *values[] = {kCFBooleanTrue};
		CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
			&kCFTypeDictionaryValueCallBacks);
		CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, options);
		CFRelease(options);
		CGDisplayModeRef best = NULL;
		long best_hz = 0;

		if (modes)
		{
			for (CFIndex i = 0; i < CFArrayGetCount(modes); i++)
			{
				CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
				const double rate = CGDisplayModeGetRefreshRate(mode);

				if (CGDisplayModeGetWidth(mode) != CGDisplayModeGetWidth(current) ||
					CGDisplayModeGetHeight(mode) != CGDisplayModeGetHeight(current) ||
					CGDisplayModeGetPixelWidth(mode) != CGDisplayModeGetPixelWidth(current) ||
					CGDisplayModeGetPixelHeight(mode) != CGDisplayModeGetPixelHeight(current) ||
					!CGDisplayModeIsUsableForDesktopGUI(mode))
				{
					continue;
				}

				const long mode_hz = lround(rate);

				if (mode_hz >= 1 && mode_hz % fps == 0 && mode_hz > best_hz)
				{
					best = mode;
					best_hz = mode_hz;
				}
			}

			if (best)
			{
				CGDisplayModeRetain(best);
			}

			CFRelease(modes);
		}

		if (!best)
		{
			if (line)
			{
				snprintf(line, line_size, "display: %ld Hz has no mode that %d fps divides; left as is", hz, fps);
			}
			CGDisplayModeRelease(current);
			return result;
		}

		CGDisplayConfigRef config;

		if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess)
		{
			if (line)
			{
				snprintf(line, line_size, "display: %ld Hz has no mode that %d fps divides; left as is", hz, fps);
			}
		}
		else
		{
			CGConfigureDisplayWithDisplayMode(config, display, best, NULL);
			const CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
			const long new_hz = lround(CGDisplayModeGetRefreshRate(best));

			if (err == kCGErrorSuccess)
			{
				switched = true;
				result = new_hz;
			}

			if (line)
			{
				snprintf(line, line_size, "display: %ld Hz to %ld Hz while the game runs (%s)", hz, new_hz,
					err == kCGErrorSuccess ? "done" : "failed");
			}
		}

		CGDisplayModeRelease(best);
		CGDisplayModeRelease(current);
	}

	return result;
}
