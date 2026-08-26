#!/usr/bin/env python3
"""PSP on-chain pepe art generator v5 — 69x69, 8-axis DNA trait stamps.

v5 (2026-08-26): resolution 48 -> 69 (nice). Base head RE-TRACED from the
user-provided pepe reference (script/assets/pepe_ref.jpg) at 69px block
majority — measured, not approximated. Authored zone constants scaled by
the shared transform S(v) = round(v*23/16) (script/resize69.py migrated
the trait stamps with the same map, so alignment holds by construction).
Palette widened 16 -> 24 slots: skins now carry a derived high-contrast
ramp (16 bright / 17 deep / 18 glint / 19 mid-shadow) for accessories,
plus fixed 20 steel-light, 21 steel-dark, 22 cream, 23 umber for
attribute shading. RLE runs are now byte-pairs [len-1, slot] (the old
4-bit nibble format cannot express 24 slots).

  expression  NEUTRAL / SMILE / GRIN / LAUGH / SAD / SCARED / ANGRY / SMIRK
  eyes        CLASSIC / FEELS / SLEEPY / DERP / WIDE / BAKED / STARRY /
              EYEROLL / DEAD
  hat         NONE / CAP / TINFOIL / CROWN / HEADBAND / NARUTO / TOPHAT /
              FRENCH / WIZARD / HOMER
  eyewear     NONE / SHADES / MONOCLE / GLASSES / MOGGED / MAGNIFYING /
              EYEPATCH / HEARTGLASSES
  item        NONE / CIGARETTE / PIPE / CHAIN / STITCHES / TATTOO /
              MUSTACHE / NOOSE
  skin        CLASSIC / GOLD / ZOMBIE / DIAMOND / NIGHT / GREY / ORANGE /
              GREEN  (slots 2,3,4,10 + derived 16-19)
  iris        7 colors overriding slot 6 (pupils + brows + bags)
  background  10 colors overriding slot 15 (independent of skin!)

Frogs have NO teeth: every mouth is solid lips / dark lining only.
The reference's white band at the left mouth corner was its cigarette.

Slot -> meaning (24 slots):
  0 transparent     1 outline (unused)  2 base skin       3 light skin
  4 dark skin shade 5 eye white         6 pupil/iris      7 lips rose
  8 lips dark       9 accent red       10 nostril brown  11 gold
 12 gold dark      13 cookie gold     14 shades black   15 background
 16 skin bright    17 skin deep       18 skin glint     19 skin mid-shadow
 20 steel light    21 steel dark      22 cream          23 umber
"""
import copy
import json
import os
import random
import re
import sys

from PIL import Image

SIZE = 69
C2I = {'.': 0, '#': 1, 'G': 2, 'L': 3, 'D': 4, 'W': 5, 'P': 6,
       'r': 7, 'R': 8, 'c': 9, 'n': 10, 'g': 11, 'd': 12,
       'k': 13, 's': 14, 'b': 15,
       'H': 16, 'E': 17, 'X': 18, 'M': 19, 'A': 20, 'a': 21,
       'C': 22, 'o': 23}
I2C = {v: k for k, v in C2I.items()}
assert max(C2I.values()) < 2 ** 5, 'palette must fit 5 bits'

ASSET = os.path.join(os.path.dirname(__file__), 'assets', 'pepe_ref.jpg')

# reference colors (measured from pepe_ref.jpg) -> slot
TRACE_COLS = {
    2: (0x62, 0xC8, 0x75),   # base green
    3: (0x8B, 0xD0, 0x7C),   # light green
    4: (0x2D, 0x50, 0x34),   # dark green shade / outline
    5: (0xFE, 0xFE, 0xFE),   # eye white
    6: (0x3F, 0x57, 0x5B),   # pupil slate
    7: (0xC8, 0x62, 0x6D),   # lips rose
    8: (0x43, 0x21, 0x22),   # mouth dark
    13: (0xB2, 0x75, 0x32),  # cookie gold
    12: (0x58, 0x3F, 0x29),  # cookie dark rim
}
# feature colors win ties: pupil > white > dark > lips > light > base > cookie
TRACE_PRIO = {6: 9, 5: 8, 4: 7, 8: 6, 7: 5, 3: 4, 2: 3, 13: 2, 12: 1, 0: 0}


