#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs level sweep (2026-11-08): every single-player map in one launch, renderer = $1 (metal | gl3).
# Build tree release (build-macos-arm64-Release/release), the project's game data (read only), a fresh scratch
# profile in build.nosync/sweep/run-<renderer> (inside the project, not uploaded by iCloud, deleted after the run):
# no owner settings, nothing written into the game data or the installed app.
#   tools/sweep/sweep_spots.py game-data/sof/base build.nosync/sweep/spots.json <maps>   (camera spots)
#   tools/sweep/make_cfgs.py build.nosync/sweep/spots.json build.nosync/sweep/cfg sw    (one cfg per map)
#   tools/sweep/run-sweep.sh metal                                                       (one launch)
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SW=$REPO/build.nosync/sweep
R=${1:?renderer: metal or gl3}
T="$SW/run-$R"
rm -rf "$T"; mkdir -p "$T/user" "$T/xdg"
cp "$SW"/cfg/sw_*.cfg "$T/user/"
cd "$REPO/build-macos-arm64-Release/release" || exit 1
export XDG_DATA_HOME="$T/xdg"
exec ./openMerc -basedir "$REPO/game-data/sof" -user "$T/user" +set vid_renderer "$R" +set cheats 1 \
  +set sv_jumpcinematic 1 +set vid_fullscreen 0 +set vid_pauseonfocuslost 0 +set s_volume 0 +set s_musicvolume 0 \
  +set con_notifytime 0 +set r_metal_gputime 1 +set r_om_gputime 1 +exec sw_00.cfg > "$T/console.log" 2>&1
