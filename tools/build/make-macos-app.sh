#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds "Soldier of Fortune.app" from release/ with the RLabs kit (rlabs-kit/launcher in this project: compiled
# Game Mode launcher, bundled libraries, ad-hoc signature), in one of two forms:
#
#   with the game inside (default): a private build for your own copy of the game. The app carries the game data
#   from game-data/sof/base and must never be given to anyone.
#
#     tools/build/make-macos-app.sh [OUT_DIR]        (default: a temporary folder outside iCloud - codesign
#                                                      refuses bundles built anywhere in the synced Documents)
#     tools/build/make-macos-app.sh --install        build, install into /Applications (rollback in
#                                                      build.nosync/rollback) and leave a copy in the project folder
#
#   without the game (--no-data): the app other people can download. It holds no game file; on its first start the
#   launcher asks for the folder of the player's own copy, checks it and copies the files into
#   ~/Library/Application Support/Soldier of Fortune/game (rlabs-kit/launcher/rlk_gamedata.m). Every binary must
#   run on OM_MACOS_MIN (default 13.0), so the engine has to be built against SDL3 and OpenAL Soft from
#   tools/build/build-macos-deps.sh, not Homebrew's (docs/BUILD-macos.md, "An app for other people").
#
#     tools/build/make-macos-app.sh --no-data [--version 1.0] [--dmg] OUT_DIR
#         --dmg   also writes OUT_DIR/Soldier-of-Fortune-for-Mac-<version>.dmg (the app, an Applications
#                 shortcut and a Read Me) and checks it: image, signature, no game file inside
#
# env: OM_BUILD_DIR  the build tree (default <repo>/build-macos-arm64-Release, as build-macos.sh)
#      OM_MACOS_MIN  oldest macOS (default 13.0; the same value the engine was built with)
#
# Folder layout: source, your game data (game-data/sof/base), builds, rollbacks and a copy of the app all live in
# the project folder; /Applications holds the app you play; only settings, saves and logs live in ~/Library.
#
# Layout inside the app:
#   Contents/MacOS/SoldierOfFortune       launcher -> exec Resources/engine/openMerc
#   Contents/Resources/engine/            openMerc, ref_metal.dylib, OMsnd.dylib (Metal only: no ref_gl3/gles3)
#   Contents/Resources/engine/openmerc-data/ gamex86.dylib, player.dylib, zz_openmerc.pak (openMERC's own files)
#   Contents/Resources/game/base/         pak0..pak3, gs.pak (APFS clones of game-data/sof/base; not with --no-data)
#   Contents/Resources/licenses/          licence texts and where the source is (--no-data)
#   ~/Library/Application Support/Soldier of Fortune/user   settings and saves (-user)
#   ~/Library/Application Support/Soldier of Fortune/game   the player's game files (--no-data)
#   ~/Library/Logs/Soldier of Fortune/last-run.log          console of the last run
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BLD=${OM_BUILD_DIR:-$REPO/build-macos-arm64-Release}
MIN=${OM_MACOS_MIN:-13.0}
# The kit: RLABS_KIT, else the folder the engine was configured with (engine/CMakeLists.txt), else the project's own
# rlabs-kit
KIT_ROOT=${RLABS_KIT:-$(sed -n 's/^RLABS_KIT:PATH=//p' "$BLD/engine/CMakeCache.txt" 2>/dev/null || true)}
[ -n "$KIT_ROOT" ] && [ -f "$KIT_ROOT/launcher/make-app.sh" ] || KIT_ROOT=$REPO/rlabs-kit
[ -f "$KIT_ROOT/launcher/make-app.sh" ] || {
  echo "RLabs kit not found at $KIT_ROOT (the project's rlabs-kit folder, or set RLABS_KIT)" >&2; exit 1; }
KIT=$(cd "$KIT_ROOT/launcher" && pwd)
INSTALL=0
NODATA=0
DMG=0
VERSION=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1;;
    --no-data) NODATA=1;;
    --dmg) DMG=1;;
    --version) VERSION=${2:?version}; shift;;
    -*) echo "unknown option $1" >&2; exit 2;;
    *) OUT=$1;;
  esac
  shift
