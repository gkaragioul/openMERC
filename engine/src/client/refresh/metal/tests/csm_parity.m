// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-AMEND-016 R16.2 / R16.4 verification.
// The native sun keys and cascades against the actual gl3_csm.c functions (extracted into csm_gl_ref.h by the script),
// and the MSL receiver, caster and world/shadow shader variants on the GPU.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "csm_host_shaders.h"
#include "mtl_csm_math.h"
#include "mtl_csm_shader.h"
#include "mtl_post_shaders.h"
#include "mtl_lightmap_shader.h"

/* ---- the environment of the GPL functions ---- */
typedef int qboolean;
typedef float vec_t;
typedef vec_t vec3_t[3];
typedef struct { float value; } cvar_t;
#define CSM_MAXCASC 4
#define PRINT_DEVELOPER 1
#define R_Printf(...) ((void)0)
#define Com_sprintf snprintf
#define Q_stricmp strcasecmp
#define Q_strncasecmp strncasecmp
#define Q_strlcpy(d, s, n) snprintf((d), (n), "%s", (s))
#define Q_min(a, b) ((a) < (b) ? (a) : (b))
#define Q_max(a, b) ((a) > (b) ? (a) : (b))
#define Q_clamp(a, lo, hi) ((a) < (lo) ? (lo) : ((a) > (hi) ? (hi) : (a)))
#define VectorSet(v, x, y, z) ((v)[0] = (x), (v)[1] = (y), (v)[2] = (z))
#define VectorClear(v) ((v)[0] = (v)[1] = (v)[2] = 0)
#define VectorCopy(a, b) ((b)[0] = (a)[0], (b)[1] = (a)[1], (b)[2] = (a)[2])
#define VectorSubtract(a, b, c) ((c)[0] = (a)[0] - (b)[0], (c)[1] = (a)[1] - (b)[1], (c)[2] = (a)[2] - (b)[2])
#define VectorAdd(a, b, c) ((c)[0] = (a)[0] + (b)[0], (c)[1] = (a)[1] + (b)[1], (c)[2] = (a)[2] + (b)[2])
#define VectorScale(v, s, o) ((o)[0] = (v)[0] * (s), (o)[1] = (v)[1] * (s), (o)[2] = (v)[2] * (s))
#define DotProduct(a, b) ((a)[0] * (b)[0] + (a)[1] * (b)[1] + (a)[2] * (b)[2])
static float VectorLength(const float v[3]) { return sqrtf(DotProduct(v, v)); }
static float VectorNormalize(float v[3])
{
	float l = VectorLength(v);
	if (l) { float i = 1.0f / l; v[0] *= i; v[1] *= i; v[2] *= i; }
	return l;
}
static void CrossProduct(const float a[3], const float b[3], float c[3])
{
	c[0] = a[1] * b[2] - a[2] * b[1];
	c[1] = a[2] * b[0] - a[0] * b[2];
	c[2] = a[0] * b[1] - a[1] * b[0];
}
static cvar_t r_om_csm_bias_value = {0.0015f}, *r_om_csm_bias = &r_om_csm_bias_value;
static struct { float fov_x, fov_y; float vieworg[3]; } r_newrefdef;
static vec3_t vup, vpn, vright;
#include "csm_gl_ref.h"
/* ---- */

static int checks, failures;
static void check(int pass, const char *label) { checks++; if (!pass) { failures++; fprintf(stderr, "FAIL: %s\n", label); } }
static int nearv(const float *a, const float *b, int n, float eps)
{
	for (int i = 0; i < n; i++)
		if (fabsf(a[i] - b[i]) > eps * (1.0f + fabsf(b[i]))) return 0;
	return 1;
}

static void sun_case(const char *name, const char *text)
{
	mtl_csm_sun_t m;
	char label[128];
	C.built = NULL;
	GL3_CSM_LoadSun(text, (int)strlen(text));
	MTL_CSMParseSun(text, (int)strlen(text), &m);
	snprintf(label, sizeof(label), "sun valid: %s", name);
	check(m.valid == sun.valid, label);
	if (sun.valid) {
		snprintf(label, sizeof(label), "sun direction: %s", name);
		check(nearv(m.tosun, sun.tosun, 3, 1e-5f), label);
		snprintf(label, sizeof(label), "sun colour/light/ambient: %s", name);
		check(nearv(m.color, sun.color, 3, 1e-6f) && m.light == sun.light && nearv(m.ambient, sun.ambient, 3, 1e-6f), label);
		snprintf(label, sizeof(label), "sun source name: %s", name);
		check(!strcmp(m.how, sun.how), label);
	}
}

