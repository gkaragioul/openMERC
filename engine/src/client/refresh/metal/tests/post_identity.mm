// SPDX-License-Identifier: GPL-2.0-or-later
// Native offscreen Task3 resource/encoder/depth/identity contracts.
// Implements: SPEC-002, SPEC-412 section11 and SPEC-413 native depth.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <map>
#include <string>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
static id<MTLDevice> mtl_device;
static id<MTLCommandQueue> mtl_queue;
static id<MTLCommandBuffer> mtl_cb;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<CAMetalDrawable> mtl_drawable,mtl_last_drawable;
static bool mtl_encoder_open;
static CAMetalLayer *mtl_layer;
static int mtl_width=63,mtl_height=47;
typedef struct {float value;} cvar_t;
static std::map<std::string,cvar_t> cvars;
static cvar_t *get_cvar(const char *name,const char *value,int){
 auto p=cvars.emplace(name,cvar_t{(float)atof(value)});return &p.first->second;
}
static struct {cvar_t *(*Cvar_Get)(const char*,const char*,int);} ri={get_cvar};
#define CVAR_ARCHIVE 1
#define RDF_NOWORLDMODEL 2
#define RDF_IRGOGGLES 4
static cvar_t fullbright={0};static cvar_t *mtl_fullbright_cvar=&fullbright;
static struct {int rdflags;} mtl_refdef;
static void *mtl_worldmodel=(void *)1;
static void MTL_Fatal(const char *where,const char *why){fprintf(stderr,"%s: %s\n",where,why?why:"");abort();}
#include "../mtl_targets.h"
#if !POST_IDENTITY_OLD
#include "../mtl_emission_state.h"
#include "../mtl_post.h"
#endif
static int checks,failures;
static void check(bool ok,const char *name){checks++;if(!ok){fprintf(stderr,"FAIL %s\n",name);failures++;}}
static void set(const char *n,float v){get_cvar(n,"0",0)->value=v;}
static id<MTLTexture> texture(MTLPixelFormat format,int w,int h){
 auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
 d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
 return [mtl_device newTextureWithDescriptor:d];
}
static id<MTLRenderPipelineState> marker[3];static id<MTLDepthStencilState> write_depth;
static void pipelines(){
 NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nstruct O{float4 p [[position]];};vertex O v(uint i [[vertex_id]],constant float &z [[buffer(0)]]){float2 p=float2(i==1?3:-1,i==2?-3:1);O o;o.p=float4(p,z,1);return o;} fragment float4 f(O o [[stage_in]],constant float4 &c [[buffer(0)]]){return c;} struct R{float4 c [[color(0)]];float4 e [[color(1)]];};fragment R m(O o [[stage_in]],constant float4 &c [[buffer(0)]]){R r;r.c=c;r.e=float4(1,0,1,1);return r;} fragment R gradient(O o [[stage_in]]){R r;r.c=float4(o.p.x/63.0,o.p.y/47.0,.25,1);r.e=float4(0);return r;}";
 NSError *e=nil;auto lib=[mtl_device newLibraryWithSource:source options:nil error:&e];if(!lib)MTL_Fatal("marker shader",e.localizedDescription.UTF8String);
 for(int i=0;i<3;i++){auto d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[lib newFunctionWithName:@"v"];d.fragmentFunction=[lib newFunctionWithName:i==2?@"gradient":i?@"m":@"f"];d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;if(i)d.colorAttachments[1].pixelFormat=MTLPixelFormatRGBA8Unorm;d.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;marker[i]=[mtl_device newRenderPipelineStateWithDescriptor:d error:&e];if(!marker[i])MTL_Fatal("marker pipeline",e.localizedDescription.UTF8String);}
 auto d=[MTLDepthStencilDescriptor new];d.depthCompareFunction=MTLCompareFunctionLessEqual;d.depthWriteEnabled=YES;write_depth=[mtl_device newDepthStencilStateWithDescriptor:d];
}
static void fill(float z,float r,float g,float b){float c[4]={r,g,b,1};
 [mtl_enc setRenderPipelineState:marker[mtl_current_targets.color_count==2]];
 [mtl_enc setDepthStencilState:write_depth];[mtl_enc setCullMode:MTLCullModeNone];
 [mtl_enc setVertexBytes:&z length:4 atIndex:0];[mtl_enc setFragmentBytes:c length:16 atIndex:0];
 [mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}
static mtl_frame_targets_t window_targets;
static void begin(int w=63,int h=47){
 mtl_width=w;mtl_height=h;mtl_cb=[mtl_queue commandBuffer];window_targets={};
 window_targets.color[0]=texture(MTLPixelFormatBGRA8Unorm,w,h);window_targets.depth=texture(MTLPixelFormatDepth32Float,w,h);
 window_targets.color_count=window_targets.samples=1;window_targets.viewport={0,0,(double)w,(double)h,0,1};window_targets.scissor={0,0,(NSUInteger)w,(NSUInteger)h};window_targets.clear_depth=1;
 check(MTL_TargetOpen(&window_targets,MTLLoadActionClear,MTLLoadActionClear),"window opens");fill(.1f,1,0,0);
}
static void finish(){MTL_TargetEnd();[mtl_cb commit];[mtl_cb waitUntilCompleted];if(mtl_cb.error)MTL_Fatal("identity test",mtl_cb.error.localizedDescription.UTF8String);mtl_cb=nil;MTL_TargetReset();}
static void read(id<MTLTexture> tex,void *bytes){
 if(!tex)return;NSUInteger row=(tex.width*4+255)&~255ul;
 auto buffer=[mtl_device newBufferWithLength:row*tex.height options:MTLResourceStorageModeShared];auto cb=[mtl_queue commandBuffer];auto blit=[cb blitCommandEncoder];
 [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(tex.width,tex.height,1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*tex.height];[blit endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error)MTL_Fatal("identity read",cb.error.localizedDescription.UTF8String);
 for(NSUInteger y=0;y<tex.height;y++)memcpy((char*)bytes+y*tex.width*4,(char*)buffer.contents+y*row,tex.width*4);
}
static void pixel(id<MTLTexture> t,int x,int y,int r,int g,int b,const char *name){
 auto data=(unsigned char *)calloc(t.width*t.height,4);read(t,data);auto p=data+(y*t.width+x)*4;
 bool bgra=t.pixelFormat==MTLPixelFormatBGRA8Unorm;bool ok=abs(p[bgra?2:0]-r)<=1&&abs(p[1]-g)<=1&&abs(p[bgra?0:2]-b)<=1;
 if(!ok)fprintf(stderr,"  RGB %u %u %u expected %d %d %d\n",p[bgra?2:0],p[1],p[bgra?0:2],r,g,b);check(ok,name);free(data);
}
static float depth_at(id<MTLTexture> t,int x,int y){if(!t)return -1;auto data=(float*)calloc(t.width*t.height,4);read(t,data);float v=data[y*t.width+x];free(data);return v;}
static float projection[16]={1,0,0,0,0,1,0,0,0,0,-1.01f,-1,0,0,-.101f,0},view[16]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
@interface FailingDevice : NSObject
@property(nonatomic,strong) id<MTLDevice> actual;
@property(nonatomic) int successes;
@end
@implementation FailingDevice
-(id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d{if(self.successes>0){self.successes--;return [self.actual newTextureWithDescriptor:d];}return nil;}
-(id)forwardingTargetForSelector:(SEL)s{(void)s;return self.actual;}
@end
@interface FailingBuffer : NSObject
@property(nonatomic,strong) id<MTLCommandBuffer> actual;
@property(nonatomic) BOOL fail;
@end
@implementation FailingBuffer
-(id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)p{if(self.fail){self.fail=NO;return nil;}return [self.actual renderCommandEncoderWithDescriptor:p];}
-(id)forwardingTargetForSelector:(SEL)s{(void)s;return self.actual;}
@end
#if !POST_IDENTITY_OLD
static int process_calls,composite_calls;
static bool composite_writes;
static void process_view(){process_calls++;MTL_TargetEnd();}
static BOOL composite_view(){
 composite_calls++;
 check(mtl_post.active&&mtl_current_targets.color[0]==window_targets.color[0]&&
  mtl_current_targets.depth==window_targets.depth,"custom composite receives restored window targets while view is active");
 if(!composite_writes)return NO;
 float z=.05f,color[4]={0,1,1,1};
 [mtl_enc setRenderPipelineState:marker[0]];
 [mtl_enc setVertexBytes:&z length:sizeof(z) atIndex:0];
 [mtl_enc setFragmentBytes:color length:sizeof(color) atIndex:0];
 [mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
 return YES;
}
#endif
int main(){@autoreleasepool{
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 77;mtl_queue=[mtl_device newCommandQueue];mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;pipelines();
#if !POST_IDENTITY_OLD
 MTL_PostEmissionInit();MTL_PostInit();check(get_cvar("r_om_bloom","0",0)->value==1&&get_cvar("r_om_softparticles","1",0)->value==0&&get_cvar("r_om_volfog","0",0)->value==1&&get_cvar("r_om_post_debug","1",0)->value==0,"post activation defaults match current GPL");set("r_metal_post_identity",1);
#endif
 begin();id<MTLTexture> snapshot=nil;
#if POST_IDENTITY_OLD
 // Actual pre-Task3 native route: same single-color/depth window target.
#else
 check(MTL_PostBeginView(7,9,31,23,projection,view),"odd shifted view opens post");
 check(MTL_PostEmissionControls().enabled,"accepted bloom view enables actual source metadata");
#endif
 check(mtl_current_targets.color_count==2,"world has scene plus emission");fill(.6f,0,1,0);
#if !POST_IDENTITY_OLD
 MTL_PostCopyOpaqueDepth();check(MTL_PostDepthReady(),"opaque depth ready before entities");snapshot=MTL_PostOpaqueDepth();
#endif
 fill(.2f,0,0,1);
#if !POST_IDENTITY_OLD
 MTL_PostCopyOpaqueDepth();MTL_PostEndView();check(!MTL_PostDepthReady(),"ended view exposes no stale depth");
 check(!MTL_PostEmissionControls().enabled,"ended view disables actual emission source metadata");
 check(mtl_current_targets.color[0]==window_targets.color[0]&&mtl_current_targets.depth==window_targets.depth,"window attachments restored");
#endif
 fill(.3f,1,1,0);finish();
 pixel(window_targets.color[0],20,20,0,0,255,"identity copies view over independent window depth");
 pixel(window_targets.color[0],2,2,255,0,0,"outside physical view untouched");
 check(fabsf(depth_at(window_targets.depth,20,20)-.1f)<1e-6,"composition never alters window depth");
 check(fabsf(depth_at(snapshot,20,20)-.6f)<1e-6,"snapshot excludes later nearer entity and second copy");
#if !POST_IDENTITY_OLD
 begin();check(MTL_PostBeginView(0,0,63,47,projection,view),"full odd-sized view opens");
 float full_depth=.6f;[mtl_enc setRenderPipelineState:marker[2]];[mtl_enc setDepthStencilState:write_depth];[mtl_enc setCullMode:MTLCullModeNone];[mtl_enc setVertexBytes:&full_depth length:4 atIndex:0];[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
 MTL_PostEndView();finish();unsigned char full_pattern[63*47*4];read(window_targets.color[0],full_pattern);bool full_identity=true;
 for(int y=0;y<47;y++)for(int x=0;x<63;x++){auto q=full_pattern+(y*63+x)*4;full_identity&=abs(q[2]-(int)roundf((x+.5f)/63*255))<=1&&abs(q[1]-(int)roundf((y+.5f)/47*255))<=1&&abs(q[0]-64)<=1&&q[3]==255;}
 check(full_identity,"all odd full-target pixels preserve source within1 byte");
 begin();check(MTL_PostBeginView(7,9,31,23,projection,view),"first same-frame view opens");fill(.6f,0,1,0);MTL_PostEndView();
 check(MTL_PostBeginView(40,4,9,11,projection,view),"second differently sized same-frame view opens");fill(.6f,0,0,1);MTL_PostEndView();finish();
 pixel(window_targets.color[0],20,20,0,255,0,"first same-frame view survives second composition");
 pixel(window_targets.color[0],43,8,0,0,255,"second same-frame view uses independent physical rect");
 pixel(window_targets.color[0],2,2,255,0,0,"same-frame sequential views preserve outside sentinel");
 begin();check(MTL_PostBeginView(7,9,31,23,projection,view),"nonuniform identity view opens");
 float gradient_depth=.6f;[mtl_enc setRenderPipelineState:marker[2]];[mtl_enc setDepthStencilState:write_depth];[mtl_enc setCullMode:MTLCullModeNone];[mtl_enc setVertexBytes:&gradient_depth length:4 atIndex:0];[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
 MTL_PostEndView();finish();unsigned char pattern[63*47*4];read(window_targets.color[0],pattern);bool identity=true;
 for(int y=9;y<32;y++)for(int x=7;x<38;x++){auto q=pattern+(y*63+x)*4;identity&=abs(q[2]-(int)roundf((x+.5f)/63*255))<=1&&abs(q[1]-(int)roundf((y+.5f)/47*255))<=1&&abs(q[0]-64)<=1&&q[3]==255;}
 check(identity,"all odd-view gradient pixels preserve top-left orientation, texel centers and color within1 byte");
 // Restore the original blue source for the following gl_clear0 reuse case.
 begin();MTL_PostBeginView(7,9,31,23,projection,view);fill(.2f,0,0,1);MTL_PostEndView();finish();
 begin();check(MTL_PostBeginView(8,10,9,7,projection,view),"sequential second view opens");MTL_PostCopyOpaqueDepth();snapshot=MTL_PostOpaqueDepth();id<MTLTexture> emission=mtl_post.emissive;MTL_PostEndView();finish();
 pixel(window_targets.color[0],10,12,0,0,255,"gl_clear0 loads previous scene inside second view");pixel(window_targets.color[0],20,20,255,0,0,"sequential composition copies only second rect");pixel(emission,20,20,0,0,0,"emission clears every view including old footprint");check(depth_at(snapshot,20,20)==1,"new snapshot has far depth outside new geometry");
 set("gl_clear",1);begin();MTL_PostBeginView(8,10,9,7,projection,view);MTL_PostEndView();finish();pixel(window_targets.color[0],10,12,0,0,0,"gl_clear1 clears reused scene");set("gl_clear",0);
 begin(65,49);MTL_PostBeginView(7,9,31,23,projection,view);MTL_PostEndView();finish();pixel(window_targets.color[0],20,20,0,0,0,"new resized scene initializes even gl_clear0");check(mtl_post.scene.width==65&&mtl_post.scene.height==49,"all resources resize to physical window");
 begin(67,51);auto original=mtl_enc;auto actual=mtl_device;auto old_scene=mtl_post.scene;FailingDevice *bad=[FailingDevice new];bad.actual=actual;bad.successes=2;mtl_device=(id<MTLDevice>)bad;
 check(!MTL_PostBeginView(7,9,31,23,projection,view),"partial resource allocation failure bypasses atomically");check(mtl_enc==original&&MTL_TargetTracked()&&mtl_post.scene==old_scene,"allocation failure leaves old encoder and complete resources unchanged");mtl_device=actual;finish();
 begin(65,49);FailingBuffer *badcb=[FailingBuffer new];badcb.actual=mtl_cb;badcb.fail=YES;mtl_cb=(id<MTLCommandBuffer>)badcb;
 check(!MTL_PostBeginView(7,9,31,23,projection,view),"failed world target open restores direct route");check(MTL_TargetTracked()&&mtl_current_targets.color[0]==window_targets.color[0],"open failure restores saved window attachments");fill(.05f,0,1,0);finish();pixel(window_targets.color[0],20,20,0,255,0,"restored encoder remains drawable after failed open");
 set("r_metal_post_identity",0);set("r_om_bloom",0);set("r_om_softparticles",0);set("r_om_volfog",0);begin();original=mtl_enc;check(!MTL_PostBeginView(7,9,31,23,projection,view)&&mtl_enc==original,"all-off direct route leaves encoder untouched");finish();
 set("r_metal_post_identity",1);begin();check(MTL_PostBeginView(7,9,31,23,projection,view)&&!mtl_post.bloom&&!mtl_post.soft&&!mtl_post.volfog,"forced identity activates with every effect off");check(!MTL_PostEmissionControls().enabled,"forced identity all-off does not invent glow sources");MTL_PostCopyOpaqueDepth();check(MTL_PostDepthReady(),"forced identity enables controlled snapshot check");MTL_PostEndView();finish();set("r_metal_post_identity",0);
 set("r_om_bloom",1);begin();check(MTL_PostBeginView(7,9,31,23,projection,view),"ordinary bloom-only view opens");MTL_PostCopyOpaqueDepth();check(!MTL_PostDepthReady(),"bloom-only view does not request unused opaque depth copy");MTL_PostEndView();finish();
 begin();mtl_refdef.rdflags=RDF_NOWORLDMODEL;check(!MTL_PostBeginView(7,9,31,23,projection,view),"NOWORLD bypass");mtl_refdef.rdflags=0;mtl_worldmodel=NULL;check(!MTL_PostBeginView(7,9,31,23,projection,view),"missing world bypass");mtl_worldmodel=(void*)1;fullbright.value=1;check(!MTL_PostBeginView(7,9,31,23,projection,view),"fullbright suppresses normal bloom");fullbright.value=0;mtl_refdef.rdflags=RDF_IRGOGGLES;check(!MTL_PostBeginView(7,9,31,23,projection,view),"nightvision suppresses normal bloom");set("r_om_softparticles",1);check(MTL_PostBeginView(7,9,31,23,projection,view)&&mtl_post.soft&&!mtl_post.bloom,"nightvision retains explicitly requested soft depth path");MTL_PostCopyOpaqueDepth();check(MTL_PostDepthReady(),"nightvision soft route snapshots opaque depth");MTL_PostEndView();mtl_refdef.rdflags=0;finish();
 set("r_om_bloom",0);set("r_om_softparticles",0);set("r_om_volfog",1);MTL_PostSetFogRegionCount(1);begin();check(MTL_PostBeginView(7,9,31,23,projection,view)&&mtl_post.volfog,"volfog activation requires actual positive region count");MTL_PostEndView();finish();set("gl_fogmode",2);begin();check(!MTL_PostBeginView(7,9,31,23,projection,view),"fog mode2 disables volume-only route");set("gl_fogmode",0);MTL_PostSetFogRegionCount(0);check(!MTL_PostBeginView(7,9,31,23,projection,view),"zero regions disables volume-only route");set("r_om_post_debug",1);check(MTL_PostBeginView(7,9,31,23,projection,view),"debug activates identity MRT");MTL_PostEndView();finish();
 begin();MTLViewport saved_view={3,4,49,35,0,1};MTLScissorRect saved_clip={5,6,43,29};[mtl_enc setViewport:saved_view];MTL_TargetRecordViewport(saved_view);[mtl_enc setScissorRect:saved_clip];MTL_TargetRecordScissor(saved_clip);
 check(MTL_PostBeginView(7,9,31,23,projection,view),"post switches from custom saved window raster");MTL_PostEndView();check(mtl_current_targets.viewport.originX==3&&mtl_current_targets.scissor.x==5,"saved physical raster descriptor restored");fill(.05f,1,1,0);finish();pixel(window_targets.color[0],45,30,255,255,0,"restored viewport draws beyond old view");pixel(window_targets.color[0],2,2,255,0,0,"restored custom clip excludes outside sentinel");
 begin();original=mtl_enc;check(!MTL_PostBeginView(-1,9,31,23,projection,view),"negative view rejected");check(!MTL_PostBeginView(7,9,99,23,projection,view),"out-of-window view rejected");float singular[16]={0};check(!MTL_PostBeginView(7,9,31,23,projection,singular),"singular PV rejected before target switch");
 float nonfinite[16];memcpy(nonfinite,projection,sizeof(nonfinite));nonfinite[0]=NAN;
 check(!MTL_PostBeginView(7,9,31,23,nonfinite,view),"nonfinite projection rejected before target switch");
 memcpy(nonfinite,view,sizeof(nonfinite));nonfinite[12]=INFINITY;
 check(!MTL_PostBeginView(7,9,31,23,projection,nonfinite),"nonfinite view rejected before target switch");
 check(!MTL_PostBeginView(7,9,31,23,NULL,view)&&!MTL_PostBeginView(7,9,31,23,projection,NULL),"null matrix inputs rejected before target switch");
 check(!MTL_PostBeginView(7,9,0,23,projection,view)&&!MTL_PostBeginView(7,9,31,0,projection,view),"zero view dimensions rejected before target switch");
 check(mtl_enc==original&&MTL_TargetTracked(),"invalid input preserves original active encoder");finish();
 begin();MTLViewport reverse_raster=mtl_current_targets.viewport;reverse_raster.znear=1;reverse_raster.zfar=0;
 [mtl_enc setViewport:reverse_raster];MTL_TargetRecordViewport(reverse_raster);set("r_metal_post_identity",1);
 check(MTL_PostBeginView(7,9,31,23,projection,view),"reversed-depth view opens");
 check(mtl_post.depth_min==1&&mtl_post.depth_max==0&&mtl_post.C==projection[10]&&mtl_post.D==projection[14],"post retains native projection coefficients and reversed range");
 auto active_encoder=mtl_enc;check(!MTL_PostBeginView(7,9,31,23,projection,view)&&mtl_enc==active_encoder,"nested begin leaves active view unchanged");
 MTL_PostCopyOpaqueDepth();snapshot=MTL_PostOpaqueDepth();MTL_PostEndView();finish();
 check(depth_at(snapshot,20,20)==0&&depth_at(snapshot,2,2)==0,"reversed world depth clears and snapshots far zero across full allocation");
 set("r_metal_post_identity",0);
 set("r_om_post_debug",0);set("r_om_volfog",1);MTL_PostSetFogRegionCount(1);set("gl_fogmode",3);begin();check(!MTL_PostBeginView(7,9,31,23,projection,view),"fog mode3 disables volume-only route");set("gl_fogmode",0);set("r_om_volfog_intensity",0);check(!MTL_PostBeginView(7,9,31,23,projection,view),"zero volume intensity disables volume-only route");finish();
 // Processing may end the world encoder; replacement composition runs after
 // the window Load resume and must preserve its depth and outside-view pixels.
 set("gl_fogmode",0);set("r_om_volfog_intensity",.4f);set("r_metal_post_identity",0);
 mtl_framepost_process_view=process_view;mtl_framepost_composite_view=composite_view;
 composite_writes=true;begin();check(MTL_PostBeginView(7,9,31,23,projection,view),"custom processed view opens");fill(.6f,0,0,1);MTL_PostEndView();finish();
 check(process_calls==1&&composite_calls==1,"normal post runs process then replacement compositor once");
 pixel(window_targets.color[0],20,20,0,255,255,"replacement composite bypasses identity draw");
 pixel(window_targets.color[0],2,2,255,0,0,"replacement composite retains outside-view pixels");
 check(fabsf(depth_at(window_targets.depth,20,20)-.1f)<1e-6,"replacement composite starts with depth writes disabled");
 composite_writes=false;begin();MTL_PostBeginView(7,9,31,23,projection,view);fill(.6f,0,0,1);MTL_PostEndView();finish();
 check(process_calls==2&&composite_calls==2,"replacement compositor may decline after normal processing");
 pixel(window_targets.color[0],20,20,0,0,255,"declined replacement uses identity composition");
 composite_writes=true;set("r_metal_post_identity",1);begin();MTL_PostBeginView(7,9,31,23,projection,view);fill(.6f,0,0,1);MTL_PostEndView();finish();
 check(process_calls==2&&composite_calls==2,"forced identity skips process and replacement compositor");
 pixel(window_targets.color[0],20,20,0,0,255,"forced identity preserves original scene despite installed processing");
 begin();check(MTL_PostBeginView(7,9,31,23,projection,view),"view can remain active during renderer shutdown");fill(.6f,0,0,1);
 MTL_PostShutdown();check(MTL_TargetTracked()&&mtl_current_targets.color[0]==window_targets.color[0]&&mtl_current_targets.depth==window_targets.depth,"active-view shutdown restores saved window pass");
 fill(.05f,0,1,0);finish();pixel(window_targets.color[0],20,20,0,255,0,"saved window remains drawable after active-view shutdown");
 check(!mtl_post.scene&&!MTL_PostDepthReady(),"shutdown releases targets and stale depth state");check(!mtl_framepost_process_view&&!mtl_framepost_composite_view,"shutdown clears both processing hooks");MTL_PostInit();check(!mtl_post.scene&&!MTL_PostOpaqueDepth(),"renderer restart starts without stale resources");check(!mtl_framepost_process_view&&!mtl_framepost_composite_view,"renderer restart has no stale processing hooks");MTL_PostShutdown();
#endif
 printf("Identity framegraph GPU checks: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}}
