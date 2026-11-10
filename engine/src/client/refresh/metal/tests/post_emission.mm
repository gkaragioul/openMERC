// SPDX-License-Identifier: GPL-2.0-or-later
// Actual native old FX fragment baseline, then production shared MRT outputs.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include "post_alias_before.h"
#if !OM_POST_OLD
#include "mtl_post_shaders.h"
#include "mtl_post_math.h"
#endif

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static int checks,failures;
static void check(bool pass,const char *label) {checks++;if(!pass){fprintf(stderr,"FAIL: %s\n",label);failures++;}}
static void fatal(NSString *label,NSError *error) {fprintf(stderr,"%s: %s\n",label.UTF8String,error.localizedDescription.UTF8String);abort();}
static void near(float actual,float expected,const char *label) { if(std::fabs(actual-expected)>1e-6f)fprintf(stderr,"%s actual%g expected%g\n",label,actual,expected);check(std::fabs(actual-expected)<=1e-6f,label); }
static id<MTLRenderPipelineState> make_pipeline(int blend,bool mrt)
{
	NSString *vertex=@"\nvertex AliasVSOut test_vertex(uint i [[vertex_id]],constant float4 &color [[buffer(4)]]) { AliasVSOut o;float2 p=float2(i==1?3:-1,i==2?3:-1);o.position=float4(p,.5,1);o.uv=float2(.5);o.color=color;return o;}\n";
	NSString *fragment=@"\nstruct TestPost {float4 emission;float4 source;}; fragment OMPostOutput test_fragment(AliasVSOut in [[stage_in]],texture2d<float> tex [[texture(0)]],sampler smp [[sampler(0)]],constant float &cutoff [[buffer(2)]],constant TestPost &post [[buffer(3)]]) {float4 c=tex.sample(smp,in.uv)*in.color;if(c.a<=cutoff) discard_fragment();if(post.source.w==1)return OM_PostDefault(c);if(post.source.w==2)return OM_PostSource(c,post.source.rgb,post.emission.x);return OM_PostFragment(c,post.source.rgb,post.emission);}\n";
#if OM_POST_OLD
	(void)fragment;
	NSString *source=[post_alias_before stringByAppendingString:vertex];
#else
	NSString *types=@"struct AliasVSOut {float4 position [[position]];float2 uv;float4 color;};\n";
	NSString *source=[NSString stringWithFormat:@"%@\n%@\n%@\n%@",MTL_PostMSLPreamble(mrt),types,vertex,fragment];
#endif
	NSError *error=nil;id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error];
	if(!lib)fatal(@"emission shader",error);
	MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
	pd.vertexFunction=[lib newFunctionWithName:@"test_vertex"];
	pd.fragmentFunction=[lib newFunctionWithName:OM_POST_OLD?@"mtl_fs_fx":@"test_fragment"];
	MTLRenderPipelineColorAttachmentDescriptor *a=pd.colorAttachments[0];
	a.pixelFormat=MTLPixelFormatBGRA8Unorm;a.blendingEnabled=blend!=0;
	if(blend==1) {a.sourceRGBBlendFactor=MTLBlendFactorSourceAlpha;a.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;a.sourceAlphaBlendFactor=MTLBlendFactorSourceAlpha;a.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;}
	if(blend==2) {a.sourceRGBBlendFactor=a.sourceAlphaBlendFactor=MTLBlendFactorOne;a.destinationRGBBlendFactor=a.destinationAlphaBlendFactor=MTLBlendFactorOne;}
	if(blend==3) {a.sourceRGBBlendFactor=a.sourceAlphaBlendFactor=MTLBlendFactorZero;a.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceColor;a.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;}
	if(blend==4) {a.sourceRGBBlendFactor=MTLBlendFactorDestinationColor;a.sourceAlphaBlendFactor=MTLBlendFactorDestinationAlpha;a.destinationRGBBlendFactor=a.destinationAlphaBlendFactor=MTLBlendFactorZero;}
	if(blend==5) {a.sourceRGBBlendFactor=MTLBlendFactorDestinationColor;a.sourceAlphaBlendFactor=MTLBlendFactorDestinationAlpha;a.destinationRGBBlendFactor=MTLBlendFactorSourceColor;a.destinationAlphaBlendFactor=MTLBlendFactorSourceAlpha;}
