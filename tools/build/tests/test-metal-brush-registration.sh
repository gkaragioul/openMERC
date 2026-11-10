#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
python3 - "${OM_BRUSH_MAIN:-$repo/engine/src/client/refresh/metal/mtl_main.m}" "$tmp/brush_registration_production.h" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
names=['MTL_TrackModelImage','MTL_FreeModel','MTL_RemoveModel','MTL_FreeModels','MTL_RegisterModel','MTL_BeginRegistration','MTL_EndRegistration']
text='static struct model_s *MTL_RegisterModel(const char *name);\n'
if re.search(r'^MTL_FreeModels\(',s,re.M):text+='#define OM_BRUSH_OWNERSHIP 1\n'
for name in names:
 m=re.search(r'(?ms)^static (?:void|struct model_s \*)\n'+name+r'\(.*?^}',s)
 if m:text+=m.group()+'\n'
pathlib.Path(sys.argv[2]).write_text(text)
PY
clang -std=c11 -Wall -Wextra -Wno-unused-function -Wno-unused-variable -Werror -fsanitize=address,undefined -I"$tmp" \
 "$repo/engine/src/client/refresh/metal/tests/brush_registration.c" -o "$tmp/brush_registration"
ASAN_OPTIONS=detect_leaks=0 "$tmp/brush_registration"
