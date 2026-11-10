// SPDX-License-Identifier: GPL-2.0-or-later
// Native menu state. Implements: SPEC-412 section 2 and OpenMerc UI scaling.
#include "mtl_menu_geometry.h"

static void MTL_SoF_Set2D(int restore)
{
	MTL_UpdateHUDState();
	mtl_menu_active=NO;
	mtl_ui_w=(float)mtl_width; mtl_ui_h=(float)mtl_height;
	if ((restore&255) && mtl_menu_saved) {
		mtl_menu_saved=NO;
		if (mtl_menu_clip_saved) {
			mtl_hud_clipenabled=YES;
			MTL_HUDReapplyClipRect();
		}
	}
	MTL_SoF_HUDResetState();
	if (mtl_encoder_open) {
		[mtl_enc setViewport:(MTLViewport){0,0,(double)mtl_width,(double)mtl_height,0,1}];
#ifdef OM_METAL_TARGETS
		MTL_TargetRecordViewport((MTLViewport){0,0,(double)mtl_width,(double)mtl_height,0,1});
#endif
		[mtl_enc setDepthStencilState:mtl_depth_2d];
		[mtl_enc setCullMode:MTLCullModeNone];
		[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
	}
}

static void MTL_SoF_Set3DInMenu(int flag)
{
	mtl_menu_active=YES;
	MTL_MenuProjection((float)mtl_width,(float)mtl_height,mtl_hud_scale,flag&255,
		mtl_nearclip_cvar?mtl_nearclip_cvar->value:4,
		mtl_farclip_cvar?mtl_farclip_cvar->value:65535,mtl_menu_mvp);
	if(flag&255) {
		mtl_menu_saved=YES;
		mtl_menu_clip_saved=mtl_hud_clipenabled;
		mtl_hud_clipenabled=NO;
		MTL_HUDUpdateClip();
	}
	if (mtl_encoder_open) {
		[mtl_enc setViewport:(MTLViewport){0,0,(double)mtl_width,(double)mtl_height,0,1}];
#ifdef OM_METAL_TARGETS
		MTL_TargetRecordViewport((MTLViewport){0,0,(double)mtl_width,(double)mtl_height,0,1});
#endif
		[mtl_enc setDepthStencilState:mtl_depth_world];
	}
}