done
[ -n "$VERSION" ] || VERSION=$(date +%Y.%m.%d)
if [ $NODATA = 1 ] && [ $INSTALL = 1 ]; then
  echo "--no-data builds the app for other people; it is not installed over your own (which has your game inside)" >&2; exit 2
fi
if [ $DMG = 1 ] && { [ $NODATA = 0 ] || [ -z "$OUT" ]; }; then
  echo "--dmg needs --no-data (an app with the game inside is never packaged) and an OUT_DIR" >&2; exit 2
fi
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
SCAN=("$REL")
if [ $NODATA = 0 ]; then
  [ -f "$DATA/pak0.pak" ] || { echo "missing $DATA/pak0.pak" >&2; exit 1; }
  SCAN+=("$DATA")
fi
if find "${SCAN[@]}" -flags +dataless 2>/dev/null | grep -q .; then
  echo "some files are iCloud placeholders; brctl download them first:" >&2
  find "${SCAN[@]}" -flags +dataless >&2; exit 1
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/sof-stage.XXXXXX")
CONF=$(mktemp -d "${TMPDIR:-/tmp}/sof-conf.XXXXXX")
trap 'rm -rf "$STAGE" "$CONF"' EXIT
# openMERC's own files go in <exe dir>/openmerc-data (Linux: openmerc; on a case-insensitive Mac disk that name
# collides with the openMerc program), as in the Linux package (package-linux.sh): the engine
# reads its data archive (menus, fonts, modern key defaults) only from there; <exe dir>/base is searched for
# the game/player modules only, so a zz_openmerc.pak there was never loaded (fixed 2026-11-05)
mkdir -p "$STAGE/engine/openmerc-data"
cp -c "$REL/openMerc" "$REL/ref_metal.dylib" "$REL/OMsnd.dylib" "$STAGE/engine/"
cp -c "$REL/base/gamex86.dylib" "$REL/base/player.dylib" "$REL/base/zz_openmerc.pak" "$STAGE/engine/openmerc-data/"

