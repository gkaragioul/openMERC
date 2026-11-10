#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Native Metal view-weapon contract: regular alias weapons use r_gunfov while
# both alias and Ghoul paths preserve the GL3 RF_DEPTHHACK depth-range rule.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$repo/engine/src/client/refresh/metal/mtl_main.m"

for required in \
  'r_gunfov' \
  'MTL_AliasEntityMVP' \
  'RF_WEAPONMODEL' \
  'RF_DEPTHHACK' \
  'MTL_ApplyDepthHack' \
  'MTL_DrawAliasModel(e, mvp, view)' \
  'MTL_DrawGhoulEntity(e, mvp)'; do
	if ! grep -q "$required" "$source_file"; then
		printf 'FAIL: native Metal view-weapon path is missing %s\n' "$required" >&2
		exit 1
	fi
done

printf '%s\n' 'PASS: native Metal alias weapon FOV and Ghoul/alias depth-hack contract is present'
