#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo/engine/src/client/refresh/metal/mtl_main.m" "$tmp/brush_matrix_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(re.search(r'(?ms)^static void\nMTL_EntityMatrix\(.*?^}',s).group())
PY
clang -std=c11 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$tmp" \
 "$repo/engine/src/client/refresh/metal/tests/brush_math.c" -o "$tmp/brush_math"
"$tmp/brush_math"
