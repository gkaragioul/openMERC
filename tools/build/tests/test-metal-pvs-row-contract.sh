#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# A PVS row is indexed by clusters, not by BSP leaves.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
source_file="$root/engine/src/client/refresh/metal/mtl_main.m"

if ! grep -Fq 'const int numclusters = mod->vis ? LittleLong(mod->vis->numclusters) : 0;' "$source_file" ||
   ! grep -Fq 'const int visrow = (numclusters + 7) / 8;' "$source_file"; then
	echo "FAIL: native Metal PVS row is not sized from numclusters" >&2
	exit 1
fi

if ! grep -Fq 'Mod_DecompressVis((const byte *)mod->vis + offset, visrow)' "$source_file"; then
	echo "FAIL: native Metal does not decompress PVS using the cluster row length" >&2
	exit 1
fi

echo "PASS: native Metal sizes PVS rows from the cluster count"
