#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Native Metal alias models must combine BSP light with the MD2 normal shade.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$root/engine/src/client/refresh/metal/mtl_main.m"
alias_body=$(sed -n '/MTL_DrawAliasModel(entity_t \*e,/,/^}/p' "$source_file")
trace_body=$(sed -n '/MTL_LightTrace(mtl_model_t \*mod,/,/^}/p' "$source_file")
shade_body=$(sed -n '/MTL_AliasShadeLight(const entity_t \*e,/,/^}/p' "$source_file")

if ! grep -Fq 'MTL_AliasShadeLight(e, shadelight);' <<<"$alias_body"; then
	echo "FAIL: alias entities do not request native Metal entity lighting" >&2
	exit 1
fi

if ! grep -Fq 'MTL_SoFLightPoint(e->origin, shadelight);' <<<"$shade_body"; then
	echo "FAIL: alias entities do not sample native Metal BSP lighting" >&2
	exit 1
fi

if ! grep -Fq 'cur->color[j] = l * shadelight[j];' <<<"$alias_body"; then
	echo "FAIL: alias normal shading is not combined with sampled light" >&2
	exit 1
fi

if ! grep -Fq '* modulate' <<<"$trace_body"; then
	echo "FAIL: static light trace no longer matches GL3's first gl_modulate stage" >&2
	exit 1
fi

echo "PASS: native Metal alias lighting combines BSP and normal shading"
