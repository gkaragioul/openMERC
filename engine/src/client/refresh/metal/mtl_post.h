// SPDX-License-Identifier: GPL-2.0-or-later
// Single-sample identity framegraph. Implements: SPEC-002, SPEC-412 section11,
// SPEC-413 projection/clear controls and current GPL gl3_post.c view lifecycle.
// Bloom/fog/MSAA processing is explicitly staged after this identity gate.
#ifndef OM_METAL_POST_H
#define OM_METAL_POST_H
#include "mtl_framepost_math.h"
/* The host includes mtl_emission_state.h before this framegraph. */
static void MTL_PostEmissionViewState(BOOL active,BOOL source_enabled);

typedef struct {
 BOOL active,bloom,bloomthis,soft,volfog,depthcopied,force_identity;
 BOOL no_sky; /* the level has no sky pictures (`sky none`): nothing ever draws its sky faces */
 int x,y,width,height,window_width,window_height,samples,fog_regions;
 id<MTLTexture> scene,emissive,depth,depthcopy;
 mtl_frame_targets_t window;
 float projection[16],view[16],pv[16],inverse_pv[16],eye[3],C,D,depth_min,depth_max;
} mtl_post_state_t;
static mtl_post_state_t mtl_post;
static cvar_t *mtl_framepost_bloom,*mtl_framepost_soft,*mtl_framepost_volfog;
static cvar_t *mtl_framepost_debug,*mtl_framepost_identity,*mtl_framepost_clear,*mtl_framepost_ztrick;
static cvar_t *mtl_framepost_fogmode,*mtl_framepost_volfog_intensity;
static id<MTLRenderPipelineState> mtl_framepost_copy_pipeline;
static MTLPixelFormat mtl_framepost_copy_format,mtl_framepost_copy_depth_format;
static id<MTLDepthStencilState> mtl_framepost_no_depth;
static id<MTLSamplerState> mtl_framepost_linear,mtl_framepost_nearest;
/* Task4/7 may install native scene processing here. Forced identity skips it. */
static void (*mtl_framepost_process_view)(void);
/* Returns YES only when a replacement composite was encoded into the window. */
static BOOL (*mtl_framepost_composite_view)(void);

static NSString *const mtl_framepost_shader=@R"MSL(
#include <metal_stdlib>
using namespace metal;
struct FramePostOut{float4 position [[position]];float2 uv;};
vertex FramePostOut framepost_v(uint i [[vertex_id]],constant float4 &rect [[buffer(0)]]){
 float2 p=float2(i==1?2:0,i==2?2:0);FramePostOut o;
 o.position=float4(2*p.x-1,1-2*p.y,0,1);o.uv=rect.xy+p*rect.zw;return o;
}
fragment float4 framepost_f(FramePostOut in [[stage_in]],texture2d<float> tex [[texture(0)]],sampler s [[sampler(0)]]){
 return float4(tex.sample(s,in.uv).rgb,1);
}
)MSL";

static id<MTLTexture> MTL_FramePostTexture(MTLPixelFormat format,NSUInteger width,NSUInteger height)
{
 MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
 d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
 return [mtl_device newTextureWithDescriptor:d];
}