def _sky(p):
    r, g, b = p
    return b > 140 and b > r + 30 and g > 110


def _trace():
    """1280x1280 jpg -> 48x48 slot grid, block majority vote."""
    im = Image.open(ASSET).convert('RGB')
    W, H = im.size[0], im.size[1]
    grid = [[0] * SIZE for _ in range(SIZE)]
    for ty in range(SIZE):
        for tx in range(SIZE):
            x0, x1 = tx * W // SIZE, (tx + 1) * W // SIZE
            y0, y1 = ty * H // SIZE, (ty + 1) * H // SIZE
            votes = {}
            for sy in range(y0, y1, 2):
                for sx in range(x0, x1, 2):
                    p = im.getpixel((sx, sy))
                    if _sky(p):
                        s = 0
                    else:
                        s = min(TRACE_COLS, key=lambda k: (
                            p[0] - TRACE_COLS[k][0]) ** 2
                            + (p[1] - TRACE_COLS[k][1]) ** 2
                            + (p[2] - TRACE_COLS[k][2]) ** 2)
                    votes[s] = votes.get(s, 0) + 1
            grid[ty][tx] = max(votes, key=lambda k: (votes[k], TRACE_PRIO[k]))
    return grid


# ─── base cleanup ────────────────────────────────────────────────────
# All constants below are the v4 48px originals pushed through
# S(v) = round(v*23/16) (inclusive spans via [S(a), S(b+1)-1]).
# snack (golden cookie) box in reference coords -> wipe to green; the
# cookie returns as an ITEM stamp so only some pepes hold it.
SNACK_BOX = (13, 35, 22, 46)        # x0, y0, x1, y1 (69-grid, inclusive)

# eye sockets (the turn: left eye wider, pair biased right). Rows include
# 2 spare rows on top for brows; stamps own brows->lids->whites->rounded
# bottom. Eye stamps reconnect the pair at the TOP (nose bridge skin).
EYE_Y0, EYE_Y1 = 22, 36             # stamp rows (brows..bottom of whites)
LX0, LX1 = 20, 35                   # left eye whites span (16 cols)
RX0, RX1 = 39, 54                   # right eye whites span (16 cols)

# nostrils, shifted right of face centerline for the turn; stay in the
# BASE (rows 37-39, above every expression stamp)
NOSTRILS = [(37, 32, 34), (38, 32, 34), (39, 32, 34),
            (37, 39, 41), (38, 39, 41), (39, 39, 41)]


def _base():
    g = _trace()
    # wipe the snack back to base skin (inside the head only)
    for y in range(SNACK_BOX[1], SNACK_BOX[3] + 1):
        for x in range(SNACK_BOX[0], SNACK_BOX[2] + 1):
            if g[y][x] != 0:
                g[y][x] = 2
    # stray dark pixels above the forehead -> dark skin shade
    for y in range(0, 22):
        for x in range(SIZE):
            if g[y][x] in (7, 8):
                g[y][x] = 4
    # stray traced "teeth" whites below the eye zone are mouth noise
    for y in range(39, 52):
        for x in range(SIZE):
            if g[y][x] == 5:
                g[y][x] = 7
    # clear the eye + mouth zones (stamps own them). Mouth clear extends
    # past the lower lip: the traced reference's lower-lip remnant must
    # NOT survive under thinner expression stamps or it reads as a
    # second, detached set of lips.
    for y in range(EYE_Y0, EYE_Y1 + 2):
        for x in range(LX0 - 1, RX1 + 4):
            if g[y][x] != 0:
                g[y][x] = 2
    for y in range(39, 52):
        for x in range(19, 61):
            if g[y][x] != 0:
                g[y][x] = 2
    # authored nostrils (keep their authored placement even though the
    # 69px trace resolves more of the reference nose)
    for (y, x0, x1) in NOSTRILS:
        for x in range(x0, x1 + 1):
            if g[y][x] != 0:
                g[y][x] = 10
    # 1px dark rim just inside the silhouette
    for y in range(SIZE):
        for x in range(SIZE):
            if g[y][x] in (2, 3):
                if (x == SIZE - 1 or g[y][x + 1] == 0) or (
                    y == SIZE - 1 or g[y + 1][x] == 0
                ) or x == 0 or g[y][x - 1] == 0 or y == 0 or g[y - 1][x] == 0:
                    g[y][x] = 4
    return g


