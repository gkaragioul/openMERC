// SPDX-License-Identifier: GPL-2.0-or-later
// Generic MD2/SP2 coverage, alpha and depth through actual production draws.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include <vector>
#include <map>
#include <string>
#include "ghoul_host.h"

typedef unsigned char byte;
typedef bool qboolean;
typedef float vec3_t[3];
#define MAX_SKINNAME 64
#define MAX_MD2SKINS 32
#define MAX_VERTS 2048
#define MTL_SHADEDOT_QUANT 16
#define MTL_MAX_ALIAS_VERTS (MAX_VERTS * 4)
#define MTL_MAX_ALIAS_IDX (MTL_MAX_ALIAS_VERTS * 3)
#define RF_TRANSLUCENT 0x20
#define Q_min(a,b) ((a)<(b)?(a):(b))
#define DEG2RAD(x) ((x)*0.01745329251994329577f)
#define VectorSubtract(a,b,c) do {for(int vi=0;vi<3;vi++) (c)[vi]=(a)[vi]-(b)[vi];} while(0)
#define VectorAdd(a,b,c) do {for(int vi=0;vi<3;vi++) (c)[vi]=(a)[vi]+(b)[vi];} while(0)
#define DotProduct(a,b) ((a)[0]*(b)[0]+(a)[1]*(b)[1]+(a)[2]*(b)[2])
#include "generic_formats.h"
struct mtl_image_s {void *tex;};
typedef struct mtl_image_s mtl_image_t;
struct mtl_model_t {void *aliashdr;size_t aliashdr_bytes;mtl_image_t *skins[MAX_MD2SKINS];};
struct entity_t {
 void *model,*skin;float origin[3],oldorigin[3],angles[3];int frame,oldframe,skinnum,flags;
 float backlerp,alpha;
};
static id<MTLDevice> mtl_device;
static id<MTLCommandQueue> queue;
static CAMetalLayer *mtl_layer;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLRenderPipelineState> mtl_pipe_alias,mtl_pipe_alias_alpha;
static id<MTLDepthStencilState> mtl_depth_world,mtl_depth_readonly;
static id<MTLSamplerState> mtl_samp_clamp;
static id<MTLTexture> mtl_white;
static mtl_image_t *mtl_notexture;
static bool mtl_encoder_open;
static struct {float viewangles[3];int rdflags;} mtl_refdef;
#define RDF_IRGOGGLES 4
#define CVAR_ARCHIVE 1
typedef struct {float value;int flags;} cvar_t;
static std::map<std::string,cvar_t> model_cvars;
static cvar_t *ModelCvar(const char *name,const char *value,int flags)
{return &model_cvars.emplace(name,cvar_t{(float)atof(value),flags}).first->second;}
static struct {cvar_t *(*Cvar_Get)(const char*,const char*,int);} ri={ModelCvar};
#include "../mtl_overbright.h"
static float mtl_avertexnormal_dots[MTL_SHADEDOT_QUANT][256];
static float light_colour=1;
static void Com_Printf(const char *format,...)
{ va_list a;va_start(a,format);vfprintf(stderr,format,a);va_end(a); }
static void MTL_Fatal(const char *where,const char *why)
{fprintf(stderr,"FATAL %s: %s\n",where,why?why:"");abort();}
static void identity(float *m)
{memset(m,0,64);for(int i=0;i<4;i++)m[i*5]=1;}
static void MTL_EntityMatrix(const float *,const float *,float *m) {identity(m);}
static void MTL_AliasEntityMVP(entity_t *,const float *m,const float *,float *out) {memcpy(out,m,64);}
static void MTL_Mul4(const float *a,const float *b,float *out)
{for(int c=0;c<4;c++)for(int r=0;r<4;r++){out[c*4+r]=0;for(int k=0;k<4;k++)out[c*4+r]+=a[k*4+r]*b[c*4+k];}}
static void MTL_AliasShadeLight(entity_t *,float *out) {for(int i=0;i<3;i++)out[i]=light_colour;}
#include "generic_shared.h"
static mtl_alias_vertex_t mtl_alias_vtx[MTL_MAX_ALIAS_VERTS];
static unsigned short mtl_alias_idx[MTL_MAX_ALIAS_IDX];
static float mtl_lerped[MAX_VERTS][4];
#include "generic_models_production.h"

