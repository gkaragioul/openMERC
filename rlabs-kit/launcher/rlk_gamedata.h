/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit: the player's own game files for an app that ships without them (rlk_gamedata.m).
 * Used by rlk_launcher.c when it is compiled with RLK_DATA_FILES.
 */
#ifndef RLK_GAMEDATA_H
#define RLK_GAMEDATA_H

#include <stddef.h>

typedef struct
{
	const char *game_name;        /* "Soldier of Fortune": window titles */
	const char *const *required;  /* NULL-terminated; the first one is the file a game folder is recognised by */
	const long long *sizes;       /* size of each required file in the tested version, or NULL: no version check */
	const char *const *optional;  /* NULL-terminated or NULL: copied when present beside the required files */
	const char *intro;            /* first question: which folder to choose */
	const char *version_note;     /* added to "files are missing" and "not the tested version" */
} rlk_gamedata_t;

/* 1 when every required file is in dir (as a regular file that is not empty) */
int rlk_gamedata_complete(const rlk_gamedata_t *g, const char *dir);

/*
 * Looks for the game files in the chosen folder (or, for a chosen file, in its folder) and up to four folders
 * below it. Returns
 *    0  found: found_dir holds the folder with every required file
 *    1  the first required file is nowhere in the chosen folder
 *    2  a folder with the first required file was found (found_dir) but files are missing (missing: "a, b")
 */
int rlk_gamedata_locate(const rlk_gamedata_t *g, const char *chosen, char *found_dir, size_t found_size,
	char *missing, size_t missing_size);

/* required files of found_dir whose size is not the tested one, as "a, b" in different; returns their number */
int rlk_gamedata_different(const rlk_gamedata_t *g, const char *found_dir, char *different, size_t different_size);

/*
 * Copies the required and optional files from found_dir into dest_dir under their lower-case names (an APFS
 * clone when both are on one volume, so it takes no time and no space). found_dir is only read. Returns 0, or an
 * errno value with the file's name in failed.
 */
int rlk_gamedata_copy(const rlk_gamedata_t *g, const char *found_dir, const char *dest_dir, char *failed,
	size_t failed_size);

/*
 * The whole first start: nothing when dest_dir is complete; otherwise asks for the folder, explains what is wrong
 * with a choice, copies, and notes the choice in <dest_dir>/../chosen-folder.txt. Returns 1 when the game can
 * start, 0 when the player chose to quit.
 * given: a folder named on the command line (--game-files <folder>), or NULL. It is taken as the first choice
 * without a question, also when dest_dir is complete already (the way to bring in another copy of the game); a
 * wrong folder gets the same messages as a wrong choice in the window.
 */
int rlk_gamedata_ensure(const rlk_gamedata_t *g, const char *dest_dir, const char *given);

#endif
