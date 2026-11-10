#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)};mkdir -p "$tmp"
python3 - "$repo" "$tmp" "${OM_MD2_NATIVE_SOURCE:-}" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2])
s=(r/'engine/src/client/refresh/files/models.c').read_text()
(p/'md2_loader_production.h').write_text(re.search(r'(?ms)^void \*\nMod_LoadMD2 .*?^}',s).group())
s=(r/'engine/src/client/refresh/metal/mtl_generic_models.h').read_text()
(p/'md2_parser_production.h').write_text(s[:s.index('static id<MTLRenderPipelineState>')])
s=(pathlib.Path(sys.argv[3]) if sys.argv[3] else r/'engine/src/client/refresh/metal/mtl_main.m').read_text()
(p/'md2_native_production.h').write_text(re.search(r'(?ms)^static mtl_model_t \*\nMTL_LoadAliasModel\(.*?^}',s).group())
PY
clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-sign-compare -Wno-unused-function \
 -DMD2_PREFLIGHT=1 -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' \
 -fsanitize=address,undefined -I"$tmp" "$repo/engine/src/client/refresh/metal/tests/md2_native_loader.c" -o "$tmp/md2_native_loader"
"$tmp/md2_native_loader"