static int checks,failures;
static void check(bool ok,const char *name,int got=-1,int expected=-1)
{checks++;if(!ok){failures++;fprintf(stderr,"FAIL %s (got %d expected %d)\n",name,got,expected);}}
static id<MTLTexture> texture(const byte *rgba,int width=1,int height=1)
{
 auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
 auto t=[mtl_device newTextureWithDescriptor:d];
 [t replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0 withBytes:rgba bytesPerRow:width*4];return t;
}
static float sprite_mvp[16],alias_mvp[16],view[16];
static dsprite_t sprite={};
static mtl_model_t sprite_model={};
static std::vector<byte> md2_data;
static mtl_model_t alias_model={};
static entity_t sprite_entity={},alias_entity={};
static mtl_image_t skin;
static void set_skin(id<MTLTexture> t)
{skin.tex=(__bridge void *)t;sprite_model.skins[0]=alias_model.skins[0]=&skin;}
static id<MTLTexture> target,depth;
static id<MTLCommandBuffer> cb;
static void begin()
{
 auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget;target=[mtl_device newTextureWithDescriptor:d];
 d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:32 height:32 mipmapped:NO];
 d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;depth=[mtl_device newTextureWithDescriptor:d];
 auto p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=target;
 p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;
 p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
 p.depthAttachment.texture=depth;p.depthAttachment.loadAction=MTLLoadActionClear;p.depthAttachment.storeAction=MTLStoreActionStore;p.depthAttachment.clearDepth=1;
 cb=[queue commandBuffer];mtl_enc=[cb renderCommandEncoderWithDescriptor:p];mtl_encoder_open=true;
 [mtl_enc setViewport:(MTLViewport){0,0,32,32,0,1}];
}
static std::vector<byte> finish()
{
 [mtl_enc endEncoding];mtl_enc=nil;mtl_encoder_open=false;[cb commit];[cb waitUntilCompleted];
 if(cb.error)MTL_Fatal("generic models",cb.error.localizedDescription.UTF8String);
 std::vector<byte> p(32*32*4);[target getBytes:p.data() bytesPerRow:128 fromRegion:MTLRegionMake2D(0,0,32,32) mipmapLevel:0];return p;
}
static void pixel(const std::vector<byte> &p,int x,int y,int r,int g,int b,const char *name)
{
 const byte *q=&p[(y*32+x)*4];check(abs(q[2]-r)<=1 && abs(q[1]-g)<=1 && abs(q[0]-b)<=1,name,q[2],r);
}
static void draw_marker(float z,const byte rgba[4])
{
 // A subsequent actual opaque SP2 draw verifies pipeline/depth/cutoff reset.
 entity_t e=sprite_entity;e.flags=0;e.alpha=1;
 auto t=texture(rgba);set_skin(t);float m[16];memcpy(m,sprite_mvp,64);m[14]=z;
 MTL_DrawSpriteModel(&e,&sprite_model,m);
}
static void fixture_models()
{
 identity(view);identity(alias_mvp);identity(sprite_mvp);
 sprite_mvp[0]=0;sprite_mvp[4]=-1;sprite_mvp[5]=0;sprite_mvp[9]=1;sprite_mvp[10]=0;sprite_mvp[14]=0.25f;
 sprite.numframes=1;sprite.frames[0].width=2;sprite.frames[0].height=2;sprite.frames[0].origin_x=1;sprite.frames[0].origin_y=1;
 sprite_model.aliashdr=&sprite;sprite_entity.model=&sprite_model;sprite_entity.alpha=1;
 // Four corners, one fan, one frame. Coordinates fill the central 80%.
 size_t frame_bytes=offsetof(daliasframe_t,verts)+4*sizeof(dtrivertx_t);
 md2_data.resize(sizeof(dmdl_t)+16+24+frame_bytes+14*sizeof(int));auto h=(dmdl_t *)md2_data.data();
 h->ident=0x32504449;h->version=8;h->skinwidth=h->skinheight=2;
 h->num_st=4;h->num_tris=2;h->num_glcmds=14;h->ofs_skins=sizeof(dmdl_t);h->ofs_st=sizeof(dmdl_t);h->ofs_tris=sizeof(dmdl_t)+16;
 h->num_frames=1;h->num_xyz=4;h->framesize=(int)frame_bytes;h->ofs_frames=sizeof(dmdl_t)+16+24;h->ofs_glcmds=(int)(h->ofs_frames+frame_bytes);h->ofs_end=(int)md2_data.size();
 auto f=(daliasframe_t *)(md2_data.data()+h->ofs_frames);f->scale[0]=f->scale[1]=1.6f;f->scale[2]=0;
 f->translate[0]=f->translate[1]=-0.8f;f->translate[2]=0.25f;
 const byte corners[4][2]={{0,0},{0,1},{1,1},{1,0}};
 for(int i=0;i<4;i++){f->verts[i].v[0]=corners[i][0];f->verts[i].v[1]=corners[i][1];}
 int *cmd=(int *)(md2_data.data()+h->ofs_glcmds);*cmd++=-4;
 const float uv[4][2]={{0,1},{0,0},{1,0},{1,1}};
 for(int i=0;i<4;i++){memcpy(cmd,uv[i],8);cmd+=2;*cmd++=i;}*cmd=0;
 alias_model.aliashdr=md2_data.data();alias_model.aliashdr_bytes=md2_data.size();alias_entity.model=&alias_model;alias_entity.alpha=1;
 for(auto &row:mtl_avertexnormal_dots)for(float &x:row)x=1;
}

