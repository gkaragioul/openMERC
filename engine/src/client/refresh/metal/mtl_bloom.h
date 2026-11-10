// SPDX-License-Identifier: GPL-2.0-or-later
// View-local native bloom chain and final LDR composite.
// Implements: SPEC-AMEND-016 R16.7; current GPL gl3_post.c.
// Host supplies ri/cvar_t/CVAR_ARCHIVE and mtl_device. No frame ownership here.
#ifndef OM_METAL_BLOOM_H
#define OM_METAL_BLOOM_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "mtl_post_math.h"
#include "mtl_bloom_shader.h"
typedef struct {float rect[4],clampuv[4],halfpx[2],knee;unsigned mode;} mtl_bloom_filter_t;
typedef struct {float intensity;unsigned mode;float padding[2];} mtl_bloom_composite_t;
typedef struct {
 BOOL ready;
 int width,height,nlevels;
 id<MTLTexture> level[7];
 id<MTLLibrary> library;
 id<MTLRenderPipelineState> down,up,composite;
 id<MTLSamplerState> sampler;
 id<MTLDepthStencilState> no_depth;
 MTLPixelFormat composite_color,composite_depth;
 NSUInteger composite_samples;
} mtl_bloom_state_t;
static mtl_bloom_state_t mtl_bloom;
static cvar_t *mtl_bloom_threshold,*mtl_bloom_intensity,*mtl_bloom_radius,*mtl_bloom_fromscene;

