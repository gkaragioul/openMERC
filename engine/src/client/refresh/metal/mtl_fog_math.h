// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Adapted from the GPL gl3_fog.c; all state is explicitly supplied.
// Implements: SPEC-410 fog thickness, overlay alpha, point and linear fog.
#ifndef OM_METAL_FOG_MATH_H
#define OM_METAL_FOG_MATH_H
#include <math.h>
#include <stdio.h>
#include <string.h>
#define MTL_FOG_MAX_REGIONS 256
#define MTL_FOG_MAX_PLANES 5
#define MTL_FOG_MAX_QUEUE 1024

typedef struct {float normal[3],dist;int source_index;} mtl_fog_plane_t;
typedef struct {
 int kind,flags;float opacity,amplitude,start,range,speed,farwall;
 unsigned char color[4];float mins[3],maxs[3],size[3];
 mtl_fog_plane_t planes[MTL_FOG_MAX_PLANES];int numplanes;
 unsigned char planemarked[MTL_FOG_MAX_PLANES];
 float phase[10],phasespeed[10],w[10];
} mtl_fog_region_t;
typedef struct {int numverts;float (*verts)[3];} mtl_fog_poly_t;
typedef struct {int region,numpolys;mtl_fog_poly_t *polys;} mtl_fog_surface_t;
typedef struct {
 float start,range,density,time,densityrange;
 int color_enabled;const char *color;
} mtl_fog_overrides_t;
typedef struct mtl_fog_world_s {
 mtl_fog_region_t *regions;int numregions;
 mtl_fog_surface_t *surfaces;int numsurfaces;
 mtl_fog_poly_t *polys;int numpolys;
 short *leafregions;int numleafs;
 int viewregion,lastregion,mode;float eye[3];
 unsigned char regionseen[MTL_FOG_MAX_REGIONS];
 mtl_fog_overrides_t overrides;
} mtl_fog_world_t;

