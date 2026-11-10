/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit check: the launcher's game-file search, checks and copy (launcher/rlk_gamedata.m) on made-up folders.
 * No game data is used: the "pak" files are a few bytes each. Run by tests/run-gamedata-test.sh.
 *   rlk_gamedata_test <empty work folder>
 */
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "rlk_gamedata.h"

static int passed, failed_count;

#define CHECK(cond, ...) \
	do \
	{ \
		if (cond) \
		{ \
			passed++; \
		} \
		else \
		{ \
			failed_count++; \
			printf("FAIL %s:%d: ", __FILE__, __LINE__); \
			printf(__VA_ARGS__); \
			printf("\n"); \
		} \
	} while (0)

static const char *const required[] = {"pak0.pak", "pak1.pak", "pak2.pak", "pak3.pak", NULL};
static const long long sizes[] = {5, 6, 7, 8};
static const char *const optional[] = {"gs.pak", NULL};
static const rlk_gamedata_t game = {"Test Game", required, sizes, optional, "intro", "note"};

static char root[PATH_MAX];

static const char *
at(const char *rel)
{
	static char buf[8][PATH_MAX];
	static int n;
	char *p = buf[n++ & 7];

	snprintf(p, PATH_MAX, "%s/%s", root, rel);
	return p;
}

static void
dirs(const char *rel)
{
	char path[PATH_MAX];

	snprintf(path, sizeof path, "%s/%s", root, rel);

	for (char *p = path + 1; *p; p++)
	{
		if (*p == '/')
		{
			*p = 0;
			mkdir(path, 0755);
			*p = '/';
		}
	}

	mkdir(path, 0755);
}

static void
put(const char *rel, int bytes)
{
	FILE *f = fopen(at(rel), "w");

	for (int i = 0; f && i < bytes; i++)
	{
		fputc('a' + i % 26, f);
	}

	if (f)
	{
		fclose(f);
	}
}

/* a folder with the four files in the tested sizes */
static void
game_in(const char *rel)
{
	char p[PATH_MAX];

	dirs(rel);

	for (int i = 0; required[i]; i++)
	{
		snprintf(p, sizeof p, "%s/%s", rel, required[i]);
		put(p, (int)sizes[i]);
	}
}

static long long
size_of(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0 ? (long long)st.st_size : -1;
}

static int
remove_one(const char *path, const struct stat *st, int flag, struct FTW *ftw)
{
	(void)st;
	(void)flag;
	(void)ftw;
	chmod(path, 0755);
	return remove(path);
}

