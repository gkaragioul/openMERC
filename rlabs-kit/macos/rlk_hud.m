/* SPDX-License-Identifier: GPL-2.0-or-later */
/* RLabs kit: Metal Performance HUD switch. See rlk_hud.h. Built with -fobjc-arc. */

#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>

#include "rlk_hud.h"

static int
hud_enabled(void)
{
	const char *e = getenv("MTL_HUD_ENABLED");

	return e && e[0] == '1' && e[1] == 0;
}

int
rlk_hud_available(void)
{
	return hud_enabled();
}

void
rlk_hud_set(void *metal_layer, int on)
{
	CAMetalLayer *layer = (__bridge CAMetalLayer *)metal_layer;

	if (!layer || !hud_enabled())
	{
		return;
	}

	layer.developerHUDProperties = @{@"mode" : on ? @"default" : @"disabled"};
	fprintf(stderr, "[HUD] Metal Performance HUD %s\n", on ? "on" : "off");
}
