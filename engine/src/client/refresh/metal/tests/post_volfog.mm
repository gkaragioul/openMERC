// SPDX-License-Identifier: GPL-2.0-or-later
// Implements: SPEC-410 fog regions, SPEC-AMEND-016 volumetric fog.
// Pure CPU checks for region packing, wanted, steps, noise clamp, overlay dim.
#import <Foundation/Foundation.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "mtl_volfog.h"
#include "mtl_fog_math.h"
#include "mtl_post_shaders.h"
#include "mtl_volfog_shader.h"
#include <cstddef>

#import <Metal/Metal.h>
static int checks, failures;
static void check(bool pass, const char *label) { checks++; if (!pass) { fprintf(stderr, "FAIL: %s\n", label); failures++; } }
static void nearf(float actual, float expected, const char *label) { if (std::fabs(actual - expected) > 1e-6f) fprintf(stderr, "%s actual%g expected%g\n", label, actual, expected); check(std::fabs(actual - expected) <= 1e-6f, label); }

static void setup_region(mtl_fog_region_t *r, float opacity, float start, float range,
	float color0, float color1, float color2, int flags, int numplanes)
{
	memset(r, 0, sizeof(*r));
	r->opacity = opacity;
	r->start = start;
	r->range = range;
	r->color[0] = (unsigned char)(color0 * 255);
	r->color[1] = (unsigned char)(color1 * 255);
	r->color[2] = (unsigned char)(color2 * 255);
	r->color[3] = 255;
	r->flags = flags;
	r->mins[0] = 0; r->mins[1] = 0; r->mins[2] = 0;
	r->maxs[0] = 10; r->maxs[1] = 10; r->maxs[2] = 10;
	r->numplanes = numplanes;
	for (int k = 0; k < numplanes && k < MTL_FOG_MAX_PLANES; k++) {
		r->planes[k].normal[0] = 1; r->planes[k].normal[1] = 0; r->planes[k].normal[2] = 0;
		r->planes[k].dist = 5;
	}
}

static void math(void)
{
	check(MTL_VolFogWanted(1, 0.4f, 5, 0, 0) == 1, "wanted with regions");
	check(MTL_VolFogWanted(0, 0.4f, 5, 0, 0) == 0, "disabled cvar");
	check(MTL_VolFogWanted(1, 0, 5, 0, 0) == 0, "zero intensity");
	check(MTL_VolFogWanted(1, 0.4f, 0, 0, 0) == 0, "no regions");
	check(MTL_VolFogWanted(1, 0.4f, 5, 2, 0) == 0, "fog mode 2");
	check(MTL_VolFogWanted(1, 0.4f, 5, 3, 0) == 0, "fog mode 3");
	check(MTL_VolFogWanted(1, 0.4f, 5, 0, 1) == 0, "nightvision");

	check(MTL_VolFogSteps(0) == 6, "quality 0 -> 6 steps");
	check(MTL_VolFogSteps(1) == 10, "quality 1 -> 10 steps");
	check(MTL_VolFogSteps(2) == 16, "quality 2 -> 16 steps");
	check(MTL_VolFogSteps(3) == 28, "quality 3 -> 28 steps");

	nearf(MTL_VolFogNoiseClamp(-0.5f), 0.0f, "noise negative -> 0");
	nearf(MTL_VolFogNoiseClamp(0.5f), 0.5f, "noise mid");
	nearf(MTL_VolFogNoiseClamp(1.5f), 0.9f, "noise clamped to 0.9");

	nearf(MTL_VolFogOverlayDim(0, 0.85f), 1.0f, "inactive -> 1");
	nearf(MTL_VolFogOverlayDim(1, 0.85f), 0.85f, "active -> configured");
	nearf(MTL_VolFogOverlayDim(1, 1.5f), 1.0f, "active clamped high");
	nearf(MTL_VolFogOverlayDim(1, -0.5f), 0.0f, "active clamped low");

	mtl_fog_world_t f;
	memset(&f, 0, sizeof(f));
	f.numregions = 2;
	f.regions = (mtl_fog_region_t*)calloc(2, sizeof(mtl_fog_region_t));
	f.regionseen[0] = 1;
	f.viewregion = 1;
	f.overrides.start = -1; f.overrides.range = -1; f.overrides.density = -1;
	f.overrides.color_enabled = 0;

	setup_region(&f.regions[0], 0.5f, 100.0f, 50.0f, 0.5f, 0.3f, 0.1f, 1, 2);
	setup_region(&f.regions[1], 0.8f, 200.0f, 80.0f, 0.2f, 0.4f, 0.6f, 3, 1);

	float eye[3] = {5, 5, 5};
	float out[MTL_VOLFog_MAX_REGIONS * MTL_VOLFog_FLOATS_PER_REGION];
	memset(out, 0, sizeof(out));

	int n = MTL_VolFogPackRegions(&f, eye, out, MTL_VOLFog_MAX_REGIONS);
	check(n == 2, "packed 2 regions");

	check(out[3] > 0, "extinction > 0");
	check(out[7] == 0.0f, "height flag (flags=1, no height falloff)");
	check(out[8] > 0 && out[8] <= 1, "RGB in range");
	check(out[11] == 0.5f, "maxOpacity");

	float *r0 = out;
	for (int k = 2; k < MTL_FOG_MAX_PLANES; k++) {
		float *pl = r0 + 12 + k * 4;
		check(pl[0] == 0 && pl[1] == 0 && pl[2] == 0 && pl[3] == -1,
			"unused halfspace is (0,0,0,-1)");
	}

	mtl_fog_world_t empty;
	memset(&empty, 0, sizeof(empty));
	float out2[MTL_VOLFog_MAX_REGIONS * MTL_VOLFog_FLOATS_PER_REGION];
	check(MTL_VolFogPackRegions(&empty, eye, out2, MTL_VOLFog_MAX_REGIONS) == 0, "empty world packs 0");

	check(MTL_VolFogPackRegions(NULL, eye, out, 16) == 0, "null world");
	check(MTL_VolFogPackRegions(&f, NULL, out, 16) == 0, "null eye");
	check(MTL_VolFogPackRegions(&f, eye, NULL, 16) == 0, "null out");

	free(f.regions);
}


