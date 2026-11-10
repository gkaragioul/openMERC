// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Cascaded sun shadows of the Metal renderer (r_om_csm): depth maps, casters and the receiver state.
// Adapted from the GPL gl3_csm.c; maths in mtl_csm_math.h, shaders in mtl_csm_shader.h.
// Implements: SPEC-AMEND-016 R16.2 and R16.4; docs/impl/GFX-modern.md section 4.
//
// As in GL: two depth maps per cascade, the static world (opaque world faces) and the dynamic casters (Ghoul models as
// drawn in the previous frame). The lightmaps already hold the static shadows, so the world is darkened only where the
// static world lets the sun through and a dynamic caster blocks it. Ghoul ground shadows give way in the sun.
// Include after mtl_post.h, mtl_csm_shader.h and the model/encoder globals.
#ifndef OM_METAL_CSM_H
#define OM_METAL_CSM_H
#include "mtl_csm_math.h"
#include <stdarg.h>

#define MTL_CSM_MAXDYN (3 * 1024 * 1024) /* floats of captured caster triangles */

static cvar_t *mtl_csm_cvar, *mtl_csm_cascades_cvar, *mtl_csm_size_cvar, *mtl_csm_soft_cvar, *mtl_csm_bias_cvar;
static cvar_t *mtl_csm_normalbias_cvar, *mtl_csm_split_cvar, *mtl_csm_maxdist_cvar, *mtl_csm_replace_ghl_cvar;
static cvar_t *mtl_csm_strength_cvar, *mtl_csm_debug_cvar;

typedef struct {
	BOOL failed, active, capture, replace, have_dyn_box;
	int size, ncasc, numstatic, numdyn, maxdyn;
	id<MTLTexture> map;
	id<MTLRenderPipelineState> caster;
	id<MTLDepthStencilState> caster_depth;
	id<MTLBuffer> statics;
	id<MTLRenderCommandEncoder> bound;
	const mtl_model_t *built;
	float wmins[3], wmaxs[3];
	float *dyn;
	mtl_csm_sun_t sun;
	float X[3], Y[3], Z[3];
	mtl_csm_uniform_t u;
	float dyn_lx[2], dyn_ly[2];
	float last_static[MTL_CSM_MAXCASC][16];
	BOOL static_valid[MTL_CSM_MAXCASC], dyn_dirty[MTL_CSM_MAXCASC];
} mtl_csm_state_t;
static mtl_csm_state_t mtl_csm;

static void MTL_CSMPrint(int level, const char *format, ...)
{
	va_list argptr;
	va_start(argptr, format);
	ri.Com_VPrintf(level, format, argptr);
	va_end(argptr);
}
#define R_Printf MTL_CSMPrint

static void MTL_CSMInfo(void);

static void MTL_CSMInit(void)
{
	mtl_csm_cvar = ri.Cvar_Get("r_om_csm", "1", CVAR_ARCHIVE);
	mtl_csm_cascades_cvar = ri.Cvar_Get("r_om_csm_cascades", "4", CVAR_ARCHIVE);
	mtl_csm_size_cvar = ri.Cvar_Get("r_om_csm_size", "2048", CVAR_ARCHIVE);
	mtl_csm_soft_cvar = ri.Cvar_Get("r_om_csm_soft", "2", CVAR_ARCHIVE);
	mtl_csm_bias_cvar = ri.Cvar_Get("r_om_csm_bias", "0.0015", CVAR_ARCHIVE);
	mtl_csm_normalbias_cvar = ri.Cvar_Get("r_om_csm_normalbias", "0.02", CVAR_ARCHIVE);
	mtl_csm_split_cvar = ri.Cvar_Get("r_om_csm_split", "0.75", CVAR_ARCHIVE);
	mtl_csm_maxdist_cvar = ri.Cvar_Get("r_om_csm_maxdist", "2048", CVAR_ARCHIVE);
	mtl_csm_replace_ghl_cvar = ri.Cvar_Get("r_om_csm_replace_ghl", "1", CVAR_ARCHIVE);
	mtl_csm_strength_cvar = ri.Cvar_Get("r_om_csm_strength", "0.65", CVAR_ARCHIVE);
	mtl_csm_debug_cvar = ri.Cvar_Get("r_om_csm_debug", "0", 0);
	free(mtl_csm.dyn);
	mtl_csm = (mtl_csm_state_t){};
	ri.Cmd_AddCommand("r_om_csm_info", MTL_CSMInfo);
}

