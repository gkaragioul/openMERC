// SPDX-License-Identifier: GPL-2.0-or-later
// Actual Metal color/depth/readback; a drawable wrapper avoids a game/window.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdint>
static id<MTLDevice> mtl_device;
static id<MTLCommandQueue> mtl_queue;
static id<MTLCommandBuffer> mtl_cb;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<CAMetalDrawable> mtl_drawable,mtl_last_drawable;
static id<MTLTexture> mtl_depth;
static int mtl_width,mtl_height;
static bool mtl_encoder_open;
static dispatch_semaphore_t mtl_inflight;
#include "readback_clip_production.h"
#if __has_include("mtl_readback.h")
#include "mtl_readback.h"
#endif
#ifdef OM_METAL_READBACK
static void (*read_thumbnail)(unsigned char *,int,int)=MTL_SoF_ReadThumbnail;
static void (*model_fence)(void)=MTL_ModelFence;
#else
static void (*read_thumbnail)(unsigned char *,int,int);
static void (*model_fence)(void);
#endif

static int presents,checks,failures;
@interface TestDrawable : NSObject <CAMetalDrawable>
@property(nonatomic,strong) id<MTLTexture> texture;
@end
@implementation TestDrawable
-(CAMetalLayer *)layer { return nil; }
-(NSTimeInterval)presentedTime { return 0; }
-(NSUInteger)drawableID { return 1; }
-(void)addPresentedHandler:(MTLDrawablePresentedHandler)handler { (void)handler; }
-(void)present { presents++; }
-(void)presentAtTime:(CFTimeInterval)time { (void)time; presents++; }
-(void)presentAfterMinimumDuration:(CFTimeInterval)time { (void)time; presents++; }
@end
static id<MTLRenderPipelineState> pipeline;
static id<MTLDepthStencilState> depth_write;
static void check(bool pass,const char *label)
{ checks++; if(!pass) { fprintf(stderr,"FAIL: %s\n",label); failures++; } }
static void completed(id<MTLCommandBuffer> cb)
{
    [cb waitUntilCompleted];
    if(cb.error) { fprintf(stderr,"GPU error: %s\n",cb.error.localizedDescription.UTF8String); abort(); }
}
static void begin(int width,int height,bool withdepth=true,bool depthstore=true)
{
    mtl_width=width; mtl_height=height;
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    td.storageMode=MTLStorageModePrivate; td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    TestDrawable *drawable=[TestDrawable new]; drawable.texture=[mtl_device newTextureWithDescriptor:td]; mtl_drawable=drawable;
    mtl_depth=nil;
    if(withdepth) {
        td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:width height:height mipmapped:NO];
        td.storageMode=MTLStorageModePrivate; td.usage=MTLTextureUsageRenderTarget; mtl_depth=[mtl_device newTextureWithDescriptor:td];
    }
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=mtl_drawable.texture; pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore; pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    if(withdepth) {
        pass.depthAttachment.texture=mtl_depth; pass.depthAttachment.loadAction=MTLLoadActionClear;
        pass.depthAttachment.storeAction=depthstore?MTLStoreActionStore:MTLStoreActionDontCare; pass.depthAttachment.clearDepth=1;
    }
    mtl_cb=[mtl_queue commandBuffer]; mtl_enc=[mtl_cb renderCommandEncoderWithDescriptor:pass]; mtl_encoder_open=true;
    mtl_hud_clipenabled=NO; MTL_HUDApplyClip(width,height);
}
static void finish(bool wait=true)
{
    [mtl_enc endEncoding]; mtl_encoder_open=false; mtl_enc=nil;
    id<MTLCommandBuffer> cb=mtl_cb; [cb commit]; if(wait) completed(cb);
    mtl_last_drawable=mtl_drawable; mtl_drawable=nil; mtl_cb=nil;
}
static void rect(int x,int y,int w,int h,float z,const unsigned char rgba[4])
{
    struct Vertex { float pos[3]; } v[6];
    const int corners[6]={0,1,2,0,2,3}; const float xy[4][2]={{(float)x,(float)y},{(float)(x+w),(float)y},{(float)(x+w),(float)(y+h)},{(float)x,(float)(y+h)}};
    for(int i=0;i<6;i++) { int k=corners[i]; v[i]={{2*xy[k][0]/mtl_width-1,1-2*xy[k][1]/mtl_height,z}}; }
    float c[4]; for(int i=0;i<4;i++) c[i]=rgba[i]/255.0f;
    [mtl_enc setRenderPipelineState:pipeline]; [mtl_enc setDepthStencilState:depth_write]; [mtl_enc setCullMode:MTLCullModeNone];
    [mtl_enc setVertexBytes:v length:sizeof(v) atIndex:0]; [mtl_enc setFragmentBytes:c length:sizeof(c) atIndex:0];
    [mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}
static void pixel(const unsigned char *out,int width,int x,int y,int r,int g,int b,const char *label)
{
    const unsigned char *p=out+((size_t)y*width+x)*4;
    bool ok=abs((int)p[0]-r)<=1 && abs((int)p[1]-g)<=1 && abs((int)p[2]-b)<=1 && p[3]==255;
    if(!ok) fprintf(stderr,"  %s at %d,%d: RGBA %u %u %u %u expected %d %d %d 255\n",label,x,y,p[0],p[1],p[2],p[3],r,g,b);
    check(ok,label);
}
static const unsigned char cells[15][4]={
    {10,20,30,0},{50,20,37,1},{90,20,44,127},{130,20,51,254},{170,20,58,255},
    {10,80,39,20},{50,80,46,80},{90,80,53,160},{130,80,60,200},{170,80,67,255},
    {10,140,48,0},{50,140,55,20},{90,140,62,120},{130,140,69,220},{170,140,76,255}};
static void pattern(void)
{
    begin(5,3);
    for(int y=0;y<3;y++) for(int x=0;x<5;x++) rect(x,y,1,1,.5f,cells[y*5+x]);
}
static void sampling(void)
{
    unsigned char out[8*6*4]; pattern(); read_thumbnail(out,5,3);
    const int full[15]={10,11,12,13,14,5,6,7,8,9,0,1,2,3,4};
    for(int i=0;i<15;i++) { const unsigned char *p=cells[full[i]]; pixel(out,5,i%5,i/5,p[0],p[1],p[2],"BGRA/RGBA bottom-to-top exact readback"); }
    read_thumbnail(out,3,2); const int down[6]={10,11,13,5,6,8};
    for(int i=0;i<6;i++) { const unsigned char *p=cells[down[i]]; pixel(out,3,i%3,i/3,p[0],p[1],p[2],"nondivisible 16.16 downsample"); }
    read_thumbnail(out,8,6); const int sx[8]={0,0,1,1,2,3,3,4}, sy[6]={2,2,1,1,0,0};
    for(int y=0;y<6;y++) for(int x=0;x<8;x++) { const unsigned char *p=cells[sy[y]*5+sx[x]]; pixel(out,8,x,y,p[0],p[1],p[2],"16.16 nearest upsample"); }
    check(mtl_encoder_open && mtl_cb && mtl_enc,"repeated readbacks leave current frame open");
    check(presents==0,"readbacks do not present drawable");
    check(dispatch_semaphore_wait(mtl_inflight,DISPATCH_TIME_NOW)!=0,"readbacks retain frame semaphore ownership");
    finish();
}
static void continuation(void)
{
    const unsigned char red[4]={255,0,0,25},green[4]={0,255,0,50},blue[4]={0,0,255,75},yellow[4]={255,255,0,90};
    unsigned char first[16*12*4],second[sizeof(first)],third[sizeof(first)];
    begin(16,12,true,getenv("OM_READBACK_DONTCARE")==nullptr); rect(0,0,8,12,.2f,red); rect(8,0,8,12,.6f,green);
    mtl_hud_clipenabled=YES; mtl_hud_scissor[0]=4;mtl_hud_scissor[1]=3;mtl_hud_scissor[2]=9;mtl_hud_scissor[3]=8; MTL_HUDApplyClip(16,12);
    read_thumbnail(first,16,12); rect(0,0,16,12,.5f,blue); read_thumbnail(second,16,12);
    pixel(second,16,5,6,255,0,0,"continued draw retains nearer depth");
    pixel(second,16,8,6,0,0,255,"continued draw passes stored farther depth inside clip");
    pixel(second,16,10,6,0,255,0,"continued draw preserves color outside restored clip");
    pixel(second,16,8,9,0,255,0,"clip retains top-left coordinate orientation after resume");
    read_thumbnail(third,16,12); check(!memcmp(second,third,sizeof(second)),"repeated readback preserves color/depth");
    model_fence(); check(mtl_encoder_open,"model fence resumes open frame");
    rect(0,0,16,12,.4f,yellow); read_thumbnail(third,16,12);
    pixel(third,16,5,6,255,0,0,"model fence retains nearer depth");
    pixel(third,16,8,6,255,255,0,"model fence continuation draws through restored clip");
    pixel(third,16,10,6,0,255,0,"model fence preserves outside color");
    check(presents==0,"fence and continuation do not present");
    check(dispatch_semaphore_wait(mtl_inflight,DISPATCH_TIME_NOW)!=0,"fence retains frame semaphore ownership");
    finish();
}
static void idle(void)
{
    unsigned char out[15*4]; pattern(); finish(false);
    read_thumbnail(out,5,3);
    pixel(out,5,0,0,10,140,48,"idle readback waits for last drawable's queued render");
    pixel(out,5,4,2,170,20,58,"idle readback top source row");
    check(!mtl_encoder_open && !mtl_cb && !mtl_enc,"idle readback does not create a frame");
    id<MTLBuffer> marker=[mtl_device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[mtl_queue commandBuffer]; id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    [blit fillBuffer:marker range:NSMakeRange(0,256) value:0x7b]; [blit endEncoding]; [cb commit];
    model_fence(); check(((const unsigned char *)marker.contents)[255]==0x7b,"idle model fence drains earlier queued work");
    check(!mtl_encoder_open && !mtl_cb && !mtl_enc,"idle model fence does not create a frame");
    check(presents==0,"idle operations do not present");
    check(dispatch_semaphore_wait(mtl_inflight,DISPATCH_TIME_NOW)!=0,"idle operations do not signal frame semaphore");
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:2 mipmapped:NO];
    td.storageMode=MTLStorageModeShared;
    TestDrawable *rgba=[TestDrawable new]; rgba.texture=[mtl_device newTextureWithDescriptor:td];
    const unsigned char rows[8]={230,20,10,0, 5,30,240,127};
    [rgba.texture replaceRegion:MTLRegionMake2D(0,0,1,2) mipmapLevel:0 withBytes:rows bytesPerRow:4];
    mtl_last_drawable=rgba; read_thumbnail(out,1,2);
    pixel(out,1,0,0,5,30,240,"RGBA source retains channel order and bottom row");
    pixel(out,1,0,1,230,20,10,"RGBA source ignores input alpha");
    begin(2,2,false); read_thumbnail(out,2,2); pixel(out,2,0,0,0,0,0,"color-only encoder can be drained and resumed");
    model_fence(); check(mtl_encoder_open && !mtl_depth,"color-only model fence resumes without depth"); finish();
}
static void invalid(void)
{
    unsigned char out[64]; memset(out,0x5a,sizeof(out));
    begin(4,4); id<MTLRenderCommandEncoder> original=mtl_enc; id<MTLCommandBuffer> originalcb=mtl_cb;
    read_thumbnail(out,0,4); read_thumbnail(out,4,-1); read_thumbnail(nullptr,4,4);
    check(mtl_enc==original && mtl_cb==originalcb && mtl_encoder_open,"invalid parameters leave active encoder untouched");
    bool unchanged=true;for(unsigned char c:out) unchanged&=c==0x5a; check(unchanged,"invalid parameters do not mutate output"); finish();
    mtl_last_drawable=nil; read_thumbnail(out,4,4);
    unchanged=true;for(unsigned char c:out) unchanged&=c==0x5a; check(unchanged,"missing drawable does not mutate output");
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:4 height:4 mipmapped:NO];
    TestDrawable *unsupported=[TestDrawable new]; unsupported.texture=[mtl_device newTextureWithDescriptor:td]; mtl_last_drawable=unsupported;
    read_thumbnail(out,4,4); unchanged=true;for(unsigned char c:out) unchanged&=c==0x5a;
    check(unchanged,"unsupported source format does not mutate output"); mtl_last_drawable=nil;
}
int main(void)
{
    @autoreleasepool {
        mtl_device=MTLCreateSystemDefaultDevice(); if(!mtl_device) return 77;
        mtl_queue=[mtl_device newCommandQueue]; mtl_inflight=dispatch_semaphore_create(0);
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nstruct V { packed_float3 p; }; struct O { float4 p [[position]]; }; vertex O vert(uint i [[vertex_id]],constant V *v [[buffer(0)]]) { O o; o.p=float4(float3(v[i].p),1); return o; } fragment float4 frag(constant float4 &c [[buffer(0)]]) { return c; }";
        NSError *error=nil; id<MTLLibrary> lib=[mtl_device newLibraryWithSource:source options:nil error:&error];
        if(!lib) { fprintf(stderr,"shader: %s\n",error.localizedDescription.UTF8String); return 1; }
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"vert"]; pd.fragmentFunction=[lib newFunctionWithName:@"frag"];
        pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm; pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
        pipeline=[mtl_device newRenderPipelineStateWithDescriptor:pd error:&error];
        MTLDepthStencilDescriptor *ds=[MTLDepthStencilDescriptor new]; ds.depthWriteEnabled=YES; ds.depthCompareFunction=MTLCompareFunctionLess;
        depth_write=[mtl_device newDepthStencilStateWithDescriptor:ds];
        check(read_thumbnail!=nullptr,"native synchronous thumbnail implementation"); check(model_fence!=nullptr,"native encoder-preserving model fence implementation");
        if(read_thumbnail && model_fence) { sampling(); continuation(); idle(); invalid(); }
        printf("Menu readback GPU checks: %d passed, %d failed\n",checks-failures,failures);
        return failures?1:0;
    }
}
