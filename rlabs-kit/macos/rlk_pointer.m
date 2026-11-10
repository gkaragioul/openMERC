/* SPDX-License-Identifier: GPL-2.0-or-later */
/* RLabs kit: one pointer over the game window. See rlk_pointer.h. Built with -fobjc-arc. */

#import <AppKit/AppKit.h>
#include <stdio.h>
#include <string.h>

#include "rlk_pointer.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations" /* CGCursorIsVisible: still the only visibility query */

#define MAX_HIDES 4      /* CGDisplayHideCursor nests: never more than this many outstanding */
#define MAX_REPORTS 8    /* "still visible" lines in the log */

static int hides;
static int still_visible_reports;
static NSCursor *blank;

static void
show_all(void)
{
	while (hides > 0)
	{
		CGDisplayShowCursor(kCGNullDirectDisplay);
		hides--;
	}
}

static NSCursor *
blank_cursor(void)
{
	if (!blank)
	{
		/* AppKit's own invisible cursor when it has one (not public API: asked for, not assumed) */
		SEL sel = NSSelectorFromString(@"invisibleCursor");

		if ([NSCursor respondsToSelector:sel])
		{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
			blank = [NSCursor performSelector:sel];
#pragma clang diagnostic pop
		}
	}

	if (!blank)
	{
		/* a fully transparent 16x16 picture */
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:16 pixelsHigh:16
			bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
			bytesPerRow:64 bitsPerPixel:32];
		memset(rep.bitmapData, 0, 16 * 64);
		NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
		[image addRepresentation:rep];
		blank = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
	}

	return blank;
}

void
rlk_pointer_update(void *nswindow, int focused)
{
	@autoreleasepool
	{
		NSWindow *window = (__bridge NSWindow *)nswindow;

		if (window && focused && NSApp.isActive && window.isKeyWindow &&
			NSPointInRect(NSEvent.mouseLocation, window.frame))
		{
			NSCursor *cursor = blank_cursor();

			if (NSCursor.currentCursor != cursor)
			{
				[cursor set];
			}

			if (CGCursorIsVisible() && hides < MAX_HIDES)
			{
				CGDisplayHideCursor(kCGNullDirectDisplay);
				hides++;

				if (CGCursorIsVisible() && still_visible_reports < MAX_REPORTS)
				{
					still_visible_reports++;
					fprintf(stderr, "[POINTER] still visible after hiding (hides=%d)\n", hides);
				}
			}
		}
		else
		{
			show_all();
		}
	}
}

void
rlk_pointer_release(void)
{
	show_all();
}

int
rlk_pointer_hides(void)
{
	return hides;
}

int
rlk_pointer_still_visible_reports(void)
{
	return still_visible_reports;
}