static void MTL_CSMShutdown(void)
{
	free(mtl_csm.dyn);
	mtl_csm.dyn = NULL;
	mtl_csm.map = nil;
	mtl_csm.caster = nil;
	mtl_csm.caster_depth = nil;
	mtl_csm.statics = nil;
	mtl_csm.bound = nil;
	mtl_csm.built = NULL;
	mtl_csm.active = mtl_csm.failed = NO;
	mtl_csm.numdyn = mtl_csm.maxdyn = mtl_csm.size = mtl_csm.ncasc = 0;
	mtl_world_csm_variant = 0;
	ri.Cmd_RemoveCommand("r_om_csm_info");
}

/* the compiler's sun keys of worldspawn, when a map is loaded (SPEC-AMEND-016 R16.2) */
static void MTL_CSMLoadSun(const char *ents, int len)
{
	float tosun[3];
	MTL_CSMParseSun(ents, len, &mtl_csm.sun);
	mtl_csm.built = NULL; /* the static casters of the new map */
	mtl_csm.numdyn = 0;
	memset(mtl_csm.static_valid, 0, sizeof(mtl_csm.static_valid));
	memcpy(tosun, mtl_csm.sun.tosun, sizeof(tosun));
	MTL_CSMAxes(tosun, mtl_csm.X, mtl_csm.Y, mtl_csm.Z);
	if (mtl_csm.sun.valid)
		R_Printf(PRINT_DEVELOPER, "CSM: sun from %s, toward (%.3f %.3f %.3f), light %g\n", mtl_csm.sun.how,
			mtl_csm.sun.tosun[0], mtl_csm.sun.tosun[1], mtl_csm.sun.tosun[2], mtl_csm.sun.light);
	else
		R_Printf(PRINT_DEVELOPER, "CSM: no directional sun in this map\n");
}

static BOOL MTL_CSMObjects(void)
{
	if (mtl_csm.caster) return YES;
	NSError *error = nil;
	id<MTLLibrary> library = [mtl_device newLibraryWithSource:mtl_csm_caster_msl options:nil error:&error];
	if (!library) { Com_Printf("r_om_csm: shader failed, shadows off: %s\n", error.localizedDescription.UTF8String); return NO; }
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.label = @"openMerc sun shadow casters";
	d.vertexFunction = [library newFunctionWithName:@"mtl_vs_csm_caster"];
	d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	id<MTLRenderPipelineState> pipeline = [mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
	if (!pipeline) { Com_Printf("r_om_csm: pipeline failed, shadows off: %s\n", error.localizedDescription.UTF8String); return NO; }
	MTLDepthStencilDescriptor *depth = [MTLDepthStencilDescriptor new];
	depth.depthCompareFunction = MTLCompareFunctionLess;
	depth.depthWriteEnabled = YES;
	mtl_csm.caster_depth = [mtl_device newDepthStencilStateWithDescriptor:depth];
	mtl_csm.caster = pipeline;
	return YES;
}

static BOOL MTL_CSMCreateMap(int size, int ncasc)
{
	if (mtl_csm.map && mtl_csm.size == size && mtl_csm.ncasc == ncasc) return YES;
	mtl_csm.map = nil;
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:(NSUInteger)size height:(NSUInteger)size mipmapped:NO];
	d.textureType = MTLTextureType2DArray;
	d.arrayLength = (NSUInteger)(2 * ncasc);
	d.storageMode = MTLStorageModePrivate;
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	mtl_csm.map = [mtl_device newTextureWithDescriptor:d];
	if (!mtl_csm.map) { Com_Printf("r_om_csm: shadow map allocation failed, shadows off\n"); return NO; }
	mtl_csm.map.label = @"openMerc sun shadow maps";
	mtl_csm.size = size;
	mtl_csm.ncasc = ncasc;
	memset(mtl_csm.static_valid, 0, sizeof(mtl_csm.static_valid));
	for (int c = 0; c < MTL_CSM_MAXCASC; c++) mtl_csm.dyn_dirty[c] = YES; /* new layers: cleared on the first frame */
	return YES;
}

