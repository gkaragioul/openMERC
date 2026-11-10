#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs whole-game scan (2026-11-09): every cut scene of every single-player level in one launch, Metal, small window, muted.
# Scratch profile in build.nosync/sweep/film (inside the project, not uploaded by iCloud, deleted after the sheets are made).
#   tools/sweep/make_film_cfgs.py <audit dir> <spots.json> build.nosync/sweep/film-cfg
#   tools/sweep/run-film.sh
#   /usr/bin/python3 tools/sweep/film_sheets.py build.nosync/sweep/film-cfg/index.json build.nosync/sweep/film/user/scrnshot build.nosync/sweep/film/console.log <out>
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SW=$REPO/build.nosync/sweep
T="$SW/film"
rm -rf "$T"; mkdir -p "$T/user" "$T/xdg"
cp "$SW"/film-cfg/*.cfg "$T/user/"
cd "$REPO/build-macos-arm64-Release/release" || exit 1
export XDG_DATA_HOME="$T/xdg"
exec ./openMerc -basedir "$REPO/game-data/sof" -user "$T/user" +set vid_renderer metal +set cheats 1 \
  +set vid_fullscreen 0 +set r_mode -1 +set r_customwidth 960 +set r_customheight 540 +set vid_pauseonfocuslost 0 \
  +set s_volume 0 +set s_musicvolume 0 +set con_notifytime 0 +exec "${1:-film_000.cfg}" > "$T/console.log" 2>&1
