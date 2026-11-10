// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-412 soft particles, SPEC-AMEND-016 R16.8.
// Pure CPU/GPU math checks for soft particle fade mode, uniforms and distance fade.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "mtl_post_math.h"

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static int checks, failures;
static void check(bool pass, const char *label) { checks++; if (!pass) { fprintf(stderr, "FAIL: %s\n", label); failures++; } }
static void near(float actual, float expected, const char *label) { if (std::fabs(actual - expected) > 1e-6f) fprintf(stderr, "%s actual%g expected%g\n", label, actual, expected); check(std::fabs(actual - expected) <= 1e-6f, label); }

static void math(void)
{
	// Soft mode eligibility
	check(MTL_PostSoftMode(1, 1, 1, 1, 0) == 1, "normal blend billboard depthtest -> alpha mode");
	check(MTL_PostSoftMode(2, 1, 1, 1, 1) == 2, "additive blend with add control -> colour mode");
	check(MTL_PostSoftMode(3, 1, 1, 1, 1) == 2, "darken blend with add control -> colour mode");
	check(MTL_PostSoftMode(2, 1, 1, 1, 0) == 0, "additive without add control -> disabled");
	check(MTL_PostSoftMode(0, 1, 1, 1, 1) == 0, "opaque blend -> disabled");
	check(MTL_PostSoftMode(4, 1, 1, 1, 1) == 0, "multiply blend -> disabled");
	check(MTL_PostSoftMode(1, 0, 1, 1, 0) == 0, "non-billboard -> disabled");
	check(MTL_PostSoftMode(1, 1, 0, 1, 0) == 0, "no depth test -> disabled");
	check(MTL_PostSoftMode(1, 1, 1, 0, 0) == 0, "soft disabled globally -> disabled");

	// Eye distance (Metal 0..1 depth)
	float C = 4.0f, D = 100.0f;
	near(MTL_PostEyeDistance(0.5f, C, D, 0.0f, 1.0f), D / (0.5f + C), "eye distance at mid depth");
	near(MTL_PostEyeDistance(0.0f, C, D, 0.0f, 1.0f), D / (0.0f + C), "eye distance at near");
	near(MTL_PostEyeDistance(1.0f, C, D, 0.0f, 1.0f), D / (1.0f + C), "eye distance at far");
	check(!std::isfinite(MTL_PostEyeDistance(0.5f, C, D, 1.0f, 1.0f)), "equal depth range -> infinity");

	// Reversed depth range
	near(MTL_PostEyeDistance(0.5f, C, D, 1.0f, 0.0f), D / ((0.5f - 1.0f) / (0.0f - 1.0f) + C), "reversed depth range");

	// Soft uniforms
	mtl_soft_uniform_t u;
	MTL_PostSoftUniforms(1, C, D, 0.0f, 1.0f, 800, 600, 12.0f, &u);
	near(u.projection[0], C, "uniform projection C");
	near(u.projection[1], D, "uniform projection D");
	near(u.projection[2], 0.0f, "uniform depth min");
	near(u.projection[3], 1.0f, "uniform depth max");
	near(u.view[0], 1.0f / 800.0f, "uniform 1/windowW");
	near(u.view[1], 1.0f / 600.0f, "uniform 1/windowH");
	near(u.view[2], 12.0f, "uniform fade distance");
	near(u.view[3], 1.0f, "uniform mode");

	// Fade distance clamped to at least 1
	MTL_PostSoftUniforms(2, C, D, 0.0f, 1.0f, 800, 600, 0.5f, &u);
	near(u.view[2], 1.0f, "fade distance clamped to 1");

	// Soft fade
	near(MTL_PostSoftFade(10.0f, 4.0f, 12.0f), 6.0f / 12.0f, "fade at partial distance");
	near(MTL_PostSoftFade(4.0f, 10.0f, 12.0f), 0.0f, "fade clamped to 0");
	near(MTL_PostSoftFade(20.0f, 4.0f, 12.0f), 1.0f, "fade clamped to 1");
	near(MTL_PostSoftFade(10.0f, 4.0f, 0.0f), 1.0f, "zero fade dist treated as 1");

	// Null safety
	MTL_PostSoftUniforms(0, C, D, 0.0f, 1.0f, 800, 600, 12.0f, nullptr);
}

int main(void)
{
	@autoreleasepool {
		device = MTLCreateSystemDefaultDevice();
		if (!device) return 77;
		queue = [device newCommandQueue];
		math();
		printf("Post soft checks: %d passed, %d failed\n", checks - failures, failures);
		return failures ? 1 : 0;
	}
}