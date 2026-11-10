/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit: the player's own game files for an app that ships without them.
 *
 * A downloadable app must not carry the game. On its first start the launcher asks for the folder of the player's
 * own copy, checks that the needed files are there, copies them into ~/Library/Application Support/<game> and
 * starts the game from that copy. Later starts find the copy and ask nothing. The chosen folder is only read.
 *
 *   - the folder can also be named on the command line (--game-files <folder>): no question, same checks;
 *   - any folder at or above the files will do: the installed game's folder, its "base" folder, or the folder an
 *     installer was unpacked into (searched four folders deep, upper and lower case alike);
 *   - a choice with no game in it, or with files missing, gets a message that names what is missing;
 *   - files whose sizes are not those of the tested version get a warning, and can be used anyway;
 *   - the copy is an APFS clone when both folders are on one volume (no time, no space); a slow copy shows a
 *     small progress window.
 *
 * The folder search, the checks and the copy are plain functions (tests/rlk_gamedata_test.c); only
 * rlk_gamedata_ensure shows windows.
 */
#import <AppKit/AppKit.h>
#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "rlk_gamedata.h"

#define SEARCH_DEPTH 4     /* folders below the chosen one */
#define SEARCH_FOLDERS 4000 /* at most this many folders are opened (a whole home folder is not walked) */

/* the entry of dir whose name is `name` in any letter case, when it is a regular file that is not empty */
static int
find_entry(const char *dir, const char *name, char *path, size_t path_size, long long *size)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	int found = 0;

	if (!d)
	{
		return 0;
	}

	while (!found && (e = readdir(d)))
	{
		struct stat st;

		if (strcasecmp(e->d_name, name) != 0)
		{
			continue;
		}

		snprintf(path, path_size, "%s/%s", dir, e->d_name);

		if (stat(path, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0)
		{
			if (size)
			{
				*size = (long long)st.st_size;
			}

			found = 1;
		}
	}

	closedir(d);
	return found;
}

static void
append_name(char *list, size_t list_size, const char *name)
{
	const size_t n = strlen(list);

	if (list_size > n)
	{
		snprintf(list + n, list_size - n, "%s%s", n ? ", " : "", name);
	}
}

/* the required files dir lacks, as "a, b"; returns their number */
static int
missing_in(const rlk_gamedata_t *g, const char *dir, char *missing, size_t missing_size)
{
	char path[PATH_MAX];
	int count = 0;

	if (missing && missing_size)
	{
		missing[0] = 0;
	}

	for (int i = 0; g->required[i]; i++)
	{
		if (!find_entry(dir, g->required[i], path, sizeof path, NULL))
		{
			count++;

			if (missing)
			{
				append_name(missing, missing_size, g->required[i]);
			}
		}
	}

	return count;
}

int
rlk_gamedata_complete(const rlk_gamedata_t *g, const char *dir)
{
	return missing_in(g, dir, NULL, 0) == 0;
}