static void sun_parity(void)
{
	sun_case("angle", "{ \"classname\" \"worldspawn\" \"_sun_angle\" \"45 -60\" \"_sun_light\" \"150\" }");
	sun_case("angle ambient triple colour", "{ \"classname\" \"worldspawn\" \"_sun_angle\" \"90 -35\" \"_sun_ambient\" \"30 30 40\" \"_sun_color\" \"1 .5 .2\" \"_sun_light\" \"40\" }");
	sun_case("angle ambient one", "{ \"classname\" \"worldspawn\" \"_sun_angle\" \"0 -89\" \"_sun_ambient\" \"20\" }");
	sun_case("target pair", "{ \"classname\" \"worldspawn\" \"_sun\" \"sunpoint\" }\n{ \"classname\" \"info_null\" \"targetname\" \"sunpoint\" \"origin\" \"0 0 0\" }\n{ \"classname\" \"light\" \"target\" \"sunpoint\" \"origin\" \"100 200 1000\" }");
	sun_case("target key spelling", "{ \"classname\" \"worldspawn\" \"_sun_target\" \"tp\" }\n{ \"classname\" \"info_notnull\" \"targetname\" \"tp\" \"origin\" \"10 20 30\" }\n{ \"classname\" \"light_spot\" \"target\" \"tp\" \"origin\" \"200 40 900\" }");
	sun_case("target missing light", "{ \"classname\" \"worldspawn\" \"_sun\" \"sunpoint\" }\n{ \"classname\" \"info_null\" \"targetname\" \"sunpoint\" \"origin\" \"0 0 0\" }");
	sun_case("vector", "{ \"classname\" \"worldspawn\" \"_sun_vector\" \"0.2 0.4 -1\" }");
	sun_case("surface only", "{ \"classname\" \"worldspawn\" \"_sun_surface\" \"1\" }");
	sun_case("below the horizon", "{ \"classname\" \"worldspawn\" \"_sun_angle\" \"45 10\" }");
	sun_case("no keys", "{ \"classname\" \"worldspawn\" }\n{ \"classname\" \"light\" \"origin\" \"0 0 0\" }");
	sun_case("keys of a later entity ignored", "{ \"classname\" \"worldspawn\" }\n{ \"classname\" \"info_null\" \"_sun_angle\" \"45 -60\" }");
	sun_case("_sunlight used, _sun_light wins", "{ \"classname\" \"worldspawn\" \"_sun_angle\" \"45 -60\" \"_sunlight\" \"70\" \"_sun_light\" \"130\" }");
	sun_case("angle precedence over vector", "{ \"classname\" \"worldspawn\" \"_sun_vector\" \"1 0 -1\" \"_sun_angle\" \"45 -60\" }");
}

static float rnd(float lo, float hi) { return lo + (hi - lo) * ((float)rand() / (float)RAND_MAX); }

