// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Region fog of the SoF world in Metal: the per-frame glue between mtl_fog_draw.h and the renderer.
// Pass order and state adapted from the GPL gl3_fog.c and gl3_main.c.
// Implements: SPEC-410 Fog regions, SPEC-411 object fog, SPEC-412 effect fog.
#ifndef OM_METAL_FOG_FRAME_H
#define OM_METAL_FOG_FRAME_H
#include "mtl_fog_draw.h"
#include "mtl_fog_shaders.h"
#include "mtl_volfog.h"

#define MTL_FOG_CHAIN_MAX 16384

static mtl_fog_draw_t mtl_fogdraw;
static cvar_t *mtl_fog_start_cvar,*mtl_fog_end_cvar,*mtl_fog_density_cvar,*mtl_fog_color_cvar;
static cvar_t *mtl_fog_time_cvar,*mtl_fog_densityrange_cvar,*mtl_fog_ppfog_cvar,*mtl_ghl_obj_fog_cvar;
static cvar_t *mtl_fog_overlaydim_cvar;
static int mtl_fog_chain[MTL_FOG_CHAIN_MAX],mtl_fog_chain_count;
static mtl_fog_vertex_t *mtl_fog_batch;
static int mtl_fog_batch_count,mtl_fog_batch_cap;
static const float *mtl_fog_mvp;

static void MTL_FogShutdown(void)
{
	free(mtl_fog_batch);
	mtl_fog_batch=NULL;mtl_fog_batch_count=mtl_fog_batch_cap=0;
	memset(&mtl_fogdraw,0,sizeof(mtl_fogdraw));
}

static id<MTLRenderPipelineState> MTL_FogPipeline(void)
{
	mtl_pipeline_targets_t targets=MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> pipeline=MTL_PostPipelineCached(MTL_POST_PIPE_FOG,0,0,&targets);
	if(pipeline)return pipeline;
	pipeline=MTL_FogBuildPipeline(mtl_device,targets.color_count,targets.scene_format,targets.emission_format,targets.samples);
	if(!pipeline)MTL_Fatal("fog pipeline",NULL);
	MTL_PostPipelineStore(MTL_POST_PIPE_FOG,0,0,&targets,pipeline);
	return pipeline;
}

/* SPEC-410 Overlay drawing: blended, depth tested, no depth writes, polygon offset. One draw for the whole pass; the
 * r_om_ppfog add-on needs its per-polygon uniforms and flushes after each polygon. */
static void MTL_FogFlush(const mtl_fog_pixel_uniform_t *pixel)
{
	int count=mtl_fog_batch_count;
	mtl_fog_batch_count=0;
	if(count<=0||!mtl_encoder_open||!mtl_fog_mvp)return;
	NSUInteger offset=0;
	id<MTLBuffer> buffer=MTL_FrameUpload(mtl_fog_batch,(NSUInteger)count*sizeof(*mtl_fog_batch),&offset);
	if(!buffer)return;
	mtl_fog_pixel_uniform_t none;
	memset(&none,0,sizeof(none));
	[mtl_enc setRenderPipelineState:MTL_FogPipeline()];
	[mtl_enc setDepthStencilState:mtl_depth_readonly];
	[mtl_enc setCullMode:MTLCullModeNone];
	[mtl_enc setDepthBias:mtl_offset_units_cvar->value slopeScale:mtl_offset_factor_cvar->value clamp:0];
	[mtl_enc setVertexBuffer:buffer offset:offset atIndex:0];
	[mtl_enc setVertexBytes:mtl_fog_mvp length:16*sizeof(float) atIndex:1];
	[mtl_enc setFragmentBytes:pixel?pixel:&none length:sizeof(none) atIndex:1];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)count];
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
}

/* a region polygon or the far wall: a triangle fan */
static void MTL_FogEmit(void *user,const mtl_fog_vertex_t *vertices,int count,const mtl_fog_pixel_uniform_t *pixel,int wall)
{
	(void)user;(void)wall;
	if(count<3)return;
	int need=mtl_fog_batch_count+(count-2)*3;
	if(need>mtl_fog_batch_cap){
		int cap=mtl_fog_batch_cap?mtl_fog_batch_cap*2:4096;
		while(cap<need)cap*=2;
		mtl_fog_vertex_t *grown=realloc(mtl_fog_batch,(size_t)cap*sizeof(*grown));
		if(!grown)return;
		mtl_fog_batch=grown;mtl_fog_batch_cap=cap;
	}
	for(int i=1;i<count-1;i++){
		mtl_fog_batch[mtl_fog_batch_count++]=vertices[0];
		mtl_fog_batch[mtl_fog_batch_count++]=vertices[i];
		mtl_fog_batch[mtl_fog_batch_count++]=vertices[i+1];
	}
	if(pixel&&pixel->eye[3]>.5f)MTL_FogFlush(pixel);
}

