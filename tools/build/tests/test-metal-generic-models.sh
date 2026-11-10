#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Actual production model functions and MSL, rendered offscreen without a game.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
python3 - "$repo" "$tmp" "${OM_GENERIC_MODELS_SOURCE:-}" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);override=sys.argv[3]
shared=pathlib.Path(override) if override and pathlib.Path(override).suffix=='.m' else r/'engine/src/client/refresh/metal/mtl_main.m'
s=shared.read_text()
parts=['#include "tests/post_factory_environment.h"','#include "mtl_fog_shaders.h"']
for name in ('mtl_shader_source','mtl_alias_shader'):
 parts.append(re.search(r'(?ms)^static [^\n]+\b'+name+r' = @R"MSL\(.*?\)MSL";',s).group())
for tag,alias in [('mtl_alias_vertex_s','mtl_alias_vertex_t')]:
 parts.append(re.search(r'(?ms)^typedef struct '+tag+r'.*?^} '+alias+r';',s).group())
parts+=re.findall(r'^#define MTL_BLEND_.*$',s,re.M)
parts.append('#define MTL_ALIAS_STRIDE sizeof(mtl_alias_vertex_t)')
parts.append(re.search(r'(?ms)^static [^\n]+\nMTL_BuildAliasPipeline\(.*?^}',s).group())
(out/'generic_shared.h').write_text('\n\n'.join(parts)+'\n')
source=pathlib.Path(override) if override else r/'engine/src/client/refresh/metal/mtl_generic_models.h'
if not source.exists() or source.suffix=='.m':
 text=source.read_text() if source.exists() else s
 blocks=[re.search(r'(?ms)^static void\n'+name+r'\(.*?^}',text).group() for name in ('MTL_DrawAliasModel','MTL_DrawSpriteModel')]
 (out/'generic_models_production.h').write_text('\n\n'.join(blocks)+'\n')
else:
 (out/'generic_models_production.h').write_text(source.read_text())
# The before-source adapter has no parser API; actual old draw cases still run
# and fail in ASan. Only the two direct new-helper arithmetic probes are absent.
bounded='MTL_MD2Validate' in (out/'generic_models_production.h').read_text()
with (out/'generic_models_production.h').open('a') as generated:
 generated.write('\n#define OM_MD2_BUDGET_TEST_API '+str(int(bounded))+'\n')
# The test uses the same on-disk format declarations as the real model loader.
f=(r/'engine/src/common/header/files.h').read_text()
names=('dtrivertx_t','daliasframe_t','dmdl_t','dsprframe_t','dsprite_t')
types=[]
for name in names:
 candidates=re.findall(r'(?ms)^typedef struct\n\{.*?^} '+name+r';',f)
 # A non-greedy start can include earlier typedefs. Keep only the final struct.
 types.append(candidates[0][candidates[0].rfind('typedef struct'):])
(out/'generic_formats.h').write_text('\n'.join(types)+'\n')
PY
sanitize=(-fno-omit-frame-pointer)
if [ "${OM_GENERIC_MODELS_SANITIZE:-0}" = 1 ]; then sanitize=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable -Wno-c++11-narrowing \
 "${sanitize[@]}" -I"$tmp" -I"$repo/engine/src/ghoul" -I"$repo/engine/src/client/refresh/metal" \
 "$repo/engine/src/client/refresh/metal/tests/generic_models.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/generic_models"
"$tmp/generic_models"
