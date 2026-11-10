// SPDX-License-Identifier: GPL-2.0-or-later
// Independent literal lightmap pixel oracles through production native MSL.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <cstdint>
#define MTL_MAX_DLIGHTS 32
typedef unsigned char byte;
typedef bool qboolean;
typedef struct {float rgb[3],white;} lightstyle_t;
typedef struct {float origin[3],color[3],intensity;} dlight_t;
static id<MTLDevice> mtl_device;
static CAMetalLayer *mtl_layer;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLTexture> mtl_white;
static int checks,failures;
static void MTL_Fatal(const char *where,const char *why)
{fprintf(stderr,"FATAL %s: %s\n",where,why?why:"");abort();}
#include "lightmap_production.h"
#ifndef OM_LIGHTMAP_BASELINE
#include "mtl_lightmap.h"
#include "mtl_lightmap_shader.h"
typedef float vec3_t[3];
typedef struct {float normal[3],dist;} cplane_t;
typedef struct {int animrate;} mtl_image_t;
typedef struct mtexinfo_s {float vecs[2][4];unsigned flags;mtl_image_t *image;struct mtexinfo_s *next;int numframes;} mtexinfo_t;
static float game_clock;
static float MTL_GameTime(void) {return game_clock;}
#include "lightmap_animation_production.h"
typedef struct {mtexinfo_t *texinfo;int lmsize[2],dlightframe;unsigned dlightbits;byte *samples;cplane_t *plane;int texturemins[2],lmstep[2];} msurface_t;
static int gl3_framecount=1;
static struct {float value;} dynamic_cvar={1},*gl_dynamic=&dynamic_cvar;
static struct {dlight_t *dlights;int num_dlights;} r_newrefdef;
#define DYN_MAX_SAMPLES 12288
#define DLIGHT_CUTOFF 64
#define SOFSURF_SKY 4
#define SURF_WARP 8
#define SOFSURF_ALPHA 0x800
#define DotProduct(a,b) ((a)[0]*(b)[0]+(a)[1]*(b)[1]+(a)[2]*(b)[2])
#define VectorMA(a,s,b,c) do {for(int k=0;k<3;k++)(c)[k]=(a)[k]+(s)*(b)[k];}while(0)
static float blockbuf[DYN_MAX_SAMPLES*4],oracle_dynamic[DYN_MAX_SAMPLES*4];
static int Remember(msurface_t *) {return 1;}
static void UploadBlock(msurface_t *s,const float *data) {memcpy(oracle_dynamic,data,(size_t)s->lmsize[0]*s->lmsize[1]*4*sizeof(float));}
#include "lightmap_dynamic_oracle.h"
#endif
static void check(bool ok,const char *name,int got=-1,int expected=-1)
{checks++;if(!ok){failures++;fprintf(stderr,"FAIL %s (got %d expected %d)\n",name,got,expected);}}
static id<MTLTexture> rgba_texture(const byte *rgba,int w,int h)
{
 auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
 auto t=[mtl_device newTextureWithDescriptor:d];[t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:rgba bytesPerRow:w*4];return t;
}
static id<MTLTexture> dynamic_texture(const float rgb[3])
{
 auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:1 height:1 mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;auto t=[mtl_device newTextureWithDescriptor:d];
 __fp16 p[4]={(__fp16)rgb[0],(__fp16)rgb[1],(__fp16)rgb[2],0};[t replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:p bytesPerRow:8];return t;
}
static id<MTLRenderPipelineState> pipeline;
static id<MTLCommandQueue> queue;
static id<MTLSamplerState> linear,nearest,diffuse_sampler;
static lightstyle_t styles[256];
static mtl_world_uniform_t u;
static void draw_case(const char *name,const std::vector<byte> &samples,int width,int maps,float modulate,
 int mode,int r,int g,int b,bool live=true,const float *dyn=nullptr,bool fullbright=false,bool reverseTable=false,
 float diffuse_u=0.5f,float offset_s=0,bool checker=false)
{
 byte ids[4]={255,255,255,255};for(int i=0;i<maps;i++)ids[i]=(byte)i;
 auto td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;auto target=[mtl_device newTextureWithDescriptor:td];
 td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:8 height:8 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;auto depth=[mtl_device newTextureWithDescriptor:td];
 auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
 pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.clearDepth=1;
 auto cb=[queue commandBuffer];mtl_enc=[cb renderCommandEncoderWithDescriptor:pass];
 [mtl_enc setRenderPipelineState:pipeline];[mtl_enc setCullMode:MTLCullModeNone];
 mtl_world_vertex_t verts[6]={};const float xy[6][2]={{-1,-1},{-1,1},{1,1},{-1,-1},{1,1},{1,-1}};
 for(int i=0;i<6;i++){verts[i].pos[0]=xy[i][0];verts[i].pos[1]=xy[i][1];verts[i].pos[2]=0.5;verts[i].uv[0]=diffuse_u;verts[i].uv[1]=verts[i].luv[0]=verts[i].luv[1]=0.5;}
 u.fullbright=fullbright;u.lm_adjust[0]=offset_s;[mtl_enc setVertexBytes:verts length:sizeof(verts) atIndex:0];[mtl_enc setVertexBytes:&u length:sizeof(u) atIndex:1];[mtl_enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
 byte colors[8]={255,0,0,255,0,255,0,255};auto diffuse=checker?rgba_texture(colors,2,1):mtl_white;
 [mtl_enc setFragmentTexture:diffuse atIndex:0];[mtl_enc setFragmentSamplerState:diffuse_sampler atIndex:0];[mtl_enc setFragmentSamplerState:linear atIndex:1];[mtl_enc setFragmentSamplerState:nearest atIndex:2];
 byte table[256];for(int i=0;i<256;i++)table[i]=reverseTable?255-i:i;
 auto tabd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:256 height:1 mipmapped:NO];tabd.storageMode=MTLStorageModeShared;auto tab=[mtl_device newTextureWithDescriptor:tabd];[tab replaceRegion:MTLRegionMake2D(0,0,256,1) mipmapLevel:0 withBytes:table bytesPerRow:256];[mtl_enc setFragmentTexture:tab atIndex:2];
 float zero[3]={0,0,0};auto dynamic=dynamic_texture(dyn?dyn:zero);
#ifdef OM_LIGHTMAP_BASELINE
 (void)modulate;(void)mode;(void)live;
 std::vector<byte> plane(width*4);for(int j=0;j<width;j++){for(int k=0;k<3;k++)plane[j*4+k]=samples[j*3+k];plane[j*4+3]=255;}
 auto first=rgba_texture(plane.data(),width,1);[mtl_enc setFragmentTexture:first atIndex:1];
#else
 mtl_lightmap_t *lm=MTL_LightmapCreate(samples.data(),samples.size(),width,1,ids,nullptr);
 if(!lm)MTL_Fatal("test create","valid fixture rejected");
 MTL_LightmapBind(lm,styles,live,modulate,mode,dynamic);
 // Release before submission: the encoded command owns its bound textures.
 MTL_LightmapFree(lm);
#endif
 [mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];[mtl_enc endEncoding];mtl_enc=nil;[cb commit];[cb waitUntilCompleted];if(cb.error)MTL_Fatal("lightmap GPU",cb.error.localizedDescription.UTF8String);
 byte out[8*8*4];[target getBytes:out bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];byte *p=out+(4*8+4)*4;
 check(abs(p[2]-r)<=1 && abs(p[1]-g)<=1 && abs(p[0]-b)<=1,name,p[2],r);
}
static void reset_styles(){for(auto &s:styles){s.rgb[0]=s.rgb[1]=s.rgb[2]=s.white=1;}}
#ifndef OM_LIGHTMAP_BASELINE
static void resource_math_checks()
{
 byte ids[4]={0,1,2,3};byte samples[12]={1,2,3,4,5,6,7,8,9,10,11,12};
 check(!MTL_LightmapCreate(samples,11,1,1,ids,nullptr),"all four sample planes must fit input bounds");
 check(!MTL_LightmapCreate(samples,sizeof(samples),129,1,ids,nullptr),"lightmap dimension limit");
 check(!MTL_LightmapCreate(nullptr,0,128,128,ids,nullptr),"lightmap sample-count limit");
 check(!MTL_LightmapCreate(nullptr,0,0,1,ids,nullptr),"zero dimension rejected");
 auto no_samples=MTL_LightmapCreate(nullptr,0,1,1,ids,nullptr);check(no_samples && !no_samples->has_samples,"missing samples retained as fullbright planes");MTL_LightmapFree(no_samples);
 byte end[4]={0,255,200,201};auto one=MTL_LightmapCreate(samples,3,1,1,end,nullptr);check(one && one->count==1,"style255 terminates sample bounds");MTL_LightmapFree(one);
 byte none[4]={255,255,255,255};auto unlit=MTL_LightmapCreate(nullptr,0,1,1,none,nullptr);check(unlit && unlit->count==1,"no samples and no styles gets white fallback");MTL_LightmapFree(unlit);
 check(MTL_LightmapMonoMode('0')==0 && MTL_LightmapMonoMode('L')==1 && MTL_LightmapMonoMode('I')==2 && MTL_LightmapMonoMode('C')==3 && MTL_LightmapMonoMode('A')==4 && MTL_LightmapMonoMode('l')==5,"mono selector matches case-sensitive map latch");
 float phase[2];int packed=(int)((30u<<16)|(unsigned short)-20);MTL_LightmapFlow(0x40,packed,2.5,phase);check(fabs(phase[0]+0.75f)<0.000001f && fabs(phase[1]-0.5f)<0.000001f,"signed packed flow speeds use game clock and distinct axes");
 MTL_LightmapFlow(0x40,packed,1000000002.5,phase);check(fabs(phase[0]+0.75f)<0.000001f && fabs(phase[1]-0.5f)<0.000001f,"long game clock retains fractional flow phase");
 MTL_LightmapFlow(0,packed,2.5,phase);check(phase[0]==0 && phase[1]==0,"non-flowing materials clear prior UV offset");
 float detail[2]={0,0},shift[2]={0.3f,-0.2f};MTL_LightmapDetailScroll(detail,shift,0.25f);MTL_LightmapDetailScroll(detail,shift,0.5f);check(fabs(detail[0]-0.225f)<0.000001f && fabs(detail[1]+0.15f)<0.000001f,"detail scroll accumulates game-clock delta");
 MTL_LightmapDetailScroll(detail,shift,0);check(fabs(detail[0]-0.225f)<0.000001f && fabs(detail[1]+0.15f)<0.000001f,"paused game clock leaves detail scroll unchanged");
 MTL_LightmapDetailScroll(detail,shift,9);check(fabs(detail[0]-0.925f)<0.000001f && fabs(detail[1]+1.95f)<0.000001f,"detail positive wrap preserves unwrapped negative reference behavior");
 mtl_image_t images[3]={{4},{0},{0}};mtexinfo_t chain[3]={};for(int i=0;i<3;i++){chain[i].image=&images[i];chain[i].next=&chain[(i+1)%3];chain[i].numframes=3;chain[i].flags=0x1000;}
 game_clock=1;check(MTL_AnimatedWorldImage(chain,0)==&images[1],"animation rate uses game clock");chain[0].flags=0;
 check(MTL_AnimatedWorldImage(chain,2)==&images[2],"opaque world caller frame selects chain image");
 check(MTL_AnimatedWorldImage(chain,-1)==&images[2],"negative entity animation wraps");chain[0].flags=0x1000;images[0].animrate=0;
 check(MTL_AnimatedWorldImage(chain,4)==&images[1],"zero animation rate falls back to entity frame");
 mtl_lightmap_geometry_t geometry={};geometry.normal[2]=1;geometry.texvecs[0][0]=geometry.texvecs[1][1]=1;geometry.steps[0]=geometry.steps[1]=16;
 mtl_lightmap_light_t light={};light.origin[2]=10;light.intensity=100;light.color[0]=1;float result[3*4];
 int lit=MTL_LightmapDynamicSamples(result,3,1,&geometry,1,&light,1);
 check(lit && fabs(result[0]*255-90)<0.001 && fabs(result[4]*255-74)<0.001 && result[8]==0,"sample fallback radius cutoff and16-unit spacing");
 light.origin[2]=-10;MTL_LightmapDynamicSamples(result,3,1,&geometry,1,&light,1);check(fabs(result[0]*255-90)<0.001,"dynamic fallback accepts either plane side");
 light.origin[0]=17;light.origin[1]=9;light.origin[2]=0;MTL_LightmapDynamicSamples(result,1,1,&geometry,1,&light,1);check(fabs(result[0]*255-79)<0.001,"dynamic fallback integer min-distance halving");
 MTL_LightmapDynamicSamples(result,1,1,&geometry,0,&light,1);check(result[0]==0,"unmarked dynamic light excluded");
 light.intensity=63;MTL_LightmapDynamicSamples(result,1,1,&geometry,1,&light,1);check(result[0]==0,"radius below64 excluded");
 byte single[4]={0,255,255,255};byte black_samples[9]={};geometry.steps[0]=16;
 auto lit_map=MTL_LightmapCreate(black_samples,sizeof(black_samples),3,1,single,&geometry);
 dlight_t frame_light={};frame_light.origin[2]=10;frame_light.color[0]=1;frame_light.intensity=100;
 auto dynamic=MTL_LightmapMakeDynamic(lit_map,1,&frame_light,1,true,false);__fp16 half[12];[dynamic getBytes:half bytesPerRow:24 fromRegion:MTLRegionMake2D(0,0,3,1) mipmapLevel:0];
 check(fabs((float)half[0]*255-90)<0.05 && fabs((float)half[4]*255-74)<0.05 && half[8]==0,"production fallback uploads float16 sample layer without byte clamp");
 auto frozen=MTL_LightmapMakeDynamic(lit_map,1,&frame_light,1,false,false);__fp16 empty[4];[frozen getBytes:empty bytesPerRow:8 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];check(empty[0]==0,"gl_dynamic0 production layer stays zero");
 auto per_pixel=MTL_LightmapMakeDynamic(lit_map,1,&frame_light,1,true,true);[per_pixel getBytes:empty bytesPerRow:8 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];check(empty[0]==0,"per-pixel path excludes CPU fallback to avoid double lighting");
 auto next_frame=MTL_LightmapMakeDynamic(lit_map,0,nullptr,0,true,false);[next_frame getBytes:empty bytesPerRow:8 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];check(empty[0]==0 && half[0]>0,"a later unlit draw does not mutate or retain prior dynamic layer");
 MTL_LightmapFree(lit_map);
 geometry.flags=8;MTL_LightmapDynamicSamples(result,1,1,&geometry,1,&light,1);check(result[0]==0,"warp surfaces excluded from sample fallback");geometry.flags=0;
 // Exact GPL CPU function is a second oracle for fractional plane/axis inputs.
 // Helpers below supply only upload storage; all falloff math is production GL3.
 int differences=0;unsigned seed=0x52616e64u;
 for(int trial=0;trial<128;trial++) {
  cplane_t plane={{0.6f,0.8f,0},100000};mtexinfo_t tex={};tex.vecs[0][0]=1;tex.vecs[1][1]=1;
  tex.vecs[0][3]=-83333;tex.vecs[1][3]=-62500;
  msurface_t surf={};surf.texinfo=&tex;surf.lmsize[0]=3;surf.lmsize[1]=2;surf.dlightframe=1;surf.dlightbits=1;surf.samples=black_samples;surf.plane=&plane;surf.lmstep[0]=surf.lmstep[1]=16;
  seed=seed*1664525u+1013904223u;frame_light.origin[0]=83333+(int)(seed&63)/16.0f;
  seed=seed*1664525u+1013904223u;frame_light.origin[1]=62500+(int)(seed&63)/16.0f;frame_light.origin[2]=0;frame_light.intensity=200;
  r_newrefdef.dlights=&frame_light;r_newrefdef.num_dlights=1;memset(oracle_dynamic,0,24*sizeof(float));GL3_DynLight_Face(&surf);
  mtl_lightmap_geometry_t g={};memcpy(g.normal,plane.normal,12);g.distance=plane.dist;memcpy(g.texvecs,tex.vecs,sizeof(g.texvecs));g.steps[0]=g.steps[1]=16;
  mtl_lightmap_light_t l={};memcpy(l.origin,frame_light.origin,12);memcpy(l.color,frame_light.color,12);l.intensity=frame_light.intensity;
  float actual[24];MTL_LightmapDynamicSamples(actual,3,2,&g,1,&l,1);
  for(int i=0;i<24;i++)if(fabs(actual[i]-oracle_dynamic[i])>0.000001f){differences++;break;}
 }
 check(differences==0,"sample fallback matches exact GPL function for128 fractional-plane fixtures",differences,0);
 geometry.steps[0]=0;check(!MTL_LightmapDynamicSamples(result,1,1,&geometry,1,&light,1),"invalid dynamic spacing rejected");
 // A changed table is a new immutable texture, preserving already encoded draws.
 byte a[256],b[256];for(int i=0;i<256;i++){a[i]=i;b[i]=255-i;}auto ta=MTL_LightmapColorTable(a);auto tb=MTL_LightmapColorTable(b);byte old[256],current[256];[ta getBytes:old bytesPerRow:256 fromRegion:MTLRegionMake2D(0,0,256,1) mipmapLevel:0];[tb getBytes:current bytesPerRow:256 fromRegion:MTLRegionMake2D(0,0,256,1) mipmapLevel:0];check(old[64]==64 && current[64]==191 && ta!=tb,"color-table updates preserve prior texture");
}
#endif
int main(){@autoreleasepool {
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 2;queue=[mtl_device newCommandQueue];mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
#ifdef OM_LIGHTMAP_BASELINE
 pipeline=MTL_BuildWorldPipeline();
#else
 NSError *error=nil;auto lib=[mtl_device newLibraryWithSource:[NSString stringWithFormat:@"%@\n%@",mtl_world_shader,mtl_lightmap_shader] options:nil error:&error];if(!lib)MTL_Fatal("new lightmap shader",error.localizedDescription.UTF8String);
 auto pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"mtl_vs_world_lightmaps"]?:[lib newFunctionWithName:@"mtl_vs_world"];pd.fragmentFunction=[lib newFunctionWithName:@"mtl_fs_world_lightmaps"];pd.colorAttachments[0].pixelFormat=mtl_layer.pixelFormat;pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;pipeline=[mtl_device newRenderPipelineStateWithDescriptor:pd error:&error];if(!pipeline)MTL_Fatal("new lightmap pipeline",error.localizedDescription.UTF8String);
#endif
 auto sm=[MTLSamplerDescriptor new];sm.minFilter=sm.magFilter=MTLSamplerMinMagFilterLinear;sm.sAddressMode=sm.tAddressMode=MTLSamplerAddressModeClampToEdge;linear=[mtl_device newSamplerStateWithDescriptor:sm];sm.minFilter=sm.magFilter=MTLSamplerMinMagFilterNearest;nearest=[mtl_device newSamplerStateWithDescriptor:sm];sm.sAddressMode=sm.tAddressMode=MTLSamplerAddressModeRepeat;diffuse_sampler=[mtl_device newSamplerStateWithDescriptor:sm];
 byte white[4]={255,255,255,255};mtl_white=rgba_texture(white,1,1);memset(&u,0,sizeof(u));for(int i=0;i<4;i++)u.mvp[i*5]=1;u.overbright=1;reset_styles();
 draw_case("one-style control",{64,32,16},1,1,1,0,64,32,16);
 draw_case("two independent style planes",{64,0,0,0,96,0},1,2,1,0,64,96,0);
 draw_case("all four style planes",{40,0,0,0,50,0,0,0,60,10,20,30},1,4,1,0,50,70,90);
 styles[0].rgb[0]=0.5;styles[0].rgb[1]=0.25;styles[0].rgb[2]=2;draw_case("live RGB style multiplier",{100,80,60},1,1,1,0,50,20,120);reset_styles();
 draw_case("latched modulate affects world",{64,32,16},1,1,2,0,128,64,32);
 draw_case("normalize after summing styles",{200,100,50,200,100,50},1,2,1,0,255,127,63);
 styles[0].rgb[0]=-1;draw_case("negative style sum clamps before lookup",{100,80,60},1,1,1,0,0,80,60);reset_styles();
 draw_case("interpolate separate planes before saturation",{250,0,0,0,0,0,250,0,0,0,0,0},2,2,1,0,250,0,0);
 draw_case("color lookup follows combined sum",{64,0,0,64,0,0},1,2,1,0,127,255,255,true,nullptr,false,true);
 for(int mode:{1,2})draw_case("luminance and intensity mono modes",{64,128,32},1,1,1,mode,128,128,128);
 draw_case("intensity alpha participates in cutoff",{8,0,0},1,1,1,2,0,0,255);
 draw_case("color-weighted alpha mono mode",{64,128,32},1,1,1,3,45,90,22);
 draw_case("alpha mono mode RGB black",{64,128,32},1,1,1,4,0,0,0);
 draw_case("alpha mono full light is discarded",{255,255,255},1,1,1,4,0,0,255);
 draw_case("other mono mode RGB black",{64,128,32},1,1,1,5,0,0,0);
 float dyn[3]={0.25f,0.5f,0};draw_case("float dynamic layer before rounding",{0,0,0},1,1,1,0,64,128,0,true,dyn);
 dyn[0]=100.0f/255;dyn[1]=0;draw_case("dynamic layer not multiplied by modulate",{10,0,0},1,1,2,0,120,0,0,true,dyn);
 styles[0].rgb[0]=0;styles[0].rgb[1]=3;styles[0].rgb[2]=0.5;draw_case("gl_dynamic0 freezes styles and omits dynamic layer",{20,40,60},1,1,2,0,40,80,120,false,dyn);reset_styles();
 draw_case("fullbright bypasses light styles and mono",{0,0,0},1,1,1,5,255,255,255,true,dyn,true);
 u.pdlight[0]=1;u.pdlight[1]=1;u.dlight_meta[0]=1;u.surface_normal[2]=1;u.dlight_origin_radius[0][3]=128;u.dlight_color[0][0]=1;draw_case("existing per-pixel light still adds after styles",{32,0,0},1,1,1,0,160,0,0);memset(u.pdlight,0,sizeof(u.pdlight));u.dlight_meta[0]=0;
 draw_case("next draw has no stale dynamic contribution",{20,40,60},1,1,1,0,20,40,60);
 draw_case("opaque flowing coordinates move diffuse sample",{255,255,255},1,1,1,0,0,255,0,true,nullptr,false,false,0.25f,0.5f,true);
 draw_case("opaque flow preserves independent lightmap coordinates",{0,255,0,0,128,0},2,1,1,0,0,192,0,true,nullptr,false,false,0.25f,0.5f,true);
#ifndef OM_LIGHTMAP_BASELINE
 resource_math_checks();MTL_LightmapsShutdown();
#else
 printf("Resource/math implementation absent in baseline; pixel tests above exercise actual old world shader.\n");
#endif
 printf("%d checks passed, %d failed\n",checks-failures,failures);return failures?1:0;
}}
