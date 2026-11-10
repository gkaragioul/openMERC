// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Checked native ownership adapted from GPL gl3_fog.c. Include after model types.
// Implements: SPEC-410 SoF region records, polygons and leaf classification.
#ifndef OM_METAL_FOG_H
#define OM_METAL_FOG_H
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>
#include "mtl_fog_math.h"

static void MTL_FogDestroy(mtl_fog_world_t *f)
{
 if(!f)return;
 if(f->polys)for(int i=0;i<f->numpolys;i++)free(f->polys[i].verts);
 free(f->polys);free(f->surfaces);free(f->leafregions);free(f->regions);free(f);
}
static void MTL_FogFree(mtl_model_t *root)
{
 if(!root||(root->owner&&root->owner!=root))return;
 MTL_FogDestroy(root->fog);root->fog=NULL;
}
static int MTL_FogLumpValid(const lump_t *l,size_t bytes,size_t stride)
{
 return l&&l->fileofs>=0&&l->filelen>=0&&(size_t)l->fileofs<=bytes&&
  (size_t)l->filelen<=bytes-(size_t)l->fileofs&&(size_t)l->filelen%stride==0;
}
static uint32_t MTL_FogReadU32(const byte *p)
{
 unsigned char v[4];memcpy(v,p,4);
 return (uint32_t)v[0]|((uint32_t)v[1]<<8)|((uint32_t)v[2]<<16)|((uint32_t)v[3]<<24);
}
static int32_t MTL_FogReadI32(const byte *p)
{
 uint32_t u=MTL_FogReadU32(p);int32_t value;memcpy(&value,&u,4);return value;
}
static unsigned MTL_FogReadU16(const byte *p)
{
 unsigned char v[2];memcpy(v,p,2);return (unsigned)v[0]|((unsigned)v[1]<<8);
}
static int MTL_FogReadI16(const byte *p)
{
 unsigned u=MTL_FogReadU16(p);return u<32768?(int)u:(int)u-65536;
}
static float MTL_FogReadFloat(const byte *p)
{
 uint32_t u=MTL_FogReadU32(p);float value;memcpy(&value,&u,4);return value;
}
static float MTL_FogRandom(float lo,float hi)
{
 return lo+(hi-lo)*((float)rand()/(float)RAND_MAX);
}
static int MTL_FogLoad(mtl_model_t *root,const byte *base,size_t bytes,
 const lump_t *faces,const lump_t *polys,const lump_t *regions,const lump_t *leafs)
{
 if(!root||!base||(root->owner&&root->owner!=root)||
  !MTL_FogLumpValid(faces,bytes,44)||!MTL_FogLumpValid(polys,bytes,8)||
  !MTL_FogLumpValid(regions,bytes,76)||!MTL_FogLumpValid(leafs,bytes,32)||
  faces->filelen/44!=root->numsurfaces||leafs->filelen/32!=root->numleafs||
  root->numsurfaces<0||root->numleafs<0||root->numplanes<0||root->numedges<0||root->numvertexes<0||root->numsurfedges<0||
  (root->numsurfaces&&!root->surfaces)||(root->numplanes&&!root->planes))return 0;
 mtl_fog_world_t *f=calloc(1,sizeof(*f));if(!f)return 0;
 f->numregions=regions->filelen/76;if(f->numregions>MTL_FOG_MAX_REGIONS)f->numregions=MTL_FOG_MAX_REGIONS;
 f->numsurfaces=root->numsurfaces;f->numleafs=root->numleafs;f->numpolys=polys->filelen/8;
 f->viewregion=f->lastregion=-1;MTL_FogDefaultOverrides(&f->overrides);
 f->regions=calloc(f->numregions?f->numregions:1,sizeof(*f->regions));
 f->surfaces=calloc(f->numsurfaces?f->numsurfaces:1,sizeof(*f->surfaces));
 f->leafregions=calloc(f->numleafs?f->numleafs:1,sizeof(*f->leafregions));
 f->polys=calloc(f->numpolys?f->numpolys:1,sizeof(*f->polys));
 if(!f->regions||!f->surfaces||!f->leafregions||!f->polys)goto invalid;
 for(int i=0;i<f->numregions;i++){
  const byte *rec=base+regions->fileofs+(size_t)i*76;mtl_fog_region_t *r=&f->regions[i];
  r->kind=MTL_FogReadI32(rec);r->opacity=MTL_FogReadFloat(rec+4);r->amplitude=MTL_FogReadFloat(rec+8);
  r->start=MTL_FogReadFloat(rec+12);r->range=MTL_FogReadFloat(rec+16);memcpy(r->color,rec+24,4);
  r->flags=MTL_FogReadI32(rec+28);r->speed=MTL_FogReadFloat(rec+32);r->farwall=MTL_FogReadFloat(rec+36);
  if(!isfinite(r->opacity)||!isfinite(r->amplitude)||!isfinite(r->start)||!isfinite(r->range)||!isfinite(r->speed)||!isfinite(r->farwall))goto invalid;
  for(int k=0;k<3;k++){r->mins[k]=999999;r->maxs[k]=-999999;}
 }
 /* One allocation per global polygon record bounds memory even if malformed
  * faces repeat an enormous overlapping span. Surface views only borrow it. */
 for(int i=0;i<f->numpolys;i++){
  const byte *rec=base+polys->fileofs+(size_t)i*8;int first=MTL_FogReadI32(rec),count=MTL_FogReadI32(rec+4);
  if(first<0||count<3||count>64||first>root->numsurfedges||count>root->numsurfedges-first||!root->surfedges||!root->edges||!root->vertexes)goto invalid;
  mtl_fog_poly_t *p=&f->polys[i];p->numverts=count;p->verts=malloc((size_t)count*sizeof(*p->verts));if(!p->verts)goto invalid;
  for(int j=0;j<count;j++){
   int edge=root->surfedges[first+j];if(edge==INT_MIN)goto invalid;
   int index=edge<0?-edge:edge;if(index<0||index>=root->numedges)goto invalid;
   unsigned vertex=root->edges[index].v[edge<0?1:0];if(vertex>=(unsigned)root->numvertexes)goto invalid;
   for(int k=0;k<3;k++){float v=root->vertexes[vertex].position[k];if(!isfinite(v))goto invalid;p->verts[j][k]=v;}
  }
 }
 for(int i=0;i<f->numsurfaces;i++){
  const byte *rec=base+faces->fileofs+(size_t)i*44;mtl_fog_surface_t *s=&f->surfaces[i];
  int region=MTL_FogReadI16(rec+12),first=MTL_FogReadI32(rec+16),count=(int)MTL_FogReadU16(rec+20);
  unsigned plane=MTL_FogReadU16(rec);s->region=-1;
  if(plane>=(unsigned)root->numplanes)goto invalid;
  if(region<0||region>=f->numregions)continue;
  s->region=region;mtl_fog_region_t *r=&f->regions[region];
  if(root->surfaces[i].flags&0x10000){
   int k;for(k=0;k<r->numplanes;k++)if(r->planes[k].source_index==(int)plane)break;
   if(k==r->numplanes&&k<MTL_FOG_MAX_PLANES){
    mtl_fog_plane_t *out=&r->planes[r->numplanes++];out->source_index=(int)plane;
    for(int a=0;a<3;a++){out->normal[a]=root->planes[plane].normal[a];if(!isfinite(out->normal[a]))goto invalid;}
    out->dist=root->planes[plane].dist;if(!isfinite(out->dist))goto invalid;
   }
  }
  if(!count){if(first < -1||first>f->numpolys)goto invalid;continue;}
  if(first<0||first>f->numpolys||count>f->numpolys-first)goto invalid;
  s->polys=&f->polys[first];s->numpolys=count;
  for(int j=0;j<count;j++)for(int v=0;v<s->polys[j].numverts;v++)for(int a=0;a<3;a++){
   float x=s->polys[j].verts[v][a];if(x<r->mins[a])r->mins[a]=x;if(x>r->maxs[a])r->maxs[a]=x;
  }
 }
 for(int i=0;i<f->numleafs;i++){
  int region=MTL_FogReadI16(base+leafs->fileofs+(size_t)i*32+8);
  /* Stock maps without volumes retain volume0 in the solid leaf. The GPL
   * loader maps every unavailable region to the none sentinel. */
  f->leafregions[i]=(short)(region>=0&&region<f->numregions?region:-1);
 }
 /* Consume random phases only after every structural check succeeds. */
 for(int i=0;i<f->numregions;i++){
  mtl_fog_region_t *r=&f->regions[i];for(int k=0;k<3;k++)r->size[k]=r->maxs[k]-r->mins[k];
  if(r->flags&1)for(int j=0;j<10;j++){r->phase[j]=MTL_FogRandom(0,20);r->phasespeed[j]=MTL_FogRandom(.05f,.3f);}
 }
 MTL_FogDestroy(root->fog);root->fog=f;return 1;
invalid:
 MTL_FogDestroy(f);return 0;
}
/* Validate addresses with integer arithmetic, avoiding subtraction of unrelated
 * pointers when callers supply a stale or foreign surface/leaf descriptor. */
