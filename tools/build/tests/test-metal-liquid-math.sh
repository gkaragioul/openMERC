#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo" "$tmp/liquid_reference.h" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);base=r/'engine/src/client/refresh'
warp=(base/'gl3/gl3_warp.c').read_text()
warp=warp[warp.index('static void\nR_BoundPoly'):warp.index('/*\n * Breaks a polygon')]
liquid=(base/'gl3/gl3_liquid.c').read_text().split('#include "header/local.h"',1)[1]
main=(base/'metal/mtl_main.m').read_text()
matrix=re.search(r'(?ms)^static void\nMTL_EntityMatrix\(.*?^}',main).group()
adapter=(base/'metal/mtl_liquid.h').read_text()
matrix+='\n'+re.search(r'(?ms)^static void MTL_LiquidEntityMatrix\(.*?^}',adapter).group()
pathlib.Path(sys.argv[2]).write_text(warp+'\n'+liquid+'\n'+matrix)
PY
clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-function \
 -fsanitize=address,undefined -I"$tmp" \
 "$repo/engine/src/client/refresh/metal/tests/liquid_math.c" -o "$tmp/liquid_math"
"$tmp/liquid_math"
