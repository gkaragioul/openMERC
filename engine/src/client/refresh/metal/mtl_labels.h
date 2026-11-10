// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Native adaptation of GPL gl3_sof2d.c world label placement.
// Implements: SPEC-412 section 7, SPEC-AMEND-002 1.5.

static void
MTL_HUDWorldLabel(float *origin, char *text, char *pic, unsigned int rgba)
{
	vec3_t d, forward, right, up;
	float across, upward, depth, k, k2;
	int cx, cy, sx, sy, sy2, h = 0;
	om_fontref_t small;

	if (!origin)
	{
		return;
	}

	AngleVectors(mtl_refdef.viewangles, forward, right, up);
	VectorSubtract(origin, mtl_refdef.vieworg, d);
	across = DotProduct(d, right);
	upward = DotProduct(d, up);
	depth = DotProduct(d, forward);

	if ((depth < 0.01f) || (mtl_refdef.fov_x <= 0) || (mtl_refdef.fov_y <= 0))
	{
		return;
	}

	cx = mtl_refdef.width / 2;
	cy = mtl_refdef.height / 2;
	sx = (int)(cx + across * cx / depth * 95.0f / mtl_refdef.fov_x);
	sy = (int)(cy - upward * cy / depth * 95.0f / mtl_refdef.fov_y);

	k = (depth > 256) ? 0.7f : 1.0f - 0.3f * depth / 256.0f;

	if (sx < 0)
	{
		sx = (int)(sx + 5 * k);
	}
	else if (sx > 0)
	{
		sx = (int)(sx - 5 * k);
	}

	sy2 = (int)(sy - 20 * k);

	memset(&small, 0, sizeof(small));
	small.chars = "small";
	small.length = 5;
	h = MTL_HUDFontHeight(&small);

	if (text)
	{
		/* the text is always opaque white (SPEC-AMEND-002 1.5) */
		MTL_HUDFontString(sx - MTL_HUDFontWidth(text, &small) / 2, sy2 + h / 2, text,
			0xFFFFFFFFu, &small, 0);
	}

	if (pic)
	{
		int pw, ph, dw, dh;
		byte c[4];

		k2 = (depth > 256) ? 0.4f : 1.0f - 0.6f * depth / 256.0f;
		MTL_HUDGetPicSize(&pw, &ph, pic);
		dw = (int)(pw * k2);
		dh = (int)(ph * k2);
		MTL_HUDUnpack(rgba, c);
		MTL_HUDStretch(sx - dw / 2, (int)(sy2 - h / 2 - dh / 2 - 4 * k2), dw, dh, c, pic, 0);
	}
}