/* the opaque faces of the world model (not brush entities) as one triangle list */
static void MTL_CSMBuildStatic(void)
{
	mtl_model_t *w = mtl_worldmodel;
	const mtl_model_t *sub = w->numsubmodels > 0 ? &w->submodels[0] : w;
	int first = sub->firstsurface, count = sub->nummodelsurfaces, total = 0, n = 0;
	if (first < 0 || first + count > w->numsurfaces) { first = 0; count = w->numsurfaces; }
	const mtl_world_vertex_t *source = (const mtl_world_vertex_t *)[(__bridge id<MTLBuffer>)w->vbuf contents];
	const int skip = SURF_SKY | SURF_WARP | SURF_TRANS33 | SURF_TRANS66 | SURF_NODRAW | 0x800 | 0x10000;

	mtl_csm.built = w;
	mtl_csm.numstatic = 0;
	mtl_csm.statics = nil;
	mtl_csm.wmins[0] = mtl_csm.wmins[1] = mtl_csm.wmins[2] = 0;
	mtl_csm.wmaxs[0] = mtl_csm.wmaxs[1] = mtl_csm.wmaxs[2] = 0;
	memset(mtl_csm.static_valid, 0, sizeof(mtl_csm.static_valid));

	for (int i = first; i < first + count; i++) {
		const mtl_surface_t *s = &w->surfaces[i];
		if ((s->texinfo && (s->texinfo->flags & skip)) || s->num_vertex < 3) continue;
		total += s->num_vertex;
	}
	if (!total) return;

	id<MTLBuffer> buffer = [mtl_device newBufferWithLength:(NSUInteger)total * 3 * sizeof(float) options:MTLResourceStorageModeShared];
	if (!buffer) return;
	float *v = (float *)buffer.contents, lo[3] = {1e30f, 1e30f, 1e30f}, hi[3] = {-1e30f, -1e30f, -1e30f};
	for (int i = first; i < first + count; i++) {
		const mtl_surface_t *s = &w->surfaces[i];
		if ((s->texinfo && (s->texinfo->flags & skip)) || s->num_vertex < 3) continue;
		for (int j = 0; j < s->num_vertex; j++) {
			const float *p = source[s->first_vertex + j].pos;
			for (int k = 0; k < 3; k++) {
				v[n + k] = p[k];
				if (p[k] < lo[k]) lo[k] = p[k];
				if (p[k] > hi[k]) hi[k] = p[k];
			}
			n += 3;
		}
	}
	memcpy(mtl_csm.wmins, lo, sizeof(lo));
	memcpy(mtl_csm.wmaxs, hi, sizeof(hi));
	mtl_csm.statics = buffer;
	mtl_csm.numstatic = n / 3;
	R_Printf(PRINT_DEVELOPER, "CSM: %d static caster triangles\n", mtl_csm.numstatic / 3);
}

static BOOL MTL_CSMWant(void)
{
	if (!mtl_csm_cvar || !mtl_csm_cvar->value || !mtl_csm.sun.valid || mtl_csm.failed || !mtl_worldmodel) return NO;
	if (mtl_refdef.rdflags & (RDF_NOWORLDMODEL | RDF_IRGOGGLES)) return NO;
	if (mtl_fullbright_cvar && mtl_fullbright_cvar->value) return NO;
	return YES;
}

static BOOL MTL_CSMActive(void) { return mtl_csm.active; }

/* one layer pass: clear, draw the triangle list */
static void MTL_CSMPass(int layer, const float vp[16], id<MTLBuffer> buffer, NSUInteger offset, int vertices)
{
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.depthAttachment.texture = mtl_csm.map;
	pass.depthAttachment.slice = (NSUInteger)layer;
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.storeAction = MTLStoreActionStore;
	pass.depthAttachment.clearDepth = 1.0;
	id<MTLRenderCommandEncoder> encoder = [mtl_cb renderCommandEncoderWithDescriptor:pass];
	if (!encoder) return;
	if (vertices > 0) {
		MTLViewport viewport = {0, 0, (double)mtl_csm.size, (double)mtl_csm.size, 0, 1};
		[encoder setViewport:viewport];
		[encoder setRenderPipelineState:mtl_csm.caster];
		[encoder setDepthStencilState:mtl_csm.caster_depth];
		[encoder setCullMode:MTLCullModeNone];
		[encoder setDepthBias:2.0f slopeScale:1.5f clamp:0];
		[encoder setVertexBuffer:buffer offset:offset atIndex:0];
		[encoder setVertexBytes:vp length:16 * sizeof(float) atIndex:1];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)vertices];
	}
	[encoder endEncoding];
}

