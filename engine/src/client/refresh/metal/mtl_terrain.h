// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Terrain sets of Soldier of Fortune in Metal: the scrolling landscape and drifting clouds outside the train of trn1.
// Ported from the GPL gl3_terrain.c: the same file layout, row ring, scroll, brightness and clouds. The fog branch of
// the GL path is left out because the only stock set (env/train.trn) has no fog.
// Implements: SPEC-410 Terrain sets, SPEC-144 (.trn), SPEC-002 slot 0x38.
#ifndef OM_METAL_TERRAIN_H
#define OM_METAL_TERRAIN_H

#define MTL_TRN_HEADER_SIZE 88
#define MTL_TRN_GROUP_SIZE 52
#define MTL_TRN_COLUMN_SIZE 68
#define MTL_TRN_MAX_ROWS 1024
#define MTL_TRN_MAX_COLUMNS 256
#define MTL_TRN_NUM_CLOUDS 32
#define MTL_TRN_CLOUD_EXTENT 16383.0f
#define MTL_TRN_CLOUD_WRAP 32766.0f

typedef struct {
	mtl_image_t *image;
	float threshold, sdiv, tdiv, fixs, fixt;
	byte whole;
} mtl_trnentry_t;
typedef struct { int numentries; mtl_trnentry_t *entries; } mtl_trnslot_t;
typedef struct {
	int slot;
	float ymin, ymax, zmin, zmax;
	int flags;      /* 0x2: mirror the texture */
	float lw[4], hw[4];
} mtl_trncolumn_t;
typedef struct {
	vec3_t pos;
	float s0, s1, t0, t1, bright;
	mtl_trnentry_t *entry;
	qboolean behind;
} mtl_trnvert_t;
typedef struct { vec3_t centre, corner[4], vel; } mtl_trncloud_t;
typedef struct { float pos[3], st[2], rgba[4]; } mtl_trn_gpu_t;

static struct {
	qboolean loaded, active, built;
	int numrows, numcols, spacing, numslots, rear;
	float speed, latoffset, hgtoffset, prevclock;
	mtl_trncolumn_t *columns;
	mtl_trnslot_t *slots;
	mtl_trnvert_t *verts;
	mtl_trncloud_t clouds[MTL_TRN_NUM_CLOUDS];
	mtl_image_t *cloudimage;
} mtl_trn;
static mtl_trn_gpu_t *mtl_trn_batch;
static int mtl_trn_batch_cap;

static float MTL_TrnRand(float lo, float hi) { return lo + (hi - lo) * ((float)rand() / (float)RAND_MAX); }

static void MTL_TerrainFree(void)
{
	if (mtl_trn.slots)
		for (int i = 0; i < mtl_trn.numslots; i++)
			free(mtl_trn.slots[i].entries);
	free(mtl_trn.slots);
	free(mtl_trn.columns);
	free(mtl_trn.verts);
	memset(&mtl_trn, 0, sizeof(mtl_trn));
}

typedef struct { const byte *p, *end; qboolean bad; } mtl_trnreader_t;
static int MTL_TrnInt(mtl_trnreader_t *r)
{
	if (r->p + 4 > r->end) { r->bad = true; return 0; }
	int v; memcpy(&v, r->p, 4); r->p += 4;
	return LittleLong(v);
}
static float MTL_TrnFloat(mtl_trnreader_t *r)
{
	if (r->p + 4 > r->end) { r->bad = true; return 0; }
	float v; memcpy(&v, r->p, 4); r->p += 4;
	return LittleFloat(v);
}
static byte MTL_TrnByte(mtl_trnreader_t *r)
{
	if (r->p + 1 > r->end) { r->bad = true; return 0; }
	return *r->p++;
}
static void MTL_TrnString(mtl_trnreader_t *r, char *out, size_t size)
{
	size_t n = 0;
	while (r->p < r->end && *r->p) { if (n + 1 < size) out[n++] = (char)*r->p; r->p++; }
	out[n] = 0;
	if (r->p >= r->end) { r->bad = true; return; }
	r->p++;
}

/* a texture name of the set: a trailing .m32 is optional in the file; the wall image or the "notexture" picture */
static mtl_image_t *MTL_TrnImage(const char *name)
{
	char base[MAX_QPATH];
	Q_strlcpy(base, name, sizeof(base));
	size_t len = strlen(base);
	if (len > 4 && !Q_stricmp(base + len - 4, ".m32"))
		base[len - 4] = 0;
	char path[MAX_QPATH];
	Com_sprintf(path, sizeof(path), "%s.m32", base);
	mtl_image_t *image = (mtl_image_t *)MTL_FindImage(path, it_wall);
	return image ? image : mtl_notexture;
}

