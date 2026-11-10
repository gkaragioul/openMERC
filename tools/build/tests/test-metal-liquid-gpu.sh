#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
mode=${1:-after}
tmp=${2:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "${OM_LIQUID_BASELINE_SOURCE:-$repo/engine/src/client/refresh/metal/mtl_main.m}" "$tmp/liquid_old.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
shader=re.search(r'(?ms)^static NSString \*mtl_turb_shader = @R"MSL\(.*?\)MSL";',s).group()
pathlib.Path(sys.argv[2]).write_text(shader)
PY
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-variable \
 -DLIQUID_OLD=$([ "$mode" = before ] && echo 1 || echo 0) -I"$tmp" -I"$repo/engine/src/client/refresh/metal" \
 "$repo/engine/src/client/refresh/metal/tests/liquid_gpu.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/liquid_gpu"
"$tmp/liquid_gpu"