static void MTL_BloomShutdown(void){mtl_bloom=(mtl_bloom_state_t){};}
static void MTL_BloomInit(void)
{
 MTL_BloomShutdown();
 mtl_bloom_threshold=ri.Cvar_Get("r_om_bloom_threshold","0",CVAR_ARCHIVE);
 mtl_bloom_intensity=ri.Cvar_Get("r_om_bloom_intensity","0.45",CVAR_ARCHIVE);
 mtl_bloom_radius=ri.Cvar_Get("r_om_bloom_radius","1",CVAR_ARCHIVE);
 mtl_bloom_fromscene=ri.Cvar_Get("r_om_bloom_fromscene","0",CVAR_ARCHIVE);
 NSError *error=nil;mtl_bloom.library=[mtl_device newLibraryWithSource:mtl_bloom_shader options:nil error:&error];
 if(!mtl_bloom.library)return;
 MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
 d.label=@"openMerc native bloom downsample";d.vertexFunction=[mtl_bloom.library newFunctionWithName:@"bloom_v"];
 d.fragmentFunction=[mtl_bloom.library newFunctionWithName:@"bloom_down"];d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
 mtl_bloom.down=[mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
 d.label=@"openMerc native bloom additive upsample";d.fragmentFunction=[mtl_bloom.library newFunctionWithName:@"bloom_up"];
 d.colorAttachments[0].blendingEnabled=YES;d.colorAttachments[0].sourceRGBBlendFactor=d.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;
 d.colorAttachments[0].destinationRGBBlendFactor=d.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOne;
 mtl_bloom.up=[mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
 MTLSamplerDescriptor *sampler=[MTLSamplerDescriptor new];sampler.minFilter=sampler.magFilter=MTLSamplerMinMagFilterLinear;
 sampler.sAddressMode=sampler.tAddressMode=MTLSamplerAddressModeClampToEdge;mtl_bloom.sampler=[mtl_device newSamplerStateWithDescriptor:sampler];
 MTLDepthStencilDescriptor *depth=[MTLDepthStencilDescriptor new];depth.depthCompareFunction=MTLCompareFunctionAlways;depth.depthWriteEnabled=NO;mtl_bloom.no_depth=[mtl_device newDepthStencilStateWithDescriptor:depth];
}

static BOOL MTL_BloomPrepare(int width,int height)
{
 int widths[7],heights[7],count=MTL_PostBloomLayout(width,height,mtl_bloom_radius->value,widths,heights);
 if(!count){for(int i=0;i<7;i++)mtl_bloom.level[i]=nil;mtl_bloom.nlevels=0;return NO;}
 if(mtl_bloom.width==width&&mtl_bloom.height==height&&mtl_bloom.nlevels==count&&mtl_bloom.level[0])return YES;
 // Replace only a complete chain, so allocation failure cannot mix old/new mips.
 id<MTLTexture> levels[7]={};
 for(int i=0;i<count;i++){
  MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:widths[i] height:heights[i] mipmapped:NO];
  d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;levels[i]=[mtl_device newTextureWithDescriptor:d];if(!levels[i])return NO;
  levels[i].label=[NSString stringWithFormat:@"openMerc bloom level%d",i];
 }
 for(int i=0;i<7;i++)mtl_bloom.level[i]=levels[i];mtl_bloom.width=width;mtl_bloom.height=height;mtl_bloom.nlevels=count;return YES;
}

/* Caller must end its world encoder before this call. This function neither
 * adopts/restores targets nor presents/commits/waits; it leaves no encoder open. */
static BOOL MTL_BloomProcess(id<MTLCommandBuffer> buffer,id<MTLTexture> scene,id<MTLTexture> emission,
 int x,int y,int width,int height,BOOL enabled)
{
 mtl_bloom.ready=NO;
 if(!enabled){mtl_bloom.nlevels=0;return YES;}
 if(!buffer||!scene||!emission||scene.width!=emission.width||scene.height!=emission.height||
  scene.sampleCount!=1||emission.sampleCount!=1||x<0||y<0||width<=0||height<=0||
  (NSUInteger)x>scene.width||(NSUInteger)y>scene.height||(NSUInteger)width>scene.width-(NSUInteger)x||
  (NSUInteger)height>scene.height-(NSUInteger)y||!mtl_bloom.down||!mtl_bloom.up||!mtl_bloom.sampler||!MTL_BloomPrepare(width,height))return NO;
 for(int i=0;i<mtl_bloom.nlevels;i++){
  id<MTLTexture> source=i?mtl_bloom.level[i-1]:(mtl_bloom_fromscene->value?scene:emission),target=mtl_bloom.level[i];
  MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;
  pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc=[buffer renderCommandEncoderWithDescriptor:pass];if(!enc)return NO;
  mtl_bloom_filter_t u={};u.rect[2]=u.rect[3]=1;float sw=source.width,sh=source.height;
  u.halfpx[0]=1/sw;u.halfpx[1]=1/sh;
  if(!i){u.rect[0]=x/sw;u.rect[1]=y/sh;u.rect[2]=width/sw;u.rect[3]=height/sh;
   u.clampuv[0]=(x+.5f)/sw;u.clampuv[1]=(y+.5f)/sh;u.clampuv[2]=(x+width-.5f)/sw;u.clampuv[3]=(y+height-.5f)/sh;
   u.mode=mtl_bloom_fromscene->value?2:1;float knee=mtl_bloom_threshold->value;u.knee=knee<0?0:knee>.95f?.95f:knee;
  }else {u.clampuv[0]=.5f/sw;u.clampuv[1]=.5f/sh;u.clampuv[2]=1-.5f/sw;u.clampuv[3]=1-.5f/sh;}
  [enc setRenderPipelineState:mtl_bloom.down];[enc setCullMode:MTLCullModeNone];[enc setVertexBytes:u.rect length:sizeof(u.rect) atIndex:0];
  [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];[enc setFragmentTexture:source atIndex:0];[enc setFragmentSamplerState:mtl_bloom.sampler atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];
 }
 for(int i=mtl_bloom.nlevels-2;i>=0;i--){
  id<MTLTexture> source=mtl_bloom.level[i+1],target=mtl_bloom.level[i];
  MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;
  pass.colorAttachments[0].loadAction=MTLLoadActionLoad;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc=[buffer renderCommandEncoderWithDescriptor:pass];if(!enc)return NO;
  mtl_bloom_filter_t u={};u.rect[2]=u.rect[3]=1;u.halfpx[0]=.5f/source.width;u.halfpx[1]=.5f/source.height;
  [enc setRenderPipelineState:mtl_bloom.up];[enc setCullMode:MTLCullModeNone];[enc setVertexBytes:u.rect length:sizeof(u.rect) atIndex:0];
  [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];[enc setFragmentTexture:source atIndex:0];[enc setFragmentSamplerState:mtl_bloom.sampler atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];
 }
 mtl_bloom.ready=YES;return YES;
}

static BOOL MTL_BloomCompositePipeline(MTLPixelFormat color,MTLPixelFormat depth,NSUInteger samples)
{
 if(mtl_bloom.composite&&mtl_bloom.composite_color==color&&mtl_bloom.composite_depth==depth&&mtl_bloom.composite_samples==samples)return YES;
 if(!mtl_bloom.library||!mtl_bloom.no_depth||!mtl_bloom.sampler)return NO;
 MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.label=@"openMerc native bloom LDR composite";
 d.vertexFunction=[mtl_bloom.library newFunctionWithName:@"bloom_v"];d.fragmentFunction=[mtl_bloom.library newFunctionWithName:@"bloom_composite"];
 d.colorAttachments[0].pixelFormat=color;d.depthAttachmentPixelFormat=depth;d.rasterSampleCount=samples;NSError *error=nil;
 id<MTLRenderPipelineState> state=[mtl_device newRenderPipelineStateWithDescriptor:d error:&error];if(!state)return NO;
 mtl_bloom.composite=state;mtl_bloom.composite_color=color;mtl_bloom.composite_depth=depth;mtl_bloom.composite_samples=samples;return YES;
}

/* Caller resumes the window and sets the physical view viewport/scissor. Debug1
 * is emission regardless of bloom; debug2 is bloom-only only if bloom ran. */
static BOOL MTL_BloomComposite(id<MTLRenderCommandEncoder> encoder,id<MTLTexture> scene,id<MTLTexture> emission,
 MTLPixelFormat color,MTLPixelFormat depth,NSUInteger samples,int x,int y,int width,int height,int debug,BOOL enabled)
{
 if(!encoder||!scene||!emission||!MTL_BloomCompositePipeline(color,depth,samples))return NO;
 BOOL bloom=enabled&&mtl_bloom.ready&&mtl_bloom.nlevels>0;
 unsigned mode=debug==1?2:debug==2&&bloom?3:bloom?1:0;
 mtl_bloom_composite_t u={mtl_bloom_intensity->value*2/(mtl_bloom.nlevels>0?mtl_bloom.nlevels:1),mode,{0,0}};
 float rect[4]={(float)x/scene.width,(float)y/scene.height,(float)width/scene.width,(float)height/scene.height};
 [encoder setRenderPipelineState:mtl_bloom.composite];[encoder setDepthStencilState:mtl_bloom.no_depth];[encoder setCullMode:MTLCullModeNone];
 [encoder setVertexBytes:rect length:sizeof(rect) atIndex:0];[encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
 [encoder setFragmentTexture:scene atIndex:0];[encoder setFragmentTexture:bloom?mtl_bloom.level[0]:emission atIndex:1];[encoder setFragmentTexture:emission atIndex:2];
 [encoder setFragmentSamplerState:mtl_bloom.sampler atIndex:0];[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];return YES;
}
#endif
