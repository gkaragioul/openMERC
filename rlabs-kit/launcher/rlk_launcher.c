/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * RLabs kit: the compiled launcher in Contents/MacOS of a game app (a compiled program, not a script, so the app
 * is the process macOS starts and Game Mode applies to the game it becomes). It
 *   - finds the app's Contents folder from its own path,
 *   - makes ~/Library/Application Support/<game> (settings, saves) and ~/Library/Logs/<game>,
 *   - keeps the previous run's log (last-run.log -> previous-run.log) and sends the game's output to last-run.log,
 *   - sets the environment (RLK_ENV), changes to the work folder (RLK_WORKDIR) and replaces itself with the game
 *     program (RLK_PROGRAM) and its arguments (RLK_ARGS, then the app's own arguments without Finder's -psn_),
 *   - shows an alert when the program is missing or cannot be started.
 * {RES} {DATA} {LOGS} {HOME} in RLK_ENV and RLK_ARGS become Contents/Resources, the Application Support folder,
 * the Logs folder and the home folder.
 *
 * Compile-time settings (make-app.sh LAUNCHER_DEFS), e.g.
 *   -DRLK_GAME_NAME='"Soldier of Fortune"' -DRLK_PROGRAM='"Resources/engine/openMerc"'
 *   -DRLK_WORKDIR='"Resources/engine"' -DRLK_ENV='"XDG_DATA_HOME={DATA}","MTL_HUD_ENABLED=1"'
 *   -DRLK_ARGS='"-basedir","{RES}/game","-user","{DATA}/user"'
 *
 * This version was written on 2026-11-08 for the Soldier of Fortune port; it keeps the earlier kit's
 * behaviour and log lines.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef RLK_GAME_NAME
#error "define RLK_GAME_NAME"
#endif
#ifndef RLK_PROGRAM
#error "define RLK_PROGRAM (relative to Contents)"
#endif
#ifndef RLK_WORKDIR
#define RLK_WORKDIR "Resources"
#endif
#ifndef RLK_ENV
#define RLK_ENV NULL
#endif
#ifndef RLK_ARGS
#define RLK_ARGS NULL
#endif

static const char *const env_list[] = {RLK_ENV, NULL};
static const char *const arg_list[] = {RLK_ARGS, NULL};

static char res_dir[PATH_MAX], data_dir[PATH_MAX], logs_dir[PATH_MAX], home_dir[PATH_MAX];

/* a copy of s with {RES} {DATA} {LOGS} {HOME} replaced */
static char *
expand(const char *s)
{
	char out[2048];
	size_t n = 0;

	while (*s && n < sizeof out - 1)
	{
		const char *value = NULL;
		size_t skip = 0;

		if (!strncmp(s, "{RES}", 5))
		{
			value = res_dir, skip = 5;
		}
		else if (!strncmp(s, "{DATA}", 6))
		{
			value = data_dir, skip = 6;
		}
		else if (!strncmp(s, "{LOGS}", 6))
		{
			value = logs_dir, skip = 6;
		}
		else if (!strncmp(s, "{HOME}", 6))
		{
			value = home_dir, skip = 6;
		}

		if (value)
		{
			n += (size_t)snprintf(out + n, sizeof out - n, "%s", value);
			if (n > sizeof out - 1)
			{
				n = sizeof out - 1;
			}
			s += skip;
		}
		else
		{
			out[n++] = *s++;
		}
	}

	out[n] = 0;
	return strdup(out);
}

static void
make_dirs(char *path)
{
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
alert(const char *message)
{
	CFStringRef title = CFStringCreateWithCString(NULL, RLK_GAME_NAME, kCFStringEncodingUTF8);
	CFStringRef text = CFStringCreateWithCString(NULL, message, kCFStringEncodingUTF8);

	CFUserNotificationDisplayAlert(0, kCFUserNotificationStopAlertLevel, NULL, NULL, NULL, title, text, NULL, NULL,
		NULL, NULL);

	if (title)
	{
		CFRelease(title);
	}

	if (text)
	{
		CFRelease(text);
	}
}

int
main(int argc, char **argv)
{
	char exe[PATH_MAX], real[PATH_MAX], contents[PATH_MAX], path[PATH_MAX], program[PATH_MAX];
	char log_path[PATH_MAX], prev_path[PATH_MAX], stamp[64];
	uint32_t size = sizeof exe;
	const char *home;

	if (_NSGetExecutablePath(exe, &size) != 0 || !realpath(exe, real))
	{
		return 1;
	}

	snprintf(path, sizeof path, "%s/..", dirname(real));

	if (!realpath(path, contents))
	{
		return 1;
	}

	snprintf(res_dir, sizeof res_dir, "%s/Resources", contents);

	home = getenv("HOME");

	if (!home || !home[0])
	{
		const struct passwd *pw = getpwuid(getuid());

		if (!pw)
		{
			return 1;
		}

		home = pw->pw_dir;
	}

	snprintf(home_dir, sizeof home_dir, "%s", home);
	snprintf(data_dir, sizeof data_dir, "%s/Library/Application Support/%s", home, RLK_GAME_NAME);
	snprintf(logs_dir, sizeof logs_dir, "%s/Library/Logs/%s", home, RLK_GAME_NAME);
	snprintf(path, sizeof path, "%s", data_dir);
	make_dirs(path);
	snprintf(path, sizeof path, "%s", logs_dir);
	make_dirs(path);

	snprintf(program, sizeof program, "%s/%s", contents, RLK_PROGRAM);

	if (access(program, X_OK) != 0)
	{
		alert("The game program was not found inside the app. Reinstall the app.");
		return 1;
	}

	/* the run log: this run in last-run.log, the one before in previous-run.log */
	snprintf(log_path, sizeof log_path, "%s/last-run.log", logs_dir);
	snprintf(prev_path, sizeof prev_path, "%s/previous-run.log", logs_dir);
	rename(log_path, prev_path);

	{
		const int fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

		if (fd >= 0)
		{
			dup2(fd, 1);
			dup2(fd, 2);
			close(fd);
		}
	}

	{
		const time_t now = time(NULL);

		strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&now));
	}

	printf("[LAUNCHER] %s %s, app %s\n", RLK_GAME_NAME, stamp, contents);
	fflush(stdout);

	for (int i = 0; env_list[i]; i++)
	{
		char *e = expand(env_list[i]);
		char *eq = strchr(e, '=');

		if (eq)
		{
			*eq++ = 0;
			setenv(e, eq, 1);
			printf("[LAUNCHER] %s=%s\n", e, eq);
		}
	}

	fflush(stdout);

	snprintf(path, sizeof path, "%s/%s", contents, RLK_WORKDIR);

	if (chdir(path) != 0)
	{
		chdir(res_dir);
	}

	{
		int n = 0, count = 0;

		while (arg_list[count])
		{
			count++;
		}

		char **args = calloc((size_t)(count + argc + 1), sizeof *args);

		if (!args)
		{
			return 1;
		}

		args[n++] = program;

		for (int i = 0; i < count; i++)
		{
			args[n++] = expand(arg_list[i]);
		}

		for (int i = 1; i < argc; i++)
		{
			if (strncmp(argv[i], "-psn_", 5) != 0) /* Finder's process serial number */
			{
				args[n++] = argv[i];
			}
		}

		args[n] = NULL;
		execv(program, args);
	}

	fprintf(stderr, "[LAUNCHER] could not start %s: %s\n", program, strerror(errno));
	alert("The game could not be started. The run log in ~/Library/Logs has the details.");
	return 1;
}
