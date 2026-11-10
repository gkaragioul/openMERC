#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-412 soft particles and SPEC-AMEND-016 verification.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
if [ "$#" -gt 0 ]; then tmp=$1; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable \
  -I"$repo/engine/src/client/refresh/metal" \
  "$repo/engine/src/client/refresh/metal/tests/post_soft.mm" \
  -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/post_soft"
"$tmp/post_soft"