// SPDX-License-Identifier: GPL-2.0-or-later
// Generic refexport MD2/SP2 drawing. Included after lighting/matrix helpers
// in mtl_main.m. Call shutdown with the other GPU
// pipeline cleanup after the renderer's resource fence.
// Implements: SPEC-411; GPL gl3_mesh.c and gl3_main.c generic-model behavior.
#include <stdint.h>
#include <stddef.h>
#include <limits.h>

typedef struct {
	size_t vertices, indices;
	const int *commands;
	size_t words;
} mtl_md2_budget_t;

/* Bound every byte span before pointer arithmetic; division avoids overflow
 * even for corrupt positive header counts. Empty optional spans may be zero. */
static int MTL_MD2Span(int offset,int count,size_t stride,size_t limit)
{
	if (offset<0 || count<0 || (size_t)offset>limit) return 0;
	if (!count) return 1;
	return offset>=(int)sizeof(dmdl_t) && (size_t)count<=(limit-(size_t)offset)/stride;
}

static int MTL_MD2Validate(const void *data,size_t available,mtl_md2_budget_t *budget)
{
	memset(budget,0,sizeof(*budget));
	if (!data || available<sizeof(dmdl_t)) return 0;
	/* Raw file bytes can be unaligned. Validate a local header and use memcpy
	 * for numeric payloads; native loaded hunks remain aligned for drawing. */
	dmdl_t value;memcpy(&value,data,sizeof(value));const dmdl_t *header=&value;
	const byte *base=(const byte *)data;
	if (header->ident!=0x32504449 || header->version!=8 ||
		header->ofs_end<(int)sizeof(*header) || (size_t)header->ofs_end>available ||
		header->num_xyz<=0 || header->num_xyz>MAX_VERTS || header->num_frames<=0 ||
		header->num_skins<0 || header->num_skins>MAX_MD2SKINS ||
		header->num_st<=0 || header->num_tris<=0 || header->num_glcmds<=0 ||
		header->framesize<(int)(offsetof(daliasframe_t,verts)+(size_t)header->num_xyz*sizeof(dtrivertx_t))) return 0;
	size_t limit=(size_t)header->ofs_end;
	if (!MTL_MD2Span(header->ofs_skins,header->num_skins,MAX_SKINNAME,limit) ||
		!MTL_MD2Span(header->ofs_st,header->num_st,4,limit) ||
		!MTL_MD2Span(header->ofs_tris,header->num_tris,12,limit) ||
		!MTL_MD2Span(header->ofs_frames,header->num_frames,(size_t)header->framesize,limit) ||
		!MTL_MD2Span(header->ofs_glcmds,header->num_glcmds,sizeof(int),limit) ||
		(header->ofs_frames&3) || (header->framesize&3) || (header->ofs_glcmds&3)) return 0;
	for (int i=0;i<header->num_skins;i++)
		if (!memchr(base+(size_t)header->ofs_skins+(size_t)i*MAX_SKINNAME,0,MAX_SKINNAME)) return 0;
	for (int i=0;i<header->num_frames;i++) {
		float coordinates[6];memcpy(coordinates,base+(size_t)header->ofs_frames+
			(size_t)i*(size_t)header->framesize,sizeof(coordinates));
		for (int k=0;k<6;k++) if (!isfinite(coordinates[k])) return 0;
	}
	const byte *command_bytes=base+header->ofs_glcmds;
	size_t word=0,words=(size_t)header->num_glcmds;
	while (word<words) {
		int raw;memcpy(&raw,command_bytes+word*sizeof(int),sizeof(raw));word++;
		if (!raw) {
			if (!budget->vertices || !budget->indices ||
				budget->vertices>SIZE_MAX/MTL_ALIAS_STRIDE ||
				budget->indices>SIZE_MAX/sizeof(uint32_t)) return 0;
			budget->commands=(const int *)command_bytes;budget->words=word;return 1;
		}
		/* Widen before negation: INT_MIN is a rejected span, never UB. */
		size_t count=(size_t)(raw<0?-(int64_t)raw:(int64_t)raw);
		if (count<3 || count>(words-word)/3 || count>UINT32_MAX-budget->vertices ||
			count-2>SIZE_MAX/3) return 0;
		size_t indices=(count-2)*3;
		if (indices>SIZE_MAX-budget->indices) return 0;
		for (size_t i=0;i<count;i++) {
			float uv[2];memcpy(uv,command_bytes+word*sizeof(int),8);
			int index;memcpy(&index,command_bytes+(word+2)*sizeof(int),sizeof(index));
			if (!isfinite(uv[0]) || !isfinite(uv[1]) || index<0 || index>=header->num_xyz) return 0;
			word+=3;
		}
		budget->vertices+=count;budget->indices+=indices;
	}
	return 0; /* no terminator inside the declared command span */
}

