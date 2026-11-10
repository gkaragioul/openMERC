// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 overlay passes, queue bounds and object fog state.
#include <stdio.h>
#include <math.h>
#include <string.h>
#include "../mtl_fog_draw.h"
static int failures,checks,emits,farwalls;static float first_alpha,last_pos[3],last_alpha;static mtl_fog_pixel_uniform_t last_pixel;
static void check(int p,const char *name){checks++;if(!p){fprintf(stderr,"FAIL: %s\n",name);failures++;}}
static void emit(void *user,const mtl_fog_vertex_t *v,int count,const mtl_fog_pixel_uniform_t *pp,int wall){(void)user;(void)count;emits++;farwalls+=wall;if(emits==1)first_alpha=v[0].color[3];memcpy(last_pos,v[0].position,sizeof(last_pos));last_alpha=v[0].color[3];last_pixel=*pp;}
int main(void){
 mtl_fog_region_t region={0};mtl_fog_surface_t faces[2]={{0,1,NULL},{0,1,NULL}};float points[3][3]={{3,4,0},{6,8,0},{3,4,2}};mtl_fog_poly_t poly={3,points};faces[0].polys=faces[1].polys=&poly;
 mtl_fog_world_t world={0};world.regions=&region;world.numregions=1;world.surfaces=faces;world.numsurfaces=2;world.viewregion=-1;world.lastregion=-1;MTL_FogDefaultOverrides(&world.overrides);
 region.opacity=1;region.range=1;region.color[0]=255;region.color[3]=255;region.numplanes=1;region.planes[0].source_index=7;region.planes[0].normal[0]=1;region.planes[0].dist=100;
 mtl_fog_draw_t d={0};d.emit=emit;d.overlaydim=1;float eye[3]={0},forward[3]={1,0,0},right[3]={0,-1,0},up[3]={0,0,1};
 MTL_FogDrawBegin(&d,&world,eye,forward,right,up,-1);MTL_FogDrawMarkPlane(&d,0,7);check(region.planemarked[0],"boundary plane mark uses stable original identity");
 MTL_FogDrawQueueSurface(&d,0,0x10000);MTL_FogDrawQueueSurface(&d,1,4);check(d.numqueued==2&&world.regionseen[0],"boundary and sky regions queue before classification");
 MTL_FogDrawSurfaceImmediate(&d,1,0);check(emits==1&&d.numqueued==2,"immediate alpha overlay preserves original queued overlay");
 MTL_FogDrawPassState(&d,1);check(emits==3&&d.numqueued==0&&d.polygons==2,"first pass consumes all original queued overlays");
 world.mode=1;MTL_FogDrawQueueSurface(&d,0,0);check(d.numqueued==0,"mode1 excludes interior overlay");MTL_FogDrawQueueSurface(&d,0,0x10000);check(d.numqueued==1,"mode1 retains boundary overlay");MTL_FogDrawPassState(&d,0);
 world.mode=2;MTL_FogDrawQueueSurface(&d,0,0);int before=emits;MTL_FogDrawPassState(&d,1);check(emits==before&&d.numqueued==0,"mode2 emits no overlay and drains queue");
 world.mode=3;MTL_FogDrawQueueSurface(&d,0,0);MTL_FogDrawPassState(&d,1);check(fabsf(last_alpha-.8f)<1e-6f,"mode3 identity color alpha .8");
 world.mode=0;region.flags=1;region.phase[0]=0;region.phasespeed[0]=.25f;region.speed=2;region.amplitude=1;region.farwall=1;
 MTL_FogDrawQueueSurface(&d,0,0);MTL_FogDrawPassState(&d,1);check(region.phase[0]==.5f&&farwalls==1,"first rendered overlay advances shimmer and far wall");
 MTL_FogDrawQueueSurface(&d,0,0);MTL_FogDrawPassState(&d,0);check(region.phase[0]==.5f&&farwalls==1,"second overlay advances neither shimmer nor far wall");
 check(last_pos[0]==3&&last_pos[1]==4,"world overlay retains polygon coordinates");
 region.flags=0;region.farwall=0;region.numplanes=0;d.ppfog=1;MTL_FogDrawQueueSurface(&d,0,0);MTL_FogDrawPassState(&d,1);check(last_pixel.eye[3]==1&&last_alpha==0,"per-pixel world overlay carries shader params and shimmer input");
 float origin[3]={10,20,30},fwd[3]={0,1,0},rgt[3]={1,0,0},top[3]={0,0,1};
 MTL_FogDrawQueueModel(&d,0,0,0,origin,fwd,rgt,top);MTL_FogDrawPassState(&d,0);check(last_pos[0]==6&&last_pos[1]==23&&last_pos[2]==30,"inline overlay transforms axes while preserving original local thickness inputs");check(last_pixel.eye[3]==0,"inline overlays keep vertex alpha under ppfog");
 for(int i=0;i<1025;i++)MTL_FogDrawQueueSurface(&d,0,0);check(d.numqueued==1024,"queue cap1024 bounded");before=emits;MTL_FogDrawSurfaceImmediate(&d,0,0);check(emits==before&&d.numqueued==1024,"full queue blocks immediate temporary slot");d.numqueued=0;
 mtl_linear_fog_t u;world.mode=1;MTL_FogDrawLinear(&d,0,1,&u);check(u.params[2]==1&&u.params[0]==90&&u.params[1]==1,"world hardware uniforms use override-aware linear parameters");
 world.mode=0;MTL_FogDrawEffectUniforms(&d,0,2,points[0],&u);check(u.params[2]==1&&u.color[0]==0&&u.color[3]==1,"additive effects use black point fog");
 MTL_FogDrawEffectUniforms(&d,0,3,points[0],&u);check(u.color[0]==0,"darkening effects use black point fog");
 MTL_FogDrawEffectUniforms(&d,0,1,points[0],&u);check(u.color[0]==1&&u.color[3]==1,"ordinary effects use region color");
 MTL_FogDrawModelUniforms(&d,0,points[0],1,1,&u);check(u.params[2]==0,"weapon excludes object fog");
 MTL_FogDrawModelUniforms(&d,0,points[0],0,0,&u);check(u.params[0]==90&&u.params[1]==1,"ghl_obj_fog0 raw linear state");
 MTL_FogDrawModelUniforms(&d,0,points[0],0,1,&u);check(u.params[0]==0&&u.params[2]==1,"ghl_obj_fog1 uses point fog");
 world.mode=3;MTL_FogDrawModelUniforms(&d,0,points[0],0,1,&u);check(u.params[2]==0,"diagnostic mode excludes point object fog");
 printf("fog draw state: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}
