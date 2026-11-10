#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-410 actual production world boundary/sky classification.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
OM_WORLD_FOG_TEST=1 bash "$repo/tools/build/tests/test-metal-world-materials.sh" "$@"
