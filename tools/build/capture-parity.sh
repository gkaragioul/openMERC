#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Capture the same frame from ref_gl3 and ref_metal and print the pixel difference.
#
#   tools/build/capture-parity.sh <map> [frames] [extra +args...]
#
# Example: tools/build/capture-parity.sh tsr1 30
#
# Both renderers run with the same command line, one after the other (never two
# game processes at once), into separate user folders, and the two TGA captures
# are compared with ImageMagick's absolute difference. The script fails when the
# captures are missing, so a silent "no screenshot" cannot be mistaken for parity.
set -euo pipefail

MAP=${1:?map name, e.g. tsr1}
FRAMES=${2:-30}
shift 2 || true
EXTRA=("$@")

# Commands passed at startup are capped at 255 bytes by the engine.  Each
# packed wait is five bytes, so 51 is the highest valid frame count.
if ! [[ "$FRAMES" =~ ^[0-9]+$ ]] || (( FRAMES > 51 )); then
	echo "frames must be an integer from 0 to 51 (the packed +wait argument is capped at 255 bytes)" >&2
	exit 2
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DATA=${OM_DATA_DIR:-$REPO/game-data/sof}
BUILD=${OM_BUILD_DIR:-$REPO/build-macos-arm64-Release}
REL=$BUILD/release
OUT=${OM_PARITY_DIR:-$REPO/build.nosync/parity}
SAFE=$(echo "$MAP" | tr "/ " "__")  # map names contain slashes

[ -x "$REL/openMerc" ] || { echo "build first: tools/build/build-macos.sh" >&2; exit 1; }
[ -d "$DATA/base" ] || { echo "game data not found at $DATA/base" >&2; exit 1; }
REL=$(cd "$REL" && pwd -P)
DATA=$(cd "$DATA" && pwd -P)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)

# Existing captures and user files may be valuable evidence. Refuse to replace
# them; callers can choose a fresh OM_PARITY_DIR for each experiment.
for r in gl3 metal; do
	for suffix in .log .tga .png _crop.png; do
		[ ! -e "$OUT/parity_${SAFE}_${r}${suffix}" ] || {
			echo "capture FAILED: $OUT/parity_${SAFE}_${r}${suffix} already exists; use a fresh OM_PARITY_DIR" >&2
			exit 1
		}
	done
done

# The engine caps command-line arguments at 50. Its late-command parser splits
# at each '+', so pack waits in one argument while retaining the frame count.
waits=
for ((i = 0; i < FRAMES; i++)); do waits+="+wait"; done

capture() { # <renderer> <name>
	local r=$1 name=$2 rundir userdir
	# Metal currently writes screenshots to ./user; running in an isolated
	# directory keeps those writes together with the configured user directory.
	rundir=$(mktemp -d "$OUT/${name}_run.XXXXXXXX")
	userdir=$rundir/user
	mkdir "$userdir"
	(
		cd "$rundir"
		# fixedtime pins the frame clock: cinematic cameras then advance by frame count, not by
		# wall time, so the two renderers provably capture the same instant
		"$REL/openMerc" -basedir "$DATA" -user "$userdir" +set vid_renderer "$r" +set vid_fullscreen 0 \
			+set fixedtime 16666 \
			+map "$MAP" ${EXTRA[@]+"${EXTRA[@]}"} ${waits:+"$waits"} +screenshot "$name" \
			+wait +wait +wait +quit
	) > "$OUT/$name.log" 2>&1 || true

	local shot=$userdir/scrnshot/$name.tga
	if [ ! -f "$shot" ]; then
		echo "capture FAILED: $r produced no screenshot (see $OUT/$name.log)" >&2
		exit 1
	fi
	mv "$shot" "$OUT/$name.tga"
	echo "captured $r -> $OUT/$name.tga"
}

capture gl3 "parity_${SAFE}_gl3"
capture metal "parity_${SAFE}_metal"

if ! command -v magick >/dev/null; then
	echo "captured both frames; install imagemagick for the diff" >&2
	exit 0
fi

# Compare the lower part of the frame only: the console overlay and its log text cover the top
# of the screen and change between runs, which otherwise dominates the number.
CROP=${OM_PARITY_CROP:-100%x55%+0+45%}
magick "$OUT/parity_${SAFE}_gl3.tga" -crop "$CROP" +repage "$OUT/parity_${SAFE}_gl3_crop.png"
magick "$OUT/parity_${SAFE}_metal.tga" -crop "$CROP" +repage "$OUT/parity_${SAFE}_metal_crop.png"
magick "$OUT/parity_${SAFE}_gl3_crop.png" "$OUT/parity_${SAFE}_metal_crop.png" \
	-compose difference -composite -colorspace Gray -format 'mean difference (crop '"$CROP"'): %[fx:mean*255]/255\n' info:

magick "$OUT/parity_${SAFE}_gl3.tga" -resize 1280x "$OUT/parity_${SAFE}_gl3.png"
magick "$OUT/parity_${SAFE}_metal.tga" -resize 1280x "$OUT/parity_${SAFE}_metal.png"
