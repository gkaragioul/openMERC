// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 liquids, SPEC-AMEND-006 I4c.1.
// Include in Objective-C after mtl_device, mtl_layer and MTL_Fatal.
static NSString *const mtl_liquid_shader = @R"MSL(
#include <metal_stdlib>
using namespace metal;
struct LiquidVertex { float3 pos; float2 uv; float4 color; };
struct LiquidOutput { float4 pos [[position]]; float2 uv; float4 color; };
vertex LiquidOutput mtl_vs_liquid(const device LiquidVertex *v [[buffer(0)]],
 constant float4x4 &mvp [[buffer(1)]], uint i [[vertex_id]]) {
 LiquidOutput o; o.pos=mvp*float4(v[i].pos,1);o.uv=v[i].uv;o.color=v[i].color;return o;
}
fragment OMPostOutput mtl_fs_liquid(LiquidOutput in [[stage_in]],
 texture2d<float> tex [[texture(0)]],sampler smp [[sampler(0)]]) {
 float4 c=tex.sample(smp,in.uv)*in.color;
 if(c.a<=.05)discard_fragment();return OM_PostDefault(c);
}
fragment OMPostOutput mtl_fs_liquid_env(LiquidOutput in [[stage_in]],
 texture2d<float> tex [[texture(0)]],sampler smp [[sampler(0)]],
 constant OMPostUniforms &post [[buffer(3)]]) {
 float4 c=tex.sample(smp,in.uv); // base image again, no alpha test
 return OM_PostFragment(c,c.rgb,post.emission);
}
)MSL";

static id<MTLRenderPipelineState> MTL_BuildLiquidPipeline(int pass,int translucent)
{
 mtl_pipeline_targets_t targets=MTL_PostPipelineTargets();
 id<MTLRenderPipelineState> cached=MTL_PostPipelineCached(MTL_POST_PIPE_LIQUID,translucent,pass,&targets);
 if(cached)return cached;
 NSError *error=nil;
 id<MTLLibrary> lib=[mtl_device newLibraryWithSource:MTL_PostShaderSource(mtl_liquid_shader,&targets) options:nil error:&error];
 if(!lib){MTL_Fatal("MSL compile (liquid)",error.localizedDescription.UTF8String);return nil;}
 MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
 d.label=pass?@"openMerc liquid sphere base image":@"openMerc SoF liquid";
 d.vertexFunction=[lib newFunctionWithName:@"mtl_vs_liquid"];
 d.fragmentFunction=[lib newFunctionWithName:pass?@"mtl_fs_liquid_env":@"mtl_fs_liquid"];
 d.colorAttachments[0].pixelFormat=mtl_layer.pixelFormat;
 d.colorAttachments[0].blendingEnabled=translucent!=0;
 if(translucent){
  d.colorAttachments[0].sourceRGBBlendFactor=pass?MTLBlendFactorDestinationColor:MTLBlendFactorSourceAlpha;
  d.colorAttachments[0].destinationRGBBlendFactor=pass?MTLBlendFactorSourceColor:MTLBlendFactorOneMinusSourceAlpha;
  d.colorAttachments[0].sourceAlphaBlendFactor=pass?MTLBlendFactorDestinationAlpha:MTLBlendFactorSourceAlpha;
  d.colorAttachments[0].destinationAlphaBlendFactor=pass?MTLBlendFactorSourceAlpha:MTLBlendFactorOneMinusSourceAlpha;
 }
 d.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
 MTL_PostConfigurePipeline(d,&targets);
 id<MTLRenderPipelineState> pipeline=[mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
 if(!pipeline)MTL_Fatal("liquid pipeline",error.localizedDescription.UTF8String);
 MTL_PostPipelineStore(MTL_POST_PIPE_LIQUID,translucent,pass,&targets,pipeline);
 return pipeline;
}