/* Parity with GL3_Fog_VolumeRegions (each of these fails on the first native pack that sorted by box centre,
 * ignored the size test and overrides and left boundary planes unoriented). */
static void pack_parity(void)
{
	mtl_fog_world_t f;
	memset(&f, 0, sizeof(f));
	f.numregions = 3;
	f.regions = (mtl_fog_region_t*)calloc(3, sizeof(mtl_fog_region_t));
	f.viewregion = -1;
	f.overrides.start = -1; f.overrides.range = -1; f.overrides.density = -1;
	f.regionseen[0] = f.regionseen[1] = f.regionseen[2] = 1;
	setup_region(&f.regions[0], 0.5f, 100, 50, .1f, .2f, .3f, 0, 0); /* far box, near centre */
	f.regions[0].mins[0] = -500; f.regions[0].maxs[0] = 520;  /* eye at x 600: 80 from the box, centre 590 away */
	setup_region(&f.regions[1], 0.5f, 100, 50, .4f, .5f, .6f, 0, 0); /* near box, far centre */
	f.regions[1].mins[0] = 590; f.regions[1].maxs[0] = 2000;  /* eye 0 away horizontally inside y/z */
	f.regions[1].mins[1] = -10; f.regions[1].maxs[1] = 10;
	f.regions[1].mins[2] = -10; f.regions[1].maxs[2] = 10;
	setup_region(&f.regions[2], 0.5f, 100, 50, .7f, .8f, .9f, 2, 0); /* height flag but no size */
	float eye[3] = {600, 0, 0};
	float out[MTL_VOLFog_MAX_REGIONS * MTL_VOLFog_FLOATS_PER_REGION];
	int n = MTL_VolFogPackRegions(&f, eye, out, MTL_VOLFog_MAX_REGIONS);
	check(n == 3, "three regions packed");
	nearf(out[8], f.regions[1].color[0] / 255.0f, "nearest box first, not nearest centre");
	check(out[32 + 8] != out[64 + 8], "distinct regions packed");
	/* region 2 has the height flag but zero size: GL leaves falloff off */
	nearf(out[2 * 32 + 7], 0.0f, "height flag needs a size");

	/* boundary half-spaces: inside normal, dist - 1 */
	setup_region(&f.regions[0], 0.5f, 100, 50, .1f, .2f, .3f, 0, 1);
	f.regions[0].mins[0] = 0; f.regions[0].maxs[0] = 100;
	f.regions[0].planes[0].normal[0] = -1; f.regions[0].planes[0].normal[1] = 0; f.regions[0].planes[0].normal[2] = 0;
	f.regions[0].planes[0].dist = 0; /* box on the negative side of the plane: normal must flip to +x */
	f.regionseen[1] = f.regionseen[2] = 0;
	float eye2[3] = {50, 5, 5};
	n = MTL_VolFogPackRegions(&f, eye2, out, MTL_VOLFog_MAX_REGIONS);
	check(n == 1, "one region packed");
	nearf(out[12], 1.0f, "plane oriented toward the box");
	nearf(out[15], -0.0f - 1.0f, "dist moved one unit outwards");

	/* overrides and a zero range */
	f.overrides.density = 0.25f;
	n = MTL_VolFogPackRegions(&f, eye2, out, MTL_VOLFog_MAX_REGIONS);
	nearf(out[11], 0.25f, "gl_fogdensity override reaches the volume");
	f.overrides.density = -1;
	f.regions[0].range = 0;
	n = MTL_VolFogPackRegions(&f, eye2, out, MTL_VOLFog_MAX_REGIONS);
	nearf(out[11], 0.0f, "a zero range has no maximum opacity");
	f.regions[0].range = 50;

	/* fog modes */
	f.mode = 2;
	check(MTL_VolFogPackRegions(&f, eye2, out, MTL_VOLFog_MAX_REGIONS) == 0, "fog mode 2 packs nothing");
	f.mode = 3;
	check(MTL_VolFogPackRegions(&f, eye2, out, MTL_VOLFog_MAX_REGIONS) == 0, "fog mode 3 packs nothing");
	f.mode = 0;
	free(f.regions);
}

