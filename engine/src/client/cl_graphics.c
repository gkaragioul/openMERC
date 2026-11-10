/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs graphics settings (design decision 2026-11-05: "I would prefer 3 graphics settings
 * and thats it"; then "What if i want to play on battery but have 120hz full performance? ... Battery should be one
 * setting, easier to get"). The player picks one of three; the port picks every effect:
 *
 *   Performance (120 fps)            only the effects that hold 120 at native resolution on the test Mac
 *   Quality (60 fps, best looks)     every effect the port has
 *   Battery (60 fps, saves power)    light
 *
 * Nothing changes by itself: Performance stays 120 fps on battery and in Low Power Mode. r_graphics 0/1/2 is the
 * choice (Video page). The effect cvars below stay in the config file and console for testing; a change of the
 * setting writes them again. The contents of each setting are measured per game and recorded on the game's page.
 */

#include "header/client.h"

typedef struct
{
	const char *cvar;
	const char *value[3]; /* Performance, Quality, Battery */
} gfx_row_t;

/* SoF on the M5 Pro (2026-11-05): the sets below follow the measured GPU times */
static const gfx_row_t gfx_rows[] = {
	{"vid_maxfps", {"120", "60", "60"}},
	{"r_om_bloom", {"1", "1", "0"}},
	{"r_om_volfog", {"1", "1", "0"}},
	{"r_om_pdlight", {"1", "1", "0"}},
	{"r_om_softparticles", {"1", "1", "0"}},
	{"r_om_overbright", {"0", "0", "0"}}, /* not in the original game */
	{"r_anisotropic", {"16", "16", "4"}},
	{"gl_texturemode", {"GL_LINEAR_MIPMAP_LINEAR", "GL_LINEAR_MIPMAP_LINEAR", "GL_LINEAR_MIPMAP_NEAREST"}},
	{"gl_detailtexturing", {"1", "1", "0"}},
	{"ghl_light_method", {"3", "3", "1"}},
	{"ghl_specular", {"1", "1", "0"}},
	{NULL, {NULL, NULL, NULL}}
};

static const char *gfx_names[3] = {"Performance (120 fps)", "Quality (60 fps, best looks)",
	"Battery (60 fps, saves power)"};

static cvar_t *r_graphics;
static int gfx_applied = -1;

void
CL_Graphics_Init(void)
{
	r_graphics = Cvar_Get("r_graphics", "0", CVAR_ARCHIVE);
}

/* every client frame: cheap unless the choice changed */
void
CL_Graphics_Frame(void)
{
	int choice, i;

	if (!r_graphics || (!r_graphics->modified && gfx_applied >= 0))
	{
		return;
	}

	r_graphics->modified = false;
	choice = (int)r_graphics->value;

	if (choice < 0 || choice > 2)
	{
		choice = 0;
	}

	if (choice == gfx_applied)
	{
		return;
	}

	for (i = 0; gfx_rows[i].cvar; i++)
	{
		Cvar_Set((char *)gfx_rows[i].cvar, (char *)gfx_rows[i].value[choice]);
	}

	Com_Printf("graphics: %s\n", gfx_names[choice]);
	gfx_applied = choice;
}
