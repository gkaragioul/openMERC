#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs whole-game scan (2026-11-09): one console script per cut scene of every single-player level. A cut scene is a
# script_runner whose script holds the player (`hold()`); intros that start by themselves are played from the map
# start, the others are fired with the test command `omfire <targetname>` on a fresh load of the level.
# A menu an outro leaves open (intermission) is closed before the next load, else the console stays down and the game
# paused for every later scene (run 0215).
# usage: make_film_cfgs.py <audit dir: x/maps, dsl/> <spots.json> <out dir> [map ...]
import json, os, re, struct, sys

A, SPOTS, OUT = sys.argv[1:4]
only = set(sys.argv[4:])
maps = [m['map'] for m in json.load(open(SPOTS))]
os.makedirs(OUT, exist_ok=True)
STEP_S = 0.75  # one w100 at the scan's frame rate


def ents(m):
    b = open(f'{A}/x/maps/{m}.bsp', 'rb').read()
    o, l = struct.unpack_from('<ii', b, 8)
    t = b[o:o + l].decode('latin-1')
    return [dict(re.findall(r'"([^"]*)"\s+"([^"]*)"', x.group(1))) for x in re.finditer(r'\{(.*?)\}', t, re.S)]


def dsl(s):
    p = f'{A}/dsl/{s.lower()}.dsl'
    return open(p, encoding='latin-1').read() if os.path.exists(p) else ''


HEAD = '''alias w10 "wait;wait;wait;wait;wait;wait;wait;wait;wait;wait"
alias w100 "w10;w10;w10;w10;w10;w10;w10;w10;w10;w10"
set cl_maxfps 100
set vid_vsync 0
'''
scenes = []
for m in maps:
    if only and m not in only:
        continue
    E = ents(m)
    world = next((e for e in E if e.get('classname') == 'worldspawn'), {})
    wt = dsl(world.get('script', ''))
    # names the level's start-up script uses: var = targetname("x") ... use(var)
    bind = dict(re.findall(r'(\w+) = targetname\("([^"]+)"\)', wt))
    auto = {bind.get(v, v) for v in re.findall(r'\buse\((\w+)\)', wt)}
    seen = set()
    for e in E:
        if e.get('classname') != 'script_runner' or not e.get('targetname'):
            continue
        s = e.get('script', '')
        t = dsl(s)
        if 'hold()' not in t:
            continue
        key = (e['targetname'], s.lower())
        if key in seen:
            continue
        seen.add(key)
        dur = sum(float(x) for x in re.findall(r'\bwait\(([0-9.]+)\)', t))
        isauto = e['targetname'] in auto or 'intro' in s.lower().split('/')[-1] or e['targetname'].startswith('startintro') or s.lower() == 'tsr1/startcin'
        if (m, e['targetname']) in (('sib2', 't189'), ('ger4', 't1043')):
            isauto = False  # started by walking into a trigger, not at level start
        scenes.append((m, e['targetname'], s, dur, isauto))

index = []
for n, (m, tn, s, dur, isauto) in enumerate(scenes):
    shots = min(115, int((max(dur, 4.0) + 3) / 0.84) + 1)  # one picture every two w100 is about 0.84 s (runs 0215, 0217)
    first_pass = min(46, int(max(dur, 4.0) / 1.5) + 5)    # what run 0217's sheets covered
    tag = f"{m}_{n:02d}"
    lines = [f'// {m} {tn} {s} ({dur:.1f} s of waits, auto={isauto})', HEAD]
    lines.append('killmenu')
    lines.append(f'echo RLFILM {tag} load {tn} {s}')
    if isauto:
        lines += ['set sv_jumpcinematic 0', f'map {m}', 'w10;w10;w10', f'echo RLFILM {tag} go']
    else:
        # the door or button the player opens on the way in (runs 0227, 0228): fired directly, the scene's actors walk into it
        fire = {('sud3', 't27'): ['omfire *142'], ('ger4', 't1043'): ['omfire *35', 'w100;w100;w100', 'omfire t1043']}.get((m, tn), [f'omfire {tn}'])
        lines += ['set sv_jumpcinematic 1', f'map {m}', 'w100;w100;w100;w100', 'set sv_jumpcinematic 0',
                  f'echo RLFILM {tag} go'] + fire + ['w10;w10']
    for k in range(shots):
        lines += [f'screenshot {tag}_{k:02d}', 'w100', 'w100']
    lines.append(f'echo RLFILM {tag} done')
    nxt = f'film_{n + 1:03d}.cfg' if n + 1 < len(scenes) else None
    lines.append(f'exec {nxt}' if nxt else 'quit')
    open(os.path.join(OUT, f'film_{n:03d}.cfg'), 'w').write('\n'.join(lines) + '\n')
    index.append({'tag': tag, 'map': m, 'target': tn, 'script': s, 'waits': dur, 'auto': isauto, 'shots': shots, 'tail_from': max(0, first_pass - 2)})
json.dump(index, open(os.path.join(OUT, 'index.json'), 'w'), indent=0)
print(len(index), 'scenes,', sum(i['shots'] for i in index), 'pictures')
