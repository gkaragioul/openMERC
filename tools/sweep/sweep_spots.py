#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs level sweep (2026-11-08): pick camera spots for every single-player map, read-only from the pak files.
# Spots per map: S0 the player start (its own facing), S1/S3 item or weapon spots spread over the level (farthest
# from the spots already chosen), each looking down its longest open line, S2 a view of a character (camera in front
# of it, facing it). A spot needs a floor below, head room and an open view; positions follow SPEC-101 BSP lumps.
# usage: sweep_spots.py <base dir with pak files> <out.json> map...
import json, math, os, struct, sys

SOLID, WINDOW, LAVA, SLIME, WATER = 1, 2, 8, 16, 32
BLOCK = SOLID | WINDOW | LAVA | SLIME | WATER


def pak_index(base):
    idx = {}
    for p in sorted(os.listdir(base)):
        if not p.endswith('.pak'):
            continue
        path = os.path.join(base, p)
        with open(path, 'rb') as f:
            ident, dirofs, dirlen = struct.unpack('<4sii', f.read(12))
            if ident != b'PACK':
                continue
            f.seek(dirofs)
            for _ in range(dirlen // 64):
                n, ofs, ln = struct.unpack('<56sii', f.read(64))
                idx[n.split(b'\0')[0].decode('latin-1').lower()] = (path, ofs, ln)
    return idx


def read(idx, name):
    path, ofs, ln = idx[name]
    with open(path, 'rb') as f:
        f.seek(ofs)
        return f.read(ln)


class Bsp:
    def __init__(self, d):
        self.lumps = [struct.unpack_from('<ii', d, 8 + 8 * i) for i in range(22)]
        lump = lambda i: d[self.lumps[i][0]:self.lumps[i][0] + self.lumps[i][1]]
        self.ents = lump(0).decode('latin-1').rstrip('\0')
        self.planes = [struct.unpack_from('<4f', lump(1), i) for i in range(0, len(lump(1)), 20)]
        self.nodes = [struct.unpack_from('<iii', lump(4), i) for i in range(0, len(lump(4)), 28)]
        self.leafs = [struct.unpack_from('<ihh', lump(8), i) for i in range(0, len(lump(8)), 32)]
        self.headnode = struct.unpack_from('<i', lump(13), 36)[0]

    def contents(self, p):
        n = self.headnode
        while n >= 0:
            pl, c0, c1 = self.nodes[n]
            nx, ny, nz, dist = self.planes[pl]
            n = c0 if nx * p[0] + ny * p[1] + nz * p[2] - dist >= 0 else c1
        return self.leafs[-1 - n][0]

    def floor(self, x, y, z):
        """floor z below (x, y, z), or None (start must be open, floor within 400 units)"""
        if self.contents((x, y, z)) & BLOCK:
            return None
        for dz in range(0, 400, 2):
            c = self.contents((x, y, z - dz))
            if c & SOLID:
                return z - dz + 2
            if c & (LAVA | SLIME | WATER):
                return None
        return None

    def free_column(self, x, y, fz, r=16):
        for zz in range(8, 80, 8):
            for ox, oy in ((0, 0), (r, 0), (-r, 0), (0, r), (0, -r)):
                if self.contents((x + ox, y + oy, fz + zz)) & BLOCK:
                    return False
        return True

    def ray(self, x, y, z, yaw, limit=2000):
        dx, dy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        for t in range(16, limit, 8):
            if self.contents((x + dx * t, y + dy * t, z)) & SOLID:
                return t
        return limit

    def best_yaw(self, x, y, fz):
        best = max(range(0, 360, 22), key=lambda a: self.ray(x, y, fz + 60, a))
        return best, self.ray(x, y, fz + 60, best)


def entities(text):
    out, cur, key = [], None, None
    import re
    for tok in re.findall(r'"([^"]*)"|([{}])', text):
        s, brace = tok
        if brace == '{':
            cur = {}
        elif brace == '}':
            out.append(cur)
            cur = None
        elif cur is not None:
            if key is None:
                key = s
            else:
                cur[key.lower()] = s
                key = None
    return out


def origin(e):
    try:
        return tuple(float(v) for v in e.get('origin', '').split())[:3]
    except ValueError:
        return None


def facing(e):
    if 'angle' in e:
        try:
            return float(e['angle'])
        except ValueError:
            pass
    if 'angles' in e:
        try:
            return float(e['angles'].split()[1])
        except (ValueError, IndexError):
            pass
    return 0.0


def spot(bsp, x, y, z, yaw=None, min_open=256):
    fz = bsp.floor(x, y, z + 16)
    if fz is None or not bsp.free_column(x, y, fz):
        return None
    if yaw is None:
        yaw, dist = bsp.best_yaw(x, y, fz)
        if dist < min_open:
            return None
    else:
        dist = bsp.ray(x, y, fz + 60, yaw)
    return {'x': round(x), 'y': round(y), 'z': round(fz + 40), 'yaw': int(yaw) % 360, 'open': dist}


def pick(bsp, ents, mapname):
    spots = []
    starts = [e for e in ents if e.get('classname') == 'info_player_start' and origin(e)]
    start = next((e for e in starts if 'targetname' not in e), starts[0] if starts else None)
    if start:
        x, y, z = origin(start)
        s = {'x': round(x), 'y': round(y), 'z': round(z), 'yaw': int(facing(start)) % 360, 'open': 0,
             'kind': 'start', 'ent': 'info_player_start', 'natural': True}
        spots.append(s)
    items = []
    for e in ents:
        c = e.get('classname', '')
        o = origin(e)
        if o and (c.startswith('item_') or c.startswith('weapon_')):
            x, y, z = o
            s0 = spot(bsp, x, y, z)
            if not s0:
                continue
            # stand 64 units behind the item, looking past it (no pickup at the camera)
            a = math.radians(s0['yaw'])
            s = spot(bsp, x - 64 * math.cos(a), y - 64 * math.sin(a), z, yaw=s0['yaw'], min_open=0)
            if not s or s['open'] < 128:
                s = s0
            s.update(kind='item', ent=c)
            items.append(s)
    chars = []
    for e in ents:
        c = e.get('classname', '')
        o = origin(e)
        if o and c.startswith('m_') and not (int(e.get('spawnflags', '0') or 0) & 0x10000):
            x, y, z = o
            f = math.radians(facing(e))
            cx, cy = x + 112 * math.cos(f), y + 112 * math.sin(f)
            s = spot(bsp, cx, cy, z, yaw=(facing(e) + 180) % 360, min_open=0)
            if s and bsp.ray(cx, cy, s['z'] + 20, s['yaw']) > 112:
                s.update(kind='character', ent=c)
                chars.append(s)

    def farthest(cands):
        if not cands:
            return None
        if not spots:
            return max(cands, key=lambda s: s['open'])
        return max(cands, key=lambda s: min(math.dist((s['x'], s['y'], s['z']), (t['x'], t['y'], t['z'])) for t in spots))

    for group, other in ((items, chars), (chars, items), (items, chars)):
        s = farthest([c for c in group if c not in spots]) or farthest([c for c in other if c not in spots])
        if s:
            spots.append(s)
    for i, s in enumerate(spots):
        s['id'] = f'S{i}'
    return {'map': mapname, 'starts': len(starts), 'items': len(items), 'characters': len(chars), 'spots': spots}


def main():
    base, out, maps = sys.argv[1], sys.argv[2], sys.argv[3:]
    idx = pak_index(base)
    res = []
    for m in maps:
        bsp = Bsp(read(idx, f'maps/{m}.bsp'))
        r = pick(bsp, entities(bsp.ents), m)
        res.append(r)
        print(f"{m:6} starts {r['starts']} items {r['items']:3} chars {r['characters']:3} spots " +
              ' '.join(f"{s['kind'][0]}({s['x']},{s['y']},{s['z']} y{s['yaw']} o{s['open']})" for s in r['spots']))
    with open(out, 'w') as f:
        json.dump(res, f, indent=1)


main()
