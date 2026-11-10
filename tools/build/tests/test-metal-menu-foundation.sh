#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Actual offscreen pixels from production menu operations and production MSL.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
if [ -n "${OM_MENU_HUD_HEADER:-}" ]; then cp "$OM_MENU_HUD_HEADER" "$tmp/mtl_sofhud.h"; fi
python3 - "$repo/engine/src/client/refresh/metal/mtl_main.m" "$tmp/menu_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
parts=[re.search(r'(?ms)^static [^\n]+\bmtl_shader_source = @R"MSL\(.*?\)MSL";',s).group()]
for struct,alias in [('mtl_vertex_s','mtl_vertex_t'),('mtl_image_s','mtl_image_t')]:
    parts.append(re.search(r'(?ms)^typedef struct '+struct+r'.*?^} '+alias+r';',s).group())
parts.append('#define MTL_VERTEX_STRIDE sizeof(mtl_vertex_t)')
for name in ('MTL_BuildPipeline','MTL_MakeGhoulSampler','MTL_SoF2DPipeline','MTL_MakeUISampler','MTL_SubmitQuad'):
    parts.append(re.search(r'(?ms)^static [^\n]+\n'+name+r'\(.*?^}',s).group())
pathlib.Path(sys.argv[2]).write_text('\n\n'.join(parts))
PY
sanitize=(-fno-omit-frame-pointer)
if [ "${OM_MENU_SANITIZE:-0}" = 1 ]; then sanitize=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
clang++ -std=c++17 -fobjc-arc -Wno-incompatible-pointer-types -Wno-format "${sanitize[@]}" \
    -I"$tmp" -I"$repo/engine/src/client/refresh/metal" \
    "${OM_MENU_TEST_SOURCE:-$repo/engine/src/client/refresh/metal/tests/menu_foundation.mm}" \
    -Wl,-export_dynamic -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/menu_foundation"
"$tmp/menu_foundation"
