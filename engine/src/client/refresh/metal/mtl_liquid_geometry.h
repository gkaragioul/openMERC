/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 1997-2001 Id Software, Inc.
 * Copyright (C) 2016-2017 Daniel Gibson
 * Copyright (C) 2026 OpenMerc contributors
 *
 * Subdivision adapted from GPL gl3_warp.c (Quake II/Yamagi). This program
 * is free software under GNU GPL version 2 or, at your option, any later
 * version; distributed WITHOUT ANY WARRANTY. See LICENSE.
 * Implements: SPEC-410 liquids, SPEC-411 section 8, SPEC-413 section 1,
 *             SPEC-AMEND-006 I4c.1.
 */
#ifndef MTL_LIQUID_GEOMETRY_H
#define MTL_LIQUID_GEOMETRY_H
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct mtl_liquid_poly_s {
 struct mtl_liquid_poly_s *next;
 int count;
 float pos[64][3]; /* centre, original ring, duplicate first ring point */
} mtl_liquid_poly_t;

/* Deliberately the native alias stream's alignment, without an alias model's
 * lighting clamp. Metal float3 occupies 16 bytes, followed by UV and colour. */
typedef struct {
 float pos[3],pos_pad,uv[2],uv_pad[2],color[4];
} mtl_liquid_vertex_t;

typedef void (*mtl_liquid_light_fn)(void *,const float[3],float[3]);
typedef struct {
 const float *matrix; /* NULL = world; otherwise original model -> world */
 const float *table;
 float clock;
 unsigned flags;
 float vecs[2][4]; /* original model-space texinfo; offsets ignored */
 float normal[3]; /* stored plane normal, transformed to world, NOT side-flipped */
 float eye[3],forward[3],right[3],up[3];
} mtl_liquid_params_t;

static void MTL_LiquidFree(mtl_liquid_poly_t *poly)
{
 while(poly){mtl_liquid_poly_t *next=poly->next;free(poly);poly=next;}
}

static int MTL_LiquidSplit(int n,const float (*v)[3],mtl_liquid_poly_t **head,
 int depth,int *pieces)
{
 if(n<3||n>60||depth>64||*pieces>=65536)return 0;
 float mins[3]={9999,9999,9999},maxs[3]={-9999,-9999,-9999};
 for(int j=0;j<n;j++)for(int k=0;k<3;k++){
  if(!isfinite(v[j][k]))return 0;
  if(v[j][k]<mins[k])mins[k]=v[j][k];
  if(v[j][k]>maxs[k])maxs[k]=v[j][k];
 }
 for(int axis=0;axis<3;axis++){
  float middle=(mins[axis]+maxs[axis])*.5;
  middle=64.0f*floor(middle/64.0f+.5);
  if(maxs[axis]-middle<8||middle-mins[axis]<8)continue;
  float dist[61];for(int j=0;j<n;j++)dist[j]=v[j][axis]-middle;dist[n]=dist[0];
  float front[64][3],back[64][3];int nf=0,nb=0;
  for(int j=0;j<n;j++){
   if(dist[j]>=0){memcpy(front[nf++],v[j],12);}
   if(dist[j]<=0){memcpy(back[nb++],v[j],12);}
   if(dist[j]==0||dist[j+1]==0)continue;
   if((dist[j]>0)!=(dist[j+1]>0)){
    float fraction=dist[j]/(dist[j]-dist[j+1]);
    for(int k=0;k<3;k++)front[nf][k]=back[nb][k]=v[j][k]+fraction*(v[(j+1)%n][k]-v[j][k]);
    nf++;nb++;
   }
  }
  /* GPL subdivision recurses front then back and prepends each leaf. Light
   * sampling is stateful, so the resulting reversed DFS order is required. */
  return MTL_LiquidSplit(nf,front,head,depth+1,pieces)&&
         MTL_LiquidSplit(nb,back,head,depth+1,pieces);
 }
 mtl_liquid_poly_t *poly=calloc(1,sizeof(*poly));if(!poly)return 0;
 poly->count=n+2;poly->next=*head;*head=poly;(*pieces)++;
 for(int j=0;j<n;j++)for(int k=0;k<3;k++){
  poly->pos[j+1][k]=v[j][k];poly->pos[0][k]+=v[j][k];
 }
 /* Same double reciprocal then float scale as GPL VectorScale. */
 for(int k=0;k<3;k++)poly->pos[0][k]*=(1.0/n);
 memcpy(poly->pos[n+1],poly->pos[1],12);
 return 1;
}

static int MTL_LiquidSubdivide(int n,const float (*ring)[3],mtl_liquid_poly_t **out)
{
 if(!out)return 0;
 *out=NULL;int pieces=0;
 if(!ring||!MTL_LiquidSplit(n,ring,out,0,&pieces)){
  MTL_LiquidFree(*out);*out=NULL;return 0;
 }
 return 1;
}

/* Approved spec: minimum over all subdivided vertices, before waves.
 * Sorting must not issue light queries. */
