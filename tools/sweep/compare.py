#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# RLabs level sweep: Metal vs GL reference screenshot per spot (/usr/bin/python3 for PIL; reads only this sweep's
# own captures). Per spot: mean absolute difference (/255), share of pixels differing by more than 48 levels in any
# channel, mean brightness of each. Writes compare.csv, a strip (Metal | GL | difference) for every spot into
# strips/, and two contact sheets (all Metal / all GL thumbnails) for spot checks by eye.
# usage: compare.py <spots.json> <metal scrnshot dir> <gl scrnshot dir> <out dir>
import csv, json, os, sys
from PIL import Image, ImageChops, ImageDraw, ImageStat

spots, md, gd, out = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
os.makedirs(os.path.join(out, 'strips'), exist_ok=True)
rows, thumbs = [], {'metal': [], 'gl': []}
TW = 480
for m in spots:
    for s in m['spots']:
        key = f"{m['map']}_{s['id']}"
        pm, pg = os.path.join(md, f'sw_{key}.tga'), os.path.join(gd, f'sw_{key}.tga')
        row = {'map': m['map'], 'spot': s['id'], 'kind': s['kind'], 'ent': s['ent'],
               'metal': os.path.exists(pm), 'gl': os.path.exists(pg)}
        im = Image.open(pm).convert('RGB') if row['metal'] else None
        ig = Image.open(pg).convert('RGB') if row['gl'] else None
        for tag, img in (('metal', im), ('gl', ig)):
            if img:
                t = img.resize((TW, round(img.height * TW / img.width)))
                thumbs[tag].append((key, t))
        if im and ig and im.size == ig.size:
            d = ImageChops.difference(im, ig)
            row['mad'] = round(sum(ImageStat.Stat(d).mean) / 3, 3)
            mx = d.convert('L').point(lambda v: 255 if v > 48 else 0)  # L = weighted, close enough for a mask
            row['big_pct'] = round(100 * ImageStat.Stat(mx).mean[0] / 255, 2)
            row['bright_metal'] = round(sum(ImageStat.Stat(im).mean) / 3, 1)
            row['bright_gl'] = round(sum(ImageStat.Stat(ig).mean) / 3, 1)
            h = round(im.height * TW / im.width)
            strip = Image.new('RGB', (TW * 3, h + 18), (0, 0, 0))
            dd = d.point(lambda v: min(255, v * 4))
            for i, img in enumerate((im, ig, dd)):
                strip.paste(img.resize((TW, h)), (TW * i, 18))
            ImageDraw.Draw(strip).text((4, 3), f"{key} {s['kind']} {s['ent']}  Metal | GL | diff x4   mad "
                                       f"{row['mad']}  big {row['big_pct']}%", fill=(255, 255, 0))
            strip.save(os.path.join(out, 'strips', f'{key}.jpg'), quality=72)
        rows.append(row)
with open(os.path.join(out, 'compare.csv'), 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=['map', 'spot', 'kind', 'ent', 'metal', 'gl', 'mad', 'big_pct', 'bright_metal',
                                      'bright_gl'])
    w.writeheader()
    w.writerows(rows)
for tag, lst in thumbs.items():
    if not lst:
        continue
    cw, ch, cols = 240, round(lst[0][1].height / 2), 8
    sheet = Image.new('RGB', (cw * cols, (ch + 12) * ((len(lst) + cols - 1) // cols)), (0, 0, 0))
    for i, (key, t) in enumerate(lst):
        x, y = cw * (i % cols), (ch + 12) * (i // cols)
        sheet.paste(t.resize((cw, ch)), (x, y + 12))
        ImageDraw.Draw(sheet).text((x + 2, y), key, fill=(255, 255, 0))
    sheet.save(os.path.join(out, f'contact-{tag}.jpg'), quality=70)
done = [r for r in rows if 'mad' in r]
print(f"{len(rows)} spots, {len(done)} compared, missing metal {sum(not r['metal'] for r in rows)}, "
      f"missing gl {sum(not r['gl'] for r in rows)}")
for r in sorted(done, key=lambda r: -r['big_pct'])[:25]:
    print(f"{r['map']:6} {r['spot']} {r['kind']:9} mad {r['mad']:6} big {r['big_pct']:6}% bright M {r['bright_metal']} "
          f"G {r['bright_gl']}")
