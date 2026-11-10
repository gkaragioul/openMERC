// SPDX-License-Identifier: GPL-2.0-or-later
// Offscreen pixels through the production Ghoul shader/state selectors.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include "ghoul_host.h"
#include "../../../../common/header/sof/refapi.h"

#define MAX_QPATH 64
#define ERR_FATAL 1
#define Q_min(a,b) ((a)<(b)?(a):(b))
#define Q2_DLL_EXPORTED
#define LittleFloat(v) (v)
#define LittleLong(v) (v)
typedef unsigned char byte;
typedef bool qboolean;
typedef enum { it_pic } imagetype_t;
typedef struct mtl_image_s mtl_image_t;
static void Com_Printf(const char *,...) {}
static void Com_sprintf(char *out,size_t n,const char *format,...)
{
	va_list args; va_start(args,format); vsnprintf(out,n,format,args); va_end(args);
}
static void Q_strlcpy(char *out,const char *s,size_t n) { snprintf(out,n,"%s",s); }
static const char *COM_FileExtension(const char *s) { const char *p=strrchr(s,'.'); return p?p+1:""; }
static void *MTL_FindImage(const char *,imagetype_t) { return nullptr; }
static void Com_Error(int,const char *format,...) { fprintf(stderr,"unexpected HUD asset load: %s\n",format); abort(); }
static struct { int (*FS_LoadFile)(const char *,void **); void (*FS_FreeFile)(void *); } ri;

static id<MTLDevice> mtl_device;
static CAMetalLayer *mtl_layer;
static id<MTLRenderPipelineState> mtl_pipe_alias, mtl_pipe_alias_alpha, mtl_pipe_alias_additive;
static id<MTLRenderPipelineState> mtl_pipe_ghoul, mtl_pipe_fx_alpha, mtl_pipe_fx_additive;
static id<MTLSamplerState> mtl_ghoul_samp_clamp_mip, mtl_ghoul_samp_repeat_mip;
static id<MTLSamplerState> mtl_ghoul_samp_clamp_nomip, mtl_ghoul_samp_repeat_nomip;
static id<MTLSamplerState> mtl_ghoul_samplers[2][2][2];
static id<MTLRenderPipelineState> mtl_pipe2d,mtl_pipe_sof2d,mtl_pipe_sof2d_replace;
static id<MTLSamplerState> mtl_samp_ui,mtl_samp_ui_linear,mtl_samp_clamp,mtl_samp_repeat;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLDepthStencilState> mtl_depth_2d;
static id<MTLTexture> mtl_white;
static bool mtl_encoder_open;
static float mtl_ui_w=16,mtl_ui_h=16;
static mtl_image_t *draw_chars,*mtl_notexture;
static void MTL_Fatal(const char *where,const char *message)
{
	fprintf(stderr,"%s: %s\n",where,message?message:""); abort();
}
#include "material_production.h"
#include "mtl_sofhud.h"