static int MTL_FogArrayIndex(const void *p,const void *base,size_t stride,int count)
{
 uintptr_t a=(uintptr_t)p,b=(uintptr_t)base;if(!p||!base||a<b||count<=0)return -1;
 uintptr_t delta=a-b;if(delta%stride||delta/stride>=(uintptr_t)count)return -1;
 return (int)(delta/stride);
}
static int MTL_FogSurfaceRegion(const mtl_surface_t *surface)
{
 mtl_model_t *root=mtl_worldmodel;if(!root||!root->fog)return -1;
 int i=MTL_FogArrayIndex(surface,root->surfaces,sizeof(*surface),root->fog->numsurfaces);
 return i>=0?root->fog->surfaces[i].region:-1;
}
static int MTL_FogRegionOfPoint(const float p[3])
{
 mtl_model_t *root=mtl_worldmodel;if(!root||!root->fog||!root->nodes||!root->fog->numregions)return -1;
 const mleaf_t *leaf=Mod_PointInLeaf(p,root->nodes);
 int i=MTL_FogArrayIndex(leaf,root->leafs,sizeof(*leaf),root->fog->numleafs);
 return i>=0?root->fog->leafregions[i]:-1;
}
static int MTL_FogNumRegions(void)
{
 return mtl_worldmodel&&mtl_worldmodel->fog?mtl_worldmodel->fog->numregions:0;
}
#endif
