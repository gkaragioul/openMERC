// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-412 section11 through actual GPL gl3_fx.c oracles.
#define main IdentityRegressionMain
#include "post_identity.mm"
#undef main
#if !POST_OVERLAY_OLD
typedef unsigned char byte;
#include "../mtl_post_overlay.h"
static unsigned char reference_noise[64*64*3];
static float nvtime;static int nvbright,nvhavetex;static unsigned noisetex;
#define GL_UNPACK_ALIGNMENT 0
#define GL_TEXTURE_2D 0
#define GL_RGB8 0
#define GL_RGB 0
#define GL_UNSIGNED_BYTE 0
#define GL_TEXTURE_MIN_FILTER 0
#define GL_TEXTURE_MAG_FILTER 0
#define GL_NEAREST 0
#define GL_TEXTURE_WRAP_S 0
#define GL_TEXTURE_WRAP_T 0
#define GL_REPEAT 0
#define GL_TEXTURE_MAX_LEVEL 0
static void glGenTextures(int,unsigned *out){*out=1;}
static void GL3_Bind(unsigned){}
static void glPixelStorei(int,int){}
static void glTexParameteri(int,int,int){}
static void glTexImage2D(int,int,int,int,int,int,int,int,const void *data){memcpy(reference_noise,data,sizeof(reference_noise));}
#include "post_overlay_reference.h"
#endif
int main(){@autoreleasepool{
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 77;mtl_queue=[mtl_device newCommandQueue];mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;pipelines();
 begin();fill(.05f,100/255.f,80/255.f,40/255.f);
#if !POST_OVERLAY_OLD
 MTL_PostInit();MTL_PostOverlayInit();
 auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];td.storageMode=MTLStorageModeShared;
 auto noise=[mtl_device newTextureWithDescriptor:td];unsigned char color[4]={40,200,40,255};[noise replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:color bytesPerRow:4];
 float uv[4]={0,0,1,1},white[4]={1,1,1,1};
 MTL_FramePostOverlayQuad(7,9,31,23,noise,uv,white,1);
 float tint[4]={1,0,0,.5f};MTL_PostScreenOverlays(7,9,31,23,0,.1f,tint,0,0);
#endif
 fill(.1f,0,1,0);finish();pixel(window_targets.color[0],20,20,135,32,3,"post ordering: nightvision multiply then quantized source-over tint");pixel(window_targets.color[0],2,2,100,80,40,"overlays stay inside physical view");check(fabsf(depth_at(window_targets.depth,20,20)-.05f)<1e-6,"screen overlays never write window depth");
#if !POST_OVERLAY_OLD
 for(int bright=0;bright<2;bright++){
  int seed=0;for(;seed<1000;seed++){srand(seed);if((IRand(0,10)==0)==(bright!=0))break;}
  check(seed<1000,"deterministic seeds exercise bright and ordinary GPL noise branches");
  for(float time:{0.f,.5f,1.5f,1.9f,2.f}){
   nvtime=time;srand(seed);NightVisionTexture();unsigned char rgba[64*64*4];mtl_framepost_nv_time=time;srand(seed);MTL_FramePostNVGenerate(rgba);
   bool equal=mtl_framepost_nv_bright==(bright!=0);for(int i=0;i<64*64;i++)for(int k=0;k<3;k++)equal&=rgba[i*4+k]==reference_noise[i*3+k];
   check(equal,"bright/ordinary noise and fade bytes equal actual GPL generator");
  }
 }
 MTL_PostOverlayShutdown();MTL_PostOverlayInit();set("r_warnings",1);
 begin();fill(.05f,100/255.f,80/255.f,40/255.f);float no_tint[4]={0,0,0,0};MTL_PostScreenOverlays(7,9,31,23,0,.1f,no_tint,730,1);finish();pixel(window_targets.color[0],20,20,162,48,24,"current GPL polygon warning replaces view tint");
 set("r_warnings",0);begin();fill(.05f,100/255.f,80/255.f,40/255.f);MTL_PostScreenOverlays(7,9,31,23,RDF_IRGOGGLES,0,no_tint,0,0);finish();check(mtl_framepost_nv_time==0,"paused game clock holds nightvision fade");pixel(window_targets.color[0],20,20,0,0,0,"zero-time nightvision fade uses black modulation");
 // Past the fade, the ordinary source is reused unless the fifth random
 // draw (after four UV draws) requests regeneration; bright frames regenerate.
 int reuse_seed=0;for(;reuse_seed<1000;reuse_seed++){srand(reuse_seed);for(int i=0;i<4;i++)(void)FRand(-16,-8);if(IRand(0,10)>=2)break;}
 auto previous_noise=mtl_framepost_nv_texture;mtl_framepost_nv_time=2.1f;mtl_framepost_nv_bright=NO;srand(reuse_seed);
 begin();MTL_PostScreenOverlays(7,9,31,23,RDF_IRGOGGLES,.1f,no_tint,0,0);finish();
 check(mtl_framepost_nv_texture==previous_noise&&mtl_framepost_nv_time==2.1f,"ordinary post-fade noise can reuse its immutable texture");
 mtl_framepost_nv_bright=YES;srand(reuse_seed);begin();MTL_PostScreenOverlays(7,9,31,23,RDF_IRGOGGLES,.1f,no_tint,0,0);finish();
 check(mtl_framepost_nv_texture!=previous_noise,"bright post-fade noise always regenerates");
 begin();MTL_PostScreenOverlays(7,9,31,23,0,.1f,no_tint,0,0);finish();check(!mtl_framepost_nv_texture&&mtl_framepost_nv_time==0,"nightvision off retires noise and resets timer");MTL_PostOverlayShutdown();MTL_PostShutdown();
#endif
 printf("Post overlay checks: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}}
