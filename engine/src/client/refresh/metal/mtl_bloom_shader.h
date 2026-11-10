// SPDX-License-Identifier: GPL-2.0-or-later
// Native MSL translation of the current GPL gl3_post.c filters/composite.
// Implements: SPEC-AMEND-016 R16.7. LDR inputs; no gamma or tone mapping.
#ifndef OM_METAL_BLOOM_SHADER_H
#define OM_METAL_BLOOM_SHADER_H
static NSString *const mtl_bloom_shader=@R"MSL(
#include <metal_stdlib>
using namespace metal;
struct BloomOut{float4 position [[position]];float2 uv;float2 vuv;};
struct BloomFilter{float4 rect;float4 clampuv;float2 halfpx;float knee;uint mode;};
struct BloomComposite{float intensity;uint mode;float2 padding;};
vertex BloomOut bloom_v(uint i [[vertex_id]],constant float4 &rect [[buffer(0)]]){
 float2 p=float2(i==1?2:0,i==2?2:0);BloomOut o;
 o.position=float4(2*p.x-1,1-2*p.y,0,1);o.vuv=p;o.uv=rect.xy+p*rect.zw;return o;
}
inline float3 bloom_sample(texture2d<float> tex,sampler s,float2 uv,float4 bounds){return tex.sample(s,clamp(uv,bounds.xy,bounds.zw)).rgb;}
fragment float4 bloom_down(BloomOut in [[stage_in]],texture2d<float> tex [[texture(0)]],sampler s [[sampler(0)]],constant BloomFilter &u [[buffer(0)]]){
 float2 p=in.uv,h=u.halfpx;
 float3 c=bloom_sample(tex,s,p,u.clampuv)*4;
 c+=bloom_sample(tex,s,p-h,u.clampuv)+bloom_sample(tex,s,p+h,u.clampuv);
 c+=bloom_sample(tex,s,p+float2(h.x,-h.y),u.clampuv)+bloom_sample(tex,s,p-float2(h.x,-h.y),u.clampuv);
 c*=.125;
 if(u.mode==1)c=max(c-u.knee,float3(0))/max(1-u.knee,.05f);
 else if(u.mode==2)c*=clamp((max(c.r,max(c.g,c.b))-.8f)*5,0.f,1.f);
 return float4(c,1);
}
fragment float4 bloom_up(BloomOut in [[stage_in]],texture2d<float> tex [[texture(0)]],sampler s [[sampler(0)]],constant BloomFilter &u [[buffer(0)]]){
 float2 p=in.uv,h=u.halfpx;
 float3 c=tex.sample(s,p+float2(-2*h.x,0)).rgb;
 c+=tex.sample(s,p+float2(-h.x,h.y)).rgb*2;
 c+=tex.sample(s,p+float2(0,2*h.y)).rgb;
 c+=tex.sample(s,p+float2(h.x,h.y)).rgb*2;
 c+=tex.sample(s,p+float2(2*h.x,0)).rgb;
 c+=tex.sample(s,p+float2(h.x,-h.y)).rgb*2;
 c+=tex.sample(s,p+float2(0,-2*h.y)).rgb;
 c+=tex.sample(s,p+float2(-h.x,-h.y)).rgb*2;
 return float4(c/12,1);
}
fragment float4 bloom_composite(BloomOut in [[stage_in]],texture2d<float> scene [[texture(0)]],texture2d<float> bloom [[texture(1)]],texture2d<float> emission [[texture(2)]],sampler s [[sampler(0)]],constant BloomComposite &u [[buffer(0)]]){
 float3 c;
 if(u.mode==2)c=emission.sample(s,in.uv).rgb;
 else if(u.mode==3)c=bloom.sample(s,in.vuv).rgb*u.intensity;
 else {c=scene.sample(s,in.uv).rgb;if(u.mode==1)c+=bloom.sample(s,in.vuv).rgb*u.intensity;}
 return float4(c,1);
}
)MSL";
#endif
