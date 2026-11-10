#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Exercise the production native light-point function with deterministic BSP hits.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}
mkdir -p "$tmp"
python3 - "${OM_LIGHTPOINT_MAIN:-$repo/engine/src/client/refresh/metal/mtl_main.m}" "$tmp/lightpoint_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
fn=re.search(r'(?ms)^static void\nMTL_SoFLightPointDir\(.*?^}',s).group()
cache=re.search(r'(?ms)^/\* Light-point static cache.*?(?=^static void\nMTL_SoFLightPointDir)',s)
pathlib.Path(sys.argv[2]).write_text((cache.group() if cache else 'static void MTL_ClearLightCache(void) {}\n')+fn)
PY
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I"$tmp" \
  "$repo/engine/src/client/refresh/metal/tests/lightpoint_cache.c" -lm -o "$tmp/lightpoint_cache"
"$tmp/lightpoint_cache"
