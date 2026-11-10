/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs: a live level behind the main menu.
 *
 * Play-test 2026-11-05: the main menu should "feel like the game, with proper background" - a live game scene: a
 * slow camera drifting through a real level, in 3D, like modern title screens. While no level runs and the menu
 * is open, the client registers one map of the player's own game data with the renderer (world, lightmaps, sky;
 * no server, no characters, no sound) and draws it from a camera that glides between the shots of
 * menus/om_scene.txt, fading through black between shots. A level load replaces the registration as usual; the
 * scene registers again the next time the menu shows without a level.
 *
 * menus/om_scene.txt:
 *   map <name>                                      (one map: one registration)
 *   music <set>                                     (sound/music/<set>.dms, its calm track; optional)
 *   shot <seconds> <x y z> <pitch yaw> <x y z> <pitch yaw>
 *
 * Cvars: menu_scene 1 (0 = the flat backdrop), menu_scene_file.
 */

#include "header/client.h"
#include "fx/cl_fx.h"
#include "header/sof_sound.h"

#define MS_MAX_SHOTS 16
#define MS_FADE 1.25f

typedef struct
{
	float seconds;
	vec3_t org[2];
	vec3_t ang[2];
} ms_shot_t;

static struct
{
	qboolean parsed, failed, registered;
	char map[MAX_QPATH];
	char music[MAX_QPATH];
	qboolean musicon;
	char sky[MAX_QPATH];
	float skyrotate;
	vec3_t skyaxis;
	ms_shot_t shot[MS_MAX_SHOTS];
	int numshots;
	int start_ms;
	float fade;
} ms;

static cvar_t *menu_scene;
static cvar_t *menu_scene_file;
static lightstyle_t ms_lightstyles[MAX_LIGHTSTYLES];
static refdef_t ms_refdef;

qboolean MWD_Enabled(void); /* menu/m_wide.c */

/* the worldspawn "sky" keys of the map, read from its entity lump */
static void
MS_ReadSky(void)
{
	char path[MAX_QPATH], *ents, *p, key[64], val[MAX_QPATH];
	byte *buf;
	int len, ofs, elen;

	ms.sky[0] = 0;
	ms.skyrotate = 0;
	VectorClear(ms.skyaxis);

	Com_sprintf(path, sizeof(path), "maps/%s.bsp", ms.map);
	len = FS_LoadFile(path, (void **)&buf);

	if (!buf)
	{
		return;
	}

	if (len < 16)
	{
		FS_FreeFile(buf);
		return;
	}

	ofs = LittleLong(((int *)buf)[2]);
	elen = LittleLong(((int *)buf)[3]);

	if (ofs < 0 || elen <= 0 || ofs + elen > len)
	{
		FS_FreeFile(buf);
		return;
	}

	ents = Z_Malloc(elen + 1);
	memcpy(ents, buf + ofs, elen);
	ents[elen] = 0;
	FS_FreeFile(buf);

	/* the first entity is worldspawn */
	p = strchr(ents, '{');

	while (p && *p && *p != '}')
	{
		char *q = strchr(p, '"'), *e;

		if (!q || (e = strchr(q + 1, '"')) == NULL)
		{
			break;
		}

		Q_strlcpy(key, q + 1, Q_min((int)sizeof(key), (int)(e - q)));
		q = strchr(e + 1, '"');

		if (!q || (e = strchr(q + 1, '"')) == NULL)
		{
			break;
		}

		Q_strlcpy(val, q + 1, Q_min((int)sizeof(val), (int)(e - q)));

		if (!Q_stricmp(key, "sky"))
		{
			Q_strlcpy(ms.sky, val, sizeof(ms.sky));
		}
		else if (!Q_stricmp(key, "skyrotate"))
		{
			ms.skyrotate = (float)atof(val);
		}
		else if (!Q_stricmp(key, "skyaxis"))
		{
			sscanf(val, "%f %f %f", &ms.skyaxis[0], &ms.skyaxis[1], &ms.skyaxis[2]);
		}

		p = e + 1;

		while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
		{
			p++;
		}
	}

	Z_Free(ents);
}

