// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 inline faces, SPEC-411 section 8, SPEC-412 section 10.
#ifndef OM_MTL_BRUSH_MATH_H
#define OM_MTL_BRUSH_MATH_H
#include <math.h>
#include <limits.h>

static inline int MTL_BrushRange(int first, int count, int total)
{
	return first >= 0 && count >= 0 && first <= total && count <= total - first;
}

/* Collision-only inline models can have no draw faces and a negative leaf
 * head. Stock tsr1 has five such descriptors; never index nodes with them. */
static inline int MTL_BrushDescriptorValid(int index, int first, int count,
	int head, int faces, int nodes, int leafs)
{
	if (!MTL_BrushRange(first, count, faces)) return 0;
	if (head >= 0) return MTL_BrushRange(head, 1, nodes);
	return index > 0 && count == 0 && leafs > 0 && head >= -leafs;
}

static inline int MTL_BrushInlineIndex(const char *name, int count)
{
	if (!name || name[0] != '*' || name[1] < '0' || name[1] > '9') return -1;
	int n = 0;
	for (const char *p = name + 1; *p; p++)
	{
		if (*p < '0' || *p > '9' || n > 256) return -1;
		n = n * 10 + (*p - '0');
	}
	return n >= 1 && n <= 256 && n < count ? n : -1;
}

static inline void MTL_BrushXform(const float m[16], const float p[3], float out[3], int point)
{
	float v[3];
	for (int k = 0; k < 3; k++)
		v[k] = m[k] * p[0] + m[4+k] * p[1] + m[8+k] * p[2] + (point ? m[12+k] : 0);
	for (int k = 0; k < 3; k++) out[k] = v[k];
}

static inline void MTL_BrushLocalEye(const float m[16], const float eye[3], float out[3])
{
	float v[3] = {eye[0]-m[12], eye[1]-m[13], eye[2]-m[14]};
	for (int k = 0; k < 3; k++) out[k] = m[4*k]*v[0] + m[4*k+1]*v[1] + m[4*k+2]*v[2];
}

static inline void MTL_BrushBounds(const float mins[3], const float maxs[3], float radius,
	const float origin[3], const float angles[3], float outmin[3], float outmax[3])
{
	int rotated = angles[0] != 0 || angles[1] != 0 || angles[2] != 0;
	for (int k = 0; k < 3; k++)
	{
		outmin[k] = origin[k] + (rotated ? -radius : mins[k]);
		outmax[k] = origin[k] + (rotated ? radius : maxs[k]);
	}
}

static inline float MTL_BrushCenterKey(const float mins[3], const float maxs[3],
	const float origin[3], const float eye[3])
{
	float key = 0;
	for (int k = 0; k < 3; k++)
	{
		float d = origin[k] + (mins[k] + maxs[k])*0.5f - eye[k];
		key += d*d;
	}
	return key;
}

static inline int MTL_BrushFront(const float eye[3], const float point[3], const float normal[3])
{
	float d = 0;
	for (int k = 0; k < 3; k++) d += (eye[k]-point[k])*normal[k];
	return d > 0.01f;
}
#endif
