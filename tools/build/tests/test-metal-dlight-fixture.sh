#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Check the visible response of the controlled red SoF light fixture.
# Inputs must be the same fixed kos2 camera with r_om_pdlight_test
# "800 128 1 0 0", changing only r_om_pdlight from 0 to 1.
# This proves a visible world response, not cross-renderer pixel parity.
set -euo pipefail

before=${1:?disabled capture required}
after=${2:?enabled capture required}
before_size=$(magick identify -format '%wx%h' "$before")
after_size=$(magick identify -format '%wx%h' "$after")
if [ "$before_size" != "$after_size" ]; then
	echo 'FAIL: dynamic-light fixture capture sizes differ' >&2
	exit 1
fi

# Exclude changing console text, HUD and the first-person weapon. The upper
# central world patch is lit strongly by the same GL3 reference fixture.
red_delta=$(magick \( "$before" -gravity North -crop '70%x45%+0+70' +repage \) \
	\( "$after" -gravity North -crop '70%x45%+0+70' +repage \) \
	-compose difference -composite -channel R -separate -format '%[fx:mean]' info:)
awk -v delta="$red_delta" 'BEGIN {
	printf "controlled world red delta: %.6f (%.3f/255)\n", delta, delta * 255;
	if (delta < 0.02) {
		print "FAIL: native per-pixel dynamic light has no substantial world response";
		exit 1;
	}
	print "PASS: controlled native per-pixel dynamic light visibly reaches the world";
}'
