#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs whole-game scan: every character class a level uses, spawned once in that level (each level has its own model
# set, so a class is only complete in the levels that use it), one picture each, at the level's most open test spot.
# usage: make_levelgallery.py <audit dir: x/maps> <spots.json> <out.cfg> <next cfg>
import json, re, struct, sys
A, SPOTS, OUT, NEXT = sys.argv[1:5]
SKIP = ('chopper', 'hind', 'tank', 'snowcat')
def ents(m):
    b = open(f'{A}/x/maps/{m}.bsp', 'rb').read(); o, l = struct.unpack_from('<ii', b, 8); t = b[o:o + l].decode('latin-1')
    return [dict(re.findall(r'"([^"]*)"\s+"([^"]*)"', x.group(1))) for x in re.finditer(r'\{(.*?)\}', t, re.S)]
L = ['// RLabs per-level character gallery', 'alias w10 "wait;wait;wait;wait;wait;wait;wait;wait;wait;wait"',
     'alias w100 "w10;w10;w10;w10;w10;w10;w10;w10;w10;w10"', 'set cl_maxfps 100', 'set vid_vsync 0']
idx = []
for m in json.load(open(SPOTS)):
    name = m['map']
    cl = sorted({e['classname'] for e in ents(name) if e.get('classname', '').startswith('m_') and not any(s in e['classname'] for s in SKIP)})
    if not cl:
        continue
    sp = max(m['spots'], key=lambda s: s.get('open', 0))
    L += ['killmenu', f'echo RLGAL {name} load', 'set sv_jumpcinematic 1', f'map {name}', 'w100;w100;w100;w100', 'set sv_jumpcinematic 0', 'omfire nothing_here', 'ninja', 'w10']
    for c in cl:
        tag = f'{name}__{c}'
        L += ['omclear', 'w10', f"omsetpos {sp['x']} {sp['y']} {sp['z']} {sp['yaw']} 18", 'w10', f'gimme {c}', 'w100;w100', f'screenshot lg_{tag}']
        idx.append(tag)
L += ['echo RLGAL done', 'killmenu', f'exec {NEXT}']
open(OUT, 'w').write('\n'.join(L) + '\n')
print(len(idx), 'pictures')