static id<MTLCommandQueue> queue;
static int failures;
static void hud_check(int sequence,int expected)
{
	MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
	td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageRenderTarget;
	id<MTLTexture> target=[mtl_device newTextureWithDescriptor:td];
	td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];
	td.storageMode=MTLStorageModePrivate; td.usage=MTLTextureUsageRenderTarget;
	id<MTLTexture> depth=[mtl_device newTextureWithDescriptor:td];
	MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear;
	pass.colorAttachments[0].storeAction=MTLStoreActionStore;
	pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
	pass.depthAttachment.texture=depth; pass.depthAttachment.loadAction=MTLLoadActionClear;
	pass.depthAttachment.storeAction=MTLStoreActionDontCare; pass.depthAttachment.clearDepth=1;
	id<MTLCommandBuffer> cb=[queue commandBuffer];
	mtl_enc=[cb renderCommandEncoderWithDescriptor:pass]; mtl_encoder_open=true;
	MTL_SoF_HUDResetState();
	byte black[4]={0,0,0,255},gray[4]={127,127,127,127};
	char name[]="TEST",text[]="A",colourCode[]={9,'A',0};
	om_fontref_t font={}; font.chars="small";
	MTL_HUDFill(0,0,16,16,black);
	if(sequence==1) MTL_HUDDrawPic(0,0,name,0xff000000);
	if(sequence==2) MTL_HUDPicScaled(0,0,1,1,black,name);
	if(sequence==3) MTL_HUDFontString(0,0,text,0xff000000,&font,0);
	if(sequence==4) MTL_HUDPicPart(0,0,0,0,16,16,black,name);
	if(sequence==5) {
		MTL_HUDDrawPic(0,0,name,0xff000000);
		MTL_HUDCharFloat(8,0,100,gray,'A');
	}
	if(sequence==6) {
		MTL_HUDDrawPic(0,0,name,0xff000000);
		char missing[]="MISSING"; MTL_HUDPicScaled(0,0,1,1,black,missing);
	}
	if(sequence==7) {
		MTL_HUDDrawPic(0,0,name,0xff000000);
		MTL_HUDCharFloat(8,0,100,gray,' ');
	}
	MTL_HUDConsoleColor(0,0,colourCode,1,nullptr);
	[mtl_enc endEncoding]; mtl_encoder_open=false; mtl_enc=nil;
	[cb commit]; [cb waitUntilCompleted];
	if(cb.error) MTL_Fatal("offscreen HUD",cb.error.localizedDescription.UTF8String);
	byte pixels[16*16*4];
	[target getBytes:pixels bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];
	int red=pixels[(4*16+4)*4+2];
	if(abs(red-expected)>1) { fprintf(stderr,"FAIL HUD sequence %d: red %d, expected %d\n",sequence,red,expected); failures++; }
}
static void pixel_check(const char *name,const unsigned char *rgba,
	om_ghoul_native_draw_t draw,float u,float v,float vertexColour,float vertexAlpha,int expectedR,int expectedG,int expectedB,
	bool aliasControl=false)
{
	MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:2 mipmapped:YES];
	td.storageMode=MTLStorageModeShared;
	id<MTLTexture> texture=[mtl_device newTextureWithDescriptor:td];
	[texture replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:rgba bytesPerRow:8];
	unsigned char mip[4]={128,128,128,255};
	[texture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:1 withBytes:mip bytesPerRow:4];
	td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
	td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageRenderTarget;
	id<MTLTexture> target=[mtl_device newTextureWithDescriptor:td];
	td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];
	td.storageMode=MTLStorageModePrivate; td.usage=MTLTextureUsageRenderTarget;
	id<MTLTexture> depth=[mtl_device newTextureWithDescriptor:td];
	MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear;
	pass.colorAttachments[0].storeAction=MTLStoreActionStore;
	pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
	pass.depthAttachment.texture=depth; pass.depthAttachment.loadAction=MTLLoadActionClear;
	pass.depthAttachment.storeAction=MTLStoreActionDontCare; pass.depthAttachment.clearDepth=1;
	id<MTLCommandBuffer> cb=[queue commandBuffer];
	id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass];
	[enc setRenderPipelineState:aliasControl?mtl_pipe_alias:MTL_GhoulPipeline(&draw)];
	[enc setCullMode:MTLCullModeNone];
	mtl_alias_vertex_t vertices[6]={};
	const float xy[6][2]={{-1,1},{1,1},{1,-1},{-1,1},{1,-1},{-1,-1}};
	for(int i=0;i<6;i++) {
		vertices[i].pos[0]=xy[i][0]; vertices[i].pos[1]=xy[i][1]; vertices[i].pos[2]=0.5f;
		vertices[i].uv[0]=u; vertices[i].uv[1]=v;
		vertices[i].color[0]=vertices[i].color[1]=vertices[i].color[2]=vertexColour;
		vertices[i].color[3]=vertexAlpha;
	}
	float mvp[16]={}; for(int i=0;i<4;i++) mvp[5*i]=1;
	float cutoff=MTL_GhoulAlphaCutoff(&draw);
	[enc setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
	[enc setVertexBytes:mvp length:sizeof(mvp) atIndex:1];
	[enc setFragmentBytes:&cutoff length:sizeof(cutoff) atIndex:2];
	[enc setFragmentTexture:texture atIndex:0];
	[enc setFragmentSamplerState:MTL_GhoulSampler(draw.texture) atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	[enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
	if(cb.error) MTL_Fatal("offscreen GPU",cb.error.localizedDescription.UTF8String);
	unsigned char pixels[16*16*4];
	[target getBytes:pixels bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];
	const unsigned char *p=pixels+(8*16+8)*4;
	if(abs((int)p[2]-expectedR)>1 || abs((int)p[1]-expectedG)>1 || abs((int)p[0]-expectedB)>1) {
		fprintf(stderr,"FAIL %s: RGB %u %u %u, expected %d %d %d\n",name,p[2],p[1],p[0],expectedR,expectedG,expectedB); failures++;
	}
}
int main(void)
{
	@autoreleasepool {
		mtl_device=MTLCreateSystemDefaultDevice(); if(!mtl_device) return 77;
		queue=[mtl_device newCommandQueue]; mtl_layer=[CAMetalLayer layer];
		mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
		mtl_pipe_alias=MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_OPAQUE,0);
		mtl_pipe_alias_alpha=MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ALPHA,0);
		mtl_pipe_alias_additive=MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ADDITIVE,0);
		mtl_pipe_ghoul=MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_OPAQUE,2);
		mtl_pipe_fx_alpha=MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ALPHA,2);
		mtl_pipe_fx_additive=MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ADDITIVE,2);
		MTL_TestInitSamplers();
		mtl_pipe2d=MTL_BuildPipeline(NO,YES);
		mtl_pipe_sof2d=MTL_BuildPipeline(YES,YES);
		mtl_pipe_sof2d_replace=MTL_BuildPipeline(YES,NO);
		MTLDepthStencilDescriptor *depthState=[MTLDepthStencilDescriptor new];
		depthState.depthCompareFunction=MTLCompareFunctionAlways;
		mtl_depth_2d=[mtl_device newDepthStencilStateWithDescriptor:depthState];
		MTLTextureDescriptor *whiteDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
		whiteDesc.storageMode=MTLStorageModeShared;
		mtl_white=[mtl_device newTextureWithDescriptor:whiteDesc];
		const byte white[4]={255,255,255,255};
		[mtl_white replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:white bytesPerRow:4];
		mtl_image_t whiteImage={}; whiteImage.width=whiteImage.height=16;
		whiteImage.tex=(void *)CFBridgingRetain(mtl_white);
		draw_chars=mtl_notexture=&whiteImage;
		mtl_hud_numimages=1; strcpy(mtl_hud_images[0].name,"TEST"); mtl_hud_images[0].image=&whiteImage;
		mtl_hud_fonts[0].loaded=true; mtl_hud_fonts[0].count=224; mtl_hud_fonts[0].page=&whiteImage;
		mtl_hud_fonts[0].glyphs['A'-32]=(mtl_hud_glyph_t){{0,0,1,1},8,8,8};
		for(int sequence=0;sequence<8;sequence++) hud_check(sequence,(sequence==1||sequence==3||sequence==6)?63:127);
		om_ghoul_native_texture_t texture={}; om_ghoul_native_draw_t draw={}; draw.texture=&texture;
		const unsigned char checker[16]={255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255};
		for(int nomip=0;nomip<2;nomip++) {
			texture.nomip=nomip;
			for(int u=0;u<2;u++) for(int v=0;v<2;v++) {
				texture.repeat_u=u; texture.repeat_v=v;
				char name[64]; snprintf(name,sizeof(name),"wrap u=%d v=%d nomip=%d",u,v,nomip);
				int r=(!u&&!v)||(u&&v)?255:0, g=!u?255:0, b=!v?255:0;
				pixel_check(name,checker,draw,1.25f,1.25f,1,1,r,g,b);
			}
		}
		unsigned char solid[16];
		for(int i=0;i<4;i++) { solid[4*i]=200; solid[4*i+1]=100; solid[4*i+2]=50; solid[4*i+3]=0; }
		draw.alpha_test=0;
		pixel_check("opaque material ignores texture alpha",solid,draw,.25f,.25f,1,1,200,100,50);
		pixel_check("generic alias cutout remains",solid,draw,.25f,.25f,1,1,0,0,0,true);
		draw.blend=OM_GHOUL_NATIVE_BLEND_ADDITIVE;
		pixel_check("specular RGB survives zero map alpha",solid,draw,.25f,.25f,.5f,1,100,50,25);
		for(int i=0;i<4;i++) { solid[4*i]=solid[4*i+1]=solid[4*i+2]=255; solid[4*i+3]=5; }
		draw.blend=OM_GHOUL_NATIVE_BLEND_ALPHA; draw.alpha_test=1;
		pixel_check("blended alpha >0 retains low-alpha edge",solid,draw,.25f,.25f,1,1,5,5,5);
		for(int i=0;i<4;i++) solid[4*i+3]=255;
		draw.blend=OM_GHOUL_NATIVE_BLEND_ADDITIVE;
		pixel_check("alpha test uses modulated output",solid,draw,.25f,.25f,1,0,0,0,0);
		if(failures) return 1;
		puts("PASS: production Ghoul wrap/alpha and HUD blend-inheritance GPU pixels; generic alias control retained");
	}
	return 0;
}
