#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# A native SoF frame must retain its separate model-animation clock.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
source="$repo/engine/src/client/refresh/metal/mtl_main.m"
python3 - "$source" <<'PY'
import pathlib, re, sys
s = pathlib.Path(sys.argv[1]).read_text()
assert 'exports.RenderFrame = MTL_SoF_RenderFrame;' in s, 'native SoF frame adapter absent'
assert 'params.time = MTL_GameTime();' in s, 'Ghoul still uses the client clock'
assert re.search(r'return\s+mtl_sof_frame\s*\?\s*mtl_sof_frame->gametime\s*:\s*mtl_refdef.time', s), 'game clock is not retained'
assert 'mtl_sof_frame = fd;' in s and 'mtl_sof_frame = NULL;' in s, 'SoF frame lifetime is not bounded'
print('PASS: native SoF frame retains its game clock for Ghoul')
PY
