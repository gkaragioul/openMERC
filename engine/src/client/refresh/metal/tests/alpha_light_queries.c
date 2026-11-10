// SPDX-License-Identifier: GPL-2.0-or-later
// Stateful light-query oracle: the polygon-ring order must survive fan expansion.
#include <stdio.h>
#include <string.h>
typedef struct { int flags,value; } mtexinfo_t;
typedef struct { int num_vertex; mtexinfo_t *texinfo; } mtl_surface_t;
typedef struct { float pos[3],uv[2]; } mtl_world_vertex_t;
typedef struct { float pos[3],uv[2],color[4]; } mtl_alias_vertex_t;
static int queries,order[16];
static float MTL_GameTime(void) { return 2; }
static void MTL_SoFLightPointDir(const float *p,float *color,int direction)
{
 (void)direction; order[queries]=(int)p[0]; queries++;
 color[0]=(float)queries; color[1]=p[0]; color[2]=0;
}
#include "alpha_production.h"
int main(void)
{
 mtexinfo_t tex={0x40,128}; mtl_surface_t surface={9,&tex};
 const int ring[]={0,1,2,0,2,3,0,3,4};
 mtl_world_vertex_t source[9]={0}; mtl_alias_vertex_t out[9]={0};
 for(int i=0;i<9;i++) {source[i].pos[0]=(float)ring[i];source[i].uv[0]=1;source[i].uv[1]=3;}
 MTL_FillAlphaVertices(&surface,source,out);
 if(queries!=5) {fprintf(stderr,"FAIL: pentagon needs 5 light queries, got %d\n",queries);return 1;}
 for(int i=0;i<5;i++) if(order[i]!=i) {fputs("FAIL: polygon-ring light query order\n",stderr);return 1;}
 for(int i=0;i<9;i++) if(out[i].color[0]!=ring[i]+1 || out[i].color[3]!=1 ||
   out[i].uv[0]!=1 || out[i].uv[1]<0.4399f || out[i].uv[1]>0.4401f) {
   fputs("FAIL: reused vertex colour/flow\n",stderr);return 1;
 }
 puts("PASS: production alpha polygon-ring light order/count and reused fan colours/flow");return 0;
}
