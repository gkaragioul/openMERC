// SPDX-License-Identifier: GPL-2.0-or-later
// Reuse all 100 production readback cases, then distinguish world MRT from
// the drawable. No window/game launch is involved.
#define main MenuReadbackLegacyMain
#include "menu_readback.mm"
#undef main
#include "mtl_targets.h"

static id<MTLRenderPipelineState> window_pipeline;
static id<MTLRenderPipelineState> mrt_pipeline[3];

static id<MTLTexture> target_texture(MTLPixelFormat format,NSUInteger samples=1)
{
	MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:24 height:16 mipmapped:NO];
	td.storageMode=MTLStorageModePrivate;
	td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
	if(samples>1) { td.textureType=MTLTextureType2DMultisample; td.sampleCount=samples; }
	return [mtl_device newTextureWithDescriptor:td];
}
static void target_pixels(id<MTLTexture> texture,unsigned char out[24*16*4])
{
	id<MTLBuffer> buffer=[mtl_device newBufferWithLength:256*16 options:MTLResourceStorageModeShared];
	id<MTLCommandBuffer> cb=[mtl_queue commandBuffer];
	id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
	[blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
		sourceSize:MTLSizeMake(24,16,1) toBuffer:buffer destinationOffset:0
		destinationBytesPerRow:256 destinationBytesPerImage:256*16];
	[blit endEncoding]; [cb commit]; completed(cb);
	const unsigned char *source=(const unsigned char *)buffer.contents;
	bool bgra=texture.pixelFormat==MTLPixelFormatBGRA8Unorm;
	for(int y=0;y<16;y++) for(int x=0;x<24;x++) {
		const unsigned char *s=source+y*256+x*4;
		unsigned char *p=out+(y*24+x)*4;
		p[0]=s[bgra?2:0];p[1]=s[1];p[2]=s[bgra?0:2];p[3]=255;
	}
}
static void make_mrt_pipeline(NSUInteger samples)
{
	NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nstruct V { packed_float3 p; }; struct O { float4 p [[position]]; }; struct R { float4 scene [[color(0)]]; float4 emission [[color(1)]]; }; vertex O vert(uint i [[vertex_id]],constant V *v [[buffer(0)]]) { O o; o.p=float4(float3(v[i].p),1);return o;} fragment R frag(constant float4 &c [[buffer(0)]]) { R r;r.scene=c;r.emission=float4(c.g,c.b,c.r,c.a);return r;}";
	NSError *error=nil;
	id<MTLLibrary> lib=[mtl_device newLibraryWithSource:source options:nil error:&error];
	if(!lib) { fprintf(stderr,"MRT shader: %s\n",error.localizedDescription.UTF8String);abort(); }
	MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
	pd.vertexFunction=[lib newFunctionWithName:@"vert"];pd.fragmentFunction=[lib newFunctionWithName:@"frag"];
	pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[1].pixelFormat=MTLPixelFormatRGBA8Unorm;
	pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;pd.rasterSampleCount=samples;
	mrt_pipeline[samples]=[mtl_device newRenderPipelineStateWithDescriptor:pd error:&error];
	if(!mrt_pipeline[samples]) { fprintf(stderr,"MRT pipeline: %s\n",error.localizedDescription.UTF8String);abort(); }
}
static void world_targets(NSUInteger samples)
{
	const unsigned char red[4]={255,0,0,255},green[4]={0,255,0,255},blue[4]={0,0,255,255},yellow[4]={255,255,0,255};
	unsigned char shot[24*16*4],scene[sizeof(shot)],emission[sizeof(shot)],window[sizeof(shot)];
	pipeline=window_pipeline;begin(24,16);rect(0,0,24,16,.5f,red);
	MTL_TargetEnd(); // root retains the drawable and its depth separately
	mtl_frame_targets_t targets={};
	targets.color_count=2;targets.samples=samples;
	targets.color[0]=target_texture(MTLPixelFormatBGRA8Unorm,samples);
	targets.color[1]=target_texture(MTLPixelFormatRGBA8Unorm,samples);
	targets.depth=target_texture(MTLPixelFormatDepth32Float,samples);
	if(samples>1) {
		targets.resolve[0]=target_texture(MTLPixelFormatBGRA8Unorm);
		targets.resolve[1]=target_texture(MTLPixelFormatRGBA8Unorm);
	}
	targets.viewport={0,0,24,16,0,1};targets.scissor={0,0,24,16};
	targets.clear_color[0]=MTLClearColorMake(0,.25,0,1);
	targets.clear_color[1]=MTLClearColorMake(0,0,.25,1);targets.clear_depth=1;
	check(MTL_TargetOpen(&targets,MTLLoadActionClear,MTLLoadActionClear),"world MRT target opens with distinct world depth");
	check(MTL_TargetTracked(),"world MRT encoder is tracked");
	[mtl_enc setViewport:(MTLViewport){5,3,12,10,0,1}];
	MTL_TargetRecordViewport((MTLViewport){5,3,12,10,0,1});
	[mtl_enc setScissorRect:(MTLScissorRect){7,5,7,6}];
	MTL_TargetRecordScissor((MTLScissorRect){7,5,7,6});
	pipeline=mrt_pipeline[samples];rect(0,0,12,16,.2f,red);rect(12,0,12,16,.6f,green);
	read_thumbnail(shot,24,16);
	pixel(shot,24,8,16-1-7,255,0,0,"thumbnail reads current world scene, not red window (near)");
	pixel(shot,24,13,16-1-7,0,255,0,"thumbnail reads current world scene, not red window (far)");
	check(MTL_TargetTracked(),"thumbnail continuation stays in tracked MRT");
	// A retained old drain resumes the one-color window. Use its compatible
	// pipeline so the baseline yields numeric evidence instead of GPU abort.
	pipeline=MTL_TargetTracked()?mrt_pipeline[samples]:window_pipeline;
	rect(0,0,24,16,.5f,blue);
	read_thumbnail(shot,24,16);
	pixel(shot,24,8,16-1-7,255,0,0,"world continuation retains near depth");
	pixel(shot,24,13,16-1-7,0,0,255,"world continuation uses stored far depth");
	pixel(shot,24,6,16-1-7,0,64,0,"world continuation retains physical scissor");
	model_fence();check(MTL_TargetTracked(),"model fence resumes tracked MRT");
	pipeline=MTL_TargetTracked()?mrt_pipeline[samples]:window_pipeline;
	rect(0,0,24,16,.4f,yellow);
	// Fully clipped menu/world work is a valid encoder state, including
	// physical origins exactly at the target's right/bottom edge.
	[mtl_enc setScissorRect:(MTLScissorRect){24,16,0,0}];
	MTL_TargetRecordScissor((MTLScissorRect){24,16,0,0});
	model_fence();
	check(MTL_TargetTracked() && mtl_current_targets.scissor.width==0 &&
		mtl_current_targets.scissor.x==24,"zero-area physical clip survives fence without abort");
	MTL_TargetEnd();id<MTLCommandBuffer> cb=mtl_cb;[cb commit];completed(cb);mtl_cb=nil;
	target_pixels(samples>1?targets.resolve[0]:targets.color[0],scene);
	target_pixels(samples>1?targets.resolve[1]:targets.color[1],emission);
	target_pixels(mtl_drawable.texture,window);
	pixel(scene,24,8,7,255,0,0,"model fence preserves world near depth");
	pixel(scene,24,13,7,255,255,0,"model fence draws in original reduced viewport");
	pixel(scene,24,15,7,0,64,0,"model fence does not expand viewport/scissor");
	pixel(emission,24,8,7,0,0,255,"first emissive marker survives two readbacks and fence");
	pixel(emission,24,13,7,255,0,255,"continued draw writes second MRT attachment");
	pixel(emission,24,6,7,0,0,64,"emissive clear outside physical clip survives continuation");
	pixel(window,24,13,7,255,0,0,"MRT readback and fence leave window untouched");
	check(presents==0,"MRT drain never presents");
	check(dispatch_semaphore_wait(mtl_inflight,DISPATCH_TIME_NOW)!=0,"MRT drain retains frame semaphore ownership");
	mtl_last_drawable=mtl_drawable;mtl_drawable=nil;MTL_TargetReset();
}
static void rejected_targets(void)
{
	pipeline=window_pipeline;begin(24,16);
	id<MTLRenderCommandEncoder> encoder=mtl_enc;
	id<MTLCommandBuffer> buffer=mtl_cb;
	mtl_frame_targets_t invalid={};invalid.color_count=2;invalid.samples=1;
	invalid.color[0]=mtl_drawable.texture;invalid.depth=mtl_depth;
	invalid.viewport={0,0,24,16,0,1};invalid.scissor={0,0,24,16};
	check(!MTL_TargetCreateEncoder([mtl_queue commandBuffer],&invalid,MTLLoadActionLoad,MTLLoadActionLoad),"missing second attachment rejected before disturbing original");
	check(mtl_enc==encoder && mtl_cb==buffer && mtl_encoder_open,"rejected target creation keeps original encoder usable");
	invalid.color_count=1;invalid.scissor={23,0,2,16};
	check(!MTL_TargetValid(&invalid),"out-of-bounds scissor rejected without Metal validation abort");
	invalid.scissor={24,16,0,0};
	check(MTL_TargetValid(&invalid),"fully clipped physical target remains valid");
	invalid.scissor={0,0,24,16};invalid.viewport.width=NAN;
	check(!MTL_TargetValid(&invalid),"nonfinite viewport rejected without Metal validation abort");
	finish();MTL_TargetReset();
}
static void failed_continuation(void)
{
	pipeline=window_pipeline;begin(24,16);MTL_TargetEnd();
	mtl_frame_targets_t targets={};targets.color_count=2;targets.samples=1;
	targets.color[0]=target_texture(MTLPixelFormatBGRA8Unorm);
	targets.color[1]=target_texture(MTLPixelFormatRGBA8Unorm);
	targets.depth=target_texture(MTLPixelFormatDepth32Float);
	targets.viewport={0,0,24,16,0,1};targets.scissor={0,0,24,16};targets.clear_depth=1;
	check(MTL_TargetOpen(&targets,MTLLoadActionClear,MTLLoadActionClear),"continuation-failure fixture opens MRT");
	id<MTLRenderCommandEncoder> encoder=mtl_enc;id<MTLCommandBuffer> buffer=mtl_cb;
	mtl_current_targets.color[1]=nil; // deterministic preparation failure
	check(!MTL_ReadbackDrain(nil,nil,0),"invalid continuation is rejected before drain");
	check(mtl_enc==encoder && mtl_cb==buffer && mtl_encoder_open,"failed continuation preserves original active encoder and command buffer");
	mtl_current_targets=targets;MTL_TargetEnd();[mtl_cb commit];completed(mtl_cb);mtl_cb=nil;
	mtl_drawable=nil;MTL_TargetReset();
}
static void unresolved_msaa_fence(void)
{
	const unsigned char red[4]={255,0,0,255},green[4]={0,255,0,255},blue[4]={0,0,255,255};
	unsigned char shot[24*16*4],scene[sizeof(shot)],emission[sizeof(shot)];
	pipeline=window_pipeline;begin(24,16);MTL_TargetEnd();
	mtl_frame_targets_t targets={};targets.color_count=2;targets.samples=2;
	targets.color[0]=target_texture(MTLPixelFormatBGRA8Unorm,2);
	targets.color[1]=target_texture(MTLPixelFormatRGBA8Unorm,2);
	targets.depth=target_texture(MTLPixelFormatDepth32Float,2);
	targets.viewport={0,0,24,16,0,1};targets.scissor={0,0,24,16};targets.clear_depth=1;
	check(MTL_TargetOpen(&targets,MTLLoadActionClear,MTLLoadActionClear),"unresolved MSAA target opens");
	pipeline=mrt_pipeline[2];rect(0,0,12,16,.2f,red);rect(12,0,12,16,.6f,green);
	check(MTL_TargetReadableColor()==nil,"unresolved MSAA does not expose a multisample texture as readable color");
	memset(shot,0x5a,sizeof(shot));read_thumbnail(shot,24,16);
	bool unchanged=true;for(unsigned char c:shot)unchanged&=c==0x5a;
	check(unchanged && mtl_encoder_open,"unresolved thumbnail leaves output and encoder untouched");
	model_fence();check(MTL_TargetTracked(),"unresolved MSAA model fence resumes same attachments");
	pipeline=MTL_TargetTracked()?mrt_pipeline[2]:window_pipeline;rect(0,0,24,16,.5f,blue);
	MTL_TargetEnd();targets.resolve[0]=target_texture(MTLPixelFormatBGRA8Unorm);targets.resolve[1]=target_texture(MTLPixelFormatRGBA8Unorm);
	check(MTL_TargetOpen(&targets,MTLLoadActionLoad,MTLLoadActionLoad),"stored MSAA colors can resolve after the fence");
	MTL_TargetEnd();[mtl_cb commit];completed(mtl_cb);mtl_cb=nil;
	target_pixels(targets.resolve[0],scene);target_pixels(targets.resolve[1],emission);
	pixel(scene,24,6,7,255,0,0,"unresolved fence preserves MSAA near depth");
	pixel(scene,24,18,7,0,0,255,"unresolved fence draws through MSAA far depth");
	pixel(emission,24,18,7,0,255,0,"unresolved fence retains second MSAA color");
	mtl_drawable=nil;MTL_TargetReset();
}
int main(void)
{
	int legacy=MenuReadbackLegacyMain();if(legacy)return legacy;
	@autoreleasepool {
		window_pipeline=pipeline;make_mrt_pipeline(1);world_targets(1);rejected_targets();failed_continuation();
		if([mtl_device supportsTextureSampleCount:2]) { make_mrt_pipeline(2);world_targets(2);unresolved_msaa_fence(); }
		printf("Attachment/readback GPU checks: %d passed, %d failed\n",checks-failures,failures);
		return failures?1:0;
	}
}
