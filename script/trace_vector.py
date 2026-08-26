#!/usr/bin/env python3
"""Vector (SVG path) pepe art experiment — traced with potrace (2026-08-24).

Option B of the art alternatives: high-quality vector pepes that look like
the original reference, 100% on-chain as SVG path strings (no images, no
IPFS). Base head is traced from the 1280px reference (quantized to slot
colors, feature zones wiped exactly like the pixel pipeline), then potrace
turns each color region into smooth Bezier paths. Trait stamps are upscaled
x10 from the 48-grid trait files and traced the same way — same DNA codec,
same layer order, so any DNA that renders as a pixel pepe also renders as a
vector pepe.

Emits:
  src/VectorBaseArt.sol     base paths + full palette constants
  src/VectorTraitArt.sol    stamp paths per trait axis
  src/VectorPepeDescriptor.sol   renderer (same codec as PepeDescriptor)
  script/out/vector/library.json   everything the JS lab needs
  script/out/vector/preview_*.svg  sample composites
"""
import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_pepe_art as G  # noqa: E402
from traits.palettes import SKINS, FIXED, IRISES, BACKGROUNDS  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image, ImageFilter  # noqa: E402
from scipy import ndimage  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out', 'vector')
W = 480          # working resolution
S = W // 48      # 48-grid -> working scale (10)

# potrace options tuned for cartoon regions
POT = ['potrace', '-s', '-u', '1', '--opttolerance', '0.4', '-t', '20']


def _hexs(c):
    return f'#{c[0]:02X}{c[1]:02X}{c[2]:02X}'


def _pal_asm():
    """16-slot palette per (skin, iris, bg) — same layout as the pixel lib."""
    def ramp(slots):
        return ''.join(_hexs(slots[s]).lstrip('#') for s in (2, 3, 4, 10))
    skins = ''.join(ramp(slots) for _, slots in SKINS)
    fixed = ''.join(_hexs(FIXED[s]).lstrip('#') for s in (5, 7, 8, 9, 11, 12, 13, 14))
    irises = ''.join(_hexs(c).lstrip('#') for _, c in IRISES)
    bgs = ''.join(_hexs(c).lstrip('#') for _, c in BACKGROUNDS)
    return skins, fixed, irises, bgs


# ── quantize the reference ───────────────────────────────────────────

def ref_slots():
    """reference -> W x W numpy slot map, zones wiped like the pixel base.

    The reference is flat-fill cartoon art: dead-flat green fill (single
    luminance 160) + a thin dark contour + features. So the vector base =
    flat green silhouette + smooth dark outline band. The outline band is
    the union of the dark-ish classifications (slots 3/4/6/8 all scatter
    along the rim depending on local anti-aliasing), dilated 1px to close
    gaps; it renders as slot 4 UNDER the green fill (green path is traced
    from the green region only, so the band reads as a clean rim).
    """
    im = Image.open(G.ASSET).convert('RGB').resize((W, W), Image.LANCZOS)
    a = np.asarray(im).astype(np.int32)
    sky = (a[:, :, 2] > 140) & (a[:, :, 2] > a[:, :, 0] + 30) & (a[:, :, 1] > 110)
    cols = {s: np.array(c, dtype=np.int32) for s, c in G.TRACE_COLS.items()}
    slot = np.full((W, W), -1, dtype=np.int32)
    best = np.full((W, W), np.inf)
    for s, c in cols.items():
        d = ((a - c) ** 2).sum(axis=2)
        closer = d < best
        slot[closer] = s
        best[closer] = d[closer]
    slot[sky] = 0

    # outline band: dark pixels + dark-ish classifications, dilated 1px
    lum = (0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2])
    band = (lum < 150) & (slot != 0)
    band |= (slot == 3) | (slot == 4) | (slot == 6) | (slot == 8)
    band &= (slot != 0)
    band = _dilate(band)
    slot[band] = 4

    # The head's OUTER CONTOUR survives the feature wipes below: rim
    # pixels adjacent to background are the silhouette edge, not interior
    # feature ink. (Caught by scoopy: gaps between the nubs/side of head
    # and the whole right side nub->chin, where the eye/mouth/snack wipe
    # rectangles crossed the outline.)
    outer = _shift_or((slot == 0), 3) & (slot == 4)

    def wipe(x0, y0, x1, y1, to=2):
        reg = slot[y0:y1, x0:x1]
        reg[(reg != 0) & ~outer[y0:y1, x0:x1]] = to

    # snack box (48-grid 9..15, 24..32 -> x10)
    wipe(9 * S, 24 * S, 16 * S, 33 * S)
    # eye zone rows 15..27(cols+2), cols 13..41
    wipe((G.LX0 - 1) * S, G.EYE_Y0 * S, (G.RX1 + 3) * S, (G.EYE_Y1 + 2) * S)
    # mouth zone rows 27..35, cols 13..42
    wipe(13 * S, 27 * S, 42 * S, 36 * S)
    slot[slot == -1] = 2
    # (speck control is potrace's job — the -t 20 turd filter)
    return slot


