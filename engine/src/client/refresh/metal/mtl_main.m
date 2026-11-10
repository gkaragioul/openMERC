/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * Copyright (C) 2026 OpenMerc contributors
 *
 * OpenMerc native Metal renderer (macOS / Apple Silicon).
 *
 * Implements: SPEC-002 (renderer module interface); the 2D part of SPEC-800..803
 * (menus), SPEC-310 (HUD) and SPEC-413 (console and 2D drawing).
 *
 * Milestone M1: window + CAMetalLayer + presentation, textures and the complete
 * 2D path (pictures, charset glyphs, fills, tiles, fades, raw cinematic frames).
 * RenderFrame does not draw the world yet; see docs/METAL.md for the milestones.
 * There is no OpenGL anywhere in this renderer.
 */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>

#include <SDL3/SDL.h>

#include <sys/stat.h>
#include <limits.h>

#include "../../../common/header/common.h"
#include "../../../common/header/sof/refapi.h"
#include "../../../ghoul/ghoul_host.h"
#include "../../vid/header/ref.h"
#include "../ref_shared.h"

#define MTL_VERTEX_STRIDE (8 * sizeof(float)) /* pos2 uv2 rgba4 */

typedef struct mtl_vertex_s
{
	float x, y;
	float u, v;
	float r, g, b, a;
} mtl_vertex_t;

typedef struct mtl_image_s
{
	char name[MAX_QPATH];
	imagetype_t type;
	int width, height;
	int registration_sequence;
	qboolean has_alpha;
	float sl, tl, sh, th;
	void *tex;              /* id<MTLTexture>, +1 retained */
	struct mtl_image_s *detail;
	struct mtl_image_s *damage; /* SPEC-413 step 8: shown once the surface is damaged */
	float detail_scale[2], detail_shift[2];
	int kind, animrate;
	int declared_m32_flags; /* file flags at0x2c4, independent of decoded alpha */
	float detail_scroll[2];
	unsigned detail_scroll_frame;
	BOOL raw_image;        /* SPEC-413 RAW filtering differs from PIC/FONT */
} mtl_image_t;

/* ---- state ------------------------------------------------------- */

refimport_t ri; /* ref.h declares it extern; each renderer defines it */

static id<MTLDevice> mtl_device;
static id<MTLCommandQueue> mtl_queue;
static dispatch_semaphore_t mtl_inflight;
static CAMetalLayer *mtl_layer;
static SDL_MetalView mtl_view;
static id<CAMetalDrawable> mtl_drawable;
static id<CAMetalDrawable> mtl_last_drawable; /* retained for between-frame thumbnails */
static id<MTLCommandBuffer> mtl_cb;
static id<MTLRenderCommandEncoder> mtl_enc;
static id<MTLRenderPipelineState> mtl_pipe2d;
static id<MTLRenderPipelineState> mtl_pipe_sof2d;
static id<MTLRenderPipelineState> mtl_pipe_sof2d_replace;
static id<MTLSamplerState> mtl_samp_ui;
static id<MTLSamplerState> mtl_samp_ui_linear;
static id<MTLSamplerState> mtl_samp_clamp;
static id<MTLSamplerState> mtl_samp_repeat;
static id<MTLSamplerState> mtl_samp_world;
/* Ghoul owns material sampler state.  Keep it separate from the generic
 * image samplers: normal skins select a nearest mip level, while _NOMIP
 * skins are nearest-filtered at level zero exactly as the GL path requests. */
static id<MTLSamplerState> mtl_ghoul_samplers[2][2][2]; /* U wrap, V wrap, no mip */
static id<MTLTexture> mtl_white;

static SDL_Window *mtl_window;
static int mtl_width, mtl_height;   /* drawable size in pixels */
static float mtl_ui_w, mtl_ui_h;    /* logical 2D size the engine draws in */
static float mtl_sof_dirtable[250][3];
static int mtl_sof_dircount;
static qboolean mtl_encoder_open;
static qboolean mtl_vsync;
static refdef_t mtl_refdef;

static unsigned mtl_palette[256];
static mtl_image_t *draw_chars;
static cvar_t *mtl_vsync_cvar;
#ifdef OM_RLABS_KIT
#include "rlk_hud.h"
#include "rlk_vrr.h"
static cvar_t *mtl_perfhud_cvar; /* r_perfhud: Apple's Metal Performance HUD (Video page; RLabs kit) */
static cvar_t *mtl_vrr_cvar;     /* r_vrr: variable refresh in full screen (RLabs kit rlk_vrr, default 1) */
static int mtl_vrr;              /* frames presented when ready (afterMinimumDuration) */
static double mtl_vrr_fastest;   /* the screen's fastest refresh, Hz */
#endif
static byte mtl_colortable[256];      /* SPEC-413 §9 image colour table */
static cvar_t *vid_gamma;
static cvar_t *vid_brightness;
static cvar_t *vid_contrast;
static cvar_t *mtl_nearclip_cvar;
static cvar_t *mtl_farclip_cvar;
static cvar_t *mtl_skymip_cvar;
static cvar_t *mtl_ghoul_debug_cvar;
static cvar_t *mtl_ghoul_light_method_cvar;
static cvar_t *mtl_ghoul_light_multiply_cvar;
static cvar_t *mtl_ghoul_specular_cvar;
static int mtl_ghoul_specular_state = -1;
static cvar_t *mtl_ghoul_max_lights_cvar;
static cvar_t *mtl_ghoul_fast_lights_cvar;
static cvar_t *mtl_ghoul_mip_cvar;
static cvar_t *mtl_ghoul_gllight_directional_cvar;
static cvar_t *mtl_ghoul_gllight_attenuation_cvar;
static cvar_t *mtl_ghoul_gllight_max_lights_cvar;
static cvar_t *mtl_ghoul_local_viewer_cvar;
static cvar_t *mtl_modulate_cvar;
static cvar_t *mtl_monolightmap_cvar;
static float mtl_modulate_latched = 1.0f;
static int mtl_monolightmap_mode;
static cvar_t *mtl_gunfov_cvar;
static cvar_t *mtl_particle_size_cvar;
static cvar_t *mtl_particle_debug_cvar;
static cvar_t *mtl_fullbright_cvar;
static cvar_t *mtl_world_debug_cvar;
static cvar_t *mtl_nocull_cvar;
static cvar_t *mtl_cull_cvar, *mtl_drawflat_cvar;
/* GFX-modern: native Metal implementation of GL3's per-pixel SoF dynamic
 * lights.  Keep the user-facing controls identical so captures can use the
 * same bounded test-light fixture on both renderers. */
static cvar_t *mtl_pdlight_cvar;
static cvar_t *mtl_pdlight_max_cvar;
static cvar_t *mtl_pdlight_scale_cvar;
static cvar_t *mtl_pdlight_normal_cvar;
static cvar_t *mtl_pdlight_soft_cvar;
static cvar_t *mtl_pdlight_test_cvar;
static cvar_t *mtl_gl_dynamic_cvar;
static cvar_t *mtl_texturemode_cvar;
static cvar_t *mtl_scissor_broken_cvar;
static cvar_t *mtl_anisotropic_cvar;
static cvar_t *mtl_ext_anisotropic_cvar;
static cvar_t *mtl_detail_cvar, *mtl_detail_distance_cvar;
static cvar_t *mtl_offset_factor_cvar, *mtl_offset_units_cvar;
static id<MTLTexture> mtl_lighttable; /* the table as a 256 x 1 texture */

static void MTL_SoF_BuildColorTable(float g, float b, float c, float d);
static void MTL_SoF_CorrectColours(byte *rgba, size_t npix, const char *name);
static void MTL_SoF_HUDShutdown(void);
static void MTL_SoF_HUDResetState(void);
static void MTL_HUDSetScissorBroken(float value);
static void MTL_HUDApplyClip(int width, int height);
static void MTL_HUDSetRawLinear(BOOL linear);
static void MTL_SoF_Set2D(int restore);
static void MTL_FXShutdown(void);

#ifndef DEG2RAD
#define DEG2RAD(x) ((x) * 0.017453292519943295769f)
#endif
#ifndef RAD2DEG
#define RAD2DEG(x) ((x) * 57.295779513082320876f)
#endif

/* world pass state (defined in the M2 section below) */
static id<MTLTexture> mtl_depth;
static id<MTLRenderPipelineState> mtl_pipe_world;
static id<MTLRenderPipelineState> mtl_pipe_sky;
static id<MTLDepthStencilState> mtl_depth_world;
static id<MTLDepthStencilState> mtl_depth_readonly;
static id<MTLDepthStencilState> mtl_depth_2d;
static id<MTLRenderPipelineState> mtl_pipe_alias;
static id<MTLRenderPipelineState> mtl_pipe_alias_alpha;
static id<MTLRenderPipelineState> mtl_pipe_alias_additive;
static id<MTLRenderPipelineState> mtl_pipe_ghoul;
static id<MTLRenderPipelineState> mtl_pipe_fx_alpha, mtl_pipe_fx_additive, mtl_pipe_fx_darken;
static id<MTLRenderPipelineState> mtl_pipe_detail, mtl_pipe_detail_replace;
static id<MTLRenderPipelineState> mtl_pipe_particles;
static id<MTLRenderPipelineState> mtl_pipe_turb_opaque;
static id<MTLRenderPipelineState> mtl_pipe_turb_alpha;
static id<MTLDepthStencilState> mtl_depth_sky;
static cvar_t *mtl_fullscreen_cvar;
static cvar_t *mtl_mode_cvar;
static void *mtl_ghoul_system;
static float mtl_ghoul_mvp[16]; /* current world projection x view, set synchronously per entity */
static BOOL mtl_menu_active, mtl_menu_saved, mtl_menu_clip_saved;
static float mtl_menu_mvp[16];

static void MTL_GhoulDraw(void *ctx, const om_ghoul_native_draw_t *draw);
static void MTL_GhoulShadow(void *ctx, const om_ghoul_native_shadow_t *shadow);
static void MTL_TerrainFree(void);
static om_ghoul_native_sink_t mtl_ghoul_sink = {NULL, NULL, MTL_GhoulDraw, NULL, NULL, 0, MTL_GhoulShadow};
static struct image_s *MTL_FindImage(const char *name, imagetype_t type);

#include "mtl_readback.h"

/* ------------------------------------------------------------------ */

static void
MTL_Fatal(const char *what, const char *detail)
{
	ri.Sys_Error(ERR_FATAL, "ref_metal: %s failed: %s", what, detail ? detail : "unknown");
}

static void
MTL_WarnMissing(const char *pic)
{
	Com_Printf("ref_metal: can't find pic: %s\n", pic);
}

/* ---- textures ---------------------------------------------------- */

static void *
MTL_NewTextureChain(const byte *rgba, int w, int h, qboolean mipmap)
{
	MTLTextureDescriptor *desc =
		[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		                                                   width:(NSUInteger)w
		                                                  height:(NSUInteger)h
		                                               mipmapped:mipmap ? YES : NO];
	desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	desc.storageMode = MTLStorageModeManaged;

	id<MTLTexture> tex = [mtl_device newTextureWithDescriptor:desc];
	if (!tex)
	{
		return NULL;
	}

	[tex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
	       mipmapLevel:0
	         withBytes:rgba
	       bytesPerRow:(NSUInteger)w * 4];

	/* Generic non-SoF images use the driver-built chain, like GL3_Upload32.
	 * SoF .m32 images use their own stored chain below, as GL3 UploadM32 does.
	 * Pics, the sky and lightmaps are not mipmapped. */
	if (mipmap && (w > 1 || h > 1))
	{
		id<MTLCommandBuffer> cb = [mtl_queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];

		[blit generateMipmapsForTexture:tex];
		[blit endEncoding];
		[cb commit];
	}

	return (void *)CFBridgingRetain(tex);
}

/* Implements: SPEC-100 (stored mip chain), SPEC-413 §8/9 (upload/correction).
 * LoadM32 has already validated the contiguous halving chain down to 1x1.
 * Keep its exact image data instead of regenerating lower levels from a
 * colour-corrected level zero, which is a different nonlinear operation. */
static void *
MTL_NewStoredTextureChain(const byte *rgba, int w, int h)
{
	MTLTextureDescriptor *desc =
		[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		                                                   width:(NSUInteger)w
		                                                  height:(NSUInteger)h
		                                               mipmapped:YES];
	desc.usage = MTLTextureUsageShaderRead;
	desc.storageMode = MTLStorageModeShared;
	id<MTLTexture> tex = [mtl_device newTextureWithDescriptor:desc];
	if (!tex)
	{
		return NULL;
	}
	size_t offset = 0;
	for (NSUInteger level = 0;; level++)
	{
		[tex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
		       mipmapLevel:level withBytes:rgba + offset bytesPerRow:(NSUInteger)w * 4];
		offset += (size_t)w * h * 4;
		if (w == 1 && h == 1)
		{
			break;
		}
		w = w > 1 ? w / 2 : 1;
		h = h > 1 ? h / 2 : 1;
	}
	return (void *)CFBridgingRetain(tex);
}

/* Ghoul explicitly builds its own `(sum + 2) >> 2` mip data before handing
 * it to the GL table. Keep that data path for the native sink instead of
 * asking Metal to generate a different chain. */
static void
MTL_GhoulDownsample(const byte *src, int w, int h, byte *dst, int nw, int nh)
{
	for (int y = 0; y < nh; y++)
	{
		for (int x = 0; x < nw; x++)
		{
			int x0 = (2 * x) % w, x1 = (2 * x + 1) % w;
			int y0 = (2 * y) % h, y1 = (2 * y + 1) % h;
			for (int c = 0; c < 4; c++)
			{
				int sum = src[((size_t)y0 * w + x0) * 4 + c] +
				          src[((size_t)y0 * w + x1) * 4 + c] +
				          src[((size_t)y1 * w + x0) * 4 + c] +
				          src[((size_t)y1 * w + x1) * 4 + c];
				dst[((size_t)y * nw + x) * 4 + c] = (byte)((sum + 2) >> 2);
			}
		}
	}
}

static void *
MTL_NewGhoulTextureChain(const byte *rgba, int w, int h, qboolean nomip, int detail)
{
	if (!rgba || w <= 0 || h <= 0)
		return NULL;
	if (detail < 0)
		detail = 0;
	byte *current = malloc((size_t)w * h * 4);
	if (!current)
		return NULL;
	memcpy(current, rgba, (size_t)w * h * 4);
	int cw = w, ch = h;
	while (detail-- > 0 && (cw > 1 || ch > 1))
	{
		int nw = cw > 1 ? cw / 2 : 1;
		int nh = ch > 1 ? ch / 2 : 1;
		byte *next = malloc((size_t)nw * nh * 4);
		if (!next)
		{
			free(current);
			return NULL;
		}
		MTL_GhoulDownsample(current, cw, ch, next, nw, nh);
		free(current);
		current = next;
		cw = nw;
		ch = nh;
	}
	MTLTextureDescriptor *desc =
		[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		                                                   width:(NSUInteger)cw
		                                                  height:(NSUInteger)ch
		                                               mipmapped:nomip ? NO : YES];
	desc.usage = MTLTextureUsageShaderRead;
	desc.storageMode = MTLStorageModeManaged;
	id<MTLTexture> tex = [mtl_device newTextureWithDescriptor:desc];
	if (!tex)
	{
		free(current);
		return NULL;
	}
	for (NSUInteger level = 0;; level++)
	{
		[tex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)cw, (NSUInteger)ch)
		       mipmapLevel:level withBytes:current bytesPerRow:(NSUInteger)cw * 4];
		if (nomip || (cw == 1 && ch == 1))
			break;
		int nw = cw > 1 ? cw / 2 : 1;
		int nh = ch > 1 ? ch / 2 : 1;
		byte *next = malloc((size_t)nw * nh * 4);
		if (!next)
		{
			free(current);
			return NULL;
		}
		MTL_GhoulDownsample(current, cw, ch, next, nw, nh);
		free(current);
		current = next;
		cw = nw;
		ch = nh;
	}
	free(current);
	return (void *)CFBridgingRetain(tex);
}

/* RLabs (2026-11-05, play-tester: "game is not locked at 120hz", "lots of drops"): every Ghoul draw used to build a new
 * Metal texture from the decoded pixels - a CPU mip chain, an upload, one draw, then release - each frame, for every
 * model part on screen. Sampling a 120 fps run showed it as the main-thread cost behind the 12-64 ms frames. The
 * Ghoul texture cache keeps its decoded pixels while a level runs (PurgeImages frees unused ones between levels), so
 * one Metal texture per decoded image is built once and reused; the cache is emptied at every level registration
 * and renderer shutdown. Key: the pixel pointer plus the image name, size, nomip and detail level. */
#define MTL_GHOUL_TEXCACHE 4096
typedef struct
{
	const void *rgba;
	unsigned name_hash;
	int w, h, nomip, detail;
	void *tex; /* CFBridgingRetain'd id<MTLTexture> */
} mtl_ghoul_texcache_t;
static mtl_ghoul_texcache_t mtl_ghoul_texcache[MTL_GHOUL_TEXCACHE];
static int mtl_ghoul_texcache_count;

static void
MTL_GhoulTexCacheFlush(void)
{
	for (int i = 0; i < MTL_GHOUL_TEXCACHE; i++)
	{
		if (mtl_ghoul_texcache[i].tex)
			CFRelease(mtl_ghoul_texcache[i].tex);
	}
	memset(mtl_ghoul_texcache, 0, sizeof(mtl_ghoul_texcache));
	mtl_ghoul_texcache_count = 0;
}

static unsigned
MTL_GhoulNameHash(const char *name)
{
	unsigned h = 2166136261u;
	for (; name && *name; name++)
		h = (h ^ (unsigned char)*name) * 16777619u;
	return h;
}

static void *MTL_NewGhoulTextureChain(const byte *rgba, int w, int h, qboolean nomip, int detail);

/* a texture owned by the cache (do not release); NULL when it cannot be built */
static void *
MTL_GhoulCachedTexture(const byte *rgba, const char *name, int w, int h, qboolean nomip, int detail)
{
	const unsigned nh = MTL_GhoulNameHash(name);
	size_t key = (size_t)rgba ^ ((size_t)nh << 7) ^ ((size_t)w * 73856093u) ^ ((size_t)h * 19349663u) ^
		((size_t)detail << 3) ^ (size_t)(nomip ? 1 : 0);
	unsigned slot = (unsigned)((key ^ (key >> 17) ^ (key >> 31)) % MTL_GHOUL_TEXCACHE);

	for (int probe = 0; probe < MTL_GHOUL_TEXCACHE; probe++, slot = (slot + 1) % MTL_GHOUL_TEXCACHE)
	{
		mtl_ghoul_texcache_t *e = &mtl_ghoul_texcache[slot];
		if (!e->tex)
			break;
		if (e->rgba == rgba && e->name_hash == nh && e->w == w && e->h == h && e->nomip == (nomip ? 1 : 0) &&
			e->detail == detail)
			return e->tex;
	}

	if (mtl_ghoul_texcache_count >= MTL_GHOUL_TEXCACHE * 3 / 4)
	{
		/* far more images than a level uses: start over rather than probe a full table */
		MTL_GhoulTexCacheFlush();
		slot = (unsigned)((key ^ (key >> 17) ^ (key >> 31)) % MTL_GHOUL_TEXCACHE);
	}

	void *tex = MTL_NewGhoulTextureChain(rgba, w, h, nomip, detail);
	if (!tex)
		return NULL;
	while (mtl_ghoul_texcache[slot].tex)
		slot = (slot + 1) % MTL_GHOUL_TEXCACHE;
	mtl_ghoul_texcache[slot] = (mtl_ghoul_texcache_t){rgba, nh, w, h, nomip ? 1 : 0, detail, tex};
	mtl_ghoul_texcache_count++;
	return tex;
}

/* 8-bit palette pixels or 32-bit RGBA -> RGBA8 */
/*
 * SPEC-413 §9: T[0] = 0; for i = 1..255: x = (i + 0.5) / 255.5,
 * v = 255 x^(1 - g) + 0.5, k = (1.5 - c)^3 for c < 0.5 else (1.5 - c)^0.5,
 * w = 128 (1 + s (|v - 128| / 128)^k), T[i] = (w + 160 b - 80) d clamped and
 * truncated. Same function as the GL3 reference (gl3_image.c); the SoF look
 * comes entirely from baking this into the images at load time.
 */
static void
MTL_SoF_BuildColorTable(float g, float b, float c, float d)
{
	int i;
	double k = (c < 0.5f) ? pow(1.5 - c, 3.0) : pow(1.5 - c, 0.5);

	mtl_colortable[0] = 0;

	for (i = 1; i < 256; i++)
	{
		double x = (i + 0.5) / 255.5;
		double v = 255.0 * pow(x, 1.0 - g) + 0.5;
		double s = (v >= 128.0) ? 1.0 : -1.0;
		double w = 128.0 * (1.0 + s * pow(fabs(v - 128.0) / 128.0, k));
		double t = (w + 160.0 * b - 80.0) * d;

		if (t < 0)
		{
			t = 0;
		}
		else if (t > 255)
		{
			t = 255;
		}

		mtl_colortable[i] = (byte)t;
	}
}

static byte *
MTL_ToRGBA(const byte *pic, int w, int h, size_t npix, int bits, qboolean *has_alpha)
{
	byte *out = malloc(npix * 4);
	if (!out)
	{
		return NULL;
	}

	*has_alpha = false;

	if (bits == 8)
	{
		for (size_t i = 0; i < npix; i++)
		{
			unsigned c = mtl_palette[pic[i]];
			out[i * 4 + 0] = (byte)(c & 0xff);
			out[i * 4 + 1] = (byte)((c >> 8) & 0xff);
			out[i * 4 + 2] = (byte)((c >> 16) & 0xff);
			out[i * 4 + 3] = (byte)((c >> 24) & 0xff);
		}
	}
	else
	{
		memcpy(out, pic, npix * 4);
	}

	for (size_t i = 0; i < npix; i++)
	{
		if (out[i * 4 + 3] != 255)
		{
			*has_alpha = true;
			break;
		}
	}

	return out;
}

/* loadimage_t callback used by the shared image loaders (files/ dir) */
/*
 * SPEC-413 §9: colour correction of every stored level, except detail
 * (kind 0x2: uploaded as luminance from the red channel) and environment
 * (kind 0x8) images. The kind lives at 0x378 of the .m32 header (SPEC-100),
 * which the loadimage callback does not receive, so the file is read again.
 */
static void
MTL_SoF_CorrectColours(byte *rgba, size_t npix, const char *name)
{
	const char *dot = strrchr(name, '.');
	byte *m = NULL;
	int size, kind = 0;

	if (!dot || strcmp(dot, ".m32"))
	{
		return;
	}

	size = ri.FS_LoadFile(name, (void **)&m);

	if (m && size >= 0x3C8)
	{
		kind = LittleLong(*(const int *)(m + 0x378));
	}

	if (m)
	{
		ri.FS_FreeFile(m);
	}

	if (kind & 0x8)
	{
		return; /* environment map: uploaded untouched */
	}

	if (kind & 0x2)
	{
		for (size_t i = 0; i < npix; i++)
		{
			rgba[i * 4 + 1] = rgba[i * 4 + 2] = rgba[i * 4 + 0];
			rgba[i * 4 + 3] = 255;
		}
		return;
	}

	for (size_t i = 0; i < npix; i++)
	{
		rgba[i * 4 + 0] = mtl_colortable[rgba[i * 4 + 0]];
		rgba[i * 4 + 1] = mtl_colortable[rgba[i * 4 + 1]];
		rgba[i * 4 + 2] = mtl_colortable[rgba[i * 4 + 2]];
	}
}

static struct image_s *
MTL_LoadPic(const char *name, byte *pic, int width, int realwidth,
            int height, int realheight, size_t data_size,
            imagetype_t type, int bits)
{
	(void)realwidth; (void)realheight;
	size_t npix = (size_t)width * (size_t)height;
	const qboolean stored_mips = bits == 32 && type != it_pic && type != it_sky &&
		!Q_stricmp(COM_FileExtension(name), "m32") && data_size > npix;
	if (stored_mips)
	{
		/* For .m32 this is a validated pixel count, not a byte count. */
		npix = data_size;
	}
	qboolean alpha = false;
	byte *rgba = MTL_ToRGBA(pic, width, height, npix, bits, &alpha);
	if (!rgba)
	{
		return NULL;
	}

	MTL_SoF_CorrectColours(rgba, npix, name);

	mtl_image_t *img = calloc(1, sizeof(*img));
	Q_strlcpy(img->name, name, sizeof(img->name));
	img->type = type;
	img->width = width;
	img->height = height;
	img->has_alpha = alpha;
	img->sh = 1.0f;
	img->th = 1.0f;
	img->tex = stored_mips ? MTL_NewStoredTextureChain(rgba, width, height) :
		MTL_NewTextureChain(rgba, width, height, (type != it_pic && type != it_sky));

	free(rgba);

	if (!img->tex)
	{
		free(img);
		return NULL;
	}
	/* SPEC-410 second-pass material metadata. Image loading is recursive,
	 * but malformed self/cyclic detail references must remain bounded. */
	static int detail_depth;
	if (!Q_stricmp(COM_FileExtension(name), "m32"))
	{
		byte *m = NULL;
		int size = ri.FS_LoadFile(name, (void **)&m);
		if (m && size >= 0x3c8)
		{
			img->declared_m32_flags = LittleLong(*(const int *)(m + 0x2c4));
			img->kind = LittleLong(*(const int *)(m + 0x378));
			img->animrate = LittleLong(*(const int *)(m + 0x2cc)) & 255;
			char detail_name[129], path[MAX_QPATH];
			memcpy(detail_name, m + 0x2dc, 128);
			detail_name[128] = 0;
			if (detail_name[0] && detail_depth < 8)
			{
				Com_sprintf(path, sizeof(path), "textures/%s.m32", detail_name);
				if (Q_stricmp(path, name))
				{
					detail_depth++;
					img->detail = (mtl_image_t *)MTL_FindImage(path, it_wall);
					detail_depth--;
				}
			}
			/* SPEC-413 step 8: the damaged variant is a wall image; chains load recursively (same depth bound) */
			char damage_name[129];
			memcpy(damage_name, m + 0x184, 128);
			damage_name[128] = 0;
			if (damage_name[0])
			{
				Com_sprintf(path, sizeof(path), "textures/%s.m32", damage_name);
				if (!Q_stricmp(path, name))
					Com_Printf("GL_FindImage: Recursvive damage texture (%s)\n", name);
				else if (detail_depth < 8)
				{
					detail_depth++;
					img->damage = (mtl_image_t *)MTL_FindImage(path, it_wall);
					detail_depth--;
				}
			}
			memcpy(img->detail_scale, m + 0x35c, sizeof(img->detail_scale));
			memcpy(img->detail_shift, m + 0x364, sizeof(img->detail_shift));
		}
		if (m)
			ri.FS_FreeFile(m);
	}

	return (struct image_s *)img;
}

/* name arrives with its extension from R_FindPic / the model loaders */
static struct image_s *
MTL_FindImage(const char *name, imagetype_t type)
{
	char ext[8] = {0};
	const char *dot = strrchr(name, '.');

	if (dot && strlen(dot + 1) < sizeof(ext))
	{
		Q_strlcpy(ext, dot + 1, sizeof(ext));
	}

	if (!ext[0])
	{
		return NULL;
	}

	if (!strcmp(ext, "m32") || !strcmp(ext, "m8"))
	{
		return R_LoadImage(name, name, ext, type, false, (loadimage_t)MTL_LoadPic);
	}

	if (!strcmp(ext, "pcx") || !strcmp(ext, "wal") ||
	    !strcmp(ext, "tga") || !strcmp(ext, "png") || !strcmp(ext, "jpg"))
	{
		return R_LoadImage(name, name, ext, type, false, (loadimage_t)MTL_LoadPic);
	}

	return NULL;
}

static mtl_image_t *
MTL_FindPic(const char *name)
{
	return (mtl_image_t *)R_FindPic(name, (findimage_t)MTL_FindImage);
}

/* ---- shaders: runtime MSL (no offline metal tool on this host) ---- */

static NSString *const mtl_shader_source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VSIn
{
	float2 pos;
	float2 uv;
	float4 color;
};

struct VSOut
{
	float4 position [[position]];
	float2 uv;
	float4 color;
};

vertex VSOut mtl_vs_2d(const device VSIn *verts [[buffer(0)]],
                       constant float2 &target [[buffer(1)]],
                       uint vid [[vertex_id]])
{
	VSOut o;
	VSIn v = verts[vid];
	/* pixel space, top-left origin -> NDC; Metal NDC is Y-up, as in GL */
	o.position = float4(v.pos.x / target.x * 2.0 - 1.0,
	                    1.0 - v.pos.y / target.y * 2.0,
	                    0.0, 1.0);
	o.uv = v.uv;
	o.color = v.color;
	return o;
}

fragment float4 mtl_fs_2d(VSOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          sampler smp [[sampler(0)]])
{
	float4 t = tex.sample(smp, in.uv);
	return float4(t.rgb * in.color.rgb, t.a * in.color.a);
}

fragment float4 mtl_fs_sof2d(VSOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler smp [[sampler(0)]])
{
	float4 c = tex.sample(smp, in.uv) * in.color;
	if (c.a <= 0.05) discard_fragment();
	return c;
}
)MSL";

