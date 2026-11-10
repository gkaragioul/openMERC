// SPDX-License-Identifier: GPL-2.0-or-later
// Native inline brush entities. Implements: SPEC-410, SPEC-411 section 8, SPEC-412 section 10.
// Include after MTL_DrawDetailPass; opaque/world-alpha/FX hooks stay in the renderer coordinator.
#include "mtl_brush_polygons.h"

static mtl_model_t *mtl_brush_mark_owner;
static void MTL_BrushMarkSurfaceLights(dlight_t *light, int bit, mnode_t *node, int frame)
{
	(void)light; (void)frame;
	mtl_model_t *owner = mtl_brush_mark_owner;
	if (!owner || !MTL_BrushRange(node->firstsurface, node->numsurfaces, owner->numsurfaces)) return;
	for (int i = 0; i < node->numsurfaces; i++)
		owner->surfaces[node->firstsurface+i].dlightbits |= (unsigned)bit;
}

static float MTL_BrushSortKey(const entity_t *entity)
{
	const mtl_model_t *model = (const mtl_model_t *)entity->model;
	return MTL_BrushCenterKey(model->mins, model->maxs, entity->origin, mtl_refdef.vieworg);
}

static void MTL_DrawBrushAlpha(const mtl_model_t *model, const mtl_surface_t *surface,
	const float light[3], const float mvp[16])
{
	mtl_image_t *image = (mtl_image_t *)surface->texinfo->image;
	if (!image || !image->tex || surface->num_vertex < 3) return;
	const mtl_world_vertex_t *source = (const mtl_world_vertex_t *)
		[(__bridge id<MTLBuffer>)model->vbuf contents] + surface->first_vertex;
	mtl_alias_vertex_t *vertices = calloc((size_t)surface->num_vertex, sizeof(*vertices));
	if (!vertices) return;
	for (int i = 0; i < surface->num_vertex; i++)
	{
		VectorCopy(source[i].pos, vertices[i].pos);
		memcpy(vertices[i].uv, source[i].uv, sizeof(vertices[i].uv));
		VectorCopy(light, vertices[i].color);
		vertices[i].color[3] = 1;
	}
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
}

