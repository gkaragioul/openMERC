#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-002, SPEC-412 and SPEC-413 native framegraph verification.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
mode=${1:-after};tmp=${2:-$(mktemp -d)};mkdir -p "$tmp"
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable \
 -DPOST_IDENTITY_OLD=$([ "$mode" = before ] && echo 1 || echo 0) -fsanitize=address,undefined \
 "$repo/engine/src/client/refresh/metal/tests/post_identity.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/post_identity"
"$tmp/post_identity"