static void large_md2_fixture(int triangles=2731)
{
 // 2731 separate valid triangles, 3 unique vertices: 8193 expanded vertices.
 // This is below format MAX_TRIANGLES4096 and MAX_VERTS2048.
 const int words=triangles*10+1;
 const size_t framebytes=offsetof(daliasframe_t,verts)+3*sizeof(dtrivertx_t);
 md2_data.assign(sizeof(dmdl_t)+12+triangles*12+framebytes+words*4,0);
 auto h=(dmdl_t *)md2_data.data();h->ident=0x32504449;h->version=8;h->skinwidth=h->skinheight=2;
 h->num_xyz=h->num_st=3;h->num_tris=triangles;h->num_glcmds=words;h->num_frames=1;h->framesize=(int)framebytes;
 h->ofs_skins=h->ofs_st=sizeof(dmdl_t);h->ofs_tris=h->ofs_st+12;h->ofs_frames=h->ofs_tris+triangles*12;
 h->ofs_glcmds=h->ofs_frames+(int)framebytes;h->ofs_end=(int)md2_data.size();
 auto f=(daliasframe_t *)(md2_data.data()+h->ofs_frames);f->scale[0]=f->scale[1]=1.6f;
 f->translate[0]=f->translate[1]=-.8f;f->translate[2]=.25f;
 const byte corners[3][2]={{0,0},{0,1},{1,1}};
 for(int i=0;i<3;i++){f->verts[i].v[0]=corners[i][0];f->verts[i].v[1]=corners[i][1];}
 int *command=(int *)(md2_data.data()+h->ofs_glcmds);
 for(int t=0;t<triangles;t++){
  *command++=3;
  for(int i=0;i<3;i++){float st[2]={.5f,.5f};memcpy(command,st,8);command+=2;*command++=i;}
 }
 *command=0;alias_model.aliashdr=md2_data.data();alias_model.aliashdr_bytes=md2_data.size();
}