static id<MTLRenderPipelineState>
MTL_BuildPipeline(BOOL sof, BOOL blend)
{
	NSError *err = nil;
	id<MTLLibrary> lib = [mtl_device newLibraryWithSource:mtl_shader_source options:nil error:&err];
	if (!lib)
	{
		MTL_Fatal("MSL compile", err ? err.localizedDescription.UTF8String : NULL);
		return nil;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.label = @"openMerc 2D";
	desc.vertexFunction = [lib newFunctionWithName:@"mtl_vs_2d"];
	desc.fragmentFunction = [lib newFunctionWithName:sof ? @"mtl_fs_sof2d" : @"mtl_fs_2d"];

	MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
	vd.attributes[0].format = MTLVertexFormatFloat2;
	vd.attributes[0].offset = 0;
	vd.attributes[0].bufferIndex = 0;
	vd.attributes[1].format = MTLVertexFormatFloat2;
	vd.attributes[1].offset = sizeof(float) * 2;
	vd.attributes[1].bufferIndex = 0;
	vd.attributes[2].format = MTLVertexFormatFloat4;
	vd.attributes[2].offset = sizeof(float) * 4;
	vd.attributes[2].bufferIndex = 0;
	vd.layouts[0].stride = MTL_VERTEX_STRIDE;
	vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
	desc.vertexDescriptor = vd;

	MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
	ca.pixelFormat = mtl_layer.pixelFormat;
	ca.blendingEnabled = blend;
	ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	ca.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

	id<MTLRenderPipelineState> pipe = [mtl_device newRenderPipelineStateWithDescriptor:desc error:&err];
	if (!pipe)
	{
		MTL_Fatal("2D pipeline", err ? err.localizedDescription.UTF8String : NULL);
	}

	return pipe;
}

static id<MTLSamplerState>
MTL_MakeSampler(BOOL repeat)
{
	MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
	d.minFilter = MTLSamplerMinMagFilterLinear;
	d.magFilter = MTLSamplerMinMagFilterLinear;
	d.mipFilter = MTLSamplerMipFilterLinear;
	d.sAddressMode = repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
	d.tAddressMode = repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
	return [mtl_device newSamplerStateWithDescriptor:d];
}

static id<MTLSamplerState>
MTL_MakeGhoulSampler(BOOL repeat_u, BOOL repeat_v, BOOL nomip)
{
	MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
	d.minFilter = nomip ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
	d.magFilter = nomip ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
	d.mipFilter = nomip ? MTLSamplerMipFilterNotMipmapped : MTLSamplerMipFilterNearest;
	d.sAddressMode = repeat_u ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
	d.tAddressMode = repeat_v ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
	return [mtl_device newSamplerStateWithDescriptor:d];
}

/* Implements: SPEC-413 §8. Diffuse world images own their filter state;
 * don't share the UI/lightmap/Ghoul samplers merely because they repeat. */
static void
MTL_UpdateWorldSampler(void)
{
	if (mtl_samp_world && !mtl_texturemode_cvar->modified &&
	    !mtl_anisotropic_cvar->modified && !mtl_ext_anisotropic_cvar->modified)
	{
		return;
	}
	const char *mode = mtl_texturemode_cvar->string;
	MTLSamplerDescriptor *d = [[MTLSamplerDescriptor alloc] init];
	d.sAddressMode = MTLSamplerAddressModeRepeat;
	d.tAddressMode = MTLSamplerAddressModeRepeat;
	d.minFilter = d.magFilter = MTLSamplerMinMagFilterLinear;
	d.mipFilter = MTLSamplerMipFilterLinear;
	if (!Q_stricmp(mode, "GL_NEAREST"))
	{
		d.minFilter = d.magFilter = MTLSamplerMinMagFilterNearest;
		d.mipFilter = MTLSamplerMipFilterNotMipmapped;
	}
	else if (!Q_stricmp(mode, "GL_LINEAR"))
	{
		d.mipFilter = MTLSamplerMipFilterNotMipmapped;
	}
	else if (!Q_stricmp(mode, "GL_NEAREST_MIPMAP_NEAREST"))
	{
		d.minFilter = d.magFilter = MTLSamplerMinMagFilterNearest;
		d.mipFilter = MTLSamplerMipFilterNearest;
	}
	else if (!Q_stricmp(mode, "GL_LINEAR_MIPMAP_NEAREST"))
	{
		d.mipFilter = MTLSamplerMipFilterNearest;
	}
	else if (!Q_stricmp(mode, "GL_NEAREST_MIPMAP_LINEAR"))
	{
		d.minFilter = d.magFilter = MTLSamplerMinMagFilterNearest;
	}
	else if (Q_stricmp(mode, "GL_LINEAR_MIPMAP_LINEAR"))
	{
		Com_Printf("ref_metal: bad texture filter name: %s\n", mode);
		/* As GL3 does, an invalid mode leaves the current sampler alone. */
		if (mtl_samp_world)
		{
			mtl_texturemode_cvar->modified = false;
			return;
		}
	}
	float a = mtl_ext_anisotropic_cvar->value ? 2.0f : 1.0f;
	if (mtl_anisotropic_cvar->value >= 1.0f)
	{
		a = mtl_anisotropic_cvar->value;
	}
	d.maxAnisotropy = (NSUInteger)Q_max(1.0f, Q_min(a, 16.0f));
	mtl_samp_world = [mtl_device newSamplerStateWithDescriptor:d];
	mtl_texturemode_cvar->modified = false;
	mtl_anisotropic_cvar->modified = false;
	mtl_ext_anisotropic_cvar->modified = false;
}

/* ---- frame -------------------------------------------------------- */

static void
MTL_UpdateSizes(void)
{
	int dw = mtl_width, dh = mtl_height;

	if (mtl_window)
	{
		SDL_GetWindowSizeInPixels(mtl_window, &dw, &dh);
	}
	if (dw <= 0 || dh <= 0)
	{
		dw = 1280;
		dh = 720;
	}

	mtl_width = dw;
	mtl_height = dh;

	if (mtl_layer)
	{
		mtl_layer.drawableSize = CGSizeMake(dw, dh);
	}

	if (mtl_device && (!mtl_depth || mtl_depth.width != (NSUInteger)dw ||
	                   mtl_depth.height != (NSUInteger)dh))
	{
		MTLTextureDescriptor *dd =
			[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
			                                                   width:(NSUInteger)dw
			                                                  height:(NSUInteger)dh
			                                               mipmapped:NO];
		dd.usage = MTLTextureUsageRenderTarget;
		dd.storageMode = MTLStorageModePrivate;
		mtl_depth = [mtl_device newTextureWithDescriptor:dd];
	}

	mtl_ui_w = (float)mtl_refdef.width;
	mtl_ui_h = (float)mtl_refdef.height;
	if (mtl_ui_w <= 0.0f || mtl_ui_h <= 0.0f)
	{
		mtl_ui_w = (float)dw;
		mtl_ui_h = (float)dh;
	}
}

static id<MTLRenderPipelineState>
MTL_SoF2DPipeline(BOOL blend)
{
	return blend ? mtl_pipe_sof2d : mtl_pipe_sof2d_replace;
}

static id<MTLSamplerState>
MTL_MakeUISampler(BOOL linear)
{
	MTLSamplerDescriptor *desc = [MTLSamplerDescriptor new];
	/* SPEC-413 PIC/FONT/RAW retain GL's repeat texture-object state. */
	desc.sAddressMode = desc.tAddressMode = MTLSamplerAddressModeRepeat;
	desc.minFilter = desc.magFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
	desc.mipFilter = MTLSamplerMipFilterNotMipmapped;
	return [mtl_device newSamplerStateWithDescriptor:desc];
}

static void
MTL_SubmitQuad(const mtl_vertex_t vtx[6], id<MTLTexture> tex, BOOL repeat, BOOL sof, BOOL blend, BOOL linear)
{
	if (!mtl_encoder_open || !tex)
	{
		return;
	}

	float target[2] = {mtl_ui_w, mtl_ui_h};

	[mtl_enc setRenderPipelineState:sof ? MTL_SoF2DPipeline(blend) : mtl_pipe2d];
	[mtl_enc setDepthStencilState:mtl_depth_2d];
	[mtl_enc setCullMode:MTLCullModeNone];
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
	[mtl_enc setVertexBytes:vtx length:sizeof(mtl_vertex_t) * 6 atIndex:0];
	[mtl_enc setVertexBytes:&target length:sizeof(target) atIndex:1];
	[mtl_enc setFragmentTexture:tex atIndex:0];
	[mtl_enc setFragmentSamplerState:sof ? (linear ? mtl_samp_ui_linear : mtl_samp_ui) :
		(repeat ? mtl_samp_repeat : mtl_samp_clamp) atIndex:0];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

static void
MTL_DrawQuad(const mtl_vertex_t vtx[6], id<MTLTexture> tex, BOOL repeat)
{
	MTL_SubmitQuad(vtx, tex, repeat, NO, YES, NO);
}

static void
MTL_Quad(float x, float y, float w, float h,
         float u0, float v0, float u1, float v1,
         const float c[4], id<MTLTexture> tex, BOOL repeat)
{
	mtl_vertex_t v[6] = {
		{x,     y,     u0, v0, c[0], c[1], c[2], c[3]},
		{x + w, y,     u1, v0, c[0], c[1], c[2], c[3]},
		{x + w, y + h, u1, v1, c[0], c[1], c[2], c[3]},
		{x,     y,     u0, v0, c[0], c[1], c[2], c[3]},
		{x + w, y + h, u1, v1, c[0], c[1], c[2], c[3]},
		{x,     y + h, u0, v1, c[0], c[1], c[2], c[3]},
	};
	MTL_DrawQuad(v, tex, repeat);
}

static void
MTL_DrawImage(mtl_image_t *img, float x, float y, float w, float h, float alpha)
{
	if (!img || !img->tex)
	{
		return;
	}
	float c[4] = {1.0f, 1.0f, 1.0f, alpha};
	MTL_Quad(x, y, w, h, img->sl, img->tl, img->sh, img->th, c,
	         (__bridge id<MTLTexture>)img->tex, NO);
}

/* ---- screenshots -------------------------------------------------- */

static int shot_pending;
static char shot_name[MAX_QPATH];

static void
MTL_Screenshot_f(void)
{
	if (ri.Cmd_Argc() > 1)
	{
		Q_strlcpy(shot_name, ri.Cmd_Argv(1), sizeof(shot_name));
	}
	else
	{
		shot_name[0] = 0;
	}
	shot_pending = 1;
}

/* BGRA8 drawable -> uncompressed 24-bit TGA, bottom row first (the engine's format) */
static void
MTL_WriteScreenshot(id<MTLTexture> tex, const byte *bgra, size_t bytes_per_row)
{
	char path[MAX_OSPATH];
	char dir[MAX_OSPATH];
	FILE *f;

	/* RLabs 2026-11-05: in the player's writable game folder (-user), not relative to the working directory: the
	   Mac app runs from inside its bundle, and "./user/scrnshot" wrote into the signed app (run 0079) */
	{
		const char *gd = ri.FS_Gamedir ? ri.FS_Gamedir() : NULL;

		if (gd && gd[0])
		{
			Com_sprintf(dir, sizeof(dir), "%s/scrnshot", gd);
		}
		else
		{
			Q_strlcpy(dir, "./user/scrnshot", sizeof(dir));
			mkdir("./user", 0755);
		}
	}
	mkdir(dir, 0755);

	if (shot_name[0])
	{
		Com_sprintf(path, sizeof(path), "%s/%s.tga", dir, shot_name);
	}
	else
	{
		for (int n = 0;; n++)
		{
			Com_sprintf(path, sizeof(path), "%s/sof%02d.tga", dir, n);
			f = fopen(path, "rb");
			if (!f)
			{
				break;
			}
			fclose(f);
			if (n > 98)
			{
				return;
			}
		}
	}

	f = fopen(path, "wb");
	if (!f)
	{
		Com_Printf("ref_metal: could not write %s\n", path);
		return;
	}

	byte header[18] = {0};
	header[2] = 2; /* uncompressed true colour */
	header[12] = (byte)(tex.width & 255);
	header[13] = (byte)((tex.width >> 8) & 255);
	header[14] = (byte)(tex.height & 255);
	header[15] = (byte)((tex.height >> 8) & 255);
	header[16] = 24;
	fwrite(header, 1, sizeof(header), f);

	for (int y = (int)tex.height - 1; y >= 0; y--)
	{
		const byte *row = bgra + (size_t)y * bytes_per_row;
		for (int x = 0; x < (int)tex.width; x++)
		{
			byte bgr[3] = {row[x * 4 + 0], row[x * 4 + 1], row[x * 4 + 2]};
			fwrite(bgr, 1, 3, f);
		}
	}

	fclose(f);
	Com_Printf("Wrote %s\n", path);
	shot_pending = 0;
}

static void
MTL_CaptureDrawable(void)
{
	if (!shot_pending || !mtl_drawable)
	{
		return;
	}

	NSUInteger w = mtl_drawable.texture.width;
	NSUInteger h = mtl_drawable.texture.height;
	NSUInteger bpr = (w * 4 + 255) & ~(NSUInteger)255;

	id<MTLBuffer> buf = [mtl_device newBufferWithLength:bpr * h
	                                           options:MTLResourceStorageModeShared];
	[mtl_cb presentDrawable:mtl_drawable];
	id<MTLBlitCommandEncoder> blit = [mtl_cb blitCommandEncoder];
	[blit copyFromTexture:mtl_drawable.texture
	          sourceSlice:0
	          sourceLevel:0
	         sourceOrigin:MTLOriginMake(0, 0, 0)
	           sourceSize:MTLSizeMake(w, h, 1)
	             toBuffer:buf
	    destinationOffset:0
	destinationBytesPerRow:bpr
	destinationBytesPerImage:bpr * h];
	[blit endEncoding];

	[mtl_cb commit];
	[mtl_cb waitUntilCompleted];

	MTL_WriteScreenshot(mtl_drawable.texture, (const byte *)buf.contents, bpr);

	return;
}


/* =================================================================== */
/* M2: world pass — BSP surfaces, lightmaps, depth                      */
/* =================================================================== */

#include "../../../common/header/files.h"
#include "mtl_brush_math.h"

typedef struct mtl_surface_s
{
	mtexinfo_t *texinfo;
	const cplane_t *bsp_plane; /* stable original plane identity for region boundaries */
	int plane_back;        /* the face lies on the back of bsp_plane (flags mixes SURF_PLANEBACK with texinfo bits) */
	vec3_t normal;         /* explicit BSP face normal, as in GL3 passNormal */
	vec3_t liquid_plane_normal; /* unflipped stored plane for SoF environment mapping */
	int flags;
	int visframe;
	unsigned dlightbits;   /* inline BSP marking; world keeps its current light path */
	byte styles[MAXLIGHTMAPS];
	const byte *samples;    /* raw RGB lightmaps, one block per used style */
	short lm_w, lm_h;
	short lm_step[2];
	short lm_mins[2];
	short lm_extents[2];
	int first_vertex, num_vertex;
	void *lightmap;         /* id<MTLTexture>, +1 */
	struct mtl_lightmap_s *lighting; /* owns all style planes; lightmap is a borrowed plane0 alias */
	vec3_t skyring[64];     /* sky faces: face ring for the sky box clip */
	int skyring_n;
} mtl_surface_t;

#define MTL_MAX_ALPHA_SURFACES 4096
static mtl_surface_t *mtl_alpha_surfaces[MTL_MAX_ALPHA_SURFACES];
static int mtl_alpha_count;

typedef struct mtl_model_s
{
	char name[MAX_QPATH];
	vec3_t mins, maxs, origin;
	int numsubmodels;
	struct mtl_model_s *submodels;
	int firstsurface, nummodelsurfaces, numsurfaces; /* view range; shared allocation count */
	struct mtl_model_s *owner; /* root owns data; inline descriptors borrow it */
	struct mtl_fog_world_s *fog; /* root-only allocation; inline descriptors use owner */
	void *hunk;
	int registration_sequence;
	mtl_image_t **owned_images;
	int num_owned_images;
	mtl_surface_t *surfaces;
	int numvertexes;
	mvertex_t *vertexes;
	int numedges;
	medge_t *edges;
	int numsurfedges;
	int *surfedges;
	int numtexinfo;
	mtexinfo_t *texinfo;
	byte *lightdata;
	int lightdata_bytes;
	dvis_t *vis;

	cplane_t *planes;
	int numplanes;
	mnode_t *nodes;
	int numnodes;
	int firstnode;
	mleaf_t *leafs;
	int numleafs;
	struct msurface_s **marksurfaces;
	int nummarksurfaces;
	void *vbuf;             /* id<MTLBuffer>, +1 */
	int vbuf_vertices;
	int bspversion;

	/* alias models (MD2/SP2) */
	modtype_t type;
	void *aliashdr;         /* dmdl_t * (MD2) or dsprite_t * (SP2) */
	size_t aliashdr_bytes;  /* validated allocation bound for command/frame parsing */
	mtl_image_t *skins[MAX_MD2SKINS];
	int numframes;
	float radius;
} mtl_model_t;

/* 32 bytes: MSL aligns float3 to 16, so the shader struct has a 4-byte gap after pos */
typedef struct mtl_world_vertex_s
{
	float pos[3];
	float pad;
	float uv[2];
	float luv[2];
} mtl_world_vertex_t;

#define MTL_WORLD_STRIDE (sizeof(mtl_world_vertex_t))

/* The GL3 parity path uploads at most the refapi's MAX_DLIGHTS (32). */
#define MTL_MAX_DLIGHTS MAX_DLIGHTS

/* alias (MD2/SP2) model vertex: pos, texcoord, light colour (SPEC-410 model lighting) */
typedef struct mtl_alias_vertex_s
{
	float pos[3];
	float pos_pad;          /* Metal float3 occupies a 16-byte slot */
	float uv[2];
	float uv_pad[2];        /* align float4 colour to the next 16-byte slot */
	float color[4];
} mtl_alias_vertex_t;

#define MTL_ALIAS_STRIDE (sizeof(mtl_alias_vertex_t))

_Static_assert(MTL_ALIAS_STRIDE == 48,
               "AliasVSIn must match Metal float3/float2/float4 alignment");

#define MTL_SHADEDOT_QUANT 16

/* per-yaw-angle light values for the MD2 vertex normals (same table as gl3_mesh.c) */
static float mtl_avertexnormal_dots[MTL_SHADEDOT_QUANT][256] = {
#include "../constants/anormtab.h"
};

typedef struct
{
	float mvp[16];
	float lm_adjust[2];     /* unused for now: lightmap is one texture */
	float overbright;
	float fullbright;
	/* GFX-modern r_om_pdlight: native layout mirrors the Metal Uniforms
	 * declaration below. Dynamic light colour is linear and intensity is in
	 * the .w component of the matching origin/radius record. */
	float pdlight[4];       /* enabled, scale, normal term, soft edge */
	float texdim[4];        /* diffuse texture dimensions in texture units */
	float dlight_meta[4];   /* active light count, then padding */
	float surface_normal[4];
	float surface_s[4];
	float surface_t[4];
	float dlight_origin_radius[MTL_MAX_DLIGHTS][4];
	float dlight_color[MTL_MAX_DLIGHTS][4];
} mtl_world_uniform_t;

_Static_assert(MTL_MAX_DLIGHTS == 32, "Metal world light arrays must match refapi MAX_DLIGHTS");
_Static_assert(sizeof(mtl_world_uniform_t) == 1200, "Metal world uniform ABI must match MSL");

/* Keep a frame-local copy only when the renderer's controlled diagnostic
 * light is requested.  This matches GL3_DynLight_TestLight: the test light
 * is part of the renderer refdef for this frame, so Ghoul and the world see
 * the same fixture without touching client-owned data. */
static dlight_t mtl_pdlight_test_lights[MTL_MAX_DLIGHTS];
static int mtl_pdlight_active_count;

static void
MTL_PrepareDynamicLights(void)
{
	float v[5] = {0, 64, 1, 1, 1};
	int n = mtl_refdef.num_dlights;

	if (n < 0)
	{
		n = 0;
	}

	if (mtl_pdlight_test_cvar && mtl_pdlight_test_cvar->string[0] &&
	    (mtl_pdlight_test_cvar->string[0] != '0') &&
	    !(mtl_refdef.rdflags & RDF_NOWORLDMODEL) && (n < MTL_MAX_DLIGHTS))
	{
		if (n > 0 && mtl_refdef.dlights)
		{
			memcpy(mtl_pdlight_test_lights, mtl_refdef.dlights, (size_t)n * sizeof(dlight_t));
		}
		sscanf(mtl_pdlight_test_cvar->string, "%f %f %f %f %f",
		       &v[0], &v[1], &v[2], &v[3], &v[4]);
		AngleVectors(mtl_refdef.viewangles, mtl_pdlight_test_lights[n].origin, NULL, NULL);
		/* AngleVectors writes a direction, then place the test light in front
		 * of the eye exactly as the GL3 fixture does. */
		for (int k = 0; k < 3; k++)
		{
			mtl_pdlight_test_lights[n].origin[k] = mtl_refdef.vieworg[k] +
				v[1] * mtl_pdlight_test_lights[n].origin[k];
			mtl_pdlight_test_lights[n].color[k] = v[k + 2];
		}
		mtl_pdlight_test_lights[n].intensity = v[0];
		mtl_refdef.dlights = mtl_pdlight_test_lights;
		mtl_refdef.num_dlights = ++n;
	}

	/* GL3 masks high bits according to r_om_pdlight_max.  A negative value
	 * means no additional cap; the fixed native shader capacity is 32. */
	if (n > MTL_MAX_DLIGHTS)
	{
		n = MTL_MAX_DLIGHTS;
	}
	if (mtl_pdlight_max_cvar && mtl_pdlight_max_cvar->value >= 0.0f &&
	    n > (int)mtl_pdlight_max_cvar->value)
	{
		n = (int)mtl_pdlight_max_cvar->value;
	}
	if (n < 0)
	{
		n = 0;
	}
	mtl_pdlight_active_count = n;
}

static id<MTLSamplerState> mtl_samp_lm;
static mtl_image_t *mtl_notexture;
static mtl_model_t *mtl_worldmodel;
#include "mtl_lightmap.h"
#include "mtl_fog.h"
static mtl_surface_t *mtl_detail_surfaces[1024];
static int mtl_detail_count;
static mtl_model_t **mtl_models;
static int mtl_nummodels;
static int mtl_registration_sequence;
static void MTL_ModelFence(void); /* coordinator supplies encoder-preserving GPU fence */
static void MTL_FreeModels(void);
static void MTL_GenericModelsShutdown(void);

#include "mtl_emission_state.h"
#include "mtl_overbright.h"
#include "mtl_post.h"
#include "mtl_fog_shaders.h"
#include "mtl_post_overlay.h"
#include "mtl_bloom.h"

static void
MTL_ProcessBloomView(void)
{
	MTL_TargetEnd();
	(void)MTL_BloomProcess(mtl_cb, mtl_post.scene, mtl_post.emissive,
		mtl_post.x, mtl_post.y, mtl_post.width, mtl_post.height, mtl_post.bloomthis);
}

static BOOL
MTL_CompositeBloomView(void)
{
	return MTL_BloomComposite(mtl_enc, mtl_post.scene, mtl_post.emissive,
		mtl_current_targets.color[0].pixelFormat,
		mtl_current_targets.depth ? mtl_current_targets.depth.pixelFormat : MTLPixelFormatInvalid,
		mtl_current_targets.samples, mtl_post.x, mtl_post.y, mtl_post.width, mtl_post.height,
		(int)mtl_framepost_debug->value, mtl_post.bloomthis);
}
static struct model_s *MTL_RegisterModel(const char *name);
static void MTL_DrawBrushModel(entity_t *entity, const float mvp[16]);
static float MTL_BrushSortKey(const entity_t *entity);

static NSString *const mtl_world_shader = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct WVSIn
{
	float3 pos;
	float2 uv;
	float2 luv;
};

struct WVOut
{
	float4 position [[position]];
	float2 uv;
	float2 luv;
	float3 worldpos;
};

struct Uniforms
{
	float4x4 mvp;
	float2 adjust;
	float overbright;
	float fullbright;
	float4 pdlight;
	float4 texdim;
	float4 dlight_meta;
	float4 surface_normal;
	float4 surface_s;
	float4 surface_t;
	float4 dlight_origin_radius[32];
	float4 dlight_color[32];
};

vertex WVOut mtl_vs_world(const device WVSIn *verts [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]],
                          uint vid [[vertex_id]])
{
	WVOut o;
	WVSIn v = verts[vid];
	o.position = u.mvp * float4(v.pos, 1.0);
	o.uv = v.uv;
	o.luv = v.luv;
	o.worldpos = v.pos;
	return o;
}

/* Implements: SPEC-410 (per-pixel SoF light rule). A planar BSP face already
 * owns the exact texture gradients which GL3 reconstructs with derivatives.
 * Use those analytic gradients to keep them invariant across fan triangles. */
float3 omSoFDlights(WVOut in, constant Uniforms &u)
{
	if (u.pdlight.x <= 0.5)
	{
		return float3(0.0);
	}
	float3 P = in.worldpos;
	float3 N = normalize(u.surface_normal.xyz);
	float3 gS = u.surface_s.xyz;
	float3 gT = u.surface_t.xyz;
	float3 sum = float3(0.0);
	for (int i = 0; i < int(u.dlight_meta.x); ++i)
	{
		float3 L = u.dlight_origin_radius[i].xyz;
		float d = dot(L - P, N);
		float r = u.dlight_origin_radius[i].w - abs(d);
		if (r < 64.0)
		{
			continue;
		}
		float3 v = (L - d * N) - P;
		float ds = abs(dot(v, gS));
		float dt = abs(dot(v, gT));
		float x = r - (max(ds, dt) + 0.5 * min(ds, dt));
		float add = (u.pdlight.w > 0.0) ? x * smoothstep(56.0, 56.0 + u.pdlight.w, x)
			: ((x >= 72.0) ? x : 72.0 * clamp((x - 56.0) / 16.0, 0.0, 1.0));
		if (u.pdlight.z > 0.0)
		{
			add *= mix(1.0, abs(dot(N, normalize(L - P))), u.pdlight.z);
		}
		sum += u.dlight_color[i].rgb * add;
	}
	return sum * (u.pdlight.y / 255.0);
}

fragment float4 mtl_fs_world(WVOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             texture2d<float> lmap [[texture(1)]],
                             texture2d<float> table [[texture(2)]],
                             sampler smp [[sampler(0)]],
                             sampler smplm [[sampler(1)]],
                             sampler smptb [[sampler(2)]],
                             constant Uniforms &u [[buffer(1)]])
{
	float4 t = tex.sample(smp, in.uv);
	/* SPEC-410 lightmap building: the summed light is rounded, clamped at 0,
	   scaled down when its brightest channel exceeds 255, and stored through
	   the SPEC-413 §9 image colour table; the GL3 reference does the same
	   lookup in its world shader (omColorTable). overbright stays 1.0. */
	float3 s = lmap.sample(smplm, in.luv).rgb;
	/* Implements: SPEC-410 (dynamic light accumulation). omSoFDlights is
	 * normalized to 0..1, just like the static lightmap. Sum before the
	 * byte-unit round/clamp/colour-table conversion, as GL3 does. */
	s += omSoFDlights(in, u);
	float3 omL = max(floor(s * 255.0 + 0.5), float3(0.0));
	float omA = max(omL.r, max(omL.g, omL.b));
	if (omA > 255.0)
	{
		omL = floor(omL * (255.0 / omA));
	}
	float3 lm;
	if (u.fullbright != 0.0)
	{
		lm = float3(1.0);
	}
	else
	{
		lm.r = table.sample(smptb, float2((omL.r + 0.5) / 256.0, 0.5)).r;
		lm.g = table.sample(smptb, float2((omL.g + 0.5) / 256.0, 0.5)).r;
		lm.b = table.sample(smptb, float2((omL.b + 0.5) / 256.0, 0.5)).r;
	}
	/* alpha-tested world textures (SoF .m32 flag 0x800, grates, fences);
	   the lightmap alpha is 1.0 in colour-table mode */
	if (t.a <= 0.05)
	{
		discard_fragment();
	}
	return float4(t.rgb * lm * u.overbright, t.a);
}
)MSL";

#include "mtl_csm_shader.h"
#include "mtl_lightmap_shader.h"

