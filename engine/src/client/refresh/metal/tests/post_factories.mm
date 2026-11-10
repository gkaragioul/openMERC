// SPDX-License-Identifier: GPL-2.0-or-later
// Existing material controls plus every non-world production pipeline variant.
#define main MaterialRegressionMain
#include "material_state.mm"
#undef main
#include <initializer_list>
#include "mtl_post_math.h"
#include "mtl_fx_geometry.h"
static struct {float vieworg[3];} mtl_refdef;
static struct {float value;} factory_units,factory_factor;
static auto *mtl_offset_units_cvar=&factory_units,*mtl_offset_factor_cvar=&factory_factor;
static id<MTLDepthStencilState> mtl_depth_readonly;
static id<MTLSamplerState> mtl_samp_world;
static id<MTLRenderPipelineState> mtl_pipe_fx_darken;
static mtl_post_emission_controls_t MTL_PostEmissionControls(void)
{return (mtl_post_emission_controls_t){1,1,.5f,1,.3f};}
#include "post_factories_production.h"
#include "../mtl_liquid_shader.h"
static int factory_checks;
static void factory_check(bool pass,const char *label)
{factory_checks++;if(!pass){fprintf(stderr,"FAIL factory: %s\n",label);failures++;}}
static id<MTLRenderPipelineState> select_factory(int kind,int blend,int fragment)
{
	if(kind==0)return MTL_BuildAliasPipeline(blend,fragment);
	if(kind==1)return MTL_BuildParticlePipeline();
	if(kind==2)return MTL_BuildTurbPipeline(blend);
	if(kind==3)return MTL_BuildLiquidPipeline(fragment,blend);
	if(kind==5)return MTL_BuildWorldPipeline();
	if(kind==6)return MTL_BuildSkyPipeline();
	return MTL_GenericModelPipeline(blend);
}
static float blend_channel(float source,float destination,float alpha,int blend)
{
	if(blend==1)return source*alpha+destination*(1-alpha);
	if(blend==2)return fminf(source+destination,1);
	if(blend==3)return destination*source*2;
	if(blend==4)return destination*(1-source);
	return source;
}
static id<MTLTexture> make_target(MTLPixelFormat format,NSUInteger samples)
{
	MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:16 height:16 mipmapped:NO];
	d.storageMode=samples>1?MTLStorageModePrivate:MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget;
	if(samples>1){d.textureType=MTLTextureType2DMultisample;d.sampleCount=samples;}
	return [mtl_device newTextureWithDescriptor:d];
}
static void check_rgb(id<MTLTexture> texture,const float expected[3],const char *label)
{
	byte pixels[16*16*4];[texture getBytes:pixels bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,16) mipmapLevel:0];
	byte *p=pixels+(8*16+8)*4;bool bgra=texture.pixelFormat==MTLPixelFormatBGRA8Unorm;
	int got[3]={p[bgra?2:0],p[1],p[bgra?0:2]};bool pass=true;
	for(int k=0;k<3;k++)pass&=abs(got[k]-(int)lroundf(expected[k]*255))<=1;
	if(!pass)fprintf(stderr,"%s RGB%d,%d,%d expected%g,%g,%g\n",label,got[0],got[1],got[2],expected[0]*255,expected[1]*255,expected[2]*255);
	factory_check(pass,label);
}
static void factory_pixel(int kind,int blend,int fragment,bool mrt,NSUInteger samples)
{
	char name[96];snprintf(name,sizeof(name),"kind%d blend%d fragment%d MRT%d samples%lu",kind,blend,fragment,mrt,(unsigned long)samples);
	mtl_test_pipeline_targets={mrt?2u:1u,samples,MTLPixelFormatBGRA8Unorm,mrt?MTLPixelFormatRGBA8Unorm:MTLPixelFormatInvalid};
	id<MTLRenderPipelineState> state=select_factory(kind,blend,fragment);
	factory_check(state && state==select_factory(kind,blend,fragment),"identical actual format/sample/fragment key reuses native pipeline");
	id<MTLTexture> scene=make_target(MTLPixelFormatBGRA8Unorm,1),emis=make_target(MTLPixelFormatRGBA8Unorm,1);
	MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture=samples>1?make_target(MTLPixelFormatBGRA8Unorm,samples):scene;
	pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=samples>1?MTLStoreActionMultisampleResolve:MTLStoreActionStore;
	pass.colorAttachments[0].clearColor=MTLClearColorMake(.25,.25,.25,.25);if(samples>1)pass.colorAttachments[0].resolveTexture=scene;
	if(mrt){pass.colorAttachments[1].texture=samples>1?make_target(MTLPixelFormatRGBA8Unorm,samples):emis;pass.colorAttachments[1].loadAction=MTLLoadActionClear;pass.colorAttachments[1].storeAction=samples>1?MTLStoreActionMultisampleResolve:MTLStoreActionStore;pass.colorAttachments[1].clearColor=MTLClearColorMake(.25,.25,.25,.25);if(samples>1)pass.colorAttachments[1].resolveTexture=emis;}
	pass.depthAttachment.texture=make_target(MTLPixelFormatDepth32Float,samples);pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.clearDepth=1;
	id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass];
	[enc setRenderPipelineState:state];[enc setDepthStencilState:mtl_depth_2d];[enc setCullMode:MTLCullModeNone];
	const float xy[3][2]={{-1,-1},{3,-1},{-1,3}};
	mtl_alias_vertex_t alias[3]={};mtl_world_vertex_t turb[3]={};
	for(int i=0;i<3;i++) {
		alias[i].pos[0]=turb[i].pos[0]=xy[i][0];alias[i].pos[1]=turb[i].pos[1]=xy[i][1];alias[i].pos[2]=turb[i].pos[2]=.5;
		alias[i].uv[0]=alias[i].uv[1]=turb[i].uv[0]=turb[i].uv[1]=.5;
		alias[i].color[0]=.8f;alias[i].color[1]=.4f;alias[i].color[2]=.2f;alias[i].color[3]=.25f;
	}
	if(kind==2 || kind>=5)[enc setVertexBytes:turb length:sizeof(turb) atIndex:0];else[enc setVertexBytes:alias length:sizeof(alias) atIndex:0];
	float uniform[24]={};for(int i=0;i<4;i++)uniform[i*5]=1;uniform[17]=.25f;
	[enc setVertexBytes:uniform length:sizeof(uniform) atIndex:1];
	if(kind>=5) {
		mtl_world_uniform_t world={};for(int i=0;i<4;i++)world.mvp[i*5]=1;world.overbright=1;world.fullbright=fragment?1:0;
		[enc setVertexBytes:&world length:sizeof(world) atIndex:1];[enc setFragmentBytes:&world length:sizeof(world) atIndex:1];
		float styles[20]={};styles[0]=styles[1]=styles[2]=1;[enc setFragmentBytes:styles length:sizeof(styles) atIndex:3];
	}
	float parameters[2]={-1,1.5f};[enc setFragmentBytes:parameters length:sizeof(parameters) atIndex:2];
	mtl_post_emission_controls_t controls={1,1,.5f,1,1};
	mtl_emission_t emission={{0,0,0,0}};
	if(kind==0 && fragment==2) emission=blend==MTL_BLEND_DARKEN?MTL_PostEmissionForBlend(3,0,&controls):MTL_PostEmissionForBlend(blend,.5f,&controls);
	if((kind==0 && fragment==1 && blend==MTL_BLEND_DETAIL) || (kind==3 && fragment && blend)) emission=MTL_PostEmissionForBlend(5,0,&controls);
	if(kind==5)emission.value[0]=.5f,emission.value[3]=1;
	if(kind<5)[enc setFragmentBytes:emission.value length:sizeof(emission.value) atIndex:3];else[enc setFragmentBytes:emission.value length:sizeof(emission.value) atIndex:4];
	bool image_only=(kind==0 && fragment==1)||(kind==3 && fragment==1)||kind>=5;
	byte image[4]={255,255,255,255};if(image_only){image[0]=204;image[1]=102;image[2]=51;image[3]=64;}
	MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];td.storageMode=MTLStorageModeShared;
	id<MTLTexture> tex=[mtl_device newTextureWithDescriptor:td];[tex replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:image bytesPerRow:4];
	[enc setFragmentTexture:tex atIndex:0];[enc setFragmentSamplerState:mtl_samp_ui atIndex:0];
	if(kind>=5) {
		byte black_bytes[4]={0,0,0,0},white_bytes[4]={255,255,255,255};
		id<MTLTexture> black=[mtl_device newTextureWithDescriptor:td],white=[mtl_device newTextureWithDescriptor:td];
		[black replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:black_bytes bytesPerRow:4];[white replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:white_bytes bytesPerRow:4];
		[enc setFragmentTexture:white atIndex:1];for(int i=4;i<8;i++)[enc setFragmentTexture:black atIndex:i];
		MTLTextureDescriptor *table_d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:256 height:1 mipmapped:NO];table_d.storageMode=MTLStorageModeShared;
		id<MTLTexture> table=[mtl_device newTextureWithDescriptor:table_d];byte table_bytes[256];for(int i=0;i<256;i++)table_bytes[i]=(byte)i;[table replaceRegion:MTLRegionMake2D(0,0,256,1) mipmapLevel:0 withBytes:table_bytes bytesPerRow:256];[enc setFragmentTexture:table atIndex:2];
		[enc setFragmentSamplerState:mtl_samp_ui atIndex:1];[enc setFragmentSamplerState:mtl_samp_ui atIndex:2];
	}
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[enc endEncoding];[cb commit];[cb waitUntilCompleted];
	if(cb.error)MTL_Fatal(name,cb.error.localizedDescription.UTF8String);
	int actual_blend=blend;
	if(kind==1)actual_blend=1;
	if(kind==2 || kind==4)actual_blend=blend?1:0;
	if(kind==3)actual_blend=blend?(fragment?3:1):0;
	float source[3]={.8f,.4f,.2f},alpha=image_only?64/255.f:.25f;
	if(kind==5)alpha=1;
	if(kind==2)source[0]=source[1]=source[2]=1;
	float expected_scene[3],expected_emission[3];
	for(int k=0;k<3;k++) {
		float glow=emission.value[3]>1.5f?emission.value[k]:(emission.value[3]>.5f?source[k]*emission.value[0]:0);
		expected_scene[k]=blend_channel(source[k],64/255.f,alpha,actual_blend);
		expected_emission[k]=blend_channel(glow,64/255.f,alpha,actual_blend);
	}
	check_rgb(scene,expected_scene,name);if(mrt)check_rgb(emis,expected_emission,name);
}
static void fx_binding_case(int blend)
{
	mtl_test_pipeline_targets={2,1,MTLPixelFormatBGRA8Unorm,MTLPixelFormatRGBA8Unorm};
	// Give retained old caller code compatible MRT pipelines so its missing
	// per-draw binding is measured numerically, independently of factory work.
	mtl_pipe_fx_alpha=MTL_BuildAliasPipeline(1,2);mtl_pipe_fx_additive=MTL_BuildAliasPipeline(2,2);mtl_pipe_fx_darken=MTL_BuildAliasPipeline(MTL_BLEND_DARKEN,2);
	id<MTLTexture> scene=make_target(MTLPixelFormatBGRA8Unorm,1),emission=make_target(MTLPixelFormatRGBA8Unorm,1);
	MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
	for(int i=0;i<2;i++){pass.colorAttachments[i].texture=i?emission:scene;pass.colorAttachments[i].loadAction=MTLLoadActionClear;pass.colorAttachments[i].storeAction=MTLStoreActionStore;pass.colorAttachments[i].clearColor=MTLClearColorMake(.25,.25,.25,.25);}
	pass.depthAttachment.texture=make_target(MTLPixelFormatDepth32Float,1);pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.clearDepth=1;
	id<MTLCommandBuffer> cb=[queue commandBuffer];mtl_enc=[cb renderCommandEncoderWithDescriptor:pass];mtl_encoder_open=true;
	MTL_PostBindEmission((mtl_emission_t){{1,0,0,1}},3); // stale prior additive source
	sofalphaquad_t quad={};quad.flags=SOF_AQ_BILLBOARD;quad.origin[2]=.5f;quad.v0c[0]=quad.v0c[1]=quad.f18=1;
	mtl_image_t image={};image.tex=(__bridge void *)mtl_white;
	float color[4]={.8f,.4f,.2f,.25f};if(blend!=1){color[0]=.2f;color[1]=.1f;color[2]=.05f;color[3]=1;}
	float mvp[16]={};for(int i=0;i<4;i++)mvp[i*5]=1;const float right[3]={1,0,0},up[3]={0,1,0};
	MTL_FXDrawGeometry(&quad,&image,color,blend,0,0,0,mvp,right,up);
	[mtl_enc endEncoding];mtl_encoder_open=false;mtl_enc=nil;[cb commit];[cb waitUntilCompleted];if(cb.error)MTL_Fatal("FX emission binding",cb.error.localizedDescription.UTF8String);
	float expected_scene[3],expected_emission[3];
	for(int k=0;k<3;k++){
		expected_scene[k]=blend_channel(color[k],64/255.f,color[3],blend==3?4:blend);
		expected_emission[k]=blend==1?(64/255.f)*(1-color[3]):(64/255.f)+(blend==2?color[k]*.3f:0);
	}
	check_rgb(scene,expected_scene,"actual FX geometry scene binding");check_rgb(emission,expected_emission,"actual FX geometry replaces stale emission on every draw");
}
int main(void)
{
	int result=MaterialRegressionMain();if(result)return result;
	@autoreleasepool {
		for(NSUInteger samples:{1u,2u,4u,8u}) {
			if(![mtl_device supportsTextureSampleCount:samples])continue;
			printf("Validating production factories at %lux MSAA\n",(unsigned long)samples);
			for(int mrt=0;mrt<2;mrt++) {
				for(int blend=0;blend<3;blend++){factory_pixel(0,blend,0,mrt,samples);factory_pixel(0,blend,2,mrt,samples);}
				factory_pixel(0,MTL_BLEND_DARKEN,2,mrt,samples);factory_pixel(0,MTL_BLEND_DETAIL,1,mrt,samples);factory_pixel(0,0,1,mrt,samples);
				factory_pixel(1,1,0,mrt,samples);
				factory_pixel(5,0,0,mrt,samples);factory_pixel(5,0,1,mrt,samples);factory_pixel(6,0,0,mrt,samples);
				for(int blend=0;blend<2;blend++){factory_pixel(2,blend,0,mrt,samples);factory_pixel(4,blend,0,mrt,samples);for(int p=0;p<2;p++)factory_pixel(3,blend,p,mrt,samples);}
			}
		}
		mtl_depth_readonly=mtl_depth_2d;mtl_samp_world=mtl_samp_ui;
		for(int blend=1;blend<=3;blend++)fx_binding_case(blend);
		mtl_test_pipeline_targets={1,1,MTLPixelFormatBGRA8Unorm,MTLPixelFormatInvalid};id<MTLRenderPipelineState> bgra=MTL_BuildAliasPipeline(0,0);
		mtl_test_pipeline_targets.scene_format=MTLPixelFormatRGBA8Unorm;id<MTLRenderPipelineState> rgba=MTL_BuildAliasPipeline(0,0);
		factory_check(bgra!=rgba,"different scene format never aliases cached pipeline");
		MTL_PostPipelineClear();factory_check(!MTL_PostPipelineCached(MTL_POST_PIPE_ALIAS,0,0,&mtl_test_pipeline_targets),"shutdown clears format/sample pipeline cache");
		printf("Actual renderer factory/binding checks: %d passed, %d failed\n",factory_checks-failures,failures);return failures?1:0;
	}
}
