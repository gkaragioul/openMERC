#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-AMEND-006 I4c.4 actual native brush-face count.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
mode=${1:-after};tmp=${2:-$(mktemp -d)};mkdir -p "$tmp"
case "$mode" in before|after) ;; *) echo "usage: $0 [before|after] [VERIFY directory]" >&2;exit 2;; esac
if [ "$mode" = before ]; then
 if [ ! -f "$tmp/retained-main.m" ] || [ ! -f "$tmp/retained-brush.h" ] || [ ! -f "$tmp/retained-worldalpha.h" ]; then
  if rg -q 'MTL_BrushPolygonDrawn' "$repo/engine/src/client/refresh/metal/mtl_main.m"; then
   echo 'before mode requires the VERIFY directory containing the retained pre-counter main/brush/worldalpha sources' >&2
   exit 2
  fi
  cp "$repo/engine/src/client/refresh/metal/mtl_main.m" "$tmp/retained-main.m"
  cp "$repo/engine/src/client/refresh/metal/mtl_brush.h" "$tmp/retained-brush.h"
  cp "$repo/engine/src/client/refresh/metal/mtl_worldalpha.h" "$tmp/retained-worldalpha.h"
 fi
fi
python3 - "$repo" "$tmp" "$mode" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2]);old=sys.argv[3]=='before'
s=(p/'retained-main.m' if old else r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
parts=[]
for tag,name in [('mtl_image_s','mtl_image_t'),('mtl_surface_s','mtl_surface_t'),('mtl_model_s','mtl_model_t'),('mtl_world_vertex_s','mtl_world_vertex_t'),('mtl_alias_vertex_s','mtl_alias_vertex_t')]:
 parts.append(re.search(r'(?ms)^typedef struct '+tag+r'.*?^} '+name+r';',s).group())
parts+=['#define MTL_WORLD_STRIDE sizeof(mtl_world_vertex_t)','#define MTL_ALIAS_STRIDE sizeof(mtl_alias_vertex_t)',re.search(r'(?ms)^typedef struct\n\{\n\tfloat mvp\[16\];.*?^} mtl_world_uniform_t;',s).group()]
(p/'brush_polygon_types.h').write_text('\n'.join(parts)+'\n')
parts=[]
for name in ('MTL_EntityMatrix','MTL_DrawTurbSurface','MTL_DrawSurface'):
 parts.append(re.search(r'(?ms)^static void\n'+name+r'\(.*?^}',s).group())
parts.append((p/'retained-worldalpha.h' if old else r/'engine/src/client/refresh/metal/mtl_worldalpha.h').read_text())
parts.append((p/'retained-brush.h' if old else r/'engine/src/client/refresh/metal/mtl_brush.h').read_text())
(p/'brush_polygon_functions.h').write_text('\n'.join(parts)+'\n')
PY
clang -x objective-c -std=gnu11 -fobjc-arc -arch arm64 -O2 -Wall -Wextra -Wno-unused-function -Wno-unused-variable \
 -DBRUSH_POLYGONS_OLD=$([ "$mode" = before ] && echo 1 || echo 0) -fsanitize=address,undefined \
 -I"$tmp" -I"$repo/engine/src/client/refresh/metal" -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' \
 "$repo/engine/src/client/refresh/metal/tests/brush_polygons.m" -framework Foundation -framework Metal -o "$tmp/brush_polygons"
"$tmp/brush_polygons"
