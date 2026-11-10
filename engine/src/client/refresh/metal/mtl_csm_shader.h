// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// The cascaded sun shadow receiver and caster in MSL, written from the GPL gl3_csm.c GLSL.
// Implements: SPEC-AMEND-016 R16.4; docs/impl/GFX-modern.md section 4.
#ifndef OM_METAL_CSM_SHADER_H
#define OM_METAL_CSM_SHADER_H
#import <Foundation/Foundation.h>

/* The renderer sets this for the frames with sun shadow maps; the world pipeline then builds its receiver variant.
 * Contract harnesses never see this header: their world pipeline is the plain one. */
static int mtl_world_csm_variant;

/* buffer(7): OMCsmUniforms (mtl_csm_uniform_t), texture(8): the depth array (static layers 0..n-1, dynamic n..2n-1) */
__attribute__((unused)) static NSString *const mtl_csm_msl = @R"MSL(
struct OMCsmUniforms {
 float4x4 vp[4];
 float4 split;
 float4 sun;
 float4 params;
 float4 params2;
 float4 view;
 float4 amb;
 float4 texel;
 float4 bias;
 float4 dynrect[4];
};
constexpr sampler omCsmSampler(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less_equal);
inline int omCsmCascade(float3 wp, thread float &fade, constant OMCsmUniforms &u) {
 float d = dot(u.view.xyz, wp) + u.view.w;
 int n = int(u.params2.x + 0.5);
 fade = 1.0;
 for (int i = 0; i < min(n, 4); i++) {
  if (d < u.split[i]) {
   if (i == n - 1) fade = clamp((u.split[i] - d) / (0.15 * u.split[i]), 0.0, 1.0);
   return i;
  }
 }
 return -1;
}
inline float3 omCsmPos(int c, float3 wp, constant OMCsmUniforms &u) {
 float4 p = u.vp[c] * float4(wp, 1.0);
 return float3(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5, p.z * 0.5 + 0.5);
}
/* 1 where the static world lets the sun through */
inline float omCsmStatic(int c, float3 wp, float3 n, constant OMCsmUniforms &u, depth2d_array<float> map) {
 float3 p = omCsmPos(c, wp + n * (u.texel[c] * (u.params.z + 1.0)), u);
 if (p.x <= 0.0 || p.y <= 0.0 || p.x >= 1.0 || p.y >= 1.0 || p.z >= 1.0) return 1.0;
 return map.sample_compare(omCsmSampler, p.xy, uint(c), p.z - 4.0 * u.bias[c]);
}
/* 0..1 of the sun a dynamic caster blocks (percentage-closer filtered) */
inline float omCsmDynamic(int c, float3 wp, float3 n, constant OMCsmUniforms &u, depth2d_array<float> map) {
 float3 p = omCsmPos(c, wp + n * (u.texel[c] * u.params.z), u);
 if (p.x <= 0.0 || p.y <= 0.0 || p.x >= 1.0 || p.y >= 1.0 || p.z >= 1.0) return 0.0;
 /* no dynamic caster near this texel: the taps below would all pass (the box already has the PCF reach in it) */
 float4 rect = u.dynrect[c];
 if (p.x < rect.x || p.y < rect.y || p.x > rect.z || p.y > rect.w) return 0.0;
 uint layer = uint(c + int(u.params2.x + 0.5));
 float zr = p.z - u.bias[c];
 int r = int(u.params.w + 0.5);
 float s = 0.0, w = 0.0;
 for (int y = -2; y <= 2; y++) {
  for (int x = -2; x <= 2; x++) {
   if (abs(x) > r || abs(y) > r) continue;
   s += map.sample_compare(omCsmSampler, p.xy + float2(float(x), float(y)) * u.params2.y, layer, zr);
   w += 1.0;
  }
 }
 return 1.0 - s / w;
}
inline float3 omCsmApply(float3 lm, float3 wp, float3 n, constant OMCsmUniforms &u, depth2d_array<float> map) {
 if (u.sun.w < 0.5) return lm;
 float ndl = dot(n, u.sun.xyz);
 float fade;
 int c = omCsmCascade(wp, fade, u);
 /* r_om_csm_debug: red = static sun visibility, green = dynamic shadow, blue = cascade */
 if (u.params2.w > 0.5)
  return (c < 0 || ndl <= 0.0) ? float3(0.0, 0.0, 0.1) : float3(omCsmStatic(c, wp, n, u, map), omCsmDynamic(c, wp, n, u, map), float(c + 1) * 0.25);
 if (ndl <= 0.0 || c < 0) return lm;
 float lit = omCsmStatic(c, wp, n, u, map);
 if (lit <= 0.01) return lm;
 float sh = omCsmDynamic(c, wp, n, u, map);
 if (sh <= 0.0) return lm;
 float k = u.params.x * lit * sh * fade * smoothstep(0.0, 0.3, ndl);
 return max(lm * (1.0 - k), min(lm, u.amb.rgb));
}
/* how much of a Ghoul ground shadow is left: 0 where the ground is in the sun */
inline float omCsmGhoulShadowKeep(float3 wp, constant OMCsmUniforms &u, depth2d_array<float> map) {
 if (u.sun.w < 0.5 || u.params2.z < 0.5) return 1.0;
 float fade;
 int c = omCsmCascade(wp, fade, u);
 if (c < 0) return 1.0;
 float3 p = omCsmPos(c, wp + float3(0.0, 0.0, u.texel[c] * (u.params.z + 1.0)), u);
 if (p.x <= 0.0 || p.y <= 0.0 || p.x >= 1.0 || p.y >= 1.0 || p.z >= 1.0) return 1.0 - fade;
 /* 3 x 3 taps two texels apart: the hand-over to the sun shadow is soft, not texel-blocky */
 float s = 0.0;
 for (int y = -1; y <= 1; y++)
  for (int x = -1; x <= 1; x++)
   s += map.sample_compare(omCsmSampler, p.xy + float2(float(x), float(y)) * 2.0 * u.params2.y, uint(c), p.z - 4.0 * u.bias[c]);
 /* a contact shadow stays even in full sun (the sun shadow leaves the feet at a low sun); a weak (night) sun, whose CSM
  * shadow is faint (omCsmParams.x = strength x light / 100), keeps more of it (fb3) */
 return 1.0 - (s / 9.0) * fade * 0.7 * clamp(u.params.x / 0.65, 0.0, 1.0);
}
)MSL";

/* the casters of a cascade layer: positions in world space, depth with GL's range so the shader biases carry over */
__attribute__((unused)) static NSString *const mtl_csm_caster_msl = @R"MSL(
#include <metal_stdlib>
using namespace metal;
struct OMCsmCasterOut { float4 position [[position]]; };
vertex OMCsmCasterOut mtl_vs_csm_caster(uint id [[vertex_id]], const device packed_float3 *v [[buffer(0)]], constant float4x4 &vp [[buffer(1)]]) {
 OMCsmCasterOut o;
 float4 p = vp * float4(float3(v[id]), 1.0);
 p.z = p.z * 0.5 + 0.5 * p.w;
 o.position = p;
 return o;
}
)MSL";
#endif