static qboolean MTL_TrnParse(const byte *buf, int len)
{
	if (len < MTL_TRN_HEADER_SIZE)
		return false;
	mtl_trnreader_t r = {buf + 0x06, buf + len, false};
	mtl_trn.active = buf[1] != 0;
	mtl_trn.numrows = MTL_TrnInt(&r);
	mtl_trn.numcols = MTL_TrnInt(&r);
	int numgroups = MTL_TrnInt(&r), numsprites = MTL_TrnInt(&r);
	mtl_trn.numslots = MTL_TrnInt(&r);
	mtl_trn.speed = MTL_TrnFloat(&r);
	r.p = buf + MTL_TRN_HEADER_SIZE;
	if (mtl_trn.numrows < 2 || mtl_trn.numrows > MTL_TRN_MAX_ROWS || mtl_trn.numcols < 2 ||
	    mtl_trn.numcols > MTL_TRN_MAX_COLUMNS || numgroups < 1 || numgroups > 64 || numsprites < 0 ||
	    numsprites > 1024 || mtl_trn.numslots < 1 || mtl_trn.numslots > 1024)
		return false;
	mtl_trn.columns = calloc((size_t)mtl_trn.numcols, sizeof(mtl_trncolumn_t));
	for (int g = 0; g < numgroups; g++) { /* only group 0 is used */
		const byte *grp = r.p;
		int spacing = MTL_TrnInt(&r);
		float lat = MTL_TrnFloat(&r), hgt = MTL_TrnFloat(&r);
		r.p = grp + MTL_TRN_GROUP_SIZE;
		if (g == 0) { mtl_trn.spacing = spacing; mtl_trn.latoffset = lat; mtl_trn.hgtoffset = hgt; }
		for (int i = 0; i < mtl_trn.numcols; i++) {
			const byte *col = r.p;
			mtl_trncolumn_t c;
			c.slot = MTL_TrnInt(&r);
			MTL_TrnInt(&r);
			c.ymin = MTL_TrnFloat(&r); c.ymax = MTL_TrnFloat(&r);
			c.zmin = MTL_TrnFloat(&r); c.zmax = MTL_TrnFloat(&r);
			MTL_TrnFloat(&r); MTL_TrnFloat(&r);
			c.flags = MTL_TrnInt(&r);
			for (int k = 0; k < 4; k++) c.lw[k] = MTL_TrnFloat(&r);
			for (int k = 0; k < 4; k++) c.hw[k] = MTL_TrnFloat(&r);
			r.p = col + MTL_TRN_COLUMN_SIZE;
			if (g == 0) mtl_trn.columns[i] = c;
		}
		if (r.bad || r.p > r.end)
			return false;
	}
	r.p += 4; /* sprite section: parsed and discarded (terrain sprites are never drawn) */
	for (int i = 0; i < numsprites && !r.bad; i++) {
		int n = MTL_TrnInt(&r);
		for (int k = 0; k < n && !r.bad; k++) {
			char name[256];
			MTL_TrnString(&r, name, sizeof(name));
			r.p += 20;
		}
	}
	r.p += 4; /* texture section */
	mtl_trn.slots = calloc((size_t)mtl_trn.numslots, sizeof(mtl_trnslot_t));
	for (int i = 0; i < mtl_trn.numslots && !r.bad; i++) {
		int n = MTL_TrnInt(&r);
		if (n < 1 || n > 256)
			return false;
		mtl_trn.slots[i].numentries = n;
		mtl_trn.slots[i].entries = calloc((size_t)n, sizeof(mtl_trnentry_t));
		for (int k = 0; k < n && !r.bad; k++) {
			mtl_trnentry_t *e = &mtl_trn.slots[i].entries[k];
			char name[256];
			MTL_TrnString(&r, name, sizeof(name));
			e->threshold = MTL_TrnFloat(&r);
			e->sdiv = MTL_TrnFloat(&r); e->tdiv = MTL_TrnFloat(&r);
			e->fixs = MTL_TrnFloat(&r); e->fixt = MTL_TrnFloat(&r);
			e->whole = MTL_TrnByte(&r);
			if (!r.bad) e->image = MTL_TrnImage(name);
		}
	}
	return !r.bad;
}

