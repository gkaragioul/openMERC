#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo/engine/src/client/refresh/metal/mtl_worldalpha.h" "$tmp/alpha_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(re.search(r'(?ms)^static void MTL_FillAlphaVertices\(.*?^}',s).group())
PY
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$tmp" \
 "$repo/engine/src/client/refresh/metal/tests/alpha_light_queries.c" -o "$tmp/alpha_light_queries"
"$tmp/alpha_light_queries"