/* arm64 host and MD2 file bytes are both little-endian. The root loader calls
 * this before Mod_LoadMD2 touches any untrusted offsets or skin strings. */
static int MTL_MD2DataValid(const void *data,size_t bytes)
{
	mtl_md2_budget_t budget;return MTL_MD2Validate(data,bytes,&budget);
}

static id<MTLRenderPipelineState> mtl_generic_pipelines[2];
static id<MTLDevice> mtl_generic_device;

static void
MTL_GenericModelsShutdown(void)
{
	mtl_generic_pipelines[0] = nil;
	mtl_generic_pipelines[1] = nil;
	mtl_generic_device = nil;
}

static NSString *const mtl_generic_fragment = @R"MSL(
fragment OMPostOutput mtl_fs_generic(AliasVSOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant float2 &parameters [[buffer(2)]])
{
	float4 t = tex.sample(smp, in.uv);
	if (t.a <= parameters.x) discard_fragment();
	t.rgb *= min(in.color.rgb, float3(1.5));
	t.a *= parameters.y > 0 ? min(in.color.a, parameters.y) : in.color.a;
	return OM_PostDefault(t);
}
)MSL";

static id<MTLRenderPipelineState>
MTL_GenericModelPipeline(BOOL blend)
{
	if (mtl_generic_device != mtl_device)
	{
		MTL_GenericModelsShutdown();
		mtl_generic_device = mtl_device;
	}
	mtl_pipeline_targets_t targets=MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> cached=MTL_PostPipelineCached(MTL_POST_PIPE_GENERIC,blend,0,&targets);
	if(cached) return cached;
	NSError *error = nil;
	id<MTLLibrary> library = [mtl_device newLibraryWithSource:
		MTL_PostShaderSource([NSString stringWithFormat:@"%@\n%@\n%@", mtl_fog_linear_msl, mtl_alias_shader, mtl_generic_fragment],&targets)
		options:nil error:&error];
	if (!library) MTL_Fatal("MSL compile (generic models)", error.localizedDescription.UTF8String);
	MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
	descriptor.label = blend ? @"openMerc generic model source-over" : @"openMerc generic model opaque";
	descriptor.vertexFunction = [library newFunctionWithName:@"mtl_vs_alias"];
	descriptor.fragmentFunction = [library newFunctionWithName:@"mtl_fs_generic"];
	MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
	color.pixelFormat = mtl_layer.pixelFormat;
	color.blendingEnabled = blend;
	if (blend)
	{
		color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		color.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
		color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	MTL_PostConfigurePipeline(descriptor,&targets);
	id<MTLRenderPipelineState> pipeline = [mtl_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
	if (!pipeline) MTL_Fatal("pipeline (generic models)", error.localizedDescription.UTF8String);
	MTL_PostPipelineStore(MTL_POST_PIPE_GENERIC,blend,0,&targets,pipeline);
	return pipeline;
}

static void
MTL_GenericModelState(entity_t *entity, BOOL sprite)
{
	BOOL translucent = (entity->flags & RF_TRANSLUCENT) != 0;
	float alpha = translucent ? entity->alpha : 1.0f;
	/* GL3's sprite alpha==1 branch is cutout even when RF_TRANSLUCENT is
	 * present. The flag still suppresses depth writes in that case. MD2's
	 * ordinary shader never alpha-tests its skin. */
	BOOL blend = sprite ? alpha != 1.0f : translucent;
	float parameters[2] = {sprite && alpha == 1.0f ? 0.666f : -1.0f, sprite ? -1.0f : 1.5f};
	[mtl_enc setRenderPipelineState:MTL_GenericModelPipeline(blend)];
	[mtl_enc setFragmentBytes:parameters length:sizeof(parameters) atIndex:2];
	[mtl_enc setDepthStencilState:translucent ? mtl_depth_readonly : mtl_depth_world];
	[mtl_enc setDepthBias:0 slopeScale:0 clamp:0];
	[mtl_enc setCullMode:sprite ? MTLCullModeNone : MTLCullModeBack];
	[mtl_enc setFrontFacingWinding:MTLWindingClockwise];
}


static void
MTL_DrawAliasModel(entity_t *e, const float mvp[16], const float view[16])
{
	if (!e || !e->model || !mtl_encoder_open) return;
	mtl_model_t *mod = (mtl_model_t *)e->model;
	dmdl_t *hdr = (dmdl_t *)mod->aliashdr;
	mtl_md2_budget_t budget;
	if (!MTL_MD2Validate(hdr,mod->aliashdr_bytes,&budget)) return;
	mtl_alias_vertex_t *vertices=(mtl_alias_vertex_t *)calloc(budget.vertices,sizeof(*vertices));
	uint32_t *indices=(uint32_t *)calloc(budget.indices,sizeof(*indices));
	float (*lerped)[3]=(float (*)[3])calloc((size_t)hdr->num_xyz,sizeof(*lerped));
	if (!vertices || !indices || !lerped) {free(vertices);free(indices);free(lerped);return;}
	daliasframe_t *frame, *oldframe;
	dtrivertx_t *v, *ov;
	const int *order;
	float alpha;
	vec3_t move, delta, fwd, rgt, up;
	float backlerp = e->backlerp;
	float frontlerp = 1.0f - backlerp;
	float frontv[3], backv[3];
	vec3_t shadelight;
	int i, j, index_xyz, count;

	if (e->frame >= hdr->num_frames || e->frame < 0)
	{
		e->frame = 0;
	}

	if (e->oldframe >= hdr->num_frames || e->oldframe < 0)
	{
		e->oldframe = 0;
	}

	float *shadedots = mtl_avertexnormal_dots[
		((int)(e->angles[1] * (MTL_SHADEDOT_QUANT / 360.0f))) & (MTL_SHADEDOT_QUANT - 1)];
	MTL_AliasShadeLight(e, shadelight);

	frame = (daliasframe_t *)((byte *)hdr + hdr->ofs_frames + e->frame * hdr->framesize);
	oldframe = (daliasframe_t *)((byte *)hdr + hdr->ofs_frames + e->oldframe * hdr->framesize);

	v = frame->verts;
	ov = oldframe->verts;

	alpha = (e->flags & RF_TRANSLUCENT) ? (e->alpha * 0.666f) : 1.0f;

	/* move = backlerp x (rotated origin delta + old translate) + frontlerp x translate */
	VectorSubtract(e->oldorigin, e->origin, delta);

	float sp = sinf(DEG2RAD(e->angles[0])), cp = cosf(DEG2RAD(e->angles[0]));
	float sy = sinf(DEG2RAD(e->angles[1])), cy = cosf(DEG2RAD(e->angles[1]));
	float sr = sinf(DEG2RAD(e->angles[2])), cr = cosf(DEG2RAD(e->angles[2]));

	fwd[0] = cp * cy; fwd[1] = cp * sy; fwd[2] = -sp;
	rgt[0] = -sr * sp * cy + cr * sy; rgt[1] = -sr * sp * sy - cr * cy; rgt[2] = -sr * cp;
	up[0] = cr * sp * cy + sr * sy; up[1] = cr * sp * sy - sr * cy; up[2] = cr * cp;

	move[0] = DotProduct(delta, fwd);
	move[1] = -DotProduct(delta, rgt);
	move[2] = DotProduct(delta, up);
	VectorAdd(move, oldframe->translate, move);

	for (i = 0; i < 3; i++)
	{
		move[i] = backlerp * move[i] + frontlerp * frame->translate[i];
		frontv[i] = frontlerp * frame->scale[i];
		backv[i] = backlerp * oldframe->scale[i];
	}

	/* lerp every MD2 vertex between the old and current frame */
	for (i = 0; i < hdr->num_xyz; i++)
	{
		for (j = 0; j < 3; j++)
		{
			lerped[i][j] = move[j] + ov[i].v[j] * backv[j] + v[i].v[j] * frontv[j];
		}
	}

	/* build the vertex + triangle-index arrays from the strip/fan command list */
	size_t nverts = 0, nidx = 0;
	order = budget.commands;

	while (1)
	{
		uint32_t base = (uint32_t)nverts;

		count = *order++;

		if (!count)
		{
			break;
		}

		qboolean fan = false;

		if (count < 0)
		{
			count = -count;
			fan = true;
		}

		for (i = 0; i < count; i++)
		{
			mtl_alias_vertex_t *cur = &vertices[nverts + (size_t)i];
			float l;

			memcpy(cur->uv,order,sizeof(cur->uv));
			index_xyz = order[2];
			order += 3;

			l = shadedots[v[index_xyz].lightnormalindex];

			for (j = 0; j < 3; j++)
			{
				cur->pos[j] = lerped[index_xyz][j];
				cur->color[j] = l * shadelight[j];
			}

			/* GPL alias passColor scales all four components before its cap. */
			cur->color[3] = Q_min(alpha * MTL_Overbright(), 1.5f);
		}

		if (fan)
		{
			for (i = 1; i < count - 1; i++)
			{
				indices[nidx++] = base;
				indices[nidx++] = base + (uint32_t)i;
				indices[nidx++] = base + (uint32_t)(i + 1);
			}
		}
		else
		{
			for (i = 1; i < count - 2; i += 2)
			{
				indices[nidx++] = base + (uint32_t)(i - 1);
				indices[nidx++] = base + (uint32_t)i;
				indices[nidx++] = base + (uint32_t)(i + 1);
				indices[nidx++] = base + (uint32_t)i;
				indices[nidx++] = base + (uint32_t)(i + 2);
				indices[nidx++] = base + (uint32_t)(i + 1);
			}

			if (i < count - 1)
			{
				indices[nidx++] = base + (uint32_t)(i - 1);
				indices[nidx++] = base + (uint32_t)i;
				indices[nidx++] = base + (uint32_t)(i + 1);
			}
		}

		nverts += count;
	}

	/* Use per-draw shared buffers.  The command queue permits three in-flight
	   frames, so rewriting one persistent buffer could race the GPU. */
	NSUInteger vbytes = (NSUInteger)nverts * MTL_ALIAS_STRIDE;
	NSUInteger ibytes = (NSUInteger)nidx * sizeof(uint32_t);
	id<MTLBuffer> vb = [mtl_device newBufferWithBytes:vertices
	                                            length:vbytes
	                                           options:MTLResourceStorageModeShared];
	id<MTLBuffer> ib = [mtl_device newBufferWithBytes:indices
	                                            length:ibytes
	                                           options:MTLResourceStorageModeShared];
	free(vertices);free(indices);free(lerped);
	if (!vb || !ib)
	{
		Com_Printf("ref_metal: couldn't allocate alias streaming buffers\n");
		return;
	}

	/* entity model matrix: projection x view x model. View weapons use
	 * r_gunfov before the same entity transform, matching GL3_DrawAliasModel. */
	float model[16], projection_view[16], emvp[16];
	MTL_EntityMatrix(e->origin, e->angles, model);
	MTL_AliasEntityMVP(e, mvp, view, projection_view);
	MTL_Mul4(projection_view, model, emvp);

	mtl_image_t *skin = mod->skins[e->skinnum < MAX_MD2SKINS && e->skinnum >= 0 ? e->skinnum : 0];
	if (e->skin)
	{
		skin = (mtl_image_t *)e->skin;
	}

	MTL_GenericModelState(e, NO);
	[mtl_enc setVertexBuffer:vb offset:0 atIndex:0];
	[mtl_enc setVertexBytes:&emvp length:sizeof(emvp) atIndex:1];
	[mtl_enc setFragmentTexture:(skin && skin->tex) ? (__bridge id<MTLTexture>)skin->tex : mtl_white atIndex:0];
	[mtl_enc setFragmentSamplerState:mtl_samp_clamp atIndex:0];
	[mtl_enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
	                    indexCount:(NSUInteger)nidx
	                     indexType:MTLIndexTypeUInt32
	                   indexBuffer:ib
	             indexBufferOffset:0];
}

static void
MTL_DrawSpriteModel(entity_t *e, mtl_model_t *mod, const float mvp[16])
{
	if (!e || !mod || !mod->aliashdr || !mtl_encoder_open || !mtl_pipe_alias)
		return;
	dsprite_t *sprite = (dsprite_t *)mod->aliashdr;
	if (sprite->numframes <= 0)
		return;
	int frame_index = e->frame % sprite->numframes;
	if (frame_index < 0)
		frame_index += sprite->numframes;
	dsprframe_t *frame = &sprite->frames[frame_index];
	float sp = sinf(DEG2RAD(mtl_refdef.viewangles[0])), cp = cosf(DEG2RAD(mtl_refdef.viewangles[0]));
	float sy = sinf(DEG2RAD(mtl_refdef.viewangles[1])), cy = cosf(DEG2RAD(mtl_refdef.viewangles[1]));
	float sr = sinf(DEG2RAD(mtl_refdef.viewangles[2])), cr = cosf(DEG2RAD(mtl_refdef.viewangles[2]));
	vec3_t right = {-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp};
	vec3_t up = {cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp};
	float alpha = (e->flags & RF_TRANSLUCENT) ? e->alpha : 1.0f;
	mtl_alias_vertex_t v[4] = {};
	const float dx[4] = {-(float)frame->origin_x, -(float)frame->origin_x,
		(float)(frame->width - frame->origin_x), (float)(frame->width - frame->origin_x)};
	const float dy[4] = {-(float)frame->origin_y, (float)(frame->height - frame->origin_y),
		(float)(frame->height - frame->origin_y), -(float)frame->origin_y};
	const float uv[4][2] = {{0, 1}, {0, 0}, {1, 0}, {1, 1}};
	for (int i = 0; i < 4; i++)
	{
		for (int k = 0; k < 3; k++)
			v[i].pos[k] = e->origin[k] + dx[i] * right[k] + dy[i] * up[k];
		v[i].uv[0] = uv[i][0];
		v[i].uv[1] = uv[i][1];
		v[i].color[0] = v[i].color[1] = v[i].color[2] = 1.0f;
		v[i].color[3] = alpha;
	}
	mtl_image_t *skin = mod->skins[frame_index];
	mtl_alias_vertex_t triangles[6];
	const int indices[6] = {0, 1, 2, 0, 2, 3};
	for (int i = 0; i < 6; i++) triangles[i] = v[indices[i]];
	MTL_GenericModelState(e, YES);
	[mtl_enc setVertexBytes:triangles length:sizeof(triangles) atIndex:0];
	[mtl_enc setVertexBytes:mvp length:sizeof(float) * 16 atIndex:1];
	[mtl_enc setFragmentTexture:(skin && skin->tex) ? (__bridge id<MTLTexture>)skin->tex : mtl_notexture ? (__bridge id<MTLTexture>)mtl_notexture->tex : mtl_white atIndex:0];
	[mtl_enc setFragmentSamplerState:mtl_samp_clamp atIndex:0];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}