def _dilate(m):
    return (m | np.roll(m, 1, 0) | np.roll(m, -1, 0)
            | np.roll(m, 1, 1) | np.roll(m, -1, 1))


def _shift_or(m, n=1):
    for _ in range(n):
        m = m | np.roll(m, 1, 0) | np.roll(m, -1, 0) \
              | np.roll(m, 1, 1) | np.roll(m, -1, 1)
    return m


def _shift_and(m, n=1):
    for _ in range(n):
        m = m & np.roll(m, 1, 0) & np.roll(m, -1, 0) \
              & np.roll(m, 1, 1) & np.roll(m, -1, 1)
    return m


def _binary_open(m):
    return _shift_or(_shift_and(m, 2), 2)


def _binary_close(m):
    return _shift_and(_shift_or(m, 2), 2)


# ── potrace bridge ───────────────────────────────────────────────────

def trace_mask(mask):
    """bool numpy array -> SVG path d string (potrace y-up coords),
    or None when the region is empty / below the speck threshold."""
    return _trace_cmd(POT + ['-o', '-'], mask)


def _flip_y(d, H=480.0):
    """potrace path data is y-up (it normally ships a corrective
    translate(0,H) scale(1,-1) group that we strip). Bake the flip here so
    every consumer (previews, chain, studio) works in plain y-down SVG:
    absolute commands (uppercase) get y -> H - y per coordinate pair,
    relative commands (lowercase) get dy negated. 'z' takes no args."""
    parts = re.split(r'([A-Za-z])', d)
    out = []
    for k in range(1, len(parts), 2):
        letter = parts[k]
        nums = [float(x) for x in re.findall(r'-?\d+\.?\d*', parts[k + 1])]
        out.append(letter)
        if letter in 'zZ' or not nums:
            continue
        if letter.isupper():
            for j in range(1, len(nums), 2):
                nums[j] = H - nums[j]
        else:
            for j in range(1, len(nums), 2):
                nums[j] = -nums[j]
        out.append(''.join(
            (str(int(v)) if v == int(v) else '%.4g' % v) + ' ' for v in nums
        ).strip())
    return ' '.join(out).replace(' z', 'z')


def stamp_paths(grid48, tol='0.4'):
    """48x48 slot grid -> [(slot, d)] at 480 canvas, nonzero slots only.

    v2 (2026-08-24, after the ground-truth audit):
    - kron nearest-neighbor blocks + blur(8) + turd(30) destroyed every
      feature thinner than ~2 cells (mouth lines -> 0px, one iris lost,
      DEAD eyes empty). Now: BICUBIC upscale (smooth antialiased edges),
      blur <= 1.5, turd 2, and a validation ladder that falls back to
      exact-geometry tracing when the soft pass drops subpaths.
    - small round blobs (<= 20 cells, circularity >= 0.8) are emitted as
      exact circle paths - irises are perfectly round and symmetric by
      construction, never potrace mush.
    - every traced path gets _flip_y (potrace is y-up).
    """
    a = np.asarray(grid48, dtype=np.int32)
    out = []
    for s in sorted(set(a.flatten().tolist()) - {0}):
        m48 = (a == s)
        lab, n = ndimage.label(m48, structure=np.ones((3, 3)))
        need = n
        circles = []
        rest = m48.copy()
        for i in range(1, n + 1):
            blob = lab == i
            area = int(blob.sum())
            if area > 20:
                continue
            ys, xs = np.nonzero(blob)
            cy, cx = ys.mean(), xs.mean()
            rmax = float(np.hypot(ys - cy, xs - cx).max())
            circ = area / (np.pi * rmax ** 2) if rmax > 0 else 0.0
            if circ >= 0.8:
                r = np.sqrt(area / np.pi) * S
                circles.append(
                    _circle_path(cx * S + S / 2, cy * S + S / 2, r))
                rest &= ~blob
        d = None
        if rest.any():
            for blur, turd, mode in ((1.5, 2, 'bicubic'), (0, 1, 'bicubic'),
                                     (0, 1, 'kron')):
                m480 = _upscale(rest, mode)
                cand = _trace_soft(m480, tol, turd, blur)
                if cand and cand.count('M') >= need - len(circles):
                    d = _flip_y(cand)
                    break
                cand = cand or None
            if d is None:
                # best effort: exact geometry, no softening
                cand = _trace_soft(_upscale(rest, 'kron'), tol, 1, 0)
                if cand:
                    d = _flip_y(cand)
        if circles:
            cs = ' '.join(circles)
            d = (d + ' ' + cs) if d else cs
        if d:
            out.append((s, d))
    return out


