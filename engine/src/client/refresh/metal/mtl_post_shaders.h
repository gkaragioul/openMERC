// SPDX-License-Identifier: GPL-2.0-or-later
// Shared native single-target/MRT fragment outputs and attachment configuration.
// Implements: SPEC-AMEND-016 modern emission, current GPL gl3_post.c wrapper.
#ifndef OM_METAL_POST_SHADERS_H
#define OM_METAL_POST_SHADERS_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static NSString *const mtl_post_output_msl=@
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct OMPostOutput {\n"
" float4 scene [[color(0)]];\n"
"#if OM_POST_MRT\n"
" float4 emissive [[color(1)]];\n"
"#endif\n"
"};\n"
"struct OMPostUniforms { float4 emission; };\n"
"inline OMPostOutput OM_PostFragment(float4 scene,float3 source,float4 params) {\n"
" OMPostOutput out;out.scene=scene;\n"
"#if OM_POST_MRT\n"
" float3 glow=float3(0);\n"
" if(params.w>1.5) glow=params.xyz;\n"
" else if(params.w>.5) glow=source*params.x;\n"
" out.emissive=float4(glow,scene.a);\n"
"#endif\n"
" return out;\n"
"}\n"
"inline OMPostOutput OM_PostDefault(float4 scene) {\n"
" return OM_PostFragment(scene,scene.rgb,float4(0));\n"
"}\n"
"inline OMPostOutput OM_PostSource(float4 scene,float3 source,float weight) {\n"
" return OM_PostFragment(scene,source,float4(weight,0,0,1));\n"
"}\n";

/* Compile the matching shader variant. A single-target program does not even
 * declare color1; it cannot accidentally require a missing menu attachment. */
static NSString *MTL_PostMSLPreamble(BOOL mrt)
{
	return [NSString stringWithFormat:@"#define OM_POST_OUTPUTS 1\n#define OM_POST_MRT %d\n%@",mrt?1:0,mtl_post_output_msl];
}

/* Call after the factory establishes color0's actual blend factors. Emission
 * must use those same factors, including alpha. This does not choose a shader
 * entry point: the factory must compile the corresponding preamble variant. */
static BOOL
MTL_PostConfigurePipelineTargets(MTLRenderPipelineDescriptor *descriptor,NSUInteger color_count,
	MTLPixelFormat scene_format,MTLPixelFormat emission_format,NSUInteger samples)
{
	if (!descriptor || color_count<1 || color_count>2 || scene_format==MTLPixelFormatInvalid ||
		(color_count==2 && emission_format==MTLPixelFormatInvalid) || !samples) return NO;
	descriptor.rasterSampleCount=samples;
	MTLRenderPipelineColorAttachmentDescriptor *scene=descriptor.colorAttachments[0];
	scene.pixelFormat=scene_format;
	if (color_count==2) {
		MTLRenderPipelineColorAttachmentDescriptor *emission=[scene copy];
		emission.pixelFormat=emission_format;
		descriptor.colorAttachments[1]=emission;
	} else {
		descriptor.colorAttachments[1]=[MTLRenderPipelineColorAttachmentDescriptor new];
		descriptor.colorAttachments[1].pixelFormat=MTLPixelFormatInvalid;
	}
	return YES;
}
#endif
