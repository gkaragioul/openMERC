#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs level sweep: per-map facts from one run's console.log (RLSWEEP markers from make_cfgs.py).
# Per map: reached / content marker (the map's own file name in its section, knowledge entry "Load tests: prove the
# intended content loaded") / spots shot / camera where asked (viewpos vs omsetpos) / error-like lines / GPU ms.
# usage: parse_log.py <spots.json> <console.log> <out.json>
import json, re, sys

spots = {m['map']: m for m in json.load(open(sys.argv[1]))}
text = open(sys.argv[2], encoding='latin-1').read().splitlines()
ERR = re.compile(r'ERROR|Error|error|fatal|Fatal|Couldn\'t|couldn\'t|failed|Failed|can\'t|not found|missing|'
                 r'overflow|WARNING|Warning|signal|assert|could not|cannot|unable|bad |invalid', re.I)
NOISE = re.compile(r'conback|primary sound format|Error during loading chunk 0|r_metal_gputime|cl_slowframe')
res, cur, spot = {}, None, None
for ln in text:
    m = re.match(r'RLSWEEP (\S+) (\S+)(.*)', ln.strip())
    if m:
        name, what = m.group(1), m.group(2)
        if name == 'all':
            res['_all_done'] = True
            continue
        if what == 'load':
            cur = res.setdefault(name, {'map': name, 'in': False, 'done': False, 'marker': False, 'shots': [],
                                        'viewpos': {}, 'errors': [], 'gpu': [], 'slow': 0, 'lines': 0})
        elif what == 'in':
            cur['in'] = True
        elif what == 'done':
            cur['done'] = True
        elif what.startswith('S'):
            spot = what
        continue
    if cur is None:
        continue
    cur['lines'] += 1
    if f"maps/{cur['map']}." in ln.lower() or ln.strip().lower() == cur['map']:
        cur['marker'] = True
    w = re.search(r'Wrote .*/(\w+)_(\w+)_(S\d)\.tga', ln)
    if w:
        cur['shots'].append(w.group(3))
    v = re.match(r'position: ([-\d]+) ([-\d]+) ([-\d]+), angles: ([-\d]+) ([-\d]+)', ln.strip())
    if v and spot:
        cur['viewpos'][spot] = [float(v.group(i)) for i in (1, 2, 3, 5)]
        continue
    g = re.match(r'\[GPU\] \d+ frames \S+: avg ([\d.]+) ms, max ([\d.]+) ms', ln)
    if g:
        cur['gpu'].append((float(g.group(1)), float(g.group(2))))
        continue
    if ln.startswith('[SLOW]'):
        cur['slow'] += 1
        continue
    if ERR.search(ln) and not NOISE.search(ln):
        cur['errors'].append(ln.strip()[:200])
for name, r in res.items():
    if name.startswith('_'):
        continue
    want = {s['id']: s for s in spots[name]['spots']}
    r['camera_off'] = []
    for sid, s in want.items():
        vp = r['viewpos'].get(sid)
        if vp and not s.get('natural') and 'x' in s and (abs(vp[0] - s['x']) > 24 or abs(vp[1] - s['y']) > 24):
            r['camera_off'].append(sid)
    r['spots_wanted'] = len(want)
    r['gpu_avg'] = round(sum(a for a, _ in r['gpu']) / len(r['gpu']), 2) if r['gpu'] else None
    r['gpu_max'] = max((b for _, b in r['gpu']), default=None)
json.dump(res, open(sys.argv[3], 'w'), indent=1)
for name in spots:
    r = res.get(name)
    if not r:
        print(f'{name:6} NOT REACHED')
        continue
    print(f"{name:6} in={int(r['in'])} done={int(r['done'])} marker={int(r['marker'])} shots {len(r['shots'])}/"
          f"{r['spots_wanted']} cam_off {','.join(r['camera_off']) or '-'} gpu {r['gpu_avg']}/{r['gpu_max']} "
          f"slow {r['slow']} errors {len(r['errors'])}")
print('all done' if res.get('_all_done') else 'NOT all done')
