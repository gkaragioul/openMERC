/* SPDX-License-Identifier: GPL-2.0-or-later
 * OpenMerc (sof-openmerc-macos): module-load check for the macOS build.
 *
 * dlopen()s a module and resolves the entry point the engine looks up, which is the property
 * the Mach-O exported_symbols_list has to satisfy. Exit code 0 = resolved, 1 = dlopen failed,
 * 2 = entry point missing. Compiled by tools/build/check-modules-macos.sh.
 */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
	if (argc != 3)
	{
		fprintf(stderr, "usage: %s <module> <symbol>\n", argv[0]);
		return 64;
	}

	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h)
	{
		printf("dlopen FAILED: %s\n", dlerror());
		return 1;
	}

	void *sym = dlsym(h, argv[2]);
	if (!sym)
	{
		printf("dlsym('%s') MISSING: %s\n", argv[2], dlerror());
		return 2;
	}

	printf("ok: %s -> %s = %p\n", argv[1], argv[2], sym);
	return 0;
}
