// SPDX-License-Identifier: GPL-2.0-or-later
// Actual image metadata loader and DrawSurface, observed as native GPU pixels.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "../../../../common/header/common.h"
#include "../../../../common/header/files.h"
#include "../../ref_shared.h"
#include "../mtl_post_math.h"
#include "../mtl_brush_math.h"
#include "../mtl_brush_polygons.h"
#define MTL_MAX_DLIGHTS 32
#define SKY_MAX_CLIP_VERTS 64
#define MTL_MAX_ALPHA_SURFACES 4096
#include "world_material_types.h"
refimport_t ri;
static id<MTLDevice> mtl_device;
static id<MTLCommandQueue> queue;
static CAMetalLayer *mtl_layer;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLTexture> mtl_white,mtl_lighttable;
static id<MTLRenderPipelineState> mtl_pipe_world;
static id<MTLDepthStencilState> mtl_depth_world;
static id<MTLSamplerState> mtl_samp_clamp,mtl_samp_world,mtl_samp_lm;
static mtl_model_t *mtl_worldmodel;
static mtl_model_t **mtl_models;
static int mtl_nummodels;
static mtl_surface_t *mtl_alpha_surfaces[MTL_MAX_ALPHA_SURFACES],*mtl_detail_surfaces[1024];
static int mtl_alpha_count,mtl_detail_count,mtl_pdlight_active_count;
static refdef_t mtl_refdef;
static cvar_t overbright_defaults[3]={{.value=0},{.value=2},{.value=1}};
static cvar_t *WorldCvarGet(const char *name,const char *value,int flags)
{(void)value;(void)flags;return &overbright_defaults[!strcmp(name,"r_om_overbright_scale")?1:!strcmp(name,"r_om_overbright_models")?2:0];}
#include "../mtl_overbright.h"
static cvar_t zero={0},one={.value=1};
static cvar_t *mtl_detail_cvar=&zero,*mtl_fullbright_cvar=&zero,*mtl_pdlight_cvar=&zero,*mtl_pdlight_scale_cvar=&one,*mtl_pdlight_normal_cvar=&zero,*mtl_pdlight_soft_cvar=&zero,*mtl_gl_dynamic_cvar=&one,*mtl_cull_cvar=&zero,*mtl_drawflat_cvar=&zero;
static float mtl_modulate_latched=1;
static int mtl_monolightmap_mode;
static float game_clock;
static float MTL_GameTime(void) {return game_clock;}
static mtl_post_emission_controls_t MTL_PostEmissionControls(void) {mtl_post_emission_controls_t c={0};return c;}
static id<MTLRenderPipelineState> MTL_BuildWorldPipeline(void) {return mtl_pipe_world;}
static int fog_order[8],fog_events;
static void MTL_FogMarkBoundaryPlane(mtl_surface_t *surface) {(void)surface;if(fog_events<8)fog_order[fog_events++]=1;}
static void MTL_FogQueueSurface(mtl_surface_t *surface) {(void)surface;if(fog_events<8)fog_order[fog_events++]=2;}
static void MTL_FogQueueChain(mtl_surface_t *surface) {(void)surface;}
static void MTL_AddSkySurface(mtl_surface_t *surface) {(void)surface;if(fog_events<8)fog_order[fog_events++]=3;}
static void MTL_DrawTurbSurface(void *model,...) {(void)model;}
static int MTL_DrawSoFLiquid(void *model,...) {(void)model;return 0;}
static void MTL_Fatal(const char *a,const char *b) {fprintf(stderr,"%s: %s\n",a,b);abort();}
void Com_Error(int level,const char *format,...) {(void)level;fprintf(stderr,"unexpected error: %s\n",format);abort();}
void Com_Printf(const char *format,...) {(void)format;}
int Q_stricmp(const char *a,const char *b) {return strcasecmp(a,b);}
int LittleLong(int value) {return value;}
int Q_strlcpy(char *dst,const char *src,int size) {return snprintf(dst,size,"%s",src);}
const char *COM_FileExtension(const char *name) {const char *dot=strrchr(name,'.');return dot?dot+1:"";}
void Com_sprintf(char *dst,int size,const char *format,...) {va_list a;va_start(a,format);vsnprintf(dst,size,format,a);va_end(a);}
static byte *MTL_ToRGBA(const byte *p,int w,int h,size_t pixels,int bits,qboolean *alpha)
{(void)w;(void)h;(void)bits;byte *out=malloc(pixels*4);memcpy(out,p,pixels*4);*alpha=false;for(size_t i=0;i<pixels;i++)if(p[i*4+3]!=255)*alpha=true;return out;}
static void MTL_SoF_CorrectColours(byte *p,size_t pixels,const char *name) {(void)p;(void)pixels;(void)name;}
static void *MTL_NewTextureChain(const byte *p,int w,int h,BOOL mip)
{(void)mip;MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;id<MTLTexture> t=[mtl_device newTextureWithDescriptor:d];[t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:p bytesPerRow:w*4];return (void *)CFBridgingRetain(t);}
static void *MTL_NewStoredTextureChain(const byte *p,int w,int h) {return MTL_NewTextureChain(p,w,h,NO);}
static struct image_s *MTL_FindImage(const char *name,imagetype_t type) {(void)name;(void)type;return NULL;}
static int file_flags;
static int LoadMetadata(const char *name,void **out)
{(void)name;byte *p=calloc(1,0x3c8);memcpy(p+0x2c4,&file_flags,4);*out=p;return 0x3c8;}
#include "../mtl_lightmap.h"
#include "world_material_shaders.h"
#include "../mtl_lightmap_shader.h"
#include "world_material_functions.h"
static int checks,failures;
static void render_check(const char *name,mtl_model_t *model,int expected_r,int expected_g,int expected_b)
{
 MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget;id<MTLTexture> target=[mtl_device newTextureWithDescriptor:d];
 d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:8 height:8 mipmapped:NO];d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;id<MTLTexture> depth=[mtl_device newTextureWithDescriptor:d];
 MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.clearDepth=1;
 id<MTLCommandBuffer> cb=[queue commandBuffer];mtl_enc=[cb renderCommandEncoderWithDescriptor:pass];[mtl_enc setRenderPipelineState:mtl_pipe_world];[mtl_enc setCullMode:MTLCullModeNone];[mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];[mtl_enc setFragmentSamplerState:mtl_samp_lm atIndex:1];
 float mvp[16]={0};for(int i=0;i<4;i++)mvp[i*5]=1;MTL_DrawSurface(model,0,mvp);[mtl_enc endEncoding];mtl_enc=nil;[cb commit];[cb waitUntilCompleted];if(cb.error)MTL_Fatal("actual world material",cb.error.localizedDescription.UTF8String);
 byte pixels[8*8*4];[target getBytes:pixels bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];byte *p=pixels+(4*8+4)*4;checks++;if(abs(p[2]-expected_r)>1 || abs(p[1]-expected_g)>1 || abs(p[0]-expected_b)>1){failures++;fprintf(stderr,"FAIL %s: RGB %d %d %d expected %d %d %d\n",name,p[2],p[1],p[0],expected_r,expected_g,expected_b);}
}
int main(void){@autoreleasepool {
 mtl_device=MTLCreateSystemDefaultDevice();queue=[mtl_device newCommandQueue];mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;ri.FS_LoadFile=LoadMetadata;ri.FS_FreeFile=free;ri.Cvar_Get=WorldCvarGet;MTL_OverbrightInit();
 byte white[4]={255,255,255,255};mtl_white=CFBridgingRelease(MTL_NewTextureChain(white,1,1,NO));byte table[256];for(int i=0;i<256;i++)table[i]=i;mtl_lighttable=MTL_LightmapColorTable(table);
 MTLSamplerDescriptor *sampler=[MTLSamplerDescriptor new];sampler.minFilter=sampler.magFilter=MTLSamplerMinMagFilterNearest;sampler.sAddressMode=sampler.tAddressMode=MTLSamplerAddressModeRepeat;mtl_samp_world=[mtl_device newSamplerStateWithDescriptor:sampler];sampler.sAddressMode=sampler.tAddressMode=MTLSamplerAddressModeClampToEdge;mtl_samp_lm=mtl_samp_clamp=[mtl_device newSamplerStateWithDescriptor:sampler];
 MTLDepthStencilDescriptor *ds=[MTLDepthStencilDescriptor new];ds.depthCompareFunction=MTLCompareFunctionLessEqual;ds.depthWriteEnabled=YES;mtl_depth_world=[mtl_device newDepthStencilStateWithDescriptor:ds];
 NSError *error=nil;id<MTLLibrary> library=[mtl_device newLibraryWithSource:[NSString stringWithFormat:@"%@\n%@",mtl_world_shader,mtl_lightmap_shader] options:nil error:&error];if(!library)MTL_Fatal("material MSL",error.localizedDescription.UTF8String);MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
#ifdef OM_WORLD_HAS_LIGHTMAPS
 pd.vertexFunction=[library newFunctionWithName:@"mtl_vs_world_lightmaps"];pd.fragmentFunction=[library newFunctionWithName:@"mtl_fs_world_lightmaps"];
#else
 pd.vertexFunction=[library newFunctionWithName:@"mtl_vs_world"];pd.fragmentFunction=[library newFunctionWithName:@"mtl_fs_world"];
#endif
 pd.colorAttachments[0].pixelFormat=mtl_layer.pixelFormat;pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;mtl_pipe_world=[mtl_device newRenderPipelineStateWithDescriptor:pd error:&error];if(!mtl_pipe_world)MTL_Fatal("material pipeline",error.localizedDescription.UTF8String);
 byte red[4]={255,0,0,255},green[4]={0,255,0,255},yellow[4]={255,255,0,255};file_flags=0;mtl_image_t *a=(mtl_image_t *)MTL_LoadPic("textures/a.m32",red,1,0,1,0,1,it_wall,32);mtl_image_t *b=(mtl_image_t *)MTL_LoadPic("textures/b.m32",green,1,0,1,0,1,it_wall,32);file_flags=0x800;mtl_image_t *c=(mtl_image_t *)MTL_LoadPic("textures/c.m32",yellow,1,0,1,0,1,it_wall,32);
 mtexinfo_t tex[2]={0};tex[0].image=(struct image_s *)a;tex[1].image=(struct image_s *)b;tex[0].next=&tex[1];tex[1].next=&tex[0];tex[0].numframes=tex[1].numframes=2;
 mtl_surface_t surface={0};surface.texinfo=&tex[0];surface.num_vertex=6;surface.samples=white;surface.normal[2]=1;surface.lm_w=surface.lm_h=1;surface.lightmap=(__bridge void *)mtl_white;
#ifdef OM_WORLD_HAS_LIGHTMAPS
 byte ids[4]={0,255,255,255};surface.lighting=MTL_LightmapCreate(white,3,1,1,ids,NULL);
#endif
 mtl_world_vertex_t vertices[6]={0};float xy[6][2]={{-1,-1},{-1,1},{1,1},{-1,-1},{1,1},{1,-1}};for(int i=0;i<6;i++){vertices[i].pos[0]=xy[i][0];vertices[i].pos[1]=xy[i][1];vertices[i].pos[2]=0.5;vertices[i].uv[0]=vertices[i].uv[1]=vertices[i].luv[0]=vertices[i].luv[1]=0.5;}
 id<MTLBuffer> vb=[mtl_device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared];mtl_model_t world={0};world.surfaces=&surface;world.numsurfaces=1;world.vbuf=(__bridge void *)vb;world.bspversion=BSPVERSION_SOF;world.owner=&world;mtl_worldmodel=&world;
 game_clock=0;render_check("opaque base frame control",&world,255,0,0);game_clock=0.75;render_check("opaque world selects animated image",&world,0,255,0);
 tex[0].next=NULL;tex[0].numframes=1;tex[0].image=(struct image_s *)c;render_check("declared alpha image without alpha texinfo is skipped in world",&world,0,0,255);
 mtl_model_t inline_model=world;inline_model.owner=&world;render_check("inline model keeps declared alpha image with opaque texinfo",&inline_model,255,255,0);
 tex[0].image=(struct image_s *)a;render_check("next material clears skipped-image state",&world,255,0,0);
#ifdef OM_FOG_CLASSIFICATION_TEST
 tex[0].flags=0x10000;fog_events=0;render_check("actual boundary face never draws textured geometry",&world,0,0,255);
 checks++;if(fog_events!=2||fog_order[0]!=1||fog_order[1]!=2){fprintf(stderr,"FAIL: actual boundary must mark plane then queue before classification\n");failures++;}
 tex[0].flags=0x10000|SURF_DRAWSKY;surface.skyring_n=3;fog_events=0;render_check("boundary classification precedes sky",&world,0,0,255);
 checks++;if(fog_events!=2||fog_order[0]!=1||fog_order[1]!=2){fprintf(stderr,"FAIL: actual boundary takes precedence over sky\n");failures++;}
 tex[0].flags=SURF_DRAWSKY;fog_events=0;render_check("ordinary sky remains clear",&world,0,0,255);
 checks++;if(fog_events!=2||fog_order[0]!=2||fog_order[1]!=3){fprintf(stderr,"FAIL: actual sky region queues before sky draw\n");failures++;}
 tex[0].flags=0;surface.skyring_n=0;
#endif
 byte flow_pixels[8]={255,0,0,255,0,255,0,255};file_flags=0;mtl_image_t *flow=(mtl_image_t *)MTL_LoadPic("textures/flow.m32",flow_pixels,2,0,1,0,2,it_wall,32);
 tex[0].image=(struct image_s *)flow;tex[0].flags=0x40;tex[0].value=200<<16;game_clock=0.125;render_check("actual opaque draw binds game-clock flow offset",&world,255,0,0);tex[0].flags=0;
#ifdef OM_WORLD_DETAIL_UPDATE
 mtl_image_t *owned[3]={a,b,a};world.owned_images=owned;world.num_owned_images=3;mtl_model_t *models[2]={&world,&inline_model};mtl_models=models;mtl_nummodels=2;a->detail_shift[0]=1;b->detail_shift[0]=2;
 MTL_UpdateDetailScroll(0.25f);checks++;if(fabsf(a->detail_scroll[0]-0.25f)>0.000001f || fabsf(b->detail_scroll[0]-0.5f)>0.000001f){failures++;fprintf(stderr,"FAIL: actual detail update accumulates each shared image once\n");}
 MTL_UpdateDetailScroll(0.5f);checks++;if(fabsf(a->detail_scroll[0]-0.75f)>0.000001f || fabsf(b->detail_scroll[0]-0.5f)>0.000001f){failures++;fprintf(stderr,"FAIL: actual detail update retains history and positive wrap\n");}
 MTL_UpdateDetailScroll(0);checks++;if(fabsf(a->detail_scroll[0]-0.75f)>0.000001f){failures++;fprintf(stderr,"FAIL: paused actual detail update changes phase\n");}
#else
 checks++;failures++;fprintf(stderr,"FAIL: actual accumulated detail-scroll update absent\n");
#endif
#ifdef OM_WORLD_HAS_LIGHTMAPS
 MTL_LightmapFree(surface.lighting);
#endif
 CFRelease(a->tex);CFRelease(b->tex);CFRelease(c->tex);CFRelease(flow->tex);free(a);free(b);free(c);free(flow);MTL_LightmapsShutdown();printf("%d checks passed, %d failed\n",checks-failures,failures);return failures?1:0;
}}
