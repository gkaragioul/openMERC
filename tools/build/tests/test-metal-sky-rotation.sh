#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo" "$tmp" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2])
s=(r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
helper=re.search(r'(?ms)^static void\nMTL_SkyPosition\(.*?^}',s)
draw=re.search(r'(?ms)^static void\nMTL_DrawSkyBox\(.*?^}',s).group()
if helper:
 assert 'MTL_SkyPosition(pos[j], mtl_refdef.vieworg, mtl_skyrotate, mtl_skyaxis, MTL_GameTime(), q[k].pos)' in draw
 body=helper.group()
else:
 # Exercise actual old production vertex placement, not a missing-symbol failure.
 assignments=re.findall(r'q\[k\]\.pos\[\d\] = [^;]+;',draw)
 assert len(assignments)==3
 assignments='\n'.join(assignments).replace('q[k].pos','out').replace('mtl_refdef.vieworg','eye').replace('pos[j]','src')
 body='static void MTL_SkyPosition(const float src[3],const float eye[3],float rotate,const float axis[3],float time,float out[3]) { (void)rotate;(void)axis;(void)time;\n'+assignments+'\n}'
(p/'sky_rotation_production.h').write_text(body+'\n')
PY
if [ -n "${OM_SKY_ROTATION_PRODUCTION:-}" ]; then cp "$OM_SKY_ROTATION_PRODUCTION" "$tmp/sky_rotation_production.h"; fi
clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-missing-braces -Wno-unused-function \
 -fsanitize=address,undefined -I"$tmp" -I"$repo/engine/src/client/refresh/gl3/header" \
 "$repo/engine/src/client/refresh/metal/tests/sky_rotation.c" -lm -o "$tmp/sky_rotation"
"$tmp/sky_rotation"
