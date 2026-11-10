// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Immutable static light planes and per-draw dynamic layers. Host globals:
// mtl_device, mtl_enc and mtl_white. Included after the world model types.
// Implements: SPEC-410 (lightmaps), SPEC-413 (latched controls and color table).
#ifndef OM_METAL_LIGHTMAP_H
#define OM_METAL_LIGHTMAP_H
#include <stdlib.h>
#include "mtl_lightmap_math.h"

typedef struct mtl_lightmap_s {
	void *planes[4];             /* retained Metal textures, immutable */
	int width, height, count, has_samples, has_geometry;
	unsigned char styles[4];
	mtl_lightmap_geometry_t geometry;
} mtl_lightmap_t;

typedef struct {
	float scales[4][4];
	float mode[4];
} mtl_lightmap_uniform_t;

static id<MTLDevice> mtl_lightmap_device;
static id<MTLTexture> mtl_lightmap_zero, mtl_lightmap_table;
static unsigned char mtl_lightmap_table_bytes[256];

static void
MTL_LightmapsShutdown(void)
{
	mtl_lightmap_zero = nil;
	mtl_lightmap_table = nil;
	mtl_lightmap_device = nil;
	memset(mtl_lightmap_table_bytes, 0, sizeof(mtl_lightmap_table_bytes));
}

static void
MTL_LightmapCheckDevice(void)
{
	if (mtl_lightmap_device != mtl_device) {
		MTL_LightmapsShutdown();
		mtl_lightmap_device = mtl_device;
	}
}

static void
MTL_LightmapFree(mtl_lightmap_t *lightmap)
{
	if (!lightmap) return;
	for (int i = 0; i < 4; i++) if (lightmap->planes[i]) CFRelease(lightmap->planes[i]);
	free(lightmap);
}

static mtl_lightmap_t *
MTL_LightmapCreate(const unsigned char *samples, size_t available, int width, int height,
	const unsigned char styles[4], const mtl_lightmap_geometry_t *geometry)
{
	if (!mtl_device || !styles || !MTL_LightmapDimensions(width, height)) return NULL;
	int count = 0;
	while (count < 4 && styles[count] != 255) count++;
	size_t pixels = (size_t)width * height;
	if (samples && available < pixels * 3 * (size_t)count) return NULL;
	mtl_lightmap_t *lightmap = (mtl_lightmap_t *)calloc(1, sizeof(*lightmap));
	if (!lightmap) return NULL;
	lightmap->width = width;
	lightmap->height = height;
	lightmap->count = !samples && !count ? 1 : count;
	lightmap->has_samples = samples != NULL;
	memcpy(lightmap->styles, styles, 4);
	if (geometry) { lightmap->geometry = *geometry; lightmap->has_geometry = 1; }
	unsigned char *rgba = (unsigned char *)malloc(pixels * 4);
	if (!rgba) { MTL_LightmapFree(lightmap); return NULL; }
	for (int map = 0; map < lightmap->count; map++) {
		for (size_t p = 0; p < pixels; p++) {
			for (int k = 0; k < 3; k++) rgba[p * 4 + k] = samples ? samples[((size_t)map * pixels + p) * 3 + k] : 255;
			unsigned char maximum = rgba[p * 4];
			if (rgba[p * 4 + 1] > maximum) maximum = rgba[p * 4 + 1];
			if (rgba[p * 4 + 2] > maximum) maximum = rgba[p * 4 + 2];
			rgba[p * 4 + 3] = maximum;
		}
		MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
		descriptor.storageMode = MTLStorageModeShared;
		descriptor.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> texture = [mtl_device newTextureWithDescriptor:descriptor];
		if (!texture) { free(rgba); MTL_LightmapFree(lightmap); return NULL; }
		[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:rgba bytesPerRow:(NSUInteger)width * 4];
		lightmap->planes[map] = (void *)CFBridgingRetain(texture);
	}
	free(rgba);
	return lightmap;
}

static id<MTLTexture>
MTL_LightmapZero(void)
{
	MTL_LightmapCheckDevice();
	if (!mtl_lightmap_zero) {
		MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:1 height:1 mipmapped:NO];
		descriptor.storageMode = MTLStorageModeShared;
		descriptor.usage = MTLTextureUsageShaderRead;
		mtl_lightmap_zero = [mtl_device newTextureWithDescriptor:descriptor];
		__fp16 zeros[4] = {0, 0, 0, 0};
		[mtl_lightmap_zero replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zeros bytesPerRow:8];
	}
	return mtl_lightmap_zero;
}

