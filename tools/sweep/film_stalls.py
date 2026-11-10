#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs whole-game scan: triage of the cut-scene contact sheets from film_sheets.py (/usr/bin/python3 for PIL). A held scene that
# stops moving shows as a long run of near-identical pictures with no HUD, as the sud3 Dekker scene did (runs 0227, 0228). It lists
# the longest such run of each scene; long talking shots also appear, so a listed scene is looked at, not called broken.
# usage: film_stalls.py <index.json> <sheet dir> [min run, default 6]
import json, os, sys
from PIL import Image, ImageChops, ImageStat

idx, sheets = sys.argv[1:3]
MIN = int(sys.argv[3]) if len(sys.argv) > 3 else 6
W, COLS, TOP = 240, 8, 16
out = []
for s in json.load(open(idx)):
    p = os.path.join(sheets, s['tag'] + '.jpg')
    if not os.path.exists(p):
        out.append((999, s['tag'], s['script'], 'no sheet'))
        continue
    im = Image.open(p).convert('RGB')
    n = s['shots'] - (s.get('tail_from', 0) if False else 0)
    rows = (n + COLS - 1) // COLS
    H = (im.height - TOP) // rows
    last, run, best, at, hud_frames = None, 0, 0, 0, 0
    for i in range(n):
        x, y = (i % COLS) * W, TOP + (i // COLS) * H
        t = im.crop((x, y, x + W, y + H))
        bar = ImageStat.Stat(t.crop((105, H - 9, 135, H - 5))).mean
        hud = bar[0] - bar[1] > 40
        hud_frames += hud
        g = t.convert('L').crop((0, 14, W, H - 20))
        bright = ImageStat.Stat(g).mean[0]
        if last is not None and not hud and bright > 5 and ImageStat.Stat(ImageChops.difference(g, last)).mean[0] < 0.6:
            run += 1
            if run > best:
                best, at = run, i
        else:
            run = 0
        last = g
    out.append((best, s['tag'], s['script'], f'ends at picture {at} of {n}, {hud_frames} with HUD'))
out.sort(reverse=True)
for r in out:
    if r[0] >= MIN:
        print(*r)
print(len(out), 'scenes;', sum(1 for r in out if r[0] >= MIN), f'with {MIN} or more still pictures in a row')
