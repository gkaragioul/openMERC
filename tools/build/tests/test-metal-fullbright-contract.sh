#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Require native Metal world rendering to honor the engine's fullbright/IR
# lightmap bypass instead of silently sampling lightmaps in every frame.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$repo/engine/src/client/refresh/metal/mtl_main.m"

for required in \
  'r_fullbright' \
  'RDF_IRGOGGLES' \
  'u.fullbright' \
  'lm = float3(1.0)'; do
	if ! grep -q "$required" "$source_file"; then
		printf 'FAIL: native Metal fullbright path is missing %s\n' "$required" >&2
		exit 1
	fi
done

printf '%s\n' 'PASS: native Metal world fullbright/IR lightmap bypass contract is present'
