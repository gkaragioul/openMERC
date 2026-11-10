#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Native Metal must select world visibility from the refdef it is rendering.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$root/engine/src/client/refresh/metal/mtl_main.m"
mark_leaves=$(sed -n '/MTL_MarkLeaves(mtl_model_t \*mod)/,/^}/p' "$source_file")

if ! grep -Fq 'Mod_PointInLeaf(mtl_refdef.vieworg, mod->nodes)' <<<"$mark_leaves"; then
	echo "FAIL: native Metal does not select PVS from mtl_refdef.vieworg" >&2
	exit 1
fi

if grep -Fq 'r_newrefdef' <<<"$mark_leaves"; then
	echo "FAIL: native Metal visibility still reads another renderer's refdef" >&2
	exit 1
fi

echo "PASS: native Metal visibility uses its current refdef"
