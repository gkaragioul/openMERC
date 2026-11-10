#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "${OM_BRUSH_MAIN:-$repo/engine/src/client/refresh/metal/mtl_main.m}" "$tmp/brush_surface_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text();out=''
for tag,name in [('mtl_surface_s','mtl_surface_t'),('mtl_model_s','mtl_model_t'),('mtl_world_vertex_s','mtl_world_vertex_t')]:
 out+=re.search(r'(?ms)^typedef struct '+tag+r'.*?^} '+name+r';',s).group()+'\n'
out+='#define MTL_WORLD_STRIDE sizeof(mtl_world_vertex_t)\n'
fn=re.search(r'(?ms)^static void\nMTL_LoadWorldSurfaces\(.*?^}',s).group()
if 'struct mtl_lightmap_s *lighting' in s:out+='#define OM_BRUSH_HAS_LIGHTMAPS 1\n'
if 'const cplane_t *bsp_plane' in s:out+='#define OM_BRUSH_HAS_FOG_PLANES 1\n'
if 'const dmodel_t *dm' in fn:out+='#define OM_BRUSH_OLD_LOADER 1\n'
pathlib.Path(sys.argv[2]).write_text(out+fn+'\n')
PY
clang -fobjc-arc -arch arm64 -O2 -Wno-deprecated-declarations -fsanitize=address,undefined -I"$tmp" \
 -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' \
 "$repo/engine/src/client/refresh/metal/tests/brush_surface_loader.m" \
 -framework Foundation -framework Metal -o "$tmp/brush_surface_loader"
"$tmp/brush_surface_loader"
