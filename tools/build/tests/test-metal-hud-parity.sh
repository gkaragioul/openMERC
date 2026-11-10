#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Bottom HUD band; use the same kos2 camera after weapon parity is established.
set -euo pipefail
actual=${1:?Metal capture required}
reference=${2:?GL3 capture required}
limit=${3:-1}
[ "$(magick identify -format '%wx%h' "$actual")" = "$(magick identify -format '%wx%h' "$reference")" ] || exit 1
error=$(magick \( "$actual" -gravity South -crop '100%x15%+0+0' +repage \) \
	\( "$reference" -gravity South -crop '100%x15%+0+0' +repage \) \
	-compose difference -composite -format '%[fx:mean*255]' info:)
awk -v error="$error" -v limit="$limit" 'BEGIN {
	printf "HUD band MAE: %.6f/255 (limit %.3f/255)\n", error, limit;
	if (error > limit) { print "FAIL: HUD band exceeds parity limit"; exit 1; }
	print "PASS: HUD band meets parity limit";
}'
