// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 actual native polygon fog and emissive attenuation.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../mtl_fog_draw.h"
#include "../mtl_fog_shaders.h"
static int checks,failed;
static void pixel(id<MTLTexture> t,int red,int green,int blue,const char *name){unsigned char rgba[8*8*4];[t getBytes:rgba bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];unsigned char *p=rgba+(4*8+4)*4;checks++;if(abs(p[0]-red)>1||abs(p[1]-green)>1||abs(p[2]-blue)>1){fprintf(stderr,"FAIL: %s RGB%d,%d,%d expected%d,%d,%d\n",name,p[0],p[1],p[2],red,green,blue);failed++;}}
static id<MTLTexture> texture(id<MTLDevice> device,MTLPixelFormat format){MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:8 height:8 mipmapped:NO];d.storageMode=format==MTLPixelFormatDepth32Float?MTLStorageModePrivate:MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget;return [device newTextureWithDescriptor:d];}
int main(void){@autoreleasepool{
 id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)return 2;id<MTLCommandQueue> queue=[device newCommandQueue];
 MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new];dd.depthCompareFunction=MTLCompareFunctionLessEqual;dd.depthWriteEnabled=NO;id<MTLDepthStencilState> depth=[device newDepthStencilStateWithDescriptor:dd];
 id<MTLTexture> scene=texture(device,MTLPixelFormatRGBA8Unorm),emission=texture(device,MTLPixelFormatRGBA8Unorm),z=texture(device,MTLPixelFormatDepth32Float);
 float mvp[16]={0};for(int i=0;i<4;i++)mvp[i*5]=1;
 mtl_fog_vertex_t v[6]={};float xy[6][2]={{-1,-1},{-1,1},{1,1},{-1,-1},{1,1},{1,-1}};
 for(int i=0;i<6;i++){v[i].position[0]=xy[i][0];v[i].position[1]=xy[i][1];v[i].position[2]=.5;v[i].color[0]=1;v[i].color[3]=225.0f/255;}
 for(int colors=1;colors<=2;colors++)for(int mode=0;mode<4;mode++){
  id<MTLRenderPipelineState> pipeline=MTL_FogBuildPipeline(device,(NSUInteger)colors,MTLPixelFormatRGBA8Unorm,MTLPixelFormatRGBA8Unorm,1);checks++;if(!pipeline){failed++;continue;}
  MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=scene;p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
  if(colors==2){p.colorAttachments[1].texture=emission;p.colorAttachments[1].loadAction=MTLLoadActionClear;p.colorAttachments[1].storeAction=MTLStoreActionStore;p.colorAttachments[1].clearColor=MTLClearColorMake(0,1,0,1);}
  p.depthAttachment.texture=z;p.depthAttachment.loadAction=MTLLoadActionClear;p.depthAttachment.storeAction=MTLStoreActionStore;p.depthAttachment.clearDepth=mode==2?.2:1;
  mtl_fog_pixel_uniform_t u={};if(mode==1){u.eye[3]=1;u.params[1]=.01;u.params[2]=255;u.height[2]=1;for(int i=0;i<6;i++)v[i].color[3]=0;}else for(int i=0;i<6;i++)v[i].color[3]=225.0f/255;
  id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:p];[e setRenderPipelineState:pipeline];[e setDepthStencilState:depth];[e setCullMode:MTLCullModeNone];[e setVertexBytes:v length:sizeof(v) atIndex:0];[e setVertexBytes:mvp length:sizeof(mvp) atIndex:1];[e setFragmentBytes:&u length:sizeof(u) atIndex:1];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  if(mode==3){for(int i=0;i<6;i++){v[i].position[2]=.75;v[i].color[0]=0;v[i].color[1]=1;v[i].color[3]=1;}[e setVertexBytes:v length:sizeof(v) atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];for(int i=0;i<6;i++){v[i].position[2]=.5;v[i].color[0]=1;v[i].color[1]=0;}}
  [e endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error){fprintf(stderr,"FAIL GPU: %s\n",cb.error.localizedDescription.UTF8String);failed++;continue;}
  int alpha=mode==1?28:225;if(mode==2){pixel(scene,0,0,255,"nearer world depth occludes fog");if(colors==2)pixel(emission,0,255,0,"occluded fog preserves emission");}
  else if(mode==3){pixel(scene,0,255,0,"fog does not write depth");if(colors==2)pixel(emission,0,0,0,"later opaque geometry clears glow");}
  else{pixel(scene,alpha,0,255-alpha,mode?"per-pixel squared alpha":"vertex alpha");if(colors==2)pixel(emission,0,255-alpha,0,"fog black emission retains scene alpha");}
 }
 const NSUInteger sample_counts[4]={1,2,4,8};for(NSUInteger samples:sample_counts)if([device supportsTextureSampleCount:samples])for(NSUInteger colors=1;colors<=2;colors++){checks++;if(!MTL_FogBuildPipeline(device,colors,MTLPixelFormatRGBA8Unorm,MTLPixelFormatRGBA8Unorm,samples)){failed++;fprintf(stderr,"FAIL fog pipeline sample%lu colors%lu\n",samples,colors);}}
 printf("fog native GPU: %d passed, %d failed\n",checks-failed,failed);return failed?1:0;
}}