def _circle_path(cx, cy, r):
    """exact circle as two arc commands (y-down canvas coords, no flip)"""
    return (f'M{cx - r:.1f} {cy:.1f} '
            f'a{r:.1f} {r:.1f} 0 1 0 {2 * r:.1f} 0 '
            f'a{r:.1f} {r:.1f} 0 1 0 -{2 * r:.1f} 0z')


def _upscale(m48, mode):
    if mode == 'kron':
        return np.kron(m48, np.ones((S, S), dtype=bool))
    im = Image.fromarray((m48 * 255).astype(np.uint8), 'L')
    im = im.resize((W, W), Image.Resampling.BICUBIC)
    return np.asarray(im) > 127


def _trace_soft(mask, tol, turd, blur):
    m = mask
    if blur:
        im = Image.fromarray((mask * 255).astype(np.uint8), 'L')
        m = np.asarray(im.filter(ImageFilter.GaussianBlur(blur))) > 127
    cmd = ['potrace', '-s', '-u', '1', '--opttolerance', str(tol),
           '-t', str(turd), '-o', '-']
    return _trace_cmd(cmd, m)


def _soften(mask, radius):
    """Gaussian blur + re-threshold a binary mask (corner rounding)."""
    im = Image.fromarray((mask * 255).astype(np.uint8), 'L')
    im = im.filter(ImageFilter.GaussianBlur(radius))
    return np.asarray(im) > (255 * 0.45)


def _trace_cmd(cmd, mask):
    h, w = mask.shape
    with tempfile.NamedTemporaryFile(suffix='.pbm', delete=False) as f:
        pbm = f.name
        f.write(b'P4\n%d %d\n' % (w, h))
        f.write(np.packbits(mask.astype(np.uint8), axis=None).tobytes())
    svg = subprocess.run(cmd + [pbm], capture_output=True, text=True,
                         check=True).stdout
    os.unlink(pbm)
    # potrace emits ONE <path> PER CONNECTED COMPONENT (in a shared
    # translate(0,H) scale(1,-1) group). Grab them ALL - taking only the
    # first silently drops every component except the largest (the audit
    # caught the rim band losing 3 of its 4 arcs this way).
    ds = re.findall(r'<path[^>]*\bd="([^"]+)"', svg)
    if not ds:
        return None
    # potrace wraps long path data across lines; flatten (newline -> space)
    return ' '.join(re.sub(r'\s*\n\s*', ' ', x).strip() for x in ds)


def base_paths():
    slot = ref_slots()
    # potrace is y-up: flip the base too (the audit caught the head
    # rendering upside down because this flip was missing)
    return {s: _flip_y(d) for s in (2, 3, 4)
            if (d := trace_mask(slot == s)) is not None}


# ── solid emit ───────────────────────────────────────────────────────

def _names_const(names):
    return '\n'.join(f'        if (id == {i}) return "{n}";'
                     for i, n in enumerate(names))