# ─── trait file loaders ──────────────────────────────────
# Trait art is hand-editable text under script/traits69/. Those files are
# the source of truth for all trait pixels; this module parses them.
# (script/traits/ keeps the palettes + the 48px originals for reference;
#  script/traits48-backup/ is the pre-v5 snapshot.)

TRAITS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      'traits')          # palettes live here
ART = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'traits69')          # 69px trait grids live here
sys.path.insert(0, os.path.dirname(TRAITS))
from traits.palettes import SKINS, FIXED, IRISES, BACKGROUNDS

_DIR = re.compile(r'^#\s*(name|y|dx|dy):\s*(\S+)\s*$')


def _parse_blocks(path):
    """'# name:' blocks with optional '# y/dx/dy:' integer directives."""
    blocks, cur = {}, None
    for ln, raw in enumerate(open(path), 1):
        line = raw.rstrip('\n')
        m = _DIR.match(line)
        if m:
            key, val = m.groups()
            if key == 'name':
                cur = {'rows': [], 'y': 0, 'dx': None, 'dy': None}
                assert val not in blocks, f'{path} dup block {val}'
                blocks[val] = cur
            else:
                assert cur is not None, f'{path}:{ln} directive before name'
                cur[key] = int(val)
            continue
        if line.startswith('#') or not line.strip():
            continue                     # comment / blank separator
        assert cur is not None, f'{path}:{ln} data outside a block'
        for ch in line:
            assert ch in C2I, f'{path}:{ln} unknown letter {ch!r}'
        cur['rows'].append(line)
    return blocks


def _load_full_grids(path):
    """name -> 48x48 grid; data rows are full-canvas width, '# y:' = the
    first row's canvas index. DNA id = file order."""
    out = {}
    for name, b in _parse_blocks(path).items():
        g = [[0] * SIZE for _ in range(SIZE)]
        for j, row in enumerate(b['rows']):
            assert len(row) == SIZE, \
                f'{path} {name} row {j}: {len(row)} chars, need {SIZE}'
            for i, ch in enumerate(row):
                if ch != '.':
                    g[b['y'] + j][i] = C2I[ch]
        out[name] = g
    return out


def _load_stamps(path):
    """name -> {'rows', 'dx', 'dy'} letter-table stamps (hats etc.).
    'NONE' is implicit id 0; file blocks get ids 1..N in file order."""
    return _parse_blocks(path)


# ─── eye + expression stamps (script/traits/*.txt) ──────────

HEAD_PATH = os.path.join(TRAITS, 'head.txt')
_head_blocks = _load_full_grids(HEAD_PATH) \
    if os.path.exists(HEAD_PATH) else {}
HEAD_GRID = _head_blocks.get('BASE')   # None -> trace from reference
assert HEAD_GRID is None or len(HEAD_GRID) == SIZE, 'head.txt bad height'

EXPR_GRIDS = _load_full_grids(os.path.join(ART, 'expressions.txt'))
EYE_GRIDS = _load_full_grids(os.path.join(ART, 'eyes.txt'))
EXPRESSIONS = list(EXPR_GRIDS)          # DNA id = file order
EYES = list(EYE_GRIDS)


def _expr_grid(kind):
    """48x48 grid containing just the expression stamp."""
    return copy.deepcopy(EXPR_GRIDS[kind])


def _eye_grid(kind):
    """48x48 grid containing just the eye stamp."""
    return copy.deepcopy(EYE_GRIDS[kind])


# ─── hat stamps (script/traits/hats.txt) ──────────────

HATS = {'NONE': None, **_load_stamps(os.path.join(ART, 'hats.txt'))}
HAT_NAMES = ['NONE'] + [n for n in HATS if n != 'NONE']