static id<MTLRenderPipelineState>
MTL_BuildWorldPipeline(void)
{
	mtl_pipeline_targets_t targets = MTL_PostPipelineTargets();
#ifdef OM_METAL_CSM_SHADER_H
	const int csm = mtl_world_csm_variant; /* the sun shadow receiver, only in frames with CSM (mtl_csm.h) */
#else
	const int csm = 0;
#endif
	id<MTLRenderPipelineState> cached = MTL_PostPipelineCached(MTL_POST_PIPE_WORLD, 0, csm, &targets);
	if (cached) return cached;
	NSError *err = nil;
	NSString *world_source = [NSString stringWithFormat:@"%@\n%@", mtl_world_shader, mtl_lightmap_shader];
#ifdef OM_METAL_CSM_SHADER_H
	if (csm) world_source = [NSString stringWithFormat:@"#define OM_CSM 1\n%@\n%@", mtl_csm_msl, world_source];
#endif
	id<MTLLibrary> lib = [mtl_device newLibraryWithSource:
		MTL_PostShaderSource(world_source, &targets)
	                                              options:nil error:&err];
	if (!lib)
	{
		MTL_Fatal("MSL compile (world)", err ? err.localizedDescription.UTF8String : NULL);
		return nil;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.label = @"openMerc world";
	desc.vertexFunction = [lib newFunctionWithName:@"mtl_vs_world_lightmaps"];
	desc.fragmentFunction = [lib newFunctionWithName:@"mtl_fs_world_lightmaps"];

	MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
	vd.attributes[0].format = MTLVertexFormatFloat3;
	vd.attributes[0].offset = 0;
	vd.attributes[0].bufferIndex = 0;
	vd.attributes[1].format = MTLVertexFormatFloat2;
	vd.attributes[1].offset = sizeof(float) * 4;
	vd.attributes[1].bufferIndex = 0;
	vd.attributes[2].format = MTLVertexFormatFloat2;
	vd.attributes[2].offset = sizeof(float) * 6;
	vd.attributes[2].bufferIndex = 0;
	vd.layouts[0].stride = MTL_WORLD_STRIDE;
	vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
	desc.vertexDescriptor = vd;

	MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
	ca.pixelFormat = mtl_layer.pixelFormat;
	ca.blendingEnabled = NO;
	if (!MTL_PostConfigurePipeline(desc, &targets)) MTL_Fatal("world pipeline", "invalid active attachments");

	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

	id<MTLRenderPipelineState> pipe = [mtl_device newRenderPipelineStateWithDescriptor:desc error:&err];
	if (!pipe)
	{
		MTL_Fatal("world pipeline", err ? err.localizedDescription.UTF8String : NULL);
	}
	MTL_PostPipelineStore(MTL_POST_PIPE_WORLD, 0, csm, &targets, pipe);
	return pipe;
}

/* Sky is unlit and never an emission source. Keeping a separate entry point
 * also avoids requiring style-plane or dynamic-layer bindings on sky draws. */
static id<MTLRenderPipelineState>
MTL_BuildSkyPipeline(void)
{
	mtl_pipeline_targets_t targets = MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> cached = MTL_PostPipelineCached(MTL_POST_PIPE_SKY, 0, 0, &targets);
	if (cached) return cached;
	NSError *error = nil;
	NSString *source = [NSString stringWithFormat:@"%@\n%@", mtl_world_shader, mtl_lightmap_shader];
	id<MTLLibrary> library = [mtl_device newLibraryWithSource:MTL_PostShaderSource(source, &targets) options:nil error:&error];
	if (!library) MTL_Fatal("MSL compile (sky)", error.localizedDescription.UTF8String);
	MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
	descriptor.label = @"openMerc unlit sky";
	descriptor.vertexFunction = [library newFunctionWithName:@"mtl_vs_world"];
	descriptor.fragmentFunction = [library newFunctionWithName:@"mtl_fs_sky_native"];
	descriptor.colorAttachments[0].blendingEnabled = NO;
	if (!MTL_PostConfigurePipeline(descriptor, &targets)) MTL_Fatal("sky pipeline", "invalid active attachments");
	descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	id<MTLRenderPipelineState> pipeline = [mtl_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
	if (!pipeline) MTL_Fatal("sky pipeline", error.localizedDescription.UTF8String);
	MTL_PostPipelineStore(MTL_POST_PIPE_SKY, 0, 0, &targets, pipeline);
	return pipeline;
}

/* ---- alias models (MD2/SP2) -------------------------------------- */

static NSString *const mtl_alias_shader = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct AliasVSIn
{
	float3 pos;
	float2 uv;
	float4 color;
};

struct AliasVSOut
{
	float4 position [[position]];
	float2 uv;
	float4 color;
};

struct AliasUniforms
{
	float4x4 mvp;
};

vertex AliasVSOut mtl_vs_alias(const device AliasVSIn *verts [[buffer(0)]],
                               constant AliasUniforms &u [[buffer(1)]],
                               uint vid [[vertex_id]])
{
	AliasVSOut o;
	AliasVSIn v = verts[vid];
	o.position = u.mvp * float4(v.pos, 1.0);
	o.uv = v.uv;
	o.color = v.color;
	return o;
}

fragment OMPostOutput mtl_fs_alias(AliasVSOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler smp [[sampler(0)]])
{
	float4 t = tex.sample(smp, in.uv);
	/* Ghoul and alias cutout skins use alpha testing for the opaque pass.
	 * Without this discard, RGB values stored behind transparent texels turn
	 * otherwise invisible model triangles into solid foreground polygons. */
	if (t.a <= 0.05)
		discard_fragment();
	/* SPEC-410 model lighting: skin x clamped light colour (gl3 si3Dalias:
	   texel *= min(1.5, passColor); overbright 1, gamma 1, intensity 1) */
	t.rgb *= min(in.color.rgb, float3(1.5));
	t.a *= in.color.a;
	return OM_PostDefault(t);
}

fragment OMPostOutput mtl_fs_detail(AliasVSOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant OMPostUniforms &post [[buffer(3)]])
{
	/* Detail pass has no alpha test, lighting or gamma operation. */
	float4 c=tex.sample(smp, in.uv);
	return OM_PostFragment(c,c.rgb,post.emission);
}

/* Ghoul models, effect quads and alpha faces: as mtl_vs_alias, plus the eye distance along the fog plane */
struct FxVSOut
{
	float4 position [[position]];
	float2 uv;
	float4 color;
	float fogdist;
};

vertex FxVSOut mtl_vs_fx(const device AliasVSIn *verts [[buffer(0)]],
                         constant AliasUniforms &u [[buffer(1)]],
                         constant float4 &fogPlane [[buffer(2)]],
                         uint vid [[vertex_id]])
{
	FxVSOut o;
	AliasVSIn v = verts[vid];
	o.position = u.mvp * float4(v.pos, 1.0);
	o.uv = v.uv;
	o.color = v.color;
	o.fogdist = abs(dot(fogPlane.xyz, float3(v.pos)) + fogPlane.w);
	return o;
}

fragment OMPostOutput mtl_fs_fx(FxVSOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          sampler smp [[sampler(0)]],
                          constant float &cutoff [[buffer(2)]],
                          constant OMPostUniforms &post [[buffer(3)]],
                          texture2d<float> omDepth [[texture(1)]],
                          sampler omDepthSmp [[sampler(1)]],
                          constant float4 &omSoftP [[buffer(4)]],
                          constant float4 &omSoftV [[buffer(5)]],
                          constant OMFogLinear &omFog [[buffer(6)]])
{
	float4 c = tex.sample(smp, in.uv) * in.color;
	if (c.a <= cutoff) discard_fragment();
	if (omSoftV.w > 0.5) {
		float z = omDepth.sample(omDepthSmp, in.position.xy * float2(omSoftV.x, omSoftV.y)).r;
		float mapped = (z - omSoftP.z) / (omSoftP.w - omSoftP.z);
		float sceneDist = omSoftP.y / (mapped + omSoftP.x);
		float pmapped = (in.position.z - omSoftP.z) / (omSoftP.w - omSoftP.z);
		float particleDist = omSoftP.y / (pmapped + omSoftP.x);
		float fade = clamp((sceneDist - particleDist) / omSoftV.z, 0.0f, 1.0f);
		if (omSoftV.w < 1.5) c.a *= fade;
		else c.rgb *= fade;
	}
	c = OM_FogApply(c, OM_FogVisibility(in.fogdist, omFog), omFog);
	return OM_PostFragment(c,c.rgb,post.emission);
}
)MSL";

#define MTL_BLEND_DETAIL 3
#define MTL_BLEND_DARKEN 4
static id<MTLRenderPipelineState>
MTL_BuildAliasPipeline(int blend, int fragment)
{
	mtl_pipeline_targets_t targets=MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> cached=MTL_PostPipelineCached(MTL_POST_PIPE_ALIAS,blend,fragment,&targets);
	if(cached) return cached;
	NSError *err = nil;
	id<MTLLibrary> lib = [mtl_device newLibraryWithSource:
		MTL_PostShaderSource([NSString stringWithFormat:@"%@\n%@\n%@", mtl_shader_source, mtl_fog_linear_msl, mtl_alias_shader],&targets)
	                                              options:nil error:&err];
	if (!lib)
	{
		MTL_Fatal("MSL compile (alias)", err ? err.localizedDescription.UTF8String : NULL);
		return nil;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.label = blend == OM_GHOUL_NATIVE_BLEND_ALPHA ? @"openMerc alias alpha"
		: (blend == OM_GHOUL_NATIVE_BLEND_ADDITIVE ? @"openMerc alias additive" : @"openMerc alias");
	desc.vertexFunction = [lib newFunctionWithName:fragment == 2 ? @"mtl_vs_fx" : @"mtl_vs_alias"];
	desc.fragmentFunction = [lib newFunctionWithName:fragment == 2 ? @"mtl_fs_fx" :
		(fragment == 1 ? @"mtl_fs_detail" : @"mtl_fs_alias")];

	MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
	vd.attributes[0].format = MTLVertexFormatFloat3;
	vd.attributes[0].offset = 0;
	vd.attributes[0].bufferIndex = 0;
	vd.attributes[1].format = MTLVertexFormatFloat2;
	vd.attributes[1].offset = sizeof(float) * 4;
	vd.attributes[1].bufferIndex = 0;
	vd.attributes[2].format = MTLVertexFormatFloat4;
	vd.attributes[2].offset = sizeof(float) * 8;
	vd.attributes[2].bufferIndex = 0;
	vd.layouts[0].stride = MTL_ALIAS_STRIDE;
	vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
	desc.vertexDescriptor = vd;

	MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
	ca.pixelFormat = mtl_layer.pixelFormat;
	ca.blendingEnabled = blend != OM_GHOUL_NATIVE_BLEND_OPAQUE;
	if (blend == OM_GHOUL_NATIVE_BLEND_ALPHA)
	{
		ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		ca.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	else if (blend == OM_GHOUL_NATIVE_BLEND_ADDITIVE)
	{
		ca.sourceRGBBlendFactor = MTLBlendFactorOne;
		ca.destinationRGBBlendFactor = MTLBlendFactorOne;
		ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
		ca.destinationAlphaBlendFactor = MTLBlendFactorOne;
	}
	else if (blend == MTL_BLEND_DARKEN)
	{
		ca.sourceRGBBlendFactor = MTLBlendFactorZero;
		ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceColor;
		ca.sourceAlphaBlendFactor = MTLBlendFactorZero;
		ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	else if (blend == MTL_BLEND_DETAIL)
	{
		ca.sourceRGBBlendFactor = MTLBlendFactorDestinationColor;
		ca.destinationRGBBlendFactor = MTLBlendFactorSourceColor;
		ca.sourceAlphaBlendFactor = MTLBlendFactorDestinationAlpha;
		ca.destinationAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	}

	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	MTL_PostConfigurePipeline(desc,&targets);

	id<MTLRenderPipelineState> pipe = [mtl_device newRenderPipelineStateWithDescriptor:desc error:&err];
	if (!pipe)
	{
		MTL_Fatal("alias pipeline", err ? err.localizedDescription.UTF8String : NULL);
	}
	MTL_PostPipelineStore(MTL_POST_PIPE_ALIAS,blend,fragment,&targets,pipe);
	return pipe;
}

/* RLabs (2026-11-05): mtl_fs_fx reads its soft-particle fade from fragment buffers 4 and 5, which only the effect
 * draw (mtl_fx.h) binds. Every other draw with that shader - Ghoul models, translucent world faces, translucent
 * brush faces - inherited whatever the last effect left there, so after smoke or blood a floor grate faded into the
 * recess under it (play-tester: "there was not supposed to be a pit") and models near a surface faded or flickered with
 * the view. These draws are not particles: bind the fade off. */
/* RLabs (2026-11-05, play-tester: "lots of drops"): per-frame vertex streams went through newBufferWithBytes - a new GPU
 * allocation for every detail face, Ghoul part, particle batch and translucent face, every frame. Sampling a 120 fps
 * run put the detail pass alone at a fifth of the main thread, inside the allocator. MTL_FrameUpload copies a stream
 * into the frame's slice of a ring of shared buffers instead: four slices, one more than the three frames the
 * in-flight semaphore lets the GPU hold, so a slice is never written while the GPU reads it. A stream that does not
 * fit falls back to its own buffer. */
#define MTL_FRAME_RING 4
#define MTL_FRAME_RING_BYTES (32u << 20)
static id<MTLBuffer> mtl_frame_ring[MTL_FRAME_RING];
static int mtl_frame_ring_index;
static NSUInteger mtl_frame_ring_used;

static void MTL_FrameRingNext(void)
{
	mtl_frame_ring_index = (mtl_frame_ring_index + 1) % MTL_FRAME_RING;
	mtl_frame_ring_used = 0;
}

static void MTL_FrameRingFree(void)
{
	for (int i = 0; i < MTL_FRAME_RING; i++)
		mtl_frame_ring[i] = nil;
	mtl_frame_ring_used = 0;
}

static id<MTLBuffer> MTL_FrameUpload(const void *bytes, NSUInteger length, NSUInteger *offset)
{
	*offset = 0;
	if (!bytes || !length)
		return nil;
	id<MTLBuffer> ring = mtl_frame_ring[mtl_frame_ring_index];
	if (!ring)
	{
		ring = [mtl_device newBufferWithLength:MTL_FRAME_RING_BYTES options:MTLResourceStorageModeShared];
		mtl_frame_ring[mtl_frame_ring_index] = ring;
	}
	NSUInteger start = (mtl_frame_ring_used + 255) & ~(NSUInteger)255;
	if (!ring || start + length > MTL_FRAME_RING_BYTES)
		return [mtl_device newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];
	memcpy((char *)ring.contents + start, bytes, length);
	mtl_frame_ring_used = start + length;
	*offset = start;
	return ring;
}

static void MTL_FXSoftOff(void)
{
	float softP[4] = {0, 0, 0, 1};
	float softV[4] = {1.0f, 1.0f, 0, 0};
	[mtl_enc setFragmentBytes:softP length:sizeof(softP) atIndex:4];
	[mtl_enc setFragmentBytes:softV length:sizeof(softV) atIndex:5];
}

/* Quake-style particles are camera-facing, translucent discs. They use the
 * alias stream layout (position, corner UV, colour), but expand their CPU
 * quads in the vertex function to preserve GL3's point-size behaviour. */
static NSString *mtl_particle_shader = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct ParticleVSIn { float3 pos; float2 uv; float4 color; };
struct ParticleUniforms { float4x4 mvp; float3 right; float size; float3 up; float pad; };
struct ParticleVSOut { float4 position [[position]]; float2 uv; float4 color; };

vertex ParticleVSOut mtl_vs_particle(const device ParticleVSIn *verts [[buffer(0)]],
                                     constant ParticleUniforms &u [[buffer(1)]],
                                     uint vid [[vertex_id]])
{
	ParticleVSIn v = verts[vid];
	ParticleVSOut o;
	float3 p = v.pos + (v.uv.x - 0.5) * u.right * u.size
		+ (v.uv.y - 0.5) * u.up * u.size;
	o.position = u.mvp * float4(p, 1.0);
	o.uv = v.uv;
	o.color = v.color;
	return o;
}

fragment OMPostOutput mtl_fs_particle(ParticleVSOut in [[stage_in]])
{
	float2 d = 2.0 * (in.uv - float2(0.5));
	float d2 = dot(d, d);
	if (d2 > 1.0)
		discard_fragment();
	float4 c = in.color;
	c.a *= min(1.0, 1.2 * (1.0 - d2));
	return OM_PostDefault(c);
}
)MSL";

static id<MTLRenderPipelineState>
MTL_BuildParticlePipeline(void)
{
	mtl_pipeline_targets_t targets=MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> cached=MTL_PostPipelineCached(MTL_POST_PIPE_PARTICLE,0,0,&targets);
	if(cached) return cached;
	NSError *err = nil;
	id<MTLLibrary> lib = [mtl_device newLibraryWithSource:
		MTL_PostShaderSource([NSString stringWithFormat:@"%@\n%@", mtl_shader_source, mtl_particle_shader],&targets)
	                                              options:nil error:&err];
	if (!lib)
	{
		MTL_Fatal("MSL compile (particles)", err ? err.localizedDescription.UTF8String : NULL);
		return nil;
	}
	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.label = @"openMerc particles";
	desc.vertexFunction = [lib newFunctionWithName:@"mtl_vs_particle"];
	desc.fragmentFunction = [lib newFunctionWithName:@"mtl_fs_particle"];
	MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
	vd.attributes[0].format = MTLVertexFormatFloat3;
	vd.attributes[0].offset = 0;
	vd.attributes[0].bufferIndex = 0;
	vd.attributes[1].format = MTLVertexFormatFloat2;
	vd.attributes[1].offset = sizeof(float) * 4;
	vd.attributes[1].bufferIndex = 0;
	vd.attributes[2].format = MTLVertexFormatFloat4;
	vd.attributes[2].offset = sizeof(float) * 8;
	vd.attributes[2].bufferIndex = 0;
	vd.layouts[0].stride = MTL_ALIAS_STRIDE;
	vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
	desc.vertexDescriptor = vd;
	MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
	ca.pixelFormat = mtl_layer.pixelFormat;
	ca.blendingEnabled = YES;
	ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	ca.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	MTL_PostConfigurePipeline(desc,&targets);
	id<MTLRenderPipelineState> pipe = [mtl_device newRenderPipelineStateWithDescriptor:desc error:&err];
	if (!pipe)
		MTL_Fatal("particle pipeline", err ? err.localizedDescription.UTF8String : NULL);
	MTL_PostPipelineStore(MTL_POST_PIPE_PARTICLE,0,0,&targets,pipe);
	return pipe;
}

/* M4 water/turb surfaces use the loaded BSP triangle stream directly. The
 * shader reproduces the time-varying Quake warp without borrowing any GL
 * state; opaque and alpha liquids differ only in blend/depth configuration. */
static NSString *mtl_turb_shader = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct TurbVSIn { float3 pos; float2 uv; float2 luv; };
struct TurbUniforms { float4x4 mvp; float time; float alpha; float2 pad; };
struct TurbVSOut { float4 position [[position]]; float2 uv; float alpha; };

vertex TurbVSOut mtl_vs_turb(const device TurbVSIn *verts [[buffer(0)]],
                             constant TurbUniforms &u [[buffer(1)]],
                             uint vid [[vertex_id]])
{
	TurbVSIn v = verts[vid];
	TurbVSOut o;
	o.position = u.mvp * float4(v.pos, 1.0);
	float s = sin(v.uv.y * 96.0 + u.time) * 0.015625;
	float t = sin(v.uv.x * 96.0 + u.time * 1.17) * 0.015625;
	o.uv = v.uv + float2(s, t);
	o.alpha = u.alpha;
	return o;
}

fragment OMPostOutput mtl_fs_turb(TurbVSOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler smp [[sampler(0)]])
{
	float4 t = tex.sample(smp, in.uv);
	if (t.a <= 0.05)
		discard_fragment();
	t.a *= in.alpha;
	return OM_PostDefault(t);
}
)MSL";

static id<MTLRenderPipelineState>
MTL_BuildTurbPipeline(qboolean blend)
{
	mtl_pipeline_targets_t targets=MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> cached=MTL_PostPipelineCached(MTL_POST_PIPE_TURB,blend,0,&targets);
	if(cached) return cached;
	NSError *err = nil;
	id<MTLLibrary> lib = [mtl_device newLibraryWithSource:
		MTL_PostShaderSource([NSString stringWithFormat:@"%@\n%@", mtl_shader_source, mtl_turb_shader],&targets)
	                                              options:nil error:&err];
	if (!lib)
	{
		MTL_Fatal("MSL compile (turb)", err ? err.localizedDescription.UTF8String : NULL);
		return nil;
	}
	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.label = blend ? @"openMerc turb alpha" : @"openMerc turb opaque";
	desc.vertexFunction = [lib newFunctionWithName:@"mtl_vs_turb"];
	desc.fragmentFunction = [lib newFunctionWithName:@"mtl_fs_turb"];
	MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
	vd.attributes[0].format = MTLVertexFormatFloat3;
	vd.attributes[0].offset = 0;
	vd.attributes[0].bufferIndex = 0;
	vd.attributes[1].format = MTLVertexFormatFloat2;
	vd.attributes[1].offset = sizeof(float) * 4;
	vd.attributes[1].bufferIndex = 0;
	vd.attributes[2].format = MTLVertexFormatFloat2;
	vd.attributes[2].offset = sizeof(float) * 6;
	vd.attributes[2].bufferIndex = 0;
	vd.layouts[0].stride = MTL_WORLD_STRIDE;
	vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
	desc.vertexDescriptor = vd;
	MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
	ca.pixelFormat = mtl_layer.pixelFormat;
	ca.blendingEnabled = blend ? YES : NO;
	if (blend)
	{
		ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		ca.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	MTL_PostConfigurePipeline(desc,&targets);
	id<MTLRenderPipelineState> pipe = [mtl_device newRenderPipelineStateWithDescriptor:desc error:&err];
	if (!pipe)
		MTL_Fatal("turb pipeline", err ? err.localizedDescription.UTF8String : NULL);
	MTL_PostPipelineStore(MTL_POST_PIPE_TURB,blend,0,&targets,pipe);
	return pipe;
}

/* ---- matrices ---------------------------------------------------- */

static void
MTL_Mul4(const float a[16], const float b[16], float out[16])
{
	/* column-major: out = a * b */
	for (int c = 0; c < 4; c++)
	{
		for (int r = 0; r < 4; r++)
		{
			float sum = 0;
			for (int k = 0; k < 4; k++)
			{
				sum += a[k * 4 + r] * b[c * 4 + k];
			}
			out[c * 4 + r] = sum;
		}
	}
}

static void
MTL_ViewMatrix(const vec3_t origin, const vec3_t angles, float out[16])
{
	/* AngleVectors (pitch, yaw, roll) exactly as the client builds them */
	float sp = sinf(DEG2RAD(angles[0])), cp = cosf(DEG2RAD(angles[0]));
	float sy = sinf(DEG2RAD(angles[1])), cy = cosf(DEG2RAD(angles[1]));
	float sr = sinf(DEG2RAD(angles[2])), cr = cosf(DEG2RAD(angles[2]));

	vec3_t forward = {cp * cy, cp * sy, -sp};
	vec3_t right = {-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp};
	vec3_t up = {cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp};

	float m[16] = {0};
	/* rows: right, up, -forward (column-major storage) */
	m[0] = right[0];    m[4] = right[1];    m[8]  = right[2];
	m[1] = up[0];       m[5] = up[1];       m[9]  = up[2];
	m[2] = -forward[0]; m[6] = -forward[1]; m[10] = -forward[2];
	m[12] = -(right[0] * origin[0] + right[1] * origin[1] + right[2] * origin[2]);
	m[13] = -(up[0] * origin[0] + up[1] * origin[1] + up[2] * origin[2]);
	m[14] =  (forward[0] * origin[0] + forward[1] * origin[1] + forward[2] * origin[2]);
	m[15] = 1.0f;

	memcpy(out, m, sizeof(m));
}

/*
 * Model matrix for an entity: the GL3 reference builds it with
 * rotAroundAxisZYX(yaw, -pitch, -roll) (gl3_main.c GL3_RotateForEntity) and
 * then sets the translation to the entity origin. Column-major output.
 */
static void
MTL_EntityMatrix(const vec3_t origin, const vec3_t angles, float out[16])
{
	float a = DEG2RAD(angles[1]);  /* yaw (around Z) */
	float b = DEG2RAD(-angles[0]); /* pitch (around Y) */
	float g = DEG2RAD(-angles[2]); /* roll (around X) */

	float sinA = sinf(a), cosA = cosf(a);
	float sinB = sinf(b), cosB = cosf(b);
	float sinG = sinf(g), cosG = cosf(g);

	/* column-major; matches rotAroundAxisZYX exactly */
	out[0] = cosA * cosB;
	out[1] = sinA * cosB;
	out[2] = -sinB;
	out[3] = 0;

	out[4] = cosA * sinB * sinG - sinA * cosG;
	out[5] = sinA * sinB * sinG + cosA * cosG;
	out[6] = cosB * sinG;
	out[7] = 0;

	out[8] = cosA * sinB * cosG + sinA * sinG;
	out[9] = sinA * sinB * cosG - cosA * sinG;
	out[10] = cosB * cosG;
	out[11] = 0;

	out[12] = origin[0];
	out[13] = origin[1];
	out[14] = origin[2];
	out[15] = 1.0f;
}

/*
 * SPEC-413 §6: near = r_nearclipdist x f(fov_y), far = r_farclipdist, where
 * f(fov_y) = 3.9 below 5 degrees, 1.0 + (75 - fov_y) / 70 x 2.9 below 75,
 * else 1.0. Same ladder as the GL3 reference (gl3_main.c GL3_SetPerspective);
 * the sky box half-size 37800 needs the 65535 far plane.
 */
static void
MTL_ProjMatrix(float fov_x, float aspect, float out[16])
{
	float fovy = 2.0f * atanf(tanf(DEG2RAD(fov_x) * 0.5f) / aspect);
	float fovy_degrees = RAD2DEG(fovy);
	float f = 1.0f / tanf(fovy * 0.5f);
	float fclip, znear, zfar;

	if (fovy_degrees < 5.0f)
	{
		fclip = 3.9f;
	}
	else if (fovy_degrees < 75.0f)
	{
		fclip = 1.0f + (75.0f - fovy_degrees) / 70.0f * 2.9f;
	}
	else
	{
		fclip = 1.0f;
	}

	znear = (mtl_nearclip_cvar ? mtl_nearclip_cvar->value : 0.0f);
	if (znear < 0.1f)
	{
		znear = 0.1f;
	}
	znear *= fclip;
	zfar = mtl_farclip_cvar ? mtl_farclip_cvar->value : 65535.0f;
	if (zfar < znear + 1.0f)
	{
		zfar = znear + 1.0f;
	}

	memset(out, 0, sizeof(float) * 16);
	out[0] = f / aspect;
	out[5] = f;
	out[10] = zfar / (znear - zfar);
	out[11] = -1.0f;
	out[14] = (zfar * znear) / (znear - zfar);
}

/* GL's RF_DEPTHHACK maps the post-projection depth range to [0, 0.3].
 * Metal has no mutable per-draw depth range, so pre-multiply the current
 * projection-view matrix with the equivalent clip-space Z scale. */
static void
MTL_ApplyDepthHack(const float in[16], float out[16])
{
	float depth[16] = {0};
	depth[0] = depth[5] = depth[15] = 1.0f;
	depth[10] = 0.3f;
	MTL_Mul4(depth, in, out);
}

/* GL3 gives ordinary alias view models their own r_gunfov projection, but
 * Ghoul models only narrow the depth range. Keep that distinction here:
 * applying gun FOV to Ghoul would be a Metal-only visual change. */
static void
MTL_AliasEntityMVP(const entity_t *e, const float world_mvp[16], const float view[16], float out[16])
{
	if (e->flags & RF_WEAPONMODEL)
	{
		float aspect = mtl_ui_h > 0.0f ? mtl_ui_w / mtl_ui_h : 16.0f / 9.0f;
		float world_fovy = 2.0f * atanf(tanf(DEG2RAD(mtl_refdef.fov_x) * 0.5f) / aspect);
		float gun_fovy = (mtl_gunfov_cvar && mtl_gunfov_cvar->value >= 0.0f)
			? DEG2RAD(mtl_gunfov_cvar->value) : world_fovy;
		float gun_fovx = RAD2DEG(2.0f * atanf(tanf(gun_fovy * 0.5f) * aspect));
		float proj[16];
		MTL_ProjMatrix(gun_fovx, aspect, proj);
		MTL_Mul4(proj, view, out);
	}
	else
	{
		memcpy(out, world_mvp, sizeof(float) * 16);
	}

	if (e->flags & RF_DEPTHHACK)
	{
		float depth_hacked[16];
		MTL_ApplyDepthHack(out, depth_hacked);
		memcpy(out, depth_hacked, sizeof(depth_hacked));
	}
}

/* ---- BSP leafs, marksurfaces and traversal ------------------------ */

static int mtl_framecount = 1;
static int mtl_visframecount = 1;
static int mtl_last_cluster = -1;
static cplane_t mtl_frustum[4];

static void
MTL_LoadLeafs(mtl_model_t *mod, const byte *base, const lump_t *l, int bspversion)
{
	int recsize = (bspversion == BSPVERSION_SOF) ? (int)sizeof(dleaf46_t) : (int)sizeof(dleaf_t);
	int count = (int)(l->filelen / recsize);

	mod->leafs = calloc(count ? count : 1, sizeof(mleaf_t));
	mod->numleafs = count;

	for (int i = 0; i < count; i++)
	{
		const byte *in = base + l->fileofs + (size_t)i * recsize;
		mleaf_t *out = &mod->leafs[i];
		short cluster, area, mins[3], maxs[3];
		unsigned short firstleafface, numleaffaces;

		if (bspversion == BSPVERSION_SOF)
		{
			const dleaf46_t *L = (const dleaf46_t *)in;
			out->contents = LittleLong(L->contents);
			cluster = L->cluster;
			area = L->area;
			memcpy(mins, L->mins, sizeof(mins));
			memcpy(maxs, L->maxs, sizeof(maxs));
			firstleafface = L->firstleafface;
			numleaffaces = L->numleaffaces;
		}
		else
		{
			const dleaf_t *L = (const dleaf_t *)in;
			out->contents = LittleLong(L->contents);
			cluster = L->cluster;
			area = L->area;
			memcpy(mins, L->mins, sizeof(mins));
			memcpy(maxs, L->maxs, sizeof(maxs));
			firstleafface = L->firstleafface;
			numleaffaces = L->numleaffaces;
		}

		out->cluster = cluster;
		out->area = area;
		out->firstmarksurface = NULL;
		out->nummarksurfaces = numleaffaces;
		out->visframe = 0;

		for (int k = 0; k < 3; k++)
		{
			out->minmaxs[k] = (float)mins[k];
			out->minmaxs[3 + k] = (float)maxs[k];
		}
	}
}

/* leaffaces -> per-leaf arrays of surface pointers */
static void
MTL_LinkMarksurfaces(mtl_model_t *mod, const byte *base, const lump_t *l)
{
	const int count = l->filelen / (int)sizeof(unsigned short);
	const unsigned short *in = (const unsigned short *)(base + l->fileofs);

	mod->nummarksurfaces = count;
	mod->marksurfaces = calloc(count ? count : 1, sizeof(*mod->marksurfaces));

	for (int i = 0; i < count; i++)
	{
		int idx = in[i];
		if (idx < 0 || idx >= mod->numsurfaces)
		{
			mod->marksurfaces[i] = NULL;
			continue;
		}
		mod->marksurfaces[i] = (struct msurface_s *)&mod->surfaces[idx];
	}

	/* firstmarksurface is a pointer into the same array, offset by the leaf's first index */
	{
		int cursor = 0;
		for (int i = 0; i < mod->numleafs; i++)
		{
			mod->leafs[i].firstmarksurface = mod->marksurfaces + cursor;
			cursor += mod->leafs[i].nummarksurfaces;
			if (cursor > count)
			{
				cursor = count;
			}
		}
	}
}

/* mark leaves and their node chains from the view leaf's PVS */
static void
MTL_MarkLeaves(mtl_model_t *mod)
{
	/* A PVS bit row is indexed by cluster, not leaf number.  A map can have
	 * multiple leaves per cluster, so using numleafs overreads the compressed
	 * stream and marks an unrelated BSP path. */
	const int numclusters = mod->vis ? LittleLong(mod->vis->numclusters) : 0;
	const int visrow = (numclusters + 7) / 8;
	byte *vis = NULL;
	mleaf_t *viewleaf;
	int viewcluster2;
	byte fatvis[MAX_MAP_LEAFS / 8];
	static int worlddebug_lines;
	int pvsleafs = 0, arealeafs = 0;

	mtl_framecount++;
	mtl_visframecount++;

	viewleaf = Mod_PointInLeaf(mtl_refdef.vieworg, mod->nodes);

	/* the camera can sit inside solid geometry (cinematic paths, tight spots): the leaf then has
	   cluster -1 and has no PVS. Step vertically until a real leaf is found, as the reference does
	   for water boundaries, rather than giving up and drawing the whole map. */
	if (!viewleaf || (viewleaf->cluster < 0))
	{
		vec3_t probe;
		for (int step = 1; step <= 8; step++)
		{
			for (int dir = -1; dir <= 1; dir += 2)
			{
				probe[0] = mtl_refdef.vieworg[0];
				probe[1] = mtl_refdef.vieworg[1];
				probe[2] = mtl_refdef.vieworg[2] + (float)(dir * step * 8);
				mleaf_t *l = Mod_PointInLeaf(probe, mod->nodes);
				if (l && l->cluster >= 0)
				{
					viewleaf = l;
					step = 99;
					break;
				}
			}
		}
	}

	if (!viewleaf)
	{
		return;
	}

	if (viewleaf->cluster < 0 && mtl_last_cluster >= 0)
	{
		/* reference behaviour: a solid view leaf keeps the previous valid PVS */
		mleaf_t *l = NULL;
		for (int i = 0; i < mod->numleafs; i++)
		{
			if (mod->leafs[i].cluster == mtl_last_cluster)
			{
				l = &mod->leafs[i];
				break;
			}
		}
		if (l)
		{
			viewleaf = l;
		}
	}
	else if (viewleaf->cluster >= 0)
	{
		mtl_last_cluster = viewleaf->cluster;
	}

	/* Match GL3's boundary probe: crossing a water/solid boundary needs the
	 * union of both leaf clusters, otherwise the PVS can omit the visible
	 * side of the boundary even though the camera itself is in empty space. */
	viewcluster2 = viewleaf->cluster;
	if (!viewleaf->contents)
	{
		vec3_t probe;
		mleaf_t *leaf;
		VectorCopy(mtl_refdef.vieworg, probe);
		probe[2] -= 16.0f;
		leaf = Mod_PointInLeaf(probe, mod->nodes);
		if (leaf && !(leaf->contents & CONTENTS_SOLID) &&
			(leaf->cluster != viewcluster2))
		{
			viewcluster2 = leaf->cluster;
		}
	}
	else
	{
		vec3_t probe;
		mleaf_t *leaf;
		VectorCopy(mtl_refdef.vieworg, probe);
		probe[2] += 16.0f;
		leaf = Mod_PointInLeaf(probe, mod->nodes);
		if (leaf && !(leaf->contents & CONTENTS_SOLID) &&
			(leaf->cluster != viewcluster2))
		{
			viewcluster2 = leaf->cluster;
		}
	}

	if ((viewleaf->cluster >= 0) && mod->vis && (numclusters > 0) &&
	    (viewleaf->cluster < numclusters))
	{
		const int offset = LittleLong(mod->vis->bitofs[viewleaf->cluster][DVIS_PVS]);
		vis = (byte *)Mod_DecompressVis((const byte *)mod->vis + offset, visrow);
	}
	if (vis && (viewcluster2 >= 0) && (viewcluster2 != viewleaf->cluster) &&
		(viewcluster2 < numclusters))
	{
		const int offset = LittleLong(mod->vis->bitofs[viewcluster2][DVIS_PVS]);
		const byte *secondary_vis;
		memcpy(fatvis, vis, (size_t)visrow);
		secondary_vis = Mod_DecompressVis((const byte *)mod->vis + offset, visrow);
		vis = fatvis;
		for (int i = 0; i < visrow; i++)
		{
			vis[i] |= secondary_vis[i];
		}
	}

	if (!vis)
	{
		for (int i = 0; i < mod->numleafs; i++)
		{
			mod->leafs[i].visframe = mtl_visframecount;
		}
		for (int i = 0; i < mod->numnodes; i++)
		{
			mod->nodes[i].visframe = mtl_visframecount;
		}
	}
	else
	{
		for (int i = 0; i < mod->numleafs; i++)
		{
			mleaf_t *leaf = &mod->leafs[i];
			const int cluster = leaf->cluster;

			if (cluster < 0 || !(vis[cluster >> 3] & (1 << (cluster & 7))))
			{
				continue;
			}

			mnode_t *node = (mnode_t *)leaf;
			do
			{
				if (node->visframe == mtl_visframecount)
				{
					break;
				}
				node->visframe = mtl_visframecount;
				node = node->parent;
			}
			while (node);
		}
	}

	/* surfaces of visible leaves become drawable this frame */
	for (int i = 0; i < mod->numleafs; i++)
	{
		mleaf_t *leaf = &mod->leafs[i];

		if (leaf->visframe != mtl_visframecount)
		{
			continue;
		}
		pvsleafs++;
		if (mtl_refdef.areabits && !R_AreaVisible(mtl_refdef.areabits, leaf))
		{
			continue;
		}
		arealeafs++;
		for (unsigned int k = 0; k < leaf->nummarksurfaces; k++)
		{
			mtl_surface_t *surf = (mtl_surface_t *)leaf->firstmarksurface[k];
			if (surf)
			{
				surf->visframe = mtl_framecount;
			}
		}
	}

	if (mtl_world_debug_cvar && mtl_world_debug_cvar->value && worlddebug_lines++ < 5)
	{
		Com_Printf("ref_metal: worlddebug pvs origin %.3f %.3f %.3f cluster %d cluster2 %d pvsleaves %d arealeaves %d\\n",
		           mtl_refdef.vieworg[0], mtl_refdef.vieworg[1], mtl_refdef.vieworg[2],
		           viewleaf->cluster, viewcluster2, pvsleafs, arealeafs);
	}
}

/* =================================================================== */
/* SPEC-410 Sky: the SoF sky box. pics/sky/<name>.txt names one image   */
/* per line for the faces rt, bk, lf, ft, up, dn; a face whose line is  */
/* "none" (any case) or whose image is missing is not drawn. The box is */
/* centred on the eye, half-size 37 800; the visible faces accumulate   */
/* bounds through the clipped world polygons, as in the GL3 reference.  */
/* =================================================================== */

#define SKY_ON_EPSILON 0.1f
enum { SKY_MAX_CLIP_VERTS = 64 };
enum { SKY_SIDE_FRONT = 0, SKY_SIDE_BACK = 1, SKY_SIDE_ON = 2 };

static const int mtl_skytexorder[6] = {0, 2, 1, 3, 4, 5};

static float mtl_skymins[2][6], mtl_skymaxs[2][6];
static float mtl_sky_min, mtl_sky_max;
static float mtl_skyrotate;
static vec3_t mtl_skyaxis;
static mtl_image_t *mtl_skyimages[6];

static const float mtl_skyclip[6][3] = {
	{1, 1, 0},
	{1, -1, 0},
	{0, -1, 1},
	{0, 1, 1},
	{1, 0, 1},
	{-1, 0, 1}
};

static const int mtl_st_to_vec[6][3] = {
	{3, -1, 2},
	{-3, 1, 2},

	{1, 3, 2},
	{-1, -3, 2},

	{-2, -1, 3}, /* 0 degrees yaw, look straight up */
	{2, -1, -3}  /* look straight down */
};

static const int mtl_vec_to_st[6][3] = {
	{-2, 3, 1},
	{2, 3, -1},

	{1, 3, 2},
	{-1, 3, -2},

	{-2, -1, 3},
	{-2, 1, -3}
};

static void
MTL_DrawSkyPolygon(int nump, vec3_t vecs)
{
	int i, j;
	vec3_t v, av;
	float s, t, dv;
	int axis;
	float *vp;

	VectorClear(v);

	for (i = 0, vp = vecs; i < nump; i++, vp += 3)
	{
		VectorAdd(vp, v, v);
	}

	av[0] = fabs(v[0]);
	av[1] = fabs(v[1]);
	av[2] = fabs(v[2]);

	if ((av[0] > av[1]) && (av[0] > av[2]))
	{
		axis = (v[0] < 0) ? 1 : 0;
	}
	else if ((av[1] > av[2]) && (av[1] > av[0]))
	{
		axis = (v[1] < 0) ? 3 : 2;
	}
	else
	{
		axis = (v[2] < 0) ? 5 : 4;
	}

	/* project new texture coords */
	for (i = 0; i < nump; i++, vecs += 3)
	{
		j = mtl_vec_to_st[axis][2];

		dv = (j > 0) ? vecs[j - 1] : -vecs[-j - 1];

		if (dv < 0.001f)
		{
			continue; /* don't divide by zero */
		}

		j = mtl_vec_to_st[axis][0];
		s = (j < 0) ? -vecs[-j - 1] / dv : vecs[j - 1] / dv;

		j = mtl_vec_to_st[axis][1];
		t = (j < 0) ? -vecs[-j - 1] / dv : vecs[j - 1] / dv;

		if (s < mtl_skymins[0][axis])
		{
			mtl_skymins[0][axis] = s;
		}

		if (t < mtl_skymins[1][axis])
		{
			mtl_skymins[1][axis] = t;
		}

		if (s > mtl_skymaxs[0][axis])
		{
			mtl_skymaxs[0][axis] = s;
		}

		if (t > mtl_skymaxs[1][axis])
		{
			mtl_skymaxs[1][axis] = t;
		}
	}
}

static void
MTL_ClipSkyPolygon(int nump, vec3_t vecs, int stage)
{
	const float *norm;
	const float *v;
	qboolean front, back;
	float d, e;
	float dists[SKY_MAX_CLIP_VERTS];
	int sides[SKY_MAX_CLIP_VERTS];
	vec3_t newv[2][SKY_MAX_CLIP_VERTS];
	int newc[2];
	int i, j;

	if (nump > SKY_MAX_CLIP_VERTS - 2)
	{
		Com_Error(ERR_DROP, "MTL_ClipSkyPolygon: SKY_MAX_CLIP_VERTS");
	}

	if (stage == 6)
	{
		/* fully clipped, so draw it */
		MTL_DrawSkyPolygon(nump, vecs);
		return;
	}

	front = back = false;
	norm = mtl_skyclip[stage];

	for (i = 0, v = vecs; i < nump; i++, v += 3)
	{
		d = DotProduct(v, norm);

		if (d > SKY_ON_EPSILON)
		{
			front = true;
			sides[i] = SKY_SIDE_FRONT;
		}
		else if (d < -SKY_ON_EPSILON)
		{
			back = true;
			sides[i] = SKY_SIDE_BACK;
		}
		else
		{
			sides[i] = SKY_SIDE_ON;
		}

		dists[i] = d;
	}

	if (!front || !back)
	{
		/* not clipped */
		MTL_ClipSkyPolygon(nump, vecs, stage + 1);
		return;
	}

	/* clip it */
	sides[nump] = sides[0];
	dists[nump] = dists[0];
	vecs[nump * 3 + 0] = vecs[0];
	vecs[nump * 3 + 1] = vecs[1];
	vecs[nump * 3 + 2] = vecs[2];
	newc[0] = newc[1] = 0;

	for (i = 0, v = vecs; i < nump; i++, v += 3)
	{
		switch (sides[i])
		{
			case SKY_SIDE_FRONT:
				VectorCopy(v, newv[0][newc[0]]);
				newc[0]++;
				break;
			case SKY_SIDE_BACK:
				VectorCopy(v, newv[1][newc[1]]);
				newc[1]++;
				break;
			case SKY_SIDE_ON:
				VectorCopy(v, newv[0][newc[0]]);
				newc[0]++;
				VectorCopy(v, newv[1][newc[1]]);
				newc[1]++;
				break;
		}

		if ((sides[i] == SKY_SIDE_ON) ||
			(sides[i + 1] == SKY_SIDE_ON) ||
			(sides[i + 1] == sides[i]))
		{
			continue;
		}

		d = dists[i] / (dists[i] - dists[i + 1]);

		for (j = 0; j < 3; j++)
		{
			e = v[j] + d * (v[j + 3] - v[j]);
			newv[0][newc[0]][j] = e;
			newv[1][newc[1]][j] = e;
		}

		newc[0]++;
		newc[1]++;
	}

	/* continue */
	MTL_ClipSkyPolygon(newc[0], newv[0][0], stage + 1);
	MTL_ClipSkyPolygon(newc[1], newv[1][0], stage + 1);
}

/* Sky loads own their image trees separately from world-model/HUD images.
 * Preserve all unique owners before clearing roots, and drain submitted uses. */
static void
MTL_FreeSkyImages(void)
{
	mtl_image_t *owned[64];
	int count = 0;
	for (int face = 0; face < 6; face++)
		for (mtl_image_t *image = mtl_skyimages[face]; image; image = image->detail)
		{
			int found;
			for (found = 0; found < count; found++) if (owned[found] == image) break;
			if (found < count) break;
			if (count == 64) { Com_Error(ERR_DROP, "ref_metal: sky ownership limit"); return; }
			owned[count++] = image;
		}
	if (count) MTL_ModelFence();
	for (int face = 0; face < 6; face++) mtl_skyimages[face] = NULL;
	for (int i = 0; i < count; i++)
	{
		if (owned[i]->tex) CFRelease(owned[i]->tex);
		free(owned[i]);
	}
}

void
MTL_SoF_SetSky(const char *name, float rotate, vec3_t axis)
{
	char path[MAX_QPATH];
	char *buf = NULL, *s;
	int len, face;

	mtl_skyrotate = rotate;
	VectorCopy(axis, mtl_skyaxis);

	MTL_FreeSkyImages();
	mtl_post.no_sky = YES; /* until one of this sky's pictures loads */

	/* texel inset; the stored chain already has every mip, so no extra level */
	if ((mtl_skymip_cvar && mtl_skymip_cvar->value) || (rotate != 0.0f))
	{
		mtl_sky_min = 1.0f / 256;
		mtl_sky_max = 255.0f / 256;
	}
	else
	{
		mtl_sky_min = 1.0f / 512;
		mtl_sky_max = 511.0f / 512;
	}

	Com_sprintf(path, sizeof(path), "pics/sky/%s.txt", name);
	len = ri.FS_LoadFile(path, (void **)&buf);

	if (!buf)
	{
		return;
	}

	s = buf;
	face = 0;

	while ((s < buf + len) && (face < 6))
	{
		char line[MAX_QPATH];
		int n = 0;

		/* one line; CR (13), LF (10) or both end it */
		while ((s < buf + len) && (*s != 13) && (*s != 10))
		{
			if (n < (int)sizeof(line) - 1)
			{
				line[n++] = *s;
			}

			s++;
		}

		line[n] = 0;

		if ((s < buf + len) && (*s == 13))
		{
			s++;
		}

		if ((s < buf + len) && (*s == 10))
		{
			s++;
		}

		if (line[0] && Q_stricmp(line, "none"))
		{
			/* SPEC-410: sky lists name root-relative SoF assets, not PICs.
			 * e.g. textures/sky/bos_side2 must not gain a pics/ prefix. */
			char imagepath[MAX_QPATH];
			if (COM_FileExtension(line)[0])
				Q_strlcpy(imagepath, line, sizeof(imagepath));
			else
				Com_sprintf(imagepath, sizeof(imagepath), "%s.m32", line);
			mtl_skyimages[face] = (mtl_image_t *)MTL_FindImage(imagepath, it_sky);
			if (mtl_skyimages[face])
				mtl_post.no_sky = NO;
		}

		face++;
	}

	ri.FS_FreeFile(buf);
}

static void
MTL_AddSkySurface(mtl_surface_t *surf)
{
	vec3_t verts[SKY_MAX_CLIP_VERTS];
	int i;
	static int debug_rings;
	qboolean debug = ri.Cvar_Get("r_metal_sky_debug", "0", 0)->value && debug_rings++ < 4;

	for (i = 0; i < surf->skyring_n; i++)
	{
		VectorSubtract(surf->skyring[i], mtl_refdef.vieworg, verts[i]);
		if (debug) Com_Printf("ref_metal sky ring %d/%d %.6f %.6f %.6f\n", i,
			surf->skyring_n, verts[i][0], verts[i][1], verts[i][2]);
	}

	MTL_ClipSkyPolygon(surf->skyring_n, verts[0], 0);
}

static void
MTL_ClearSkyBox(void)
{
	int i;

	for (i = 0; i < 6; i++)
	{
		mtl_skymins[0][i] = mtl_skymins[1][i] = 9999.0f;
		mtl_skymaxs[0][i] = mtl_skymaxs[1][i] = -9999.0f;
	}
}

static void
MTL_MakeSkyVec(float s, float t, int axis, vec3_t out_pos, float out_uv[2])
{
	float b[3], v[3];
	int j, k;
	const float dist = 37800.0f; /* SPEC-410 sky box half-size */

	b[0] = s * dist;
	b[1] = t * dist;
	b[2] = dist;

	for (j = 0; j < 3; j++)
	{
		k = mtl_st_to_vec[axis][j];

		if (k < 0)
		{
			v[j] = -b[-k - 1];
		}
		else
		{
			v[j] = b[k - 1];
		}
	}

	/* avoid bilerp seam */
	s = (s + 1.0f) * 0.5f;
	t = (t + 1.0f) * 0.5f;

	if (s < mtl_sky_min)
	{
		s = mtl_sky_min;
	}
	else if (s > mtl_sky_max)
	{
		s = mtl_sky_max;
	}

	if (t < mtl_sky_min)
	{
		t = mtl_sky_min;
	}
	else if (t > mtl_sky_max)
	{
		t = mtl_sky_max;
	}

	t = 1.0f - t;

	VectorCopy(v, out_pos);

	out_uv[0] = s;
	out_uv[1] = t;
}

/* Implements: SPEC-410. Match GPL HMM_Rotate's normalized axis and degree
 * convention, then put the centered box at the eye. SoF time is not client time. */
static void
MTL_SkyPosition(const float src[3], const float eye[3], float rotate,
                const float axis[3], float game_time, float out[3])
{
	if (rotate == 0.0f)
	{
		for (int i = 0; i < 3; i++) out[i] = eye[i] + src[i];
		return;
	}
	float length = sqrtf(axis[0]*axis[0] + axis[1]*axis[1] + axis[2]*axis[2]);
	float inverse = length != 0.0f ? 1.0f / length : 0.0f;
	float x = axis[0]*inverse, y = axis[1]*inverse, z = axis[2]*inverse;
	float angle = DEG2RAD(game_time * rotate);
	float s = sinf(angle), c = cosf(angle), k = 1.0f - c;
	float matrix[9] = {
		x*x*k+c, x*y*k+z*s, x*z*k-y*s,
		y*x*k-z*s, y*y*k+c, y*z*k+x*s,
		z*x*k+y*s, z*y*k-x*s, z*z*k+c
	};
	for (int row = 0; row < 3; row++)
	{
		out[row] = eye[row];
		for (int col = 0; col < 3; col++) out[row] += matrix[col*3+row] * src[col];
	}
}

static float MTL_GameTime(void);

static void
MTL_DrawSkyBox(const float mvp[16])
{
	mtl_world_vertex_t q[6];
	mtl_world_uniform_t u = {};
	int i, j, k;
	float s, t;
	[mtl_enc setRenderPipelineState:MTL_BuildSkyPipeline()];
	/* Opt-in, non-rendering diagnostics for attributing sky face rejection. */
	static int sky_debug_frames;
	qboolean debug_sky = ri.Cvar_Get("r_metal_sky_debug", "0", 0)->value && sky_debug_frames++ < 3;
	if (debug_sky)
		for (int face = 0; face < 6; face++)
			Com_Printf("ref_metal sky face %d bounds %.6f %.6f %.6f %.6f asset %s\n", face,
				mtl_skymins[0][face], mtl_skymaxs[0][face], mtl_skymins[1][face], mtl_skymaxs[1][face],
				mtl_skyimages[mtl_skytexorder[face]] ? mtl_skyimages[mtl_skytexorder[face]]->name : "(none)");

	/* OpenMerc: the whole face when rotating or fov_x < 90 (SPEC-410) */
	qboolean wholeface = (mtl_skyrotate != 0.0f) || (mtl_refdef.fov_x < 90.0f);

	if (mtl_skyrotate != 0.0f)
	{
		/* check for no sky at all */
		for (i = 0; i < 6; i++)
		{
			if ((mtl_skymins[0][i] < mtl_skymaxs[0][i]) &&
			    (mtl_skymins[1][i] < mtl_skymaxs[1][i]))
			{
				break;
			}
		}

		if (i == 6)
		{
			return; /* nothing visible */
		}
	}

	for (i = 0; i < 6; i++)
	{
		if (wholeface)
		{
			mtl_skymins[0][i] = -1;
			mtl_skymins[1][i] = -1;
			mtl_skymaxs[0][i] = 1;
			mtl_skymaxs[1][i] = 1;
		}

		if ((mtl_skymins[0][i] >= mtl_skymaxs[0][i]) ||
		    (mtl_skymins[1][i] >= mtl_skymaxs[1][i]))
		{
			continue;
		}

		/* faces named "none" or missing are not drawn */
		if (!mtl_skyimages[mtl_skytexorder[i]])
		{
			continue;
		}

		/* fan ordering 0,1,2,3 as two triangles: (0,1,2) (0,2,3) */
		float uv[4][2];
		vec3_t pos[4];

		MTL_MakeSkyVec(mtl_skymins[0][i], mtl_skymins[1][i], i, pos[0], uv[0]);
		MTL_MakeSkyVec(mtl_skymins[0][i], mtl_skymaxs[1][i], i, pos[1], uv[1]);
		MTL_MakeSkyVec(mtl_skymaxs[0][i], mtl_skymaxs[1][i], i, pos[2], uv[2]);
		MTL_MakeSkyVec(mtl_skymaxs[0][i], mtl_skymins[1][i], i, pos[3], uv[3]);

		/* Rotate with the actual SoF game clock before adding the eye. */
		const int idx[6] = {0, 1, 2, 0, 2, 3};
		for (k = 0; k < 6; k++)
		{
			j = idx[k];
			MTL_SkyPosition(pos[j], mtl_refdef.vieworg, mtl_skyrotate, mtl_skyaxis, MTL_GameTime(), q[k].pos);
			q[k].pad = 0.0f;
			q[k].uv[0] = uv[j][0];
			q[k].uv[1] = uv[j][1];
			q[k].luv[0] = 0.0f;
			q[k].luv[1] = 0.0f;
		}

		memcpy(u.mvp, mvp, sizeof(u.mvp));
		u.lm_adjust[0] = 0;
		u.lm_adjust[1] = 0;
		u.overbright = 1.0f;
		u.fullbright = 0;

		[mtl_enc setVertexBytes:q length:sizeof(q) atIndex:0];
		[mtl_enc setVertexBytes:&u length:sizeof(u) atIndex:1];
		[mtl_enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
		[mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)mtl_skyimages[mtl_skytexorder[i]]->tex atIndex:0];
		/* white lightmap: omL 255 -> colour table 255 -> identity, which is
		   exactly what the GL3 sky shader outputs for gamma 1 */
		[mtl_enc setFragmentTexture:mtl_white atIndex:1];
		[mtl_enc setFragmentTexture:mtl_lighttable atIndex:2];
		[mtl_enc setFragmentSamplerState:mtl_samp_clamp atIndex:0];
		[mtl_enc setFragmentSamplerState:mtl_samp_clamp atIndex:1];
		[mtl_enc setFragmentSamplerState:mtl_samp_clamp atIndex:2];
		/* the box sits behind the world: test the depth the world wrote,
		   write none (the world may still be drawn after in later passes) */
		[mtl_enc setDepthStencilState:mtl_depth_sky];
		[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	}
}

static float MTL_GameTime(void);
static void MTL_SoFLightPointDir(const vec3_t point, vec3_t color, int direction);
static mtl_image_t *MTL_AnimatedWorldImage(const mtexinfo_t *tex, int frame);
#include "mtl_liquid.h"
#include "mtl_liquid_inline.h"
#include "mtl_brush_polygons.h"
#include "mtl_fog_frame.h"
#include "mtl_volfog_pass.h"
#include "mtl_csm.h"

static void
MTL_DrawTurbSurface(mtl_model_t *mod, mtl_surface_t *surf, mtl_image_t *img,
                    const float mvp[16])
{
	qboolean alpha = (surf->texinfo->flags & 0x800) != 0; /* SOFSURF_ALPHA */
	id<MTLRenderPipelineState> pipe = MTL_BuildTurbPipeline(alpha);
	if (!pipe || !img || !img->tex)
		return;
	typedef struct { float mvp[16]; float time; float alpha; float pad[2]; } turb_uniform_t;
	turb_uniform_t u = {};
	memcpy(u.mvp, mvp, sizeof(u.mvp));
	u.time = mtl_refdef.time;
	u.alpha = 1.0f;
	id<MTLBuffer> vb = (__bridge id<MTLBuffer>)mod->vbuf;
	[mtl_enc setRenderPipelineState:pipe];
	[mtl_enc setDepthStencilState:alpha ? mtl_depth_readonly : mtl_depth_world];
	[mtl_enc setCullMode:alpha ? MTLCullModeNone : MTLCullModeBack];
	[mtl_enc setFrontFacingWinding:MTLWindingClockwise];
	[mtl_enc setVertexBuffer:vb offset:(NSUInteger)surf->first_vertex * MTL_WORLD_STRIDE atIndex:0];
	[mtl_enc setVertexBytes:&u length:sizeof(u) atIndex:1];
	[mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)img->tex atIndex:0];
	[mtl_enc setFragmentSamplerState:mtl_samp_repeat atIndex:0];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)surf->num_vertex];
	MTL_BrushPolygonDrawn();
}

static void
MTL_DrawSurface(mtl_model_t *mod, int index, const float mvp[16])
{
	mtl_surface_t *surf = &mod->surfaces[index];
	mtl_image_t *img = MTL_AnimatedWorldImage(surf->texinfo, (int)(MTL_GameTime() * 2));
	const int flags = surf->texinfo ? surf->texinfo->flags : 0;

	/* RLabs (2026-11-08, owner at the tsr1 trains: "What is this wall doing there?", "the train lights?"):
	   SPEC-410 texinfo 0x10000 is a fog-region boundary - never drawn; it only bounds its region and receives the
	   fog overlay. Drawn here, tsr1's 11 boundary faces (subway/1_tunnelwall) stood as walls across the subway
	   tracks and hid the trains and their lights behind them; nyc1, nyc2, sud3, irq3b and ger1 have more. Inline
	   models already skip them (mtl_brush.h). Checked before sky: a boundary face is never a sky face. */
	if (mod->bspversion == BSPVERSION_SOF && (flags & 0x10000))
	{
		MTL_FogMarkBoundaryPlane(surf);
		MTL_FogQueueSurface(surf);
		return;
	}

	/* SPEC-410 Sky: sky faces do not draw themselves; they carve the
	   visible bounds of the sky box that is drawn after the world */
	if (flags & SURF_DRAWSKY)
	{
		MTL_FogQueueSurface(surf);
		if (surf->skyring_n >= 3)
		{
			MTL_AddSkySurface(surf);
		}
		return;
	}

	if (!img || !img->tex || surf->num_vertex <= 0)
	{
		return;
	}
	/* SPEC-410's per-image world chain excludes declared alpha images whose
	 * texinfo is opaque. Inline models deliberately retain their cutout draw. */
	if (mod == mtl_worldmodel && mod->bspversion == BSPVERSION_SOF &&
		(img->declared_m32_flags & 0x800) && !(flags & 0x800)) return;
	/* SPEC-410: SoF alpha faces join entities/effects in one distance sort.
	 * They are vertex-lit, blended and never write world depth. */
	if (mod->bspversion == BSPVERSION_SOF && (flags & 0x800))
	{
		const mtl_world_vertex_t *vertices = (const mtl_world_vertex_t *)
			[(__bridge id<MTLBuffer>)mod->vbuf contents] + surf->first_vertex;
		vec3_t delta;
		VectorSubtract(mtl_refdef.vieworg, vertices[0].pos, delta);
		if (DotProduct(delta, surf->normal) > 0.01f && mtl_alpha_count < MTL_MAX_ALPHA_SURFACES)
		{
			mtl_alpha_surfaces[mtl_alpha_count++] = surf;
			MTL_FogQueueSurface(surf);
		}
		return;
	}
	if (mod->bspversion == BSPVERSION_SOF)
		MTL_FogQueueChain(surf);
	if (mod->bspversion == BSPVERSION_SOF && (flags & 8))
	{
		img = MTL_AnimatedWorldImage(surf->texinfo, (int)(MTL_GameTime() * 2));
		if (MTL_DrawSoFLiquid(mod, surf, img, mvp, NULL, surf->liquid_plane_normal,
			0, mtl_cull_cvar->value != 0, (int)mtl_drawflat_cvar->value)) MTL_BrushPolygonDrawn();
		return;
	}
	if (mod->bspversion != BSPVERSION_SOF && (flags & SURF_DRAWTURB))
	{
		MTL_DrawTurbSurface(mod, surf, img, mvp);
		return;
	}
	if (!surf->lighting)
	{
		return;
	}
	if (mtl_detail_cvar && mtl_detail_cvar->value && img->detail &&
	    !(flags & 0x400) && mtl_detail_count < 1024)
	{
		mtl_detail_surfaces[mtl_detail_count++] = surf;
		if (mtl_detail_cvar->value >= 3)
			return;
	}

	mtl_world_uniform_t u = {};
	memcpy(u.mvp, mvp, sizeof(u.mvp));
	if (mod->bspversion == BSPVERSION_SOF)
		MTL_LightmapFlow((unsigned)flags, surf->texinfo->value, MTL_GameTime(), u.lm_adjust);
	else if (flags & SURF_FLOWING)
	{
		u.lm_adjust[0] = -64.0f * ((mtl_refdef.time / 40.0f) - (int)(mtl_refdef.time / 40.0f));
		if (u.lm_adjust[0] == 0.0f) u.lm_adjust[0] = -64.0f;
	}
	u.overbright = MTL_Overbright(); /* Current GPL: scale after the colour table. */
	u.fullbright = (mtl_fullbright_cvar && mtl_fullbright_cvar->value != 0.0f) ||
		(mtl_refdef.rdflags & RDF_IRGOGGLES);
	const qboolean pdl_enabled = mtl_pdlight_cvar && (mtl_pdlight_cvar->value != 0.0f) &&
		(mod == mtl_worldmodel || mod->owner == mtl_worldmodel) && (mod->bspversion == BSPVERSION_SOF) &&
		surf->samples && !(flags & 0x800) &&
		!(mtl_refdef.rdflags & RDF_NOWORLDMODEL) &&
		(!mtl_gl_dynamic_cvar || mtl_gl_dynamic_cvar->value != 0.0f);
	u.pdlight[0] = pdl_enabled ? 1.0f : 0.0f;
	u.pdlight[1] = mtl_pdlight_scale_cvar ? mtl_pdlight_scale_cvar->value : 1.0f;
	u.pdlight[2] = mtl_pdlight_normal_cvar ?
		Q_max(0.0f, Q_min(mtl_pdlight_normal_cvar->value, 1.0f)) : 0.0f;
	u.pdlight[3] = mtl_pdlight_soft_cvar ?
		Q_max(0.0f, Q_min(mtl_pdlight_soft_cvar->value, 128.0f)) : 40.0f;
	u.texdim[0] = (float)img->width;
	u.texdim[1] = (float)img->height;
	memcpy(u.surface_normal, surf->normal, sizeof(surf->normal));
	memcpy(u.surface_s, surf->texinfo->vecs[0], sizeof(u.surface_s));
	memcpy(u.surface_t, surf->texinfo->vecs[1], sizeof(u.surface_t));
	u.dlight_meta[0] = pdl_enabled ? (float)mtl_pdlight_active_count : 0.0f;
	if (pdl_enabled && mtl_refdef.dlights)
	{
		for (int i = 0; i < mtl_pdlight_active_count; i++)
		{
			if (!(surf->dlightbits & (1u << i))) continue;
			const dlight_t *dl = &mtl_refdef.dlights[i];
			memcpy(u.dlight_origin_radius[i], dl->origin, sizeof(dl->origin));
			u.dlight_origin_radius[i][3] = dl->intensity;
			memcpy(u.dlight_color[i], dl->color, sizeof(dl->color));
		}
	}

	id<MTLBuffer> vb = (__bridge id<MTLBuffer>)mod->vbuf;
	[mtl_enc setRenderPipelineState:MTL_BuildWorldPipeline()];
#ifdef OM_METAL_CSM_SHADER_H
	MTL_CSMBindReceiver();
#endif
	[mtl_enc setVertexBuffer:vb offset:(NSUInteger)surf->first_vertex * MTL_WORLD_STRIDE atIndex:0];
	[mtl_enc setVertexBytes:&u length:sizeof(u) atIndex:1];
	[mtl_enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
	[mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)img->tex atIndex:0];
	qboolean dynamic = !mtl_gl_dynamic_cvar || mtl_gl_dynamic_cvar->value != 0.0f;
	id<MTLTexture> dynamic_layer = MTL_LightmapMakeDynamic(surf->lighting, surf->dlightbits,
		mtl_refdef.dlights, mtl_refdef.num_dlights, dynamic && mod->bspversion == BSPVERSION_SOF, pdl_enabled);
	if (!MTL_LightmapBind(surf->lighting, mtl_refdef.lightstyles, dynamic,
		mtl_modulate_latched, mtl_monolightmap_mode, dynamic_layer)) return;
	mtl_post_emission_controls_t controls = MTL_PostEmissionControls();
	mtl_post_fragment_uniform_t post = {{MTL_PostSurfaceEmission(flags, surf->texinfo->value, &controls), 0, 0, 1}};
	[mtl_enc setFragmentBytes:&post length:sizeof(post) atIndex:4];
	[mtl_enc setFragmentTexture:mtl_lighttable atIndex:2];
	[mtl_enc setFragmentSamplerState:mtl_samp_clamp atIndex:2];
	[mtl_enc setDepthStencilState:mtl_depth_world];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)surf->num_vertex];
	MTL_BrushPolygonDrawn();
}

