/*!
 * PSPCompiler — trait-text → Solidity compiler for the PSP pepe art pipeline.
 * Zero-dependency ES2020 UMD. Byte-identical JS port of the emit path of
 * script/gen_pepe_art.py (Python source of truth); the node test
 * (studio/test_compiler.mjs) proves byte-equality against the golden
 * studio/spec/golden/PepeArtData.sol.
 *
 * Load:
 *   browser <script>:  window.PSPCompiler
 *   node (CJS scope):  require('./compiler.js')  -> module.exports
 *   node (ESM scope):  import './compiler.js'    -> globalThis.PSPCompiler
 *                      (also set in every other case, harmless duplicate)
 */
(function (factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports !== undefined) {
    module.exports = api;
  }
  if (typeof globalThis !== 'undefined') {
    globalThis.PSPCompiler = api;
  }
})(function () {
  'use strict';

  const SIZE = 69;

  // letter -> palette slot (mirrors C2I in script/gen_pepe_art.py)
  const C2I = {
    '.': 0, '#': 1, 'G': 2, 'L': 3, 'D': 4, 'W': 5, 'P': 6,
    'r': 7, 'R': 8, 'c': 9, 'n': 10, 'g': 11, 'd': 12,
    'k': 13, 's': 14, 'b': 15,
    'H': 16, 'E': 17, 'X': 18, 'M': 19, 'A': 20, 'a': 21,
    'C': 22, 'o': 23,
  };
  if (Math.max(...Object.values(C2I)) >= 32) {
    throw new Error('palette must fit 5 bits');
  }
  // slot -> letter (mirrors I2C)
  const I2C = [];
  for (const ch of Object.keys(C2I)) I2C[C2I[ch]] = ch;

  const STAMP_AXES = { hats: true, eyewear: true, items: true };

  // Canonical per-axis file headers (verbatim from script/traits/*.txt).
  // traitText re-emits them so a parse→edit→serialize round trip keeps the
  // file byte-stable. Each ends with a single '\n'.
  const HEADERS = {
    head:
      '# PSP pepe traits \u2014 HEAD (the one base sprite, 69x69)\n' +
      "# Full-canvas format like expressions.txt: '# name: BASE' + '# y:' + 69-char rows.\n" +
      '# Letters: . transparent | G base-skin(2) | L light-skin(3) | D dark-skin(4)\n' +
      '#          n nostril(10) | H bright(16) E deep(17) X glint(18) M mid(19)\n' +
      '# Exactly ONE block. The head is NOT a DNA axis \u2014 every pepe starts here.\n',
    expressions:
      '# PSP pepe traits \u2014 EXPRESSIONS (mouth stamps, 69x69)\n' +
      "# Format: '# name:' starts a block; '# y:' = first row index on the 69x69\n" +
      "# canvas; every data row is EXACTLY 69 chars. '.' = transparent.\n" +
      '# Letters: . transparent | r lips-rose(7) | R lips-dark(8)\n' +
      '# DNA id = file order (block 0 = id 0). Frogs have NO teeth (tests check).\n',
    eyes:
      '# PSP pepe traits \u2014 EYES (eye stamps, rows ~22-36)\n' +
      "# Same format as expressions.txt: '# name:' + '# y:' + 69-char rows.\n" +
      '# Letters: . transparent | G base-skin(2) | L light-skin(3) | D dark-skin(4)\n' +
      '#          W eye-white(5) | P pupil/iris(6)\n' +
      '# The white bridge at cols 36-37 joins the eye TOPS (W rows); the\n' +
      '# light-skin ridge below keeps them distinct. DNA id = file order.\n',
    hats:
      '# PSP pepe traits \u2014 HATS (69x69)\n' +
      '# Letters: c red(9) W white(5) g gold(11) d gold-dark(12) r rose(7) R lips-dark(8)\n' +
      '#          H skin-bright(16) E skin-deep(17) X skin-glint(18) M skin-mid(19)\n' +
      '#          A steel-light(20) a steel-dark(21) C cream(22) o umber(23)\n' +
      "# Format: '# name:' + '# dx:' + '# dy:' then rows of uniform\n" +
      "# width. '.' = transparent. DNA id 0 is always NONE (implicit).\n" +
      '# Other blocks: DNA id = file order + 1.\n',
    eyewear:
      '# PSP pepe traits \u2014 EYEWEAR (69x69)\n' +
      '# Letters: s shades-black(14) W white(5) g gold(11)\n' +
      '#          A steel-light(20) a steel-dark(21) C cream(22)\n' +
      "# Format: '# name:' + '# dx:' + '# dy:' then rows of uniform\n" +
      "# width. '.' = transparent. DNA id 0 is always NONE (implicit).\n" +
      '# Other blocks: DNA id = file order + 1.\n',
    items:
      '# PSP pepe traits \u2014 ITEMS (69x69)\n' +
      '# Letters: c red(9) W white(5) d gold-dark(12) r rose(7)\n' +
      '#          s shades-black(14) n nostril-brown(10) g gold(11)\n' +
      '#          o umber(23) C cream(22) A steel-light(20) a steel-dark(21)\n' +
      "# Format: '# name:' + '# dx:' + '# dy:' then rows of uniform\n" +
      "# width. '.' = transparent. DNA id 0 is always NONE (implicit).\n" +
      '# Other blocks: DNA id = file order + 1.\n',
  };

  // header comment line -> axis (uppercase axis name must appear in it).
  // Longest names first so 'EYEWEAR' can never be shadowed.
  const UPPER = {
    head: 'HEAD',
    expressions: 'EXPRESSIONS',
    eyes: 'EYES',
    hats: 'HATS',
    eyewear: 'EYEWEAR',
    items: 'ITEMS',
  };
  const AXIS_ORDER = ['eyewear', 'expressions', 'eyes', 'hats', 'items', 'head'];

  const DIR_RE = /^#\s*(name|y|dx|dy):\s*(\S+)\s*$/;
  const INT_RE = /^[+-]?\d+$/;

  function zeroGrid() {
    const g = [];
    for (let y = 0; y < SIZE; y++) {
      const row = new Array(SIZE);
      for (let x = 0; x < SIZE; x++) row[x] = 0;
      g.push(row);
    }
    return g;
  }

  function inferAxis(text, source) {
    const lines = text.split('\n');
    for (const line of lines) {
      if (line.charAt(0) !== '#') continue;
      for (const axis of AXIS_ORDER) {
        if (line.indexOf(UPPER[axis]) !== -1) return axis;
      }
    }
    throw new Error(
      source + ':1: cannot infer axis from header (need one of ' +
      AXIS_ORDER.map((a) => UPPER[a]).join('/') + ')');
  }

  /**
   * parseTraitText(text[, source]) -> { axis, traits: [{name, y, dx, dy, rows}] }
   * rows are letter strings exactly as written in the file.
   * Throws Error('<source>:<line>: msg') on unknown letter, data before a
   * '# name:', duplicate name, ragged rows, bad integers.
   */
  function parseTraitText(text, source) {
    source = source || 'trait.txt';
    const axis = inferAxis(text, source);
    const isStamp = !!STAMP_AXES[axis];
    const lines = String(text).replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    const traits = [];
    const byName = Object.create(null);
    let cur = null;
    let width = null;
    for (let ln = 1; ln <= lines.length; ln++) {
      const line = lines[ln - 1];
      const m = DIR_RE.exec(line);
      if (m) {
        const key = m[1];
        const val = m[2];
        if (key === 'name') {
          if (Object.prototype.hasOwnProperty.call(byName, val)) {
            throw new Error(source + ':' + ln + ': duplicate name ' + val);
          }
          cur = { name: val, y: 0, dx: null, dy: null, rows: [] };
          byName[val] = cur;
          traits.push(cur);
          width = null;
        } else {
          if (!cur) throw new Error(source + ':' + ln + ': directive before name');
          if (!INT_RE.test(val)) {
            throw new Error(source + ':' + ln + ": bad integer '" + val + "'");
          }
          cur[key] = parseInt(val, 10);
        }
        continue;
      }
      if (line.charAt(0) === '#' || !line.trim()) continue; // comment / blank
      if (!cur) throw new Error(source + ':' + ln + ': data outside a block');
      for (const ch of line) {
        if (!Object.prototype.hasOwnProperty.call(C2I, ch)) {
          throw new Error(source + ':' + ln + ": unknown letter '" + ch + "'");
        }
      }
      if (width === null) width = line.length;
      else if (line.length !== width) {
        throw new Error(source + ':' + ln + ': ragged row (' + line.length +
          ' chars, expected ' + width + ')');
      }
      if (!isStamp && width !== SIZE) {
        throw new Error(source + ':' + ln + ': row must be exactly ' + SIZE +
          ' chars, got ' + width);
      }
      cur.rows.push(line);
    }
    return { axis, traits };
  }

  /**
   * traitToGrid(trait) -> 48x48 array of slot ints.
   * Full-canvas axes (expressions/eyes): rows are full-width 48, first row
   * index = trait.y. Stamp axes: rows placed at (trait.dx, trait.dy).
   * Dispatch: stamp placement iff dx or dy is set.
   */
  function traitToGrid(trait) {
    const g = zeroGrid();
    const rows = trait.rows || [];
    const stamp = trait.dx != null || trait.dy != null;
    if (stamp && (trait.dx == null || trait.dy == null)) {
      throw new Error('trait ' + trait.name + ': stamp placement needs both dx and dy');
    }
    const offY = stamp ? trait.dy : (trait.y || 0);
    const offX = stamp ? trait.dx : 0;
    for (let j = 0; j < rows.length; j++) {
      const row = rows[j];
      if (offY + j < 0 || offY + j >= SIZE) {
        throw new Error('trait ' + trait.name + ': row ' + j + ' out of bounds (y=' + (offY + j) + ')');
      }
      if (!stamp && row.length !== SIZE) {
        throw new Error('trait ' + trait.name + ': row ' + j + ' must be exactly ' + SIZE + ' chars');
      }
      for (let i = 0; i < row.length; i++) {
        const ch = row.charAt(i);
        if (ch === '.') continue;
        const slot = C2I[ch];
        if (slot === undefined) {
          throw new Error('trait ' + trait.name + ': unknown letter ' + JSON.stringify(ch));
        }
        const x = offX + i;
        if (x < 0 || x >= SIZE) {
          throw new Error('trait ' + trait.name + ': row ' + j + ' col ' + i + ' out of bounds');
        }
        g[offY + j][x] = slot;
      }
    }
    return g;
  }

  /**
   * stampBox(grid) -> [x0, y0, x1, y1] inclusive bounding box of non-zero
   * cells, or null when the grid is empty.
   */
  function stampBox(grid) {
    let x0 = SIZE, y0 = SIZE, x1 = -1, y1 = -1;
    for (let y = 0; y < grid.length; y++) {
      const row = grid[y];
      for (let x = 0; x < row.length; x++) {
        if (row[x]) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
      }
    }
    return y1 < 0 ? null : [x0, y0, x1, y1];
  }

  /**
   * gridToTrait(axis, name, grid) -> trait.
   * Full-canvas axes: y = bbox top, rows are the 48-wide absolute slices for
   * the bbox rows. Stamp axes: rows cropped to the bbox, dx/dy = bbox
   * top-left. Empty grid -> y:0 rows:[] (stamps: dx/dy 0).
   */
  function gridToTrait(axis, name, grid) {
    const isStamp = !!STAMP_AXES[axis];
    const box = stampBox(grid);
    if (!box) {
      return isStamp
        ? { name, y: 0, dx: 0, dy: 0, rows: [] }
        : { name, y: 0, dx: null, dy: null, rows: [] };
    }
    const x0 = box[0], y0 = box[1], x1 = box[2], y1 = box[3];
    const xStart = isStamp ? x0 : 0;
    const xEnd = isStamp ? x1 : SIZE - 1;
    const rows = [];
    for (let y = y0; y <= y1; y++) {
      let s = '';
      for (let x = xStart; x <= xEnd; x++) s += I2C[grid[y][x]];
      rows.push(s);
    }
    return isStamp
      ? { name, y: 0, dx: x0, dy: y0, rows }
      : { name, y: y0, dx: null, dy: null, rows };
  }

  /**
   * traitText(axis, traits) -> full .txt file text (canonical repo headers,
   * blocks in order, single trailing newline).
   */
  function traitText(axis, traits) {
    if (!Object.prototype.hasOwnProperty.call(HEADERS, axis)) {
      throw new Error("traitText: unknown axis '" + axis + "'");
    }
    const isStamp = !!STAMP_AXES[axis];
    const blocks = [];
    for (const t of traits) {
      const lines = ['# name: ' + t.name];
      if (isStamp) {
        if (t.dx != null) lines.push('# dx: ' + t.dx);
        if (t.dy != null) lines.push('# dy: ' + t.dy);
      } else {
        lines.push('# y: ' + (t.y || 0));
      }
      for (const r of (t.rows || [])) lines.push(r);
      blocks.push(lines.join('\n'));
    }
    return HEADERS[axis] + '\n' + blocks.join('\n\n') + '\n';
  }

  /**
   * rle(grid) -> array of byte ints. Per-row RLE; runs never cross rows.
   * v5 byte-pairs: [len-1][slot] — 24 palette slots don't fit the old
   * 4-bit nibble. Max run 256 (row width is 69).
   */
  function rle(grid) {
    const out = [];
    const w = grid[0].length;
    for (const row of grid) {
      if (row.length !== w) throw new Error('ragged grid row');
      let i = 0;
      while (i < w) {
        const p = row[i];
        let j = i;
        while (j < w && row[j] === p && j - i < 256) j++;
        out.push(j - i - 1, p);
        i = j;
      }
    }
    return out;
  }

  /**
   * stampBytes(grid) -> array of byte ints: 4-byte header (x0, y0, w, h)
   * from the bounding box of non-zero cells, then RLE of the crop.
   */
  function stampBytes(grid) {
    const box = stampBox(grid);
    if (!box) throw new Error('stampBytes: empty grid');
    const x0 = box[0], y0 = box[1], x1 = box[2], y1 = box[3];
    const crop = [];
    for (let y = y0; y <= y1; y++) {
      const row = [];
      for (let x = x0; x <= x1; x++) row.push(grid[y][x]);
      crop.push(row);
    }
    return [x0, y0, x1 - x0 + 1, y1 - y0 + 1].concat(rle(crop));
  }

  /** hexlit(bytes) -> 'hex"ABCD"' (UPPERCASE). */
  function hexlit(bytes) {
    let s = '';
    for (const b of bytes) {
      s += (b < 16 ? '0' : '') + b.toString(16).toUpperCase();
    }
    return 'hex"' + s + '"';
  }

  function hex6(c) {
    let s = '';
    for (const v of c) s += (v < 16 ? '0' : '') + v.toString(16).toUpperCase();
    return s;
  }

  /**
   * resolvePalette(palettes, skinId, irisId, bgId) -> [[r,g,b] x16].
   * palettes = psp_state.json 'palettes'. Skin slots 2,3,4,10; FIXED fills
   * 5,7,8,9,11,12,13,14; iris -> 6; bg -> 15; everything else [0,0,0].
   */
  function resolvePalette(palettes, skinId, irisId, bgId) {
    const pal = [];
    for (let i = 0; i < 24; i++) pal.push([0, 0, 0]);
    const skin = palettes.skins[skinId];
    for (const k of [2, 3, 4, 10, 16, 17, 18, 19]) {
      const c = skin.slots[k];
      pal[k] = [c[0], c[1], c[2]];
    }
    for (const k of [5, 7, 8, 9, 11, 12, 13, 14, 20, 21, 22, 23]) {
      const c = palettes.fixed[k];
      if (c) pal[k] = [c[0], c[1], c[2]];
    }
    const iris = palettes.irises[irisId].rgb;
    pal[6] = [iris[0], iris[1], iris[2]];
    const bg = palettes.backgrounds[bgId].rgb;
    pal[15] = [bg[0], bg[1], bg[2]];
    return pal;
  }

  // switch() generator — nested <=4-branch halves so via-ir never hits
  // stack-too-deep on the bytes-return ABI encoder (see Python source).
  function switchFn(fn, names, prefix) {
    const pairs = [];
    for (let i = 0; i < names.length; i++) {
      if (names[i] !== 'NONE') pairs.push([i, names[i]]);
    }
    const half = Math.ceil(pairs.length / 2);
    const lo = pairs.slice(0, half);
    const hi = pairs.slice(half);

    function chain(items) {
      const lines = [];
      for (let k = 0; k < items.length - 1; k++) {
        lines.push('        if (id == ' + items[k][0] + ') return ' + prefix + items[k][1] + ';');
      }
      lines.push('        return ' + prefix + items[items.length - 1][1] + ';');
      return lines.join('\n');
    }

    const guard = names[0] === 'NONE' ? '        if (id == 0) return "";\n' : '';
    let body;
    if (hi.length) {
      const split = lo[lo.length - 1][0] + 1;
      body = guard + '        if (id < ' + split + ') {\n' + chain(lo) +
        '\n        }\n' + chain(hi);
    } else {
      body = guard + chain(lo);
    }
    return '    function ' + fn + '(uint8 id) internal pure returns (bytes memory) {\n' +
      body + '\n    }';
  }

  /**
   * compileSolidity(state) -> the full PepeArtData.sol text.
   * state = { baseGrid, axes: {expressions:[{name,grid}], eyes:[...],
   * hats:[...], eyewear:[...], items:[...]}, palettes } — axes use 48x48
   * slot grids; stamp axes implicitly have NONE at id 0.
   */
  function compileSolidity(state) {
    const palettes = state.palettes;
    const axes = state.axes;

    const EXPR_NAMES = axes.expressions.map((t) => t.name);
    const EYE_NAMES = axes.eyes.map((t) => t.name);
    // NONE is implicit id 0 on stamp axes; drop it if a caller included one.
    const stripNone = (arr) => arr.filter((t) => t.name !== 'NONE');
    const HAT_NAMES = ['NONE'].concat(stripNone(axes.hats).map((t) => t.name));
    const WEAR_NAMES = ['NONE'].concat(stripNone(axes.eyewear).map((t) => t.name));
    const ITEM_NAMES = ['NONE'].concat(stripNone(axes.items).map((t) => t.name));

    function consts(arr, prefix) {
      const lines = [];
      for (const t of stripNone(arr)) {
        lines.push('    bytes internal constant ' + prefix + '_' + t.name +
          ' = ' + hexlit(stampBytes(t.grid)) + ';');
      }
      return lines.join('\n');
    }
    const layers = [
      consts(axes.expressions, 'EXPR'),
      consts(axes.eyes, 'EYE'),
      consts(axes.hats, 'HAT'),
      consts(axes.eyewear, 'WEAR'),
      consts(axes.items, 'ITEM'),
    ].join('\n\n');

    const rampHex = (slots) => [2, 3, 4, 10, 16, 17, 18, 19]
      .map((k) => hex6(slots[k])).join('');
    const skins = palettes.skins.map((s) => rampHex(s.slots)).join('');
    const fixed = [5, 7, 8, 9, 11, 12, 13, 14, 20, 21, 22, 23]
      .map((k) => hex6(palettes.fixed[k])).join('');
    const irises = palettes.irises.map((i) => hex6(i.rgb)).join('');
    const bgs = palettes.backgrounds.map((b) => hex6(b.rgb)).join('');

    return `// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PepeArtData — PSP on-chain pepe art v5 (69x69, 8-axis DNA)
/// @notice GENERATED FILE — do not edit by hand.
///         Regenerate with \`python3 script/gen_pepe_art.py\`
///         (2026-08-26). Art lives entirely in this bytecode: no IPFS,
///         no HTTP pointers, nothing off-chain.
/// @dev RLE format: TWO bytes per run = [len-1][paletteIndex],
///      row-major over the grid. Index 0 = transparent (skip).
///      Stamps carry a 4-byte header: dx, dy, w, h.
///      DNA: expression|eyes|hat|eyewear|item|skin|iris|background.
library PepeArtData {
    uint8 public constant SIZE = ${SIZE};
    uint8 public constant SLOTS = 24;
    uint8 public constant EXPR_COUNT = ${EXPR_NAMES.length};
    uint8 public constant EYE_COUNT = ${EYE_NAMES.length};
    uint8 public constant HAT_COUNT = ${HAT_NAMES.length};
    uint8 public constant WEAR_COUNT = ${WEAR_NAMES.length};
    uint8 public constant ITEM_COUNT = ${ITEM_NAMES.length};
    uint8 public constant SKIN_COUNT = ${palettes.skins.length};
    uint8 public constant IRIS_COUNT = ${palettes.irises.length};
    uint8 public constant BG_COUNT = ${palettes.backgrounds.length};
    uint256 public constant COMBOS =
        uint256(EXPR_COUNT) * EYE_COUNT * HAT_COUNT * WEAR_COUNT
        * ITEM_COUNT * SKIN_COUNT * IRIS_COUNT * BG_COUNT;

    bytes internal constant SPRITE_BASE = ${hexlit(rle(state.baseGrid))};

${layers}

    /// @dev skin ramps: 8x RGB per skin (slots 2,3,4,10,16,17,18,19)
    bytes internal constant SKIN_RAMPS = hex"${skins}";

    /// @dev fixed slots shared by all skins (5,7,8,9,11,12,13,14,20-23)
    bytes internal constant FIXED_SLOTS = hex"${fixed}";

    /// @dev iris colors override slot 6 (3 bytes each)
    bytes internal constant IRIS_COLORS = hex"${irises}";

    /// @dev background colors override slot 15 (3 bytes each)
    bytes internal constant BG_COLORS = hex"${bgs}";

${switchFn('expr', EXPR_NAMES, 'EXPR_')}

${switchFn('eye', EYE_NAMES, 'EYE_')}

${switchFn('hat', HAT_NAMES, 'HAT_')}

${switchFn('wear', WEAR_NAMES, 'WEAR_')}

${switchFn('item', ITEM_NAMES, 'ITEM_')}

    /// @dev skin + iris + bg -> full 24-slot palette.
    function palette(uint8 skinId, uint8 irisId, uint8 bgId)
        internal
        pure
        returns (bytes3[24] memory m)
    {
        bytes memory skins = SKIN_RAMPS;
        bytes memory slots = FIXED_SLOTS;
        for (uint256 i; i < 8; ++i) {
            uint256 o = uint256(skinId) * 24 + i * 3;
            m[[2, 3, 4, 10, 16, 17, 18, 19][i]] = bytes3(
                (uint24(uint8(skins[o])) << 16)
                    | (uint24(uint8(skins[o + 1])) << 8)
                    | uint24(uint8(skins[o + 2]))
            );
        }
        for (uint256 i; i < 12; ++i) {
            uint256 o = i * 3;
            m[[5, 7, 8, 9, 11, 12, 13, 14, 20, 21, 22, 23][i]] = bytes3(
                (uint24(uint8(slots[o])) << 16)
                    | (uint24(uint8(slots[o + 1])) << 8)
                    | uint24(uint8(slots[o + 2]))
            );
        }
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
    }
}
`;
  }

  return {
    SIZE,
    parseTraitText,
    traitToGrid,
    gridToTrait,
    traitText,
    rle,
    stampBox,
    stampBytes,
    hexlit,
    resolvePalette,
    compileSolidity,
  };
});
