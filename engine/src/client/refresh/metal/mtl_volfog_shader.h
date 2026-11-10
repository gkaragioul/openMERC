// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// The r_om_volfog raymarch in MSL, written from the GPL gl3_post.c shader; shared by the renderer and its GPU check.
// Implements: SPEC-AMEND-016 R16.7; docs/impl/GFX-modern.md section 3.
#ifndef OM_METAL_VOLFOG_SHADER_H
#define OM_METAL_VOLFOG_SHADER_H
#import <Foundation/Foundation.h>

/* uniforms of mtl_fs_volfog: MSL struct OMVolFogUniforms */
typedef struct {
	float invpv[16];
	float eye[4];  /* xyz, time */
	float prm[4];  /* depth range min, max; intensity; shafts */
	float prm2[4]; /* regions, steps, noise, sun */
	float vr[16 * 32];
} mtl_volfog_uniform_t;

/* Needs the MSL preamble (OMPostOutput, namespace metal) in front; with OM_VOLFOG_SHAFTS 1 also the sun shadow
 * functions (mtl_csm_msl) and their buffer(7)/texture(8) bindings. */
__attribute__((unused)) static NSString *const mtl_volfog_msl = @R"MSL(
#ifndef OM_VOLFOG_SHAFTS
#define OM_VOLFOG_SHAFTS 0
#endif
struct OMVolFogUniforms {
 float4x4 invpv;
 float4 eye;
 float4 prm;
 float4 prm2;
 float4 vr[128];
};
struct OMVolFogVarying { float4 position [[position]]; float2 ndc; };
vertex OMVolFogVarying mtl_vs_volfog(uint id [[vertex_id]]) {
 float2 p = float2(id == 1 ? 2 : 0, id == 2 ? 2 : 0);
 OMVolFogVarying o;
 o.ndc = float2(2 * p.x - 1, 1 - 2 * p.y);
 o.position = float4(o.ndc, 0, 1);
 return o;
}
inline float omVolH3(float3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
inline float omVolNoise(float3 x) {
 float3 i = floor(x), f = fract(x);
 f = f * f * (3.0 - 2.0 * f);
 return mix(mix(mix(omVolH3(i), omVolH3(i + float3(1, 0, 0)), f.x), mix(omVolH3(i + float3(0, 1, 0)), omVolH3(i + float3(1, 1, 0)), f.x), f.y),
            mix(mix(omVolH3(i + float3(0, 0, 1)), omVolH3(i + float3(1, 0, 1)), f.x), mix(omVolH3(i + float3(0, 1, 1)), omVolH3(i + float3(1, 1, 1)), f.x), f.y), f.z);
}
fragment OMPostOutput mtl_fs_volfog(OMVolFogVarying in [[stage_in]],
 depth2d<float> depthtex [[texture(0)]], constant OMVolFogUniforms &u [[buffer(0)]]
#if OM_VOLFOG_SHAFTS
 , constant OMCsmUniforms &csm [[buffer(7)]], depth2d_array<float> csmmap [[texture(8)]]
#endif
 ) {
 float z = depthtex.read(uint2(in.position.xy));
 float nz = (z - u.prm.x) / (u.prm.y - u.prm.x);
 float4 w = u.invpv * float4(in.ndc, nz, 1.0);
 float3 ro = u.eye.xyz;
 float3 dv = w.xyz / w.w - ro;
 float tmax = length(dv);
 if (w.w <= 0.0) tmax = 1e6;
 float3 rd = dv / max(tmax, 0.001);
 float3 inv = 1.0 / (rd + sign(rd + 1e-9) * 1e-6);
 float jit = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
 int n = int(u.prm2.x + 0.5);
 int steps = int(u.prm2.y + 0.5);
#if OM_VOLFOG_SHAFTS
 float ph = pow(max(dot(rd, csm.sun.xyz), 0.0), 4.0);
#endif
 float3 acc = float3(0);
 float T = 1.0;
 for (int i = 0; i < n; i++) {
  float4 a0 = u.vr[i * 8];
  float4 a1 = u.vr[i * 8 + 1];
  float4 a2 = u.vr[i * 8 + 2];
  float3 ta = (a0.xyz - ro) * inv;
  float3 tb = (a1.xyz - ro) * inv;
  float3 tn = min(ta, tb);
  float3 tf = max(ta, tb);
  float t0 = max(max(tn.x, tn.y), max(tn.z, 0.0));
  float t1 = min(min(tf.x, tf.y), min(tf.z, tmax));
  for (int k = 0; k < 5; k++) {
   float4 pl = u.vr[i * 8 + 3 + k];
   float a = dot(pl.xyz, ro) - pl.w;
   float b = dot(pl.xyz, rd);
   if (abs(b) < 1e-5) { if (a < 0.0) t1 = -1.0; }
   else if (b > 0.0) t0 = max(t0, -a / b);
   else t1 = min(t1, -a / b);
  }
  if (t1 <= t0 || a2.w <= 0.0) continue;
  float len = t1 - t0;
  float ds = len / float(steps);
  float dens = 0.0, lit = 0.0;
  for (int s = 0; s < steps; s++) {
   float3 p = ro + rd * (t0 + (float(s) + jit) * ds);
   float d = 1.0;
   if (a1.w > 0.5) { float h = clamp((a1.z - p.z) / max(a1.z - a0.z, 1.0), 0.0, 1.0); d = h * h; }
   if (u.prm2.z > 0.0) d *= 1.0 + u.prm2.z * (omVolNoise(p * 0.011 + float3(0.0, u.eye.w * 0.07, u.eye.w * 0.11)) * 2.0 - 1.0);
   dens += d;
#if OM_VOLFOG_SHAFTS
   if (ph > 0.001) {
    float fade;
    int c = omCsmCascade(p, fade, csm);
    float l = (c < 0) ? 0.5 : mix(0.5, omCsmStatic(c, p, float3(0), csm, csmmap), fade);
    lit += l * d;
   }
#endif
  }
  dens /= float(steps);
  float al = clamp(a2.w * u.prm.z, 0.0, 1.0) * (1.0 - exp(-a0.w * dens * len));
  float3 col = a2.rgb;
#if OM_VOLFOG_SHAFTS
  if (ph > 0.001) col *= 1.0 + u.prm.w * 0.5 * ph * (lit / float(steps)) / max(dens, 0.001);
#endif
  acc += T * al * col;
  T *= 1.0 - al;
 }
 OMPostOutput o;
 o.scene = float4(acc, T);
#if OM_POST_MRT
 o.emissive = float4(0, 0, 0, T);
#endif
 return o;
}
)MSL";
#endif
