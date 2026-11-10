#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-002 native renderer language compatibility.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
clang -std=gnu11 -fobjc-arc -fsyntax-only -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable \
 "$repo/engine/src/client/refresh/metal/tests/post_header_c.m"
echo 'PASS: post resources/overlay headers compile in production GNU Objective-C11 dialect'
