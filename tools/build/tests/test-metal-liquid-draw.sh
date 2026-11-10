#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo/engine/src/client/refresh/metal/mtl_main.m" "$tmp/liquid_draw_types.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text();parts=[]
for struct,alias in [('mtl_image_s','mtl_image_t'),('mtl_surface_s','mtl_surface_t'),('mtl_model_s','mtl_model_t'),('mtl_world_vertex_s','mtl_world_vertex_t')]:
 parts.append(re.search(r'(?ms)^typedef struct '+struct+r'.*?^} '+alias+r';',s).group())
parts.append('#define MTL_WORLD_STRIDE sizeof(mtl_world_vertex_t)')
pathlib.Path(sys.argv[2]).write_text('\n'.join(parts))
PY
clang -x objective-c -std=gnu11 -O2 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-function \
 -Wno-unused-variable -fsanitize=address,undefined -I"$tmp" \
 -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' \
 "$repo/engine/src/client/refresh/metal/tests/liquid_draw.m" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/liquid_draw"
"$tmp/liquid_draw"
