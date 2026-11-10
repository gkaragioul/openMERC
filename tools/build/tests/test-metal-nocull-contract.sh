#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Require the native Metal world walk to honour the same r_nocull diagnostic
# control as the GL3 reference before using it to isolate a frustum issue.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$repo/engine/src/client/refresh/metal/mtl_main.m"

for required in \
  'r_nocull' \
  'mtl_nocull_cvar' \
  '!mtl_nocull_cvar->value'; do
	if ! grep -q "$required" "$source_file"; then
		printf 'FAIL: native Metal world nocull control is missing %s\n' "$required" >&2
		exit 1
	fi
done

printf '%s\n' 'PASS: native Metal world nocull diagnostic contract is present'
