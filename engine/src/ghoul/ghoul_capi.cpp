// SPDX-License-Identifier: GPL-2.0-or-later
// OpenMerc Ghoul model system - C entry points for the engine (ghoul_host.h).
// Implements: SPEC-010 A (the three system objects), SPEC-010 game imports #61-#66 (SPEC-001 #60-#66),
//             SPEC-012 section 10 (gserver)

#include "ghoul_host.h"
#include "ghoul_internal.h"

namespace ghoul {
int TextLoad(const char *folder, const char *file, void **buffer);
int TextGetLine(int *remaining, char **cursor, char *line);
void TextPreloadList(const char *folder, const char *name);
int TextRegisterList(const char *folder, const char *name, void *object);
void TextPartsOff(const char *folder, const char *name, void *object, void *instance);
IGhoulPlayerModel *NewPlayerModel(const char *file);
void GserverCommand(int argc, const char *const *argv);
void DestroySystems();
void ForgetShadowTextures();
} // namespace ghoul

using namespace ghoul;

namespace {
class CApiRenderParams final : public GhoulRenderParams
{
public:
	bool BoxOutside(const float (*)[3]) override { return false; }
};

static void CopyParams(CApiRenderParams &out, const om_ghoul_render_params_t &in)
{
	std::memset((char *)&out + sizeof(void *), 0, sizeof(out) - sizeof(void *));
	out.time = in.time;
	std::memcpy(out.lightColor, in.light_color, sizeof(out.lightColor));
	std::memcpy(out.lightDir, in.light_dir, sizeof(out.lightDir));
	std::memcpy(out.origin, in.origin, sizeof(out.origin));
	out.dirValid = in.dir_valid != 0;
	out.useGLLights = in.use_gl_lights != 0;
	out.specular = in.specular != 0;
	out.fastLights = in.fast_lights != 0;
	out.hardwareLights = in.hardware_lights != 0;
	out.glDirectional = in.gl_directional != 0;
	out.glAttenuation = in.gl_attenuation != 0;
	out.entityFlag1000 = in.entity_flag_1000 != 0;
	out.shadowOnly = in.shadow_only != 0;
	out.noTextureStack = in.no_texture_stack != 0;
	out.noDynamicLights = in.no_dynamic_lights != 0;
	out.shadowDarkness = in.shadow_darkness;
	out.fogVisibility = in.fog_visibility;
	out.shadowDist = in.shadow_dist;
	out.shadowMode = in.shadow_mode;
	out.worldTrace = in.world_trace;
	out.maxLights = in.max_lights;
	std::memcpy(&out.entityToWorld.m[0][0], in.entity_to_world, sizeof(in.entity_to_world));
	out.entityToWorld.flags = 0;
	std::memcpy(out.viewOrigin, in.view_origin, sizeof(out.viewOrigin));
	std::memcpy(out.viewForward, in.view_forward, sizeof(out.viewForward));
}
} // namespace

extern "C" {

void OMGhoul_Init(const om_ghoul_host_t *host)
{
	SetHost(host);
	for (int r = 0; r < 3; r++)
		GetSystemObject(r);
}

void OMGhoul_Shutdown(void)
{
	OMGhoul_SetNativeSink(nullptr);
	DestroySystems();
	ReleaseAllTextures();
	ForgetShadowTextures();
	FlushChunkCache();
	G().files.PurgeUnreferenced();
	G().imageLists.clear();
	G().textures.clear();
	G().texts.clear();
	G().playerTexts.clear();
}

void OMGhoul_SetNativeSink(const om_ghoul_native_sink_t *sink)
{
	if (G().hasNativeSink && G().nativeSink.release_resources)
		G().nativeSink.release_resources(G().nativeSink.ctx);
	std::memset(&G().nativeSink, 0, sizeof(G().nativeSink));
	G().hasNativeSink = false;
	if (!sink || !sink->draw)
		G().nativeHardwareShininess = 0.0f;
	if (sink && sink->draw)
	{
		G().nativeSink = *sink;
		G().hasNativeSink = true;
	}
}

int OMGhoul_HasNativeSink(void) { return G().hasNativeSink ? 1 : 0; }

void *OMGhoul_FindInstance(void *system, int handle)
{
	if (!system || !handle)
		return nullptr;
	return static_cast<IGhoulSystem *>(system)->FindInstance(handle);
}

void OMGhoul_DrawInstance(void *instance, const om_ghoul_render_params_t *params)
{
	if (!instance || !params)
		return;
	CApiRenderParams bridge;
	CopyParams(bridge, *params);
	static_cast<IGhoulInst *>(instance)->Draw(&bridge);
}

void OMGhoul_ClearLights(void *system)
{
	if (system)
		static_cast<IGhoulSystem *>(system)->ClearLights();
}

void OMGhoul_AddDynamicLight(void *system, const om_ghoul_light_t *light)
{
	if (!system || !light)
		return;
	LightRecord record = {};
	std::memcpy(record.origin, light->origin, sizeof(record.origin));
	std::memcpy(record.color, light->color, sizeof(record.color));
	record.radius = light->radius;
	static_cast<IGhoulSystem *>(system)->AddDynamicLight(&record);
}

void OMGhoul_BeginWorldLights(void *system)
{
	if (system)
		static_cast<IGhoulSystem *>(system)->BeginWorldLights();
}

void OMGhoul_AddWorldLight(void *system, const om_ghoul_light_t *light)
{
	if (!system || !light)
		return;
	LightRecord record = {};
	std::memcpy(record.origin, light->origin, sizeof(record.origin));
	std::memcpy(record.color, light->color, sizeof(record.color));
	record.radius = light->radius;
	static_cast<IGhoulSystem *>(system)->AddWorldLight(&record);
}

void OMGhoul_FinishWorldLights(void *system)
{
	if (system)
		static_cast<IGhoulSystem *>(system)->FinishWorldLights();
}

void OMGhoul_SetGamma(void *system, const uint8_t *table256)
{
	if (system && table256)
		static_cast<IGhoulSystem *>(system)->SetGamma(table256);
}

void OMGhoul_SetTextureDetail(void *system, int level)
{
	if (system)
		static_cast<IGhoulSystem *>(system)->SetTextureDetail(level);
}

void OMGhoul_SetSpecular(void *system, int enabled)
{
	if (system)
		static_cast<IGhoulSystem *>(system)->SetSpecular(enabled != 0);
}

void *OMGhoul_GetSystem(int role) { return static_cast<IGhoulSystem *>(GetSystemObject(role)); }

void *OMGhoul_NewPlayerModel(const char *file) { return NewPlayerModel(file); }

int OMGhoul_LoadFile(const char *folder, const char *file, void **buffer) { return TextLoad(folder, file, buffer); }

int OMGhoul_GetLine(int *remaining, char **cursor, char *line) { return TextGetLine(remaining, cursor, line); }

void OMGhoul_PreloadList(const char *folder, const char *name) { TextPreloadList(folder, name); }

int OMGhoul_RegisterList(const char *folder, const char *name, void *object)
{
	return TextRegisterList(folder, name, object);
}

void OMGhoul_PartsOff(const char *folder, const char *name, void *object, void *instance)
{
	TextPartsOff(folder, name, object, instance);
}

void OMGhoul_Command(int argc, const char *const *argv) { GserverCommand(argc, argv); }
float OMGhoul_SizeMatters(void) { return G().gs.sizeMatters; }

} // extern "C"