static mtl_trnvert_t *MTL_TrnVert(int row, int col) { return &mtl_trn.verts[row * mtl_trn.numcols + col]; }
static float MTL_TrnDist(const vec3_t a, const vec3_t b)
{
	vec3_t d;
	VectorSubtract(a, b, d);
	return sqrtf(DotProduct(d, d));
}
/* one texture range (s or t) by the rules of SPEC-410 Texture coordinates */
static void MTL_TrnRange(float fixed, byte whole, float divisor, float length, float start, float *r0, float *r1)
{
	float q = divisor != 0 ? length / divisor : 0;
	if (fixed != 0) { *r0 = 0; *r1 = fixed; }
	else if (whole) { *r0 = 0; *r1 = (float)(int)q; }
	else { *r0 = start; *r1 = start + q; }
}
/* generates row `row` at x with the game clock t; prev = the row one spacing behind it (-1: none) */
static void MTL_TrnGenerateRow(int row, float x, int prev, float t)
{
	for (int c = 0; c < mtl_trn.numcols; c++) {
		const mtl_trncolumn_t *col = &mtl_trn.columns[c];
		mtl_trnvert_t *v = MTL_TrnVert(row, c);
		v->pos[0] = x;
		v->pos[1] = MTL_TrnRand(col->ymin, col->ymax) + col->lw[2] * sinf(col->lw[0] * t) +
		            col->lw[3] * sinf(col->lw[1] * t) - mtl_trn.latoffset;
		v->pos[2] = MTL_TrnRand(col->zmin, col->zmax) + col->hw[2] * sinf(col->hw[0] * t) +
		            col->hw[3] * sinf(col->hw[1] * t) - mtl_trn.hgtoffset;
		float rnd = MTL_TrnRand(0, 1);
		v->entry = NULL;
		if (col->slot >= 0 && col->slot < mtl_trn.numslots) {
			const mtl_trnslot_t *s = &mtl_trn.slots[col->slot];
			for (int k = 0; k < s->numentries; k++)
				if (s->entries[k].threshold >= rnd) { v->entry = &s->entries[k]; break; }
		}
		v->bright = 0;
		v->behind = false;
	}
	for (int c = 0; c < mtl_trn.numcols; c++) {
		const mtl_trncolumn_t *col = &mtl_trn.columns[c];
		mtl_trnvert_t *v = MTL_TrnVert(row, c);
		const mtl_trnentry_t *e = v->entry;
		v->s0 = v->s1 = v->t0 = v->t1 = 0;
		if (!e)
			continue;
		float ls = c + 1 < mtl_trn.numcols ? MTL_TrnDist(v->pos, MTL_TrnVert(row, c + 1)->pos) : 0;
		MTL_TrnRange(e->fixs, e->whole, e->sdiv, ls, v->pos[1], &v->s0, &v->s1);
		float lt = prev >= 0 ? MTL_TrnDist(v->pos, MTL_TrnVert(prev, c)->pos) : 0;
		MTL_TrnRange(e->fixt, e->whole, e->tdiv, lt, t, &v->t0, &v->t1);
		if (col->flags & 0x2) {
			float tmp = v->s0; v->s0 = v->s1; v->s1 = tmp;
			tmp = v->t0; v->t0 = v->t1; v->t1 = tmp;
		}
	}
}

static void MTL_TrnPlaceClouds(void)
{
	for (int i = 0; i < MTL_TRN_NUM_CLOUDS; i++) {
		mtl_trncloud_t *cl = &mtl_trn.clouds[i];
		for (;;) {
			int near2000 = 0;
			qboolean reject = false;
			cl->centre[0] = MTL_TrnRand(-MTL_TRN_CLOUD_EXTENT, MTL_TRN_CLOUD_EXTENT);
			cl->centre[1] = MTL_TrnRand(-MTL_TRN_CLOUD_EXTENT, MTL_TRN_CLOUD_EXTENT);
			for (int j = 0; j < i; j++) {
				float dx = mtl_trn.clouds[j].centre[0] - cl->centre[0], dy = mtl_trn.clouds[j].centre[1] - cl->centre[1];
				float dd = sqrtf(dx * dx + dy * dy);
				if (dd < 800) { reject = true; break; }
				if (dd < 2000 && ++near2000 >= 3) { reject = true; break; }
			}
			/* the lateral value is read from the first cloud of the list (SPEC-410 Clouds) */
			if (!reject && fabsf(mtl_trn.clouds[0].centre[1]) > 8191 && MTL_TrnRand(0, 1) < 2.0f / 3.0f)
				reject = true;
			if (!reject)
				break;
		}
		cl->centre[2] = MTL_TrnRand(3000, 5000);
		float h = 2 * MTL_TrnRand(1200, 1800);
		vec3_t d = {MTL_TrnRand(-1, 1), MTL_TrnRand(-1, 1), 0}, p;
		float len = sqrtf(d[0] * d[0] + d[1] * d[1]);
		if (len > 0) { d[0] /= len; d[1] /= len; } else d[0] = 1;
		p[0] = d[1]; p[1] = -d[0]; p[2] = 0;
		static const float ab[4][2] = {{-1, -1}, {-1, 1}, {1, 1}, {1, -1}};
		for (int k = 0; k < 4; k++)
			for (int a = 0; a < 3; a++)
				cl->corner[k][a] = cl->centre[a] + h * (ab[k][0] * d[a] + ab[k][1] * p[a]);
		cl->vel[0] = -400;
		cl->vel[1] = MTL_TrnRand(-40, 40);
		cl->vel[2] = 0;
	}
}