typedef struct
{
	int nodes;
	int culled;
	int unmarked;
	int leaves;
	int candidates;
	int marked_surfaces;
} mtl_world_walk_stats_t;

static void
MTL_RecursiveWorldNode(mtl_model_t *mod, mnode_t *node, const float mvp[16], int *drawn,
					   mtl_world_walk_stats_t *stats)
{
	if (node->contents == CONTENTS_NODE)
	{
		qboolean culled;
		stats->nodes++;
		culled = R_CullBox(node->minmaxs, node->minmaxs + 3, mtl_frustum);
		if (mtl_world_debug_cvar && mtl_world_debug_cvar->value)
		{
			static int worlddebug_nodes;
			if (worlddebug_nodes++ < 24)
			{
				Com_Printf("ref_metal: walk node %td marked %d culled %d bounds %.3f %.3f %.3f .. %.3f %.3f %.3f\\n",
				           node - mod->nodes, node->visframe == mtl_visframecount, culled,
				           node->minmaxs[0], node->minmaxs[1], node->minmaxs[2],
				           node->minmaxs[3], node->minmaxs[4], node->minmaxs[5]);
			}
		}
		if ((!mtl_nocull_cvar || !mtl_nocull_cvar->value) && culled)
		{
			stats->culled++;
			return;
		}
		if (node->visframe != mtl_visframecount)
		{
			stats->unmarked++;
			return;
		}
	}
	else
	{
		mleaf_t *leaf = (mleaf_t *)node;
		stats->leaves++;
		if (leaf->visframe != mtl_visframecount)
		{
			return;
		}
		return;
	}

	for (int i = 0; i < node->numsurfaces; i++)
	{
		int idx = node->firstsurface + i;
		stats->candidates++;
		if (idx >= mod->numsurfaces)
		{
			break;
		}
		if (mod->surfaces[idx].visframe != mtl_framecount)
		{
			continue;
		}
		stats->marked_surfaces++;
		MTL_DrawSurface(mod, idx, mvp);
		(*drawn)++;
	}

	MTL_RecursiveWorldNode(mod, node->children[0], mvp, drawn, stats);
	MTL_RecursiveWorldNode(mod, node->children[1], mvp, drawn, stats);
}

/* ---- model loading ------------------------------------------------ */

