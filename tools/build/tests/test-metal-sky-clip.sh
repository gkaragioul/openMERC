#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo/engine/src/client/refresh/metal/mtl_main.m" "$tmp/sky_clip_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text();out=[]
out.append(re.search(r'(?ms)^#define SKY_ON_EPSILON.*?^};\n\nstatic void\nMTL_DrawSkyPolygon',s).group().rsplit('static void',1)[0])
# Omit texture/image state: this harness owns only the clipping geometry.
out[0]=re.sub(r'^static mtl_image_t.*\n','',out[0],flags=re.M)
for name in ('MTL_DrawSkyPolygon','MTL_ClipSkyPolygon'):
 out.append(re.search(r'(?ms)^static void\n'+name+r'\(.*?^}',s).group())
pathlib.Path(sys.argv[2]).write_text('\n'.join(out))
PY
clang -std=c11 -O2 -Wall -Wextra -Wno-unused-variable -Werror -fsanitize=address,undefined -I"$tmp" "$repo/engine/src/client/refresh/metal/tests/sky_clip.c" -lm -o "$tmp/sky_clip"
"$tmp/sky_clip"