static void MTL_DrawBrushModel(entity_t *entity, const float mvp[16])
{
	mtl_model_t *model = (mtl_model_t *)entity->model;
	if (!model || !model->vbuf || !model->owner || model->type != mod_brush ||
	    !model->nummodelsurfaces || !mtl_encoder_open ||
	    !MTL_BrushRange(model->firstsurface, model->nummodelsurfaces, model->numsurfaces)) return;
	vec3_t mins, maxs;
	MTL_BrushBounds(model->mins, model->maxs, model->radius, entity->origin, entity->angles, mins, maxs);
	if (!mtl_nocull_cvar->value && R_CullBox(mins, maxs, mtl_frustum)) return;
	float matrix[16]; vec3_t local_eye;
	MTL_EntityMatrix(entity->origin, entity->angles, matrix);
	float liquid_matrix[16];
	MTL_LiquidEntityMatrix(entity->origin, entity->angles, liquid_matrix);
	MTL_BrushLocalEye(matrix, mtl_refdef.vieworg, local_eye);
	/* SPEC-410 preserves the reference BSP marking in model coordinates with
	 * untransformed light origins. The pixel evaluation uses world geometry. */
	for (int i = 0; i < model->nummodelsurfaces; i++)
		model->surfaces[model->firstsurface+i].dlightbits = 0;
	mtl_brush_mark_owner = model->owner;
	for (int i = 0; mtl_refdef.dlights && i < mtl_pdlight_active_count; i++)
		R_MarkLights(&mtl_refdef.dlights[i], (int)(1u << i), model->nodes + model->firstnode,
			mtl_framecount, MTL_BrushMarkSurfaceLights);
	mtl_brush_mark_owner = NULL;
	const mtl_world_vertex_t *source = (const mtl_world_vertex_t *)
		[(__bridge id<MTLBuffer>)model->vbuf contents];
	int count = model->nummodelsurfaces;
	mtl_surface_t *surfaces = calloc((size_t)count, sizeof(*surfaces));
	mtexinfo_t *texinfo = calloc((size_t)count, sizeof(*texinfo));
	if (!surfaces || !texinfo) { free(surfaces); free(texinfo); return; }
	int nvertices = 0;
	/* SPEC-410: an inline model's faces take the fog of the region at its bounding-box centre */
	int fogregion = -1;
	if (mtl_fogdraw.world)
	{
		float fogcentre[3];
		for (int k = 0; k < 3; k++)
			fogcentre[k] = entity->origin[k] + (model->mins[k] + model->maxs[k]) * 0.5f;
		fogregion = MTL_FogRegionOfPoint(fogcentre);
	}
	for (int i = 0; i < count; i++)
	{
		const mtl_surface_t *surface = &model->surfaces[model->firstsurface+i];
		if (!surface->texinfo || surface->num_vertex < 3 ||
		    !MTL_BrushRange(surface->first_vertex, surface->num_vertex, model->vbuf_vertices) ||
		    (surface->texinfo->flags & (0x10000 | SURF_DRAWSKY)) ||
		    !MTL_BrushFront(local_eye, source[surface->first_vertex].pos, surface->normal)) continue;
		if (surface->num_vertex > INT_MAX - nvertices) { free(surfaces); free(texinfo); return; }
		if (fogregion >= 0)
			MTL_FogQueueModelSurface(surface, fogregion, entity->origin, entity->angles);
		surfaces[i] = *surface;
		texinfo[i] = *surface->texinfo;
		/* Material/frame selection is per entity. Keep shared texinfo immutable. */
		texinfo[i].image = (struct image_s *)MTL_AnimatedWorldImage(surface->texinfo, entity->frame);
		texinfo[i].next = NULL;
		texinfo[i].numframes = 1;
		surfaces[i].texinfo = &texinfo[i];
		surfaces[i].first_vertex = nvertices;
		MTL_BrushXform(matrix, surface->normal, surfaces[i].normal, 0);
		for (int axis = 0; axis < 2; axis++)
		{
			MTL_BrushXform(matrix, surface->texinfo->vecs[axis], texinfo[i].vecs[axis], 0);
			texinfo[i].vecs[axis][3] = surface->texinfo->vecs[axis][3] -
				DotProduct(texinfo[i].vecs[axis], entity->origin);
		}
		nvertices += surface->num_vertex;
	}
	if (!nvertices) { free(surfaces); free(texinfo); return; }
	mtl_world_vertex_t *vertices = calloc((size_t)nvertices, sizeof(*vertices));
	if (!vertices) { free(surfaces); free(texinfo); return; }
	for (int i = 0; i < count; i++)
	{
		const mtl_surface_t *original = &model->surfaces[model->firstsurface+i];
		for (int j = 0; j < surfaces[i].num_vertex; j++)
		{
			mtl_world_vertex_t *vertex = &vertices[surfaces[i].first_vertex+j];
			*vertex = source[original->first_vertex+j];
			MTL_BrushXform(matrix, vertex->pos, vertex->pos, 1);
		}
	}
	id<MTLBuffer> buffer = [mtl_device newBufferWithBytes:vertices
		length:(NSUInteger)nvertices * MTL_WORLD_STRIDE options:MTLResourceStorageModeShared];
	free(vertices);
	if (!buffer) { free(surfaces); free(texinfo); return; }
	/* A borrowed draw view owns no allocation. Metal retains this immutable
	 * per-entity buffer for the submitted command buffer's lifetime. */
	mtl_model_t draw = *model;
	draw.surfaces = surfaces;
	draw.numsurfaces = count;
	draw.firstsurface = 0;
	draw.vbuf = (__bridge void *)buffer;
	draw.vbuf_vertices = nvertices;
	mtl_detail_count = 0;
	int alpha_count = 0;
	for (int i = 0; i < count; i++)
	{
		if (!surfaces[i].num_vertex) continue;
		if (surfaces[i].texinfo->flags & 0x800) { alpha_count++; continue; }
		const mtl_surface_t *original = &model->surfaces[model->firstsurface+i];
		if (original->texinfo->flags & 8)
		{
			if (MTL_DrawSoFLiquid(model, original, (mtl_image_t *)texinfo[i].image,
				mvp, liquid_matrix, original->liquid_plane_normal, 0,
				mtl_cull_cvar->value != 0, (int)mtl_drawflat_cvar->value)) MTL_BrushPolygonDrawn();
			continue;
		}
		[mtl_enc setRenderPipelineState:MTL_BuildWorldPipeline()];
		[mtl_enc setDepthStencilState:mtl_depth_world];
		[mtl_enc setCullMode:MTLCullModeBack];
		[mtl_enc setFrontFacingWinding:MTLWindingClockwise];
		[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
		[mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];
		[mtl_enc setFragmentSamplerState:mtl_samp_lm atIndex:1];
		MTL_DrawSurface(&draw, i, mvp);
	}
	if (alpha_count)
	{
		vec3_t centre, light;
		for (int k = 0; k < 3; k++)
			centre[k] = entity->origin[k] + (model->mins[k]+model->maxs[k])*0.5f;
		MTL_SoFLightPoint(centre, light);
		/* Inline alpha stays in original face order inside the sorted entity. */
		for (int i = 0; i < count; i++)
			if (surfaces[i].num_vertex && (surfaces[i].texinfo->flags & 0x800))
			{
				if (surfaces[i].texinfo->flags & 8)
				{
					if (MTL_DrawSoFLiquidInlineAlpha(model, &model->surfaces[model->firstsurface+i],
						(mtl_image_t *)texinfo[i].image, mvp, liquid_matrix, light)) MTL_BrushPolygonDrawn();
				}
				else MTL_DrawBrushAlpha(&draw, &surfaces[i], light, mvp);
			}
	}
	MTL_DrawDetailPass(&draw, mvp);
	mtl_detail_count = 0;
	free(surfaces);
	free(texinfo);
}