static inline void MTL_FogDefaultOverrides(mtl_fog_overrides_t *o)
{
 memset(o,0,sizeof(*o));o->start=o->range=o->density=o->time=o->densityrange=-1;
}
static inline int MTL_FogValidRegion(const mtl_fog_world_t *f,int region)
{
 return f && f->regions && region>=0 && region<f->numregions;
}
static inline void MTL_FogParams(const mtl_fog_world_t *f,const mtl_fog_region_t *r,
 float *start,float *range,float *maxalpha,float color[4])
{
 const mtl_fog_overrides_t *o=&f->overrides;
 *start=o->start>=0?o->start:r->start;*range=o->range>=0?o->range:r->range;
 *maxalpha=255.0f*(o->density>=0?o->density:r->opacity);
 for(int i=0;i<4;i++)color[i]=r->color[i];
 if(o->color_enabled){float c[3]={0};if(o->color)sscanf(o->color,"%f %f %f",&c[0],&c[1],&c[2]);for(int i=0;i<3;i++)color[i]=c[i];}
}
static inline float MTL_FogDot(const float a[3],const float b[3])
{
 return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
}
static inline float MTL_FogThicknessEye(mtl_fog_world_t *f,int region,const float p[3],const float eye[3])
{
 if(!MTL_FogValidRegion(f,region)||!p||!eye)return 0;
 mtl_fog_region_t *r=&f->regions[region];float d[3]={p[0]-eye[0],p[1]-eye[1],p[2]-eye[2]};
 float D=MTL_FogDot(d,d),D0=D;
 if(f->viewregion!=region)for(int k=0;k<r->numplanes;k++){
  if(r->planemarked[k])continue;
  const mtl_fog_plane_t *pl=&r->planes[k];float a=MTL_FogDot(pl->normal,eye)-pl->dist,b=pl->dist-MTL_FogDot(pl->normal,p);
  if(a!=0&&b!=0&&((a>0)!=(b>0))){r->planemarked[k]=1;continue;}
  if(a*a+b*b>0){float t=D0*b*b/(a*a+b*b);if(t<D)D=t;}
 }
 if(r->flags&1){float coord=floorf(fabsf(p[0])+fabsf(p[1])+fabsf(p[2]));
  /* fmod before int conversion also bounds large finite coordinates. */
  if(isfinite(coord))D+=r->w[(int)fmodf(coord,10.0f)];}
 return D;
}
static inline float MTL_FogOverlayAlpha(const mtl_fog_world_t *f,int region,const float p[3],float thickness)
{
 if(!MTL_FogValidRegion(f,region)||!p)return 0;
 const mtl_fog_region_t *r=&f->regions[region];float start,range,maxalpha,color[4];
 MTL_FogParams(f,r,&start,&range,&maxalpha,color);float a=range!=0?(thickness-start)/range:0;
 if(a<0)a=0;if(a>maxalpha)a=maxalpha;
 if((r->flags&2)&&r->size[2]>0){float h=(r->maxs[2]-p[2])/r->size[2];a*=h*h;}
 return floorf(a);
}
static inline float MTL_FogPointFactor(mtl_fog_world_t *f,int region,const float p[3],float color[4])
{
 if(!MTL_FogValidRegion(f,region)||f->mode==2||!color)return 0;
 float D=MTL_FogThicknessEye(f,region,p,f->eye),start,range,maxalpha,col[4];
 int source=MTL_FogValidRegion(f,f->lastregion)?f->lastregion:region;
 MTL_FogParams(f,&f->regions[source],&start,&range,&maxalpha,col);
 float a=range!=0?(D-start)/range:0;if(a<0)a=0;if(a>maxalpha)a=maxalpha;
 for(int i=0;i<4;i++)color[i]=col[i]/255.0f;
 float factor=a/255.0f;return factor>1?1:factor;
}
/* Ghoul ghl_obj_fog0 reads raw map parameters in the current GPL source. */
static inline int MTL_FogRegionLinear(const mtl_fog_world_t *f,int region,float *start,float *end,float color[4])
{
 if(!MTL_FogValidRegion(f,region)||!start||!end||!color)return 0;
 const mtl_fog_region_t *r=&f->regions[region];*start=r->start+90;
 *end=r->opacity!=0?r->range/r->opacity:r->range;
 for(int i=0;i<4;i++)color[i]=r->color[i]/255.0f;return 1;
}
/* gl_fogmode1 world hardware fog applies overrides before converting units. */
static inline int MTL_FogHardwareParams(const mtl_fog_world_t *f,int region,float *start,float *end,float color[4])
{
 if(!MTL_FogValidRegion(f,region)||!start||!end||!color)return 0;
 float s,range,maxalpha;MTL_FogParams(f,&f->regions[region],&s,&range,&maxalpha,color);
 float opacity=maxalpha/255.0f;*start=s+90;*end=opacity!=0?range/opacity:range;
 for(int i=0;i<4;i++)color[i]/=255.0f;return 1;
}
/* Call only at the first actually rendered overlay pass with a nonempty queue. */
static inline void MTL_FogAdvanceShimmer(mtl_fog_world_t *f)
{
 if(!f)return;
 for(int i=0;i<f->numregions;i++){
  mtl_fog_region_t *r=&f->regions[i];if(!(r->flags&1))continue;
  float speed=f->overrides.time>=0?f->overrides.time:r->speed,amp=f->overrides.densityrange>=0?f->overrides.densityrange:r->amplitude;
  for(int j=0;j<10;j++){r->phase[j]+=r->phasespeed[j]*speed;float c=cosf(r->phase[j])*amp;r->w[j]=c*fabsf(c);}
 }
}
static inline void MTL_FogBeginFrameState(mtl_fog_world_t *f,const float eye[3],int viewregion)
{
 if(!f)return;
 memcpy(f->eye,eye,sizeof(f->eye));f->viewregion=MTL_FogValidRegion(f,viewregion)?viewregion:-1;
 memset(f->regionseen,0,sizeof(f->regionseen));
 for(int i=0;i<f->numregions;i++)memset(f->regions[i].planemarked,0,sizeof(f->regions[i].planemarked));
 /* lastregion intentionally survives frames, matching current GPL behavior. */
}
#endif
