// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 OpenMerc contributors
// Sun keys and cascade maths of the cascaded sun shadows, adapted from the GPL gl3_csm.c.
// Implements: SPEC-AMEND-016 R16.2 and R16.4; docs/impl/GFX-modern.md section 4.
// Pure maths: no Metal calls, no renderer globals.
#ifndef OM_METAL_CSM_MATH_H
#define OM_METAL_CSM_MATH_H
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define MTL_CSM_MAXCASC 4

/* the sun of a map (worldspawn keys of the map compiler, R16.2) */
typedef struct {
	int valid;
	float tosun[3];   /* unit vector from a lit point toward the sun */
	float color[3];
	float light;      /* _sun_light, 100 when missing */
	float ambient[3]; /* _sun_ambient / 255 */
	char how[48];
} mtl_csm_sun_t;

/* the block read by the MSL struct OMCsmUniforms (four float4x4, then float4s) */
typedef struct {
	float vp[MTL_CSM_MAXCASC][16];
	float split[4];    /* far view depth of each cascade */
	float sun[4];      /* toward sun, enabled */
	float params[4];   /* strength, -, normal offset in texels, PCF radius in texels */
	float params2[4];  /* cascades, 1 / size, replace Ghoul shadows, debug view */
	float view[4];     /* view forward, -forward . origin */
	float amb[4];      /* ambient floor (lightmap units) */
	float texel[4];    /* world size of a texel per cascade */
	float bias[4];     /* depth bias per cascade (dynamic layer; static is 4x) */
	float dynrect[MTL_CSM_MAXCASC][4]; /* uv box of last frame's dynamic casters per cascade, for the early out */
} mtl_csm_uniform_t;

typedef struct {
	float origin[3], forward[3], right[3], up[3];
	float fov_x, fov_y;
} mtl_csm_view_t;

/* the clamped r_om_csm_* controls */
typedef struct {
	int ncasc, size;
	float lambda, maxdist, strength, normalbias, soft, bias;
	int replace_ghl, debug;
} mtl_csm_config_t;

typedef struct { float cx, cy, radius; } mtl_csm_cascade_t;

/* entity lump tokenizer: quoted strings, bare words, braces */
static inline const char *MTL_CSMToken(const char **p, const char *end, char *out, int outsize)
{
	const char *s = *p;
	int n = 0;
	while (s < end && *s && (unsigned char)*s <= ' ') s++;
	if (s >= end || !*s) { *p = s; return NULL; }
	if (*s == '{' || *s == '}') { out[0] = *s; out[1] = 0; *p = s + 1; return out; }
	if (*s == '"') {
		s++;
		while (s < end && *s && *s != '"') { if (n < outsize - 1) out[n++] = *s; s++; }
		if (s < end && *s == '"') s++;
	} else {
		while (s < end && *s && (unsigned char)*s > ' ' && *s != '{' && *s != '}') { if (n < outsize - 1) out[n++] = *s; s++; }
	}
	out[n] = 0;
	*p = s;
	return out;
}

static inline int MTL_CSMFloats(const char *s, float *out, int max)
{
	int n = 0;
	while (*s && n < max) {
		char *e;
		float v;
		while (*s && (unsigned char)*s <= ' ') s++;
		if (!*s) break;
		v = (float)strtod(s, &e);
		if (e == s) break;
		out[n++] = v;
		s = e;
	}
	return n;
}

