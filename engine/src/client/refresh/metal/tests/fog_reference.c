// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 math equivalence against the actual current GPL bodies.
#include <stdio.h>
#include <math.h>
#include <string.h>
#include "../mtl_fog_math.h"
typedef float vec3_t[3];typedef int qboolean;
#define false 0
#define true 1
#define VectorSubtract(a,b,o) do{for(int k_=0;k_<3;k_++)(o)[k_]=(a)[k_]-(b)[k_];}while(0)
#define DotProduct(a,b) ((a)[0]*(b)[0]+(a)[1]*(b)[1]+(a)[2]*(b)[2])
typedef struct {float normal[3],dist;} cplane_t;
typedef struct {
 int kind;float opacity,amplitude,start,range;unsigned char color[4];int flags;float speed,farwall;
 float mins[3],maxs[3],size[3];cplane_t *planes[5];int numplanes;int planemarked[5];float phase[10],phasespeed[10],w[10];
} fogregion_t;
static fogregion_t regions[2];static int numregions=2,viewregion=-1,lastregion=-1;
static struct {float vieworg[3];} r_newrefdef;
typedef struct {float value;const char *string;} cvar_t;
static cvar_t start={-1,"-1"},range={-1,"-1"},density={-1,"-1"},colorvar={-1,"-1"},mode={0,"0"};
static cvar_t *gl_fogstart=&start,*gl_fogend=&range,*gl_fogdensity=&density,*gl_fogcolor=&colorvar,*gl_fogmode=&mode;
#include "fog_reference_production.h"
static unsigned rng=7;static float sample(void){rng=rng*1664525u+1013904223u;return ((rng>>8)&65535)/65535.0f;}
static int failures,checks;
static void compare(float a,float b,const char *name){checks++;if(!isfinite(a)||!isfinite(b)||fabsf(a-b)>1e-5f*fmaxf(1,fabsf(b))){if(failures<8)fprintf(stderr,"FAIL: %s native %.9g GPL %.9g\n",name,a,b);failures++;}}
int main(void){
 mtl_fog_region_t native[2];mtl_fog_world_t f={0};f.regions=native;f.numregions=2;MTL_FogDefaultOverrides(&f.overrides);
 for(int trial=0;trial<256;trial++){
  memset(native,0,sizeof(native));memset(regions,0,sizeof(regions));cplane_t planes[2][5];
  for(int i=0;i<2;i++){
   mtl_fog_region_t *n=&native[i];fogregion_t *r=&regions[i];
   n->start=r->start=sample()*64;n->range=r->range=sample()*50+.1f;n->opacity=r->opacity=sample()*1.5f;
   n->flags=r->flags=trial%4;n->numplanes=r->numplanes=trial%6;
   for(int k=0;k<3;k++){n->mins[k]=r->mins[k]=-20;n->maxs[k]=r->maxs[k]=20;n->size[k]=r->size[k]=40;}
   for(int k=0;k<4;k++)n->color[k]=r->color[k]=(unsigned char)(sample()*255);
   for(int k=0;k<10;k++)n->w[k]=r->w[k]=sample()*8-4;
   for(int k=0;k<n->numplanes;k++){
    float norm[3]={sample()-.5f,sample()-.5f,sample()-.5f},d=sample()*40-20;
    memcpy(n->planes[k].normal,norm,sizeof(norm));memcpy(planes[i][k].normal,norm,sizeof(norm));n->planes[k].dist=planes[i][k].dist=d;r->planes[k]=&planes[i][k];
    n->planemarked[k]=(unsigned char)(r->planemarked[k]=(trial+k)%3==0);
   }
  }
  f.viewregion=viewregion=(trial%3)-1;f.lastregion=lastregion=(trial%2?1:-1);
  float p[3];for(int k=0;k<3;k++){p[k]=sample()*50-25;f.eye[k]=r_newrefdef.vieworg[k]=sample()*50-25;}
  int which=trial%2;float nd=MTL_FogThicknessEye(&f,which,p,f.eye),rd=ThicknessEye(which,p,r_newrefdef.vieworg);compare(nd,rd,"thickness");
  compare(MTL_FogOverlayAlpha(&f,which,p,nd),OverlayAlpha(which,p,rd),"overlay alpha");
  float nc[4],rc[4],ns,ne,rs,re;compare(MTL_FogPointFactor(&f,which,p,nc),GL3_Fog_PointFactor(which,p,rc),"point factor");
  for(int k=0;k<4;k++)compare(nc[k],rc[k],"point color");
  MTL_FogRegionLinear(&f,which,&ns,&ne,nc);GL3_Fog_RegionLinear(which,&rs,&re,rc);compare(ns,rs,"linear start");compare(ne,re,"linear end");
  for(int k=0;k<4;k++)compare(nc[k],rc[k],"linear color");
  for(int k=0;k<native[which].numplanes;k++)compare(native[which].planemarked[k],regions[which].planemarked[k],"plane mark");
 }
 printf("fog GPL reference: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}
