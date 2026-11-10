#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs enemy reaction audit: one console script per single-player level, chained by the game's omaudit command when it
# finishes a level (game/src/ai/ai_audit.cpp). Run with tools/sweep/run-cfg.sh and sum up with audit_report.py.
# Cut scenes are skipped while the level loads, then played normally (with skipping left on, tsr2 fast-forwarded into its level
# end, runs 0275-0277); a cut scene that never ends is cleared by the audit after 15 s.
# usage: make_audit_cfgs.py <spots.json> <out dir> [map ...]   writes au_00.cfg ... and audit_all.cfg (concatenation head)
import json, os, sys

SPOTS, OUT = sys.argv[1:3]
only = set(sys.argv[3:])
maps = [m['map'] for m in json.load(open(SPOTS)) if not only or m['map'] in only]
os.makedirs(OUT, exist_ok=True)
HEAD = '''alias w10 "wait;wait;wait;wait;wait;wait;wait;wait;wait;wait"
alias w100 "w10;w10;w10;w10;w10;w10;w10;w10;w10;w10"
set cl_maxfps 100
set vid_vsync 0
'''
for n, m in enumerate(maps):
    nxt = f'exec au_{n + 1:02d}.cfg' if n + 1 < len(maps) else 'quit'
    open(os.path.join(OUT, f'au_{n:02d}.cfg'), 'w').write(
        f'// omaudit {m}\n{HEAD}killmenu\nw10\nset timescale 1\nset sv_jumpcinematic 1\nmap {m}\nw100;w100;w100;w100\n'
        f'set sv_jumpcinematic 0\nset timescale 3\nset om_audit_next "{nxt}"\nomaudit\n')
print(len(maps), 'levels')