def emit_solidity(base, stamps, noff=(0, 0)):
    skins, fixed, irises, bgs = _pal_asm()

    names = {2: 'BASE_SKIN', 3: 'BASE_LIGHT', 4: 'BASE_DARK'}
    base_consts = '\n'.join(
        f'    /// @dev {"base skin region" if s == 2 else ("light shade" if s == 3 else "dark outline")} (slot {s})\n'
        f'    string internal constant {names[s]} = "{d}";'
        for s, d in sorted(base.items()))

    base_art = f"""// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title VectorBaseArt — traced vector pepe base + palettes (GENERATED by
///        script/trace_vector.py 2026-08-24 — do not edit by hand).
/// @dev Base head traced from script/assets/pepe_ref.jpg at 480px, feature
///      zones wiped exactly like the pixel pipeline; regions potraced to
///      smooth paths. Palette constants identical to PepeArtData.
library VectorBaseArt {{
    uint16 public constant SIZE = 480;

    /// @dev nostril nudge from the vector studio (48-grid cells, x10 used)
    int16 internal constant NOSTRIL_OFF_X = {noff[0]};
    int16 internal constant NOSTRIL_OFF_Y = {noff[1]};

{base_consts}

    /// @dev skin ramps: 8 skins x (2,3,4,10) x 3B
    bytes internal constant SKIN_RAMPS = hex"{skins}";

    /// @dev fixed slots (5,7,8,9,11,12,13,14)
    bytes internal constant FIXED_SLOTS = hex"{fixed}";

    /// @dev iris colors override slot 6
    bytes internal constant IRIS_COLORS = hex"{irises}";

    /// @dev background colors override slot 15
    bytes internal constant BG_COLORS = hex"{bgs}";

    /// @dev full 16-slot palette (verbatim mirror of PepeArtData.palette)
    function palette(uint8 skinId, uint8 irisId, uint8 bgId)
        internal
        pure
        returns (bytes3[16] memory m)
    {{
        bytes memory skins = SKIN_RAMPS;
        bytes memory slots = FIXED_SLOTS;
        for (uint256 i; i < 4; ++i) {{
            uint256 o = uint256(skinId) * 12 + i * 3;
            m[[2, 3, 4, 10][i]] = bytes3(
                (uint24(uint8(skins[o])) << 16)
                    | (uint24(uint8(skins[o + 1])) << 8)
                    | uint24(uint8(skins[o + 2]))
            );
        }}
        for (uint256 i; i < 8; ++i) {{
            uint256 o = i * 3;
            m[[5, 7, 8, 9, 11, 12, 13, 14][i]] = bytes3(
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
"""
    open(os.path.join(ROOT, 'src', 'VectorBaseArt.sol'), 'w').write(base_art)

    # trait art library
    def stamp_const(name, entries):
        parts = ',\n'.join(f'("{d}", "{p}")' for _s, p in entries for d in [_slot_digits(_s)])
        # entries are (slot,d) — emit as (slotDigit, path)
        parts = ',\n'.join(f'("{_slot_digits(s)}", "{p}")' for s, p in entries)
        return f'    string[2][] internal constant {name} = [{parts}];'

    def _slot_digits(s):
        return '0123456789ABCDEF'[s]

    chunks = ['// SPDX-License-Identifier: MIT',
              'pragma solidity 0.8.26;',
              '',
              '/// @title VectorTraitArt — traced vector trait stamps (GENERATED',
              '///        by script/trace_vector.py 2026-08-24 — do not edit).',
              '/// @dev Each entry = [slotDigit, pathD]. Paths are in x10 stamp-local',
              '///      coords; the descriptor translates by dx*10, dy*10.',
              'library VectorTraitArt {']
    def chunks_path(stamp_map, axis):
        """path constants block for one axis (packed: "slot|d;slot|d")"""
        out = []
        for name, meta in stamp_map[axis].items():
            entries = meta['paths']
            const = f'{axis.upper()}_{re.sub(r"[^A-Z0-9]", "_", name.upper())}'
            packed = ';'.join(f'{_slot_digits(s)}|{d}' for s, d in entries)
            out.append('    /// @dev packed paths: "slot|d;slot|d" (slot hex digit)')
            out.append(f'    string internal constant {const} = "{packed}";')
        return '\n'.join(out)

    def selector(axis, names, offset=0):
        rows = []
        for i, n in enumerate(names):
            rows.append(f'        if (id == {i + offset}) return {axis.upper()}_{re.sub(r"[^A-Z0-9]", "_", n.upper())};')
        rows.append(f'        return {axis.upper()}_{re.sub(r"[^A-Z0-9]", "_", names[0].upper())};')
        return '\n'.join(rows)

    def namefn(fn, names, offset=0):
        rows = []
        if offset:
            rows.append('        if (id == 0) return "None";')
        rows += [f'        if (id == {i + offset}) return "{n}";'
                 for i, n in enumerate(names)]
        rows.append(f'        return "{names[0]}";')
        return (f'    function {fn}(uint8 id) internal pure returns (string memory) {{\n'
                + '\n'.join(rows) + '\n    }')

    def offsel(axis, names, offset=1):
        rows = []
        for i, n in enumerate(names):
            base = f'{axis.upper()}_{re.sub(r"[^A-Z0-9]", "_", n.upper())}_OFF'
            rows.append(f'        if (id == {i + offset}) return ({base}_X, {base}_Y);')
        first = f'{axis.upper()}_{re.sub(r"[^A-Z0-9]", "_", names[0].upper())}_OFF'
        rows.append(f'        return ({first}_X, {first}_Y);')
        return '\n'.join(rows)

    expr_names = list(stamps['expr'].keys())
    eye_names = list(stamps['eyes'].keys())
    hat_names = [n for n in stamps['hat'].keys()]
    wear_names = [n for n in stamps['wear'].keys()]
    item_names = [n for n in stamps['item'].keys()]

    header = ['// SPDX-License-Identifier: MIT',
              'pragma solidity 0.8.26;',
              '',
              '/// @title VectorTraitArt — traced vector trait stamps (GENERATED',
              '///        by script/trace_vector.py 2026-08-24 — do not edit).',
              '/// @dev Each entry = [slotDigit, pathD]. Paths are in x10 stamp-local',
              '///      coords; the descriptor translates by dx*10, dy*10.']

    # library A: expressions + eyes (ids start at 0)
    a = list(header)
    a.append('library VectorTraitArt {')
    a.append(chunks_path(stamps, 'expr'))
    a.append(chunks_path(stamps, 'eyes'))
    # expr/eye offset constants (0 until the vector studio moves them)
    offa = []
    for axis in ('expr', 'eyes'):
        for n, m in stamps[axis].items():
            b_ = f'{axis.upper()}_{re.sub(r"[^A-Z0-9]", "_", n.upper())}_OFF'
            offa.append(f'    int16 internal constant {b_}_X = {m["dx"]};')
            offa.append(f'    int16 internal constant {b_}_Y = {m["dy"]};')
    a.append('\n'.join(offa))
    a.append(f'''
    /// @dev expression stamp paths for id
    function exprPaths(uint8 id) internal pure returns (string memory) {{
{selector('expr', expr_names)}
    }}

    /// @dev eye stamp paths for id
    function eyePaths(uint8 id) internal pure returns (string memory) {{
{selector('eyes', eye_names)}
    }}

    /// @dev expression stamp offset (48-grid cells) for id
    function exprOff(uint8 id) internal pure returns (int16 dx, int16 dy) {{
{offsel('expr', expr_names, 0)}
    }}

    /// @dev eye stamp offset (48-grid cells) for id
    function eyeOff(uint8 id) internal pure returns (int16 dx, int16 dy) {{
{offsel('eyes', eye_names, 0)}
    }}

    /// @dev trait names (same order as the pixel pipeline)
{namefn('exprName', expr_names)}

{namefn('eyeName', eye_names)}

    uint8 public constant EXPR_COUNT = {len(expr_names)};
    uint8 public constant EYE_COUNT = {len(eye_names)};
}}''')
    open(os.path.join(ROOT, 'src', 'VectorTraitArt.sol'), 'w').write('\n'.join(a) + '\n')

    # library B: hats + eyewear + items (0 = NONE implicit, 1..N file order)
    b = list(header)
    b.append('library VectorTraitArt2 {')
    for axis in ('hat', 'wear', 'item'):
        b.append(chunks_path(stamps, axis))

    offs = []
    for axis in ('hat', 'wear', 'item'):
        for n, m in stamps[axis].items():
            base = f'{axis.upper()}_{re.sub(r"[^A-Z0-9]", "_", n.upper())}_OFF'
            offs.append('    /// @dev dx, dy in 48-grid cells (x10 when used)')
            offs.append(f'    int16 internal constant {base}_X = {m["dx"]};')
            offs.append(f'    int16 internal constant {base}_Y = {m["dy"]};')
    b += [''] + offs + [f'''
    /// @dev hat stamp offset (48-grid cells) for id
    function hatOff(uint8 id) internal pure returns (int16 dx, int16 dy) {{
{offsel('hat', hat_names, 1)}
    }}

    /// @dev eyewear stamp offset (48-grid cells) for id
    function wearOff(uint8 id) internal pure returns (int16 dx, int16 dy) {{
{offsel('wear', wear_names, 1)}
    }}

    /// @dev item stamp offset (48-grid cells) for id
    function itemOff(uint8 id) internal pure returns (int16 dx, int16 dy) {{
{offsel('item', item_names, 1)}
    }}

    /// @dev hat stamp paths for id (0 = NONE, 1..N in file order)
    function hatPaths(uint8 id) internal pure returns (string memory) {{
{selector('hat', hat_names, 1)}
    }}

    /// @dev eyewear stamp paths for id (0 = NONE, 1..N in file order)
    function wearPaths(uint8 id) internal pure returns (string memory) {{
{selector('wear', wear_names, 1)}
    }}

    /// @dev item stamp paths for id (0 = NONE, 1..N in file order)
    function itemPaths(uint8 id) internal pure returns (string memory) {{
{selector('item', item_names, 1)}
    }}

    /// @dev trait names (same order as the pixel pipeline)
{namefn('hatName', hat_names, 1)}

{namefn('wearName', wear_names, 1)}

{namefn('itemName', item_names, 1)}

    uint8 public constant HAT_COUNT = {len(hat_names) + 1};
    uint8 public constant WEAR_COUNT = {len(wear_names) + 1};
    uint8 public constant ITEM_COUNT = {len(item_names) + 1};
}}''']
    open(os.path.join(ROOT, 'src', 'VectorTraitArt2.sol'), 'w').write('\n'.join(b) + '\n')
    print('emitted VectorBaseArt.sol + VectorTraitArt.sol + VectorTraitArt2.sol')


