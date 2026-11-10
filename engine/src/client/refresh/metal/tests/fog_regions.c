// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 checked SoF region records and root-model lifetime.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include "../mtl_fog_math.h"
typedef unsigned char byte;
typedef float vec3_t[3];
typedef struct {int fileofs,filelen;} lump_t;
typedef struct {float normal[3],dist;} cplane_t;
typedef struct {float position[3];} mvertex_t;
typedef struct {unsigned short v[2];} medge_t;
typedef struct {int flags;const cplane_t *bsp_plane;} mtl_surface_t;
typedef struct {int dummy;} mleaf_t;
typedef struct mtl_model_s {
 struct mtl_model_s *owner;mtl_fog_world_t *fog;
 mtl_surface_t *surfaces;int numsurfaces;
 mvertex_t *vertexes;int numvertexes;medge_t *edges;int numedges;int *surfedges,numsurfedges;
 cplane_t *planes;int numplanes;mleaf_t *leafs;int numleafs;void *nodes;
} mtl_model_t;
static mtl_model_t *mtl_worldmodel;
static mleaf_t *selected_leaf;
static mleaf_t *Mod_PointInLeaf(const float p[3],void *nodes) {(void)p;(void)nodes;return selected_leaf;}
static int alloc_count,fail_at=-1,live_allocs;
static void *fog_calloc(size_t n,size_t size) {if(alloc_count++==fail_at)return NULL;void *p=calloc(n,size);if(p)live_allocs++;return p;}
static void *fog_malloc(size_t size) {if(alloc_count++==fail_at)return NULL;void *p=malloc(size);if(p)live_allocs++;return p;}
static void fog_free(void *p) {if(p)live_allocs--;free(p);}
#define calloc fog_calloc
#define malloc fog_malloc
#define free fog_free
#include "../mtl_fog.h"
#undef calloc
#undef malloc
#undef free
static byte blob[40000];static lump_t faces,polys,regions,leafs;
static mtl_surface_t surfaces[8];static cplane_t planes[6];static mleaf_t leaves[2];
static mvertex_t vertices[3]={{{0,0,0}},{{10,0,0}},{{0,20,30}}};
static medge_t edges[3]={{{0,1}},{{1,2}},{{2,0}}};static int surfedges[3]={0,1,2};
static mtl_model_t root;static int checks,failures;
static void check(int pass,const char *name) {checks++;if(!pass){fprintf(stderr,"FAIL: %s\n",name);failures++;}}
static void i16(int offset,int value) {uint16_t v=(uint16_t)value;blob[offset]=(byte)v;blob[offset+1]=(byte)(v>>8);}
static void i32(int offset,int value) {uint32_t v=(uint32_t)value;for(int i=0;i<4;i++)blob[offset+i]=(byte)(v>>(8*i));}
static void f32(int offset,float value) {uint32_t v;memcpy(&v,&value,4);i32(offset,(int)v);}
static void fixture(void) {
 MTL_FogFree(&root);memset(&root,0,sizeof(root));memset(blob,0,sizeof(blob));memset(surfaces,0,sizeof(surfaces));memset(planes,0,sizeof(planes));
 faces=(lump_t){1,8*44};polys=(lump_t){355,8};regions=(lump_t){365,76};leafs=(lump_t){25001,64};
 root.owner=&root;root.surfaces=surfaces;root.numsurfaces=8;root.planes=planes;root.numplanes=6;
 root.vertexes=vertices;root.numvertexes=3;root.edges=edges;root.numedges=3;root.surfedges=surfedges;root.numsurfedges=3;root.leafs=leaves;root.numleafs=2;root.nodes=&root;
 for(int i=0;i<8;i++){int f=faces.fileofs+i*44;i16(f+12,0);i32(f+16,0);i16(f+20,1);surfaces[i].flags=0x10000;surfaces[i].bsp_plane=&planes[0];}
 for(int i=0;i<6;i++)planes[i].normal[i%3]=1;
 i32(polys.fileofs,0);i32(polys.fileofs+4,3);f32(regions.fileofs+4,.5f);f32(regions.fileofs+12,4);f32(regions.fileofs+16,400);
 blob[regions.fileofs+24]=100;blob[regions.fileofs+25]=150;blob[regions.fileofs+26]=200;blob[regions.fileofs+27]=255;
 i16(leafs.fileofs+8,0);i16(leafs.fileofs+32+8,-1);surfedges[0]=0;mtl_worldmodel=&root;selected_leaf=leaves;
}
static int load(void) {return MTL_FogLoad(&root,blob,sizeof(blob),&faces,&polys,&regions,&leafs);}
int main(void) {
 fixture();check(load(),"unaligned valid records load");
 check(root.fog && root.fog->numregions==1 && root.fog->numsurfaces==8,"world owns preserved regions and faces");
 if(root.fog){check(root.fog->regions[0].numplanes==1,"duplicate original planes deduplicated");check(root.fog->regions[0].maxs[2]==30 && root.fog->regions[0].size[1]==20,"polygon vertices form region bounds");
  check(MTL_FogSurfaceRegion(&surfaces[7])==0,"surface classification stable");check(MTL_FogRegionOfPoint(vertices[0].position)==0,"leaf volume preserved");selected_leaf=&leaves[1];check(MTL_FogRegionOfPoint(vertices[0].position)==-1,"leaf none sentinel preserved");
  mtl_model_t inline_model=root;inline_model.owner=&root;MTL_FogFree(&inline_model);check(root.fog!=NULL,"inline descriptor cannot free root fog");
  mtl_fog_world_t *old=root.fog;regions.filelen=75;check(!load()&&root.fog==old,"failed replacement preserves old allocation");regions.filelen=76;check(load(),"successful replacement retires old allocation");}
 fixture();faces.filelen--;check(!load(),"misaligned faces rejected");
 fixture();polys.filelen--;check(!load(),"misaligned polygon records rejected");
 fixture();leafs.filelen--;check(!load(),"misaligned leaf records rejected");
 fixture();regions.fileofs=sizeof(blob)-75;check(!load(),"truncated region bytes rejected");
 fixture();regions.fileofs=-1;check(!load(),"negative lump offset rejected");
 fixture();i16(faces.fileofs+12,1);check(load()&&root.fog->surfaces[0].region==-1,"unknown face region normalized to none");
 fixture();i16(leafs.fileofs+8,1);check(load()&&root.fog->leafregions[0]==-1,"unknown leaf region normalized to none");
 fixture();i32(faces.fileofs+16,INT_MAX);check(!load(),"overflowing first polygon rejected");
 fixture();i32(polys.fileofs,1);check(!load(),"out of bounds polygon surfedge span rejected");
 fixture();i32(polys.fileofs+4,65);check(!load(),"65 vertex polygon rejected");
 fixture();surfedges[0]=INT_MIN;check(!load(),"INT_MIN signed edge rejected before negate");
 fixture();surfedges[0]=3;check(!load(),"invalid edge index rejected");
 fixture();edges[0].v[0]=3;check(!load(),"invalid vertex index rejected");edges[0].v[0]=0;
 fixture();i16(faces.fileofs,6);check(!load(),"invalid original plane index rejected");
 fixture();f32(regions.fileofs+16,NAN);check(!load(),"nonfinite fog range rejected");
 fixture();for(int i=0;i<6;i++)i16(faces.fileofs+i*44,i);check(load()&&root.fog->regions[0].numplanes==5,"boundary plane cap5");
 fixture();regions.filelen=257*76;check(load()&&root.fog->numregions==256,"region cap256");
 fixture();regions.filelen=0;polys.filelen=0;for(int i=0;i<8;i++){i16(faces.fileofs+i*44+12,-1);i16(faces.fileofs+i*44+20,0);i32(faces.fileofs+i*44+16,-1);}
 check(load()&&root.fog->numregions==0&&root.fog->leafregions[0]==-1,"stock zero region maps with solid leaf0 volume0 remain valid");
 MTL_FogFree(&root);check(!root.fog,"root cleanup clears ownership");MTL_FogFree(&root);check(!root.fog,"repeated cleanup safe");
 check(live_allocs==0,"all owned allocation counts return to zero");
 for(int i=0;i<6;i++){fixture();alloc_count=0;fail_at=i;check(!load()&&!root.fog&&live_allocs==0,"allocation failure unwinds every earlier owned allocation");fail_at=-1;}
 printf("fog regions: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}