#if OM_POST_OLD
	if(mrt) {
		MTLRenderPipelineColorAttachmentDescriptor *e=[a copy];e.pixelFormat=MTLPixelFormatRGBA8Unorm;pd.colorAttachments[1]=e;
	}
#else
	check(MTL_PostConfigurePipelineTargets(pd,mrt?2:1,MTLPixelFormatBGRA8Unorm,MTLPixelFormatRGBA8Unorm,1),"production target configuration accepts single/MRT variant");
#endif
	id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];
	if(!pipeline)fatal(@"emission pipeline",error);return pipeline;
}
static id<MTLTexture> texture(MTLPixelFormat format,int size,bool target)
{
	MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:size height:size mipmapped:NO];
	d.storageMode=MTLStorageModeShared;d.usage=target?MTLTextureUsageRenderTarget:MTLTextureUsageShaderRead;return [device newTextureWithDescriptor:d];
}
static void rgb(id<MTLTexture> tex,const float expected[3],const char *label)
{
	unsigned char bytes[8*8*4];[tex getBytes:bytes bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
	const unsigned char *p=bytes+(4*8+4)*4;bool bgra=tex.pixelFormat==MTLPixelFormatBGRA8Unorm;
	int actual[3]={p[bgra?2:0],p[1],p[bgra?0:2]};bool pass=true;
	for(int i=0;i<3;i++)pass&=abs(actual[i]-(int)std::lround(expected[i]*255))<=1;
	if(!pass)fprintf(stderr,"%s actual%d,%d,%d expected%g,%g,%g\n",label,actual[0],actual[1],actual[2],expected[0]*255,expected[1]*255,expected[2]*255);
	check(pass,label);
}
static void pixel(const char *name,int blend,bool mrt,const float color[4],const float source[3],const float emission[4],
	const float expectedScene[3],const float expectedEmission[3],bool discard=false,int helper=0)
{
	id<MTLTexture> scene=texture(MTLPixelFormatBGRA8Unorm,8,true),glow=texture(MTLPixelFormatRGBA8Unorm,8,true),white=texture(MTLPixelFormatRGBA8Unorm,1,false);
	unsigned char rgba[4]={255,255,255,255};[white replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:rgba bytesPerRow:4];
	MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture=scene;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;rp.colorAttachments[0].clearColor=MTLClearColorMake(.25,.25,.25,.25);
	if(mrt) {rp.colorAttachments[1].texture=glow;rp.colorAttachments[1].loadAction=MTLLoadActionClear;rp.colorAttachments[1].storeAction=MTLStoreActionStore;rp.colorAttachments[1].clearColor=MTLClearColorMake(.25,.25,.25,.25);}
	id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:make_pipeline(blend,mrt)];[enc setCullMode:MTLCullModeNone];
	float cutoff=discard?1.0f:-1.0f;float post[8]={emission[0],emission[1],emission[2],emission[3],source[0],source[1],source[2],(float)helper};
	[enc setVertexBytes:color length:16 atIndex:4];[enc setFragmentBytes:&cutoff length:sizeof(cutoff) atIndex:2];[enc setFragmentBytes:post length:sizeof(post) atIndex:3];
	[enc setFragmentTexture:white atIndex:0];MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];[enc setFragmentSamplerState:[device newSamplerStateWithDescriptor:sd] atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.error)fatal(@"emission draw",cb.error);
	rgb(scene,expectedScene,name);if(mrt)rgb(glow,expectedEmission,name);
}
static void math(void)
{
#if !OM_POST_OLD
	mtl_post_emission_controls_t c={1,1,.5f,1,1};
	const float expected[6][4]={{0,0,0,0},{0,0,0,0},{1,0,0,1},{0,0,0,2},{1,1,1,2},{.5f,.5f,.5f,2}};
	for(int blend=0;blend<6;blend++) {mtl_emission_t e=MTL_PostEmissionForBlend(blend,0,&c);for(int k=0;k<4;k++)near(e.value[k],expected[blend][k],"all blend modes have exact neutral/source emission");}
	near(MTL_PostSurfaceEmission(1,0,&c),.35f,"SURF_LIGHT lower source clamp");near(MTL_PostSurfaceEmission(1,500,&c),.5f,"SURF_LIGHT value weight");near(MTL_PostSurfaceEmission(1,2000,&c),1,"SURF_LIGHT upper source clamp");near(MTL_PostSurfaceEmission(0x1000,1000,&c),0,"animation flag alone is not emission");
	for(float source:{.49f,.5f,.8f,2.f}) {mtl_emission_t e=MTL_PostGhoulEmission(0,source,0,0,&c);near(e.value[0],source<.5f?0:fminf(source,1),"Ghoul threshold/cap uses source provenance");}
	mtl_emission_t e=MTL_PostGhoulEmission(2,0,0,0,&c);near(e.value[0],0,"hardware additive base with no source does not inherit FX glow");near(e.value[3],2,"non-source additive Ghoul uses neutral constant");
	e=MTL_PostGhoulEmission(2,.8f,1,.35f,&c);near(e.value[0],0,"specular-only additive pass excludes all source/entity glow");near(e.value[3],2,"specular-only additive pass preserves existing emission");
	e=MTL_PostGhoulEmission(0,0,0,.35f,&c);near(e.value[0],.35f,"entity glow survives material threshold");
	near(MTL_PostEntityGlow(1,0,&c),.35f,"fullbright/glow nonweapon entity weight");near(MTL_PostEntityGlow(1,1,&c),0,"weapon entity excluded from fullbright/glow seed");near(MTL_PostEntityGlow(0,0,&c),0,"ordinary entity has no fullbright/glow seed");
	c.fullbright_scale=2;near(MTL_PostEntityGlow(1,0,&c),.7f,"entity glow scale remains explicit");
	c.surface_scale=2;near(MTL_PostSurfaceEmission(1,500,&c),1,"surface scale follows source clamp");
	c.fx_scale=.3f;e=MTL_PostEmissionForBlend(2,0,&c);near(e.value[0],.3f,"additive FX uses explicit configured scale");
	e=MTL_PostEmissionForBlend(2,.7f,&c);near(e.value[0],.7f,"material source overrides fallback FX scale");
	c.enabled=0;for(int blend=0;blend<6;blend++) {e=MTL_PostEmissionForBlend(blend,1,&c);for(float v:e.value)near(v,0,"disabled bloom suppresses source and neutral overrides");}
	near(MTL_PostEntityGlow(1,0,&c),0,"disabled bloom suppresses entity seed");near(MTL_PostSurfaceEmission(1,1000,&c),0,"disabled bloom suppresses surface seed");
	e=MTL_PostGhoulEmission(2,1,0,1,&c);near(e.value[3],0,"disabled bloom suppresses Ghoul material/entity overrides");
	near(MTL_PostSurfaceEmission(1,1000,nullptr),0,"absent controls are disabled");
	MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.colorAttachments[0].blendingEnabled=YES;pd.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorDestinationColor;pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorSourceColor;pd.colorAttachments[0].writeMask=MTLColorWriteMaskRed;
	check(MTL_PostConfigurePipelineTargets(pd,2,MTLPixelFormatBGRA8Unorm,MTLPixelFormatRGBA8Unorm,2) && pd.rasterSampleCount==2 && pd.colorAttachments[1].sourceRGBBlendFactor==MTLBlendFactorDestinationColor && pd.colorAttachments[1].destinationRGBBlendFactor==MTLBlendFactorSourceColor && pd.colorAttachments[1].writeMask==MTLColorWriteMaskRed,"MRT descriptor copies real blend/write state and sample count");
	check(MTL_PostConfigurePipelineTargets(pd,1,MTLPixelFormatBGRA8Unorm,MTLPixelFormatRGBA8Unorm,1) && pd.colorAttachments[1].pixelFormat==MTLPixelFormatInvalid && !pd.colorAttachments[1].blendingEnabled,"single-target descriptor removes color1 entirely");
	check(!MTL_PostConfigurePipelineTargets(pd,2,MTLPixelFormatBGRA8Unorm,MTLPixelFormatInvalid,1) && pd.colorAttachments[1].pixelFormat==MTLPixelFormatInvalid,"invalid MRT format rejected before descriptor mutation");
	check(!MTL_PostConfigurePipelineTargets(pd,1,MTLPixelFormatBGRA8Unorm,MTLPixelFormatRGBA8Unorm,0) && pd.rasterSampleCount==1,"zero sample count rejected before descriptor mutation");
#endif
}
int main(void)
{
	@autoreleasepool {
		device=MTLCreateSystemDefaultDevice();if(!device)return 77;queue=[device newCommandQueue];math();
		const float color[4]={.8f,.4f,.2f,.25f},source[3]={.8f,.4f,.2f};
		const float none[4]={0,0,0,0},light[4]={.5f,0,0,1},multiply[4]={1,1,1,2},twice[4]={.5f,.5f,.5f,2},dark[4]={0,0,0,2};
		const float plain[3]={.8f,.4f,.2f},alpha[3]={.3875f,.2875f,.2375f},add[3]={1,.65f,.45f},darkScene[3]={.05f,.15f,.2f},mulScene[3]={.2f,.1f,.05f},doubleScene[3]={.4f,.2f,.1f};
		const float zero[3]={0,0,0},quarter[3]={.25f,.25f,.25f},retain[3]={.1875f,.1875f,.1875f},halfSource[3]={.4f,.2f,.1f},alphaSource[3]={.2875f,.2375f,.2125f},addSource[3]={.65f,.45f,.35f};
		for(bool mrt:{false,true}) {
			pixel("ordinary opaque occludes emission",0,mrt,color,source,none,plain,zero);
			pixel("source opaque emits shaded color",0,mrt,color,source,light,plain,halfSource);
			pixel("ordinary translucent occludes emission by scene alpha",1,mrt,color,source,none,alpha,retain);
			pixel("source translucent emits and occludes with scene alpha",1,mrt,color,source,light,alpha,alphaSource);
			pixel("source additive emits without suppressing prior emission",2,mrt,color,source,light,add,addSource);
			pixel("non-source additive/specular leaves emission intact",2,mrt,color,source,dark,add,quarter);
			pixel("darkening neutral keeps emission",3,mrt,color,source,dark,darkScene,quarter);
			pixel("multiply neutral keeps emission",4,mrt,color,source,multiply,mulScene,quarter);
			pixel("double-multiply neutral keeps emission",5,mrt,color,source,twice,doubleScene,quarter);
			pixel("discard leaves both outputs intact",0,mrt,color,source,light,quarter,quarter,true);
			const float fogSource[3]={.2f,.1f,.05f},fogEmission[3]={.1f,.05f,.025f};
			pixel("emission source excludes added fog color",0,mrt,color,fogSource,light,plain,fogEmission);
			pixel("default helper emits black with scene alpha",1,mrt,color,source,light,alpha,retain,false,1);
			pixel("source helper emits actual shaded source",0,mrt,color,source,light,plain,halfSource,false,2);
		}
		printf("Post emission checks: %d passed, %d failed\n",checks-failures,failures);return failures?1:0;
	}
}