static void invalid_md2_fixture(int which,id<MTLTexture> redtex)
{
 fixture_models();auto h=(dmdl_t *)md2_data.data();
 auto frame=(daliasframe_t *)(md2_data.data()+h->ofs_frames);
 auto cmd=(int *)(md2_data.data()+h->ofs_glcmds);
 switch(which){
 case 1:cmd[h->num_glcmds-1]=3;break; // no bounded terminator
 case 2:cmd[3]=h->num_xyz;break; // invalid vertex index
 case 3:cmd[0]=INT32_MIN;break; // negation overflow
 case 4:cmd[0]=INT32_MAX;break; // command exceeds available words
 case 5:h->ofs_glcmds=h->ofs_end+4;break;
 case 6:h->framesize=offsetof(daliasframe_t,verts)-1;break;
 case 7:h->ofs_frames=-4;break;
 case 8:h->num_xyz=MAX_VERTS+1;break;
 case 9:h->ofs_end++;break;
 case 10:alias_model.aliashdr_bytes=sizeof(dmdl_t)-1;break;
 case 11:h->num_frames=INT32_MAX;break;
 case 12:h->num_glcmds=INT32_MAX;break;
 case 13:{float nan=NAN;memcpy(cmd+1,&nan,4);break;}
 case 14:frame->scale[0]=NAN;break;
 case 15:h->num_xyz=0;break;
 case 16:cmd[0]=2;break;
 case 17:h->ofs_st=h->ofs_end;break;
 case 18:h->ofs_tris=h->ofs_end;break;
 case 19:h->ident=0;break;
 case 20:h->version=7;break;
 case 21:h->ofs_frames++;break;
 case 22:h->ofs_glcmds++;break;
 case 23:h->num_skins=-1;break;
 case 24:h->num_skins=MAX_MD2SKINS+1;break;
 case 25:h->num_tris=INT32_MAX;break;
 case 26:cmd[3]=-1;break;
 }
 alias_entity.flags=0;alias_entity.frame=alias_entity.oldframe=0;set_skin(redtex);begin();
 MTL_DrawAliasModel(&alias_entity,alias_mvp,view);auto p=finish();
 char name[96];snprintf(name,sizeof(name),"MD2 rejects bounded invalid fixture %d without drawing",which);
 pixel(p,10,10,0,0,255,name);
}
int main()
{
 MTL_OverbrightInit();
 @autoreleasepool {
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device){fprintf(stderr,"No native Metal device\n");return 2;}
 queue=[mtl_device newCommandQueue];mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
 mtl_pipe_alias=MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_OPAQUE,0);mtl_pipe_alias_alpha=MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ALPHA,0);
 auto ds=[MTLDepthStencilDescriptor new];ds.depthCompareFunction=MTLCompareFunctionLessEqual;ds.depthWriteEnabled=YES;mtl_depth_world=[mtl_device newDepthStencilStateWithDescriptor:ds];
 ds.depthWriteEnabled=NO;mtl_depth_readonly=[mtl_device newDepthStencilStateWithDescriptor:ds];
 auto sm=[MTLSamplerDescriptor new];sm.minFilter=sm.magFilter=MTLSamplerMinMagFilterNearest;sm.sAddressMode=sm.tAddressMode=MTLSamplerAddressModeClampToEdge;mtl_samp_clamp=[mtl_device newSamplerStateWithDescriptor:sm];
 const byte white[4]={255,255,255,255},red[4]={255,0,0,255},green[4]={0,255,0,255};mtl_white=texture(white);
 fixture_models();
 const byte invalid_red[4]={255,0,0,255};auto invalid_tex=texture(invalid_red);
 if(const char *only=getenv("OM_MD2_INVALID")){
  invalid_md2_fixture(atoi(only),invalid_tex);return failures?1:0;
 }
 const byte quadrants[16]={255,0,0,255,0,255,0,255,255,255,0,255,255,255,255,255};auto quad=texture(quadrants,2,2);
 set_skin(quad);begin();MTL_DrawSpriteModel(&sprite_entity,&sprite_model,sprite_mvp);auto p=finish();
 pixel(p,7,7,255,0,0,"SP2 upper left coverage");pixel(p,24,7,0,255,0,"SP2 upper right coverage");pixel(p,7,24,255,255,0,"SP2 lower left coverage");pixel(p,24,24,255,255,255,"SP2 lower right coverage");
 for(int a:{10,128,169,170,255}){byte rgba[4]={255,0,0,(byte)a};auto t=texture(rgba);set_skin(t);begin();MTL_DrawSpriteModel(&sprite_entity,&sprite_model,sprite_mvp);p=finish();
  pixel(p,10,10,a<=169?0:255,0,a<=169?255:0,"SP2 opaque cutoff at .666");}
 sprite_entity.flags=RF_TRANSLUCENT;sprite_entity.alpha=0.5f;
 for(int a:{10,128,255}){byte rgba[4]={255,0,0,(byte)a};auto t=texture(rgba);set_skin(t);begin();MTL_DrawSpriteModel(&sprite_entity,&sprite_model,sprite_mvp);p=finish();
  int r=(int)round(a*0.5);pixel(p,10,10,r,0,255-r,"SP2 source-over without alpha discard");}
 sprite_entity.alpha=3;byte faint[4]={255,0,0,10};auto fainttex=texture(faint);set_skin(fainttex);begin();MTL_DrawSpriteModel(&sprite_entity,&sprite_model,sprite_mvp);p=finish();pixel(p,10,10,30,0,225,"SP2 alpha does not inherit MD2 clamp");sprite_entity.alpha=0.5f;
 // A full quad must receive alpha once, including points inside the old overlap.
 auto redtex=texture(red);set_skin(redtex);begin();MTL_DrawSpriteModel(&sprite_entity,&sprite_model,sprite_mvp);p=finish();
 pixel(p,24,7,128,0,127,"SP2 translucent overlap is drawn once");pixel(p,24,24,128,0,127,"SP2 translucent lower right coverage");
 for(int flag:{0,RF_TRANSLUCENT}){sprite_entity.flags=flag;sprite_entity.alpha=1;set_skin(redtex);begin();MTL_DrawSpriteModel(&sprite_entity,&sprite_model,sprite_mvp);draw_marker(0.5f,green);p=finish();
  pixel(p,10,10,flag?0:255,flag?255:0,0,"SP2 depth writes follow flag even at alpha one");}
 sprite_entity.flags=RF_TRANSLUCENT;sprite_entity.alpha=1;byte halfalpha[4]={255,0,0,128};auto half=texture(halfalpha);set_skin(half);begin();MTL_DrawSpriteModel(&sprite_entity,&sprite_model,sprite_mvp);p=finish();pixel(p,10,10,0,0,255,"SP2 effective alpha one keeps opaque cutoff despite translucent flag");
 sprite_entity.flags=0;sprite_entity.alpha=1;
 for(float a:{0.5f,1.0f}){alias_entity.flags=RF_TRANSLUCENT;alias_entity.alpha=a;set_skin(redtex);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);p=finish();int r=(int)round(255*a*0.666f);
  pixel(p,10,10,r,0,255-r,"MD2 translucent source-over alpha times .666");}
 alias_entity.flags=0;alias_entity.alpha=1;set_skin(redtex);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);p=finish();pixel(p,10,10,255,0,0,"MD2 opaque control");
 alias_entity.flags=RF_TRANSLUCENT;alias_entity.alpha=3;set_skin(half);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);p=finish();pixel(p,10,10,192,0,63,"MD2 vertex alpha retains GL3 1.5 clamp before skin alpha");
 alias_entity.flags=RF_TRANSLUCENT;alias_entity.alpha=1;set_skin(redtex);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);draw_marker(0.5f,green);p=finish();pixel(p,10,10,0,255,0,"MD2 translucent does not occlude later opaque geometry");
 alias_entity.flags=0;byte lowalpha[4]={255,0,0,10};auto low=texture(lowalpha);set_skin(low);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);p=finish();pixel(p,10,10,255,0,0,"MD2 opaque has no unsupported alpha discard");
 byte gray[4]={128,0,0,255};auto graytex=texture(gray);light_colour=2;set_skin(graytex);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);p=finish();pixel(p,10,10,192,0,0,"MD2 lighting retains 1.5 clamp");light_colour=1;
 // Subsequent opaque model must reset alpha blend/cutoff/depth state.
 alias_entity.flags=RF_TRANSLUCENT;alias_entity.alpha=0.5f;set_skin(redtex);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);draw_marker(0.1f,green);p=finish();pixel(p,10,10,0,255,0,"MD2-to-SP2 state restoration");
 large_md2_fixture();alias_entity.flags=0;alias_entity.alpha=1;alias_entity.frame=alias_entity.oldframe=0;
 set_skin(redtex);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);p=finish();
 pixel(p,10,10,255,0,0,"valid MD2 preserves all 8193 expanded command vertices");
 large_md2_fixture(4096);set_skin(redtex);begin();MTL_DrawAliasModel(&alias_entity,alias_mvp,view);p=finish();
 pixel(p,10,10,255,0,0,"valid format-maximum triangle list preserves 12288 expanded vertices");
 for(int i=1;i<=26;i++)invalid_md2_fixture(i,redtex);
#if OM_MD2_BUDGET_TEST_API
 check(!MTL_MD2Span((int)sizeof(dmdl_t),INT32_MAX,SIZE_MAX,SIZE_MAX),"byte span division rejects overflowing count-times-stride");
 check(!MTL_MD2Span(INT32_MAX,INT32_MAX,4,INT32_MAX),"positive header count cannot overrun allocation end");
#endif
 printf("%d checks passed, %d failed\n",checks-failures,failures);return failures?1:0;
}}