def _slot_digits(s):
    return '0123456789ABCDEF'[s]


# ── preview compose (python side, mirrors the descriptor) ────────────

def _pal(skin, iris, bg):
    pal = dict(FIXED)
    pal.update(SKINS[skin][1])
    pal[6] = IRISES[iris][1]
    pal[15] = BACKGROUNDS[bg][1]
    return pal


def compose_svg(base, stamps, expr, eyes, hat, wear, item, skin, iris, bg,
                noff=(0, 0)):
    pal = _pal(skin, iris, bg)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {W}">',
             f'<rect width="{W}" height="{W}" fill="{_hexs(pal[15])}"/>']
    for s in (4, 2, 3):  # rim under fill, green over, light shade on top
        if base.get(s):
            parts.append(f'<path d="{base[s]}" fill="{_hexs(pal[s])}"/>')
    # nostrils (authored, like the pixel pipeline) + studio offset
    parts.append(f'<g transform="translate({noff[0] * S},{noff[1] * S})">')
    for cx in (230, 280):
        parts.append(f'<ellipse cx="{cx}" cy="270" rx="9" ry="10" '
                     f'fill="{_hexs(pal[10])}"/>')
    parts.append('</g>')
    for axis, name in (('expr', expr), ('eyes', eyes), ('hat', hat),
                       ('wear', wear), ('item', item)):
        if not name or name == 'NONE':
            continue
        meta = stamps[axis][name]
        tx, ty = meta['dx'] * S, meta['dy'] * S
        for s, d in meta['paths']:
            parts.append(f'<g transform="translate({tx},{ty})">'
                         f'<path d="{d}" fill="{_hexs(pal[s])}"/></g>')
    parts.append('</svg>')
    return ''.join(parts)


