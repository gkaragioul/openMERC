// SPDX-License-Identifier: GPL-2.0-or-later
// Native translucent world pass. Implements: SPEC-410 Alpha surfaces, SPEC-412 sorting.
#include "mtl_brush_polygons.h"
static mtl_image_t *MTL_AnimatedWorldImage(const mtexinfo_t *tex, int frame)
{
	if (!tex || !tex->next || tex->numframes <= 1) return tex ? (mtl_image_t *)tex->image : NULL;
	mtl_image_t *image = (mtl_image_t *)tex->image;
	int index = (tex->flags & 0x1000) && image && image->animrate ?
		(int)floorf(image->animrate * MTL_GameTime()) : frame;
	index %= tex->numframes;
	if (index < 0) index += tex->numframes;
	while (index-- > 0 && tex->next) tex = tex->next;
	return (mtl_image_t *)tex->image;
}

static const mtl_world_vertex_t *MTL_AlphaVertices(const mtl_surface_t *surface)
{
	return (const mtl_world_vertex_t *)[(__bridge id<MTLBuffer>)mtl_worldmodel->vbuf contents] + surface->first_vertex;
}

static float MTL_AlphaSortKey(const mtl_surface_t *surface)
{
	float best = mtl_farclip_cvar->value * mtl_farclip_cvar->value;
	if (surface->texinfo->flags & 8)
		return MTL_SoFLiquidSortKey(mtl_worldmodel, surface, mtl_refdef.vieworg, best);
	const mtl_world_vertex_t *vertices = MTL_AlphaVertices(surface);
	for (int i = 0; i < surface->num_vertex; i++) {
		vec3_t delta; VectorSubtract(vertices[i].pos, mtl_refdef.vieworg, delta);
		float key = DotProduct(delta, delta);
		if (key < best) best = key;
	}
	return best;
}

static void MTL_FillAlphaVertices(const mtl_surface_t *surface,
	const mtl_world_vertex_t *source, mtl_alias_vertex_t *vertices)
{
	float scroll[2] = {0,0};
	if (surface->texinfo->flags & 0x40) {
		unsigned value = (unsigned)surface->texinfo->value;
		scroll[0] = (short)(value >> 16) * MTL_GameTime() * 0.01f;
		scroll[1] = (short)value * MTL_GameTime() * 0.01f;
	}
	for (int i = 0; i < surface->num_vertex; i++) {
		mtl_alias_vertex_t *v = &vertices[i];
		memcpy(v->pos, source[i].pos, sizeof(v->pos));
		v->uv[0] = source[i].uv[0] - scroll[0];
		v->uv[1] = source[i].uv[1] - scroll[1];
	}
	/* The BSP ring became a triangle fan at load time. Light queries are
	 * stateful (SPEC-410 cell-cache aging), so visit each ring vertex once,
	 * in ring order, before copying its colour to duplicate fan vertices. */
	int ring_count = surface->num_vertex / 3 + 2;
	for (int ring = 0; ring < ring_count; ring++) {
		int index = ring < 2 ? ring : 3 * (ring - 2) + 2;
		MTL_SoFLightPointDir(vertices[index].pos, vertices[index].color, 255);
		vertices[index].color[3] = 1;
	}
	for (int i = 0; i < surface->num_vertex; i++) {
		int ring = i % 3 == 0 ? 0 : i / 3 + i % 3;
		int index = ring < 2 ? ring : 3 * (ring - 2) + 2;
		if (index != i) memcpy(vertices[i].color, vertices[index].color, sizeof(vertices[i].color));
	}
}

static void MTL_DrawAlphaSurface(mtl_surface_t *surface, const float mvp[16])
{
	mtl_image_t *image = MTL_AnimatedWorldImage(surface->texinfo, (int)(MTL_GameTime() * 2));
	if (!image || !image->tex || surface->num_vertex < 3) return;
	if (surface->texinfo->flags & 8) {
		if (MTL_DrawSoFLiquid(mtl_worldmodel, surface, image, mvp, NULL,
			surface->liquid_plane_normal, 1, 0, (int)mtl_drawflat_cvar->value)) MTL_BrushPolygonDrawn();
		MTL_FogDrawSurfaceNow(surface, mvp);
		return;
	}
	const mtl_world_vertex_t *source = MTL_AlphaVertices(surface);
	mtl_alias_vertex_t *vertices = calloc((size_t)surface->num_vertex, sizeof(*vertices));
	if (!vertices) return;
	MTL_FillAlphaVertices(surface, source, vertices);
	NSUInteger buffer_offset = 0;
	id<MTLBuffer> buffer = MTL_FrameUpload(vertices, (NSUInteger)surface->num_vertex * MTL_ALIAS_STRIDE, &buffer_offset);
	free(vertices);
	if (!buffer) return;
	float cutoff = 0.05f;
	[mtl_enc setRenderPipelineState:MTL_BuildAliasPipeline(OM_GHOUL_NATIVE_BLEND_ALPHA,2)];
	MTL_PostBindEmission((mtl_emission_t){{0,0,0,0}},3);
	[mtl_enc setDepthStencilState:mtl_depth_readonly];
	[mtl_enc setCullMode:MTLCullModeNone];
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
	[mtl_enc setVertexBuffer:buffer offset:buffer_offset atIndex:0];
	[mtl_enc setVertexBytes:mvp length:16*sizeof(float) atIndex:1];
	[mtl_enc setFragmentBytes:&cutoff length:sizeof(cutoff) atIndex:2];
	[mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)image->tex atIndex:0];
	[mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];
	MTL_FXSoftOff();
	MTL_FogBindNone();
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)surface->num_vertex];
	MTL_BrushPolygonDrawn();
	MTL_FogDrawSurfaceNow(surface, mvp); /* SPEC-410: its overlay right after the face */
}
