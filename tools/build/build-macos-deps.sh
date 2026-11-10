#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build SDL3 and OpenAL Soft from their released source for an app that is given to other people.
#
# Homebrew's libraries only run on the macOS version they were bottled for (libSDL3 and libopenal from a Homebrew
# on macOS 27 carry "minos 27.0"), so an app that bundles them does not start on anything older. This script builds
# the same two libraries with the deployment target of the engine (OM_MACOS_MIN, default 13.0, as build-macos.sh):
#
#   tools/build/build-macos-deps.sh                      -> <repo>/build-macos-deps/prefix
#   OM_SDL3_PREFIX=<repo>/build-macos-deps/prefix OM_OPENAL_PREFIX=<repo>/build-macos-deps/prefix \
#     tools/build/build-macos.sh
#
# The source archives are downloaded once from the projects' own release pages and checked against the SHA-256 written here.
# env: OM_MACOS_MIN  deployment target (default 13.0)
#      OM_DEPS_DIR   work and install folder (default <repo>/build-macos-deps)
#      OM_JOBS       parallel jobs
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MIN=${OM_MACOS_MIN:-13.0}
DEPS=${OM_DEPS_DIR:-$REPO/build-macos-deps}
JOBS=${OM_JOBS:-$(sysctl -n hw.ncpu)}

SDL_VER=3.4.18
SDL_URL=https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VER/SDL3-$SDL_VER.tar.gz
SDL_SHA=9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3
AL_VER=1.25.2
AL_URL=https://openal-soft.org/openal-releases/openal-soft-$AL_VER.tar.bz2
AL_SHA=1dbaac44e7579d5bc8847ca8db4b2e8b9fd3961041f35ee20def4958301e1089

for t in cmake ninja clang curl shasum tar; do
  command -v "$t" >/dev/null || { echo "missing tool: $t (see docs/BUILD-macos.md)" >&2; exit 1; }
done
mkdir -p "$DEPS/src" "$DEPS/prefix"

fetch() { # url sha256 -> path of the checked archive
  local url=$1 sha=$2 file="$DEPS/src/$(basename "$1")" got
  if [ ! -f "$file" ]; then
    echo "   downloading $url" >&2
    curl -fsSL --retry 2 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  got=$(shasum -a 256 "$file" | awk '{print $1}')
  [ "$got" = "$sha" ] || { echo "$file: SHA-256 is $got, expected $sha (delete the file to download it again)" >&2; exit 1; }
  echo "$file"
}

unpack() { # archive folder-name
  [ -d "$DEPS/src/$2" ] || tar -xf "$1" -C "$DEPS/src"
  [ -d "$DEPS/src/$2" ] || { echo "$1 did not unpack to $2" >&2; exit 1; }
}

build() { # source build-name [cmake args]
  local src=$1 bld="$DEPS/build-$2"; shift 2
  cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
    -DCMAKE_INSTALL_PREFIX="$DEPS/prefix" -DCMAKE_INSTALL_NAME_DIR="$DEPS/prefix/lib" "$@" > "$bld.configure.log" 2>&1 \
    || { tail -30 "$bld.configure.log" >&2; exit 1; }
  cmake --build "$bld" -j "$JOBS" > "$bld.build.log" 2>&1 || { tail -40 "$bld.build.log" >&2; exit 1; }
  cmake --install "$bld" > "$bld.install.log" 2>&1
}

echo "== SDL $SDL_VER (macOS $MIN)"
unpack "$(fetch "$SDL_URL" "$SDL_SHA")" "SDL3-$SDL_VER"
build "$DEPS/src/SDL3-$SDL_VER" sdl3 -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF \
  -DSDL_EXAMPLES=OFF -DSDL_X11=OFF -DSDL_WAYLAND=OFF

echo "== OpenAL Soft $AL_VER (macOS $MIN)"
unpack "$(fetch "$AL_URL" "$AL_SHA")" "openal-soft-$AL_VER"
# HAVE_WFUNCTION_EFFECTS=OFF: with Apple clang 21 and the macOS 27 SDK OpenAL Soft's own -Werror=function-effects
# stops at two CoreAudio callbacks ("attribute 'nonblocking' should not be added via type conversion"); the check
# is a diagnostic only, the source stays unmodified
build "$DEPS/src/openal-soft-$AL_VER" openal -DHAVE_WFUNCTION_EFFECTS=OFF -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
  -DALSOFT_BACKEND_PORTAUDIO=OFF -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_JACK=OFF -DALSOFT_BACKEND_SDL2=OFF \
  -DALSOFT_BACKEND_SDL3=OFF -DALSOFT_INSTALL_CONFIG=OFF -DALSOFT_INSTALL_HRTF_DATA=OFF \
  -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF

# the licence texts travel with the libraries (make-macos-app.sh puts them into the app)
mkdir -p "$DEPS/prefix/licenses"
cp "$DEPS/src/SDL3-$SDL_VER/LICENSE.txt" "$DEPS/prefix/licenses/SDL3-LICENSE.txt"
cp "$DEPS/src/openal-soft-$AL_VER/COPYING" "$DEPS/prefix/licenses/OpenAL-Soft-COPYING.txt"
printf 'SDL %s\n%s\nsha256 %s\n\nOpenAL Soft %s\n%s\nsha256 %s\n\nBuilt for macOS %s, arm64, unmodified.\n' \
  "$SDL_VER" "$SDL_URL" "$SDL_SHA" "$AL_VER" "$AL_URL" "$AL_SHA" "$MIN" > "$DEPS/prefix/licenses/LIBRARIES.txt"

for lib in libSDL3.0.dylib libopenal.1.dylib; do
  f="$DEPS/prefix/lib/$lib"
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
  got=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  echo "   $lib: minos $got"
  [ "$got" = "$MIN" ] || { echo "$f is built for macOS $got, not $MIN" >&2; exit 1; }
done
echo "Built into $DEPS/prefix"
