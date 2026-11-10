#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds msl-floor/msl_floor.m, the library that makes the game compile every shader as Metal Shading Language
# 3.0 (the language of macOS 13, the oldest macOS the build targets), and prints how to use it:
#   tools/build/tests/test-metal-msl-floor.sh [out dir]      (default: a temporary folder)
# Then start the engine once with the printed DYLD_INSERT_LIBRARIES, visit levels that use every effect (a
# landscape level, fog, water, the Quality graphics setting), and read the [MSL-FLOOR] lines of the run log:
# "FAILED" names a shader that an older macOS could not compile. The count of "ok" lines is the number of shader
# libraries the run reached; ref_metal has 16 compile sites (grep newLibraryWithSource).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:-$(mktemp -d "${TMPDIR:-/tmp}/msl-floor.XXXXXX")}
mkdir -p "$OUT"
clang -arch arm64 -dynamiclib -fno-objc-arc -O1 -Wall "$HERE/msl-floor/msl_floor.m" -framework Metal -framework Foundation \
  -o "$OUT/libmslfloor.dylib"
echo "DYLD_INSERT_LIBRARIES=$OUT/libmslfloor.dylib"
