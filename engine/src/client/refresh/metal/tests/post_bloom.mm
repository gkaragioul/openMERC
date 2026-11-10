// SPDX-License-Identifier: GPL-2.0-or-later
// Independent numeric CPU oracle against production native post shaders.
// Implements: SPEC-AMEND-016 R16.7; current GPL gl3_post.c bloom filters.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
static id<MTLDevice> mtl_device;
static id<MTLCommandQueue> queue;
typedef struct { float value; } cvar_t;
static std::map<std::string,cvar_t> cvars;
static cvar_t *get_cvar(const char *n,const char *v,int){return &cvars.emplace(n,cvar_t{(float)atof(v)}).first->second;}
static struct { cvar_t *(*Cvar_Get)(const char *,const char *,int); } ri={get_cvar};
#define CVAR_ARCHIVE 1
#if POST_BLOOM_OLD
#include "post_bloom_baseline.h"
#else
#include "../mtl_bloom.h"
#endif
static int checks,failures;
static int largest_byte_difference;
static float largest_mip_difference;
static void check(bool yes,const char *name){checks++;if(!yes){failures++;fprintf(stderr,"FAIL %s\n",name);}}
static void fatal(const char *why,NSError *error){fprintf(stderr,"%s: %s\n",why,error.localizedDescription.UTF8String);exit(2);}
static void set(const char *n,float v){get_cvar(n,"0",0)->value=v;}
using Pixel=std::array<float,4>;
struct Image { int w,h;std::vector<Pixel> p;Image(int w_,int h_,Pixel c={0,0,0,1}):w(w_),h(h_),p(w_*h_,c){};Pixel &at(int x,int y){return p[y*w+x];} };
static float unorm(float f){return (float)(round((double)std::clamp(f,0.f,1.f)*255)/255);}
static float half(float f){return (float)(_Float16)f;}
static Image ldr(Image a){for(auto &p:a.p)for(float &v:p)v=unorm(v);return a;}
static Pixel sample(const Image &a,float u,float v){
 float fx=u*a.w-.5f,fy=v*a.h-.5f;int ix=(int)floorf(fx),iy=(int)floorf(fy);float tx=fx-ix,ty=fy-iy;Pixel out={};
 for(int j=0;j<2;j++)for(int i=0;i<2;i++){const auto &c=a.p[std::clamp(iy+j,0,a.h-1)*a.w+std::clamp(ix+i,0,a.w-1)];float k=(i?tx:1-tx)*(j?ty:1-ty);for(int q=0;q<3;q++)out[q]+=c[q]*k;}
 out[3]=1;return out;
}
// The reference deliberately does not call production layout/filter helpers.
static std::vector<Image> oracle(const Image &scene,const Image &emission,int x,int y,int w,int h,float radius,float threshold,bool fromscene){
 int wanted=std::clamp((int)(4+std::max(radius,0.f)+.5f),2,7),dw=w/2,dh=h/2;std::vector<Image> chain;
 for(int n=0;n<wanted&&dw>=4&&dh>=4;n++,dw/=2,dh/=2){
  chain.emplace_back(dw,dh);const Image &src=n?chain[n-1]:(fromscene?scene:emission);auto &dst=chain[n];
  float knee=std::clamp(threshold,0.f,.95f),loU=n?.5f/src.w:(x+.5f)/src.w,loV=n?.5f/src.h:(y+.5f)/src.h;
  float hiU=n?1-.5f/src.w:(x+w-.5f)/src.w,hiV=n?1-.5f/src.h:(y+h-.5f)/src.h;
  for(int dy=0;dy<dh;dy++)for(int dx=0;dx<dw;dx++){
   float u=n?(dx+.5f)/dw:(x+(dx+.5f)*w/dw)/src.w,v=n?(dy+.5f)/dh:(y+(dy+.5f)*h/dh)/src.h;
   Pixel result={};const int taps[5][3]={{0,0,4},{-1,-1,1},{1,1,1},{1,-1,1},{-1,1,1}};
   for(auto &t:taps){auto p=sample(src,std::clamp(u+t[0]/(float)src.w,loU,hiU),std::clamp(v+t[1]/(float)src.h,loV,hiV));for(int q=0;q<3;q++)result[q]+=p[q]*t[2]/8.f;}
   if(!n){if(fromscene){float k=std::clamp((*std::max_element(result.begin(),result.begin()+3)-.8f)*5,0.f,1.f);for(int q=0;q<3;q++)result[q]*=k;}else for(int q=0;q<3;q++)result[q]=std::max(result[q]-knee,0.f)/std::max(1-knee,.05f);}
   for(int q=0;q<3;q++)result[q]=half(result[q]);result[3]=1;dst.at(dx,dy)=result;
  }
 }
 for(int n=(int)chain.size()-2;n>=0;n--){auto &dst=chain[n];const auto &src=chain[n+1];
  for(int dy=0;dy<dst.h;dy++)for(int dx=0;dx<dst.w;dx++){
   float u=(dx+.5f)/dst.w,v=(dy+.5f)/dst.h;Pixel result={};const int taps[8][3]={{-2,0,1},{-1,1,2},{0,2,1},{1,1,2},{2,0,1},{1,-1,2},{0,-2,1},{-1,-1,2}};
   for(auto &t:taps){auto p=sample(src,u+t[0]*.5f/src.w,v+t[1]*.5f/src.h);for(int q=0;q<3;q++)result[q]+=p[q]*t[2]/12.f;}
   for(int q=0;q<3;q++)dst.at(dx,dy)[q]=half(dst.at(dx,dy)[q]+result[q]);
  }
 }
 return chain;
}
static Image composite(const Image &scene,const Image &emission,const std::vector<Image> &chain,int x,int y,int w,int h,int debug,bool enabled,float intensity){
 Image dst(scene.w,scene.h,{.13f,.27f,.39f,1});bool bloom=enabled&&!chain.empty();int mode=debug==1?2:debug==2&&bloom?3:bloom?1:0;
 for(int dy=y;dy<y+h;dy++)for(int dx=x;dx<x+w;dx++){
  Pixel out=mode==2?emission.p[dy*scene.w+dx]:mode==3?Pixel{0,0,0,1}:scene.p[dy*scene.w+dx];
  if(mode==1||mode==3){auto b=sample(chain[0],(dx-x+.5f)/w,(dy-y+.5f)/h);for(int q=0;q<3;q++)out[q]+=b[q]*intensity*2/chain.size();}out[3]=1;dst.at(dx,dy)=out;
 }
 return ldr(dst);
}
static id<MTLTexture> texture(MTLPixelFormat fmt,int w,int h){auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;return [mtl_device newTextureWithDescriptor:d];}
static id<MTLRenderPipelineState> source_pipeline,old_pipeline;
static void init_pipelines(){
 NSString *shader=@R"MSL(
#include <metal_stdlib>
using namespace metal;
struct O{float4 p [[position]];};
vertex O v(uint i [[vertex_id]]){float2 p=float2(i==1?3:-1,i==2?-3:1);return {float4(p,0,1)};}
struct R{float4 s [[color(0)]];float4 e [[color(1)]];};
fragment R f(O o [[stage_in]],device const float4 *s [[buffer(0)]],device const float4 *e [[buffer(1)]],constant uint &w [[buffer(2)]]){uint i=uint(o.p.y)*w+uint(o.p.x);return {s[i],e[i]};}
)MSL";
 NSError *e=nil;auto lib=[mtl_device newLibraryWithSource:shader options:nil error:&e];if(!lib)fatal("source shader",e);
 auto d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[lib newFunctionWithName:@"v"];d.fragmentFunction=[lib newFunctionWithName:@"f"];d.colorAttachments[0].pixelFormat=d.colorAttachments[1].pixelFormat=MTLPixelFormatRGBA8Unorm;
 source_pipeline=[mtl_device newRenderPipelineStateWithDescriptor:d error:&e];if(!source_pipeline)fatal("source pipeline",e);
