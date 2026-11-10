// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Legacy pass ordering and object state adapted from current GPL gl3_fog.c.
// Implements: SPEC-410 overlays/point fog, SPEC-411 object fog, SPEC-412 effects.
#ifndef OM_METAL_FOG_DRAW_H
#define OM_METAL_FOG_DRAW_H
#include "mtl_fog_math.h"
typedef struct {float position[3],pad;float color[4];} mtl_fog_vertex_t;
typedef struct {float eye[4],params[4],height[4],planes[5][4];} mtl_fog_pixel_uniform_t;
typedef struct {float color[4],plane[4],params[4];} mtl_linear_fog_t;
typedef struct {
 int surface,region,model;float origin[3],forward[3],right[3],up[3];
} mtl_fog_queued_t;
typedef void (*mtl_fog_emit_fn)(void *,const mtl_fog_vertex_t *,int,const mtl_fog_pixel_uniform_t *,int);
typedef struct {
 mtl_fog_world_t *world;mtl_fog_queued_t queue[MTL_FOG_MAX_QUEUE];int numqueued,polygons;
 float forward[3],right[3],up[3],overlaydim;int ppfog;
 int wallregion;float wallbest;mtl_fog_emit_fn emit;void *user;
} mtl_fog_draw_t;
static inline int MTL_FogDrawValidSurface(const mtl_fog_draw_t *d,int index)
{
 return d&&d->world&&index>=0&&index<d->world->numsurfaces;
}
static inline void MTL_FogDrawBegin(mtl_fog_draw_t *d,mtl_fog_world_t *world,
 const float eye[3],const float forward[3],const float right[3],const float up[3],int viewregion)
{
 d->world=world;d->numqueued=0;d->wallregion=-1;d->wallbest=1e30f;
 memcpy(d->forward,forward,sizeof(d->forward));memcpy(d->right,right,sizeof(d->right));memcpy(d->up,up,sizeof(d->up));
 if(world)MTL_FogBeginFrameState(world,eye,viewregion);
}
static inline void MTL_FogDrawMarkPlane(mtl_fog_draw_t *d,int surface,int original_plane)
{
 if(!MTL_FogDrawValidSurface(d,surface))return;int region=d->world->surfaces[surface].region;
 if(!MTL_FogValidRegion(d->world,region))return;
 mtl_fog_region_t *r=&d->world->regions[region];
 for(int k=0;k<r->numplanes;k++)if(r->planes[k].source_index==original_plane)r->planemarked[k]=1;
}
static inline void MTL_FogDrawQueueSurface(mtl_fog_draw_t *d,int surface,int flags)
{
 if(!MTL_FogDrawValidSurface(d,surface)||(d->world->mode==1&&!(flags&0x10000)))return;
 int region=d->world->surfaces[surface].region;if(!MTL_FogValidRegion(d->world,region))return;
 d->world->regionseen[region]=1;if(d->numqueued>=MTL_FOG_MAX_QUEUE)return;
 mtl_fog_queued_t *q=&d->queue[d->numqueued++];memset(q,0,sizeof(*q));q->surface=surface;q->region=region;
}
static inline void MTL_FogDrawQueueModel(mtl_fog_draw_t *d,int surface,int region,int flags,
 const float origin[3],const float forward[3],const float right[3],const float up[3])
{
 if(!MTL_FogDrawValidSurface(d,surface)||!MTL_FogValidRegion(d->world,region)||d->numqueued>=MTL_FOG_MAX_QUEUE||
  !d->world->surfaces[surface].numpolys||(d->world->mode==1&&!(flags&0x10000)))return;
 d->world->regionseen[region]=1;mtl_fog_queued_t *q=&d->queue[d->numqueued++];q->surface=surface;q->region=region;q->model=1;
 memcpy(q->origin,origin,sizeof(q->origin));memcpy(q->forward,forward,sizeof(q->forward));memcpy(q->right,right,sizeof(q->right));memcpy(q->up,up,sizeof(q->up));
}
static inline void MTL_FogDrawPixelParams(mtl_fog_draw_t *d,int region,const float eye[3],mtl_fog_pixel_uniform_t *p)
{
 mtl_fog_world_t *f=d->world;mtl_fog_region_t *r=&f->regions[region];float color[4];
 memset(p,0,sizeof(*p));memcpy(p->eye,eye,3*sizeof(float));p->eye[3]=1;
 MTL_FogParams(f,r,&p->params[0],&p->params[1],&p->params[2],color);
 p->params[3]=(r->flags&2)&&r->size[2]>0;p->height[0]=r->maxs[2];p->height[1]=r->size[2];p->height[2]=d->overlaydim;
 int n=0;
 if(f->viewregion!=region){
  for(int k=0;k<r->numplanes;k++)if(!r->planemarked[k]){
   memcpy(p->planes[n],r->planes[k].normal,3*sizeof(float));p->planes[n++][3]=r->planes[k].dist;
  }
 }
 p->height[3]=(float)n;
}
static inline void MTL_FogDrawQueued(mtl_fog_draw_t *d,int from,int to)
{
 mtl_fog_world_t *f=d->world;if(!f||!d->emit)return;
 for(int i=from;i<to;i++){
  mtl_fog_queued_t *q=&d->queue[i];mtl_fog_surface_t *fs=&f->surfaces[q->surface];mtl_fog_region_t *r=&f->regions[q->region];
  float eye[3],start,range,maxalpha,color[4];MTL_FogParams(f,r,&start,&range,&maxalpha,color);f->lastregion=q->region;
  for(int k=0;k<3;k++)eye[k]=f->eye[k]-(q->model?q->origin[k]:0);
  for(int j=0;j<fs->numpolys;j++){
   mtl_fog_poly_t *p=&fs->polys[j];d->polygons++;if(!p->verts||p->numverts<3||p->numverts>64)continue;
   mtl_fog_vertex_t vertices[64];mtl_fog_pixel_uniform_t pixel;
   memset(vertices,0,sizeof(vertices));memset(&pixel,0,sizeof(pixel));
   for(int k=0;k<p->numverts;k++){
    mtl_fog_vertex_t *v=&vertices[k];const float *local=p->verts[k];
    for(int a=0;a<3;a++)v->position[a]=q->model?q->origin[a]+local[0]*q->forward[a]-local[1]*q->right[a]+local[2]*q->up[a]:local[a];
    if(f->mode==3){unsigned hash=(unsigned)(q->surface*64+j)*2654435761u;for(int a=0;a<3;a++)v->color[a]=((hash>>(8*a))&255)/255.0f;v->color[3]=.8f;continue;}
    float thickness=MTL_FogThicknessEye(f,q->region,local,eye);
    for(int a=0;a<3;a++)v->color[a]=color[a]/255.0f;
    v->color[3]=MTL_FogOverlayAlpha(f,q->region,local,thickness)/255.0f*d->overlaydim;
    if(d->ppfog&&!q->model){v->color[3]=0;if(r->flags&1){float coord=floorf(fabsf(local[0])+fabsf(local[1])+fabsf(local[2]));if(isfinite(coord))v->color[3]=r->w[(int)fmodf(coord,10)];}}
    if(r->farwall!=0&&thickness<d->wallbest){d->wallbest=thickness;d->wallregion=q->region;}
   }
   /* Evaluate parameters after the CPU vertex walk has marked its planes. */
   if(d->ppfog&&!q->model&&f->mode!=3)MTL_FogDrawPixelParams(d,q->region,eye,&pixel);
   d->emit(d->user,vertices,p->numverts,&pixel,0);
  }
 }
}
static inline void MTL_FogDrawFarWall(mtl_fog_draw_t *d,int region)
{
 if(!d->emit||!MTL_FogValidRegion(d->world,region))return;
 float start,range,maxalpha,color[4];MTL_FogParams(d->world,&d->world->regions[region],&start,&range,&maxalpha,color);
 const float corners[4][2]={{-1,1},{1,1},{1,-1},{-1,-1}};mtl_fog_vertex_t v[4];mtl_fog_pixel_uniform_t pixel;
 memset(v,0,sizeof(v));memset(&pixel,0,sizeof(pixel));
 for(int i=0;i<4;i++){for(int k=0;k<3;k++)v[i].position[k]=d->world->eye[k]+2000*d->forward[k]+2500*corners[i][0]*d->right[k]+2500*corners[i][1]*d->up[k];for(int k=0;k<4;k++)v[i].color[k]=color[k]/255.0f;}
 d->emit(d->user,v,4,&pixel,1);
}
static inline void MTL_FogDrawPassState(mtl_fog_draw_t *d,int first)
{
 int n=d->numqueued;d->numqueued=0;if(first)d->polygons=0;
 if(!d->world||d->world->mode==2||!n)return;
 if(first)MTL_FogAdvanceShimmer(d->world);d->wallregion=-1;d->wallbest=1e30f;
 MTL_FogDrawQueued(d,0,n);
 if(first&&d->world->mode!=3){int view=d->world->viewregion;
  if(MTL_FogValidRegion(d->world,view)&&d->world->regions[view].farwall!=0)MTL_FogDrawFarWall(d,view);
  else if(d->wallregion>=0)MTL_FogDrawFarWall(d,d->wallregion);}
}
static inline void MTL_FogDrawSurfaceImmediate(mtl_fog_draw_t *d,int surface,int flags)
{
 if(!MTL_FogDrawValidSurface(d,surface)||d->world->mode==2||d->numqueued>=MTL_FOG_MAX_QUEUE||
  (d->world->mode==1&&!(flags&0x10000)))return;
 int region=d->world->surfaces[surface].region;if(!MTL_FogValidRegion(d->world,region))return;
 mtl_fog_queued_t *q=&d->queue[d->numqueued];memset(q,0,sizeof(*q));q->surface=surface;q->region=region;
 MTL_FogDrawQueued(d,d->numqueued,d->numqueued+1);
}
static inline void MTL_FogDrawPlane(const mtl_fog_draw_t *d,mtl_linear_fog_t *u)
{
 memcpy(u->plane,d->forward,3*sizeof(float));u->plane[3]=-MTL_FogDot(d->forward,d->world->eye);
}
static inline void MTL_FogDrawLinear(const mtl_fog_draw_t *d,int region,int hardware,mtl_linear_fog_t *u)
{
 memset(u,0,sizeof(*u));if(!d->world||!MTL_FogValidRegion(d->world,region))return;
 if(hardware){if(d->world->mode!=1)return;MTL_FogHardwareParams(d->world,region,&u->params[0],&u->params[1],u->color);u->color[3]=1;}
 else MTL_FogRegionLinear(d->world,region,&u->params[0],&u->params[1],u->color);
 u->params[2]=1;MTL_FogDrawPlane(d,u);
}
static inline void MTL_FogDrawEffectUniforms(mtl_fog_draw_t *d,int region,int blend,const float origin[3],mtl_linear_fog_t *u)
{
 memset(u,0,sizeof(*u));if(!d->world)return;
 float color[4],factor=MTL_FogPointFactor(d->world,region,origin,color);if(factor<=.01f)return;
 float delta[3]={origin[0]-d->world->eye[0],origin[1]-d->world->eye[1],origin[2]-d->world->eye[2]};
 u->params[1]=fabsf(MTL_FogDot(d->forward,delta))/factor;u->params[2]=1;
 if(blend!=2&&blend!=3)memcpy(u->color,color,3*sizeof(float));u->color[3]=1;MTL_FogDrawPlane(d,u);
}
static inline void MTL_FogDrawModelUniforms(mtl_fog_draw_t *d,int region,const float origin[3],int weapon,float objectfog,mtl_linear_fog_t *u)
{
 memset(u,0,sizeof(*u));if(weapon||!d->world)return;
 if(objectfog<=.5f)MTL_FogDrawLinear(d,region,0,u);
 else if(d->world->mode!=3)MTL_FogDrawEffectUniforms(d,region,1,origin,u);
}
#endif
