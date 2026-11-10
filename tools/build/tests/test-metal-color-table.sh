#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo/engine/src/client/refresh/metal/mtl_main.m" "$tmp/color_table_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text();parts=[]
for name in ('MTL_SoF_BuildColorTable','MTL_SoF_SetColorCorrection'):
 parts.append(re.search(r'(?ms)^static void\n'+name+r'\(.*?^}',s).group())
pathlib.Path(sys.argv[2]).write_text('\n'.join(parts))
PY
clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-function -Werror -fsanitize=address,undefined -I"$tmp" "$repo/engine/src/client/refresh/metal/tests/color_table.m" -framework Foundation -framework Metal -o "$tmp/color_table"
"$tmp/color_table"
