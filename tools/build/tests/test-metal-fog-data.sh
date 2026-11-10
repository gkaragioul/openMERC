#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-410 read-only actual native fog-loader asset check.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -lt 2 ]; then echo 'usage: test-metal-fog-data.sh VERIFY_DIR USER_PAK [USER_PAK ...]' >&2; exit 2; fi
tmp=$1; shift;mkdir -p "$tmp"
clang -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined -fno-omit-frame-pointer \
 "$repo/engine/src/client/refresh/metal/tests/fog_bsp.c" -lm -o "$tmp/fog_bsp"
"$tmp/fog_bsp" "$@"