def main():
    os.makedirs(OUT, exist_ok=True)
    print('tracing base from reference...')
    base = base_paths()
    for s, d in base.items():
        print(f'  slot {s}: {len(d)} chars')

    print('tracing stamps...')
    stamps = {'expr': {}, 'eyes': {}, 'hat': {}, 'wear': {}, 'item': {}}
    for name, grid in G.EXPR_GRIDS.items():
        stamps['expr'][name] = {'dx': 0, 'dy': 0, 'paths': stamp_paths(grid)}
    for name, grid in G.EYE_GRIDS.items():
        stamps['eyes'][name] = {'dx': 0, 'dy': 0, 'paths': stamp_paths(grid)}
    for axis, table in (('hat', G.HATS), ('wear', G.EYEWEAR), ('item', G.ITEMS)):
        for name, meta in table.items():
            if name == 'NONE' or meta is None:
                continue
            g = G._stamp_grid(table, name)
            stamps[axis][name] = {'dx': meta['dx'], 'dy': meta['dy'],
                                  'paths': stamp_paths(g)}

    # authored artistic overrides (script/authored_traits.py): smooth
    # Bezier construction in FINAL canvas coords — replaces the traced
    # pixel stamps entirely; offsets zero because coords are absolute.
    from authored_traits import AUTHORED
    for (axis, name), paths in AUTHORED.items():
        if name not in stamps[axis]:
            raise SystemExit(f'authored override for unknown {axis}/{name}')
        stamps[axis][name] = {'dx': 0, 'dy': 0, 'paths': list(paths)}
    print(f'  authored overrides applied: {len(AUTHORED)}')

    total = sum(len(d) for ax in stamps.values()
                for m in ax.values() for _s, d in m['paths'])
    print(f'  stamp path chars total: {total}')

    # manual placement overrides from the vector studio:
    # {"expr": {"SMILE": {"dx": 0, "dy": 1}}, ..., "nostrils": {"dx": 0, "dy": 0}}
    noff = {'dx': 0, 'dy': 0}
    ov_path = os.path.join(OUT, 'overrides.json')
    if os.path.exists(ov_path):
        ov = json.load(open(ov_path))
        for ax, traits in ov.items():
            if ax == 'nostrils':
                noff.update({k: int(v) for k, v in (traits or {}).items()})
                continue
            for n, off in (traits or {}).items():
                if n in stamps.get(ax, {}):
                    stamps[ax][n]['dx'] = int(off.get('dx', stamps[ax][n]['dx']))
                    stamps[ax][n]['dy'] = int(off.get('dy', stamps[ax][n]['dy']))
        print(f'  studio overrides applied from {ov_path}')

    emit_solidity(base, stamps, (noff['dx'], noff['dy']))

    # library.json for the JS lab
    lib = {
        'W': W, 'S': S,
        'base': {str(s): d for s, d in base.items()},
        'nostrils': [[230, 270, 9, 10], [280, 270, 9, 10]],
        'nostrils_off': [noff['dx'], noff['dy']],
        'stamps': {ax: {n: {'dx': m['dx'], 'dy': m['dy'],
                            'paths': [[s, d] for s, d in m['paths']]}
                        for n, m in t.items()} for ax, t in stamps.items()},
        'palettes': {
            'skins': [{str(s): list(c) for s, c in slots.items()} for _, slots in SKINS],
            'fixed': {str(s): list(c) for s, c in FIXED.items()},
            'irises': [list(c) for _, c in IRISES],
            'bgs': [list(c) for _, c in BACKGROUNDS],
            'skin_names': [n for n, _ in SKINS],
            'iris_names': [n for n, _ in IRISES],
            'bg_names': [n for n, _ in BACKGROUNDS],
        },
        'names': {'expr': list(G.EXPR_GRIDS), 'eyes': list(G.EYE_GRIDS),
                  'hat': G.HAT_NAMES, 'wear': G.EYEWEAR_NAMES,
                  'item': G.ITEM_NAMES},
    }
    with open(f'{OUT}/library.json', 'w') as f:
        json.dump(lib, f)
    print(f'library.json ({os.path.getsize(f"{OUT}/library.json")} bytes)')

    # sample composites
    samples = [
        ('classic', 'NEUTRAL', 'CLASSIC', 'NONE', 'NONE', 'NONE', 0, 0, 0),
        ('gold', 'SMILE', 'STARRY', 'WIZARD', 'NONE', 'PIPE', 1, 2, 1),
        ('zombie', 'SAD', 'SLEEPY', 'TOPHAT', 'SHADES', 'CIGARETTE', 2, 5, 6),
        ('diamond', 'LAUGH', 'WIDE', 'CROWN', 'GLASSES', 'CHAIN', 3, 1, 4),
    ]
    for row in samples:
        name = row[0]
        svg = compose_svg(base, stamps, *row[1:],
                          noff=(noff['dx'], noff['dy']))
        open(f'{OUT}/preview_{name}.svg', 'w').write(svg)
        print(f'preview_{name}.svg ({len(svg)} bytes)')


if __name__ == '__main__':
    main()
