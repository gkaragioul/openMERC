#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)}; mkdir -p "$tmp"
clang -std=c11 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined \
  "$repo/engine/src/client/refresh/metal/tests/lightmap_math.c" -o "$tmp/lightmap_math"
"$tmp/lightmap_math"