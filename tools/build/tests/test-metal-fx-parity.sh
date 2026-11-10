#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fixed om_fxrenderfixture=2 kos2 patch: billboard, oriented quad and beam.
set -euo pipefail
actual=${1:?Metal capture required}
reference=${2:?GL3 capture required}
limit=${3:-1}
variant=${4:-base}
for capture in "$actual" "$reference"; do
	[ "$(magick identify -format '%wx%h' "$capture")" = 1728x1117 ] || exit 1
done
error=$(magick \( "$actual" -crop 900x420+450+340 +repage \) \
	\( "$reference" -crop 900x420+450+340 +repage \) \
	-compose difference -composite -format '%[fx:mean*255]' info:)
awk -v error="$error" -v limit="$limit" 'BEGIN {
	printf "FX patch MAE: %.6f/255 (limit %.3f/255)\n", error, limit;
	if (error > limit) { print "FAIL: FX patch exceeds parity limit"; exit 1; }
	print "PASS: FX patch meets parity limit";
}'
if [ "$variant" = lit ]; then
	# Mode 3's lit sprite extends above the broad patch. Its small footprint
	# must not disappear into an average dominated by unchanged world pixels.
	error=$(magick \( "$actual" -crop 190x100+770+300 +repage \) \
		\( "$reference" -crop 190x100+770+300 +repage \) \
		-compose difference -composite -format '%[fx:mean*255]' info:)
	awk -v error="$error" -v limit="$limit" 'BEGIN {
		printf "lit sprite MAE: %.6f/255 (limit %.3f/255)\n", error, limit;
		if(error>limit) { print "FAIL: lit sprite exceeds parity limit"; exit 1; }
		print "PASS: lit sprite meets parity limit";
	}'
fi
