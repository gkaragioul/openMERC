#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-AMEND-016 R16.2 and R16.4 verification.
# Native sun keys and cascade maths against the actual GPL gl3_csm.c functions, and the MSL receiver on the GPU.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
python3 - "$repo" "$tmp" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2])
s=(r/'engine/src/client/refresh/gl3/gl3_csm.c').read_text()
def block(pat):
 m=re.search(pat,s,re.S|re.M)
 assert m,pat
 return m.group(0)
parts=[]
parts.append(block(r'^static struct\n\{\n\tqboolean valid;.*?^\} sun;'))
parts.append(block(r'^typedef struct\n\{\n\tfloat vp\[CSM_MAXCASC\]\[16\];.*?^\} csmubo_t;'))
parts.append('static struct { const void *built; int numdyn, size; csmubo_t u; } C;')
parts.append(block(r'^typedef struct\n\{\n\tchar classname\[32\].*?^\} csment_t;'))
parts.append(block(r'^static const char \*\nToken\(.*?^\}'))
parts.append(block(r'^static int\nFloats\(.*?^\}'))
parts.append(block(r'^void\nGL3_CSM_LoadSun\(.*?^\}'))
parts.append(block(r'^static void\nOrthoForCascade\(.*?^\}'))
(out/'csm_gl_ref.h').write_text('\n\n'.join(parts)+'\n')
main=(r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
world=re.search(r'(?ms)^static [^\n]+\bmtl_world_shader = @R"MSL\(.*?\)MSL";',main).group()
gs=re.search(r'(?ms)^static NSString \*const mtl_gshadow_msl = @R"MSL\(.*?\)MSL";',main).group().replace('mtl_gshadow_msl','mtl_gshadow_test_msl')
(out/'csm_host_shaders.h').write_text(world.replace('static const char *mtl_world_shader','static NSString *const mtl_world_shader')+'\n\n'+gs+'\n')
PY
clang -std=gnu2x -O1 -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter \
  -I"$tmp" -I"$repo/engine/src/client/refresh/metal" \
  "$repo/engine/src/client/refresh/metal/tests/csm_parity.m" -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/csm_parity"
"$tmp/csm_parity"