#if POST_BLOOM_OLD
 lib=[mtl_device newLibraryWithSource:post_bloom_baseline_shader options:nil error:&e];if(!lib)fatal("actual retained identity shader",e);
 d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[lib newFunctionWithName:@"framepost_v"];d.fragmentFunction=[lib newFunctionWithName:@"framepost_f"];d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;old_pipeline=[mtl_device newRenderPipelineStateWithDescriptor:d error:&e];if(!old_pipeline)fatal("actual retained identity pipeline",e);
#endif
}
static std::vector<unsigned char> read(id<MTLTexture> tex,int bpp){NSUInteger row=(tex.width*bpp+255)&~255ul;auto buf=[mtl_device newBufferWithLength:row*tex.height options:MTLResourceStorageModeShared];auto cb=[queue commandBuffer];auto b=[cb blitCommandEncoder];[b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(tex.width,tex.height,1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*tex.height];[b endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error)fatal("readback",cb.error);std::vector<unsigned char> data(tex.width*tex.height*bpp);for(NSUInteger y=0;y<tex.height;y++)memcpy(data.data()+y*tex.width*bpp,(char*)buf.contents+y*row,tex.width*bpp);return data;}
static void run_case(const char *name,Image scene,Image emission,int x,int y,int w,int h,float radius=1,float knee=0,bool fromscene=false,int debug=0,bool enabled=true,float intensity=.45f){
 set("r_om_bloom_radius",radius);set("r_om_bloom_threshold",knee);set("r_om_bloom_fromscene",fromscene);set("r_om_bloom_intensity",intensity);
 auto s=texture(MTLPixelFormatRGBA8Unorm,scene.w,scene.h),e=texture(MTLPixelFormatRGBA8Unorm,scene.w,scene.h),out=texture(MTLPixelFormatRGBA8Unorm,scene.w,scene.h);
 auto cb=[queue commandBuffer];auto p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=s;p.colorAttachments[1].texture=e;
 for(int i=0;i<2;i++){p.colorAttachments[i].loadAction=MTLLoadActionDontCare;p.colorAttachments[i].storeAction=MTLStoreActionStore;}
 auto enc=[cb renderCommandEncoderWithDescriptor:p];[enc setRenderPipelineState:source_pipeline];auto sb=[mtl_device newBufferWithBytes:scene.p.data() length:scene.p.size()*sizeof(Pixel) options:MTLResourceStorageModeShared],eb=[mtl_device newBufferWithBytes:emission.p.data() length:emission.p.size()*sizeof(Pixel) options:MTLResourceStorageModeShared];unsigned width=scene.w;
 [enc setFragmentBuffer:sb offset:0 atIndex:0];[enc setFragmentBuffer:eb offset:0 atIndex:1];[enc setFragmentBytes:&width length:4 atIndex:2];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];
 scene=ldr(scene);emission=ldr(emission);auto chain=enabled?oracle(scene,emission,x,y,w,h,radius,knee,fromscene):std::vector<Image>{};
#if !POST_BLOOM_OLD
 bool processed=MTL_BloomProcess(cb,s,e,x,y,w,h,enabled);check(processed==(!enabled||!chain.empty()),"bloom enabled/too-small result matches chain availability");
#endif
 p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=out;p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].clearColor=MTLClearColorMake(.13,.27,.39,1);p.colorAttachments[0].storeAction=MTLStoreActionStore;
 enc=[cb renderCommandEncoderWithDescriptor:p];[enc setViewport:(MTLViewport){(double)x,(double)y,(double)w,(double)h,0,1}];[enc setScissorRect:(MTLScissorRect){(NSUInteger)x,(NSUInteger)y,(NSUInteger)w,(NSUInteger)h}];