DEFS="-DRLK_GAME_NAME='\"Soldier of Fortune\"' -DRLK_PROGRAM='\"Resources/engine/openMerc\"' \
-DRLK_WORKDIR='\"Resources/engine\"' -DRLK_ENV='\"XDG_DATA_HOME={DATA}\",\"MTL_HUD_ENABLED=1\"'"
if [ $NODATA = 0 ]; then
  mkdir -p "$STAGE/game/base"
  for p in "$DATA"/*.pak; do cp -c "$p" "$STAGE/game/base/"; done
  DEFS="$DEFS -DRLK_ARGS='\"-basedir\",\"{RES}/game\",\"-user\",\"{DATA}/user\",\"+set\",\"vid_renderer\",\"metal\"'"
  ICON="$REPO/tools/build/macos/AppIcon.icns"
  GAMEDATA=0
  STRICT=0
else
  # The player's own files. Sizes: the 1.07f set of the Platinum Edition CD (the set this port was made and tested
  # with); other sizes get a warning, not a refusal. gs.pak (the multiplayer menus of the 1.07f GameSpy update) is
  # copied when it is there; the game starts without it.
  cat > "$CONF/gamedata.h" <<'EOF'
#define RLK_DATA_FILES "pak0.pak", "pak1.pak", "pak2.pak", "pak3.pak"
#define RLK_DATA_SIZES 705825871LL, 20517183LL, 48985072LL, 9406518LL
#define RLK_DATA_OPTIONAL "gs.pak"
#define RLK_DATA_DEST "game/base"
#define RLK_DATA_INTRO \
	"This app does not include the game. Choose the folder of your own copy of Soldier of Fortune: the folder " \
	"where the game is installed, or the folder that holds pak0.pak, pak1.pak, pak2.pak and pak3.pak.\n\n" \
	"The files are copied into your Library (about 800 MB). Your own folder is not changed."
#define RLK_DATA_NOTE \
	"This app is made for version 1.07f of the game: the Platinum Edition or the GOG release. An older copy has " \
	"to be updated to 1.07f first."
EOF
  DEFS="$DEFS -include \"$CONF/gamedata.h\" \
-DRLK_ARGS='\"-basedir\",\"{DATA}/game\",\"-user\",\"{DATA}/user\",\"+set\",\"vid_renderer\",\"metal\"'"
  # the private icon is made from the CD artwork and stays private; this one is drawn for the port
  # (free-icon.svg; rendered with qlmanage, corners cut with ImageMagick, packed with iconutil)
  ICON="$REPO/tools/build/macos/free-icon.icns"
  GAMEDATA=1
  STRICT=1
  # licence texts and the way to the source travel with the binaries (GPL-2.0, LGPL for OpenAL Soft)
  mkdir -p "$STAGE/licenses"
  cp "$REPO/LICENSE" "$STAGE/licenses/GPL-2.0.txt"
  cp "$REPO/THIRD_PARTY.md" "$STAGE/licenses/THIRD_PARTY.md"
  [ -f "$REPO/engine/LICENSE" ] && cp "$REPO/engine/LICENSE" "$STAGE/licenses/engine-LICENSE.txt"
  LIBLIC=$(sed -n 's/^SDL3_DIR:PATH=\(.*\)\/lib\/cmake\/SDL3$/\1/p' "$BLD/engine/CMakeCache.txt" 2>/dev/null || true)/licenses
  if [ -d "$LIBLIC" ]; then cp "$LIBLIC"/* "$STAGE/licenses/"; else
    echo "no licence texts for SDL3 and OpenAL Soft at $LIBLIC (build them with tools/build/build-macos-deps.sh)" >&2; exit 1
  fi
  {
    echo "Soldier of Fortune for Mac $VERSION - an unofficial native port built on openMERC (GPL-2.0-or-later)."
    echo "No game data is included: the app asks for your own copy of the game."
    echo
    echo "Source code of this build: https://github.com/gkaragioul/openMERC (branch macos-port)"
    echo "commit $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)$(git -C "$REPO" diff --quiet HEAD 2>/dev/null || echo ' plus uncommitted changes')"
    echo "Build steps: docs/BUILD-macos.md in that source. The licence texts are beside this file."
  } > "$STAGE/licenses/SOURCE.txt"
fi

mkdir -p "$OUT"
APP_NAME="Soldier of Fortune" BUNDLE_ID="com.rlabs.soldier-of-fortune" EXEC_NAME="SoldierOfFortune" \
VERSION="$VERSION" ICON="$ICON" STAGE="$STAGE" OUT_DIR="$OUT" MIN_MACOS="$MIN" LAUNCHER_GAMEDATA=$GAMEDATA \
STRICT_MIN=$STRICT LAUNCHER_DEFS="$DEFS" \
  bash "$KIT/make-app.sh"
APP="$OUT/Soldier of Fortune.app"

if [ $NODATA = 1 ]; then
  echo "== check: no game file in the app"
  # the only archive allowed is openMERC's own zz_openmerc.pak (menus, fonts, key defaults: built from data/base)
  bad=$(find "$APP" -type f \( -iname '*.pak' -o -iname '*.bsp' -o -iname '*.m32' -o -iname '*.ghb' -o -iname '*.adp' \) \
    ! -path '*/engine/openmerc-data/zz_openmerc.pak' || true)
  [ -z "$bad" ] || { echo "game files in the app:" >&2; echo "$bad" >&2; exit 1; }
  cmp -s "$REL/base/zz_openmerc.pak" "$APP/Contents/Resources/engine/openmerc-data/zz_openmerc.pak" || {
    echo "zz_openmerc.pak in the app is not the one just built" >&2; exit 1; }
  echo "none ($(find "$APP" -type f | wc -l | tr -d ' ') files, $(du -sh "$APP" | awk '{print $1}'))"
fi

