// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Implements: SPEC-410 legacy polygon/linear fog, SPEC-AMEND-016 glow occlusion.
#ifndef OM_METAL_FOG_SHADERS_H
#define OM_METAL_FOG_SHADERS_H
#include "mtl_post_shaders.h"
static NSString *const mtl_fog_linear_msl=@R"MSL(
struct OMFogLinear { float4 color; float4 plane; float4 params; };
inline float OM_FogDistance(float3 p,constant OMFogLinear &u) {
 return abs(dot(u.plane.xyz,p)+u.plane.w);
}
inline float OM_FogVisibility(float distance,constant OMFogLinear &u) {
 if(u.params.z==0) return 1;
 float denominator=u.params.y-u.params.x;
 if(u.params.w>1.5) { if(denominator==0) return 1; }
 else if(u.params.w>.5) denominator=max(denominator,.0001f);
 else if(abs(denominator)<.0001f) denominator=.0001f;
 return clamp((u.params.y-distance)/denominator,0.0f,1.0f);
}
inline float4 OM_FogApply(float4 scene,float visibility,constant OMFogLinear &u) {
 if(u.params.z!=0) scene.rgb=mix(u.color.rgb,scene.rgb,visibility);
 return scene;
}
)MSL";
static NSString *const mtl_fog_overlay_msl=@R"MSL(
struct OMFogVertex { packed_float3 position; float pad; float4 color; };
struct OMFogVarying { float4 position [[position]]; float3 world; float4 color; };
struct OMFogPixel { float4 eye; float4 params; float4 height; float4 planes[5]; };
vertex OMFogVarying mtl_vs_fog(uint id [[vertex_id]],
 constant OMFogVertex *vertices [[buffer(0)]],constant float4x4 &mvp [[buffer(1)]]) {
 OMFogVarying o;float3 p=float3(vertices[id].position);o.position=mvp*float4(p,1);o.world=p;o.color=vertices[id].color;return o;
}
inline float OM_FogOverlayAlpha(float3 p,float shimmer,constant OMFogPixel &u) {
 float3 d=p-u.eye.xyz;float original=dot(d,d),thickness=original;
 for(int k=0;k<5;k++) {
  if(k>=int(u.height.w)) break;
  float a=dot(u.planes[k].xyz,u.eye.xyz)-u.planes[k].w;
  float b=u.planes[k].w-dot(u.planes[k].xyz,p);
  if(a!=0 && b!=0 && ((a>0)!=(b>0))) continue;
  float squared=a*a+b*b;
  if(squared>0) thickness=min(thickness,original*b*b/squared);
 }
 thickness+=shimmer;
 float alpha=u.params.y!=0?(thickness-u.params.x)/u.params.y:0;
 alpha=clamp(alpha,0.0f,u.params.z);
 if(u.params.w>.5 && u.height.y>0) {float h=(u.height.x-p.z)/u.height.y;alpha*=h*h;}
 return floor(alpha)/255.0f*u.height.z;
}
fragment OMPostOutput mtl_fs_fog(OMFogVarying in [[stage_in]],constant OMFogPixel &u [[buffer(1)]]) {
 float4 color=in.color;if(u.eye.w>.5) color.a=OM_FogOverlayAlpha(in.world,in.color.a,u);
 return OM_PostDefault(color);
}
)MSL";
static id<MTLRenderPipelineState> MTL_FogBuildPipeline(id<MTLDevice> device,
 NSUInteger count,MTLPixelFormat scene,MTLPixelFormat emission,NSUInteger samples)
{
 if(!device||![device supportsTextureSampleCount:samples])return nil;
 NSString *source=[NSString stringWithFormat:@"%@\n%@",MTL_PostMSLPreamble(count>1),mtl_fog_overlay_msl];
 NSError *error=nil;id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
 if(!library){NSLog(@"Metal fog shader: %@",error);return nil;}
 MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
 d.vertexFunction=[library newFunctionWithName:@"mtl_vs_fog"];d.fragmentFunction=[library newFunctionWithName:@"mtl_fs_fog"];
 d.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
 d.colorAttachments[0].blendingEnabled=YES;
 d.colorAttachments[0].sourceRGBBlendFactor=d.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorSourceAlpha;
 d.colorAttachments[0].destinationRGBBlendFactor=d.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
 if(!MTL_PostConfigurePipelineTargets(d,count,scene,emission,samples))return nil;
 id<MTLRenderPipelineState> p=[device newRenderPipelineStateWithDescriptor:d error:&error];if(!p)NSLog(@"Metal fog pipeline: %@",error);return p;
}
#endif
