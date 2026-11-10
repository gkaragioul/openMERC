#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo" "$tmp/world_labels_production.h" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);s=(r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
a=(r/'engine/src/common/shared/shared.c').read_text()
out=re.search(r'(?ms)^void\nAngleVectors\(.*?^}',a).group()+'\n'
if re.search(r'exports.DrawWorldLabel\s*=\s*MTL_HUDWorldLabel',s):
 out+=(r/'engine/src/client/refresh/metal/mtl_labels.h').read_text()
else:
 # Actual old API is nil; HUD_DrawLabels skips the complete operation.
 out+='static void MTL_HUDWorldLabel(float *o,char *t,char *p,unsigned c){(void)o;(void)t;(void)p;(void)c;}\n'
pathlib.Path(sys.argv[2]).write_text(out)
PY
clang -std=gnu11 -O2 -Wall -Wextra -Wno-unused-function -Werror -fsanitize=address,undefined -I"$tmp" \
 -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' "$repo/engine/src/client/refresh/metal/tests/world_labels.c" -lm -o "$tmp/world_labels"
"$tmp/world_labels"