int
rlk_gamedata_locate(const rlk_gamedata_t *g, const char *chosen, char *found_dir, size_t found_size, char *missing,
	size_t missing_size)
{
	/* breadth first, so the folder nearest to the choice wins */
	typedef struct
	{
		char path[PATH_MAX];
		int depth;
	} item_t;

	item_t *queue = calloc(SEARCH_FOLDERS, sizeof *queue);
	int head = 0, tail = 0, result = 1;
	struct stat st;
	char path[PATH_MAX];

	found_dir[0] = 0;
	missing[0] = 0;

	if (!queue)
	{
		return 1;
	}

	snprintf(queue[0].path, sizeof queue[0].path, "%s", chosen);

	/* a chosen file (pak0.pak itself, say): its folder */
	if (stat(chosen, &st) == 0 && !S_ISDIR(st.st_mode))
	{
		char *slash = strrchr(queue[0].path, '/');

		if (slash && slash != queue[0].path)
		{
			*slash = 0;
		}
	}

	/* no trailing slash: paths are joined with one */
	{
		size_t n = strlen(queue[0].path);

		while (n > 1 && queue[0].path[n - 1] == '/')
		{
			queue[0].path[--n] = 0;
		}
	}

	queue[0].depth = 0;
	tail = 1;

	while (head < tail)
	{
		const item_t *it = &queue[head++];
		DIR *d;
		struct dirent *e;

		if (find_entry(it->path, g->required[0], path, sizeof path, NULL))
		{
			char lacks[512];

			if (missing_in(g, it->path, lacks, sizeof lacks) == 0)
			{
				snprintf(found_dir, found_size, "%s", it->path);
				missing[0] = 0;
				result = 0;
				break;
			}

			if (result == 1) /* remember the first incomplete folder, keep looking for a complete one */
			{
				snprintf(found_dir, found_size, "%s", it->path);
				snprintf(missing, missing_size, "%s", lacks);
				result = 2;
			}
		}

		if (it->depth >= SEARCH_DEPTH || !(d = opendir(it->path)))
		{
			continue;
		}

		while ((e = readdir(d)) && tail < SEARCH_FOLDERS)
		{
			if (e->d_name[0] == '.')
			{
				continue;
			}

			snprintf(path, sizeof path, "%s/%s", it->path, e->d_name);

			if (stat(path, &st) == 0 && S_ISDIR(st.st_mode))
			{
				snprintf(queue[tail].path, sizeof queue[tail].path, "%s", path);
				queue[tail].depth = it->depth + 1;
				tail++;
			}
		}

		closedir(d);
	}

	free(queue);
	return result;
}

int
rlk_gamedata_different(const rlk_gamedata_t *g, const char *found_dir, char *different, size_t different_size)
{
	char path[PATH_MAX];
	int count = 0;

	different[0] = 0;

	if (!g->sizes)
	{
		return 0;
	}

	for (int i = 0; g->required[i]; i++)
	{
		long long size = 0;

		if (find_entry(found_dir, g->required[i], path, sizeof path, &size) && size != g->sizes[i])
		{
			count++;
			append_name(different, different_size, g->required[i]);
		}
	}

	return count;
}

