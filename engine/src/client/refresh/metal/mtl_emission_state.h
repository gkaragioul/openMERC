// SPDX-License-Identifier: GPL-2.0-or-later
// Actual native pass/cvar emission state. Implements: SPEC-AMEND-016.
// Include after current frame/target/model and cvar globals, before factories.
#ifndef OM_METAL_EMISSION_STATE_H
#define OM_METAL_EMISSION_STATE_H
#include "mtl_post_math.h"
#include "mtl_post_pipeline_cache.h"
static cvar_t *mtl_bloom_enable_cvar,*mtl_post_debug_cvar;
static cvar_t *mtl_bloom_surface_cvar,*mtl_bloom_ghoulmin_cvar,*mtl_bloom_fullbright_cvar,*mtl_bloom_fx_cvar;
static BOOL mtl_emission_view_known,mtl_emission_view_active,mtl_emission_view_sources;
/* The framegraph reports its actual resource/activation decision after setup.
 * Until it is installed, explicit standalone MRT callers use the same cvar
 * policy; a reported failed/inactive view always suppresses source writes. */
static void MTL_PostEmissionViewState(BOOL active,BOOL source_enabled)
{
	mtl_emission_view_known=YES;mtl_emission_view_active=active;mtl_emission_view_sources=source_enabled;
}

static mtl_pipeline_targets_t MTL_PostPipelineTargets(void)
{
	mtl_pipeline_targets_t targets={1,1,mtl_layer?mtl_layer.pixelFormat:MTLPixelFormatBGRA8Unorm,MTLPixelFormatInvalid};
	if(MTL_TargetTracked()) {
		targets.color_count=mtl_current_targets.color_count;
		targets.samples=mtl_current_targets.samples?mtl_current_targets.samples:1;
		targets.scene_format=mtl_current_targets.color[0].pixelFormat;
		if(targets.color_count==2) targets.emission_format=mtl_current_targets.color[1].pixelFormat;
	}
	return targets;
}
static mtl_post_emission_controls_t MTL_PostEmissionControls(void)
{
	mtl_post_emission_controls_t controls={0,1,.5f,1,1};
	BOOL normal=(mtl_bloom_enable_cvar?mtl_bloom_enable_cvar->value:1)!=0 &&
		!(mtl_fullbright_cvar && mtl_fullbright_cvar->value) && !(mtl_refdef.rdflags&RDF_IRGOGGLES);
	BOOL debug=mtl_post_debug_cvar && mtl_post_debug_cvar->value!=0;
	controls.enabled=MTL_TargetTracked() && mtl_current_targets.color_count==2 && mtl_worldmodel &&
		!(mtl_refdef.rdflags&RDF_NOWORLDMODEL) && (normal || debug);
	if(mtl_emission_view_known && (!mtl_emission_view_active || !mtl_emission_view_sources))controls.enabled=0;
	if(mtl_bloom_surface_cvar)controls.surface_scale=mtl_bloom_surface_cvar->value;
	if(mtl_bloom_ghoulmin_cvar)controls.ghoul_min=mtl_bloom_ghoulmin_cvar->value;
	if(mtl_bloom_fullbright_cvar)controls.fullbright_scale=mtl_bloom_fullbright_cvar->value;
	if(mtl_bloom_fx_cvar)controls.fx_scale=mtl_bloom_fx_cvar->value;
	return controls;
}
static void MTL_PostBindEmission(mtl_emission_t emission,NSUInteger index)
{
	[mtl_enc setFragmentBytes:emission.value length:sizeof(emission.value) atIndex:index];
}
static void MTL_PostEmissionInit(void)
{
	mtl_emission_view_known=mtl_emission_view_active=mtl_emission_view_sources=NO;
	mtl_bloom_enable_cvar=ri.Cvar_Get("r_om_bloom","1",CVAR_ARCHIVE);
	mtl_post_debug_cvar=ri.Cvar_Get("r_om_post_debug","0",0);
	mtl_bloom_surface_cvar=ri.Cvar_Get("r_om_bloom_surfscale","1",CVAR_ARCHIVE);
	mtl_bloom_ghoulmin_cvar=ri.Cvar_Get("r_om_bloom_ghoulmin","0.5",CVAR_ARCHIVE);
	mtl_bloom_fullbright_cvar=ri.Cvar_Get("r_om_bloom_fullbright","1",CVAR_ARCHIVE);
	mtl_bloom_fx_cvar=ri.Cvar_Get("r_om_bloom_fx","1",CVAR_ARCHIVE);
}
static void MTL_PostEmissionShutdown(void)
{
	MTL_PostPipelineClear();
	mtl_emission_view_known=mtl_emission_view_active=mtl_emission_view_sources=NO;
	mtl_bloom_enable_cvar=mtl_post_debug_cvar=NULL;
	mtl_bloom_surface_cvar=mtl_bloom_ghoulmin_cvar=mtl_bloom_fullbright_cvar=mtl_bloom_fx_cvar=NULL;
}
#endif