static void cascade_parity(void)
{
	srand(7);
	for (int t = 0; t < 400; t++) {
		float tosun[3] = {rnd(-1, 1), rnd(-1, 1), rnd(.05f, 1)};
		VectorNormalize(tosun);
		int ncasc = 1 + rand() % 4;
		int size = (rand() & 1) ? 2048 : 1024;
		float wmins[3] = {rnd(-8000, -2000), rnd(-8000, -2000), rnd(-1000, 0)};
		float wmaxs[3] = {rnd(2000, 8000), rnd(2000, 8000), rnd(200, 2000)};
		float lambda = rnd(0, 1), maxd = rnd(256, 4096);
		/* the view of the frame */
		r_newrefdef.fov_x = rnd(50, 110);
		r_newrefdef.fov_y = rnd(40, 80);
		for (int k = 0; k < 3; k++) r_newrefdef.vieworg[k] = rnd(-3000, 3000);
		vpn[0] = rnd(-1, 1); vpn[1] = rnd(-1, 1); vpn[2] = rnd(-.5f, .5f);
		VectorNormalize(vpn);
		float upref[3] = {0, 0, 1};
		CrossProduct(vpn, upref, vright);
		VectorNormalize(vright);
		CrossProduct(vright, vpn, vup);
		VectorNormalize(vup);

		/* GL3_CSM_Frame's use of OrthoForCascade (the rest of that function draws) */
		vec3_t X, Y, Z, ref;
		float zworld = -1e30f, dnear = 4.0f, prev;
		C.size = size;
		VectorCopy(tosun, Z);
		VectorSet(ref, 0, 0, 1);
		if (fabsf(Z[2]) > 0.99f) VectorSet(ref, 1, 0, 0);
		CrossProduct(ref, Z, X);
		VectorNormalize(X);
		CrossProduct(Z, X, Y);
		for (int i = 0; i < 8; i++) {
			vec3_t p;
			p[0] = (i & 1) ? wmaxs[0] : wmins[0];
			p[1] = (i & 2) ? wmaxs[1] : wmins[1];
			p[2] = (i & 4) ? wmaxs[2] : wmins[2];
			float dz = DotProduct(p, Z);
			if (dz > zworld) zworld = dz;
		}
		float gllambda = Q_clamp(lambda, 0.0f, 1.0f), glmaxd = Q_clamp(maxd, 256.0f, 16384.0f);
		prev = dnear;
		for (int c = 0; c < ncasc; c++) {
			float f = (float)(c + 1) / ncasc;
			float uni = dnear + (glmaxd - dnear) * f, lg = dnear * powf(glmaxd / dnear, f);
			float d = uni + (lg - uni) * gllambda;
			OrthoForCascade(c, (c == 0) ? 0.0f : prev, d, X, Y, Z, zworld);
			prev = d;
		}

		mtl_csm_uniform_t u;
		mtl_csm_cascade_t cas[MTL_CSM_MAXCASC];
		mtl_csm_sun_t s;
		mtl_csm_view_t v;
		mtl_csm_config_t cfg;
		memset(&u, 0, sizeof(u));
		memset(&s, 0, sizeof(s));
		memcpy(s.tosun, tosun, sizeof(tosun));
		s.light = rnd(10, 200);
		s.ambient[0] = s.ambient[1] = s.ambient[2] = .06f;
		memcpy(v.origin, r_newrefdef.vieworg, sizeof(v.origin));
		memcpy(v.forward, vpn, sizeof(v.forward));
		memcpy(v.right, vright, sizeof(v.right));
		memcpy(v.up, vup, sizeof(v.up));
		v.fov_x = r_newrefdef.fov_x;
		v.fov_y = r_newrefdef.fov_y;
		cfg.ncasc = ncasc; cfg.size = size; cfg.lambda = lambda; cfg.maxdist = maxd;
		cfg.strength = .65f; cfg.normalbias = .02f; cfg.soft = 2; cfg.bias = .0015f; cfg.replace_ghl = 1; cfg.debug = 0;
		MTL_CSMCompute(&u, cas, &s, wmins, wmaxs, &v, &cfg);

		int ok = 1;
		for (int c = 0; c < ncasc; c++) {
			if (!nearv(u.vp[c], C.u.vp[c], 16, 1e-5f)) ok = 0;
			if (!nearv(&u.split[c], &C.u.split[c], 1, 1e-5f)) ok = 0;
			if (!nearv(&u.texel[c], &C.u.texel[c], 1, 1e-5f)) ok = 0;
			if (!nearv(&u.bias[c], &C.u.bias[c], 1, 1e-5f)) ok = 0;
		}
		check(ok, "cascade matrices, splits, texels, biases");
		/* the other uniforms, from the same inputs as GL */
		check(fabsf(u.params[0] - 0.65f * Q_clamp(s.light / 100.0f, 0.25f, 1.0f)) < 1e-6f, "strength with sun light");
		check(fabsf(u.params[2] - 2.0f) < 1e-5f && fabsf(u.params[3] - 2.0f) < 1e-6f, "normal offset and PCF radius");
		check(fabsf(u.params2[0] - ncasc) < 1e-6f && fabsf(u.params2[1] - 1.0f / size) < 1e-6f && u.params2[2] == 1 && u.params2[3] == 0, "cascades and texel size");
		check(nearv(u.sun, Z, 3, 1e-6f) && u.sun[3] == 1, "sun vector");
		float wantw = -DotProduct(vpn, r_newrefdef.vieworg);
		check(nearv(u.view, vpn, 3, 1e-6f) && fabsf(u.view[3] - wantw) <= 1e-3f + fabsf(wantw) * 1e-5f, "view plane");

		/* the dynamic box: a caster point always falls inside it, and an empty box is empty */
		float px = rnd(-3000, 3000), py = rnd(-3000, 3000), pz = rnd(-100, 500);
		float wp[3] = {px, py, pz};
		float lx = DotProduct(wp, X), ly = DotProduct(wp, Y);
		for (int c = 0; c < ncasc; c++) {
			float rect[4];
			MTL_CSMDynRect(rect, &cas[c], size, 2, 1, lx, lx, ly, ly);
			const float *m = u.vp[c];
			float ndcx = m[0] * px + m[4] * py + m[8] * pz + m[12], ndcy = m[1] * px + m[5] * py + m[9] * pz + m[13];
			float uvx = ndcx * .5f + .5f, uvy = .5f - ndcy * .5f;
			check(uvx >= rect[0] && uvx <= rect[2] && uvy >= rect[1] && uvy <= rect[3], "caster inside its box");
			MTL_CSMDynRect(rect, &cas[c], size, 2, 0, 0, 0, 0, 0);
			check(rect[2] < rect[0] && rect[3] < rect[1], "no casters: empty box");
		}
	}
}