static void
MTL_LoadWorldSurfaces(mtl_model_t *mod, const byte *base, const lump_t *faces,
                      int bspversion)
{
	int face_size = (bspversion == BSPVERSION_SOF) ? (int)sizeof(dface46_t) : (int)sizeof(dface_t);
	int count = faces->filelen / face_size;

	mod->surfaces = calloc(count, sizeof(mtl_surface_t));
	if (count && !mod->surfaces) { Com_Error(ERR_DROP, "ref_metal: surface allocation failed"); return; }
	mod->firstsurface = 0;
	mod->numsurfaces = count;

	/* count vertices first so one buffer can hold the whole model */
	int total = 0;
	for (int i = 0; i < count; i++)
	{
		const byte *f = base + faces->fileofs + (size_t)i * face_size;
		int numedges;
		if (bspversion == BSPVERSION_SOF)
		{
			numedges = ((const dface46_t *)f)->numedges;
		}
		else
		{
			numedges = ((const dface_t *)f)->numedges;
		}
		if (numedges > 2)
		{
			if ((numedges - 2) > (INT_MAX - total) / 3)
			{
				Com_Error(ERR_DROP, "ref_metal: BSP vertex count overflow");
				return;
			}
			total += (numedges - 2) * 3;
		}
	}

	mtl_world_vertex_t *verts = calloc((size_t)(total ? total : 1), sizeof(*verts));
	if (!verts) { Com_Error(ERR_DROP, "ref_metal: BSP vertex allocation failed"); return; }
	int v = 0;

	for (int i = 0; i < count; i++)
	{
		const byte *f = base + faces->fileofs + (size_t)i * face_size;
		mtl_surface_t *surf = &mod->surfaces[i];

		int planenum, side, firstedge, numedges, texinfo_index, lightofs;
		short lm_w = 1, lm_h = 1;
		short lm_step_s = 16, lm_step_t = 16;
		short lm_mins_s = 0, lm_mins_t = 0;
		short lm_ext_s = 0, lm_ext_t = 0;
		byte lm_styles[MAXLIGHTMAPS] = {255, 255, 255, 255};

		if (bspversion == BSPVERSION_SOF)
		{
			const dface46_t *in = (const dface46_t *)f;
			planenum = in->planenum;
			side = in->side;
			firstedge = in->firstedge;
			numedges = in->numedges;
			texinfo_index = in->texinfo;
			lightofs = in->lightofs;
			lm_w = in->lm_width;
			lm_h = in->lm_height;
			lm_step_s = in->lm_scale[0] * 16;
			lm_step_t = in->lm_scale[1] * 16;
			lm_mins_s = in->lm_mins[0];
			lm_mins_t = in->lm_mins[1];
			lm_ext_s = in->lm_extents[0];
			lm_ext_t = in->lm_extents[1];
			memcpy(lm_styles, in->styles, sizeof(lm_styles));
		}
		else
		{
			const dface_t *in = (const dface_t *)f;
			planenum = in->planenum;
			side = in->side;
			firstedge = in->firstedge;
			numedges = in->numedges;
			texinfo_index = in->texinfo;
			lightofs = in->lightofs;
			memcpy(lm_styles, in->styles, sizeof(lm_styles));
		}

		/* Region faces can have no ordinary textured ring or decoded image. */
		if (planenum >= 0 && planenum < mod->numplanes)
		{
			surf->bsp_plane = &mod->planes[planenum];
			surf->plane_back = side ? 1 : 0;
		}
		if (texinfo_index >= 0 && texinfo_index < mod->numtexinfo)
		{
			surf->texinfo = &mod->texinfo[texinfo_index];
			surf->flags = surf->texinfo->flags | (side ? SURF_PLANEBACK : 0);
		}
		if (numedges < 3 || texinfo_index < 0 || texinfo_index >= mod->numtexinfo ||
		    !MTL_BrushRange(firstedge, numedges, mod->numsurfedges) ||
		    planenum < 0 || planenum >= mod->numplanes)
		{
			continue;
		}
		qboolean valid_edges = true;
		for (int e = 0; e < numedges; e++)
		{
			int edge = mod->surfedges[firstedge + e];
			if (edge == INT_MIN || abs(edge) >= mod->numedges ||
			    mod->edges[abs(edge)].v[edge < 0] >= mod->numvertexes)
			{
				valid_edges = false;
				break;
			}
		}
		if (!valid_edges) continue;

		mtexinfo_t *ti = &mod->texinfo[texinfo_index];
		mtl_image_t *img = (mtl_image_t *)ti->image;
		if (!img || !img->tex)
		{
			continue;
		}

		const qboolean skyface = (ti->flags & SURF_DRAWSKY) != 0;
		vec3_t sky_ring[SKY_MAX_CLIP_VERTS];
		int sky_n = 0;

		surf->texinfo = ti;
		surf->flags = ti->flags | (side ? SURF_PLANEBACK : 0);
		if (planenum >= 0 && planenum < mod->numplanes)
		{
			VectorScale(mod->planes[planenum].normal, side ? -1.0f : 1.0f, surf->normal);
			VectorCopy(mod->planes[planenum].normal, surf->liquid_plane_normal);
		}
		surf->lm_w = lm_w;
		surf->lm_h = lm_h;
		surf->lm_step[0] = lm_step_s;
		surf->lm_step[1] = lm_step_t;
		surf->lm_mins[0] = lm_mins_s;
		surf->lm_mins[1] = lm_mins_t;
		surf->lm_extents[0] = lm_ext_s;
		surf->lm_extents[1] = lm_ext_t;
		memcpy(surf->styles, lm_styles, sizeof(surf->styles));

		/* Each style remains an independent byte plane. Combining before
		 * filtering would lose precision and saturate bright style sums early. */
		if (!skyface && !(ti->flags & (bspversion == BSPVERSION_SOF ? 8 : SURF_DRAWTURB)))
		{
			const byte *samples = NULL;
			size_t available = 0;
			if (lightofs >= 0)
			{
				if (!mod->lightdata || !MTL_BrushRange(lightofs, 0, mod->lightdata_bytes))
				{
					free(verts);
					Com_Error(ERR_DROP, "ref_metal: invalid lightmap sample offset");
					return;
				}
				samples = mod->lightdata + lightofs;
				available = (size_t)(mod->lightdata_bytes - lightofs);
			}
			int width = samples ? lm_w : (lm_w > 0 ? lm_w : lm_ext_s / 16 + 1);
			int height = samples ? lm_h : (lm_h > 0 ? lm_h : lm_ext_t / 16 + 1);
			mtl_lightmap_geometry_t geometry = {};
			memcpy(geometry.normal, surf->normal, sizeof(geometry.normal));
			geometry.distance = mod->planes[planenum].dist * (side ? -1.0f : 1.0f);
			memcpy(geometry.texvecs, ti->vecs, sizeof(geometry.texvecs));
			geometry.mins[0] = lm_mins_s; geometry.mins[1] = lm_mins_t;
			geometry.steps[0] = lm_step_s; geometry.steps[1] = lm_step_t;
			geometry.flags = (unsigned)ti->flags;
			surf->lighting = MTL_LightmapCreate(samples, available, width, height, lm_styles, &geometry);
			if (!surf->lighting)
			{
				free(verts);
				Com_Error(ERR_DROP, "ref_metal: invalid or unavailable lightmap planes");
				return;
			}
			surf->samples = samples;
			surf->lightmap = surf->lighting->planes[0]; /* borrowed compatibility alias */
		}

		/* fan-triangulate the face */
		vec3_t first = {0, 0, 0}, prev = {0, 0, 0};
		float uv_first[2] = {0, 0}, luv_first[2] = {0, 0};
		float uv_prev[2] = {0, 0}, luv_prev[2] = {0, 0};

		int start = v;

		for (int e = 0; e < numedges; e++)
		{
			int edge = mod->surfedges[firstedge + e];
			int vnum = (edge >= 0) ? mod->edges[edge].v[0] : mod->edges[-edge].v[1];
			vec3_t pos;
			VectorCopy(mod->vertexes[vnum].position, pos);

			/* sky faces keep their ring for the sky box clip (SPEC-410) */
			if (skyface && (sky_n < SKY_MAX_CLIP_VERTS))
			{
				/* VectorCopy evaluates its destination three times. */
				VectorCopy(pos, sky_ring[sky_n]);
				sky_n++;
			}

			float s = DotProduct(pos, ti->vecs[0]) + ti->vecs[0][3];
			float t = DotProduct(pos, ti->vecs[1]) + ti->vecs[1][3];

			float u = s / (float)img->width;
			float vv = t / (float)img->height;

			float ls = (s - (float)lm_mins_s + (float)lm_step_s * 0.5f) /
			           (float)(lm_ext_s + lm_step_s);
			float lt = (t - (float)lm_mins_t + (float)lm_step_t * 0.5f) /
			           (float)(lm_ext_t + lm_step_t);

			if (e == 0)
			{
				VectorCopy(pos, first);
				uv_first[0] = u; uv_first[1] = vv;
				luv_first[0] = ls; luv_first[1] = lt;
			}
			else if (e >= 2)
			{
				/* triangle first, prev, current */
				mtl_world_vertex_t tri[3] = {
					{{first[0], first[1], first[2]}, 0.0f, {uv_first[0], uv_first[1]}, {luv_first[0], luv_first[1]}},
					{{prev[0], prev[1], prev[2]}, 0.0f, {uv_prev[0], uv_prev[1]}, {luv_prev[0], luv_prev[1]}},
					{{pos[0], pos[1], pos[2]}, 0.0f, {u, vv}, {ls, lt}},
				};
				memcpy(&verts[v], tri, sizeof(tri));
				v += 3;
			}

			VectorCopy(pos, prev);
			uv_prev[0] = u; uv_prev[1] = vv;
			luv_prev[0] = ls; luv_prev[1] = lt;
		}

		surf->first_vertex = start;
		surf->num_vertex = v - start;
		surf->skyring_n = skyface ? sky_n : 0;
		if (skyface && (sky_n > 0))
		{
			memcpy(surf->skyring, sky_ring, sizeof(vec3_t) * sky_n);
		}
	}

	if (v > 0)
	{
		id<MTLBuffer> buf = [mtl_device newBufferWithBytes:verts
		                                            length:(NSUInteger)v * MTL_WORLD_STRIDE
		                                           options:MTLResourceStorageModeManaged];
		mod->vbuf = (void *)CFBridgingRetain(buf);
		mod->vbuf_vertices = v;
	}
	free(verts);

}

/* Static SoF model lighting is sampled from the first lightmapped surface
 * beneath the entity. This is the same BSP data already owned by the Metal
 * world renderer; it deliberately does not delegate to the GL3 renderer. */
static int
MTL_LightTrace(mtl_model_t *mod, mnode_t *node, const vec3_t start, const vec3_t end, vec3_t color)
{
	float front, back, frac;
	int side;
	vec3_t mid;

	if (!node || node->contents != CONTENTS_NODE)
	{
		return -1;
	}

	front = DotProduct(start, node->plane->normal) - node->plane->dist;
	back = DotProduct(end, node->plane->normal) - node->plane->dist;
	side = front < 0;
	if ((back < 0) == side)
	{
		return MTL_LightTrace(mod, node->children[side], start, end, color);
	}

	frac = front / (front - back);
	for (int k = 0; k < 3; k++)
	{
		mid[k] = start[k] + (end[k] - start[k]) * frac;
	}

	if (MTL_LightTrace(mod, node->children[side], start, mid, color) >= 0)
	{
		return 1;
	}

	for (int i = 0; i < node->numsurfaces; i++)
	{
		int index = node->firstsurface + i;
		if (index < 0 || index >= mod->numsurfaces)
		{
			continue;
		}
		mtl_surface_t *surf = &mod->surfaces[index];
		mtexinfo_t *tex = surf->texinfo;
		int s, t, ds, dt;

		/* SoF alpha faces are 0x800. Match GL3's static-light trace: water,
		 * sky and alpha surfaces cannot supply the entity's static light. */
			if (!tex || (surf->flags & ((mod->bspversion == BSPVERSION_SOF ? 8 : SURF_DRAWTURB) | SURF_DRAWSKY | 0x800)))
		{
			continue;
		}
		s = (int)(DotProduct(mid, tex->vecs[0]) + tex->vecs[0][3]);
		t = (int)(DotProduct(mid, tex->vecs[1]) + tex->vecs[1][3]);
		if (s < surf->lm_mins[0] || t < surf->lm_mins[1])
		{
			continue;
		}
		ds = s - surf->lm_mins[0];
		dt = t - surf->lm_mins[1];
		if (ds > surf->lm_extents[0] || dt > surf->lm_extents[1] ||
		    surf->lm_step[0] <= 0 || surf->lm_step[1] <= 0)
		{
			continue;
		}
		ds = (ds / 16) / (surf->lm_step[0] / 16);
		dt = (dt / 16) / (surf->lm_step[1] / 16);
		if (ds < 0 || dt < 0 || ds >= surf->lm_w || dt >= surf->lm_h)
		{
			continue;
		}
		if (!surf->samples)
		{
			VectorClear(color);
			return 1;
		}

		VectorClear(color);
		const byte *lightmap = surf->samples + 3 * (dt * surf->lm_w + ds);
		for (int map = 0; map < MAXLIGHTMAPS && surf->styles[map] != 255; map++)
		{
			const float *rgb = mtl_refdef.lightstyles ? mtl_refdef.lightstyles[surf->styles[map]].rgb : vec3_origin;
				float modulate = mtl_modulate_latched;
			for (int k = 0; k < 3; k++)
			{
				color[k] += lightmap[k] / 255.0f * rgb[k] * modulate;
				if (color[k] > 1.0f)
				{
					color[k] = 1.0f;
				}
			}
			lightmap += 3 * surf->lm_w * surf->lm_h;
		}
		return 1;
	}

	return MTL_LightTrace(mod, node->children[!side], mid, end, color);
}

/* Light-point static cache. Implements: SPEC-410 light sampling. A cell's
 * first query owns the static sample; dynamic lights are never cached. */
typedef struct {
	int cell[3], direction, lastuse;
	vec3_t color;
} mtl_lightcache_t;
static mtl_lightcache_t mtl_lightcache[1000];
static int mtl_lightcache_count, mtl_lightqueries;
static void MTL_ClearLightCache(void)
{
	mtl_lightcache_count = mtl_lightqueries = 0;
}

static void
MTL_SoFLightPointDir(const vec3_t point, vec3_t color, int direction)
{
	if (!mtl_worldmodel || !mtl_worldmodel->lightdata)
	{
		VectorSet(color, 1, 1, 1);
		return;
	}

	int cell[3], found = -1;
	for (int k = 0; k < 3; k++) cell[k] = (int)floorf((point[k] + 4096) / 32);
	mtl_lightqueries++;
	for (int i = 0; i < mtl_lightcache_count; i++)
	{
		mtl_lightcache_t *entry = &mtl_lightcache[i];
		if (entry->direction == direction && !memcmp(entry->cell, cell, sizeof(cell)))
		{
			entry->lastuse = mtl_lightqueries;
			VectorCopy(entry->color, color);
			found = i;
			break;
		}
	}
	if (found < 0)
	{
		vec3_t end = {point[0], point[1], point[2] - 2048.0f};
		if (direction >= 0 && direction < mtl_sof_dircount)
			VectorMA(point, 256, mtl_sof_dirtable[direction], end);
		if (MTL_LightTrace(mtl_worldmodel, mtl_worldmodel->nodes, point, end, color) < 0)
			VectorSet(color, 0.1f, 0.1f, 0.1f);
		if (mtl_lightcache_count > 200)
		{
			int count = 0;
			for (int i = 0; i < mtl_lightcache_count; i++)
				if (mtl_lightqueries - mtl_lightcache[i].lastuse <= 100)
					mtl_lightcache[count++] = mtl_lightcache[i];
			mtl_lightcache_count = count;
		}
		if (mtl_lightcache_count < 1000)
		{
			mtl_lightcache_t *entry = &mtl_lightcache[mtl_lightcache_count++];
			memcpy(entry->cell, cell, sizeof(cell));
			entry->direction = direction;
			entry->lastuse = mtl_lightqueries;
			VectorCopy(color, entry->color);
		}
	}

	for (int i = 0; i < mtl_refdef.num_dlights; i++)
	{
		dlight_t *dl = &mtl_refdef.dlights[i];
		vec3_t delta;
		VectorSubtract(point, dl->origin, delta);
		float add = (dl->intensity - VectorLength(delta)) / 256.0f;
		if (add > 0.0f)
		{
			VectorMA(color, add, dl->color, color);
		}
	}

	float modulate = mtl_modulate_latched;
	for (int k = 0; k < 3; k++)
	{
		color[k] *= modulate;
		if (color[k] > 1.0f)
		{
			color[k] = 1.0f;
		}
	}
}

static void
MTL_SoFLightPoint(const vec3_t point, vec3_t color)
{
	MTL_SoFLightPointDir(point,color,255);
}

Q2_DLL_EXPORTED void
OM_SetSoFDirTable(const float (*table)[3], int count)
{
	mtl_sof_dircount = table ? Q_max(0,Q_min(count,250)) : 0;
	if (mtl_sof_dircount) memcpy(mtl_sof_dirtable,table,(size_t)mtl_sof_dircount*sizeof(mtl_sof_dirtable[0]));
}

/* Mirrors GL3_DrawAliasModel's entity-light rules before the MD2 normal
 * dot product is applied to each vertex.  This intentionally uses the
 * renderer-owned refdef and native BSP light sampler rather than GL state. */
static void
MTL_AliasShadeLight(const entity_t *e, vec3_t shadelight)
{
	if (e->flags & (RF_SHELL_HALF_DAM | RF_SHELL_GREEN | RF_SHELL_RED |
	                RF_SHELL_BLUE | RF_SHELL_DOUBLE))
	{
		VectorClear(shadelight);
		if (e->flags & RF_SHELL_HALF_DAM)
		{
			shadelight[0] = 0.56f;
			shadelight[1] = 0.59f;
			shadelight[2] = 0.45f;
		}
		if (e->flags & RF_SHELL_DOUBLE)
		{
			shadelight[0] = 0.9f;
			shadelight[1] = 0.7f;
		}
		if (e->flags & RF_SHELL_RED)
			shadelight[0] = 1.0f;
		if (e->flags & RF_SHELL_GREEN)
			shadelight[1] = 1.0f;
		if (e->flags & RF_SHELL_BLUE)
			shadelight[2] = 1.0f;
	}
	else if (e->flags & RF_FULLBRIGHT)
	{
		VectorSet(shadelight, 1.0f, 1.0f, 1.0f);
	}
	else
	{
		MTL_SoFLightPoint(e->origin, shadelight);
	}

	if (e->flags & RF_MINLIGHT)
	{
		if (shadelight[0] <= 0.1f && shadelight[1] <= 0.1f && shadelight[2] <= 0.1f)
			VectorSet(shadelight, 0.1f, 0.1f, 0.1f);
	}

	if (e->flags & RF_GLOW)
	{
		float scale = 0.1f * sinf(mtl_refdef.time * 7.0f);
		for (int i = 0; i < 3; i++)
		{
			float minimum = shadelight[i] * 0.8f;
			shadelight[i] += scale;
			if (shadelight[i] < minimum)
				shadelight[i] = minimum;
		}
	}

	if ((mtl_refdef.rdflags & RDF_IRGOGGLES) && (e->flags & RF_IR_VISIBLE))
		VectorSet(shadelight, 1.0f, 0.0f, 0.0f);
	/* Current GPL alias passColor uses the view's overbright independently
	 * of the Ghoul-only models toggle, before the fragment's 1.5 cap. */
	VectorScale(shadelight, MTL_Overbright(), shadelight);
}

/* SPEC-410 model lights: load the SoF BSP's map-lifetime light records into
 * the native Ghoul system.  This is deliberately a data handoff, not a GL
 * compatibility path; the native Ghoul sink evaluates the resulting lights. */
static void
MTL_SoF_WorldLights(const byte *lights, int len)
{
	if (!mtl_ghoul_system || !lights || len < 36)
	{
		return;
	}

	OMGhoul_BeginWorldLights(mtl_ghoul_system);
	for (int i = 0; i < len / 36; i++)
	{
		const byte *record = lights + 36 * i;
		float intensity = LittleFloat(*(const float *)(record + 24));
		int type = LittleLong(*(const int *)(record + 28));
		int extra = LittleLong(*(const int *)(record + 32));
		om_ghoul_light_t light = {};

		if (intensity <= 0.0f || type == 3)
		{
			continue;
		}

		light.radius = (type == 0 || extra >= 2) ? sqrtf(intensity) * 0.5f : intensity;
		if (light.radius > 1500.0f)
		{
			continue;
		}
		for (int axis = 0; axis < 3; axis++)
		{
			light.origin[axis] = LittleFloat(*(const float *)(record + 4 * axis));
			light.color[axis] = LittleFloat(*(const float *)(record + 12 + 4 * axis));
		}
		OMGhoul_AddWorldLight(mtl_ghoul_system, &light);
	}
	OMGhoul_FinishWorldLights(mtl_ghoul_system);
}

#include "mtl_damage.h"
/* Native brush ownership. Inline views never release their shared parent's resources. */
static void
MTL_TrackModelImage(mtl_model_t *mod, mtl_image_t *image)
{
	if (!image || image == mtl_notexture) return;
	for (int i = 0; i < mod->num_owned_images; i++)
		if (mod->owned_images[i] == image) return;
	mtl_image_t **images = realloc(mod->owned_images,
		(size_t)(mod->num_owned_images + 1) * sizeof(*images));
	if (!images) { Com_Error(ERR_DROP, "ref_metal: model image ownership allocation failed"); return; }
	mod->owned_images = images;
	mod->owned_images[mod->num_owned_images++] = image;
	MTL_TrackModelImage(mod, image->detail);
	MTL_TrackModelImage(mod, image->damage);
}

static void
MTL_FreeModel(mtl_model_t *mod)
{
	if (!mod || (mod->owner && mod->owner != mod)) return;
	MTL_FogFree(mod);
	for (int i = 0; i < mod->numsurfaces; i++)
		MTL_LightmapFree(mod->surfaces[i].lighting);
	if (mod->vbuf) CFRelease(mod->vbuf);
	for (int i = 0; i < mod->num_owned_images; i++)
	{
		mtl_image_t *image = mod->owned_images[i];
		if (image->tex) CFRelease(image->tex);
		free(image);
	}
	free(mod->owned_images);
	free(mod->surfaces);
	free(mod->leafs);
	free(mod->marksurfaces);
	free(mod->submodels);
	Hunk_Free(mod->hunk);
	free(mod);
}

static void
MTL_RemoveModel(mtl_model_t *mod)
{
	for (int i = 0; i < mtl_nummodels; i++)
	{
		if (mtl_models[i] != mod) continue;
		if (mtl_worldmodel == mod) { MTL_DamageForget(); mtl_worldmodel = NULL; }
		MTL_FreeModel(mod);
		memmove(&mtl_models[i], &mtl_models[i+1], (size_t)(mtl_nummodels-i-1)*sizeof(*mtl_models));
		mtl_nummodels--;
		return;
	}
}

static void
MTL_FreeModels(void)
{
	if (mtl_nummodels) MTL_ModelFence();
	while (mtl_nummodels) MTL_RemoveModel(mtl_models[mtl_nummodels-1]);
	free(mtl_models);
	mtl_models = NULL;
	mtl_worldmodel = NULL;
	MTL_PostSetFogRegionCount(0);
	mtl_alpha_count = mtl_detail_count = 0;
	mtl_last_cluster = -1;
	MTL_ClearLightCache();
}

static struct model_s *
MTL_LoadBrushModel(const char *name)
{
	byte *buf = NULL;
	int len = ri.FS_LoadFile(name, (void **)&buf);
	if (!buf || len <= 0)
	{
		Com_Printf("ref_metal: can't load %s\n", name);
		return NULL;
	}

	if (len < 8) { ri.FS_FreeFile(buf); return NULL; }
	const dheader_t *header = (const dheader_t *)buf;
	int version = LittleLong(header->version);
	if (version != BSPVERSION_SOF && version != BSPVERSION)
	{
		Com_Printf("ref_metal: %s has unsupported BSP version %d\n", name, version);
		ri.FS_FreeFile(buf);
		return NULL;
	}
	if (len < (int)(version == BSPVERSION_SOF ? sizeof(dheader46_t) : sizeof(dheader_t)))
	{
		Com_Printf("ref_metal: %s has a truncated SoF BSP header\n", name);
		ri.FS_FreeFile(buf);
		return NULL;
	}
	int lumpcount = version == BSPVERSION_SOF ? HEADER_LUMPS_SOF : HEADER_LUMPS;
	for (int i = 0; i < lumpcount; i++)
	{
		const lump_t *lump = &header->lumps[i];
		if (!MTL_BrushRange(lump->fileofs, lump->filelen, len))
		{
			ri.FS_FreeFile(buf);
			Com_Error(ERR_DROP, "ref_metal: bad BSP lump range in %s", name);
			return NULL;
		}
	}
	const lump_t *lmodels = &header->lumps[LUMP_MODELS];
	const lump_t *faces = &header->lumps[LUMP_FACES];
	int face_size = version == BSPVERSION_SOF ? sizeof(dface46_t) : sizeof(dface_t);
	int numsub = lmodels->filelen / (int)sizeof(dmodel_t);
	if (!numsub || lmodels->filelen % sizeof(dmodel_t) || faces->filelen % face_size ||
	    len > (INT_MAX - (1 << 20)) / 8)
	{
		ri.FS_FreeFile(buf);
		Com_Error(ERR_DROP, "ref_metal: bad BSP models/faces in %s", name);
		return NULL;
	}
	const dmodel_t *dmodels = (const dmodel_t *)(buf + lmodels->fileofs);
	int totalfaces = faces->filelen / face_size;
	int totalnodes = header->lumps[LUMP_NODES].filelen / (int)sizeof(dnode_t);
	int totalleafs = header->lumps[LUMP_LEAFS].filelen /
		(int)(version == BSPVERSION_SOF ? sizeof(dleaf46_t) : sizeof(dleaf_t));
	for (int i = 0; i < numsub; i++)
	{
		if (!MTL_BrushDescriptorValid(i, dmodels[i].firstface, dmodels[i].numfaces,
			dmodels[i].headnode, totalfaces, totalnodes, totalleafs))
		{
			ri.FS_FreeFile(buf);
			Com_Error(ERR_DROP, "ref_metal: invalid inline descriptor in %s", name);
			return NULL;
		}
	}

	mtl_model_t *mod = calloc(1, sizeof(*mod));
	if (!mod) { ri.FS_FreeFile(buf); Com_Error(ERR_DROP, "ref_metal: model allocation failed"); return NULL; }
	Q_strlcpy(mod->name, name, sizeof(mod->name));
	mod->bspversion = version;
	mod->type = mod_brush;
	mod->owner = mod;
	mod->numsubmodels = numsub;
	mod->submodels = calloc(numsub, sizeof(*mod->submodels));
	if (!mod->submodels) { free(mod); ri.FS_FreeFile(buf); Com_Error(ERR_DROP, "ref_metal: inline allocation failed"); return NULL; }

	/* the shared lump loaders allocate from the engine hunk */
	mod->hunk = Hunk_Begin(len * 8 + (1 << 20));

	mod->vertexes = NULL;
	Mod_LoadVertexes(name, &mod->vertexes, &mod->numvertexes, buf, &header->lumps[LUMP_VERTEXES], 0);
	Mod_LoadEdges(name, &mod->edges, &mod->numedges, buf, &header->lumps[LUMP_EDGES], 0);
	Mod_LoadSurfedges(name, &mod->surfedges, &mod->numsurfedges, buf, &header->lumps[LUMP_SURFEDGES], 0);
	Mod_LoadTexinfo(name, &mod->texinfo, &mod->numtexinfo, buf, &header->lumps[LUMP_TEXINFO],
	                (findimage_t)MTL_FindImage, (struct image_s *)mtl_notexture, 0);
	for (int i = 0; i < mod->numtexinfo; i++)
		MTL_TrackModelImage(mod, (mtl_image_t *)mod->texinfo[i].image);
	Mod_LoadLighting(&mod->lightdata, buf, &header->lumps[LUMP_LIGHTING]);
	mod->lightdata_bytes = header->lumps[LUMP_LIGHTING].filelen;
	Mod_LoadVisibility(&mod->vis, buf, &header->lumps[LUMP_VISIBILITY]);
	Mod_LoadPlanes(name, &mod->planes, &mod->numplanes, buf, &header->lumps[LUMP_PLANES], 0);
	MTL_LoadLeafs(mod, buf, &header->lumps[LUMP_LEAFS], version);
	Mod_LoadNodes(name, mod->planes, mod->numplanes, mod->leafs, mod->numleafs,
	              &mod->nodes, &mod->numnodes, buf, &header->lumps[LUMP_NODES]);

	Com_Printf("ref_metal: %s bsp v%d, %d vertices, %d faces\n",
	           name, version, mod->numvertexes, (int)dmodels[0].numfaces);

	MTL_LoadWorldSurfaces(mod, buf, faces, version);
	/* GFX-modern: the compiler's sun keys of worldspawn for the sun shadows (SPEC-AMEND-016 R16.2) */
#ifdef OM_METAL_CSM_SHADER_H
	MTL_CSMLoadSun((const char *)buf + header->lumps[LUMP_ENTITIES].fileofs, header->lumps[LUMP_ENTITIES].filelen);
#endif
	MTL_LinkMarksurfaces(mod, buf, &header->lumps[LUMP_LEAFFACES]);
	if (version == BSPVERSION_SOF)
	{
		const dheader46_t *header46 = (const dheader46_t *)buf;
		if (!MTL_FogLoad(mod, buf, (size_t)len, faces,
			&header46->lumps[LUMP_FACEPOLYS], &header46->lumps[LUMP_VOLUMES],
			&header46->lumps[LUMP_LEAFS]))
		{
			Hunk_End();
			MTL_FreeModel(mod);
			ri.FS_FreeFile(buf);
			Com_Error(ERR_DROP, "ref_metal: invalid fog regions in %s", name);
			return NULL;
		}
	}
	for (int i = 0; i < numsub; i++)
	{
		mtl_model_t *view = &mod->submodels[i];
		*view = *mod;
		view->fog = NULL;
		Com_sprintf(view->name, sizeof(view->name), "*%d", i);
		for (int k = 0; k < 3; k++)
		{
			view->mins[k] = LittleFloat(dmodels[i].mins[k]) - 1;
			view->maxs[k] = LittleFloat(dmodels[i].maxs[k]) + 1;
			view->origin[k] = LittleFloat(dmodels[i].origin[k]);
		}
		view->radius = Mod_RadiusFromBounds(view->mins, view->maxs);
		view->firstnode = LittleLong(dmodels[i].headnode);
		view->firstsurface = LittleLong(dmodels[i].firstface);
		view->nummodelsurfaces = LittleLong(dmodels[i].numfaces);
	}
	mtl_model_t *world = &mod->submodels[0];
	VectorCopy(world->mins, mod->mins);
	VectorCopy(world->maxs, mod->maxs);
	VectorCopy(world->origin, mod->origin);
	mod->radius = world->radius;
	mod->firstnode = world->firstnode;
	mod->firstsurface = world->firstsurface;
	mod->nummodelsurfaces = world->nummodelsurfaces;
	if (version == BSPVERSION_SOF)
	{
		const dheader46_t *header46 = (const dheader46_t *)buf;
		const lump_t *model_lights = &header46->lumps[LUMP_LIGHTS];
		MTL_SoF_WorldLights(buf + model_lights->fileofs, model_lights->filelen);
		if (mtl_ghoul_system && model_lights->filelen < 36)
		{
			OMGhoul_BeginWorldLights(mtl_ghoul_system);
			OMGhoul_FinishWorldLights(mtl_ghoul_system);
		}
	}
	Hunk_End();

	ri.FS_FreeFile(buf);

	return (struct model_s *)mod;
}

/* ---- refexport_t -------------------------------------------------- */

static qboolean
MTL_Init(void)
{
	mtl_vsync_cvar = ri.Cvar_Get("r_vsync", "1", CVAR_ARCHIVE);
#ifdef OM_RLABS_KIT
	if (rlk_hud_available()) /* the Video row stays hidden when the launcher did not enable Metal's HUD */
		mtl_perfhud_cvar = ri.Cvar_Get("r_perfhud", "0", CVAR_ARCHIVE);
#endif
	mtl_fullscreen_cvar = ri.Cvar_Get("vid_fullscreen", "0", CVAR_ARCHIVE);
	mtl_mode_cvar = ri.Cvar_Get("r_mode", "-2", CVAR_ARCHIVE);

	/* SPEC-413 §9: the image colour table exists before the first image is
	   loaded; same cvar names and defaults as the GL3 reference. Cvars set by
	   earlier cfg execs (vid_brightness/contrast 0.6 in this data set) win. */
	vid_gamma = ri.Cvar_Get("vid_gamma", "0.0", CVAR_ARCHIVE);
	vid_brightness = ri.Cvar_Get("vid_brightness", "0.5", CVAR_ARCHIVE);
	vid_contrast = ri.Cvar_Get("vid_contrast", "0.5", CVAR_ARCHIVE);
	MTL_SoF_BuildColorTable(vid_gamma->value, vid_brightness->value,
	                        vid_contrast->value, 1.0f);

	/* SPEC-413 §6 clip distances and gl_skymip (sky texel inset) */
	mtl_nearclip_cvar = ri.Cvar_Get("r_nearclipdist", "0", 0);
	mtl_farclip_cvar = ri.Cvar_Get("r_farclipdist", "65535.0", 0);
	mtl_skymip_cvar = ri.Cvar_Get("gl_skymip", "0", 0);
	mtl_ghoul_debug_cvar = ri.Cvar_Get("r_metal_ghouldebug", "0", 0);
	mtl_ghoul_light_method_cvar = ri.Cvar_Get("ghl_light_method", "3", CVAR_ARCHIVE);
	mtl_ghoul_light_multiply_cvar = ri.Cvar_Get("ghl_light_multiply", "1.3", CVAR_ARCHIVE);
	mtl_ghoul_specular_cvar = ri.Cvar_Get("ghl_specular", "1", CVAR_ARCHIVE);
	mtl_ghoul_max_lights_cvar = ri.Cvar_Get("ghl_max_lights", "3", CVAR_ARCHIVE);
	mtl_ghoul_fast_lights_cvar = ri.Cvar_Get("ghl_fast_lights", "0", CVAR_ARCHIVE);
	mtl_ghoul_mip_cvar = ri.Cvar_Get("ghl_mip", "0", CVAR_ARCHIVE);
	mtl_ghoul_gllight_directional_cvar = ri.Cvar_Get("ghl_gllight_directional", "0", CVAR_ARCHIVE);
	mtl_ghoul_gllight_attenuation_cvar = ri.Cvar_Get("ghl_gllight_attenuation", "1", CVAR_ARCHIVE);
	mtl_ghoul_gllight_max_lights_cvar = ri.Cvar_Get("ghl_gllight_max_lights", "6", CVAR_ARCHIVE);
	mtl_ghoul_local_viewer_cvar = ri.Cvar_Get("ghl_gllight_local_viewer", "1", CVAR_ARCHIVE);
	mtl_modulate_cvar = ri.Cvar_Get("gl_modulate", "1", CVAR_ARCHIVE);
	mtl_modulate_latched = mtl_modulate_cvar->value;
	mtl_monolightmap_cvar = ri.Cvar_Get("gl_monolightmap", "0", CVAR_ARCHIVE);
	mtl_gunfov_cvar = ri.Cvar_Get("r_gunfov", "80", CVAR_ARCHIVE);
	mtl_particle_size_cvar = ri.Cvar_Get("gl3_particle_size", "40", CVAR_ARCHIVE);
	mtl_particle_debug_cvar = ri.Cvar_Get("r_metal_particledebug", "0", 0);
	mtl_fullbright_cvar = ri.Cvar_Get("r_fullbright", "0", 0);
	mtl_world_debug_cvar = ri.Cvar_Get("r_metal_worlddebug", "0", 0);
	mtl_nocull_cvar = ri.Cvar_Get("r_nocull", "0", 0);
	mtl_cull_cvar = ri.Cvar_Get("gl_cull", "1", 0);
	mtl_drawflat_cvar = ri.Cvar_Get("gl_drawflat", "0", 0);
	/* GFX-modern: retain GL3's cvar names/defaults so native and parity
	 * captures exercise exactly the same dynamic-light fixture. */
	mtl_pdlight_cvar = ri.Cvar_Get("r_om_pdlight", "1", CVAR_ARCHIVE);
	mtl_pdlight_max_cvar = ri.Cvar_Get("r_om_pdlight_max", "32", CVAR_ARCHIVE);
	mtl_pdlight_scale_cvar = ri.Cvar_Get("r_om_pdlight_scale", "1", CVAR_ARCHIVE);
	mtl_pdlight_normal_cvar = ri.Cvar_Get("r_om_pdlight_normal", "0", CVAR_ARCHIVE);
	mtl_pdlight_soft_cvar = ri.Cvar_Get("r_om_pdlight_soft", "40", CVAR_ARCHIVE);
	mtl_pdlight_test_cvar = ri.Cvar_Get("r_om_pdlight_test", "0", 0);
	mtl_gl_dynamic_cvar = ri.Cvar_Get("gl_dynamic", "1", 0);
	mtl_texturemode_cvar = ri.Cvar_Get("gl_texturemode", "GL_LINEAR_MIPMAP_LINEAR", CVAR_ARCHIVE);
	mtl_scissor_broken_cvar = ri.Cvar_Get("gl_scissor_broken", "0", CVAR_ARCHIVE);
	mtl_anisotropic_cvar = ri.Cvar_Get("r_anisotropic", "16", CVAR_ARCHIVE);
	mtl_ext_anisotropic_cvar = ri.Cvar_Get("gl_ext_anisotropic", "1", CVAR_ARCHIVE);
	mtl_detail_cvar = ri.Cvar_Get("gl_detailtexturing", "1", CVAR_ARCHIVE);
	mtl_detail_distance_cvar = ri.Cvar_Get("gl_detailtexturingdistance", "250", CVAR_ARCHIVE);
	mtl_offset_factor_cvar = ri.Cvar_Get("gl_offsetfactor", "-2.0", CVAR_ARCHIVE);
	mtl_offset_units_cvar = ri.Cvar_Get("gl_offsetunits", "-2.0", CVAR_ARCHIVE);

	for (int i = 0; i < 256; i++)
	{
		mtl_palette[i] = 0xff000000u | ((unsigned)i << 16) | ((unsigned)i << 8) | (unsigned)i;
	}

	ri.Cmd_AddCommand("screenshot", MTL_Screenshot_f);

	/* the renderer owns window creation on this engine (SPEC-002), as in the GL3 module */
	int w = 1280, h = 720;
	int mode = (int)mtl_mode_cvar->value;

	if (mode >= 0)
	{
		if (!ri.Vid_GetModeInfo(&w, &h, mode))
		{
			Com_Printf("ref_metal: invalid r_mode %d, using 1280x720\n", mode);
			w = 1280;
			h = 720;
		}
	}
	else if (mode == -1)
	{
		/* Match GL3's custom-mode entry point used by the video menu. */
		double custom_w = ri.Cvar_Get("r_customwidth", "1024", CVAR_ARCHIVE)->value;
		double custom_h = ri.Cvar_Get("r_customheight", "768", CVAR_ARCHIVE)->value;
		if (custom_w >= 1 && custom_w <= INT_MAX && custom_h >= 1 && custom_h <= INT_MAX)
		{
			w = (int)custom_w;
			h = (int)custom_h;
		}
	}
	else if (mode == -2)
	{
		if (!ri.GLimp_GetDesktopMode(&w, &h))
		{
			w = 1280;
			h = 720;
		}
	}

	int fullscreen = (int)mtl_fullscreen_cvar->value;

	Com_Printf("ref_metal: %dx%d (vid_fullscreen %d)\n", w, h, fullscreen);

	if (!ri.GLimp_InitGraphics(fullscreen, &w, &h))
	{
		return false;
	}

	return true;
}