/* ------------------------------------------------------------------ the raymarch on a real GPU */
static id<MTLTexture> gpu_target(id<MTLDevice> dev, MTLPixelFormat fmt, int w, int h, MTLTextureUsage usage)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
	d.storageMode = (fmt == MTLPixelFormatDepth32Float) ? MTLStorageModePrivate : MTLStorageModeShared;
	d.usage = usage;
	return [dev newTextureWithDescriptor:d];
}

/* Clear depth texture to known depth by drawing a triangle at depth z. */
static void gpu_fill_depth(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLTexture> depth, float z)
{
	static id<MTLRenderPipelineState> pipe;
	static id<MTLDepthStencilState> ds;
	if (!pipe) {
		NSError *e = nil;
		id<MTLLibrary> l = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
			"vertex float4 v(uint i [[vertex_id]], constant float &z [[buffer(0)]]){float2 p=float2(i==1?3:-1,i==2?3:-1);return float4(p,z,1);}\n" options:nil error:&e];
		MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
		pd.vertexFunction = [l newFunctionWithName:@"v"];
		pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
		pipe = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
		MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
		dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES;
		ds = [dev newDepthStencilStateWithDescriptor:dd];
	}
	id<MTLCommandBuffer> cb = [q commandBuffer];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear;
	rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = 1;
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:pipe]; [enc setDepthStencilState:ds];
	[enc setVertexBytes:&z length:sizeof(z) atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
}

static id<MTLRenderPipelineState> gpu_pipeline(id<MTLDevice> dev, BOOL mrt, MTLPixelFormat c0, MTLPixelFormat c1)
{
	NSError *e = nil;
	NSString *src = [NSString stringWithFormat:@"%@\n%@", MTL_PostMSLPreamble(mrt), mtl_volfog_msl];
	id<MTLLibrary> l = [dev newLibraryWithSource:src options:nil error:&e];
	if (!l) { fprintf(stderr, "MSL: %s\n", e.localizedDescription.UTF8String); return nil; }
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [l newFunctionWithName:@"mtl_vs_volfog"];
	d.fragmentFunction = [l newFunctionWithName:@"mtl_fs_volfog"];
	MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[0];
	ca.pixelFormat = c0; ca.blendingEnabled = YES;
	ca.sourceRGBBlendFactor = ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
	ca.destinationRGBBlendFactor = ca.destinationAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	if (mrt) { d.colorAttachments[1] = [ca copy]; d.colorAttachments[1].pixelFormat = c1; }
	d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
	if (!p) fprintf(stderr, "pipeline: %s\n", e.localizedDescription.UTF8String);
	return p;
}

/* One fog region around the camera, identity invpv (world = NDC, eye behind the screen): the fog colour must weigh in
 * exactly as the GL shader's formula and the destination is scaled by T, on both attachments. */
