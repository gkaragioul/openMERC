#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Implements: SPEC-AMEND-016 optional overbright at the current GPL destinations.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=${1:-$(mktemp -d)};mkdir -p "$tmp"
python3 - "$repo" "$tmp" "${OM_OVERBRIGHT_NATIVE_HEADER:-}" <<'PY'
import pathlib,re,sys
r=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2])
# Reuse the existing exact factory extraction without running its executable.
script=(r/'tools/build/tests/test-metal-post-factories.sh').read_text()
block=script.split("<<'PY'\n",1)[1].split('\nPY\n',1)[0]
overbright_argv=sys.argv;sys.argv=['extract',str(r),str(p),''];exec(compile(block,'factory extractor','exec'));sys.argv=overbright_argv
fixture=(r/'engine/src/client/refresh/metal/tests/post_factories.mm').read_text().replace('int main(void)','int ExistingFactoriesMain(void)')
(p/'overbright_factories_fixture.h').write_text(fixture)
s=(r/'engine/src/client/refresh/metal/mtl_main.m').read_text();parts=[]
for name in ('MTL_AliasShadeLight','MTL_DrawGhoulEntity'):
 parts.append(re.search(r'(?ms)^static void\n'+name+r'\(.*?^}',s).group())
world=re.search(r'(?ms)^static void\nMTL_DrawSurface\(.*?^}',s).group()
assignment=re.search(r'\bu\.overbright\s*=([^;]+);',world).group(1)
parts.append('static float MTL_TestWorldFactor(void) { return '+assignment+'; }')
generic=(r/'engine/src/client/refresh/metal/mtl_generic_models.h').read_text()
alpha=re.search(r'cur->color\[3\]\s*=([^;]+);',generic).group(1)
parts.append('static float MTL_TestAliasAlpha(float alpha) { return '+alpha+'; }')
(p/'overbright_production.h').write_text(pathlib.Path(sys.argv[3]).read_text() if len(sys.argv)>3 and sys.argv[3] else '\n'.join(parts))
gl=(r/'engine/src/client/refresh/gl3/gl3_post.c').read_text()
(p/'overbright_reference.h').write_text('\n'.join(re.search(r'(?ms)^float\n'+name+r'\(.*?^}',gl).group() for name in ('GL3_Post_Overbright','GL3_Post_OverbrightModels')))
shared=(r/'engine/src/common/header/shared.h').read_text()
(p/'overbright_flags.h').write_text('\n'.join(re.findall(r'^#define (?:RF_|RDF_)[^\n]+',shared,re.M)))
PY
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Wno-unused-function -Wno-unused-variable -Wno-format -Wno-missing-field-initializers -Wno-missing-braces \
 -fsanitize=address,undefined -fno-omit-frame-pointer \
 -I"$tmp" -I"$repo/engine/src/client/refresh/metal/tests" -I"$repo/engine/src/ghoul" -I"$repo/engine/src/client/refresh/metal" \
 "$repo/engine/src/client/refresh/metal/tests/overbright.mm" \
 -framework Foundation -framework Metal -framework QuartzCore -o "$tmp/overbright"
"$tmp/overbright"