static void
MS_Parse(void)
{
	char *buf, *line, *next;
	int len;

	ms.parsed = true;
	ms.failed = true;
	ms.numshots = 0;
	ms.map[0] = 0;
	ms.music[0] = 0;

	len = FS_LoadFile(menu_scene_file->string, (void **)&buf);

	if (!buf)
	{
		Com_Printf("menu scene: %s not found, flat backdrop\n", menu_scene_file->string);
		return;
	}

	{
		char *text = Z_Malloc(len + 1);
		memcpy(text, buf, len);
		text[len] = 0;
		FS_FreeFile(buf);

		for (line = text; line && *line; line = next)
		{
			next = strchr(line, '\n');

			if (next)
			{
				*next++ = 0;
			}

			while (*line == ' ' || *line == '\t')
			{
				line++;
			}

			if (!strncmp(line, "music ", 6))
			{
				sscanf(line + 6, "%63s", ms.music);
			}
			else if (!strncmp(line, "map ", 4))
			{
				sscanf(line + 4, "%63s", ms.map);
			}
			else if (!strncmp(line, "shot ", 5) && ms.numshots < MS_MAX_SHOTS)
			{
				ms_shot_t *s = &ms.shot[ms.numshots];

				if (sscanf(line + 5, "%f %f %f %f %f %f %f %f %f %f %f", &s->seconds,
						&s->org[0][0], &s->org[0][1], &s->org[0][2], &s->ang[0][PITCH], &s->ang[0][YAW],
						&s->org[1][0], &s->org[1][1], &s->org[1][2], &s->ang[1][PITCH], &s->ang[1][YAW]) == 11 &&
					s->seconds > 2 * MS_FADE)
				{
					s->ang[0][ROLL] = s->ang[1][ROLL] = 0;
					ms.numshots++;
				}
			}
		}

		Z_Free(text);
	}

	if (!ms.map[0] || !ms.numshots)
	{
		Com_Printf("menu scene: no map or shots in %s, flat backdrop\n", menu_scene_file->string);
		return;
	}

	MS_ReadSky();
	ms.failed = false;
	Com_Printf("menu scene: %s, %i shots, sky %s\n", ms.map, ms.numshots, ms.sky[0] ? ms.sky : "-");
}

/* menu_scene_reload: read menu_scene_file again (choosing shots) */
static void
MS_Reload_f(void)
{
	ms.parsed = false;
	ms.registered = false;
}

/* menu_scene_info: what the scene draws now (tests) */
static void
MS_Info_f(void)
{
	Com_Printf("menu scene: active %i registered %i map %s fade %.2f view %.0f %.0f %.0f angles %.0f %.0f "
		"size %ix%i fov %.1f/%.1f\n", CL_MenuScene_Active(), ms.registered, ms.map, ms.fade,
		ms_refdef.vieworg[0], ms_refdef.vieworg[1], ms_refdef.vieworg[2], ms_refdef.viewangles[0],
		ms_refdef.viewangles[1], ms_refdef.width, ms_refdef.height, ms_refdef.fov_x, ms_refdef.fov_y);
}

void
CL_MenuScene_Init(void)
{
	int i;

	Cmd_AddCommand("menu_scene_reload", MS_Reload_f);
	Cmd_AddCommand("menu_scene_info", MS_Info_f);

	menu_scene = Cvar_Get("menu_scene", "1", CVAR_ARCHIVE);
	menu_scene_file = Cvar_Get("menu_scene_file", "menus/om_scene.txt", 0);

	for (i = 0; i < MAX_LIGHTSTYLES; i++)
	{
		ms_lightstyles[i].rgb[0] = ms_lightstyles[i].rgb[1] = ms_lightstyles[i].rgb[2] = 1.0f;
		ms_lightstyles[i].white = 3.0f;
	}
}

/* the renderer's registration now belongs to a level or to a new renderer */
void
CL_MenuScene_Forget(void)
{
	ms.registered = false;
}

