// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 1997-2001 Id Software, Inc.
// Copyright (C) 2026 OpenMerc contributors
// Native counterpart of GPL gl3_dynlight.c's SoF sample-light rule.
// Implements: SPEC-410 (lightmaps and dynamic lights), SPEC-413.
#ifndef OM_METAL_LIGHTMAP_MATH_H
#define OM_METAL_LIGHTMAP_MATH_H
#include <math.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define MTL_LIGHTMAP_MAX_SAMPLES 12288
#define MTL_LIGHTMAP_MAX_DIMENSION 128

typedef struct {
	float normal[3], distance;
	float texvecs[2][4];
	int mins[2], steps[2];
	unsigned flags;
} mtl_lightmap_geometry_t;

typedef struct {
	float origin[3], color[3], intensity;
} mtl_lightmap_light_t;

static int
MTL_LightmapDimensions(int width, int height)
{
	return width > 0 && height > 0 && width <= MTL_LIGHTMAP_MAX_DIMENSION &&
		height <= MTL_LIGHTMAP_MAX_DIMENSION && width * height <= MTL_LIGHTMAP_MAX_SAMPLES;
}

static int
MTL_LightmapMonoMode(char first)
{
	switch (first) {
		case '0': return 0;
		case 'L': return 1;
		case 'I': return 2;
		case 'C': return 3;
		case 'A': return 4;
		default: return 5;
	}
}

/* The base world shader consumes this normalized UV offset. Keep the
 * fractional phase in double precision, exactly as GL3_DrawGLFlowingPoly. */
static void
MTL_LightmapFlow(unsigned flags, int packed_value, double game_time, float offset[2])
{
	offset[0] = offset[1] = 0;
	if (!(flags & 0x40u)) return;
	int16_t speed_s = (int16_t)((uint32_t)packed_value >> 16);
	int16_t speed_t = (int16_t)((uint32_t)packed_value & 0xffffu);
	offset[0] = -(float)fmod(speed_s * game_time * 0.01, 1.0);
	offset[1] = -(float)fmod(speed_t * game_time * 0.01, 1.0);
}

static void
MTL_LightmapDetailScroll(float offset[2], const float shift[2], float game_delta)
{
	for (int axis = 0; axis < 2; axis++) {
		offset[axis] += game_delta * shift[axis];
		if (offset[axis] > 1.0f) offset[axis] -= (float)(int)offset[axis];
	}
}

/* Fresh output on every call avoids a stale contribution when a light leaves.
 * Inputs use the original BSP plane/axes even for inline models, matching the
 * GPL reference's per-sample path and its untransformed R_MarkLights inputs. */
static int
MTL_LightmapDynamicSamples(float *output, int width, int height,
	const mtl_lightmap_geometry_t *geometry, unsigned bits,
	const mtl_lightmap_light_t *lights, int count)
{
	if (!output || !MTL_LightmapDimensions(width, height)) return 0;
	memset(output, 0, (size_t)width * height * 4 * sizeof(float));
	if (!geometry || !lights || !bits || count <= 0 || geometry->steps[0] <= 0 ||
		geometry->steps[1] <= 0 || (geometry->flags & (4u | 8u | 0x800u))) return 0;
	if (!isfinite(geometry->distance)) return 0;
	for (int k = 0; k < 3; k++) if (!isfinite(geometry->normal[k])) return 0;
	for (int axis = 0; axis < 2; axis++)
		for (int k = 0; k < 4; k++) if (!isfinite(geometry->texvecs[axis][k])) return 0;
	if (count > 32) count = 32;
	int any = 0;
	for (int n = 0; n < count; n++) {
		if (!(bits & (1u << n))) continue;
		const mtl_lightmap_light_t *light = &lights[n];
		int valid = isfinite(light->intensity);
		for (int k = 0; k < 3; k++) valid = valid && isfinite(light->origin[k]) && isfinite(light->color[k]);
		if (!valid) continue;
		/* Keep the GPL expression order: moving plane distance into the dot
		 * accumulation changes float rounding near integer sample boundaries. */
		float distance = (light->origin[0] * geometry->normal[0] +
			light->origin[1] * geometry->normal[1] + light->origin[2] * geometry->normal[2]) - geometry->distance;
		float radius = light->intensity - fabsf(distance);
		if (!isfinite(radius) || radius < 64.0f) continue;
		float impact[3], local[2];
		for (int k = 0; k < 3; k++) impact[k] = light->origin[k] - distance * geometry->normal[k];
		for (int axis = 0; axis < 2; axis++) {
			local[axis] = impact[0] * geometry->texvecs[axis][0] + impact[1] * geometry->texvecs[axis][1] +
				impact[2] * geometry->texvecs[axis][2] + geometry->texvecs[axis][3] - (float)geometry->mins[axis];
		}
		for (int y = 0; y < height; y++) {
			float t = local[1] - (float)geometry->steps[1] * y;
			if (!isfinite(t) || t <= -2147483648.0f || t >= 2147483648.0f) continue;
			int64_t dt = (int)t;
			if (dt < 0) dt = -dt;
			for (int x = 0; x < width; x++) {
				float s = local[0] - (float)geometry->steps[0] * x;
				if (!isfinite(s) || s <= -2147483648.0f || s >= 2147483648.0f) continue;
				int64_t ds = (int)s;
				if (ds < 0) ds = -ds;
				int64_t metric = ds > dt ? ds + (dt >> 1) : dt + (ds >> 1);
				if ((float)metric >= radius - 64.0f) continue;
				float *sample = output + ((size_t)y * width + x) * 4;
				for (int k = 0; k < 3; k++) sample[k] += (radius - (float)metric) * light->color[k] * (1.0f / 255.0f);
				any = 1;
			}
		}
	}
	return any;
}
#endif