#if POST_BLOOM_OLD
 float rect[4]={(float)x/scene.w,(float)y/scene.h,(float)w/scene.w,(float)h/scene.h};auto sd=[MTLSamplerDescriptor new];sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
 [enc setRenderPipelineState:old_pipeline];[enc setVertexBytes:rect length:16 atIndex:0];[enc setFragmentTexture:s atIndex:0];[enc setFragmentSamplerState:[mtl_device newSamplerStateWithDescriptor:sd] atIndex:0];[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
#else
 check(MTL_BloomComposite(enc,s,e,MTLPixelFormatRGBA8Unorm,MTLPixelFormatInvalid,1,x,y,w,h,debug,enabled),"production composite encodes");
#endif
 [enc endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error)fatal(name,cb.error);
 auto actual=read(out,4);auto expected=composite(scene,emission,chain,x,y,w,h,debug,enabled,intensity);bool good=true;int maxdiff=0;for(size_t i=0;i<expected.p.size();i++)for(int q=0;q<4;q++){int diff=abs(actual[i*4+q]-(int)roundf(expected.p[i][q]*255));maxdiff=std::max(maxdiff,diff);good&=diff<=1;}
 largest_byte_difference=std::max(largest_byte_difference,maxdiff);
 if(!good)fprintf(stderr,"  %s composite max byte difference %d\n",name,maxdiff);check(good,name);
#if !POST_BLOOM_OLD
 bool all=true;float maxerror=0;check(mtl_bloom.nlevels==(int)chain.size(),"runtime mip count follows radius and integer view halves");
 for(size_t n=0;n<chain.size();n++){auto data=read(mtl_bloom.level[n],8);auto values=(const _Float16 *)data.data();for(size_t i=0;i<chain[n].p.size();i++)for(int q=0;q<3;q++){float error=fabsf((float)values[i*4+q]-chain[n].p[i][q]);maxerror=std::max(maxerror,error);all&=error<=.007f;}}
 largest_mip_difference=std::max(largest_mip_difference,maxerror);
 if(!all)fprintf(stderr,"  %s mip max error %.7f\n",name,maxerror);check(all,"all RGBA16Float mip pixels match independent down/up oracle");
#endif
}
#if !POST_BLOOM_OLD
@interface BloomFailingDevice : NSObject
@property(nonatomic,strong) id<MTLDevice> actual;
@end
@implementation BloomFailingDevice
-(id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d{(void)d;return nil;}
-(id)forwardingTargetForSelector:(SEL)s{(void)s;return self.actual;}
@end
@interface BloomFailingBuffer : NSObject
@end
@implementation BloomFailingBuffer
-(id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d{(void)d;return nil;}
@end
static void resource_cases(){
 set("r_om_bloom_radius",1);set("r_om_bloom_fromscene",0);set("r_om_bloom_intensity",.45f);
 auto s=texture(MTLPixelFormatRGBA8Unorm,65,49),e=texture(MTLPixelFormatRGBA8Unorm,65,49);
 auto cb=[queue commandBuffer];auto p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=s;p.colorAttachments[1].texture=e;
 for(int i=0;i<2;i++){p.colorAttachments[i].loadAction=MTLLoadActionClear;p.colorAttachments[i].storeAction=MTLStoreActionStore;p.colorAttachments[i].clearColor=MTLClearColorMake(.2,.3,.4,1);}
 auto enc=[cb renderCommandEncoderWithDescriptor:p];[enc endEncoding];check(MTL_BloomProcess(cb,s,e,0,0,65,49,YES),"known-good resources establish previous bloom chain");[cb commit];[cb waitUntilCompleted];if(cb.error)fatal("resource setup",cb.error);
 auto old=mtl_bloom.level[0];int count=mtl_bloom.nlevels;auto s2=texture(MTLPixelFormatRGBA8Unorm,129,97),e2=texture(MTLPixelFormatRGBA8Unorm,129,97);
 auto actual=mtl_device;BloomFailingDevice *bad=[BloomFailingDevice new];bad.actual=actual;mtl_device=(id<MTLDevice>)bad;cb=[queue commandBuffer];
 check(!MTL_BloomProcess(cb,s2,e2,0,0,129,97,YES),"allocation failure rejects changed chain");
 check(!mtl_bloom.ready&&mtl_bloom.level[0]==old&&mtl_bloom.nlevels==count,"allocation failure preserves complete old resources without exposing stale bloom");mtl_device=actual;
 check(!MTL_BloomProcess((id<MTLCommandBuffer>)[BloomFailingBuffer new],s,e,0,0,65,49,YES)&&!mtl_bloom.ready,"failed native render encoder disables partial bloom");
 check(!MTL_BloomProcess(cb,s,e,-1,0,65,49,YES)&&!mtl_bloom.ready,"invalid physical view cannot expose previous bloom");
 auto out=texture(MTLPixelFormatRGBA8Unorm,65,49),depth=texture(MTLPixelFormatDepth32Float,65,49);
 p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=out;p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;p.depthAttachment.texture=depth;p.depthAttachment.loadAction=MTLLoadActionClear;p.depthAttachment.storeAction=MTLStoreActionStore;p.depthAttachment.clearDepth=.37;
 enc=[cb renderCommandEncoderWithDescriptor:p];[enc setViewport:(MTLViewport){7,9,31,23,0,1}];[enc setScissorRect:(MTLScissorRect){7,9,31,23}];
 check(MTL_BloomComposite(enc,s,e,MTLPixelFormatRGBA8Unorm,MTLPixelFormatDepth32Float,1,7,9,31,23,2,YES),"unready bloom uses scene fallback with actual depth attachment");[enc endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error)fatal("resource fallback",cb.error);
 auto data=read(depth,4);bool preserved=true;for(size_t i=0;i<data.size()/4;i++)preserved&=fabsf(((const float *)data.data())[i]-.37f)<1e-6f;check(preserved,"composite leaves every window-depth pixel unchanged");
 auto pixels=read(out,4);const auto at=pixels.data()+(15*65+15)*4;check(abs(at[0]-51)<=1&&abs(at[1]-77)<=1&&abs(at[2]-102)<=1,"failed bloom never samples previous frame in debug2 fallback");
 check(MTL_BloomCompositePipeline(MTLPixelFormatBGRA8Unorm,MTLPixelFormatDepth32Float,1),"native window BGRA/depth format pipeline key");
 for(NSUInteger samples:{2,4,8})if([mtl_device supportsTextureSampleCount:samples])check(MTL_BloomCompositePipeline(MTLPixelFormatBGRA8Unorm,MTLPixelFormatDepth32Float,samples),"compositor pipeline follows supported sample key");
}
#endif
int main(){@autoreleasepool{
 mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 77;queue=[mtl_device newCommandQueue];init_pipelines();
#if !POST_BLOOM_OLD
 MTL_BloomInit();check(get_cvar("r_om_bloom_threshold","1",0)->value==0&&get_cvar("r_om_bloom_radius","0",0)->value==1&&get_cvar("r_om_bloom_intensity","0",0)->value==.45f&&get_cvar("r_om_bloom_fromscene","1",0)->value==0,"current GPL bloom defaults");
 int ws[7],hs[7];check(MTL_PostBloomLayout(7,7,1,ws,hs)==0,"too-small view has no invalid mip");check(MTL_PostBloomLayout(31,23,1,ws,hs)==2&&ws[0]==15&&hs[0]==11&&ws[1]==7&&hs[1]==5,"odd view uses truncated integer halves");check(MTL_PostBloomLayout(1025,1025,100,ws,hs)==7&&ws[6]==8,"radius caps full chain at seven levels");check(MTL_PostBloomLayout(1025,1025,-4,ws,hs)==4,"negative radius uses reference minimum radius0");check(MTL_PostOverbright(1,.5f,0)==1&&MTL_PostOverbright(1,8,0)==4&&MTL_PostOverbright(1,2,1)==1&&MTL_PostOverbright(0,2,0)==1,"overbright clamp/disable/nightvision reference controls");
#endif
 Image scene(257,193,{.1f,.15f,.2f,1}),emission(257,193,{.2f,.1f,.05f,1});
 run_case("constant field preserves energy across five mips",scene,emission,0,0,257,193);
 run_case("intensity0 is exact LDR scene with no gamma",scene,emission,0,0,257,193,1,0,false,0,true,0);
 run_case("negative knee clamps to0",scene,emission,0,0,257,193,1,-1);
 run_case("knee suppresses each channel independently",scene,emission,0,0,257,193,1,.12f);
 run_case("knee clamps at .95",scene,Image(257,193,{1,.96f,.9f,1}),0,0,257,193,1,10);
 run_case("scene source uses maxRGB .8 luminance gate",Image(257,193,{.9f,.5f,.2f,1}),emission,0,0,257,193,1,.95f,true);
 run_case("scene below luminance gate emits zero",Image(257,193,{.79f,.4f,.2f,1}),emission,0,0,257,193,1,0,true);
 run_case("emission debug1 exact source",scene,emission,0,0,257,193,1,0,false,1);
 run_case("bloom debug2 uses intensity",scene,emission,0,0,257,193,1,0,false,2);
 run_case("disabled bloom debug2 falls back to scene",scene,emission,0,0,257,193,1,0,false,2,false);
 run_case("disabled bloom still supports emission debug1",scene,emission,0,0,257,193,1,0,false,1,false);
 Image odd(63,47,{.04f,.08f,.12f,1}),edge(63,47,{4,2,1,1});for(int y=9;y<32;y++)for(int x=7;x<38;x++)edge.at(x,y)={0,0,0,1};
 run_case("reduced odd viewport rejects bright neighboring UI",odd,edge,7,9,31,23);
 edge.at(7,9)={1,.5f,.1f,1};edge.at(22,20)={.2f,.7f,1,1};edge.at(37,31)={1,.2f,.6f,1};run_case("colored impulses preserve native view orientation and edge clamps",odd,edge,7,9,31,23);
 run_case("resize and radius change recreate complete seven-level chain",Image(1025,1025,{0,0,0,1}),Image(1025,1025,{.1f,.2f,.3f,1}),0,0,1025,1025,7);
 run_case("same-size radius runtime change rebuilds to four levels",scene,emission,0,0,257,193,0);
 run_case("LDR target saturates before floating-point blur",Image(63,47,{.1f,.2f,.3f,1}),Image(63,47,{4,2,.5f,1}),0,0,63,47);
 run_case("tiny view has scene fallback without sampling stale chain",Image(17,15,{.1f,.2f,.3f,1}),Image(17,15,{1,1,1,1}),2,3,7,7);
#if !POST_BLOOM_OLD
 resource_cases();
 MTL_BloomShutdown();check(!mtl_bloom.ready&&!mtl_bloom.level[0],"shutdown retires all bloom resources");MTL_BloomInit();check(!mtl_bloom.ready&&!mtl_bloom.level[0],"restart exposes no previous-frame bloom");MTL_BloomShutdown();
#endif
 printf("Largest composite byte difference: %d; largest mip linear difference: %.7f\n",largest_byte_difference,largest_mip_difference);
 printf("Bloom CPU/GPU checks: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
}}
