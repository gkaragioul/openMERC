// SPDX-License-Identifier: GPL-2.0-or-later
// Missing clip, square-cap, bevel or mutable-image state must change real GPU pixels.
// The asset loader is the only test double: no game data or window is needed.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdarg>
#include <dlfcn.h>
#include "../../../../common/header/sof/refapi.h"
#define MAX_QPATH 64
#define ERR_FATAL 1
#define Q_min(a,b) ((a)<(b)?(a):(b))
#define Q2_DLL_EXPORTED extern "C"
#define LittleFloat(v) (v)
#define LittleLong(v) (v)
typedef unsigned char byte;
typedef bool qboolean;
typedef enum { it_pic } imagetype_t;
typedef struct mtl_image_s mtl_image_t;
static void Com_Printf(const char *,...) {}
static void Com_sprintf(char *out,size_t n,const char *format,...)
{ va_list args; va_start(args,format); vsnprintf(out,n,format,args); va_end(args); }
static void Q_strlcpy(char *out,const char *s,size_t n) { snprintf(out,n,"%s",s); }
static const char *COM_FileExtension(const char *s) { const char *p=strrchr(s,'.'); return p?p+1:""; }
static void *MTL_FindImage(const char *,imagetype_t);
static void Com_Error(int,const char *,...) { abort(); }
static struct { int (*FS_LoadFile)(const char *,void **); void (*FS_FreeFile)(void *); } ri;
static id<MTLDevice> mtl_device;
static CAMetalLayer *mtl_layer;
static id<MTLRenderPipelineState> mtl_pipe2d,mtl_pipe_sof2d,mtl_pipe_sof2d_replace;
static id<MTLSamplerState> mtl_samp_ui,mtl_samp_ui_linear,mtl_samp_clamp,mtl_samp_repeat;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLDepthStencilState> mtl_depth_2d;
static id<MTLTexture> mtl_white;
static bool mtl_encoder_open;
static float mtl_ui_w=32,mtl_ui_h=32;
static mtl_image_t *draw_chars,*mtl_notexture;
static void MTL_Fatal(const char *where,const char *message)
{ fprintf(stderr,"%s: %s\n",where,message?message:""); abort(); }
#include "menu_production.h"
#include "mtl_sofhud.h"

