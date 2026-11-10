// SPDX-License-Identifier: GPL-2.0-or-later
// Native view overlays AFTER post composition, BEFORE ordinary2D/HUD.
// Implements: SPEC-412 section11 and current GPL gl3_fx.c ScreenOverlays.
// Include after mtl_post.h. Separate resources never own HUD/FX images.
#ifndef OM_METAL_POST_OVERLAY_H
#define OM_METAL_POST_OVERLAY_H
#include <stdlib.h>
#include <string.h>
static float mtl_framepost_nv_time;
static BOOL mtl_framepost_nv_bright;
static id<MTLTexture> mtl_framepost_nv_texture;
static id<MTLSamplerState> mtl_framepost_nv_sampler;
static cvar_t *mtl_framepost_warnings;
static id<MTLRenderPipelineState> mtl_framepost_overlay_pipeline[2];
static MTLPixelFormat mtl_framepost_overlay_color,mtl_framepost_overlay_depth;

static int MTL_FramePostIRand(int lo,int hi)
{return lo+(int)((hi-lo+1)*((float)rand()/((float)RAND_MAX+1.0f)));}
static float MTL_FramePostFRand(float lo,float hi)
{return lo+(hi-lo)*((float)rand()/(float)RAND_MAX);}

static void MTL_FramePostNVGenerate(unsigned char out[64*64*4])
{
 mtl_framepost_nv_bright=MTL_FramePostIRand(0,10)==0;
 float m=1;if(mtl_framepost_nv_time<2)m=mtl_framepost_nv_time<=1.5f?mtl_framepost_nv_time:3.0f-mtl_framepost_nv_time;
 for(int i=0;i<64*64;i++){
  int r=mtl_framepost_nv_bright?0:40,g=mtl_framepost_nv_bright?MTL_FramePostIRand(220,255):MTL_FramePostIRand(160,210),b=r;
  if(mtl_framepost_nv_time<2){
   r=(int)(r*m);b=(int)(b*m);g=(int)(g*m);
   if(g>255)g=MTL_FramePostIRand(230,255);if(r>255)r=255;if(b>255)b=255;
  }
  out[i*4]=(unsigned char)r;out[i*4+1]=(unsigned char)g;out[i*4+2]=(unsigned char)b;out[i*4+3]=255;
 }
}

static void MTL_PostOverlayInit(void)
{
 mtl_framepost_nv_time=0;mtl_framepost_nv_bright=NO;
 mtl_framepost_warnings=ri.Cvar_Get("r_warnings","0",0);
 MTLSamplerDescriptor *s=[MTLSamplerDescriptor new];s.minFilter=s.magFilter=MTLSamplerMinMagFilterNearest;
 s.sAddressMode=s.tAddressMode=MTLSamplerAddressModeRepeat;mtl_framepost_nv_sampler=[mtl_device newSamplerStateWithDescriptor:s];
}
static void MTL_PostOverlayShutdown(void)
{
 mtl_framepost_nv_texture=nil;mtl_framepost_nv_sampler=nil;mtl_framepost_nv_time=0;mtl_framepost_nv_bright=NO;
 mtl_framepost_overlay_pipeline[0]=mtl_framepost_overlay_pipeline[1]=nil;mtl_framepost_warnings=NULL;
}

static id<MTLRenderPipelineState> MTL_FramePostOverlayPipeline(int multiply)
{
 MTLPixelFormat color=mtl_current_targets.color[0].pixelFormat;
 MTLPixelFormat depth=mtl_current_targets.depth?mtl_current_targets.depth.pixelFormat:MTLPixelFormatInvalid;
 if(color!=mtl_framepost_overlay_color||depth!=mtl_framepost_overlay_depth){
  mtl_framepost_overlay_pipeline[0]=mtl_framepost_overlay_pipeline[1]=nil;
  mtl_framepost_overlay_color=color;mtl_framepost_overlay_depth=depth;
 }
 if(mtl_framepost_overlay_pipeline[multiply])return mtl_framepost_overlay_pipeline[multiply];
 NSString *extra=@R"MSL(
fragment float4 framepost_noise(FramePostOut in [[stage_in]],texture2d<float> t [[texture(0)]],sampler s [[sampler(0)]]){return t.sample(s,in.uv);}
fragment float4 framepost_tint(FramePostOut in [[stage_in]],constant float4 &c [[buffer(1)]]){return c;}
)MSL";
 NSError *error=nil;id<MTLLibrary> lib=[mtl_device newLibraryWithSource:[NSString stringWithFormat:@"%@\n%@",mtl_framepost_shader,extra] options:nil error:&error];
 if(!lib){MTL_Fatal("view overlay shader",error.localizedDescription.UTF8String);return nil;}
 MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[lib newFunctionWithName:@"framepost_v"];
 d.fragmentFunction=[lib newFunctionWithName:multiply?@"framepost_noise":@"framepost_tint"];
 d.colorAttachments[0].pixelFormat=color;d.depthAttachmentPixelFormat=depth;d.colorAttachments[0].blendingEnabled=YES;
 d.colorAttachments[0].sourceRGBBlendFactor=multiply?MTLBlendFactorDestinationColor:MTLBlendFactorSourceAlpha;
 d.colorAttachments[0].destinationRGBBlendFactor=multiply?MTLBlendFactorZero:MTLBlendFactorOneMinusSourceAlpha;
 d.colorAttachments[0].sourceAlphaBlendFactor=multiply?MTLBlendFactorDestinationAlpha:MTLBlendFactorSourceAlpha;
 d.colorAttachments[0].destinationAlphaBlendFactor=multiply?MTLBlendFactorZero:MTLBlendFactorOneMinusSourceAlpha;
 id<MTLRenderPipelineState> p=[mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
 if(!p)MTL_Fatal("view overlay pipeline",error.localizedDescription.UTF8String);
 mtl_framepost_overlay_pipeline[multiply]=p;return p;
}