static void
make_dirs(const char *dir)
{
	char path[PATH_MAX];

	snprintf(path, sizeof path, "%s", dir);

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

static int
copy_one(const char *found_dir, const char *dest_dir, const char *name, int required)
{
	char src[PATH_MAX], tmp[PATH_MAX], dst[PATH_MAX];

	if (!find_entry(found_dir, name, src, sizeof src, NULL))
	{
		return required ? ENOENT : 0;
	}

	/* under a temporary name first: a file with its final name is always whole */
	snprintf(tmp, sizeof tmp, "%s/.incoming-%s", dest_dir, name);
	snprintf(dst, sizeof dst, "%s/%s", dest_dir, name);
	unlink(tmp);

	if (copyfile(src, tmp, NULL, COPYFILE_CLONE) != 0)
	{
		const int err = errno ? errno : EIO;

		unlink(tmp);
		return err;
	}

	chmod(tmp, 0644); /* files from a CD are read-only */

	if (rename(tmp, dst) != 0)
	{
		const int err = errno ? errno : EIO;

		unlink(tmp);
		return err;
	}

	return 0;
}

int
rlk_gamedata_copy(const rlk_gamedata_t *g, const char *found_dir, const char *dest_dir, char *failed,
	size_t failed_size)
{
	char a[PATH_MAX], b[PATH_MAX];

	failed[0] = 0;
	make_dirs(dest_dir);

	/* the player chose the app's own copy: nothing to do */
	if (realpath(found_dir, a) && realpath(dest_dir, b) && !strcmp(a, b))
	{
		return 0;
	}

	for (int i = 0; g->required[i]; i++)
	{
		const int err = copy_one(found_dir, dest_dir, g->required[i], 1);

		if (err)
		{
			snprintf(failed, failed_size, "%s", g->required[i]);
			return err;
		}
	}

	for (int i = 0; g->optional && g->optional[i]; i++)
	{
		const int err = copy_one(found_dir, dest_dir, g->optional[i], 0);

		if (err)
		{
			snprintf(failed, failed_size, "%s", g->optional[i]);
			return err;
		}
	}

	return 0;
}

/* ---- windows ---------------------------------------------------------------------------------------------- */

static NSString *
str(const char *s)
{
	return [NSString stringWithUTF8String:s ? s : ""] ?: @"";
}

static void
bring_forward(void)
{
	if (@available(macOS 14.0, *))
	{
		[NSApp activate];
	}
	else
	{
		[NSApp activateIgnoringOtherApps:YES];
	}
}

/* the number of the button pressed, counted from 0 */
static int
ask(NSString *title, NSString *text, NSArray<NSString *> *buttons, NSAlertStyle style)
{
	NSAlert *alert = [[NSAlert alloc] init];

	alert.messageText = title;
	alert.informativeText = text;
	alert.alertStyle = style;

	for (NSString *b in buttons)
	{
		[alert addButtonWithTitle:b];
	}

	bring_forward();
	return (int)([alert runModal] - NSAlertFirstButtonReturn);
}

/* the copy on another thread; a small window when it takes longer than a moment */
static int
copy_with_progress(const rlk_gamedata_t *g, const char *found_dir, const char *dest_dir, char *failed,
	size_t failed_size)
{
	__block int result = 0;
	__block atomic_int done = 0;
	NSWindow *window = nil;
	const NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		result = rlk_gamedata_copy(g, found_dir, dest_dir, failed, failed_size);
		atomic_store(&done, 1);
	});

	while (!atomic_load(&done))
	{
		NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
			untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05] inMode:NSDefaultRunLoopMode dequeue:YES];

		if (event)
		{
			[NSApp sendEvent:event];
		}

		if (!window && [NSDate timeIntervalSinceReferenceDate] - started > 0.4)
		{
			NSTextField *label = [NSTextField labelWithString:@"Copying your game files…"];
			NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 20, 320, 20)];

			window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 90)
				styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
			window.title = str(g->game_name);
			window.releasedWhenClosed = NO;
			label.frame = NSMakeRect(20, 50, 320, 20);
			bar.indeterminate = YES;
			bar.style = NSProgressIndicatorStyleBar;
			[bar startAnimation:nil];
			[window.contentView addSubview:label];
			[window.contentView addSubview:bar];
			[window center];
			[window makeKeyAndOrderFront:nil];
			bring_forward();
		}
	}

	if (window)
	{
		[window orderOut:nil];
		[window close];
	}

	return result;
}

