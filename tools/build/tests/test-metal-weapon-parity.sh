#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fixed kos2 shotgun patch, excluding the HUD and console, at 1728x1117.
set -euo pipefail
actual=${1:?Metal capture required}
reference=${2:?GL3 capture required}
limit=${3:-1}
for capture in "$actual" "$reference"; do
	[ "$(magick identify -format '%wx%h' "$capture")" = 1728x1117 ] || {
		echo 'FAIL: weapon fixture requires 1728x1117 captures' >&2; exit 1;
	}
done
# The HUD health panel reaches x=900 near the bottom of this viewport.
# Stop above it; a full-height crop incorrectly mixes HUD with weapon parity.
error=$(magick \( "$actual" -crop 550x360+900+650 +repage \) \
	\( "$reference" -crop 550x360+900+650 +repage \) \
	-compose difference -composite -format '%[fx:mean*255]' info:)
awk -v error="$error" -v limit="$limit" 'BEGIN {
	printf "weapon patch MAE: %.6f/255 (limit %.3f/255)\n", error, limit;
	if (error > limit) { print "FAIL: fixed weapon patch exceeds parity limit"; exit 1; }
	print "PASS: fixed weapon patch meets parity limit";
}'
