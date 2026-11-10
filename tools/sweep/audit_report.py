#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs enemy reaction audit: sums up the OMAUDIT lines of a console log (game/src/ai/ai_audit.cpp).
# usage: audit_report.py <console.log> [out.json]
import collections, json, re, sys

text = open(sys.argv[1], encoding='latin-1').read().splitlines()
rows, done, started, why = [], {}, [], {}
for ln in text:
    for tag in ('OMWHY4 ', 'OMWHY5 '):
        j = ln.find(tag)
        if j >= 0:
            q = ln[j:].split()
            why.setdefault((q[1], q[2][4:]), {}).update(kv.split('=', 1) for kv in q[3:] if '=' in kv)
    i = ln.find('OMAUDIT ')
    if i < 0:
        continue
    p = ln[i:].split()
    if p[2] == 'start':
        started.append(p[1])
    elif p[2] == 'done':
        done[p[1]] = dict(kv.split('=') for kv in p[3:])
    else:
        rows.append(dict(map=p[1], result=p[2], **dict(kv.split('=', 1) for kv in p[3:])))
lights = [(int(r['plight']), int(r['clight'])) for r in rows if 'plight' in r]
if lights:
    print('player light seen by the sight roll: entity light_level (new) min %d max %d; client lightlevel (old) min %d max %d' %
          (min(l[0] for l in lights), max(l[0] for l in lights), min(l[1] for l in lights), max(l[1] for l in lights)))
tally = collections.Counter(r['result'] for r in rows)
times = sorted(float(r['t']) for r in rows if r['result'] in ('ATTACK', 'CHASE'))
# tsr2 is a cut-scene level: its start script (ds/tsr1/startcin.os) ends with `changelevel` into trn1 (intermission), so
# the level ends itself before its 29 actors can be checked
CUTSCENE_LEVELS = ('tsr2',)
print('levels started', len(started), 'finished', len(done), 'not finished',
      [m + (' (cut-scene level)' if m in CUTSCENE_LEVELS else '') for m in started if m not in done])
print('enemies', len(rows), dict(tally), 'median reaction', times[len(times) // 2] if times else '-', 's, slowest', times[-1] if times else '-')
# passive by design: cows and bulls moo and never fight (SPEC-722 cow/bull body, test 3)
PASSIVE = ('m_x_bull',)
for r in rows:
    if r['result'] == 'SILENT' and r['class'] in PASSIVE:
        r['result'] = 'PASSIVE'
# riders: a dormant passenger woken by the audit inside its vehicle, before its script lets it out (sib1 bridge snowcat)
# stuck: never moves (spawnflag 128) and has no clear shot past a prop or vehicle (by design: it holds its post)
for r in rows:
    w = why.get((r['map'], r['ent']), {})
    if r['result'] != 'SILENT':
        continue
    if w.get('start') == '1' and not w.get('hit', '').startswith('worldspawn'):
        r['result'] = 'RIDER'
    elif int(r['sf']) & 128 and w.get('clear') == '0' and not w.get('blocker', '').startswith('0('):
        r['result'] = 'POSTED'
    elif int(r.get('sf0', '0')) & 22 == 22:
        # cut-scene actor: spawned dormant, blind and deaf (spawnflags 16, 2, 4), waiting for its script; the audit woke it
        # out of order (sud3 Dekker and missile scene raiders have no fire record at all). Listed below, check by name
        r['result'] = 'SCRIPTED'
tally = collections.Counter(r['result'] for r in rows)
print('after riders and posted guards:', dict(tally))
tally = collections.Counter(r['result'] for r in rows)
print('after passive animals:', dict(tally))
for r in rows:
    if r['result'] in ('SCRIPTED', 'RIDER', 'POSTED'):
        print('not counted:', r['map'], r['result'], r['class'], r['name'], 'sf0', r.get('sf0'))
bad = [r for r in rows if r['result'] in ('SILENT', 'NOSPOT')]
by = collections.Counter((r['result'], r['class'], r['act'], r['rec'], r['dec']) for r in bad)
for (res, cls, act, rec, dec), n in by.most_common(40):
    print(f'{n:4d} {res:7s} {cls:24s} action {act:3s} {rec:28s} decisions {dec}')
for r in bad[:60]:
    print(r['map'], r['result'], r['class'], r['name'], 'sf', r['sf'], r['pos'], 'awake', r['awake'], 'alerted', r['alerted'], 'act', r['act'], r['rec'])
if len(sys.argv) > 2:
    json.dump(dict(rows=rows, done=done), open(sys.argv[2], 'w'), indent=0)