static void MTL_TrnBuild(void)
{
	float t = MTL_GameTime();
	mtl_trn.verts = calloc((size_t)mtl_trn.numrows * (size_t)mtl_trn.numcols, sizeof(mtl_trnvert_t));
	MTL_TrnPlaceClouds();
	for (int i = 0; i < mtl_trn.numrows; i++)
		MTL_TrnGenerateRow(i, (float)(i - mtl_trn.numrows / 2) * mtl_trn.spacing, i - 1, t);
	mtl_trn.rear = 0;
	mtl_trn.cloudimage = MTL_TrnImage("textures/uganda/cloud");
	mtl_trn.built = true;
}

/* SPEC-002 slot 0x38 (map registration and the console command `terrain`) */
static void MTL_SoF_SetTerrain(char *name)
{
	MTL_TerrainFree();
	if (!name || !name[0] || !strcmp(name, "(null)"))
		return;
	char path[MAX_QPATH];
	byte *buf = NULL;
	Com_sprintf(path, sizeof(path), "env/%s.trn", name);
	int len = ri.FS_LoadFile(path, (void **)&buf);
	if (!buf) { Com_Printf("%s isn't a valid terrain set name\n", name); return; }
	if (len < 1 || buf[0] != '"') {
		Com_Printf("Invalid version for Terrain Set %s\n", name);
		ri.FS_FreeFile(buf);
		return;
	}
	if (!MTL_TrnParse(buf, len)) {
		Com_DPrintf("Terrain set %s: bad layout\n", name);
		ri.FS_FreeFile(buf);
		MTL_TerrainFree();
		return;
	}
	ri.FS_FreeFile(buf);
	mtl_trn.loaded = true;
	mtl_trn.prevclock = MTL_GameTime();
	if (mtl_trn.active)
		MTL_TrnBuild();
}

static NSString *const mtl_terrain_msl = @R"MSL(
struct OMTerrainVertex { packed_float3 pos; packed_float2 st; packed_float4 rgba; };
struct OMTerrainVarying { float4 position [[position]]; float2 st; float4 color; };
vertex OMTerrainVarying mtl_vs_terrain(const device OMTerrainVertex *v [[buffer(0)]], uint id [[vertex_id]],
                                       constant float4x4 &mvp [[buffer(1)]]) {
 OMTerrainVarying o; o.position = mvp * float4(float3(v[id].pos), 1); o.st = float2(v[id].st); o.color = float4(v[id].rgba); return o;
}
fragment OMPostOutput mtl_fs_terrain(OMTerrainVarying in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
 float4 c = t.sample(s, in.st) * in.color;
 if (c.a <= 0.0f) discard_fragment();
 return OM_PostDefault(c);
}
)MSL";

