// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 fog thickness, alpha, point and hardware calculations.
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "../mtl_fog_math.h"
static int checks, failures;
static void near(float actual,float expected,const char *name) {
 checks++;if(!isfinite(actual)||fabsf(actual-expected)>0.0001f){fprintf(stderr,"FAIL: %s got %.9g expected %.9g\n",name,actual,expected);failures++;}
}
int main(void) {
 mtl_fog_region_t regions[2]={0};mtl_fog_world_t f={0};
 f.regions=regions;f.numregions=2;f.viewregion=-1;f.lastregion=-1;MTL_FogDefaultOverrides(&f.overrides);
 float p[3]={3,4,0},eye[3]={0,0,0},color[4],s,e;
 near(MTL_FogThicknessEye(&f,0,p,eye),25,"no boundary squared distance");
 regions[0].numplanes=1;regions[0].planes[0].normal[0]=1;regions[0].planes[0].dist=2;
 near(MTL_FogThicknessEye(&f,0,p,eye),5,"crossing boundary clips squared thickness");
 p[0]=1;p[1]=0;near(MTL_FogThicknessEye(&f,0,p,eye),1,"same-side boundary marks instead of clipping");
 near(regions[0].planemarked[0],1,"same-side mark persists");
 p[0]=3;p[1]=4;near(MTL_FogThicknessEye(&f,0,p,eye),25,"already marked plane skipped");
 regions[0].planemarked[0]=0;f.viewregion=0;
 near(MTL_FogThicknessEye(&f,0,p,eye),25,"inside view region skips clipping");
 regions[0].flags=1;regions[0].w[7]=13;
 near(MTL_FogThicknessEye(&f,0,p,eye),38,"shimmer uses floor absolute coordinate sum modulo10");
 regions[0].flags=0;regions[0].start=4;regions[0].range=4;regions[0].opacity=.5;
 near(MTL_FogOverlayAlpha(&f,0,p,15),2,"overlay floors fractional byte alpha");
 near(MTL_FogOverlayAlpha(&f,0,p,0),0,"overlay clamps negative");
 near(MTL_FogOverlayAlpha(&f,0,p,99999),127,"overlay floors maximum opacity");
 regions[0].flags=2;regions[0].maxs[2]=10;regions[0].size[2]=10;p[2]=5;
 near(MTL_FogOverlayAlpha(&f,0,p,99999),31,"height applies after maximum clamp before floor");
 regions[0].range=0;near(MTL_FogOverlayAlpha(&f,0,p,99999),0,"zero range gives zero overlay");
 regions[0].range=4;regions[1].start=0;regions[1].range=2;regions[1].opacity=2;
 regions[1].color[0]=64;regions[1].color[1]=128;regions[1].color[2]=255;regions[1].color[3]=200;
 f.lastregion=1;memcpy(f.eye,eye,sizeof(eye));
 near(MTL_FogPointFactor(&f,0,p,color),25.0f/255,"point uses last region, no floor and no height");
 regions[1].range=4;near(MTL_FogPointFactor(&f,0,p,color),12.5f/255,"point preserves fractional byte alpha");regions[1].range=2;
 near(color[1],128.0f/255,"point uses last region color");
 p[0]=100;near(MTL_FogPointFactor(&f,0,p,color),1,"point caps fraction at one");
 f.mode=2;near(MTL_FogPointFactor(&f,0,p,color),0,"mode2 disables point fog");f.mode=0;
 near(MTL_FogRegionLinear(&f,0,&s,&e,color),1,"valid linear region");
 near(s,94,"linear start adds90");near(e,8,"linear end divides raw opacity");
 regions[0].opacity=0;MTL_FogRegionLinear(&f,0,&s,&e,color);near(e,4,"zero opacity linear end uses range");
 f.overrides.start=20;f.overrides.range=100;f.overrides.density=.25;f.overrides.color_enabled=1;f.overrides.color="10 20 30";
 MTL_FogHardwareParams(&f,0,&s,&e,color);near(s,110,"hardware override start");near(e,400,"hardware override end density");near(color[2],30.0f/255,"override color string parsed");
 MTL_FogRegionLinear(&f,0,&s,&e,color);near(s,94,"object raw RegionLinear excludes hardware overrides");
 f.overrides.color="12 invalid";MTL_FogHardwareParams(&f,0,&s,&e,color);near(color[0],12.0f/255,"partial override color first component");near(color[1],0,"partial override color missing component zero");
 near(MTL_FogRegionLinear(&f,-1,&s,&e,color),0,"invalid linear region rejected");
 MTL_FogDefaultOverrides(&f.overrides);regions[0].flags=1;regions[0].speed=2;regions[0].amplitude=3;
 regions[0].phase[0]=0;regions[0].phasespeed[0]=.25f;MTL_FogAdvanceShimmer(&f);
 near(regions[0].phase[0],.5f,"shimmer advances by phase speed times region speed");
 near(regions[0].w[0],cosf(.5f)*cosf(.5f)*9,"shimmer uses signed square cosine");
 regions[0].planemarked[0]=1;f.regionseen[0]=1;f.lastregion=1;MTL_FogBeginFrameState(&f,eye,0);
 near(regions[0].planemarked[0],0,"frame reset clears plane marks");near(f.regionseen[0],0,"frame reset clears seen regions");near(f.lastregion,1,"frame reset preserves last processed region");
 regions[0].kind=99;regions[0].flags=0;regions[0].opacity=.5f;p[0]=3;p[1]=4;p[2]=0;
 near(MTL_FogOverlayAlpha(&f,0,p,15),2,"unused fog kind has no legacy effect");
 printf("fog math: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}
