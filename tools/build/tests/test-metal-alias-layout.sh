#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Verifies the CPU vertex layout consumed directly by AliasVSIn in Metal.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$repo/engine/src/client/refresh/metal/mtl_main.m"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# This extracts the real production declaration rather than copying it into a
# fixture.  A packed float3/float2/float4 layout is unsafe for Metal's direct
# device-struct reads: float3 is 16-byte aligned in the shader ABI.
awk '
  /typedef struct mtl_alias_vertex_s/ { capture = 1 }
  capture { print }
  capture && /} mtl_alias_vertex_t;/ { exit }
' "$source_file" > "$tmp/alias_vertex.h"

if ! grep -q 'mtl_alias_vertex_t' "$tmp/alias_vertex.h"; then
	printf '%s\n' "FAIL: could not extract the production alias vertex declaration" >&2
	exit 1
fi

cat > "$tmp/layout.c" <<'EOF'
#include <stddef.h>
#include <stdio.h>
#include "alias_vertex.h"

int main(void)
{
	printf("%zu %zu %zu %zu\n", offsetof(mtl_alias_vertex_t, pos),
	       offsetof(mtl_alias_vertex_t, uv), offsetof(mtl_alias_vertex_t, color),
	       sizeof(mtl_alias_vertex_t));
	return 0;
}
EOF

cc -std=c11 -Wall -Wextra -Werror "$tmp/layout.c" -o "$tmp/layout"
actual=$("$tmp/layout")
expected="0 16 32 48"

if [[ "$actual" != "$expected" ]]; then
	printf 'FAIL: AliasVSIn needs CPU offsets/stride "%s"; got "%s"\n' "$expected" "$actual" >&2
	exit 1
fi

printf '%s\n' 'PASS: alias CPU vertex layout matches Metal float3/float2/float4 ABI'