# ─── eyewear stamps (script/traits/eyewear.txt) ────────

EYEWEAR = {'NONE': None,
           **_load_stamps(os.path.join(ART, 'eyewear.txt'))}
EYEWEAR_NAMES = ['NONE'] + [n for n in EYEWEAR if n != 'NONE']


# ─── item stamps (script/traits/items.txt) ───────────────

ITEMS = {'NONE': None, **_load_stamps(os.path.join(ART, 'items.txt'))}
ITEM_NAMES = ['NONE'] + [n for n in ITEMS if n != 'NONE']


def _stamp_grid(table, name):
    g = [[0] * SIZE for _ in range(SIZE)]
    spec = table[name]
    if spec is None:
        return g
    for j, row in enumerate(spec['rows']):
        assert len(row) == len(spec['rows'][0]), f'{name} ragged row {j}'
        for i, ch in enumerate(row):
            if ch != '.':
                g[spec['dy'] + j][spec['dx'] + i] = C2I[ch]
    return g


# ─── colors ───────────────────────────────────────────────
# SKINS / FIXED / IRISES / BACKGROUNDS live in script/traits/palettes.py
# (hand-editable). Skin ramps own slots {2 base, 3 light, 4 dark, 10
# nostril, 16 bright, 17 deep, 18 glint, 19 mid-shadow}; iris overrides
# slot 6; background overrides slot 15.

SLOTS = 24
SKIN_SLOTS = [2, 3, 4, 10, 16, 17, 18, 19]
FIXED_SLOTS = [5, 7, 8, 9, 11, 12, 13, 14, 20, 21, 22, 23]
assert SLOTS == 1 + max(SKIN_SLOTS + FIXED_SLOTS + [6, 15])


def assemble_palette(skin_id, iris_id, bg_id):
    pal = [(0, 0, 0)] * SLOTS
    for k, v in SKINS[skin_id][1].items():
        pal[k] = v
    for k, v in FIXED.items():
        pal[k] = v
    pal[6] = IRISES[iris_id][1]
    pal[15] = BACKGROUNDS[bg_id][1]
    return pal


# ─── encode ──────────────────────────────────────────────────────────

def rle(grid):
    """Per-row RLE, byte-pairs [len-1, slot]: runs never cross rows, max
    run 256 (row width is 69). Row width inferred = len(grid[0]); caller
    must feed full-width grids. Byte-pair format replaced v4's
    (len-1)<<4|slot nibble — 24 palette slots don't fit 4 bits."""
    out = bytearray()
    w = len(grid[0])
    for row in grid:
        assert len(row) == w, 'ragged grid row'
        i = 0
        while i < w:
            p = row[i]
            j = i
            while j < w and row[j] == p and j - i < 256:
                j += 1
            out.append(j - i - 1)
            out.append(p)
            i = j
    return bytes(out)


