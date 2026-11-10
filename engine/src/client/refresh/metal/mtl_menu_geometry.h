// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-412 menu model projection; direct Metal [0,1] clip depth.
#ifndef OM_METAL_MENU_GEOMETRY_H
#define OM_METAL_MENU_GEOMETRY_H
#include <math.h>
#include <string.h>
static inline void MTL_MenuProjection(float width,float height,float scale,int perspective,
 float nearclip,float farclip,float out[16])
{
 memset(out,0,16*sizeof(float));
 if(perspective) {
  float near=nearclip>0.1f?nearclip:0.1f,far=farclip;
  if(far<=near) far=near+1;
  float f=1/tanf(33.75084377109428f*(3.14159265358979323846f/360));
  out[0]=f/1.3333f;out[5]=f;out[10]=far/(near-far);out[11]=-1;
  out[14]=near*far/(near-far);
 } else {
  if(!(scale>0)) scale=1;
  out[0]=2*scale/width;out[5]=-2*scale/height;out[10]=1.0f/19998;
  out[12]=-1;out[13]=1;out[14]=0.5f;out[15]=1;
 }
}
#endif
