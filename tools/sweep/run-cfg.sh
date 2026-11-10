#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# One scripted launch with a fresh scratch profile: run-cfg.sh <metal|gl3> <script.cfg> <tag>
# Build tree release, the project's game data (read only), profile and screenshots in build.nosync/sweep/<tag>
# (inside the project, not uploaded by iCloud, deleted after the run), windowed, sound muted.
# Extra engine arguments may follow the tag. See run-sweep.sh for the all-levels sweep.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
R=${1:?renderer: metal or gl3}; CFG=${2:?script}; TAG=${3:?tag}; shift 3
REL=${OM_REL:-$REPO/build-macos-arm64-Release/release}
T="$REPO/build.nosync/sweep/$TAG"
rm -rf "$T"; mkdir -p "$T/user" "$T/xdg"
cp "$CFG" "$T/user/run.cfg"
cd "$REL" || exit 1
export XDG_DATA_HOME="$T/xdg"
exec ./openMerc -basedir "$REPO/game-data/sof" -user "$T/user" +set vid_renderer "$R" +set cheats 1 \
  +set sv_jumpcinematic 1 +set vid_fullscreen 0 +set vid_pauseonfocuslost 0 +set s_volume 0 +set s_musicvolume 0 \
  +set con_notifytime 0 +set r_metal_gputime 1 "$@" +exec run.cfg > "$T/console.log" 2>&1
