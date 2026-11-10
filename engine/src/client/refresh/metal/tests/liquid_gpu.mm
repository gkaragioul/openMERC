// SPDX-License-Identifier: GPL-2.0-or-later
// Actual native shader/pipeline pixels; no engine or window is launched.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static id<MTLDevice> mtl_device;
static CAMetalLayer *mtl_layer;
static void MTL_Fatal(const char *s,const char *e) { fprintf(stderr,"%s: %s\n",s,e?e:""); abort(); }
#if LIQUID_OLD
#include "liquid_old.h"
static id<MTLRenderPipelineState> MTL_BuildLiquidPipeline(int,int translucent)
{
 NSError *error=nil;
 id<MTLLibrary> lib=[mtl_device newLibraryWithSource:mtl_turb_shader options:nil error:&error];
 if(!lib) MTL_Fatal("old shader",error.localizedDescription.UTF8String);
 MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
 d.vertexFunction=[lib newFunctionWithName:@"mtl_vs_turb"];
 d.fragmentFunction=[lib newFunctionWithName:@"mtl_fs_turb"];
 d.colorAttachments[0].pixelFormat=mtl_layer.pixelFormat;
 d.colorAttachments[0].blendingEnabled=translucent;
 d.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;
 d.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
 d.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
 id<MTLRenderPipelineState> p=[mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
 if(!p) MTL_Fatal("old pipeline",error.localizedDescription.UTF8String);
 return p;
}
#else
#include "post_factory_environment.h"
#include "../mtl_liquid_shader.h"
#endif
static int failures;
static void pixel(const char *name,int pass,int translucent,float light,float alpha,
 const unsigned char rgba[4],int expected)
{
 MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
 td.storageMode=MTLStorageModeShared;
 id<MTLTexture> tex=[mtl_device newTextureWithDescriptor:td];
 [tex replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:rgba bytesPerRow:4];
 td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mtl_layer.pixelFormat width:8 height:8 mipmapped:NO];
 td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;
 id<MTLTexture> target=[mtl_device newTextureWithDescriptor:td];
 MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
 rp.colorAttachments[0].texture=target;rp.colorAttachments[0].loadAction=MTLLoadActionClear;
 rp.colorAttachments[0].storeAction=MTLStoreActionStore;
 rp.colorAttachments[0].clearColor=MTLClearColorMake(.25,.25,.25,.25);
 td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:8 height:8 mipmapped:NO];
 td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
 rp.depthAttachment.texture=[mtl_device newTextureWithDescriptor:td];
 rp.depthAttachment.loadAction=MTLLoadActionClear;rp.depthAttachment.clearDepth=1;
 id<MTLCommandQueue> queue=[mtl_device newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];
 id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:rp];
 [enc setRenderPipelineState:MTL_BuildLiquidPipeline(pass,translucent)];
 [enc setCullMode:MTLCullModeNone];
 const float xy[3][2]={{-1,-1},{3,-1},{-1,3}};
#if LIQUID_OLD
 float vertices[3][8]={};
#else
 float vertices[3][12]={};
#endif
 for(int i=0;i<3;i++) {
  vertices[i][0]=xy[i][0];vertices[i][1]=xy[i][1];vertices[i][2]=.5;
  vertices[i][4]=vertices[i][5]=.5;
#if !LIQUID_OLD
  vertices[i][8]=vertices[i][9]=vertices[i][10]=light;vertices[i][11]=alpha;
#endif
 }
#if LIQUID_OLD
 (void)light;float uniform[20]={};for(int i=0;i<4;i++)uniform[i*5]=1;uniform[17]=alpha;
#else
 float uniform[16]={};for(int i=0;i<4;i++)uniform[i*5]=1;
#endif
 [enc setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
 [enc setVertexBytes:uniform length:sizeof(uniform) atIndex:1];
 [enc setFragmentTexture:tex atIndex:0];
 MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];
 [enc setFragmentSamplerState:[mtl_device newSamplerStateWithDescriptor:sd] atIndex:0];
 [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
 [enc endEncoding];[cb commit];[cb waitUntilCompleted];
 if(cb.error)MTL_Fatal("liquid GPU",cb.error.localizedDescription.UTF8String);
 unsigned char pixels[8*8*4];[target getBytes:pixels bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
 int actual=pixels[(4*8+4)*4+2];
 if(abs(actual-expected)>1){fprintf(stderr,"FAIL %s: red=%d expected=%d\n",name,actual,expected);failures++;}
}
int main(void) { @autoreleasepool {
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 77;
 mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
 const unsigned char white[4]={255,255,255,255},transparent[4]={200,100,50,0},gray[4]={200,200,200,128};
 pixel("base light modulation",0,0,.25,1,white,64);
 pixel("base tests modulated alpha",0,0,1,.01,white,64);
 pixel("environment opaque ignores texture alpha",1,0,1,1,transparent,200);
 pixel("environment translucent symmetric modulation",1,1,1,1,gray,100);
 if(failures)return 1;
 puts("PASS: native liquid base lighting/output-alpha cutoff and environment replace/symmetric blend pixels");
 }return 0;}
