// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 production fog loader against read-only user BSP data.
// No engine launch, Metal device, original executable or game-data write.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "../mtl_fog_math.h"
typedef unsigned char byte;typedef float vec3_t[3];
typedef struct {int fileofs,filelen;} lump_t;
typedef struct {float normal[3],dist;} cplane_t;
typedef struct {float position[3];} mvertex_t;
typedef struct {unsigned short v[2];} medge_t;
typedef struct {int flags;const cplane_t *bsp_plane;} mtl_surface_t;
typedef struct {int unused;} mleaf_t;
typedef struct mtl_model_s {
 struct mtl_model_s *owner;mtl_fog_world_t *fog;mtl_surface_t *surfaces;int numsurfaces;
 mvertex_t *vertexes;int numvertexes;medge_t *edges;int numedges;int *surfedges,numsurfedges;
 cplane_t *planes;int numplanes;mleaf_t *leafs;int numleafs;void *nodes;
} mtl_model_t;
static mtl_model_t *mtl_worldmodel;
static mleaf_t *Mod_PointInLeaf(const float p[3],void *nodes) {(void)p;(void)nodes;return NULL;}
#include "../mtl_fog.h"
static int maps,failed,regionmaps,totalregions;
static void inspect(const byte *b,size_t bytes,const char *name)
{
 if(bytes<184||memcmp(b,"IBSP",4)||MTL_FogReadI32(b+4)!=46)return;
 maps++;lump_t l[22];for(int i=0;i<22;i++){l[i].fileofs=MTL_FogReadI32(b+8+i*8);l[i].filelen=MTL_FogReadI32(b+12+i*8);if(!MTL_FogLumpValid(&l[i],bytes,1)){failed++;return;}}
 mtl_model_t root={0};root.owner=&root;
 root.numvertexes=l[2].filelen/12;root.numedges=l[11].filelen/4;root.numsurfedges=l[12].filelen/4;
 root.numplanes=l[1].filelen/20;root.numsurfaces=l[6].filelen/44;root.numleafs=l[8].filelen/32;
 root.vertexes=calloc((size_t)root.numvertexes,sizeof(*root.vertexes));root.edges=calloc((size_t)root.numedges,sizeof(*root.edges));root.surfedges=calloc((size_t)root.numsurfedges,sizeof(*root.surfedges));
 root.planes=calloc((size_t)root.numplanes,sizeof(*root.planes));root.surfaces=calloc((size_t)root.numsurfaces,sizeof(*root.surfaces));root.leafs=calloc((size_t)root.numleafs,sizeof(*root.leafs));
 if(!root.vertexes||!root.edges||!root.surfedges||!root.planes||!root.surfaces||!root.leafs){fprintf(stderr,"fixture allocation failed\n");exit(2);}
 for(int i=0;i<root.numvertexes;i++)for(int k=0;k<3;k++)root.vertexes[i].position[k]=MTL_FogReadFloat(b+l[2].fileofs+i*12+k*4);
 for(int i=0;i<root.numedges;i++)for(int k=0;k<2;k++)root.edges[i].v[k]=(unsigned short)MTL_FogReadU16(b+l[11].fileofs+i*4+k*2);
 for(int i=0;i<root.numsurfedges;i++)root.surfedges[i]=MTL_FogReadI32(b+l[12].fileofs+i*4);
 for(int i=0;i<root.numplanes;i++){for(int k=0;k<3;k++)root.planes[i].normal[k]=MTL_FogReadFloat(b+l[1].fileofs+i*20+k*4);root.planes[i].dist=MTL_FogReadFloat(b+l[1].fileofs+i*20+12);}
 for(int i=0;i<root.numsurfaces;i++){
  const byte *rec=b+l[6].fileofs+i*44;unsigned plane=MTL_FogReadU16(rec);int texinfo=MTL_FogReadI16(rec+10);
  if(plane<(unsigned)root.numplanes)root.surfaces[i].bsp_plane=&root.planes[plane];
  if(texinfo>=0&&texinfo<l[5].filelen/76)root.surfaces[i].flags=MTL_FogReadI32(b+l[5].fileofs+texinfo*76+32);
 }
 if(!MTL_FogLoad(&root,b,bytes,&l[6],&l[19],&l[21],&l[8])){fprintf(stderr,"FAIL: actual MTL_FogLoad rejects %s\n",name);failed++;}
 else {
  int nonempty=0;for(int i=0;i<root.fog->numregions;i++){mtl_fog_region_t *r=&root.fog->regions[i];if(r->size[0]>=0&&r->size[1]>=0&&r->size[2]>=0)nonempty++;}
  printf("PASS %s regions=%d bounded=%d faces=%d polygons=%d\n",name,root.fog->numregions,nonempty,root.numsurfaces,root.fog->numpolys);
  if(root.fog->numregions)regionmaps++;totalregions+=root.fog->numregions;
 }
 MTL_FogFree(&root);free(root.vertexes);free(root.edges);free(root.surfedges);free(root.planes);free(root.surfaces);free(root.leafs);
}
int main(int argc,char **argv)
{
 for(int a=1;a<argc;a++){
  FILE *f=fopen(argv[a],"rb");if(!f){perror(argv[a]);return 2;}byte h[12];if(fread(h,1,12,f)!=12||memcmp(h,"PACK",4)){fclose(f);return 2;}
  int ofs=MTL_FogReadI32(h+4),len=MTL_FogReadI32(h+8);if(ofs<0||len<0||len%64){fclose(f);return 2;}
  byte *dir=malloc((size_t)len);if(!dir||fseek(f,ofs,SEEK_SET)||fread(dir,1,(size_t)len,f)!=(size_t)len){fclose(f);free(dir);return 2;}
  for(int i=0;i<len;i+=64){char name[57];memcpy(name,dir+i,56);name[56]=0;size_t n=strlen(name);if(n<4||strcmp(name+n-4,".bsp"))continue;
   int off=MTL_FogReadI32(dir+i+56),size=MTL_FogReadI32(dir+i+60);if(off<0||size<0){free(dir);fclose(f);return 2;}
   byte *b=malloc((size_t)size);if(!b||fseek(f,off,SEEK_SET)||fread(b,1,(size_t)size,f)!=(size_t)size){free(b);free(dir);fclose(f);return 2;}
   inspect(b,(size_t)size,name);free(b);
  }
  free(dir);fclose(f);
 }
 printf("actual native fog data: maps=%d region_maps=%d regions=%d rejected=%d\n",maps,regionmaps,totalregions,failed);
 return failed||!maps?1:0;
}
