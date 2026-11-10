#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-410 actual fog queue/pass and native shader verification.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)};mkdir -p "$tmp"
clang -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -fno-omit-frame-pointer \
 "$repo/engine/src/client/refresh/metal/tests/fog_draw.c" -lm -o "$tmp/fog_draw"
"$tmp/fog_draw"
clang++ -std=c++17 -fobjc-arc -O1 -g -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable -fsanitize=address,undefined -fno-omit-frame-pointer \
 "$repo/engine/src/client/refresh/metal/tests/fog_draw.mm" -framework Foundation -framework Metal -o "$tmp/fog_draw_gpu"
"$tmp/fog_draw_gpu"
