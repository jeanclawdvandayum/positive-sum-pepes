# PSP Trait Studio — GUI app spec

A single-file, dependency-free web app: a visual pixel-grid trait editor for
the Positive Sum Pepes art system, with a live pepe preview and a one-click
compiler to `PepeArtData.sol`. It REPLACES hand-editing the ASCII trait
files: same data model, but you paint real colors on a grid.

User: scoopy (art director). He judges by eyeball; give him big, crisp
previews and instant feedback. Desktop-first (macOS Chrome), dark theme,
pepe green accents. No build tooling required to USE it — the deliverable
opens from disk and works offline.

## Repo layout you will create (nothing else may change)
```
studio/
  compiler.js          # EXISTS — Agent A's module. DO NOT MODIFY. Read it.
  spec/                # EXISTS — read-only reference (specs + golden + state)
  src/
    index.html         # app shell (references ../compiler.js in dev)
    app.js             # all app logic
    app.css            # styles
    defaults.js        # GENERATED: see build steps (embedded repo state)
  tools/
    build_inline.py    # concatenates/inlines src + compiler + defaults
                       # -> ../dist/trait-studio.html (ONE self-contained file)
    make_defaults.py   # reads repo trait files + spec/psp_state.json
                       # -> src/defaults.js  (window.PSP_DEFAULTS = {...})
  dist/
    trait-studio.html  # the shippable artifact (also the deploy payload)
```

## Data model (mirrors compiler.js / gen_pepe_art.py — read COMPILER_SPEC.md)
- Canvas 48x48. Cells hold palette slot ints 0..15 (0 = transparent).
- Axes: `expressions`, `eyes` (full-canvas grids, DNA id = array index)
  and `hats`, `eyewear`, `items` (edited full-canvas too; export auto-crops
  to bounding box with dx/dy — compiler.gridToTrait does this). Stamp axes
  have implicit `NONE` at id 0 (not stored in the array).
- Palettes: 16 slots. Fixed: 5 white, 7 lips-rose, 8 lips-dark, 9 red,
  11 gold, 12 gold-dark, 13 cookie, 14 shades-black. Skin-recoloring:
  2 base, 3 light, 4 dark, 10 nostril. Iris -> 6. Background -> 15.
  Slot 1 (outline) unused. Slot names shown in tooltips.
- DNA counts: 8 expressions · 6 eyes · 5 hats · 5 eyewear · 5 items ·
  5 skins · 6 irises · 8 backgrounds (from current arrays — display live).

## Layout
Top bar: 🐸 **PSP TRAIT STUDIO** · axis tabs (EXPRESSIONS · EYES · HATS ·
EYEWEAR · ITEMS · PALETTES) · right side: [Import…] [Export Files] 
[▶ Compile] [Self-Test] and a modified-since-export dot.

Three-column body:
1. **LEFT — trait list** (hidden on palettes tab): rows with DNA id badge
   (`#0`, `#1`…) + name + thumbnail (24px render). Selected row highlighted.
   Buttons: + New, Duplicate, Rename, Delete, ▲▼ Move. Stamp axes show a
   pinned, non-editable `NONE #0` row at top.
   ⚠ Deleting/moving anything but the LAST trait shifts DNA ids of existing
   pepes — confirm dialog quoting the trait and new ordering. New traits
   append at the end (no warning needed).
2. **CENTER — grid editor**: 48x48 canvas, cell size slider 8–28px (default
   16), checkerboard-transparent or dark background. Tools: pencil, eraser,
   fill (flood same-slot), line, rectangle outline, eyedropper; brush
   paints single cells. **Mirror-X toggle** (paints x AND 47-x — eyes and
   mouths are symmetric, this is the killer feature). Undo/redo buttons +
   Ctrl/Cmd-Z / Shift-Ctrl/Cmd-Z, depth ≥100, per-trait stacks.
   Toggles: grid lines; **ghost base-head underlay** (the traced base at
   adjustable opacity — for placing hats/eyewear/items; expressions/eyes
   edits are drawn over it since those zones are stamp-owned anyway).
   Keyboard: B pencil, E eraser, G fill, L line, R rect, I eyedropper, M mirror.
   Status under canvas: cursor coords, active slot name, trait DNA id.
