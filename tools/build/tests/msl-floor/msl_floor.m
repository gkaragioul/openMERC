/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Check for the oldest macOS the Metal renderer supports: every shader the game compiles is compiled as the
 * Metal Shading Language version of that macOS instead of the newest one this Mac knows.
 *
 * ref_metal compiles its shaders from source when it starts and when a level needs them (newLibraryWithSource
 * with no options, so the newest language version of the running macOS). On macOS 13 that version is 3.0. This
 * library is put in front of the game with DYLD_INSERT_LIBRARIES, sets languageVersion = 3.0 for every compile and
 * writes one line per shader library to the run log:
 *   [MSL-FLOOR] ok MSL 3.0, <characters>, functions: <names>
 *   [MSL-FLOOR] FAILED MSL 3.0, ... : <compiler message>
 * It proves the language level only: it cannot show how an older macOS's own compiler or drivers behave.
 * Built and explained by tools/build/tests/test-metal-msl-floor.sh. Not part of the game.
 */
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdio.h>

typedef id (*compile_fn)(id, SEL, NSString *, MTLCompileOptions *, NSError **);
static compile_fn original;

/* manual reference counting: the +1 object of the "new" method goes straight back to the caller */
static id
forced(id self, SEL cmd, NSString *source, MTLCompileOptions *options, NSError **error)
{
	MTLCompileOptions *o = options ? [options copy] : [[MTLCompileOptions alloc] init];
	NSError *e = nil;
	id<MTLLibrary> lib;

	o.languageVersion = MTLLanguageVersion3_0;
	lib = original(self, cmd, source, o, &e);
	fprintf(stderr, "[MSL-FLOOR] %s MSL 3.0, %lu characters, functions: %s%s%s\n", lib ? "ok" : "FAILED",
		(unsigned long)source.length, lib ? [[lib.functionNames componentsJoinedByString:@","] UTF8String] : "-",
		e ? " : " : "", e ? e.localizedDescription.UTF8String : "");
	[o release];

	if (error)
	{
		*error = e;
	}

	return lib;
}

__attribute__((constructor)) static void
install(void)
{
	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	Method m = class_getInstanceMethod(object_getClass(device), @selector(newLibraryWithSource:options:error:));

	if (!device || !m)
	{
		fprintf(stderr, "[MSL-FLOOR] no Metal device or compile method: nothing checked\n");
		return;
	}

	original = (compile_fn)method_setImplementation(m, (IMP)forced);
	fprintf(stderr, "[MSL-FLOOR] every shader is compiled as Metal Shading Language 3.0 (macOS 13) on %s\n",
		device.name.UTF8String);
}
