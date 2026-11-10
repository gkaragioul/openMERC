#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds "Soldier of Fortune.app" from release/ and your own extracted game data, with the RLabs kit
# (rlabs-kit/launcher in this project: compiled Game Mode launcher, bundled libraries, ad-hoc signature). A private build
# for your own copy of the game: the app carries your game data, so never publish or share it.
#
#   tools/build/make-macos-app.sh [OUT_DIR]        (default: a temporary folder outside iCloud - codesign
#                                                    refuses bundles built anywhere in the synced Documents)
#   tools/build/make-macos-app.sh --install        build, install into /Applications (rollback in build.nosync/rollback)
#                                                    and leave a copy of the app in the project folder
#
# Folder layout: source, your game data (game-data/sof/base), builds, rollbacks and a copy of the app all live in
# the project folder; /Applications holds the app you play; only settings, saves and logs live in ~/Library.
#
# Layout inside the app:
#   Contents/MacOS/SoldierOfFortune       launcher -> exec Resources/engine/openMerc
#   Contents/Resources/engine/            openMerc, ref_metal.dylib, OMsnd.dylib (Metal only: no ref_gl3/gles3)
#   Contents/Resources/engine/openmerc-data/ gamex86.dylib, player.dylib, zz_openmerc.pak (openMERC's own files)
#   Contents/Resources/game/base/         pak0..pak3, gs.pak (APFS clones of game-data/sof/base)
#   ~/Library/Application Support/Soldier of Fortune/user   settings and saves (-user)
#   ~/Library/Logs/Soldier of Fortune/last-run.log          console of the last run
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BLD="$REPO/build-macos-arm64-Release"
# The kit: RLABS_KIT, else the folder the engine was configured with (engine/CMakeLists.txt), else the project's own
# rlabs-kit
KIT_ROOT=${RLABS_KIT:-$(sed -n 's/^RLABS_KIT:PATH=//p' "$BLD/engine/CMakeCache.txt" 2>/dev/null || true)}
[ -n "$KIT_ROOT" ] && [ -f "$KIT_ROOT/launcher/make-app.sh" ] || KIT_ROOT=$REPO/rlabs-kit
[ -f "$KIT_ROOT/launcher/make-app.sh" ] || {
  echo "RLabs kit not found at $KIT_ROOT (the project's rlabs-kit folder, or set RLABS_KIT)" >&2; exit 1; }
KIT=$(cd "$KIT_ROOT/launcher" && pwd)
INSTALL=0
OUT=""
for a in "$@"; do case "$a" in --install) INSTALL=1;; *) OUT=$a;; esac; done
TEMPOUT=0
if [ -z "$OUT" ]; then OUT=$(mktemp -d "${TMPDIR:-/tmp}/sof-app.XXXXXX"); TEMPOUT=1; fi
REL="$BLD/release"
DATA="$REPO/game-data/sof/base"

for f in openMerc ref_metal.dylib OMsnd.dylib base/gamex86.dylib base/player.dylib base/zz_openmerc.pak; do
  [ -f "$REL/$f" ] || { echo "missing $REL/$f (run tools/build/build-macos.sh)" >&2; exit 1; }
done
# An engine built without the kit has no pointer hiding, 120 Hz switch, variable refresh or HUD setting; never
# install one (2026-11-08: after the project moved, a rebuild would have dropped them without an error)
for f in openMerc ref_metal.dylib; do
  # not grep -q: it leaves at the first match, and under pipefail a still-writing nm then fails the check on a good build
  nm "$REL/$f" 2>/dev/null | grep ' T _rlk_' >/dev/null || {
    echo "$REL/$f was built without the RLabs kit; rerun tools/build/build-macos.sh (kit: $KIT_ROOT)" >&2; exit 1; }
done
[ -f "$DATA/pak0.pak" ] || { echo "missing $DATA/pak0.pak" >&2; exit 1; }
if find "$REL" "$DATA" -flags +dataless 2>/dev/null | grep -q .; then
  echo "some files are iCloud placeholders; brctl download them first:" >&2
  find "$REL" "$DATA" -flags +dataless >&2; exit 1
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/sof-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
# openMERC's own files go in <exe dir>/openmerc-data (Linux: openmerc; on a case-insensitive Mac disk that name
# collides with the openMerc program), as in the Linux package (package-linux.sh): the engine
# reads its data archive (menus, fonts, modern key defaults) only from there; <exe dir>/base is searched for
# the game/player modules only, so a zz_openmerc.pak there was never loaded (fixed 2026-11-05)
mkdir -p "$STAGE/engine/openmerc-data" "$STAGE/game/base"
cp -c "$REL/openMerc" "$REL/ref_metal.dylib" "$REL/OMsnd.dylib" "$STAGE/engine/"
cp -c "$REL/base/gamex86.dylib" "$REL/base/player.dylib" "$REL/base/zz_openmerc.pak" "$STAGE/engine/openmerc-data/"
for p in "$DATA"/*.pak; do cp -c "$p" "$STAGE/game/base/"; done

mkdir -p "$OUT"
APP_NAME="Soldier of Fortune" BUNDLE_ID="com.rlabs.soldier-of-fortune" EXEC_NAME="SoldierOfFortune" \
VERSION="$(date +%Y.%m.%d)" ICON="$REPO/tools/build/macos/AppIcon.icns" STAGE="$STAGE" OUT_DIR="$OUT" \
LAUNCHER_DEFS="-DRLK_GAME_NAME='\"Soldier of Fortune\"' -DRLK_PROGRAM='\"Resources/engine/openMerc\"' \
-DRLK_WORKDIR='\"Resources/engine\"' -DRLK_ENV='\"XDG_DATA_HOME={DATA}\",\"MTL_HUD_ENABLED=1\"' \
-DRLK_ARGS='\"-basedir\",\"{RES}/game\",\"-user\",\"{DATA}/user\",\"+set\",\"vid_renderer\",\"metal\"'" \
  bash "$KIT/make-app.sh"

if [ $INSTALL = 1 ]; then
  # First install: bring existing settings and saves from the project folder (never overwrites)
  SUP="$HOME/Library/Application Support/Soldier of Fortune/user"
  if [ ! -d "$SUP" ] && [ -d "$REPO/user" ]; then
    mkdir -p "$SUP"
    cp -R "$REPO/user/." "$SUP/"
    echo "settings and saves copied to $SUP (project copy kept)"
  fi
  # rollbacks in the project folder (.nosync: kept on this Mac, not uploaded); a copy of the app beside the source
  bash "$KIT/install-app.sh" "$OUT/Soldier of Fortune.app" "$REPO/build.nosync/rollback" --copy-to "$REPO"
  # the temporary build is a clone of what was installed: nothing to keep
  [ $TEMPOUT = 1 ] && rm -rf "$OUT"
elif [ $TEMPOUT = 1 ]; then
  echo "built in $OUT (temporary; pass an OUT_DIR outside iCloud to keep it elsewhere)"
fi
