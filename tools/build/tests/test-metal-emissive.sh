#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ];then tmp=$1;mkdir -p "$tmp";else tmp=$(mktemp -d);trap 'rm -rf "$tmp"' EXIT;fi
source=${OM_POST_BASELINE_SOURCE:-$repo/engine/src/client/refresh/metal/mtl_main.m}
python3 - "$source" "$tmp/post_alias_before.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text();fragment=re.search(r'(?ms)^static NSString \*const mtl_alias_shader = @R"MSL\(.*?\)MSL";',s).group()
pathlib.Path(sys.argv[2]).write_text(fragment.replace('mtl_alias_shader','post_alias_before',1)+'\n')
PY
old=${OM_POST_OLD:-0}
if [ ! -f "$repo/engine/src/client/refresh/metal/mtl_post_shaders.h" ];then old=1;fi
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-parameter \
 -fsanitize=address,undefined -fno-omit-frame-pointer -DOM_POST_OLD="$old" \
 -I"$tmp" -I"$repo/engine/src/client/refresh/metal" \
 "$repo/engine/src/client/refresh/metal/tests/post_emission.mm" \
 -framework Foundation -framework Metal -o "$tmp/post_emission"
"$tmp/post_emission"
