// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Volumetric fog region packing and raymarch math for Metal, adapted from GPL gl3_fog.c / gl3_post.c.
// Implements: SPEC-410 fog regions, SPEC-AMEND-016 R16.7.
// Pure math: no Metal calls, no renderer globals.
#ifndef OM_METAL_VOLFog_H
#define OM_METAL_VOLFog_H
#include "mtl_fog_math.h"
#include <math.h>

#define MTL_VOLFog_MAX_REGIONS 16
#define MTL_VOLFog_FLOATS_PER_REGION 32

/* Region packing, as GL3_Fog_VolumeRegions: fills out[] with at most maxRegions seen/view regions, nearest first by
 * distance from the eye to the region's box (the eye inside counts as 0; ties keep map order). Each region is 8 float4s:
 *   [0] mins.xyz, extinction per unit (2 / the distance at which the overlay reaches its maximum)
 *   [1] maxs.xyz, heightFlag (1 if height falloff)
 *   [2] RGB (0..1), maximum opacity
 *   [3..7] five half-spaces (inside normal, dist); unused ones are always inside (0,0,0,-1)
 * Returns the number of regions packed. */
static int MTL_VolFogPackRegions(const mtl_fog_world_t *f, const float eye[3],
	float out[], int maxRegions)
{
	if (!f || !eye || !out || maxRegions <= 0) return 0;
	if (maxRegions > MTL_VOLFog_MAX_REGIONS) maxRegions = MTL_VOLFog_MAX_REGIONS;
	if (f->mode == 2 || f->mode == 3) return 0;

	int idx[MTL_FOG_MAX_REGIONS], n = 0;
	float dist[MTL_FOG_MAX_REGIONS];

	for (int i = 0; i < f->numregions && i < MTL_FOG_MAX_REGIONS; i++) {
		if (!f->regionseen[i] && i != f->viewregion) continue;

		const mtl_fog_region_t *r = &f->regions[i];
		float d2 = 0;
		for (int k = 0; k < 3; k++) {
			float e = eye[k];
			float o = (e < r->mins[k]) ? r->mins[k] - e : ((e > r->maxs[k]) ? e - r->maxs[k] : 0);
			d2 += o * o;
		}

		int j;
		for (j = n; j > 0 && dist[j - 1] > d2; j--) {
			dist[j] = dist[j - 1];
			idx[j] = idx[j - 1];
		}
		dist[j] = d2;
		idx[j] = i;
		n++;
	}

	if (n > maxRegions) n = maxRegions;

	for (int i = 0; i < n; i++) {
		const mtl_fog_region_t *r = &f->regions[idx[i]];
		float *o = out + i * MTL_VOLFog_FLOATS_PER_REGION;
		float start, range, maxalpha, color[4], full;

		MTL_FogParams(f, r, &start, &range, &maxalpha, color);
		full = start + range * maxalpha;
		full = (full > 1) ? sqrtf(full) : 1;

		for (int k = 0; k < 3; k++) o[k] = r->mins[k];
		o[3] = 2.0f / full;
		for (int k = 0; k < 3; k++) o[4 + k] = r->maxs[k];
		o[7] = ((r->flags & 2) && (r->size[2] > 0)) ? 1.0f : 0.0f;
		o[8] = color[0] / 255.0f;
		o[9] = color[1] / 255.0f;
		o[10] = color[2] / 255.0f;
		o[11] = (range > 0) ? maxalpha / 255.0f : 0.0f;

		for (int k = 0; k < MTL_FOG_MAX_PLANES; k++) {
			float *pl = o + 12 + k * 4;
			pl[0] = pl[1] = pl[2] = 0;
			pl[3] = -1;

			if (k < r->numplanes) {
				const mtl_fog_plane_t *p = &r->planes[k];
				float lo = 1e30f, hi = -1e30f;

				/* the inside is the side holding most of the region's box */
				for (int c = 0; c < 8; c++) {
					float v[3] = {
						(c & 1) ? r->maxs[0] : r->mins[0],
						(c & 2) ? r->maxs[1] : r->mins[1],
						(c & 4) ? r->maxs[2] : r->mins[2]};
					float d = MTL_FogDot(p->normal, v) - p->dist;
					lo = (d < lo) ? d : lo;
					hi = (d > hi) ? d : hi;
				}

				if (hi >= -lo) {
					pl[0] = p->normal[0];
					pl[1] = p->normal[1];
					pl[2] = p->normal[2];
					pl[3] = p->dist - 1;
				} else {
					pl[0] = -p->normal[0];
					pl[1] = -p->normal[1];
					pl[2] = -p->normal[2];
					pl[3] = -p->dist - 1;
				}
			}
		}
	}
	return n;
}

/* Overlay dim: scales the region overlay when volfog is active. */
static float MTL_VolFogOverlayDim(int volfog_active, float configured)
{
	if (!volfog_active) return 1.0f;
	if (configured < 0) configured = 0;
	if (configured > 1) configured = 1;
	return configured;
}

/* Quality to step count mapping. */
static int MTL_VolFogSteps(int quality)
{
	switch (quality) {
		case 0: return 6;
		case 1: return 10;
		case 2: return 16;
		case 3: return 28;
		default: return 16;
	}
}

/* Noise value: 0 disables noise. Clamped to 0..0.9 (9/10). */
static float MTL_VolFogNoiseClamp(float noise)
{
	if (noise < 0) noise = 0;
	if (noise > 0.9f) noise = 0.9f;
	return noise;
}

/* Wanted check (pure: needs region count). */
static int MTL_VolFogWanted(int volfog_cvar, float intensity, int num_regions, int fog_mode, int nightvision)
{
	if (!volfog_cvar) return 0;
	if (intensity <= 0) return 0;
	if (num_regions <= 0) return 0;
	if (fog_mode == 2 || fog_mode == 3) return 0;
	if (nightvision) return 0;
	return 1;
}

#endif