qboolean
CL_MenuScene_Active(void)
{
	if (!menu_scene || !menu_scene->value || cls.state != ca_disconnected || cls.key_dest != key_menu ||
		!MWD_Enabled())
	{
		return false;
	}

	if (!ms.parsed)
	{
		MS_Parse();
	}

	return !ms.failed;
}

/* black over the scene, 0..1 (fades between shots) */
float
CL_MenuScene_Fade(void)
{
	return ms.fade;
}

static float
MS_Ease(float t)
{
	return t * t * (3.0f - 2.0f * t);
}

static float
MS_LerpAngle(float a, float b, float f)
{
	float d = b - a;

	while (d > 180)
	{
		d -= 360;
	}

	while (d < -180)
	{
		d += 360;
	}

	return a + d * f;
}

/* draws the scene into the frame's world pass; false when it cannot (the caller ends the pass) */
qboolean
CL_MenuScene_Render(void)
{
	float total = 0, t, f, fovy, w, h;
	const ms_shot_t *s;
	int i;

	if (!CL_MenuScene_Active())
	{
		return false;
	}

	if (!ms.registered)
	{
		int t0 = Sys_Milliseconds();

		R_BeginRegistration(ms.map);
		R_SetSky(ms.sky, ms.skyrotate, ms.skyaxis);
		R_EndRegistration();
		ms.registered = true;
		ms.start_ms = Sys_Milliseconds();
		Com_Printf("menu scene: %s registered in %i ms\n", ms.map, ms.start_ms - t0);
	}

	for (i = 0; i < ms.numshots; i++)
	{
		total += ms.shot[i].seconds;
	}

	t = (float)fmod((Sys_Milliseconds() - ms.start_ms) * 0.001, total);

	for (i = 0; i < ms.numshots - 1 && t >= ms.shot[i].seconds; i++)
	{
		t -= ms.shot[i].seconds;
	}

	s = &ms.shot[i];
	f = MS_Ease(Q_min(1.0f, Q_max(0.0f, t / s->seconds)));

	if (t < MS_FADE)
	{
		ms.fade = 1.0f - t / MS_FADE;
	}
	else if (t > s->seconds - MS_FADE)
	{
		ms.fade = 1.0f - (s->seconds - t) / MS_FADE;
	}
	else
	{
		ms.fade = 0;
	}

	memset(&ms_refdef, 0, sizeof(ms_refdef));
	ms_refdef.x = 0;
	ms_refdef.y = 0;
	ms_refdef.width = viddef.width;
	ms_refdef.height = viddef.height;

	for (i = 0; i < 3; i++)
	{
		ms_refdef.vieworg[i] = s->org[0][i] + (s->org[1][i] - s->org[0][i]) * f + 1.0f / 16;
		ms_refdef.viewangles[i] = MS_LerpAngle(s->ang[0][i], s->ang[1][i], f);
	}

	/* the 4:3 view's vertical angle (90 across 640x480), wider on wide windows (Hor+) */
	w = (float)ms_refdef.width;
	h = (float)ms_refdef.height;
	fovy = 73.739795f;
	ms_refdef.fov_y = fovy;
	ms_refdef.fov_x = (float)(atan(tan(fovy * M_PI / 360.0) * w / h) * 360.0 / M_PI);
	ms_refdef.time = (Sys_Milliseconds() - ms.start_ms) * 0.001f;
	ms_refdef.areabits = NULL; /* every area: no server, no portals */
	ms_refdef.lightstyles = ms_lightstyles;

	CLFX_RenderFrame(&ms_refdef);
	return true;
}

/* every client frame: the menu music follows the scene (play-test 2026-11-05: the menu "should have music") */
void
CL_MenuScene_Frame(void)
{
	qboolean want = CL_MenuScene_Active() && ms.music[0];

	if (want && !ms.musicon)
	{
		SNDH_MenuMusic(ms.music);
		ms.musicon = true;
	}
	else if (!want && ms.musicon)
	{
		SNDH_MenuMusic(NULL);
		ms.musicon = false;
	}
}
