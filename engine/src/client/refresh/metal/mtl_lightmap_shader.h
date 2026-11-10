// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 1997-2001 Id Software, Inc.
// Copyright (C) 2016-2017 Daniel Gibson
// Copyright (C) 2026 OpenMerc contributors
// Append to mtl_world_shader: uses its WVOut/Uniforms and omSoFDlights.
// Implements: SPEC-410, SPEC-413; matches GPL gl3_shaders.c lightmap modes.
static NSString *const mtl_lightmap_shader = @R"MSL(
struct LightmapUniforms {
	float4 scales[4];
	float4 mode;
};

vertex WVOut mtl_vs_world_lightmaps(const device WVSIn *verts [[buffer(0)]],
	constant Uniforms &u [[buffer(1)]], uint vid [[vertex_id]])
{
	WVOut output;
	WVSIn value = verts[vid];
	output.position = u.mvp * float4(value.pos, 1.0);
	output.uv = value.uv + u.adjust;
	output.luv = value.luv;
	output.worldpos = value.pos;
	return output;
}

#ifdef OM_POST_OUTPUTS
#define OM_LIGHTMAP_OUTPUT OMPostOutput
#else
#define OM_LIGHTMAP_OUTPUT float4
#endif

fragment OM_LIGHTMAP_OUTPUT mtl_fs_world_lightmaps(WVOut in [[stage_in]],
	texture2d<float> tex [[texture(0)]], texture2d<float> light0 [[texture(1)]],
	texture2d<float> table [[texture(2)]], texture2d<float> light1 [[texture(4)]],
	texture2d<float> light2 [[texture(5)]], texture2d<float> light3 [[texture(6)]],
	texture2d<float> dynamic_light [[texture(7)]],
	sampler diffuse_sampler [[sampler(0)]], sampler light_sampler [[sampler(1)]],
	sampler table_sampler [[sampler(2)]], constant Uniforms &u [[buffer(1)]],
	constant LightmapUniforms &lm [[buffer(3)]]
#ifdef OM_POST_OUTPUTS
	, constant OMPostUniforms &post [[buffer(4)]]
#endif
#if OM_CSM
	, constant OMCsmUniforms &csm [[buffer(7)]], depth2d_array<float> csmmap [[texture(8)]]
#endif
	)
{
	float4 diffuse = tex.sample(diffuse_sampler, in.uv);
	if (diffuse.a <= 0.05) discard_fragment();
	if (u.fullbright != 0.0) {
		float4 scene = float4(diffuse.rgb * u.overbright, 1.0);
#ifdef OM_POST_OUTPUTS
		return OM_PostFragment(scene, scene.rgb, post.emission);
#else
		return scene;
#endif
	}
	float3 sum = light0.sample(light_sampler, in.luv).rgb * lm.scales[0].rgb;
	sum += light1.sample(light_sampler, in.luv).rgb * lm.scales[1].rgb;
	sum += light2.sample(light_sampler, in.luv).rgb * lm.scales[2].rgb;
	sum += light3.sample(light_sampler, in.luv).rgb * lm.scales[3].rgb;
#if OM_CSM
	/* sun shadows of moving casters (gl3_csm.c): on the lightmap, before the dynamic light is added */
	sum = omCsmApply(sum, in.worldpos, u.surface_normal.xyz, csm, csmmap);
#endif
	sum += dynamic_light.sample(light_sampler, in.luv).rgb;
	sum += omSoFDlights(in, u);
	float3 light_bytes = max(floor(sum * 255.0 + 0.5), float3(0.0));
	float maximum = max(light_bytes.r, max(light_bytes.g, light_bytes.b));
	if (maximum > 255.0) {
		light_bytes = floor(light_bytes * (255.0 / maximum));
		maximum = floor(maximum * (255.0 / maximum));
	}
	float3 color;
	float light_alpha = 1.0;
	int mode = int(lm.mode.x);
	if (mode == 0) {
		color.r = table.sample(table_sampler, float2((light_bytes.r + 0.5) / 256.0, 0.5)).r;
		color.g = table.sample(table_sampler, float2((light_bytes.g + 0.5) / 256.0, 0.5)).r;
		color.b = table.sample(table_sampler, float2((light_bytes.b + 0.5) / 256.0, 0.5)).r;
	} else if (mode == 1 || mode == 2) {
		color = float3(maximum / 255.0);
		if (mode == 2) light_alpha = maximum / 255.0;
	} else if (mode == 3) {
		float alpha_byte = 255.0 - floor((light_bytes.r + light_bytes.g + light_bytes.b) / 3.0);
		color = floor(light_bytes * (alpha_byte / 255.0)) / 255.0;
		light_alpha = alpha_byte / 255.0;
	} else {
		color = float3(0.0);
		light_alpha = mode == 4 ? (255.0 - maximum) / 255.0 : 1.0;
	}
	if (diffuse.a * light_alpha <= 0.05) discard_fragment();
	float4 scene = float4(diffuse.rgb * color * u.overbright, 1.0);
#ifdef OM_POST_OUTPUTS
	return OM_PostFragment(scene, scene.rgb, post.emission);
#else
	return scene;
#endif
}

fragment OM_LIGHTMAP_OUTPUT mtl_fs_sky_native(WVOut in [[stage_in]],
	texture2d<float> tex [[texture(0)]], sampler sky_sampler [[sampler(0)]])
{
	float4 scene = tex.sample(sky_sampler, in.uv);
#ifdef OM_POST_OUTPUTS
	return OM_PostDefault(scene);
#else
	return scene;
#endif
}

#undef OM_LIGHTMAP_OUTPUT
)MSL";