static id<MTLRenderPipelineState> MTL_TerrainPipeline(void)
{
	mtl_pipeline_targets_t targets = MTL_PostPipelineTargets();
	id<MTLRenderPipelineState> pipeline = MTL_PostPipelineCached(MTL_POST_PIPE_TERRAIN, 0, 0, &targets);
	if (pipeline)
		return pipeline;
	NSError *error = nil;
	id<MTLLibrary> library = [mtl_device newLibraryWithSource:MTL_PostShaderSource(mtl_terrain_msl, &targets) options:nil error:&error];
	if (!library) { NSLog(@"Metal terrain shader: %@", error); MTL_Fatal("terrain shader", NULL); }
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = [library newFunctionWithName:@"mtl_vs_terrain"];
	d.fragmentFunction = [library newFunctionWithName:@"mtl_fs_terrain"];
	d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	d.colorAttachments[0].blendingEnabled = YES;
	d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
	d.colorAttachments[0].destinationRGBBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	if (!MTL_PostConfigurePipeline(d, &targets))
		MTL_Fatal("terrain targets", NULL);
	pipeline = [mtl_device newRenderPipelineStateWithDescriptor:d error:&error];
	if (!pipeline) { NSLog(@"Metal terrain pipeline: %@", error); MTL_Fatal("terrain pipeline", NULL); }
	MTL_PostPipelineStore(MTL_POST_PIPE_TERRAIN, 0, 0, &targets, pipeline);
	return pipeline;
}

static int MTL_TrnPush(int count, const mtl_trn_gpu_t *q)
{
	if (count + 6 > mtl_trn_batch_cap) {
		int cap = mtl_trn_batch_cap ? mtl_trn_batch_cap * 2 : 8192;
		mtl_trn_gpu_t *grown = realloc(mtl_trn_batch, (size_t)cap * sizeof(*grown));
		if (!grown)
			return count;
		mtl_trn_batch = grown;
		mtl_trn_batch_cap = cap;
	}
	static const int order[6] = {0, 1, 2, 0, 2, 3};
	for (int i = 0; i < 6; i++)
		mtl_trn_batch[count++] = q[order[i]];
	return count;
}
static void MTL_TrnCorner(mtl_trn_gpu_t *o, const mtl_trnvert_t *v, float s, float t)
{
	float b = v->bright;
	VectorCopy(v->pos, o->pos);
	o->st[0] = s; o->st[1] = t;
	o->rgba[0] = 0.46f * b; o->rgba[1] = 0.89f * b; o->rgba[2] = b; o->rgba[3] = 1;
}
static void MTL_TrnDrawRange(id<MTLBuffer> buffer, NSUInteger offset, int first, int count, mtl_image_t *image, const float mvp[16], id<MTLDepthStencilState> depth)
{
	if (count <= 0 || !image || !image->tex)
		return;
	[mtl_enc setRenderPipelineState:MTL_TerrainPipeline()];
	[mtl_enc setDepthStencilState:depth];
	[mtl_enc setCullMode:MTLCullModeNone];
	[mtl_enc setVertexBuffer:buffer offset:offset atIndex:0];
	[mtl_enc setVertexBytes:mvp length:16 * sizeof(float) atIndex:1];
	[mtl_enc setFragmentTexture:(__bridge id<MTLTexture>)image->tex atIndex:0];
	[mtl_enc setFragmentSamplerState:mtl_samp_world atIndex:0];
	[mtl_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(NSUInteger)first vertexCount:(NSUInteger)count];
}