static float MTL_LiquidSortKey(const mtl_liquid_poly_t *poly,const float eye[3],
 float far_squared)
{
 float best=far_squared;
 for(;poly;poly=poly->next)for(int i=0;i<poly->count;i++){
  float d[3];for(int k=0;k<3;k++)d[k]=poly->pos[i][k]-eye[k];
  float key=d[0]*d[0]+d[1]*d[1]+d[2]*d[2];if(key<best)best=key;
 }
 return best;
}

/* Recover the original ring, including its collinear points, from the world
 * loader's ordinary triangle fan expansion. No normalized UV is reused. */
static int MTL_LiquidReadRing(const void *vertices,size_t stride,int count,float ring[60][3])
{
 if(!vertices||!ring||stride<12||count<3||count%3||count/3+2>60)return 0;
 int n=count/3+2;
 for(int i=0;i<n;i++){
  int index=i<2?i:3*(i-2)+2;
  memcpy(ring[i],(const char*)vertices+(size_t)index*stride,12);
 }
 return n;
}

static void MTL_LiquidTableInit(float table[256],int *starts)
{
 float amplitude=8;
 ++*starts;for(int i=0;i<*starts;i++)amplitude*=.5f;
 for(int i=0;i<256;i++)table[i]=amplitude*sinf(2.0f*3.14159265358979323846f*i/256.0f);
}

static float MTL_LiquidTurb(const float table[256],float x)
{
 float index=x*(256.0f/(2.0f*3.14159265358979323846f));
 /* Ordinary game-clock values follow the reference truncation exactly;
  * range reduction keeps malformed/huge clocks out of undefined int casts. */
 if(!isfinite(index))return table[0];
 if(index>=2147483648.0f||index< -2147483648.0f)index=fmodf(index,256);
 return table[((int)index)&255];
}

static float MTL_LiquidDot(const float *a,const float *b)
{return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}

static void MTL_LiquidTransform(const float *matrix,const float in[3],float out[3],int point)
{
 float p[3];
 for(int k=0;k<3;k++){
  if(!matrix)p[k]=in[k];
  else if(point)p[k]=matrix[12+k]+in[0]*matrix[k]+in[1]*matrix[4+k]+in[2]*matrix[8+k];
  else p[k]=in[0]*matrix[k]+in[1]*matrix[4+k]+in[2]*matrix[8+k];
 }
 memcpy(out,p,12);
}

static void MTL_LiquidSphere(const mtl_liquid_params_t *p,const float pos[3],float st[2])
{
 float d[3],u[3],n[3],r[3];for(int k=0;k<3;k++)d[k]=pos[k]-p->eye[k];
 u[0]=MTL_LiquidDot(d,p->right);u[1]=MTL_LiquidDot(d,p->up);u[2]=-MTL_LiquidDot(d,p->forward);
 float length=sqrtf(MTL_LiquidDot(u,u));if(length)for(int k=0;k<3;k++)u[k]*=1/length;
 n[0]=MTL_LiquidDot(p->normal,p->right);n[1]=MTL_LiquidDot(p->normal,p->up);n[2]=-MTL_LiquidDot(p->normal,p->forward);
 float scale=2*MTL_LiquidDot(n,u);for(int k=0;k<3;k++)r[k]=u[k]-scale*n[k];
 float m=2*sqrtf(r[0]*r[0]+r[1]*r[1]+(r[2]+1)*(r[2]+1));if(m==0)m=1;
 st[0]=r[0]/m+.5f;st[1]=r[1]/m+.5f;
}

static void MTL_LiquidEvaluate(const mtl_liquid_params_t *p,const float local[3],int pass,
 mtl_liquid_light_fn light,void *context,mtl_liquid_vertex_t *out)
{
 memset(out,0,sizeof(*out));float world[3],height=0,multiplier=1,alpha=1;
 MTL_LiquidTransform(p->matrix,local,world,1);
 if(p->flags&0x2000){
  float a=(2.3f*world[0]+world[1])*.015f,b=(1.7f*world[1]+world[0])*.015f;
  height=.5625f*MTL_LiquidTurb(p->table,a+2.0f*p->clock);
  multiplier=(height+4.5f)*.1f+.1f;
  alpha=(.5625f*MTL_LiquidTurb(p->table,a+2.7f*p->clock)*.125f*
   MTL_LiquidTurb(p->table,b+3.37f*p->clock)+4.5f)*.038889f+.6f;
 }
 memcpy(out->pos,world,12);out->pos[2]+=height;
 if(pass){MTL_LiquidSphere(p,out->pos,out->uv);for(int k=0;k<4;k++)out->color[k]=1;}
 else {
  float s=MTL_LiquidDot(local,p->vecs[0]),t=MTL_LiquidDot(local,p->vecs[1]);
  out->uv[0]=(s+MTL_LiquidTurb(p->table,t*.125f+p->clock))/64;
  out->uv[1]=(t+MTL_LiquidTurb(p->table,s*.125f+p->clock))/64;
  /* Exactly one query per polygon vertex, including centre and closing
   * duplicate, in reference order; query before wave displacement. */
  light(context,world,out->color);
  for(int k=0;k<3;k++)out->color[k]*=multiplier;
  out->color[3]=alpha;
 }
}
#endif
