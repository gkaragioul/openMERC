#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs: tsr1 train ride summary. usage: ride_stats.py <console log or .gz>  -- what the three tsr1 train skinheads did after "RLEND on train"
import collections, gzip, re, sys
f = sys.argv[1]
L = (gzip.open(f, 'rt', encoding='latin-1') if f.endswith('.gz') else open(f, encoding='latin-1')).read().splitlines()
ents = {}
for l in L:
    m = re.search(r'ai (\d+): wakes at .* (rtskinhead\d)', l)
    if m: ents[m.group(1)] = m.group(2)
i0 = next(i for i, l in enumerate(L) if 'RLEND on train' in l)
for e, name in sorted(ents.items(), key=lambda x: x[1]):
    q = collections.Counter(); runs = fails = 0
    for l in L[i0:]:
        m = re.search(r'ai %s: queue class (\d+) (\S+)' % e, l)
        if m: q[m.group(1)] += 1
        m = re.search(r'ai %s: action 7 \(\S+\) done m ([0-9.]+)' % e, l)
        if m:
            runs += 1; fails += m.group(1) == '0.00'
    print(name, 'ent', e, 'attacks', q['13'], 'stands', q['1'], 'runs', runs, 'failed runs', fails)