static void
MTL_Shutdown(void)
{
	OMGhoul_SetNativeSink(NULL);
	mtl_ghoul_system = NULL;
	/* context teardown is ShutdownContext */
}

static int
MTL_PrepareForWindow(void)
{
	return 0;
}

static int
MTL_InitContext(void *sdl_window)
{
	mtl_window = (SDL_Window *)sdl_window;
	Com_Printf("ref_metal: init context (SDL window %p)\n", sdl_window);

	mtl_device = MTLCreateSystemDefaultDevice();
	if (!mtl_device)
	{
		Com_Printf("ref_metal: no Metal device\n");
		return 0;
	}

	mtl_queue = [mtl_device newCommandQueue];
	mtl_inflight = dispatch_semaphore_create(3);

	mtl_view = SDL_Metal_CreateView(mtl_window);
	if (!mtl_view)
	{
		Com_Printf("ref_metal: SDL_Metal_CreateView failed: %s\n", SDL_GetError());
		return 0;
	}

	mtl_layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(mtl_view);
	if (!mtl_layer)
	{
		Com_Printf("ref_metal: no CAMetalLayer\n");
		return 0;
	}

	mtl_layer.device = mtl_device;
	mtl_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	mtl_layer.framebufferOnly = NO; /* native screenshot/thumbnail blit source */
	mtl_layer.maximumDrawableCount = 3;
	mtl_vsync = !mtl_vsync_cvar || (mtl_vsync_cvar->value != 0);
	mtl_layer.displaySyncEnabled = mtl_vsync;
#ifdef OM_RLABS_KIT
	if (mtl_perfhud_cvar)
	{
		rlk_hud_set((__bridge void *)mtl_layer, mtl_perfhud_cvar->value != 0);
		mtl_perfhud_cvar->modified = false;
	}
#endif

	mtl_pipe2d = MTL_BuildPipeline(NO, YES);
	mtl_pipe_sof2d = MTL_BuildPipeline(YES, YES);
	mtl_pipe_sof2d_replace = MTL_BuildPipeline(YES, NO);
	mtl_samp_ui_linear = MTL_MakeUISampler(YES);
	mtl_samp_ui = MTL_MakeUISampler(NO);
	mtl_samp_clamp = MTL_MakeSampler(NO);
	mtl_samp_repeat = MTL_MakeSampler(YES);
	for (int u = 0; u < 2; u++)
		for (int v = 0; v < 2; v++)
			for (int n = 0; n < 2; n++)
				mtl_ghoul_samplers[u][v][n] = MTL_MakeGhoulSampler(u, v, n);
	mtl_samp_lm = mtl_samp_clamp;

	/* the SPEC-413 §9 table as a 256 x 1 texture for the world shader's
	   lightmap lookup (mirrors the GL3 reference's omColorTable) */
	{
		MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
		td.textureType = MTLTextureType2D;
		td.pixelFormat = MTLPixelFormatR8Unorm;
		td.width = 256;
		td.height = 1;
		td.usage = MTLTextureUsageShaderRead;
		mtl_lighttable = [mtl_device newTextureWithDescriptor:td];
		[mtl_lighttable replaceRegion:MTLRegionMake2D(0, 0, 256, 1)
		                  mipmapLevel:0 withBytes:mtl_colortable bytesPerRow:256];
	}

	MTLDepthStencilDescriptor *dsw = [[MTLDepthStencilDescriptor alloc] init];
	dsw.depthCompareFunction = MTLCompareFunctionLessEqual;
	dsw.depthWriteEnabled = YES;
	mtl_depth_world = [mtl_device newDepthStencilStateWithDescriptor:dsw];
	MTLDepthStencilDescriptor *dsr = [[MTLDepthStencilDescriptor alloc] init];
	dsr.depthCompareFunction = MTLCompareFunctionLessEqual;
	dsr.depthWriteEnabled = NO;
	mtl_depth_readonly = [mtl_device newDepthStencilStateWithDescriptor:dsr];

	MTLDepthStencilDescriptor *ds2 = [[MTLDepthStencilDescriptor alloc] init];
	ds2.depthCompareFunction = MTLCompareFunctionAlways;
	ds2.depthWriteEnabled = NO;
	mtl_depth_2d = [mtl_device newDepthStencilStateWithDescriptor:ds2];

	MTLDepthStencilDescriptor *dss = [[MTLDepthStencilDescriptor alloc] init];
	/* SPEC-410 Sky: the box is drawn after the world; it must lose the depth
	   test against every closer world pixel and must not write depth */
	dss.depthCompareFunction = MTLCompareFunctionLessEqual;
	dss.depthWriteEnabled = NO;
	mtl_depth_sky = [mtl_device newDepthStencilStateWithDescriptor:dss];

	mtl_pipe_world = MTL_BuildWorldPipeline();
	mtl_pipe_sky = MTL_BuildSkyPipeline();
	MTL_PostEmissionInit();
	MTL_OverbrightInit();
	MTL_PostInit();
	MTL_VolFogInit();
	MTL_CSMInit();
	MTL_PostOverlayInit();
	MTL_BloomInit();
	mtl_framepost_process_view = MTL_ProcessBloomView;
	mtl_framepost_composite_view = MTL_CompositeBloomView;
	mtl_pipe_alias = MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_OPAQUE, false);
	mtl_pipe_alias_alpha = MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ALPHA, false);
	mtl_pipe_alias_additive = MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ADDITIVE, false);
	mtl_pipe_ghoul = MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_OPAQUE, 2);
	mtl_pipe_fx_alpha = MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ALPHA, 2);
	mtl_pipe_fx_additive = MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ADDITIVE, 2);
	mtl_pipe_fx_darken = MTL_BuildAliasPipeline(MTL_BLEND_DARKEN, 2);
	mtl_pipe_detail = MTL_BuildAliasPipeline(MTL_BLEND_DETAIL, true);
	mtl_pipe_detail_replace = MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_OPAQUE, true);
	mtl_pipe_particles = MTL_BuildParticlePipeline();
	mtl_pipe_turb_opaque = MTL_BuildTurbPipeline(false);
	mtl_pipe_turb_alpha = MTL_BuildTurbPipeline(true);
	MTL_LiquidInit();

	/* a 64x64 magenta/black checker for surfaces whose texture is missing */
	{
		enum { NT = 64 };
		byte *nt = malloc(NT * NT * 4);
		for (int y = 0; y < NT; y++)
		{
			for (int x = 0; x < NT; x++)
			{
				int on = ((x / 8) + (y / 8)) & 1;
				byte *px = &nt[(y * NT + x) * 4];
				px[0] = on ? 255 : 0;
				px[1] = 0;
				px[2] = on ? 255 : 0;
				px[3] = 255;
			}
		}
		mtl_notexture = calloc(1, sizeof(*mtl_notexture));
		Q_strlcpy(mtl_notexture->name, "*notex", sizeof(mtl_notexture->name));
		mtl_notexture->width = NT;
		mtl_notexture->height = NT;
		mtl_notexture->sh = 1.0f;
		mtl_notexture->th = 1.0f;
		mtl_notexture->tex = MTL_NewTextureChain(nt, NT, NT, NO);
		free(nt);
	}

	byte white[4] = {255, 255, 255, 255};
	id<MTLTexture> wtex =
		[mtl_device newTextureWithDescriptor:
			[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
			                                                   width:1 height:1 mipmapped:NO]];
	[wtex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:white bytesPerRow:4];
	mtl_white = wtex;

	MTL_UpdateSizes();

	Com_Printf("ref_metal: %s, drawable %dx%d\n",
	           mtl_device.name.UTF8String, mtl_width, mtl_height);

	draw_chars = MTL_FindPic("conchars");
	if (draw_chars)
	{
		Com_Printf("ref_metal: charset %dx%d\n", draw_chars->width, draw_chars->height);
	}

	return 1;
}

static void
MTL_ShutdownContext(void)
{
	MTL_GhoulTexCacheFlush(); /* RLabs: cached Ghoul textures belong to this device */
	MTL_FrameRingFree();
	MTL_FreeModels();
	MTL_FreeSkyImages();
	MTL_LightmapsShutdown();
	MTL_GenericModelsShutdown();
	MTL_LiquidShutdown();
	MTL_PostOverlayShutdown();
	MTL_PostShutdown();
	MTL_BloomShutdown();
	MTL_PostEmissionShutdown();
	MTL_TargetEnd();
	MTL_TargetReset();
	mtl_last_drawable=nil;
	MTL_ClearLightCache();
	MTL_SoF_HUDShutdown();
	MTL_FXShutdown();
	MTL_FogShutdown();
	MTL_VolFogShutdown();
	MTL_CSMShutdown();
	MTL_TerrainFree();
	mtl_drawable = nil;
	mtl_cb = nil;
	mtl_enc = nil;
	mtl_encoder_open = false;

	ri.Cmd_RemoveCommand("screenshot");

	if (mtl_view)
	{
		SDL_Metal_DestroyView(mtl_view);
		mtl_view = NULL;
	}

	mtl_layer = nil;
	mtl_pipe2d = nil;
	mtl_pipe_sof2d = nil;
	mtl_pipe_sof2d_replace = nil;
	mtl_samp_ui_linear = nil;
	mtl_samp_ui = nil;
	for (int u = 0; u < 2; u++)
		for (int v = 0; v < 2; v++)
			for (int n = 0; n < 2; n++)
				mtl_ghoul_samplers[u][v][n] = nil;
	mtl_pipe_world = nil;
	mtl_pipe_sky = nil;
	mtl_pipe_detail = nil;
	mtl_pipe_detail_replace = nil;
	mtl_pipe_alias = nil;
	mtl_pipe_ghoul = nil;
	mtl_pipe_fx_alpha = mtl_pipe_fx_additive = mtl_pipe_fx_darken = nil;
	mtl_pipe_particles = nil;
	mtl_pipe_turb_opaque = nil;
	mtl_pipe_turb_alpha = nil;
	mtl_samp_clamp = nil;
	mtl_samp_repeat = nil;
	mtl_samp_world = nil;
	mtl_samp_lm = nil;
	mtl_lighttable = nil;
	mtl_white = nil;
	mtl_queue = nil;
	mtl_device = nil;
}

static void
MTL_GetDrawableSize(int *width, int *height)
{
	MTL_UpdateSizes();
	*width = mtl_width;
	*height = mtl_height;
}

static qboolean
MTL_IsVSyncActive(void)
{
	return mtl_vsync;
}

static void
MTL_BeginRegistration(const char *map)
{
	char name[MAX_QPATH];
	Com_sprintf(name, sizeof(name), "maps/%s.bsp", map);
	mtl_registration_sequence++;
	mtl_alpha_count = mtl_detail_count = 0;
	MTL_GhoulTexCacheFlush(); /* RLabs: Ghoul may free decoded images between levels */
	mtl_last_cluster = -1;
	MTL_ClearLightCache();
	MTL_DamageRestore(); /* a kept world starts this map load undamaged too */
	cvar_t *flushmap = ri.Cvar_Get("flushmap", "0", 0);
	if (mtl_worldmodel && (strcmp(mtl_worldmodel->name, name) || flushmap->value))
	{
		MTL_ModelFence();
		MTL_RemoveModel(mtl_worldmodel);
	}
	if (!mtl_worldmodel)
	{
		/* A retained map keeps the modes with which its lightmaps were built. */
		mtl_monolightmap_mode = MTL_LightmapMonoMode(mtl_monolightmap_cvar &&
			mtl_monolightmap_cvar->string ? mtl_monolightmap_cvar->string[0] : '0');
		mtl_worldmodel = (mtl_model_t *)MTL_RegisterModel(name);
	}
	if (!mtl_worldmodel) { Com_Error(ERR_DROP, "ref_metal: cannot register world %s", name); return; }
	mtl_worldmodel->registration_sequence = mtl_registration_sequence;
}

static int MTL_MD2DataValid(const void *data, size_t bytes);

static mtl_model_t *
MTL_LoadAliasModel(const char *name)
{
	byte *buf = NULL;
	int len = ri.FS_LoadFile(name, (void **)&buf);

	if (!buf || len < (int)sizeof(unsigned))
	{
		if (buf) ri.FS_FreeFile(buf);
		return NULL;
	}

	unsigned ident = LittleLong(*(unsigned *)buf);
	if (ident == IDALIASHEADER && !MTL_MD2DataValid(buf, (size_t)len))
	{
		ri.FS_FreeFile(buf);
		return NULL;
	}

	mtl_model_t *mod = calloc(1, sizeof(*mod));
	if (!mod) { ri.FS_FreeFile(buf); return NULL; }
	Q_strlcpy(mod->name, name, sizeof(mod->name));

	if (ident == IDALIASHEADER)
	{
		mod->aliashdr = Mod_LoadMD2(name, buf, len, mod->mins, mod->maxs,
		                            (struct image_s **)mod->skins, (findimage_t)MTL_FindImage,
		                            &mod->type);
		mod->numframes = mod->aliashdr ? ((dmdl_t *)mod->aliashdr)->num_frames : 0;
		mod->aliashdr_bytes = mod->aliashdr ? (size_t)((dmdl_t *)mod->aliashdr)->ofs_end : 0;
	}
	else if (ident == IDSPRITEHEADER)
	{
		mod->aliashdr = Mod_LoadSP2(name, buf, len,
		                            (struct image_s **)mod->skins, (findimage_t)MTL_FindImage,
		                            &mod->type);
		mod->numframes = mod->aliashdr ? ((dsprite_t *)mod->aliashdr)->numframes : 0;
		/* sprites have no stored bounds; a small box centred on the origin */
		VectorSet(mod->mins, -16, -16, -16);
		VectorSet(mod->maxs, 16, 16, 16);
	}

	/* The shared MD2/SP2 loaders begin their own hunk.  Close it before a
	   subsequent registration begins another one, as the reference renderer
	   does for every registered model. */
	Hunk_End();

	ri.FS_FreeFile(buf);

	if (!mod->aliashdr)
	{
		free(mod);
		return NULL;
	}

	mod->radius = Mod_RadiusFromBounds(mod->mins, mod->maxs);
	return mod;
}

static struct model_s *
MTL_RegisterModel(const char *name)
{
	if (!name || !name[0])
	{
		return NULL;
	}

	if (name[0] == '*')
	{
		int index = MTL_BrushInlineIndex(name, mtl_worldmodel ? mtl_worldmodel->numsubmodels : 0);
		if (index < 0) { Com_Error(ERR_DROP, "Bad inline model number"); return NULL; }
		mtl_worldmodel->registration_sequence = mtl_registration_sequence;
		mtl_worldmodel->submodels[index].registration_sequence = mtl_registration_sequence;
		return (struct model_s *)&mtl_worldmodel->submodels[index];
	}
	for (int i = 0; i < mtl_nummodels; i++)
	{
		if (strcmp(mtl_models[i]->name, name)) continue;
		mtl_models[i]->registration_sequence = mtl_registration_sequence;
		return (struct model_s *)mtl_models[i];
	}

	/* dispatch on the file magic: IBSP brush, IDP2 MD2, IDS2 SP2 */
	byte *head = NULL;
	int hlen = ri.FS_LoadFile(name, (void **)&head);

	if (!head || hlen < 4)
	{
		if (head) ri.FS_FreeFile(head);
		return NULL;
	}

	unsigned ident = LittleLong(*(unsigned *)head);
	ri.FS_FreeFile(head);

	mtl_model_t *mod = NULL;

	if (ident == IDBSPHEADER)
	{
		mod = (mtl_model_t *)MTL_LoadBrushModel(name);
	}
	else if (ident == IDALIASHEADER || ident == IDSPRITEHEADER)
	{
		mod = MTL_LoadAliasModel(name);
	}

	if (!mod)
	{
		return NULL;
	}
	mod->owner = mod;
	mod->registration_sequence = mtl_registration_sequence;
	if (mod->type != mod_brush)
	{
		mod->hunk = mod->aliashdr;
		for (int i = 0; i < MAX_MD2SKINS; i++) MTL_TrackModelImage(mod, mod->skins[i]);
	}

	mtl_model_t **models = realloc(mtl_models, (size_t)(mtl_nummodels + 1) * sizeof(*mtl_models));
	if (!models) { MTL_FreeModel(mod); Com_Error(ERR_DROP, "ref_metal: model registry allocation failed"); return NULL; }
	mtl_models = models;
	mtl_models[mtl_nummodels++] = mod;
	if (!mtl_worldmodel && mod->type == mod_brush && mod->numsubmodels > 0)
		mtl_worldmodel = mod;

	return (struct model_s *)mod;
}

static struct image_s *
MTL_RegisterSkin(const char *name)
{
	return (struct image_s *)MTL_FindPic(name);
}

static void
MTL_SetSky(const char *name, float rotate, vec3_t axis)
{
	MTL_SoF_SetSky(name, rotate, axis);
}

static void
MTL_EndRegistration(void)
{
	/* Drop unused file models only; inline views share their marked world owner. */
	int fenced = 0;
	for (int i = mtl_nummodels - 1; i >= 0; i--)
	{
		mtl_model_t *mod = mtl_models[i];
		if (mod == mtl_worldmodel || mod->registration_sequence == mtl_registration_sequence) continue;
		if (!fenced) { MTL_ModelFence(); fenced = 1; }
		MTL_RemoveModel(mod);
	}
}

static void
MTL_UpdateHUDState(void)
{
	MTL_HUDSetScissorBroken(mtl_scissor_broken_cvar ? mtl_scissor_broken_cvar->value : 0);
	const char *mode = mtl_texturemode_cvar ? mtl_texturemode_cvar->string : "GL_LINEAR";
	if (!Q_stricmp(mode,"GL_LINEAR") || !Q_stricmp(mode,"GL_LINEAR_MIPMAP_NEAREST") ||
		!Q_stricmp(mode,"GL_LINEAR_MIPMAP_LINEAR")) MTL_HUDSetRawLinear(YES);
	else if (!Q_stricmp(mode,"GL_NEAREST") || !Q_stricmp(mode,"GL_NEAREST_MIPMAP_NEAREST") ||
		!Q_stricmp(mode,"GL_NEAREST_MIPMAP_LINEAR")) MTL_HUDSetRawLinear(NO);
}

static void
MTL_BeginFrame(float camera_separation)
{
#ifdef OM_RLABS_KIT
	if (mtl_perfhud_cvar && mtl_perfhud_cvar->modified && mtl_layer)
	{
		rlk_hud_set((__bridge void *)mtl_layer, mtl_perfhud_cvar->value != 0);
		mtl_perfhud_cvar->modified = false;
	}
#endif
	MTL_UpdateHUDState();
	mtl_menu_active=NO;
	(void)camera_separation;
	MTL_SoF_HUDResetState();

	dispatch_semaphore_wait(mtl_inflight, DISPATCH_TIME_FOREVER);
	MTL_FrameRingNext(); /* RLabs: this frame's vertex stream slice */

#ifdef OM_RLABS_KIT
	/* RLabs (play-test 2026-11-05: "add vrr if it will help"): variable refresh in full screen on ProMotion and
	   Adaptive-Sync screens - a frame that misses its interval shows a few ms later instead of a whole refresh
	   later, and a 144 Hz VRR screen shows 120 fps without the 120 Hz switch. Checked twice a second. */
	{
		static int vrr_frames;

		if (!mtl_vrr_cvar)
			mtl_vrr_cvar = ri.Cvar_Get("r_vrr", "1", CVAR_ARCHIVE);

		if (mtl_window && (vrr_frames++ % 60) == 0)
		{
			void *nswindow = SDL_GetPointerProperty(SDL_GetWindowProperties(mtl_window),
				SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
			const int fullscreen = (SDL_GetWindowFlags(mtl_window) & SDL_WINDOW_FULLSCREEN) != 0;
			char line[160];
			double slowest = 0;

			mtl_vrr = rlk_vrr_update(nswindow, fullscreen, mtl_vrr_cvar->value != 0 && mtl_vsync, line, sizeof line);
			if (!rlk_vrr_screen_range(nswindow, &slowest, &mtl_vrr_fastest))
				mtl_vrr_fastest = 0;
			if (line[0])
				Com_Printf("%s\n", line);
			ri.Cvar_Set("vid_vrr_active", mtl_vrr ? "1" : "0");
		}
	}
#endif

	/* RLabs 2026-11-05: follow the window's pixel size every frame, not only in world frames. Starting in the
	   Mac's full screen (vid_fullscreen 2, now the default) resizes the window after init while only the menu
	   draws; the drawable then no longer matched the depth target and BeginFrame failed fatally (run 0061) */
	MTL_UpdateSizes();

	mtl_drawable = [mtl_layer nextDrawable];
	if (!mtl_drawable)
	{
		dispatch_semaphore_signal(mtl_inflight);
		return;
	}

	if (mtl_depth && (mtl_drawable.texture.width != mtl_depth.width ||
	                  mtl_drawable.texture.height != mtl_depth.height))
	{
		/* a drawable from before the resize: skip this frame, the next one has the new size */
		mtl_drawable = nil;
		dispatch_semaphore_signal(mtl_inflight);
		return;
	}

	mtl_cb = [mtl_queue commandBuffer];

	mtl_frame_targets_t targets = {};
	targets.color[0] = mtl_drawable.texture;
	targets.color_count = targets.samples = 1;
	targets.depth = mtl_depth;
	targets.viewport = (MTLViewport){0, 0, (double)mtl_width, (double)mtl_height, 0, 1};
	targets.scissor = (MTLScissorRect){0, 0, (NSUInteger)mtl_width, (NSUInteger)mtl_height};
	targets.clear_color[0] = MTLClearColorMake(0, 0, 0, 1);
	targets.clear_depth = 1;
	if (!MTL_TargetOpen(&targets, MTLLoadActionClear, MTLLoadActionClear))
		MTL_Fatal("BeginFrame", "could not open drawable render target");
	MTL_HUDApplyClip(mtl_width, mtl_height);
}

/* ---- entity (alias model) drawing --------------------------------- */

/* Generic MD2/SP2 draw paths own validated, dynamically sized streams. */
#include "mtl_generic_models.h"


/* Native Ghoul sink: the GPL model system has already emitted posed triangles
 * and material values.  Convert only the explicit native vertex ABI to this
 * renderer's direct Metal alias ABI; no GL entry point or GL state is replayed. */
/* SPEC-002 carries a game clock separately from client time. The native
 * frame owns these pointers only during its synchronous RenderFrame call. */
static const sofrefdef_t *mtl_sof_frame;

static float
MTL_GameTime(void)
{
	return mtl_sof_frame ? mtl_sof_frame->gametime : mtl_refdef.time;
}

#include "mtl_terrain.h"

/* Material selectors are kept together so the offscreen GPU checks exercise
 * the same state choices as a native model draw. */
static const float *
MTL_GhoulProjection(void)
{
	return mtl_menu_active ? mtl_menu_mvp : mtl_ghoul_mvp;
}

static id<MTLRenderPipelineState>
MTL_GhoulPipeline(const om_ghoul_native_draw_t *draw)
{
	return MTL_BuildAliasPipeline(draw->blend,2);
}

static id<MTLSamplerState>
MTL_GhoulSampler(const om_ghoul_native_texture_t *texture)
{
	return mtl_ghoul_samplers[texture && texture->repeat_u]
		[texture && texture->repeat_v][texture && texture->nomip];
}

static float
MTL_GhoulAlphaCutoff(const om_ghoul_native_draw_t *draw)
{
	/* SPEC-012 Ghoul uses output alpha >0 for blended base materials and
	 * no alpha test for opaque/specular passes. Generic aliases retain .05. */
	return draw->alpha_test ? 0.0f : -1.0f;
}

static float mtl_ghoul_entity_emission;
static mtl_linear_fog_t mtl_ghoul_fog; /* SPEC-411 step 10: the current Ghoul entity's fog, zero when none */
static void
MTL_GhoulDraw(void *ctx, const om_ghoul_native_draw_t *draw)
{
	static int debug_lines;
	static qboolean debug_matrix_logged;
	(void)ctx;
	if (!draw || !draw->vertices || draw->vertex_count == 0 || !mtl_encoder_open || !mtl_pipe_alias)
		return;

#ifdef OM_METAL_CSM_SHADER_H
	/* GFX-modern sun shadows: opaque depth-writing triangles are casters, kept for the next frame */
	if (mtl_csm.capture && draw->depth_write && draw->blend == OM_GHOUL_NATIVE_BLEND_OPAQUE && !draw->alpha_test)
		MTL_CSMCaptureDraw(draw);
#endif

	mtl_alias_vertex_t *vertices = calloc(draw->vertex_count, sizeof(*vertices));
	if (!vertices)
		return;
	float first_pos[3] = {draw->vertices[0].position[0], draw->vertices[0].position[1], draw->vertices[0].position[2]};
	for (size_t i = 0; i < draw->vertex_count; i++)
	{
		memcpy(vertices[i].pos, draw->vertices[i].position, sizeof(vertices[i].pos));
		memcpy(vertices[i].uv, draw->vertices[i].uv, sizeof(vertices[i].uv));
		memcpy(vertices[i].color, draw->vertices[i].colour, sizeof(vertices[i].color));
	}
	if (mtl_ghoul_debug_cvar && mtl_ghoul_debug_cvar->value != 0.0f && debug_lines++ < 32)
	{
		float lo[3] = {vertices[0].pos[0], vertices[0].pos[1], vertices[0].pos[2]};
		float hi[3] = {lo[0], lo[1], lo[2]};
		float uvlo[2] = {vertices[0].uv[0], vertices[0].uv[1]};
		float uvhi[2] = {uvlo[0], uvlo[1]};
		for (size_t i = 1; i < draw->vertex_count; i++)
			for (int k = 0; k < 3; k++)
			{
				if (vertices[i].pos[k] < lo[k]) lo[k] = vertices[i].pos[k];
				if (vertices[i].pos[k] > hi[k]) hi[k] = vertices[i].pos[k];
			}
		for (size_t i = 1; i < draw->vertex_count; i++)
			for (int k = 0; k < 2; k++)
			{
				if (vertices[i].uv[k] < uvlo[k]) uvlo[k] = vertices[i].uv[k];
				if (vertices[i].uv[k] > uvhi[k]) uvhi[k] = vertices[i].uv[k];
			}
		Com_Printf("ref_metal: ghoul batch verts %zu first %.2f %.2f %.2f range %.2f %.2f %.2f..%.2f %.2f %.2f uv %.3f %.3f..%.3f %.3f colour %.2f %.2f %.2f %.2f texture %s declared %d list %d decoded %d %dx%d rgba %u %u %u %u world %.2f %.2f %.2f blend %d cull %d native_lights %d ambient %.2f %.2f %.2f hardware %d attenuation %d first_light %.2f %.2f %.2f\\n",
		           draw->vertex_count, vertices[0].pos[0], vertices[0].pos[1], vertices[0].pos[2],
		           lo[0], lo[1], lo[2], hi[0], hi[1], hi[2],
		           uvlo[0], uvlo[1], uvhi[0], uvhi[1],
		           vertices[0].color[0], vertices[0].color[1], vertices[0].color[2], vertices[0].color[3],
		           draw->texture && draw->texture->key ? draw->texture->key : "<none>",
		           draw->texture_declared, draw->texture_list_resolved, draw->texture_decoded,
		           draw->texture ? draw->texture->width : 0, draw->texture ? draw->texture->height : 0,
		           draw->texture && draw->texture->rgba ? draw->texture->rgba[0] : 0,
		           draw->texture && draw->texture->rgba ? draw->texture->rgba[1] : 0,
		           draw->texture && draw->texture->rgba ? draw->texture->rgba[2] : 0,
		           draw->texture && draw->texture->rgba ? draw->texture->rgba[3] : 0,
		           draw->model_to_world[12], draw->model_to_world[13], draw->model_to_world[14],
		           draw->blend, draw->cull, draw->native_light_count,
		           draw->native_ambient[0], draw->native_ambient[1], draw->native_ambient[2],
		           draw->native_hardware_lights, draw->native_gl_attenuation,
		           draw->native_first_light[0], draw->native_first_light[1], draw->native_first_light[2]);
	}
	if (mtl_ghoul_debug_cvar && mtl_ghoul_debug_cvar->value != 0.0f &&
		draw->blend != OM_GHOUL_NATIVE_BLEND_OPAQUE)
	{
		Com_Printf("ref_metal: ghoul blended batch mode %d depth_write %d alpha_test %d verts %zu\\n",
			draw->blend, draw->depth_write, draw->alpha_test, draw->vertex_count);
	}
	NSUInteger vb_offset = 0;
	id<MTLBuffer> vb = MTL_FrameUpload(vertices, (NSUInteger)draw->vertex_count * MTL_ALIAS_STRIDE, &vb_offset);
	free(vertices);
	if (!vb)
		return;

	float model[16], emvp[16];
	/* Ghoul's row-vector matrix storage is the physical transpose that a
	 * column-vector Metal float4x4 needs.  Copy it verbatim: transposing again
	 * puts translation in the projective row and makes clip w grow with it. */
	memcpy(model, draw->model_to_world, sizeof(model));
	/* Reuse the exact projection x view matrix that has already rendered the
	 * current world frame.  The native callback is synchronous with this
	 * entity, so only the native model matrix participates here. */
	if (mtl_ghoul_debug_cvar && mtl_ghoul_debug_cvar->value != 0.0f && !debug_matrix_logged)
	{
		debug_matrix_logged = true;
		Com_Printf("ref_metal: ghoul saved mvp [%.6g %.6g %.6g %.6g] [%.6g %.6g %.6g %.6g] [%.6g %.6g %.6g %.6g] [%.6g %.6g %.6g %.6g]\\n",
		           mtl_ghoul_mvp[0], mtl_ghoul_mvp[1], mtl_ghoul_mvp[2], mtl_ghoul_mvp[3],
		           mtl_ghoul_mvp[4], mtl_ghoul_mvp[5], mtl_ghoul_mvp[6], mtl_ghoul_mvp[7],
		           mtl_ghoul_mvp[8], mtl_ghoul_mvp[9], mtl_ghoul_mvp[10], mtl_ghoul_mvp[11],
		           mtl_ghoul_mvp[12], mtl_ghoul_mvp[13], mtl_ghoul_mvp[14], mtl_ghoul_mvp[15]);
		Com_Printf("ref_metal: ghoul converted model [%.6g %.6g %.6g %.6g] [%.6g %.6g %.6g %.6g] [%.6g %.6g %.6g %.6g] [%.6g %.6g %.6g %.6g]\\n",
		           model[0], model[1], model[2], model[3], model[4], model[5], model[6], model[7],
		           model[8], model[9], model[10], model[11], model[12], model[13], model[14], model[15]);
	}
	MTL_Mul4(MTL_GhoulProjection(), model, emvp);
	if (mtl_ghoul_debug_cvar && mtl_ghoul_debug_cvar->value != 0.0f && debug_lines <= 32)
	{
		/* `vertices` has been copied into the Metal buffer and released above. */
		float x = first_pos[0], y = first_pos[1], z = first_pos[2];
		float cx = emvp[0] * x + emvp[4] * y + emvp[8] * z + emvp[12];
		float cy = emvp[1] * x + emvp[5] * y + emvp[9] * z + emvp[13];
		float cz = emvp[2] * x + emvp[6] * y + emvp[10] * z + emvp[14];
		float cw = emvp[3] * x + emvp[7] * y + emvp[11] * z + emvp[15];
		Com_Printf("ref_metal: ghoul first clip %.3f %.3f %.3f %.3f ndc %.3f %.3f %.3f\\n",
		           cx, cy, cz, cw, cw != 0.0f ? cx / cw : 0.0f,
		           cw != 0.0f ? cy / cw : 0.0f, cw != 0.0f ? cz / cw : 0.0f);
	}

	id<MTLTexture> texture = mtl_white;
	if (draw->texture && draw->texture->rgba && draw->texture->width > 0 && draw->texture->height > 0)
	{
		int detail = (int)floorf((mtl_ghoul_mip_cvar ? mtl_ghoul_mip_cvar->value : 0.0f) + 0.5f);
		void *cached = MTL_GhoulCachedTexture(draw->texture->rgba, draw->texture->key, draw->texture->width,
		                                      draw->texture->height, draw->texture->nomip, detail);
		if (cached)
			texture = (__bridge id<MTLTexture>)cached;
	}
	id<MTLRenderPipelineState> pipeline = MTL_GhoulPipeline(draw);
	[mtl_enc setRenderPipelineState:pipeline];
	[mtl_enc setDepthStencilState:draw->depth_write ? mtl_depth_world : mtl_depth_readonly];
	[mtl_enc setDepthBias:draw->depth_bias slopeScale:draw->depth_slope clamp:0];
	[mtl_enc setCullMode:draw->cull == OM_GHOUL_NATIVE_CULL_NONE ? MTLCullModeNone
		: (draw->cull == OM_GHOUL_NATIVE_CULL_FRONT ? MTLCullModeFront : MTLCullModeBack)];
	/* Ghoul emits CCW model fronts, unlike the BSP world triangles. */
	[mtl_enc setFrontFacingWinding:MTLWindingCounterClockwise];
	[mtl_enc setVertexBuffer:vb offset:vb_offset atIndex:0];
	[mtl_enc setVertexBytes:&emvp length:sizeof(emvp) atIndex:1];
	[mtl_enc setFragmentTexture:texture atIndex:0];
	float cutoff = MTL_GhoulAlphaCutoff(draw);
	[mtl_enc setFragmentBytes:&cutoff length:sizeof(cutoff) atIndex:2];
	mtl_post_emission_controls_t emission_controls=MTL_PostEmissionControls();
	MTL_PostBindEmission(MTL_PostGhoulEmission(draw->blend,draw->bloom_source,draw->specular_pass,
		mtl_ghoul_entity_emission,&emission_controls),3);
	[mtl_enc setFragmentSamplerState:MTL_GhoulSampler(draw->texture) atIndex:0];
	MTL_FXSoftOff();
	if (draw->blend == OM_GHOUL_NATIVE_BLEND_ADDITIVE || mtl_ghoul_fog.params[2] == 0.0f)
	{
		/* additive batches already carry the fog as a colour scale (fog_visibility, ghoul_draw.cpp) */
		MTL_FogBindNone();
	}
	else
	{
		/* the fog plane in model space: the vertex function has model positions */
		const float *p = mtl_ghoul_fog.plane;
		const float model_plane[4] = {
			p[0] * model[0] + p[1] * model[1] + p[2] * model[2],
			p[0] * model[4] + p[1] * model[5] + p[2] * model[6],
			p[0] * model[8] + p[1] * model[9] + p[2] * model[10],
			p[0] * model[12] + p[1] * model[13] + p[2] * model[14] + p[3]};
		MTL_FogBindLinear(&mtl_ghoul_fog, model_plane);
	}
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)draw->vertex_count];
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
}