/* SPEC-410 frame set-up step 3: the view leaf, or the leaf 16 units across a water surface */
static int MTL_FogViewRegion(const mtl_model_t *root,const mtl_fog_world_t *f)
{
	vec3_t p;
	const mleaf_t *leaf=Mod_PointInLeaf(mtl_refdef.vieworg,root->nodes);
	VectorCopy(mtl_refdef.vieworg,p);
	p[2]+=leaf->contents?16:-16;
	const mleaf_t *probe=Mod_PointInLeaf(p,root->nodes);
	if(!(probe->contents&CONTENTS_SOLID)&&probe->cluster!=leaf->cluster)leaf=probe;
	int i=MTL_FogArrayIndex(leaf,root->leafs,sizeof(*leaf),f->numleafs);
	return i>=0?f->leafregions[i]:-1;
}

/* before the world walk */
static void MTL_FogBeginFrame(void)
{
	mtl_model_t *root=mtl_worldmodel;
	mtl_fog_world_t *f=root?root->fog:NULL;
	mtl_fog_chain_count=0;
	mtl_fogdraw.numqueued=0;
	if(!f||!f->numregions){mtl_fogdraw.world=NULL;return;}
	if(!mtl_fog_start_cvar){
		mtl_fog_start_cvar=ri.Cvar_Get("gl_fogstart","-1",0x40);
		mtl_fog_end_cvar=ri.Cvar_Get("gl_fogend","-1",0x40);
		mtl_fog_density_cvar=ri.Cvar_Get("gl_fogdensity","-1",0x40);
		mtl_fog_color_cvar=ri.Cvar_Get("gl_fogcolor","-1",0x40);
		mtl_fog_time_cvar=ri.Cvar_Get("gl_fogtime","-1",0x40);
		mtl_fog_densityrange_cvar=ri.Cvar_Get("gl_fogdensityrange","-1",0x40);
		mtl_fog_ppfog_cvar=ri.Cvar_Get("r_om_ppfog","0",CVAR_ARCHIVE);
		mtl_ghl_obj_fog_cvar=ri.Cvar_Get("ghl_obj_fog","1",CVAR_ARCHIVE);
		mtl_fog_overlaydim_cvar=ri.Cvar_Get("r_om_volfog_overlaydim","0.85",CVAR_ARCHIVE);
	}
	f->mode=(int)mtl_framepost_fogmode->value;
	f->overrides.start=mtl_fog_start_cvar->value;
	f->overrides.range=mtl_fog_end_cvar->value;
	f->overrides.density=mtl_fog_density_cvar->value;
	f->overrides.time=mtl_fog_time_cvar->value;
	f->overrides.densityrange=mtl_fog_densityrange_cvar->value;
	f->overrides.color_enabled=mtl_fog_color_cvar->value>=0;
	f->overrides.color=mtl_fog_color_cvar->string;
	vec3_t forward,right,up;
	AngleVectors(mtl_refdef.viewangles,forward,right,up);
	MTL_FogDrawBegin(&mtl_fogdraw,f,mtl_refdef.vieworg,forward,right,up,MTL_FogViewRegion(root,f));
	/* GL3_VolFog_OverlayDim: with the volumetric pass on, the overlay gives up part of its alpha (r_om_volfog_overlaydim) */
	mtl_fogdraw.overlaydim=MTL_VolFogOverlayDim(mtl_post.active&&mtl_post.volfog,mtl_fog_overlaydim_cvar->value);
	mtl_fogdraw.ppfog=mtl_fog_ppfog_cvar->value!=0&&f->mode!=3;
	mtl_fogdraw.emit=MTL_FogEmit;
}

static int MTL_FogWorldIndex(const mtl_surface_t *surface)
{
	mtl_fog_world_t *f=mtl_fogdraw.world;
	return f?MTL_FogArrayIndex(surface,mtl_worldmodel->surfaces,sizeof(*surface),f->numsurfaces):-1;
}
/* The GL walk skips faces on the wrong side of their plane before it classifies them; this renderer's walk leaves
 * that to GPU culling, which the unculled overlay does not have (RLabs 2026-11-08: a back face of a region showed as a
 * pale patch on a wall in ger1). */
