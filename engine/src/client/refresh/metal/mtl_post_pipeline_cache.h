// SPDX-License-Identifier: GPL-2.0-or-later
// Format/sample-aware native 3D pipeline cache. Implements: SPEC-AMEND-016.
#ifndef OM_METAL_POST_PIPELINE_CACHE_H
#define OM_METAL_POST_PIPELINE_CACHE_H
#include "mtl_post_shaders.h"

typedef struct {
	NSUInteger color_count,samples;
	MTLPixelFormat scene_format,emission_format;
} mtl_pipeline_targets_t;
enum {
	MTL_POST_PIPE_WORLD,MTL_POST_PIPE_SKY,MTL_POST_PIPE_ALIAS,
	MTL_POST_PIPE_PARTICLE,MTL_POST_PIPE_TURB,MTL_POST_PIPE_LIQUID,MTL_POST_PIPE_GENERIC,MTL_POST_PIPE_FOG,MTL_POST_PIPE_TERRAIN,MTL_POST_PIPE_GSHADOW
};
/* Native host supplies the actual active render-pass snapshot. Standalone
 * shader tests supply their explicit offscreen pass as the same input. */
static mtl_pipeline_targets_t MTL_PostPipelineTargets(void);

typedef struct {
	int family,blend,fragment;
	mtl_pipeline_targets_t targets;
	id<MTLRenderPipelineState> pipeline;
} mtl_pipeline_cache_entry_t;
static mtl_pipeline_cache_entry_t mtl_post_pipeline_cache[256];
static NSUInteger mtl_post_pipeline_next;
static id<MTLDevice> mtl_post_pipeline_device;

static void MTL_PostPipelineClear(void)
{
	for(NSUInteger i=0;i<256;i++) mtl_post_pipeline_cache[i].pipeline=nil;
	mtl_post_pipeline_next=0;mtl_post_pipeline_device=nil;
}
static BOOL MTL_PostPipelineSameTargets(const mtl_pipeline_targets_t *a,const mtl_pipeline_targets_t *b)
{
	return a->color_count==b->color_count && a->samples==b->samples &&
		a->scene_format==b->scene_format && a->emission_format==b->emission_format;
}
static id<MTLRenderPipelineState>
MTL_PostPipelineCached(int family,int blend,int fragment,const mtl_pipeline_targets_t *targets)
{
	if(mtl_post_pipeline_device!=mtl_device) {MTL_PostPipelineClear();mtl_post_pipeline_device=mtl_device;}
	for(NSUInteger i=0;i<256;i++) {
		mtl_pipeline_cache_entry_t *e=&mtl_post_pipeline_cache[i];
		if(e->pipeline && e->family==family && e->blend==blend && e->fragment==fragment &&
			MTL_PostPipelineSameTargets(&e->targets,targets)) return e->pipeline;
	}
	return nil;
}
static void
MTL_PostPipelineStore(int family,int blend,int fragment,const mtl_pipeline_targets_t *targets,
	id<MTLRenderPipelineState> pipeline)
{
	if(!pipeline) return;
	mtl_pipeline_cache_entry_t *e=&mtl_post_pipeline_cache[mtl_post_pipeline_next++%256];
	e->family=family;e->blend=blend;e->fragment=fragment;e->targets=*targets;e->pipeline=pipeline;
}
static NSString *MTL_PostShaderSource(NSString *source,const mtl_pipeline_targets_t *targets)
{
	return [NSString stringWithFormat:@"%@\n%@",MTL_PostMSLPreamble(targets->color_count==2),source];
}
static BOOL MTL_PostConfigurePipeline(MTLRenderPipelineDescriptor *descriptor,const mtl_pipeline_targets_t *targets)
{
	return MTL_PostConfigurePipelineTargets(descriptor,targets->color_count,targets->scene_format,
		targets->emission_format,targets->samples);
}
#endif
