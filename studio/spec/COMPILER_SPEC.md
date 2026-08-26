# PSP Compiler — JS port spec (byte-identical to Python)

GOAL: a dependency-free JavaScript module that, given the current repo trait
files + state, produces a `PepeArtData.sol` **byte-identical** to the Python
generator's output. The node test is the referee — iterate until PASS.

## Source of truth to port from
- `/Users/clawdbot/clawd/positive-sum-pepes/script/gen_pepe_art.py`
  (functions: `_parse_blocks`, `_load_full_grids`, `_load_stamps`, `rle`,
  `stamp_bytes`, `stamp_box`, `hexlit`, `emit_solidity` and the
  layer-stamp assembly in `main()`). READ THE WHOLE FILE FIRST.
- Trait inputs: `/Users/clawdbot/clawd/positive-sum-pepes/script/traits/*.txt`
  (5 files: expressions eyes hats eyewear items)
- Base grid + palettes + letter map:
  `/Users/clawdbot/clawd/positive-sum-pepes/studio/spec/psp_state.json`
- Golden output to match byte-for-byte:
  `/Users/clawdbot/clawd/positive-sum-pepes/studio/spec/golden/PepeArtData.sol`
  (sha256 `963b18626f9c17f43616411b1db41f35b9f86ea2964a7ba7610521c2558ce72d`)

## Deliverables
- `/Users/clawdbot/clawd/positive-sum-pepes/studio/compiler.js`
  — UMD-ish: attaches `window.PSPCompiler` in browsers, `module.exports`
  under node. Zero dependencies.
- `/Users/clawdbot/clawd/positive-sum-pepes/studio/test_compiler.mjs`
  — node test (see below).

## Public API (the GUI depends on this exact shape)
```js
PSPCompiler.SIZE;                       // 48
parseTraitText(text)                    // -> {axis, traits:[{name,y,dx,dy,rows}]}
  // axis: 'expressions'|'eyes'|'hats'|'eyewear'|'items'
  // inferred from the header comment line '# PSP pepe traits — EXPRESSIONS'
  // (that line contains the axis name uppercased; map to lowercase key).
  // Throws Error('<file>:<line>: msg') on: unknown letter, data before a
  // '# name:', duplicate name, ragged stamp rows.
traitToGrid(trait)                      // -> 48x48 array of slot ints
  // expressions/eyes: rows are full-width 48, first row index = trait.y
  // hats/eyewear/items: rows placed at trait.dx, trait.dy ('.' skipped)
gridToTrait(axis, name, grid)           // -> trait (rows/y or rows/dx/dy)
  // inverse: full-canvas axes -> bounding box, y = bbox top, rows are the
  // 48-wide absolute slices for bbox rows; stamp axes -> crop rows to bbox,
  // dx/dy = bbox top-left. Empty grid -> y:0 rows:[] (or dx/dy 0).
traitText(axis, traits)                 // -> full .txt file text (with the
  // same header comment block style as the repo files; blocks in order)
rle(grid)                               // -> array of byte ints
stampBytes(grid)                        // -> array of byte ints (bbox crop,
                                        //    4-byte header x0,y0,w,h then RLE)
resolvePalette(palettes, skinId, irisId, bgId)  // -> [[r,g,b] x16]
  // palettes = psp_state.json 'palettes' object; skin slots 2,3,4,10;
  // FIXED fill 5,7,8,9,11,12,13,14; iris -> 6; bg -> 15; rest [0,0,0]
compileSolidity(state)                  // -> string (the .sol file text)
  // state = { baseGrid, axes: { expressions:[{name,grid}...], eyes:[...],
  //   hats:[...], eyewear:[...], items:[...] }, palettes }
  // counts = array lengths (stamp axes implicitly have NONE at id 0);
  // layer bytes from grids via stampBytes; MUST equal golden for repo state.
```

## Byte-match pitfalls (from the Python source — verify each)
- `emit_solidity` is an f-string with `{{`/`}}` escapes — literal braces.
- Header comment contains the literal date `(2026-08-20)` and
  `v4 (48x48, 8-axis DNA)` — copy verbatim.
- hex literals: UPPERCASE (`hex"6080..."`).
- RLE: runs never cross rows, max run 16, byte = ((len-1)<<4)|slot.
- `stamp_bytes`: header (x0, y0, w, h) unsigned bytes from bounding box
  of non-zero cells (inclusive coords; w=x1-x0+1).
- Layer constants named `EXPR_<NAME>` etc, in axis order, EXPR/EYE/HAT/
  WEAR/ITEM blocks joined by blank lines; inside a block one constant per
  line, `bytes internal constant X = hex"...";`.
- SKIN_RAMPS: per skin, slots (2,3,4,10) concatenated; `%02X` uppercase.
- FIXED_SLOTS order: (5,7,8,9,11,12,13,14). IRIS_COLORS / BG_COLORS 3B each.
- The `switch` function generator: pairs exclude 'NONE'; half =
  ceil(len/2); `split = lo[-1][0] + 1`; guard `if (id == 0) return "";`
  ONLY when names[0] == 'NONE'; each chain ends with an unconditional
  `return` for its last item. Transcribe the exact string building.
- `palette(uint8 skinId, uint8 irisId, uint8 bgId)` body: copy verbatim
  from the generated golden .sol (it is fixed text).
- File ends with `}\n` (single trailing newline).

## Node test requirements (`studio/test_compiler.mjs`)
1. Load psp_state.json; parse all 5 repo trait files; build axes arrays;
   `compileSolidity` → compare `===` against golden .sol text read from
   spec/golden. Print both sha256 (node:crypto) and PASS/FAIL.
2. Round-trip grids: for every repo trait, `gridToTrait` then
   `traitToGrid` must deep-equal the original grid.
3. Round-trip text: `traitText(parse(file))` re-parsed equals the first
   parse (names, order, dx/dy/y) for all 5 files.
4. Exit non-zero on any failure; print a summary line for each check.

## Constraints
- Do NOT modify anything outside `/Users/clawdbot/clawd/positive-sum-pepes/studio/`
  except creating the two files above (and nothing in studio/spec/).
- No npm installs, no deps. Plain JS (ES2020), works in both node and browser.
- Iterate: `node studio/test_compiler.mjs` until all checks PASS.
