// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// The r_om_volfog pass of a world view: region packing, pipeline and draw; adapted from the GPL gl3_post.c.
// Implements: SPEC-AMEND-016 R16.7; docs/impl/GFX-modern.md section 3.
// Include after mtl_post.h, the fog frame header and mtl_world/mtl_enc globals.
#ifndef OM_METAL_VOLFOG_PASS_H
#define OM_METAL_VOLFOG_PASS_H
#include "mtl_volfog.h"
#include "mtl_volfog_shader.h"

#define MTL_POST_PIPE_VOLFOG 100 /* outside the shared family enum of mtl_post_pipeline_cache.h */

static cvar_t *mtl_volfog_quality_cvar, *mtl_volfog_shafts_cvar, *mtl_volfog_noise_cvar;

static void MTL_VolFogInit(void)
{
	/* the master switch and intensity are registered with the view lifecycle (mtl_post.h), the overlay dim with mtl_fog_frame.h */
	mtl_volfog_quality_cvar = ri.Cvar_Get("r_om_volfog_quality", "2", CVAR_ARCHIVE);
	mtl_volfog_shafts_cvar = ri.Cvar_Get("r_om_volfog_shafts", "1", CVAR_ARCHIVE);
	mtl_volfog_noise_cvar = ri.Cvar_Get("r_om_volfog_noise", "0.25", CVAR_ARCHIVE);
}

static void MTL_VolFogShutdown(void)
{
	mtl_volfog_quality_cvar = mtl_volfog_shafts_cvar = mtl_volfog_noise_cvar = NULL;
}

static id<MTLRenderPipelineState> MTL_VolFogPipeline(int shafts)
{
	mtl_pipeline_targets_t targets = MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> pipeline = MTL_PostPipelineCached(MTL_POST_PIPE_VOLFOG, 0, shafts, &targets);
	if (pipeline) return pipeline;
	NSString *source = mtl_volfog_msl;
#ifdef OM_METAL_CSM_SHADER_H
	if (shafts) source = [NSString stringWithFormat:@"#define OM_VOLFOG_SHAFTS 1\n%@\n%@", mtl_csm_msl, mtl_volfog_msl];
#endif
	NSError *error = nil;
	id<MTLLibrary> library = [mtl_device newLibraryWithSource:MTL_PostShaderSource(source, &targets) options:nil error:&error];
	if (!library) { MTL_Fatal("MSL compile (volumetric fog)", error.localizedDescription.UTF8String); return nil; }
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.label = @"openMerc volumetric fog";
	d.vertexFunction = [library newFunctionWithName:@"mtl_vs_volfog"];
	d.fragmentFunction = [library newFunctionWithName:@"mtl_fs_volfog"];
	/* (1, source alpha) on colour and emission, as GL: acc + dst * T; the bloom buffer is dimmed by the fog too */
	MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[0];
	ca.blendingEnabled = YES;
	ca.sourceRGBBlendFactor = ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
	ca.destinationRGBBlendFactor = ca.destinationAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	if (!MTL_PostConfigurePipeline(d, &targets)) MTL_Fatal("volumetric fog targets", "invalid active attachments");
	d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	pipeline = [mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
	if (!pipeline) { MTL_Fatal("volumetric fog pipeline", error.localizedDescription.UTF8String); return nil; }
	MTL_PostPipelineStore(MTL_POST_PIPE_VOLFOG, 0, shafts, &targets, pipeline);
	return pipeline;
}

/* after the overlay pass of the opaque world, as GL3_Post_VolFog */
static void MTL_VolFogDraw(int shafts_available)
{
	if (!mtl_encoder_open || !mtl_post.active || !mtl_post.volfog || !mtl_post.depthcopied || !mtl_volfog_quality_cvar)
		return;
	mtl_model_t *root = mtl_worldmodel;
	mtl_fog_world_t *f = root ? root->fog : NULL;
	if (!f) return;

	static mtl_volfog_uniform_t u;
	int n = MTL_VolFogPackRegions(f, mtl_refdef.vieworg, u.vr, MTL_VOLFog_MAX_REGIONS);
	if (n <= 0) return;

	int q = (int)mtl_volfog_quality_cvar->value;
	q = q < 0 ? 0 : (q > 3 ? 3 : q);
	float shafts = mtl_volfog_shafts_cvar->value;
	shafts = shafts > 0 ? shafts : 0;
	int usesun = shafts_available && shafts > 0;

	memcpy(u.invpv, mtl_post.inverse_pv, sizeof(u.invpv));
	u.eye[0] = mtl_refdef.vieworg[0];
	u.eye[1] = mtl_refdef.vieworg[1];
	u.eye[2] = mtl_refdef.vieworg[2];
	u.eye[3] = mtl_refdef.time;
	u.prm[0] = mtl_post.depth_min;
	u.prm[1] = mtl_post.depth_max;
	u.prm[2] = mtl_framepost_volfog_intensity->value;
	u.prm[3] = shafts;
	u.prm2[0] = (float)n;
	u.prm2[1] = (float)MTL_VolFogSteps(q);
	u.prm2[2] = MTL_VolFogNoiseClamp(mtl_volfog_noise_cvar->value);
	u.prm2[3] = usesun ? 1.0f : 0.0f;

	id<MTLRenderPipelineState> pipeline = MTL_VolFogPipeline(usesun);
	if (!pipeline) return;
	[mtl_enc setRenderPipelineState:pipeline];
	[mtl_enc setDepthStencilState:mtl_framepost_no_depth];
	[mtl_enc setCullMode:MTLCullModeNone];
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
	[mtl_enc setFragmentTexture:mtl_post.depthcopy atIndex:0];
	[mtl_enc setFragmentBytes:&u length:offsetof(mtl_volfog_uniform_t, vr) + (NSUInteger)n * 32 * sizeof(float) atIndex:0];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}
#endif
