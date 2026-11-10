#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
	"$repo/engine/src/client/refresh/metal/tests/fx_geometry.c" -lm -o "$tmp/fx_geometry"
"$tmp/fx_geometry"
