#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Execute production clock, creation/pop, draw and model update functions.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
python3 - "${OM_MENU_CLOCK_SOURCE:-$repo/engine/src/client/menu/menu.c}" \
    "${OM_MENU_MODEL_SOURCE:-$repo/engine/src/client/menu/m_model.c}" "$tmp/menu_clock_production.h" <<'PY'
import pathlib,re,sys
menu=pathlib.Path(sys.argv[1]).read_text();model=pathlib.Path(sys.argv[2]).read_text()
parts=[]
for name in ('M_ClockNow','M_Time','M_CreateSystem','M_PopTop','M_Draw'):
    m=re.search(r'(?ms)^(?:static )?\w[\w *]*\n'+name+r'\(.*?^}',menu)
    if m: parts.append(m.group())
parts.append(re.search(r'(?ms)^struct mmodel_s\n\{.*?^};',model).group())
for name in ('MM_Clock','MM_Update'):
    parts.append(re.search(r'(?ms)^static \w[\w *]*\n'+name+r'\(.*?^}',model).group())
pathlib.Path(sys.argv[3]).write_text('\n\n'.join(parts)+'\n')
PY
clang -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
    -fsanitize=address,undefined -fno-omit-frame-pointer -I"$tmp" \
    "$repo/engine/src/client/menu/tests/menu_clock.c" -lm -o "$tmp/menu_clock"
"$tmp/menu_clock"