static void MTL_FramePostOverlayQuad(int x,int y,int width,int height,id<MTLTexture> texture,
 const float uv[4],const float color[4],int multiply)
{
 if(!MTL_TargetTracked()||mtl_current_targets.color_count!=1||width<=0||height<=0||x<0||y<0)return;
 NSUInteger w=mtl_current_targets.color[0].width,h=mtl_current_targets.color[0].height;
 if((NSUInteger)x>w||(NSUInteger)y>h||(NSUInteger)width>w-(NSUInteger)x||(NSUInteger)height>h-(NSUInteger)y)return;
 mtl_frame_targets_t saved=mtl_current_targets;
 [mtl_enc setViewport:(MTLViewport){(double)x,(double)y,(double)width,(double)height,0,1}];
 [mtl_enc setScissorRect:(MTLScissorRect){(NSUInteger)x,(NSUInteger)y,(NSUInteger)width,(NSUInteger)height}];
 [mtl_enc setRenderPipelineState:MTL_FramePostOverlayPipeline(multiply)];
 [mtl_enc setDepthStencilState:mtl_framepost_no_depth];[mtl_enc setCullMode:MTLCullModeNone];[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
 [mtl_enc setVertexBytes:uv length:4*sizeof(float) atIndex:0];[mtl_enc setFragmentBytes:color length:4*sizeof(float) atIndex:1];
 if(multiply){[mtl_enc setFragmentTexture:texture atIndex:0];[mtl_enc setFragmentSamplerState:mtl_framepost_nv_sampler atIndex:0];}
 [mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];MTL_TargetApplyRaster(&saved);
}

/* warnings_eligible = world has vis and current leaf cluster>=0. Current GPL
 * wrapper implements the polygon-red warning; the older spec's Ghoul/texture
 * warning branches are absent there and are not invented here. */
static void MTL_PostScreenOverlays(int x,int y,int width,int height,int rdflags,float game_delta,
 const float blend[4],int brush_polygons,int warnings_eligible)
{
 if(rdflags&RDF_NOWORLDMODEL)mtl_framepost_nv_time=0;
 if(rdflags&RDF_IRGOGGLES){
  float uv[4];uv[0]=MTL_FramePostFRand(-16,-8);uv[1]=MTL_FramePostFRand(-16,-8);
  uv[2]=MTL_FramePostFRand(8,16)-uv[0];uv[3]=MTL_FramePostFRand(8,16)-uv[1];
  BOOL regenerate=NO;
  if(mtl_framepost_nv_time<2){mtl_framepost_nv_time+=game_delta;regenerate=YES;}
  else if(!mtl_framepost_nv_texture||MTL_FramePostIRand(0,10)<2||mtl_framepost_nv_bright)regenerate=YES;
  if(regenerate){
   unsigned char rgba[64*64*4];MTL_FramePostNVGenerate(rgba);
   MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
   d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
   id<MTLTexture> texture=[mtl_device newTextureWithDescriptor:d];
   if(texture){[texture replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:rgba bytesPerRow:64*4];mtl_framepost_nv_texture=texture;}
  }
  float white[4]={1,1,1,1};if(mtl_framepost_nv_texture)MTL_FramePostOverlayQuad(x,y,width,height,mtl_framepost_nv_texture,uv,white,1);
 }else{mtl_framepost_nv_time=0;mtl_framepost_nv_texture=nil;}
 float tint[4];memcpy(tint,blend,sizeof(tint));
 if(mtl_framepost_warnings&&mtl_framepost_warnings->value&&warnings_eligible&&brush_polygons>700){
  tint[0]=1;tint[1]=tint[2]=0;tint[3]=(brush_polygons-700)/150.0f+.2f;if(tint[3]>1)tint[3]=1;
 }
 if(tint[3]!=0){
  for(int k=0;k<4;k++){float f=tint[k]*255;unsigned char c=(unsigned char)(f<0?0:f>255?255:f);tint[k]=c/255.0f;}
  float uv[4]={0,0,1,1};MTL_FramePostOverlayQuad(x,y,width,height,nil,uv,tint,0);
 }
}
#endif
