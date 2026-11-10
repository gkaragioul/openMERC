#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo" "$tmp" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2]);s=(r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
out=''
for tag,name in [('mtl_image_s','mtl_image_t'),('mtl_surface_s','mtl_surface_t'),('mtl_model_s','mtl_model_t'),('mtl_world_vertex_s','mtl_world_vertex_t'),('mtl_alias_vertex_s','mtl_alias_vertex_t')]:
 out+=re.search(r'(?ms)^typedef struct '+tag+r'.*?^} '+name+r';',s).group()+'\n'
out+='#define MTL_WORLD_STRIDE sizeof(mtl_world_vertex_t)\n#define MTL_ALIAS_STRIDE sizeof(mtl_alias_vertex_t)\n'
(p/'brush_draw_types.h').write_text(out)
out=re.search(r'(?ms)^static void\nMTL_EntityMatrix\(.*?^}',s).group()+'\n'
a=(r/'engine/src/common/shared/shared.c').read_text()
out+=re.search(r'(?ms)^void\nAngleVectors\(.*?^}',a).group()+'\n'
a=(r/'engine/src/client/refresh/metal/mtl_liquid.h').read_text()
out+=re.search(r'(?ms)^static void MTL_LiquidEntityMatrix\(.*?^}',a).group()+'\n'
a=(r/'engine/src/client/refresh/metal/mtl_worldalpha.h').read_text()
out+=re.search(r'(?ms)^static mtl_image_t \*MTL_AnimatedWorldImage\(.*?^}',a).group()+'\n'
a=(r/'engine/src/client/refresh/files/surf.c').read_text()
out+=re.search(r'(?ms)^void\nR_MarkLights\(.*?^}',a).group()+'\n'
(p/'brush_draw_functions.h').write_text(out)
PY
clang -fobjc-arc -arch arm64 -O2 -Wno-deprecated-declarations -Wno-incompatible-pointer-types -fsanitize=address,undefined -I"$tmp" \
 -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' \
 "$repo/engine/src/client/refresh/metal/tests/brush_draw.m" \
 -framework Foundation -framework Metal -o "$tmp/brush_draw"
"$tmp/brush_draw"
