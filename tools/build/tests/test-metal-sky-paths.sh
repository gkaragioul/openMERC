#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
pak=${OM_SKY_PAK:-$repo/game-data/sof/base/pak0.pak}
if [ ! -f "$pak" ]; then echo "SKIP: sky asset path check requires OM_SKY_PAK pointing to the user's pak0.pak"; exit 0; fi
python3 - "$repo" "$tmp" "$pak" <<'PY'
import pathlib,re,struct,json,sys
r=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2]);pak=pathlib.Path(sys.argv[3])
with pak.open('rb') as f:
 ident,offset,size=struct.unpack('<4sII',f.read(12));assert ident==b'PACK';f.seek(offset);entries={}
 for _ in range(size//64):
  n,pos,length=struct.unpack('<56sII',f.read(64));entries[n.split(b'\0')[0].decode('latin1')]=(pos,length)
 offset,size=entries['pics/sky/bos.txt'];f.seek(offset);text=f.read(size).decode('latin1')
 names=['textures/sky/bos_side2.m32','textures/sky/bos_side1.m32','textures/sky/bos_up.m32']
 for n in names:assert n in entries
 # The false PIC prefixes are absent in this same actual asset directory.
 for n in names:
  assert 'pics/'+n not in entries and 'pics/console/'+n not in entries and 'pics/misc/'+n not in entries
(p/'sky_asset_names.h').write_text('static const char *actual_sky_text='+json.dumps(text)+';\nstatic const char *actual_sky_names[3]={'+','.join(json.dumps(n) for n in names)+'};\n')
s=(r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
helper=re.search(r'(?ms)^static void\nMTL_FreeSkyImages\(.*?^}',s)
(p/'sky_set_production.h').write_text((helper.group()+'\n' if helper else '')+re.search(r'(?ms)^void\nMTL_SoF_SetSky\(.*?^}',s).group()+'\n')
s=(r/'engine/src/client/refresh/files/stb.c').read_text()
(p/'sky_pic_production.h').write_text(re.search(r'(?ms)^struct image_s \*\nR_FindPic\(.*?^}',s).group()+'\n')
PY
if [ -n "${OM_SKY_FUNCTION:-}" ]; then cp "$OM_SKY_FUNCTION" "$tmp/sky_set_production.h"; fi
clang -std=c11 -O2 -Wall -Wextra -Wno-unused-function -Werror -fsanitize=address,undefined -I"$tmp" \
 "$repo/engine/src/client/refresh/metal/tests/sky_paths.c" -o "$tmp/sky_paths"
"$tmp/sky_paths"