/* before the view's passes begin: the cascades and both depth maps (GL3_CSM_Frame) */
static void MTL_CSMFrame(float fov_x, float fov_y)
{
	int size, ncasc;
	mtl_csm.active = NO;
	mtl_csm.bound = nil;
	mtl_world_csm_variant = 0;
	if (!MTL_CSMWant()) { mtl_csm.numdyn = 0; mtl_csm.have_dyn_box = NO; return; }
	if (!MTL_CSMObjects()) { mtl_csm.failed = YES; return; }

	size = (int)mtl_csm_size_cvar->value;
	size = (size >= 4096) ? 4096 : (size >= 2048) ? 2048 : (size >= 1024) ? 1024 : 512;
	ncasc = (int)mtl_csm_cascades_cvar->value;
	ncasc = (ncasc < 1) ? 1 : (ncasc > MTL_CSM_MAXCASC) ? MTL_CSM_MAXCASC : ncasc;
	if (!MTL_CSMCreateMap(size, ncasc)) { mtl_csm.failed = YES; return; }
	if (mtl_csm.built != mtl_worldmodel) MTL_CSMBuildStatic();

	mtl_csm_view_t view;
	mtl_csm_config_t config;
	mtl_csm_cascade_t cascades[MTL_CSM_MAXCASC];
	vec3_t forward, right, up;
	AngleVectors(mtl_refdef.viewangles, forward, right, up);
	memcpy(view.origin, mtl_refdef.vieworg, sizeof(view.origin));
	memcpy(view.forward, forward, sizeof(view.forward));
	memcpy(view.right, right, sizeof(view.right));
	memcpy(view.up, up, sizeof(view.up));
	view.fov_x = fov_x;
	view.fov_y = fov_y;
	config.ncasc = ncasc;
	config.size = size;
	config.lambda = mtl_csm_split_cvar->value;
	config.maxdist = mtl_csm_maxdist_cvar->value;
	config.strength = mtl_csm_strength_cvar->value;
	config.normalbias = mtl_csm_normalbias_cvar->value;
	config.soft = mtl_csm_soft_cvar->value;
	config.bias = mtl_csm_bias_cvar->value;
	config.replace_ghl = mtl_csm_replace_ghl_cvar->value != 0;
	config.debug = mtl_csm_debug_cvar->value != 0;
	MTL_CSMCompute(&mtl_csm.u, cascades, &mtl_csm.sun, mtl_csm.wmins, mtl_csm.wmaxs, &view, &config);
	for (int c = 0; c < ncasc; c++)
		MTL_CSMDynRect(mtl_csm.u.dynrect[c], &cascades[c], size, mtl_csm.u.params[2], mtl_csm.have_dyn_box,
			mtl_csm.dyn_lx[0], mtl_csm.dyn_lx[1], mtl_csm.dyn_ly[0], mtl_csm.dyn_ly[1]);

	/* the depth maps: outside the view's render passes, as GL renders them before SetupGL */
	mtl_frame_targets_t targets = mtl_current_targets;
	MTL_TargetEnd();
	id<MTLBuffer> dynbuffer = nil;
	NSUInteger dynoffset = 0;
	if (mtl_csm.numdyn > 0)
		dynbuffer = MTL_FrameUpload(mtl_csm.dyn, (NSUInteger)mtl_csm.numdyn * sizeof(float), &dynoffset);
	int numdyn = dynbuffer ? mtl_csm.numdyn / 3 : 0;
	for (int c = 0; c < ncasc; c++) {
		/* a static layer is valid while the cascade's whole-texel matrix does not change (standing still) */
		if (!mtl_csm.static_valid[c] || memcmp(mtl_csm.last_static[c], mtl_csm.u.vp[c], 16 * sizeof(float))) {
			MTL_CSMPass(c, mtl_csm.u.vp[c], mtl_csm.statics, 0, mtl_csm.numstatic);
			memcpy(mtl_csm.last_static[c], mtl_csm.u.vp[c], 16 * sizeof(float));
			mtl_csm.static_valid[c] = YES;
		}
		if (numdyn > 0 || mtl_csm.dyn_dirty[c]) {
			MTL_CSMPass(ncasc + c, mtl_csm.u.vp[c], dynbuffer, dynoffset, numdyn);
			mtl_csm.dyn_dirty[c] = numdyn > 0;
		}
	}
	if (!MTL_TargetResume(mtl_cb, &targets)) MTL_Fatal("CSM", "could not resume the frame after the shadow maps");

	mtl_csm.numdyn = 0;
	mtl_csm.have_dyn_box = NO;
	mtl_csm.active = YES;
	mtl_world_csm_variant = 1;
}

static void MTL_CSMEndView(void)
{
	mtl_world_csm_variant = 0;
	mtl_csm.bound = nil;
}