static void gpu(void)
{
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	if (!dev) { printf("no Metal device, GPU checks skipped\n"); return; }
	id<MTLCommandQueue> q = [dev newCommandQueue];
	const int W = 16, H = 16;
	id<MTLTexture> depth = gpu_target(dev, MTLPixelFormatDepth32Float, W, H, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
	id<MTLTexture> color = gpu_target(dev, MTLPixelFormatBGRA8Unorm, W, H, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
	id<MTLTexture> emis = gpu_target(dev, MTLPixelFormatRGBA8Unorm, W, H, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
	id<MTLTexture> sdepth = gpu_target(dev, MTLPixelFormatDepth32Float, W, H, MTLTextureUsageRenderTarget);
	const float zscene = 0.8f;
	gpu_fill_depth(dev, q, depth, zscene);
	id<MTLRenderPipelineState> pipe = gpu_pipeline(dev, YES, MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA8Unorm);
	check(pipe != nil, "volumetric MSL compiles (MRT)");
	check(gpu_pipeline(dev, NO, MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid) != nil, "volumetric MSL compiles (single target)");
	if (!pipe) return;

	mtl_volfog_uniform_t u;
	memset(&u, 0, sizeof(u));
	u.invpv[0] = u.invpv[5] = u.invpv[10] = u.invpv[15] = 1;
	float eye[3] = {0, 0, -1};
	u.eye[0] = eye[0]; u.eye[1] = eye[1]; u.eye[2] = eye[2]; u.eye[3] = 0;
	u.prm[0] = 0; u.prm[1] = 1; u.prm[2] = 0.4f; u.prm[3] = 0;
	u.prm2[0] = 1; u.prm2[1] = 16; u.prm2[2] = 0; u.prm2[3] = 0;
	float *v = u.vr;
	v[0] = -2; v[1] = -2; v[2] = -2; v[3] = 0.9f;   /* mins, extinction */
	v[4] = 2; v[5] = 2; v[6] = 2; v[7] = 0;         /* maxs, no height falloff */
	v[8] = 0.8f; v[9] = 0.4f; v[10] = 0.2f; v[11] = 0.75f; /* colour, max opacity */
	for (int k = 0; k < 5; k++) { v[12 + k * 4 + 3] = -1; }

	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = color; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
	rp.colorAttachments[1].texture = emis; rp.colorAttachments[1].loadAction = MTLLoadActionClear;
	rp.colorAttachments[1].storeAction = MTLStoreActionStore; rp.colorAttachments[1].clearColor = MTLClearColorMake(0.6, 0.6, 0.6, 1);
	rp.depthAttachment.texture = sdepth; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:pipe];
	[enc setCullMode:MTLCullModeNone];
	[enc setFragmentBytes:&u length:offsetof(mtl_volfog_uniform_t, vr) + 32 * sizeof(float) atIndex:0];
	[enc setFragmentTexture:depth atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
	check(cb.error == nil, "volumetric pass executed");

	unsigned char px[16][16][4], pe[16][16][4];
	[color getBytes:px bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
	[emis getBytes:pe bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
	float worst = 0, worste = 0;
	for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
		float nx = 2 * (x + .5f) / W - 1, ny = 1 - 2 * (y + .5f) / H;
		float d[3] = {nx - eye[0], ny - eye[1], zscene - eye[2]};
		float len = std::sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2]);
		/* region is -2..2, the scene point at z 0.8 inside it: the whole ray is fog */
		float al = 0.75f * 0.4f * (1 - std::exp(-0.9f * 1.0f * len));
		float T = 1 - al;
		/* pixel is BGRA: px[y][x][0]=B, [1]=G, [2]=R */
		float diff[3] = {std::fabs(px[y][x][2] / 255.0f - (0.8f*al + 0.25f*T)),
		                 std::fabs(px[y][x][1] / 255.0f - (0.4f*al + 0.5f*T)),
		                 std::fabs(px[y][x][0] / 255.0f - (0.2f*al + 0.75f*T))};
		for (int i = 0; i < 3; i++) { if (diff[i] > worst) worst = diff[i]; }
		float de = std::fabs(pe[y][x][0] / 255.0f - 0.6f * T);
		if (de > worste) worste = de;
	}
	if (worst > 1.5f / 255) fprintf(stderr, "worst colour difference %.3f/255\n", worst * 255);
	check(worst <= 1.5f / 255, "fog weight and source-alpha blend match the GL formula");
	check(worste <= 1.5f / 255, "emission buffer is attenuated by the same T");
}

int main(void)
{
	math();
	pack_parity();
	gpu();
	printf("VolFog checks: %d passed, %d failed\n", checks - failures, failures);
	return failures ? 1 : 0;
}