#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Compile only production shader/factory/selector declarations into a tiny
# native offscreen GPU test. No game process, window or translation backend.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
python3 - "$repo/engine/src/client/refresh/metal/mtl_main.m" "$tmp/material_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
parts=['#include "tests/post_factory_environment.h"','#include "mtl_fog_shaders.h"']
for name in ('mtl_shader_source','mtl_alias_shader'):
    parts.append(re.search(r'(?ms)^static [^\n]+\b'+name+r' = @R"MSL\(.*?\)MSL";',s).group())
for struct,alias in [('mtl_alias_vertex_s','mtl_alias_vertex_t'),('mtl_vertex_s','mtl_vertex_t'),('mtl_image_s','mtl_image_t')]:
    parts.append(re.search(r'(?ms)^typedef struct '+struct+r'.*?^} '+alias+r';',s).group())
parts.append('#define MTL_ALIAS_STRIDE sizeof(mtl_alias_vertex_t)')
parts.append('#define MTL_VERTEX_STRIDE sizeof(mtl_vertex_t)')
parts.extend(re.findall(r'^#define MTL_BLEND_.*$',s,re.M))
for name in ('MTL_BuildAliasPipeline','MTL_MakeGhoulSampler','MTL_GhoulPipeline','MTL_GhoulSampler','MTL_GhoulAlphaCutoff','MTL_BuildPipeline','MTL_SoF2DPipeline','MTL_MakeUISampler','MTL_SubmitQuad'):
    parts.append(re.search(r'(?ms)^static [^\n]+\n'+name+r'\(.*?^}',s).group())
args=re.search(r'MTL_MakeGhoulSampler\(([^)]*)\)',s).group(1)
if args.count(',')==1:
    init='''mtl_ghoul_samp_clamp_mip=MTL_MakeGhoulSampler(NO,NO);
    mtl_ghoul_samp_repeat_mip=MTL_MakeGhoulSampler(YES,NO);
    mtl_ghoul_samp_clamp_nomip=MTL_MakeGhoulSampler(NO,YES);
    mtl_ghoul_samp_repeat_nomip=MTL_MakeGhoulSampler(YES,YES);
    mtl_samp_ui=MTL_MakeGhoulSampler(NO,YES);'''
else:
    init='''for(int u=0;u<2;u++) for(int v=0;v<2;v++) for(int n=0;n<2;n++)
    mtl_ghoul_samplers[u][v][n]=MTL_MakeGhoulSampler(u,v,n);
    mtl_samp_ui=MTL_MakeGhoulSampler(NO,NO,YES);'''
parts.append('static void MTL_TestInitSamplers(void) { '+init+' mtl_samp_ui=MTL_MakeUISampler(NO); mtl_samp_ui_linear=MTL_MakeUISampler(YES); }')
pathlib.Path(sys.argv[2]).write_text('\n\n'.join(parts))
PY
clang++ -std=c++17 -fobjc-arc -Wno-incompatible-pointer-types -Wno-format \
	-I"$repo/engine/src/ghoul" -I"$repo/engine/src/client/refresh/metal" -I"$tmp" \
	"$repo/engine/src/client/refresh/metal/tests/material_state.mm" \
	-framework Foundation -framework Metal -framework QuartzCore -o "$tmp/material_state"
"$tmp/material_state"