int
main(int argc, char **argv)
{
	char found[PATH_MAX], names[512], failed[256];
	int r;

	if (argc != 2 || !realpath(argv[1], root))
	{
		fprintf(stderr, "usage: rlk_gamedata_test <empty work folder>\n");
		return 2;
	}

	/* 1 the folder that holds the files */
	game_in("plain");
	r = rlk_gamedata_locate(&game, at("plain"), found, sizeof found, names, sizeof names);
	CHECK(r == 0 && !strcmp(found, at("plain")), "plain folder: %d %s", r, found);
	CHECK(rlk_gamedata_complete(&game, at("plain")), "plain folder is complete");
	r = rlk_gamedata_locate(&game, at("plain/"), found, sizeof found, names, sizeof names);
	CHECK(r == 0 && !strcmp(found, at("plain")), "trailing slash: %d %s", r, found);

	/* 2 the installed game's folder: files in base */
	game_in("installed/Soldier of Fortune/base");
	r = rlk_gamedata_locate(&game, at("installed/Soldier of Fortune"), found, sizeof found, names, sizeof names);
	CHECK(r == 0 && !strcmp(found, at("installed/Soldier of Fortune/base")), "installed game: %d %s", r, found);

	/* 3 an unpacked installer, chosen two folders above the files */
	game_in("unpacked/Game_Data_Files/base");
	r = rlk_gamedata_locate(&game, at("unpacked"), found, sizeof found, names, sizeof names);
	CHECK(r == 0 && !strcmp(found, at("unpacked/Game_Data_Files/base")), "unpacked installer: %d %s", r, found);

	/* 4 a file was chosen instead of a folder */
	r = rlk_gamedata_locate(&game, at("plain/pak1.pak"), found, sizeof found, names, sizeof names);
	CHECK(r == 0 && !strcmp(found, at("plain")), "chosen file: %d %s", r, found);

	/* 5 upper-case names, as some Windows copies have them */
	dirs("upper/BASE");
	put("upper/BASE/PAK0.PAK", 5);
	put("upper/BASE/Pak1.pak", 6);
	put("upper/BASE/PAK2.PAK", 7);
	put("upper/BASE/PAK3.PAK", 8);
	put("upper/BASE/GS.PAK", 3);
	r = rlk_gamedata_locate(&game, at("upper"), found, sizeof found, names, sizeof names);
	CHECK(r == 0 && !strcmp(found, at("upper/BASE")), "upper case: %d %s", r, found);

	/* 6 an older game: two files missing; an empty file counts as missing */
	dirs("old/base");
	put("old/base/pak0.pak", 5);
	put("old/base/pak1.pak", 6);
	put("old/base/pak3.pak", 0);
	r = rlk_gamedata_locate(&game, at("old"), found, sizeof found, names, sizeof names);
	CHECK(r == 2 && !strcmp(found, at("old/base")) && !strcmp(names, "pak2.pak, pak3.pak"), "old game: %d %s [%s]",
		r, found, names);
	CHECK(!rlk_gamedata_complete(&game, at("old/base")), "old game is not complete");

	/* 7 no game at all */
	dirs("other/stuff");
	put("other/stuff/readme.txt", 4);
	r = rlk_gamedata_locate(&game, at("other"), found, sizeof found, names, sizeof names);
	CHECK(r == 1 && !found[0] && !names[0], "no game: %d %s [%s]", r, found, names);
	r = rlk_gamedata_locate(&game, at("does-not-exist"), found, sizeof found, names, sizeof names);
	CHECK(r == 1, "missing folder: %d", r);

	/* 8 an incomplete folder first, a complete one deeper: the complete one */
	dirs("both");
	put("both/pak0.pak", 5);
	game_in("both/full/base");
	r = rlk_gamedata_locate(&game, at("both"), found, sizeof found, names, sizeof names);
	CHECK(r == 0 && !strcmp(found, at("both/full/base")) && !names[0], "complete one wins: %d %s [%s]", r, found,
		names);

	/* 9 four folders down is found, five is not */
	game_in("deep4/a/b/c/d");
	r = rlk_gamedata_locate(&game, at("deep4"), found, sizeof found, names, sizeof names);
	CHECK(r == 0, "four folders down: %d", r);
	game_in("deep5/a/b/c/d/e");
	r = rlk_gamedata_locate(&game, at("deep5"), found, sizeof found, names, sizeof names);
	CHECK(r == 1, "five folders down: %d", r);

	/* 10 the tested version by size */
	r = rlk_gamedata_different(&game, at("plain"), names, sizeof names);
	CHECK(r == 0 && !names[0], "tested sizes: %d [%s]", r, names);
	game_in("patched");
	put("patched/pak1.pak", 60);
	put("patched/pak3.pak", 80);
	r = rlk_gamedata_different(&game, at("patched"), names, sizeof names);
	CHECK(r == 2 && !strcmp(names, "pak1.pak, pak3.pak"), "other sizes: %d [%s]", r, names);

	/* 11 the copy: lower-case names, optional file too, source untouched (it is read-only here) */
	chmod(at("upper/BASE/PAK0.PAK"), 0444);
	chmod(at("upper/BASE"), 0555);
	CHECK(!rlk_gamedata_complete(&game, at("dest/game/base")), "destination starts empty");
	r = rlk_gamedata_copy(&game, at("upper/BASE"), at("dest/game/base"), failed, sizeof failed);
	CHECK(r == 0 && !failed[0], "copy: %d [%s]", r, failed);
	CHECK(rlk_gamedata_complete(&game, at("dest/game/base")), "destination complete after the copy");
	{
		/* exact names as stored (the disk may not tell letter case apart, so read the folder) */
		char cmd[PATH_MAX + 64], line[256], all[512] = "";
		FILE *p;

		snprintf(cmd, sizeof cmd, "ls -A '%s' | sort | tr '\\n' ' '", at("dest/game/base"));
		p = popen(cmd, "r");

		if (p)
		{
			while (fgets(line, sizeof line, p))
			{
				strncat(all, line, sizeof all - strlen(all) - 1);
			}

			pclose(p);
		}

		CHECK(!strcmp(all, "gs.pak pak0.pak pak1.pak pak2.pak pak3.pak "), "copied names: [%s]", all);

		snprintf(cmd, sizeof cmd, "ls -A '%s' | sort | tr '\\n' ' '", at("upper/BASE"));
		all[0] = 0;
		p = popen(cmd, "r");

		if (p)
		{
			while (fgets(line, sizeof line, p))
			{
				strncat(all, line, sizeof all - strlen(all) - 1);
			}

			pclose(p);
		}

		CHECK(!strcmp(all, "GS.PAK PAK0.PAK PAK1.PAK PAK2.PAK PAK3.PAK ") ||
			!strcmp(all, "GS.PAK PAK0.PAK PAK2.PAK PAK3.PAK Pak1.pak "), "source names unchanged: [%s]", all);
	}
	CHECK(size_of(at("dest/game/base/pak2.pak")) == 7 && size_of(at("dest/game/base/gs.pak")) == 3, "copied sizes");
	CHECK(access(at("dest/game/base/pak0.pak"), W_OK) == 0, "the copy of a read-only file can be replaced later");
	CHECK(size_of(at("upper/BASE/PAK0.PAK")) == 5 && access(at("upper/BASE/PAK0.PAK"), W_OK) != 0,
		"the source file is as it was");
	chmod(at("upper/BASE"), 0755);

	/* 12 no optional file: still fine; copying a folder onto itself: nothing happens */
	r = rlk_gamedata_copy(&game, at("plain"), at("dest2/base"), failed, sizeof failed);
	CHECK(r == 0 && rlk_gamedata_complete(&game, at("dest2/base")) && size_of(at("dest2/base/gs.pak")) == -1,
		"copy without the optional file: %d", r);
	r = rlk_gamedata_copy(&game, at("plain"), at("plain"), failed, sizeof failed);
	CHECK(r == 0 && size_of(at("plain/pak0.pak")) == 5, "copy onto itself: %d", r);

	/* 13 a copy that cannot be written reports the file and the reason, and leaves no half file */
	dirs("locked/base");
	chmod(at("locked/base"), 0555);
	r = rlk_gamedata_copy(&game, at("plain"), at("locked/base"), failed, sizeof failed);
	CHECK(r != 0 && !strcmp(failed, "pak0.pak"), "locked destination: %d [%s]", r, failed);
	CHECK(!rlk_gamedata_complete(&game, at("locked/base")), "locked destination is not complete");
	chmod(at("locked/base"), 0755);

	/* 14 a source that loses a file between the check and the copy */
	r = rlk_gamedata_copy(&game, at("old/base"), at("dest3/base"), failed, sizeof failed);
	CHECK(r == ENOENT && !strcmp(failed, "pak2.pak"), "source lacks a file: %d [%s]", r, failed);
	CHECK(!rlk_gamedata_complete(&game, at("dest3/base")), "partial copy is not complete");

	nftw(root, remove_one, 16, FTW_DEPTH | FTW_PHYS); /* the made-up folders of this run */
	printf("rlk_gamedata: %d passed, %d failed\n", passed, failed_count);
	return failed_count ? 1 : 0;
}
