#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Native Metal Ghoul hand-off regression gate.  Exercises the built dylib's
# exported surface and dependency references; it does not inspect source text.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
dylib=${1:-"$root/build-macos-arm64-Release/engine/release/ref_metal.dylib"}
engine=${OM_METAL_ENGINE:-"$root/build-macos-arm64-Release/engine/release/openMerc"}

if [[ ! -f "$dylib" ]]; then
	echo "FAIL: ref_metal dylib not found: $dylib" >&2
	exit 1
fi

if [[ ! -x "$engine" ]]; then
	echo "FAIL: openMerc executable not found: $engine" >&2
	exit 1
fi

if ! nm -gU "$dylib" | awk '{print $NF}' | grep -qx '_OM_GetSoFRefExports'; then
	echo "FAIL: ref_metal does not export OM_GetSoFRefExports" >&2
	exit 1
fi

forbidden='OpenGL|CGL|NSOpenGL|Vulkan|MoltenVK|ANGLE|SPIRV-Cross'
if otool -L "$dylib" | grep -E "$forbidden" >/dev/null || nm -u "$dylib" | grep -E "$forbidden" >/dev/null; then
	echo "FAIL: ref_metal has a forbidden graphics dependency" >&2
	exit 1
fi

for symbol in _OMGhoul_SetNativeSink _OMGhoul_FindInstance _OMGhoul_DrawInstance; do
	# Do the exact-match check in awk so it reads the complete dyld_info output.
	# A grep -q consumer can close the pipe early; with pipefail that turns the
	# producer's harmless SIGPIPE into a false failed gate.
	if ! dyld_info -exports "$engine" 2>&1 | awk -v symbol="$symbol" '
		$NF == symbol { found = 1 }
		END { exit found ? 0 : 1 }
	'; then
		echo "FAIL: openMerc does not dynamically export $symbol" >&2
		exit 1
	fi
done

echo "PASS: ref_metal exposes native Ghoul hand-off without translation dependencies"