/* ------------------------------------------------------------------ GPU */
static id<MTLRenderPipelineState> frag_pipe(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *vs, NSString *fs, MTLPixelFormat color)
{
	NSError *e = nil;
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [lib newFunctionWithName:vs];
	if (fs) d.fragmentFunction = [lib newFunctionWithName:fs];
	if (color != MTLPixelFormatInvalid) d.colorAttachments[0].pixelFormat = color;
	else d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
	if (!p) fprintf(stderr, "pipeline %s: %s\n", fs.UTF8String, e.localizedDescription.UTF8String);
	return p;
}

static void gpu(void)
{
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	if (!dev) { printf("no Metal device, GPU checks skipped\n"); return; }
	NSError *e = nil;

	/* every MSL variant the renderer can build compiles */
	NSString *world = [NSString stringWithFormat:@"#define OM_POST_OUTPUTS 1\n#define OM_POST_MRT 1\n%@\n#define OM_CSM 1\n%@\n%@\n%@", MTL_PostMSLPreamble(YES), mtl_csm_msl, mtl_world_shader, mtl_lightmap_shader];
	id<MTLLibrary> worldlib = [dev newLibraryWithSource:world options:nil error:&e];
	if (!worldlib) fprintf(stderr, "world+csm: %s\n", e.localizedDescription.UTF8String);
	check(worldlib != nil && [worldlib newFunctionWithName:@"mtl_fs_world_lightmaps"] != nil, "world lightmap shader compiles with the receiver");
	NSString *plain = [NSString stringWithFormat:@"#define OM_POST_OUTPUTS 1\n#define OM_POST_MRT 1\n%@\n%@\n%@", MTL_PostMSLPreamble(YES), mtl_world_shader, mtl_lightmap_shader];
	check([dev newLibraryWithSource:plain options:nil error:&e] != nil, "plain world shader unchanged");
	NSString *gshadow = [NSString stringWithFormat:@"#define OM_CSM 1\n%@\n%@\n%@", MTL_PostMSLPreamble(YES), mtl_csm_msl, mtl_gshadow_test_msl];
	id<MTLLibrary> shadowlib = [dev newLibraryWithSource:gshadow options:nil error:&e];
	if (!shadowlib) fprintf(stderr, "ghoul shadow+csm: %s\n", e.localizedDescription.UTF8String);
	check(shadowlib != nil, "Ghoul shadow shader compiles with the receiver");

	/* the receiver functions on a real depth array */
	NSString *bench = @R"MSL(
struct V { float4 position [[position]]; float2 ndc; };
vertex V vs(uint i [[vertex_id]]) { float2 p = float2(i == 1 ? 2 : 0, i == 2 ? 2 : 0); V o; o.ndc = float2(2 * p.x - 1, 1 - 2 * p.y); o.position = float4(o.ndc, 0, 1); return o; }
fragment float4 fs_apply(V in [[stage_in]], constant OMCsmUniforms &u [[buffer(7)]], depth2d_array<float> map [[texture(8)]]) {
 float3 l = omCsmApply(float3(1.0), float3(in.ndc, 0.5), float3(0, 0, 1), u, map);
 return float4(l, 1);
}
fragment float4 fs_keep(V in [[stage_in]], constant OMCsmUniforms &u [[buffer(7)]], depth2d_array<float> map [[texture(8)]]) {
 float k = omCsmGhoulShadowKeep(float3(in.ndc, 0.5), u, map);
 return float4(k, k, k, 1);
}
)MSL";
	NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\n%@", mtl_csm_msl, bench];
	id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
	if (!lib) { fprintf(stderr, "bench: %s\n", e.localizedDescription.UTF8String); check(0, "bench shaders"); return; }
	id<MTLLibrary> caster = [dev newLibraryWithSource:mtl_csm_caster_msl options:nil error:&e];
	if (!caster) { fprintf(stderr, "caster: %s\n", e.localizedDescription.UTF8String); check(0, "caster shader"); return; }
	check(1, "caster shader compiles");

