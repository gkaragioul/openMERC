#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Verify the native Metal renderer owns a refdef.particles path with circular,
# alpha-blended camera-facing billboards and read-only depth.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$repo/engine/src/client/refresh/metal/mtl_main.m"

for required in \
  'mtl_vs_particle' \
  'mtl_fs_particle' \
  'MTL_BuildParticlePipeline' \
  'MTL_DrawParticles' \
  'mtl_refdef.particles' \
  'MTLBlendFactorSourceAlpha' \
  'mtl_depth_readonly' \
  'MTL_DrawParticles(mvp, render_right, render_up'; do
	if ! grep -q "$required" "$source_file"; then
		printf 'FAIL: native Metal particle path is missing %s\n' "$required" >&2
		exit 1
	fi
done

printf '%s\n' 'PASS: native Metal refdef particle billboard contract is present'
