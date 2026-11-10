#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Require an independent native Metal path for BSP turbulent surfaces.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$repo/engine/src/client/refresh/metal/mtl_main.m"

for required in \
  'mtl_vs_turb' \
  'mtl_fs_turb' \
  'MTL_BuildTurbPipeline' \
  'MTL_DrawTurbSurface' \
  'SURF_DRAWTURB' \
  'mtl_pipe_turb_alpha' \
  'mtl_depth_readonly'; do
	if ! grep -q "$required" "$source_file"; then
		printf 'FAIL: native Metal turb path is missing %s\n' "$required" >&2
		exit 1
	fi
done

printf '%s\n' 'PASS: native Metal BSP turb surface contract is present'
