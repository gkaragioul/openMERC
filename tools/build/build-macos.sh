#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the fully open OpenMerc on macOS (Apple Silicon, arm64) with CMake + Ninja
# (docs/BUILD-macos.md):
#   engine (openMerc, openMerc-ded, ref_gl3, Ghoul, sofpm_test, omghoul_test),
#   game module (gamex86.so), player module (player.so), sound module (OMsnd.so on OpenAL Soft,
#   skipped when the library is absent), OpenMerc's data archive (zz_openmerc.pak), staged into one
#   directory, then the unit tests.
#
# usage: tools/build/build-macos.sh [arm64] [Release|Debug]
# env:   OM_BUILD_DIR  build root (default <repo>/build-macos-<arch>-<cfg>)
#        OM_NO_TESTS=1 skip the unit tests
#        OM_JOBS       parallel jobs (default: number of CPUs)
#        OM_SDL3_PREFIX  Homebrew prefix for SDL3 (default: /opt/homebrew)
#        OM_SKIP_SOUND=1 do not build OMsnd even if OpenAL Soft is installed
#        RLABS_KIT     another RLabs kit folder (default: <repo>/rlabs-kit, docs/BUILD-macos.md)
# Output: <build root>/release/ - openMerc, openMerc-ded, ref_gl3.dylib, OMsnd.so,
#         base/gamex86.so, base/player.so, base/zz_openmerc.pak. Add the game data (pak files)
#         yourself; none is shipped.
set -euo pipefail

ARCH=${1:-arm64}
CFG=${2:-Release}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=${OM_BUILD_DIR:-$REPO/build-macos-$ARCH-$CFG}
JOBS=${OM_JOBS:-$(sysctl -n hw.ncpu)}
SDL3_PREFIX=${OM_SDL3_PREFIX:-/opt/homebrew}
OPENAL_PREFIX=${OM_OPENAL_PREFIX:-/opt/homebrew/opt/openal-soft}

case "$ARCH" in
  arm64|aarch64) ARCH=arm64; FLAGS="-arch arm64" ;;
  *) echo "unknown arch '$ARCH' (only arm64; Intel Macs are not a target)" >&2; exit 2 ;;
esac

# SDL3 from Homebrew carries its own CMake config; make it discoverable without a global install.
export CMAKE_PREFIX_PATH="$SDL3_PREFIX:$OPENAL_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig:$OPENAL_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

for t in cmake ninja clang python3; do
  command -v "$t" >/dev/null || { echo "missing tool: $t (see docs/BUILD-macos.md)" >&2; exit 1; }
done
[ -d "$SDL3_PREFIX/lib/cmake/SDL3" ] || {
  echo "SDL3 not found under $SDL3_PREFIX (brew install sdl3, or set OM_SDL3_PREFIX)" >&2; exit 1; }

# The renderers and modules are MODULE libraries; on Darwin CMake already names them .dylib/.so as the
# engine's loader expects (ref_<name>.dylib, gamex86.so, player.so, OMsnd.so).
configure() { # <source> <build> [extra args]
  local src=$1 bld=$2 fresh=""; shift 2
  # a tree configured in another folder (the project was moved) makes CMake stop: configure it afresh
  if [ -f "$bld/CMakeCache.txt" ] && ! grep -qxF "CMAKE_HOME_DIRECTORY:INTERNAL=$src" "$bld/CMakeCache.txt"; then
    echo "   $bld was configured for another folder: configuring afresh"
    fresh=--fresh
  fi
  cmake $fresh -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE="$CFG" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$FLAGS" -DCMAKE_MODULE_LINKER_FLAGS="$FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$FLAGS" "$@"
  cmake --build "$bld" -j "$JOBS"
}

echo "== engine";  configure "$REPO/engine" "$OUT/engine" -DCURL_SUPPORT=OFF
echo "== game";    configure "$REPO/game"   "$OUT/game"
echo "== player";  configure "$REPO/player" "$OUT/player"

SOUND=0
if [ "${OM_SKIP_SOUND:-0}" != "1" ] && [ -d "$OPENAL_PREFIX/lib/cmake/OpenAL" ]; then
  SOUND=1
fi
if [ "$SOUND" = "1" ]; then
  echo "== sound"; configure "$REPO/modules/sound" "$OUT/sound"
else
  echo "== sound: skipped (no OpenAL Soft in $OPENAL_PREFIX; brew install openal-soft)"
fi

echo "== staging"
REL=$OUT/release
mkdir -p "$REL/base"
cp -f "$OUT/engine/release/openMerc" "$OUT/engine/release/openMerc-ded" "$REL/"
for r in ref_gl3.dylib ref_gles3.dylib ref_metal.dylib; do [ -f "$OUT/engine/release/$r" ] && cp -f "$OUT/engine/release/$r" "$REL/"; done
[ "$SOUND" = "1" ] && cp -f "$OUT/sound/OMsnd.dylib" "$REL/"
cp -f "$OUT/game/gamex86.dylib" "$OUT/player/player.dylib" "$REL/base/"
python3 "$REPO/tools/mkpak.py" "$REPO/data/base" "$REL/base/zz_openmerc.pak"
# openMERC reads its own data only from <exe dir>/openmerc-data on macOS (Linux: openmerc, as the Linux package lays it out); keep a copy there
# so dev runs from release/ get openMERC's menus, fonts and modern key defaults
mkdir -p "$REL/openmerc-data"
cp -f "$REL/base/gamex86.dylib" "$REL/base/player.dylib" "$REL/base/zz_openmerc.pak" "$REL/openmerc-data/"

if [ "${OM_NO_TESTS:-0}" != "1" ]; then
  echo "== unit tests"
  rc=0
  "$OUT/engine/sofpm_test" || rc=1
  "$OUT/player/pm_unit" || rc=1
  [ -x "$OUT/game/g3tests" ] && { "$OUT/game/g3tests" ${OM_G3_FIXTURES:-} || rc=1; }
  "$OUT/engine/src/ghoul/omghoul_test" "${OM_GHOUL_DATA:-$OUT/no-ghoul-data}" "$OUT/ghoul-renders" || rc=1
  [ $rc -eq 0 ] || { echo "unit tests FAILED" >&2; exit 1; }
fi
echo "Built into $REL"