static inline float MTL_CSMClamp(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline float MTL_CSMDot(const float a[3], const float b[3]) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
static inline float MTL_CSMNormalize(float v[3])
{
	float len = sqrtf(MTL_CSMDot(v, v));
	if (len != 0) { float s = 1.0f / len; v[0] *= s; v[1] *= s; v[2] *= s; }
	return len;
}

typedef struct {
	char classname[32], targetname[64], target[64];
	float origin[3];
	int hasorigin;
} mtl_csm_ent_t;

/* the keys of GL3_CSM_LoadSun, in its order and precedence */
static inline void MTL_CSMParseSun(const char *ents, int len, mtl_csm_sun_t *sun)
{
	const char *p = ents, *end = ents + len;
	char key[128], val[512];
	mtl_csm_ent_t *list = NULL;
	int num = 0, cap = 0, i, j;
	char ws_angle[128] = "", ws_name[64] = "", ws_vector[128] = "", ws_color[128] = "", ws_light[64] = "";
	char ws_ambient[128] = "";
	int ws_surface = 0, first = 1;

	memset(sun, 0, sizeof(*sun));
	if (!ents || len <= 0) return;

	while (MTL_CSMToken(&p, end, key, sizeof(key))) {
		mtl_csm_ent_t e;
		if (key[0] != '{') break;
		memset(&e, 0, sizeof(e));
		while (MTL_CSMToken(&p, end, key, sizeof(key)) && key[0] != '}') {
			if (!MTL_CSMToken(&p, end, val, sizeof(val))) break;
			if (!strcasecmp(key, "classname")) snprintf(e.classname, sizeof(e.classname), "%s", val);
			else if (!strcasecmp(key, "targetname")) snprintf(e.targetname, sizeof(e.targetname), "%s", val);
			else if (!strcasecmp(key, "target")) snprintf(e.target, sizeof(e.target), "%s", val);
			else if (!strcasecmp(key, "origin")) e.hasorigin = (MTL_CSMFloats(val, e.origin, 3) == 3);
			else if (first) {
				if (!strcasecmp(key, "_sun_angle")) snprintf(ws_angle, sizeof(ws_angle), "%s", val);
				else if (!strcasecmp(key, "_sun") || !strcasecmp(key, "_sun_target")) snprintf(ws_name, sizeof(ws_name), "%s", val);
				else if (!strcasecmp(key, "_sun_vector")) snprintf(ws_vector, sizeof(ws_vector), "%s", val);
				else if (!strcasecmp(key, "_sun_color")) snprintf(ws_color, sizeof(ws_color), "%s", val);
				else if (!strcasecmp(key, "_sun_light") || (!strcasecmp(key, "_sunlight") && !ws_light[0]))
					snprintf(ws_light, sizeof(ws_light), "%s", val);
				else if (!strcasecmp(key, "_sun_ambient")) snprintf(ws_ambient, sizeof(ws_ambient), "%s", val);
				else if (!strcasecmp(key, "_sun_surface")) ws_surface = 1;
			}
		}
		first = 0;
		if (num == cap) {
			cap = cap ? cap * 2 : 256;
			mtl_csm_ent_t *n2 = (mtl_csm_ent_t *)realloc(list, (size_t)cap * sizeof(*list));
			if (!n2) break;
			list = n2;
		}
		list[num++] = e;
	}

	/* direction (the key, not a fit; precedence between kinds is unknown, R16.2) */
	if (ws_angle[0]) {
		float a[2];
		if (MTL_CSMFloats(ws_angle, a, 2) == 2) {
			float y = a[0] * (float)M_PI / 180.0f, pt = a[1] * (float)M_PI / 180.0f;
			/* the angles give the direction the light travels */
			sun->tosun[0] = -cosf(y) * cosf(pt);
			sun->tosun[1] = -sinf(y) * cosf(pt);
			sun->tosun[2] = -sinf(pt);
			sun->valid = 1;
			snprintf(sun->how, sizeof(sun->how), "_sun_angle %g %g", a[0], a[1]);
		}
	} else if (ws_name[0]) {
		const mtl_csm_ent_t *nul = NULL, *light = NULL;
		for (i = 0; i < num; i++) {
			if (!strcasecmp(list[i].targetname, ws_name) && list[i].hasorigin &&
				(!strcasecmp(list[i].classname, "info_null") || !strcasecmp(list[i].classname, "info_notnull"))) {
				nul = &list[i];
				break;
			}
		}
		for (j = 0; nul && j < num; j++) {
			if (!strcasecmp(list[j].target, ws_name) && list[j].hasorigin && !strncasecmp(list[j].classname, "light", 5)) {
				light = &list[j];
				break;
			}
		}
		if (nul && light) {
			for (i = 0; i < 3; i++) sun->tosun[i] = light->origin[i] - nul->origin[i];
			sun->valid = (MTL_CSMNormalize(sun->tosun) > 0.001f);
			snprintf(sun->how, sizeof(sun->how), "_sun %s", ws_name);
		}
	} else if (ws_vector[0]) {
		float v[3];
		if (MTL_CSMFloats(ws_vector, v, 3) == 3) {
			sun->tosun[0] = -v[0]; sun->tosun[1] = -v[1]; sun->tosun[2] = -v[2];
			sun->valid = (MTL_CSMNormalize(sun->tosun) > 0.001f);
			snprintf(sun->how, sizeof(sun->how), "_sun_vector");
		}
	} else if (ws_surface) {
		sun->tosun[0] = 0; sun->tosun[1] = 0; sun->tosun[2] = 1;
		sun->valid = 1;
		snprintf(sun->how, sizeof(sun->how), "_sun_surface (down)");
	}

	/* a sun below the horizon lights nothing from above */
	if (sun->valid && sun->tosun[2] <= 0.02f) sun->valid = 0;

	sun->color[0] = sun->color[1] = sun->color[2] = 1;
	if (ws_color[0]) {
		float c[3];
		if (MTL_CSMFloats(ws_color, c, 3) == 3) {
			sun->color[0] = MTL_CSMClamp(c[0], 0, 1);
			sun->color[1] = MTL_CSMClamp(c[1], 0, 1);
			sun->color[2] = MTL_CSMClamp(c[2], 0, 1);
		}
	}
	sun->light = 100;
	if (ws_light[0]) {
		float l;
		if (MTL_CSMFloats(ws_light, &l, 1) == 1) sun->light = l;
	}
	sun->ambient[0] = sun->ambient[1] = sun->ambient[2] = 0.06f;
	if (ws_ambient[0]) {
		float a[3];
		int n = MTL_CSMFloats(ws_ambient, a, 3);
		if (n == 3) { sun->ambient[0] = a[0] / 255.0f; sun->ambient[1] = a[1] / 255.0f; sun->ambient[2] = a[2] / 255.0f; }
		else if (n == 1) { sun->ambient[0] = sun->ambient[1] = sun->ambient[2] = a[0] / 255.0f; }
	}
	free(list);
}

/* light space: Z toward the sun */
static inline void MTL_CSMAxes(const float tosun[3], float X[3], float Y[3], float Z[3])
{
	float ref[3] = {0, 0, 1};
	Z[0] = tosun[0]; Z[1] = tosun[1]; Z[2] = tosun[2];
	if (fabsf(Z[2]) > 0.99f) { ref[0] = 1; ref[1] = 0; ref[2] = 0; }
	X[0] = ref[1] * Z[2] - ref[2] * Z[1];
	X[1] = ref[2] * Z[0] - ref[0] * Z[2];
	X[2] = ref[0] * Z[1] - ref[1] * Z[0];
	MTL_CSMNormalize(X);
	Y[0] = Z[1] * X[2] - Z[2] * X[1];
	Y[1] = Z[2] * X[0] - Z[0] * X[2];
	Y[2] = Z[0] * X[1] - Z[1] * X[0];
}

static inline void MTL_CSMOrtho(mtl_csm_uniform_t *u, mtl_csm_cascade_t *out, int c, const mtl_csm_view_t *v,
	float dnear, float dfar, const float X[3], const float Y[3], const float Z[3], float zworld, int size, float bias)
{
	float tx = tanf(v->fov_x * (float)M_PI / 360.0f), ty = tanf(v->fov_y * (float)M_PI / 360.0f);
	float corners[8][3], center[3] = {0, 0, 0};
	float R = 0, texel, cx, cy, zmax, zmin, k, *m = u->vp[c];

	for (int i = 0; i < 8; i++) {
		float d = (i & 4) ? dfar : dnear;
		float sx = (i & 1) ? 1.0f : -1.0f, sy = (i & 2) ? 1.0f : -1.0f;
		for (int j = 0; j < 3; j++) {
			corners[i][j] = v->origin[j] + v->forward[j] * d + v->right[j] * (sx * d * tx) + v->up[j] * (sy * d * ty);
			center[j] += corners[i][j];
		}
	}
	for (int j = 0; j < 3; j++) center[j] *= 1.0f / 8;
	for (int i = 0; i < 8; i++) {
		float d[3] = {corners[i][0] - center[0], corners[i][1] - center[1], corners[i][2] - center[2]};
		float len = sqrtf(MTL_CSMDot(d, d));
		if (len > R) R = len;
	}

	/* a radius that does not change with the view direction, and centres on whole texels: no shimmer */
	R = ceilf(R / 16.0f) * 16.0f;
	texel = 2 * R / size;
	cx = floorf(MTL_CSMDot(center, X) / texel) * texel;
	cy = floorf(MTL_CSMDot(center, Y) / texel) * texel;
	zmax = zworld + 32;                          /* the highest point of the world toward the sun */
	zmin = MTL_CSMDot(center, Z) - R - 32;
	if (zmax < zmin + 64) zmax = zmin + 64;

	k = -2.0f / (zmax - zmin);
	memset(m, 0, 16 * sizeof(float));
	m[0] = X[0] / R;
	m[4] = X[1] / R;
	m[8] = X[2] / R;
	m[12] = -cx / R;
	m[1] = Y[0] / R;
	m[5] = Y[1] / R;
	m[9] = Y[2] / R;
	m[13] = -cy / R;
	m[2] = Z[0] * k;
	m[6] = Z[1] * k;
	m[10] = Z[2] * k;
	m[14] = 2.0f * zmax / (zmax - zmin) - 1.0f;
	m[15] = 1;

	u->split[c] = dfar;
	u->texel[c] = texel;
	/* r_om_csm_bias is per 1000 world units: 0.0015 = 1.5 units */
	u->bias[c] = (bias > 0 ? bias : 0.0f) * 1000.0f / (zmax - zmin) * 0.5f;
	out->cx = cx;
	out->cy = cy;
	out->radius = R;
}

/* the matrices and every uniform of a frame (GL3_CSM_Frame) */
static inline void MTL_CSMCompute(mtl_csm_uniform_t *u, mtl_csm_cascade_t cascades[MTL_CSM_MAXCASC],
	const mtl_csm_sun_t *sun, const float wmins[3], const float wmaxs[3], const mtl_csm_view_t *v, const mtl_csm_config_t *cfg)
{
	float X[3], Y[3], Z[3], zworld = -1e30f, dnear = 4.0f, prev;
	int ncasc = cfg->ncasc;

	MTL_CSMAxes(sun->tosun, X, Y, Z);
	for (int i = 0; i < 8; i++) {
		float p[3] = {(i & 1) ? wmaxs[0] : wmins[0], (i & 2) ? wmaxs[1] : wmins[1], (i & 4) ? wmaxs[2] : wmins[2]};
		float d = MTL_CSMDot(p, Z);
		if (d > zworld) zworld = d;
	}

	float lambda = MTL_CSMClamp(cfg->lambda, 0.0f, 1.0f), maxd = MTL_CSMClamp(cfg->maxdist, 256.0f, 16384.0f);
	prev = dnear;
	for (int c = 0; c < ncasc; c++) {
		float f = (float)(c + 1) / ncasc;
		float uni = dnear + (maxd - dnear) * f, lg = dnear * powf(maxd / dnear, f);
		float d = uni + (lg - uni) * lambda;
		MTL_CSMOrtho(u, &cascades[c], c, v, (c == 0) ? 0.0f : prev, d, X, Y, Z, zworld, cfg->size, cfg->bias);
		prev = d;
	}

	u->sun[0] = Z[0]; u->sun[1] = Z[1]; u->sun[2] = Z[2]; u->sun[3] = 1;
	/* a weak (night) sun casts lighter shadows: _sun_light 100 and more is full strength */
	u->params[0] = MTL_CSMClamp(cfg->strength, 0.0f, 1.0f) * MTL_CSMClamp(sun->light / 100.0f, 0.25f, 1.0f);
	u->params[1] = 0;
	u->params[2] = (cfg->normalbias > 0 ? cfg->normalbias : 0.0f) * 100.0f; /* 0.02 = 2 texels */
	u->params[3] = MTL_CSMClamp(cfg->soft, 0.0f, 2.0f);
	u->params2[0] = (float)ncasc;
	u->params2[1] = 1.0f / cfg->size;
	u->params2[2] = cfg->replace_ghl ? 1.0f : 0.0f;
	u->params2[3] = cfg->debug ? 1.0f : 0.0f;
	u->view[0] = v->forward[0]; u->view[1] = v->forward[1]; u->view[2] = v->forward[2];
	u->view[3] = -MTL_CSMDot(v->forward, v->origin);
	u->amb[0] = sun->ambient[0]; u->amb[1] = sun->ambient[1]; u->amb[2] = sun->ambient[2]; u->amb[3] = 0;
}

/* The uv box of the dynamic casters in one cascade, padded by the PCF radius, one texel of bilinear reach and the
 * receiver's normal offset; no casters: an empty box, the shader skips its 25 taps. A Metal-side saving, GL has none. */
static inline void MTL_CSMDynRect(float out[4], const mtl_csm_cascade_t *c, int size, float normal_offset_texels,
	int have, float lx0, float lx1, float ly0, float ly1)
{
	if (!have) { out[0] = out[1] = 2; out[2] = out[3] = -1; return; }
	float pad = (3.0f + normal_offset_texels) / (float)size;
	out[0] = ((lx0 - c->cx) / c->radius) * 0.5f + 0.5f - pad;
	out[2] = ((lx1 - c->cx) / c->radius) * 0.5f + 0.5f + pad;
	out[1] = 0.5f - ((ly1 - c->cy) / c->radius) * 0.5f - pad;
	out[3] = 0.5f - ((ly0 - c->cy) / c->radius) * 0.5f + pad;
}
#endif
