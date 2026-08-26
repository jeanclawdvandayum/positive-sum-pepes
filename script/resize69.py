#!/usr/bin/env python3
"""48->69 asset migration. One shared transform, applied to EVERYTHING
(grids, stamps, anchors, zone constants) so relative alignment holds by
construction:  S(v) = round(v * 69/48) = round(v * 23/16).

Outputs:
  - script/traits69/  (new 69-wide trait text files, the new source of truth)
  - constants table for gen_pepe_art.py v5 (printed)
  - script/out/resize69_report.json (per-trait bbox + placements)
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
TRAITS = os.path.join(HERE, 'traits')
OUT69 = os.path.join(HERE, 'traits69')
OUTDIR = os.path.join(HERE, 'out')
OLD, NEW = 48, 69


def S(v):
    """Forward map, round-half-up: 48-space -> 69-space. S(48) == 69."""
    return (v * 23 + 8) // 16


def src_map(n_src, n_dst):
    """dest index -> source index. Every dest cell covered exactly once;
    every source cell contributes >= 1 dest cell when n_dst > n_src."""
    m = []
    s = 0
    for d in range(n_dst):
        while s + 1 < n_src and S(s + 1) <= d:
            s += 1
        m.append(s)
    return m


COLSRC = src_map(OLD, NEW)
ROWSRC = src_map(OLD, NEW)

_DIR = re.compile(r'^#\s*(name|y|dx|dy):\s*(\S+)\s*$')


def parse_blocks(path):
    blocks, cur = {}, None
    for raw in open(path):
        line = raw.rstrip('\n')
        m = _DIR.match(line)
        if m:
            key, val = m.groups()
            if key == 'name':
                cur = {'rows': [], 'y': 0, 'dx': 0, 'dy': 0}
                blocks[val] = cur
            else:
                cur[key] = int(val)
            continue
        if line.startswith('#') or not line.strip():
            continue
        cur['rows'].append(line)
    return blocks


def scale_table(rows):
    """Equal-length letter table -> scaled table under S. Works for both
    full grids (48 rows of 48) and tight stamps (h rows of w).
    A w-wide table becomes S(w) wide: source col c paints dest cols
    [S(c), S(c+1)) — every dest cell covered exactly once."""
    h, w = len(rows), len(rows[0])
    assert all(len(r) == w for r in rows), 'ragged source rows'
    cs, rs = src_map(w, S(w)), src_map(h, S(h))
    return [''.join(rows[ry][cx] for cx in cs) for ry in rs]


def scale_stamp_global(rows, dx, dy):
    """Scale a TIGHT stamp through the GLOBAL canvas transform.

    S(a) + S(b) != S(a + b) — the transform is not affine — so scaling a
    stamp's table locally (col 0 -> dest col 0) lands up to ~2px off the
    grid the base and full-grid traits use. This maps every source canvas
    cell (dx+i, dy+j) to its global dest span [S(p), S(p+1)) instead,
    then re-crops. Returns (rows, dx, dy) with empty edge rows/cols kept
    relative to the span (trim happens in the caller)."""
    h, w = len(rows), len(rows[0])
    x0, y0 = S(dx), S(dy)
    x1, y1 = S(dx + w), S(dy + h)          # exclusive
    # global src-col index for each dest col in [x0, x1)
    cols = []
    s = dx
    for xx in range(x0, x1):
        while s + 1 < dx + w and S(s + 1) <= xx:
            s += 1
        cols.append(s - dx)
    out = []
    s = dy
    for yy in range(y0, y1):
        while s + 1 < dy + h and S(s + 1) <= yy:
            s += 1
        r = rows[s - dy]
        out.append(''.join(r[c] for c in cols))
    return out, x0, y0


def SPAN(a, b):
    """Inclusive 48-space span [a, b] -> inclusive 69-space span."""
    return (S(a), S(b + 1) - 1)


def bbox(rows):
    ys = [j for j, r in enumerate(rows) if set(r) - {'.'}]
    if not ys:
        return None
    xs = [i for i in range(len(rows[0]))
          if any(rows[j][i] != '.' for j in range(len(rows)))]
    return (min(xs), min(ys), max(xs), max(ys))


def trim_empty(rows):
    """(rows, ndropped_top) — drop empty edge rows so files stay tidy."""
    top = 0
    while rows and set(rows[0]) == {'.'}:
        rows.pop(0)
        top += 1
    while rows and set(rows[-1]) == {'.'}:
        rows.pop()
    return rows, top


def main():
    os.makedirs(OUT69, exist_ok=True)
    os.makedirs(OUTDIR, exist_ok=True)
    report = {'files': {}}

    # full-grid traits: expressions, eyes (rows are full-canvas width,
    # content-height, anchored by '# y:')
    for fname in ('expressions.txt', 'eyes.txt'):
        blocks = parse_blocks(os.path.join(TRAITS, fname))
        lines = ['# 69x69 — migrated from the 48px originals by'
                 ' script/resize69.py (S(v)=round(v*23/16))']
        for name, b in blocks.items():
            scaled = scale_table(b['rows'])
            assert all(len(r) == NEW for r in scaled), 'bad width'
            scaled, top = trim_empty(scaled)
            lines.append('')
            lines.append(f'# name: {name}')
            lines.append(f'# y: {S(b["y"]) + top}')
            lines.extend(scaled)
            sb, db = bbox(b['rows']), bbox(scaled)
            report['files'][f'{fname}:{name}'] = {
                'src_bbox': list(sb) if sb else None,
                'dst_bbox': list(db) if db else None}
        open(os.path.join(OUT69, fname), 'w').write('\n'.join(lines) + '\n')

    # stamp traits: hats, eyewear, items (tight tables + dx/dy anchors).
    # Scaled through the GLOBAL canvas transform (see scale_stamp_global)
    # so stamps stay on the same grid as the base + full-grid traits.
    for fname in ('hats.txt', 'eyewear.txt', 'items.txt'):
        blocks = parse_blocks(os.path.join(TRAITS, fname))
        lines = ['# 69x69 — migrated from the 48px originals by'
                 ' script/resize69.py (S(v)=round(v*23/16), global map)']
        for name, b in blocks.items():
            scaled, gx, gy = scale_stamp_global(
                b['rows'], b['dx'], b['dy'])
            scaled, top = trim_empty(scaled)
            # trim empty leading COLUMNS too (adjust dx accordingly)
            first = next((i for i, c in enumerate(zip(*scaled))
                          if set(c) - {'.'}), None)
            if first:
                scaled = [r[first:] for r in scaled]
            elif first is None:
                scaled = []
            dx, dy = gx + first, gy + top
            lines.append('')
            lines.append(f'# name: {name}')
            lines.append(f'# dx: {dx}')
            lines.append(f'# dy: {dy}')
            lines.extend(scaled)
            sb, db = bbox(b['rows']), bbox(scaled)
            report['files'][f'{fname}:{name}'] = {
                'src_bbox': list(sb) if sb else None,
                'dst_bbox': list(db) if db else None,
                'dx': dx, 'dy': dy}
        open(os.path.join(OUT69, fname), 'w').write('\n'.join(lines) + '\n')

    # constants table for gen v5 (zone clears + authored features).
    # SPAN() for inclusive ranges; NOSTRILS expanded row-by-row.
    nostril_rows = []
    for y0, y1 in (SPAN(26, 26), SPAN(27, 27)):
        for x0, x1 in ((22, 23), (27, 28)):
            a, b = SPAN(x0, x1)
            for y in range(y0, y1 + 1):
                nostril_rows.append([y, a, b])
    consts = {
        'EYE_Y0': SPAN(15, 25)[0], 'EYE_Y1': SPAN(15, 25)[1],
        'LX0': SPAN(14, 24)[0], 'LX1': SPAN(14, 24)[1],
        'RX0': SPAN(27, 37)[0], 'RX1': SPAN(27, 37)[1],
        'SNACK_BOX': [SPAN(9, 15)[0], SPAN(24, 32)[0],
                      SPAN(9, 15)[1], SPAN(24, 32)[1]],
        'stray_y_top': S(15),
        'teeth_y0': SPAN(27, 35)[0], 'teeth_y1': SPAN(27, 35)[1],
        'mouth_y0': SPAN(27, 35)[0], 'mouth_y1': SPAN(27, 35)[1],
        'mouth_x0': SPAN(13, 42)[0], 'mouth_x1': SPAN(13, 42)[1],
        'clear_eye_y1': S(26) + 1,
        'clear_x0': S(13), 'clear_x1': S(40),
        'NOSTRILS': nostril_rows,
    }
    report['constants'] = consts
    json.dump(report, open(os.path.join(OUTDIR, 'resize69_report.json'), 'w'),
              indent=1)
    print(json.dumps(consts, indent=1))
    print('wrote', OUT69)


if __name__ == '__main__':
    main()
