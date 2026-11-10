#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
python3 - "$repo" "$tmp" "${OM_WORLD_MATERIAL_SOURCE:-}" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);s=pathlib.Path(sys.argv[3]).read_text() if sys.argv[3] else (r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
parts=[]
for tag,name in [('mtl_image_s','mtl_image_t'),('mtl_surface_s','mtl_surface_t'),('mtl_model_s','mtl_model_t'),('mtl_world_vertex_s','mtl_world_vertex_t')]:
 parts.append(re.search(r'(?ms)^typedef struct '+tag+r'.*?^} '+name+r';',s).group())
parts.append('#define MTL_WORLD_STRIDE sizeof(mtl_world_vertex_t)')
parts.append(re.search(r'(?ms)^typedef struct\n\{\n\tfloat mvp\[16\];.*?^} mtl_world_uniform_t;',s).group())
if 'struct mtl_lightmap_s *lighting' in s:parts.append('#define OM_WORLD_HAS_LIGHTMAPS 1')
(out/'world_material_types.h').write_text('\n'.join(parts)+'\n')
parts=[]
for name in ('mtl_shader_source','mtl_world_shader'):
 parts.append(re.search(r'(?ms)^static [^\n]+\b'+name+r' = @R"MSL\(.*?\)MSL";',s).group())
(out/'world_material_shaders.h').write_text('\n'.join(parts)+'\n')
parts=[]
update=re.search(r'(?ms)^static void\nMTL_UpdateDetailScroll\(.*?^}',s)
if update:parts+=['#define OM_WORLD_DETAIL_UPDATE 1',update.group()]
for name in ('MTL_LoadPic','MTL_DrawSurface'):
 parts.append(re.search(r'(?ms)^static [^\n]+\n'+name+r'\(.*?^}',s).group())
a=(r/'engine/src/client/refresh/metal/mtl_worldalpha.h').read_text()
parts.insert(0,re.search(r'(?ms)^static mtl_image_t \*MTL_AnimatedWorldImage\(.*?^}',a).group())
(out/'world_material_functions.h').write_text('\n'.join(parts)+'\n')
PY
extra=();if [ "${OM_WORLD_FOG_TEST:-0}" = 1 ]; then extra=(-DOM_FOG_CLASSIFICATION_TEST=1);fi
clang -fobjc-arc -arch arm64 -O2 -Wall -Wextra -Wno-unused-function -Wno-unused-variable -Wno-format -Wno-incompatible-pointer-types "${extra[@]}" \
 -fsanitize=address,undefined -I"$tmp" -I"$repo/engine/src/client/refresh/metal" -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' \
 "$repo/engine/src/client/refresh/metal/tests/world_materials.m" -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/world_materials"
"$tmp/world_materials"