if [ $DMG = 1 ]; then
  echo "== disk image"
  IMG="$OUT/Soldier-of-Fortune-for-Mac-$VERSION.dmg"
  ROOT="$CONF/dmg"
  mkdir -p "$ROOT"
  cp -c -R "$APP" "$ROOT/"
  ln -s /Applications "$ROOT/Applications"
  cat > "$ROOT/Read Me.txt" <<EOF
Soldier of Fortune for Mac $VERSION
An unofficial native port for Macs with Apple silicon (macOS $MIN or newer). No game data is included.

1. Drag Soldier of Fortune onto the Applications folder.
2. Double-click it in Applications. macOS says it was "Not Opened": click Done, then open
   Apple menu > System Settings > Privacy & Security, scroll down to Security and click Open Anyway.
3. The game asks for your own copy of Soldier of Fortune (version 1.07f: the Platinum Edition or the
   GOG release). Click Choose Folder... and pick the folder where the game is installed, or the folder
   that holds pak0.pak, pak1.pak, pak2.pak and pak3.pak. The files are copied; your folder is not changed.

Your game files:      ~/Library/Application Support/Soldier of Fortune/game  (delete it to choose again)
Settings and saves:   ~/Library/Application Support/Soldier of Fortune/user
Log of the last run:  ~/Library/Logs/Soldier of Fortune/last-run.log

How to get the files out of a CD or a Windows installer, and the source code:
https://github.com/gkaragioul/mac-ports/blob/main/games/soldier-of-fortune.md
https://github.com/gkaragioul/openMERC (branch macos-port, GPL-2.0-or-later)

Soldier of Fortune is a trademark of its respective owner. Unofficial fan project, not affiliated with or
endorsed by any game publisher.
EOF
  [ ! -e "$IMG" ] || { echo "$IMG exists already; move it away first" >&2; exit 1; }
  hdiutil create -quiet -volname "Soldier of Fortune" -srcfolder "$ROOT" -fs HFS+ -format UDZO "$IMG"
  hdiutil verify -quiet "$IMG"
  MNT="$CONF/mnt"
  mkdir -p "$MNT"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MNT" "$IMG" 2>/dev/null
  rc=0
  codesign --verify --deep --strict "$MNT/Soldier of Fortune.app" && echo "signature ok inside the image" || rc=1
  bad=$(find "$MNT" -type f \( -iname '*.pak' -o -iname '*.bsp' -o -iname '*.m32' -o -iname '*.ghb' -o -iname '*.adp' \) \
    ! -path '*/engine/openmerc-data/zz_openmerc.pak' || true)
  [ -z "$bad" ] && echo "no game file inside the image" || { echo "game files in the image: $bad" >&2; rc=1; }
  hdiutil detach -quiet "$MNT" || true
  [ $rc = 0 ] || { echo "the image did not pass its checks: $IMG" >&2; exit 1; }
  echo "Built $IMG ($(du -h "$IMG" | awk '{print $1}'), sha256 $(shasum -a 256 "$IMG" | awk '{print $1}'))"
fi

if [ $INSTALL = 1 ]; then
  # First install: bring existing settings and saves from the project folder (never overwrites)
  SUP="$HOME/Library/Application Support/Soldier of Fortune/user"
  if [ ! -d "$SUP" ] && [ -d "$REPO/user" ]; then
    mkdir -p "$SUP"
    cp -R "$REPO/user/." "$SUP/"
    echo "settings and saves copied to $SUP (project copy kept)"
  fi
  # rollbacks in the project folder (.nosync: kept on this Mac, not uploaded); a copy of the app beside the source
  bash "$KIT/install-app.sh" "$APP" "$REPO/build.nosync/rollback" --copy-to "$REPO"
  # the temporary build is a clone of what was installed: nothing to keep
  [ $TEMPOUT = 1 ] && rm -rf "$OUT"
elif [ $TEMPOUT = 1 ]; then
  echo "built in $OUT (temporary; pass an OUT_DIR outside iCloud to keep it elsewhere)"
fi
