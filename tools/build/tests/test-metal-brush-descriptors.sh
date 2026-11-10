#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
pak=${OM_BRUSH_PAK:-$repo/game-data/sof/base/pak0.pak}
if [ ! -f "$pak" ]; then echo 'SKIP: set OM_BRUSH_PAK to the read-only game pak0.pak';exit 0;fi
python3 - "$repo" "$tmp" "$pak" <<'PY'
import pathlib,re,struct,sys
r=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);pak=pathlib.Path(sys.argv[3])
with pak.open('rb') as f:
 magic,o,n=struct.unpack('<4sII',f.read(12));assert magic==b'PACK';f.seek(o);entries={}
 for _ in range(n//64):
  name,offset,length=struct.unpack('<56sII',f.read(64));entries[name.split(b'\0')[0].decode('latin1')]=(offset,length)
 o,n=entries['maps/tsr1.bsp'];f.seek(o);b=f.read(n)
assert struct.unpack_from('<4sI',b)==(b'IBSP',46)
lumps=[struct.unpack_from('<II',b,8+i*8) for i in range(22)]
assert lumps[6][1]%44==0 and lumps[4][1]%28==0 and lumps[8][1]%32==0 and lumps[13][1]%48==0
o,n=lumps[13];rows=[]
for i in range(n//48):
 head,first,count=struct.unpack_from('<3i',b,o+i*48+36);rows.append('{'+','.join(map(str,[i,head,first,count]))+'}')
(out/'brush_descriptor_records.h').write_text('static const int records[][4]={'+','.join(rows)+'};\nstatic const int face_count='+str(lumps[6][1]//44)+',node_count='+str(lumps[4][1]//28)+',leaf_count='+str(lumps[8][1]//32)+';\n')
s=(r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
cond=re.search(r'(?ms)if \(([^;]*?)\)\n\t\t\{\n\t\t\tri.FS_FreeFile\(buf\);\n\t\t\tCom_Error\(ERR_DROP, "ref_metal: invalid inline descriptor',s).group(1)
# Keep the exact production predicate, with a single supplied descriptor at dmodels[0].
cond=cond.replace('dmodels[i]','dmodels[0]')
(out/'brush_descriptors_production.h').write_text('static int MTL_TestDescriptor(const dmodel_t *dmodels,int i,int totalfaces,int totalnodes,int totalleafs){(void)i;(void)totalleafs;return !('+cond+');}\n')
PY
clang -std=gnu11 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$tmp" \
 -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' "$repo/engine/src/client/refresh/metal/tests/brush_descriptors.c" -lm -o "$tmp/brush_descriptors"
"$tmp/brush_descriptors"
