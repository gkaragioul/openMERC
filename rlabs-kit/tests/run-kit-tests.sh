#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs kit check: build tests/rlk_kit_test.m against the kit sources (the engine's flags) and, when the old compiled
# kit is present (build.nosync/kit-baseline/objects, saved 2026-11-08), against those objects too; compare outputs.
# Also compares the instructions of each new object with the old one (informational: same code = same behaviour).
#   rlabs-kit/tests/run-kit-tests.sh [work dir]      (default build.nosync/kit-test, deleted at the end)
set -euo pipefail
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO=$(cd "$KIT/.." && pwd)
OLD="$REPO/build.nosync/kit-baseline/objects"
W=${1:-$REPO/build.nosync/kit-test}
rm -rf "$W"; mkdir -p "$W/new" "$W/old"
FW="-framework AppKit -framework CoreGraphics -framework QuartzCore -framework CoreFoundation"
INC="-I$KIT/macos -I$KIT/input"

# the new kit, compiled as the engine compiles it (engine/CMakeLists.txt, build.ninja)
for f in rlk_pointer rlk_display rlk_vrr rlk_hud; do
  clang -O3 -DNDEBUG -arch arm64 -fobjc-arc $INC -c "$KIT/macos/$f.m" -o "$W/new/$f.m.o"
done
clang -arch arm64 -Wall -fno-strict-aliasing -fwrapv -O2 -DNDEBUG -std=gnu11 $INC -c "$KIT/input/rlk_mouse_motion.c" \
  -o "$W/new/rlk_mouse_motion.c.o"
clang -O1 -arch arm64 -fobjc-arc $INC -c "$KIT/tests/rlk_kit_test.m" -o "$W/test.o"
clang -arch arm64 -fobjc-arc "$W/test.o" "$W/new/"*.o $FW -o "$W/kit-test-new"
"$W/kit-test-new" > "$W/new.txt" 2>&1
echo "new kit: $(wc -l < "$W/new.txt" | tr -d ' ') result lines"

if [ -d "$OLD" ]; then
  clang -arch arm64 -fobjc-arc "$W/test.o" "$OLD/openMerc/"*.o "$OLD/ref_metal/rlk_hud.m.o" $FW -o "$W/kit-test-old"
  "$W/kit-test-old" > "$W/old.txt" 2>&1
  if diff -u "$W/old.txt" "$W/new.txt" > "$W/diff.txt"; then
    echo "SAME results as the old compiled kit ($(wc -l < "$W/old.txt" | tr -d ' ') lines)"; rc=0
  else
    echo "DIFFERENT from the old compiled kit:"; head -40 "$W/diff.txt"; rc=1
  fi
  echo "instructions, new vs old object (lines differing / total):"
  for o in "$W/new/"*.o; do
    b=$(basename "$o")
    old="$OLD/openMerc/$b"; [ -f "$old" ] || old="$OLD/ref_metal/$b"
    norm() { otool -tV "$1" | tail -n +2 | sed -E 's/^[0-9a-f]+[[:space:]]+//; s/0x[0-9a-f]+/ADDR/g'; }
    d=$(diff <(norm "$old") <(norm "$o") | grep -c '^[<>]' || true)
    echo "   $b: $d / $(norm "$old" | wc -l | tr -d ' ')"
  done
else
  echo "old compiled kit not present: no comparison"; rc=0
fi
[ -n "${KEEP:-}" ] || rm -rf "$W"
exit $rc
