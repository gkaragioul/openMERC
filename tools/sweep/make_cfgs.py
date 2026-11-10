#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs level sweep (2026-11-08): one cfg per map, each ending with the next one's exec (the commands after `map`
# are held back until the client has entered the level, Cbuf_CopyToDefer / sv_user.c Cbuf_InsertFromDefer).
# No semicolons in cfg comments: the command buffer splits lines at them.
# usage: make_cfgs.py <spots.json> <out dir> <prefix>
import json, os, sys

spots, out, prefix = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
head = [
    'alias w10 "wait;wait;wait;wait;wait;wait;wait;wait;wait;wait"',
    'alias w50 "w10;w10;w10;w10;w10"',
    'alias w100 "w10;w10;w10;w10;w10;w10;w10;w10;w10;w10"',
]
for i, m in enumerate(spots):
    name = m['map']
    L = [f'// RLabs level sweep {i + 1}/{len(spots)}: {name}'] + (head if i == 0 else [])
    # the intro skip turns itself off once a skipped intro ends (sv_main.c, g_main.cpp level exit): set it per map
    L += [f'echo RLSWEEP {name} load', 'set sv_jumpcinematic 1', f'map {name}',
          'w100', 'w100', 'w100',
          f'echo RLSWEEP {name} in', 'heretic', 'ninja',
          # GPU time at the start view with the region fog as a player has it, then fog off for the comparison
          'set gl_fogmode 0', 'w100', 'w100', 'w100',
          'set gl_fogmode 2', 'w100']
    for s in m['spots']:
        sid = s['id']
        if not s.get('natural'):
            L += [f"omsetpos {s['x']} {s['y']} {s['z']} {s['yaw']} 0", 'w100', 'w50']
        L += [f'echo RLSWEEP {name} {sid} {s["kind"]} {s["ent"]}', 'viewpos', 'w50',
              f'screenshot {prefix}_{name}_{sid}', 'w10']
    L += [f'echo RLSWEEP {name} done']
    L += [f'exec sw_{i + 1:02d}.cfg'] if i + 1 < len(spots) else ['echo RLSWEEP all done', 'w100', 'quit']
    with open(os.path.join(out, f'sw_{i:02d}.cfg'), 'w') as f:
        f.write('\n'.join(L) + '\n')
print(f'{len(spots)} cfgs, {sum(len(m["spots"]) for m in spots)} spots')
