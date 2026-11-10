// SPDX-License-Identifier: GPL-2.0-or-later
// Actual liquid adapter and shader with native GPU buffers and final pixels.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "../../../../common/header/common.h"
#include "../../ref_shared.h"
#include <assert.h>
#include "liquid_draw_types.h"
static id<MTLDevice> mtl_device;
static CAMetalLayer *mtl_layer;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLDepthStencilState> mtl_depth_world,mtl_depth_readonly;
static id<MTLSamplerState> mtl_samp_world;
static int mtl_encoder_open;
static refdef_t mtl_refdef;
static int lightqueries;
static void MTL_Fatal(const char *s,const char *e){fprintf(stderr,"%s: %s\n",s,e?e:"");abort();}
static float MTL_GameTime(void){return 1.25f;}
void AngleVectors(const vec3_t a,vec3_t f,vec3_t r,vec3_t u){(void)a;VectorSet(f,1,0,0);VectorSet(r,0,-1,0);VectorSet(u,0,0,1);}
static void MTL_SoFLightPointDir(const float *p,float *c,int d){assert(d==255);assert(p[0]>=4&&p[0]<=8&&p[1]>=6&&p[1]<=10&&p[2]==.5f);VectorSet(c,.25,.25,.25);lightqueries++;}
#include "../mtl_liquid.h"
#include "../mtl_liquid_inline.h"
int main(void){@autoreleasepool{
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 77;
 mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
 MTL_LiquidInit();
 MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new];dd.depthCompareFunction=MTLCompareFunctionLessEqual;dd.depthWriteEnabled=YES;mtl_depth_world=[mtl_device newDepthStencilStateWithDescriptor:dd];
 dd.depthWriteEnabled=NO;mtl_depth_readonly=[mtl_device newDepthStencilStateWithDescriptor:dd];
 mtl_samp_world=[mtl_device newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
 MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
 td.storageMode=MTLStorageModeShared;id<MTLTexture> tex=[mtl_device newTextureWithDescriptor:td];
 const byte rgba[4]={200,100,50,255};[tex replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:rgba bytesPerRow:4];
 mtl_image_t image={0},env={0};image.tex=(__bridge void *)tex;env.kind=8;
 mtexinfo_t info={0};info.flags=8;info.vecs[0][0]=info.vecs[1][1]=1;
 mtl_surface_t surface={0};surface.texinfo=&info;surface.num_vertex=6;
 mtl_world_vertex_t source[6]={0};float xy[6][2]={{0,0},{4,0},{4,4},{0,0},{4,4},{0,4}};
 for(int i=0;i<6;i++){source[i].pos[0]=xy[i][0];source[i].pos[1]=xy[i][1];source[i].pos[2]=.5f;}
 id<MTLBuffer> vb=[mtl_device newBufferWithBytes:source length:sizeof(source) options:MTLResourceStorageModeShared];
 mtl_model_t model={0};model.vbuf=(__bridge void *)vb;model.vbuf_vertices=6;
 float sorteye[3]={2,2,1.5f};assert(fabsf(MTL_SoFLiquidSortKey(&model,&surface,sorteye,100)-1)<1e-6f);assert(!lightqueries);
 float matrix[16]={1,0,0,0,0,1,0,0,0,0,1,0,4,6,0,1};
 float exact[16],origin[3]={4,6,0},angles[3]={0};MTL_LiquidEntityMatrix(origin,angles,exact);for(int i=0;i<16;i++)assert(matrix[i]==exact[i]);
 float mvp[16]={.5,0,0,0,0,.5,0,0,0,0,1,0,-3,-4,0,1},normal[3]={0,0,1};
 const int expected[7]={50,200,50,78,50,0,50};
 for(int i=0;i<7;i++){
  image.detail=(i==1||i==3||i==4)?&env:NULL;
  td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mtl_layer.pixelFormat width:16 height:16 mipmapped:NO];
  td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;id<MTLTexture> target=[mtl_device newTextureWithDescriptor:td];
  td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=target;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  rp.depthAttachment.texture=[mtl_device newTextureWithDescriptor:td];rp.depthAttachment.loadAction=MTLLoadActionClear;rp.depthAttachment.clearDepth=1;
  id<MTLCommandQueue> queue=[mtl_device newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];mtl_enc=[cb renderCommandEncoderWithDescriptor:rp];mtl_encoder_open=1;
  int start=lightqueries;
  if(i==6){
   float centerlight[3]={.25,.25,.25};info.flags=0x2808;image.detail=&env;info.image=(struct image_s *)&image;
   assert(MTL_DrawSoFLiquidInlineAlpha(&model,&surface,&image,mvp,matrix,centerlight));assert(lightqueries==start);
  }else{
   assert(MTL_DrawSoFLiquid(&model,&surface,&image,mvp,matrix,normal,i==2||i==3,i==5,i==4));
   assert(lightqueries-start==6);
  }
  [mtl_enc endEncoding];mtl_encoder_open=0;mtl_enc=nil;
  [cb commit];[cb waitUntilCompleted];assert(!cb.error);
  byte pixels[16*16*4];[target getBytes:pixels bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];
  assert(abs(pixels[(8*16+8)*4+2]-expected[i])<=1);
 }
 assert(!memcmp(source,[vb contents],sizeof(source)));
 surface.num_vertex=7;assert(!MTL_DrawSoFLiquid(&model,&surface,&image,mvp,matrix,normal,0,0,0));
 MTL_LiquidShutdown();MTL_LiquidInit();assert(fabsf(mtl_liquid_table[64]-2)<1e-6f);MTL_LiquidShutdown();
 puts("PASS: actual adapter transformed model, base/env GPU pixels, exactly six light queries, source immutability, malformed range and renderer restart");
}return 0;}