static id<MTLCommandQueue> queue;
static id<MTLCommandBuffer> cb;
static id<MTLTexture> target,depth;
static sofrefexport_t api;
static OM_SetAlphaImage_t upload_alpha;
static int failures,checks;
static int diskloads;
static byte diskcolour[4]={255,0,0,255};
static byte pixels[32*32*4];
static const byte white[4]={255,255,255,255}, red[4]={255,0,0,255};
static void check(bool passed,const char *label)
{ checks++; if(!passed) { fprintf(stderr,"FAIL: %s\n",label); failures++; } }
static void pixel(int x,int y,int r,int g,int b,const char *label)
{
    const byte *p=pixels+(y*32+x)*4;
    bool ok=abs((int)p[2]-r)<=1 && abs((int)p[1]-g)<=1 && abs((int)p[0]-b)<=1;
    if(!ok) fprintf(stderr,"  %s at %d,%d: RGB %u,%u,%u expected %d,%d,%d\n",label,x,y,p[2],p[1],p[0],r,g,b);
    check(ok,label);
}
static void begin(bool reset=true)
{
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
    pass.depthAttachment.texture=depth; pass.depthAttachment.loadAction=MTLLoadActionClear;
    pass.depthAttachment.storeAction=MTLStoreActionDontCare; pass.depthAttachment.clearDepth=1;
    cb=[queue commandBuffer]; mtl_enc=[cb renderCommandEncoderWithDescriptor:pass]; mtl_encoder_open=true;
    MTL_SoF_HUDResetState();
#ifdef MTL_HUD_MENU_FOUNDATION
    MTL_HUDApplyClip(32,32);
    if(reset) { MTL_HUDSetScissorBroken(0); api.ResetClipRect(); }
#endif
    OM_Set2DScale(1);
}
static void end(void)
{
    [mtl_enc endEncoding]; mtl_encoder_open=false; mtl_enc=nil;
    [cb commit]; [cb waitUntilCompleted];
    if(cb.error) MTL_Fatal("menu GPU",cb.error.localizedDescription.UTF8String);
    [target getBytes:pixels bytesPerRow:128 fromRegion:MTLRegionMake2D(0,0,32,32) mipmapLevel:0];
}
static void fill(void) { api.DrawFill(0,0,32,32,white); }
static void clips(void)
{
    bool ready=api.SetClipRect && api.ResetClipRect && api.ClipRightTo && api.ClipLeftFrom && api.ReapplyClipRect;
    check(ready,"five operational clip exports"); if(!ready) return;
    begin(); api.SetClipRect(3,5,7,9); fill(); end();
    pixel(3,5,255,255,255,"clip top-left is included"); pixel(9,13,255,255,255,"clip lower-right interior");
    pixel(2,5,0,0,0,"clip left exterior"); pixel(3,4,0,0,0,"top-left orientation excludes upper row");
    pixel(10,8,0,0,0,"clip right edge excluded"); pixel(6,14,0,0,0,"clip bottom edge excluded");
    begin(); api.SetClipRect(3,5,7,9); api.ClipRightTo(6); fill(); end();
    pixel(5,7,255,255,255,"right crop interior"); pixel(6,7,0,0,0,"right crop edge");
    begin(); api.SetClipRect(3,5,7,9); api.ClipLeftFrom(6); fill(); end();
    pixel(5,7,0,0,0,"left crop exterior"); pixel(6,7,255,255,255,"left crop interior");
    begin(); api.SetClipRect(3,5,7,9); api.ClipRightTo(6); api.ReapplyClipRect(); fill(); end();
    pixel(9,7,255,255,255,"reapply restores remembered right edge");
    begin(); api.SetClipRect(3,5,7,9); api.ClipLeftFrom(2); api.SetClipRect(0,0,-1,4); fill(); end();
    pixel(3,5,255,255,255,"invalid clip calls retain old rectangle"); pixel(2,5,0,0,0,"invalid clip retains left edge");
    begin(); api.ClipRightTo(4); api.ClipLeftFrom(2); api.ReapplyClipRect(); fill(); end();
    pixel(24,24,255,255,255,"crop/reapply never enable disabled clipping");
    begin(); api.SetClipRect(-5,-3,9,7); fill(); end();
    pixel(0,0,255,255,255,"negative origin clamps safely"); pixel(3,3,255,255,255,"clamped extent"); pixel(4,3,0,0,0,"clamped right extent");
    begin(); api.SetClipRect(40,2,3,5); fill(); end(); pixel(31,3,0,0,0,"offscreen rectangle clips everything");
    begin(); api.SetClipRect(5,5,0,4); fill(); end(); pixel(5,5,0,0,0,"zero width clips everything");
    begin(); api.SetClipRect(3,5,7,9); api.ResetClipRect(); fill(); end();
    pixel(0,0,255,255,255,"reset disables enabled clip"); pixel(24,24,255,255,255,"reset restores full window");
    begin(); OM_Set2DScale(1.5f); api.SetClipRect(1,2,3,3); fill(); end();
    pixel(2,3,255,255,255,"fractional left rounded once"); pixel(5,7,255,255,255,"fractional endpoint rounded");
    pixel(1,3,0,0,0,"fractional left exterior"); pixel(6,4,0,0,0,"fractional right exterior");
    begin(); OM_Set2DScale(2); api.SetClipRect(2,3,4,4); OM_Set2DScale(1); fill(); end();
    pixel(4,6,255,255,255,"scale change retains physical scissor"); pixel(3,6,0,0,0,"scale change does not move clip");
#ifdef MTL_HUD_MENU_FOUNDATION
    begin(); api.SetClipRect(3,5,7,9); MTL_HUDSetScissorBroken(1); api.ResetClipRect(); api.SetClipRect(0,0,32,32);
    api.ClipLeftFrom(8); api.ClipRightTo(4); api.ReapplyClipRect(); fill(); end();
    pixel(3,5,255,255,255,"broken cvar leaves existing hardware clip"); pixel(2,5,0,0,0,"broken cvar makes all five calls no-ops");
    MTL_HUDSetScissorBroken(0);
    begin(); api.SetClipRect(3,5,7,9); end(); begin(false); fill(); end();
    pixel(3,5,255,255,255,"new encoder restores clipping"); pixel(2,5,0,0,0,"new encoder preserves clip exterior");
#endif
}
static void geometry(void)
{
    check(api.DrawLine!=nullptr,"line export"); check(api.DrawBevelBox!=nullptr,"bevel export");
    if(!api.DrawLine || !api.DrawBevelBox) return;
    begin(); api.DrawLine(8,10,16,10,4,red); end();
    pixel(6,8,255,0,0,"square cap extends before first endpoint"); pixel(17,11,255,0,0,"square cap extends after last endpoint");
    pixel(5,10,0,0,0,"line exterior before cap"); pixel(18,10,0,0,0,"line exterior after cap");
    begin(); api.DrawLine(8,8,8,8,4,red); end(); pixel(6,6,255,0,0,"zero-length line is a square");
    begin(); OM_Set2DScale(2); api.DrawLine(4,5,8,5,2,red); end(); pixel(6,8,255,0,0,"line width scales once");
    begin(); api.DrawLine(10,10,18,18,4,red); end();
    pixel(9,9,255,0,0,"diagonal cap extends in segment direction"); pixel(18,18,255,0,0,"diagonal end cap");
    pixel(9,13,0,0,0,"diagonal width excludes side exterior");
    const byte gray[4]={100,100,100,255}; begin(); api.DrawBevelBox(5,5,12,12,gray); end();
    pixel(10,10,100,100,100,"bevel fill"); pixel(10,4,130,130,130,"bevel top light line");
    pixel(4,10,130,130,130,"bevel left light line"); pixel(16,10,70,70,70,"bevel right dark line");
    pixel(10,16,70,70,70,"bevel bottom dark line"); pixel(3,10,0,0,0,"bevel exterior");
    const byte saturated[4]={250,100,0,127}; begin(); api.DrawBevelBox(5,5,12,12,saturated); end();
    pixel(10,4,127,65,0,"bevel light saturates RGB before alpha blend");
    // The dark edge overlays the earlier translucent fill at this pixel.
    pixel(16,10,150,60,0,"bevel dark retains input alpha over fill");
}
static int test_font(const char *name,void **data)
{
    if(strcmp(name,"pics/menus/fonts/font1.fnt")) return -1;
    byte *records=(byte *)calloc(224,28); *data=records;
    float st[4]={0,0,1,1}; int metrics[3]={8,8,8};
    memcpy(records+('A'-32)*28,st,sizeof(st));
    memcpy(records+('A'-32)*28+16,metrics,sizeof(metrics));
    return 224*28;
}
static void images(void)
{
    bool ready=api.SetRawImage && api.UnregisterPic;
    check(ready,"mutable raw image exports"); check(upload_alpha!=nullptr,"alpha image export");
    if(!ready || !upload_alpha) return;
    char name[]="pics/menus/om/test_dynamic";
    byte rgba[16]={255,0,0,0, 0,255,0,127, 0,0,255,255, 255,255,0,0};
    int w,h; api.DrawGetPicSize(&w,&h,name); check(w==-1 && h==-1,"missing image is cached");
    check(!upload_alpha(name,0,0,nullptr),"existence query never loads a missing image");
    api.SetRawImage(name,2,2,rgba); api.DrawGetPicSize(&w,&h,name); check(w==2 && h==2,"raw upload repairs cached miss");
    begin(); api.DrawStretchPic(0,0,2,2,white,name,0); end();
    pixel(0,0,255,0,0,"raw RGB ignores zero input alpha"); pixel(1,0,0,255,0,"raw RGB ignores partial input alpha");
    check(upload_alpha(name,2,2,rgba),"alpha replaces raw image");
    begin(); api.DrawStretchPic(0,0,16,16,white,name,0); end();
    pixel(3,3,0,0,0,"alpha replacement preserves transparency"); pixel(12,3,0,127,0,"alpha replacement preserves partial alpha");
    pixel(3,12,0,0,255,"alpha replacement preserves opaque colour");
    byte cyan[4]={0,255,255,255}; api.SetRawImage(name,1,1,cyan); api.DrawGetPicSize(&w,&h,name);
    check(w==1 && h==1,"raw replacement changes dimensions");
    begin(); api.DrawStretchPic(0,0,16,16,white,name,0); end(); pixel(3,3,0,255,255,"replacement updates drawn texture");
    api.SetRawImage(name,-1,2,rgba); check(upload_alpha(name,0,0,nullptr),"invalid upload preserves valid image");
    api.UnregisterPic(name); check(!upload_alpha(name,0,0,nullptr),"unregister removes existence result");
    api.DrawGetPicSize(&w,&h,name); check(w==-1 && h==-1,"unregister allows a fresh disk lookup");
    upload_alpha(name,1,1,cyan); check(upload_alpha(name,0,0,nullptr),"reupload after unregister repairs cached miss");
    char fontname[]="pics/menus/fonts/font1", alias[]="pics/menus/fonts/font1.m32";
    upload_alpha(fontname,1,1,cyan);
    mtl_hud_fonts[0].loaded=true; mtl_hud_fonts[0].page=MTL_HUDPic(fontname);
    api.UnregisterPic(alias);
    check(!mtl_hud_fonts[0].loaded && !mtl_hud_fonts[0].page,"font-page unregister invalidates cached font pointer across m32 alias");
    upload_alpha(alias,1,1,cyan); check(upload_alpha(fontname,0,0,nullptr),"canonical font alias reupload is visible");
    mtl_hud_fonts[0].loaded=true; mtl_hud_fonts[0].page=MTL_HUDPic(fontname);
    upload_alpha(alias,2,2,rgba);
    check(!mtl_hud_fonts[0].loaded && !mtl_hud_fonts[0].page,"font-page replacement invalidates cached pointer");
    ri.FS_LoadFile=test_font; ri.FS_FreeFile=free;
    om_fontref_t font={}; font.chars="small"; char text[]="A";
    begin(); api.DrawFontString(0,0,text,0xffffffff,&font,0); end();
    pixel(1,1,0,0,0,"reloaded font uses replacement transparent texel");
    pixel(6,1,0,127,0,"reloaded font uses replacement partial-alpha texel");
    pixel(1,6,0,0,255,"reloaded font uses replacement opaque texel");
    char disk[]="pics/menus/om/disk", diskalias[]="/pics/menus/om/disk.m32";
    api.DrawGetPicSize(&w,&h,disk); check(w==1 && h==1,"disk image is cached");
    begin(); api.DrawStretchPic(0,0,8,8,white,disk,0); end(); pixel(3,3,255,0,0,"first disk image colour");
    api.UnregisterPic(diskalias); diskcolour[0]=0; diskcolour[2]=255;
    begin(); api.DrawStretchPic(0,0,8,8,white,disk,0); end();
    pixel(3,3,0,0,255,"unregister reloads disk data through suffix/leading-slash alias");
    check(diskloads==2,"disk image loaded once before and once after unregister");
    byte ruby[4]={255,0,0,255}, blue[4]={0,0,255,255};
    api.SetRawImage(name,1,1,ruby); begin(); api.DrawStretchPic(0,0,8,8,white,name,0);
    api.SetRawImage(name,1,1,blue); api.DrawStretchPic(8,0,8,8,white,name,0); end();
    pixel(3,3,255,0,0,"replacement retains earlier encoded draw texture");
    pixel(11,3,0,0,255,"replacement used by later encoded draw");
    byte opaque[4]={255,255,255,255}; upload_alpha(name,1,1,opaque); draw_chars=MTL_HUDPic(name);
    const byte gray[4]={127,127,127,127};
    begin(); api.DrawPic(20,20,name,0xffffffff); api.DrawLine(20,20,25,20,1,red); api.DrawChar(0,0,'A',gray); end();
    pixel(3,3,127,127,127,"line leaves blending disabled for next character");
    begin(); api.DrawPic(20,20,name,0xffffffff); api.DrawBevelBox(20,20,5,5,red); api.DrawChar(0,0,'A',gray); end();
    pixel(3,3,127,127,127,"bevel leaves blending disabled for next character");
    draw_chars=nullptr;
}
static void filtering(void)
{
    char name[]="pics/menus/om/filter_test";
    byte edge[8]={0,0,0,255,255,255,255,255};
    MTL_HUDSetRawLinear(YES); api.SetRawImage(name,2,1,edge);
    begin(); api.DrawStretchPic(0,0,16,8,white,name,0); end();
    pixel(7,3,112,112,112,"raw magnification uses linear boundary sample");
    pixel(8,3,143,143,143,"raw linear opposite boundary");
    pixel(0,3,112,112,112,"raw linear outer edge repeats opposite texel");
    pixel(15,3,143,143,143,"raw linear far outer edge repeats");
    MTL_HUDSetRawLinear(NO);
    begin(); api.DrawStretchPic(0,0,16,8,white,name,0); end();
    pixel(7,3,0,0,0,"raw honors nearest magnification mode");
    pixel(8,3,255,255,255,"raw nearest opposite boundary");
    upload_alpha(name,2,1,edge);
    begin(); api.DrawStretchPic(0,0,16,8,white,name,0); end();
    pixel(7,3,0,0,0,"picture at whole scale stays nearest");
    begin(); api.DrawPicPart(0,0,-1,0,1,1,white,name); end();
    pixel(0,0,255,255,255,"nearest picture crop outside image repeats");
    begin(); mtl_hud_scale=1.5f; api.DrawStretchPic(0,0,16,8,white,name,0); end();
    pixel(11,3,117,117,117,"fractional picture scale uses linear boundary sample");
    pixel(0,3,117,117,117,"fractional picture outer edge repeats");
    MTL_HUDSetRawLinear(YES);
}
static void *MTL_FindImage(const char *name,imagetype_t)
{
    if(strcmp(name,"pics/menus/om/disk.m32")) return nullptr;
    diskloads++;
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    td.storageMode=MTLStorageModeShared;
    id<MTLTexture> texture=[mtl_device newTextureWithDescriptor:td];
    [texture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:diskcolour bytesPerRow:4];
    mtl_image_t *image=(mtl_image_t *)calloc(1,sizeof(*image));
    image->width=image->height=1; image->tex=(void *)CFBridgingRetain(texture);
    return image;
}
int main(void)
{
    @autoreleasepool {
        mtl_device=MTLCreateSystemDefaultDevice(); if(!mtl_device) return 77;
        queue=[mtl_device newCommandQueue]; mtl_layer=[CAMetalLayer layer]; mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
        mtl_pipe2d=MTL_BuildPipeline(NO,YES); mtl_pipe_sof2d=MTL_BuildPipeline(YES,YES); mtl_pipe_sof2d_replace=MTL_BuildPipeline(YES,NO);
        mtl_samp_ui=MTL_MakeUISampler(NO); mtl_samp_clamp=mtl_samp_repeat=mtl_samp_ui;
        mtl_samp_ui_linear=MTL_MakeUISampler(YES);
        MTLDepthStencilDescriptor *ds=[MTLDepthStencilDescriptor new]; ds.depthCompareFunction=MTLCompareFunctionAlways;
        mtl_depth_2d=[mtl_device newDepthStencilStateWithDescriptor:ds];
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        td.storageMode=MTLStorageModeShared; mtl_white=[mtl_device newTextureWithDescriptor:td];
        [mtl_white replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:white bytesPerRow:4];
        td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
        td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageRenderTarget; target=[mtl_device newTextureWithDescriptor:td];
        td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:32 height:32 mipmapped:NO];
        td.storageMode=MTLStorageModePrivate; td.usage=MTLTextureUsageRenderTarget; depth=[mtl_device newTextureWithDescriptor:td];
        upload_alpha=(OM_SetAlphaImage_t)dlsym(RTLD_DEFAULT,"OM_SetAlphaImage");
        MTL_SoF_HUDExports(&api); check(!api.Set2D && !api.Set3DInMenu,"partial native table retains menu fallback");
        clips(); geometry(); images(); filtering(); MTL_SoF_HUDShutdown();
        printf("Menu foundation GPU checks: %d passed, %d failed\n",checks-failures,failures);
        return failures?1:0;
    }
}
