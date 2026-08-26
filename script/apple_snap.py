#!/usr/bin/env python3
"""8-bit Apple-palette snap experiment for PSP pepes (2026-08-24).

Takes the LIVE palette axes (skins / fixed slots / irises / backgrounds) and
snaps every color to the nearest entry of an "Apple 16-color x intensity"
lattice. Geometry (sprites, RLE, DNA) is untouched — this is a pure color
remap, which is exactly how an 8-bit machine would do palette tricks.

Emits:
  src/PepeArtData8Bit.sol       (copy of PepeArtData, 4 color constants swapped)
  src/PepeDescriptor8Bit.sol    (copy of PepeDescriptor, art import swapped)
  script/out/apple8/preview_*.png   (contact sheets, python-rendered)
  script/out/apple8/lattice.json    (lattices + snapped palettes, for the lab)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_pepe_art as G  # noqa: E402
from traits.palettes import SKINS, FIXED, IRISES, BACKGROUNDS  # noqa: E402
from PIL import Image  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out', 'apple8')

# ── candidate base palettes ──────────────────────────────────────────
# (A) Lospec "Apple II" — NTSC double-hi-res artifact colors (verified pull)
APPLE_DHGR = [
    (0xca, 0x58, 0x34), (0x00, 0x00, 0x00), (0x51, 0x5c, 0x16), (0x84, 0x3d, 0x52),
    (0xea, 0x7d, 0x27), (0x51, 0x48, 0x88), (0xe8, 0x5d, 0xef), (0xf5, 0xb7, 0xc9),
    (0x00, 0x67, 0x52), (0x00, 0xc8, 0x2c), (0x91, 0x91, 0x91), (0xc9, 0xd1, 0x99),
    (0x00, 0xa6, 0xf0), (0x98, 0xdb, 0xc9), (0xc8, 0xc1, 0xf7), (0xff, 0xff, 0xff),
]
# (B) Apple IIgs RGB — canonical 16 (my recollection; labeled unverified in UI)
APPLE_IIGS = [
    (0x00, 0x00, 0x00), (0xdd, 0x00, 0x33), (0x88, 0x22, 0xcc), (0xdd, 0x77, 0xee),
    (0x00, 0x66, 0x00), (0x55, 0x55, 0x55), (0x22, 0xaa, 0xee), (0x99, 0xdd, 0xff),
    (0x77, 0x22, 0x00), (0xee, 0x77, 0x00), (0x88, 0x88, 0x88), (0xdd, 0x88, 0x99),
    (0x00, 0xcc, 0x00), (0xff, 0xee, 0x00), (0x66, 0xdd, 0xcc), (0xff, 0xff, 0xff),
]

PALETTES = {'dhgr': APPLE_DHGR, 'iigs': APPLE_IIGS}

# intensity multipliers for the lattice ramps (clamped; duplicates removed)
INTENSITIES = [0.55, 0.75, 1.0, 1.3]


def build_lattice(base16, intensities=INTENSITIES):
    lat, seen = [], set()
    for c in base16:
        for m in intensities:
            v = tuple(min(255, round(ch * m)) for ch in c)
            if v not in seen:
                seen.add(v)
                lat.append(v)
    return lat


def snap(rgb, lattice):
    return min(lattice, key=lambda k: (rgb[0] - k[0]) ** 2
               + (rgb[1] - k[1]) ** 2 + (rgb[2] - k[2]) ** 2)


def snapped_palette_axes(lattice):
    """skins/irises/bgs with each color snapped; fixed slots too."""
    skins = []
    for name, slots in SKINS:
        skins.append((name, {s: snap(c, lattice) for s, c in slots.items()}))
    fixed = {s: snap(c, lattice) for s, c in FIXED.items()}
    irises = [(n, snap(c, lattice)) for n, c in IRISES]
    bgs = [(n, snap(c, lattice)) for n, c in BACKGROUNDS]
    return skins, fixed, irises, bgs


def assemble_8bit(skin_id, iris_id, bg_id, skins, fixed, irises, bgs):
    """mirror of G.assemble_palette but over snapped tables"""
    pal = dict(fixed)
    pal.update(skins[skin_id][1])
    pal[6] = irises[iris_id][1]
    pal[15] = bgs[bg_id][1]
    return [pal.get(i, (0, 0, 0)) for i in range(16)]


def _hexl(colors):
    return ''.join(f'{r:02X}{g:02X}{b:02X}' for r, g, b in colors)


def emit_solidity(lattice_name):
    skins, fixed, irises, bgs = snapped_palette_axes(lattice_name)
    src = open(os.path.join(ROOT, 'src', 'PepeArtData.sol')).read()

    def repl(name, colors, count=None):
        nonlocal src
        h = _hexl(colors)
        import re
        pat = re.compile(r'(bytes internal constant %s = hex")([0-9A-Fa-f]*)(";)' % name)
        m = pat.search(src)
        assert m, f'{name} not found'
        if count is not None:
            assert len(m.group(2)) == 6 * count, f'{name}: expected {count} colors, found {len(m.group(2))//6}'
        src = pat.sub(lambda mm: mm.group(1) + h + mm.group(3), src, count=1)

    repl('SKIN_RAMPS', [c for _, slots in skins for c in
                        (slots[2], slots[3], slots[4], slots[10])], 4 * len(skins))
    repl('FIXED_SLOTS', [fixed[s] for s in (5, 7, 8, 9, 11, 12, 13, 14)], 8)
    repl('IRIS_COLORS', [c for _, c in irises], len(irises))
    repl('BG_COLORS', [c for _, c in bgs], len(bgs))
    src = src.replace('library PepeArtData {', 'library PepeArtData8Bit {')
    src = src.replace('/// @title PepeArtData', '/// @title PepeArtData8Bit')
    open(os.path.join(ROOT, 'src', 'PepeArtData8Bit.sol'), 'w').write(src)

    d = open(os.path.join(ROOT, 'src', 'PepeDescriptor.sol')).read()
    d = d.replace('import {PepeArtData} from "./PepeArtData.sol";',
                  'import {PepeArtData8Bit} from "./PepeArtData8Bit.sol";')
    d = d.replace('PepeArtData.', 'PepeArtData8Bit.')
    d = d.replace('contract PepeDescriptor ', 'contract PepeDescriptor8Bit ')
    d = d.replace('/// @title PepeDescriptor —', '/// @title PepeDescriptor8Bit —')
    open(os.path.join(ROOT, 'src', 'PepeDescriptor8Bit.sol'), 'w').write(d)
    print(f'emitted PepeArtData8Bit.sol + PepeDescriptor8Bit.sol '
          f'({lattice_name and len(lattice_name)}-color lattice)')


def render_sheets(lattice, tag):
    """python-side previews: compose real grids, snap palette, PNG sheets"""
    os.makedirs(OUT, exist_ok=True)
    skins, fixed, irises, bgs = snapped_palette_axes(lattice)
    base = G._base()

    combos = [
        ('classic', dict(skin=0, iris=0, bg=0)),
        ('gold', dict(skin=1, iris=2, bg=1)),
        ('zombie', dict(skin=2, iris=5, bg=6)),
        ('diamond', dict(skin=3, iris=1, bg=4)),
        ('hat_wiz', dict(skin=0, iris=0, bg=0, hat='WIZARD')),
        ('wear_shades', dict(skin=4, iris=4, bg=8, wear='SHADES')),
        ('item_cig', dict(skin=0, iris=3, bg=2, item='CIGARETTE')),
        ('expr_laugh', dict(skin=6, iris=6, bg=9, expr='LAUGH')),
    ]
    for name, kw in combos:
        kw = dict(kw)
        expr = kw.pop('expr', 'NEUTRAL')
        eyes = kw.pop('eyes', 'CLASSIC')
        hat = kw.pop('hat', 'NONE')
        wear = kw.pop('wear', 'NONE')
        item = kw.pop('item', 'NONE')
        grid = G.compose(base, expr, eyes, hat, wear, item, **kw)
        pal = assemble_8bit(kw.get('skin', 0), kw.get('iris', 0), kw.get('bg', 0),
                            skins, fixed, irises, bgs)
        im = Image.new('RGB', (48, 48))
        for y in range(48):
            for x in range(48):
                im.putpixel((x, y), pal[grid[y][x]] if grid[y][x] else pal[15])
        im = im.resize((480, 480), Image.NEAREST)
        im.save(f'{OUT}/preview_{tag}_{name}.png')
    print(f'previews -> {OUT}/preview_{tag}_*.png')


def dump_json():
    data = {}
    for key, base in PALETTES.items():
        lattice = build_lattice(base)
        skins, fixed, irises, bgs = snapped_palette_axes(lattice)
        data[key] = {
            'base16': [f'{r:02x}{g:02x}{b:02x}' for r, g, b in base],
            'intensities': INTENSITIES,
            'lattice': [f'{r:02x}{g:02x}{b:02x}' for r, g, b in lattice],
            'skins': [{str(s): f'{c[0]:02x}{c[1]:02x}{c[2]:02x}' for s, c in slots.items()}
                      for _, slots in skins],
            'fixed': {str(s): f'{c[0]:02x}{c[1]:02x}{c[2]:02x}' for s, c in fixed.items()},
            'irises': [f'{c[0]:02x}{c[1]:02x}{c[2]:02x}' for _, c in irises],
            'bgs': [f'{c[0]:02x}{c[1]:02x}{c[2]:02x}' for _, c in bgs],
        }
    os.makedirs(OUT, exist_ok=True)
    with open(f'{OUT}/lattice.json', 'w') as f:
        json.dump(data, f)
    print(f'lattice json ({ {k: len(v["lattice"]) for k, v in data.items()} })')


if __name__ == '__main__':
    which = sys.argv[1] if len(sys.argv) > 1 else 'dhgr'
    lattice = build_lattice(PALETTES[which])
    print(f'{which}: {len(lattice)} unique colors in lattice')
    for name, c in [('classic green', SKINS[0][1][2]), ('lips rose', FIXED[7]),
                    ('sky bg', BACKGROUNDS[0][1])]:
        print(f'  {name} {c} -> {snap(c, lattice)}')
    emit_solidity(lattice)
    render_sheets(lattice, which)
    dump_json()
