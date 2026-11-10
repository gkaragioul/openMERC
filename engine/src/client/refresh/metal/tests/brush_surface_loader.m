// SPDX-License-Identifier: GPL-2.0-or-later
// Actual production face loader, synthetic BSP faces, real native Metal buffer.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../../../../common/header/common.h"
#include "../../../../common/header/files.h"
#include "../../ref_shared.h"
#include "../mtl_brush_math.h"
#include <setjmp.h>
typedef struct mtl_image_s {int width,height;void *tex;} mtl_image_t;
static id<MTLDevice> mtl_device;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLTexture> mtl_white;
enum {SKY_MAX_CLIP_VERTS=64};
static jmp_buf expected_error;
static int expect_error;
void Com_Error(int code,const char *fmt,...) {(void)code;if(expect_error)longjmp(expected_error,1);fprintf(stderr,"unexpected error: %s\n",fmt);abort();}
void VectorScale(const vec3_t in,vec_t scale,vec3_t out) {for(int k=0;k<3;k++)out[k]=in[k]*scale;}
static void *MTL_NewTextureChain(const byte *b,int w,int h,BOOL mip) {(void)b;(void)w;(void)h;(void)mip;return NULL;}
#include "../mtl_lightmap.h"
#include "brush_surface_production.h"
static void free_fixture(mtl_model_t *model)
{
#ifdef OM_BRUSH_HAS_LIGHTMAPS
 for(int i=0;i<model->numsurfaces;i++)MTL_LightmapFree(model->surfaces[i].lighting);
#endif
 if(model->vbuf)CFRelease(model->vbuf);free(model->surfaces);
 model->vbuf=NULL;model->surfaces=NULL;model->vbuf_vertices=0;
}
int main(void)
{
 @autoreleasepool {
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device){fprintf(stderr,"Metal device unavailable\n");return 2;}
 mtl_model_t model={0};
 dface46_t faces[2]={0};
 for(int i=0;i<2;i++){faces[i].numedges=3;faces[i].firstedge=i*3;faces[i].lightofs=-1;}
 faces[1].side=1;
 mvertex_t points[6]={{{0,0,0}},{{2,0,0}},{{0,2,0}},{{10,0,0}},{{12,0,0}},{{10,2,0}}};
 medge_t edges[6]={0};int surfedges[6]={0,1,2,3,4,5};
 for(int i=0;i<6;i++)edges[i].v[0]=i;
 cplane_t plane={0};plane.normal[2]=1;
 mtl_image_t image={16,16,(void *)1};
 mtexinfo_t texture={0};texture.image=(struct image_s *)&image;texture.vecs[0][0]=1;texture.vecs[1][1]=1;
 model.vertexes=points;model.numvertexes=6;model.edges=edges;model.numedges=6;
 model.surfedges=surfedges;model.numsurfedges=6;model.planes=&plane;model.numplanes=1;
 model.texinfo=&texture;model.numtexinfo=1;
 lump_t lump={0,sizeof(faces)};
#ifdef OM_BRUSH_OLD_LOADER
 dmodel_t dm={0};dm.numfaces=1;
 MTL_LoadWorldSurfaces(&model,(const byte *)faces,&lump,&dm,BSPVERSION_SOF);
#else
 MTL_LoadWorldSurfaces(&model,(const byte *)faces,&lump,BSPVERSION_SOF);
#endif
 int failures=0;
 if(model.numsurfaces!=2){fprintf(stderr,"FAIL: loaded %d faces; need world+inline total2\n",model.numsurfaces);failures++;}
 if(model.vbuf_vertices!=6){fprintf(stderr,"FAIL: loaded %d vertices; need6\n",model.vbuf_vertices);failures++;}
 if(model.numsurfaces==2 && model.vbuf){
  const mtl_world_vertex_t *v=[(__bridge id<MTLBuffer>)model.vbuf contents];
  if(model.surfaces[1].first_vertex!=3 || v[3].pos[0]!=10 || model.surfaces[1].normal[2]!=-1){
   fprintf(stderr,"FAIL: inline global face index/vertex offset/plane side\n");failures++;
  }
 }
 free_fixture(&model);
 texture.flags=SURF_DRAWSKY;
#ifdef OM_BRUSH_OLD_LOADER
 MTL_LoadWorldSurfaces(&model,(const byte *)faces,&lump,&dm,BSPVERSION_SOF);
#else
 MTL_LoadWorldSurfaces(&model,(const byte *)faces,&lump,BSPVERSION_SOF);
#endif
 for(int i=0;i<model.numsurfaces;i++) {
  if(model.surfaces[i].skyring_n!=3){fprintf(stderr,"FAIL: sky face%d ring count %d expected3\n",i,model.surfaces[i].skyring_n);failures++;}
  for(int j=0;j<3;j++) for(int k=0;k<3;k++)
   if(model.surfaces[i].skyring[j][k]!=points[i*3+j].position[k]) {
    fprintf(stderr,"FAIL: sky face%d ring vertex%d component%d differs from BSP\n",i,j,k);failures++;
   }
 }
 free_fixture(&model);
 texture.flags=0;
 byte samples[12]={10,20,30,40,50,60,70,80,90,100,110,120};model.lightdata=samples;model.lightdata_bytes=sizeof(samples);
 for(int i=0;i<2;i++){faces[i].lightofs=0;faces[i].lm_width=faces[i].lm_height=1;faces[i].lm_scale[0]=faces[i].lm_scale[1]=1;for(int j=0;j<4;j++)faces[i].styles[j]=j;}
 MTL_LoadWorldSurfaces(&model,(const byte *)faces,&lump,BSPVERSION_SOF);
#ifdef OM_BRUSH_HAS_LIGHTMAPS
 for(int i=0;i<model.numsurfaces;i++) {
  mtl_lightmap_t *lightmap=model.surfaces[i].lighting;
  if(!lightmap || lightmap->count!=4){fprintf(stderr,"FAIL: production loader retains all four style planes\n");failures++;continue;}
  for(int map=0;map<4;map++){
   byte pixel[4];[(__bridge id<MTLTexture>)lightmap->planes[map] getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
   if(memcmp(pixel,samples+map*3,3)){fprintf(stderr,"FAIL: loaded style plane%d loses raw samples\n",map);failures++;}
  }
 }
#else
 fprintf(stderr,"FAIL: production loader has no four-style lightmap resource\n");failures++;
#endif
 free_fixture(&model);
 /* Fog boundary ownership survives faces with no ordinary draw ring/image. */
 texture.flags=0x10000;image.tex=NULL;faces[0].numedges=0;
 MTL_LoadWorldSurfaces(&model,(const byte *)faces,&lump,BSPVERSION_SOF);
#ifdef OM_BRUSH_HAS_FOG_PLANES
 for(int i=0;i<model.numsurfaces;i++)if(model.surfaces[i].bsp_plane!=&plane || !(model.surfaces[i].flags&0x10000)) {
  fprintf(stderr,"FAIL: skipped textured face loses original fog plane/flags\n");failures++;
 }
#else
 fprintf(stderr,"FAIL: production surface has no stable original fog plane\n");failures++;
#endif
 free_fixture(&model);texture.flags=0;image.tex=(void *)1;faces[0].numedges=3;
 model.lightdata_bytes=11;expect_error=1;
 if(setjmp(expected_error)==0){MTL_LoadWorldSurfaces(&model,(const byte *)faces,&lump,BSPVERSION_SOF);fprintf(stderr,"FAIL: truncated fourth style plane accepted\n");failures++;}
 expect_error=0;free_fixture(&model);MTL_LightmapsShutdown();
 if(failures)return 1;
 puts("PASS: production all-face load, inline indexing, sky ring, four raw style planes, reload cleanup and truncated-plane rejection");return 0;
 }
}