3. **RIGHT — preview + palette**:
   - LIVE PREVIEW: composite of base + selected expr + eye + hat + wear +
     item (compose order exactly like gen_pepe_art.compose: expr overlay,
     eye overlay, then hat, wear, item stamps — later wins). Rendered at
     crisp nearest-neighbor 4x (192px) default, switchable 1x/2x/4x/10x,
     transparent bg slot 15 color. Below: skin / iris / bg dropdowns
     (recolor preview AND palette swatches live), **RANDOM 🎲** (random
     DNA combo, shows the packed DNA number), **PNG ↓** (saves preview at
     current scale).
   - PALETTE dock: 16 swatches with resolved RGB for the current
     skin/iris/bg. Groups: TRANSPARENT (0, = eraser), SKIN (2,3,4,10 —
     labeled "recolors with skin"), IRIS (6), FIXED (5,7,8,9,11,12,13,14).
     Slots 1 & 15 shown grayed with tooltip "unused in stamps". Click a
     swatch to arm painting; armed swatch gets a ring. Also visible in the
     PALETTES tab: every skin/iris/bg color editable via <input
     type=color>, renamable, plus fixed slots editable (warn: affects all
     pepes); [Reset palettes] and the option to add/remove skins/irises/
     backgrounds (append-at-end + DNA warning).

**Validation panel** (collapsible bottom of right column, live):
- errors from the compiler (unknown letters etc. — should be impossible
  via GUI, but surface import errors here)
- "frogs have no teeth" heuristic: slot 5 pixels in rows ≥27 inside the
  mouth zone (cols 14–41) on an expressions trait → warning
- duplicate trait names; empty trait grids; trait pixels outside canvas
  bounds (impossible via GUI — skip); DNA-shift actions taken this session
  (log entries, dismissible).

## Compile modal
[▶ Compile] → `PSPCompiler.compileSolidity(state)` → modal: sha256 (Web
Crypto), line count, byte size, first/last lines preview, full text in a
scrollable <pre>, [Download PepeArtData.sol] [Copy]. If inputs equal the
embedded repo defaults, green banner "identical to repo build ✓". Modal
also shows per-layer byte sizes (stampBytes length per trait).

## Import / Export
- Import: multi-file picker (.txt trait files, palettes.json = the
  psp_state.json `palettes` object). Axis inferred per file by compiler's
  parseTraitText; on error show file+line in validation panel, skip file.
  Replacing an axis asks: Replace axis / Merge-append (new traits append
  at end; same-name traits overwritten in place, keeping DNA id).
- Export Files: downloads `expressions.txt`, `eyes.txt`, `hats.txt`,
  `eyewear.txt`, `items.txt` (compiler.traitText) and — if palettes were
  edited — `palettes.py` regenerated in the exact repo literal format
  (tuples `("Classic", {2: (0x62, 0xC8, 0x75), ...})` style, same comments
  header as the current file). Sequential downloads, no zip dependency.
- Persistence: full state autosaved to localStorage (debounced 500ms);
  on load, if a save exists offer Restore / Use defaults. [Reset all] in
  the top bar menu with confirm.

## Embedded defaults + self-test
- `tools/make_defaults.py` generates `src/defaults.js`:
  `window.PSP_DEFAULTS = { baseGrid, palettes, axes: {…name+grid per
  trait in DNA order…} }` from the REPO's current script/traits files +
  spec/psp_state.json (use compiler.js logic in node to build grids —
  import it, it's UMD).
- Embedded golden sha256 constant:
  `963b18626f9c17f43616411b1db41f35b9f86ea2964a7ba7610521c2558ce72d`.
- Self-Test (button + auto-run once on load + `window.__pspSelfTest()`
  returning a promise of {pass, sha}): compile embedded defaults →
  sha256 → compare constant. Badge in status bar: ✓ self-test passed /
  ✗ failed. This is the app's own proof the compiler chain is intact.

## Build + your acceptance tests (must run and pass before reporting done)
1. `python3 studio/tools/make_defaults.py` (run from repo root)
2. `python3 studio/tools/build_inline.py` → studio/dist/trait-studio.html
   — verify: single file, zero external references (`grep -E
   "src=\"http|href=\"http|fetch\(" dist/trait-studio.html` → nothing),
   contains compiler code.
3. `node studio/test_compiler.mjs` still passes (you didn't break it).
4. Browser check (use the browser toolset): serve `studio/dist` with
   `python3 -m http.server` (background), open the page, confirm:
   self-test badge ✓; paint a cell → preview updates; undo works (state
   reverts); switch axes; RANDOM preview renders; Compile modal shows
   sha and downloads (verify via console). Take a screenshot for your
   report. Kill the server after.

## Style
Dark (#0e120f-ish), pepe green (#62C875) accents, monospace for DNA/ids,
system font stack for UI. Big preview. No emoji spam beyond 🐸/🎲. Keep
DOM vanilla — no frameworks, no CDN. Everything offline.
