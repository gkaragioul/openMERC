#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs enemy reaction audit: what each silent enemy's AI did in the last two seconds of its turn. game/src/ai/ai_audit.cpp
# switches ai_trace 2 on between "OMTRACE <map> ent=<n> on" and "OMTRACE <map> off"; this groups that enemy's trace lines.
# usage: audit_traces.py <console.log>
import collections, re, sys

lines = open(sys.argv[1], encoding='latin-1').read().splitlines()
cur, out = None, []
for ln in lines:
    i = ln.find('OMTRACE ')
    if i >= 0:
        p = ln[i:].split()
        if p[2].startswith('ent='):
            cur = dict(map=p[1], ent=p[2][4:], combat=[], plans=collections.Counter(), queued=collections.Counter(), blocked=0)
            out.append(cur)
        else:
            cur = None
        continue
    if not cur:
        continue
    m = re.search(r'ai %s(:| )(.*)' % cur['ent'], ln)
    if not m:
        continue
    t = m.group(2).strip()
    if t.startswith('combat:'):
        cur['combat'].append(t)
    elif t.startswith('plan kind'):
        cur['plans'][t.split(' prio')[0]] += 1
    elif t.startswith('queue class'):
        cur['queued'][' '.join(t.split()[:4])] += 1
    elif 'move blocked' in t:
        cur['blocked'] += 1
codes = collections.Counter()
for r in out:
    cs = [re.search(r'code (\d+)', c).group(1) for c in r['combat'] if re.search(r'code (\d+)', c)]
    key = ','.join(sorted(set(cs))) or '-'
    codes[key] += 1
    last = r['combat'][-1][:150] if r['combat'] else '-'
    print(f"{r['map']:6s} ent {r['ent']:4s} codes {key:6s} plans {dict(r['plans'])} queued {dict(r['queued'].most_common(2))} blocked {r['blocked']}\n        last: {last}")
print('silent enemies traced', len(out), 'by combat range code', dict(codes))
