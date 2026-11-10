#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Metal must retain the GL3 two-cluster PVS union around water boundaries.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$root/engine/src/client/refresh/metal/mtl_main.m"

for required in 'viewcluster2' 'fatvis' 'Mod_PointInLeaf(probe, mod->nodes)' 'viewleaf->contents' 'vis[i] |= secondary_vis[i]'; do
	if ! grep -Fq "$required" "$source_file"; then
		echo "FAIL: native Metal water-boundary PVS union is missing $required" >&2
		exit 1
	fi
done

echo "PASS: native Metal preserves the two-cluster water-boundary PVS union"