/* draws the landscape and the clouds; called by the world pass after the sky box, as in GL */
static void MTL_TerrainDraw(const float mvp[16])
{
	if (!mtl_trn.loaded || !mtl_trn.active || !mtl_trn.built || !mtl_encoder_open)
		return;
	int n = mtl_trn.numrows, nc = mtl_trn.numcols;
	float clock = MTL_GameTime(), dt = clock - mtl_trn.prevclock;
	mtl_trn.prevclock = clock;
	if (dt < 0) dt = 0; else if (dt > 0.1f) dt = 0.1f;
	if (dt != 0)
		for (int i = 0; i < n * nc; i++)
			mtl_trn.verts[i].pos[0] -= mtl_trn.speed * dt;
	vec3_t forward, right, up;
	float vx = mtl_refdef.vieworg[0], vy = mtl_refdef.vieworg[1];
	AngleVectors(mtl_refdef.viewangles, forward, right, up);
	for (int i = 0; i < n * nc; i++) {
		mtl_trnvert_t *v = &mtl_trn.verts[i];
		float m = 10000 - (fabsf(v->pos[0] - vx) + fabsf(v->pos[1] - vy));
		v->bright = 0.5f * (m > 0 ? m * 0.0001f : 0);
		vec3_t d;
		VectorSubtract(v->pos, mtl_refdef.vieworg, d);
		v->behind = DotProduct(d, forward) < 0;
	}
	/* recycling: at most one row per frame */
	if (MTL_TrnVert(mtl_trn.rear, 0)->pos[0] < vx - (float)n * mtl_trn.spacing / 2) {
		int front = (mtl_trn.rear + n - 1) % n, old = mtl_trn.rear;
		mtl_trn.rear = (mtl_trn.rear + 1) % n;
		MTL_TrnGenerateRow(old, MTL_TrnVert(old, 0)->pos[0] + (float)n * mtl_trn.spacing, front, clock);
	}
	/* the quads, one image at a time */
	mtl_image_t *drawn[64];
	int numdrawn = 0, total = 0, starts[65] = {0};
	for (;;) {
		mtl_image_t *image = NULL;
		for (int row = 0; row < n && !image; row++)
			for (int c = 0; c + 1 < nc; c++) {
				const mtl_trnvert_t *v = MTL_TrnVert(row, c);
				if (!v->entry) continue;
				mtl_image_t *im = v->entry->image;
				int k;
				for (k = 0; k < numdrawn; k++) if (drawn[k] == im) break;
				if (k == numdrawn) { image = im; break; }
			}
		if (!image || numdrawn >= 64)
			break;
		starts[numdrawn] = total;
		drawn[numdrawn++] = image;
		for (int row = 0; row < n; row++) {
			int ahead = (row + 1) % n;
			if (ahead == mtl_trn.rear)
				continue; /* no quad across the seam between the frontmost and the rearmost row */
			for (int c = 0; c + 1 < nc; c++) {
				const mtl_trnvert_t *v = MTL_TrnVert(row, c), *v2 = MTL_TrnVert(row, c + 1),
				                    *v3 = MTL_TrnVert(ahead, c + 1), *v4 = MTL_TrnVert(ahead, c);
				if (!v->entry || v->entry->image != image)
					continue;
				if (v->behind && v2->behind && v3->behind && v4->behind)
					continue;
				mtl_trn_gpu_t q[4];
				MTL_TrnCorner(&q[0], v, v->s0, v->t0);
				MTL_TrnCorner(&q[1], v2, v->s0, v->t1);
				MTL_TrnCorner(&q[2], v3, v->s1, v->t1);
				MTL_TrnCorner(&q[3], v4, v->s1, v->t0);
				total = MTL_TrnPush(total, q);
			}
		}
	}
	starts[numdrawn] = total;
	/* clouds: move, wrap, draw (never fogged, no depth writes) */
	int cloudstart = total;
	for (int i = 0; i < MTL_TRN_NUM_CLOUDS; i++) {
		mtl_trncloud_t *cl = &mtl_trn.clouds[i];
		for (int k = 0; k < 4; k++) {
			VectorMA(cl->corner[k], dt, cl->vel, cl->corner[k]);
			cl->corner[k][2] = 2500 + 1000 * (MTL_TRN_CLOUD_EXTENT - fabsf(cl->corner[k][0])) / MTL_TRN_CLOUD_EXTENT;
		}
		VectorMA(cl->centre, dt, cl->vel, cl->centre);
		for (int a = 0; a < 2; a++) {
			float shift = cl->centre[a] > MTL_TRN_CLOUD_EXTENT ? -MTL_TRN_CLOUD_WRAP : cl->centre[a] < -MTL_TRN_CLOUD_EXTENT ? MTL_TRN_CLOUD_WRAP : 0;
			if (shift != 0) {
				cl->centre[a] += shift;
				for (int k = 0; k < 4; k++) cl->corner[k][a] += shift;
			}
		}
		static const float cst[4][2] = {{0, 0}, {0, 1}, {1, 1}, {1, 0}};
		mtl_trn_gpu_t q[4];
		for (int k = 0; k < 4; k++) {
			VectorCopy(cl->corner[k], q[k].pos);
			q[k].st[0] = cst[k][0]; q[k].st[1] = cst[k][1];
			q[k].rgba[0] = q[k].rgba[1] = q[k].rgba[2] = q[k].rgba[3] = 1;
		}
		total = MTL_TrnPush(total, q);
	}
	if (total <= 0)
		return;
	NSUInteger offset = 0;
	id<MTLBuffer> buffer = MTL_FrameUpload(mtl_trn_batch, (NSUInteger)total * sizeof(*mtl_trn_batch), &offset);
	if (!buffer)
		return;
	for (int i = 0; i < numdrawn; i++)
		MTL_TrnDrawRange(buffer, offset, starts[i], starts[i + 1] - starts[i], drawn[i], mvp, mtl_depth_world);
	MTL_TrnDrawRange(buffer, offset, cloudstart, total - cloudstart, mtl_trn.cloudimage, mvp, mtl_depth_readonly);
}
#endif
