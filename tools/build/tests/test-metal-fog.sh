#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-410 validated fog ownership and pure math verification.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "$repo/engine/src/client/refresh/gl3/gl3_fog.c" "$tmp/fog_reference_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text();parts=[]
for name in ['Params','ThicknessEye','Thickness','OverlayAlpha','GL3_Fog_PointFactor','GL3_Fog_RegionLinear']:
 parts.append(re.search(r'(?ms)^(?:static )?(?:void|float|qboolean)\n'+name+r'\(.*?^}',s).group())
pathlib.Path(sys.argv[2]).write_text('\n'.join(parts)+'\n')
PY
for suite in fog_math fog_regions fog_reference; do
 clang -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -fno-omit-frame-pointer \
  -DYQ2ARCH='"arm64"' -DYQ2OSTYPE='"Darwin"' -I"$tmp" \
  "$repo/engine/src/client/refresh/metal/tests/$suite.c" -lm -o "$tmp/$suite"
 "$tmp/$suite"
done
