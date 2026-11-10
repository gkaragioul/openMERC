#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs whole-game audit (2026-11-08): static checks of every single-player level's entity list and designer scripts,
# from the game data only (read through a scratch extract). Finds references that cannot resolve and script commands
# the engine treats specially.
# usage: audit_levels.py <extract dir with maps/ ds/ > <dsl dir (os_script.py dump)> <paklist.txt> <repo> <spots.json> > report
import json, os, re, struct, sys
from collections import Counter, defaultdict

X, DSL, PAKLIST, REPO, SPOTS = sys.argv[1:6]
maps = [m['map'] for m in json.load(open(SPOTS))]


def ents_of(path):
    b = open(path, 'rb').read()
    ofs, ln = struct.unpack_from('<ii', b, 8)
    txt = b[ofs:ofs + ln].decode('latin-1')
    return [dict(re.findall(r'"([^"]*)"\s+"([^"]*)"', m.group(1))) for m in re.finditer(r'\{(.*?)\}', txt, re.S)]


files = set()
for ln in open(PAKLIST, encoding='latin-1'):
    p = ln.split()
    if len(p) >= 2:
        files.add(p[-1].replace('\\', '/').lower())

# spawnable classnames: every "name" the game module lists
classes = set(re.findall(r'"([a-zA-Z_0-9]+)"', open(os.path.join(REPO, 'game/src/g_classlist.inc')).read()))

# AI command table (kind, animation)
table = {}
for ln in open(os.path.join(REPO, 'docs/specs/SPEC-750-script-vm.md'), encoding='utf-8'):
    m = re.match(r'\| (\d+) \| (\d+) \| ([^|]*)\| ([^|]*)\|', ln)
    if m:
        table[int(m.group(1))] = (int(m.group(2)), m.group(4).strip().strip('`'))
anims = set(re.findall(r'G3A\("([^"]+)"', open(os.path.join(REPO, 'game/src/damage/g3_humananims.inc')).read()))

findings = defaultdict(list)
scripts_used = defaultdict(set)
allents = {}
for mp in maps:
    p = os.path.join(X, 'maps', mp + '.bsp')
    if not os.path.exists(p):
        findings['map missing'].append(mp)
        continue
    ents = ents_of(p)
    allents[mp] = ents
    names = {e['targetname'] for e in ents if 'targetname' in e}
    stargets = {e['scripttarget'] for e in ents if 'scripttarget' in e}
    for e in ents:
        c = e.get('classname', '')
        if c and c not in classes:
            findings['class with no spawn entry'].append(f'{mp}: {c}')
        for k in ('target', 'killtarget', 'pathtarget', 'combattarget', 'deathtarget', 'spawntarget'):
            if k in e and e[k] not in names:
                findings[f'{k} names nothing'].append(f"{mp}: {c} at {e.get('origin','?')} -> {e[k]}")
        if c == 'script_runner' and 'script' in e:
            scripts_used[e['script'].lower()].add(mp)
        if c == 'worldspawn' and 'script' in e:
            scripts_used[e['script'].lower()].add(mp)
        if c == 'target_changelevel' and 'map' in e:
            t = e['map'].split('$')[0].lower()
            if t + '.bsp' not in {f.split('/')[-1] for f in files if f.startswith('maps/')}:
                findings['changelevel to a missing map'].append(f"{mp} -> {e['map']}")

idx = {}
for root, _, fs in os.walk(DSL):
    for f in fs:
        if f.endswith('.dsl'):
            rel = os.path.relpath(os.path.join(root, f), DSL)[:-4].lower().replace('\\', '/')
            idx[rel] = os.path.join(root, f)

noscr = 0
for s, used in sorted(scripts_used.items()):
    if s not in idx:
        noscr += 1
        findings['script file missing'].append(f"{s} used by {sorted(used)}")
        continue
    text = open(idx[s], encoding='latin-1').read()
    for mp in used:
        ents = allents[mp]
        names = {e['targetname'] for e in ents if 'targetname' in e} | {'player'}
        st = {e['scripttarget'] for e in ents if 'scripttarget' in e}
        for n in set(re.findall(r'targetname\("([^"]+)"\)', text)):
            if n not in names:
                findings['script asks for a name the level lacks'].append(f'{mp} {s}: {n}')
        for n in set(re.findall(r'scripttarget\("([^"]+)"\)', text)):
            if n not in st:
                findings['script asks for a scripttarget the level lacks'].append(f'{mp} {s}: {n}')
    for ln in text.splitlines():
        m = re.search(r'\bai\((\w+), (\d+)(.*)\) \[flags (0x[0-9a-f]+)\]', ln)
        if m:
            cid, fl = int(m.group(2)), int(m.group(4), 16)
            kind, an = table.get(cid, (0, ''))
            if fl & 0x400:
                continue
            if kind == 1 and not (fl & 0x84):
                findings['move command with no destination or target'].append(f'{s}: {ln.strip()[:100]}  [{an}]')
            if an and an != '— (none)' and an not in anims:
                findings['command animation not in the animation table'].append(f'{s}: id {cid} {an}')
            if cid not in table and cid not in (0, 3, 4, 10, 11, 12, 13, 14, 16, 17, 18, 19, 28, 135):
                findings['AI command id not in the table'].append(f'{s}: {ln.strip()[:100]}')
        for q in re.findall(r'(?:sound|precache_sound|sound_global)\([^"]*"([^"]+)"', ln):
            f = 'sound/' + q.replace('\\\\', '/').replace('\\', '/').lower()
            if f not in files and f.rsplit('.', 1)[0] + '.adp' not in files and f.rsplit('.', 1)[0] + '.wav' not in files:
                findings['sound file missing'].append(f'{s}: {q}')
        for q in re.findall(r'rof\([^"]*"([^"]+)"', ln):
            f = 'ds/roff/' + q.lower()
            if f not in files:
                findings['ROF file missing'].append(f'{s}: {q}')

print(f'{len(allents)} levels, {len(scripts_used)} scripts used, {len(idx)} listings')
for k in sorted(findings, key=lambda k: -len(findings[k])):
    v = sorted(set(findings[k]))
    print(f'\n== {k}: {len(v)}')
    for x in v[:80]:
        print('  ' + x)
    if len(v) > 80:
        print(f'  ... {len(v) - 80} more')
