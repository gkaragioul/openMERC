#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo/engine/src/client/refresh/metal/mtl_main.m" "$tmp/menu_selector.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(re.search(r'(?ms)^static const float \*\nMTL_GhoulProjection\(.*?^}',s).group())
PY
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$tmp" \
 "$repo/engine/src/client/refresh/metal/tests/menu_projection.c" -lm -o "$tmp/menu_projection"
"$tmp/menu_projection"
