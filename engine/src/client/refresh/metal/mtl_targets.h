// SPDX-License-Identifier: GPL-2.0-or-later
// Actual render attachments and raster bounds, independent of the drawable.
// Implements: SPEC-002 frame ownership, SPEC-412 synchronous readback.
// Include after mtl_cb/mtl_enc/mtl_encoder_open and drawable globals.
#ifndef OM_METAL_TARGETS_H
#define OM_METAL_TARGETS_H
#define OM_METAL_TARGETS 1
#include <math.h>

typedef struct {
	id<MTLTexture> color[2], resolve[2], depth;
	NSUInteger color_count, samples;
	MTLViewport viewport;
	MTLScissorRect scissor;
	MTLClearColor clear_color[2];
	double clear_depth;
} mtl_frame_targets_t;

static mtl_frame_targets_t mtl_current_targets;
static id<MTLRenderCommandEncoder> mtl_target_encoder;

/* A descriptor is recorded only after a native encoder is created. Rejected
 * requests must leave the original open encoder and its attachments usable. */
static BOOL
MTL_TargetValid(const mtl_frame_targets_t *targets)
{
	if (!targets || !targets->color_count || targets->color_count>2 || !targets->color[0]) return NO;
	id<MTLTexture> first=targets->color[0];
	NSUInteger samples=targets->samples?targets->samples:1;
	for (NSUInteger i=0;i<targets->color_count;i++) {
		id<MTLTexture> color=targets->color[i];
		if (!color || color.width!=first.width || color.height!=first.height || color.sampleCount!=samples) return NO;
		id<MTLTexture> resolve=targets->resolve[i];
		if (resolve && (samples==1 || resolve.sampleCount!=1 || resolve.width!=color.width ||
			resolve.height!=color.height || resolve.pixelFormat!=color.pixelFormat)) return NO;
	}
	if (targets->depth && (targets->depth.width!=first.width || targets->depth.height!=first.height ||
		targets->depth.sampleCount!=samples)) return NO;
	MTLScissorRect scissor=targets->scissor;
	if (scissor.x>first.width || scissor.y>first.height ||
		scissor.width>first.width-scissor.x || scissor.height>first.height-scissor.y) return NO;
	MTLViewport viewport=targets->viewport;
	if (!(viewport.width>0) || !(viewport.height>0) || !isfinite(viewport.originX) ||
		!isfinite(viewport.originY) || !isfinite(viewport.width) || !isfinite(viewport.height) ||
		!isfinite(viewport.znear) || !isfinite(viewport.zfar)) return NO;
	return YES;
}

static id<MTLRenderCommandEncoder>
MTL_TargetCreateEncoderLoads(id<MTLCommandBuffer> buffer,const mtl_frame_targets_t *targets,
	const MTLLoadAction color_load[2],MTLLoadAction depth_load)
{
	if (!buffer || buffer.status>=MTLCommandBufferStatusCommitted || !MTL_TargetValid(targets)) return nil;
	MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
	for (NSUInteger i=0;i<targets->color_count;i++) {
		pass.colorAttachments[i].texture=targets->color[i];
		pass.colorAttachments[i].resolveTexture=targets->resolve[i];
		pass.colorAttachments[i].loadAction=color_load[i];
		/* Store retains the MSAA source across a fence. Resolve also makes a
		 * requested single-sample color readable after this encoder ends. */
		pass.colorAttachments[i].storeAction=targets->resolve[i]?
			MTLStoreActionStoreAndMultisampleResolve:MTLStoreActionStore;
		pass.colorAttachments[i].clearColor=targets->clear_color[i];
	}
	if (targets->depth) {
		pass.depthAttachment.texture=targets->depth;
		pass.depthAttachment.loadAction=depth_load;
		pass.depthAttachment.storeAction=MTLStoreActionStore;
		pass.depthAttachment.clearDepth=targets->clear_depth;
	}
	return [buffer renderCommandEncoderWithDescriptor:pass];
}