#define SIZE 64
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:SIZE height:SIZE mipmapped:NO];
	td.textureType = MTLTextureType2DArray;
	td.arrayLength = 2;
	td.storageMode = MTLStorageModePrivate;
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	id<MTLTexture> map = [dev newTextureWithDescriptor:td];

	/* uniforms: identity light matrix (GL ndc: z maps to 0..1 with p.z * .5 + .5), one cascade, sun straight up */
	mtl_csm_uniform_t u;
	memset(&u, 0, sizeof(u));
	u.vp[0][0] = u.vp[0][5] = u.vp[0][10] = u.vp[0][15] = 1;
	u.split[0] = 1000;
	u.sun[2] = 1; u.sun[3] = 1;
	u.params[0] = 0.65f; u.params[2] = 0; u.params[3] = 2;
	u.params2[0] = 1; u.params2[1] = 1.0f / SIZE; u.params2[2] = 1; u.params2[3] = 0;
	u.view[2] = 0; u.view[3] = 1;
	u.amb[0] = u.amb[1] = u.amb[2] = 0.06f;
	u.bias[0] = 1e-4f;
	u.dynrect[0][0] = 0; u.dynrect[0][1] = 0; u.dynrect[0][2] = 1; u.dynrect[0][3] = 1;

	id<MTLCommandQueue> q = [dev newCommandQueue];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	/* layer 0: static world, a quad over the half y < 0 at z = 0.5 + bias depth: empty (cleared far) */
	MTLRenderPassDescriptor *p0 = [MTLRenderPassDescriptor renderPassDescriptor];
	p0.depthAttachment.texture = map; p0.depthAttachment.slice = 0;
	p0.depthAttachment.loadAction = MTLLoadActionClear; p0.depthAttachment.storeAction = MTLStoreActionStore; p0.depthAttachment.clearDepth = 1;
	[[cb renderCommandEncoderWithDescriptor:p0] endEncoding];
	/* layer 1: dynamic: the caster covers the half with world y > 0, z = -0.5 (depth 0.25) through the real caster pipeline */
	float vp_id[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
	float tris[6][3] = {{-1, 0, -.5f}, {1, 0, -.5f}, {1, 1, -.5f}, {-1, 0, -.5f}, {1, 1, -.5f}, {-1, 1, -.5f}};
	id<MTLRenderPipelineState> casterpipe = frag_pipe(dev, caster, @"mtl_vs_csm_caster", nil, MTLPixelFormatInvalid);
	check(casterpipe != nil, "caster pipeline");
	if (!casterpipe) return;
	MTLRenderPassDescriptor *p1 = [MTLRenderPassDescriptor renderPassDescriptor];
	p1.depthAttachment.texture = map; p1.depthAttachment.slice = 1;
	p1.depthAttachment.loadAction = MTLLoadActionClear; p1.depthAttachment.storeAction = MTLStoreActionStore; p1.depthAttachment.clearDepth = 1;
	id<MTLRenderCommandEncoder> ce = [cb renderCommandEncoderWithDescriptor:p1];
	MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
	dd.depthCompareFunction = MTLCompareFunctionLess; dd.depthWriteEnabled = YES;
	[ce setRenderPipelineState:casterpipe];
	[ce setDepthStencilState:[dev newDepthStencilStateWithDescriptor:dd]];
	[ce setCullMode:MTLCullModeNone];
	[ce setVertexBytes:tris length:sizeof(tris) atIndex:0];
	[ce setVertexBytes:vp_id length:sizeof(vp_id) atIndex:1];
	[ce drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	[ce endEncoding];

	MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:SIZE height:SIZE mipmapped:NO];
	cd.storageMode = MTLStorageModeShared;
	cd.usage = MTLTextureUsageRenderTarget;
	id<MTLTexture> outa = [dev newTextureWithDescriptor:cd], outb = [dev newTextureWithDescriptor:cd];

	void (^draw)(id<MTLTexture>, NSString *, const mtl_csm_uniform_t *) = ^(id<MTLTexture> tex, NSString *fs, const mtl_csm_uniform_t *uni) {
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = tex;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
		id<MTLRenderPipelineState> p = frag_pipe(dev, lib, @"vs", fs, MTLPixelFormatRGBA32Float);
		if (!p) { [enc endEncoding]; return; }
		[enc setRenderPipelineState:p];
		[enc setFragmentBytes:uni length:sizeof(*uni) atIndex:7];
		[enc setFragmentTexture:map atIndex:8];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding];
	};
	draw(outa, @"fs_apply", &u);
	mtl_csm_uniform_t empty = u;
	empty.dynrect[0][0] = 2; empty.dynrect[0][1] = 2; empty.dynrect[0][2] = -1; empty.dynrect[0][3] = -1;
	draw(outb, @"fs_apply", &empty);
	id<MTLTexture> outk = [dev newTextureWithDescriptor:cd];
	draw(outk, @"fs_keep", &u);
	[cb commit];
	[cb waitUntilCompleted];
	check(cb.error == nil, "GPU work executed");
	float apply[SIZE * SIZE * 4], skip[SIZE * SIZE * 4], keep[SIZE * SIZE * 4];
	[outa getBytes:apply bytesPerRow:SIZE * 16 fromRegion:MTLRegionMake2D(0, 0, SIZE, SIZE) mipmapLevel:0];
	[outb getBytes:skip bytesPerRow:SIZE * 16 fromRegion:MTLRegionMake2D(0, 0, SIZE, SIZE) mipmapLevel:0];
	[outk getBytes:keep bytesPerRow:SIZE * 16 fromRegion:MTLRegionMake2D(0, 0, SIZE, SIZE) mipmapLevel:0];

	/* image row 0 is the top (ndc y = +1): the caster side */
	int shadowed = 0, lit = 0, wrong = 0, keepwrong = 0;
	for (int y = 0; y < SIZE; y++) {
		for (int x = 0; x < SIZE; x++) {
			float *pix = apply + (y * SIZE + x) * 4;
			float nd = 1 - 2 * (y + .5f) / SIZE;
			float want;
			if (nd > 0.05f) { want = 0.35f; shadowed++; }       /* casters above: 1 - 0.65 */
			else if (nd < -0.05f) { want = 1.0f; lit++; }        /* no caster */
			else continue;                                       /* the PCF edge row */
			if (fabsf(pix[0] - want) > 0.03f) wrong++;
			float *s = skip + (y * SIZE + x) * 4;
			if (fabsf(s[0] - 1.0f) > 0.001f) wrong++;            /* empty dynamic box: lit everywhere */
			float *k = keep + (y * SIZE + x) * 4;
			if (fabsf(k[0] - (1.0f - 0.7f)) > 0.03f) keepwrong++; /* static all sun: 1 - s/9 * fade * 0.7 * (0.65/0.65) */
		}
	}
	if (wrong) fprintf(stderr, "apply: %d wrong pixels (first row sample %.3f)\n", wrong, apply[(SIZE / 8 * SIZE + SIZE / 2) * 4]);
	check(shadowed > 0 && lit > 0 && wrong == 0, "shadow lands on the receivers under the casters, not mirrored in y");
	check(keepwrong == 0, "ground shadow keeps its contact part in full sun");
}

int main(void)
{
	sun_parity();
	cascade_parity();
	gpu();
	printf("CSM checks: %d passed, %d failed\n", checks - failures, failures);
	return failures ? 1 : 0;
}