/* bind the shadow map and its block on this encoder, once (fragment buffer 7, texture 8: not used by anything else) */
static void MTL_CSMBindReceiver(void)
{
	if (!mtl_csm.active || mtl_enc == mtl_csm.bound) return;
	[mtl_enc setFragmentBytes:&mtl_csm.u length:sizeof(mtl_csm.u) atIndex:7];
	[mtl_enc setFragmentTexture:mtl_csm.map atIndex:8];
	mtl_csm.bound = mtl_enc;
}

/* Ghoul triangles as drawn, in world space, for the next frame's dynamic layers (GL: opaque, depth-writing triangles) */
static void MTL_CSMCaptureDraw(const om_ghoul_native_draw_t *draw)
{
	if (!mtl_csm.active || draw->vertex_count < 3) return;
	int count = (int)draw->vertex_count;
	count -= count % 3;
	if (count <= 0 || mtl_csm.numdyn + (size_t)count * 3 > MTL_CSM_MAXDYN) return;
	if (mtl_csm.numdyn + count * 3 > mtl_csm.maxdyn) {
		int want = mtl_csm.numdyn + count * 3, cap = mtl_csm.maxdyn ? mtl_csm.maxdyn : 65536;
		while (cap < want) cap *= 2;
		if (cap > MTL_CSM_MAXDYN) cap = MTL_CSM_MAXDYN;
		float *d = (float *)realloc(mtl_csm.dyn, (size_t)cap * sizeof(float));
		if (!d) return;
		mtl_csm.dyn = d;
		mtl_csm.maxdyn = cap;
	}
	const float *m = draw->model_to_world;
	const float *X = mtl_csm.X, *Y = mtl_csm.Y;
	float *o = mtl_csm.dyn + mtl_csm.numdyn;
	float lx0, lx1, ly0, ly1;
	if (mtl_csm.have_dyn_box) { lx0 = mtl_csm.dyn_lx[0]; lx1 = mtl_csm.dyn_lx[1]; ly0 = mtl_csm.dyn_ly[0]; ly1 = mtl_csm.dyn_ly[1]; }
	else { lx0 = ly0 = 1e30f; lx1 = ly1 = -1e30f; }
	for (int i = 0; i < count; i++, o += 3) {
		const float x = draw->vertices[i].position[0], y = draw->vertices[i].position[1], z = draw->vertices[i].position[2];
		/* the column layout the draw gives the vertex stage */
		o[0] = m[0] * x + m[4] * y + m[8] * z + m[12];
		o[1] = m[1] * x + m[5] * y + m[9] * z + m[13];
		o[2] = m[2] * x + m[6] * y + m[10] * z + m[14];
		const float lx = X[0] * o[0] + X[1] * o[1] + X[2] * o[2], ly = Y[0] * o[0] + Y[1] * o[1] + Y[2] * o[2];
		if (lx < lx0) lx0 = lx;
		if (lx > lx1) lx1 = lx;
		if (ly < ly0) ly0 = ly;
		if (ly > ly1) ly1 = ly;
	}
	mtl_csm.numdyn += count * 3;
	mtl_csm.dyn_lx[0] = lx0; mtl_csm.dyn_lx[1] = lx1;
	mtl_csm.dyn_ly[0] = ly0; mtl_csm.dyn_ly[1] = ly1;
	mtl_csm.have_dyn_box = YES;
}

/* r_om_csm_info: what the loaded map gives (the layer coverage dump of GL is not ported) */
static void MTL_CSMInfo(void)
{
	if (!mtl_csm.sun.valid) { R_Printf(PRINT_ALL, "CSM: no directional sun in this map\n"); return; }
	R_Printf(PRINT_ALL, "CSM: sun from %s, toward (%.3f %.3f %.3f), colour (%.2f %.2f %.2f), light %g, "
		"ambient (%.3f %.3f %.3f), %s, %d static / %d dynamic caster triangles\n", mtl_csm.sun.how,
		mtl_csm.sun.tosun[0], mtl_csm.sun.tosun[1], mtl_csm.sun.tosun[2], mtl_csm.sun.color[0], mtl_csm.sun.color[1], mtl_csm.sun.color[2],
		mtl_csm.sun.light, mtl_csm.sun.ambient[0], mtl_csm.sun.ambient[1], mtl_csm.sun.ambient[2], mtl_csm.active ? "active" : "inactive",
		mtl_csm.numstatic / 3, mtl_csm.numdyn / 9);
}
#endif