static BOOL MTL_FramePostPipeline(const mtl_frame_targets_t *window)
{
 MTLPixelFormat color=window->color[0].pixelFormat,depth=window->depth?window->depth.pixelFormat:MTLPixelFormatInvalid;
 if(mtl_framepost_copy_pipeline&&color==mtl_framepost_copy_format&&depth==mtl_framepost_copy_depth_format)return YES;
 NSError *error=nil;id<MTLLibrary> lib=[mtl_device newLibraryWithSource:mtl_framepost_shader options:nil error:&error];
 if(!lib)return NO;
 MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.label=@"openMerc identity view composition";
 d.vertexFunction=[lib newFunctionWithName:@"framepost_v"];d.fragmentFunction=[lib newFunctionWithName:@"framepost_f"];
 d.colorAttachments[0].pixelFormat=color;d.depthAttachmentPixelFormat=depth;
 id<MTLRenderPipelineState> pipeline=[mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
 if(!pipeline)return NO;
 mtl_framepost_copy_pipeline=pipeline;mtl_framepost_copy_format=color;mtl_framepost_copy_depth_format=depth;return YES;
}

static void MTL_PostInit(void)
{
 mtl_post=(mtl_post_state_t){};mtl_framepost_process_view=NULL;mtl_framepost_composite_view=NULL;
 MTL_PostEmissionViewState(NO,NO);
 mtl_framepost_bloom=ri.Cvar_Get("r_om_bloom","1",CVAR_ARCHIVE);
 mtl_framepost_soft=ri.Cvar_Get("r_om_softparticles","0",CVAR_ARCHIVE);
 mtl_framepost_volfog=ri.Cvar_Get("r_om_volfog","1",CVAR_ARCHIVE);
 mtl_framepost_volfog_intensity=ri.Cvar_Get("r_om_volfog_intensity","0.4",CVAR_ARCHIVE);
 mtl_framepost_fogmode=ri.Cvar_Get("gl_fogmode","0",0);
 mtl_framepost_debug=ri.Cvar_Get("r_om_post_debug","0",0);
 mtl_framepost_identity=ri.Cvar_Get("r_metal_post_identity","0",0);
 mtl_framepost_clear=ri.Cvar_Get("gl_clear","0",CVAR_ARCHIVE);
 mtl_framepost_ztrick=ri.Cvar_Get("gl_ztrick","0",0);
 MTLDepthStencilDescriptor *depth=[MTLDepthStencilDescriptor new];depth.depthCompareFunction=MTLCompareFunctionAlways;depth.depthWriteEnabled=NO;
 mtl_framepost_no_depth=[mtl_device newDepthStencilStateWithDescriptor:depth];
 MTLSamplerDescriptor *sampler=[MTLSamplerDescriptor new];sampler.sAddressMode=sampler.tAddressMode=MTLSamplerAddressModeClampToEdge;
 sampler.minFilter=sampler.magFilter=MTLSamplerMinMagFilterLinear;mtl_framepost_linear=[mtl_device newSamplerStateWithDescriptor:sampler];
 sampler.minFilter=sampler.magFilter=MTLSamplerMinMagFilterNearest;mtl_framepost_nearest=[mtl_device newSamplerStateWithDescriptor:sampler];
}

static void MTL_PostSetFogRegionCount(int count){mtl_post.fog_regions=count>0?count:0;}
static BOOL MTL_PostDepthReady(void){return mtl_post.active&&mtl_post.depthcopied;}
static id<MTLTexture> MTL_PostOpaqueDepth(void){return MTL_PostDepthReady()?mtl_post.depthcopy:nil;}

static BOOL MTL_PostBeginView(int x,int y,int width,int height,const float projection[16],const float view[16])
{
 if(mtl_post.active)return NO;
 MTL_PostEmissionViewState(NO,NO);
 mtl_post.bloom=mtl_post.bloomthis=mtl_post.soft=mtl_post.volfog=mtl_post.depthcopied=NO;
 if(!mtl_framepost_bloom||!mtl_worldmodel||(mtl_refdef.rdflags&RDF_NOWORLDMODEL)||!MTL_TargetTracked())return NO;
 BOOL nv=(mtl_fullbright_cvar&&mtl_fullbright_cvar->value)||(mtl_refdef.rdflags&RDF_IRGOGGLES);
 BOOL bloom=mtl_framepost_bloom->value&&!nv,soft=mtl_framepost_soft->value!=0;
 int fogmode=(int)mtl_framepost_fogmode->value;
 BOOL volfog=mtl_framepost_volfog->value&&mtl_framepost_volfog_intensity->value>0&&mtl_post.fog_regions>0&&fogmode!=2&&fogmode!=3&&!nv;
 BOOL identity=mtl_framepost_identity->value!=0,debug=mtl_framepost_debug->value!=0;
 if(!bloom&&!soft&&!volfog&&!debug&&!identity)return NO;
 mtl_frame_targets_t window=mtl_current_targets;
 NSUInteger w=window.color[0].width,h=window.color[0].height;
 if(window.color_count!=1||window.samples>1||x<0||y<0||width<=0||height<=0||
  (NSUInteger)x>w||(NSUInteger)y>h||(NSUInteger)width>w-(NSUInteger)x||(NSUInteger)height>h-(NSUInteger)y)return NO;
 float pv[16],inverse[16],inverse_view[16];
 if(!projection||!view)return NO;
 MTL_FramePostMultiply(projection,view,pv);
 if(!MTL_FramePostInverse(pv,inverse)||!MTL_FramePostInverse(view,inverse_view)||inverse_view[15]==0)return NO;
 if(!MTL_FramePostPipeline(&window)||!mtl_framepost_no_depth||!mtl_framepost_linear)return NO;
 BOOL fresh=!mtl_post.scene||mtl_post.scene.width!=w||mtl_post.scene.height!=h;
 id<MTLTexture> scene=mtl_post.scene,emission=mtl_post.emissive,depth=mtl_post.depth,copy=mtl_post.depthcopy;
 if(fresh){
  scene=MTL_FramePostTexture(MTLPixelFormatBGRA8Unorm,w,h);emission=MTL_FramePostTexture(MTLPixelFormatRGBA8Unorm,w,h);
  depth=MTL_FramePostTexture(MTLPixelFormatDepth32Float,w,h);copy=MTL_FramePostTexture(MTLPixelFormatDepth32Float,w,h);
  if(!scene||!emission||!depth||!copy)return NO;
 }
 mtl_frame_targets_t targets={};targets.color[0]=scene;targets.color[1]=emission;targets.depth=depth;targets.color_count=2;targets.samples=1;
 targets.viewport=(MTLViewport){(double)x,(double)y,(double)width,(double)height,window.viewport.znear,window.viewport.zfar};
 targets.scissor=(MTLScissorRect){(NSUInteger)x,(NSUInteger)y,(NSUInteger)width,(NSUInteger)height};targets.clear_depth=window.viewport.znear>window.viewport.zfar?0:1;
 if(mtl_framepost_clear->value&&mtl_framepost_ztrick->value)targets.clear_color[0]=MTLClearColorMake(1,0,.5,.5);
 if(!MTL_TargetValid(&targets))return NO;
 /* RLabs 2026-11-08: this texture outlives a level change, so a level with `sky none` (sib1, irq3b) showed the last
    frame of the level before it through its sky faces, and old pixels would smear there as the view turns. SPEC-410
    leaves those pixels undefined; region fog paints over them where a region has fog (mtl_fog_frame.h), and the
    clear is what remains where none does, or with gl_fogmode 2. DEVIATIONS.md */
 const MTLLoadAction loads[2]={fresh||mtl_framepost_clear->value||mtl_post.no_sky?MTLLoadActionClear:MTLLoadActionLoad,MTLLoadActionClear};
 /* All allocation/descriptor validation precedes ending the old pass. Metal
  * permits only one active encoder per command buffer; unexpected open
  * failure therefore restores the saved pass with Load, preserving work. */
 MTL_TargetEnd();
 if(!MTL_TargetOpenLoads(&targets,loads,MTLLoadActionClear)){
  if(!MTL_TargetResume(mtl_cb,&window))MTL_Fatal("PostBeginView","could not restore window after target failure");return NO;
 }
 mtl_post.scene=scene;mtl_post.emissive=emission;mtl_post.depth=depth;mtl_post.depthcopy=copy;mtl_post.window=window;
 mtl_post.x=x;mtl_post.y=y;mtl_post.width=width;mtl_post.height=height;mtl_post.window_width=(int)w;mtl_post.window_height=(int)h;mtl_post.samples=1;
 mtl_post.active=YES;mtl_post.bloomthis=bloom;mtl_post.bloom=bloom||debug;mtl_post.soft=soft;mtl_post.volfog=volfog;mtl_post.force_identity=identity;
 MTL_PostEmissionViewState(YES,bloom||debug);
 memcpy(mtl_post.projection,projection,64);memcpy(mtl_post.view,view,64);memcpy(mtl_post.pv,pv,64);memcpy(mtl_post.inverse_pv,inverse,64);
 for(int k=0;k<3;k++)mtl_post.eye[k]=inverse_view[12+k]/inverse_view[15];
 mtl_post.C=projection[10];mtl_post.D=projection[14];mtl_post.depth_min=targets.viewport.znear;mtl_post.depth_max=targets.viewport.zfar;
 return YES;
}

static void MTL_PostCopyOpaqueDepth(void)
{
 if(!mtl_post.active||mtl_post.depthcopied||!(mtl_post.soft||mtl_post.volfog||mtl_post.force_identity))return;
 mtl_frame_targets_t targets=mtl_current_targets;MTL_TargetEnd();
 id<MTLBlitCommandEncoder> blit=[mtl_cb blitCommandEncoder];
 if(blit){
  /* World depth was cleared to far across the full allocation. Copying the
   * full native Depth32 image also deterministically retires stale pixels
   * outside this view; consumers sample only the physical view rectangle. */
  [blit copyFromTexture:mtl_post.depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
   sourceSize:MTLSizeMake(mtl_post.depth.width,mtl_post.depth.height,1) toTexture:mtl_post.depthcopy
   destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
  [blit endEncoding];mtl_post.depthcopied=YES;
 }
 if(!MTL_TargetResume(mtl_cb,&targets))MTL_Fatal("PostDepthCopy","could not resume world MRT");
}

static void MTL_PostEndView(void)
{
 if(!mtl_post.active)return;
 if(!mtl_post.force_identity&&mtl_framepost_process_view)mtl_framepost_process_view();
 MTL_TargetEnd();
 if(!MTL_TargetResume(mtl_cb,&mtl_post.window))MTL_Fatal("PostEndView","could not restore window");
 MTLViewport viewport={(double)mtl_post.x,(double)mtl_post.y,(double)mtl_post.width,(double)mtl_post.height,0,1};
 MTLScissorRect scissor={(NSUInteger)mtl_post.x,(NSUInteger)mtl_post.y,(NSUInteger)mtl_post.width,(NSUInteger)mtl_post.height};
 [mtl_enc setViewport:viewport];[mtl_enc setScissorRect:scissor];
 float rect[4]={(float)mtl_post.x/mtl_post.window_width,(float)mtl_post.y/mtl_post.window_height,
  (float)mtl_post.width/mtl_post.window_width,(float)mtl_post.height/mtl_post.window_height};
 [mtl_enc setDepthStencilState:mtl_framepost_no_depth];
 [mtl_enc setCullMode:MTLCullModeNone];[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
 /* Process hooks may end the world pass; composite hooks receive the restored
  * single-color window and physical view raster. A declined replacement must
  * leave its destination unchanged so the identity fallback remains valid. */
 BOOL composited=!mtl_post.force_identity&&mtl_framepost_composite_view&&mtl_framepost_composite_view();
 if(!composited){
  [mtl_enc setViewport:viewport];[mtl_enc setScissorRect:scissor];
  [mtl_enc setRenderPipelineState:mtl_framepost_copy_pipeline];[mtl_enc setDepthStencilState:mtl_framepost_no_depth];
  [mtl_enc setCullMode:MTLCullModeNone];[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
  [mtl_enc setVertexBytes:rect length:sizeof(rect) atIndex:0];[mtl_enc setFragmentTexture:mtl_post.scene atIndex:0];
  [mtl_enc setFragmentSamplerState:mtl_framepost_linear atIndex:0];[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
 }
 MTL_TargetApplyRaster(&mtl_post.window);
 mtl_post.active=mtl_post.bloom=mtl_post.bloomthis=mtl_post.soft=mtl_post.volfog=mtl_post.depthcopied=NO;
 MTL_PostEmissionViewState(NO,NO);
}

static void MTL_PostShutdown(void)
{
 if(mtl_post.active){MTL_TargetEnd();if(!MTL_TargetResume(mtl_cb,&mtl_post.window))MTL_Fatal("PostShutdown","could not restore window");}
 mtl_post=(mtl_post_state_t){};mtl_framepost_copy_pipeline=nil;mtl_framepost_no_depth=nil;
 MTL_PostEmissionViewState(NO,NO);
 mtl_framepost_linear=mtl_framepost_nearest=nil;mtl_framepost_process_view=NULL;mtl_framepost_composite_view=NULL;
 mtl_framepost_bloom=mtl_framepost_soft=mtl_framepost_volfog=NULL;
 mtl_framepost_debug=mtl_framepost_identity=mtl_framepost_clear=mtl_framepost_ztrick=NULL;
 mtl_framepost_fogmode=mtl_framepost_volfog_intensity=NULL;
}
#endif
