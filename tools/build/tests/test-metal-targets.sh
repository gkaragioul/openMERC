#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Production attachment tracking/readback with distinct offscreen MRT colors.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1;mkdir -p "$tmp";else tmp=$(mktemp -d);trap 'rm -rf "$tmp"' EXIT;fi
if [ -n "${OM_MENU_READBACK_HEADER:-}" ];then cp "$OM_MENU_READBACK_HEADER" "$tmp/mtl_readback.h";fi
python3 - "$repo/engine/src/client/refresh/metal/mtl_sofhud.h" "$tmp/readback_clip_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
out='static int mtl_hud_clip_targetw,mtl_hud_clip_targeth;\nstatic BOOL mtl_hud_clipenabled;\nstatic double mtl_hud_scissor[4];\n'
out+=re.search(r'(?ms)^static void\nMTL_HUDApplyClip\(.*?^}',s).group()+'\n'
pathlib.Path(sys.argv[2]).write_text(out)
PY
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable \
 -fsanitize=address,undefined -fno-omit-frame-pointer \
 -I"$tmp" -I"$repo/engine/src/client/refresh/metal" \
 "$repo/engine/src/client/refresh/metal/tests/post_targets.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/post_targets"
"$tmp/post_targets"
