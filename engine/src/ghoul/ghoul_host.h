/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 * OpenMerc Ghoul model system - host services and C entry points for the engine.
 *
 * The Ghoul library depends on nothing else in the engine. Everything it needs from its host
 * (files, console, memory, time, fatal errors) comes through om_ghoul_host_t; the engine (C) or a
 * test program fills one in and passes it to OMGhoul_Init.
 *
 * Implements: SPEC-010 (system roles, game imports #61-#66, gserver), SPEC-012 (caches), SPEC-001 (#60-#66),
 *             SPEC-013 (engine bit buffer of the network methods)
 */
#ifndef OM_GHOUL_HOST_H
#define OM_GHOUL_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(OM_GHOUL_HOST_EXPORTS) && (defined(__clang__) || defined(__GNUC__))
#define OM_GHOUL_HOST_EXPORT __attribute__((visibility("default")))
#else
#define OM_GHOUL_HOST_EXPORT
#endif

typedef struct om_ghoul_host_s
{
	void *ctx; /* passed back to every callback */

	/* Load a whole file by game path ("ghoul/enemy/meso/MESO_PLAYER.ghb"; case-insensitive, '/' or '\').
	   Returns the length and sets *data (released with free_file), or -1 and *data = NULL.
	   Opening a file this way also records it as used (download list, SPEC-010 system method 22). */
	int (*load_file)(void *ctx, const char *path, void **data);
	void (*free_file)(void *ctx, void *data);

	/* Console output (text already formatted, may contain newlines). */
	void (*print)(void *ctx, const char *text);

	/* Fatal error, text = "Ghoul :<message>". Must not return (Sys_Error, or a C++ throw in test hosts).
	   If it returns, the library aborts the process. */
	void (*fatal)(void *ctx, const char *text);

	/* Memory for model data and caches; NULL entries mean malloc/free. */
	void *(*alloc)(void *ctx, size_t size);
	void (*release)(void *ctx, void *ptr);

	/* Real time in milliseconds (diagnostics only); may be NULL. */
	double (*milliseconds)(void *ctx);
} om_ghoul_host_t;

/* Engine bit buffer passed to the engine-only network methods (system methods 16, 18, 24, 25).
   Bits are written/read least-significant-bit first (SPEC-201 B.1).
   Writer: data = buffer, maxbits = byte budget * 8, bit = 0. After the call the payload is
           (bit + 7) / 8 bytes (zero padded); the engine sends it as svc 26 / svc 27.
   Reader: data = payload, maxbits = payload bytes * 8, bit = 0. */
typedef struct om_ghoul_bits_s
{
	unsigned char *data;
	int maxbits;
	int bit;
	int overflowed; /* writer: something did not fit; reader: read past the end */
} om_ghoul_bits_t;

/* system roles (SPEC-010 A) */
#define OM_GHOUL_SERVER 0
#define OM_GHOUL_CLIENT 1
#define OM_GHOUL_MENU 2

/* Native renderer hand-off.  This is deliberately separate from the fixed
   IGhoulSystem method table and from GhoulGLTable: a host renderer may receive
   direct posed batches without creating or translating an OpenGL call stream.
   The draw payload is introduced by the producer in ghoul_draw.cpp; callbacks
   must consume its data synchronously. */
enum
{
	OM_GHOUL_NATIVE_BLEND_OPAQUE = 0,
	OM_GHOUL_NATIVE_BLEND_ALPHA = 1,
	OM_GHOUL_NATIVE_BLEND_ADDITIVE = 2
};

enum
{
	OM_GHOUL_NATIVE_CULL_NONE = 0,
	OM_GHOUL_NATIVE_CULL_BACK = 1,
	OM_GHOUL_NATIVE_CULL_FRONT = 2
};

typedef struct om_ghoul_native_vertex_s
{
	float position[3];
	float normal[3];
	float uv[2];
	float colour[4];
} om_ghoul_native_vertex_t;

typedef struct om_ghoul_native_texture_s
{
	const char *key;
	int width, height;
	int has_alpha;
	/* The fixed-function path gives _NOMIP skins nearest-only sampling.  A
	 * native renderer receives this material property explicitly rather than
	 * inheriting the sampler state of an unrelated texture. */
	int nomip;
	int repeat_u, repeat_v;
	const uint8_t *rgba;
} om_ghoul_native_texture_t;

typedef struct om_ghoul_native_draw_s
{
	const om_ghoul_native_vertex_t *vertices;
	size_t vertex_count;
	const om_ghoul_native_texture_t *texture; /* NULL for an untextured material */
	/* Material provenance remains valid only for this synchronous callback. It
	 * lets a native renderer diagnose a null texture without guessing whether
	 * the source material was intentionally untextured, unresolved, or failed
	 * during decode. */
	const char *material_name;
	const char *texture_name;
	int texture_declared;
	int texture_list_resolved;
	int texture_decoded;
	float model_to_world[16];                 /* row-vector matrix, valid for this callback only */
	int blend;
	int cull;
	int depth_write;
	int alpha_test;
	float depth_bias, depth_slope;
	/* Snapshot of the shared native-light calculation for bounded renderer
	 * diagnostics.  It is valid only for this synchronous callback. */
	int native_light_count;
	float native_ambient[3];
	/* Diagnostic snapshot of the actual native base-light branch before the
	 * material texture/modulate step. */
	int native_hardware_lights;
	int native_gl_attenuation;
	float native_first_light[3];
	/* Explicit modern bloom provenance, independent of final lighting/blend.
	 * A specular-only pass never seeds glow; the base material's unthresholded
	 * max(self-illumination, additive?1:0) remains available to the renderer. */
	float bloom_source;
	int specular_pass;
} om_ghoul_native_draw_t;

/* Plain-C input used by a native renderer to invoke a Ghoul instance draw.
   The library owns the C++ render-parameter adapter and does not expose its
   vtable across this boundary. */
typedef struct om_ghoul_render_params_s
{
	float time;
	float light_color[3];
	float light_dir[3];
	float origin[3];
	int dir_valid, use_gl_lights, specular, fast_lights, hardware_lights;
	int gl_directional, gl_attenuation, entity_flag_1000, shadow_only;
	int no_texture_stack, no_dynamic_lights;
	float shadow_darkness, fog_visibility, shadow_dist;
	int shadow_mode, max_lights;
	float entity_to_world[16];
	float view_origin[3], view_forward[3];
	float (*world_trace)(const float *start, const float *end); /* fraction, -1 = start in solid; ground shadows */
} om_ghoul_render_params_t;

/* Plain-C frame light record for a native renderer.  The Ghoul system owns
 * the copy and uses it only for the current render frame. */
typedef struct om_ghoul_light_s
{
	float origin[3];
	float color[3];
	float radius;
} om_ghoul_light_t;

/* One ground-shadow quad (SPEC-411 section 7): 64 x 64 alpha mask, drawn with blend (0, 1 - src alpha), depth tested,
   no depth writes, polygon offset (-3, -3), culling off; texel alpha x `alpha` darkens the world. */
typedef struct om_ghoul_native_shadow_s
{
	const unsigned char *mask;
	float pos[4][3], st[4][2];
	float alpha;
} om_ghoul_native_shadow_t;

typedef struct om_ghoul_native_sink_s
{
	void *ctx;
	void (*begin_frame)(void *ctx);
	void (*draw)(void *ctx, const om_ghoul_native_draw_t *draw);
	void (*end_frame)(void *ctx);
	void (*release_resources)(void *ctx);
	/* Native hardware-light material policy; independent of the legacy ABI. */
	int hardware_local_viewer;
	void (*shadow)(void *ctx, const om_ghoul_native_shadow_t *shadow);
} om_ghoul_native_sink_t;

/* Install the host (copied). Must be called before any other function. */
void OMGhoul_Init(const om_ghoul_host_t *host);
/* Destroy every object and free every cache. */
void OMGhoul_Shutdown(void);

/* Install (or clear with NULL) the direct native renderer sink.  The library
   copies the callback table; the caller retains ownership of its storage. */
OM_GHOUL_HOST_EXPORT void OMGhoul_SetNativeSink(const om_ghoul_native_sink_t *sink);
/* Non-zero exactly while a complete native sink is installed. */
OM_GHOUL_HOST_EXPORT int OMGhoul_HasNativeSink(void);
/* C bridge for a renderer that cannot directly instantiate the C++ Ghoul
   render-parameter class.  `system` is the pointer returned by
   OMGhoul_GetSystem(OM_GHOUL_CLIENT). */
OM_GHOUL_HOST_EXPORT void *OMGhoul_FindInstance(void *system, int handle);
OM_GHOUL_HOST_EXPORT void OMGhoul_DrawInstance(void *instance, const om_ghoul_render_params_t *params);
OM_GHOUL_HOST_EXPORT void OMGhoul_ClearLights(void *system);
OM_GHOUL_HOST_EXPORT void OMGhoul_AddDynamicLight(void *system, const om_ghoul_light_t *light);
/* Map-lifetime BSP model lights.  Begin/Finish delimit a complete replacement
 * of the system-owned static world-light set. */
OM_GHOUL_HOST_EXPORT void OMGhoul_BeginWorldLights(void *system);
OM_GHOUL_HOST_EXPORT void OMGhoul_AddWorldLight(void *system, const om_ghoul_light_t *light);
OM_GHOUL_HOST_EXPORT void OMGhoul_FinishWorldLights(void *system);
/* Renderer-owned colour table used by Ghoul while decoding subsequently
 * loaded skin textures. */
OM_GHOUL_HOST_EXPORT void OMGhoul_SetGamma(void *system, const uint8_t *table256);
/* GL3 method 38: the first source mip Ghoul exposes to a renderer. */
OM_GHOUL_HOST_EXPORT void OMGhoul_SetTextureDetail(void *system, int level);
/* System method 2 prepares existing and subsequently loaded materials for
 * specular rendering; the per-instance draw flag alone cannot enable it. */
OM_GHOUL_HOST_EXPORT void OMGhoul_SetSpecular(void *system, int enabled);

/* The three system objects (SPEC-010 A). Return the C++ interface pointer (ghoul::IGhoulSystem *). */
void *OMGhoul_GetSystem(int role);

/* Game import #61: new player-model description (ghoul::IGhoulPlayerModel *), loaded from
   Ghoul/pmodels/<file>. The caller deletes it with its method 18 (flags 1). */
void *OMGhoul_NewPlayerModel(const char *file);
/* Game import #62: load Ghoul/<folder>/<file> (else Ghoul/comskin/<file>) into the shared text cache.
   Returns the length or -1; *buffer is not NUL-terminated and must not be freed. */
int OMGhoul_LoadFile(const char *folder, const char *file, void **buffer);
/* Game import #63: next CR LF line (see SPEC-010 for the last-byte quirk). Returns 1 when a line feed
   was found. */
int OMGhoul_GetLine(int *remaining, char **cursor, char *line);
/* Game import #64: pre-load <name>.gsq. */
void OMGhoul_PreloadList(const char *folder, const char *name);
/* Game import #65: register the sequences of a .gsq list with a model object (ghoul::IGhoulObject *). */
int OMGhoul_RegisterList(const char *folder, const char *name, void *object);
/* Game import #66: hide the parts of a "parts off" list on an instance. */
void OMGhoul_PartsOff(const char *folder, const char *name, void *object, void *instance);

/* Console command "gserver <sub-command> [argument]" (SPEC-012 section 10); argv[0] is "gserver". */
void OMGhoul_Command(int argc, const char *const *argv);
/* ENG2: the shared size-matters value for the movement routine (SPEC-314 Inputs) */
float OMGhoul_SizeMatters(void);

#ifdef __cplusplus
}
#endif

#undef OM_GHOUL_HOST_EXPORT

#endif
