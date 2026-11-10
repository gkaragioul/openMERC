#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-410 production load/free fog ownership verification.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "${OM_FOG_MAIN:-$repo/engine/src/client/refresh/metal/mtl_main.m}" "$tmp" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text();out=pathlib.Path(sys.argv[2]);types=''
for tag,name in [('mtl_surface_s','mtl_surface_t'),('mtl_model_s','mtl_model_t')]:
 t=re.search(r'(?ms)^typedef struct '+tag+r'.*?^} '+name+r';',s).group()
 # The old exact loader has no region hook; an observation field in its fixture
 # remains calloc-zero. The loader body itself is never changed by this test.
 if name=='mtl_model_t' and not re.search(r'\bfog\s*;',t):t=t.replace('} mtl_model_t;','struct mtl_fog_world_s *fog;\n} mtl_model_t;')
 if name=='mtl_surface_t' and 'bsp_plane' not in t:t=t.replace('} mtl_surface_t;','const cplane_t *bsp_plane;\n} mtl_surface_t;')
 types+=t+'\n'
(out/'fog_registration_types.h').write_text(types)
fn=''
for name in ['MTL_FreeModel','MTL_LoadBrushModel']:
 fn+=re.search(r'(?ms)^static (?:void|struct model_s \*)\n'+name+r'\(.*?^}',s).group()+'\n'
(out/'fog_registration_functions.h').write_text(fn)
PY
clang -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable -fsanitize=address,undefined -fno-omit-frame-pointer \
 -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' -I"$tmp" \
 "$repo/engine/src/client/refresh/metal/tests/fog_registration.c" -lm -o "$tmp/fog_registration"
"$tmp/fog_registration"
