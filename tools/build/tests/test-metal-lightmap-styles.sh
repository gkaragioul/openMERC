#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
python3 - "$repo" "$tmp" "${OM_LIGHTMAP_BASELINE_SOURCE:-}" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);base=sys.argv[3]
s=pathlib.Path(base).read_text() if base else (r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
parts=[]
for name in ('mtl_shader_source','mtl_world_shader'):
 declaration=re.search(r'(?ms)^static [^\n]+\b'+name+r' = @R"MSL\(.*?\)MSL";',s).group()
 # Objective-C's historical char* declaration holds an NSString literal.
 # Use its actual runtime type in this strict Objective-C++ harness; MSL is exact.
 declaration=declaration.replace('static const char *mtl_world_shader','static NSString *const mtl_world_shader')
 parts.append(declaration)
parts.append(re.search(r'(?ms)^typedef struct mtl_world_vertex_s.*?^} mtl_world_vertex_t;',s).group())
parts.append(re.search(r'(?ms)^typedef struct\n\{\n\tfloat mvp\[16\];.*?^} mtl_world_uniform_t;',s).group())
parts+=['#define MTL_WORLD_STRIDE sizeof(mtl_world_vertex_t)']
if base:
 parts.append('#define OM_LIGHTMAP_BASELINE 1')
 parts.append(re.search(r'(?ms)^static [^\n]+\nMTL_BuildWorldPipeline\(.*?^}',s).group())
(out/'lightmap_production.h').write_text('\n\n'.join(parts)+'\n')
reference=(r/'engine/src/client/refresh/gl3/gl3_dynlight.c').read_text()
(out/'lightmap_dynamic_oracle.h').write_text(re.search(r'(?ms)^void\nGL3_DynLight_Face\(.*?^}',reference).group()+'\n')
animation=(r/'engine/src/client/refresh/metal/mtl_worldalpha.h').read_text()
(out/'lightmap_animation_production.h').write_text(re.search(r'(?ms)^static mtl_image_t \*MTL_AnimatedWorldImage\(.*?^}',animation).group()+'\n')
PY
sanitize=(-fno-omit-frame-pointer)
if [ "${OM_LIGHTMAP_SANITIZE:-0}" = 1 ]; then sanitize=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable \
 -Wno-format -Wno-objc-literal-conversion "${sanitize[@]}" -I"$tmp" -I"$repo/engine/src/client/refresh/metal" \
 "$repo/engine/src/client/refresh/metal/tests/lightmap_styles.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/lightmap_styles"
"$tmp/lightmap_styles"