static id<MTLRenderCommandEncoder>
MTL_TargetCreateEncoder(id<MTLCommandBuffer> buffer,const mtl_frame_targets_t *targets,
	MTLLoadAction color_load,MTLLoadAction depth_load)
{
	const MTLLoadAction loads[2]={color_load,color_load};
	return MTL_TargetCreateEncoderLoads(buffer,targets,loads,depth_load);
}

static void
MTL_TargetApplyRaster(const mtl_frame_targets_t *targets)
{
	[mtl_enc setViewport:targets->viewport];
	[mtl_enc setScissorRect:targets->scissor];
}

static void
MTL_TargetAdopt(id<MTLCommandBuffer> buffer,id<MTLRenderCommandEncoder> encoder,
	const mtl_frame_targets_t *targets)
{
	mtl_cb=buffer;
	mtl_enc=encoder;
	mtl_encoder_open=true;
	mtl_current_targets=*targets;
	mtl_target_encoder=encoder;
	MTL_TargetApplyRaster(targets);
}

static BOOL
MTL_TargetOpen(const mtl_frame_targets_t *targets,MTLLoadAction color_load,MTLLoadAction depth_load)
{
	if (mtl_encoder_open) return NO; /* switching owners must end the old pass explicitly */
	id<MTLRenderCommandEncoder> encoder=MTL_TargetCreateEncoder(mtl_cb,targets,color_load,depth_load);
	if (!encoder) return NO;
	MTL_TargetAdopt(mtl_cb,encoder,targets);
	return YES;
}

static BOOL
MTL_TargetOpenLoads(const mtl_frame_targets_t *targets,const MTLLoadAction color_load[2],MTLLoadAction depth_load)
{
	if (mtl_encoder_open) return NO;
	id<MTLRenderCommandEncoder> encoder=MTL_TargetCreateEncoderLoads(mtl_cb,targets,color_load,depth_load);
	if (!encoder) return NO;
	MTL_TargetAdopt(mtl_cb,encoder,targets);return YES;
}

static void
MTL_TargetEnd(void)
{
	if (mtl_encoder_open) [mtl_enc endEncoding];
	mtl_enc=nil;
	mtl_target_encoder=nil;
	mtl_encoder_open=false;
}

static BOOL
MTL_TargetResume(id<MTLCommandBuffer> buffer,const mtl_frame_targets_t *targets)
{
	if (mtl_encoder_open) return NO;
	id<MTLRenderCommandEncoder> encoder=MTL_TargetCreateEncoder(buffer,targets,MTLLoadActionLoad,MTLLoadActionLoad);
	if (!encoder) return NO;
	MTL_TargetAdopt(buffer,encoder,targets);
	return YES;
}

/* Every direct viewport/scissor mutation must record its physical value. The
 * HUD clip function should call RecordScissor after setting the encoder. */
static void MTL_TargetRecordViewport(MTLViewport viewport)
{
	if (mtl_enc==mtl_target_encoder) mtl_current_targets.viewport=viewport;
}
static void MTL_TargetRecordScissor(MTLScissorRect scissor)
{
	if (mtl_enc==mtl_target_encoder) mtl_current_targets.scissor=scissor;
}
static BOOL MTL_TargetTracked(void)
{
	return mtl_encoder_open && mtl_enc==mtl_target_encoder && mtl_current_targets.color_count!=0;
}
static id<MTLTexture> MTL_TargetReadableColor(void)
{
	if (!mtl_encoder_open) return mtl_last_drawable.texture;
	if (!MTL_TargetTracked()) return mtl_drawable.texture;
	if (mtl_current_targets.samples>1) return mtl_current_targets.resolve[0];
	return mtl_current_targets.color[0];
}
static void MTL_TargetReset(void)
{
	mtl_current_targets=(mtl_frame_targets_t){};
	mtl_target_encoder=nil;
}
#endif
