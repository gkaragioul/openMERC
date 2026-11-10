// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 lightmaps and dynamic lights.
// Pure C checks for lightmap math helpers.
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "../mtl_lightmap_math.h"

int main(void)
{
	/* Dimensions */
	assert(MTL_LightmapDimensions(1, 1) == 1);
	assert(MTL_LightmapDimensions(0, 1) == 0);
	assert(MTL_LightmapDimensions(1, 0) == 0);
	assert(MTL_LightmapDimensions(129, 1) == 0);
	assert(MTL_LightmapDimensions(1, 129) == 0);
	assert(MTL_LightmapDimensions(128, 128) == 0); /* 16384 > 12288 */
	assert(MTL_LightmapDimensions(96, 128) == 1); /* 12288 <= 12288 */

	/* Mono mode */
	assert(MTL_LightmapMonoMode('0') == 0);
	assert(MTL_LightmapMonoMode('L') == 1);
	assert(MTL_LightmapMonoMode('I') == 2);
	assert(MTL_LightmapMonoMode('C') == 3);
	assert(MTL_LightmapMonoMode('A') == 4);
	assert(MTL_LightmapMonoMode('X') == 5);

	/* Flow */
	float offset[2];
	MTL_LightmapFlow(0, 0, 1.0, offset);
	assert(offset[0] == 0 && offset[1] == 0);
	/* With flow flag 0x40 */
	MTL_LightmapFlow(0x40, 0x00010002, 1.0, offset);
	/* speed_s = 1, speed_t = 2 */
	/* offset[0] = -fmod(1 * 1.0 * 0.01, 1.0) = -0.01 */
	/* offset[1] = -fmod(2 * 1.0 * 0.01, 1.0) = -0.02 */
	assert(fabsf(offset[0] + 0.01f) < 1e-6f);
	assert(fabsf(offset[1] + 0.02f) < 1e-6f);

	/* Detail scroll */
	float off[2] = {0.5f, 0.5f};
	float shift[2] = {1.0f, 2.0f};
	MTL_LightmapDetailScroll(off, shift, 0.5f);
	assert(fabsf(off[0] - 1.0f) < 1e-6f);
	assert(fabsf(off[1] - 0.5f) < 1e-6f);
	/* Wrap */
	float off2[2] = {0.9f, 0.9f};
	MTL_LightmapDetailScroll(off2, shift, 0.5f);
	/* 0.9 + 0.5 = 1.4, should wrap to 0.4 */
	assert(fabsf(off2[0] - 0.4f) < 1e-6f);

	/* Dynamic samples - basic null checks */
	float output[4] = {0};
	assert(MTL_LightmapDynamicSamples(NULL, 1, 1, NULL, 0, NULL, 0) == 0);
	assert(MTL_LightmapDynamicSamples(output, 0, 1, NULL, 0, NULL, 0) == 0);
	assert(MTL_LightmapDynamicSamples(output, 1, 0, NULL, 0, NULL, 0) == 0);

	printf("Lightmap math checks: PASS\n");
	return 0;
}