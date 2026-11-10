#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs kit check: the launcher's game-file search, checks and copy (launcher/rlk_gamedata.m), on made-up folders
# with files of a few bytes (no game data). Also builds the launcher both ways: without RLK_DATA_FILES (an app with
# the game inside: no AppKit, nothing asked) and with it (an app without the game).
#   rlabs-kit/tests/run-gamedata-test.sh
set -euo pipefail
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/rlk-gamedata.XXXXXX")
MIN=${MIN_MACOS:-13.0}
CC="clang -arch arm64 -mmacosx-version-min=$MIN -Wall -Wextra -Werror -Wunguarded-availability"

$CC -O1 -fobjc-arc -I"$KIT/launcher" "$KIT/tests/rlk_gamedata_test.c" "$KIT/launcher/rlk_gamedata.m" \
  -framework AppKit -o "$W/rlk_gamedata_test"
mkdir "$W/work"
"$W/rlk_gamedata_test" "$W/work"

BASE="-DRLK_GAME_NAME=\"Test\" -DRLK_PROGRAM=\"Resources/x\""
$CC -O2 $BASE "$KIT/launcher/rlk_launcher.c" -framework CoreFoundation -o "$W/launcher-with-game"
$CC -O2 -fobjc-arc $BASE '-DRLK_DATA_FILES="a.pak","b.pak"' '-DRLK_DATA_SIZES=1LL,2LL' '-DRLK_DATA_DEST="game/base"' \
  "$KIT/launcher/rlk_launcher.c" "$KIT/launcher/rlk_gamedata.m" -framework CoreFoundation -framework AppKit \
  -o "$W/launcher-without-game"
if otool -L "$W/launcher-with-game" | grep -q AppKit; then echo "FAIL: the launcher with the game inside links AppKit"; exit 1; fi
otool -L "$W/launcher-without-game" | grep -q AppKit || { echo "FAIL: the launcher without the game lacks AppKit"; exit 1; }
echo "launcher builds both ways (work files in $W)"
