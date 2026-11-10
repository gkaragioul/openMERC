#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fixed-clock 1920x1080 menu controls, with a feature-sized gate.
set -euo pipefail
actual=${1:?Metal capture required}; reference=${2:?GL3 capture required}
variant=${3:?legacy, modern, fractional or lit}; limit=${4:-1}
for capture in "$actual" "$reference"; do
 [ "$(magick identify -format '%wx%h' "$capture")" = 1920x1080 ] || {
  echo 'FAIL: menu fixture requires 1920x1080';exit 1;
 }
done
case "$variant" in
 legacy) patch=640x224+640+300;;
 modern) patch=1880x1000+20+60;;
 fractional) patch=1848x838+36+122;;
 lit) patch=360x390+480+180;;
 *) echo 'Unsupported menu fixture';exit 2;;
esac
error=$(magick \( "$actual" -crop "$patch" +repage \) \( "$reference" -crop "$patch" +repage \) \
 -compose difference -composite -format '%[fx:mean*255]' info:)
awk -v variant="$variant" -v error="$error" -v limit="$limit" 'BEGIN {
 printf "%s menu patch MAE: %.9f/255 (limit %.3f/255)\n",variant,error,limit;
 if(error>limit){print "FAIL: native menu patch exceeds parity limit";exit 1;}
 print "PASS: native menu patch meets parity limit";
}'
