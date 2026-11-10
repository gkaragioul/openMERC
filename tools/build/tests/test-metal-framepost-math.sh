#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-413 native depth/inverse verification.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)};mkdir -p "$tmp"
clang -std=c11 -O2 -Wall -Wextra -Werror -fsanitize=address,undefined \
 "$repo/engine/src/client/refresh/metal/tests/framepost_math.c" -o "$tmp/framepost_math"
"$tmp/framepost_math"
