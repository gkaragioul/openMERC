#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Exercise the harness with a fake engine; never launch the game.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/openmerc-parity-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/build/release/user" "$tmp/data/base" "$tmp/out" "$tmp/bin"
printf 'keep me\n' > "$tmp/build/release/user/important.txt"

cat > "$tmp/build/release/openMerc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if (($# + 1 > 50)); then
    printf 'fake engine: argc exceeds engine limit\n' >&2
    exit 1
fi
user=./user
shot=
renderer=
while (($#)); do
    if [[ $1 == -user ]]; then user=$2; shift 2
    elif [[ $1 == +set && ${2:-} == user ]]; then
        printf 'fake engine: user must be supplied with -user, not +set user\n' >&2
        exit 1
    elif [[ $1 == +set && ${2:-} == vid_renderer ]]; then renderer=$3; shift 3
    elif [[ $1 == +screenshot ]]; then shot=$2; shift 2
    else shift; fi
done
# The current Metal renderer writes to ./user regardless of the cvar.
if [[ $renderer == metal ]]; then user=./user; fi
mkdir -p "$user/scrnshot"
printf 'fake capture\n' > "$user/scrnshot/$shot.tga"
EOF
chmod +x "$tmp/build/release/openMerc"
cat > "$tmp/bin/magick" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/magick"

OM_BUILD_DIR="$tmp/build" OM_DATA_DIR="$tmp/data" OM_PARITY_DIR="$tmp/out" \
PATH="$tmp/bin:$PATH" "$repo/tools/build/capture-parity.sh" tsr1 30 >/dev/null

test -f "$tmp/build/release/user/important.txt" || {
    printf 'FAIL: capture removed the existing user directory\n' >&2
    exit 1
}
test -f "$tmp/out/parity_tsr1_gl3.tga"
test -f "$tmp/out/parity_tsr1_metal.tga"
printf 'keep capture\n' > "$tmp/out/parity_tsr1_gl3.tga"
if OM_BUILD_DIR="$tmp/build" OM_DATA_DIR="$tmp/data" OM_PARITY_DIR="$tmp/out" \
    PATH="$tmp/bin:$PATH" "$repo/tools/build/capture-parity.sh" tsr1 1 >/dev/null 2>&1; then
    printf 'FAIL: capture accepted existing evidence\n' >&2
    exit 1
fi
test "$(cat "$tmp/out/parity_tsr1_gl3.tga")" = 'keep capture'

if OM_BUILD_DIR="$tmp/build" OM_DATA_DIR="$tmp/data" OM_PARITY_DIR="$tmp/too-many-waits" \
    PATH="$tmp/bin:$PATH" "$repo/tools/build/capture-parity.sh" tsr1 52 >/dev/null 2>&1; then
    printf 'FAIL: capture accepted a packed wait argument over the engine 255-byte limit\n' >&2
    exit 1
fi
printf 'PASS: user data and existing captures survive; both renderers captured\n'
