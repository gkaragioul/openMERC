#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-AMEND-016 native bloom before/after numeric oracle.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
mode=${1:-after};tmp=${2:-$(mktemp -d)};mkdir -p "$tmp"
case "$mode" in before|after) ;; *) echo "usage: $0 [before|after] [VERIFY directory]" >&2;exit 2;; esac
if [ "$mode" = before ]; then
 cp "$repo/engine/src/client/refresh/metal/mtl_post.h" "$tmp/retained-mtl_post.h"
 python3 - "$tmp/retained-mtl_post.h" "$tmp/post_bloom_baseline.h" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
shader=text.split('static NSString *const mtl_framepost_shader=@R"MSL(',1)[1].split(')MSL";',1)[0]
pathlib.Path(sys.argv[2]).write_text('static NSString *const post_bloom_baseline_shader=@R"MSL('+shader+')MSL";\n')
PY
fi
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable \
 -DPOST_BLOOM_OLD=$([ "$mode" = before ] && echo 1 || echo 0) -I"$tmp" -fsanitize=address,undefined \
 "$repo/engine/src/client/refresh/metal/tests/post_bloom.mm" \
 -framework Foundation -framework Metal -o "$tmp/post_bloom"
"$tmp/post_bloom"
