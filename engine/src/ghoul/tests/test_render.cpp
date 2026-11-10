// SPDX-License-Identifier: GPL-2.0-or-later
// OpenMerc Ghoul test program - pose sampling of stock models: draws instances through the Ghoul draw path into
// the software GL table, writes PNG contact sheets, and exports the posed triangles as OBJ and glTF.
// Implements: SPEC-012 sections 4 and 8, SPEC-010 D / SPEC-121 (.gpm skins, parts, bolt-ons) (verification)

#include <algorithm>
#include <cmath>
#include <cstring>
#include <set>

#include "../ghoul_internal.h"
#include "test_common.h"
#include "synth.h"

using namespace ghoul;

void SoftGL_SetCapture(SoftGL *s, bool on);
void SoftGL_Resize(SoftGL *s, int w, int h);
const std::vector<PosedTri> &SoftGL_Captured(SoftGL *s);
bool SoftGL_TextureImage(SoftGL *s, unsigned name, Image &out);

namespace {

float g_ground = 0.0f;

float GroundTrace(const float *start, const float *end)
{
	float dz = start[2] - end[2];
	if (dz <= 0)
		return 1.0f;
	float f = (start[2] - g_ground) / dz;
	return f < 0 ? -1.0f : (f > 1 ? 1.0f : f);
}

struct Params : public GhoulRenderParams
{
	bool BoxOutside(const float (*)[3]) override { return false; }
	Params()
	{
		std::memset((char *)this + sizeof(void *), 0, sizeof(*this) - sizeof(void *));
		lightColor[0] = lightColor[1] = lightColor[2] = 1.0f;
		fogVisibility = 1.0f;
		maxLights = 3;
		useGLLights = 1;
		specular = 1;
		shadowDarkness = 0.75f;
		shadowDist = 25.0f;
		shadowMode = 2;
		worldTrace = GroundTrace;
		MatIdentity(entityToWorld);
	}
};

void LookAt(const Vec3 &eye, const Vec3 &target, float view[16])
{
	Vec3 f = Normalize(target - eye), up(0, 0, 1);
	Vec3 r = Normalize(Cross(f, up));
	Vec3 u = Cross(r, f);
	// column-major, rows r, u, -f
	float m[16] = {r.x, u.x, -f.x, 0, r.y, u.y, -f.y, 0, r.z, u.z, -f.z, 0, -Dot(r, eye), -Dot(u, eye), Dot(f, eye), 1};
	std::memcpy(view, m, sizeof(m));
}

void Perspective(float fovy, float aspect, float n, float fz, float p[16])
{
	float t = 1.0f / std::tan(fovy * 3.14159265f / 360.0f);
	float m[16] = {t / aspect, 0, 0, 0, 0, t, 0, 0, 0, 0, (fz + n) / (n - fz), -1, 0, 0, 2 * fz * n / (n - fz), 0};
	std::memcpy(p, m, sizeof(m));
}

SoftGL *g_gl = nullptr;
bool g_axes = false;
bool g_flag1000 = false;
bool g_hwlights = false; // I4c: ghl_light_method > 2.5 with ghl_gllight_attenuation 1

void RecordNativeDraw(void *, const om_ghoul_native_draw_t *) {}

/* The native sink is an additive host API.  This test catches a missing,
 * partially-installed, or uncleared renderer hand-off without relying on the
 * GL test table.  Triangle emission is tested separately once Task 2 adds the
 * native batch producer. */
void TestNativeSinkInstallation()
{
	om_ghoul_native_sink_t sink = {};
	sink.ctx = &sink;
	sink.draw = RecordNativeDraw;
	OMGhoul_SetNativeSink(&sink);
	CHECK(OMGhoul_HasNativeSink() == 1, "native sink installs");
	OMGhoul_SetNativeSink(nullptr);
	CHECK(OMGhoul_HasNativeSink() == 0, "native sink clears");
}

struct NativeBatchRecord
{
	int batches = 0;
	size_t vertices = 0;
	int blend = -1;
	int cull = -1;
	int depthWrite = -1;
	int textureDeclared = -1;
	int textureListResolved = -1;
	int textureDecoded = -1;
	float firstPosition[3] = {};
	float firstUV[2] = {};
	float firstColour[4] = {};
	float initialColour[4] = {};
	int initialBlend = -1, initialDepthWrite = -1, initialTextureAlpha = -1;
	float modelToWorld[16] = {};
	std::vector<float> bloomSources;
	std::vector<int> specularPasses;
};

/* Missing old-ABI metadata has no source/pass information. Keeping these
 * test-only accessors permits replaying the real pre-change producer/header
 * as a numeric failing baseline, rather than a compile-error-only check. */
template<class T> auto NativeBloomSource(const T *draw,int) -> decltype(draw->bloom_source) { return draw->bloom_source; }
template<class T> float NativeBloomSource(const T *,long) { return 0; }
template<class T> auto NativeSpecularPass(const T *draw,int) -> decltype(draw->specular_pass) { return draw->specular_pass; }
template<class T> int NativeSpecularPass(const T *,long) { return 0; }

void RecordNativeBatch(void *ctx, const om_ghoul_native_draw_t *draw)
{
	NativeBatchRecord *record = static_cast<NativeBatchRecord *>(ctx);
	if (record->batches == 0)
	{
		std::memcpy(record->initialColour, draw->vertices[0].colour, sizeof(record->initialColour));
		record->initialBlend = draw->blend;
		record->initialDepthWrite = draw->depth_write;
		if (draw->texture && draw->texture->rgba) record->initialTextureAlpha = draw->texture->rgba[3];
	}
	record->batches++;
	record->vertices += draw->vertex_count;
	record->blend = draw->blend;
	record->cull = draw->cull;
	record->depthWrite = draw->depth_write;
	record->textureDeclared = draw->texture_declared;
	record->textureListResolved = draw->texture_list_resolved;
	record->textureDecoded = draw->texture_decoded;
	record->bloomSources.push_back(NativeBloomSource(draw,0));
	record->specularPasses.push_back(NativeSpecularPass(draw,0));
	std::memcpy(record->firstPosition, draw->vertices[0].position, sizeof(record->firstPosition));
	std::memcpy(record->firstUV, draw->vertices[0].uv, sizeof(record->firstUV));
	std::memcpy(record->firstColour, draw->vertices[0].colour, sizeof(record->firstColour));
	std::memcpy(record->modelToWorld, draw->model_to_world, sizeof(record->modelToWorld));
}

void TestNativeBatchEmission(IGhoulSystem *cl)
{
	SynModel model;
	model.seqs = {SynSeq{"NATIVE", 100.0f, 0, 3, {}}};
	SynNode mesh;
	mesh.name = "NATIVE_MESH";
	mesh.kind = 1;
	mesh.tx = {0.0f, 4.0f, 8.0f};
	model.nodes = {mesh};
	g_host.overlay["GHOUL/TEST/NATIVE.GHB"] = BuildSynthetic(model);

	IGhoulObject *object = cl->CreateObject();
	GhoulID seq = object->RegisterSequence("ghoul/test/native.ghl", false);
	object->FinishRegistration(false);
	object->Prepare(true);
	IGhoulInst *instance = object->CreateInstance();
	instance->Play(seq, 0.0f, 0.0f, true, 0, false, false);

	NativeBatchRecord first, second;
	om_ghoul_native_sink_t sink = {};
	sink.draw = RecordNativeBatch;
	sink.ctx = &first;
	OMGhoul_SetNativeSink(&sink);
	Params params;
	params.time = 0.0f;
	params.shadowMode = 0;
	instance->Draw(&params);
	sink.ctx = &second;
	OMGhoul_SetNativeSink(&sink);
	params.time = 0.15f;
	params.entityToWorld.m[3][0] = 12.0f;
	params.entityToWorld.flags = 0;
	instance->Draw(&params);
	OMGhoul_SetNativeSink(nullptr);

	CHECK(first.batches == 1 && first.vertices == 6, "native sink emits one six-vertex triangle batch");
	CHECK(first.blend == OM_GHOUL_NATIVE_BLEND_OPAQUE && first.cull == OM_GHOUL_NATIVE_CULL_BACK && first.depthWrite == 1,
		"native batch carries opaque depth/cull state");
	CHECK(std::isfinite(first.firstPosition[0]) && std::isfinite(first.firstColour[0]) && first.firstColour[3] == 1.0f,
		"native batch carries finite posed vertex and final alpha");
	CHECK(first.textureDeclared == 0 && first.textureListResolved == 0 && first.textureDecoded == 0,
		"untextured native batch reports its texture provenance");
	CHECK(std::fabs(second.modelToWorld[12] - first.modelToWorld[12]) > 1.0f,
		"native batch carries changed entity transform (%g -> %g)", first.modelToWorld[12], second.modelToWorld[12]);
	object->Destroy();
}

/* Alpha and additive Ghoul materials are legitimate native draw inputs. The
 * old native bootstrap skipped them because it only had an opaque Metal
 * pipeline, which left effects and material layers missing from the scene. */
void TestNativeBlendedBatchEmission(IGhoulSystem *cl)
{
	SynModel model;
	model.seqs = {SynSeq{"NATIVE_BLEND", 100.0f, 0, 3, {}}};
	SynNode mesh;
	mesh.name = "NATIVE_BLEND_MESH";
	mesh.kind = 1;
	model.nodes = {mesh};
	model.alphaTexture = true;
	model.opacity = 0.5f;
	g_host.overlay["GHOUL/TEST/NATIVE_BLEND.GHB"] = BuildSynthetic(model);

	IGhoulObject *object = cl->CreateObject();
	GhoulID seq = object->RegisterSequence("ghoul/test/native_blend.ghl", false);
	object->FinishRegistration(false);
	object->Prepare(true);
	IGhoulInst *instance = object->CreateInstance();
	instance->Play(seq, 0.0f, 0.0f, true, 0, false, false);

	NativeBatchRecord record;
	om_ghoul_native_sink_t sink = {};
	sink.draw = RecordNativeBatch;
	sink.ctx = &record;
	OMGhoul_SetNativeSink(&sink);
	Params params;
	params.shadowMode = 0;
	instance->Draw(&params);
	OMGhoul_SetNativeSink(nullptr);

	CHECK(record.batches == 1 && record.vertices == 6,
		"native sink emits an alpha-material batch instead of discarding it");
	CHECK(record.blend == OM_GHOUL_NATIVE_BLEND_ALPHA && record.depthWrite == 0,
		"native alpha batch carries source-over blending with read-only depth");
	CHECK(std::fabs(record.firstColour[3] - 0.5f) <= 1e-5f,
		"native alpha batch preserves material opacity (%g)", record.firstColour[3]);
	object->Destroy();
}

void TestNativeAdditiveBatchEmission(IGhoulSystem *cl)
{
	SynModel model;
	model.seqs = {SynSeq{"NATIVE_ADD", 100.0f, 0, 3, {}}};
	SynNode mesh;
	mesh.name = "NATIVE_ADD_MESH";
	mesh.kind = 1;
	model.nodes = {mesh};
	model.blend = 1;
	model.opacity = 0.5f;
	g_host.overlay["GHOUL/TEST/NATIVE_ADD.GHB"] = BuildSynthetic(model);

	IGhoulObject *object = cl->CreateObject();
	GhoulID seq = object->RegisterSequence("ghoul/test/native_add.ghl", false);
	object->FinishRegistration(false);
	object->Prepare(true);
	IGhoulInst *instance = object->CreateInstance();
	instance->Play(seq, 0.0f, 0.0f, true, 0, false, false);

	NativeBatchRecord record;
	om_ghoul_native_sink_t sink = {};
	sink.draw = RecordNativeBatch;
	sink.ctx = &record;
	OMGhoul_SetNativeSink(&sink);
	Params params;
	params.shadowMode = 0;
	params.fogVisibility = 0.4f;
	instance->Draw(&params);
	OMGhoul_SetNativeSink(nullptr);

	CHECK(record.batches == 1 && record.blend == OM_GHOUL_NATIVE_BLEND_ADDITIVE && record.depthWrite == 0,
		"native sink emits additive material with read-only depth");
	/* The native sink now uses the same GL lighting-method ambient (default
	 * LIGHT_AMBIENT 0.6) before additive fog scales the contribution. */
	CHECK(std::fabs(record.firstColour[0] - 0.096f) <= 1e-5f && record.firstColour[3] == 1.0f,
		"native additive batch applies ambient and fog opacity as colour scale (%g, %g)",
		record.firstColour[0], record.firstColour[3]);
	object->Destroy();
}

/* The GL implementation rotates sprite nodes about their local origin toward
 * the viewer. Native Metal consumes posed vertices, so it must receive that
 * same local billboard transform rather than the unrotated quad. */
void TestNativeSpriteBillboard(IGhoulSystem *cl)
{
	SynModel model;
	model.seqs = {SynSeq{"NATIVE_SPRITE", 100.0f, 0, 3, {}}};
	SynNode mesh;
	mesh.name = "NATIVE_SPRITE_MESH";
	mesh.kind = 1;
	mesh.sprite = true;
	model.nodes = {mesh};
	g_host.overlay["GHOUL/TEST/NATIVE_SPRITE.GHB"] = BuildSynthetic(model);

	IGhoulObject *object = cl->CreateObject();
	GhoulID seq = object->RegisterSequence("ghoul/test/native_sprite.ghl", false);
	object->FinishRegistration(false);
	object->Prepare(true);
	IGhoulInst *instance = object->CreateInstance();
	instance->Play(seq, 0.0f, 0.0f, true, 0, false, false);

	NativeBatchRecord record;
	om_ghoul_native_sink_t sink = {};
	sink.draw = RecordNativeBatch;
	sink.ctx = &record;
	OMGhoul_SetNativeSink(&sink);
	Params params;
	params.shadowMode = 0;
	params.viewOrigin[0] = 10.0f;
	params.viewOrigin[1] = 10.0f;
	instance->Draw(&params);
	OMGhoul_SetNativeSink(nullptr);

	CHECK(record.batches == 1 && std::fabs(record.firstPosition[0]) > 0.9f,
		"native sprite batch rotates its local quad toward the viewer (x %g)", record.firstPosition[0]);
	object->Destroy();
}

/* A sprite away from the model origin (every headlight and lamp glow) turns about its OWN node: GL multiplies
 * N, rotation, N-inverse on its stack, so a vertex goes through N-inverse first. The native transform once applied
 * them in the opposite order, which is invisible for a node at the origin and throws the glow far from its lamp. */
void TestNativeSpriteBillboardOffCentre(IGhoulSystem *cl)
{
	const float nodeX = 40.0f, nodeY = 30.0f;
	SynModel model;
	model.seqs = {SynSeq{"NATIVE_SPRITE_OFF", 100.0f, 0, 3, {}}};
	SynNode mesh;
	mesh.name = "NATIVE_SPRITE_OFF_MESH";
	mesh.kind = 1;
	mesh.sprite = true;
	mesh.tx = {nodeX};
	mesh.ty = {nodeY};
	model.nodes = {mesh};
	g_host.overlay["GHOUL/TEST/NATIVE_SPRITE_OFF.GHB"] = BuildSynthetic(model);

	IGhoulObject *object = cl->CreateObject();
	GhoulID seq = object->RegisterSequence("ghoul/test/native_sprite_off.ghl", false);
	object->FinishRegistration(false);
	object->Prepare(true);
	IGhoulInst *instance = object->CreateInstance();
	instance->Play(seq, 0.0f, 0.0f, true, 0, false, false);

	NativeBatchRecord record;
	om_ghoul_native_sink_t sink = {};
	sink.draw = RecordNativeBatch;
	sink.ctx = &record;
	OMGhoul_SetNativeSink(&sink);
	Params params;
	params.shadowMode = 0;
	params.viewOrigin[0] = 10.0f;
	params.viewOrigin[1] = 10.0f;
	instance->Draw(&params);
	OMGhoul_SetNativeSink(nullptr);

	/* the quad's corners are (0, +-1, +-1): turning about the node's Y axis keeps y and the distance from the node */
	const float dx = record.firstPosition[0] - nodeX, dz = record.firstPosition[2];
	const float radius = std::sqrt(dx * dx + dz * dz), expected = std::sqrt(nodeX * nodeX + 1.0f);
	CHECK(record.batches == 1 && std::fabs(std::fabs(record.firstPosition[1]) - 1.0f) < 0.01f &&
		std::fabs(radius - expected) < 0.01f,
		"native sprite away from the origin turns about its own node (y %g, radius %g, expected %g)",
		record.firstPosition[1], radius, expected);
	object->Destroy();
}

/* The Metal path consumes decoded CPU RGBA directly and deliberately installs
 * no GL table. Keep this separate from the software-GL texture tests: a
 * texture declared by a native batch must still decode in that state. */
void TestNativeTextureDecodeWithoutGL()
{
	std::vector<uint8_t> tga(18 + 2 * 2 * 3, 0);
	tga[2] = 2; /* uncompressed true-colour */
	tga[12] = tga[14] = 2;
	tga[16] = 24;
	/* BGR pixels: red, green, blue, white. */
	const uint8_t pixels[] = {0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255};
	std::memcpy(tga.data() + 18, pixels, sizeof(pixels));
	g_host.overlay["GHOUL/TEST/NATIVE_DECODE.TGA"] = tga;
	const GhoulGLTable *saved = G().gl;
	G().gl = nullptr;
	ImageList *list = AcquireImageList("GHOUL/TEST/", "NATIVE_DECODE");
	Texture *texture = ListTexture(list, 0, true);
	CHECK(texture && texture->decoded && texture->width == 2 && texture->height == 2 && texture->rgba.size() == 16,
		"native texture decodes without a GL table");
	ReleaseImageList(list);
	G().gl = saved;
}

/* Implements: SPEC-012 section 8: the texture matrix is part of a material,
 * including its animation and the explicit no-texture-stack bypass. */
void TestNativeTextureMatrix(IGhoulSystem *cl)
{
	SynModel model;
	model.seqs = {SynSeq{"NATIVE_UV", 100.0f, 0, 3, {}}};
	SynNode mesh;
	mesh.name = "NATIVE_UV_MESH";
	mesh.kind = 1;
	model.nodes = {mesh};
	g_host.overlay["GHOUL/TEST/NATIVE_UV.GHB"] = BuildSynthetic(model);
	std::vector<uint8_t> tga(18 + 12, 255);
	std::fill(tga.begin(), tga.begin() + 18, 0);
	tga[2] = 2;
	tga[12] = tga[14] = 2;
	tga[16] = 24;
	g_host.overlay["GHOUL/TEST/NATIVE_UV.TGA"] = tga;
	IGhoulObject *object = cl->CreateObject();
	GhoulID seq = object->RegisterSequence("ghoul/test/native_uv.ghl", false);
	GhbSlot &slot = static_cast<Object *>(object)->files[0]->materials[0].slots[0];
	slot.texture = "NATIVE_UV";
	slot.hasTexture = true;
	slot.staticUV = false;
	Matrix4 transform = MatIdentity();
	transform.m[0][0] = 2.0f;
	transform.m[1][1] = 3.0f;
	transform.m[3][0] = 0.25f;
	transform.m[3][1] = 0.125f;
	transform.flags = 0;
	slot.uv.v = {transform};
	object->FinishRegistration(false);
	object->Prepare(true);
	IGhoulInst *instance = object->CreateInstance();
	instance->Play(seq, 0, 0, true, 0, false, false);
	NativeBatchRecord raw, transformed, animated;
	om_ghoul_native_sink_t sink = {};
	sink.draw = RecordNativeBatch;
	sink.ctx = &raw;
	OMGhoul_SetNativeSink(&sink);
	Params params;
	params.shadowMode = 0;
	params.specular = 0;
	params.noTextureStack = 1;
	instance->Draw(&params);
	params.noTextureStack = 0;
	sink.ctx = &transformed;
	OMGhoul_SetNativeSink(&sink);
	instance->Draw(&params);
	CHECK(transformed.textureDecoded == 1, "native UV fixture resolves its texture");
	CHECK(std::fabs(transformed.firstUV[0] - (raw.firstUV[0] * 2 + 0.25f)) < 1e-5f &&
		std::fabs(transformed.firstUV[1] - (raw.firstUV[1] * 3 + 0.125f)) < 1e-5f,
		"native material applies texture matrix (%g,%g -> %g,%g)",
		raw.firstUV[0], raw.firstUV[1], transformed.firstUV[0], transformed.firstUV[1]);
	slot.uv.constant = false;
	Matrix4 next = transform;
	next.m[3][0] += 2;
	slot.uv.v = {transform, next, next};
	params.time = 0.05f;
	sink.ctx = &animated;
	OMGhoul_SetNativeSink(&sink);
	instance->Draw(&params);
	CHECK(std::fabs(animated.firstUV[0] - transformed.firstUV[0] - 1.0f) < 1e-5f,
		"native material interpolates adjacent texture matrices (%g -> %g)",
		transformed.firstUV[0], animated.firstUV[0]);
	OMGhoul_SetNativeSink(nullptr);
	object->Destroy();
}

void TestNativeSpecularConfiguration(IGhoulSystem *cl)
{
	OMGhoul_SetSpecular(cl, 0);
	SynModel model;
	model.seqs = {SynSeq{"NATIVE_SPEC", 100, 0, 3, {}}};
	SynNode mesh;
	mesh.name = "NATIVE_SPEC_MESH";
	mesh.kind = 1;
	model.nodes = {mesh};
	g_host.overlay["GHOUL/TEST/NATIVE_SPEC.GHB"] = BuildSynthetic(model);
	IGhoulObject *object = cl->CreateObject();
	GhoulID seq = object->RegisterSequence("ghoul/test/native_spec.ghl", false);
	GhbMaterial &material = static_cast<Object *>(object)->files[0]->materials[0];
	material.gloss.v = {0.25f};
	material.specLevel.v = {1.0f};
	object->FinishRegistration(false);
	object->Prepare(false);
	IGhoulInst *instance = object->CreateInstance();
	instance->Play(seq, 0, 0, true, 0, false, false);
	Params params;
	params.shadowMode = 0;
	params.dirValid = 1;
	/* The synthetic quad lies in YZ and faces +X. */
	params.viewOrigin[0] = 10;
	params.lightDir[0] = 500;
	NativeBatchRecord disabled, enabled, disabledAgain;
	om_ghoul_native_sink_t sink = {};
	sink.draw = RecordNativeBatch;
	sink.ctx = &disabled;
	OMGhoul_SetNativeSink(&sink);
	instance->Draw(&params);
	OMGhoul_SetSpecular(cl, 1);
	sink.ctx = &enabled;
	OMGhoul_SetNativeSink(&sink);
	instance->Draw(&params);
	OMGhoul_SetSpecular(cl, 0);
	sink.ctx = &disabledAgain;
	OMGhoul_SetNativeSink(&sink);
	instance->Draw(&params);
	CHECK(disabled.batches == 1 && disabledAgain.batches == 1,
		"native system specular disable removes the second pass");
	CHECK(enabled.batches == 2 && enabled.blend == OM_GHOUL_NATIVE_BLEND_ADDITIVE &&
		enabled.depthWrite == 0 && enabled.firstColour[0] > 0.05f,
		"native system specular enable prepares a visible additive material pass");
	OMGhoul_SetNativeSink(nullptr);
	object->Destroy();
	OMGhoul_SetSpecular(cl, 1);
}

void TestNativeHardwareSpecular(IGhoulSystem *cl)
{
	SynModel model;
	model.seqs = {SynSeq{"NATIVE_HW_SPEC",100,0,3,{}}};
	SynNode mesh;
	mesh.name="NATIVE_HW_SPEC_MESH"; mesh.kind=1; model.nodes={mesh};
	g_host.overlay["GHOUL/TEST/NATIVE_HW_SPEC.GHB"]=BuildSynthetic(model);
	IGhoulObject *object=cl->CreateObject();
	GhoulID seq=object->RegisterSequence("ghoul/test/native_hw_spec.ghl",false);
	GhbMaterial &material=static_cast<Object *>(object)->files[0]->materials[0];
	material.diffuse.v={Vec3(1,1,1)};
	material.gloss.v={0.25f}; material.specLevel.v={1.0f};
	object->FinishRegistration(false); object->Prepare(true);
	IGhoulInst *instance=object->CreateInstance();
	instance->Play(seq,0,0,true,0,false,false);
	cl->BeginWorldLights();
	LightRecord light={{10,-1,-1},20,{1,1,1}};
	cl->AddWorldLight(&light); cl->FinishWorldLights();
	Params params;
	params.shadowMode=0; params.hardwareLights=1; params.glAttenuation=1;
	params.lightColor[0]=params.lightColor[1]=params.lightColor[2]=0;
	params.viewOrigin[0]=10; params.viewOrigin[1]=params.viewOrigin[2]=-1;
	params.viewForward[0]=-1;
	NativeBatchRecord record;
	om_ghoul_native_sink_t sink={}; sink.draw=RecordNativeBatch; sink.ctx=&record;
	OMGhoul_SetNativeSink(&sink);
	instance->Draw(&params);
	/* First corner is (0,-1,-1), N=+X; viewer and point light are aligned
	 * at distance 10 with radius 20. Hardware diffuse and specular each
	 * contribute (1-.6)/(1+10/20), combined before clamping. */
	CHECK(record.batches==1 && std::fabs(record.firstColour[0]-0.5333333f)<1e-5f,
		"native hardware combines attenuated diffuse/specular (%d batches, red %g)",
		record.batches,record.firstColour[0]);
	params.viewOrigin[0]=-10;
	sink.hardware_local_viewer=1;
	OMGhoul_SetNativeSink(&sink); record=NativeBatchRecord{};
	instance->Draw(&params);
	CHECK(record.batches==1 && std::fabs(record.firstColour[0]-0.2666667f)<1e-5f,
		"native local viewer changes the hardware half vector (red %g)",record.firstColour[0]);
	params.viewOrigin[0]=10; sink.hardware_local_viewer=0;
	OMGhoul_SetNativeSink(&sink); record=NativeBatchRecord{};
	params.entityToWorld.m[0][0]=2; params.entityToWorld.flags=0;
	instance->Draw(&params);
	CHECK(record.batches==1 && std::fabs(record.firstColour[0]-0.1333333f)<1e-5f,
		"native hardware uses the unnormalised inverse-transpose normal (red %g)",record.firstColour[0]);
	MatIdentity(params.entityToWorld);
	std::vector<uint8_t> map(18+16,0);
	map[2]=2; map[12]=map[14]=2; map[16]=32;
	for(int i=0;i<4;i++) map[18+i*4]=map[19+i*4]=map[20+i*4]=255;
	g_host.overlay["GHOUL/TEST/NATIVE_HW_MAP.TGA"]=map;
	material.slots[1].texture="NATIVE_HW_MAP"; material.slots[1].hasTexture=true;
	object->Prepare(true); record=NativeBatchRecord{};
	instance->Draw(&params);
	CHECK(record.batches==2 && record.initialBlend==OM_GHOUL_NATIVE_BLEND_OPAQUE &&
		record.initialDepthWrite==1 && record.blend==OM_GHOUL_NATIVE_BLEND_ADDITIVE && record.depthWrite==0,
		"native hardware specular map precedes additive base (%d batches)",record.batches);
	CHECK(record.initialTextureAlpha==0 && std::fabs(record.initialColour[0]-0.2666667f)<1e-5f &&
		std::fabs(record.firstColour[0]-0.2666667f)<1e-5f,
		"native hardware map/base carry separate attenuated terms (%g/%g)",
		record.initialColour[0],record.firstColour[0]);
	OMGhoul_SetNativeSink(nullptr);
	object->Destroy(); cl->BeginWorldLights(); cl->FinishWorldLights();
}

void TestNativeBloomProvenance(IGhoulSystem *cl)
{
	SynModel model;
	model.seqs={SynSeq{"NATIVE_BLOOM",100,0,3,{}}};
	SynNode mesh;mesh.name="NATIVE_BLOOM_MESH";mesh.kind=1;model.nodes={mesh};
	g_host.overlay["GHOUL/TEST/NATIVE_BLOOM.GHB"]=BuildSynthetic(model);
	IGhoulObject *object=cl->CreateObject();
	GhoulID seq=object->RegisterSequence("ghoul/test/native_bloom.ghl",false);
	GhbMaterial &material=static_cast<Object *>(object)->files[0]->materials[0];
	object->FinishRegistration(false);object->Prepare(true);
	IGhoulInst *instance=object->CreateInstance();instance->Play(seq,0,0,true,0,false,false);
	Params params;params.shadowMode=0;params.specular=0;
	NativeBatchRecord record;om_ghoul_native_sink_t sink={};sink.draw=RecordNativeBatch;sink.ctx=&record;
	OMGhoul_SetNativeSink(&sink);
	for(float source:{0.49f,0.5f,0.8f}) {
		material.selfIllum.v={source};record=NativeBatchRecord{};instance->Draw(&params);
		CHECK(record.batches==1 && std::fabs(record.bloomSources[0]-source)<1e-6f && record.specularPasses[0]==0,
			"native base batch preserves unthresholded self-illumination source %g",source);
	}
	material.blend=1;material.selfIllum.v={0.1f};record=NativeBatchRecord{};instance->Draw(&params);
	CHECK(record.batches==1 && record.bloomSources[0]==1 && record.specularPasses[0]==0,
		"native additive material source is one independent of final brightness");
	material.blend=0;material.selfIllum.v={0.6f};material.gloss.v={0.25f};material.specLevel.v={1.0f};
	params.specular=1;params.dirValid=1;params.viewOrigin[0]=10;params.lightDir[0]=500;
	OMGhoul_SetSpecular(cl,1);object->Prepare(true);record=NativeBatchRecord{};instance->Draw(&params);
	CHECK(record.batches==2 && std::fabs(record.bloomSources[0]-.6f)<1e-6f && record.specularPasses[0]==0 &&
		record.bloomSources[1]==0 && record.specularPasses[1]==1,
		"native software specular second pass is excluded while base retains material source");
	std::vector<uint8_t> map(18+16,0);map[2]=2;map[12]=map[14]=2;map[16]=32;
	for(int i=0;i<4;i++)map[18+i*4]=map[19+i*4]=map[20+i*4]=255;
	g_host.overlay["GHOUL/TEST/NATIVE_BLOOM_MAP.TGA"]=map;
	material.slots[1].texture="NATIVE_BLOOM_MAP";material.slots[1].hasTexture=true;
	params.hardwareLights=1;params.glAttenuation=1;object->Prepare(true);record=NativeBatchRecord{};instance->Draw(&params);
	CHECK(record.batches==2 && record.bloomSources[0]==0 && record.specularPasses[0]==1 &&
		std::fabs(record.bloomSources[1]-.6f)<1e-6f && record.specularPasses[1]==0,
		"native hardware specular first pass is excluded while additive base retains source");
	material.slots[1].hasTexture=false;material.slots[1].texture.clear();object->Prepare(true);
	record=NativeBatchRecord{};instance->Draw(&params);
	CHECK(record.batches==1 && std::fabs(record.bloomSources[0]-.6f)<1e-6f && record.specularPasses[0]==0,
		"combined hardware specular remains a material base pass");
	OMGhoul_SetNativeSink(nullptr);object->Destroy();
}

void TestNativeHardwareBillboard(IGhoulSystem *cl)
{
	SynModel model;
	model.seqs={SynSeq{"NATIVE_HW_SPRITE",100,0,3,{}}};
	SynNode mesh; mesh.name="NATIVE_HW_SPRITE_MESH"; mesh.kind=1; model.nodes={mesh};
	g_host.overlay["GHOUL/TEST/NATIVE_HW_SPRITE.GHB"]=BuildSynthetic(model);
	IGhoulObject *object=cl->CreateObject();
	GhoulID seq=object->RegisterSequence("ghoul/test/native_hw_sprite.ghl",false);
	GhbFile *file=static_cast<Object *>(object)->files[0];
	file->nodes[0].sprite=true; file->materials[0].diffuse.v={Vec3(1,1,1)};
	object->FinishRegistration(false); object->Prepare(true);
	IGhoulInst *instance=object->CreateInstance(); instance->Play(seq,0,0,true,0,false,false);
	cl->BeginWorldLights();
	LightRecord light={{-1,-1,-10},20,{1,1,1}};
	cl->AddWorldLight(&light); cl->FinishWorldLights();
	Params params; params.shadowMode=0; params.hardwareLights=1; params.glAttenuation=1;
	params.lightColor[0]=params.lightColor[1]=params.lightColor[2]=0;
	params.viewOrigin[0]=10; params.viewForward[0]=-1;
	NativeBatchRecord record; om_ghoul_native_sink_t sink={};
	sink.draw=RecordNativeBatch; sink.ctx=&record; OMGhoul_SetNativeSink(&sink);
	instance->Draw(&params);
	/* The sprite rotates its +X normal to -Z and its first corner to
	 * (-1,-1,0). The independently installed light remains ten units below. */
	CHECK(std::fabs(record.firstPosition[0]+1)<1e-5f && std::fabs(record.firstPosition[2])<1e-5f,
		"hardware-lit billboard fixture rotates the geometry");
	CHECK(record.batches==1 && std::fabs(record.firstColour[0]-0.2666667f)<1e-5f,
		"billboard rotates geometry without rotating its hardware light (red %g)",record.firstColour[0]);
	OMGhoul_SetNativeSink(nullptr); object->Destroy();
	cl->BeginWorldLights(); cl->FinishWorldLights();
}

void Blit(Image &dst, const Image &src, int x0, int y0)
{
	for (int y = 0; y < src.h && y + y0 < dst.h; y++)
		std::memcpy(&dst.rgb[((size_t)(y + y0) * dst.w + x0) * 3], &src.rgb[(size_t)y * src.w * 3], (size_t)src.w * 3);
}

// draw one instance; returns triangles drawn
int DrawInto(IGhoulInst *in, float t, const Vec3 &eye, const Vec3 &target, Image &out, bool ground, float fov = 40.0f)
{
	float view[16], proj[16];
	LookAt(eye, target, view);
	Perspective(fov, (float)out.w / out.h, 1.0f, 5000.0f, proj);
	SoftGL_Resize(g_gl, out.w, out.h);
	uint8_t clear[3] = {72, 84, 104};
	SoftGL_Begin(g_gl, view, proj, clear);
	const GhoulGLTable *g = SoftGL_Table();
	if (ground)
	{
		// a grey floor at z = g_ground so the projected shadow is visible
		g->Disable(0x0DE1);
		g->Disable(0x0B44);
		g->Color4f(0.55f, 0.55f, 0.5f, 1);
		g->Begin(4);
		float s = 400;
		float q[6][2] = {{-s, -s}, {s, -s}, {s, s}, {-s, -s}, {s, s}, {-s, s}};
		for (auto &v : q)
			g->Vertex3f(target.x + v[0], target.y + v[1], g_ground);
		g->End();
		g->Enable(0x0DE1);
		g->Enable(0x0B44);
	}
	Params P;
	P.time = t;
	P.entityFlag1000 = g_flag1000 ? 1 : 0;
	P.hardwareLights = g_hwlights ? 1 : 0;
	P.glAttenuation = g_hwlights ? 1 : 0;
	eye.Store(P.viewOrigin);
	Normalize(target - eye).Store(P.viewForward);
	P.origin[0] = P.origin[1] = 0;
	P.origin[2] = 0;
	in->Draw(&P);
	if (g_axes)
	{
		// axis markers at the model origin: X red, Y green, Z blue (40 units)
		g->Disable(0x0DE1);
		g->Disable(0x0B44);
		g->Disable(0x0B71);
		float cols[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
		for (int a = 0; a < 3; a++)
		{
			g->Color4f(cols[a][0], cols[a][1], cols[a][2], 1);
			g->Begin(4);
			float p0[3] = {0, 0, 0}, p1[3] = {0, 0, 0}, p2[3] = {0, 0, 0};
			p1[a] = 40;
			p2[a] = 40;
			p2[(a + 1) % 3] = 1.5f;
			p0[(a + 2) % 3] = 1.5f;
			g->Vertex3f(p0[0], p0[1], p0[2]);
			g->Vertex3f(p1[0], p1[1], p1[2]);
			g->Vertex3f(p2[0], p2[1], p2[2]);
			g->End();
		}
		g->Enable(0x0DE1);
		g->Enable(0x0B44);
		g->Enable(0x0B71);
	}
	out = SoftGL_Image(g_gl);
	return SoftGL_Triangles(g_gl);
}

// world-space triangles of the posed instance (view = identity)
std::vector<PosedTri> Capture(IGhoulInst *in, float t)
{
	float id[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
	uint8_t c[3] = {0, 0, 0};
	Image keep = SoftGL_Image(g_gl);
	SoftGL_Begin(g_gl, id, id, c);
	SoftGL_SetCapture(g_gl, true);
	Params P;
	P.time = t;
	P.shadowMode = 0;
	in->Draw(&P);
	SoftGL_SetCapture(g_gl, false);
	return SoftGL_Captured(g_gl);
}

void Export(const std::string &stem, const std::vector<PosedTri> &tris)
{
	WriteOBJ(stem + ".obj", tris);
	WriteGLTF(stem + ".gltf", tris);
	std::set<int> mats;
	for (auto &t : tris)
		mats.insert(t.material);
	std::string base = stem.substr(stem.find_last_of("/\\") + 1);
	for (int m : mats)
	{
		Image img;
		if (m && SoftGL_TextureImage(g_gl, (unsigned)m, img))
			WritePNG(stem + "_tex" + std::to_string(m) + ".png", img);
	}
}

// a player model from a .gpm (or .gbm): object, skins, parts, bolt-ons
struct Built
{
	IGhoulObject *obj = nullptr;
	IGhoulInst *inst = nullptr;
	std::vector<IGhoulObject *> extra;
	std::string dir;
};

Built BuildPlayer(IGhoulSystem *sys, const std::string &gpm, bool menuModel)
{
	Built b;
	IGhoulPlayerModel *pm = (IGhoulPlayerModel *)OMGhoul_NewPlayerModel(gpm.c_str());
	if (!pm->IsLoaded())
	{
		pm->Destroy(1);
		return b;
	}
	b.dir = pm->GetModelDir();
	std::string base = pm->GetBaseModel();
	std::string menu = pm->GetMenuSequence();
	b.obj = sys->CreateObject();
	if (menuModel || base.empty())
		b.obj->RegisterSequence(menu.c_str(), false);
	else
		b.obj->RegisterSequence(("ghoul/" + b.dir + "/" + base + ".ghl").c_str(), false);
	OMGhoul_RegisterList(b.dir.c_str(), pm->GetSequenceList(), b.obj);
	b.obj->FinishRegistration(false);
	std::vector<std::pair<int, std::pair<int, int>>> skins;
	for (int i = 1; i <= pm->NumSkins(); i++)
	{
		PlayerSkinEntry e;
		pm->GetSkinEntry(i, &e);
		GhoulID m = b.obj->FindMaterial(e.material);
		GhoulID s = m ? b.obj->RegisterSkin(m, e.skin, 0) : 0;
		GhoulID part = e.part[0] ? b.obj->FindPart(e.part) : 0;
		if (m && s)
			skins.push_back(std::make_pair((int)m, std::make_pair((int)s, (int)part)));
	}
	b.obj->Prepare(true);
	b.inst = b.obj->CreateInstance();
	for (auto &s : skins)
		b.inst->SetSkin((GhoulID)s.first, (GhoulID)s.second.first, (GhoulID)s.second.second);
	OMGhoul_PartsOff(b.dir.c_str(), (std::string(pm->GetSequenceList()) + "_poff").c_str(), b.obj, b.inst);
	for (int i = 1; i <= pm->NumPartSwitches(); i++)
	{
		PlayerPartEntry e;
		pm->GetPartEntry(i, &e);
		GhoulID part = b.obj->FindPart(e.part);
		if (part)
			b.inst->SetPartOnOff(part, e.shown != 0);
	}
	for (int i = 1; i <= pm->NumBoltons(); i++)
	{
		PlayerBoltonEntry e;
		pm->GetBoltonEntry(i, &e);
		Built c = BuildPlayer(sys, e.file, true);
		if (!c.obj)
			continue;
		b.extra.push_back(c.obj);
		for (auto *x : c.extra)
			b.extra.push_back(x);
		c.inst->Play(1, 0.0f, 0.0f, true, 0, false, false);
		if (e.scale != 1.0f && e.scale > 0)
		{
			Matrix4 m;
			MatIdentity(m);
			m.m[0][0] = m.m[1][1] = m.m[2][2] = e.scale;
			m.flags = 0;
			c.inst->SetTransform(&m);
		}
		b.inst->AttachChild(b.obj->FindPart(e.bolt), c.inst, c.obj->FindPart(e.boltonBolt));
	}
	pm->Destroy(1);
	return b;
}

void Destroy(Built &b)
{
	if (b.obj)
		b.obj->Destroy();
	for (auto *x : b.extra)
		x->Destroy();
	b = Built();
}

// contact sheet: one cell per sample time
struct Sheet
{
	Image img;
	int cw, ch, cols, n = 0;
	Sheet(int cells, int cellW, int cellH, int c) : cw(cellW), ch(cellH), cols(c)
	{
		int rows = (cells + c - 1) / c;
		img.Init(cellW * c, cellH * rows, 0, 0, 0);
	}
	void Add(const Image &cell)
	{
		Blit(img, cell, (n % cols) * cw, (n / cols) * ch);
		n++;
	}
};

struct Framing
{
	Vec3 eye, target;
};

std::vector<PosedTri> Capture(IGhoulInst *in, float t);

// frame the camera on the posed triangles at time t
Framing Frame(IGhoulInst *in, float t, const Vec3 &dir, float zoom, float &minZ)
{
	std::vector<PosedTri> tris = Capture(in, t);
	Vec3 mn(1e30f, 1e30f, 1e30f), mx(-1e30f, -1e30f, -1e30f);
	for (auto &tr : tris)
		for (int k = 0; k < 3; k++)
			for (int a = 0; a < 3; a++)
			{
				mn[a] = std::min(mn[a], tr.p[k][a]);
				mx[a] = std::max(mx[a], tr.p[k][a]);
			}
	if (tris.empty())
		mn = mx = Vec3();
	Vec3 c = (mn + mx) * 0.5f;
	float ext = std::max(mx[0] - mn[0], std::max(mx[1] - mn[1], mx[2] - mn[2]));
	Framing f;
	f.target = c;
	f.eye = c + Normalize(dir) * (ext * 1.45f / zoom + 2.0f);
	minZ = mn[2];
	return f;
}

int g_cells = 0, g_exports = 0;
std::string g_out;

// render 'seq' of 'in' at n evenly spaced times; returns triangles of the first pose
bool g_eyeView = false; // first-person: camera at the model origin looking along -Y (stock in-view models face -Y)

int SampleSequence(const std::string &name, IGhoulObject *o, IGhoulInst *in, GhoulID seq, int n, const Vec3 &viewDir,
	bool ground, int cellW = 256, int cellH = 320, float zoom = 1.0f, bool exportFirst = true)
{
	float d = in->SequenceDuration(seq, 0, nullptr);
	in->Play(seq, 0.0f, 0.0f, true, 0, false, false);
	Sheet sheet(n, cellW, cellH, std::min(n, 4));
	int tris0 = 0;
	float minZ = 0;
	Framing fr = Frame(in, 0.0f, viewDir, zoom, minZ);
	g_ground = ground ? minZ : fr.target.z - 1000.0f;
	if (g_eyeView)
	{
		fr.eye = Vec3(0, 0, 0);
		fr.target = Vec3(0, -100, 0);
	}
	for (int k = 0; k < n; k++)
	{
		float t = n > 1 ? d * k / n : 0.0f;
		Image cell;
		cell.Init(cellW, cellH, 0, 0, 0);
		int tris = DrawInto(in, t, fr.eye, fr.target, cell, ground, g_eyeView ? 75.0f : 40.0f);
		if (k == 0)
			tris0 = tris;
		sheet.Add(cell);
		g_cells++;
		if (k == 0 && exportFirst)
		{
			Export(g_out + "/" + name + "_f0", Capture(in, t));
			g_exports++;
		}
	}
	WritePNG(g_out + "/" + name + ".png", sheet.img);
	(void)o;
	return tris0;
}

} // namespace

void RunRenderTests(const std::string &outDir, bool quick)
{
	std::printf("== pose sampling, drawing and exports (SPEC-012 sections 4, 8) -> %s\n", outDir.c_str());
	g_out = outDir;
	IGhoulSystem *cl = (IGhoulSystem *)OMGhoul_GetSystem(OM_GHOUL_CLIENT);
	cl->Reset();
	g_gl = SoftGL_Create(256, 320);
	unsigned char gamma[256];
	for (int i = 0; i < 256; i++)
		gamma[i] = (unsigned char)i;
	cl->SetGamma(gamma);
	cl->SetGLTable(SoftGL_Table());
	cl->SetSpecular(true);
	TestNativeSinkInstallation();
	TestNativeBatchEmission(cl);
	TestNativeBlendedBatchEmission(cl);
	TestNativeAdditiveBatchEmission(cl);
	TestNativeSpriteBillboard(cl);
	TestNativeSpriteBillboardOffCentre(cl);
	TestNativeTextureDecodeWithoutGL();
	TestNativeTextureMatrix(cl);
	TestNativeSpecularConfiguration(cl);
	TestNativeHardwareSpecular(cl);
	TestNativeBloomProvenance(cl);
	TestNativeHardwareBillboard(cl);
	cl->BeginWorldLights();
	LightRecord l = {{80, -60, 90}, 400, {1.0f, 0.95f, 0.85f}};
	cl->AddWorldLight(&l);
	LightRecord l2 = {{-60, 80, 40}, 300, {0.35f, 0.4f, 0.55f}};
	cl->AddWorldLight(&l2);
	cl->FinishWorldLights();

	// 1. characters from .gpm files, with skins, part switches and the menu weapon bolt-on
	struct Ch
	{
		const char *gpm;
		const char *seqs[3];
	} chars[] = {
		{"Dekker.gpm", {"std_ialert_n_p_n", "std_lrun_fwd_l_2", "std_ddeathfwd_n_a_n"}},
		{"Princess.gpm", {"std_ialert_n_p_n", "std_lrun_fwd_l_2", nullptr}},
		{"Amu.gpm", {"std_ialert_n_p_n", nullptr, nullptr}},
	};
	for (auto &c : chars)
	{
		Built b = BuildPlayer(cl, c.gpm, false);
		if (!g_haveData)
		{
			std::printf("SKIP: player model %s needs the game data\n", c.gpm);
			continue;
		}
		CHECK(b.obj && b.obj->NumSequences() > 0, "player model %s", c.gpm);
		if (!b.obj)
			continue;
		int any = 0;
		if (!std::strcmp(c.gpm, "Dekker.gpm"))
		{
			GhoulID seq = b.obj->FindSequence("ghoul/enemy/meso/std_ialert_n_p_n.ghl");
			if (seq)
			{
				b.inst->Play(seq, 0.0f, 0.0f, true, 0, false, false);
				Vec3 views[4] = {Vec3(1, 0, 0.15f), Vec3(0, -1, 0.15f), Vec3(-1, 0, 0.15f), Vec3(0.05f, 0.0f, 1)};
				Sheet sheet(4, 256, 320, 4);
				g_axes = true;
				for (auto &v : views)
				{
					float minZ;
					Framing fr = Frame(b.inst, 0.0f, v, 1.0f, minZ);
					g_ground = minZ;
					Image cell;
					cell.Init(256, 320, 0, 0, 0);
					DrawInto(b.inst, 0.0f, fr.eye, fr.target, cell, false);
					sheet.Add(cell);
				}
				g_axes = false;
				WritePNG(g_out + "/Dekker_orientation_views_px_my_mx_top.png", sheet.img);

				// I4c, SPEC-AMEND-005 I4b.5: with hardware lights and GL attenuation the world lights of radius
				// 400 and 300 get GL_LINEAR_ATTENUATION 1/400 and 1/300 (not 0.75/R)
				{
					float minZ;
					Framing fr = Frame(b.inst, 0.0f, views[0], 1.0f, minZ);
					Image cell;
					cell.Init(256, 320, 0, 0, 0);
					SoftGL_TakeLinearAttenuations();
					g_hwlights = true;
					DrawInto(b.inst, 0.0f, fr.eye, fr.target, cell, false);
					g_hwlights = false;
					std::vector<float> att = SoftGL_TakeLinearAttenuations();
					bool r300 = false, r400 = false, old = false;
					for (float a : att)
					{
						r300 = r300 || std::fabs(a - 1.0f / 300.0f) < 1e-7f;
						r400 = r400 || std::fabs(a - 1.0f / 400.0f) < 1e-7f;
						// the old 0.75/R: 0.0025 for R = 300 (equal to the new 1/400) and 0.001875 for R = 400
						old = old || std::fabs(a - 0.75f / 400.0f) < 1e-7f;
					}
					for (float a : att)
						std::printf("   GL_LINEAR_ATTENUATION %g (1/%g)\n", a, a != 0 ? 1.0f / a : 0.0f);
					CHECK(r300 && r400 && !old, "world-light GL attenuation 1/R (%d values)", (int)att.size());
				}
			}
		}
		for (const char *s : c.seqs)
		{
			if (!s || (quick && any))
				continue;
			GhoulID seq = b.obj->FindSequence(("ghoul/" + b.dir + "/" + s + ".ghl").c_str());
			if (!seq)
			{
				std::printf("   %s: sequence %s not present\n", c.gpm, s);
				continue;
			}
			std::string name = std::string(c.gpm).substr(0, std::strlen(c.gpm) - 4) + "_" + s;
			int tris = SampleSequence(name, b.obj, b.inst, seq, 8, Vec3(1.0f, -0.6f, 0.35f), true);
			CHECK(tris > 300, "%s: %d triangles", name.c_str(), tris);
			std::printf("   %s: %d triangles, %d bolt-ons\n", name.c_str(), tris, b.inst->NumChildren());
			any++;
		}
		Destroy(b);
	}

	// 2. first-person weapon (in view space), reload sequence
	{
		IGhoulObject *w = cl->CreateObject();
		OMGhoul_RegisterList("weapon/inview/pistol1", "pistol1", w);
		w->FinishRegistration(true);
		w->Prepare(true);
		IGhoulInst *in = w->CreateInstance();
		GhoulID seq = w->FindSequence("ghoul/weapon/inview/pistol1/reload_a.ghl");
		if (seq)
		{
			g_eyeView = true;
			int tris = SampleSequence("pistol1_reload_a", w, in, seq, 8, Vec3(-1.0f, 0.3f, 0.25f), false, 320, 240);
			GhoulID fire = w->FindSequence("ghoul/weapon/inview/pistol1/fire1_a.ghl");
			if (fire)
				SampleSequence("pistol1_fire1_a", w, in, fire, 4, Vec3(-1.0f, 0.3f, 0.25f), false, 320, 240, 1.0f, false);
			g_eyeView = false;
			CHECK(tris > 100, "pistol1 triangles %d", tris);
		}
		w->Destroy();
	}

	// 3. objects: static, int16-animated, chunk-animated, rigid arm, blinking material, model lights
	struct Ob
	{
		const char *dir, *list, *name;
		Vec3 view;
	} obs[] = {
		{"objects/generic/trashcan_barrel", "trashcan", "trashcan", Vec3(1, -0.7f, 0.6f)},
		{"enemy/chopper", "rotor_start", "rotor_start", Vec3(0.6f, -0.6f, 1.0f)},
		{"objects/bosnia/searchlight", "arm", "searchlight_arm", Vec3(1, -1, 0.5f)},
		{"objects/light/emergency", "emergency", "emergency", Vec3(1, -0.5f, 0.5f)},
		{"enemy/chopper", "nav_lite", "nav_lite", Vec3(1, -0.5f, 0.5f)},
		{"enemy/bolt", "w_assault_rifle", "w_assault_rifle", Vec3(0.3f, -1, 0.4f)},
	};
	for (auto &ob : obs)
	{
		IGhoulObject *o = cl->CreateObject();
		OMGhoul_RegisterList(ob.dir, ob.list, o);
		if (!o->NumSequences())
		{
			std::printf("   %s: no sequences\n", ob.name);
			o->Destroy();
			continue;
		}
		o->FinishRegistration(true);
		o->Prepare(true);
		IGhoulInst *in = o->CreateInstance();
		cl->ClearLights();
		int tris = SampleSequence(ob.name, o, in, 1, quick ? 2 : 8, ob.view, false);
		CHECK(tris > 0, "%s triangles %d", ob.name, tris);
		std::printf("   %s: %d sequences, %d triangles, model lights exported %d\n", ob.name, o->NumSequences(), tris,
			cl->ModelLightCount());
		o->Destroy();
	}

	// billboards: the candle's SPRITEBALL flame and flash face the camera from every side
	{
		IGhoulObject *o = cl->CreateObject();
		OMGhoul_RegisterList("objects/light/candle", "candle", o);
		if (o->NumSequences())
		{
			o->FinishRegistration(true);
			o->Prepare(true);
			IGhoulInst *in = o->CreateInstance();
			in->Play(1, 0.0f, 0.0f, true, 0, false, false);
			Vec3 views[4] = {Vec3(1, 0, 0.3f), Vec3(0, -1, 0.3f), Vec3(-1, 0.3f, 0.3f), Vec3(0.2f, 0.1f, 1)};
			Sheet sheet(4, 200, 200, 4);
			for (auto &v : views)
			{
				float minZ;
				Framing fr = Frame(in, 0.0f, v, 1.0f, minZ);
				Image cell;
				cell.Init(200, 200, 0, 0, 0);
				DrawInto(in, 0.0f, fr.eye, fr.target, cell, false);
				sheet.Add(cell);
			}
			WritePNG(g_out + "/candle_billboards_4views.png", sheet.img);
		}
		o->Destroy();
	}
	// SPEC-012 vector 12: a non-character model casts a shadow only with entity flag 0x1000
	{
		IGhoulObject *o = cl->CreateObject();
		OMGhoul_RegisterList("objects/generic/trashcan_barrel", "trashcan", o);
		o->FinishRegistration(false);
		o->Prepare(true);
		IGhoulInst *in = o->CreateInstance();
		in->Play(1, 0.0f, 0.0f, true, 0, false, false);
		float minZ;
		Framing fr = Frame(in, 0.0f, Vec3(1, -1, 1), 1.0f, minZ);
		g_ground = minZ - 1.0f;
		Image cell;
		cell.Init(128, 128, 0, 0, 0);
		int plain = DrawInto(in, 0.0f, fr.eye, fr.target, cell, false);
		g_flag1000 = true;
		int flagged = DrawInto(in, 0.0f, fr.eye, fr.target, cell, false);
		g_flag1000 = false;
		if (!g_haveData)
			std::printf("SKIP: shadow flag 0x1000 check needs the game data\n");
		else
			CHECK(flagged == plain + 6, "shadow only with flag 0x1000: %d vs %d triangles", plain, flagged);
		o->Destroy();
	}
	// SPEC-012 vector 10: a missing slot texture prints once with the COMSKIN path
	{
		g_host.log.clear();
		ImageList *a = AcquireImageList("GHOUL/ENEMY/MESO/", "FOO");
		ImageList *b = AcquireImageList("GHOUL/ENEMY/MESO/", "FOO");
		int n = 0;
		for (auto &l : g_host.log)
			n += l == "Ghoul :GHOUL/COMSKIN/FOO not found\n";
		CHECK(!a && !b && n == 1, "missing texture message printed %d times", n);
	}
	// SPEC-AMEND-002 vector 7 / SPEC-012 section 10: gserver
	{
		g_host.log.clear();
		const char *argv1[] = {"gserver", "light_ambient"};
		OMGhoul_Command(2, argv1);
		const char *argv2[] = {"gserver", "SUMMARY"};
		OMGhoul_Command(2, argv2);
		CHECK(g_host.log.size() == 4 && g_host.log[0] == "LIGHT_AMBIENT = 0.60\n", "gserver output '%s'",
			g_host.log.empty() ? "" : g_host.log[0].c_str());
	}

	// 4. every stock model: register, prepare, play its first sequence, draw one pose (no explosions: all posed
	//    vertices stay within the file's bounding box enlarged by 10 %)
	int models = 0, drawn = 0, bad = 0;
	if (!quick)
	{
		std::vector<std::string> files = ListFiles("ghoul", ".ghb");
		for (auto &p : files)
		{
			std::string norm = NormalizeName(p);
			IGhoulObject *o = cl->CreateObject();
			GhoulID s = o->RegisterSequence((StripExtension(p) + ".ghl").c_str(), false);
			models++;
			if (!s)
			{
				o->Destroy();
				continue;
			}
			o->FinishRegistration(false);
			IGhoulInst *in = o->CreateInstance();
			in->Play(s, 0.0f, 0.0f, true, 0, false, false);
			float d = in->SequenceDuration(s, 0, nullptr);
			std::vector<PosedTri> tris = Capture(in, d * 0.37f);
			if (!tris.empty())
				drawn++;
			const GhbFile *f = static_cast<Object *>(o)->files.empty() ? nullptr : static_cast<Object *>(o)->files[0];
			if (f && !tris.empty())
			{
				Vec3 lo = f->bounds.mn, hi = f->bounds.mx, ext = (hi - lo) * 0.1f + Vec3(1, 1, 1);
				bool out = false;
				for (auto &t : tris)
					for (int k = 0; k < 3; k++)
						for (int a = 0; a < 3; a++)
							if (t.p[k][a] < lo[a] - ext[a] || t.p[k][a] > hi[a] + ext[a])
								out = true;
				// billboards rotate about their node and may leave the box; ignore files with sprites
				bool sprites = false;
				for (auto &n : f->nodes)
					sprites = sprites || n.sprite;
				if (out && !sprites)
				{
					bad++;
					std::printf("   posed vertices outside the bounds: %s\n", p.c_str());
				}
			}
			o->Destroy();
			cl->Purge();
		}
		std::printf("   every model: %d registered, %d drew triangles, %d outside their bounds\n", models, drawn, bad);
		CHECK(bad == 0, "%d models posed outside their bounds", bad);
	}
	std::printf("   %d rendered cells, %d exports (OBJ + glTF)\n", g_cells, g_exports);
	cl->ReleaseTextures();
	cl->Reset();
}