/* A replacement texture leaves already encoded/in-flight frames unchanged.
 * Reuse is safe only when every byte and the device agree. */
static id<MTLTexture>
MTL_LightmapColorTable(const unsigned char bytes[256])
{
	if (!bytes || !mtl_device) return nil;
	MTL_LightmapCheckDevice();
	if (!mtl_lightmap_table || memcmp(bytes, mtl_lightmap_table_bytes, 256)) {
		MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:256 height:1 mipmapped:NO];
		descriptor.storageMode = MTLStorageModeShared;
		descriptor.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> texture = [mtl_device newTextureWithDescriptor:descriptor];
		if (!texture) return nil;
		[texture replaceRegion:MTLRegionMake2D(0, 0, 256, 1) mipmapLevel:0 withBytes:bytes bytesPerRow:256];
		mtl_lightmap_table = texture;
		memcpy(mtl_lightmap_table_bytes, bytes, 256);
	}
	return mtl_lightmap_table;
}

static id<MTLTexture>
MTL_LightmapMakeDynamic(const mtl_lightmap_t *lightmap, unsigned bits,
	const dlight_t *frame_lights, int count, qboolean dynamic, qboolean per_pixel)
{
	if (!dynamic || per_pixel || !lightmap || !lightmap->has_samples || !lightmap->has_geometry ||
		!bits || !frame_lights || count <= 0) return MTL_LightmapZero();
	if (count > 32) count = 32;
	mtl_lightmap_light_t lights[32];
	for (int i = 0; i < count; i++) {
		memcpy(lights[i].origin, frame_lights[i].origin, sizeof(lights[i].origin));
		memcpy(lights[i].color, frame_lights[i].color, sizeof(lights[i].color));
		lights[i].intensity = frame_lights[i].intensity;
	}
	size_t values = (size_t)lightmap->width * lightmap->height * 4;
	float *samples = (float *)malloc(values * sizeof(float));
	if (!samples) return MTL_LightmapZero();
	if (!MTL_LightmapDynamicSamples(samples, lightmap->width, lightmap->height, &lightmap->geometry, bits, lights, count)) {
		free(samples);
		return MTL_LightmapZero();
	}
	__fp16 *half = (__fp16 *)malloc(values * sizeof(*half));
	if (!half) { free(samples); return MTL_LightmapZero(); }
	for (size_t i = 0; i < values; i++) half[i] = (__fp16)samples[i];
	free(samples);
	MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:lightmap->width height:lightmap->height mipmapped:NO];
	descriptor.storageMode = MTLStorageModeShared;
	descriptor.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> texture = [mtl_device newTextureWithDescriptor:descriptor];
	if (texture) [texture replaceRegion:MTLRegionMake2D(0, 0, lightmap->width, lightmap->height) mipmapLevel:0 withBytes:half bytesPerRow:(NSUInteger)lightmap->width * 8];
	free(half);
	return texture ? texture : MTL_LightmapZero();
}

static int
MTL_LightmapBind(const mtl_lightmap_t *lightmap, const lightstyle_t *frame_styles,
	qboolean dynamic, float modulate, int mono_mode, id<MTLTexture> dynamic_texture)
{
	if (!lightmap || !mtl_enc) return 0;
	mtl_lightmap_uniform_t uniforms = {};
	uniforms.mode[0] = (float)mono_mode;
	const int texture_slots[4] = {1, 4, 5, 6};
	for (int map = 0; map < 4; map++) {
		id<MTLTexture> plane = lightmap->planes[map] ? (__bridge id<MTLTexture>)lightmap->planes[map] : mtl_white;
		[mtl_enc setFragmentTexture:plane atIndex:texture_slots[map]];
		if (map >= lightmap->count) continue;
		for (int k = 0; k < 3; k++) {
			float style = dynamic && frame_styles && lightmap->styles[map] != 255 ? frame_styles[lightmap->styles[map]].rgb[k] : 1.0f;
			uniforms.scales[map][k] = style * modulate;
		}
		uniforms.scales[map][3] = 1.0f;
	}
	[mtl_enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:3];
	[mtl_enc setFragmentTexture:dynamic && dynamic_texture ? dynamic_texture : MTL_LightmapZero() atIndex:7];
	return 1;
}
#endif