static int MTL_FogFacesViewer(const mtl_surface_t *surface)
{
	const cplane_t *plane=surface->bsp_plane;
	if(!plane)return 0;
	float side=DotProduct(mtl_refdef.vieworg,plane->normal)-plane->dist;
	return surface->plane_back==(side>=0?0:1);
}
/* boundary, sky and alpha faces: queued by the walk, ahead of the opaque faces (SPEC-AMEND-006 I4c.2) */
static void MTL_FogQueueSurface(mtl_surface_t *surface)
{
	int index=MTL_FogWorldIndex(surface);
	if(index>=0&&MTL_FogFacesViewer(surface))MTL_FogDrawQueueSurface(&mtl_fogdraw,index,surface->texinfo->flags);
}
static void MTL_FogMarkBoundaryPlane(mtl_surface_t *surface)
{
	int index=MTL_FogWorldIndex(surface);
	if(index>=0&&surface->bsp_plane&&MTL_FogFacesViewer(surface))
		MTL_FogDrawMarkPlane(&mtl_fogdraw,index,(int)(surface->bsp_plane-mtl_worldmodel->planes));
}
/* an opaque face drawn by the walk; its overlay is queued after the walk, as GL queues the texture chains */
static void MTL_FogQueueChain(mtl_surface_t *surface)
{
	int index=MTL_FogWorldIndex(surface);
	if(index>=0&&mtl_fogdraw.world->surfaces[index].region>=0&&mtl_fog_chain_count<MTL_FOG_CHAIN_MAX&&MTL_FogFacesViewer(surface))
		mtl_fog_chain[mtl_fog_chain_count++]=index;
}
static void MTL_FogQueueChains(void)
{
	mtl_fog_world_t *f=mtl_fogdraw.world;
	if(!f)return;
	for(int i=0;i<mtl_fog_chain_count;i++)
		MTL_FogDrawQueueSurface(&mtl_fogdraw,mtl_fog_chain[i],mtl_worldmodel->surfaces[mtl_fog_chain[i]].texinfo->flags);
	mtl_fog_chain_count=0;
}
/* first = after the opaque world (shimmer and far wall); then again after the sorted pass */
static void MTL_FogPass(const float mvp[16],int first)
{
	mtl_fog_mvp=mvp;
	MTL_FogDrawPassState(&mtl_fogdraw,first);
	MTL_FogFlush(NULL);
}
/* a translucent world face gets its overlay right after it is drawn, as well as in the first pass (gl3_fog.c) */
static void MTL_FogDrawSurfaceNow(mtl_surface_t *surface,const float mvp[16])
{
	int index=MTL_FogWorldIndex(surface);
	if(index<0)return;
	mtl_fog_mvp=mvp;
	MTL_FogDrawSurfaceImmediate(&mtl_fogdraw,index,surface->texinfo->flags);
	MTL_FogFlush(NULL);
}
/* an inline model's faces, in the fog of the region at the model's centre (gl3_surf.c) */
static void MTL_FogQueueModelSurface(const mtl_surface_t *surface,int region,const float origin[3],const float angles[3])
{
	int index=MTL_FogWorldIndex(surface);
	if(index<0)return;
	vec3_t forward,right,up;
	AngleVectors(angles,forward,right,up);
	MTL_FogDrawQueueModel(&mtl_fogdraw,index,region,surface->texinfo->flags,origin,forward,right,up);
}

/* distance fog of the model and effect shader: world-space plane for the vertex function, colour and range for the
 * fragment function (buffers 2 and 6 of the mtl_vs_fx / mtl_fs_fx pipelines, which every draw with them must bind) */
static void MTL_FogBindLinear(const mtl_linear_fog_t *fog,const float plane[4])
{
	[mtl_enc setVertexBytes:plane length:4*sizeof(float) atIndex:2];
	[mtl_enc setFragmentBytes:fog length:sizeof(*fog) atIndex:6];
}
static void MTL_FogBindNone(void)
{
	mtl_linear_fog_t none;
	memset(&none,0,sizeof(none));
	MTL_FogBindLinear(&none,none.plane);
}
/* SPEC-412: an effect quad takes the point fog of its region at its origin */
static void MTL_FogBindEffect(int region,int blend,const float origin[3])
{
	mtl_linear_fog_t fog;
	MTL_FogDrawEffectUniforms(&mtl_fogdraw,region,blend,origin,&fog);
	MTL_FogBindLinear(&fog,fog.plane);
}
#endif
