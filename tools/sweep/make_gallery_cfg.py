#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs whole-game scan: one screenshot of every character class standing on a flat floor (arm1), from the front and
# looking slightly down so the feet and the ground shadow are in view.
# usage: make_gallery_cfg.py <repo> <out.cfg>
import re, sys
repo, out = sys.argv[1:3]
SKIP = ('chopper', 'hind', 'tank', 'snowcat')
names = sorted(set(re.findall(r'"(m_[a-zA-Z0-9_]+)"', open(repo + '/game/src/g_classlist.inc').read())))
names = [n for n in names if not any(s in n for s in SKIP)]
L = ['// RLabs character gallery', 'alias w10 "wait;wait;wait;wait;wait;wait;wait;wait;wait;wait"',
     'alias w100 "w10;w10;w10;w10;w10;w10;w10;w10;w10;w10"', 'set cl_maxfps 100', 'set vid_vsync 0',
     'set sv_jumpcinematic 1', 'map arm1', 'w100;w100;w100;w100', 'omfire nothing_here', 'ninja', 'w10']
for n in names:
    L += ['omclear', 'w10', 'omsetpos 72 24 40 90 18', 'w10', f'echo RLGAL {n}', f'gimme {n}', 'w100;w100', f'screenshot gal_{n}']
L += ['echo RLGAL done', 'w100', 'quit']
open(out, 'w').write('\n'.join(L) + '\n')
print(len(names), 'classes')
