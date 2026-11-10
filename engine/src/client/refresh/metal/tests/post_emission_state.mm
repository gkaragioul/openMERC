// SPDX-License-Identifier: GPL-2.0-or-later
// Actual target snapshot/cvar gate without a window or game process.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
typedef struct {float value;int flags;} cvar_t;
#define CVAR_ARCHIVE 1
#define RDF_NOWORLDMODEL 2
#define RDF_IRGOGGLES 4
static id<MTLDevice> mtl_device;
static CAMetalLayer *mtl_layer;
static id<MTLCommandQueue> queue;
static id<MTLCommandBuffer> mtl_cb;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<CAMetalDrawable> mtl_drawable,mtl_last_drawable;
static bool mtl_encoder_open;
static void *mtl_worldmodel=(void *)1;
static struct {int rdflags;} mtl_refdef;
static cvar_t fullbright;static cvar_t *mtl_fullbright_cvar=&fullbright;
static cvar_t vars[6];static const char *names[6];static int numvars;
static cvar_t *get_cvar(const char *name,const char *value,int flags)
{
	for(int i=0;i<numvars;i++)if(!strcmp(names[i],name))return &vars[i];
	if(numvars==6)abort();names[numvars]=name;vars[numvars]={(float)atof(value),flags};return &vars[numvars++];
}
static struct {cvar_t *(*Cvar_Get)(const char *,const char *,int);} ri={get_cvar};
#include "mtl_targets.h"
#include "mtl_emission_state.h"
static int checks,failures;
static void check(bool pass,const char *label){checks++;if(!pass){failures++;fprintf(stderr,"FAIL %s\n",label);}}
static id<MTLTexture> texture(MTLPixelFormat format)
{
	auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:8 height:8 mipmapped:NO];d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;return [mtl_device newTextureWithDescriptor:d];
}
static void finish(void)
{
	if(mtl_encoder_open)MTL_TargetEnd();
	if(mtl_cb){[mtl_cb commit];[mtl_cb waitUntilCompleted];check(!mtl_cb.error,"state fixture command buffer completes");mtl_cb=nil;}
	MTL_TargetReset();
}
static void begin(int colors)
{
	finish();mtl_cb=[queue commandBuffer];mtl_frame_targets_t target={};
	target.color_count=colors;target.samples=1;target.color[0]=texture(MTLPixelFormatRGBA8Unorm);
	if(colors==2)target.color[1]=texture(MTLPixelFormatRGBA16Float);
	target.viewport={0,0,8,8,0,1};target.scissor={0,0,8,8};target.clear_depth=1;
	check(MTL_TargetOpen(&target,MTLLoadActionClear,MTLLoadActionClear),"state fixture opens actual tracked targets");
}
int main(void)
{
	@autoreleasepool {
		mtl_device=MTLCreateSystemDefaultDevice();if(!mtl_device)return 77;queue=[mtl_device newCommandQueue];mtl_layer=[CAMetalLayer layer];mtl_layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
		MTL_PostEmissionInit();check(numvars==6,"six actual source/debug cvars registered");
		check(mtl_bloom_enable_cvar->value==1 && mtl_post_debug_cvar->value==0 && mtl_bloom_surface_cvar->value==1 && mtl_bloom_ghoulmin_cvar->value==.5f && mtl_bloom_fullbright_cvar->value==1 && mtl_bloom_fx_cvar->value==1,"registered source defaults match current GPL");
		check(mtl_bloom_enable_cvar->flags==CVAR_ARCHIVE && mtl_post_debug_cvar->flags==0 && mtl_bloom_fx_cvar->flags==CVAR_ARCHIVE,"debug/source archive policies match GPL");
		begin(1);check(!MTL_PostEmissionControls().enabled,"single-target menu cannot emit even with bloom enabled");
		begin(2);check(MTL_PostEmissionControls().enabled,"world MRT enables ordinary bloom source state");
		mtl_pipeline_targets_t targets=MTL_PostPipelineTargets();check(targets.color_count==2 && targets.samples==1 && targets.scene_format==MTLPixelFormatRGBA8Unorm && targets.emission_format==MTLPixelFormatRGBA16Float,"pipeline snapshot reads actual formats rather than layer defaults");
		mtl_fullbright_cvar->value=1;check(!MTL_PostEmissionControls().enabled,"fullbright bypass suppresses normal bloom seed");
		mtl_post_debug_cvar->value=1;check(MTL_PostEmissionControls().enabled,"debug emission remains available in fullbright");
		mtl_fullbright_cvar->value=0;mtl_refdef.rdflags=RDF_IRGOGGLES;mtl_post_debug_cvar->value=0;check(!MTL_PostEmissionControls().enabled,"nightvision bypass suppresses normal bloom seed");
		mtl_post_debug_cvar->value=2;check(MTL_PostEmissionControls().enabled,"post debug matches reference emission activation in nightvision");
		mtl_refdef.rdflags=RDF_NOWORLDMODEL;check(!MTL_PostEmissionControls().enabled,"NOWORLDMODEL bypass wins over debug");
		mtl_refdef.rdflags=0;mtl_worldmodel=nullptr;check(!MTL_PostEmissionControls().enabled,"missing world bypass wins over debug");mtl_worldmodel=(void *)1;
		mtl_post_debug_cvar->value=0;mtl_bloom_enable_cvar->value=0;check(!MTL_PostEmissionControls().enabled,"soft-only MRT does not seed bloom");
		mtl_post_debug_cvar->value=1;check(MTL_PostEmissionControls().enabled,"emission debug activates with bloom cvar disabled");
		mtl_bloom_surface_cvar->value=.7f;mtl_bloom_ghoulmin_cvar->value=.8f;mtl_bloom_fullbright_cvar->value=2;mtl_bloom_fx_cvar->value=.3f;
		mtl_post_emission_controls_t c=MTL_PostEmissionControls();check(c.surface_scale==.7f && c.ghoul_min==.8f && c.fullbright_scale==2 && c.fx_scale==.3f,"live source controls are read without shader or model reload");
		MTL_PostEmissionViewState(YES,NO);check(!MTL_PostEmissionControls().enabled,"actual source-resource/activation decision overrides requested cvars");
		MTL_PostEmissionViewState(YES,YES);check(MTL_PostEmissionControls().enabled,"accepted framegraph source activation enables eligible MRT view");
		MTL_PostEmissionViewState(NO,YES);check(!MTL_PostEmissionControls().enabled,"ended framegraph view cannot leave sources enabled");
		finish();targets=MTL_PostPipelineTargets();check(targets.color_count==1 && targets.samples==1 && targets.scene_format==MTLPixelFormatBGRA8Unorm && targets.emission_format==MTLPixelFormatInvalid,"untracked target fallback is single layer format and sample1");
		MTL_PostEmissionShutdown();check(!mtl_bloom_enable_cvar && !mtl_post_debug_cvar && !mtl_bloom_fx_cvar,"shutdown clears emission-owned state");
		printf("Actual emission-state checks: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
	}
}
