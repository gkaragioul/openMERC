#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs whole-game scan: one contact sheet per cut scene from the scan's screenshots (/usr/bin/python3 for PIL), and
# a per-scene summary of anomaly lines from the console log. Deletes each screenshot once it is on a sheet.
# usage: film_sheets.py <index.json> <scrnshot dir> <console.log> <out dir> [tail]
import json, os, re, sys
from PIL import Image, ImageDraw

idx, shots, logf, out = sys.argv[1:5]
TAIL = len(sys.argv) > 5 and sys.argv[5] == 'tail'  # only the pictures past what an earlier pass covered
os.makedirs(out, exist_ok=True)
W, COLS = 240, 8
scenes = json.load(open(idx))
log = open(logf, encoding='latin-1').read().splitlines()
ANOM = re.compile(r"not available for|Botched idiocy|Invalid action code|Couldn't|ERROR|Error:|error|Failed fDot|script|No AI|"
                  r"no AI|not found|eek\.|WILL_KILL|bad |invalid|overflow|signal", re.I)
NOISE = re.compile(r'\[GPU\]|\[SLOW\]|\[MOUSE\]|^Wrote |conback|Ghoul :|execing|RLFILM|Sound|MUSIC|primary sound')
span = {}
cur = None
for ln in log:
    m = re.match(r'RLFILM (\S+) (\S+)', ln.strip())
    if m:
        cur = m.group(1) if m.group(2) != 'done' else None
        span.setdefault(m.group(1), [])
        continue
    if cur and ANOM.search(ln) and not NOISE.search(ln):
        span[cur].append(ln.strip()[:150])
report = []
for s in scenes:
    tag = s['tag']
    fs = [os.path.join(shots, f'{tag}_{k:02d}.tga') for k in range(s['shots'])]
    fs = [f for f in fs if os.path.exists(f)]
    tail = s.get('tail_from', 0) if TAIL else 0
    drop, fs = fs[:tail], fs[tail:]
    for f in drop:
        os.remove(f)
    report.append({'tag': tag, 'map': s['map'], 'script': s['script'], 'target': s['target'], 'auto': s['auto'],
                   'pictures': len(fs), 'reached': tag in span, 'lines': sorted(set(span.get(tag, [])))})
    if not fs:
        continue
    ims = []
    for k, f in enumerate(fs):
        im = Image.open(f).convert('RGB')
        h = int(im.height * W / im.width)
        t = im.resize((W, h))
        ImageDraw.Draw(t).text((3, 3), str(k + tail), fill=(255, 255, 0))
        ims.append(t)
    H = ims[0].height
    rows = (len(ims) + COLS - 1) // COLS
    sheet = Image.new('RGB', (COLS * W, 16 + rows * H), (0, 0, 0))
    ImageDraw.Draw(sheet).text((4, 2), f"{tag}  {s['script']}  target {s['target']}  auto {s['auto']}  waits {s['waits']}", fill=(0, 255, 0))
    for i, t in enumerate(ims):
        sheet.paste(t, ((i % COLS) * W, 16 + (i // COLS) * H))
    sheet.save(os.path.join(out, f'{tag}.jpg'), quality=78)
    for f in fs:
        os.remove(f)
json.dump(report, open(os.path.join(out, 'report.json'), 'w'), indent=1)
print(len(report), 'scenes;', sum(1 for r in report if not r['pictures']), 'without pictures;',
      sum(1 for r in report if r['lines']), 'with anomaly lines')
