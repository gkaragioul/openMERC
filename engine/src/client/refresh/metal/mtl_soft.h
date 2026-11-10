// SPDX-License-Identifier: GPL-2.0-or-later
// Native soft particle eligibility, uniforms and fade math.
// Implements: SPEC-412 soft particles, SPEC-AMEND-016 R16.8.
// Pure math: no Metal calls, no renderer globals. MSL shader integration
// (omSoftP/omSoftV/omDepth uniforms) and FX draw-path calls are separate.
#ifndef OM_METAL_SOFT_H
#define OM_METAL_SOFT_H
#include "mtl_post_math.h"

/* Eligibility: 0 disabled/ineligible, 1 alpha (normal blend), 2 colour
 * (additive/darken blends when additive control enabled). */
static int MTL_SoftMode(int blend, int billboard, int depthtest,
	int soft_enabled, int soft_add)
{
	return MTL_PostSoftMode(blend, billboard, depthtest, soft_enabled, soft_add);
}

/* Fill soft uniforms from the post frame state. */
static void MTL_SoftUniforms(int mode, float C, float D, float depthMin, float depthMax,
	int windowW, int windowH, float fadeDist, mtl_soft_uniform_t *out)
{
	MTL_PostSoftUniforms(mode, C, D, depthMin, depthMax, windowW, windowH, fadeDist, out);
}

/* Eye distance from native 0..1 depth. */
static float MTL_SoftEyeDistance(float z, float C, float D, float depthMin, float depthMax)
{
	return MTL_PostEyeDistance(z, C, D, depthMin, depthMax);
}

/* Distance fade: clamp((sceneEyeDist - particleEyeDist) / fadeDist, 0, 1). */
static float MTL_SoftFade(float sceneEyeDist, float particleEyeDist, float fadeDist)
{
	return MTL_PostSoftFade(sceneEyeDist, particleEyeDist, fadeDist);
}

#endif