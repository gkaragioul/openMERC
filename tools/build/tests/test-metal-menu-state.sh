#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
OM_MENU_TEST_SOURCE="$repo/engine/src/client/refresh/metal/tests/menu_state.mm" \
 bash "$repo/tools/build/tests/test-metal-menu-foundation.sh" "$@"
