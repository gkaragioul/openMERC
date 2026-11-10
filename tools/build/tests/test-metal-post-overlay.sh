#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-412 section11 native overlay verification.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
mode=${1:-after};tmp=${2:-$(mktemp -d)};mkdir -p "$tmp"
python3 - "$repo/engine/src/client/refresh/gl3/gl3_fx.c" "$tmp/post_overlay_reference.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text();parts=[]
for name in ('IRand','FRand','NightVisionTexture'):
 parts.append(re.search(r'(?ms)^static (?:int|float|void)\n'+name+r'\(.*?^}',s).group())
pathlib.Path(sys.argv[2]).write_text('\n'.join(parts))
PY
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable \
 -DPOST_IDENTITY_OLD=0 -DPOST_OVERLAY_OLD=$([ "$mode" = before ] && echo 1 || echo 0) \
 -fsanitize=address,undefined -I"$tmp" "$repo/engine/src/client/refresh/metal/tests/post_overlay.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/post_overlay"
"$tmp/post_overlay"
