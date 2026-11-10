#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs kit: build a self-contained game app (one package with the whole game inside).
#   Contents/MacOS/<EXEC_NAME>   the compiled launcher (rlk_launcher.c with LAUNCHER_DEFS)
#   Contents/Resources/          everything in STAGE (engine, game data: APFS clones), AppIcon.icns
#   Contents/Frameworks/         every non-system library the binaries use (Homebrew), linked as @rpath/<name>
#   Contents/Info.plist          Game Mode, high resolution, the app's name and version
# then an ad-hoc signature over every binary and the app, and a check that no Homebrew path is left.
#
# Environment: APP_NAME BUNDLE_ID EXEC_NAME VERSION ICON STAGE OUT_DIR LAUNCHER_DEFS (see the game's own
# make-macos-app.sh). OUT_DIR must be outside the iCloud-synced Documents: codesign refuses bundles there.
#   MIN_MACOS            oldest macOS of the app (default 13.0): the launcher's target and LSMinimumSystemVersion
#   LAUNCHER_GAMEDATA=1  an app without the game: the launcher asks for the player's own game files on the first
#                        start (rlk_gamedata.m, AppKit; LAUNCHER_DEFS carries the RLK_DATA_ settings)
#   STRICT_MIN=1         stop when a binary in the app needs a newer macOS than MIN_MACOS (Homebrew's libraries
#                        do: they only run on the macOS they were bottled for); without it that is only reported
#
# This version was written on 2026-11-08 for the Soldier of Fortune port; it keeps the earlier kit's
# behaviour and log lines.
set -euo pipefail
: "${APP_NAME:?}" "${BUNDLE_ID:?}" "${EXEC_NAME:?}" "${VERSION:?}" "${STAGE:?}" "${OUT_DIR:?}" "${LAUNCHER_DEFS:?}"
ICON=${ICON:-}
MIN_MACOS=${MIN_MACOS:-13.0}
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP="$OUT_DIR/$APP_NAME.app"
C="$APP/Contents"

rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/Frameworks"
# one spelling of every path (TMPDIR ends in "/", /var is /private/var): the rpath depth is counted on these
C=$(cd "$C" && pwd -P)
APP=$(dirname "$C")

echo "== launcher"
LAUNCHER_MORE=""
if [ "${LAUNCHER_GAMEDATA:-0}" = 1 ]; then
  LAUNCHER_MORE="-fobjc-arc -Werror=unguarded-availability \"$KIT/rlk_gamedata.m\" -framework AppKit"
fi
eval "clang -O2 -arch arm64 -mmacosx-version-min=$MIN_MACOS -Wall $LAUNCHER_DEFS \"$KIT/rlk_launcher.c\" \
  $LAUNCHER_MORE -framework CoreFoundation -o \"$C/MacOS/$EXEC_NAME\""

echo "== resources"
for f in "$STAGE"/*; do cp -c -R "$f" "$C/Resources/"; done
if [ -n "$ICON" ] && [ -f "$ICON" ]; then cp "$ICON" "$C/Resources/AppIcon.icns"; fi

is_macho() { file -b "$1" | grep -q 'Mach-O'; }
# non-system libraries a binary links (absolute paths outside /usr/lib and /System)
foreign_deps() {
  otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^/' | grep -v -E '^/usr/lib/|^/System/' || true
}
# the folder of a binary relative to Frameworks, as @loader_path/...
rpath_for() {
  local here dir rel=""
  here=$(cd "$(dirname "$1")" && pwd -P)
  [ "$here" = "$C/Frameworks" ] && { echo "@loader_path/."; return; }
  dir=$here
  while [ "$dir" != "$C" ]; do
    [ "$dir" = "/" ] && { echo "rpath_for: $1 is not inside $C" >&2; exit 1; }
    rel="../$rel"; dir=$(dirname "$dir")
  done
  echo "@loader_path/${rel}Frameworks"
}
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/{getline; getline; print $2}'; }
add_rpath() { # file rpath (once)
  rpaths "$1" | grep -qxF "$2" || install_name_tool -add_rpath "$2" "$1" 2>/dev/null
}
drop_abs_rpaths() { # the build machine's own search paths (/opt/homebrew/lib ...) must not stay in the app
  local r; for r in $(rpaths "$1"); do case "$r" in /*) install_name_tool -delete_rpath "$r" "$1" 2>/dev/null;; esac; done
}

echo "== libraries"
BINS=()
while IFS= read -r f; do is_macho "$f" && BINS+=("$f"); done < <(find "$C/MacOS" "$C/Resources" -type f)
# copy every foreign library, and the libraries those link, into Frameworks
pending=("${BINS[@]}")
while [ ${#pending[@]} -gt 0 ]; do
  f=${pending[0]}; pending=("${pending[@]:1}")
  for dep in $(foreign_deps "$f"); do
    base=$(basename "$dep")
    if [ ! -f "$C/Frameworks/$base" ]; then
      src=$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dep")
      cp "$src" "$C/Frameworks/$base"; chmod u+w "$C/Frameworks/$base"
      install_name_tool -id "@rpath/$base" "$C/Frameworks/$base" 2>/dev/null
      echo "   $base"
      pending+=("$C/Frameworks/$base")
    fi
  done
done
# point every binary at @rpath/<name> and give it the way to Frameworks
ALL=("${BINS[@]}")
for f in "$C/Frameworks"/*; do [ -f "$f" ] && ALL+=("$f"); done
for f in "${ALL[@]}"; do
  for dep in $(foreign_deps "$f"); do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null
  done
  drop_abs_rpaths "$f"
  case "$f" in "$C/MacOS/"*) continue;; esac
  add_rpath "$f" "$(rpath_for "$f")"
done

echo "== Info.plist"
cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.action-games</string>
  <key>LSSupportsGameMode</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOF

echo "== signing (ad hoc)"
# inside out: libraries, the engine's binaries, then the app (which seals Resources)
for f in "$C/Frameworks"/* "${BINS[@]}"; do
  case "$f" in "$C/MacOS/"*) continue;; esac
  [ -f "$f" ] && codesign --force --sign - "$f" 2>/dev/null
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "signature ok"

echo "== check: no Homebrew paths left"
left=0
for f in "${ALL[@]}"; do
  if otool -L "$f" | tail -n +2 | grep -q -E '/opt/homebrew|/usr/local'; then echo "   $f still links Homebrew" >&2; left=1; fi
  if rpaths "$f" | grep -q '^/'; then echo "   $f still searches $(rpaths "$f" | grep '^/' | tr '\n' ' ')" >&2; left=1; fi
done
[ $left = 0 ] || exit 1
echo "self-contained"

echo "== check: the macOS each binary needs (the app says $MIN_MACOS)"
newer=0
for f in "${ALL[@]}"; do
  need=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  if [ "$(printf '%s\n%s\n' "$need" "$MIN_MACOS" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$MIN_MACOS" ]; then
    echo "   ${f#"$C"/} needs macOS $need"; newer=1
  fi
done
if [ $newer = 1 ]; then
  if [ "${STRICT_MIN:-0}" = 1 ]; then
    echo "these binaries do not run on macOS $MIN_MACOS (libraries: tools/build/build-macos-deps.sh)" >&2; exit 1
  fi
  echo "   this app only runs on the macOS named above or newer (fine for this Mac, not for other people)"
else
  echo "every binary runs on macOS $MIN_MACOS"
fi
echo "Built $APP"
