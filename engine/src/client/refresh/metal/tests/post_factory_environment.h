// SPDX-License-Identifier: GPL-2.0-or-later
// Explicit offscreen pass input for standalone production-factory harnesses.
// These harnesses test shaders/factories; native target ownership is exercised
// separately by post_targets.mm using the real attachment tracker.
#include "mtl_post_pipeline_cache.h"
static mtl_pipeline_targets_t mtl_test_pipeline_targets={1,1,MTLPixelFormatBGRA8Unorm,MTLPixelFormatInvalid};
static mtl_pipeline_targets_t MTL_PostPipelineTargets(void) { return mtl_test_pipeline_targets; }
