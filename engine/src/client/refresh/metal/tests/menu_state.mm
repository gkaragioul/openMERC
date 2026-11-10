// SPDX-License-Identifier: GPL-2.0-or-later
// Reuse the actual production-HUD GPU fixture; this adds real menu state transitions.
#define main foundation_main
#include "menu_foundation.mm"
#undef main
static BOOL mtl_menu_active,mtl_menu_saved,mtl_menu_clip_saved;
static float mtl_menu_mvp[16];
static int mtl_width=32,mtl_height=32;
static struct { float value; } near_clip={4},far_clip={65535};
static decltype(near_clip) *mtl_nearclip_cvar=&near_clip,*mtl_farclip_cvar=&far_clip;
static id<MTLDepthStencilState> mtl_depth_world;
static void MTL_UpdateHUDState(void) {}
#include "mtl_sofmenu.h"
int main(void)
{
 int rc=foundation_main();if(rc)return rc;
 @autoreleasepool {
  MTLDepthStencilDescriptor *ds=[MTLDepthStencilDescriptor new];
  ds.depthCompareFunction=MTLCompareFunctionLessEqual;ds.depthWriteEnabled=YES;
  mtl_depth_world=[mtl_device newDepthStencilStateWithDescriptor:ds];
  byte blue[4]={0,0,255,255};
  begin();api.SetClipRect(4,4,8,8);mtl_hud_blend=YES;
  MTL_SoF_Set3DInMenu(0);
  check(mtl_menu_active && mtl_hud_clipenabled,"orthographic menu retains clipping");
  check(fabsf(mtl_menu_mvp[0]-.0625f)<1e-6f,"menu uses full drawable dimensions");
  MTL_SoF_Set2D(0);
  check(!mtl_menu_active && !mtl_hud_blend && mtl_hud_clipenabled,"Set2D resets model/blend and preserves clip");
  MTL_SoF_Set3DInMenu(1);
  check(mtl_menu_active && !mtl_hud_clipenabled && mtl_menu_saved,"forced camera suspends clip");
  api.DrawFill(0,0,32,32,red);
  MTL_SoF_Set2D(1);api.DrawFill(0,0,32,32,blue);end();
  check(!mtl_menu_active && !mtl_menu_saved && mtl_hud_clipenabled,"restored menu state");
  pixel(2,2,255,0,0,"forced camera readies full window");
  pixel(6,6,0,0,255,"2D marker restores saved clip");
  pixel(13,6,255,0,0,"restored right edge clips marker");
  begin();OM_Set2DScale(1.5f);mtl_ui_w=8;mtl_ui_h=8;MTL_SoF_Set3DInMenu(0);
  check(fabsf(mtl_menu_mvp[0]-.09375f)<1e-6f,"fractional menu projection ignores stale world viewport");
  MTL_SoF_Set2D(0);check(mtl_ui_w==32 && mtl_ui_h==32,"Set2D full-window logical target");
  MTL_SoF_Set3DInMenu(1);MTL_SoF_Set2D(1);
  check(!mtl_hud_clipenabled,"unclipped forced camera remains unclipped");end();
  printf("Menu projection/state GPU checks: %d passed, %d failed\n",checks-failures,failures);
  return failures?1:0;
 }
}