/* ---- ground shadows of Ghoul models (SPEC-411 section 7): the library computes mask and quad, drawn here ---- */
static cvar_t *mtl_ghl_shadows_cvar, *mtl_ghl_player_shadow_cvar, *mtl_ghl_shadow_darkness_cvar, *mtl_ghl_shadow_dist_cvar;
static float mtl_ghoul_tracefrac;

/* a point trace through the world BSP, as GL's WorldTrace: fraction 0..1, -1 when the start is inside a solid */
static int MTL_GhoulTraceNode(mnode_t *node, float f1, float f2, const vec3_t p1, const vec3_t p2)
{
	if (node->contents != CONTENTS_NODE)
	{
		if (((mleaf_t *)node)->contents & (CONTENTS_SOLID | CONTENTS_WINDOW))
		{
			mtl_ghoul_tracefrac = f1;
			return 1;
		}
		return 0;
	}
	float t1 = DotProduct(node->plane->normal, p1) - node->plane->dist;
	float t2 = DotProduct(node->plane->normal, p2) - node->plane->dist;
	if (t1 >= 0 && t2 >= 0)
		return MTL_GhoulTraceNode(node->children[0], f1, f2, p1, p2);
	if (t1 < 0 && t2 < 0)
		return MTL_GhoulTraceNode(node->children[1], f1, f2, p1, p2);
	float frac = t1 / (t1 - t2), fm = f1 + (f2 - f1) * frac;
	vec3_t mid;
	for (int i = 0; i < 3; i++)
		mid[i] = p1[i] + (p2[i] - p1[i]) * frac;
	int side = t1 < 0;
	if (MTL_GhoulTraceNode(node->children[side], f1, fm, p1, mid))
		return 1;
	return MTL_GhoulTraceNode(node->children[side ^ 1], fm, f2, mid, p2);
}
static float MTL_GhoulWorldTrace(const float *start, const float *end)
{
	if (!mtl_worldmodel || !mtl_worldmodel->nodes)
		return 1.0f;
	const mleaf_t *leaf = Mod_PointInLeaf(start, mtl_worldmodel->nodes);
	if (leaf && (leaf->contents & (CONTENTS_SOLID | CONTENTS_WINDOW)))
		return -1.0f;
	mtl_ghoul_tracefrac = 1.0f;
	return MTL_GhoulTraceNode(mtl_worldmodel->nodes, 0, 1, start, end) ? mtl_ghoul_tracefrac : 1.0f;
}

static NSString *const mtl_gshadow_msl = @R"MSL(
struct OMGShadowVertex { packed_float3 pos; packed_float2 st; };
#ifndef OM_CSM
#define OM_CSM 0
#endif
struct OMGShadowVarying { float4 position [[position]]; float2 st;
#if OM_CSM
 float3 world;
#endif
};
vertex OMGShadowVarying mtl_vs_gshadow(const device OMGShadowVertex *v [[buffer(0)]], uint id [[vertex_id]],
                                       constant float4x4 &mvp [[buffer(1)]]) {
 OMGShadowVarying o; o.position = mvp * float4(float3(v[id].pos), 1); o.st = float2(v[id].st);
#if OM_CSM
 o.world = float3(v[id].pos); /* the quad is in world space (ghoul_draw) */
#endif
 return o;
}
inline float OMGShadowTexel(const device uchar *mask, int x, int y) {
 return float(mask[clamp(y, 0, 63) * 64 + clamp(x, 0, 63)]) / 255.0f;
}
fragment OMPostOutput mtl_fs_gshadow(OMGShadowVarying in [[stage_in]], const device uchar *mask [[buffer(1)]], constant float &dark [[buffer(2)]]
#if OM_CSM
 , constant OMCsmUniforms &csm [[buffer(7)]], depth2d_array<float> csmmap [[texture(8)]]
#endif
 ) {
 float2 p = in.st * 64.0f - 0.5f, b = floor(p), f = p - b;
 int x = int(b.x), y = int(b.y);
 float a = mix(mix(OMGShadowTexel(mask, x, y), OMGShadowTexel(mask, x + 1, y), f.x),
               mix(OMGShadowTexel(mask, x, y + 1), OMGShadowTexel(mask, x + 1, y + 1), f.x), f.y) * dark;
#if OM_CSM
 /* GFX-modern: this shadow gives way to the sun shadow of the model where the ground is in the sun (gl3_ghoulemu.c) */
 a *= omCsmGhoulShadowKeep(in.world, csm, csmmap);
#endif
 if (a <= 0.0f) discard_fragment();
 return OM_PostDefault(float4(1, 1, 1, a));
}
)MSL";

static id<MTLRenderPipelineState> MTL_GhoulShadowPipeline(int csm)
{
	mtl_pipeline_targets_t targets = MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> pipeline = MTL_PostPipelineCached(MTL_POST_PIPE_GSHADOW, 0, csm, &targets);
	if (pipeline)
		return pipeline;
	NSError *error = nil;
	NSString *shadow_source = csm ? [NSString stringWithFormat:@"#define OM_CSM 1\n%@\n%@", mtl_csm_msl, mtl_gshadow_msl] : mtl_gshadow_msl;
	id<MTLLibrary> library = [mtl_device newLibraryWithSource:MTL_PostShaderSource(shadow_source, &targets) options:nil error:&error];
	if (!library) { NSLog(@"Metal shadow shader: %@", error); MTL_Fatal("shadow shader", NULL); }
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [library newFunctionWithName:@"mtl_vs_gshadow"];
	d.fragmentFunction = [library newFunctionWithName:@"mtl_fs_gshadow"];
	d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	d.colorAttachments[0].blendingEnabled = YES;
	d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorZero;
	d.colorAttachments[0].destinationRGBBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	if (!MTL_PostConfigurePipeline(d, &targets))
		MTL_Fatal("shadow targets", NULL);
	pipeline = [mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
	if (!pipeline) { NSLog(@"Metal shadow pipeline: %@", error); MTL_Fatal("shadow pipeline", NULL); }
	MTL_PostPipelineStore(MTL_POST_PIPE_GSHADOW, 0, csm, &targets, pipeline);
	return pipeline;
}

static void MTL_GhoulShadow(void *ctx, const om_ghoul_native_shadow_t *s)
{
	(void)ctx;
	if (!mtl_encoder_open || !s || !s->mask)
		return;
	NSUInteger offset = 0;
	id<MTLBuffer> mask = MTL_FrameUpload(s->mask, 64 * 64, &offset);
	if (!mask)
		return;
	static const int order[6] = {0, 1, 2, 0, 2, 3};
	float v[6][5];
	for (int i = 0; i < 6; i++)
	{
		int k = order[i];
		v[i][0] = s->pos[k][0]; v[i][1] = s->pos[k][1]; v[i][2] = s->pos[k][2];
		v[i][3] = s->st[k][0]; v[i][4] = s->st[k][1];
	}
	const int csm_replace = mtl_csm.active && mtl_csm.replace; /* gl3_ghoulemu.c: only the blend (0, 1 - src alpha) ground shadow */
	[mtl_enc setRenderPipelineState:MTL_GhoulShadowPipeline(csm_replace)];
	if (csm_replace)
		MTL_CSMBindReceiver();
	[mtl_enc setDepthStencilState:mtl_depth_readonly];
	[mtl_enc setCullMode:MTLCullModeNone];
	[mtl_enc setDepthBias:-3.0f slopeScale:-3.0f clamp:0];
	[mtl_enc setVertexBytes:v length:sizeof(v) atIndex:0];
	[mtl_enc setVertexBytes:mtl_ghoul_mvp length:sizeof(mtl_ghoul_mvp) atIndex:1];
	[mtl_enc setFragmentBuffer:mask offset:offset atIndex:1];
	[mtl_enc setFragmentBytes:&s->alpha length:sizeof(float) atIndex:2];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
}

static void
MTL_DrawGhoulEntity(entity_t *e, const float mvp[16])
{
	if (!mtl_ghl_shadows_cvar)
	{
		mtl_ghl_shadows_cvar = ri.Cvar_Get("ghl_shadows", "2", CVAR_ARCHIVE);
		mtl_ghl_player_shadow_cvar = ri.Cvar_Get("ghl_player_shadow", "1", CVAR_ARCHIVE);
		mtl_ghl_shadow_darkness_cvar = ri.Cvar_Get("ghl_shadow_darkness", ".75", CVAR_ARCHIVE);
		mtl_ghl_shadow_dist_cvar = ri.Cvar_Get("ghl_shadow_dist", "25", CVAR_ARCHIVE);
	}
	if (!mtl_ghoul_system || !e)
		return;
	/* Ghoul uses signed 16-bit instance handles; local client instances are
	 * negative, even though the renderer entity stores the field as an int. */
	void *instance = OMGhoul_FindInstance(mtl_ghoul_system, (short)(e->frame & 0xffff));
	if (!instance)
		return;
	/* GL3's Ghoul path deliberately uses the ordinary projection even for a
	 * weapon model; only RF_DEPTHHACK changes its depth range. */
	if (e->flags & RF_DEPTHHACK)
	{
		MTL_ApplyDepthHack(mvp, mtl_ghoul_mvp);
	}
	else
	{
		memcpy(mtl_ghoul_mvp, mvp, sizeof(mtl_ghoul_mvp));
	}
	if (mtl_ghoul_debug_cvar && mtl_ghoul_debug_cvar->value != 0.0f)
	{
		Com_Printf("ref_metal: ghoul entity handle %d flags %08x origin %.2f %.2f %.2f angles %.2f %.2f %.2f view %.2f %.2f %.2f\\n",
		           e->frame, e->flags, e->origin[0], e->origin[1], e->origin[2],
		           e->angles[0], e->angles[1], e->angles[2],
		           mtl_refdef.vieworg[0], mtl_refdef.vieworg[1], mtl_refdef.vieworg[2]);
	}
	om_ghoul_render_params_t params = {};
	vec3_t light;
	const float light_method = mtl_ghoul_light_method_cvar ? mtl_ghoul_light_method_cvar->value : 3.0f;
	float light_multiply = mtl_ghoul_light_multiply_cvar ? mtl_ghoul_light_multiply_cvar->value : 1.3f;
	params.time = MTL_GameTime();
	if ((e->flags & RF_FULLBRIGHT) ||
	    (mtl_fullbright_cvar && mtl_fullbright_cvar->value != 0.0f) ||
	    (mtl_refdef.rdflags & RDF_IRGOGGLES))
	{
		VectorSet(light, 1.0f, 1.0f, 1.0f);
	}
	else
	{
		MTL_SoFLightPoint(e->origin, light);
	}
	/* GL3 clamps this compatibility control before applying the min-light
	 * rule.  Preserve that order so a dim view weapon reaches the same floor. */
	if (light_multiply < 0.25f)
		light_multiply = 0.25f;
	if (light_multiply > 2.0f)
		light_multiply = 2.0f;
	VectorScale(light, light_multiply, light);
	if ((e->flags & RF_MINLIGHT) &&
	    light[0] <= 0.1f && light[1] <= 0.1f && light[2] <= 0.1f)
	{
		VectorSet(light, 0.1f, 0.1f, 0.1f);
	}
	if (e->flags & RF_GLOW)
	{
		float scale = 0.1f * sinf(mtl_refdef.time * 7.0f);
		for (int i = 0; i < 3; i++)
		{
			float minimum = light[i] * 0.8f;
			light[i] += scale;
			if (light[i] < minimum)
				light[i] = minimum;
		}
	}
	VectorCopy(light, params.light_color);
	/* SPEC-002/411: report the compatibility lighting before the optional
	 * drawing-only overbright, exactly as current GPL GL3_Ghoul_DrawEntity. */
	if (mtl_sof_frame && mtl_sof_frame->entities && mtl_refdef.entities)
	{
		for (int i = 0; i < mtl_refdef.num_entities &&
		     i < mtl_sof_frame->num_entities && i < SOF_MAX_ENTITIES; i++)
		{
			if (e != &mtl_refdef.entities[i]) continue;
			sofentity_t *se = mtl_sof_frame->entities[i];
			if (se && se->lightout) VectorCopy(light, se->lightout);
			break;
		}
	}
	if (!(e->flags & RF_FULLBRIGHT) &&
	    !(mtl_fullbright_cvar && mtl_fullbright_cvar->value != 0.0f) &&
	    !(mtl_refdef.rdflags & RDF_IRGOGGLES))
	{
		VectorScale(params.light_color, MTL_OverbrightModels(), params.light_color);
	}
	params.specular = (mtl_ghoul_specular_cvar && mtl_ghoul_specular_cvar->value > 0.5f && light_method > 0.5f);
	params.use_gl_lights = !(e->flags & SOF_RF_AMBIENTONLY) && light_method >= 2.0f;
	params.fast_lights = (mtl_ghoul_fast_lights_cvar && mtl_ghoul_fast_lights_cvar->value > 0.5f && light_method < 3.0f);
	params.hardware_lights = params.use_gl_lights && light_method > 2.5f;
	params.gl_directional = mtl_ghoul_gllight_directional_cvar && mtl_ghoul_gllight_directional_cvar->value > 0.5f;
	params.gl_attenuation = !params.gl_directional && mtl_ghoul_gllight_attenuation_cvar &&
		mtl_ghoul_gllight_attenuation_cvar->value > 0.5f;
	params.max_lights = params.hardware_lights
		? (mtl_ghoul_gllight_max_lights_cvar ? (int)floorf(mtl_ghoul_gllight_max_lights_cvar->value + 0.5f) : 6)
		: (mtl_ghoul_max_lights_cvar ? (int)floorf(mtl_ghoul_max_lights_cvar->value + 0.5f) : 3);
	if (params.max_lights < 1)
		params.max_lights = 1;
	else if (params.max_lights > 8)
		params.max_lights = 8;
	if (mtl_ghoul_debug_cvar && mtl_ghoul_debug_cvar->value != 0.0f)
	{
		Com_Printf("ref_metal: ghoul static light %.3f %.3f %.3f\\n",
		           light[0], light[1], light[2]);
	}
	params.fog_visibility = 1.0f;
	params.shadow_darkness = mtl_ghl_shadow_darkness_cvar->value;
	params.shadow_dist = mtl_ghl_shadow_dist_cvar->value;
	/* SPEC-411 steps 5-6 as in GL: ground shadows, and the player's own model is drawn shadow-only or not at all */
	{
		int mode = (int)floorf(mtl_ghl_shadows_cvar->value + 0.5f);
		if (mode < 0 || (e->flags & RF_FULLBRIGHT) || mtl_fullbright_cvar->value != 0.0f ||
		    (mtl_refdef.rdflags & RDF_IRGOGGLES) || params.shadow_darkness <= 0.0f)
			mode = 0;
		if (mode > 2)
			mode = 2;
		params.shadow_mode = mode;
		if (mode)
			params.world_trace = MTL_GhoulWorldTrace;
		if (e->flags & SOF_RF_VIEWERMODEL)
		{
			if (!mode || mtl_ghl_player_shadow_cvar->value < 0.5f)
				return;
			params.shadow_only = 1;
		}
	}
	/* SPEC-411 step 10: the fog of the region at the model's origin, for every model but the view weapon */
	memset(&mtl_ghoul_fog, 0, sizeof(mtl_ghoul_fog));
	if (mtl_fogdraw.world && !(e->flags & SOF_RF_WEAPONMODEL))
	{
		const int region = MTL_FogRegionOfPoint(e->origin);
		if (region >= 0)
		{
			const float objectfog = mtl_ghl_obj_fog_cvar ? mtl_ghl_obj_fog_cvar->value : 1.0f;
			MTL_FogDrawModelUniforms(&mtl_fogdraw, region, e->origin, 0, objectfog, &mtl_ghoul_fog);
			if (objectfog > 0.5f && mtl_fogdraw.world->mode != 3)
			{
				float colour[4], factor = MTL_FogPointFactor(mtl_fogdraw.world, region, e->origin, colour);
				if (factor > 0.01f)
				{
					params.fog_visibility = 1.0f - factor;
					params.shadow_darkness *= 1.0f - factor;
				}
			}
		}
	}
	/* SPEC-011 row-vector entity matrix: exactly the Ghoul orientation used
	 * by the GL3 reference, not the column-major Metal model matrix. */
	{
		float sp = sinf(DEG2RAD(-e->angles[0])), cp = cosf(DEG2RAD(-e->angles[0]));
		float sy = sinf(DEG2RAD(e->angles[1])), cy = cosf(DEG2RAD(e->angles[1]));
		float sr = sinf(DEG2RAD(-e->angles[2])), cr = cosf(DEG2RAD(-e->angles[2]));
		vec3_t forward = {cp * cy, cp * sy, -sp};
		vec3_t right = {-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp};
		vec3_t up = {cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp};
		for (int i = 0; i < 3; i++)
		{
			params.entity_to_world[i] = forward[i];
			params.entity_to_world[4 + i] = -right[i];
			params.entity_to_world[8 + i] = up[i];
			params.entity_to_world[12 + i] = e->origin[i];
		}
		params.entity_to_world[3] = params.entity_to_world[7] = params.entity_to_world[11] = 0.0f;
		params.entity_to_world[15] = 1.0f;
	}
	memcpy(params.origin, e->origin, sizeof(params.origin));
	memcpy(params.view_origin, mtl_refdef.vieworg, sizeof(params.view_origin));
	AngleVectors(mtl_refdef.viewangles, params.view_forward, NULL, NULL);
	mtl_post_emission_controls_t emission_controls=MTL_PostEmissionControls();
	mtl_ghoul_entity_emission=MTL_PostEntityGlow((e->flags&(RF_FULLBRIGHT|RF_GLOW))!=0,
		(e->flags&RF_WEAPONMODEL)!=0,&emission_controls);
#ifdef OM_METAL_CSM_SHADER_H
	/* GFX-modern sun shadows: every Ghoul model but the view weapon and the player's own casts; its ground shadow gives
	   way to the sun shadow in the sun (SPEC-AMEND-016 R16.4). The own model keeps its blob. (gl3_ghoul.c) */
	{
		const qboolean weapon = (e->flags & SOF_RF_WEAPONMODEL) != 0, viewer = (e->flags & SOF_RF_VIEWERMODEL) != 0;
		mtl_csm.capture = mtl_csm.active && !weapon && !viewer && !(e->flags & RF_DEPTHHACK);
		mtl_csm.replace = mtl_csm.active && mtl_csm_replace_ghl_cvar->value && !weapon && !viewer;
	}
#endif
	OMGhoul_DrawInstance(instance, &params);
#ifdef OM_METAL_CSM_SHADER_H
	mtl_csm.capture = mtl_csm.replace = NO;
#endif
	mtl_ghoul_entity_emission=0;
}

static void
MTL_DrawEntity(entity_t *e, const float mvp[16], const float view[16])
{
	if (e->flags & SOF_RF_GHOUL)
	{
		MTL_DrawGhoulEntity(e, mvp);
		return;
	}
	mtl_model_t *mod = (mtl_model_t *)e->model;
	if (!mod) return;
	if (mod->type == mod_alias)
	{
		MTL_DrawAliasModel(e, mvp, view);
	}
	else if (mod->type == mod_sprite)
	{
		MTL_DrawSpriteModel(e, mod, mvp);
	}
	else if (mod->type == mod_brush)
	{
		MTL_DrawBrushModel(e, mvp);
	}
}

#include "mtl_worldalpha.h"
#include "mtl_fx.h"

static void
MTL_DrawParticles(const float mvp[16], const vec3_t right, const vec3_t up, float fovy)
{
	if (mtl_particle_debug_cvar && mtl_particle_debug_cvar->value != 0.0f)
		Com_Printf("ref_metal: refdef particles %d\n", mtl_refdef.num_particles);
	if (!mtl_refdef.particles || mtl_refdef.num_particles <= 0 || !mtl_pipe_particles)
		return;

	/* GL3 uses sizePx = gl3_particle_size * height / 480 / (distance * 0.1).
	 * This world-space billboard side projects to the same pixel size. */
	float particle_size = mtl_particle_size_cvar ? mtl_particle_size_cvar->value : 40.0f;
	float world_size = 2.0f * tanf(DEG2RAD(fovy) * 0.5f) * (particle_size / 48.0f);
	if (world_size <= 0.0f)
		return;

	const int count = mtl_refdef.num_particles;
	mtl_alias_vertex_t *verts = calloc((size_t)count * 6, sizeof(*verts));
	if (!verts)
		return;
	const float corners[6][2] = {{0, 1}, {0, 0}, {1, 0}, {0, 1}, {1, 0}, {1, 1}};
	for (int i = 0; i < count; i++)
	{
		const particle_t *p = &mtl_refdef.particles[i];
		unsigned c = mtl_palette[p->color & 255];
		for (int j = 0; j < 6; j++)
		{
			mtl_alias_vertex_t *v = &verts[i * 6 + j];
			VectorCopy(p->origin, v->pos);
			v->uv[0] = corners[j][0];
			v->uv[1] = corners[j][1];
			v->color[0] = (float)(c & 255) / 255.0f;
			v->color[1] = (float)((c >> 8) & 255) / 255.0f;
			v->color[2] = (float)((c >> 16) & 255) / 255.0f;
			v->color[3] = p->alpha;
		}
	}

	NSUInteger vb_offset = 0;
	id<MTLBuffer> vb = MTL_FrameUpload(verts, (NSUInteger)count * 6 * MTL_ALIAS_STRIDE, &vb_offset);
	free(verts);
	if (!vb)
		return;
	typedef struct { float mvp[16]; float right[3]; float size; float up[3]; float pad; } particle_uniform_t;
	particle_uniform_t u = {};
	memcpy(u.mvp, mvp, sizeof(u.mvp));
	VectorCopy(right, u.right);
	VectorCopy(up, u.up);
	u.size = world_size;
	[mtl_enc setRenderPipelineState:MTL_BuildParticlePipeline()];
	[mtl_enc setDepthStencilState:mtl_depth_readonly];
	[mtl_enc setCullMode:MTLCullModeNone];
	[mtl_enc setVertexBuffer:vb offset:vb_offset atIndex:0];
	[mtl_enc setVertexBytes:&u length:sizeof(u) atIndex:1];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)count * 6];
}

/* Implements: SPEC-410 detail/environment second pass. Reuse the native
 * textured-vertex ABI, with its own no-alpha-test fragment function and
 * destination/source-colour blend pipeline. */
static void
MTL_UpdateDetailScroll(float game_delta)
{
	static unsigned update;
	if (++update == 0) ++update;
	for (int model_index = 0; model_index < mtl_nummodels; model_index++)
	{
		mtl_model_t *model = mtl_models[model_index];
		if (!model || (model->owner && model->owner != model)) continue;
		for (int image_index = 0; image_index < model->num_owned_images; image_index++)
		{
			mtl_image_t *image = model->owned_images[image_index];
			if (!image || image->detail_scroll_frame == update) continue;
			image->detail_scroll_frame = update;
			MTL_LightmapDetailScroll(image->detail_scroll, image->detail_shift, game_delta);
		}
	}
}

static void
MTL_DrawDetailPass(mtl_model_t *mod, const float mvp[16])
{
	int mode = mtl_detail_cvar ? (int)mtl_detail_cvar->value : 0;
	if (!mode || !mtl_detail_count)
		return;
	vec3_t forward, right, up;
	AngleVectors(mtl_refdef.viewangles, forward, right, up);
	const mtl_world_vertex_t *worldverts =
		(const mtl_world_vertex_t *)[(__bridge id<MTLBuffer>)mod->vbuf contents];
	[mtl_enc setRenderPipelineState:MTL_BuildAliasPipeline(mode>=3?OM_GHOUL_NATIVE_BLEND_OPAQUE:MTL_BLEND_DETAIL,1)];
	mtl_post_emission_controls_t emission_controls=MTL_PostEmissionControls();
	MTL_PostBindEmission(MTL_PostEmissionForBlend(mode>=3?0:5,0,&emission_controls),3);
	[mtl_enc setDepthStencilState:mtl_depth_readonly];
	[mtl_enc setDepthBias:mtl_offset_units_cvar->value
	          slopeScale:mtl_offset_factor_cvar->value clamp:0.0f];
	[mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];
	[mtl_enc setVertexBytes:mvp length:16 * sizeof(float) atIndex:1];
	for (int i = 0; i < mtl_detail_count; i++)
	{
		mtl_surface_t *surf = mtl_detail_surfaces[i];
		mtl_image_t *base = MTL_AnimatedWorldImage(surf->texinfo, (int)(MTL_GameTime() * 2));
		if (!base) continue;
		mtl_image_t *detail = base->detail;
		const mtl_world_vertex_t *src = worldverts + surf->first_vertex;
		if (!detail || !detail->tex)
			continue;
		if (mode == 2)
		{
			qboolean near = false;
			for (int j = 0; j < surf->num_vertex; j++)
			{
				vec3_t delta;
				VectorSubtract(src[j].pos, mtl_refdef.vieworg, delta);
				if (DotProduct(delta, forward) < mtl_detail_distance_cvar->value)
				{
					near = true;
					break;
				}
			}
			if (!near)
				continue;
		}
		float flow[2] = {0, 0}, scroll[2];
		if (surf->texinfo->flags & SURF_FLOWING)
		{
			flow[0] = (short)((surf->texinfo->value >> 16) & 0xffff) * MTL_GameTime() * 0.01f;
			flow[1] = (short)(surf->texinfo->value & 0xffff) * MTL_GameTime() * 0.01f;
		}
		for (int k = 0; k < 2; k++)
		{
			scroll[k] = base->detail_scroll[k];
		}
		qboolean env = (detail->kind & 0x8) != 0;
		vec3_t U = {surf->normal[1], -surf->normal[0], 0}, V;
		qboolean sphere = env && ((surf->texinfo->flags & 0x20000) || DotProduct(U, U) < 0.1f);
		if (env && !sphere)
		{
			VectorNormalize(U);
			CrossProduct(U, surf->normal, V);
			VectorNormalize(V);
		}
		mtl_alias_vertex_t *vertices = calloc((size_t)surf->num_vertex, sizeof(*vertices));
		if (!vertices)
			continue;
		for (int j = 0; j < surf->num_vertex; j++)
		{
			VectorCopy(src[j].pos, vertices[j].pos);
			for (int k = 0; k < 4; k++)
				vertices[j].color[k] = 1.0f;
			if (!env)
			{
				vertices[j].uv[0] = (src[j].uv[0] - flow[0]) * base->detail_scale[0] + scroll[0];
				vertices[j].uv[1] = (src[j].uv[1] - flow[1]) * base->detail_scale[1] + scroll[1];
			}
			else if (sphere)
			{
				vec3_t d, eye_dir, eye_normal, reflection;
				VectorSubtract(src[j].pos, mtl_refdef.vieworg, d);
				VectorSet(eye_dir, DotProduct(d, right), DotProduct(d, up), -DotProduct(d, forward));
				VectorNormalize(eye_dir);
				VectorSet(eye_normal, DotProduct(surf->normal, right), DotProduct(surf->normal, up),
				          -DotProduct(surf->normal, forward));
				VectorMA(eye_dir, -2.0f * DotProduct(eye_normal, eye_dir), eye_normal, reflection);
				float m = 2.0f * sqrtf(reflection[0] * reflection[0] + reflection[1] * reflection[1] +
				                         (reflection[2] + 1) * (reflection[2] + 1));
				if (m == 0)
					m = 1;
				vertices[j].uv[0] = reflection[0] / m + 0.5f;
				vertices[j].uv[1] = reflection[1] / m + 0.5f;
			}
			else
			{
				vec3_t d, reflection;
				VectorSubtract(mtl_refdef.vieworg, src[j].pos, d);
				VectorNormalize(d);
				VectorScale(surf->normal, 2.0f * DotProduct(surf->normal, d), reflection);
				VectorSubtract(reflection, d, reflection);
				vertices[j].uv[0] = (DotProduct(reflection, U) + 1) * 0.5f;
				vertices[j].uv[1] = (DotProduct(reflection, V) + 1) * 0.5f;
			}
		}
		NSUInteger vb_offset = 0;
		id<MTLBuffer> vb = MTL_FrameUpload(vertices, (NSUInteger)surf->num_vertex * sizeof(*vertices), &vb_offset);
		free(vertices);
		if (vb)
		{
			[mtl_enc setVertexBuffer:vb offset:vb_offset atIndex:0];
			[mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)detail->tex atIndex:0];
			[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)surf->num_vertex];
		}
	}
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
	mtl_detail_count = 0;
}

