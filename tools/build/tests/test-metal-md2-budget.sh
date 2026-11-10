#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Full generic GPU regressions plus actual draw parser/budget boundary cases.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
export OM_GENERIC_MODELS_SANITIZE=1
exec bash "$root/tools/build/tests/test-metal-generic-models.sh" "$@"