int
rlk_gamedata_ensure(const rlk_gamedata_t *g, const char *dest_dir, const char *given)
{
	if (!given && rlk_gamedata_complete(g, dest_dir))
	{
		printf("[LAUNCHER] game files: %s\n", dest_dir);
		fflush(stdout);
		return 1;
	}

	if (given)
	{
		printf("[LAUNCHER] game files: --game-files %s\n", given);
	}
	else
	{
		printf("[LAUNCHER] game files: not in %s yet, asking for them\n", dest_dir);
	}

	fflush(stdout);

	@autoreleasepool
	{
		NSString *name = str(g->game_name);
		NSString *note = str(g->version_note);
		int asked = 0;

		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		[NSApp finishLaunching];

		for (;;)
		{
			char found[PATH_MAX], names[512], failed[256];
			NSOpenPanel *panel;
			NSString *chosen;
			int state, err;

			if (given) /* named on the command line: the first choice, no question */
			{
				chosen = str(given);
				given = NULL;
				asked = 1;
			}
			else
			{
				chosen = nil;

				if (!asked)
				{
					asked = 1;

					if (ask([NSString stringWithFormat:@"Choose your %@ game files", name], str(g->intro),
							@[@"Choose Folder…", @"Quit"], NSAlertStyleInformational) != 0)
					{
						printf("[LAUNCHER] game files: the player quit\n");
						fflush(stdout);
						return 0;
					}
				}

				panel = [NSOpenPanel openPanel];
				panel.canChooseDirectories = YES;
				panel.canChooseFiles = YES;
				panel.allowsMultipleSelection = NO;
				panel.message = [NSString stringWithFormat:@"Choose the folder of your own copy of %@", name];
				panel.prompt = @"Choose";
				bring_forward();

				if ([panel runModal] != NSModalResponseOK || !panel.URL.path)
				{
					asked = 0; /* cancelled: back to the first question, which can quit */
					continue;
				}

				chosen = panel.URL.path;
			}

			state = rlk_gamedata_locate(g, chosen.fileSystemRepresentation, found, sizeof found, names, sizeof names);
			printf("[LAUNCHER] game files: chosen %s -> %s%s\n", chosen.fileSystemRepresentation,
				state == 0 ? "found in " : state == 2 ? "incomplete in " : "none", found);

			if (state == 2)
			{
				printf("[LAUNCHER] game files: missing %s\n", names);
			}

			fflush(stdout);

			if (state == 1)
			{
				if (ask([NSString stringWithFormat:@"No game files in “%@”", chosen.lastPathComponent],
						[NSString stringWithFormat:@"%s was not found in this folder or in the folders inside it.\n\n"
							"Choose the folder where %@ is installed, or the folder that holds its .pak files.",
							g->required[0], name],
						@[@"Choose Again", @"Quit"], NSAlertStyleWarning) != 0)
				{
					return 0;
				}

				continue;
			}

			if (state == 2)
			{
				if (ask(@"Some game files are missing",
						[NSString stringWithFormat:@"The game was found in “%@”, but these files are missing there:\n\n"
							"%s\n\n%@", str(found).lastPathComponent, names, note],
						@[@"Choose Again", @"Quit"], NSAlertStyleWarning) != 0)
				{
					return 0;
				}

				continue;
			}

			if (rlk_gamedata_different(g, found, names, sizeof names))
			{
				printf("[LAUNCHER] game files: not the tested sizes: %s\n", names);
				fflush(stdout);

				if (ask(@"These are not the files this app was tested with",
						[NSString stringWithFormat:@"These files have another size than expected:\n\n%s\n\n%@\n\n"
							"You can use them anyway, but the game may not work properly.", names, note],
						@[@"Choose Again", @"Use Them Anyway"], NSAlertStyleWarning) == 0)
				{
					continue;
				}
			}

			err = copy_with_progress(g, found, dest_dir, failed, sizeof failed);

			if (err || !rlk_gamedata_complete(g, dest_dir))
			{
				printf("[LAUNCHER] game files: copying %s failed: %s\n", failed, strerror(err));
				fflush(stdout);

				if (ask(@"The game files could not be copied",
						[NSString stringWithFormat:@"%s: %s.\n\nThe files go to “%s”.", failed[0] ? failed : "Copy",
							err == ENOSPC ? "there is not enough free space on your disk" : strerror(err), dest_dir],
						@[@"Choose Again", @"Quit"], NSAlertStyleCritical) != 0)
				{
					return 0;
				}

				continue;
			}

			/* the choice, for the player and for problem reports (the copy itself is what later starts use) */
			{
				char note_path[PATH_MAX], stamp[64];
				const time_t now = time(NULL);
				FILE *f;

				strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&now));
				snprintf(note_path, sizeof note_path, "%s/../chosen-folder.txt", dest_dir);

				if ((f = fopen(note_path, "w")))
				{
					fprintf(f, "%s\ncopied from: %s\non: %s\nDelete this folder to choose your game files again.\n",
						g->game_name, found, stamp);
					fclose(f);
				}
			}

			printf("[LAUNCHER] game files: copied from %s to %s\n", found, dest_dir);
			fflush(stdout);
			return 1;
		}
	}
}