#include "mtl_brush.h"

static void
MTL_MarkWorldLights(void)
{
	mtl_model_t *model = mtl_worldmodel;
	for (int i = 0; i < model->numsurfaces; i++) model->surfaces[i].dlightbits = 0;
	if (!mtl_refdef.dlights || (mtl_gl_dynamic_cvar && !mtl_gl_dynamic_cvar->value)) return;
	mtl_brush_mark_owner = model;
	int count = Q_max(0, Q_min(mtl_refdef.num_dlights, MTL_MAX_DLIGHTS));
	for (int i = 0; i < count; i++)
		R_MarkLights(&mtl_refdef.dlights[i], (int)(1u << i), model->nodes + model->firstnode,
			mtl_framecount, MTL_BrushMarkSurfaceLights);
	mtl_brush_mark_owner = NULL;
}

static void
MTL_DrawWorld(void)
{
	if (!mtl_worldmodel || !mtl_worldmodel->vbuf || !mtl_worldmodel->nodes || !mtl_encoder_open ||
		(mtl_refdef.rdflags & RDF_NOWORLDMODEL))
	{
		if (mtl_world_debug_cvar && mtl_world_debug_cvar->value)
		{
			static int skiplines;
			if (skiplines++ < 5)
				Com_Printf("ref_metal: worlddebug skip world %p vbuf %p nodes %p encoder %d rdflags %d\n",
					(void *)mtl_worldmodel, mtl_worldmodel ? mtl_worldmodel->vbuf : NULL,
					mtl_worldmodel ? (void *)mtl_worldmodel->nodes : NULL, (int)mtl_encoder_open, mtl_refdef.rdflags);
		}
		return;
	}

	mtl_model_t *mod = mtl_worldmodel;

	float view[16], proj[16], mvp[16];
	MTL_ViewMatrix(mtl_refdef.vieworg, mtl_refdef.viewangles, view);

	float aspect = (float)mtl_ui_w / (float)mtl_ui_h;
	if (aspect <= 0.0f)
	{
		aspect = 16.0f / 9.0f;
	}
	MTL_ProjMatrix(mtl_refdef.fov_x, aspect, proj);
	MTL_Mul4(proj, view, mvp);
	int view_x = mtl_refdef.x, view_y = mtl_refdef.y;
	int view_width = mtl_refdef.width, view_height = mtl_refdef.height;
	if (view_x < 0 || view_y < 0 || view_width <= 0 || view_height <= 0 ||
		view_x > mtl_width || view_y > mtl_height ||
		view_width > mtl_width - view_x || view_height > mtl_height - view_y)
	{
		if (mtl_world_debug_cvar && mtl_world_debug_cvar->value)
			Com_Printf("ref_metal: worlddebug skip view %d %d %dx%d target %dx%d\n", view_x, view_y, view_width,
				view_height, mtl_width, mtl_height);
		return;
	}
	/* GFX-modern: the sun shadow maps of this view (r_om_csm), before its passes begin */
	MTL_CSMFrame(mtl_refdef.fov_x, RAD2DEG(2.0f * atanf(tanf(DEG2RAD(mtl_refdef.fov_x) * 0.5f) / aspect)));
	mtl_frame_targets_t window = mtl_current_targets;
	MTL_PostSetFogRegionCount(MTL_FogNumRegions());
	BOOL post = MTL_PostBeginView(view_x, view_y, view_width, view_height, proj, view);
	if (!post)
	{
		MTLViewport viewport = {(double)view_x, (double)view_y, (double)view_width,
			(double)view_height, window.viewport.znear, window.viewport.zfar};
		MTLScissorRect scissor = {(NSUInteger)view_x, (NSUInteger)view_y,
			(NSUInteger)view_width, (NSUInteger)view_height};
		[mtl_enc setViewport:viewport];
		[mtl_enc setScissorRect:scissor];
		MTL_TargetRecordViewport(viewport);
		MTL_TargetRecordScissor(scissor);
	}
	float fovy_degrees = RAD2DEG(2.0f * atanf(tanf(DEG2RAD(mtl_refdef.fov_x) * 0.5f) / aspect));
	vec3_t render_right, render_up;

	/* frustum for node culling (same vectors as the view matrix) */
	{
		float sp = sinf(DEG2RAD(mtl_refdef.viewangles[0])), cp = cosf(DEG2RAD(mtl_refdef.viewangles[0]));
		float sy = sinf(DEG2RAD(mtl_refdef.viewangles[1])), cy = cosf(DEG2RAD(mtl_refdef.viewangles[1]));
		float sr = sinf(DEG2RAD(mtl_refdef.viewangles[2])), cr = cosf(DEG2RAD(mtl_refdef.viewangles[2]));
		vec3_t vpn = {cp * cy, cp * sy, -sp};
		VectorSet(render_right, -sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp);
		VectorSet(render_up, cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp);
		R_SetFrustum(render_up, vpn, render_right, mtl_refdef.vieworg, mtl_refdef.fov_x,
		             fovy_degrees, mtl_frustum);
	}

	MTL_UpdateDetailScroll(mtl_sof_frame ? mtl_sof_frame->gametime_delta : 0.0f);
	MTL_MarkLeaves(mod);
	MTL_MarkWorldLights();
	MTL_UpdateWorldSampler();
	mtl_detail_count = 0;
	mtl_alpha_count = 0;

	[mtl_enc setRenderPipelineState:MTL_BuildWorldPipeline()];
	MTL_CSMBindReceiver();
	[mtl_enc setDepthStencilState:mtl_depth_world];
	[mtl_enc setCullMode:MTLCullModeBack];
	[mtl_enc setFrontFacingWinding:MTLWindingClockwise];
	[mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];
	[mtl_enc setFragmentSamplerState:mtl_samp_lm atIndex:1];

	/* SPEC-410 Sky: reset the bounds, carve them through the sky faces of
	   the world, then draw the box behind everything drawn so far */
	MTL_ClearSkyBox();

	if (ri.Cvar_Get("r_metal_quad", "0", 0)->value != 0)
	{
		/* control: a 64x64 quad 128 units in front of the camera, built here */
		vec3_t fwd, right, up;
		float sp = sinf(DEG2RAD(mtl_refdef.viewangles[0])), cp = cosf(DEG2RAD(mtl_refdef.viewangles[0]));
		float sy = sinf(DEG2RAD(mtl_refdef.viewangles[1])), cy = cosf(DEG2RAD(mtl_refdef.viewangles[1]));
		fwd[0] = cp * cy; fwd[1] = cp * sy; fwd[2] = -sp;
		right[0] = sy; right[1] = -cy; right[2] = 0;
		up[0] = sp * cy; up[1] = sp * sy; up[2] = cp;

		vec3_t c;
		for (int k = 0; k < 3; k++)
		{
			c[k] = mtl_refdef.vieworg[k] + fwd[k] * 128.0f;
		}

		vec3_t p00, p10, p11, p01;
		for (int k = 0; k < 3; k++)
		{
			p00[k] = c[k] - right[k] * 32 - up[k] * 32;
			p10[k] = c[k] + right[k] * 32 - up[k] * 32;
			p11[k] = c[k] + right[k] * 32 + up[k] * 32;
			p01[k] = c[k] - right[k] * 32 + up[k] * 32;
		}

		mtl_world_vertex_t q[6];
		mtl_world_vertex_t tri[6] = {
			{{p00[0], p00[1], p00[2]}, 0.0f, {0, 1}, {0, 1}},
			{{p10[0], p10[1], p10[2]}, 0.0f, {1, 1}, {1, 1}},
			{{p11[0], p11[1], p11[2]}, 0.0f, {1, 0}, {1, 0}},
			{{p00[0], p00[1], p00[2]}, 0.0f, {0, 1}, {0, 1}},
			{{p11[0], p11[1], p11[2]}, 0.0f, {1, 0}, {1, 0}},
			{{p01[0], p01[1], p01[2]}, 0.0f, {0, 0}, {0, 0}},
		};
		memcpy(q, tri, sizeof(q));

		mtl_world_uniform_t u;
		memset(&u, 0, sizeof(u));
		memcpy(u.mvp, mvp, sizeof(u.mvp));
		u.overbright = 1.0f;
		u.fullbright = 1.0f;
		mtl_lightmap_t control_lightmap = {};
		control_lightmap.count = 1;
		control_lightmap.styles[0] = 255;
		MTL_LightmapBind(&control_lightmap, NULL, false, 1.0f, 0, nil);
		mtl_post_fragment_uniform_t control_post = {{0, 0, 0, 0}};
		[mtl_enc setFragmentBytes:&control_post length:sizeof(control_post) atIndex:4];

		[mtl_enc setVertexBytes:q length:sizeof(q) atIndex:0];
		[mtl_enc setVertexBytes:&u length:sizeof(u) atIndex:1];
		[mtl_enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
		[mtl_enc setFragmentTexture:mtl_white atIndex:0];
		[mtl_enc setFragmentTexture:mtl_white atIndex:1];
		[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		MTL_PostCopyOpaqueDepth();
		MTL_PostEndView();
		MTL_CSMEndView();
		if (!post) MTL_TargetApplyRaster(&window);
		return;
	}

	int drawn = 0;
	mtl_world_walk_stats_t stats = {};
	MTL_FogBeginFrame();
	MTL_RecursiveWorldNode(mod, &mod->nodes[mod->firstnode], mvp, &drawn, &stats);
	MTL_FogQueueChains();
	if (mtl_world_debug_cvar && mtl_world_debug_cvar->value)
	{
		static int worlddebug_lines;
		if (worlddebug_lines++ < 5)
		{
			Com_Printf("ref_metal: worlddebug fov x %.3f y %.3f derived_y %.3f aspect %.6f\\n",
			           mtl_refdef.fov_x, mtl_refdef.fov_y, fovy_degrees, aspect);
			Com_Printf("ref_metal: worlddebug origin %.3f %.3f %.3f right %.6f %.6f %.6f up %.6f %.6f %.6f\\n",
			           mtl_refdef.vieworg[0], mtl_refdef.vieworg[1], mtl_refdef.vieworg[2],
			           render_right[0], render_right[1], render_right[2],
			           render_up[0], render_up[1], render_up[2]);
			for (int i = 0; i < 4; i++)
			{
				Com_Printf("ref_metal: worlddebug plane %d %.6f %.6f %.6f dist %.6f\\n",
				           i, mtl_frustum[i].normal[0], mtl_frustum[i].normal[1],
				           mtl_frustum[i].normal[2], mtl_frustum[i].dist);
			}
			Com_Printf("ref_metal: worlddebug root %.3f %.3f %.3f .. %.3f %.3f %.3f\\n",
			           mod->nodes[mod->firstnode].minmaxs[0], mod->nodes[mod->firstnode].minmaxs[1],
			           mod->nodes[mod->firstnode].minmaxs[2], mod->nodes[mod->firstnode].minmaxs[3],
			           mod->nodes[mod->firstnode].minmaxs[4], mod->nodes[mod->firstnode].minmaxs[5]);
			Com_Printf("ref_metal: worlddebug nodes %d culled %d unmarked %d leaves %d candidates %d marked %d submitted %d\\n",
			           stats.nodes, stats.culled, stats.unmarked, stats.leaves, stats.candidates,
			           stats.marked_surfaces, drawn);
		}
	}
	MTL_DrawDetailPass(mod, mvp);
	MTL_DrawSkyBox(mvp);
	MTL_TerrainDraw(mvp); /* SPEC-410 Terrain sets, after the sky box as in GL */
	/* Snapshot opaque WORLD before any brush/entity/particle depth is written. */
	MTL_PostCopyOpaqueDepth();
	/* SPEC-410: the fog overlay of the faces the walk collected, with shimmer and far wall; again after the sorted pass */
	MTL_FogPass(mvp, 1);
	/* GFX-modern: volumetric fog in the fog regions, over the world and its overlay; shafts from the sun maps */
	MTL_CSMBindReceiver();
	MTL_VolFogDraw(MTL_CSMActive());
	MTL_DrawScene(mvp, view, render_right, render_up);
	MTL_FogPass(mvp, 0);
	MTL_DrawParticles(mvp, render_right, render_up, fovy_degrees);
	MTL_PostEndView();
	MTL_CSMEndView();
	if (!post) MTL_TargetApplyRaster(&window);
	MTL_PostScreenOverlays(view_x, view_y, view_width, view_height, mtl_refdef.rdflags,
		mtl_sof_frame ? mtl_sof_frame->gametime_delta : 0.1f, mtl_refdef.blend,
		mtl_brush_polygons, mod->vis && mtl_last_cluster >= 0);
}

static void
MTL_RenderFrame(refdef_t *fd)
{
	mtl_refdef = *fd;
	mtl_brush_polygons = 0;
	MTL_PrepareDynamicLights();
	/* GL3 exchanges the refdef's dynamic lights with Ghoul before every frame.
	 * The native sink has no GL table through which to receive that exchange,
	 * so import the renderer-owned frame lights explicitly. */
	if (mtl_ghoul_system)
	{
		int local_viewer = mtl_ghoul_local_viewer_cvar && mtl_ghoul_local_viewer_cvar->value > 0.5f;
		if (local_viewer != mtl_ghoul_sink.hardware_local_viewer)
		{
			mtl_ghoul_sink.hardware_local_viewer = local_viewer;
			OMGhoul_SetNativeSink(&mtl_ghoul_sink);
		}
		int specular = mtl_ghoul_specular_cvar && mtl_ghoul_specular_cvar->value > 0.5f &&
			mtl_ghoul_light_method_cvar && mtl_ghoul_light_method_cvar->value > 0.5f;
		if (specular != mtl_ghoul_specular_state)
		{
			OMGhoul_SetSpecular(mtl_ghoul_system, specular);
			mtl_ghoul_specular_state = specular;
		}
		OMGhoul_ClearLights(mtl_ghoul_system);
		if (mtl_refdef.dlights && mtl_ghoul_light_method_cvar &&
		    mtl_ghoul_light_method_cvar->value > 0.5f)
		{
			for (int i = 0; i < mtl_refdef.num_dlights; i++)
			{
				om_ghoul_light_t light = {};
				memcpy(light.origin, mtl_refdef.dlights[i].origin, sizeof(light.origin));
				memcpy(light.color, mtl_refdef.dlights[i].color, sizeof(light.color));
				light.radius = mtl_refdef.dlights[i].intensity * 0.5f;
				if (light.radius > 0.0f)
					OMGhoul_AddDynamicLight(mtl_ghoul_system, &light);
			}
		}
	}
	MTL_UpdateSizes();
	MTL_DrawWorld();
	MTL_SoF_Set2D(0);
}

/* Implements: SPEC-002 frame conversion. Preserve the explicit SoF record
 * while native draws run, rather than losing game time through the generic
 * refdef fallback. No GL state or translation entry point is involved. */
static void
MTL_SoF_RenderFrame(sofrefdef_t *fd)
{
	static entity_t entities[SOF_MAX_ENTITIES];
	refdef_t rd = {};
	if (!fd)
		return;
	rd.x = fd->x;
	rd.y = fd->y;
	rd.width = fd->width;
	rd.height = fd->height;
	rd.fov_x = fd->fov_x;
	rd.fov_y = fd->fov_y;
	VectorCopy(fd->vieworg, rd.vieworg);
	VectorCopy(fd->viewangles, rd.viewangles);
	memcpy(rd.blend, fd->blend, sizeof(rd.blend));
	rd.time = fd->time;
	rd.rdflags = fd->rdflags & (SOF_RDF_NOWORLDMODEL | SOF_RDF_IRGOGGLES);
	rd.areabits = fd->areabits;
	rd.lightstyles = (lightstyle_t *)fd->lightstyles;
	rd.num_dlights = Q_max(0, Q_min(fd->num_dlights, SOF_MAX_DLIGHTS));
	rd.dlights = (dlight_t *)fd->dlights;
	rd.num_entities = Q_max(0, Q_min(fd->num_entities, SOF_MAX_ENTITIES));
	rd.entities = entities;
	for (int i = 0; i < rd.num_entities; i++)
	{
		const sofentity_t *se = fd->entities ? fd->entities[i] : NULL;
		entity_t *e = &entities[i];
		memset(e, 0, sizeof(*e));
		if (!se)
			continue;
		e->model = (struct model_s *)se->model;
		VectorCopy(se->angles, e->angles);
		VectorCopy(se->origin, e->origin);
		VectorCopy(se->origin, e->oldorigin);
		e->frame = se->frame;
		e->oldframe = se->oldframe;
		e->backlerp = se->backlerp;
		e->skinnum = se->skinnum;
		e->alpha = se->alpha;
		e->skin = (struct image_s *)se->skin;
		e->flags = se->flags & ~0x20;
	}
	mtl_sof_frame = fd;
	MTL_RenderFrame(&rd);
	mtl_sof_frame = NULL;
	/* SPEC-413 6: r_lightlevel = 150 x the largest component of the light at the eye. The client sends it with every
	 * move and the AI's sight roll scales with it (SPEC-701); never setting it made enemies treat the player as standing
	 * in complete darkness on Metal (play-test 2026-11-08 "some people are just standing"). */
	if (!(rd.rdflags & RDF_NOWORLDMODEL) && mtl_worldmodel)
	{
		static cvar_t *lightlevel;
		vec3_t light = {0, 0, 0};
		if (!lightlevel)
			lightlevel = ri.Cvar_Get("r_lightlevel", "0", 0);
		MTL_SoFLightPointDir(rd.vieworg, light, 255);
		lightlevel->value = 150.0f * Q_max(light[0], Q_max(light[1], light[2]));
	}
	fd->scratch = NULL;
}

static void
MTL_EndFrame(void)
{
	if (!mtl_encoder_open)
	{
		return;
	}

	MTL_TargetEnd();

	if (shot_pending)
	{
		MTL_CaptureDrawable(); /* commits, presents and waits */
		dispatch_semaphore_signal(mtl_inflight);
	}
	else
	{
		/* RLabs (2026-11-05, play-tester: "game is not locked at 120hz", "lots of drops"): r_metal_presentstats 1 prints,
		   once a second, how many frames reached the screen, their average and longest interval and how many
		   intervals were longer than 1.5 refreshes (a repeated frame on screen = a visible drop) */
		{
			static cvar_t *pstats;
			if (!pstats)
				pstats = ri.Cvar_Get("r_metal_presentstats", "0", 0);
			if (pstats->value != 0 && mtl_drawable)
			{
				static double last_shown, last_print, sum, worst;
				static int n, drops;
				[mtl_drawable addPresentedHandler:^(id<MTLDrawable> d) {
					const double t = d.presentedTime;
					if (t <= 0)
						return;
					@synchronized ([NSProcessInfo processInfo]) {
						if (last_shown > 0) {
							const double dt = t - last_shown;
							sum += dt;
							n++;
							if (dt > worst)
								worst = dt;
							if (dt > 1.5 / 120.0)
								drops++;
						}
						last_shown = t;
					}
				}];
				const double now = CACurrentMediaTime();
				if (last_print == 0)
					last_print = now;
				if (now - last_print >= 1.0)
				{
					@synchronized ([NSProcessInfo processInfo]) {
						if (n)
							Com_Printf("[PRESENT] %d frames shown, avg %.2f ms, longest %.2f ms, %d over 12.5 ms\n",
								n, sum / n * 1000.0, worst * 1000.0, drops);
						sum = worst = 0;
						n = drops = 0;
					}
					last_print = now;
				}
			}
		}
		if (mtl_drawable)
		{
#ifdef OM_RLABS_KIT
			if (mtl_vrr)
			{
				/* the frame-rate cap's interval (vid_maxfps; 0 = the screen's fastest refresh) */
				cvar_t *maxfps = ri.Cvar_Get("vid_maxfps", "0", CVAR_ARCHIVE);
				[mtl_cb presentDrawable:mtl_drawable
				   afterMinimumDuration:rlk_vrr_interval((int)maxfps->value, mtl_vrr_fastest)];
			}
			else
#endif
			[mtl_cb presentDrawable:mtl_drawable];
		}
		__block dispatch_semaphore_t sem = mtl_inflight;
		/* RLabs: r_metal_gputime 1 prints the GPU time per frame once a second (measuring the graphics settings) */
		static cvar_t *gputime_cvar;
		static double gpu_sum, gpu_max;
		static int gpu_n;
		static double gpu_last_print;
		if (!gputime_cvar)
			gputime_cvar = ri.Cvar_Get("r_metal_gputime", "0", 0);
		const BOOL measure = gputime_cvar->value != 0;
		[mtl_cb addCompletedHandler:^(id<MTLCommandBuffer> cb) {
			if (measure && cb.GPUEndTime > cb.GPUStartTime)
			{
				const double ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
				@synchronized ([NSProcessInfo processInfo]) {
					gpu_sum += ms;
					gpu_n++;
					if (ms > gpu_max)
						gpu_max = ms;
				}
			}
			dispatch_semaphore_signal(sem);
		}];
		if (measure)
		{
			const double now = CACurrentMediaTime();
			if (gpu_last_print == 0)
				gpu_last_print = now;
			if (now - gpu_last_print >= 1.0)
			{
				@synchronized ([NSProcessInfo processInfo]) {
					if (gpu_n)
						Com_Printf("[GPU] %d frames %dx%d: avg %.2f ms, max %.2f ms\n", gpu_n, mtl_width, mtl_height,
							gpu_sum / gpu_n, gpu_max);
					gpu_sum = gpu_max = 0;
					gpu_n = 0;
				}
				gpu_last_print = now;
			}
		}
		[mtl_cb commit];
	}

	mtl_last_drawable = mtl_drawable;
	mtl_drawable = nil;
	mtl_cb = nil;
	mtl_enc = nil;
	MTL_TargetReset();
}

static qboolean
MTL_EndWorldRenderpass(void)
{
	return true;
}

/* Yamagi hosting does not use the original SoF module entry point.  Export the
 * SoF table separately so the client can hand this renderer its Ghoul system.
 * The table intentionally exposes only operations implemented by this native
 * renderer; non-essential 2D consumers retain their documented fallback. */
static int
MTL_SoF_Init(void *hinstance, void *wndproc, void *ghoul)
{
	(void)hinstance;
	(void)wndproc;
	if (ghoul == mtl_ghoul_system)
		return 1;
	OMGhoul_SetNativeSink(NULL);
	mtl_ghoul_system = ghoul;
	mtl_ghoul_specular_state = -1;
	if (mtl_ghoul_system)
	{
		/* SPEC-010 method 2 prepares the material specular tracks, in addition
		 * to the per-draw permission carried by render params. */
		mtl_ghoul_specular_state = mtl_ghoul_specular_cvar && mtl_ghoul_specular_cvar->value > 0.5f &&
			mtl_ghoul_light_method_cvar && mtl_ghoul_light_method_cvar->value > 0.5f;
		OMGhoul_SetSpecular(mtl_ghoul_system, mtl_ghoul_specular_state);
		/* GL3 method 38 supplies this source-mip selection before Ghoul loads
		 * skins.  Retain it even though the default is zero. */
		OMGhoul_SetTextureDetail(mtl_ghoul_system,
			(int)floorf((mtl_ghoul_mip_cvar ? mtl_ghoul_mip_cvar->value : 0.0f) + 0.5f));
		/* GL3 system method 37 supplies this exact renderer-owned table before
		 * Ghoul loads skins; native Metal must not leave its decoder at identity. */
		OMGhoul_SetGamma(mtl_ghoul_system, mtl_colortable);
		mtl_ghoul_sink.hardware_local_viewer = mtl_ghoul_local_viewer_cvar && mtl_ghoul_local_viewer_cvar->value > 0.5f;
		OMGhoul_SetNativeSink(&mtl_ghoul_sink);
	}
	return 1;
}

static void
MTL_SoF_SetColorCorrection(float gamma, float brightness, float contrast, float scale)
{
	MTL_SoF_BuildColorTable(gamma, brightness, contrast, scale);
	/* SPEC-413: world lightmaps use the current correction too. Publish a new
	 * lookup so command buffers already sampling the old one remain immutable. */
	if (mtl_device && mtl_lighttable)
	{
		MTLTextureDescriptor *desc = [MTLTextureDescriptor
			texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:256 height:1 mipmapped:NO];
		desc.storageMode = MTLStorageModeShared;
		desc.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> table = [mtl_device newTextureWithDescriptor:desc];
		if (!table) MTL_Fatal("color correction", "could not allocate world light lookup");
		[table replaceRegion:MTLRegionMake2D(0, 0, 256, 1) mipmapLevel:0
			withBytes:mtl_colortable bytesPerRow:256];
		mtl_lighttable = table;
	}
	if (mtl_ghoul_system)
		OMGhoul_SetGamma(mtl_ghoul_system, mtl_colortable);
}

#include "mtl_sofhud.h"
#include "mtl_sofmenu.h"
#include "mtl_labels.h"

Q2_DLL_EXPORTED const sofrefexport_t *
OM_GetSoFRefExports(void)
{
	static sofrefexport_t exports;
	memset(&exports, 0, sizeof(exports));
	exports.api_version = SOF_REF_API_VERSION;
	exports.Init = MTL_SoF_Init;
	exports.RenderFrame = MTL_SoF_RenderFrame;
	exports.RegisterSprite = MTL_FXRegisterSprite;
	exports.SetTerrain = MTL_SoF_SetTerrain;
	exports.LightPoint = MTL_FXLightPoint;
	exports.SetColorCorrection = MTL_SoF_SetColorCorrection;
	MTL_SoF_HUDExports(&exports);
	exports.Set2D = MTL_SoF_Set2D;
	exports.Set3DInMenu = MTL_SoF_Set3DInMenu;
	exports.ReadThumbnail = MTL_SoF_ReadThumbnail;
	exports.DrawWorldLabel = MTL_HUDWorldLabel;
	exports.DamageTexture = MTL_SoF_DamageTexture;
	return &exports;
}

/* ---- 2D ----------------------------------------------------------- */

static struct image_s *
MTL_Draw_FindPic(const char *name)
{
	return (struct image_s *)MTL_FindPic(name);
}

static void
MTL_Draw_GetPicSize(int *w, int *h, const char *pic)
{
	mtl_image_t *img = MTL_FindPic(pic);
	if (!img)
	{
		*w = *h = -1;
		return;
	}
	*w = img->width;
	*h = img->height;
}

static void
MTL_Draw_StretchPic(int x, int y, int w, int h, const char *pic)
{
	mtl_image_t *img = MTL_FindPic(pic);
	if (!img)
	{
		MTL_WarnMissing(pic);
		return;
	}
	MTL_DrawImage(img, (float)x, (float)y, (float)w, (float)h, 1.0f);
}

static void
MTL_Draw_PicScaled(int x, int y, const char *pic, float factor)
{
	mtl_image_t *img = MTL_FindPic(pic);
	if (!img)
	{
		MTL_WarnMissing(pic);
		return;
	}
	MTL_DrawImage(img, (float)x, (float)y,
	              (float)img->width * factor, (float)img->height * factor, 1.0f);
}

static void
MTL_Draw_PicScaledCol(int x, int y, const char *pic, float factor, const float color[3])
{
	mtl_image_t *img = MTL_FindPic(pic);
	if (!img)
	{
		MTL_WarnMissing(pic);
		return;
	}
	float c[4] = {color[0], color[1], color[2], 1.0f};
	MTL_Quad((float)x, (float)y, (float)img->width * factor, (float)img->height * factor,
	         img->sl, img->tl, img->sh, img->th, c, (__bridge id<MTLTexture>)img->tex, NO);
}

static void
MTL_Draw_CharScaled(int x, int y, int num, float scale)
{
	if (!draw_chars || !draw_chars->tex)
	{
		return;
	}

	num &= 255;
	if ((num & 127) == 32 || y <= -8)
	{
		return;
	}

	int row = num >> 4;
	int col = num & 15;
	float size = 0.0625f;

	float u0 = draw_chars->sl + ((float)col * size) * (draw_chars->sh - draw_chars->sl);
	float v0 = draw_chars->tl + ((float)row * size) * (draw_chars->th - draw_chars->tl);
	float u1 = draw_chars->sl + ((float)(col + 1) * size) * (draw_chars->sh - draw_chars->sl);
	float v1 = draw_chars->tl + ((float)(row + 1) * size) * (draw_chars->th - draw_chars->tl);

	float c[4] = {1, 1, 1, 1};
	MTL_Quad((float)x, (float)y, 8.0f * scale, 8.0f * scale,
	         u0, v0, u1, v1, c, (__bridge id<MTLTexture>)draw_chars->tex, NO);
}

static void
MTL_Draw_TileClear(int x, int y, int w, int h, const char *pic)
{
	mtl_image_t *img = MTL_FindPic(pic);
	if (!img || !img->tex)
	{
		return;
	}
	float c[4] = {1, 1, 1, 1};
	float tw = (float)w / (float)img->width;
	float th = (float)h / (float)img->height;
	MTL_Quad((float)x, (float)y, (float)w, (float)h, 0, 0, tw, th, c,
	         (__bridge id<MTLTexture>)img->tex, YES);
}

static void
MTL_Draw_Fill(int x, int y, int w, int h, int c)
{
	unsigned col = mtl_palette[c & 255];
	float f[4] = {(float)(col & 0xff) / 255.0f,
	              (float)((col >> 8) & 0xff) / 255.0f,
	              (float)((col >> 16) & 0xff) / 255.0f,
	              (float)((col >> 24) & 0xff) / 255.0f};
	MTL_Quad((float)x, (float)y, (float)w, (float)h, 0, 0, 1, 1, f, mtl_white, NO);
}

static void
MTL_Draw_FadeScreen(void)
{
	const float *b = mtl_refdef.blend;
	float c[4] = {b[0], b[1], b[2], b[3]};
	MTL_Quad(0, 0, mtl_ui_w, mtl_ui_h, 0, 0, 1, 1, c, mtl_white, NO);
}

static void
MTL_Draw_StretchRaw(int x, int y, int w, int h, int cols, int rows, const byte *data, int bits)
{
	if (!data || cols <= 0 || rows <= 0)
	{
		return;
	}

	qboolean alpha = false;
	byte *rgba = MTL_ToRGBA(data, cols, rows, (size_t)cols * (size_t)rows, bits, &alpha);
	if (!rgba)
	{
		return;
	}

	void *tex = MTL_NewTextureChain(rgba, cols, rows, NO);
	free(rgba);
	if (!tex)
	{
		return;
	}

	float c[4] = {1, 1, 1, 1};
	MTL_Quad((float)x, (float)y, (float)w, (float)h, 0, 0, 1, 1, c,
	         (__bridge id<MTLTexture>)tex, NO);
	CFRelease(tex);
}

static void
MTL_SetPalette(const unsigned char *palette)
{
	if (!palette)
	{
		return;
	}

	for (int i = 0; i < 256; i++)
	{
		mtl_palette[i] = ((unsigned)palette[i * 3 + 0]) |
		                 ((unsigned)palette[i * 3 + 1] << 8) |
		                 ((unsigned)palette[i * 3 + 2] << 16) |
		                 (0xffu << 24);
	}
}

/* ------------------------------------------------------------------ */

refexport_t
GetRefAPI(refimport_t imp)
{
	refexport_t re = {0};

	ri = imp;

	re.api_version = API_VERSION;
	re.framework_version = SDL_VERSIONNUM_MAJOR(SDL_GetVersion());

	re.Init = MTL_Init;
	re.Shutdown = MTL_Shutdown;
	re.PrepareForWindow = MTL_PrepareForWindow;
	re.InitContext = MTL_InitContext;
	re.GetDrawableSize = MTL_GetDrawableSize;
	re.ShutdownContext = MTL_ShutdownContext;
	re.IsVSyncActive = MTL_IsVSyncActive;

	re.BeginRegistration = MTL_BeginRegistration;
	re.RegisterModel = MTL_RegisterModel;
	re.RegisterSkin = MTL_RegisterSkin;
	re.SetSky = MTL_SetSky;
	re.EndRegistration = MTL_EndRegistration;

	re.RenderFrame = MTL_RenderFrame;

	re.DrawFindPic = MTL_Draw_FindPic;
	re.DrawGetPicSize = MTL_Draw_GetPicSize;
	re.DrawPicScaled = MTL_Draw_PicScaled;
	re.DrawStretchPic = MTL_Draw_StretchPic;
	re.DrawCharScaled = MTL_Draw_CharScaled;
	re.DrawTileClear = MTL_Draw_TileClear;
	re.DrawFill = MTL_Draw_Fill;
	re.DrawFadeScreen = MTL_Draw_FadeScreen;
	re.DrawStretchRaw = MTL_Draw_StretchRaw;
	re.SetPalette = MTL_SetPalette;

	re.BeginFrame = MTL_BeginFrame;
	re.EndFrame = MTL_EndFrame;
	re.EndWorldRenderpass = MTL_EndWorldRenderpass;

	re.DrawPicScaledCol = MTL_Draw_PicScaledCol;

	return re;
}
