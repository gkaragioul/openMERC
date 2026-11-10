#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Compare a fixed kos2 world patch, excluding console, HUD and view weapon.
# Both captures must use the same camera, dimensions, time and fullbright mode.
set -euo pipefail
actual=${1:?Metal capture required}
reference=${2:?GL3 capture required}
limit=${3:-1}
if [ "$(magick identify -format '%wx%h' "$actual")" != "$(magick identify -format '%wx%h' "$reference")" ]; then
	echo 'FAIL: capture dimensions differ' >&2
	exit 1
fi
error=$(magick \( "$actual" -gravity North -crop '70%x45%+0+70' +repage \) \
	\( "$reference" -gravity North -crop '70%x45%+0+70' +repage \) \
	-compose difference -composite -format '%[fx:mean*255]' info:)
awk -v error="$error" -v limit="$limit" 'BEGIN {
	printf "world patch MAE: %.6f/255 (limit %.3f/255)\n", error, limit;
	if (error > limit) { print "FAIL: fixed world patch exceeds parity limit"; exit 1; }
	print "PASS: fixed world patch meets parity limit";
}'