def stamp_bytes(grid, box):
    """Crop grid to box (x0,y0,x1,y1 inclusive), return header+RLE."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0 + 1, y1 - y0 + 1
    crop = [[grid[y][x] for x in range(x0, x1 + 1)]
            for y in range(y0, y1 + 1)]
    return bytes((x0, y0, w, h)) + rle(crop)


def stamp_box(grid):
    """Bounding box of non-transparent cells."""
    pts = [(y, x) for y in range(SIZE) for x in range(SIZE) if grid[y][x]]
    if not pts:
        return None
    ys = [p[0] for p in pts]
    xs = [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


def hexlit(b):
    return 'hex"' + b.hex().upper() + '"'


def emit_solidity(base, layer_stamps):
    def consts(d):
        return '\n'.join(
            f'    bytes internal constant {k} = {hexlit(v)};'
            for k, v in d.items())
    layers = '\n\n'.join(consts(d) for d in layer_stamps)

    def ramp_hex(d):
        return ''.join(
            '%02X%02X%02X' % d[k] for k in (2, 3, 4, 10, 16, 17, 18, 19))

    skins = ''.join(ramp_hex(s[1]) for s in SKINS)
    fixed = ''.join('%02X%02X%02X' % c for c in
                    (FIXED[k] for k in
                     (5, 7, 8, 9, 11, 12, 13, 14, 20, 21, 22, 23)))
    irises = ''.join('%02X%02X%02X' % i[1] for i in IRISES)
    bgs = ''.join('%02X%02X%02X' % b[1] for b in BACKGROUNDS)

    def switch(fn, names, prefix):
        # split into nested <=4-branch halves so via-ir never hits
        # stack-too-deep on the bytes-return ABI encoder
        pairs = [(i, n) for i, n in enumerate(names) if n != 'NONE']
        half = (len(pairs) + 1) // 2
        lo, hi = pairs[:half], pairs[half:]

        def chain(items, final_default):
            lines = [f'        if (id == {i}) return {prefix}{n};'
                     for i, n in items[:-1]]
            lines.append(f'        return {prefix}{items[-1][1]};'
                         if final_default else
                         f'        if (id == {items[-1][0]}) '
                         f'return {prefix}{items[-1][1]};')
            return '\n'.join(lines)

        body = ''
        guard = '        if (id == 0) return "";\n' \
            if names[0] == 'NONE' else ''
        if hi:
            split = lo[-1][0] + 1
            body = (guard + '        if (id < %d) {\n%s\n        }\n%s'
                    % (split, chain(lo, True), chain(hi, True)))
        else:
            body = guard + chain(lo, True)
        return ('    function ' + fn + '(uint8 id) internal pure '
                'returns (bytes memory) {\n' + body + '\n    }')

    return f'''// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PepeArtData — PSP on-chain pepe art v5 (69x69, 8-axis DNA)
/// @notice GENERATED FILE — do not edit by hand.
///         Regenerate with `python3 script/gen_pepe_art.py`
///         (2026-08-26). Art lives entirely in this bytecode: no IPFS,
///         no HTTP pointers, nothing off-chain.
/// @dev RLE format: TWO bytes per run = [len-1][paletteIndex],
///      row-major over the grid. Index 0 = transparent (skip).
///      Stamps carry a 4-byte header: dx, dy, w, h.
///      DNA: expression|eyes|hat|eyewear|item|skin|iris|background.
library PepeArtData {{
    uint8 public constant SIZE = {SIZE};
    uint8 public constant SLOTS = {SLOTS};
    uint8 public constant EXPR_COUNT = {len(EXPRESSIONS)};
    uint8 public constant EYE_COUNT = {len(EYES)};
    uint8 public constant HAT_COUNT = {len(HAT_NAMES)};
    uint8 public constant WEAR_COUNT = {len(EYEWEAR_NAMES)};
    uint8 public constant ITEM_COUNT = {len(ITEM_NAMES)};
    uint8 public constant SKIN_COUNT = {len(SKINS)};
    uint8 public constant IRIS_COUNT = {len(IRISES)};
    uint8 public constant BG_COUNT = {len(BACKGROUNDS)};
    uint256 public constant COMBOS =
        uint256(EXPR_COUNT) * EYE_COUNT * HAT_COUNT * WEAR_COUNT
        * ITEM_COUNT * SKIN_COUNT * IRIS_COUNT * BG_COUNT;

    bytes internal constant SPRITE_BASE = {hexlit(rle(base))};

{layers}

    /// @dev skin ramps: 8x RGB per skin (slots 2,3,4,10,16,17,18,19)
    bytes internal constant SKIN_RAMPS = hex"{skins}";

    /// @dev fixed slots shared by all skins (5,7,8,9,11,12,13,14,20-23)
    bytes internal constant FIXED_SLOTS = hex"{fixed}";

    /// @dev iris colors override slot 6 (3 bytes each)
    bytes internal constant IRIS_COLORS = hex"{irises}";

    /// @dev background colors override slot 15 (3 bytes each)
    bytes internal constant BG_COLORS = hex"{bgs}";

{switch('expr', EXPRESSIONS, 'EXPR_')}

{switch('eye', EYES, 'EYE_')}

{switch('hat', HAT_NAMES, 'HAT_')}

{switch('wear', EYEWEAR_NAMES, 'WEAR_')}

{switch('item', ITEM_NAMES, 'ITEM_')}

    /// @dev skin + iris + bg -> full {SLOTS}-slot palette.
    function palette(uint8 skinId, uint8 irisId, uint8 bgId)
        internal
        pure
        returns (bytes3[{SLOTS}] memory m)
    {{
        bytes memory skins = SKIN_RAMPS;
        bytes memory slots = FIXED_SLOTS;
        for (uint256 i; i < {len(SKIN_SLOTS)}; ++i) {{
            uint256 o = uint256(skinId) * {len(SKIN_SLOTS) * 3} + i * 3;
            m[[2, 3, 4, 10, 16, 17, 18, 19][i]] = bytes3(
                (uint24(uint8(skins[o])) << 16)
                    | (uint24(uint8(skins[o + 1])) << 8)
                    | uint24(uint8(skins[o + 2]))
            );
        }}
        for (uint256 i; i < {len(FIXED_SLOTS)}; ++i) {{
            uint256 o = i * 3;
            m[[5, 7, 8, 9, 11, 12, 13, 14, 20, 21, 22, 23][i]] = bytes3(
                (uint24(uint8(slots[o])) << 16)
                    | (uint24(uint8(slots[o + 1])) << 8)
                    | uint24(uint8(slots[o + 2]))
            );
        }}
        uint256 io = uint256(irisId) * 3;
        m[6] = bytes3(
            (uint24(uint8(IRIS_COLORS[io])) << 16)
                | (uint24(uint8(IRIS_COLORS[io + 1])) << 8)
                | uint24(uint8(IRIS_COLORS[io + 2]))
        );
        uint256 bo = uint256(bgId) * 3;
        m[15] = bytes3(
            (uint24(uint8(BG_COLORS[bo])) << 16)
                | (uint24(uint8(BG_COLORS[bo + 1])) << 8)
                | uint24(uint8(BG_COLORS[bo + 2]))
        );
    }}
}}
'''


# ─── previews ────────────────────────────────────────────────────────

def compose(base, expr, eye, hat, wear, item, skin=0, iris=0, bg=0):
    g = copy.deepcopy(base)
    for kind, table in ((expr, 'EXPR'), (eye, 'EYE')):
        if kind:
            src = (_expr_grid(kind) if table == 'EXPR' else _eye_grid(kind))
            for y in range(SIZE):
                for x in range(SIZE):
                    if src[y][x]:
                        g[y][x] = src[y][x]
    for name, tbl in ((hat, HATS), (wear, EYEWEAR), (item, ITEMS)):
        if name and name != 'NONE':
            ag = _stamp_grid(tbl, name)
            for y in range(SIZE):
                for x in range(SIZE):
                    if ag[y][x]:
                        g[y][x] = ag[y][x]
    return g


def render_png(grid, pal, scale, path):
    im = Image.new('RGB', (SIZE * scale, SIZE * scale),
                   tuple(pal[15]))  # background
    px = im.load()
    for y in range(SIZE):
        for x in range(SIZE):
            v = grid[y][x]
            if v:
                r, g, b = pal[v]
                for sy in range(scale):
                    for sx in range(scale):
                        px[x * scale + sx, y * scale + sy] = (r, g, b)
    im.save(path)


def main():
    outdir = '/tmp/psp-art'
    os.makedirs(outdir, exist_ok=True)
    # head.txt is the source of truth once it exists (script/out/
    # gen_head_txt.py wrote it from the original trace); the reference
    # trace + cleanup remains as the fallback/regeneration path.
    base = HEAD_GRID if HEAD_GRID is not None else _base()

    layer_stamps = []
    for names, prefix, builder in (
            (EXPRESSIONS, 'EXPR', _expr_grid),
            (EYES, 'EYE', _eye_grid),
            (HAT_NAMES, 'HAT', lambda n: _stamp_grid(HATS, n)),
            (EYEWEAR_NAMES, 'WEAR', lambda n: _stamp_grid(EYEWEAR, n)),
            (ITEM_NAMES, 'ITEM', lambda n: _stamp_grid(ITEMS, n))):
        d = {}
        for n in names:
            if n == 'NONE':
                continue
            g = builder(n)
            box = stamp_box(g)
            d[f'{prefix}_{n}'] = stamp_bytes(g, box)
        layer_stamps.append(d)

    with open('src/PepeArtData.sol', 'w') as f:
        f.write(emit_solidity(base, layer_stamps))

    # keep the studio state snapshot fresh (base + palettes) so
    # make_defaults.py and any tooling see the current art
    state = {
        'base_grid': base,
        'palettes': {
            'skins': [{'name': n, 'slots': {str(k): list(v)
                                            for k, v in r.items()}}
                      for n, r in SKINS],
            'fixed': {str(k): list(v) for k, v in FIXED.items()},
            'irises': [{'name': n, 'rgb': list(c)} for n, c in IRISES],
            'backgrounds': [{'name': n, 'rgb': list(c)}
                            for n, c in BACKGROUNDS],
        },
    }
    with open('studio/spec/psp_state.json', 'w') as f:
        json.dump(state, f)

    manifest = {'base': {'rle_bytes': len(rle(base))}, 'layers': {}}
    total = 0
    for d in layer_stamps:
        for k, b in d.items():
            manifest['layers'][k] = {
                'bytes': len(b), 'box': list(b[:4])}
            total += len(b)
    print(f"base: {len(rle(base))} RLE bytes; layers: {total} bytes")
    for d in layer_stamps:
        for k, b in d.items():
            print(f'  {k}: {len(b)}B box={list(b[:4])}')

    # ascii dump of the classic composite for eyeball checks
    combo = compose(base, 'NEUTRAL', 'CLASSIC', 'NONE', 'NONE', 'NONE')
    print('\nBASE+NEUTRAL+CLASSIC:')
    for row in combo:
        print(''.join(I2C[v] for v in row))

    # per-axis previews (vary one axis, rest default)
    pal00 = assemble_palette(0, 0, 0)
    for k in EXPRESSIONS:
        render_png(compose(base, k, 'CLASSIC', 'NONE', 'NONE', 'NONE'),
                   pal00, 10, f'{outdir}/expr_{k.lower()}.png')
    for k in EYES:
        render_png(compose(base, 'NEUTRAL', k, 'NONE', 'NONE', 'NONE'),
                   pal00, 10, f'{outdir}/eye_{k.lower()}.png')
    for k in HAT_NAMES:
        render_png(compose(base, 'NEUTRAL', 'CLASSIC', k, 'NONE', 'NONE'),
                   pal00, 10, f'{outdir}/hat_{k.lower()}.png')
    for k in EYEWEAR_NAMES:
        render_png(compose(base, 'NEUTRAL', 'CLASSIC', 'NONE', k, 'NONE'),
                   pal00, 10, f'{outdir}/wear_{k.lower()}.png')
    for k in ITEM_NAMES:
        render_png(compose(base, 'NEUTRAL', 'CLASSIC', 'NONE', 'NONE', k),
                   pal00, 10, f'{outdir}/item_{k.lower()}.png')
    for i, (n, _) in enumerate(SKINS):
        render_png(compose(base, 'NEUTRAL', 'CLASSIC', 'NONE', 'NONE',
                           'NONE'),
                   assemble_palette(i, 0, 0), 10, f'{outdir}/skin_{i}.png')
    for i, (n, _) in enumerate(IRISES):
        render_png(compose(base, 'NEUTRAL', 'CLASSIC', 'NONE', 'NONE',
                           'NONE'),
                   assemble_palette(0, i, 0), 10, f'{outdir}/iris_{i}.png')
    for i, (n, _) in enumerate(BACKGROUNDS):
        render_png(compose(base, 'NEUTRAL', 'CLASSIC', 'NONE', 'NONE',
                           'NONE'),
                   assemble_palette(0, 0, i), 10, f'{outdir}/bg_{i}.png')

    with open(f'{outdir}/manifest.json', 'w') as f:
        json.dump(manifest, f)
    print(f'\nwrote src/PepeArtData.sol + previews to {outdir}')


if __name__ == '__main__':
    main()
