#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ];then tmp=$1;mkdir -p "$tmp";else tmp=$(mktemp -d);trap 'rm -rf "$tmp"' EXIT;fi
# Generate the unchanged material selector/factory fixture without running a
# second executable. The existing script's extraction is the shared source.
python3 - "$repo" "$tmp" "${OM_POST_FX_BINDING_SOURCE:-}" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2]);script=(r/'tools/build/tests/test-metal-material-state.sh').read_text()
block=script.split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
saved=sys.argv;sys.argv=['extract',str(r/'engine/src/client/refresh/metal/mtl_main.m'),str(p/'material_production.h')];exec(compile(block,'material extractor','exec'));sys.argv=saved
s=(r/'engine/src/client/refresh/metal/mtl_main.m').read_text();out=[]
out.append(re.search(r'(?ms)^typedef struct mtl_world_vertex_s.*?^} mtl_world_vertex_t;',s).group())
out.append('#define MTL_WORLD_STRIDE sizeof(mtl_world_vertex_t)')
out.append('#define MTL_MAX_DLIGHTS 32')
out.append(re.search(r'(?ms)^typedef struct\n\{\n\tfloat mvp\[16\];.*?^} mtl_world_uniform_t;',s).group())
for name in ('mtl_particle_shader','mtl_turb_shader','mtl_world_shader'):
 out.append(re.search(r'(?ms)^static [^\n]+\b'+name+r' = @R"MSL\(.*?\)MSL";',s).group())
out.append('#include "mtl_lightmap_shader.h"')
for name in ('MTL_BuildParticlePipeline','MTL_BuildTurbPipeline','MTL_BuildWorldPipeline','MTL_BuildSkyPipeline'):
 out.append(re.search(r'(?ms)^static [^\n]+\n'+name+r'\(.*?^}',s).group())
generic=(r/'engine/src/client/refresh/metal/mtl_generic_models.h').read_text()
out.append(generic[generic.index('static id<MTLRenderPipelineState>'):generic.index('static void\nMTL_GenericModelState')])
emission=(r/'engine/src/client/refresh/metal/mtl_emission_state.h').read_text()
out.append(re.search(r'(?ms)^static void MTL_PostBindEmission\(.*?^}',emission).group())
fx=(pathlib.Path(sys.argv[3]) if len(sys.argv)>3 and sys.argv[3] else r/'engine/src/client/refresh/metal/mtl_fx.h').read_text()
out.append(re.search(r'(?ms)^static void MTL_FXDrawGeometry\(.*?^}',fx).group())
(p/'post_factories_production.h').write_text('\n\n'.join(out))
PY
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable -Wno-format -Wno-missing-field-initializers -Wno-missing-braces \
 -fsanitize=address,undefined -fno-omit-frame-pointer \
 -I"$tmp" -I"$repo/engine/src/ghoul" -I"$repo/engine/src/client/refresh/metal" \
 "$repo/engine/src/client/refresh/metal/tests/post_factories.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/post_factories"
"$tmp/post_factories"
