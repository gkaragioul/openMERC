// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 light sampling. The function under test is production source.
#include <math.h>
#include <stdio.h>
#include <string.h>
typedef float vec3_t[3];
typedef struct { float value; } cvar_t;
typedef struct { void *lightdata, *nodes; } mtl_model_t;
typedef struct { vec3_t origin, color; float intensity; } dlight_t;
static mtl_model_t world={(void *)1,(void *)1},*mtl_worldmodel=&world;
static struct { int num_dlights; dlight_t *dlights; } mtl_refdef;
static float mtl_sof_dirtable[250][3];
static int mtl_sof_dircount;
static cvar_t modulate={1},*mtl_modulate_cvar __attribute__((unused))=&modulate;
static float mtl_modulate_latched __attribute__((unused))=1;
static int traces,failures;
#define VectorSet(v,a,b,c) ((v)[0]=(a),(v)[1]=(b),(v)[2]=(c))
#define VectorCopy(a,b) memcpy((b),(a),sizeof(vec3_t))
#define VectorMA(a,s,b,c) do {for(int k=0;k<3;k++) (c)[k]=(a)[k]+(s)*(b)[k];}while(0)
#define VectorSubtract(a,b,c) do {for(int k=0;k<3;k++) (c)[k]=(a)[k]-(b)[k];}while(0)
static float VectorLength(const vec3_t v) {return sqrtf(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);}
static int MTL_LightTrace(mtl_model_t *model,void *node,const vec3_t p,const vec3_t end,vec3_t color)
{
  (void)model;(void)node;(void)end;traces++;
  VectorSet(color,p[0]*0.01f+0.1f,0.2f,0.3f);return 1;
}
#include "lightpoint_production.h"
static void check(int truth,const char *label)
{
  if(!truth){fprintf(stderr,"FAIL: %s\n",label);failures++;}
}
int main(void)
{
  vec3_t p={1,1,1},color;
  MTL_ClearLightCache();
  MTL_SoFLightPointDir(p,color,255);
  check(fabsf(color[0]-0.11f)<1e-6f && traces==1,"first cell query traces static light");
  p[0]=15;MTL_SoFLightPointDir(p,color,255);
  check(fabsf(color[0]-0.11f)<1e-6f && traces==1,"same 32-unit cell retains first static sample");
  dlight_t dl={{15,1,1},{1,0,0},128};mtl_refdef.num_dlights=1;mtl_refdef.dlights=&dl;
  MTL_SoFLightPointDir(p,color,255);
  check(fabsf(color[0]-0.61f)<1e-6f && traces==1,"dynamic contribution remains outside static cache");
  mtl_refdef.num_dlights=0;MTL_SoFLightPointDir(p,color,3);
  check(fabsf(color[0]-0.25f)<1e-6f && traces==2,"different direction has independent static sample");
  p[0]=33;MTL_SoFLightPointDir(p,color,255);
  check(fabsf(color[0]-0.43f)<1e-6f && traces==3,"crossing cell boundary traces again");
  MTL_ClearLightCache();p[0]=15;MTL_SoFLightPointDir(p,color,255);
  check(fabsf(color[0]-0.25f)<1e-6f && traces==4,"map/reset discards old cells");
  modulate.value=2;MTL_SoFLightPointDir(p,color,255);
  check(fabsf(color[0]-0.25f)<1e-6f && traces==4,"live gl_modulate changes wait for renderer restart");
  mtl_modulate_latched=2;MTL_SoFLightPointDir(p,color,255);
  check(fabsf(color[0]-0.5f)<1e-6f && traces==4,"final modulation is outside static cache");
  if(failures)return 1;
  puts("PASS: production light-point cell/direction cache, reset, dynamic light and modulation");
  return 0;
}
